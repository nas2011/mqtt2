// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import monitor
import log
import encoding.json
import .transport
import .packet
import .properties
import .constants
import .packet_id
import .topic_filter show match-topic
import .data show validate-mqtt-string
import .metrics

/**
An incoming MQTT message.
*/
class Message:
  /** The topic the message was published to. */
  topic/string
  /** The payload of the message. */
  payload/ByteArray
  /** The MQTT 5.0 properties associated with the message. */
  properties/Properties

  constructor .topic .payload .properties:

  /** Returns all user properties as a Map. */
  user-properties -> Map: return properties.get-user-properties

  /** Returns the content type if present. */
  content-type -> string?: return properties.get-string PROPERTY-IDENTIFIER-CONTENT-TYPE

  /** Returns the response topic if present. */
  response-topic -> string?: return properties.get-string PROPERTY-IDENTIFIER-RESPONSE-TOPIC

  /** Returns the correlation data if present. */
  correlation-data -> ByteArray?: return properties.get-binary PROPERTY-IDENTIFIER-CORRELATION-DATA

/**
Options for connecting to an MQTT broker.
*/
class Options:
  /** The client identifier. If empty, the server may assign one. */
  client-id/string := ""
  /** Whether to start a clean session. */
  clean-start/bool := true
  /** The keep-alive interval in seconds. */
  keep-alive/int := 60
  /** The username for authentication. */
  username/string? := null
  /** The password for authentication. */
  password/string? := null
  /** MQTT 5.0 properties for the CONNECT packet. */
  properties/Properties := Properties
  /** The maximum number of QoS 1 and QoS 2 in-flight messages the client accepts. */
  client-receive-maximum/int? := null
  /** User properties for the CONNECT packet. */
  user-properties/Map? := null
  /** Optional Last Will and Testament message. */
  will/Will? := null

  constructor
      --.client-id=""
      --.clean-start=true
      --.keep-alive=60
      --.username=null
      --.password=null
      --.properties=Properties
      --.client-receive-maximum=null
      --.user-properties=null
      --.will=null:

/**
Options controlling automatic reconnection behavior.

Reconnect happens automatically whenever a [transport-provider] lambda is supplied
to [Client.connect]. Pass a [ReconnectOptions] to override the built-in defaults;
if none is provided, [Client.DEFAULT-RECONNECT-OPTIONS_] is used.

Delays follow an exponential backoff: each failed attempt multiplies the current
delay by [backoff-multiplier], capped at [max-delay].

Set [connect-timeout] to bound each connection attempt (transport creation + CONNACK).
Without a timeout, a silent TCP peer (dropped SYNs rather than RST) can block the
reconnect loop for the full OS-level TCP retransmission window — tens of minutes on
embedded stacks like ESP32 lwIP.
*/
class ReconnectOptions:
  /** Maximum number of reconnection attempts. -1 means retry indefinitely. */
  max-attempts/int
  /** Initial delay between reconnection attempts. */
  initial-delay/Duration
  /** Maximum delay between reconnection attempts. */
  max-delay/Duration
  /** Multiplier applied to the delay after each failed attempt. */
  backoff-multiplier/float
  /**
  Maximum time allowed for a single connection attempt, covering both transport
  creation and the CONNACK exchange. Null disables the timeout.
  */
  connect-timeout/Duration?

  constructor
      --.max-attempts=-1
      --.initial-delay=(Duration --s=2)
      --.max-delay=(Duration --s=60)
      --.backoff-multiplier=2.0
      --.connect-timeout=null:

class Subscription_:
  qos/int
  block/Lambda
  filter-parts/List

  constructor --.qos --.block --filter/string:
    filter-parts = filter.split "/"

class RequestWaiter_:
  latch/monitor.Latch
  response-topic/string

  constructor --.latch --.response-topic:

