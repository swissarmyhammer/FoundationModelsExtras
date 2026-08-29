import FoundationModels

/// Forgiving resolution of a model- or CLI-supplied payload to a specific
/// registered operation and its canonically-keyed parameters.
///
/// Layered per plan.md's "Forgiving input": an explicit `op` value tolerant
/// of case, `_`/`-` separators, and "noun verb" reordering; a shared
/// verb-alias table (`create`/`new` → `add`, …) callers can extend per tool;
/// parameter key resolution from `ParamMeta.aliases` plus camelCase/
/// snake_case normalization, never overriding an explicitly present
/// canonical key; and an optional per-tool inference closure for payloads
/// that omit `op` entirely. `OperationTool` owns one resolver instance and
/// consults it on every `call(arguments:)`.
public struct OperationResolver: Sendable {
    /// Inspects an op-less payload and proposes an op string to resolve, or
    /// `nil` if it can't infer one.
    public typealias InferenceHook = @Sendable (GeneratedContent) -> String?

    /// The shared verb-alias table every resolver starts from: `create`/
    /// `new` → `add`, `show`/`read`/`fetch` → `get`, `remove`/`rm`/`del` →
    /// `delete`.
    public static let defaultVerbAliases: [String: String] = [
        "create": "add",
        "new": "add",
        "show": "get",
        "read": "get",
        "fetch": "get",
        "remove": "delete",
        "rm": "delete",
        "del": "delete",
    ]

    /// The verb-alias table this resolver matches against: `Self
    /// .defaultVerbAliases` with the initializer's `verbAliases` merged on
    /// top (an entry with the same key overrides the default).
    public let verbAliases: [String: String]

    /// Consulted when the payload has no usable `op` value, to propose one
    /// from the payload's other fields. `nil` by default — inference is
    /// opt-in per tool.
    public let inferOp: InferenceHook?

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - verbAliases: Verb aliases merged on top of `Self
    ///     .defaultVerbAliases` (overriding a default with the same key).
    ///     Defaults to no additions.
    ///   - inferOp: An optional per-tool op-inference hook, consulted when
    ///     the payload has no usable `op` value. Defaults to `nil`.
    public init(
        verbAliases: [String: String] = [:],
        inferOp: InferenceHook? = nil
    ) {
        self.verbAliases = OperationResolver.defaultVerbAliases.merging(verbAliases) { _, override in override }
        self.inferOp = inferOp
    }
}

extension OperationResolver {
    /// One registered operation's identity, as `matchOpString` needs it:
    /// its `verb`/`noun` pair to match against (independent of `Context`,
    /// unlike `AnyOperation`) and the canonical `opString` to return.
    internal struct OpCandidate {
        internal let verb: String
        internal let noun: String
        internal let opString: String
    }

    /// Extracts a candidate op string from `content`: the explicit `op`
    /// property if present and non-empty, else `inferOp`'s proposal.
    ///
    /// - Parameter content: The payload to inspect.
    /// - Returns: The candidate op string to resolve, or `nil` if neither
    ///   source produced one.
    internal func extractedOpString(from content: GeneratedContent) -> String? {
        if let explicit = try? content.value(String.self, forProperty: OperationKeys.opFieldName),
            !explicit.isEmpty
        {
            return explicit
        }
        return inferOp?(content)
    }

    /// Matches `opString` against `candidates`, tolerant of case, `_`/`-`
    /// separators, "noun verb" reordering, and `verbAliases`.
    ///
    /// - Parameters:
    ///   - opString: The candidate op string, e.g. from `extractedOpString`.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    /// - Returns: The matching candidate's canonical `opString`, or `nil` if
    ///   none match.
    internal func matchOpString(_ opString: String, against candidates: [OpCandidate]) -> String? {
        let tokens = Self.spaceSeparatedTokens(opString)
        guard tokens.count == 2 else {
            let joined = tokens.joined(separator: " ")
            return candidates.first { Self.spaceSeparatedTokens($0.opString).joined(separator: " ") == joined }?.opString
        }

        for (verbToken, nounToken) in [(tokens[0], tokens[1]), (tokens[1], tokens[0])] {
            let verb = verbAliases[verbToken] ?? verbToken
            if let match = candidates.first(where: { $0.verb == verb && $0.noun == nounToken }) {
                return match.opString
            }
        }
        return nil
    }

