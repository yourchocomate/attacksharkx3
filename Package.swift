// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "asctl",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "asctl",
            path: "Sources/asctl",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreBluetooth"),
                // CoreBluetooth requires a usage description or the process is
                // aborted with SIGABRT. CLI binaries have no bundle, so the
                // plist is embedded into the executable's __TEXT section.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/asctl/Info.plist",
                ]),
            ]
        )
    ]
)
