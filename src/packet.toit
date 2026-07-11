// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import io
import .constants
import .properties
import .data show *
import .vbi as vbi

// Wraps an io.Reader and permits reads only up to remaining_ bytes.
// Prevents a decode_ method from consuming bytes belonging to the next packet.
class BoundedReader_ extends io.Reader:
  reader_/io.Reader
  remaining_/int := 0

  constructor .reader_ remaining/int:
    remaining_ = remaining

  read_ -> ByteArray?:
    if remaining_ == 0: return null
    data := reader_.read --max-size=remaining_
    if data != null: remaining_ -= data.size
    return data

/**
Base class for all MQTT 5.0 Control Packets.
*/
abstract class Packet:
  type/int
  flags/int

  constructor .type .flags=0:

  /** Writes the variable header and payload body to the [writer]. */
  abstract write-body writer/io.Writer -> none

  /**
  Decodes an MQTT Control Packet from the [reader].
  */
  static decode reader/io.Reader -> Packet:
    first-byte := reader.read-byte
    type := first-byte >> 4
    flags := first-byte & 0x0F
    remaining-length := vbi.decode reader

    packet-reader := BoundedReader_ reader remaining-length
    packet-reader.buffer-all

    if type == PACKET-TYPE-CONNECT:     return ConnectPacket.decode_ flags packet-reader
    if type == PACKET-TYPE-CONNACK:     return ConnackPacket.decode_ flags packet-reader
    if type == PACKET-TYPE-PUBLISH:     return PublishPacket.decode_ flags packet-reader
    if type == PACKET-TYPE-PUBACK:      return decode-ack_ type flags packet-reader :: |id rc p| PubackPacket id --reason-code=rc --properties=p
    if type == PACKET-TYPE-PUBREC:      return decode-ack_ type flags packet-reader :: |id rc p| PubrecPacket id --reason-code=rc --properties=p
    if type == PACKET-TYPE-PUBREL:      return decode-ack_ type flags packet-reader :: |id rc p| PubrelPacket id --reason-code=rc --properties=p
    if type == PACKET-TYPE-PUBCOMP:     return decode-ack_ type flags packet-reader :: |id rc p| PubcompPacket id --reason-code=rc --properties=p
    if type == PACKET-TYPE-SUBSCRIBE:   return SubscribePacket.decode_ flags packet-reader
    if type == PACKET-TYPE-SUBACK:      return decode-list-ack_ type flags packet-reader :: |id p rcs| SubackPacket id --properties=p --reason-codes=rcs
    if type == PACKET-TYPE-UNSUBSCRIBE: return UnsubscribePacket.decode_ flags packet-reader
    if type == PACKET-TYPE-UNSUBACK:    return decode-list-ack_ type flags packet-reader :: |id p rcs| UnsubackPacket id --properties=p --reason-codes=rcs
    if type == PACKET-TYPE-PINGREQ:     return PingreqPacket
    if type == PACKET-TYPE-PINGRESP:    return PingrespPacket
    if type == PACKET-TYPE-DISCONNECT:  return decode-ack_ type flags packet-reader :: |id rc p| DisconnectPacket rc --properties=p
    if type == PACKET-TYPE-AUTH:        return decode-ack_ type flags packet-reader :: |id rc p| AuthPacket rc --properties=p
    
    throw "UNKNOWN_PACKET_TYPE: $type"

  static decode-ack_ type/int flags/int reader/io.Reader factory/Lambda -> Packet:
    has-id := not (type == PACKET-TYPE-DISCONNECT or type == PACKET-TYPE-AUTH)
    id := has-id ? reader.big-endian.read-uint16 : 0
    rc := reader.buffered-size > 0 ? reader.read-byte : 0
    props := reader.buffered-size > 0 ? Properties.decode reader : Properties
    return factory.call id rc props

  static decode-list-ack_ type/int flags/int reader/io.Reader factory/Lambda -> Packet:
    id := reader.big-endian.read-uint16
    props := Properties.decode reader
    rcs := []
    while reader.buffered-size > 0: rcs.add reader.read-byte
    return factory.call id props rcs

