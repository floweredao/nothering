import Darwin
import Foundation
import Testing

@Suite struct PhoneReachabilityTests {
  @Test func reachableWhenForwarderAnswers() async throws {
    let forwarder = try FakeForwarder { _ in .datagrams }
    defer { forwarder.stop() }
    let reachability = PhoneReachability(forwarderPort: forwarder.port)
    reachability.start()
    defer { reachability.stop() }

    #expect(await eventually { reachability.isReachable })
    #expect(reachability.supportsDatagrams)
  }

  @Test func olderPhoneIsReachableWithoutDatagrams() async throws {
    let forwarder = try FakeForwarder { _ in .noDatagrams }
    defer { forwarder.stop() }
    let reachability = PhoneReachability(forwarderPort: forwarder.port)
    reachability.start()
    defer { reachability.stop() }

    #expect(await eventually { reachability.isReachable })
    #expect(!reachability.supportsDatagrams)
  }

  /// The forwarder accepts connections while its link to the phone is down, but doesn't greet.
  @Test func unreachableWhileForwarderIsSilent() async throws {
    let forwarder = try FakeForwarder { _ in .silence }
    defer { forwarder.stop() }
    let reachability = PhoneReachability(forwarderPort: forwarder.port)
    reachability.start()
    defer { reachability.stop() }

    #expect(await eventually { forwarder.connections >= 3 })
    #expect(!reachability.isReachable)
    #expect(!reachability.supportsDatagrams)
  }

  @Test func toleratesOneFailedProbe() async throws {
    let forwarder = try FakeForwarder { $0 == 2 ? .silence : .datagrams }
    defer { forwarder.stop() }
    let reachability = PhoneReachability(forwarderPort: forwarder.port)
    reachability.start()
    defer { reachability.stop() }

    #expect(await eventually { reachability.isReachable })
    var dropped = false
    // The fourth connection starts only after the failed second probe and the third have finished.
    let probed = await eventually {
      dropped = dropped || !reachability.isReachable || !reachability.supportsDatagrams
      return forwarder.connections >= 4
    }
    #expect(probed)
    #expect(!dropped)
  }

  @Test func unreachableAfterTwoFailedProbes() async throws {
    let forwarder = try FakeForwarder { $0 == 1 ? .datagrams : .silence }
    defer { forwarder.stop() }
    let reachability = PhoneReachability(forwarderPort: forwarder.port)
    reachability.start()
    defer { reachability.stop() }

    #expect(await eventually { reachability.isReachable })
    #expect(await eventually { !reachability.isReachable })
    #expect(forwarder.connections >= 3)
    #expect(!reachability.supportsDatagrams)
  }
}

private func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
  let deadline = Date() + timeout
  while !condition() {
    guard Date() < deadline else { return false }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return true
}

/// Stands in for the menu bar app's forwarder on 127.0.0.1, answering connections one at a time
/// with the reply chosen for each (numbered from 1).
private final class FakeForwarder: @unchecked Sendable {
  enum Reply {
    /// Greets and accepts the framed-UDP command, like a current phone app.
    case datagrams
    /// Greets but refuses the framed-UDP command, like a phone app that predates it.
    case noDatagrams
    /// Closes without greeting, like the forwarder while it has no link to the phone.
    case silence
  }

  let port: UInt16
  private let fd: Int32
  private let lock = NSLock()
  private var count = 0
  private var stopped = false

  var connections: Int { lock.withLock { count } }

  init(reply: @escaping @Sendable (Int) -> Reply) throws {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    self.fd = fd
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    guard bound else {
      close(fd)
      throw ForwarderError()
    }
    port = UInt16(bigEndian: address.sin_port)
    Thread.detachNewThread { [self] in serve(reply) }
  }

  func stop() {
    lock.withLock { stopped = true }
  }

  private func serve(_ reply: (Int) -> Reply) {
    defer { close(fd) }
    while !lock.withLock({ stopped }) {
      var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&pollFD, 1, 50) == 1 else { continue }
      let client = accept(fd, nil, nil)
      guard client >= 0 else { continue }
      var on: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      let number = lock.withLock {
        count += 1
        return count
      }
      answer(client, reply(number))
      close(client)
    }
  }

  private func answer(_ client: Int32, _ reply: Reply) {
    guard reply != .silence, readExactly(client, 3) == [0x05, 0x01, 0x00] else { return }
    let method: [UInt8] = [0x05, 0x00]
    _ = write(client, method, method.count)
    guard readExactly(client, 10)?.prefix(2) == [0x05, 0x83] else { return }
    let response: [UInt8] = [0x05, reply == .datagrams ? 0x00 : 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    _ = write(client, response, response.count)
  }

  private func readExactly(_ client: Int32, _ count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let received = bytes.withUnsafeMutableBytes { read(client, $0.baseAddress! + offset, count - offset) }
      guard received > 0 else { return nil }
      offset += received
    }
    return bytes
  }
}

private struct ForwarderError: Error {}
