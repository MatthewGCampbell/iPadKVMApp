// swift-tools-version: 5.9

// Swift Playgrounds app package: opens in Xcode on a Mac, or in Swift Playgrounds on the iPad.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "KVM Remote",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "KVM Remote",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.kvmremote",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .tv),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .localNetwork(purposeString: "KVM Remote connects to your PiKVM or VNC server on your local network.")
            ],
            appCategory: .utilities
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
