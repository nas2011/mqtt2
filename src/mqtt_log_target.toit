// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import log show Target TRACE-LEVEL DEBUG-LEVEL INFO-LEVEL WARN-LEVEL
import encoding.json
import .client show Client

/**
A $Target that forwards structured log records to the MQTT broker on
  `telemetry/{client-id}/logs` at QoS 0, gated by [min-level].

Every record is also forwarded to [inner] (typically the default console
  target) so serial output is preserved regardless of connection state or
  [min-level] — only the MQTT publish is filtered.

Records are silently dropped from MQTT when the client is not connected, or
  when their level is below [min-level].
A recursion guard prevents the "publishing message" debug log emitted by
  $Client.publish from re-entering the target and causing a loop.
*/
class MqttLogTarget implements Target:
  client_/Client
  client-id_/string
  inner_/Target
  log-topic_/string
  min-level_/int
  // Prevents publish → log → publish recursion. Not a monitor: mutations are
  // safe because Toit only yields at explicit monitor/sleep calls, and we set
  // the flag before the only yield point (outgoing-channel_.send inside publish).
  in-log_/bool := false

  constructor .client_ .client-id_ .inner_
      --log-topic/string="telemetry/$client-id_/logs"
      --min-level/int=TRACE-LEVEL:
    log-topic_ = log-topic
    min-level_ = min-level

  log level/int message/string names/List? keys/List? values/List? -> none:
    inner_.log level message names keys values
    if level < min-level_ or in-log_ or not client_.is-connected: return
    in-log_ = true
    try:
      tags := {:}
      if keys: keys.size.repeat: | i | tags[keys[i]] = values[i]
      record := {
        "timestamp_us": Time.now.ns-since-epoch / 1_000,
        "client_id":    client-id_,
        "level":        level-name_ level,
        "message":      message,
        "tags":         tags,
      }
      catch:
        client_.publish log-topic_ (json.encode record)
        client_.metrics.telemetry-published++
    finally:
      in-log_ = false

  static level-name_ level/int -> string:
    if level <= DEBUG-LEVEL: return "DEBUG"
    if level <= INFO-LEVEL:  return "INFO"
    if level <= WARN-LEVEL:  return "WARN"
    return "ERROR"
