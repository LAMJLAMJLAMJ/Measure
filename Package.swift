// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Measure",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MeasureDSP", targets: ["MeasureDSP"]),
        .library(name: "MeasureAudio", targets: ["MeasureAudio"]),
        .executable(name: "measure-cli", targets: ["measure-cli"]),
        .executable(name: "Measure", targets: ["Measure"]),
    ],
    targets: [
        // Signal processing and acoustics. No UI and no audio hardware, so it can be tested on its own.
        .target(name: "MeasureDSP"),
        // Core Audio device list and sweep playback/recording. macOS only; empty elsewhere.
        .target(name: "MeasureAudio", dependencies: ["MeasureDSP"]),
        // Command-line front end for analysing files, generating sweeps and measuring.
        .executableTarget(name: "measure-cli", dependencies: ["MeasureDSP", "MeasureAudio"]),
        // The Mac app (SwiftUI). Run with `swift run Measure` or bundle with scripts/build-app.sh.
        .executableTarget(name: "Measure", dependencies: ["MeasureDSP", "MeasureAudio"]),
        .testTarget(name: "MeasureDSPTests", dependencies: ["MeasureDSP"]),
    ]
)
