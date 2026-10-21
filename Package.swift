// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Measure",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MeasureDSP", targets: ["MeasureDSP"]),
        .executable(name: "measure-cli", targets: ["measure-cli"]),
    ],
    targets: [
        // Signal processing and acoustics. No UI and no audio hardware, so it can be tested on its own.
        .target(name: "MeasureDSP"),
        // Command-line front end for analysing files and generating sweeps.
        .executableTarget(name: "measure-cli", dependencies: ["MeasureDSP"]),
        .testTarget(name: "MeasureDSPTests", dependencies: ["MeasureDSP"]),
    ]
)
