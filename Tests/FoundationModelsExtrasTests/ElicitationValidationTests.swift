@testable import FoundationModelsExtras
import Foundation
import Testing

/// Exercises the `pattern` of ``ElicitationStringSchema``: the decode, the
/// encode with the wire key `pattern`, and the init.
@Suite("Elicitation string schema: the pattern goes over the wire")
struct ElicitationStringPatternTests {
    /// The pattern of a five-digit postal code.
    private static let zipPattern = "^[0-9]{5}$"

    /// The wire key of the pattern.
    private static let patternKey = "pattern"

    /// Encodes `schema` and gives the JSON object.
    ///
    /// - Parameter schema: The schema to encode.
    /// - Returns: The keys and values of the encoded schema.
    private static func encodedObject(of schema: ElicitationStringSchema) throws -> [String: Any] {
        let data = try JSONEncoder().encode(schema)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a decoded pattern is kept, and the encode writes it with the key \"pattern\"")
    func aDecodedPatternRoundTrips() throws {
        let json = #"{"type": "string", "pattern": "^[0-9]{5}$"}"#

        let schema = try JSONDecoder().decode(ElicitationStringSchema.self, from: Data(json.utf8))

        #expect(schema.pattern == Self.zipPattern)
        let object = try Self.encodedObject(of: schema)
        #expect(object[Self.patternKey] as? String == Self.zipPattern)
        let decodedAgain = try JSONDecoder().decode(ElicitationStringSchema.self, from: JSONEncoder().encode(schema))
        #expect(decodedAgain == schema)
    }

    @Test("the init keeps the pattern")
    func theInitKeepsThePattern() throws {
        let schema = ElicitationStringSchema(minLength: 1, pattern: Self.zipPattern)

        #expect(schema.pattern == Self.zipPattern)
        #expect(try Self.encodedObject(of: schema)[Self.patternKey] as? String == Self.zipPattern)
    }

    @Test("a schema with no pattern writes no pattern key")
    func noPatternWritesNoKey() throws {
        let object = try Self.encodedObject(of: ElicitationStringSchema())

        #expect(object[Self.patternKey] == nil)
    }
}

/// One field, one value, and the failure that the validator must give for
/// them, or `nil` when the value is valid.
struct ElicitationFieldCase: Sendable, CustomTestStringConvertible {
    /// What the case shows.
    let label: String

    /// The name of the field.
    let field: String

    /// The schema of the field.
    let schema: ElicitationPrimitiveSchema

    /// The value in the answer.
    let value: ElicitationValue

    /// The sentence that the validator must give, or `nil` for a valid value.
    let failure: String?

    /// The name of the case in the test report.
    var testDescription: String { label }
}

/// Exercises ``ElicitationRequestedSchema/validationFailure(of:)``: one valid
/// and one invalid value for each rule, and the rules of the whole answer.
@Suite("Elicitation validation: an accepted form answer against its requested schema")
struct ElicitationValidationTests {
    /// The values of the single select fixture.
    private static let colors = ["red", "green", "blue"]

    /// The values of the multi select fixture.
    private static let toppings = ["cheese", "olives"]

    /// The pattern of a five-digit postal code.
    private static let zipPattern = "^[0-9]{5}$"

