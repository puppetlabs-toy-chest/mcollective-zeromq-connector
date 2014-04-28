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

        @context = ZMQ::Context.new
        @socket = @context.socket(ZMQ::REQ)
        @mutex = Mutex.new

        # don't wait for messages to get delivered/received on close
        assert_zeromq(@socket.setsockopt(ZMQ::LINGER, 0))

        if get_bool_option('zeromq.curve.enabled', true)
          # load the curve keys
          middleware_public = IO.read(get_option('zeromq.curve.middleware_public_key')).chomp
          our_public  = IO.read(get_option('zeromq.curve.public_key')).chomp
          our_private = IO.read(get_option('zeromq.curve.private_key')).chomp

          # key the socket
          @socket.setsockopt(ZMQ::CURVE_SERVERKEY, middleware_public)
          @socket.setsockopt(ZMQ::CURVE_PUBLICKEY, our_public)
          @socket.setsockopt(ZMQ::CURVE_SECRETKEY, our_private)
        end
      end

      def connect
        Log.debug("connecting @socket to #{@endpoint}'")
        assert_zeromq(@socket.connect(@endpoint))

        response = make_request([ 'CONNECT', 'VERSION', '0.1' ])
        # TODO assert response[0] == 'OK'
        Log.debug "got #{response.inspect}"
      end

      def disconnect
        Log.debug('disconnecting')
        response = make_request([ 'DISCONNECT' ])
        assert_zeromq(@socket.close)
        Log.debug('disconnected')
      end

      def subscribe(agent, type, collective)
        Log.debug('subscribe')
        topic = topic_for_kind(agent, type, collective)[:topic]
        Log.debug("subscribing to topic '#{topic}'")
        response = make_request([ 'SUB', topic ])
        Log.debug "got #{response.inspect}"
      end

      def unsubscribe(agent, type, collective)
        Log.debug('unsubscribe')
        topic = topic_for_kind(agent, type, collective)[:topic]

        Log.debug("unsubscribing from topic '#{topic}'")
        response = make_request([ 'UNSUB', topic ])
        # TODO assert response[0] == 'OK'
        Log.debug "got #{response.inspect}"
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
          Log.debug('asking for a message from zeromq')

          response = make_request(['GET'])
          Log.debug(response.inspect)
          success = response.shift
          # TODO assert success == 'OK'

          kind = response.shift
          Log.debug("got a #{kind}")
          if kind == 'MESSAGE'
            topic = response.shift
            reply_to = response.shift
            body = response.shift

            headers = {}
            if reply_to != ''
              headers[:reply_to] = reply_to
            end
            Log.debug("message on '#{topic}' with #{headers.inspect}")
            return Message.new(body, nil, :headers => headers)
          end
          sleep 0.5
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

        response = make_request(['PUT', topic, reply_to, message.payload])
        # TODO assert response[0] == 'OK'
        Log.debug "got #{response.inspect}"
      end

      def make_request(message)
        @mutex.lock
        Log.debug "sending #{message.inspect}"
        assert_zeromq(@socket.send_strings(message))
        Log.debug 'sent'
        response = []
        assert_zeromq(@socket.recv_strings(response))
        @mutex.unlock
        return response
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
