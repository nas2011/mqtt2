# mqtt2 — MQTT 5.0 Client for Toit

A memory-efficient, fully asynchronous MQTT 5.0 client for the Toit ecosystem, designed for microcontrollers like the ESP32. Compliant with the [OASIS MQTT 5.0 specification](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html).

## Features

- **Full MQTT 5.0 support** — all control packets, reason codes, and properties
- **Auto-reconnect** — exponential backoff with configurable limits; enabled automatically when a transport provider is supplied
- **Asynchronous design** — two-task model (reader + writer) built on Toit Tasks and Monitors
- **Memory efficient** — bounded packet reader eliminates per-packet heap allocations; reusable encode buffer; pre-split topic filter parts; exact-match fast path for dispatch
- **Topic Aliases** — client automatically assigns and reuses outgoing aliases when the server supports them
- **Flow control** — respects the server's `Receive Maximum` with a semaphore-based in-flight quota
- **QoS 0 / 1 / 2** — full handshake support
- **Request-Response** — built-in correlation data pattern (MQTT 5.0 §4.10)
- **Observability** — `ClientMetrics` for runtime statistics; `MqttLogTarget` to forward structured logs to the broker
- **TLS** — `SocketTransport.connect-tls` for encrypted connections

## Installation

Add to your `package.yaml`:

```yaml
dependencies:
  mqtt2:
    path: . # replace with published registry reference when available
```

Then run `toit pkg install`.

## Quick Start

```toit
import net
import mqtt2 show *

HOST ::= "broker.example.com"
PORT ::= 1883

main:
  network := net.open

  client := Client
  client.on-disconnected = :: print "Permanently disconnected."

  client.connect
      (Options --client-id="toit-demo" --keep-alive=60)
      --transport-provider=(:: SocketTransport.connect network HOST PORT)

  client.subscribe "demo/+" --qos=1:: |msg/Message|
    print "[$msg.topic] $msg.payload.to-string"

  client.publish-string "demo/hello" "Hello from Toit!" --qos=1

  while true: sleep --ms=1000
```

## Auto-Reconnect

Pass a `--transport-provider` lambda to `connect` to enable automatic reconnection. The lambda is called on every attempt — including the first — so the client handles both the initial connection and all subsequent reconnects without additional logic.

```toit
client.connect
    (Options --client-id="my-device" --keep-alive=60)
    --transport-provider=(:: SocketTransport.connect network HOST PORT)
```

The default backoff policy is: 1 s initial delay, 2× multiplier, 60 s ceiling, 30 s per-attempt timeout, infinite retries. Override with `ReconnectOptions`:

```toit
client.connect
    (Options --client-id="my-device")
    --transport-provider=(:: SocketTransport.connect network HOST PORT)
    --reconnect-options=(ReconnectOptions
        --initial-delay=(Duration --s=2)
        --max-delay=(Duration --s=120)
        --max-attempts=10)
```

`on-disconnected` fires only once, on the final transition to disconnected — either when `disconnect` is called or when all reconnect attempts are exhausted.

Subscriptions are automatically re-established after each successful reconnect when the server does not resume a previous session.

Set `on-reconnected` to run logic after the reconnect loop re-establishes the session following a transient disconnect (it is not invoked after the initial `connect`, only on later automatic reconnects). Use it to re-assert state a clean-start session drops silently, e.g. a retained birth message:

```toit
client.on-reconnected = ::
  client.publish-string STATUS-TOPIC "online" --qos=1 --retain=true
```

## API Reference

### `Options`

Passed to `Client.connect`.

| Field | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `client-id` | `string` | `""` | Client identifier; empty lets the server assign one |
| `clean-start` | `bool` | `true` | Whether to start a clean session |
| `keep-alive` | `int` | `60` | Keep-alive interval in seconds |
| `username` | `string?` | `null` | Authentication username |
| `password` | `string?` | `null` | Authentication password |
| `properties` | `Properties` | `Properties` | MQTT 5.0 CONNECT properties |
| `user-properties` | `Map?` | `null` | User properties for the CONNECT packet |
| `client-receive-maximum` | `int?` | `null` | Max QoS 1/2 in-flight messages this client accepts |
| `will` | `Will?` | `null` | Last Will and Testament message |

### `ReconnectOptions`

| Field | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `max-attempts` | `int` | `-1` | Max reconnect attempts; `-1` = infinite |
| `initial-delay` | `Duration` | `2 s` | Initial backoff delay |
| `max-delay` | `Duration` | `60 s` | Maximum backoff delay |
| `backoff-multiplier` | `float` | `2.0` | Multiplier applied after each failure |
| `connect-timeout` | `Duration?` | `null` | Per-attempt timeout for transport + CONNACK; `null` disables it |