    /// The valid value of each rule.
    static let validCases: [ElicitationFieldCase] = [
        ElicitationFieldCase(
            label: "a string", field: "name", schema: .string(ElicitationStringSchema()),
            value: .string("Ada"), failure: nil),
        ElicitationFieldCase(
            label: "a number", field: "score", schema: .number(ElicitationNumberSchema(type: .number)),
            value: .number(0.5), failure: nil),
        ElicitationFieldCase(
            label: "an integer", field: "count", schema: .number(ElicitationNumberSchema(type: .integer)),
            value: .number(3), failure: nil),
        ElicitationFieldCase(
            label: "a boolean", field: "agree", schema: .boolean(ElicitationBooleanSchema()),
            value: .boolean(true), failure: nil),
        ElicitationFieldCase(
            label: "a minimum length", field: "name", schema: .string(ElicitationStringSchema(minLength: 2)),
            value: .string("Al"), failure: nil),
        ElicitationFieldCase(
            label: "a maximum length", field: "name", schema: .string(ElicitationStringSchema(maxLength: 5)),
            value: .string("Grace"), failure: nil),
        ElicitationFieldCase(
            label: "a length in code points, not in UTF-16 code units: one emoji is one code point", field: "letter",
            schema: .string(ElicitationStringSchema(maxLength: 1)), value: .string("👍"), failure: nil),
        ElicitationFieldCase(
            label: "a length in code points, not in Characters: a family emoji is five code points", field: "family",
            schema: .string(ElicitationStringSchema(minLength: 5)), value: .string("👨‍👩‍👧"), failure: nil),
        ElicitationFieldCase(
            label: "a pattern", field: "zip", schema: .string(ElicitationStringSchema(pattern: zipPattern)),
            value: .string("12345"), failure: nil),
        ElicitationFieldCase(
            label: "a pattern that matches the whole value through an alternative", field: "code",
            schema: .string(ElicitationStringSchema(pattern: "a|ab")), value: .string("ab"), failure: nil),
        ElicitationFieldCase(
            label: "a pattern with no anchors that matches a part of the value", field: "zip",
            schema: .string(ElicitationStringSchema(pattern: "[0-9]{5}")), value: .string("123456"), failure: nil),
        ElicitationFieldCase(
            label: "an email address", field: "email", schema: .string(ElicitationStringSchema(format: .email)),
            value: .string("ada@example.com"), failure: nil),
        ElicitationFieldCase(
            label: "a URI", field: "homepage", schema: .string(ElicitationStringSchema(format: .uri)),
            value: .string("https://example.com/a"), failure: nil),
        ElicitationFieldCase(
            label: "a date", field: "birthday", schema: .string(ElicitationStringSchema(format: .date)),
            value: .string("2024-02-29"), failure: nil),
        ElicitationFieldCase(
            label: "a date and time", field: "meeting", schema: .string(ElicitationStringSchema(format: .dateTime)),
            value: .string("2024-02-29T10:15:00Z"), failure: nil),
        ElicitationFieldCase(
            label: "a date and time with fractional seconds and an offset", field: "meeting",
            schema: .string(ElicitationStringSchema(format: .dateTime)),
            value: .string("2024-02-29T10:15:00.250+02:00"), failure: nil),
        ElicitationFieldCase(
            label: "a minimum", field: "age", schema: .number(ElicitationNumberSchema(type: .integer, minimum: 0)),
            value: .number(0), failure: nil),
        ElicitationFieldCase(
            label: "a maximum", field: "age", schema: .number(ElicitationNumberSchema(type: .integer, maximum: 150)),
            value: .number(150), failure: nil),
        ElicitationFieldCase(
            label: "a single select", field: "color",
            schema: .singleSelect(ElicitationSingleSelectSchema(values: colors)),
            value: .string("green"), failure: nil),
        ElicitationFieldCase(
            label: "a multi select in its count limits", field: "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: toppings, minItems: 1, maxItems: 1)),
            value: .stringArray(["cheese"]), failure: nil),
    ]

