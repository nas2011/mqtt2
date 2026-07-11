// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import net
import net.tcp as tcp
import tls
import io
import .packet
import .vbi as vbi

/**
MQTT Transport Layer.
Provides a common interface for reading and writing packets over a network connection.
*/
interface Transport:
  /**
  Reads the next MQTT Control Packet from the transport.
  Returns null if the transport is closed.
  */
  read -> Packet?

  /**
  Writes an MQTT Control Packet to the transport.
  */
  write packet/Packet -> none

  /**
  Closes the transport and the underlying connection.
  */
  close -> none

  /**
  Returns the Maximum Transmission Unit (MTU) of the transport.
  */
  mtu -> int

/**
A transport implementation that wraps a $tcp.Socket.
This works for both standard TCP and TLS sockets.
*/
class SocketTransport implements Transport:
  /** Default high-water mark for the encode buffer in bytes. */
  static DEFAULT-MAX-ENCODE-BUFFER ::= 256

  socket_/tcp.Socket
  reader_/io.Reader
  writer_/io.Writer
  encode-buffer_/io.Buffer := io.Buffer
  max-encode-buffer_/int

  constructor .socket_ --max-encode-buffer/int=DEFAULT-MAX-ENCODE-BUFFER:
    max-encode-buffer_ = max-encode-buffer
    socket_.no-delay = true
    reader_ = socket_.in
    writer_ = socket_.out

  /**
  Connects to a host using TCP.
  */
  static connect network/net.Interface host/string port/int
      --max-encode-buffer/int=DEFAULT-MAX-ENCODE-BUFFER -> SocketTransport:
    socket := network.tcp-connect host port
    return SocketTransport socket --max-encode-buffer=max-encode-buffer

  /**
  Connects to a host using TLS.
  */
  static connect-tls network/net.Interface host/string port/int
      --server-name/string?=host
      --certificate/tls.Certificate?=null
      --root-certificates=[]
      --handshake-timeout/Duration=tls.Session.DEFAULT-HANDSHAKE-TIMEOUT
      --skip-certificate-validation/bool=false
      --max-encode-buffer/int=DEFAULT-MAX-ENCODE-BUFFER -> SocketTransport:
    socket := network.tcp-connect host port
    tls-socket := tls.Socket.client socket
        --server-name=server-name
        --certificate=certificate
        --root-certificates=root-certificates
        --handshake-timeout=handshake-timeout
        --skip-certificate-validation=skip-certificate-validation
    return SocketTransport tls-socket --max-encode-buffer=max-encode-buffer

  read -> Packet?:
    // Try to peek the first byte to see if any data is available.
    // This returns false if the reader is at EOF.
    if not reader_.try-ensure-buffered 1: return null
    return Packet.decode reader_

  write packet/Packet -> none:
    encode-buffer_.clear
    packet.write-body encode-buffer_
    body := encode-buffer_.bytes
    writer_.write-byte (packet.type << 4 | packet.flags)
    vbi.encode writer_ body.size
    writer_.write body
    if encode-buffer_.size > max-encode-buffer_:
      encode-buffer_ = io.Buffer

  close -> none:
    socket_.close

  mtu -> int:
    return socket_.mtu
