import Foundation
import Network
import Testing
@testable import ProxyCore

@Suite struct DatagramRelayTests {
  /// Frames for peers that aren't ready yet used to be kept up to 32 per peer whatever their size.
  @Test func boundsDatagramsKeptForPeersNotYetReady() throws {
    // Pinned to cellular, which the test host doesn't have, so no peer ever becomes ready.
    let server = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: .cellular))
    var frames = Data()
    for port: UInt16 in [9, 10] {
      for _ in 0..<3 {
        let destination = try #require(NWEndpoint.Port(rawValue: port))
        let frame = try #require(DatagramFrame.encode(Data(count: 60000), host: .ipv6(.loopback), port: destination))
        frames += frame
      }
    }
    let client = ScriptedStream(frames)
    let relay = DatagramRelay(client: client, server: server) {}

    let kept: Int = server.queue.sync {
      relay.start()
      let bytes = relay.unconfirmedBytes
      relay.close()
      return bytes
    }
    #expect(kept > 0)
    #expect(kept <= 64 * 1024)
  }
}

/// Hands the reader `input` as fast as it asks, then nothing more. Writes are counted and never
/// complete, like a client that stopped reading. Used only on the server's queue.
private final class ScriptedStream: ByteStream {
  private var input: Data
  private(set) var pendingWriteBytes = 0

  init(_ input: Data) {
    self.input = input
  }

  func read(minimum: Int, maximum: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
    guard !input.isEmpty, input.count >= minimum else { return }
    let chunk = Data(input.prefix(maximum))
    input = Data(input.dropFirst(chunk.count))
    completion(chunk, false, nil)
  }

  func write(_ data: Data, completion: @escaping (Error?) -> Void) {
    pendingWriteBytes += data.count
  }

  func writeEOF() {}

  func cancel() {}
}