These are the defaults if you construct `ReconnectOptions` yourself. If you omit `--reconnect-options` entirely, `Client.connect` uses its own built-in policy instead (1 s initial delay, 30 s connect timeout — see [Auto-Reconnect](#auto-reconnect)).

### `Client`

#### Fields

| Field | Type | Description |
| :--- | :--- | :--- |
| `is-connected` | `bool` | True when an active MQTT session exists |
| `session` | `Session?` | Negotiated session info; available after `connect` |
| `metrics` | `ClientMetrics` | Runtime statistics |
| `on-message` | `Lambda?` | Global fallback for messages not matched by any subscription |
| `on-disconnected` | `Lambda?` | Called once on final disconnect |
| `on-reconnected` | `Lambda?` | Called after each successful automatic reconnect (not on the initial `connect`) |

#### `connect`

```toit
connect options/Options=Options
    --transport/Transport?=null
    --transport-provider/Lambda?=null
    --reconnect-options/ReconnectOptions?=null
    --debug/bool=false
    --log-target/log.Target?=null
```

- `--transport` — one-shot transport for simple scripts or tests
- `--transport-provider` — lambda returning a `Transport`; enables auto-reconnect
- `--debug` — logs protocol-level detail to the default logger
- `--log-target` — supply a custom `log.Target` (e.g. `MqttLogTarget`) to route logs there

#### Publish

```toit
publish topic/string payload/ByteArray
    --qos/int=0
    --retain/bool=false
    --timeout/Duration?=null
    --properties/Properties=Properties
    --user-properties/Map?=null
    --message-expiry-interval/int?=null
    --content-type/string?=null
    --response-topic/string?=null
    --correlation-data/ByteArray?=null

publish-string topic/string payload/string  ...same options...
publish-int    topic/string payload/int     ...same options...
publish-float  topic/string payload/float   ...same options...
publish-map    topic/string payload/Map     ...same options... (JSON-encodes; default content-type "application/json")
publish-list   topic/string payload/List    ...same options... (JSON-encodes; default content-type "application/json")
```

QoS 0 publishes return immediately. QoS 1 and 2 block until the full ACK handshake completes (or `--timeout` elapses).

#### Subscribe / Unsubscribe

```toit
subscribe topic-filter/string
    --qos/int=0
    --omit-local/bool=false
    --retain-as-published/bool=false
    --retain-handling/int=0
    --timeout/Duration?=null
    --properties/Properties=Properties
    --user-properties/Map?=null
    callback/Lambda  // called with Message for each matching incoming message

subscribe-multiple subscriptions/List           // each a SubscriptionRequest
    --properties/Properties=Properties
    --timeout/Duration?=null
    --user-properties/Map?=null -> List          // returns List of reason codes

unsubscribe topic-filter/string
    --properties/Properties=Properties
    --timeout/Duration?=null
    --user-properties/Map?=null -> int           // returns reason code

unsubscribe-multiple topic-filters/List
    --properties/Properties=Properties
    --timeout/Duration?=null
    --user-properties/Map?=null -> List
```

#### Other

```toit
request topic/string payload/ByteArray
    --response-topic/string
    --qos/int=0
    --timeout/Duration?=null
    --correlation-data/ByteArray?=null -> Message

disconnect
    --reason-code/int=0
    --properties/Properties=Properties
    --user-properties/Map?=null
    --reason-string/string?=null

close  // abrupt close; triggers reconnect if a transport-provider is configured
```

### `Message`

Passed to subscription callbacks and `on-message`.

| Member | Type | Description |
| :--- | :--- | :--- |
| `topic` | `string` | The topic the message was published on |
| `payload` | `ByteArray` | Raw message bytes |
| `properties` | `Properties` | Full MQTT 5.0 properties |
| `user-properties` | `Map` | User properties as a `Map<string, string>` |
| `content-type` | `string?` | Content type property if present |
| `response-topic` | `string?` | Response topic property if present |
| `correlation-data` | `ByteArray?` | Correlation data property if present |

### `Session`

Available as `client.session` after a successful `connect`.

| Member | Type | Description |
| :--- | :--- | :--- |
| `session-present` | `bool` | Server resumed an existing session |
| `assigned-client-identifier` | `string?` | Server-assigned client ID |
| `server-keep-alive` | `int?` | Keep-alive negotiated by server |
| `session-expiry-interval` | `int?` | Session expiry interval assigned by the server, if any |
| `receive-maximum` | `int` | Server's in-flight message limit (default 65535) |
| `topic-alias-maximum` | `int` | Number of topic aliases the server allows (default 0) |
| `maximum-qos` | `int` | Highest QoS the server supports (default 2) |
| `retain-available` | `bool` | Whether retained messages are supported (default true) |
| `maximum-packet-size` | `int?` | Maximum packet size the server accepts |
| `wildcard-subscription-available` | `bool` | Whether `+`/`#` wildcard subscriptions are supported (default true) |
| `subscription-identifier-available` | `bool` | Whether subscription identifiers are supported (default true) |
| `shared-subscription-available` | `bool` | Whether shared subscriptions are supported (default true) |

### `ClientMetrics`

Available as `client.metrics`.

| Member | Type | Description |
| :--- | :--- | :--- |
| `messages-published` | `int` | Total QoS-acknowledged publishes (excludes telemetry) |
| `messages-received` | `int` | Total messages dispatched to handlers |
| `reconnect-attempts` | `int` | Total reconnect attempts since boot |
| `telemetry-published` | `int` | Publishes from the observability layer |
| `latency-qos1` | `LatencyStats` | Round-trip latency for QoS 1 (last / min / max / avg / count) |
| `latency-qos2` | `LatencyStats` | Round-trip latency for QoS 2 |
| `client-uptime-s` | `int` | Seconds since the client was created |
| `connected-duration-s` | `int` | Seconds in the current connected session |
| `total-connected-s` | `int` | Cumulative seconds connected since boot |
| `to-map client-id/string` | `Map` | JSON-serializable snapshot for publishing |

### `SocketTransport`

```toit
// TCP
SocketTransport.connect network/net.Interface host/string port/int
    --max-encode-buffer/int=256 -> SocketTransport

// TLS
SocketTransport.connect-tls network/net.Interface host/string port/int
    --server-name/string?=host
    --certificate/tls.Certificate?=null
    --root-certificates=[]
    --handshake-timeout/Duration=tls.Session.DEFAULT-HANDSHAKE-TIMEOUT
    --skip-certificate-validation/bool=false
    --max-encode-buffer/int=256 -> SocketTransport
```

`--max-encode-buffer` bounds the reusable outgoing-packet buffer: it shrinks back to a fresh `io.Buffer` after any write that exceeds this size, so one large publish doesn't permanently inflate memory held per connection.

## Advanced Usage

### TLS Connection

```toit
client.connect
    (Options --client-id="secure-device" --keep-alive=60)
    --transport-provider=(:: SocketTransport.connect-tls network HOST 8883)
```

### Properties and User Properties

```toit
client.publish-string "sensors/temp" "24.5"
    --qos=1
    --content-type="text/plain"
    --message-expiry-interval=3600
    --user-properties={"device": "esp32-s3", "fw": "1.2.0"}
```

### Request-Response

```toit
response := client.request "cmd/get-config" #[]
    --response-topic="cmd/response/my-device"
    --timeout=(Duration --s=5)

print "Config: $response.payload.to-string"
```

### Observability

`MqttLogTarget` forwards structured log records to an MQTT topic at QoS 0, while also passing them through to the inner target (console). Records are dropped silently when not connected.

```toit
import log
import mqtt2 show *

log-target := MqttLogTarget client CLIENT-ID log.default.target_

client.connect options
    --transport-provider=(:: SocketTransport.connect network HOST PORT)
    --log-target=log-target
```

The default publish topic is `telemetry/{client-id}/logs`. Override it with `--log-topic`:

```toit
log-target := MqttLogTarget client CLIENT-ID log.default.target_
    --log-topic="devices/$CLIENT-ID/logs"
```

Use `--min-level` to make the broker quieter than the console without touching the enclosing
logger's own threshold:

```toit
log-target := MqttLogTarget client CLIENT-ID log.default.target_
    --min-level=log.INFO-LEVEL   // broker only sees INFO and above; console still sees everything
```

Publish a metrics snapshot periodically:

```toit
snapshot := client.metrics.to-map CLIENT-ID
snapshot["wifi_signal"] = wifi-client.signal-strength
client.publish-map "telemetry/$CLIENT-ID/metrics" snapshot
client.metrics.telemetry-published++
```

### Topic Aliases

Managed automatically. The first publish to a topic sends the full string; subsequent publishes to the same topic substitute a 2-byte integer alias, reducing wire size on repetitive topics. No application code needed.

### Last Will and Testament

```toit
will := Will "device/$CLIENT-ID/status" "offline".to-byte-array --qos=1 --retain=true
options := Options --client-id=CLIENT-ID --will=will
```

## Architecture

The client uses a **two-task model**:

1. **Reader task** — decodes incoming packets from the socket; handles PUBLISH dispatch, ACK resolution, QoS 2 state tracking, and keep-alive PINGREQ/PINGRESP. Keep-alive detection uses `with-timeout` directly in the read loop rather than a third task.
2. **Writer task** — drains a bounded channel of outgoing packets, ensuring the application never blocks on a slow network write.

Each call to `connect` is the start of a new connection identity (`connection-id_`). Reconnect tasks capture their identity at spawn time and abort automatically when a newer connection supersedes them — no explicit cancellation or generation counters needed.

Incoming message dispatch uses an exact-match map for wildcard-free subscriptions (O(1) lookup) and a separate wildcard scan only for filters containing `+` or `#`. Topic filter parts are pre-split at subscribe time so no string splitting occurs per message.

## AI Disclosure

This project was developed with the assistance of AI tools, specifically Anthropic's Claude and Google's Gemini.

## License

MIT-style. See [LICENSE](LICENSE) for details.

Copyright (C) 2026 Nick Sexson. All rights reserved.
