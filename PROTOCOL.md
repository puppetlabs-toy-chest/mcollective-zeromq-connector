# ZeroMQ MCollective protocol, version 0.2

This is a DRAFT of the protocol for ZeroMQ MCollective protocol 0.3.  It'll
probably move as it's implemented.

Here we describe a simple protocol that the zeromq connector and custom
middleware will use when communicating.

We use a little of the RFC terminilogy here to describe the intended use, but
not consistently.  I SHOULD fix that.  Sorry.

# Basic topology

From the connector's perspective, it connects a zeromq DEALER socket to the
middleware (a ROUTER).  We use a response TTL to ask that the middleware to
send a PING/PONG pair if it hasn't seen traffic from the connector in a while,
which as a side-effect should keep the connection alive.

We build upon ZMTP 3.0 semantics as defined here
http://rfc.zeromq.org/spec:23/ZMTP and provided by version 4.0 of the libzmq
library http://api.zeromq.org/4-0:_start

# Encryption

The middleware and connector SHALL support the CURVE protocol as outlined in
http://rfc.zeromq.org/spec:25.

# Message format

The general message format will be that of multi-part message frame.  We
choose to use simple strings for the message parts for interoperbility.

## Message structure

The general format of a request frame will be;

    [ VERB KEY1 VAL1 "" POSITIONAL ]

Which is to say a command verb followed by 0 or more key value 'header' pairs,
optionally followed by the empty string and any positional parameters.

## Reserved Headers

We reserve all headers apart from those prefixed with "X-".  The defined global
header for this is:

### ID

A unique id for the command.  If supplied the broker SHALL reply with an OK or
ERROR response including the value of this token.  It is assumed the client
will use a unique identifier for each request for verification of successful
command submission, but this is not required.

Example:

    [ 'NOOP', 'ID', '1234' ]
    [ 'OK', 'ID', '1234 '] | [ 'ERROR', 'ID', '1234' ]

# General message flow

A client will send a request and expect nothing back if nothing exceptional
occured.  In an exceptional case the middleware should send a frame with the
verb ERROR.

# Messages originated by either end

## NOOP

    [ 'NOOP' ]

An empty message used for heartbeating.

# Message originated by the connector (client)

In the following sections the first message is the frame to send, represented
as a simple array.  The second line is what the middleware MAY send back.
The | is used for alternation.

It's hoped the semantics of the verbs are self-evident, so this draft skips
over fully defining everything.

## CONNECT

    [ 'CONNECT', 'VERSION', '0.1', 'TTL', '1000' ]

All values after the initial CONNECT verb are to be intepreted as a dictionary
of connection parameters in no specific order expressed as a list of k,v,k,v.
The parameters have the following semantics:

### VERSION key

The version of this protocol in use.  It may confer other semantics onto how
to intepret messages.

### TTL key

A value in milliseconds for (a) how often to expect to recieve a command from
this client (b) how often the middleware should consider sending a NOOP.

If the client isn't heard from in this time the middleware may consider the
client absent.

## DISCONNECT

    [ 'DISCONNECT' ]

## SUB

    [ 'SUB', '', 'topic1', 'topic2' ]

## UNSUB

    [ 'UNSUB', '', 'topic1', 'topic2' ]

## PUT

    [ 'PUT', 'TOPIC', 'topic1', '', body ]

Submits a message to all subscribers of the named 'TOPIC'.

# Messages originating from the middleware

## MESSAGE

    [ 'MESSAGE', 'TOPIC', topic, '', body ]

## ERROR

    [ 'ERROR', 'MESSAGE', DESCRIPTION ]

## OK

    [ 'OK', 'ID', identity ]

