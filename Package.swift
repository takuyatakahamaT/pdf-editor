// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PDFTextEditor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PDFTextEditor", targets: ["PDFTextEditor"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "PDFTextEditor",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/PDFTextEditor",
            resources: [.copy("Resources/Fonts")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "PDFTextEditorTests",
            dependencies: ["PDFTextEditor"],
            path: "Tests/PDFTextEditorTests"
        )
    ]
)
