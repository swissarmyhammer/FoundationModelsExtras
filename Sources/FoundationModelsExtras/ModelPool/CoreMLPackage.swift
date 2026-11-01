import CoreML
import Foundation
import MLXLMCommon

/// The files of a Core ML model in a Hugging Face snapshot: where the model
/// package is, which files hold its weights, and where the compiled form of
/// the package is kept. These are plain file-system steps, thus a unit test
/// needs no model.
enum CoreMLPackage {
    /// The file extension of a Core ML model package folder.
    static let packageExtension = "mlpackage"

    /// The name of the folder that holds the weights inside a model package.
    private static let weightsFolderName = "weights"

    /// The file extension of a weight file inside a model package.
    private static let weightFileExtension = "bin"

    /// The name of the folder of the cache folder that holds the compiled
    /// models. It is not a repository folder of the Hugging Face cache, thus
    /// no snapshot is changed.
    static let compiledFolderName = "coreml-compiled"

    /// The name of a compiled model inside its commit folder.
    static let compiledModelName = "model.mlmodelc"

    /// The file patterns of a download: the files of each model package, and
    /// the files of the tokenizer. A pattern matches like `fnmatch` with no
    /// flags, thus `*` also matches a `/`. The download does not fetch
    /// conversion scripts or documents.
    ///
    /// Each package pattern ends in a file extension. The file list of the Hub
    /// holds the folders of a package too, and the Hub gives a 404 when the
    /// download asks for a folder. A pattern such as `*.mlpackage/*` matches
    /// those folders, thus the patterns name the extensions of the files of a
    /// package: the manifest, the model description and the weights.
    static let downloadPatterns =
        packageFileExtensions.map { "*.\(packageExtension)/*.\($0)" } + [
            "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
        ]

    /// The extensions of the files inside a model package.
    private static let packageFileExtensions = ["json", "mlmodel", "bin"]

    /// Finds the model package in a snapshot folder. This reads the top level
    /// of the folder only, and takes the one package that it holds.
    ///
    /// - Parameters:
    ///   - snapshot: The snapshot folder of the model.
    ///   - repository: The repository of the model, for the error.
    /// - Returns: The folder of the model package.
    /// - Throws: ``CoreMLModelLoaderError/noPackage(repository:)`` or
    ///   ``CoreMLModelLoaderError/severalPackages(repository:names:)``, or the
    ///   error of the folder read.
    static func locate(in snapshot: URL, repository: String) throws -> URL {
        let packages = try FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == packageExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let package = packages.first else {
            throw CoreMLModelLoaderError.noPackage(repository: repository)
        }
        guard packages.count == 1 else {
            throw CoreMLModelLoaderError.severalPackages(repository: repository, names: packages.map(\.lastPathComponent))
        }
        return package
    }

