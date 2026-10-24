import Darwin
import Foundation
import PhoneLink
import ProxyCore
import Testing

@Suite struct PhoneQuitDetectorTests {
  @Test func clearsSwipeAwayWhenTheAppRelaunchesBetweenProbes() {
    var detector = PhoneQuitDetector()
    detector.handle(.opened)
    detector.handle(.event(.terminating))
    detector.handle(.closed)
    detector.linkChanged(wasReachable: true, isReachable: true, isPhoneAttached: true)
    #expect(detector.hasQuit)

    detector.handle(.opened)
    #expect(!detector.hasQuit)
  }

  @Test func reportsHardKillAfterAStopAndQuickRestart() {
    var detector = PhoneQuitDetector()
    detector.handle(.opened)
    detector.handle(.event(.stopped))
    detector.handle(.closed)
    detector.linkChanged(wasReachable: true, isReachable: true, isPhoneAttached: true)
    detector.handle(.opened)

    detector.handle(.closed)
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    #expect(detector.hasQuit)
  }

  @Test func staysQuietWhenTheUserStopsTheProxy() {
    var detector = PhoneQuitDetector()
    detector.handle(.opened)
    detector.handle(.event(.stopped))
    detector.handle(.closed)
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    #expect(!detector.hasQuit)
  }

  @Test(arguments: [(true, true), (false, false)])
  func reportsSilentProxyOnlyWhileThePhoneIsAttached(isPhoneAttached: Bool, hasQuit: Bool) {
    var detector = PhoneQuitDetector()
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: isPhoneAttached)
    #expect(detector.hasQuit == hasQuit)
  }

  @Test func clearsWhenAnOldPhoneAppAnswersAgain() {
    var detector = PhoneQuitDetector()
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    detector.linkChanged(wasReachable: false, isReachable: true, isPhoneAttached: true)
    #expect(!detector.hasQuit)
  }

  @Test func staysDismissedUntilTheNextQuit() {
    var detector = PhoneQuitDetector()
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    detector.dismiss()
    detector.linkChanged(wasReachable: false, isReachable: false, isPhoneAttached: true)
    #expect(!detector.hasQuit)

    detector.linkChanged(wasReachable: false, isReachable: true, isPhoneAttached: true)
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    #expect(detector.hasQuit)
  }

  @Test func ignoresALateLinkLossForADismissedSwipeAway() {
    var detector = PhoneQuitDetector()
    detector.handle(.opened)
    detector.handle(.event(.terminating))
    detector.handle(.closed)
    detector.dismiss()
    detector.linkChanged(wasReachable: true, isReachable: false, isPhoneAttached: true)
    #expect(!detector.hasQuit)

    detector.linkChanged(wasReachable: false, isReachable: true, isPhoneAttached: true)
    detector.handle(.opened)
    detector.handle(.event(.terminating))
    #expect(detector.hasQuit)
  }

  @Test func dismissingWithoutAWarningDoesNotHideTheNextQuit() {
    var detector = PhoneQuitDetector()
    detector.handle(.opened)
    detector.dismiss()
    detector.handle(.event(.terminating))
    #expect(detector.hasQuit)
  }

  @Test func matchesTheServerEventBytes() {
    #expect(PhoneEvent.stopped.rawValue == ProxyEvent.stopped.rawValue)
    #expect(PhoneEvent.terminating.rawValue == ProxyEvent.terminating.rawValue)
  }
}

@Suite struct PhoneEventListenerTests {
  @Test func movesToANewLinkWhenTheOldStreamNeverEnds() async throws {
    let oldLink = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
    let oldPort = try await oldLink.start().rawValue
    defer { oldLink.stop() }
    let newLink = ProxyServer(configuration: .init(port: .any, requiredInterfaceType: nil))
    let newPort = try await newLink.start().rawValue
    defer { newLink.stop() }
    let listener = PhoneEventListener()
    let (updates, continuation) = AsyncStream.makeStream(of: PhoneEventListener.Update.self)
    var iterator = updates.makeAsyncIterator()

    listener.listen(connect: { try TCP.connect(host: "127.0.0.1", port: oldPort) }) { continuation.yield($0) }
    #expect(await iterator.next() == .opened)
    listener.stop()
    #expect(await iterator.next() == .closed)

    listener.listen(connect: { try TCP.connect(host: "127.0.0.1", port: newPort) }) { continuation.yield($0) }
    #expect(await iterator.next() == .opened)
    newLink.send(.terminating)
    #expect(await iterator.next() == .event(.terminating))
  }

  /// A `stop` while the link was still connecting used to be lost: the stream opened on the old link
  /// anyway and, never ending, kept `listen` from moving to the new one.
  @Test func abandonsAStreamStoppedWhileConnecting() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let (phone, proxy) = (fds[0], fds[1])
    defer { close(proxy) }
    // The proxy's replies to the greeting and the event request, sent ahead of time.
    let replies: [UInt8] = [0x05, 0x00, 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    #expect(write(proxy, replies, replies.count) == replies.count)
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(proxy, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let connecting = DispatchSemaphore(value: 0)
    let connected = DispatchSemaphore(value: 0)
    let updates = RecordedUpdates()
    let listener = PhoneEventListener()
    listener.listen(connect: {
      connecting.signal()
      connected.wait()
      return phone
    }) { updates.append($0) }
    connecting.wait()
    listener.stop()
    connected.signal()

    // Closed without a greeting, rather than greeted and held open.
    var greeting = [UInt8](repeating: 0, count: 3)
    #expect(read(proxy, &greeting, greeting.count) == 0)
    #expect(updates.values.isEmpty)
  }
}

private final class RecordedUpdates: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [PhoneEventListener.Update] = []
  var values: [PhoneEventListener.Update] { lock.withLock { storage } }
  func append(_ value: PhoneEventListener.Update) { lock.withLock { storage.append(value) } }
}
