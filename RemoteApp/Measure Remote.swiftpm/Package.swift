// swift-tools-version: 5.9

// The iPad remote for Measure. Open this folder in Xcode (or Swift Playgrounds on a Mac), choose
// your iPad as the run destination and press Run. The screens live in the main package's
// MeasureRemoteUI library, two folders up.

import AppleProductTypes
import PackageDescription

let package = Package(
    name: "Measure Remote",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Measure Remote",
            targets: ["AppModule"],
            bundleIdentifier: "local.measure.remote",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .mic),
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
                .localNetwork(
                    purposeString: "Measure Remote finds and controls Measure on your Mac over the local network.",
                    bonjourServiceTypes: ["_measure-remote._tcp"]
                )
            ]
        )
    ],
    dependencies: [
        .package(name: "Measure", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [
                .product(name: "MeasureRemoteUI", package: "Measure")
            ],
            path: "."
        )
    ]
)