    /// Finds the weight files of a model package: each `.bin` file in a
    /// `weights` folder.
    ///
    /// - Parameter package: The folder of the model package.
    /// - Returns: The weight files, in no fixed order. A snapshot file is a
    ///   link to a blob, and the result keeps the link.
    static func weightFiles(in package: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil)
        return (files?.compactMap { $0 as? URL } ?? []).filter {
            $0.pathExtension == weightFileExtension && $0.deletingLastPathComponent().lastPathComponent == weightsFolderName
        }
    }

    /// Copies a model package to `destination` as real folders and files. A
    /// file of a snapshot is a link to a blob of the Hugging Face cache, and the
    /// Core ML compiler fails on a link: it cannot change the path of a weight
    /// file. This copies the file that each link names. A folder that exists at
    /// `destination` is removed first.
    ///
    /// - Parameters:
    ///   - package: The folder of the model package in a snapshot.
    ///   - destination: The folder to make. Its parent folder is made too.
    /// - Throws: The error of a folder removal, a folder make, or a file copy.
    static func copy(_ package: URL, to destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            try files.removeItem(at: destination)
        }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = package.path
        let entries = files.enumerator(at: package, includingPropertiesForKeys: [.isDirectoryKey])
        for case let entry as URL in entries ?? FileManager.DirectoryEnumerator() {
            let relative = String(entry.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = destination.appending(path: relative)
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try files.copyItem(at: entry.resolvingSymlinksInPath(), to: target)
            }
        }
    }

    /// Runs `body` with a folder that the tokenizer loader can read. The
    /// tokenizer loader of swift-transformers throws when the folder has no
    /// `tokenizer_config.json`, and some Core ML repositories hold only a
    /// `tokenizer.json`. For such a snapshot, this makes a temporary folder
    /// with links to the tokenizer files of the snapshot and a stand-in config,
    /// then removes the folder when `body` ends.
    ///
    /// - Parameters:
    ///   - snapshot: The snapshot folder of the model.
    ///   - body: Gets the folder to load the tokenizer from.
    /// - Returns: The value of `body`.
    /// - Throws: The error of the folder make, or the error of `body`.
    static func withTokenizerFolder<Value>(
        of snapshot: URL, _ body: (URL) async throws -> Value
    ) async throws -> Value {
        let files = FileManager.default
        guard !files.fileExists(atPath: snapshot.appending(path: tokenizerConfigName).path) else {
            return try await body(snapshot)
        }
        let folder = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? files.removeItem(at: folder) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in tokenizerFileNames where files.fileExists(atPath: snapshot.appending(path: name).path) {
            try files.copyItem(
                at: snapshot.appending(path: name).resolvingSymlinksInPath(), to: folder.appending(path: name))
        }
        try Data(standInTokenizerConfig.utf8).write(to: folder.appending(path: tokenizerConfigName))
        return try await body(folder)
    }

    /// The name of the config file of a tokenizer.
    private static let tokenizerConfigName = "tokenizer_config.json"

    /// The tokenizer files that the temporary folder takes from the snapshot.
    private static let tokenizerFileNames = ["tokenizer.json", "special_tokens_map.json"]

    /// The config that stands for a missing `tokenizer_config.json`. The
    /// tokenizer loader needs the name of a tokenizer class, and the generic
    /// class reads the rules of the tokenizer from `tokenizer.json`.
    static let standInTokenizerConfig = #"{"tokenizer_class":"PreTrainedTokenizer"}"#

    /// The place of the compiled form of a model package. It is below the
    /// cache folder and outside the snapshot, and it names the repository and
    /// the commit, thus a new commit of a repository compiles again and an old
    /// commit keeps its compiled model.
    ///
    /// - Parameters:
    ///   - cacheDirectory: The folder of the Hugging Face cache.
    ///   - repository: The Hugging Face repository id of the model.
    ///   - commit: The commit of the snapshot.
    /// - Returns: The folder of the compiled model.
    static func compiledModel(in cacheDirectory: URL, repository: String, commit: String) -> URL {
        cacheDirectory.appending(path: compiledFolderName, directoryHint: .isDirectory)
            .appending(path: repository, directoryHint: .isDirectory)
            .appending(path: commit, directoryHint: .isDirectory)
            .appending(path: compiledModelName, directoryHint: .isDirectory)
    }
}

/// The shape and the type of one multi-array input of a Core ML model.
struct CoreMLTensorSpec: Equatable {
    /// The size of each dimension.
    let shape: [Int]

    /// The type of each value.
    let dataType: MLMultiArrayDataType

    /// Reads the spec of the multi-array input `description`.
    ///
    /// - Parameter description: The description of one input of a model.
    /// - Returns: The spec, or `nil` when the input is not a multi-array.
    init?(_ description: MLFeatureDescription) {
        guard let constraint = description.multiArrayConstraint else { return nil }
        shape = constraint.shape.map(\.intValue)
        dataType = constraint.dataType
    }

    /// Makes a spec.
    ///
    /// - Parameters:
    ///   - shape: The size of each dimension.
    ///   - dataType: The type of each value.
    init(shape: [Int], dataType: MLMultiArrayDataType) {
        self.shape = shape
        self.dataType = dataType
    }
}

