// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FreeSound",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "FreeSound", targets: ["FreeSound"])],
    targets: [
        .target(name: "AudioDSP", publicHeadersPath: "include"),
        .executableTarget(
            name: "FreeSound",
            dependencies: ["AudioDSP"],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AppKit")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
