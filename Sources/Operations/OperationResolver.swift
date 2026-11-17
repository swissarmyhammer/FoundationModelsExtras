import FoundationModels

/// Forgiving resolution of a model- or CLI-supplied payload to a specific
/// registered operation and its canonically-keyed parameters.
///
/// Models and people make small errors in the names they send, so the
/// resolution has layers: an explicit `op` value tolerant
/// of case, `_`/`-`/space separators (or no separators in a multi-word
/// verb or noun), and "noun verb" reordering; a shared verb-alias table
/// (`create`/`new` → `add`, …) callers can extend per tool, which applies
/// only when no operation matches the verb and noun as given; an optional
/// per-tool noun-alias table; an op of one word that names the verb or the
/// noun of exactly one operation (`read` for `read resource`); parameter key resolution from
/// `ParamMeta.aliases` plus camelCase/snake_case normalization, never
/// overriding an explicitly present canonical key; an optional per-tool
/// inference closure for payloads that omit `op` entirely; and, after that
/// closure, inference of an inferable op from the payload's keys alone,
/// with an optional per-tool `defaultOp` to settle a key set that fits
/// several inferable operations. Before all of these, a payload that a
/// caller put whole into one `arguments` key is unwrapped
/// (`unwrappingArguments(_:)`).
/// `OperationTool` owns one resolver instance and consults it on every
/// `call(arguments:)`.
///
/// **Key-fit inference.** A payload with no usable `op` (absent, empty, or
/// not a string) whose `inferOp` gives nothing is matched against each
/// operation's parameters. An operation *fits* the payload when all of these
/// hold:
///
/// 1. the payload has at least one key other than `op`, so an empty payload
///    never runs an operation the caller did not name;
/// 2. each such key resolves to one of the operation's parameters by the
///    same rules `resolveParameters(_:matching:)` uses: the canonical name,
///    a declared alias, or either one normalized (case and `_`/`-`
///    ignored);
/// 3. the payload holds every required parameter of the operation.
///
/// Inference chooses only a fitting operation that declares
/// `OperationDefinition.isInferable`, that is an operation that only reads.
/// An operation with a side effect runs only when the call names it, also
/// when it is the one operation that fits. Exactly one fitting inferable
/// operation is the inferred op. Several give `defaultOp` when it names one
/// of them, and no op otherwise. No fitting inferable operation gives no op.
///
/// With no op, `OperationTool` does not run an operation. It answers with
/// `OperationError.unnamedOperation(fitting:valid:)`: the text tells the
/// caller to name the operation in `op`, and lists each operation that fits
/// the keys (inferable or not) and all valid operations. An explicit `op` is
/// never replaced by an inferred one, even when it matches nothing. Value
/// types are not read, only keys.
public struct OperationResolver: Sendable {
    /// Inspects an op-less payload and proposes an op string to resolve, or
    /// `nil` if it can't infer one.
    public typealias InferenceHook = @Sendable (GeneratedContent) -> String?

    /// The shared verb-alias table every resolver starts from: `create`/
    /// `new` → `add`, `show`/`read`/`fetch` → `get`, `remove`/`rm`/`del` →
    /// `delete`.
    ///
    /// An alias applies only when no operation matches the words as given.
    /// So a tool with the operation `remove entry` runs it for the op
    /// `remove entry`, and the alias `remove` → `delete` applies only to a
    /// tool with no such operation.
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
    ///
    /// The proposal is matched as an explicit `op` is, so the hook can give
    /// any operation, also one that is not `isInferable`. The tool author
    /// writes the hook and chooses its op, so the resolver does not check
    /// the flag here.
    ///
    /// - Warning: An inferred call runs an operation that the caller did not
    ///   name. Do not give an op that writes, removes or has another side
    ///   effect, unless the tool author accepts that risk.
    public let inferOp: InferenceHook?