/**
An MQTT Last Will and Testament message sent by the broker if the client disconnects ungracefully.
*/
class Will:
  topic/string
  payload/ByteArray
  qos/int
  retain/bool
  properties/Properties

  constructor .topic .payload
      --.qos/int=0
      --.retain/bool=false
      --.properties/Properties=Properties:
    validate-mqtt-string topic

/**
MQTT CONNECT Packet.
*/
class ConnectPacket extends Packet:
  protocol-name/string := "MQTT"
  protocol-version/int := 5
  clean-start/bool := true
  keep-alive/int := 60
  properties/Properties := Properties
  client-id/string := ""
  will/Will? := null
  username/string? := null
  password/string? := null

  constructor
      --.client-id/string=""
      --.clean-start/bool=true
      --.keep-alive/int=60
      --.username/string?=null
      --.password/string?=null
      --.properties/Properties=Properties
      --.will/Will?=null:
    super PACKET-TYPE-CONNECT

  write-body writer/io.Writer:
    write-string writer protocol-name
    writer.write-byte protocol-version
    c-flags := 0
    if username != null: c-flags |= 0x80
    if password != null: c-flags |= 0x40
    if will:
      if will.retain: c-flags |= 0x20
      c-flags |= (will.qos << 3)
      c-flags |= 0x04
    if clean-start: c-flags |= 0x02
    writer.write-byte c-flags
    writer.big-endian.write-uint16 keep-alive
    properties.write writer
    write-string writer client-id
    if will:
      will.properties.write writer
      write-string writer will.topic
      write-binary writer will.payload
    if username != null: write-string writer username
    if password != null: write-binary writer password.to-byte-array

  static decode_ flags/int reader/io.Reader -> ConnectPacket:
    p := ConnectPacket
    p.protocol-name = read-string reader
    p.protocol-version = reader.read-byte
    if p.protocol-version != 5: throw "UNSUPPORTED_PROTOCOL_VERSION"

    c-flags := reader.read-byte
    has-username := (c-flags & 0x80) != 0
    has-password := (c-flags & 0x40) != 0
    will-retain := (c-flags & 0x20) != 0
    will-qos := (c-flags >> 3) & 0x03
    has-will := (c-flags & 0x04) != 0
    p.clean-start = (c-flags & 0x02) != 0

    p.keep-alive = reader.big-endian.read-uint16
    p.properties = Properties.decode reader

    p.client-id = read-string reader
    if has-will:
      will-props := Properties.decode reader
      will-topic := read-string reader
      will-payload := read-binary reader
      p.will = Will will-topic will-payload
          --qos=will-qos
          --retain=will-retain
          --properties=will-props

    if has-username: p.username = read-string reader
    if has-password: p.password = (read-binary reader).to-string

    return p

/**
MQTT CONNACK Packet.
*/
class ConnackPacket extends Packet:
  session-present/bool := false
  reason-code/int := 0
  properties/Properties := Properties

  constructor .reason-code=0 --.session-present=false --.properties=Properties:
    super PACKET-TYPE-CONNACK

  write-body writer/io.Writer:
    writer.write-byte (session-present ? 1 : 0)
    writer.write-byte reason-code
    properties.write writer

  static decode_ flags/int reader/io.Reader -> ConnackPacket:
    session-present := (reader.read-byte) & 0x01 != 0
    reason-code := reader.read-byte
    props := Properties.decode reader
    return ConnackPacket reason-code --session-present=session-present --properties=props