    /// Lowercases `text` and splits it into whitespace-separated tokens,
    /// treating `_`/`-` as additional word separators (so `"add_note"`,
    /// `"add-note"`, and `"add note"` all tokenize to `["add", "note"]`).
    private static func spaceSeparatedTokens(_ text: String) -> [String] {
        let separatorsAsSpaces = String(
            text.lowercased().map { (character: Character) -> Character in
                character == "_" || character == "-" ? " " : character
            }
        )
        return separatorsAsSpaces.split(separator: " ").map(String.init)
    }
}

extension OperationResolver {
    /// The result of resolving a payload's properties against one
    /// operation's declared parameters.
    internal struct ParameterResolution {
        /// A new payload containing only the recognized parameters, under
        /// their canonical names — dropping `op` and any other unrecognized
        /// key, which also sidesteps whether the target operation's
        /// `Generable` initializer tolerates extra keys (see plan.md's
        /// "`GeneratedContent` behavior with extra keys").
        internal let content: GeneratedContent

        /// The canonical names of every required parameter this resolution
        /// could not find a value for.
        internal let missingRequired: [String]
    }

    /// Resolves `content`'s properties against `parameters`' canonical
    /// names, `ParamMeta.aliases`, and camelCase/snake_case-normalized
    /// names.
    ///
    /// Resolution order per parameter, first match wins: the canonical name
    /// exactly; a declared alias exactly; the canonical name normalized
    /// (case/separator-insensitive); a declared alias normalized. An
    /// explicitly present canonical key is therefore never overridden by an
    /// alias or a normalized match.
    ///
    /// - Parameters:
    ///   - content: The payload to resolve.
    ///   - parameters: The target operation's declared parameters.
    /// - Returns: The rebuilt, canonically-keyed payload plus any missing
    ///   required parameter names.
    internal func resolveParameters(_ content: GeneratedContent, matching parameters: [ParamMeta]) -> ParameterResolution {
        let rawProperties: [String: GeneratedContent]
        if case let .structure(properties, _) = content.kind {
            rawProperties = properties
        } else {
            rawProperties = [:]
        }
        var normalizedIndex: [String: String] = [:]
        for rawKey in rawProperties.keys where normalizedIndex[OperationKeys.normalized(rawKey)] == nil {
            normalizedIndex[OperationKeys.normalized(rawKey)] = rawKey
        }

        var resolved: [String: GeneratedContent] = [:]
        var orderedKeys: [String] = []
        var missingRequired: [String] = []

        for parameter in parameters {
            guard let rawKey = Self.matchingKey(for: parameter, in: rawProperties, normalizedIndex: normalizedIndex) else {
                if parameter.required {
                    missingRequired.append(parameter.name)
                }
                continue
            }
            resolved[parameter.name] = rawProperties[rawKey]
            orderedKeys.append(parameter.name)
        }

        let rebuilt = GeneratedContent(kind: .structure(properties: resolved, orderedKeys: orderedKeys))
        return ParameterResolution(content: rebuilt, missingRequired: missingRequired)
    }

    /// Finds `parameter`'s value's raw key in `rawProperties`, trying its
    /// canonical name, its declared aliases, and both normalized, in that
    /// priority order.
    private static func matchingKey(
        for parameter: ParamMeta,
        in rawProperties: [String: GeneratedContent],
        normalizedIndex: [String: String]
    ) -> String? {
        if rawProperties[parameter.name] != nil {
            return parameter.name
        }
        if let alias = parameter.aliases.first(where: { rawProperties[$0] != nil }) {
            return alias
        }
        if let key = normalizedIndex[OperationKeys.normalized(parameter.name)] {
            return key
        }
        return parameter.aliases.lazy.compactMap { normalizedIndex[OperationKeys.normalized($0)] }.first
    }
}
