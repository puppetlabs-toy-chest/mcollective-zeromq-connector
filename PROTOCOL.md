# ZeroMQ MCollective protocol, version 0.1

This is a DRAFT of the protocol for ZeroMQ MCollective protocol 0.1.  It'll
probably move as it's implemented.

Here we describe a simple protocol that the zeromq connector and custom
middleware will use when communicating.

We use a little of the RFC terminilogy here to describe the intended use, but
not consistently.  I SHOULD fix that.  Sorry.

# Basic topology

From the connector's perspective, it connects a zeromq REQ socket to the
middleware.  REQ sockets have a FSM that assert the socket should always be
used for send/recv pairs.  We use a response TTL to ask that the middleware
always answer within a given number of milliseconds which we can use to
effectively ping/pong heartbeat the connections.

We build upon ZMTP 3.0 semantics as defined here
http://rfc.zeromq.org/spec:23/ZMTP and provided by version 4.0 of the libzmq
library http://api.zeromq.org/4-0:_start

# Encryption

The middleware and connector SHALL support the CURVE protocol as outlined in
http://rfc.zeromq.org/spec:25.

# Message format

The general message format will be that of multi-part message frame.  We
choose to use simple strings for the message parts for interoperbility.

# General message flow

A client will send request and expect a response within a given window
(indicated by the TTL field of the CONNECT frame).  The client SHOULD allow
for a slightly delayed message to allow for network latency.  The server SHALL
reply with one of the prescribed message types.

# Command verbs

In the following sections the first message is the frame to send, represented
as a simple array.  The second line is what the middleware should send back.
The | is used for alternation.

It's hoped the semantics of the verbs are self-evident, so this draft skips
over fully defining everything.

## CONNECT

    [ 'CONNECT', 'VERSION', '0.1', 'TTL', '1000' ]
    [ 'OK' ] | [ 'FAIL', REASON ]

All values after the initial CONNECT verb are to be intepreted as a dictionary
of connection parameters in no specific order expressed as a list of k,v,k,v.
The parameters have the following semantics:

### VERSION

The version of this protocol in use.  It may confer other semantics onto how
to intepret messages.

### TTL

A value in milliseconds for (a) how often to expect to recieve a command from
this client (b) how long the client is willing to wait for GET verbs to
complete (see GET/WAIT for more discussion)

## DISCONNECT

    [ 'DISCONNECT' ]
    [ 'OK' ]

## SUB

    [ 'SUB', 'topic1', 'topic2' ]
    [ 'OK' ] | [ 'FAIL', REASON ]

## UNSUB

    [ 'UNSUBSCRIBE', 'topic1' ]
    [ 'OK' ] | [ 'FAIL', REASON ]

## PUT

    [ 'PUT', TOPIC, REPLY_TO, BODY ]
    [ 'OK' ] | [ 'FAIL', REASON ]

Submits a message to all consumbers of the named TOPIC.  The REPLY_TO field is
required, but may be an empty frame ('') if no reply-to is appropriate.

## GET

    [ 'GET' ]
    [ 'OK', 'MESSAGE', TOPIC, REPLY_TO, BODY ] | [ 'OK', 'WAIT' ] | [ 'FAIL', REASON ]

In typical usage we expect to have one of two responses from the GET verb, (a)
within negotiated TTL, an [ 'OK', 'MESSAGE', ... ] response delivering a
message previously submitted with a PUT command, or (b) just within the TTL an
[ 'OK', 'WAIT' ] response indicating that you're still connected to the
middleware but it has nothing for you currently.