/**
Represents an active MQTT session and its negotiated properties.
*/
class Session:
  /** Whether the server had a session for this client. */
  session-present/bool
  /** The MQTT 5.0 properties associated with the session. */
  properties/Properties

  /**
  Creates a session with the given [session-present] flag and [properties].
  */
  constructor .session-present=false .properties=Properties:

  /** The client identifier assigned by the server, if any. */
  assigned-client-identifier -> string?:
    return properties.get-string PROPERTY-IDENTIFIER-ASSIGNED-CLIENT-IDENTIFIER

  /** The keep-alive interval assigned by the server, if any. */
  server-keep-alive -> int?:
    return properties.get-uint16 PROPERTY-IDENTIFIER-SERVER-KEEP-ALIVE

  /** The session expiry interval assigned by the server, if any. */
  session-expiry-interval -> int?:
    return properties.get-uint32 PROPERTY-IDENTIFIER-SESSION-EXPIRY-INTERVAL

  /** The maximum number of QoS 1 and QoS 2 in-flight messages the server accepts. */
  receive-maximum -> int:
    val := properties.get-uint16 PROPERTY-IDENTIFIER-RECEIVE-MAXIMUM
    return val != null ? val : 65535

  /** The maximum QoS level the server supports. Default is 2. */
  maximum-qos -> int:
    val := properties.get-uint8 PROPERTY-IDENTIFIER-MAXIMUM-QOS
    return val != null ? val : 2

  /** Whether the server supports retained messages. Default is true. */
  retain-available -> bool:
    val := properties.get-uint8 PROPERTY-IDENTIFIER-RETAIN-AVAILABLE
    return val == null or val != 0

  /** The maximum packet size the server accepts. */
  maximum-packet-size -> int?:
    return properties.get-uint32 PROPERTY-IDENTIFIER-MAXIMUM-PACKET-SIZE

  /** The maximum number of topic aliases the server accepts. Default is 0. */
  topic-alias-maximum -> int:
    val := properties.get-uint16 PROPERTY-IDENTIFIER-TOPIC-ALIAS-MAXIMUM
    return val != null ? val : 0

  /** Whether the server supports wildcard subscriptions. Default is true. */
  wildcard-subscription-available -> bool:
    val := properties.get-uint8 PROPERTY-IDENTIFIER-WILDCARD-SUBSCRIPTION-AVAILABLE
    return val == null or val != 0

  /** Whether the server supports subscription identifiers. Default is true. */
  subscription-identifier-available -> bool:
    val := properties.get-uint8 PROPERTY-IDENTIFIER-SUBSCRIPTION-IDENTIFIER-AVAILABLE
    return val == null or val != 0

  /** Whether the server supports shared subscriptions. Default is true. */
  shared-subscription-available -> bool:
    val := properties.get-uint8 PROPERTY-IDENTIFIER-SHARED-SUBSCRIPTION-AVAILABLE
    return val == null or val != 0

