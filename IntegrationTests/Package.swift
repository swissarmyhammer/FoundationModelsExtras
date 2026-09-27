// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// The real-model tests. This is a separate package, and the root manifest does
// not name it. Thus the package boundary divides the tests:
//
//     swift test                                   # unit tests, at the root
//     swift test --package-path IntegrationTests   # real models, this package
//
// Nothing reads an environment variable to select tests.
//
// Only this package depends on MLX. The core target of the root package stays
// free of MLX. The MLX pins are the pins of the FoundationModelsRouter
// integration package, so the two packages resolve the same MLX code.

let extrasPackage = "FoundationModelsExtras"
let mlxPackage = "mlx-swift-lm"
let huggingFacePackage = "swift-huggingface"
let transformersPackage = "swift-transformers"
let ulidPackage = "ULID.swift"

let package = Package(
    name: "IntegrationTests",
    // The same floor as the root package.
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: ".."),
        // The controlled fork of mlx-swift-lm.
        .package(url: "https://github.com/swissarmyhammer/\(mlxPackage)", branch: "stable"),
        .package(url: "https://github.com/huggingface/\(huggingFacePackage)", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/\(transformersPackage)", from: "1.3.0"),
        // The session id of a `ModelCallMark` is a ULID. The same floor as the
        // root package.
        .package(url: "https://github.com/yaslab/\(ulidPackage).git", from: "1.3.1"),
    ],
    targets: [
        .testTarget(
            name: "\(extrasPackage)IntegrationTests",
            dependencies: [
                .product(name: extrasPackage, package: extrasPackage),
                // `MLXLLM` and `MLXEmbedders` register the model factories.
                // `MLXFoundationModels` gives the LLM as a FoundationModels
                // `LanguageModel`.
                .product(name: "MLXLMCommon", package: mlxPackage),
                .product(name: "MLXLLM", package: mlxPackage),
                .product(name: "MLXEmbedders", package: mlxPackage),
                .product(name: "MLXFoundationModels", package: mlxPackage),
                // The Hugging Face hub client and the tokenizer loader.
                .product(name: "MLXHuggingFace", package: mlxPackage),
                .product(name: "HuggingFace", package: huggingFacePackage),
                .product(name: "Tokenizers", package: transformersPackage),
                .product(name: "ULID", package: ulidPackage),
            ],
            path: "Tests/\(extrasPackage)IntegrationTests"
        )
    ]
)
