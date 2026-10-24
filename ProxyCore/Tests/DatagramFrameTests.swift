import Foundation
import Network
import Testing
@testable import ProxyCore

@Suite struct DatagramFrameTests {
  @Test(arguments: [
    NWEndpoint.Host.ipv4(IPv4Address("1.2.3.4")!),
    .ipv6(IPv6Address("2001:db8::1")!),
    .name("example.com", nil),
  ])
  func roundTrips(host: NWEndpoint.Host) throws {
    let frame = try #require(DatagramFrame.encode(Data("quic".utf8), host: host, port: 443))
    #expect(Int(frame[0]) << 8 | Int(frame[1]) == frame.count - 2)
    let decoded = try #require(DatagramFrame.decode(body: frame.dropFirst(2)))
    #expect(decoded.host == host)
    #expect(decoded.port == 443)
    #expect(decoded.payload == Data("quic".utf8))
  }

  @Test func rejectsTruncatedAndUnknownFrames() {
    #expect(DatagramFrame.decode(body: Data()) == nil)
    #expect(DatagramFrame.decode(body: Data([0x01, 1, 2, 3, 4, 0])) == nil)
    #expect(DatagramFrame.decode(body: Data([0x03, 5, 0x61, 0x62])) == nil)
    #expect(DatagramFrame.decode(body: Data([0x09, 0, 0])) == nil)
  }

  @Test func decodesBigEndianPortAndPayload() throws {
    let frame = try #require(DatagramFrame.decode(body: Data([0x01, 10, 0, 0, 1, 0x12, 0x34, 0xAA, 0xBB])))
    #expect(frame.host == .ipv4(IPv4Address("10.0.0.1")!))
    #expect(frame.port == 0x1234)
    #expect(frame.payload == Data([0xAA, 0xBB]))
  }

  @Test func decodesEmptyPayload() throws {
    let frame = try #require(DatagramFrame.decode(body: Data([0x04] + [UInt8](repeating: 0, count: 15) + [1, 0, 53])))
    #expect(frame.host == .ipv6(.loopback))
    #expect(frame.port == 53)
    #expect(frame.payload.isEmpty)
  }

  @Test func rejectsMalformedAddresses() {
    #expect(DatagramFrame.decode(body: Data([0x04] + [UInt8](repeating: 0, count: 17))) == nil) // port cut short
    #expect(DatagramFrame.decode(body: Data([0x03])) == nil)
    #expect(DatagramFrame.decode(body: Data([0x03, 0, 0, 53])) == nil) // empty name
    #expect(DatagramFrame.decode(body: Data([0x03, 1, 0x61, 0])) == nil) // port cut short
    #expect(DatagramFrame.decode(body: Data([0x03, 1, 0xFF, 0, 53])) == nil) // not UTF-8
  }

  @Test func encodesNamesOfOneTo255Bytes() {
    #expect(DatagramFrame.encode(Data(), host: .name(String(repeating: "a", count: 255), nil), port: 53) != nil)
    #expect(DatagramFrame.encode(Data(), host: .name(String(repeating: "a", count: 256), nil), port: 53) == nil)
    #expect(DatagramFrame.encode(Data(), host: .name("", nil), port: 53) == nil)
  }

  @Test func rejectsOversizedPayload() {
    #expect(DatagramFrame.encode(Data(count: 65535), host: .ipv4(.loopback), port: 53) == nil)
  }
}
