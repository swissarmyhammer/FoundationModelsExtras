import FoundationModelsExtras
import Testing

/// Holds the validation API that a host uses to the public surface: the
/// `pattern` of ``ElicitationStringSchema``,
/// ``ElicitationRequestedSchema/validationFailure(of:)`` and
/// ``ElicitationRequestedSchema/invalidAnswerReasonPrefix``.
///
/// The import is plain, with no `@testable`. When a member loses `public`,
/// this file does not compile.
@Suite("Elicitation validation over a plain import")
struct ElicitationValidationPublicSurfaceTests {
    /// The pattern of a five-digit postal code.
    private static let zipPattern = "^[0-9]{5}$"

    /// A form schema with one required field, `zip`, that must match
    /// ``zipPattern``.
    private static func zipSchema() -> ElicitationRequestedSchema {
        ElicitationRequestedSchema(
            properties: ["zip": .string(ElicitationStringSchema(pattern: zipPattern))], required: ["zip"])
    }

    @Test("a string schema made outside the package keeps its pattern")
    func aStringSchemaKeepsItsPattern() {
        #expect(ElicitationStringSchema(pattern: Self.zipPattern).pattern == Self.zipPattern)
    }

    @Test("a host checks an accepted form answer, and builds the decline reason from the failure")
    func aHostBuildsTheDeclineReason() throws {
        let failure = try #require(Self.zipSchema().validationFailure(of: ["zip": .string("1234")]))

        let reason = ElicitationRequestedSchema.invalidAnswerReasonPrefix + failure

        #expect(reason == #"the answer is not valid: the field "zip" does not match the pattern "^[0-9]{5}$""#)
    }

    @Test("a host finds no failure in a valid answer")
    func aValidAnswerHasNoFailure() {
        #expect(Self.zipSchema().validationFailure(of: ["zip": .string("12345")]) == nil)
    }
}
