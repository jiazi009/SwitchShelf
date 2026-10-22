// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwitchShelf",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SwitchShelf", targets: ["SwitchShelfApp"]),
        .executable(name: "switchshelf-probe", targets: ["SwitchShelfProbe"]),
        .library(name: "SwitchShelfDomain", targets: ["SwitchShelfDomain"]),
        .library(name: "SwitchShelfLibrary", targets: ["SwitchShelfLibrary"]),
        .library(name: "SwitchShelfDevice", targets: ["SwitchShelfDevice"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: nil),
        .target(name: "CDBIBridge", publicHeadersPath: "include"),
        .target(name: "SwitchShelfDomain"),
        .target(name: "SwitchShelfLibrary", dependencies: ["SwitchShelfDomain", "CSQLite"]),
        .target(name: "SwitchShelfDevice", dependencies: ["SwitchShelfDomain", "CDBIBridge"]),
        .executableTarget(name: "SwitchShelfApp", dependencies: ["SwitchShelfDomain", "SwitchShelfLibrary", "SwitchShelfDevice"]),
        .executableTarget(name: "SwitchShelfProbe", dependencies: ["SwitchShelfDomain", "SwitchShelfDevice"]),
        .testTarget(name: "SwitchShelfDomainTests", dependencies: ["SwitchShelfDomain"]),
        .testTarget(name: "SwitchShelfLibraryTests", dependencies: ["SwitchShelfLibrary"]),
        .testTarget(name: "SwitchShelfDeviceTests", dependencies: ["SwitchShelfDevice"]),
    ]
)

