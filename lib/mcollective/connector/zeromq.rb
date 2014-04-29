require 'ffi-rzmq'
require 'msgpack'

  $stdout.sync = true

module MCollective
  module Connector
    class Zeromq < Base
      # Implementation notes:

      # This connector is a simple 0MQ connector that implements the 0.1
      # protocol as outlined in PROTOCOL.md

      # Topics used:
      #   "#{collective} #{agent}"                - broadcast for agents
      #   "#{collective} reply #{identity} #{$$}" - replies
      #   "#{collective} nodes #{identity}"       - direct addressing to node

      def initialize
        @endpoint = get_option('zeromq.middleware')
        @heartbeat = Integer(get_option('zeromq.heartbeat', '10'))

        @context = ZMQ::Context.new
        @socket = nil
        @socket_mutex = Mutex.new
        @subscriptions = []

        if get_bool_option('zeromq.curve.enabled', true)
          # load the curve keys
          @middleware_public = IO.read(get_option('zeromq.curve.middleware_public_key')).chomp
          @our_public  = IO.read(get_option('zeromq.curve.public_key')).chomp
          @our_private = IO.read(get_option('zeromq.curve.private_key')).chomp
        end
      end

      def connect
        Log.debug("creating new socket")
        @socket = @context.socket(ZMQ::DEALER)

        # set an identity based on the identity, pid, and thread.id of this context
        assert_zeromq(@socket.setsockopt(ZMQ::IDENTITY, "#{Config.instance.identity} #{$$} #{Thread.current.inspect}"))

        # don't wait for messages to get delivered/received on close
        assert_zeromq(@socket.setsockopt(ZMQ::LINGER, 0))

        if get_bool_option('zeromq.curve.enabled', true)
          # key the socket
          @socket.setsockopt(ZMQ::CURVE_SERVERKEY, @middleware_public)
          @socket.setsockopt(ZMQ::CURVE_PUBLICKEY, @our_public)
          @socket.setsockopt(ZMQ::CURVE_SECRETKEY, @our_private)
        end

        Log.debug("connecting @socket to #{@endpoint}'")
        assert_zeromq(@socket.connect(@endpoint))

        options = {
          'VERSION' => '0.2',
          'TTL'     => (@heartbeat * 1000).to_s,
        }

        send_message([ 'CONNECT', options.to_a ].flatten)

        if !@subscriptions.empty?
          # reconnection, resub
          send_message([ 'SUB', @subscriptions ].flatten)
        end

        @last_recv = nil
        @next_recv_by = Time.now + @heartbeat
        if !@heartbeat_thread
          Log.debug("spawning a monitoring thread")
          @heartbeat_thread = Thread.new { heartbeat_thread }
        end
      end

      def disconnect(kill_thread = true)
        Log.debug('disconnecting')
        if kill_thread
          @keepalive_thread.kill
        end

        send_message([ 'DISCONNECT' ])
        sleep 0.5 # allow for DISCONNECT to be queued/delivered
        @socket_mutex.synchronize do
          assert_zeromq(@socket.close)
        end
        @socket = nil
        Log.debug('disconnected')
      end

      def subscribe(agent, type, collective)
        Log.debug('subscribe')
        topic = topic_for_kind(agent, type, collective)[:topic]
        Log.debug("subscribing to topic '#{topic}'")
        send_message([ 'SUB', topic ])
        @subscriptions += [ topic ]
      end

      def unsubscribe(agent, type, collective)
        Log.debug('unsubscribe')
        topic = topic_for_kind(agent, type, collective)[:topic]

        Log.debug("unsubscribing from topic '#{topic}'")
        send_message([ 'UNSUB', topic ])
        @subscriptions -= [ topic ]
      end

      def publish(message)
        Log.debug('publish')

        if message.type == :direct_request
          message.discovered_hosts.each do |node|
            publish_message(message, node)
          end
        else
          publish_message(message)
        end

        Log.debug("publish done")
      end

      def receive
        while true
          Log.debug('receive a message from zeromq')
          message = recv_message
          @last_recv = Time.now
          @next_recv_by = @last_recv + @heartbeat

          kind = message.shift
          Log.debug("got a #{kind}")

          case kind
          when 'PING'
            send_message([ 'PONG', *message ])

          when 'MESSAGE'
            topic = message.shift
            reply_to = message.shift
            body = message.shift

            headers = {}
            if reply_to != ''
              headers[:reply_to] = reply_to
            end
            Log.debug("message on '#{topic}' with #{headers.inspect}")
            return Message.new(body, nil, :headers => headers)
          end
        end
      end

      private

      # topic_for_message and topic_for_kind e the behaviour of the activemq
      # connector a little.  As it's fresh here's a braindump
      #
      # The problem is you need to be able to compute a topic/queue name in a
      # certain number of situations:
      #    As a client
      #       when subscribing to your reply topic
      #       when sending a message to the servers to say 'please do this'
      #       when sending a directed message to a specific server to say 'please do this'

      #    As a daemon
      #       when subscribing to all the topics for all the agents you have
      #       when unsubscribing from those same set of topics
      #       when sending a response to a message

      # Subscription happens in response to a call to connector.subscribe(agent, type, collective)
      # and so these directly call topic_for_kind(agent, type, collective) and use the topic part of the answer

      # Unsubscription is the same pattern, but from connector.unsubscribe

      # Sending any request via .publish(MCollective::Message) is where it
      # gets interesting.

      # In the 'broadcast' mode we call topic_for_message(message) which then
      # (assuming it's not a reply), delegates to topic_for_kind(message.agent, message.type, message.collective)

      # If it's a directed request from direct addressing we iterate over the
      # set of discovered nodes (message.discovered_hosts) and call
      # topic_for_message(message, target) which calls topic_for_kind(a,t,c,
      # NODE) to generate a message with (in the activemq case) a header that
      # will match the selector.  With this connector we just make another
      # topic per node, with the assumption that it's possibly cheap enough
      # for ZeroMQ to have 2,000 'topics'

      # In all the 'we're making a request' codepaths (:broadcast, :request)
      # we also return a set of headers with our reply_to set.  This is the
      # mechanism by which we can send a response at all, and is in no other
      # part of the message. (it's message.request.headers['reply_to'])

      # the topic we should send this message on
      def topic_for_message(message, target = nil)
        case message.type
        when :reply
          {
            :topic => message.request.headers[:reply_to],
            :reply_to => '',
          }
        else
          topic_for_kind(message.agent, message.type, message.collective, target)
        end
      end

      # the topic we should subscribe to for messages of this type
      def topic_for_kind(agent, type, collective, target = nil)
        reply_to = "#{collective} reply #{Config.instance.identity} #{$$}"
        envelope = {
          :topic => nil,
          :reply_to => '',
        }
        case type
        when :reply
          envelope[:topic] = reply_to

        when :broadcast, :request
          envelope[:topic] = "#{collective} #{agent}"
          envelope[:reply_to] = reply_to

        when :direct_request
          # When we send a directed message
          envelope[:topic] = "#{collective} nodes #{target}"
          envelope[:reply_to] = reply_to

        when :directed
          # Where we listen for directed messages
          envelope[:topic] = "#{collective} nodes #{Config.instance.identity}"

        else
          raise "Unknown message type #{type}"
        end

        envelope
      end

      def publish_message(message, node = nil)
        envelope = topic_for_message(message, node)
        topic = envelope[:topic]
        reply_to = envelope[:reply_to]

        if node
          Log.debug("sending direct message to '#{node}' on '#{topic}' with reply_to '#{reply_to}'")
        else
          Log.debug("sending message on '#{topic}' with reply_to '#{reply_to}'")
        end

       send_message(['PUT', topic, reply_to, message.payload])
      end

      def send_message(message)
        Log.debug "sending #{message.inspect}"
        @socket_mutex.synchronize do
          assert_zeromq(@socket.send_strings([''] + message, ZMQ::DONTWAIT))
        end
        Log.debug 'sent'
      end

      def recv_message
        response = []
        poller = ZMQ::Poller.new
        poller.register_readable(@socket)
        poller.poll
        if poller.readables.empty?
          # We probably woke up because the connection was closed.  Raise a backoff error
          raise MessageNotReceived.new(10), "Socket didn't become readable"
        end

        @socket_mutex.synchronize do
          Log.debug 'doing read'
          assert_zeromq(@socket.recv_strings(response))
        end
        # as we're now a DEALER first frame is ''
        response.shift
        Log.debug "got #{response.inspect}"
        return response
      end

      def heartbeat_thread
        begin
          while true
            if Time.now > @next_recv_by
              # try and stimulate the connection with a PING
              send_message([ 'PING' ])
              sleep 1 # allow PONG to be handled in the main thread
            end

            now = Time.now
            if now > @next_recv_by
              last_heard = 'never'
              if @last_recv
                last_heard = "#{now - @last_recv} seconds ago"
              end

              Log.warn "Last heard from the middleware #{last_heard}.  Reconnecting."
              # disconnect(false), don't shoot the keepalive thread (ourself) in the face
              disconnect(false)
              sleep 1
              connect
            end

            time_to_wait = @next_recv_by - Time.now
            if time_to_wait > 0
              Log.debug "sleeping for #{time_to_wait} seconds"
              sleep time_to_wait
            end
          end
        rescue Exception => e
          Log.error "error in heartbeat_thread: #{e}"
        end
      end

      def assert_zeromq(rc)
        return if ZMQ::Util.resultcode_ok?(rc)
        raise "zeromq operation failed, errno [#{ZMQ::Util.errno}] description [#{ZMQ::Util.error_string}]"
      end

      def get_option(opt, default=nil)
        if Config.instance.pluginconf.include?(opt)
          return Config.instance.pluginconf[opt]
        end

        return default unless default.nil?

        raise("No plugin.#{opt} configuration option given")
      end

      def get_bool_option(opt, default=nil)
        if Config.instance.pluginconf.include?(opt)
          return Util.str_to_bool(Config.instance.pluginconf[opt])
        end

        return default unless default.nil?

        raise("No plugin.#{opt} configuration option given")
      end
    end
  end
end
