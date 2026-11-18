import FoundationModelsExtras
import Testing

/// ``SessionName`` gives the default name of a new session.
@Suite("SessionName: the default name of a new session")
struct SessionNameTests {
    @Test("with no used name, the default name is the slug of the agent name")
    func noUsedNameGivesTheAgentSlug() {
        #expect(SessionName.default(agentName: "claude-code", usedNames: []) == "claude-code")
    }

    @Test("when the agent slug is used, the default name ends with 2")
    func aUsedSlugGivesTheNumberTwo() {
        #expect(
            SessionName.default(agentName: "claude-code", usedNames: ["claude-code"])
                == "claude-code-2")
    }

    @Test("when the slug and the number 2 are used, the default name ends with 3")
    func twoUsedNamesGiveTheNumberThree() {
        #expect(
            SessionName.default(
                agentName: "claude-code", usedNames: ["claude-code", "claude-code-2"])
                == "claude-code-3")
    }

    @Test("the default name is the slug of an agent name with spaces and capitals")
    func anAgentNameWithSpacesGivesItsSlug() {
        #expect(SessionName.default(agentName: "Claude Code", usedNames: []) == "claude-code")
    }

    @Test("a used name is compared by its slug")
    func aUsedNameIsComparedBySlug() {
        #expect(
            SessionName.default(agentName: "claude-code", usedNames: ["Claude Code"])
                == "claude-code-2")
    }

    @Test("an agent name with an empty slug gives the default name session")
    func anEmptyAgentSlugGivesSession() {
        #expect(SessionName.default(agentName: "!!!", usedNames: []) == "session")
    }

    @Test("when session is used, an agent name with an empty slug gives session-2")
    func anEmptyAgentSlugWithSessionUsedGivesSessionTwo() {
        #expect(SessionName.default(agentName: "!!!", usedNames: ["session"]) == "session-2")
    }

    @Test("a used name with an empty slug does not change the fallback name")
    func usedNamesWithEmptySlugsAreIgnoredForTheFallback() {
        #expect(SessionName.default(agentName: "!!!", usedNames: ["", "???"]) == "session")
    }

    @Test("a used name with an empty slug does not change the agent slug")
    func aUsedNameWithAnEmptySlugIsIgnored() {
        #expect(SessionName.default(agentName: "claude-code", usedNames: ["!!!"]) == "claude-code")
    }

    @Test("with no used name, the fork name is the slug of the source name with -fork")
    func noUsedNameGivesTheSourceSlugWithFork() {
        #expect(SessionName.fork(sourceName: "Fix the Build", usedNames: []) == "fix-the-build-fork")
    }

    @Test("when the fork name is used, the fork name ends with -fork-2")
    func aUsedForkNameGivesForkTwo() {
        #expect(
            SessionName.fork(sourceName: "fix-the-build", usedNames: ["fix-the-build", "fix-the-build-fork"])
                == "fix-the-build-fork-2")
    }

    @Test("when -fork and -fork-2 are used, the fork name ends with -fork-3")
    func twoUsedForkNamesGiveForkThree() {
        #expect(
            SessionName.fork(
                sourceName: "fix-the-build", usedNames: ["fix-the-build-fork", "Fix the build fork 2"])
                == "fix-the-build-fork-3")
    }

    @Test("a source name with an empty slug gives the fork name session-fork")
    func anEmptySourceSlugGivesSessionFork() {
        #expect(SessionName.fork(sourceName: "!!!", usedNames: []) == "session-fork")
    }
}
