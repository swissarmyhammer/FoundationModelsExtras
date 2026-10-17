import FoundationModelsExtras
import Testing

/// One answer to a requested schema, the issue that the validator must give
/// for it, and the English sentence of that issue.
struct ElicitationIssueCase: Sendable, CustomTestStringConvertible {
    /// What the case shows.
    let label: String

    /// The requested schema.
    let schema: ElicitationRequestedSchema

    /// The content of the answer.
    let content: [String: ElicitationValue]?

    /// The issue that the validator must give.
    let issue: ElicitationValidationIssue

    /// The sentence that ``ElicitationRequestedSchema/validationFailure(of:)``
    /// must give.
    let failure: String

    /// The name of the case in the test report.
    var testDescription: String { label }

    /// Makes a case with one property, `field`, and one value for it.
    ///
    /// - Parameters:
    ///   - label: What the case shows.
    ///   - field: The name of the field.
    ///   - schema: The schema of the field.
    ///   - value: The value in the answer.
    ///   - kind: The kind of issue that the validator must give.
    ///   - failure: The sentence that the validator must give.
    static func field(
        _ label: String, _ field: String, schema: ElicitationPrimitiveSchema, value: ElicitationValue,
        kind: ElicitationValidationIssue.Kind, failure: String
    ) -> ElicitationIssueCase {
        ElicitationIssueCase(
            label: label, schema: ElicitationRequestedSchema(properties: [field: schema]), content: [field: value],
            issue: ElicitationValidationIssue(field: field, kind: kind), failure: failure)
    }
}

/// Exercises ``ElicitationRequestedSchema/validationIssue(of:)`` and
/// ``ElicitationValidationIssue/failureText``: each kind of issue, with its
/// limit and its English sentence, through the public API only.
@Suite("Elicitation validation: the issue as data that a UI can localize")
struct ElicitationValidationIssueTests {
    /// The values of the select fixtures.
    private static let colors = ["red", "green"]