/**
MQTT PUBLISH Packet.
*/
class PublishPacket extends Packet:
  topic-name/string := ""
  packet-id/int := 0
  properties/Properties := Properties
  payload/ByteArray := #[]

  constructor .topic-name .payload --qos/int=0 --retain/bool=false --dup/bool=false --.packet-id=0 --.properties=Properties:
    f := (dup ? 0x08 : 0) | (qos << 1) | (retain ? 0x01 : 0)
    super PACKET-TYPE-PUBLISH f

  qos -> int: return (flags >> 1) & 0x03
  dup -> bool: return (flags & 0x08) != 0
  retain -> bool: return (flags & 0x01) != 0

  write-body writer/io.Writer:
    write-string writer topic-name
    if qos > 0: writer.big-endian.write-uint16 packet-id
    properties.write writer
    writer.write payload

  static decode_ flags/int reader/io.Reader -> PublishPacket:
    topic := read-string reader
    qos := (flags >> 1) & 0x03
    id := 0
    if qos > 0: id = reader.big-endian.read-uint16
    props := Properties.decode reader
    payload := reader.read-bytes reader.buffered-size
    return PublishPacket topic payload
      --qos=qos
      --retain=(flags & 0x01 != 0)
      --dup=(flags & 0x08 != 0)
      --packet-id=id
      --properties=props

/**
Common base for packets with Packet Identifier, Reason Code and Properties.
Used by PUBACK, PUBREC, PUBREL, PUBCOMP, DISCONNECT (no ID), AUTH (no ID).
*/
abstract class AckPacket extends Packet:
  packet-id/int
  reason-code/int
  properties/Properties

  constructor type/int flags/int .packet-id .reason-code .properties:
    super type flags

  /** Returns true if this packet type carries a Packet Identifier field. */
  abstract has-packet-id -> bool

  write-body writer/io.Writer:
    if has-packet-id: writer.big-endian.write-uint16 packet-id
    if properties.size-no-prefix == 0 and reason-code == 0: return
    writer.write-byte reason-code
    properties.write writer

/** MQTT PUBACK Packet. Sent by the receiver to acknowledge a QoS 1 PUBLISH. */
class PubackPacket extends AckPacket:
  constructor packet-id/int --reason-code/int=0 --properties/Properties=Properties:
    super PACKET-TYPE-PUBACK 0 packet-id reason-code properties
  has-packet-id -> bool: return true

/** MQTT PUBREC Packet. First response in the QoS 2 handshake, acknowledging receipt. */
class PubrecPacket extends AckPacket:
  constructor packet-id/int --reason-code/int=0 --properties/Properties=Properties:
    super PACKET-TYPE-PUBREC 0 packet-id reason-code properties
  has-packet-id -> bool: return true

/** MQTT PUBREL Packet. Second step in the QoS 2 handshake, releasing the message for delivery. */
class PubrelPacket extends AckPacket:
  constructor packet-id/int --reason-code/int=0 --properties/Properties=Properties:
    super PACKET-TYPE-PUBREL 0x02 packet-id reason-code properties
  has-packet-id -> bool: return true

/** MQTT PUBCOMP Packet. Final step in the QoS 2 handshake, confirming delivery is complete. */
class PubcompPacket extends AckPacket:
  constructor packet-id/int --reason-code/int=0 --properties/Properties=Properties:
    super PACKET-TYPE-PUBCOMP 0 packet-id reason-code properties
  has-packet-id -> bool: return true

/**
A single subscription request with its topic filter and MQTT 5.0 subscription options.
*/
class SubscriptionRequest:
  topic-filter/string
  qos/int
  omit-local/bool
  retain-as-published/bool
  retain-handling/int

  constructor .topic-filter
      --.qos/int=0
      --.omit-local/bool=false
      --.retain-as-published/bool=false
      --.retain-handling/int=0:

  /** Returns the wire-format options byte with all subscription option flags packed. */
  options-byte -> int:
    return qos | (omit-local ? 0x04 : 0) | (retain-as-published ? 0x08 : 0) | (retain-handling << 4)

