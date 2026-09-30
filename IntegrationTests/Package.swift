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
// The tests load each model with `MLXModelLoader`, the built-in loader of the
// core, thus this package names only the products that a test file imports.
// The MLX pins are the pins of the root package and of the
// FoundationModelsRouter integration package, so the packages resolve the
// same MLX code.

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
        // The same floor as the root package.
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
                // The `@Operation` macro and `OperationTool`. The tool-hosting
                // suite mounts one `OperationTool` under a real model session.
                .product(name: "Operations", package: extrasPackage),
                // `MLXLanguageModel`: a pool test reads the model of the
                // container of a hold. This product also gives the `MLX`
                // module, whose active memory counter the memory checks read.
                .product(name: "MLXFoundationModels", package: mlxPackage),
                // `HubCache`: the memory checks measure the weight files in the
                // Hugging Face cache without the loader.
                .product(name: "HuggingFace", package: huggingFacePackage),
                // The tokenizer loader test wraps `#huggingFaceTokenizerLoader()`:
                // `MLXLMCommon` gives the `TokenizerLoader` protocol,
                // `MLXHuggingFace` gives the macro, and the macro expands to
                // `Tokenizers.AutoTokenizer`.
                .product(name: "MLXLMCommon", package: mlxPackage),
                .product(name: "MLXHuggingFace", package: mlxPackage),
                .product(name: "Tokenizers", package: transformersPackage),
                .product(name: "ULID", package: ulidPackage),
            ],
            path: "Tests/\(extrasPackage)IntegrationTests"
        )
    ]
)
