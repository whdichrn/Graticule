// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Graticule",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Graticule", targets: ["Graticule"])
    ],
    targets: [
        .executableTarget(
            name: "Graticule",
            path: "Sources/Graticule"
        ),
        .testTarget(
            name: "GraticuleTests",
            dependencies: ["Graticule"],
            path: "Tests/GraticuleTests"
        )
    ]
)
