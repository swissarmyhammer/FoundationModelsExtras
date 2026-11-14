import FoundationModels

/// Forgiving resolution of a model- or CLI-supplied payload to a specific
/// registered operation and its canonically-keyed parameters.
///
/// Models and people make small errors in the names they send, so the
/// resolution has layers: an explicit `op` value tolerant
/// of case, `_`/`-`/space separators (or no separators in a multi-word
/// verb or noun), and "noun verb" reordering; a shared verb-alias table
/// (`create`/`new` → `add`, …) callers can extend per tool; an optional
/// per-tool noun-alias table; parameter key resolution from
/// `ParamMeta.aliases` plus camelCase/snake_case normalization, never
/// overriding an explicitly present canonical key; an optional per-tool
/// inference closure for payloads that omit `op` entirely; and, after that
/// closure, inference of the op from the payload's keys alone, with an
/// optional per-tool `defaultOp` to settle a key set that fits several
/// operations. Before all of these, a payload that a caller put whole into
/// one `arguments` key is unwrapped (`unwrappingArguments(_:)`).
/// `OperationTool` owns one resolver instance and consults it on every
/// `call(arguments:)`.
///
/// **Key-fit inference (^vm78pnz).** A payload with no usable `op` (absent,
/// empty, or not a string) whose `inferOp` gives nothing is matched against
/// each operation's parameters. An operation *fits* the payload when all of
/// these hold:
///
/// 1. the payload has at least one key other than `op`, so an empty payload
///    never runs an operation the caller did not name;
/// 2. each such key resolves to one of the operation's parameters by the
///    same rules `resolveParameters(_:matching:)` uses: the canonical name,
///    a declared alias, or either one normalized (case and `_`/`-`
///    ignored);
/// 3. the payload holds every required parameter of the operation.
///
/// Exactly one fitting operation is the inferred op. Several fitting
/// operations give `defaultOp` when it names one of them, and no op
/// otherwise. No fitting operation gives no op. With no op, `OperationTool`
/// answers "Unknown operation" with the list of valid operations, as it does
/// for an op it cannot match. An explicit `op` is never replaced by an
/// inferred one, even when it matches nothing. Value types are not read,
/// only keys.
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

    /// The noun-alias table this resolver matches against, for example
    /// `reference` → `references`. There is no default table: noun
    /// vocabulary is specific to each tool.
    public let nounAliases: [String: String]

    /// Consulted when the payload has no usable `op` value, to propose one
    /// from the payload's other fields. `nil` by default — inference is
    /// opt-in per tool.
    public let inferOp: InferenceHook?

    /// The op that an op-less payload goes to when its keys fit several
    /// operations and this op is one of them (see "Key-fit inference"
    /// above). `nil` by default, so that a key set that fits several
    /// operations stays an unknown operation.
    ///
    /// The value is matched as an `op` string is, so `"use skill"` and
    /// `"use_skill"` name the same operation. It never applies to a payload
    /// that fits one operation or none, and it never overrides an explicit
    /// `op` or `inferOp`.
    ///
    /// An inferred call runs an operation the model did not name, and
    /// operations declare no read-only flag that the resolver could check.
    /// So name a read-only operation here, never a mutating one: the
    /// FoundationModelsSkills `skills` tool names `use skill`, which fits
    /// `{"id": …}` together with `list resource`, and both only read.
    public let defaultOp: String?

    /// `verbAliases` with each key compacted (see `compacted(_:)`), so that
    /// `Find_Symbol` and `findsymbol` find the same entry.
    private let compactVerbAliases: [String: String]

    /// `nounAliases` with each key compacted (see `compacted(_:)`).
    private let compactNounAliases: [String: String]

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - verbAliases: Verb aliases merged on top of `Self
    ///     .defaultVerbAliases` (overriding a default with the same key).
    ///     Defaults to no additions.
    ///   - nounAliases: Noun aliases, keyed by the alias, with the
    ///     canonical noun as the value. Defaults to no aliases.
    ///   - inferOp: An optional per-tool op-inference hook, consulted when
    ///     the payload has no usable `op` value. Defaults to `nil`.
    ///   - defaultOp: The op for an op-less payload whose keys fit several
    ///     operations, when it is one of them. Name a read-only operation.
    ///     Defaults to `nil`.
    public init(
        verbAliases: [String: String] = [:],
        nounAliases: [String: String] = [:],
        inferOp: InferenceHook? = nil,
        defaultOp: String? = nil
    ) {
        self.verbAliases = OperationResolver.defaultVerbAliases.merging(verbAliases) { _, override in override }
        self.nounAliases = nounAliases
        self.inferOp = inferOp
        self.defaultOp = defaultOp
        self.compactVerbAliases = Self.compactingKeys(of: self.verbAliases)
        self.compactNounAliases = Self.compactingKeys(of: nounAliases)
    }

    /// Returns `table` with each key compacted. When two keys compact to
    /// the same value, the entry with the lesser original key wins, so the
    /// result does not depend on dictionary order.
    private static func compactingKeys(of table: [String: String]) -> [String: String] {
        var compact: [String: String] = [:]
        for key in table.keys.sorted() where compact[compacted(key)] == nil {
            compact[compacted(key)] = table[key]
        }
        return compact
    }
}

