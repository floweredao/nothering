import Darwin
import Foundation
import Network
import os

/// A SOCKS5 (no-auth) server supporting CONNECT and framed UDP (`DatagramFrame`). Every accepted CONNECT is served by a brand-new
/// outbound connection opened from this device's own network stack.
public final class ProxyServer {
  public struct Configuration {
    public var port: NWEndpoint.Port
    /// Pin outbound connections to an interface type (e.g. `.cellular`). `nil` = system default.
    public var requiredInterfaceType: NWInterface.InterfaceType?
    /// Decides by the name of the local interface a client connected through (e.g. `bridge100`).
    public var isInterfaceAllowed: (String) -> Bool
    /// How long a client gets to send its greeting and request before it is dropped.
    public var handshakeTimeout: TimeInterval

    public init(
      port: NWEndpoint.Port = 11080,
      requiredInterfaceType: NWInterface.InterfaceType? = .cellular,
      isInterfaceAllowed: @escaping (String) -> Bool = ProxyServer.isHotspotOrLoopbackInterface,
      handshakeTimeout: TimeInterval = 10
    ) {
      self.port = port
      self.requiredInterfaceType = requiredInterfaceType
      self.isInterfaceAllowed = isInterfaceAllowed
      self.handshakeTimeout = handshakeTimeout
    }
  }

  public struct Stats: Codable, Equatable {
    public var activeConnections = 0
    public var totalConnections = 0
    public var bytesUp: UInt64 = 0
    public var bytesDown: UInt64 = 0
    /// The connection counts above, split by `Link`.
    public var activeUSBConnections = 0
    public var totalUSBConnections = 0
    public var activeHotspotConnections = 0
    public var totalHotspotConnections = 0

    public init() {}
  }

  /// The link a client came over: usbmux delivers USB connections on loopback, and Personal
  /// Hotspot clients arrive on a `bridge*` interface.
  public enum Link: Sendable {
    case usb
    case hotspot

    public init?(interface: String) {
      if interface == "lo0" {
        self = .usb
      } else if interface.hasPrefix("bridge") {
        self = .hotspot
      } else {
        return nil
      }
    }
  }

  public struct StartError: LocalizedError {
    let underlying: Error

    public var errorDescription: String? {
      "Proxy listener failed: \(underlying.localizedDescription)"
    }
  }

  let configuration: Configuration
  let queue = DispatchQueue(label: "app.nothering.proxy")
  let logger = Logger(subsystem: "app.nothering", category: "proxy")
  private var listener: SocketListener?
  private var sessions: [ObjectIdentifier: (session: Session, link: Link?)] = [:]
  private var stats = Stats()

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  /// Starts listening on all interfaces and returns the bound port.
  @discardableResult
  public func start() async throws -> NWEndpoint.Port {
    do {
      let listener = try SocketListener(port: configuration.port.rawValue, queue: queue) { [weak self] fd, interface in
        self?.accept(fd, interface: interface)
      }
      self.listener = listener
      logger.info("listening on port \(listener.port)")
      return NWEndpoint.Port(rawValue: listener.port)!
    } catch {
      throw StartError(underlying: error)
    }
  }

  public func stop() {
    queue.sync {
      listener?.cancel()
      listener = nil
      for entry in sessions.values {
        entry.session.close()
      }
      sessions.removeAll()
    }
  }

  public func currentStats() -> Stats {
    queue.sync { stats }
  }

  /// Tells every client listening for events. The write happens before this returns, so the event
  /// still goes out when the process exits or `stop` closes the connections right after.
  public func send(_ event: ProxyEvent) {
    queue.sync {
      for entry in sessions.values {
        entry.session.send(event)
      }
    }
  }

  private func accept(_ fd: Int32, interface: String?) {
    guard let interface, configuration.isInterfaceAllowed(interface) else {
      logger.notice("rejected client on interface \(interface ?? "unknown", privacy: .public)")
      Darwin.close(fd)
      return
    }
    logger.info("accepted client on interface \(interface, privacy: .public)")
    let session = Session(client: SocketStream(fd: fd, queue: queue), server: self)
    let link = Link(interface: interface)
    sessions[ObjectIdentifier(session)] = (session, link)
    stats.activeConnections += 1
    stats.totalConnections += 1
    switch link {
    case .usb:
      stats.activeUSBConnections += 1
      stats.totalUSBConnections += 1
    case .hotspot:
      stats.activeHotspotConnections += 1
      stats.totalHotspotConnections += 1
    case nil:
      break
    }
    session.start()
  }

