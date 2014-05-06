require 'spec_helper'
require 'mcollective/connector/zeromq'

module MCollective
  module Connector
    describe Zeromq do
      let(:pluginconf) do
        pluginconf = double('pluginconf')
        pluginconf.stub(:include?)
        pluginconf
      end

      let(:config) do
        conf = double('config')
        conf.stub(:identity).and_return("rspec-identity")
        conf.stub(:pluginconf).and_return(pluginconf)
        conf
      end

      let(:connector) do
        Zeromq.new
      end

      before :each do
        Config.stub(:instance).and_return(config)
        Zeromq.any_instance.stub(:get_option).with('zeromq.broker.host').and_return('rspec.host')
        Zeromq.any_instance.stub(:get_option).with('zeromq.broker.port', '61616').and_return('61617')
        Zeromq.any_instance.stub(:get_option).with('zeromq.heartbeat', '30').and_return('30')
        Zeromq.any_instance.stub(:get_bool_option).with('zeromq.curve', true).and_return(true)
        Zeromq.any_instance.stub(:get_option).with('zeromq.broker.public_key').and_return('middleware.public')
        Zeromq.any_instance.stub(:get_option).with('zeromq.public_key').and_return('instance.public')
        Zeromq.any_instance.stub(:get_option).with('zeromq.private_key').and_return('instance.private')
        IO.stub(:read).with('instance.public').and_return('instance public key contents')
        IO.stub(:read).with('instance.private').and_return('instance private key contents')
        IO.stub(:read).with('middleware.public').and_return('middleware public key contents')
        Log.stub(:debug)
      end

      describe '#initialize' do
        it 'should attempt to load the curve key' do
          connector.instance_variable_get(:@curve_enabled).should == true
          connector.instance_variable_get(:@broker_public).should == 'middleware public key contents'
          connector.instance_variable_get(:@our_public).should == 'instance public key contents'
          connector.instance_variable_get(:@our_private).should == 'instance private key contents'
        end

        it 'should not load curve when disabled' do
          Zeromq.any_instance.stub(:get_bool_option).with('zeromq.curve', true).and_return(false)
          connector.instance_variable_get(:@curve_enabled).should == false
          connector.instance_variable_get(:@broker_public).should == nil
          connector.instance_variable_get(:@our_public).should == nil
          connector.instance_variable_get(:@our_private).should == nil
        end

        it 'should zero out the @subscriptions' do
          connector.instance_variable_get(:@subscriptions).should == []
        end

        it 'should set @endpoint' do
          connector.instance_variable_get(:@endpoint).should == 'tcp://rspec.host:61617'
        end

        it 'should set @heartbeat' do
          connector.instance_variable_get(:@heartbeat).should == 30
        end
      end

      describe '#connect' do
        let(:socket) do
          socket = double('zeromq socket')
          socket.stub(:setsockopt).and_return(0)
          socket.stub(:connect).and_return(0)
          socket.stub(:send_strings).and_return(0)
          socket
        end

        before :each do
          ZMQ::Context.any_instance.stub(:socket).and_return(socket)
          Zeromq.any_instance.stub(:send_message)
          Zeromq.any_instance.stub(:recv_message).and_return([])
          Zeromq.any_instance.stub(:expect_ok_with)
          Zeromq.any_instance.stub(:start_heartbeat_threads)
        end

        it 'should create a new socket, configure and connect' do
          ZMQ::Context.any_instance.should_receive(:socket).with(ZMQ::DEALER).and_return(socket)
          socket.should_receive(:setsockopt).with(ZMQ::IDENTITY, "rspec-identity #{$$} #{Thread.current.inspect}")
          socket.should_receive(:setsockopt).with(ZMQ::LINGER, 0)
          socket.should_receive(:setsockopt).with(ZMQ::CURVE_SERVERKEY, 'middleware public key contents')
          socket.should_receive(:setsockopt).with(ZMQ::CURVE_PUBLICKEY, 'instance public key contents')
          socket.should_receive(:setsockopt).with(ZMQ::CURVE_SECRETKEY, 'instance private key contents')
          socket.should_receive(:connect).with('tcp://rspec.host:61617')
          connector.should_receive(:make_command_id).and_return('rspec-command-id')
          connector.should_receive(:send_message).with([ 'CONNECT' ] + {
            'VERSION' => '0.2',
            'TTL' => '30000',
            'ID' => 'rspec-command-id',
          }.to_a.sort.flatten)
          connector.should_receive(:expect_ok_with).with('rspec-command-id')
          connector.should_receive(:start_heartbeat_threads)

          connector.connect
        end

        it 'should not set up CURVE when disabled' do
          Zeromq.any_instance.stub(:get_bool_option).with('zeromq.curve', true).and_return(false)
          socket.should_not_receive(:setsockopt).with(ZMQ::CURVE_SERVERKEY, 'middleware public key contents')

          connector.connect
        end
      end
    end
  end
end
