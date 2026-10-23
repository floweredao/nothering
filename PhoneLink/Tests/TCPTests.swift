import Darwin
import Foundation
import PhoneLink
import Testing

@Suite struct TCPTests {
  /// `localhost` resolves to both ::1 and 127.0.0.1. Whichever comes first, a server listening on
  /// only the other one must still be reached instead of failing on the first address.
  @Test(arguments: [AF_INET, AF_INET6])
  func reachesAnyAddressOfAName(family: Int32) throws {
    let server = try listenOnLoopback(family: family)
    defer { close(server.fd) }
    let fd = try TCP.connect(host: "localhost", port: server.port, timeout: 2)
    close(fd)
  }
}

/// A listening socket on the loopback address of `family` only.
private func listenOnLoopback(family: Int32) throws -> (fd: Int32, port: UInt16) {
  let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
  guard fd >= 0 else { throw LinkError("socket failed") }
  var storage = sockaddr_storage()
  let size: Int
  if family == AF_INET6 {
    var address = sockaddr_in6()
    size = MemoryLayout<sockaddr_in6>.size
    address.sin6_len = UInt8(size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_addr = in6addr_loopback
    withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: address) { Array($0) }) }
  } else {
    var address = sockaddr_in()
    size = MemoryLayout<sockaddr_in>.size
    address.sin_len = UInt8(size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: address) { Array($0) }) }
  }
  var length = socklen_t(size)
  let bound = withUnsafeMutablePointer(to: &storage) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(size)) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
    }
  }
  guard bound else {
    close(fd)
    throw LinkError("loopback listen failed")
  }
  // `sin_port` and `sin6_port` both sit at offset 2, in network byte order.
  let bytes = withUnsafeBytes(of: storage) { Array($0.prefix(4)) }
  return (fd, UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
}