    /// The op that an op-less payload goes to when its keys fit several
    /// inferable operations and this op is one of them (see "Key-fit
    /// inference" above). `nil` by default, so that a key set that fits
    /// several inferable operations runs no operation.
    ///
    /// The value is matched as an `op` string is, so `"use skill"` and
    /// `"use_skill"` name the same operation. It never applies to a payload
    /// that fits one inferable operation or none, and it never overrides an
    /// explicit `op` or `inferOp`.
    ///
    /// An inferred call runs an operation the model did not name, so the
    /// value must name an operation that declares
    /// `OperationDefinition.isInferable`. A value that names an operation
    /// without the flag is never used. For example, the
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
    ///     inferable operations, when it is one of them. Name an operation
    ///     that declares `OperationDefinition.isInferable`. Defaults to
    ///     `nil`.
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
    /// `opString` to return, the declared `parameters` that a payload's
    /// keys must fit, and whether key-fit inference can choose it.
    internal struct OpCandidate {
        internal let verb: String
        internal let noun: String
        internal let opString: String
        internal let parameters: [ParamMeta]
        internal let isInferable: Bool

        /// Creates a candidate.
        ///
        /// - Parameters:
        ///   - verb: The operation's verb.
        ///   - noun: The operation's noun.
        ///   - opString: The canonical op string to return on a match.
        ///   - parameters: The declared parameters. Defaults to none, which
        ///     only a payload with no keys could fit, and such a payload is
        ///     never inferred.
        ///   - isInferable: Whether key-fit inference and `defaultOp` can
        ///     choose the operation. Defaults to `false`, as
        ///     `OperationDefinition.isInferable` does.
        internal init(
            verb: String, noun: String, opString: String, parameters: [ParamMeta] = [], isInferable: Bool = false
        ) {
            self.verb = verb
            self.noun = noun
            self.opString = opString
            self.parameters = parameters
            self.isInferable = isInferable
        }
    }

    /// What `matchedOp(for:among:)` found for a payload.
    internal enum OpMatch: Equatable {
        /// The canonical `opString` of the matched candidate.
        case matched(String)

        /// The payload names an op, as an explicit `op` or as the proposal
        /// of `inferOp`, and that op matches no candidate.
        case unknown

        /// The payload names no op, and key-fit inference chose no
        /// candidate. `fitting` holds the `opString` of each candidate whose
        /// parameters fit the keys, inferable or not, in candidate order.
        case unnamed(fitting: [String])
    }

    /// Finds the operation of `content` among `candidates`.
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
    /// - Returns: `.matched` with the canonical `opString` of the matching
    ///   candidate; `.unknown` when the named op matches no candidate; or
    ///   `.unnamed` with the fitting candidates when the payload names no op
    ///   and key-fit inference chose none.
    internal func matchedOp(for content: GeneratedContent, among candidates: [OpCandidate]) -> OpMatch {
        if let explicit = try? content.value(String.self, forProperty: OperationKeys.opFieldName),
            !explicit.isEmpty
        {
            return matchOpString(explicit, against: candidates).map(OpMatch.matched) ?? .unknown
        }
        if let proposed = inferOp?(content) {
            return matchOpString(proposed, against: candidates).map(OpMatch.matched) ?? .unknown
        }
        let fitting = fittingCandidates(for: content, among: candidates)
        guard let inferred = inferredOpString(among: fitting) else {
            return .unnamed(fitting: fitting.map(\.opString))
        }
        return .matched(inferred)
    }

    /// The candidates whose parameters the keys of `content` fit, inferable
    /// or not, in candidate order. The type's "Key-fit inference" states
    /// what a fit is.
    ///
    /// - Parameters:
    ///   - content: The op-less payload.
    ///   - candidates: Every registered operation, with its parameters.
    /// - Returns: The fitting candidates. Empty when `content` has no key
    ///   other than `op`.
    private func fittingCandidates(for content: GeneratedContent, among candidates: [OpCandidate]) -> [OpCandidate] {
        let givenKeys = Self.nonOpKeys(of: content)
        guard !givenKeys.isEmpty else { return [] }
        return candidates.filter { candidate in
            let resolution = resolveParameters(content, matching: candidate.parameters)
            return resolution.missingRequired.isEmpty && givenKeys.isSubset(of: resolution.matchedKeys)
        }
    }

