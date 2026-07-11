// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
Accumulates publish round-trip latency samples for a single QoS level.
QoS 0 has no round-trip and is never recorded here.
*/
class LatencyStats:
  /** Latency of the most recent recorded publish in milliseconds. */
  last-ms/int := 0
  /** Minimum recorded latency in milliseconds. 0 if no samples yet. */
  min-ms/int := 0
  /** Maximum recorded latency in milliseconds. */
  max-ms/int := 0
  /** Number of samples recorded. */
  count/int := 0

  total-ms_/int := 0
  min-raw_/int := int.MAX  // int.MAX sentinel until first sample

  /** Records a latency sample. */
  record ms/int -> none:
    last-ms = ms
    if ms < min-raw_:
      min-raw_ = ms
      min-ms   = ms
    if ms > max-ms: max-ms = ms
    total-ms_ += ms
    count++

  /** Average latency in milliseconds. 0 if no samples recorded. */
  avg-ms -> int:
    return count > 0 ? total-ms_ / count : 0

  /** Writes all latency fields into [map] using the given [prefix]. */
  add-to-map map/Map prefix/string -> none:
    map["$(prefix)_last_ms"] = last-ms
    map["$(prefix)_min_ms"]  = min-ms
    map["$(prefix)_max_ms"]  = max-ms
    map["$(prefix)_avg_ms"]  = avg-ms
    map["$(prefix)_count"]   = count

/**
Runtime statistics for an MQTT client session.
Counters accumulate since boot. Timing values use the monotonic clock.
*/
class ClientMetrics:
  /** Total messages successfully published. QoS 0 counted on write; QoS 1/2 counted on final ACK. */
  messages-published/int := 0
  /** Total incoming messages dispatched to a subscription callback or on-message handler. */
  messages-received/int := 0
  /** Total reconnection attempts across all reconnect loops since boot. */
  reconnect-attempts/int := 0
  /** Messages published by the observability layer (log records and metric snapshots). */
  telemetry-published/int := 0

  /** Round-trip latency stats for QoS 1 publishes. */
  latency-qos1/LatencyStats := LatencyStats
  /** Round-trip latency stats for QoS 2 publishes. */
  latency-qos2/LatencyStats := LatencyStats

  // Monotonic µs timestamps — immune to NTP jumps that would corrupt duration math.
  started-us_/int := Time.monotonic-us   // set at ClientMetrics construction, i.e. when Client is created
  connected-at-us_/int? := null
  total-connected-us_/int := 0

  /** Records a successful QoS 1 or 2 publish round-trip and increments messages-published. */
  record-publish-latency ms/int --qos/int -> none:
    messages-published++
    if qos == 1: latency-qos1.record ms
    else:        latency-qos2.record ms

  /** Seconds since this client was created. */
  client-uptime-s -> int:
    return (Time.monotonic-us - started-us_) / 1_000_000

  /** Seconds spent connected in the current session. 0 if not currently connected. */
  connected-duration-s -> int:
    t := connected-at-us_
    return t ? (Time.monotonic-us - t) / 1_000_000 : 0

  /** Cumulative seconds spent connected since boot, including the current session. */
  total-connected-s -> int:
    base := total-connected-us_ / 1_000_000
    t := connected-at-us_
    return t ? base + (Time.monotonic-us - t) / 1_000_000 : base

  /**
  Returns a JSON-serializable snapshot of all metrics.
  Pass the MQTT client-id as [client-id].
  Device-specific fields such as wifi_signal are not included; add them to the returned map before publishing.
  */
  to-map client-id/string -> Map:
    result := {
      "timestamp_us":        Time.now.ns-since-epoch / 1_000,
      "client_id":           client-id,
      "messages_published":  messages-published - telemetry-published,
      "telemetry_published": telemetry-published,
      "messages_received":   messages-received,
      "reconnect_attempts":  reconnect-attempts,
      "connected_duration_s": connected-duration-s,
      "total_connected_s":   total-connected-s,
      "client_uptime_s":     client-uptime-s,
      "device_uptime_s":     Time.monotonic-us / 1_000_000,
    }
    latency-qos1.add-to-map result "publish_latency_qos1"
    latency-qos2.add-to-map result "publish_latency_qos2"
    return result

  on-connect_ -> none:
    connected-at-us_ = Time.monotonic-us

  on-disconnect_ -> none:
    t := connected-at-us_
    if t: total-connected-us_ += Time.monotonic-us - t
    connected-at-us_ = null
