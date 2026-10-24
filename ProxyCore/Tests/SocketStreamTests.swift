import Darwin
import Foundation
import Testing
@testable import ProxyCore

@Suite struct SocketStreamTests {
  /// Chained one-byte reads over a full buffer used to recurse once per read and overflow the stack.
  @Test func chainsSmallReadsOverLargeBufferWithoutRecursing() async throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { Darwin.close(fds[1]) }

    // One kernel read hands the stream 64 KB, served by 64K chained reads.
    let total = 64 * 1024
    var size = Int32(total * 2)
    setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    let payload = [UInt8](repeating: 7, count: total)
    #expect(payload.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress!, total) } == total)

    let queue = DispatchQueue(label: "SocketStreamTests")
    let stream = SocketStream(fd: fds[0], queue: queue)
    defer { queue.sync { stream.cancel() } }

    let received = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
      var count = 0
      func next() {
        stream.read(minimum: 1, maximum: 1) { data, _, _ in
          guard data != nil else { return continuation.resume(returning: count) }
          count += 1
          if count == total { return continuation.resume(returning: count) }
          next()
        }
      }
      queue.async { next() }
    }
    #expect(received == total)
  }

  @Test func deliversBufferedBytesWhenPeerFinishes() async throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { Darwin.close(fds[1]) }
    let payload: [UInt8] = [1, 2, 3, 4, 5]
    #expect(Darwin.write(fds[1], payload, payload.count) == payload.count)
    shutdown(fds[1], SHUT_WR)

    let queue = DispatchQueue(label: "SocketStreamTests")
    let stream = SocketStream(fd: fds[0], queue: queue)
    defer { queue.sync { stream.cancel() } }

    // Asks for more than the peer sent: the short read comes back once EOF arrives, then EOF alone.
    let reads = await withCheckedContinuation { (continuation: CheckedContinuation<[(Data?, Bool)], Never>) in
      queue.async {
        stream.read(minimum: 10, maximum: 10) { data, isComplete, _ in
          stream.read(minimum: 1, maximum: 10) { next, nextIsComplete, _ in
            continuation.resume(returning: [(data, isComplete), (next, nextIsComplete)])
          }
        }
      }
    }
    #expect(reads[0].0 == Data(payload))
    #expect(reads[0].1)
    #expect(reads[1].0 == nil)
    #expect(reads[1].1)
  }
}
