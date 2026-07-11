// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .constants
import .data show *
import .vbi as vbi
import io

/**
MQTT 5.0 Property.
*/
abstract class Property:
  identifier/int
  constructor .identifier:

  abstract write writer/io.Writer -> none
  abstract size -> int

/**
A property with a single byte value.
*/
class ByteProperty extends Property:
  value/int
  constructor identifier .value:
    super identifier

  write writer/io.Writer:
    vbi.encode writer identifier
    writer.write-byte value

  size -> int:
    return (vbi.size identifier) + 1

/**
A property with a two-byte integer value.
*/
class TwoByteIntProperty extends Property:
  value/int
  constructor identifier .value:
    super identifier

  write writer/io.Writer:
    vbi.encode writer identifier
    writer.big-endian.write-uint16 value

  size -> int:
    return (vbi.size identifier) + 2

/**
A property with a four-byte integer value.
*/
class FourByteIntProperty extends Property:
  value/int
  constructor identifier .value:
    super identifier

  write writer/io.Writer:
    vbi.encode writer identifier
    writer.big-endian.write-uint32 value

  size -> int:
    return (vbi.size identifier) + 4

/**
A property with a variable byte integer value.
*/
class VbiProperty extends Property:
  value/int
  constructor identifier .value:
    super identifier

  write writer/io.Writer:
    vbi.encode writer identifier
    vbi.encode writer value

  size -> int:
    return (vbi.size identifier) + (vbi.size value)

/**
A property with a UTF-8 encoded string value.
*/
class Utf8Property extends Property:
  value/string
  constructor identifier .value:
    super identifier

  write writer/io.Writer:
    vbi.encode writer identifier
    write-string writer value

  size -> int:
    return (vbi.size identifier) + 2 + value.size

/**
A property with a binary data value.
*/
class BinaryProperty extends Property:
  value/ByteArray
  constructor identifier .value:
    super identifier

  write writer/io.Writer:
    vbi.encode writer identifier
    write-binary writer value

  size -> int:
    return (vbi.size identifier) + 2 + value.size

/**
A property with a UTF-8 string pair value.
*/
class Utf8PairProperty extends Property:
  key/string
  value/string
  constructor identifier .key .value:
    super identifier

  write writer/io.Writer:
    vbi.encode writer identifier
    write-string writer key
    write-string writer value

  size -> int:
    return (vbi.size identifier) + 4 + key.size + value.size

