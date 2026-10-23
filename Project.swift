import ProjectDescription

let teamID = "N2C267LBVY"
let bundleIDPrefix = "app.nothering"

// Each configuration gets its own bundle IDs so Debug, Development and Production builds install side by side.
let configurations: [Configuration] = [
  .debug(name: "Debug", settings: [
    "BUNDLE_ID_PREFIX": "\(bundleIDPrefix).debug",
    "INSTALL_NAME": "Nothering Debug",
    "APP_ICON": "AppIcon-Debug",
  ]),
  .release(name: "Development", settings: [
    "BUNDLE_ID_PREFIX": "\(bundleIDPrefix).dev",
    "INSTALL_NAME": "Nothering Dev",
    "APP_ICON": "AppIcon-Dev",
  ]),
  .release(name: "Production", settings: [
    "BUNDLE_ID_PREFIX": .string(bundleIDPrefix),
    "INSTALL_NAME": "Nothering",
    "APP_ICON": "AppIcon",
  ]),
]

let baseSettings: SettingsDictionary = [
  "DEVELOPMENT_TEAM": .string(teamID),
  "CODE_SIGN_STYLE": "Automatic",
  "SWIFT_VERSION": "5.0",
]

let version: [String: Plist.Value] = [
  "CFBundleShortVersionString": "0.4.0",
  "CFBundleVersion": .string(Environment.buildNumber.getString(default: "1")),
]

// Each configuration picks its icon through APP_ICON, so Debug and Development builds are told apart at a glance.
let appIcons: [ResourceFileElement] = ["Shared/AppIcon.icon", "Shared/AppIcon-Debug.icon", "Shared/AppIcon-Dev.icon"]
let appIcon: SettingsDictionary = ["ASSETCATALOG_COMPILER_APPICON_NAME": "$(APP_ICON)"]

let hardenedRuntime: SettingsDictionary = ["ENABLE_HARDENED_RUNTIME": "YES"]

// Static frameworks are linked into the apps and never signed on their own.
let unsigned: SettingsDictionary = ["CODE_SIGNING_ALLOWED": "NO"]

let localNetworkUsage: [String: Plist.Value] = [
  "NSLocalNetworkUsageDescription": "Nothering accepts proxy connections from devices on your Personal Hotspot.",
]

// Sparkle reads the newest release's appcast.xml, attached to every GitHub Release by fastlane.
let sparkle: [String: Plist.Value] = [
  "SUFeedURL": "https://github.com/devxoul/nothering/releases/latest/download/appcast.xml",
  "SUPublicEDKey": "Ks/eJWVB8/QBEaOubJWsIiTag+a2oDyxScuqZIcSrV8=",
  "SUEnableAutomaticChecks": true,
]

