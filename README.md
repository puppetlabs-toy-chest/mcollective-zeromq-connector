# mcollective-zeromq-connector

This for an experimental connector for MCollective that'll communicate
over 0mq.

You'll need a broker to connect things together, there's a quick hacky
implementation in `scripts/mc0d.rb`.

# Configuration

## server.cfg/client.cfg

```
libdir = $PATH_TO_HERE/lib
connector = zeromq
plugin.zeromq.middlware = tcp://192.168.1.1:61616
plugin.zeromq.keepalive = 1 # default is 5, time in seconds
plugin.zeromq.curve.middleware_public_key = /etc/mcollective/middleware.public
plugin.zeromq.curve.public_key = /etc/mcollective/this_actor.public
plugin.zeromq.curve.private_key = /etc/mcollective/this_actor.private
```

Then start the middleware from `scripts/mc0d.rb` on the middleware\_host

Authentication is via Curve and on by default.  To disable this you have to
use the option `plugin.zeromq.curve.enabled`

```
# Not recommended, but for a quick demo possibly forgivable
plugin.zeromq.curve.enabled = false
```

# TODO

Find out if there's a better way to store/manage the curve keys.  Currently we
just keep them in a file as the zeromq library uses Z85 printable text.
http://api.zeromq.org/4-0:zmq-z85-encode

Verify curve keys more strongly.  Currently the only verification is that the
middleware matches its pre-shared public key.  Hopefully there's a mechanism
that more closely resembles an issuing certificate authority with a revocation
feature.
