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
}
