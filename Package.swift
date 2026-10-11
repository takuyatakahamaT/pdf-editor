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
    targets: [
        .executableTarget(
            name: "PDFTextEditor",
            path: "Sources/PDFTextEditor"
        ),
        .testTarget(
            name: "PDFTextEditorTests",
            dependencies: ["PDFTextEditor"],
            path: "Tests/PDFTextEditorTests"
        )
    ]
)
