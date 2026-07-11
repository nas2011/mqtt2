// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import io

/**
Serialization helpers for MQTT 5.0 data types.
*/

/**
Validates that [value] is a legal MQTT UTF-8 string.

MQTT 5.0 forbids the null character (U+0000) and limits the encoded length to 65535 bytes.
Call this once at public API entry points; internal wire writes do not re-validate.

# Errors
Throws if the string contains a null character or exceeds 65535 bytes.
*/
validate-mqtt-string value/string -> none:
  if value.size > 0xFFFF: throw "STRING_TOO_LONG"
  value.size.repeat: | i |
    if (value.at --raw i) == 0: throw "INVALID_STRING_CONTENT"

/**
Encodes a UTF-8 string with a two-byte length prefix and writes it to the $writer.

Strings must be validated with $validate-mqtt-string before reaching the wire.
*/
write-string writer/io.Writer value/string -> none:
  writer.big-endian.write-uint16 value.size
  writer.write value

/**
Encodes binary data with a two-byte length prefix and writes it to the $writer.

The length of the data must be between 0 and 65535.

# Errors
Throws if the data length exceeds 65535.
*/
write-binary writer/io.Writer data/ByteArray -> none:
  if data.size > 0xFFFF: throw "DATA_TOO_LONG"
  
  writer.big-endian.write-uint16 data.size
  writer.write data

/**
Reads a UTF-8 string with a two-byte length prefix from the $reader.

# Errors
Throws if the reader ends before the length or the string content is fully read.
Throws if the string contains a null character (as per MQTT 5.0 spec).
*/
read-string reader/io.Reader -> string:
  len := reader.big-endian.read-uint16
  if len == 0: return ""
  
  bytes := reader.read-bytes len
  if (bytes.index-of 0) != -1: throw "INVALID_STRING_CONTENT"
  return bytes.to-string

/**
Reads binary data with a two-byte length prefix from the $reader.

# Errors
Throws if the reader ends before the length or the data content is fully read.
*/
read-binary reader/io.Reader -> ByteArray:
  len := reader.big-endian.read-uint16
  if len == 0: return ByteArray 0
  
  return reader.read-bytes len
