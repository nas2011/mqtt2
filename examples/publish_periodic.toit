// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import net
import net.wifi
import log
import encoding.json as json
import ..src.mqtt2 show *

BROKER-HOST     ::= "your-host.com"
BROKER-PORT     ::= 1883
BROKER-USERNAME ::= "username"
BROKER-PASSWORD ::= "password"
CLIENT-ID       ::= "esp32-pub"

// Application topics
STATUS-TOPIC      ::= "device/$CLIENT-ID/status"
MEASUREMENT-TOPIC ::= "device/$CLIENT-ID/measurement"
RSSI-TOPIC        ::= "device/$CLIENT-ID/rssi"
CMD-TOPIC         ::= "device/$CLIENT-ID/cmd/+"

// Observability topics
METRICS-TOPIC     ::= "telemetry/$CLIENT-ID/metrics"
LOG-TOPIC         ::= "telemetry/$CLIENT-ID/logs"

MEASUREMENT-INTERVAL ::= Duration --m=5
RSSI-INTERVAL        ::= Duration --m=15
METRICS-INTERVAL     ::= Duration --m=5

main:
  network    := net.open
  wifi-client := wifi.open null

  // Broker publishes "offline" to STATUS-TOPIC if the device drops unexpectedly.
  will := Will STATUS-TOPIC "offline".to-byte-array --qos=1 --retain=true

  client := Client
  client.on-disconnected = :: print "Permanently disconnected."
  client.on-message      = :: |msg/Message|
    log.warn "unhandled message" --tags={"topic": msg.topic}

  log-target := MqttLogTarget client CLIENT-ID log.default.target_
      --log-topic=LOG-TOPIC

  client.connect
      (Options
          --client-id=CLIENT-ID
          --username=BROKER-USERNAME
          --password=BROKER-PASSWORD
          --keep-alive=60
          --will=will)
      --transport-provider=(:: SocketTransport.connect network BROKER-HOST BROKER-PORT)
      --reconnect-options=(ReconnectOptions --connect-timeout=(Duration --s=15))
      --log-target=log-target

  log.info "connected"
      --tags={"session-present": client.session.session-present,
              "alias-max":       client.session.topic-alias-maximum}

  // Announce presence; broker's retained "online" overrides the Will on reconnect.
  client.publish-string STATUS-TOPIC "online" --qos=1 --retain=true

  // Subscribe to command topic. Wildcard (+) matches any single-level command name.
  client.subscribe CMD-TOPIC :: |msg/Message|
    cmd := (msg.topic.split "/").last
    log.info "command received" --tags={"cmd": cmd}
    if cmd == "disconnect":
      client.disconnect

  measurement-timer := 0
  rssi-timer        := 0
  metrics-timer     := 0

  while true:
    // QoS 1 — structured JSON payload; expires after 10 min so stale readings don't persist.
    if measurement-timer <= 0:
      exception := catch:
        client.publish MEASUREMENT-TOPIC
            (json.encode {
              "uptime_s":    Time.monotonic-us / 1_000_000,
              "wifi_signal": wifi-client.signal-strength,
            })
            --qos=1
            --message-expiry-interval=600
            --user-properties={"fw": "1.0.0"}
        print "Measurement published (QoS 1)."
      if exception: print "Measurement failed: $exception"
      measurement-timer = MEASUREMENT-INTERVAL.in-ms

    // QoS 2 — exactly-once delivery for RSSI float (dBm).
    if rssi-timer <= 0:
      exception := catch:
        client.publish-float RSSI-TOPIC wifi-client.signal-strength --qos=2
        print "RSSI published (QoS 2)."
      if exception: print "RSSI failed: $exception"
      rssi-timer = RSSI-INTERVAL.in-ms

    // QoS 0 — metrics snapshot; excluded from messages-published count via telemetry-published.
    if metrics-timer <= 0:
      exception := catch:
        snapshot := client.metrics.to-map CLIENT-ID
        snapshot["wifi_signal"] = wifi-client.signal-strength
        client.publish-map METRICS-TOPIC snapshot
        client.metrics.telemetry-published++
        print "Metrics published (QoS 0)."
      if exception: print "Metrics failed: $exception"
      metrics-timer = METRICS-INTERVAL.in-ms

    tick := 60_000
    tick = min tick measurement-timer
    tick = min tick rssi-timer
    tick = min tick metrics-timer
    sleep --ms=tick
    measurement-timer -= tick
    rssi-timer        -= tick
    metrics-timer     -= tick