    /// One case for each kind of issue, and for each expected type and format.
    static let cases: [ElicitationIssueCase] = [
        ElicitationIssueCase(
            label: "a required field that the answer does not give",
            schema: ElicitationRequestedSchema(
                properties: ["name": .string(ElicitationStringSchema())], required: ["name"]),
            content: nil, issue: ElicitationValidationIssue(field: "name", kind: .requiredFieldMissing),
            failure: #"the field "name" is required, and the answer does not give it"#),
        ElicitationIssueCase(
            label: "a key that is not in the properties",
            schema: ElicitationRequestedSchema(properties: ["name": .string(ElicitationStringSchema())]),
            content: ["nickname": .string("A")],
            issue: ElicitationValidationIssue(field: "nickname", kind: .fieldNotInSchema),
            failure: #"the field "nickname" is not in the requested schema"#),
        .field(
            "a string field with a number", "name", schema: .string(ElicitationStringSchema()), value: .number(1),
            kind: .wrongType(expected: .string), failure: #"the field "name" must be a string"#),
        .field(
            "a single select field with a number", "color",
            schema: .singleSelect(ElicitationSingleSelectSchema(values: colors)), value: .number(1),
            kind: .wrongType(expected: .string), failure: #"the field "color" must be a string"#),
        .field(
            "a number field with a string", "score", schema: .number(ElicitationNumberSchema(type: .number)),
            value: .string("high"), kind: .wrongType(expected: .number),
            failure: #"the field "score" must be a number"#),
        .field(
            "an integer field with a fraction", "count", schema: .number(ElicitationNumberSchema(type: .integer)),
            value: .number(2.5), kind: .wrongType(expected: .wholeNumber),
            failure: #"the field "count" must be a whole number"#),
        .field(
            "a boolean field with a string", "agree", schema: .boolean(ElicitationBooleanSchema()),
            value: .string("yes"), kind: .wrongType(expected: .boolean),
            failure: #"the field "agree" must be true or false"#),
        .field(
            "a multi select field with a string", "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: colors)), value: .string("red"),
            kind: .wrongType(expected: .stringList), failure: #"the field "toppings" must be a list of strings"#),
        .field(
            "a string shorter than the minimum length", "name", schema: .string(ElicitationStringSchema(minLength: 2)),
            value: .string("A"), kind: .tooShort(minLength: 2),
            failure: #"the field "name" must have 2 or more characters"#),
        .field(
            "a string longer than the maximum length, in code points", "letter",
            schema: .string(ElicitationStringSchema(maxLength: 1)), value: .string("e\u{301}"),
            kind: .tooLong(maxLength: 1), failure: #"the field "letter" must have 1 or fewer characters"#),
        .field(
            "a string that does not match the pattern", "zip",
            schema: .string(ElicitationStringSchema(pattern: "^[0-9]{5}$")), value: .string("1234"),
            kind: .patternMismatch(pattern: "^[0-9]{5}$"),
            failure: #"the field "zip" does not match the pattern "^[0-9]{5}$""#),
        .field(
            "a pattern that does not compile", "zip", schema: .string(ElicitationStringSchema(pattern: "[0-9")),
            value: .string("12345"), kind: .invalidPattern(pattern: "[0-9"),
            failure: #"the pattern "[0-9" of the field "zip" is not a valid regular expression"#),
        .field(
            "an email address with no @", "email", schema: .string(ElicitationStringSchema(format: .email)),
            value: .string("ada.example.com"), kind: .invalidFormat(.email),
            failure: #"the field "email" is not a valid email address"#),
        .field(
            "a URI with no scheme", "homepage", schema: .string(ElicitationStringSchema(format: .uri)),
            value: .string("example dot com"), kind: .invalidFormat(.uri),
            failure: #"the field "homepage" is not a valid URI"#),
        .field(
            "a date that is not in the calendar", "birthday", schema: .string(ElicitationStringSchema(format: .date)),
            value: .string("2024-02-30"), kind: .invalidFormat(.date),
            failure: #"the field "birthday" is not a valid date (yyyy-MM-dd)"#),
        .field(
            "a date and time with no time", "meeting", schema: .string(ElicitationStringSchema(format: .dateTime)),
            value: .string("2024-02-29"), kind: .invalidFormat(.dateTime),
            failure: #"the field "meeting" is not a valid date and time (ISO 8601)"#),
        .field(
            "a number less than a fractional minimum", "ratio",
            schema: .number(ElicitationNumberSchema(type: .number, minimum: 0.5)), value: .number(0.25),
            kind: .belowMinimum(0.5), failure: #"the field "ratio" must be 0.5 or more"#),
        .field(
            "a number more than the maximum", "age",
            schema: .number(ElicitationNumberSchema(type: .integer, maximum: 150)), value: .number(151),
            kind: .aboveMaximum(150), failure: #"the field "age" must be 150 or less"#),
        .field(
            "a single select value that is not in the values", "color",
            schema: .singleSelect(ElicitationSingleSelectSchema(values: colors)), value: .string("blue"),
            kind: .valueNotAllowed(allowed: colors),
            failure: #"the field "color" must be one of these values: "red", "green""#),
        .field(
            "a multi select item that is not in the values", "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: colors)), value: .stringArray(["red", "blue"]),
            kind: .itemNotAllowed(value: "blue", allowed: colors),
            failure: #"the field "toppings" has the value "blue", which is not one of these values: "red", "green""#),
        .field(
            "a multi select with fewer items than the minimum", "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: colors, minItems: 1)), value: .stringArray([]),
            kind: .tooFewItems(minItems: 1), failure: #"the field "toppings" must have 1 or more values"#),
        .field(
            "a multi select with more items than the maximum", "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: colors, maxItems: 1)),
            value: .stringArray(["red", "green"]), kind: .tooManyItems(maxItems: 1),
            failure: #"the field "toppings" must have 1 or fewer values"#),
    ]

    @Test("an invalid answer gives its issue, and the failure is the English text of that issue", arguments: cases)
    func anInvalidAnswerGivesItsIssue(_ issueCase: ElicitationIssueCase) {
        let issue = issueCase.schema.validationIssue(of: issueCase.content)

        #expect(issue == issueCase.issue)
        #expect(issue?.failureText == issueCase.failure)
        #expect(issueCase.schema.validationFailure(of: issueCase.content) == issueCase.failure)
    }

    @Test("a valid answer gives no issue")
    func aValidAnswerGivesNoIssue() {
        let schema = ElicitationRequestedSchema(
            properties: ["name": .string(ElicitationStringSchema(minLength: 1))], required: ["name"])

        #expect(schema.validationIssue(of: ["name": .string("Ada")]) == nil)
    }

    @Test("with two failed fields, the issue names the field that comes first in name order")
    func theFirstFailedFieldInNameOrderIsTheIssue() {
        let short = ElicitationPrimitiveSchema.string(ElicitationStringSchema(minLength: 2))
        let schema = ElicitationRequestedSchema(properties: ["alpha": short, "beta": short])

        let issue = schema.validationIssue(of: ["beta": .string("b"), "alpha": .string("a")])

        #expect(issue == ElicitationValidationIssue(field: "alpha", kind: .tooShort(minLength: 2)))
    }

    @Test("an issue with no field names the whole answer in its English text")
    func anIssueWithNoFieldNamesTheAnswer() {
        let issue = ElicitationValidationIssue(field: nil, kind: .fieldNotInSchema)

        #expect(issue.failureText == "the answer is not in the requested schema")
    }
}

extension ElicitationValidationTests {
    @Test(
        "the issue of each invalid value names its field, and its English text is the failure",
        arguments: invalidCases)
    func theIssueOfAnInvalidValueGivesItsFailure(_ fieldCase: ElicitationFieldCase) {
        let schema = ElicitationRequestedSchema(properties: [fieldCase.field: fieldCase.schema])

        let issue = schema.validationIssue(of: [fieldCase.field: fieldCase.value])

        #expect(issue?.field == fieldCase.field)
        #expect(issue?.failureText == fieldCase.failure)
    }
}
