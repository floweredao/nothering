import Foundation
import Network

/// Serves a framed-UDP session (see `DatagramFrame`): each frame from the client goes out as a
/// datagram from this device's own network stack, and replies come back framed with their peer.
/// All state is confined to the server's queue.
final class DatagramRelay {
  private struct Peer: Hashable {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
  }

  /// Bounds per-session sockets for apps that talk to many peers (e.g. WebRTC).
  private static let maxPeers = 256
  /// Datagrams kept per peer until its connection is ready, to resend if it falls back to NAT64.
  private static let maxUnconfirmed = 32
  /// Bounds those datagrams across all peers, which could otherwise reach 512 MB per session.
  private static let maxUnconfirmedBytes = 64 * 1024
  /// Frames waiting to be written to a client that reads slower than its peers send. Beyond this,
  /// datagrams are dropped like a full socket buffer would.
  private static let maxPendingWriteBytes = 256 * 1024

  private let client: ByteStream
  private unowned let server: ProxyServer
  private let onClose: () -> Void
  private var peers: [Peer: NWConnection] = [:]
  private var unconfirmed: [Peer: [Data]] = [:]
  private var pendingWriteBytes = 0
  private var closed = false

  init(client: ByteStream, server: ProxyServer, onClose: @escaping () -> Void) {
    self.client = client
    self.server = server
    self.onClose = onClose
  }

  func start() {
    readFrame()
  }

  func close() {
    guard !closed else { return }
    closed = true
    for connection in peers.values {
      connection.stateUpdateHandler = nil
      connection.cancel()
    }
    peers.removeAll()
    unconfirmed.removeAll()
  }

  private func readFrame() {
    read(2) { [self] header in
      read(Int(header[0]) << 8 | Int(header[1])) { [self] body in
        guard let frame = DatagramFrame.decode(body: Data(body)) else { return onClose() }
        server.record(bytes: frame.payload.count, upstream: true)
        let peer = Peer(host: frame.host, port: frame.port)
        let connection = peers[peer] ?? open(peer, via: peer.host)
        connection.send(content: frame.payload, completion: .contentProcessed { _ in })
        if connection.state != .ready, unconfirmed[peer, default: []].count < Self.maxUnconfirmed,
           unconfirmedBytes + frame.payload.count <= Self.maxUnconfirmedBytes {
          unconfirmed[peer, default: []].append(frame.payload)
        }
        readFrame()
      }
    }
  }

  /// Bytes kept in `unconfirmed`.
  var unconfirmedBytes: Int {
    var total = 0
    for payloads in unconfirmed.values {
      for payload in payloads {
        total += payload.count
      }
    }
    return total
  }

  private func read(_ count: Int, _ completion: @escaping ([UInt8]) -> Void) {
    client.read(minimum: count, maximum: count) { [self] data, _, _ in
      guard !closed else { return }
      guard let data, data.count == count else { return onClose() }
      completion([UInt8](data))
    }
  }

  private func open(_ peer: Peer, via host: NWEndpoint.Host) -> NWConnection {
    if peers.count >= Self.maxPeers, let evicted = peers.keys.first {
      peers.removeValue(forKey: evicted)?.cancel()
      unconfirmed.removeValue(forKey: evicted)
    }
    let parameters = NWParameters.udp
    if let interfaceType = server.configuration.requiredInterfaceType {
      parameters.requiredInterfaceType = interfaceType
    }
    let connection = NWConnection(host: host, port: peer.port, using: parameters)
    peers[peer] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, peers[peer] === connection else { return }
      switch state {
      case .ready:
        unconfirmed.removeValue(forKey: peer)
      case let .waiting(error) where Session.isNoRoute(error) && host == peer.host:
        // Same as TCP: IPv4 literals on an IPv6-only carrier go through NAT64. Datagrams already
        // handed to the dead connection are resent, or one-shot protocols (NTP, STUN) never answer.
        guard let nat64 = Session.nat64Address(for: host) else { return }
        connection.cancel()
        let replacement = open(peer, via: .ipv6(nat64))
        for payload in unconfirmed.removeValue(forKey: peer) ?? [] {
          replacement.send(content: payload, completion: .contentProcessed { _ in })
        }
      case .failed:
        peers.removeValue(forKey: peer)
        unconfirmed.removeValue(forKey: peer)
        connection.cancel()
      default:
        break
      }
    }
    connection.start(queue: server.queue)
    receive(from: connection, peer: peer)
    return connection
  }

  private func receive(from connection: NWConnection, peer: Peer) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self, !closed, peers[peer] === connection else { return }
      if let data, !data.isEmpty, let frame = DatagramFrame.encode(data, host: peer.host, port: peer.port),
         pendingWriteBytes + frame.count <= Self.maxPendingWriteBytes {
        server.record(bytes: data.count, upstream: false)
        pendingWriteBytes += frame.count
        client.write(frame) { [weak self] error in
          self?.pendingWriteBytes -= frame.count
          if error != nil { self?.onClose() }
        }
      }
      if error == nil { receive(from: connection, peer: peer) }
    }
  }
}
