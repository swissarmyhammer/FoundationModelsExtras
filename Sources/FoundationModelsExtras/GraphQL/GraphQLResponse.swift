import GraphQL

/// A GraphQL response, with the changes of the name rewrite in `extensions.rewrites`, the warnings of the run in
/// `extensions.warnings`, and more `extensions` keys that an endpoint adds, for example `txn`.
///
/// `GraphQLResult` encodes only `data` and `errors`, so this type encodes the same two keys in the same way, and adds
/// `extensions` when it has one or more keys.
public struct GraphQLResponse: Encodable, Sendable {
    /// A key of the response object or of its `extensions` object.
    private struct Key: CodingKey {
        /// The key of the result of the execution.
        static let data = Key(stringValue: "data")

        /// The key of the errors of the call.
        static let errors = Key(stringValue: "errors")

        /// The key of the extensions of the response.
        static let extensions = Key(stringValue: "extensions")

        /// The key of the changes of the name rewrite.
        static let rewrites = Key(stringValue: "rewrites")

        /// The key of the warnings of the run.
        static let warnings = Key(stringValue: "warnings")

        /// The text of the key.
        let stringValue: String

        /// A key is never a number.
        var intValue: Int? { nil }

        /// Makes a key from its text.
        ///
        /// - Parameter stringValue: The text of the key.
        init(stringValue: String) {
            self.stringValue = stringValue
        }

        /// A key is never a number.
        ///
        /// - Parameter intValue: The number.
        init?(intValue _: Int) {
            nil
        }
    }

    /// The result of the document, already in the form of the document that the caller wrote.
    public let result: GraphQLResult

    /// The changes of the name rewrite. An empty list gives no `extensions.rewrites` key.
    public let rewrites: [NameRewrite]

    /// The warnings of the run, in the order that the run added them. An empty list gives no `extensions.warnings`
    /// key.
    public let warnings: [ResponseWarning]

    /// More keys of `extensions`, for example `txn`. A key named `rewrites` or `warnings` is left out, because the
    /// toolkit owns these keys.
    public let extensions: [String: Map]

    /// Makes a response.
    ///
    /// - Parameters:
    ///   - result: The result, already in the form of the document that the caller wrote.
    ///   - rewrites: The changes of the name rewrite.
    ///   - warnings: The warnings of the run.
    ///   - extensions: More keys of `extensions`.
    public init(
        result: GraphQLResult,
        rewrites: [NameRewrite] = [],
        warnings: [ResponseWarning] = [],
        extensions: [String: Map] = [:]
    ) {
        self.result = result
        self.rewrites = rewrites
        self.warnings = warnings
        let ownedKeys = [Key.rewrites.stringValue, Key.warnings.stringValue]
        self.extensions = extensions.filter { key, _ in !ownedKeys.contains(key) }
    }

    /// Writes `data` when the result has it, `errors` when there is an error, and `extensions` when it has one or more
    /// keys. `extensions` has only the lists that are not empty.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: An error from the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encodeIfPresent(result.data, forKey: .data)
        if !result.errors.isEmpty {
            try container.encode(result.errors, forKey: .errors)
        }
        guard !rewrites.isEmpty || !warnings.isEmpty || !extensions.isEmpty else {
            return
        }
        var nested = container.nestedContainer(keyedBy: Key.self, forKey: .extensions)
        if !rewrites.isEmpty {
            try nested.encode(rewrites, forKey: .rewrites)
        }
        if !warnings.isEmpty {
            try nested.encode(warnings, forKey: .warnings)
        }
        for key in extensions.keys.sorted() {
            try nested.encode(extensions[key], forKey: Key(stringValue: key))
        }
    }

    /// Encodes the response as JSON text.
    ///
    /// - Parameter formatting: The formatting of the JSON text, for example `.sortedKeys`. Slashes are never escaped,
    ///   so a ref such as `tag/bug` stays easy to read.
    /// - Returns: The JSON text.
    /// - Throws: An error from the JSON encoder.
    public func json(formattedWith formatting: GraphQLJSONEncoder.OutputFormatting = []) throws -> String {
        let encoder = GraphQLJSONEncoder()
        encoder.outputFormatting = formatting.union(.withoutEscapingSlashes)
        return try String(decoding: encoder.encode(self), as: UTF8.self)
    }
}
