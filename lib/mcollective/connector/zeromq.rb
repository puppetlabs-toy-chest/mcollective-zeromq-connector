require 'ffi-rzmq'
require 'msgpack'

module MCollective
  module Connector
    class Zeromq < Base
      # Implementation notes:

      # This connector is a simple 0MQ connector that uses a pair of PUB/SUB
      # sockets.  We publish to the PUB socket (@pub_socket), and receive on
      # the SUB socket (@sub_socket)

      # Message format:
      #   We send a multipart message of 3 parts:
      #      topic
      #      headers (a hash encoded with msgpack)
      #      body (MCollective::Message#payload)

      # Currently the only header we use/need is reply_to, so it might make
      # sense to just make the second part hold that.

      # Topics used:
      #   "#{collective} #{agent} "                - broadcast for agents
      #   "#{collective} reply #{identity} #{$$} " - replies
      #   "#{collective} nodes #{identity} "       - direct addressing to node
      #
      # It's worth bearing in mind that ZeroMQ PUB/SUB suscriptions operate as
      # a common prefix match on all messages passing so a subscription to 'a'
      # will get you messages to /^a/.  For this reason we need to be careful
      # about common prefixes (imagine a foo and foobar agent).  For agents
      # and identities spaces are illegal, so we add a trailing space to the
      # name as a sentinel.

      def initialize
        @context = ZMQ::Context.new
        @pub_socket = @context.socket(ZMQ::PUB)
        @sub_socket = @context.socket(ZMQ::SUB)
      end

      def connect
        Log.debug('connect')
        assert_zeromq(@pub_socket.connect('tcp://127.0.0.1:61615'))
        assert_zeromq(@sub_socket.connect('tcp://127.0.0.1:61616'))
      end

      def disconnect
        Log.debug('disconnect')
        assert_zeromq(@sub_socket.close)
        assert_zeromq(@pub_socket.close)
      end

      def subscribe(agent, type, collective)
        Log.debug('subscribe')
        topic = topic_for_kind(agent, type, collective)[:topic]
        Log.debug("subscribing to topic '#{topic}'")
        assert_zeromq(@sub_socket.setsockopt(ZMQ::SUBSCRIBE, topic))
        Log.debug("subscribed")
      end

      def unsubscribe(agent, type, collective)
        Log.debug('unsubscribe')
        topic = topic_for_kind(agent, type, collective)[:topic]
        Log.debug("unsubscribing from topic '#{topic}'")
        assert_zeromq(@sub_socket.setsockopt(ZMQ::UNSUBSCRIBE, topic))
        Log.debug("unsubscribed from topic '#{topic}'")
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
        Log.debug('Waiting for a message from zeromq')
        topic = ''
        headers_str = ''
        body = ''

        assert_zeromq(@sub_socket.recv_string(topic))
        unless @sub_socket.more_parts?
          raise 'expected multi-part message'
        end

        assert_zeromq(@sub_socket.recv_string(headers_str))
        unless @sub_socket.more_parts?
          raise 'expected multi-part message'
        end

        assert_zeromq(@sub_socket.recv_string(body))

        headers = MessagePack.unpack(headers_str)

        Message.new(body, nil, :headers => headers)
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
            :topic => message.request.headers['reply_to'],
            :headers => {},
          }
        else
          topic_for_kind(message.agent, message.type, message.collective, target)
        end
      end

      # the topic we should subscribe to for messages of this type
      def topic_for_kind(agent, type, collective, target = nil)
        reply_to = "#{collective} reply #{Config.instance.identity} #{$$} "
        stuff = {
          :topic => nil,
          :headers => {},
        }
        case type
        when :reply
          stuff[:topic] = reply_to

        when :broadcast, :request
          stuff[:topic] = "#{collective} #{agent} "
          stuff[:headers]['reply_to'] = reply_to

        when :direct_request
          # When we send a directed message
          stuff[:topic] = "#{collective} nodes #{target} "
          stuff[:headers]['reply_to'] = reply_to

        when :directed
          # Where we listen for directed messages
          stuff[:topic] = "#{collective} nodes #{Config.instance.identity} "

        else
          raise "Unknown message type #{type}"
        end

        stuff
      end

      def publish_message(message, node = nil)
        stuff = topic_for_message(message, node)
        topic = stuff[:topic]
        headers = stuff[:headers]

        if node
          Log.debug("sending direct message to '#{node}' on '#{topic}' with headers '#{headers.inspect}'")
        else
          Log.debug("sending message on '#{topic}' with headers '#{headers.inspect}'")
        end

        assert_zeromq(@pub_socket.send_string(topic, ZMQ::SNDMORE))
        assert_zeromq(@pub_socket.send_string(headers.to_msgpack, ZMQ::SNDMORE))
        assert_zeromq(@pub_socket.send_string(message.payload))
      end

      def assert_zeromq(rc)
        return if ZMQ::Util.resultcode_ok?(rc)
        raise "zeromq operation failed, errno [#{ZMQ::Util.errno}] description [#{ZMQ::Util.error_string}]"
      end
    end
  end
end