extension OperationResolver {
    /// One registered operation's identity, as `matchOpString` and key-fit
    /// inference need it: its `verb`/`noun` pair to match against
    /// (independent of `Context`, unlike `AnyOperation`), the canonical
    /// `opString` to return, and the declared `parameters` that a payload's
    /// keys must fit.
    internal struct OpCandidate {
        internal let verb: String
        internal let noun: String
        internal let opString: String
        internal let parameters: [ParamMeta]

        /// Creates a candidate.
        ///
        /// - Parameters:
        ///   - verb: The operation's verb.
        ///   - noun: The operation's noun.
        ///   - opString: The canonical op string to return on a match.
        ///   - parameters: The declared parameters. Defaults to none, which
        ///     only a payload with no keys could fit, and such a payload is
        ///     never inferred.
        internal init(verb: String, noun: String, opString: String, parameters: [ParamMeta] = []) {
            self.verb = verb
            self.noun = noun
            self.opString = opString
            self.parameters = parameters
        }
    }

    /// Finds the canonical op string of `content` among `candidates`.
    ///
    /// The sources, first one present wins: the explicit `op` property when
    /// it is a non-empty string; else `inferOp`'s proposal; else key-fit
    /// inference (see the type's "Key-fit inference"). The explicit value and
    /// the proposal go through `matchOpString(_:against:)`, and their failure
    /// to match is final: no later source is tried.
    ///
    /// - Parameters:
    ///   - content: The payload, already through `unwrappingArguments(_:)`.
    ///   - candidates: Every registered operation, with its parameters.
    /// - Returns: The matching candidate's canonical `opString`, or `nil`
    ///   when no source gives a match.
    internal func matchedOpString(for content: GeneratedContent, among candidates: [OpCandidate]) -> String? {
        if let explicit = try? content.value(String.self, forProperty: OperationKeys.opFieldName),
            !explicit.isEmpty
        {
            return matchOpString(explicit, against: candidates)
        }
        if let proposed = inferOp?(content) {
            return matchOpString(proposed, against: candidates)
        }
        return inferredOpString(fromKeysOf: content, among: candidates)
    }

    /// Key-fit inference (^vm78pnz): the op of the one candidate whose
    /// parameters `content`'s keys fit, or `defaultOp` when several fit and
    /// it is one of them. The type's "Key-fit inference" states the rule.
    ///
    /// - Parameters:
    ///   - content: The op-less payload.
    ///   - candidates: Every registered operation, with its parameters.
    /// - Returns: The inferred canonical `opString`, or `nil` when no
    ///   candidate fits, or several fit and `defaultOp` is not one of them.
    private func inferredOpString(fromKeysOf content: GeneratedContent, among candidates: [OpCandidate]) -> String? {
        let givenKeys = Self.nonOpKeys(of: content)
        guard !givenKeys.isEmpty else { return nil }
        let fitting = candidates.filter { candidate in
            let resolution = resolveParameters(content, matching: candidate.parameters)
            return resolution.missingRequired.isEmpty && givenKeys.isSubset(of: resolution.matchedKeys)
        }
        if fitting.count == 1 {
            return fitting[0].opString
        }
        guard let defaultOp else { return nil }
        return matchOpString(defaultOp, against: fitting)
    }

    /// The keys of `content` other than the `op` key, compared normalized,
    /// so an empty `"op": ""` does not count as a key to fit. Empty when
    /// `content` is not an object.
    private static func nonOpKeys(of content: GeneratedContent) -> Set<String> {
        guard case let .structure(properties, _) = content.kind else { return [] }
        return Set(properties.keys.filter { OperationKeys.normalized($0) != OperationKeys.opFieldName })
    }

    /// The key that a caller sometimes puts a whole payload into:
    /// `{"arguments": {"op": …, …}}` (^vm78pnz).
    private static let argumentsWrapperKey = "arguments"

    /// Unwraps a payload that a caller put whole into one `arguments` key.
    ///
    /// Some tool callers (Recursive Flint, a GLM-format caller, on a
    /// SWE-bench run) send `{"arguments": {"id": "kanban", "op": "use
    /// skill"}}` in place of the payload itself. When `content` is an object
    /// with exactly one key, that key normalizes to `arguments`, and its
    /// value is an object or a string that parses as one JSON object, the
    /// result is that inner object. Otherwise the result is `content`
    /// unchanged, so a lone `arguments` array (the parameter of `use skill`
    /// or `run script`) stays as it is. The unwrap is one level only, and it
    /// runs before the op is matched or inferred.
    ///
    /// - Parameter content: The payload the tool received.
    /// - Returns: The inner object, or `content` unchanged.
    internal static func unwrappingArguments(_ content: GeneratedContent) -> GeneratedContent {
        guard case let .structure(properties, _) = content.kind, properties.count == 1,
            let (key, value) = properties.first, OperationKeys.normalized(key) == argumentsWrapperKey
        else {
            return content
        }
        if case .structure = value.kind {
            return value
        }
        guard case .string(let text) = value.kind, let parsed = try? GeneratedContent(json: text),
            case .structure = parsed.kind
        else {
            return content
        }
        return parsed
    }

