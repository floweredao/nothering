import Darwin
import Foundation
import PhoneLink
import Testing

private func query(_ name: String) -> Data {
  var message: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
  for label in name.split(separator: ".") {
    message.append(UInt8(label.utf8.count))
    message += Array(label.utf8)
  }
  return Data(message + [0, 0x00, 0x01, 0x00, 0x01])
}

@Suite struct DNSTests {
  @Test func readsQueryName() {
    #expect(DNS.queryName(query("WWW.Example.com")) == "www.example.com")
    #expect(DNS.queryName(Data([0x12, 0x34])) == nil)
  }

  @Test func rejectsMalformedQueries() {
    let header: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    var noQuestion = [UInt8](query("example.com"))
    noQuestion[5] = 0
    #expect(DNS.queryName(Data(noQuestion)) == nil)
    #expect(DNS.queryName(Data(header)) == nil)
    #expect(DNS.queryName(Data(header + [5, 0x61, 0x62])) == nil) // label runs past the end
    #expect(DNS.queryName(Data(header + [1, 0x61])) == nil) // no root label
    #expect(DNS.queryName(Data(header + [0xC0, 0x0C, 0, 1, 0, 1])) == nil) // compression pointer
  }

  @Test(arguments: [
    ("my-mac", true),
    ("my-mac.tail1234.ts.net", true),
    ("github.com", false),
    ("tsnet.example.com", false),
  ])
  func classifiesTailscaleNames(name: String, isTailscale: Bool) {
    #expect(DNS.isTailscaleName(name) == isTailscale)
  }

  @Test func exchangesOverTCPFraming() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { fds.forEach { close($0) } }
    let request = query("example.com")
    let response = Data([0xAB, 0xCD, 0xEF])

    Thread.detachNewThread {
      var header = [UInt8](repeating: 0, count: 2)
      _ = read(fds[1], &header, 2)
      var body = [UInt8](repeating: 0, count: Int(header[0]) << 8 | Int(header[1]))
      _ = read(fds[1], &body, body.count)
      if Data(body) == request {
        let reply: [UInt8] = [0x00, 0x03, 0xAB, 0xCD, 0xEF]
        _ = write(fds[1], reply, reply.count)
      }
    }
    #expect(try DNS.exchangeOverTCP(fds[0], query: request) == response)
  }
}
