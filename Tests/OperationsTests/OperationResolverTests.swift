import Testing

@testable import Operations

/// Tests for the separator-free fallback and the `nounAliases` table in
/// `OperationResolver.matchOpString(_:against:)`.
struct OperationResolverTests {
    /// Candidates with multi-word nouns, one written with `_` and one
    /// written as a single word.
    private let candidates = [
        OperationResolver.OpCandidate(verb: "get", noun: "type_definition", opString: "get type_definition"),
        OperationResolver.OpCandidate(verb: "get", noun: "callgraph", opString: "get callgraph"),
        OperationResolver.OpCandidate(verb: "get", noun: "references", opString: "get references"),
    ]

    @Test(arguments: [
        "get typedefinition",
        "get type_definition",
        "get type-definition",
        "get type definition",
        "type_definition get",
        "type definition get",
        "typedefinition get",
        "GET TypeDefinition",
    ])
    func multiWordNounMatchesWithAndWithoutSeparators(opString: String) {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString(opString, against: candidates) == "get type_definition")
    }

    @Test(arguments: ["get call_graph", "get call-graph", "get call graph", "call_graph get"])
    func separatedNounMatchesASingleWordCandidateNoun(opString: String) {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString(opString, against: candidates) == "get callgraph")
    }

    @Test func nounAliasResolvesToTheCanonicalNoun() {
        let resolver = OperationResolver(nounAliases: ["reference": "references"])

        #expect(resolver.nounAliases == ["reference": "references"])
        #expect(resolver.matchOpString("get reference", against: candidates) == "get references")
        #expect(resolver.matchOpString("reference get", against: candidates) == "get references")
    }

    @Test func verbAliasAndNounAliasApplyTogether() {
        let resolver = OperationResolver(verbAliases: ["find": "get"], nounAliases: ["reference": "references"])

        #expect(resolver.matchOpString("find reference", against: candidates) == "get references")
    }

    @Test func multiWordNounAliasMatchesWithAndWithoutSeparators() {
        let resolver = OperationResolver(nounAliases: ["type_def": "type_definition", "call_tree": "callgraph"])

        #expect(resolver.matchOpString("get typedef", against: candidates) == "get type_definition")
        #expect(resolver.matchOpString("get type def", against: candidates) == "get type_definition")
        #expect(resolver.matchOpString("show call-tree", against: candidates) == "get callgraph")
    }

    @Test func multiWordVerbAliasMatchesWithoutSeparators() {
        let resolver = OperationResolver(verbAliases: ["look_up": "get"])

        #expect(resolver.matchOpString("lookup type definition", against: candidates) == "get type_definition")
        #expect(resolver.matchOpString("look up callgraph", against: candidates) == "get callgraph")
    }

    @Test func withoutANounAliasASingularNounDoesNotMatch() {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString("get reference", against: candidates) == nil)
    }

    @Test func fallbackWithNoEquivalentCandidateReturnsNil() {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString("get type", against: candidates) == nil)
        #expect(resolver.matchOpString("get type definition extra", against: candidates) == nil)
        #expect(resolver.matchOpString("gettypedefinition", against: candidates) == nil)
    }

    @Test func firstRegisteredCandidateWinsWhenTwoCompactToTheSameOp() {
        let resolver = OperationResolver()
        let colliding = [
            OperationResolver.OpCandidate(verb: "get", noun: "type_definition", opString: "get type_definition"),
            OperationResolver.OpCandidate(verb: "get", noun: "typedefinition", opString: "get typedefinition"),
        ]

        #expect(resolver.matchOpString("type definition get", against: colliding) == "get type_definition")
    }

    /// The operation set of the `skills` tool, where the verb `read` and
    /// the noun `script` each belong to one operation only.
    private let skillsCandidates = [
        OperationResolver.OpCandidate(verb: "use", noun: "skill", opString: "use skill"),
        OperationResolver.OpCandidate(verb: "list", noun: "skill", opString: "list skill"),
        OperationResolver.OpCandidate(verb: "list", noun: "resource", opString: "list resource"),
        OperationResolver.OpCandidate(verb: "read", noun: "resource", opString: "read resource"),
        OperationResolver.OpCandidate(verb: "run", noun: "script", opString: "run script"),
    ]

    @Test(arguments: ["read", "READ", " read "])
    func oneWordOpThatIsTheVerbOfOneOperationMatchesIt(opString: String) {
        let resolver = OperationResolver(verbAliases: ["read": "read"])

        #expect(resolver.matchOpString(opString, against: skillsCandidates) == "read resource")
    }

    @Test func oneWordOpThatIsTheNounOfOneOperationMatchesIt() {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString("script", against: skillsCandidates) == "run script")
    }

    @Test func oneWordOpGoesThroughTheVerbAliases() {
        let resolver = OperationResolver(verbAliases: ["execute": "run"])

        #expect(resolver.matchOpString("execute", against: skillsCandidates) == "run script")
    }

    @Test(arguments: ["list", "skill", "resource", "get", "unknown"])
    func oneWordOpThatFitsSeveralOperationsOrNoneDoesNotMatch(opString: String) {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString(opString, against: skillsCandidates) == nil)
    }

    /// An operation set with the verb `remove`, which is a key of the
    /// default verb-alias table (`remove` -> `delete`).
    private let removeCandidates = [
        OperationResolver.OpCandidate(verb: "remove", noun: "entry", opString: "remove entry"),
        OperationResolver.OpCandidate(verb: "list", noun: "entry", opString: "list entry"),
    ]

    /// The same operation set with `delete entry` in addition.
    private let removeAndDeleteCandidates = [
        OperationResolver.OpCandidate(verb: "remove", noun: "entry", opString: "remove entry"),
        OperationResolver.OpCandidate(verb: "delete", noun: "entry", opString: "delete entry"),
    ]

    /// An operation set with `delete entry` and no `remove entry`.
    private let deleteCandidates = [
        OperationResolver.OpCandidate(verb: "delete", noun: "entry", opString: "delete entry"),
        OperationResolver.OpCandidate(verb: "list", noun: "entry", opString: "list entry"),
    ]

    @Test(arguments: ["remove entry", "entry remove", "remove_entry", "Remove-Entry", "remove"])
    func registeredVerbThatIsAnAliasKeyMatchesItsOwnOperation(opString: String) {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString(opString, against: removeCandidates) == "remove entry")
    }

    @Test(arguments: ["remove entry", "entry remove", "remove_entry", "remove"])
    func exactVerbWinsOverTheAliasWhenBothOperationsExist(opString: String) {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString(opString, against: removeAndDeleteCandidates) == "remove entry")
    }

    @Test(arguments: ["delete entry", "entry delete", "delete_entry"])
    func canonicalVerbStillMatchesWhenBothOperationsExist(opString: String) {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString(opString, against: removeAndDeleteCandidates) == "delete entry")
    }

    @Test(arguments: ["remove entry", "entry remove", "remove_entry", "rm entry", "remove"])
    func aliasStillAppliesWhenNoOperationHasTheVerbAsGiven(opString: String) {
        let resolver = OperationResolver()

        #expect(resolver.matchOpString(opString, against: deleteCandidates) == "delete entry")
    }

    @Test func exactNounWinsOverTheNounAlias() {
        let resolver = OperationResolver(nounAliases: ["entries": "entry"])
        let candidates = [
            OperationResolver.OpCandidate(verb: "list", noun: "entries", opString: "list entries"),
            OperationResolver.OpCandidate(verb: "list", noun: "entry", opString: "list entry"),
            OperationResolver.OpCandidate(verb: "get", noun: "entry", opString: "get entry"),
        ]

        #expect(resolver.matchOpString("list entries", against: candidates) == "list entries")
        #expect(resolver.matchOpString("list_entries", against: candidates) == "list entries")
        #expect(resolver.matchOpString("get entries", against: candidates) == "get entry")
    }

    @Test func oneWordThatNamesSeveralOperationsAsGivenStaysAmbiguous() {
        let resolver = OperationResolver()
        let candidates = [
            OperationResolver.OpCandidate(verb: "remove", noun: "entry", opString: "remove entry"),
            OperationResolver.OpCandidate(verb: "remove", noun: "tag", opString: "remove tag"),
            OperationResolver.OpCandidate(verb: "delete", noun: "board", opString: "delete board"),
        ]

        #expect(resolver.matchOpString("remove", against: candidates) == nil)
    }
}
