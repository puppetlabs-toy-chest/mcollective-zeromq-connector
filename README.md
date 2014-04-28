# mcollective-zeromq-connector

This is a playground for an experimental connector for
MCollective that'll communicate over 0mq.

This is the first MCollective connector I've written from scratch,
so I might not have all the behaviours down immediately.

In many configurations you'll want to run a middleware server to
allow things to connect together - there's a quick hacky one -
`bin/middleware`.  In the future that might want to become its own
project, and maybe in something lower level than ruby for the perfomance.

# Configuration

## Basic client/server

```
libdir = $PATH_TO_HERE/lib
connector = zeromq
plugin.zeromq.middlware = tcp://192.168.1.1:61616
plugin.zeromq.keepalive = 1 # default is 5
plugin.zeromq.curve.middleware_public_key = /etc/mcollective/middleware.public
plugin.zeromq.curve.public_key = /etc/mcollective/this_actor.public
plugin.zeromq.curve.private_key = /etc/mcollective/this_actor.private
```

Then start the middleware from bin/middleware on the middleware\_host

Authentication is via Curve and on by default.  To disable this you have to
use the option `zeromq.curve.enabled`

```
# Not recommended, but for a quick demo possibly forgivable
plugin.zeromq.curve.enabled = false
```

# TODO

Implement the 0.1 protocol from PROTOCOL.md

Find out if there's a better way to store/manage the curve keys.  Currently we
just keep them in a file as the zeromq library uses Z85 printable text.
http://api.zeromq.org/4-0:zmq-z85-encode

Verify curve keys more strongly.  Currently the only verification is that the
middleware matches its pre-shared public key.  Hopefully there's a mechanism
that more closely resembles an issuing certificate authority with a revocation
feature.

For maximum laziness figure out if we can key Curve from the OpenSSL CA/keys
that a puppet ca generates.
