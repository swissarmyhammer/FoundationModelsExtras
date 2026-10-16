import FoundationModelsExtras
import Testing

/// One value and the length that JSON Schema gives it: the count of its
/// Unicode code points.
struct CodePointLengthCase: Sendable, CustomTestStringConvertible {
    /// What the case shows.
    let label: String

    /// The value of the field.
    let value: String

    /// The count of the Unicode code points of the value.
    let length: Int

    /// The name of the case in the test report.
    var testDescription: String { label }
}

/// Exercises the public text rules of ``ElicitationValidation``, with a plain
/// import: a client that checks a form field calls the same functions as
/// ``ElicitationRequestedSchema/validationFailure(of:)``.
@Suite("Elicitation validation: the public text rules")
struct ElicitationValidationRulesTests {
    /// The name of the field of each schema check.
    private static let field = "value"

    /// The length cases.
    static let lengthCases: [CodePointLengthCase] = [
        CodePointLengthCase(label: "an empty value has the length 0", value: "", length: 0),
        CodePointLengthCase(label: "an ASCII word counts each letter", value: "cafe", length: 4),
        CodePointLengthCase(label: "a precomposed letter is one code point", value: "caf\u{E9}", length: 4),
        CodePointLengthCase(label: "e and a combining accent are two code points", value: "e\u{301}", length: 2),
        CodePointLengthCase(label: "an emoji out of the BMP is one code point", value: "👍", length: 1),
        CodePointLengthCase(
            label: "a family emoji of three persons is five code points",
            value: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", length: 5),
    ]

    @Test("patternMatches gives the ECMA-262 search result", arguments: ElicitationECMAPatternTests.cases)
    func patternMatchesGivesTheECMAResult(_ patternCase: ECMAPatternCase) {
        #expect(ElicitationValidation.patternMatches(patternCase.value, pattern: patternCase.pattern) == patternCase.matches)
    }

    @Test("patternMatches gives nil for a pattern that does not compile")
    func patternMatchesGivesNilForAPatternThatDoesNotCompile() {
        #expect(ElicitationValidation.patternMatches("a", pattern: "(a") == nil)
    }

    @Test("patternMatches is a search: an unanchored pattern matches a part of the value")
    func patternMatchesIsASearch() {
        #expect(ElicitationValidation.patternMatches("123456", pattern: "[0-9]{5}") == true)
        #expect(ElicitationValidation.patternMatches("123456", pattern: "^[0-9]{5}$") == false)
    }

    @Test("codePointLength counts Unicode code points", arguments: lengthCases)
    func codePointLengthCountsCodePoints(_ lengthCase: CodePointLengthCase) {
        #expect(ElicitationValidation.codePointLength(lengthCase.value) == lengthCase.length)
    }

    @Test("validationFailure uses codePointLength for maxLength", arguments: lengthCases)
    func validationFailureUsesTheSameLength(_ lengthCase: CodePointLengthCase) {
        let atTheLimit = ElicitationRequestedSchema(
            properties: [Self.field: .string(ElicitationStringSchema(maxLength: lengthCase.length))])
        #expect(atTheLimit.validationFailure(of: [Self.field: .string(lengthCase.value)]) == nil)

        guard lengthCase.length > 0 else { return }
        let belowTheLength = ElicitationRequestedSchema(
            properties: [Self.field: .string(ElicitationStringSchema(maxLength: lengthCase.length - 1))])
        #expect(belowTheLength.validationFailure(of: [Self.field: .string(lengthCase.value)]) != nil)
    }
}
