import Foundation
import FoundationModelsExtras
import Testing

/// Holds ``ToolContext/makeCompletionToken()`` to the public surface. A package
/// outside this one makes the completion token of a run with it.
///
/// The import is plain, with no `@testable`. When the function loses `public`,
/// this file does not compile. That is the assertion that matters, because the
/// caller is in another package, where `@testable` is not available.
@Suite("ToolContext.makeCompletionToken: make a completion token over the public surface")
struct ToolContextTokenPublicSurfaceTests {
    /// The number of tokens that the uniqueness test makes. It is much more
    /// than two, so a function that repeats a token only sometimes also fails.
    private static let madeTokenCount = 64

    // MARK: - Uniqueness

    @Test("each call makes a token of its own")
    func eachCallMakesADistinctToken() {
        let tokens = (0..<Self.madeTokenCount).map { _ in ToolContext.makeCompletionToken() }

        #expect(Set(tokens).count == Self.madeTokenCount)
        #expect(tokens.allSatisfy { !$0.isEmpty })
    }

    @Test("the token of the context and the token of the run plane have the same form")
    func theContextTokenAndTheRunPlaneTokenHaveTheSameForm() {
        let contextToken = ToolContext.makeCompletionToken()
        let runPlaneToken = RunPlane.makeCompletionToken()

        #expect(contextToken.count == runPlaneToken.count)
        #expect(contextToken != runPlaneToken)
    }

    // MARK: - The expression of the consumer

    @Test("with no context bound, the expression of the consumer makes a new token")
    func theConsumerExpressionFallsBackToANewToken() {
        // The expression that a tool outside this package writes: use the run
        // that the session tracks when there is one, and make a new token
        // when there is not.
        let commandID = ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()
        let laterCommandID = ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()

        // No context is bound here, so both expressions made a new token.
        #expect(ToolContext.current?.completionToken == nil)
        #expect(!commandID.isEmpty)
        #expect(commandID != laterCommandID)
    }
}
