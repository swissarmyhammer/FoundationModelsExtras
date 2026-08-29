import Testing

@testable import Operations

/// Trivially-true placeholder confirming the `OperationsTests` target
/// builds and runs against `Operations`.
@Test func placeholderPasses() {
    #expect(true)
}

/// Confirms `Operations` re-exports `ArgumentParser`: this target declares
/// no dependency on swift-argument-parser of its own, yet `ParsableCommand`
/// is visible purely through `import Operations`.
///
/// A type-only reference wouldn't prove the re-export actually works — it
/// would compile against `ParsableCommand.Type` even if that symbol resolved
/// to nothing meaningful. Instead this defines and parses a real
/// `ParsableCommand`, which both requires the re-exported ArgumentParser
/// machinery to compile and exercises its parsing behavior at runtime. This
/// is the mechanism `@Operation`'s macro-generated `Command` types rely on.
@Test func argumentParserIsVisibleThroughOperations() throws {
    struct Greet: ParsableCommand {
        @Argument var name: String
    }

    let parsed = try Greet.parse(["World"])

    #expect(parsed.name == "World")
}