/**
A collection of MQTT 5.0 properties.
Supports lazy decoding of properties received from the network to save memory.
*/
class Properties:
  bytes_/ByteArray := #[]
  buffer_/io.Buffer? := null
  decoded_/Map? := null  // int -> List<any>; null until first get or explicit populate

  constructor:

  constructor.internal_ .bytes_:

  /**
  Returns a new [Properties] with the same encoded bytes as this one.
  */
  copy -> Properties:
    return Properties.internal_ bytes-data_.copy

  /**
  Adds a [property] to the collection.
  */
  add property/Property:
    decoded_ = null  // invalidate cache on mutation
    if not buffer_:
      buffer_ = io.Buffer
      if bytes_.size > 0:
        buffer_.write bytes_
        bytes_ = #[]
    property.write buffer_

  // Materializes buffer_ into bytes_ if needed and returns the encoded bytes.
  bytes-data_ -> ByteArray:
    if buffer_:
      // .copy releases the 64-byte io.Buffer backing array immediately.
      bytes_ = buffer_.bytes.copy
      buffer_ = null
    return bytes_

  /** Adds a byte property with the given [identifier] and [value]. */
  add-uint8 identifier/int value/int:
    add (ByteProperty identifier value)

  /** Adds a two-byte integer property with the given [identifier] and [value]. */
  add-uint16 identifier/int value/int:
    add (TwoByteIntProperty identifier value)

  /** Adds a four-byte integer property with the given [identifier] and [value]. */
  add-uint32 identifier/int value/int:
    add (FourByteIntProperty identifier value)

  /** Adds a UTF-8 string property with the given [identifier] and [value]. */
  add-string identifier/int value/string:
    add (Utf8Property identifier value)

  /** Adds a binary data property with the given [identifier] and [value]. */
  add-binary identifier/int value/ByteArray:
    add (BinaryProperty identifier value)

  /**
  Adds a user property key-value pair.
  Multiple user properties with the same [key] are allowed per the MQTT 5.0 spec.
  */
  add-user-property key/string value/string:
    add (Utf8PairProperty PROPERTY-IDENTIFIER-USER-PROPERTY key value)

  /**
  Writes the properties to the [writer].
  Includes the property length VBI.
  */
  write writer/io.Writer:
    b := bytes-data_
    vbi.encode writer b.size
    writer.write b

  /**
  The total size of the properties, including the property length VBI.
  */
  size -> int:
    b := bytes-data_
    return (vbi.size b.size) + b.size

  /**
  The size of the properties, excluding the property length VBI.
  */
  size-no-prefix -> int:
    return bytes-data_.size

  /**
  Returns the value of the first property with the given [identifier], or null if not found.
  For [Utf8PairProperty], returns the property object itself.
  */
  get identifier/int -> any:
    b := bytes-data_
    if b.size == 0: return null
    if decoded_ == null: populate-decoded_ b
    list/List? := decoded_.get identifier
    if not list or list.is-empty: return null
    return list[0]

  /** Returns the byte value of the first property with the given [identifier], or null if not found. */
  get-uint8 identifier/int -> int?:
    val := get identifier
    return val is int ? val : null

  /** Returns the two-byte integer value of the first property with the given [identifier], or null if not found. */
  get-uint16 identifier/int -> int?:
    val := get identifier
    return val is int ? val : null

  /** Returns the four-byte integer value of the first property with the given [identifier], or null if not found. */
  get-uint32 identifier/int -> int?:
    val := get identifier
    return val is int ? val : null

  /** Returns the UTF-8 string value of the first property with the given [identifier], or null if not found. */
  get-string identifier/int -> string?:
    val := get identifier
    return val is string ? val : null

  /** Returns the binary data value of the first property with the given [identifier], or null if not found. */
  get-binary identifier/int -> ByteArray?:
    val := get identifier
    return val is ByteArray ? val : null

  /**
  Returns the first user property value for the given [key], or null if not found.
  */
  get-user-property key/string -> string?:
    b := bytes-data_
    if b.size == 0: return null
    if decoded_ == null: populate-decoded_ b
    list/List? := decoded_.get PROPERTY-IDENTIFIER-USER-PROPERTY
    if not list: return null
    list.do: |pair/Utf8PairProperty|
      if pair.key == key: return pair.value
    return null

  /**
  Returns all user properties as a Map of string to List of strings.
  Multiple user properties with the same key are supported.
  */
  get-user-properties -> Map:
    result := {:}
    b := bytes-data_
    if b.size == 0: return result
    if decoded_ == null: populate-decoded_ b
    list/List? := decoded_.get PROPERTY-IDENTIFIER-USER-PROPERTY
    if not list: return result
    list.do: |pair/Utf8PairProperty|
      vals := result.get pair.key --if-absent=(: [])
      vals.add pair.value
      result[pair.key] = vals
    return result

  /**
  Returns the reason string if present.
  */
  reason-string -> string?:
    return get-string PROPERTY-IDENTIFIER-REASON-STRING

  /**
  Returns a list of all properties with the given [identifier].
  */
  get-all identifier/int -> List:
    b := bytes-data_
    if b.size == 0: return []
    if decoded_ == null: populate-decoded_ b
    list/List? := decoded_.get identifier
    return list != null ? list : []

  /**
  Decodes properties from the [reader].
  Eagerly decodes all property bytes into an internal Map so every subsequent
  lookup is O(1) with no Reader allocation.
  */
  static decode reader/io.Reader -> Properties:
    len := vbi.decode reader
    if len == 0: return Properties

    // .copy breaks the reference chain to the TCP receive buffer.
    // Without it, a slice keeps the entire incoming TCP segment alive.
    // This is critical for session.properties (CONNACK), which lives
    // for the entire connection lifetime.
    bytes := (reader.read-bytes len).copy
    p := Properties.internal_ bytes
    p.populate-decoded_ bytes  // eager at point of wire receipt
    return p

  // Decodes all wire bytes into the decoded_ map.
  populate-decoded_ bytes/ByteArray -> none:
    map := {:}
    reader := io.Reader bytes
    reader.buffer-all
    while reader.buffered-size > 0:
      id := vbi.decode reader
      val := decode-value_ reader (property-type id) id
      list/List? := map.get id
      if not list:
        list = []
        map[id] = list
      list.add val
    decoded_ = map

  /**
  Internal helper to decode a property value from the [reader] based on [prop_type].
  */
  static decode-value_ reader/io.Reader prop-type/int id/int -> any:
    if prop-type == PROPERTY-TYPE-BYTE:
      return reader.read-byte
    if prop-type == PROPERTY-TYPE-TWO-BYTE-INT:
      return reader.big-endian.read-uint16
    if prop-type == PROPERTY-TYPE-FOUR-BYTE-INT:
      return reader.big-endian.read-uint32
    if prop-type == PROPERTY-TYPE-VBI:
      return vbi.decode reader
    if prop-type == PROPERTY-TYPE-UTF8:
      return read-string reader
    if prop-type == PROPERTY-TYPE-BINARY:
      return read-binary reader
    if prop-type == PROPERTY-TYPE-UTF8-PAIR:
      key := read-string reader
      val := read-string reader
      return Utf8PairProperty id key val
    throw "UNKNOWN_PROPERTY_TYPE: $prop-type"


