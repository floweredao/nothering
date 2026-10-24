import Darwin
import Foundation
import Network
import Testing
@testable import ProxyCore

@Suite struct LocalForwarderTests {
  @Test func relaysLoopbackClientToUpstream() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }

    let forwarder = LocalForwarder(port: 0) { try connectTCP(port: echoPort.rawValue) }
    let port = try forwarder.start()
    defer { forwarder.stop() }

    let client = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    try await client.startAndWaitReady()
    try await client.sendAsync(Data("through the phone".utf8))
    #expect(try await client.receiveExactly(17) == Data("through the phone".utf8))

    let stats = forwarder.currentStats()
    #expect(stats.activeConnections == 1)
    #expect(stats.bytesUp == 17)
    #expect(stats.bytesDown == 17)
    client.cancel()
  }

  @Test func closesClientWhenUpstreamFails() async throws {
    struct Unreachable: Error {}
    let forwarder = LocalForwarder(port: 0) { throw Unreachable() }
    let port = try forwarder.start()
    defer { forwarder.stop() }

    let client = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    try await client.startAndWaitReady()
    let reply = try? await client.receiveExactly(1)
    #expect(reply == nil || reply?.isEmpty == true)
    client.cancel()
  }

  /// A client still waiting for its upstream when the forwarder stops used to start relaying anyway.
  @Test func dropsClientsStillConnectingWhenStopped() async throws {
    let (echo, echoPort) = try await startEchoServer()
    defer { echo.cancel() }
    let upstream = BlockedUpstream()
    let forwarder = LocalForwarder(port: 0) {
      upstream.waitForRelease()
      return try connectTCP(port: echoPort.rawValue)
    }
    let port = try forwarder.start()

    let client = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    try await client.startAndWaitReady()
    try await client.sendAsync(Data("x".utf8))
    let deadline = ContinuousClock.now + .seconds(2)
    while !upstream.isWaiting, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(upstream.isWaiting)

    forwarder.stop()
    upstream.release()
    let reply = try? await client.receiveExactly(1)
    #expect(reply == nil || reply?.isEmpty == true)
    #expect(forwarder.currentStats().activeConnections == 0)
    client.cancel()
  }
}

/// Holds `connectUpstream` until the test releases it.
private final class BlockedUpstream: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var waiting = false

  var isWaiting: Bool { lock.withLock { waiting } }

  func waitForRelease() {
    lock.withLock { waiting = true }
    semaphore.wait()
  }

  func release() {
    semaphore.signal()
  }
}

private func connectTCP(port: UInt16) throws -> Int32 {
  let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard result == 0 else {
    Darwin.close(fd)
    throw SocketError("connect")
  }
  return fd
}
