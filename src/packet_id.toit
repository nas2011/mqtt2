// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import monitor

/**
Manager for MQTT Packet Identifiers (1-65535).
This class is thread-safe.
*/
class PacketIdentifierManager:
  next-id_/int := 1
  in-use_/Set := {}
  mutex_/monitor.Mutex := monitor.Mutex

  /**
  Allocates a new unique Packet Identifier.
  Throws an exception if no identifiers are available.
  */
  allocate -> int:
    return mutex_.do:
      start-id := next-id_
      while in-use_.contains next-id_:
        next-id_++
        if next-id_ > 65535: next-id_ = 1
        if next-id_ == start-id: throw "NO_AVAILABLE_PACKET_IDENTIFIERS"
      
      id := next-id_
      in-use_.add id
      
      next-id_++
      if next-id_ > 65535: next-id_ = 1
      id

  /**
  Releases a Packet Identifier so it can be reused.
  */
  release id/int -> none:
    mutex_.do:
      in-use_.remove id

  /**
  Clears all allocated identifiers.
  */
  clear -> none:
    mutex_.do:
      in-use_.clear
      next-id_ = 1
