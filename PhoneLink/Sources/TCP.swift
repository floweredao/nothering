import Darwin
import Foundation

public enum TCP {
  public static func connect(host: String, port: UInt16, timeout: TimeInterval = 5) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_NUMERICSERV
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
      throw LinkError("cannot resolve \(host)")
    }
    defer { freeaddrinfo(result) }

    // A name can resolve to an address that doesn't answer before one that does (e.g. ::1 ahead of
    // 127.0.0.1, or a phone's link-local IPv6 ahead of its IPv4), so try each in turn.
    var lastError: Error = LinkError("cannot resolve \(host)")
    for info in sequence(first: first, next: { $0.pointee.ai_next }) {
      do {
        return try connect(to: info.pointee, host: host, timeout: timeout)
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  private static func connect(to info: addrinfo, host: String, timeout: TimeInterval) throws -> Int32 {
    let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
    guard fd >= 0 else { throw LinkError("socket: \(String(cString: strerror(errno)))") }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    if Darwin.connect(fd, info.ai_addr, info.ai_addrlen) != 0, errno != EINPROGRESS {
      let message = String(cString: strerror(errno))
      Darwin.close(fd)
      throw LinkError("connect \(host): \(message)")
    }
    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard poll(&pollFD, 1, Int32(timeout * 1000)) == 1,
          getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0
    else {
      Darwin.close(fd)
      throw LinkError("connect \(host): \(socketError == 0 ? "timed out" : String(cString: strerror(socketError)))")
    }
    _ = fcntl(fd, F_SETFL, flags)
    return fd
  }
}