    /// Matches `opString` against `candidates`, tolerant of case, `_`/`-`/
    /// space separators (or none in a multi-word verb or noun), "noun verb"
    /// reordering, `verbAliases`, and `nounAliases`.
    ///
    /// The exact paths run first: a two-token verb/noun match, or else a
    /// compare of the joined tokens with each candidate's `opString`. If
    /// they find no match, `compactMatch(_:against:)` runs as a fallback.
    ///
    /// - Parameters:
    ///   - opString: The candidate op string, e.g. from `extractedOpString`.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    /// - Returns: The matching candidate's canonical `opString`, or `nil` if
    ///   none match.
    internal func matchOpString(_ opString: String, against candidates: [OpCandidate]) -> String? {
        let tokens = Self.spaceSeparatedTokens(opString)
        if tokens.count == 2 {
            for (verbToken, nounToken) in [(tokens[0], tokens[1]), (tokens[1], tokens[0])] {
                let verb = verbAliases[verbToken] ?? verbToken
                let noun = compactNounAliases[nounToken] ?? nounToken
                if let match = candidates.first(where: { $0.verb == verb && $0.noun == noun }) {
                    return match.opString
                }
            }
        } else {
            let joined = tokens.joined(separator: " ")
            if let match = candidates.first(where: { Self.spaceSeparatedTokens($0.opString).joined(separator: " ") == joined }) {
                return match.opString
            }
        }
        return compactMatch(tokens, against: candidates)
    }

    /// The separator-free fallback for `matchOpString(_:against:)`.
    ///
    /// For each split point in `tokens`, the tokens to the left join into
    /// one word and the tokens to the right join into one word. The two
    /// words are tried as (verb, noun) and then as (noun, verb). The verb
    /// goes through `verbAliases` and the noun goes through `nounAliases`.
    /// A candidate matches when its compacted verb and noun are equal to
    /// the two words, so `get typedefinition`, `type_definition get`, and
    /// `get call_graph` find `get type_definition` and `get callgraph`.
    ///
    /// - Parameters:
    ///   - tokens: The op string, as `spaceSeparatedTokens(_:)` gives it.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    /// - Returns: The first registered matching candidate's `opString` for
    ///   the first split and order that matches, or `nil` if none match.
    private func compactMatch(_ tokens: [String], against candidates: [OpCandidate]) -> String? {
        guard tokens.count >= 2 else { return nil }
        for split in 1..<tokens.count {
            let left = tokens[..<split].joined()
            let right = tokens[split...].joined()
            for (verbWord, nounWord) in [(left, right), (right, left)] {
                let verb = Self.compacted(compactVerbAliases[verbWord] ?? verbWord)
                let noun = Self.compacted(compactNounAliases[nounWord] ?? nounWord)
                if let match = candidates.first(where: { Self.compacted($0.verb) == verb && Self.compacted($0.noun) == noun }) {
                    return match.opString
                }
            }
        }
        return nil
    }

    /// Lowercases `text` and removes each `_`, `-`, and whitespace
    /// separator, so `"type_definition"`, `"Type-Definition"`, and
    /// `"type definition"` all compact to `"typedefinition"`.
    private static func compacted(_ text: String) -> String {
        spaceSeparatedTokens(text).joined()
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
        /// key. Thus the result does not depend on whether the target
        /// operation's `Generable` initializer accepts extra keys.
        internal let content: GeneratedContent

        /// The canonical names of every required parameter this resolution
        /// could not find a value for.
        internal let missingRequired: [String]

        /// The raw payload keys that a parameter took its value from. Key-fit
        /// inference compares them with the payload's keys (^vm78pnz).
        internal let matchedKeys: Set<String>
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
        var matchedKeys: Set<String> = []

        for parameter in parameters {
            guard let rawKey = Self.matchingKey(for: parameter, in: rawProperties, normalizedIndex: normalizedIndex) else {
                if parameter.required {
                    missingRequired.append(parameter.name)
                }
                continue
            }
            resolved[parameter.name] = rawProperties[rawKey]
            orderedKeys.append(parameter.name)
            matchedKeys.insert(rawKey)
        }

        let rebuilt = GeneratedContent(kind: .structure(properties: resolved, orderedKeys: orderedKeys))
        return ParameterResolution(content: rebuilt, missingRequired: missingRequired, matchedKeys: matchedKeys)
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