  // MARK: Session callbacks (always on `queue`)

  func sessionDidClose(_ session: Session) {
    guard let entry = sessions.removeValue(forKey: ObjectIdentifier(session)) else { return }
    stats.activeConnections -= 1
    switch entry.link {
    case .usb:
      stats.activeUSBConnections -= 1
    case .hotspot:
      stats.activeHotspotConnections -= 1
    case nil:
      break
    }
  }

  func record(bytes: Int, upstream: Bool) {
    if upstream {
      stats.bytesUp += UInt64(bytes)
    } else {
      stats.bytesDown += UInt64(bytes)
    }
  }

  // MARK: Client allowlist

  /// Allows loopback and Personal Hotspot (`bridge*`) clients only, so the proxy is never
  /// reachable from an arbitrary Wi-Fi network or cellular peer.
  public static func isHotspotOrLoopbackInterface(_ name: String) -> Bool {
    name == "lo0" || name.hasPrefix("bridge")
  }
}

// MARK: - Session

final class Session {
  private let client: ByteStream
  private var upstream: NWConnection?
  private var datagramRelay: DatagramRelay?
  private unowned let server: ProxyServer
  private static let waitingTimeout: TimeInterval = 10
  private var replied = false
  private var waitingDeadlineScheduled = false
  private var triedNAT64 = false
  private var finishedDirections = 0
  private var closed = false
  private var isEventStream = false

  init(client: ByteStream, server: ProxyServer) {
    self.client = client
    self.server = server
  }

  func start() {
    readGreeting()
    // A client that never finishes its request would otherwise hold its socket forever.
    server.queue.asyncAfter(deadline: .now() + server.configuration.handshakeTimeout) { [weak self] in
      guard let self, !replied, upstream == nil else { return }
      close()
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    upstream?.stateUpdateHandler = nil
    client.cancel()
    upstream?.cancel()
    datagramRelay?.close()
    server.sessionDidClose(self)
  }

  // MARK: Handshake

  private func readGreeting() {
    read(2) { [self] header in
      guard header[0] == 0x05 else { return close() }
      read(Int(header[1])) { [self] methods in
        guard methods.contains(0x00) else {
          client.write(Data([0x05, 0xFF])) { [self] _ in close() }
          return
        }
        client.write(Data([0x05, 0x00])) { [self] error in
          error == nil ? readRequest() : close()
        }
      }
    }
  }

  private func readRequest() {
    read(4) { [self] header in
      guard header[0] == 0x05 else { return close() }
      let command = header[1]
      guard [0x01, DatagramFrame.command, ProxyEvent.command].contains(command) else {
        return reply(0x07) // command not supported
      }
      let handle = { [self] (host: NWEndpoint.Host, portBytes: Data) in
        switch command {
        case 0x01: connect(host: host, portBytes: portBytes)
        case DatagramFrame.command: relayDatagrams()
        default: streamEvents()
        }
      }
      switch header[3] {
      case 0x01:
        read(6) { body in
          handle(.ipv4(IPv4Address(body.prefix(4))!), body.suffix(2))
        }
      case 0x04:
        read(18) { body in
          handle(.ipv6(IPv6Address(body.prefix(16))!), body.suffix(2))
        }
      case 0x03:
        read(1) { [self] length in
          read(Int(length[0]) + 2) { [self] body in
            guard let name = String(data: body.prefix(body.count - 2), encoding: .utf8) else {
              return reply(0x01)
            }
            handle(NWEndpoint.Host(name), body.suffix(2))
          }
        }
      default:
        reply(0x08) // address type not supported
      }
    }
  }

  private func connect(host: NWEndpoint.Host, portBytes: Data) {
    let bytes = [UInt8](portBytes)
    open(host: host, port: NWEndpoint.Port(rawValue: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))!)
  }