    /// The invalid value of each rule, with the sentence of its failure.
    static let invalidCases: [ElicitationFieldCase] = [
        ElicitationFieldCase(
            label: "a string field with a number", field: "name", schema: .string(ElicitationStringSchema()),
            value: .number(3), failure: #"the field "name" must be a string"#),
        ElicitationFieldCase(
            label: "a number field with a string", field: "score",
            schema: .number(ElicitationNumberSchema(type: .number)),
            value: .string("high"), failure: #"the field "score" must be a number"#),
        ElicitationFieldCase(
            label: "an integer field with a fraction", field: "count",
            schema: .number(ElicitationNumberSchema(type: .integer)),
            value: .number(2.5), failure: #"the field "count" must be a whole number"#),
        ElicitationFieldCase(
            label: "a boolean field with a string", field: "agree", schema: .boolean(ElicitationBooleanSchema()),
            value: .string("yes"), failure: #"the field "agree" must be true or false"#),
        ElicitationFieldCase(
            label: "a single select field with a number", field: "color",
            schema: .singleSelect(ElicitationSingleSelectSchema(values: colors)),
            value: .number(1), failure: #"the field "color" must be a string"#),
        ElicitationFieldCase(
            label: "a multi select field with a string", field: "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: toppings)),
            value: .string("cheese"), failure: #"the field "toppings" must be a list of strings"#),
        ElicitationFieldCase(
            label: "a string shorter than the minimum length", field: "name",
            schema: .string(ElicitationStringSchema(minLength: 2)),
            value: .string("A"), failure: #"the field "name" must have 2 or more characters"#),
        ElicitationFieldCase(
            label: "a string longer than the maximum length", field: "name",
            schema: .string(ElicitationStringSchema(maxLength: 5)),
            value: .string("Gracie"), failure: #"the field "name" must have 5 or fewer characters"#),
        ElicitationFieldCase(
            label: "a combining mark is a code point of its own", field: "letter",
            schema: .string(ElicitationStringSchema(maxLength: 1)),
            value: .string("e\u{301}"), failure: #"the field "letter" must have 1 or fewer characters"#),
        ElicitationFieldCase(
            label: "a family emoji is one Character but five code points", field: "family",
            schema: .string(ElicitationStringSchema(maxLength: 4)),
            value: .string("👨‍👩‍👧"), failure: #"the field "family" must have 4 or fewer characters"#),
        ElicitationFieldCase(
            label: "a string that does not match the pattern", field: "zip",
            schema: .string(ElicitationStringSchema(pattern: zipPattern)),
            value: .string("1234"), failure: #"the field "zip" does not match the pattern "^[0-9]{5}$""#),
        ElicitationFieldCase(
            label: "an anchored pattern that matches only a part of the value", field: "zip",
            schema: .string(ElicitationStringSchema(pattern: zipPattern)),
            value: .string("123456"), failure: #"the field "zip" does not match the pattern "^[0-9]{5}$""#),
        ElicitationFieldCase(
            label: "a pattern that does not compile", field: "zip",
            schema: .string(ElicitationStringSchema(pattern: "[0-9")),
            value: .string("12345"),
            failure: #"the pattern "[0-9" of the field "zip" is not a valid regular expression"#),
        ElicitationFieldCase(
            label: "an email address with no @", field: "email",
            schema: .string(ElicitationStringSchema(format: .email)),
            value: .string("ada.example.com"), failure: #"the field "email" is not a valid email address"#),
        ElicitationFieldCase(
            label: "a URI with no scheme", field: "homepage", schema: .string(ElicitationStringSchema(format: .uri)),
            value: .string("example dot com"), failure: #"the field "homepage" is not a valid URI"#),
        ElicitationFieldCase(
            label: "a date that is not in the calendar", field: "birthday",
            schema: .string(ElicitationStringSchema(format: .date)),
            value: .string("2024-02-30"), failure: #"the field "birthday" is not a valid date (yyyy-MM-dd)"#),
        ElicitationFieldCase(
            label: "a date with one-digit parts", field: "birthday",
            schema: .string(ElicitationStringSchema(format: .date)),
            value: .string("2024-2-3"), failure: #"the field "birthday" is not a valid date (yyyy-MM-dd)"#),
        ElicitationFieldCase(
            label: "a date and time with no time", field: "meeting",
            schema: .string(ElicitationStringSchema(format: .dateTime)),
            value: .string("2024-02-29"),
            failure: #"the field "meeting" is not a valid date and time (ISO 8601)"#),
        ElicitationFieldCase(
            label: "a number less than the minimum", field: "age",
            schema: .number(ElicitationNumberSchema(type: .integer, minimum: 0)),
            value: .number(-1), failure: #"the field "age" must be 0 or more"#),
        ElicitationFieldCase(
            label: "a number less than a fractional minimum", field: "ratio",
            schema: .number(ElicitationNumberSchema(type: .number, minimum: 0.5)),
            value: .number(0.25), failure: #"the field "ratio" must be 0.5 or more"#),
        ElicitationFieldCase(
            label: "a number more than the maximum", field: "age",
            schema: .number(ElicitationNumberSchema(type: .integer, maximum: 150)),
            value: .number(151), failure: #"the field "age" must be 150 or less"#),
        ElicitationFieldCase(
            label: "a single select value that is not in the values", field: "color",
            schema: .singleSelect(ElicitationSingleSelectSchema(values: colors)),
            value: .string("purple"),
            failure: #"the field "color" must be one of these values: "red", "green", "blue""#),
        ElicitationFieldCase(
            label: "a multi select item that is not in the values", field: "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: toppings)),
            value: .stringArray(["cheese", "ham"]),
            failure: #"the field "toppings" has the value "ham", which is not one of these values: "cheese", "olives""#),
        ElicitationFieldCase(
            label: "a multi select with fewer items than the minimum", field: "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: toppings, minItems: 1)),
            value: .stringArray([]), failure: #"the field "toppings" must have 1 or more values"#),
        ElicitationFieldCase(
            label: "a multi select with more items than the maximum", field: "toppings",
            schema: .multiSelect(ElicitationMultiSelectSchema(values: toppings, maxItems: 1)),
            value: .stringArray(["cheese", "olives"]), failure: #"the field "toppings" must have 1 or fewer values"#),
    ]

    @Test("a valid value gives no failure", arguments: validCases)
    func aValidValueGivesNoFailure(_ fieldCase: ElicitationFieldCase) {
        let schema = ElicitationRequestedSchema(properties: [fieldCase.field: fieldCase.schema])

        #expect(schema.validationFailure(of: [fieldCase.field: fieldCase.value]) == nil)
    }

    @Test("an invalid value gives one sentence that names the field and the rule", arguments: invalidCases)
    func anInvalidValueGivesItsFailure(_ fieldCase: ElicitationFieldCase) {
        let schema = ElicitationRequestedSchema(properties: [fieldCase.field: fieldCase.schema])

        #expect(schema.validationFailure(of: [fieldCase.field: fieldCase.value]) == fieldCase.failure)
    }

    // MARK: - The rules of the whole answer

    /// A schema with one required string field, `name`.
    private static let nameRequired = ElicitationRequestedSchema(
        properties: ["name": .string(ElicitationStringSchema())], required: ["name"])

    @Test("nil content with a required field fails and names the field")
    func nilContentWithARequiredFieldFails() {
        #expect(
            Self.nameRequired.validationFailure(of: nil)
                == #"the field "name" is required, and the answer does not give it"#)
    }

    @Test("content that gives each required field passes")
    func contentWithEachRequiredFieldPasses() {
        #expect(Self.nameRequired.validationFailure(of: ["name": .string("Ada")]) == nil)
    }

    @Test("nil content with no required field passes")
    func nilContentWithNoRequiredFieldPasses() {
        let schema = ElicitationRequestedSchema(properties: ["name": .string(ElicitationStringSchema())])

        #expect(schema.validationFailure(of: nil) == nil)
    }

    @Test("a key that is not in the properties fails and names the key")
    func anUnknownKeyFails() {
        let content: [String: ElicitationValue] = ["name": .string("Ada"), "nickname": .string("A")]

        #expect(
            Self.nameRequired.validationFailure(of: content)
                == #"the field "nickname" is not in the requested schema"#)
    }

    @Test("a schema with no properties asks for a free answer, so each key of the answer is valid")
    func aSchemaWithNoPropertiesTakesEachKey() {
        let freeAnswer = ElicitationRequestedSchema(properties: [:])
        let content: [String: ElicitationValue] = ["repo": .string("swissarmyhammer"), "count": .number(3)]

        #expect(freeAnswer.validationFailure(of: content) == nil)
        #expect(freeAnswer.validationFailure(of: nil) == nil)
    }

    @Test("a schema with no properties still checks its required fields")
    func aSchemaWithNoPropertiesChecksItsRequiredFields() {
        let freeAnswer = ElicitationRequestedSchema(properties: [:], required: ["repo"])

        #expect(
            freeAnswer.validationFailure(of: ["other": .string("x")])
                == #"the field "repo" is required, and the answer does not give it"#)
    }

    @Test("with two failed fields, the failure names the field that comes first in name order")
    func theFirstFailedFieldInNameOrderIsNamed() {
        let short = ElicitationPrimitiveSchema.string(ElicitationStringSchema(minLength: 2))
        let schema = ElicitationRequestedSchema(properties: ["alpha": short, "beta": short])

        let failure = schema.validationFailure(of: ["beta": .string("b"), "alpha": .string("a")])

        #expect(failure == #"the field "alpha" must have 2 or more characters"#)
    }
}
