import Network
import Testing

@Suite struct DNSRelayTests {
  @Test func addressStringOfNamesAndAddresses() {
    #expect(NWEndpoint.Host.name("example.com", nil).addressString == "example.com")
    #expect(NWEndpoint.Host.ipv4(IPv4Address("192.0.2.1")!).addressString == "192.0.2.1")
    #expect(NWEndpoint.Host.ipv6(IPv6Address("2001:db8::1")!).addressString == "2001:db8::1")
  }

  /// A link-local DNS server is only reachable through its interface, so the scope must survive.
  @Test func addressStringKeepsIPv6Scope() throws {
    let address = try #require(IPv6Address("fe80::1%lo0"))
    #expect(NWEndpoint.Host.ipv6(address).addressString == "fe80::1%lo0")
  }
}