  private func open(host: NWEndpoint.Host, port: NWEndpoint.Port) {
    let parameters = NWParameters.tcp
    if let interfaceType = server.configuration.requiredInterfaceType {
      parameters.requiredInterfaceType = interfaceType
    }
    let upstream = NWConnection(host: host, port: port, using: parameters)
    self.upstream = upstream
    upstream.stateUpdateHandler = { [self] state in
      switch state {
      case .ready:
        reply(0x00)
      case let .waiting(error) where !replied && !triedNAT64 && Self.isNoRoute(error) && Self.nat64Address(for: host) != nil:
        // IPv6-only cellular networks have no IPv4 route; reach IPv4 literals through the carrier's NAT64.
        triedNAT64 = true
        upstream.stateUpdateHandler = nil
        upstream.cancel()
        open(host: .ipv6(Self.nat64Address(for: host)!), port: port)
      case let .waiting(error) where error != .posix(.ECONNREFUSED) && !replied:
        // Often transient (path or DNS still coming up); give it a bounded chance before failing.
        guard !waitingDeadlineScheduled else { return }
        waitingDeadlineScheduled = true
        server.queue.asyncAfter(deadline: .now() + Self.waitingTimeout) { [self] in
          guard !replied, !closed else { return }
          server.logger.notice("connect \(host.debugDescription, privacy: .public):\(port.rawValue) timed out: \(error.debugDescription, privacy: .public)")
          reply(Self.replyCode(for: error))
        }
      case let .waiting(error), let .failed(error):
        server.logger.notice("connect \(host.debugDescription, privacy: .public):\(port.rawValue) failed: \(error.debugDescription, privacy: .public)")
        replied ? close() : reply(Self.replyCode(for: error))
      case .cancelled:
        close()
      default:
        break
      }
    }
    upstream.start(queue: server.queue)
  }

  /// Accepts a framed-UDP session; the request's address is unused.
  private func relayDatagrams() {
    datagramRelay = DatagramRelay(client: client, server: server) { [weak self] in self?.close() }
    reply(0x00)
  }

  /// Accepts an event stream (`ProxyEvent`); the request's address is unused.
  private func streamEvents() {
    isEventStream = true
    reply(0x00)
  }

  func send(_ event: ProxyEvent) {
    guard isEventStream, replied, !closed else { return }
    client.write(Data([event.rawValue])) { _ in }
  }

  /// The client never sends anything on an event stream, so any read result means it went away.
  private func closeWhenClientLeaves() {
    client.read(minimum: 1, maximum: 1024) { [self] _, _, _ in close() }
  }

  static func isNoRoute(_ error: NWError) -> Bool {
    error == .posix(.ENETDOWN) || error == .posix(.ENETUNREACH)
  }

  /// Maps an IPv4 host into the well-known NAT64 prefix 64:ff9b::/96 (RFC 6052).
  static func nat64Address(for host: NWEndpoint.Host) -> IPv6Address? {
    guard case let .ipv4(address) = host else { return nil }
    return IPv6Address(Data([0x00, 0x64, 0xFF, 0x9B] + [UInt8](repeating: 0, count: 8)) + address.rawValue)
  }

  /// Sends a SOCKS5 reply. Success starts the relay; any failure closes the session afterwards.
  private func reply(_ code: UInt8) {
    guard !replied else { return }
    replied = true
    let message = Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    client.write(message) { [self] error in
      guard code == 0x00, error == nil else { return close() }
      if isEventStream { return closeWhenClientLeaves() }
      if let datagramRelay { return datagramRelay.start() }
      guard let upstream else { return close() }
      pump(from: client, to: upstream, isUpstream: true)
      pump(from: upstream, to: client, isUpstream: false)
    }
  }

  static func replyCode(for error: NWError) -> UInt8 {
    switch error {
    case .posix(.ECONNREFUSED): return 0x05
    case .posix(.ENETUNREACH), .posix(.ENETDOWN): return 0x03
    case .posix(.EHOSTUNREACH), .posix(.EHOSTDOWN), .dns: return 0x04
    case .posix(.ETIMEDOUT): return 0x06
    default: return 0x01
    }
  }

  // MARK: Relay

  private func pump(from source: ByteStream, to destination: ByteStream, isUpstream: Bool) {
    source.read(minimum: 1, maximum: 64 * 1024) { [self] data, isComplete, error in
      guard !closed else { return }
      if let data, !data.isEmpty {
        server.record(bytes: data.count, upstream: isUpstream)
        destination.write(data) { [self] writeError in
          guard writeError == nil else { return close() }
          isComplete ? finish(destination) : pump(from: source, to: destination, isUpstream: isUpstream)
        }
      } else if isComplete {
        finish(destination)
      } else if error != nil {
        close()
      }
    }
  }

  /// Propagates EOF (half-close) and tears down once both directions are done.
  private func finish(_ destination: ByteStream) {
    destination.writeEOF()
    finishedDirections += 1
    if finishedDirections == 2 { close() }
  }

  private func read(_ count: Int, _ completion: @escaping (Data) -> Void) {
    guard count > 0 else { return completion(Data()) }
    client.read(minimum: count, maximum: count) { [self] data, _, error in
      guard !closed else { return }
      guard error == nil, let data, data.count == count else { return close() }
      completion(Data(data))
    }
  }
}