let project = Project(
  name: "Nothering",
  packages: [
    .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .upToNextMajor(from: "2.10.0")),
  ],
  settings: .settings(base: baseSettings, configurations: configurations, defaultSettings: .recommended),
  targets: [
    .target(
      name: "ProxyCore",
      destinations: [.iPhone, .mac],
      product: .staticFramework,
      bundleId: "\(bundleIDPrefix).proxycore",
      deploymentTargets: .multiplatform(iOS: "18.0", macOS: "15.0"),
      sources: ["ProxyCore/Sources/**"],
      settings: .settings(base: unsigned)
    ),
    .target(
      name: "ProxyCoreTests",
      destinations: [.mac],
      product: .unitTests,
      bundleId: "\(bundleIDPrefix).proxycore.tests",
      deploymentTargets: .macOS("15.0"),
      sources: ["ProxyCore/Tests/**"],
      dependencies: [.target(name: "ProxyCore")]
    ),
    .target(
      name: "NotheringiOS",
      destinations: [.iPhone],
      product: .app,
      productName: "Nothering",
      bundleId: "$(BUNDLE_ID_PREFIX).ios",
      deploymentTargets: .iOS("18.0"),
      infoPlist: .extendingDefault(with: version.merging(localNetworkUsage) { $1 }.merging([
        "CFBundleDisplayName": "Nothering",
        "UILaunchScreen": [:],
        "UIBackgroundModes": ["audio"],
        "ITSAppUsesNonExemptEncryption": false,
      ]) { $1 }),
      sources: ["iOS/App/**"],
      resources: .resources(appIcons + ["iOS/Resources/**"]),
      dependencies: [.target(name: "ProxyCore")],
      settings: .settings(base: appIcon)
    ),
    .target(
      name: "PhoneLink",
      destinations: [.mac],
      product: .staticFramework,
      bundleId: "\(bundleIDPrefix).phonelink",
      deploymentTargets: .macOS("15.0"),
      sources: ["PhoneLink/Sources/**"],
      settings: .settings(base: unsigned)
    ),
    .target(
      name: "PhoneLinkTests",
      destinations: [.mac],
      product: .unitTests,
      bundleId: "\(bundleIDPrefix).phonelink.tests",
      deploymentTargets: .macOS("15.0"),
      sources: ["PhoneLink/Tests/**"],
      dependencies: [.target(name: "PhoneLink"), .target(name: "ProxyCore")]
    ),
    .target(
      name: "NotheringMac",
      destinations: [.mac],
      product: .commandLineTool,
      productName: "nothering",
      bundleId: "\(bundleIDPrefix).cli",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: version),
      sources: ["Mac/Sources/**"],
      dependencies: [.target(name: "ProxyCore"), .target(name: "PhoneLink")],
      settings: .settings(base: hardenedRuntime)
    ),
    .target(
      name: "NotheringMenuBar",
      destinations: [.mac],
      product: .app,
      productName: "Nothering",
      bundleId: "$(BUNDLE_ID_PREFIX).mac",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: version.merging([
        "CFBundleDisplayName": "Nothering",
        "LSUIElement": true,
        // The app copies itself to /Applications under this name, so each configuration installs side by side.
        "NotheringInstallName": "$(INSTALL_NAME)",
        "CFBundleURLTypes": [["CFBundleURLName": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleURLSchemes": ["nothering"]]],
      ]) { $1 }.merging(sparkle) { $1 }),
      sources: ["MacApp/Sources/**"],
      resources: .resources(["MacApp/Resources/**"] + appIcons),
      entitlements: "MacApp/App.entitlements",
      // The proxy extension is not a target dependency: Xcode would embed it under a path resolved with the Debug
      // configuration only, while macOS requires its file name to match the per-configuration bundle ID. The
      // NotheringMenuBar scheme builds it first and this script embeds it before the app is signed.
      scripts: [
        .post(
          script: #"""
          dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/SystemExtensions"
          mkdir -p "$dir"
          rm -rf "$dir"/*.systemextension
          ditto "$BUILT_PRODUCTS_DIR/$BUNDLE_ID_PREFIX.mac.proxy.systemextension" "$dir/$BUNDLE_ID_PREFIX.mac.proxy.systemextension"
          """#,
          name: "Embed System Extension",
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: [
        .target(name: "ProxyCore"),
        .target(name: "PhoneLink"),
        .package(product: "Sparkle"),
      ],
      settings: .settings(base: hardenedRuntime.merging(appIcon) { $1 }.merging([
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
      ]) { $1 })
    ),
    .target(
      name: "NotheringProxyExtension",
      destinations: [.mac],
      product: .systemExtension,
      productName: "$(BUNDLE_ID_PREFIX).mac.proxy",
      bundleId: "$(BUNDLE_ID_PREFIX).mac.proxy",
      deploymentTargets: .macOS("15.0"),
      infoPlist: .extendingDefault(with: version.merging([
        "NSSystemExtensionUsageDescription": "Nothering routes your Mac's network connections through your iPhone.",
        "NetworkExtension": [
          "NEMachServiceName": "$(TeamIdentifierPrefix)$(BUNDLE_ID_PREFIX).mac.proxy",
          "NEProviderClasses": [
            "com.apple.networkextension.app-proxy": "$(PRODUCT_MODULE_NAME).TransparentProxyProvider",
            "com.apple.networkextension.dns-proxy": "$(PRODUCT_MODULE_NAME).DNSProxyProvider",
          ],
        ],
      ]) { $1 }),
      sources: ["MacProxy/Sources/**"],
      entitlements: "MacProxy/Proxy.entitlements",
      scripts: [
        .post(
          script: #"/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$TARGET_BUILD_DIR/$INFOPLIST_PATH""#,
          name: "Stamp Build Version",
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: [.target(name: "PhoneLink"), .target(name: "ProxyCore")],
      settings: .settings(base: hardenedRuntime.merging([
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "PRODUCT_MODULE_NAME": "NotheringProxyExtension",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        // Embedded by NotheringMenuBar's script, so archives don't carry it as a separate product.
        "SKIP_INSTALL": "YES",
      ]) { $1 })
    ),
    .target(
      name: "NotheringProxyExtensionTests",
      destinations: [.mac],
      product: .unitTests,
      bundleId: "\(bundleIDPrefix).mac.proxy.tests",
      deploymentTargets: .macOS("15.0"),
      // A system extension can't host tests, so its sources are compiled in, minus the entry point.
      sources: ["MacProxy/Tests/**", .glob("MacProxy/Sources/**", excluding: ["MacProxy/Sources/main.swift"])],
      dependencies: [.target(name: "PhoneLink"), .target(name: "ProxyCore")]
    ),
  ],
  schemes: [
    .scheme(
      name: "NotheringMenuBar",
      buildAction: .buildAction(targets: ["NotheringProxyExtension", "NotheringMenuBar"], buildOrder: .manual),
      runAction: .runAction(configuration: "Debug", executable: "NotheringMenuBar"),
      archiveAction: .archiveAction(configuration: "Production"),
      profileAction: .profileAction(configuration: "Production", executable: "NotheringMenuBar"),
      analyzeAction: .analyzeAction(configuration: "Debug")
    ),
  ]
)
