module MCollective
  module Connector
    class Zeromq < Base
      def initialize
        Log.warn("Here goes")
      end

      def connect(connector = nil)
      end

      def disconnect
      end

      def subscribe(agent, type, collective)
        require 'ap'
        ap agent
        ap type
        ap collective
      end

      def unsubscribe(agent, type, collective)
      end

      def publish(message)
      end

      def receive

      end
    end
  end
end