    /// Key-fit inference: the op of the one inferable candidate among
    /// `fitting`, or `defaultOp` when several inferable candidates fit and
    /// it is one of them. A candidate that is not inferable is never the
    /// result, also when it is the only fit or `defaultOp` names it.
    ///
    /// - Parameter fitting: The candidates whose parameters the keys fit.
    /// - Returns: The inferred canonical `opString`, or `nil` when no
    ///   inferable candidate fits, or several fit and `defaultOp` is not one
    ///   of them.
    private func inferredOpString(among fitting: [OpCandidate]) -> String? {
        let inferable = fitting.filter(\.isInferable)
        if let only = Self.soleElement(of: inferable) {
            return only.opString
        }
        guard let defaultOp else { return nil }
        return matchOpString(defaultOp, against: inferable)
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
        guard case let .structure(properties, _) = content.kind,
            let (key, value) = soleElement(of: properties), OperationKeys.normalized(key) == argumentsWrapperKey
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
    /// The words as given win over the aliases. The first pass compares the
    /// words with no alias: a two-token verb/noun match, or else a compare
    /// of the joined tokens with each candidate's `opString`, and then
    /// `compactMatch(_:against:aliased:)`. Only when that pass finds no
    /// match does the second pass apply `verbAliases` and `nounAliases`. So
    /// `remove entry` runs the operation `remove entry` when the tool has
    /// it, also when the alias table maps `remove` to `delete`, and runs
    /// `delete entry` only when the tool has no `remove entry`. An op of one
    /// word goes to `oneWordMatch(_:against:)` last, which keeps the same
    /// rule.
    ///
    /// - Parameters:
    ///   - opString: The candidate op string, e.g. from `extractedOpString`.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    /// - Returns: The matching candidate's canonical `opString`, or `nil` if
    ///   none match.
    internal func matchOpString(_ opString: String, against candidates: [OpCandidate]) -> String? {
        let tokens = Self.spaceSeparatedTokens(opString)
        return separatedMatch(tokens, against: candidates, aliased: false)
            ?? compactMatch(tokens, against: candidates, aliased: false)
            ?? separatedMatch(tokens, against: candidates, aliased: true)
            ?? compactMatch(tokens, against: candidates, aliased: true)
            ?? oneWordMatch(tokens, against: candidates)
    }

    /// The number of tokens in an op of a verb and a noun, such as
    /// `["remove", "entry"]`.
    private static let verbAndNounTokenCount = 2

    /// The match of `tokens` with the separators that the caller gave.
    ///
    /// Two tokens are compared as (verb, noun) and then as (noun, verb)
    /// with each candidate's verb and noun. Other token counts are joined
    /// with spaces and compared with each candidate's `opString`. This
    /// compare has no alias form, so it runs only when `aliased` is
    /// `false`.
    ///
    /// - Parameters:
    ///   - tokens: The op string, as `spaceSeparatedTokens(_:)` gives it.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    ///   - aliased: When `true`, the verb goes through `verbAliases` and the
    ///     noun goes through `nounAliases`. When `false`, the words are
    ///     compared as given.
    /// - Returns: The first registered matching candidate's `opString`, or
    ///   `nil` if none match.
    private func separatedMatch(_ tokens: [String], against candidates: [OpCandidate], aliased: Bool) -> String? {
        guard tokens.count == Self.verbAndNounTokenCount, let first = tokens.first, let last = tokens.last else {
            guard !aliased else { return nil }
            let joined = tokens.joined(separator: " ")
            return candidates.first { Self.spaceSeparatedTokens($0.opString).joined(separator: " ") == joined }?
                .opString
        }
        return firstMatch(of: [(first, last), (last, first)], against: candidates, aliased: aliased) { $0 }
    }

    /// The fallback for an op of one word, such as `read` where the tool
    /// has `read resource`.
    ///
    /// The word, compacted, is compared with each candidate's compacted
    /// verb and noun. When it names one or more candidates as given, that
    /// result is final: one candidate is the match, and several make the op
    /// ambiguous, so nothing matches. Only when the word as given names no
    /// candidate does it go through `verbAliases` for the compare with the
    /// verbs and through `nounAliases` for the compare with the nouns, with
    /// the same rule for one and for several candidates. For example `list`
    /// names `list skill` and `list resource`, so it matches nothing.
    ///
    /// - Parameters:
    ///   - tokens: The op string, as `spaceSeparatedTokens(_:)` gives it.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    /// - Returns: The `opString` of the one candidate the word names, or
    ///   `nil` when `tokens` is not one word, or the word names no candidate
    ///   or several.
    private func oneWordMatch(_ tokens: [String], against candidates: [OpCandidate]) -> String? {
        guard let word = Self.soleElement(of: tokens) else { return nil }
        var named = Self.candidates(namedByVerb: word, orNoun: word, among: candidates)
        if named.isEmpty {
            named = Self.candidates(
                namedByVerb: compactVerbAliases[word] ?? word,
                orNoun: compactNounAliases[word] ?? word,
                among: candidates
            )
        }
        return Self.soleElement(of: named)?.opString
    }

    /// The candidates whose compacted verb is equal to `verb` compacted, or
    /// whose compacted noun is equal to `noun` compacted.
    ///
    /// - Parameters:
    ///   - verb: The word to compare with each candidate's verb.
    ///   - noun: The word to compare with each candidate's noun.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    /// - Returns: The named candidates, in candidate order.
    private static func candidates(
        namedByVerb verb: String, orNoun noun: String, among candidates: [OpCandidate]
    ) -> [OpCandidate] {
        let verb = compacted(verb)
        let noun = compacted(noun)
        return candidates.filter { compacted($0.verb) == verb || compacted($0.noun) == noun }
    }

    /// The separator-free fallback for `matchOpString(_:against:)`.
    ///
    /// For each split point in `tokens`, the tokens to the left join into
    /// one word and the tokens to the right join into one word. The two
    /// words are tried as (verb, noun) and then as (noun, verb). A
    /// candidate matches when its compacted verb and noun are equal to the
    /// two words, so `get typedefinition`, `type_definition get`, and
    /// `get call_graph` find `get type_definition` and `get callgraph`.
    ///
    /// - Parameters:
    ///   - tokens: The op string, as `spaceSeparatedTokens(_:)` gives it.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    ///   - aliased: When `true`, the verb goes through `verbAliases` and the
    ///     noun goes through `nounAliases`. When `false`, the words are
    ///     compared as given.
    /// - Returns: The first registered matching candidate's `opString` for
    ///   the first split and order that matches, or `nil` if none match.
    private func compactMatch(_ tokens: [String], against candidates: [OpCandidate], aliased: Bool) -> String? {
        let pairs = tokens.indices.dropFirst().flatMap { split -> [(String, String)] in
            let left = tokens[..<split].joined()
            let right = tokens[split...].joined()
            return [(left, right), (right, left)]
        }
        return firstMatch(of: pairs, against: candidates, aliased: aliased, comparing: Self.compacted)
    }

    /// The `opString` of the first candidate whose verb and noun are equal
    /// to a (verb, noun) pair of `pairs`, in pair order and then in
    /// candidate order.
    ///
    /// - Parameters:
    ///   - pairs: The (verb, noun) words to try, in order.
    ///   - candidates: Every registered operation's `verb`/`noun`/`opString`.
    ///   - aliased: When `true`, the verb goes through `verbAliases` and the
    ///     noun goes through `nounAliases`, both by compacted key. When
    ///     `false`, the words are compared as given.
    ///   - form: The form in which each word and each candidate's verb and
    ///     noun are compared.
    /// - Returns: The matching candidate's `opString`, or `nil` if none
    ///   match.
    private func firstMatch(
        of pairs: [(verb: String, noun: String)],
        against candidates: [OpCandidate],
        aliased: Bool,
        comparing form: (String) -> String
    ) -> String? {
        for pair in pairs {
            let verb = form(aliased ? compactVerbAliases[pair.verb] ?? pair.verb : pair.verb)
            let noun = form(aliased ? compactNounAliases[pair.noun] ?? pair.noun : pair.noun)
            if let match = candidates.first(where: { form($0.verb) == verb && form($0.noun) == noun }) {
                return match.opString
            }
        }
        return nil
    }

    /// The one element of `elements`, or `nil` when it has no element or
    /// more than one.
    ///
    /// - Parameter elements: The collection to read.
    /// - Returns: The sole element, or `nil`.
    private static func soleElement<Elements: Collection>(of elements: Elements) -> Elements.Element? {
        guard let first = elements.first, elements.dropFirst().isEmpty else { return nil }
        return first
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
