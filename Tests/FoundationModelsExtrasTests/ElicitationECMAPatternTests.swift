@testable import FoundationModelsExtras
import Foundation
import Testing

/// One pattern, one value, and whether the pattern matches a part of the
/// value as an ECMA-262 regular expression with no flags.
struct ECMAPatternCase: Sendable, CustomTestStringConvertible {
    /// What the case shows.
    let label: String

    /// The ECMA-262 pattern.
    let pattern: String

    /// The value in the answer.
    let value: String

    /// Whether ECMA-262 finds a match in the value.
    let matches: Bool

    /// The name of the case in the test report.
    var testDescription: String { label }
}

/// Exercises the ECMA-262 meaning of a `pattern` of ``ElicitationStringSchema``:
/// the search, and each part that ICU reads in a different way.
@Suite("Elicitation validation: a pattern is an ECMA-262 search")
struct ElicitationECMAPatternTests {
    /// The name of the field of each case.
    private static let field = "value"

    /// The cases. Each value is in the result that ECMA-262 gives.
    static let cases: [ECMAPatternCase] = [
        ECMAPatternCase(label: "a pattern with no anchors finds a match in the middle", pattern: "ab", value: "xaby", matches: true),
        ECMAPatternCase(label: "^ anchors the start", pattern: "^ab", value: "xab", matches: false),
        ECMAPatternCase(label: "$ does not match before a final line feed", pattern: "^[0-9]{5}$", value: "12345\n", matches: false),
        ECMAPatternCase(label: "an escaped $ is a literal", pattern: "\\$", value: "a$b", matches: true),
        ECMAPatternCase(label: "an escaped dot is a literal", pattern: "^a\\.b$", value: "axb", matches: false),
        ECMAPatternCase(label: "\\d matches an ASCII digit", pattern: "^\\d+$", value: "123", matches: true),
        ECMAPatternCase(label: "\\d does not match an Arabic-Indic digit", pattern: "^\\d+$", value: "١٢٣", matches: false),
        ECMAPatternCase(label: "\\D matches an Arabic-Indic digit", pattern: "^\\D$", value: "١", matches: true),
        ECMAPatternCase(label: "\\w does not match a letter with an accent", pattern: "^\\w+$", value: "café", matches: false),
        ECMAPatternCase(label: "\\W matches a letter with an accent", pattern: "^\\W$", value: "é", matches: true),
        ECMAPatternCase(label: "\\s matches U+FEFF", pattern: "^\\s$", value: "\u{FEFF}", matches: true),
        ECMAPatternCase(label: "\\s matches U+000B", pattern: "^\\s$", value: "\u{0B}", matches: true),
        ECMAPatternCase(label: "\\S does not match U+FEFF", pattern: "^\\S$", value: "\u{FEFF}", matches: false),
        ECMAPatternCase(label: "\\v matches U+000B", pattern: "^\\v$", value: "\u{0B}", matches: true),
        ECMAPatternCase(label: "\\v does not match a line feed", pattern: "^\\v$", value: "\n", matches: false),
        ECMAPatternCase(label: ". matches U+0085", pattern: "^.$", value: "\u{85}", matches: true),
        ECMAPatternCase(label: ". does not match a line feed", pattern: "^.$", value: "\n", matches: false),
        ECMAPatternCase(label: ". matches one code point out of the BMP", pattern: "^.$", value: "👍", matches: true),
        ECMAPatternCase(label: "\\b uses the ASCII \\w", pattern: "\\bcat\\b", value: "écat", matches: true),
        ECMAPatternCase(label: "\\B uses the ASCII \\w", pattern: "\\Bcat", value: "écat", matches: false),
        ECMAPatternCase(label: "\\d in a class does not match an Arabic-Indic digit", pattern: "^[\\d]+$", value: "١", matches: false),
        ECMAPatternCase(label: "\\d in a negated class leaves an Arabic-Indic digit", pattern: "^[^\\d]$", value: "١", matches: true),
        ECMAPatternCase(label: "\\D in a class matches an Arabic-Indic digit", pattern: "^[\\D]$", value: "١", matches: true),
        ECMAPatternCase(label: "\\D in a negated class matches an ASCII digit", pattern: "^[^\\D]$", value: "5", matches: true),
        ECMAPatternCase(label: "\\D in a negated class does not match a letter", pattern: "^[^\\D]$", value: "a", matches: false),
        ECMAPatternCase(label: "\\w in a class does not match a letter with an accent", pattern: "^[\\w]$", value: "é", matches: false),
        ECMAPatternCase(label: "\\s in a class matches U+FEFF", pattern: "^[\\s]$", value: "\u{FEFF}", matches: true),
        ECMAPatternCase(label: "\\b in a class is the backspace", pattern: "^[\\b]$", value: "\u{08}", matches: true),
        ECMAPatternCase(label: "an empty class matches nothing", pattern: "a[]", value: "a", matches: false),
        ECMAPatternCase(label: "[^] matches a line feed", pattern: "^[^]$", value: "\n", matches: true),
        ECMAPatternCase(label: "[ in a class is a literal", pattern: "^[[]$", value: "[", matches: true),
        ECMAPatternCase(label: "&& in a class is two literals", pattern: "^[a&&b]$", value: "&", matches: true),
    ]

    @Test("a pattern gives the ECMA-262 result", arguments: cases)
    func aPatternGivesTheECMAResult(_ patternCase: ECMAPatternCase) {
        let schema = ElicitationRequestedSchema(
            properties: [Self.field: .string(ElicitationStringSchema(pattern: patternCase.pattern))])

        let failure = schema.validationFailure(of: [Self.field: .string(patternCase.value)])

        let mismatch = #"the field "value" does not match the pattern "\#(patternCase.pattern)""#
        #expect(failure == (patternCase.matches ? nil : mismatch))
    }

    @Test("a pattern that does not compile after the translation fails the field")
    func aPatternThatDoesNotCompileFails() {
        let schema = ElicitationRequestedSchema(
            properties: [Self.field: .string(ElicitationStringSchema(pattern: "(a"))])

        #expect(
            schema.validationFailure(of: [Self.field: .string("a")])
                == #"the pattern "(a" of the field "value" is not a valid regular expression"#)
    }
}
