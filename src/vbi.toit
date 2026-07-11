// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.


import io

/**
Variable Byte Integer (VBI) utilities for MQTT 5.0.

The Variable Byte Integer is used in MQTT 5.0 to represent various length and
  identifier fields. It uses 7 bits per byte for the value and the most
  significant bit as a continuation flag.

The maximum value of a VBI is 268,435,455 (0x0FFFFFFF).
*/

/**
Encodes the given $value as a Variable Byte Integer and writes it to the $writer.

The $value must be between 0 and 0x0FFFFFFF (268,435,455).

# Errors
Throws if $value is out of range.
*/
encode writer/io.Writer value/int -> none:
  if not 0 <= value <= 0x0FFF_FFFF: throw "INVALID_ARGUMENT"
  while true:
    byte := value % 128
    value /= 128
    if value > 0:
      writer.write-byte (byte | 0x80)
    else:
      writer.write-byte byte
      return

/**
Decodes a Variable Byte Integer from the given $reader.

Returns the decoded integer.

# Errors
Throws if the VBI is malformed (more than 4 bytes or multiplier exceeds max).
Throws UNEXPECTED-END-OF-READER if the reader ends before the VBI is complete.
*/
decode reader/io.Reader -> int:
  res := 0
  multiplier := 1
  while true:
    byte := reader.read-byte
    res += (byte & 0x7F) * multiplier
    if (byte & 0x80) == 0: return res
    multiplier *= 128
    if multiplier > 128 * 128 * 128: throw "MALFORMED_VBI"

/**
Calculates the number of bytes required to encode the given $value as a VBI.

The $value must be between 0 and 0x0FFFFFFF (268,435,455).

# Errors
Throws if $value is out of range.
*/
size value/int -> int:
  if not 0 <= value <= 0x0FFF_FFFF: throw "INVALID_ARGUMENT"
  if value < 128: return 1
  if value < 16384: return 2      // 128^2
  if value < 2097152: return 3    // 128^3
  return 4                        // 128^4
