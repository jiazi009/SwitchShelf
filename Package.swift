// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwitchShelf",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SwitchShelf", targets: ["SwitchShelfApp"]),
        .executable(name: "switchshelf-probe", targets: ["SwitchShelfProbe"]),
        .executable(name: "switchshelf-backend", targets: ["SwitchShelfBackendCLI"]),
        .library(name: "SwitchShelfDomain", targets: ["SwitchShelfDomain"]),
        .library(name: "SwitchShelfLibrary", targets: ["SwitchShelfLibrary"]),
        .library(name: "SwitchShelfDevice", targets: ["SwitchShelfDevice"]),
        .library(name: "SwitchShelfBackend", targets: ["SwitchShelfBackend"]),
        .library(name: "SwitchShelfBackendInstall", targets: ["SwitchShelfBackendInstall"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: nil),
        .target(name: "CDBIBridge", publicHeadersPath: "include"),
        .target(name: "CDBIBackendUSB", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "SwitchShelfDomain"),
        .target(name: "SwitchShelfLibrary", dependencies: ["SwitchShelfDomain", "CSQLite"]),
        .target(name: "SwitchShelfDevice", dependencies: ["SwitchShelfDomain", "CDBIBridge"]),
        .target(name: "SwitchShelfBackend", dependencies: ["CDBIBackendUSB"]),
        .target(name: "SwitchShelfBackendInstall", dependencies: ["SwitchShelfBackend", "SwitchShelfDevice", "SwitchShelfDomain"]),
        .executableTarget(name: "SwitchShelfApp", dependencies: ["SwitchShelfDomain", "SwitchShelfLibrary", "SwitchShelfDevice", "SwitchShelfBackend"]),
        .executableTarget(name: "SwitchShelfProbe", dependencies: ["SwitchShelfDomain", "SwitchShelfDevice"]),
        .executableTarget(name: "SwitchShelfBackendCLI", dependencies: ["SwitchShelfBackendInstall", "SwitchShelfDevice"]),
        .testTarget(name: "SwitchShelfDomainTests", dependencies: ["SwitchShelfDomain"]),
        .testTarget(name: "SwitchShelfLibraryTests", dependencies: ["SwitchShelfLibrary"]),
        .testTarget(name: "SwitchShelfDeviceTests", dependencies: ["SwitchShelfDevice"]),
        .testTarget(name: "SwitchShelfBackendTests", dependencies: ["SwitchShelfBackend", "CDBIBackendUSB"]),
        .testTarget(name: "SwitchShelfBackendInstallTests", dependencies: ["SwitchShelfBackendInstall", "SwitchShelfBackend"]),
    ]
)

