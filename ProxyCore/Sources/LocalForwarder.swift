import Darwin
import Foundation
import os

/// Accepts loopback connections and relays each one to a stream opened by `connectUpstream`
/// (e.g. usbmux or a TCP connection to the phone over the hotspot).
public final class LocalForwarder {
  public struct Stats: Equatable, Sendable {
    public var activeConnections = 0
    public var bytesUp: UInt64 = 0
    public var bytesDown: UInt64 = 0

    public init() {}
  }

  private let port: UInt16
  private let connectUpstream: () throws -> Int32
  private let queue = DispatchQueue(label: "app.nothering.forwarder")
  private let logger = Logger(subsystem: "app.nothering", category: "forwarder")
  private var listener: SocketListener?
  private var relays: [ObjectIdentifier: Relay] = [:]
  private var stats = Stats()

  /// `connectUpstream` runs off the forwarder queue and returns a connected socket.
  public init(port: UInt16, connectUpstream: @escaping () throws -> Int32) {
    self.port = port
    self.connectUpstream = connectUpstream
  }

  /// Starts listening and returns the bound port.
  public func start() throws -> UInt16 {
    let listener = try SocketListener(port: port, queue: queue) { [weak self] fd, interface in
      guard interface == "lo0" else {
        Darwin.close(fd)
        return
      }
      self?.forward(fd)
    }
    self.listener = listener
    return listener.port
  }

  public func stop() {
    queue.sync {
      listener?.cancel()
      listener = nil
      relays.values.forEach { $0.close() }
      relays.removeAll()
    }
  }

  public func currentStats() -> Stats {
    queue.sync { stats }
  }

  private func forward(_ client: Int32) {
    DispatchQueue.global().async { [self] in
      let upstream: Int32
      do {
        upstream = try connectUpstream()
      } catch {
        logger.error("upstream connect failed: \(error.localizedDescription, privacy: .public)")
        Darwin.close(client)
        return
      }
      queue.async { [self] in
        // `stop` ran while this was connecting, so nothing would ever close the relay.
        guard listener != nil else {
          Darwin.close(client)
          Darwin.close(upstream)
          return
        }
        let relay = Relay(SocketStream(fd: client, queue: queue), SocketStream(fd: upstream, queue: queue)) { [weak self] count, isUp in
          if isUp {
            self?.stats.bytesUp += UInt64(count)
          } else {
            self?.stats.bytesDown += UInt64(count)
          }
        }
        let id = ObjectIdentifier(relay)
        relays[id] = relay
        stats.activeConnections += 1
        relay.start { [weak self] in
          guard let self, relays.removeValue(forKey: id) != nil else { return }
          stats.activeConnections -= 1
        }
      }
    }
  }
}

/// Pipes bytes both ways between two streams, propagating half-close, until both sides finish.
final class Relay {
  private let first: ByteStream
  private let second: ByteStream
  /// Called with each chunk's size; `true` when it flowed from `first` to `second`.
  private let onBytes: (Int, Bool) -> Void
  private var finishedDirections = 0
  private var isClosed = false
  private var onClose: (() -> Void)?

  init(_ first: ByteStream, _ second: ByteStream, onBytes: @escaping (Int, Bool) -> Void = { _, _ in }) {
    self.first = first
    self.second = second
    self.onBytes = onBytes
  }

  func start(onClose: @escaping () -> Void) {
    self.onClose = onClose
    pump(from: first, to: second)
    pump(from: second, to: first)
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    first.cancel()
    second.cancel()
    onClose?()
    onClose = nil
  }

  private func pump(from source: ByteStream, to destination: ByteStream) {
    source.read(minimum: 1, maximum: 64 * 1024) { [self] data, isComplete, error in
      guard !isClosed else { return }
      if let data, !data.isEmpty {
        onBytes(data.count, source === first)
        destination.write(data) { [self] writeError in
          guard writeError == nil else { return close() }
          isComplete ? finish(destination) : pump(from: source, to: destination)
        }
      } else if isComplete {
        finish(destination)
      } else if error != nil {
        close()
      }
    }
  }

  private func finish(_ destination: ByteStream) {
    destination.writeEOF()
    finishedDirections += 1
    if finishedDirections == 2 { close() }
  }
}