/// What the loader needs to know of the inputs and the output of a Core ML
/// embedding model: the name of the output, and the fixed length of a token
/// row. The model description gives both, thus no value is fixed in the code.
///
/// The model must take two inputs, `input_ids` and `attention_mask`, each an
/// `int32` array of the shape `[1, length]`, and give one vector.
struct CoreMLEmbeddingContract: Equatable {
    /// The name of the input that holds the token ids.
    static let inputIDsName = "input_ids"

    /// The name of the input that holds the attention mask.
    static let attentionMaskName = "attention_mask"

    /// The name of the output that holds the vector, when the model has more
    /// than one output.
    static let preferredOutputName = "embedding"

    /// The batch size that the inputs must have.
    private static let batchSize = 1

    /// The number of dimensions of an input: the batch and the token row.
    private static let inputRank = 2

    /// The name of the output that holds the vector.
    let outputName: String

    /// The token count of each input row. The model reads exactly this many
    /// tokens.
    let sequenceLength: Int

    /// Checks the inputs and the outputs of a model.
    ///
    /// - Parameters:
    ///   - inputs: The spec of each multi-array input, by name.
    ///   - inputNames: The name of each input of the model, also an input that
    ///     is not a multi-array.
    ///   - outputNames: The name of each output of the model.
    /// - Throws: ``CoreMLModelLoaderError/unsupportedModel(reason:)`` when the
    ///   inputs are not the pair `input_ids` and `attention_mask` of
    ///   `int32[1, length]`, or when no output is the vector.
    init(inputs: [String: CoreMLTensorSpec], inputNames: [String], outputNames: [String]) throws {
        let expected = Set([Self.inputIDsName, Self.attentionMaskName])
        guard Set(inputNames) == expected else {
            throw CoreMLModelLoaderError.unsupportedModel(
                reason: "the inputs are \(inputNames.sorted()), and the model must take \(expected.sorted())")
        }
        guard let ids = inputs[Self.inputIDsName], let mask = inputs[Self.attentionMaskName], ids == mask else {
            throw CoreMLModelLoaderError.unsupportedModel(
                reason: "\(Self.inputIDsName) and \(Self.attentionMaskName) must be arrays of one shape and one type")
        }
        guard ids.dataType == .int32, ids.shape.count == Self.inputRank, ids.shape[0] == Self.batchSize,
            ids.shape[1] > 0
        else {
            throw CoreMLModelLoaderError.unsupportedModel(
                reason: "the inputs must be int32 arrays of the shape [\(Self.batchSize), length]")
        }
        sequenceLength = ids.shape[1]
        outputName = try Self.vectorOutput(in: outputNames)
    }

    /// Reads the contract from a model description.
    ///
    /// - Parameter description: The description of a loaded model.
    /// - Throws: ``CoreMLModelLoaderError/unsupportedModel(reason:)``.
    init(description: MLModelDescription) throws {
        var inputs: [String: CoreMLTensorSpec] = [:]
        for (name, feature) in description.inputDescriptionsByName {
            inputs[name] = CoreMLTensorSpec(feature)
        }
        try self.init(
            inputs: inputs, inputNames: Array(description.inputDescriptionsByName.keys),
            outputNames: Array(description.outputDescriptionsByName.keys))
    }

    /// Finds the output that holds the vector: the output named
    /// ``preferredOutputName``, or the only output.
    ///
    /// - Parameter outputNames: The name of each output of the model.
    /// - Returns: The name of the output of the vector.
    /// - Throws: ``CoreMLModelLoaderError/unsupportedModel(reason:)`` when
    ///   neither rule finds the output.
    private static func vectorOutput(in outputNames: [String]) throws -> String {
        if outputNames.contains(preferredOutputName) { return preferredOutputName }
        guard outputNames.count == 1, let only = outputNames.first else {
            throw CoreMLModelLoaderError.unsupportedModel(
                reason: "the outputs are \(outputNames.sorted()), and none is named \(preferredOutputName)")
        }
        return only
    }
}

