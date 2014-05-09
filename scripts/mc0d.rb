#!/usr/bin/env ruby
require 'ffi-rzmq'
require 'logger'
require 'optparse'

class Middleware
  class Client
    attr_accessor :id
    attr_accessor :ttl
    attr_accessor :subscriptions
    attr_accessor :last_recv, :next_recv_by
    attr_accessor :last_send, :next_send_by
  end

  def initialize(options)
    @recv_count = 0
    @send_count = 0
    @clients = {}

    $stdout.sync = true
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO

    @context = ZMQ::Context.new
    @socket = @context.socket(ZMQ::ROUTER)
    @socket_mutex = Mutex.new

    if options.include?(:curve_private_key)
      @logger.debug "enabling curve with private key '#{options[:curve_private_key]}'"
      private_key = IO.read(options[:curve_private_key]).chomp
      assert_zeromq(@socket.setsockopt(ZMQ::CURVE_SERVER, 1))
      assert_zeromq(@socket.setsockopt(ZMQ::CURVE_SECRETKEY, private_key))
    end

    # start listening to the network
    endpoint = "tcp://#{options[:bind]}:#{options[:port]}"
    @logger.debug "binding #{endpoint}"
    assert_zeromq(@socket.bind(endpoint))

    Thread.new do
      status_thread
    end
  end

  def main_loop
    @logger.info "going into mainloop"
    start_heartbeat_threads

    poller = ZMQ::Poller.new
    assert_zeromq(poller.register_readable(@socket))

    while true
      # TODO - figure out next ping we to get, and set polling based on this
      @logger.debug "polling for messages"
      poller.poll
      @logger.debug "poller woke up"

      if poller.readables.empty?
        # Here is whete we should put the sending of PING
        @logger.debug 'time to send some pings'
      else
        @logger.debug 'message available'
        # Message to route
        source, message = read_message

        client = @clients[source]
        if client.nil?
          client = Client.new
          client.id = source
          client.subscriptions = []
          @clients[client.id] = client
        end

        begin
          verb = message.shift
          if end_of_headers = message.index('')
            headers = Hash[*message.first(end_of_headers)]
            body = message.drop(end_of_headers + 1)
          else
            headers = Hash[*message]
            body = []
          end

          if headers['ID']
            id = [ 'ID', headers['ID'] ]
          else
            id = []
          end

          case verb
          when 'CONNECT'
            # TODO(richardc): versioncmp
            @logger.info "CONNECT '#{source}' #{headers.inspect}"
            if headers['TTL']
              client.ttl = Integer(headers['TTL'])
              if client.ttl
                client.next_send_by = Time.now + (0.95 * (client.ttl / 1000.0))
              end
            end

          when 'DISCONNECT'
            @logger.info "DISCONNECT '#{source}'"
            @clients.delete(client.id)

          when 'SUB'
            client.subscriptions += body

          when 'UNSUB'
            client.subscriptions -= body

          when 'PUT'
            topic = headers['TOPIC']
            count = 0
            payload = [ 'MESSAGE' ] + headers.reject{ |k,v| k == 'ID' }.to_a.flatten + [ '' ] + body
            @clients.values.select { |x| x.subscriptions.include?(topic) }.each do |subscriber|
              count += 1
              send_message(subscriber, payload)
            end
            @logger.info "forwarded message on '#{topic}' from '#{client.id}' to #{count} recipients"

          when 'NOOP'
            # yeah, whatever

          else
            @logger.error "Don't know how to handle '#{verb}', saying ERROR"
            send_message(client, [ 'ERROR', 'MESSAGE', 'Unknown verb' ] + id)
          end

          if !id.empty?
            # request for acknowledgement
            send_message(client, [ 'OK' ] + id)
          end

        rescue Exception => e
          @logger.error "Caught exception #{e}"
          send_message(client, [ 'ERROR', 'MESSAGE', "caught exception: #{e} #{e.backtrace}" ] + id)
        end

        client.last_recv = Time.now
        if client.ttl
          client.next_recv_by = Time.now + (1.05 * (client.ttl / 1000.0))
        end
      end
    end
  end

  private

  def status_thread
    @logger.info "Starting status thread"

    lastmsg = ''
    while true
      newmsg = "Currently managing #{@clients.count} clients. Recv: #{@recv_count}. Sent #{@send_count}."
      if lastmsg != newmsg
        @logger.info newmsg
        lastmsg = newmsg
      end
      sleep 2
    end
  end

  def read_message
    @logger.debug 'going to read message'
    message = []
    @socket_mutex.synchronize do
      assert_zeromq(@socket.recv_strings(message))
    end
    source = message.slice!(0,2)[0]

    @recv_count += 1
    @logger.debug "got #{message.inspect} from #{source.inspect}"
    return source, message
  end

  def send_message(client, message)
    @logger.debug "sending #{message.inspect} to #{client.id}"
    @socket_mutex.synchronize do
      @socket.send_strings([ client.id, '', *message ], ZMQ::DONTWAIT)
    end
    @logger.debug 'sent message'
    client.last_send = Time.now
    if client.ttl
      client.next_send_by = Time.now + (0.95 * (client.ttl / 1000.0))
    end
    @send_count += 1
  end

  def start_heartbeat_threads
    Thread.new { heartbeat_send_thread }
    Thread.new { heartbeat_recv_thread }
  end

  def heartbeat_send_thread
    begin
      while true
        @logger.debug 'heartbeat_send_thread: checking'
        now = Time.now
        @clients.values.select { |x| x.ttl && x.next_send_by }.each do |client|
          if now >= client.next_send_by
            @logger.info "heartbeat_send_thread: sending to #{client.id}"
            send_message(client, [ 'NOOP' ])
          end
        end
        first_to_send = @clients.values.collect { |x| x.ttl && x.next_send_by }.min

        sleep_for = first_to_send ? (first_to_send - now) : 1
        if sleep_for > 0
          @logger.debug "heartbeat_send_thread: sleeping for #{sleep_for} seconds"
          sleep sleep_for
        end
      end
    rescue Exception => e
      @logger.error "heartbeat_send_thread: #{e} #{e.backtrace}"
      retry
    end
  end

  def heartbeat_recv_thread
    begin
      while true
        now = Time.now
        @clients.values.select { |x| x.ttl && x.next_recv_by }.each do |client|
          if now >= client.next_recv_by
            @logger.info "heartbeat_recv_thread: '#{client.id}' has gone away, deleting"
            @clients.delete(client.id)
          end
        end
        first_to_recv = @clients.values.collect { |x| x.ttl && x.next_recv_by }.min

        sleep_for = first_to_recv ? (first_to_recv - now) : 1
        if sleep_for > 0
          @logger.debug "heartbeat_recv_thread: sleeping for #{sleep_for} seconds"
          sleep sleep_for
        end
      end
    rescue Exception => e
      @logger.error "heartbeat_send_thread: #{e}"
      retry
    end
  end

  def assert_zeromq(rc)
    return if ZMQ::Util.resultcode_ok?(rc)
    raise "Operation failed, errno [#{ZMQ::Util.errno}] description [#{ZMQ::Util.error_string}]"
  end
end


options = {
  :bind => '*',
  :port => 61616,
}
OptionParser.new do |opts|
  opts.banner = "Usage: middleware [options]"

  opts.on('--bind', 'Address to bind') do |v|
    options[:bind] = v
  end

  opts.on('--port', 'Port to bind') do |v|
    options[:port] = v
  end

  opts.on('--curve-private-key=s', 'The curve privatekey') do |v|
    options[:curve_private_key] = v
  end
end.parse!

Middleware.new(options).main_loop
