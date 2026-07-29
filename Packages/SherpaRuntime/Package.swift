// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SherpaRuntime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SherpaRuntime", targets: ["SherpaRuntime"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/csukuangfj/onnxruntime-libs",
            revision: "f6b9fbb2295e74ce3aecc0fec48047dfc30d4ca9"
        )
    ],
    targets: [
        .binaryTarget(
            name: "SherpaOnnxC",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.4/sherpa-onnx-v1.13.4-macos.xcframework.zip",
            checksum: "4325d8aed99b94be58969005b19f9626f3f3afc4ebd42378b0aad2b84e233552"
        ),
        .target(
            name: "SherpaRuntime",
            dependencies: [
                "SherpaOnnxC",
                .product(name: "onnxruntime-macos", package: "onnxruntime-libs")
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreML")
            ]
        )
    ]
)