/**
The MQTT 5.0 Client.
*/
class Client:
  /** Client is not connected and no reconnect loop is active. */
  static STATE-DISCONNECTED  ::= 0
  /** Client is establishing the transport and waiting for CONNACK. */
  static STATE-CONNECTING    ::= 1
  /** Client has an active MQTT session. */
  static STATE-CONNECTED     ::= 2
  /** Client is between reconnection attempts. */
  static STATE-RECONNECTING  ::= 3

  // Caps the effective keep-alive interval regardless of what the broker negotiates.
  // Ensures dead connections are detected within this many seconds even when the
  // broker advertises a longer (or absent) server-keep-alive.
  static MAX-KEEP-ALIVE-S_ ::= 30

  /**
  Default reconnect parameters used when no [ReconnectOptions] is supplied.
  1 s initial delay, 2× backoff, 60 s ceiling, 30 s per-attempt timeout, infinite retries.
  */
  static DEFAULT-RECONNECT-OPTIONS_ ::= ReconnectOptions
      --initial-delay=(Duration --s=1)
      --max-delay=(Duration --s=60)
      --backoff-multiplier=2.0
      --connect-timeout=(Duration --s=30)

  transport_/Transport? := null
  state_/int := STATE-DISCONNECTED
  logger_/log.Logger? := null

  /** Runtime statistics for this client. */
  metrics/ClientMetrics := ClientMetrics

  /** Whether the client has an active MQTT session. */
  is-connected -> bool: return state_ == STATE-CONNECTED

  constructor .transport_=null:

  /** The active session information. Available after successful [connect]. */
  session/Session? := null

  packet-id-manager_/PacketIdentifierManager := PacketIdentifierManager

  // State for tasks
  outgoing-channel_/monitor.Channel := monitor.Channel 16
  keep-alive-interval-s_/int := 0

  read-task_/Task? := null
  writer-task_/Task? := null
  pingresp-latch_/monitor.Latch? := null

  // In-flight state
  waiters_/Map := {:} // packet-id -> Latch
  incoming-qos2_/Map := {:} // packet-id -> PublishPacket
  in-flight-semaphore_/monitor.Semaphore? := null

  // Request/Response state
  request-waiters_/Map := {:} // string -> RequestWaiter_
  next-request-id_/int := 1

  // Topic Alias state
  // Outgoing (Client -> Server)
  topic-to-alias_/Map := {:} // string -> int
  next-outgoing-alias_/int := 1
  topic-alias-maximum_/int := 0 // cached from session; avoids Properties.get per publish

  // Incoming (Server -> Client)
  alias-to-topic_/Map := {:} // int -> string

  // Subscription state
  subscriptions_/Map := {:}        // wildcard filters: topic-filter -> Subscription_
  exact-subscriptions_/Map := {:}  // exact (no-wildcard) filters: topic-filter -> Subscription_

  /**
  Callback for incoming messages.
  Called for all messages unless they were handled by a topic-specific subscription callback.
  */
  on-message/Lambda? := null

  /** Callback invoked when the client permanently disconnects (will not reconnect). */
  on-disconnected/Lambda? := null

  /**
  Callback invoked after the reconnect loop re-establishes the session
  following a transient disconnect. Not invoked after the initial [connect] —
  only on later, automatic reconnects. Use this to re-assert any state a
  clean-start session drops silently, e.g. a retained birth message that
  otherwise stays overwritten by the broker's Will until the next full restart.
  */
  on-reconnected/Lambda? := null

  // Reconnect state
  options_/Options? := null
  debug_/bool := false
  transport-provider_/Lambda? := null   // :: -> Transport
  reconnect-options_/ReconnectOptions? := null
  reconnect-task_/Task? := null
  connection-id_/int := 0               // Incremented to supersede stale reconnect loops

  /**
  Connects to the MQTT broker using the provided [options].

  If already connected, the existing connection is closed first.

  Pass [transport] to use a one-shot transport for the initial connection.
  Pass [transport-provider] (a zero-argument lambda returning a [Transport]) to enable
  auto-reconnect — it is called on every connection attempt, including the first.
  If both are provided, [transport] is used for the initial connection and
  [transport-provider] is stored for subsequent reconnects.

  Reconnect is enabled automatically when [transport-provider] is supplied.
  Pass [reconnect-options] to override the built-in backoff defaults; if omitted,
  [DEFAULT-RECONNECT-OPTIONS_] is used.

  Throws if the connection is refused or the handshake fails.
  */
  connect options/Options=Options
      --transport/Transport?=null
      --transport-provider/Lambda?=null
      --reconnect-options/ReconnectOptions?=null
      --debug/bool=false
      --log-target/log.Target?=null:
    if state_ == STATE-CONNECTED or state_ == STATE-RECONNECTING: close-gracefully_

    options_ = options
    debug_ = debug
    if transport-provider: transport-provider_ = transport-provider
    if reconnect-options: reconnect-options_ = reconnect-options

    if log-target != null:
      logger_ = log.Logger log.DEBUG-LEVEL log-target --name="mqtt2"
    else if debug_:
      logger_ = log.Logger log.DEBUG-LEVEL log.default.target_ --name="mqtt2"

    // Acquire the initial transport.
    actual-transport/Transport? := transport
    if not actual-transport:
      if transport-provider_: actual-transport = transport-provider_.call
      else if transport_: actual-transport = transport_
    if not actual-transport: throw "NO_TRANSPORT"
    transport_ = actual-transport

    state_ = STATE-CONNECTING
    connect-internal_

  connect-internal_ -> none:
    if logger_: logger_.debug "connecting" --tags={"client-id": options_.client-id}

    local-props := options_.properties.copy
    if options_.client-receive-maximum != null:
      local-props.add-uint16 PROPERTY-IDENTIFIER-RECEIVE-MAXIMUM options_.client-receive-maximum
    add-user-properties_ local-props options_.user-properties

    connect-packet := ConnectPacket
        --client-id=options_.client-id
        --clean-start=options_.clean-start
        --keep-alive=options_.keep-alive
        --username=options_.username
        --password=options_.password
        --properties=local-props
        --will=options_.will

    transport_.write connect-packet

    packet := transport_.read
    if not packet: throw "CONNECTION_CLOSED"
    if packet is not ConnackPacket: throw "EXPECTED_CONNACK_GOT_$(packet.type)"

    connack := packet as ConnackPacket
    if logger_: logger_.debug "received CONNACK" --tags={"reason-code": connack.reason-code, "session-present": connack.session-present}
    if connack.reason-code != 0: throw "CONNECTION_REFUSED: $(connack.reason-code)"

    state_ = STATE-CONNECTED
    metrics.on-connect_
    session = Session connack.session-present connack.properties
    topic-alias-maximum_ = session.topic-alias-maximum

    if session.receive-maximum == 0: throw "PROTOCOL_ERROR: Server sent Receive Maximum 0"
    in-flight-semaphore_ = monitor.Semaphore --count=session.receive-maximum

    actual-keep-alive := session.server-keep-alive != null ? session.server-keep-alive : options_.keep-alive
    if actual-keep-alive > 0:
      keep-alive-interval-s_ = min actual-keep-alive MAX-KEEP-ALIVE-S_
      if logger_: logger_.debug "keep-alive: interval=$keep-alive-interval-s_ s" --tags={"negotiated": actual-keep-alive}

    writer-task_ = task --background:: writer-loop_
    read-task_ = task --background:: read-loop_

  write_ packet/Packet -> none:
    if not is-connected: throw "NOT_CONNECTED"
    outgoing-channel_.send packet
    // If close was called while we were blocked on send (channel drained by close),
    // throw so callers get an error rather than silently succeeding.
    if not is-connected: throw "NOT_CONNECTED"

  writer-loop_ -> none:
    write-timeout-ms := keep-alive-interval-s_ > 0 ? keep-alive-interval-s_ * 1000 : 30_000
    while is-connected:
      packet := outgoing-channel_.receive
      if not packet: continue

      exception := catch:
        with-timeout --ms=write-timeout-ms:
          transport_.write packet

      if exception:
        if logger_: logger_.warn "writer-loop: write failed ($exception), closing"
        if is-connected: close
        return

  read-loop_ -> none:
    keep-alive-ms := keep-alive-interval-s_ * 1000
    while is-connected:
      packet/Packet? := null

      exception := catch:
        if keep-alive-ms > 0:
          with-timeout --ms=keep-alive-ms:
            packet = transport_.read
        else:
          packet = transport_.read

      if exception == DEADLINE-EXCEEDED-ERROR:
        if not pingresp-latch_:
          if logger_: logger_.debug "keep-alive: sending PINGREQ"
          ping-ex := catch:
            write_ PingreqPacket
          if ping-ex:
            if is-connected: close
            return
          latch := monitor.Latch
          pingresp-latch_ = latch
          task --background::
            ex := catch:
              with-timeout --ms=keep-alive-ms:
                latch.get
            if ex == DEADLINE-EXCEEDED-ERROR:
              if logger_: logger_.warn "keep-alive: no PINGRESP within deadline, closing"
              if is-connected: close
        continue

      if exception:
        if logger_: logger_.warn "read-loop: read failed ($exception), closing"
        if is-connected: close
        return

      if not packet:
        if logger_: logger_.warn "read-loop: transport closed by peer, closing"
        if is-connected: close
        return

      handle-packet_ packet

  handle-packet_ packet/Packet -> none:
    if packet is PingrespPacket:
      if logger_: logger_.debug "received PINGRESP"
      latch := pingresp-latch_
      pingresp-latch_ = null
      if latch: latch.set true
      return

    if packet is DisconnectPacket:
      close
      return

    if packet is PubackPacket or packet is PubrecPacket or packet is PubcompPacket or packet is SubackPacket or packet is UnsubackPacket:
      packet-id := 0
      if packet is AckPacket:
        packet-id = (packet as AckPacket).packet-id
      else if packet is SubackPacket:
        packet-id = (packet as SubackPacket).packet-id
      else if packet is UnsubackPacket:
        packet-id = (packet as UnsubackPacket).packet-id

      latch := waiters_.get packet-id
      if latch: latch.set packet
      return

    if packet is PubrelPacket:
      rel := packet as PubrelPacket
      msg-packet := incoming-qos2_.get rel.packet-id
      if msg-packet:
        write_ (PubcompPacket rel.packet-id)
        topic := get-topic_ msg-packet
        if topic:
          deliver-message_ (Message topic msg-packet.payload msg-packet.properties)
        incoming-qos2_.remove rel.packet-id
      else:
        // Already acknowledged or unknown. Spec says MUST respond with PUBCOMP.
        write_ (PubcompPacket rel.packet-id --reason-code=0x92) // 0x92 = Packet Identifier not found
      return

    if packet is PublishPacket:
      msg-packet := packet as PublishPacket
      topic := get-topic_ msg-packet
      if logger_: logger_.debug "received PUBLISH" --tags={"topic": topic, "qos": msg-packet.qos, "packet-id": msg-packet.packet-id}
      if not topic:
        // Protocol error: Topic Alias invalid
        disconnect --reason-code=0x94
        return

      msg := Message topic msg-packet.payload msg-packet.properties

      // Handle Request/Response
      correlation-data := msg.correlation-data
      if correlation-data:
        key := correlation-data.to-string
        waiter := request-waiters_.get key
        if waiter and topic == waiter.response-topic:
          waiter.latch.set msg
          return

      if msg-packet.qos == 0:
        deliver-message_ msg
      else if msg-packet.qos == 1:
        deliver-message_ msg
        write_ (PubackPacket msg-packet.packet-id)
      else if msg-packet.qos == 2:
        if incoming-qos2_.contains msg-packet.packet-id:
          // Duplicate, just re-send PUBREC
          write_ (PubrecPacket msg-packet.packet-id)
        else:
          incoming-qos2_[msg-packet.packet-id] = msg-packet
          write_ (PubrecPacket msg-packet.packet-id)
      return

    if logger_: logger_.warn "received unhandled packet type: $(packet.type)"

  deliver-message_ msg/Message -> none:
    metrics.messages-received++
    matched := false
    exact-sub := exact-subscriptions_.get msg.topic
    if exact-sub:
      (exact-sub as Subscription_).block.call msg
      matched = true
    subscriptions_.do: |_ sub/Subscription_|
      if match-topic sub.filter-parts msg.topic:
        sub.block.call msg
        matched = true
    if not matched and on-message: on-message.call msg

  /**
  Performs a request-response flow.
  Publishes a message to [topic] and waits for a response on [response-topic].
  Generates a unique Correlation Data if not provided.
  */
  request topic/string payload/ByteArray
      --response-topic/string
      --qos/int=0
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null
      --correlation-data/ByteArray? = null -> Message:
    if not is-connected: throw "NOT_CONNECTED"

    actual-correlation-data := correlation-data
    if not actual-correlation-data:
      actual-correlation-data = "req-$(next-request-id_++)".to-byte-array

    key := actual-correlation-data.to-string
    latch := monitor.Latch
    request-waiters_[key] = RequestWaiter_ --latch=latch --response-topic=response-topic

    try:
      publish topic payload
          --qos=qos
          --properties=properties
          --user-properties=user-properties
          --response-topic=response-topic
          --correlation-data=actual-correlation-data

      if timeout:
        return with-timeout timeout: latch.get
      else:
        return latch.get
    finally:
      request-waiters_.remove key

  get-topic_ msg/PublishPacket -> string?:
    alias := msg.properties.get-uint16 PROPERTY-IDENTIFIER-TOPIC-ALIAS
    if not alias:
      if msg.topic-name == "": return null
      return msg.topic-name

    if alias == 0: return null // Alias 0 is not allowed

    if msg.topic-name != "":
      // Update mapping
      alias-to-topic_[alias] = msg.topic-name
      return msg.topic-name

    // Use existing mapping
    return alias-to-topic_.get alias

  /**
  Publishes a message to the given [topic].

  Throws an exception if the message cannot be published (e.g., timeout).
  */
  publish topic/string payload/ByteArray
      --qos/int=0
      --retain/bool=false
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null
      --message-expiry-interval/int?=null
      --content-type/string?=null
      --response-topic/string?=null
      --correlation-data/ByteArray?=null:
    validate-mqtt-string topic
    if not is-connected: throw "NOT_CONNECTED"

    // Only copy and build a modified Properties when something actually needs to be added.
    // Avoids a heap allocation cycle (Properties + io.Buffer) on every plain publish.
    has-alias := topic-alias-maximum_ > 0
    needs-props := user-properties != null or message-expiry-interval != null
        or content-type != null or response-topic != null or correlation-data != null
        or has-alias

    actual-topic := topic
    actual-props := properties

    if needs-props:
      local-props := properties.copy
      add-user-properties_ local-props user-properties
      if message-expiry-interval != null: local-props.add-uint32 PROPERTY-IDENTIFIER-MESSAGE-EXPIRY-INTERVAL message-expiry-interval
      if content-type != null: local-props.add-string PROPERTY-IDENTIFIER-CONTENT-TYPE content-type
      if response-topic != null: local-props.add-string PROPERTY-IDENTIFIER-RESPONSE-TOPIC response-topic
      if correlation-data != null: local-props.add-binary PROPERTY-IDENTIFIER-CORRELATION-DATA correlation-data

      if has-alias:
        existing-alias := topic-to-alias_.get topic
        if existing-alias:
          local-props.add-uint16 PROPERTY-IDENTIFIER-TOPIC-ALIAS existing-alias
          actual-topic = ""
        else if next-outgoing-alias_ <= topic-alias-maximum_:
          new-alias := next-outgoing-alias_++
          topic-to-alias_[topic] = new-alias
          local-props.add-uint16 PROPERTY-IDENTIFIER-TOPIC-ALIAS new-alias

      actual-props = local-props

    if qos == 0:
      if logger_: logger_.debug "publishing message" --tags={"topic": topic, "qos": 0}
      write_ (PublishPacket actual-topic payload --qos=0 --retain=retain --properties=actual-props)
      metrics.messages-published++
      return

    // QoS 1 or 2
    if not in-flight-semaphore_: throw "PROTOCOL_ERROR: No in-flight quota"

    in-flight-semaphore_.down
    packet-id := packet-id-manager_.allocate
    latch := monitor.Latch
    waiters_[packet-id] = latch

    semaphore-released := false
    try:
      if logger_: logger_.debug "publishing message" --tags={"topic": topic, "qos": qos, "packet-id": packet-id}
      write_ (PublishPacket actual-topic payload --qos=qos --retain=retain --packet-id=packet-id --properties=actual-props)

      block := :
        if qos == 1:
          ack := latch.get
          if ack is not PubackPacket: throw "EXPECTED_PUBACK_GOT_$(ack.type)"
          if (ack as PubackPacket).reason-code >= 0x80: throw "PUBACK_ERROR: $((ack as PubackPacket).reason-code)"
        else: // qos == 2
          // For QoS 2, we release the semaphore after PUBREC.
          try:
            ack := latch.get
            if ack is not PubrecPacket: throw "EXPECTED_PUBREC_GOT_$(ack.type)"
            if (ack as PubrecPacket).reason-code >= 0x80: throw "PUBREC_ERROR: $((ack as PubrecPacket).reason-code)"
          finally:
            in-flight-semaphore_.up
            semaphore-released = true

          // New latch for PUBCOMP
          latch = monitor.Latch
          waiters_[packet-id] = latch
          write_ (PubrelPacket packet-id)
          comp := latch.get
          if comp is not PubcompPacket: throw "EXPECTED_PUBCOMP_GOT_$(comp.type)"
          if (comp as PubcompPacket).reason-code >= 0x80: throw "PUBCOMP_ERROR: $((comp as PubcompPacket).reason-code)"

      start-us := Time.monotonic-us
      if timeout:
        with-timeout timeout: block.call
      else:
        block.call
      metrics.record-publish-latency (Time.monotonic-us - start-us) / 1_000 --qos=qos
    finally:
      waiters_.remove packet-id
      packet-id-manager_.release packet-id
      if not semaphore-released: in-flight-semaphore_.up

  /**
  Publishes a string message to the given [topic].
  */
  publish-string topic/string payload/string
      --qos/int=0
      --retain/bool=false
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null
      --message-expiry-interval/int?=null
      --content-type/string?=null
      --response-topic/string?=null
      --correlation-data/ByteArray?=null:
    publish topic payload.to-byte-array
        --qos=qos
        --retain=retain
        --properties=properties
        --timeout=timeout
        --user-properties=user-properties
        --message-expiry-interval=message-expiry-interval
        --content-type=content-type
        --response-topic=response-topic
        --correlation-data=correlation-data

  /**
  Publishes a float message as a string to the given [topic].
  */
  publish-float topic/string payload/float
      --qos/int=0
      --retain/bool=false
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null
      --message-expiry-interval/int?=null
      --content-type/string?=null
      --response-topic/string?=null
      --correlation-data/ByteArray?=null:
    publish-string topic payload.to-string
        --qos=qos
        --retain=retain
        --properties=properties
        --timeout=timeout
        --user-properties=user-properties
        --message-expiry-interval=message-expiry-interval
        --content-type=content-type
        --response-topic=response-topic
        --correlation-data=correlation-data

  /**
  Publishes an integer message as a string to the given [topic].
  */
  publish-int topic/string payload/int
      --qos/int=0
      --retain/bool=false
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null
      --message-expiry-interval/int?=null
      --content-type/string?=null
      --response-topic/string?=null
      --correlation-data/ByteArray?=null:
    publish-string topic payload.to-string
        --qos=qos
        --retain=retain
        --properties=properties
        --timeout=timeout
        --user-properties=user-properties
        --message-expiry-interval=message-expiry-interval
        --content-type=content-type
        --response-topic=response-topic
        --correlation-data=correlation-data

  /**
  Publishes a map message as a JSON string to the given [topic].
  */
  publish-map topic/string payload/Map
      --qos/int=0
      --retain/bool=false
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null
      --message-expiry-interval/int?=null
      --content-type/string?="application/json"
      --response-topic/string?=null
      --correlation-data/ByteArray?=null:
    // Publish the ByteArray directly to avoid a wasteful ByteArray→String→ByteArray round-trip.
    publish topic (json.encode payload)
        --qos=qos
        --retain=retain
        --properties=properties
        --timeout=timeout
        --user-properties=user-properties
        --message-expiry-interval=message-expiry-interval
        --content-type=content-type
        --response-topic=response-topic
        --correlation-data=correlation-data

  /**
  Publishes a list message as a JSON string to the given [topic].
  */
  publish-list topic/string payload/List
      --qos/int=0
      --retain/bool=false
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null
      --message-expiry-interval/int?=null
      --content-type/string?="application/json"
      --response-topic/string?=null
      --correlation-data/ByteArray?=null:
    publish topic (json.encode payload)
        --qos=qos
        --retain=retain
        --properties=properties
        --timeout=timeout
        --user-properties=user-properties
        --message-expiry-interval=message-expiry-interval
        --content-type=content-type
        --response-topic=response-topic
        --correlation-data=correlation-data

  /**
  Subscribes to the given [topic-filter] and calls the [callback] for each incoming message.
  */
  subscribe topic-filter/string
      --qos/int=0
      --omit-local/bool=false
      --retain-as-published/bool=false
      --retain-handling/int=0
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties=null
      callback/any -> none:
    validate-mqtt-string topic-filter
    req := SubscriptionRequest topic-filter
        --qos=qos
        --omit-local=omit-local
        --retain-as-published=retain-as-published
        --retain-handling=retain-handling
    results := subscribe-multiple [req]
        --properties=properties
        --timeout=timeout
        --user-properties=user-properties

    if results.size != 1 or results[0] >= 0x80:
      throw "SUBSCRIBE_FAILED: $(results.size > 0 ? results[0] : "NO_RESPONSE")"

    sub := Subscription_ --qos=qos --block=callback --filter=topic-filter
    if (sub.filter-parts.any: |p| p == "+" or p == "#"):
      subscriptions_[topic-filter] = sub
    else:
      exact-subscriptions_[topic-filter] = sub

  /**
  Subscribes to a list of [subscriptions] (each a [SubscriptionRequest]).
  Returns a list of reason codes from the server.
  */
  subscribe-multiple subscriptions/List
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties=null -> List:
    if not is-connected: throw "NOT_CONNECTED"

    local-props := properties.copy
    add-user-properties_ local-props user-properties

    packet-id := packet-id-manager_.allocate
    latch := monitor.Latch
    waiters_[packet-id] = latch

    try:
      packet := SubscribePacket packet-id --properties=local-props
      subscriptions.do: |sub| packet.subscriptions.add sub
      if logger_: logger_.debug "subscribing" --tags={"packet-id": packet-id, "subscriptions": subscriptions.size}
      write_ packet

      ack := null
      if timeout:
        with-timeout timeout: ack = latch.get
      else:
        ack = latch.get

      if ack is not SubackPacket: throw "EXPECTED_SUBACK_GOT_$(ack.type)"
      if logger_: logger_.debug "received SUBACK" --tags={"packet-id": packet-id}
      return (ack as SubackPacket).reason-codes
    finally:
      waiters_.remove packet-id
      packet-id-manager_.release packet-id

  /**
  Unsubscribes from the given [topic-filter].
  Returns the reason code from the server.
  */
  unsubscribe topic-filter/string
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null -> int:
    results := unsubscribe-multiple [topic-filter]
        --properties=properties
        --timeout=timeout
        --user-properties=user-properties

    if results.size != 1: throw "UNSUBSCRIBE_FAILED: NO_RESPONSE"

    subscriptions_.remove topic-filter
    exact-subscriptions_.remove topic-filter
    return results[0]

  /**
  Unsubscribes from a list of [topic-filters].
  Returns a list of reason codes from the server.
  */
  unsubscribe-multiple topic-filters/List
      --properties/Properties=Properties
      --timeout/Duration?=null
      --user-properties/Map?=null -> List:
    if not is-connected: throw "NOT_CONNECTED"

    local-props := properties.copy
    add-user-properties_ local-props user-properties

    packet-id := packet-id-manager_.allocate
    latch := monitor.Latch
    waiters_[packet-id] = latch

    try:
      packet := UnsubscribePacket packet-id --properties=local-props
      topic-filters.do: |tf| packet.topic-filters.add tf
      if logger_: logger_.debug "unsubscribing" --tags={"packet-id": packet-id, "filters": topic-filters.size}
      write_ packet

      ack := null
      if timeout:
        with-timeout timeout: ack = latch.get
      else:
        ack = latch.get

      if ack is not UnsubackPacket: throw "EXPECTED_UNSUBACK_GOT_$(ack.type)"
      if logger_: logger_.debug "received UNSUBACK" --tags={"packet-id": packet-id}
      return (ack as UnsubackPacket).reason-codes
    finally:
      waiters_.remove packet-id
      packet-id-manager_.release packet-id

  /**
  Disconnects from the MQTT broker by sending a DISCONNECT packet, then closes.

  If the client is currently reconnecting (not connected), the reconnect loop is
  cancelled and [on-disconnected] is invoked immediately.
  */
  disconnect
      --reason-code/int=0
      --properties/Properties=Properties
      --user-properties/Map?=null
      --reason-string/string?=null -> none:
    if state_ == STATE-DISCONNECTED: return

    if state_ != STATE-CONNECTED:
      close-gracefully_
      return

    local-props := properties.copy
    add-user-properties_ local-props user-properties
    if reason-string != null: local-props.add-string PROPERTY-IDENTIFIER-REASON-STRING reason-string

    catch:
      write_ (DisconnectPacket reason-code --properties=local-props)
      // Wait for the disconnect packet to be sent (writer task to drain it)
      // or timeout after a short while.
      catch:
        with-timeout --ms=500:
          while outgoing-channel_.size > 0:
            sleep --ms=10
    close-gracefully_

  add-user-properties_ props/Properties user-props/Map? -> none:
    if not user-props: return
    user-props.do: |key values|
      if values is string:
        props.add-user-property key values
      else if values is List:
        values.do: |v| props.add-user-property key v

  // Shared teardown: closes transport, notifies in-flight waiters, drains queues,
  // resets per-session state. Does not change state_ or invoke callbacks.
  teardown_ -> none:
    metrics.on-disconnect_

    latch := pingresp-latch_
    pingresp-latch_ = null
    if latch: catch: latch.set null

    if transport_:
      transport_.close
      transport_ = null

    waiters_.do: |id l| l.set "CONNECTION_CLOSED" --exception
    waiters_.clear

    request-waiters_.do: |id waiter| waiter.latch.set "CONNECTION_CLOSED" --exception
    request-waiters_.clear

    incoming-qos2_.clear
    packet-id-manager_.clear

    // Drain the outgoing channel
    while (outgoing-channel_.receive --blocking=false):
      // Just drop

    topic-to-alias_.clear
    next-outgoing-alias_ = 1
    topic-alias-maximum_ = 0
    alias-to-topic_.clear

    session = null

  /**
  Closes the client connection without sending a DISCONNECT packet.

  If reconnect is configured, a reconnect loop is started in the background.
  [on-disconnected] is not invoked until the client is permanently closed
  (intentional disconnect or retries exhausted).
  */
  close -> none:
    if state_ == STATE-DISCONNECTED or state_ == STATE-RECONNECTING: return
    state_ = STATE-DISCONNECTED
    teardown_

    if transport-provider_ != null:
      state_ = STATE-RECONNECTING
      connection-id_++
      id := connection-id_
      if logger_: logger_.info "close: spawning reconnect-loop"
      // Set up reconnect BEFORE cancelling background tasks. Cancelling writer-task_
      // from within the writer task itself schedules a CancelledException that fires
      // at the next yield — which would interrupt the logger calls and task creation above.
      reconnect-task_ = task --background:: reconnect-loop_ id
    else:
      if on-disconnected: on-disconnected.call

    // Cancel background tasks after reconnect is set up.
    if read-task_:
      read-task_.cancel
      read-task_ = null

    if writer-task_:
      writer-task_.cancel
      writer-task_ = null

  // Graceful close: stops any active reconnect loop, tears down the connection,
  // then fires on-disconnected. Never triggers a new reconnect loop.
  close-gracefully_ -> none:
    if state_ == STATE-DISCONNECTED: return
    connection-id_++
    if reconnect-task_:
      reconnect-task_.cancel
      reconnect-task_ = null
    if state_ == STATE-CONNECTED or state_ == STATE-CONNECTING:
      teardown_
      if read-task_:
        read-task_.cancel
        read-task_ = null
      if writer-task_:
        writer-task_.cancel
        writer-task_ = null
    state_ = STATE-DISCONNECTED
    if on-disconnected: on-disconnected.call

  reconnect-loop_ id/int -> none:
    if logger_: logger_.info "reconnect-loop: entered"
    opts := reconnect-options_ != null ? reconnect-options_ : DEFAULT-RECONNECT-OPTIONS_

    delay := opts.initial-delay
    attempts := 0

    while true:
      if id != connection-id_: return

      max := opts.max-attempts
      if max != -1 and attempts >= max:
        if logger_: logger_.error "reconnect: giving up after $max attempts"
        state_ = STATE-DISCONNECTED
        reconnect-task_ = null
        if on-disconnected: on-disconnected.call
        return

      attempts++
      metrics.reconnect-attempts++
      if logger_: logger_.info "reconnect: attempt $attempts"

      exception := catch:
        if id != connection-id_: return
        state_ = STATE-CONNECTING
        timeout := opts.connect-timeout
        if timeout:
          with-timeout timeout:
            transport_ = transport-provider_.call
            connect-internal_
        else:
          transport_ = transport-provider_.call
          connect-internal_
        // Clear task reference before resubscribing so that a transport failure
        // during resubscription triggers a fresh reconnect loop.
        reconnect-task_ = null
        if not session.session-present:
          resubscribe-all_
        if logger_: logger_.info "reconnect: succeeded on attempt $attempts"
        if on-reconnected: on-reconnected.call
        return

      if id != connection-id_: return
      state_ = STATE-RECONNECTING
      if logger_: logger_.warn "reconnect: attempt $attempts failed: $exception"

      if transport_:
        catch: transport_.close
        transport_ = null

      sleep delay

      new-us := (delay.in-us.to-float * opts.backoff-multiplier).to-int
      delay = (new-us > opts.max-delay.in-us) ? opts.max-delay : (Duration --us=new-us)

  resubscribe-all_ -> none:
    total := subscriptions_.size + exact-subscriptions_.size
    if total == 0: return
    if logger_: logger_.info "resubscribing to $total topic filters"
    filters := []
    requests := []
    subscriptions_.do: |filter sub/Subscription_|
      filters.add filter
      requests.add (SubscriptionRequest filter --qos=sub.qos)
    exact-subscriptions_.do: |filter sub/Subscription_|
      filters.add filter
      requests.add (SubscriptionRequest filter --qos=sub.qos)
    exception := catch:
      results := subscribe-multiple requests
      results.size.repeat: |i|
        if results[i] >= 0x80:
          if logger_: logger_.error "resubscribe failed for $(filters[i]): $(results[i])"
    if exception:
      if logger_: logger_.error "resubscription failed: $exception"
