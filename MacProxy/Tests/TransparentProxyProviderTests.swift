import Testing

@Suite struct TransparentProxyProviderTests {
  @Test(arguments: [
    ("io.tailscale.ipn.macsys.network-extension", true),
    ("io.tailscale.ipn.macos.network-extension", true),
    ("com.example.vpn.NetworkExtension", true),
    ("com.example.vpn.PacketTunnel.systemextension", true),
    ("com.apple.Safari", false),
    ("io.tailscale.ipn.macsys", false),
    ("com.example.networking", false),
  ])
  func detectsNetworkExtensions(identifier: String, expected: Bool) {
    #expect(TransparentProxyProvider.isNetworkExtension(identifier) == expected)
  }

  @Test(arguments: [
    ("io.tailscale.ipn.macsys.network-extension", true),
    ("IO.Tailscale.IPN.macos.network-extension", true),
    ("io.tailscale.ipn", false),
    ("io.tailscale.ipnext.network-extension", false),
    ("com.example.io.tailscale.ipn.network-extension", false),
  ])
  func detectsTailscale(identifier: String, expected: Bool) {
    #expect(TransparentProxyProvider.isTailscale(identifier) == expected)
  }
}