/** Property value types. */
PROPERTY-TYPE-BYTE          ::= 0
PROPERTY-TYPE-TWO-BYTE-INT  ::= 1
PROPERTY-TYPE-FOUR-BYTE-INT ::= 2
PROPERTY-TYPE-VBI           ::= 3
PROPERTY-TYPE-UTF8          ::= 4
PROPERTY-TYPE-BINARY        ::= 5
PROPERTY-TYPE-UTF8-PAIR     ::= 6

/**
Returns the type of the property with the given [id].
*/
property-type id/int -> int:
  if id == PROPERTY-IDENTIFIER-PAYLOAD-FORMAT-INDICATOR:           return PROPERTY-TYPE-BYTE
  if id == PROPERTY-IDENTIFIER-MESSAGE-EXPIRY-INTERVAL:            return PROPERTY-TYPE-FOUR-BYTE-INT
  if id == PROPERTY-IDENTIFIER-CONTENT-TYPE:                       return PROPERTY-TYPE-UTF8
  if id == PROPERTY-IDENTIFIER-RESPONSE-TOPIC:                     return PROPERTY-TYPE-UTF8
  if id == PROPERTY-IDENTIFIER-CORRELATION-DATA:                   return PROPERTY-TYPE-BINARY
  if id == PROPERTY-IDENTIFIER-SUBSCRIPTION-IDENTIFIER:            return PROPERTY-TYPE-VBI
  if id == PROPERTY-IDENTIFIER-SESSION-EXPIRY-INTERVAL:            return PROPERTY-TYPE-FOUR-BYTE-INT
  if id == PROPERTY-IDENTIFIER-ASSIGNED-CLIENT-IDENTIFIER:         return PROPERTY-TYPE-UTF8
  if id == PROPERTY-IDENTIFIER-SERVER-KEEP-ALIVE:                  return PROPERTY-TYPE-TWO-BYTE-INT
  if id == PROPERTY-IDENTIFIER-AUTHENTICATION-METHOD:              return PROPERTY-TYPE-UTF8
  if id == PROPERTY-IDENTIFIER-AUTHENTICATION-DATA:                return PROPERTY-TYPE-BINARY
  if id == PROPERTY-IDENTIFIER-REQUEST-PROBLEM-INFORMATION:        return PROPERTY-TYPE-BYTE
  if id == PROPERTY-IDENTIFIER-WILL-DELAY-INTERVAL:                return PROPERTY-TYPE-FOUR-BYTE-INT
  if id == PROPERTY-IDENTIFIER-REQUEST-RESPONSE-INFORMATION:       return PROPERTY-TYPE-BYTE
  if id == PROPERTY-IDENTIFIER-RESPONSE-INFORMATION:               return PROPERTY-TYPE-UTF8
  if id == PROPERTY-IDENTIFIER-SERVER-REFERENCE:                   return PROPERTY-TYPE-UTF8
  if id == PROPERTY-IDENTIFIER-REASON-STRING:                      return PROPERTY-TYPE-UTF8
  if id == PROPERTY-IDENTIFIER-RECEIVE-MAXIMUM:                    return PROPERTY-TYPE-TWO-BYTE-INT
  if id == PROPERTY-IDENTIFIER-TOPIC-ALIAS-MAXIMUM:                return PROPERTY-TYPE-TWO-BYTE-INT
  if id == PROPERTY-IDENTIFIER-TOPIC-ALIAS:                        return PROPERTY-TYPE-TWO-BYTE-INT
  if id == PROPERTY-IDENTIFIER-MAXIMUM-QOS:                        return PROPERTY-TYPE-BYTE
  if id == PROPERTY-IDENTIFIER-RETAIN-AVAILABLE:                   return PROPERTY-TYPE-BYTE
  if id == PROPERTY-IDENTIFIER-USER-PROPERTY:                      return PROPERTY-TYPE-UTF8-PAIR
  if id == PROPERTY-IDENTIFIER-MAXIMUM-PACKET-SIZE:                return PROPERTY-TYPE-FOUR-BYTE-INT
  if id == PROPERTY-IDENTIFIER-WILDCARD-SUBSCRIPTION-AVAILABLE:    return PROPERTY-TYPE-BYTE
  if id == PROPERTY-IDENTIFIER-SUBSCRIPTION-IDENTIFIER-AVAILABLE:  return PROPERTY-TYPE-BYTE
  if id == PROPERTY-IDENTIFIER-SHARED-SUBSCRIPTION-AVAILABLE:      return PROPERTY-TYPE-BYTE
  throw "INVALID_PROPERTY_IDENTIFIER: $id"

