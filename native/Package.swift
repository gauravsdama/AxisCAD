// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AxisCAD",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AxisCAD", targets: ["AxisCAD"])],
    targets: [
        .executableTarget(name: "AxisCAD", path: "Sources/AxisCAD", resources: [.process("Resources")]),
        .testTarget(name: "AxisCADTests", dependencies: ["AxisCAD"], path: "Tests/AxisCADTests")
    ],
    swiftLanguageVersions: [.v5]
)
