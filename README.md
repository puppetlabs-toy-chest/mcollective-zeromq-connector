# mcollective-zeromq-connector

This is a playground for an experimental connector for
MCollective that'll communicate over 0mq.

This is the first MCollective connector I've written from scratch,
so I might not have all the behaviours down immediately.

In many configurations you'll want to run a middleware server to
allow things to connect together - there's a quick hacky one -
`bin/middleware`.  In the future that might want to become its own
project, and maybe in something lower level than ruby, but for now
it spends most of the time in `zeromq_proxy` which is over in libzmq
anyhow.

# Configuration

## Basic client/server

```
libdir = $PATH_TO_HERE/lib
connector = zeromq
plugin.zeromq.pub_endpoint = tcp://$MIDDLEWARE_HOST:61615
plugin.zeromq.sub_endpoint = tcp://$MIDDLEWARE_HOST:61616
```

Then start the middleware from bin/middleware on the middleware\_host

## ZeroMQ multicast with no dedicated server

```
libdir = $PATH_TO_HERE/lib
connector = zeromq
plugin.zeromq.pub_endpoint = epgm://en0;239.192.1.1:61616
plugin.zeromq.sub_endpoint = epgm://en0;239.192.1.1:61616
```

One potential gotcha where is you need pgm support built into your zeromq.
On my macports at least that's not the default:

    port install zmq-devel +pgm

This isn't 100% working for me right now, will update.

# TODO

Get the multicast example working all the way.

Add authentication configuration (Curve/Password)

Figure out if we can key Curve from the OpenSSL CA/keys that a
puppet ca generates.