/// One token row of a Core ML embedding model: the token ids and the
/// attention mask, each cut or padded to the fixed length of the model.
struct CoreMLTokenRow: Equatable {
    /// The token ids, `length` items.
    let ids: [Int32]

    /// The attention mask, `length` items: 1 for a real token and 0 for a pad.
    let mask: [Int32]

    /// Cuts `tokens` to `length` items, or pads them on the right.
    ///
    /// A row that is too long keeps its first tokens. When it ends with the
    /// end token, the cut keeps that end token as the last item, as the
    /// Hugging Face tokenizers do when they truncate a text with its special
    /// tokens.
    ///
    /// - Parameters:
    ///   - tokens: The tokens of one text.
    ///   - length: The fixed token count of the model.
    ///   - padToken: The token that fills the row after its last real token.
    ///   - endToken: The end token of the tokenizer, or `nil` when it has none.
    init(tokens: [Int], length: Int, padToken: Int, endToken: Int?) {
        let kept = Self.cut(tokens, to: length, endToken: endToken)
        let paddingCount = length - kept.count
        ids = (kept + Array(repeating: padToken, count: paddingCount)).map { Int32($0) }
        mask = Array(repeating: Int32(EmbeddingBatchPadding.realToken), count: kept.count)
            + Array(repeating: Int32(EmbeddingBatchPadding.padding), count: paddingCount)
    }

    /// The token that pads a text when the tokenizer has no pad token.
    private static let fallbackPadToken = 0

    /// The pad token of the Gemma tokenizer family.
    private static let padTokenName = "<pad>"

    /// The end token of the Gemma tokenizer family. A tokenizer that loads with
    /// the stand-in config names no end token, but its vocabulary holds this
    /// one, and a cut row must keep it.
    private static let endTokenName = "<eos>"

    /// Tokenizes a text as the model expects: with the special tokens that the
    /// tokenizer adds, which are the start token and the end token.
    ///
    /// - Parameters:
    ///   - text: The text.
    ///   - tokenizer: The tokenizer of the model.
    /// - Returns: The tokens of the text.
    static func encode(_ text: String, with tokenizer: any MLXLMCommon.Tokenizer) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: true)
    }

    /// Cuts or pads the tokens of a text. The pad token and the end token come
    /// from the tokenizer: the end token is the one that its config names, else
    /// the Gemma end token.
    ///
    /// - Parameters:
    ///   - tokens: The tokens of one text.
    ///   - tokenizer: The tokenizer that made the tokens.
    ///   - length: The fixed token count of the model.
    init(tokens: [Int], tokenizer: any MLXLMCommon.Tokenizer, length: Int) {
        self.init(
            tokens: tokens, length: length,
            padToken: tokenizer.convertTokenToId(Self.padTokenName) ?? Self.fallbackPadToken,
            endToken: tokenizer.convertTokenToId(tokenizer.eosToken ?? Self.endTokenName))
    }

    /// Tokenizes a text, then cuts or pads the tokens.
    ///
    /// - Parameters:
    ///   - text: The text.
    ///   - tokenizer: The tokenizer of the model.
    ///   - length: The fixed token count of the model.
    init(text: String, tokenizer: any MLXLMCommon.Tokenizer, length: Int) {
        self.init(tokens: Self.encode(text, with: tokenizer), tokenizer: tokenizer, length: length)
    }

    /// Cuts `tokens` to at most `length` items.
    ///
    /// - Parameters:
    ///   - tokens: The tokens of one text.
    ///   - length: The most items.
    ///   - endToken: The end token of the tokenizer, or `nil`.
    /// - Returns: `tokens` when it is short enough; else its first items, with
    ///   a last end token kept at the end.
    private static func cut(_ tokens: [Int], to length: Int, endToken: Int?) -> [Int] {
        guard tokens.count > length else { return tokens }
        guard let endToken, tokens.last == endToken, length > 0 else { return Array(tokens.prefix(length)) }
        return Array(tokens.prefix(length - 1)) + [endToken]
    }
}
