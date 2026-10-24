import Darwin
import Foundation

/// What the phone's app reports on an event stream, `ProxyEvent` on the server side.
public enum PhoneEvent: UInt8, Sendable {
  case stopped = 0x01
  case terminating = 0x02
}

/// Keeps one event stream open to the phone's proxy, since the phone can't open a connection to
/// the Mac.
public final class PhoneEventListener: @unchecked Sendable {
  public enum Update: Sendable, Equatable {
    /// A running proxy accepted the stream.
    case opened
    case event(PhoneEvent)
    /// An open stream ended: the phone's proxy stopped, its app died, the link went away, or `stop`.
    case closed
  }

  private let lock = NSLock()
  private var isListening = false
  private var isStopped = false
  private var socket: Int32?

  public init() {}

  /// Opens a stream unless one is open already. Does nothing more when the phone's app predates
  /// events; the caller can try again later.
  public func listen(connect: @escaping @Sendable () throws -> Int32, onUpdate: @escaping @Sendable (Update) -> Void) {
    let shouldStart: Bool = lock.withLock {
      guard !isListening else { return false }
      isListening = true
      isStopped = false
      return true
    }
    guard shouldStart else { return }
    DispatchQueue.global().async { [self] in
      let wasOpen = stream(connect: connect, onUpdate: onUpdate)
      lock.withLock { isListening = false }
      if wasOpen { onUpdate(.closed) }
    }
  }

  /// Ends the open stream. A link that disappears without a FIN never wakes the blocked read, so
  /// the caller stops the stream whenever the link it was opened on is no longer the current one.
  public func stop() {
    lock.withLock {
      isStopped = true
      if let socket { shutdown(socket, SHUT_RDWR) }
    }
  }

  /// Returns whether the stream was open before it ended.
  private func stream(connect: () throws -> Int32, onUpdate: (Update) -> Void) -> Bool {
    guard let fd = try? connect() else { return false }
    defer { close(fd) }
    // A `stop` while connecting had no socket to shut down, so the stream would open on a link the
    // caller already left and block the next `listen` for good.
    let wasStopped: Bool = lock.withLock {
      if !isStopped { socket = fd }
      return isStopped
    }
    guard !wasStopped else { return false }
    defer { lock.withLock { socket = nil } }
    guard (try? SOCKS5.openEventStream(fd)) != nil else { return false }
    onUpdate(.opened)
    while let byte = try? SOCKS5.readEvent(fd) {
      if let event = PhoneEvent(rawValue: byte) { onUpdate(.event(event)) }
    }
    return true
  }
}

/// Decides when the Mac should warn that Nothering quit on the iPhone. The phone only announces a
/// clean stop or a swipe-away; a crash or a kill by iOS shows up as its proxy no longer answering
/// while the iPhone itself is still attached.
public struct PhoneQuitDetector: Sendable {
  public private(set) var hasQuit = false
  private var wasStopped = false
  /// The user saw the warning for the current run of the phone's proxy, so a late report of the
  /// same quit (e.g. the link refresh after the stream closed) doesn't raise it again.
  private var wasDismissed = false

  public init() {}

  public mutating func handle(_ update: PhoneEventListener.Update) {
    switch update {
    case .opened:
      // A freshly opened stream means a running proxy, even if it restarted between probes.
      startRun()
    case .event(.stopped):
      wasStopped = true
    case .event(.terminating):
      raise()
    case .closed:
      break
    }
  }

  public mutating func linkChanged(wasReachable: Bool, isReachable: Bool, isPhoneAttached: Bool) {
    if isReachable, !wasReachable {
      startRun()
    } else if wasReachable, !isReachable, !wasStopped, isPhoneAttached {
      raise()
    }
  }

  /// Clears the warning once the user has seen it. The next run that quits raises it again.
  public mutating func dismiss() {
    guard hasQuit else { return }
    hasQuit = false
    wasDismissed = true
  }

  private mutating func startRun() {
    hasQuit = false
    wasStopped = false
    wasDismissed = false
  }

  private mutating func raise() {
    if !wasDismissed { hasQuit = true }
  }
}
