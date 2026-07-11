// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
MQTT 5.0 Control Packet Types.
*/
PACKET-TYPE-CONNECT     ::= 1
PACKET-TYPE-CONNACK     ::= 2
PACKET-TYPE-PUBLISH     ::= 3
PACKET-TYPE-PUBACK      ::= 4
PACKET-TYPE-PUBREC      ::= 5
PACKET-TYPE-PUBREL      ::= 6
PACKET-TYPE-PUBCOMP     ::= 7
PACKET-TYPE-SUBSCRIBE   ::= 8
PACKET-TYPE-SUBACK      ::= 9
PACKET-TYPE-UNSUBSCRIBE ::= 10
PACKET-TYPE-UNSUBACK    ::= 11
PACKET-TYPE-PINGREQ     ::= 12
PACKET-TYPE-PINGRESP    ::= 13
PACKET-TYPE-DISCONNECT  ::= 14
PACKET-TYPE-AUTH        ::= 15

/**
MQTT 5.0 Property Identifiers.
*/
/** Payload Format Indicator. */
PROPERTY-IDENTIFIER-PAYLOAD-FORMAT-INDICATOR          ::= 0x01
/** Message Expiry Interval. */
PROPERTY-IDENTIFIER-MESSAGE-EXPIRY-INTERVAL           ::= 0x02
/** Content Type. */
PROPERTY-IDENTIFIER-CONTENT-TYPE                      ::= 0x03
/** Response Topic. */
PROPERTY-IDENTIFIER-RESPONSE-TOPIC                    ::= 0x08
/** Correlation Data. */
PROPERTY-IDENTIFIER-CORRELATION-DATA                  ::= 0x09
/** Subscription Identifier. */
PROPERTY-IDENTIFIER-SUBSCRIPTION-IDENTIFIER           ::= 0x0B
/** Session Expiry Interval. */
PROPERTY-IDENTIFIER-SESSION-EXPIRY-INTERVAL           ::= 0x11
/** Assigned Client Identifier. */
PROPERTY-IDENTIFIER-ASSIGNED-CLIENT-IDENTIFIER        ::= 0x12
/** Server Keep Alive. */
PROPERTY-IDENTIFIER-SERVER-KEEP-ALIVE                 ::= 0x13
/** Authentication Method. */
PROPERTY-IDENTIFIER-AUTHENTICATION-METHOD             ::= 0x15
/** Authentication Data. */
PROPERTY-IDENTIFIER-AUTHENTICATION-DATA               ::= 0x16
/** Request Problem Information. */
PROPERTY-IDENTIFIER-REQUEST-PROBLEM-INFORMATION       ::= 0x17
/** Will Delay Interval. */
PROPERTY-IDENTIFIER-WILL-DELAY-INTERVAL               ::= 0x18
/** Request Response Information. */
PROPERTY-IDENTIFIER-REQUEST-RESPONSE-INFORMATION       ::= 0x19
/** Response Information. */
PROPERTY-IDENTIFIER-RESPONSE-INFORMATION              ::= 0x1A
/** Server Reference. */
PROPERTY-IDENTIFIER-SERVER-REFERENCE                  ::= 0x1C
/** Reason String. */
PROPERTY-IDENTIFIER-REASON-STRING                     ::= 0x1F
/** Receive Maximum. */
PROPERTY-IDENTIFIER-RECEIVE-MAXIMUM                   ::= 0x21
/** Topic Alias Maximum. */
PROPERTY-IDENTIFIER-TOPIC-ALIAS-MAXIMUM               ::= 0x22
/** Topic Alias. */
PROPERTY-IDENTIFIER-TOPIC-ALIAS                       ::= 0x23
/** Maximum QoS. */
PROPERTY-IDENTIFIER-MAXIMUM-QOS                       ::= 0x24
/** Retain Available. */
PROPERTY-IDENTIFIER-RETAIN-AVAILABLE                  ::= 0x25
/** User Property. */
PROPERTY-IDENTIFIER-USER-PROPERTY                     ::= 0x26
/** Maximum Packet Size. */
PROPERTY-IDENTIFIER-MAXIMUM-PACKET-SIZE               ::= 0x27
/** Wildcard Subscription Available. */
PROPERTY-IDENTIFIER-WILDCARD-SUBSCRIPTION-AVAILABLE   ::= 0x28
/** Subscription Identifier Available. */
PROPERTY-IDENTIFIER-SUBSCRIPTION-IDENTIFIER-AVAILABLE ::= 0x29
/** Shared Subscription Available. */
PROPERTY-IDENTIFIER-SHARED-SUBSCRIPTION-AVAILABLE     ::= 0x2A
