import Foundation
import Network
import Testing
@testable import ProxyCore

private let loopback = NWEndpoint.Host.ipv4(.loopback)

@Suite struct ProxyServerTests {
  @Test func relaysThroughIPv4Connect() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1]) + portBytes(echoPort))
    #expect(try await client.receiveExactly(10)[1] == 0x00)

    try await client.sendAsync(Data("hello".utf8))
    #expect(try await client.receiveExactly(5) == Data("hello".utf8))
    client.cancel()

    let stats = server.currentStats()
    #expect(stats.totalConnections == 1)
    #expect(stats.bytesUp == 5)
    #expect(stats.bytesDown == 5)
  }

  @Test func relaysThroughDomainConnect() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    let name = Data("localhost".utf8)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)]) + name + portBytes(echoPort))
    #expect(try await client.receiveExactly(10)[1] == 0x00)

    try await client.sendAsync(Data("ping".utf8))
    #expect(try await client.receiveExactly(4) == Data("ping".utf8))
    client.cancel()
  }

  @Test func relaysThroughIPv6Connect() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    // The proxy listens dual-stack, so it can be its own IPv6 destination.
    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x04] + [UInt8](repeating: 0, count: 15) + [1]) + portBytes(proxyPort))
    #expect(try await client.receiveExactly(10)[1] == 0x00)

    try await client.sendAsync(Data([0x05, 0x01, 0x00]))
    #expect(try await client.receiveExactly(2) == Data([0x05, 0x00]))
    client.cancel()
  }

  @Test func relaysPayloadSentWithHandshake() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    // Greeting, request and payload in one write, before any reply.
    let client = NWConnection(host: loopback, port: proxyPort, using: .tcp)
    try await client.startAndWaitReady()
    let request = Data([0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1]) + portBytes(echoPort)
    try await client.sendAsync(request + Data("early".utf8))
    #expect(try await client.receiveExactly(2) == Data([0x05, 0x00]))
    #expect(try await client.receiveExactly(10)[1] == 0x00)
    #expect(try await client.receiveExactly(5) == Data("early".utf8))
    client.cancel()
  }

  @Test func relaysFramedUDP() async throws {
    let (echo, echoPort) = try await startEchoServer(using: .udp)
    defer { echo.cancel() }
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, DatagramFrame.command, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    #expect(try await client.receiveExactly(10)[1] == 0x00)

    for message in ["one", "two"] {
      let frame = try #require(DatagramFrame.encode(Data(message.utf8), host: loopback, port: echoPort))
      try await client.sendAsync(frame)
      let header = try await client.receiveExactly(2)
      let body = try await client.receiveExactly(Int(header[0]) << 8 | Int(header[1]))
      let reply = try #require(DatagramFrame.decode(body: body))
      #expect(reply.host == loopback)
      #expect(reply.port == echoPort)
      #expect(reply.payload == Data(message.utf8))
    }
    client.cancel()

    let stats = server.currentStats()
    #expect(stats.bytesUp == 6)
    #expect(stats.bytesDown == 6)
  }

  @Test func streamsEventsToListeningClients() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, ProxyEvent.command, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    #expect(try await client.receiveExactly(10)[1] == 0x00)

    server.send(.terminating)
    #expect(try await client.receiveExactly(1) == Data([ProxyEvent.terminating.rawValue]))
    client.cancel()
  }

  @Test func deliversEventSentRightBeforeStop() async throws {
    let (server, proxyPort) = try await startProxy()
    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, ProxyEvent.command, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    #expect(try await client.receiveExactly(10)[1] == 0x00)

    server.send(.stopped)
    server.stop()
    #expect(try await client.receiveExactly(1) == Data([ProxyEvent.stopped.rawValue]))
    client.cancel()
  }

  @Test func closesEventStreamWhenClientLeaves() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, ProxyEvent.command, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    #expect(try await client.receiveExactly(10)[1] == 0x00)
    client.cancel()
    #expect(try await eventually { server.currentStats().activeConnections == 0 })
  }

  @Test func rejectsUnsupportedCommand() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80]))
    #expect(try await client.receiveExactly(10)[1] == 0x07)
    client.cancel()
  }

  @Test func refusesClientsWithoutNoAuth() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = NWConnection(host: loopback, port: proxyPort, using: .tcp)
    try await client.startAndWaitReady()
    try await client.sendAsync(Data([0x05, 0x01, 0x02]))
    #expect(try await client.receiveExactly(2) == Data([0x05, 0xFF]))
    client.cancel()
  }

  @Test func rejectsUnsupportedAddressType() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x05]))
    #expect(try await client.receiveExactly(10)[1] == 0x08)
    client.cancel()
  }

  @Test func rejectsDomainThatIsNotUTF8() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x03, 0x02, 0xFF, 0xFE, 0x00, 0x50]))
    #expect(try await client.receiveExactly(10)[1] == 0x01)
    client.cancel()
  }

  @Test func reportsRefusedConnection() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    try await client.sendAsync(Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 1]))
    #expect(try await client.receiveExactly(10)[1] == 0x05)
    client.cancel()
  }

  @Test func describesListenerFailure() async throws {
    let (server, port) = try await startProxy()
    defer { server.stop() }

    let conflicting = ProxyServer(configuration: .init(port: port, requiredInterfaceType: nil))
    let error = await #expect(throws: ProxyServer.StartError.self) { try await conflicting.start() }
    #expect(error?.localizedDescription.contains("Address already in use") == true)
  }

  @Test(arguments: [
    ("lo0", true),
    ("bridge100", true),
    ("en0", false),
    ("pdp_ip0", false),
    ("utun3", false),
  ])
  func allowsOnlyHotspotOrLoopbackInterfaces(name: String, allowed: Bool) {
    #expect(ProxyServer.isHotspotOrLoopbackInterface(name) == allowed)
  }

  @Test func rejectsClientsOnDisallowedInterfaces() async throws {
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil, isInterfaceAllowed: { _ in false }))
    let port = try await server.start()
    defer { server.stop() }

    let client = NWConnection(host: loopback, port: port, using: .tcp)
    try await client.startAndWaitReady()
    try? await client.sendAsync(Data([0x05, 0x01, 0x00]))
    let reply = try? await client.receiveExactly(2)
    #expect(reply == nil || reply?.isEmpty == true)
    client.cancel()
    #expect(server.currentStats().totalConnections == 0)
  }

  @Test(arguments: [
    ("lo0", ProxyServer.Link.usb),
    ("bridge100", .hotspot),
    ("en0", nil),
    ("pdp_ip0", nil),
  ])
  func classifiesLinkByInterface(name: String, link: ProxyServer.Link?) {
    #expect(ProxyServer.Link(interface: name) == link)
  }

  @Test func countsLoopbackClientsAsUSB() async throws {
    let (server, proxyPort) = try await startProxy()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: proxyPort)
    var stats = server.currentStats()
    #expect(stats.activeUSBConnections == 1)
    #expect(stats.totalUSBConnections == 1)
    #expect(stats.activeHotspotConnections == 0)
    #expect(stats.totalHotspotConnections == 0)

    client.cancel()
    #expect(try await eventually { server.currentStats().activeConnections == 0 })
    stats = server.currentStats()
    #expect(stats.activeUSBConnections == 0)
    #expect(stats.totalUSBConnections == 1)
  }

  @Test func resolvesLoopbackInterfaceForAcceptedClients() async throws {
    let recorded = RecordedInterfaces()
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil, isInterfaceAllowed: {
      recorded.append($0)
      return true
    }))
    let port = try await server.start()
    defer { server.stop() }

    for host in [loopback, NWEndpoint.Host.ipv6(.loopback)] {
      let client = NWConnection(host: host, port: port, using: .tcp)
      try await client.startAndWaitReady()
      try await client.sendAsync(Data([0x05, 0x01, 0x00]))
      _ = try await client.receiveExactly(2)
      client.cancel()
    }
    #expect(recorded.values == ["lo0", "lo0"])
  }

  /// A client that connected and stalled mid-greeting used to keep its socket and session forever.
  @Test func dropsClientsThatNeverFinishTheHandshake() async throws {
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil, handshakeTimeout: 0.2))
    let port = try await server.start()
    defer { server.stop() }

    let client = NWConnection(host: loopback, port: port, using: .tcp)
    try await client.startAndWaitReady()
    try await client.sendAsync(Data([0x05, 0x01]))
    #expect(try await eventually { server.currentStats().totalConnections == 1 })
    #expect(try await eventually { server.currentStats().activeConnections == 0 })
    client.cancel()
  }

  @Test func keepsSessionsThatFinishedTheHandshake() async throws {
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil, handshakeTimeout: 0.2))
    let port = try await server.start()
    defer { server.stop() }

    let client = try await socksHandshake(proxyPort: port)
    try await client.sendAsync(Data([0x05, ProxyEvent.command, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    #expect(try await client.receiveExactly(10)[1] == 0x00)
    try await Task.sleep(for: .milliseconds(500))

    server.send(.terminating)
    #expect(try await client.receiveExactly(1) == Data([ProxyEvent.terminating.rawValue]))
    client.cancel()
  }
}

private final class RecordedInterfaces: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  var values: [String] { lock.withLock { storage } }
  func append(_ value: String) { lock.withLock { storage.append(value) } }
}