/**
MQTT SUBSCRIBE Packet.
*/
class SubscribePacket extends Packet:
  packet-id/int := 0
  properties/Properties := Properties
  subscriptions/List := [] // List of SubscriptionRequest

  constructor .packet-id --.properties=Properties:
    super PACKET-TYPE-SUBSCRIBE 0x02

  write-body writer/io.Writer:
    writer.big-endian.write-uint16 packet-id
    properties.write writer
    subscriptions.do: |sub/SubscriptionRequest|
      write-string writer sub.topic-filter
      writer.write-byte sub.options-byte

  static decode_ flags/int reader/io.Reader -> SubscribePacket:
    id := reader.big-endian.read-uint16
    props := Properties.decode reader
    p := SubscribePacket id --properties=props
    while reader.buffered-size > 0:
      topic := read-string reader
      options := reader.read-byte
      p.subscriptions.add
          SubscriptionRequest topic
              --qos=(options & 0x03)
              --omit-local=((options & 0x04) != 0)
              --retain-as-published=((options & 0x08) != 0)
              --retain-handling=((options >> 4) & 0x03)
    return p

/**
MQTT SUBACK Packet.
*/
class SubackPacket extends Packet:
  packet-id/int := 0
  properties/Properties := Properties
  reason-codes/List := []

  constructor .packet-id --.properties=Properties --.reason-codes=[]:
    super PACKET-TYPE-SUBACK 0

  write-body writer/io.Writer:
    writer.big-endian.write-uint16 packet-id
    properties.write writer
    reason-codes.do: |rc| writer.write-byte rc

/**
MQTT UNSUBSCRIBE Packet.
*/
class UnsubscribePacket extends Packet:
  packet-id/int := 0
  properties/Properties := Properties
  topic-filters/List := []

  constructor .packet-id --.properties=Properties:
    super PACKET-TYPE-UNSUBSCRIBE 0x02

  write-body writer/io.Writer:
    writer.big-endian.write-uint16 packet-id
    properties.write writer
    topic-filters.do: |tf| write-string writer tf

  static decode_ flags/int reader/io.Reader -> UnsubscribePacket:
    id := reader.big-endian.read-uint16
    props := Properties.decode reader
    p := UnsubscribePacket id --properties=props
    while reader.buffered-size > 0:
      p.topic-filters.add (read-string reader)
    return p

/**
MQTT UNSUBACK Packet.
*/
class UnsubackPacket extends Packet:
  packet-id/int := 0
  properties/Properties := Properties
  reason-codes/List := []

  constructor .packet-id --.properties=Properties --.reason-codes=[]:
    super PACKET-TYPE-UNSUBACK 0

  write-body writer/io.Writer:
    writer.big-endian.write-uint16 packet-id
    properties.write writer
    reason-codes.do: |rc| writer.write-byte rc

/**
Abstract base for packets with no variable header or payload (PINGREQ, PINGRESP).
*/
abstract class NoBodyPacket extends Packet:
  constructor type/int: super type
  write-body writer/io.Writer:

/**
MQTT PINGREQ Packet.
*/
class PingreqPacket extends NoBodyPacket:
  constructor: super PACKET-TYPE-PINGREQ

/**
MQTT PINGRESP Packet.
*/
class PingrespPacket extends NoBodyPacket:
  constructor: super PACKET-TYPE-PINGRESP

/**
MQTT DISCONNECT Packet.
*/
class DisconnectPacket extends AckPacket:
  constructor reason-code/int=0 --properties/Properties=Properties:
    super PACKET-TYPE-DISCONNECT 0 0 reason-code properties
  has-packet-id -> bool: return false

/**
MQTT AUTH Packet.
*/
class AuthPacket extends AckPacket:
  constructor reason-code/int=0 --properties/Properties=Properties:
    super PACKET-TYPE-AUTH 0 0 reason-code properties
  has-packet-id -> bool: return false
