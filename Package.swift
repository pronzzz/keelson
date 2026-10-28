// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Keelson",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Keelson",
            path: "Sources/Keelson",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("DiskArbitration"),
            ]
        )
    ]
)