// MARK: - Helpers

private func startProxy() async throws -> (ProxyServer, NWEndpoint.Port) {
  let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
  let port = try await server.start()
  return (server, port)
}

private func eventually(_ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + .seconds(2)
  while !condition() {
    guard ContinuousClock.now < deadline else { return false }
    try await Task.sleep(for: .milliseconds(10))
  }
  return true
}

private func portBytes(_ port: NWEndpoint.Port) -> Data {
  Data([UInt8(port.rawValue >> 8), UInt8(port.rawValue & 0xFF)])
}

private func socksHandshake(proxyPort: NWEndpoint.Port) async throws -> NWConnection {
  let client = NWConnection(host: loopback, port: proxyPort, using: .tcp)
  try await client.startAndWaitReady()
  try await client.sendAsync(Data([0x05, 0x01, 0x00]))
  #expect(try await client.receiveExactly(2) == Data([0x05, 0x00]))
  return client
}

func startEchoServer(using parameters: NWParameters = .tcp) async throws -> (NWListener, NWEndpoint.Port) {
  let listener = try NWListener(using: parameters, on: .any)
  let queue = DispatchQueue(label: "echo")
  listener.newConnectionHandler = { connection in
    connection.start(queue: queue)
    func echo() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        if let data, !data.isEmpty {
          connection.send(content: data, completion: .contentProcessed { _ in echo() })
        } else if isComplete || error != nil {
          connection.cancel()
        }
      }
    }
    echo()
  }
  let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        listener.stateUpdateHandler = nil
        continuation.resume(returning: listener.port!)
      case let .failed(error):
        listener.stateUpdateHandler = nil
        continuation.resume(throwing: error)
      default:
        break
      }
    }
    listener.start(queue: queue)
  }
  return (listener, port)
}

extension NWConnection {
  func startAndWaitReady() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          self?.stateUpdateHandler = nil
          continuation.resume()
        case let .failed(error), let .waiting(error):
          self?.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default:
          break
        }
      }
      start(queue: DispatchQueue(label: "client"))
    }
  }

  func sendAsync(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      send(content: data, completion: .contentProcessed { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      })
    }
  }

  func receiveExactly(_ count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: data ?? Data())
        }
      }
    }
  }
}

@Test func mapsIPv4ToWellKnownNAT64Prefix() {
  #expect(Session.nat64Address(for: .ipv4(IPv4Address("34.160.111.145")!)) == IPv6Address("64:ff9b::22a0:6f91"))
  #expect(Session.nat64Address(for: .name("example.com", nil)) == nil)
}

@Test func parsesIPv4LiteralSentAsDomainName() {
  #expect(Session.nat64Address(for: NWEndpoint.Host("34.160.111.145")) != nil)
}
