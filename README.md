# mcollective-zeromq-connector

This a connector for MCollective that communicates using the 0mq library.

You'll need a broker to connect things together, there's a simple ruby
implementation of this in [scripts](scripts)/mc0d.rb and a more perfomant
C++11 implementation available as [mc0d](https://github.com/puppetlabs/mc0d)

# Requirements

0MQ 4.0.x or later http://zeromq.org/intro:get-the-software

ffi-rzmq http://rubygems.org/gems/ffi-rzmq

MCollective 2.5.0 or later

# Configuration

The most basic configuration will look like this:

```
connector = zeromq
plugin.zeromq.broker.host = 192.168.1.1
plugin.zeromq.broker.public_key = /etc/mcollective/broker.public
plugin.zeromq.public_key = /etc/mcollective/this_actor.public
plugin.zeromq.private_key = /etc/mcollective/this_actor.private
```

The keys can be generated with [curve_keygen][curve_keygen] from the zeromq
distribution.  Save the two parts in .public and .private files, and distribute
the broker public key to all the nodes you wish to connect.

[curve_keygen]: https://github.com/zeromq/zeromq4-x/blob/master/tools/curve_keygen.c

# Settings

## plugin.zeromq.broker.host

String, required. The hostname or ip address of the host running the mc0d
broker.

## plugin.zeromq.broker.port

Number, optional (default is 61616).  The port to connect to the mc0d broker
on.

## plugin.zeromq.curve

Boolean, optional (default is true).  Should
[CURVE](http://rfc.zeromq.org/spec:25) encryption/authentication be enabled.
It is *strongly* suggested that you do not disable this.

## plugin.zeromq.broker.public_key

String, required (unless `plugin.zeromq.curve` is false).  Path to a file
containing the public key for the mc0d broker.

## plugin.zeromq.public_key

String, required (unless `plugin.zeromq.curve` is false). Path to a file
containing the public key for this client/server.

## plugin.zeromq.private_key

String, required (unless `plugin.zeromq.curve` is false).  Path to a file
containing the private key for this client/server.

## plugin.zeromq.heartbeat

Integer, optional (default: 30).  The interval, expressed in seconds, at which
to a) expect to hear from the broker, or b) send some traffic to the broker.
This is used to detect stalled/dead connections.

# Limitations and notes

For a description of the protocol in use please see [PROTOCOL.md](PROTOCOL.md).

zeromq's implementation of Curve does not appear to easily allow for trust
relationship between keys, so there's no existing model for 'create a ca to
issue keys and track revocations'.

zeromq additionally does not seem to allow for the validation of client keys,
by the server http://hintjens.com/blog:36, the clients can only verify the
server is the one indicated by `plugin.zeromq.broker.public_key`.

The implementation of the broker does not allow for persistent queues, and so
advanced uses of MCollective's asyncronous reply handling pattern such as
those explained [here][async_handling] are not currently supported.

[async_handling]: http://www.devco.net/archives/2012/08/19/mcollective-async-result-handling.php
