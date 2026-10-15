import Foundation

extension ElicitationRequestedSchema {
    /// The start of the decline reason for an accepted form answer that is
    /// not valid.
    ///
    /// A host that finds a failure with ``validationFailure(of:)`` makes the
    /// reason of its decline as `invalidAnswerReasonPrefix + failure`.
    public static let invalidAnswerReasonPrefix = "the answer is not valid: "

    /// Tells why `content` is not a valid answer to this schema.
    ///
    /// The function is pure. It examines the fields in the order of their
    /// names, and gives the first failure that it finds:
    ///
    /// - A field in ``required`` that `content` does not give. `nil` content
    ///   gives no field.
    /// - A key of `content` that is not in ``properties``, when the schema
    ///   declares one or more properties. A schema with no properties asks
    ///   for a free answer: each key of the answer is then valid, and only
    ///   the ``required`` fields are checked.
    /// - A value of the wrong type. A string property and a single select take
    ///   ``ElicitationValue/string(_:)``, a number property takes
    ///   ``ElicitationValue/number(_:)`` (a whole number when its type is
    ///   ``ElicitationNumberSchema/NumberType/integer``), a boolean property
    ///   takes ``ElicitationValue/boolean(_:)``, and a multi select takes
    ///   ``ElicitationValue/stringArray(_:)``.
    /// - A value that breaks a rule of its property: the length in characters,
    ///   the pattern (a match of the whole value), the format, the minimum and
    ///   the maximum, the values of a select, and the number of items of a
    ///   multi select.
    ///
    /// A host calls this function before it sends or posts an accepted form
    /// answer. For example, a router that also posts the answer as mail to the
    /// model, or a UI that keeps a form open for a correction. When the
    /// function gives a failure, the host keeps the form open, or it sends
    /// `.decline(reason: ElicitationRequestedSchema.invalidAnswerReasonPrefix + failure)`
    /// in place of the accept. ``ToolContext/elicit(_:)`` does the same check
    /// before it gives an answer to a run.
    ///
    /// - Parameter content: The content of an accepted form answer.
    /// - Returns: `nil` when the content is valid, or one sentence that names
    ///   the first field that failed and the rule that it broke.
    public func validationFailure(of content: [String: ElicitationValue]?) -> String? {
        let content = content ?? [:]
        let names = Set(required ?? []).union(content.keys).sorted()
        return names.lazy.compactMap { failure(ofField: $0, in: content) }.first
    }

    /// Tells why the field `name` of `content` is not valid.
    ///
    /// - Parameters:
    ///   - name: The name of a required field, or a key of `content`.
    ///   - content: The content of the answer.
    /// - Returns: `nil` when the field is valid, or the sentence of its failure.
    private func failure(ofField name: String, in content: [String: ElicitationValue]) -> String? {
        guard let value = content[name] else {
            return "\(FailureText.field(name)) is required, and the answer does not give it"
        }
        guard let property = properties[name] else {
            // A schema with no properties asks for a free answer, so each key
            // of the answer is valid.
            return properties.isEmpty ? nil : "\(FailureText.field(name)) is not in the requested schema"
        }
        return property.failure(of: value, field: name)
    }
}

extension ElicitationPrimitiveSchema {
    /// Tells why `value` is not a valid value of this property.
    ///
    /// - Parameters:
    ///   - value: The value in the answer.
    ///   - name: The name of the field.
    /// - Returns: `nil` when the value is valid, or the sentence of its failure.
    fileprivate func failure(of value: ElicitationValue, field name: String) -> String? {
        switch self {
        case .string(let schema):
            guard case .string(let text) = value else { return typeFailure(field: name) }
            return schema.failure(of: text, field: name)
        case .number(let schema):
            guard case .number(let number) = value, schema.admits(number) else { return typeFailure(field: name) }
            return schema.boundFailure(of: number, field: name)
        case .boolean:
            guard case .boolean = value else { return typeFailure(field: name) }
            return nil
        case .singleSelect(let schema):
            guard case .string(let choice) = value else { return typeFailure(field: name) }
            return schema.failure(of: choice, field: name)
        case .multiSelect(let schema):
            guard case .stringArray(let choices) = value else { return typeFailure(field: name) }
            return schema.failure(of: choices, field: name)
        }
    }

    /// The words for the type of value that this property takes.
    private var expectedValue: String {
        switch self {
        case .string, .singleSelect: "a string"
        case .number(let schema): schema.type == .integer ? "a whole number" : "a number"
        case .boolean: "true or false"
        case .multiSelect: "a list of strings"
        }
    }

    /// The failure of a value of the wrong type.
    ///
    /// - Parameter name: The name of the field.
    /// - Returns: The sentence of the failure.
    private func typeFailure(field name: String) -> String {
        "\(FailureText.field(name)) must be \(expectedValue)"
    }
}

extension ElicitationStringSchema {
    /// Tells why `text` is not a valid value of this property.
    ///
    /// - Parameters:
    ///   - text: The value in the answer.
    ///   - name: The name of the field.
    /// - Returns: `nil` when the value is valid, or the sentence of its failure.
    fileprivate func failure(of text: String, field name: String) -> String? {
        FailureText.countFailure(
            field: name, count: text.count, minimum: minLength, maximum: maxLength, unit: "characters")
            ?? patternFailure(of: text, field: name)
            ?? formatFailure(of: text, field: name)
    }

    /// Tells why `text` does not match ``pattern``.
    ///
    /// - Parameters:
    ///   - text: The value in the answer.
    ///   - name: The name of the field.
    /// - Returns: `nil` when there is no pattern or the whole value matches
    ///   it, or the sentence of the failure.
    private func patternFailure(of text: String, field name: String) -> String? {
        guard let pattern else { return nil }
        guard let matches = Self.wholeValue(text, matches: pattern) else {
            return "the pattern \(FailureText.quoted(pattern)) of \(FailureText.field(name)) "
                + "is not a valid regular expression"
        }
        return matches ? nil : "\(FailureText.field(name)) does not match the pattern \(FailureText.quoted(pattern))"
    }

    /// Tells why `text` does not have ``format``.
    ///
    /// - Parameters:
    ///   - text: The value in the answer.
    ///   - name: The name of the field.
    /// - Returns: `nil` when there is no format or the value has it, or the
    ///   sentence of the failure.
    private func formatFailure(of text: String, field name: String) -> String? {
        guard let format, !format.accepts(text) else { return nil }
        return "\(FailureText.field(name)) is not a valid \(format.valueName)"
    }

    /// Tells if `pattern` matches the whole of `text`.
    ///
    /// - Parameters:
    ///   - text: The value in the answer.
    ///   - pattern: A regular expression in the syntax of
    ///     `NSRegularExpression`.
    /// - Returns: `nil` when `pattern` does not compile, else whether a match
    ///   covers all of `text`.
    private static func wholeValue(_ text: String, matches pattern: String) -> Bool? {
        guard (try? NSRegularExpression(pattern: pattern)) != nil,
            let anchored = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z")
        else { return nil }
        return anchored.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

extension ElicitationStringFormat {
    /// The words for a value of this format.
    fileprivate var valueName: String {
        switch self {
        case .email: "email address"
        case .uri: "URI"
        case .date: "date (yyyy-MM-dd)"
        case .dateTime: "date and time (ISO 8601)"
        }
    }

    /// Tells if `text` has this format.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `true` when `text` has this format.
    fileprivate func accepts(_ text: String) -> Bool {
        switch self {
        case .email: text.wholeMatch(of: #/[^@\s]+@[^@\s]+\.[^@\s]+/#) != nil
        case .uri: !(URL(string: text)?.scheme ?? "").isEmpty
        case .date: Self.isCalendarDate(text)
        case .dateTime: Self.isDateTime(text)
        }
    }

    /// Tells if `text` is a date of the form `yyyy-MM-dd` that the calendar
    /// has.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `true` when `text` is such a date.
    private static func isCalendarDate(_ text: String) -> Bool {
        guard let parts = text.wholeMatch(of: #/([0-9]{4})-([0-9]{2})-([0-9]{2})/#)?.output,
            let year = Int(parts.1), let month = Int(parts.2), let day = Int(parts.3)
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return DateComponents(year: year, month: month, day: day).isValidDate(in: calendar)
    }

    /// Tells if `text` is an ISO 8601 date with a time and a time zone, with
    /// or without fractional seconds.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `true` when `text` is such a date and time.
    private static func isDateTime(_ text: String) -> Bool {
        let whole = ISO8601DateFormatter()
        whole.formatOptions = .withInternetDateTime
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return whole.date(from: text) != nil || fractional.date(from: text) != nil
    }
}

extension ElicitationNumberSchema {
    /// Tells if `number` is of ``type``: any number, or a whole number for
    /// ``NumberType/integer``.
    ///
    /// - Parameter number: The value in the answer.
    /// - Returns: `true` when `number` is of the type.
    fileprivate func admits(_ number: Double) -> Bool {
        type == .number || number == number.rounded()
    }

    /// Tells why `number` is less than ``minimum`` or more than ``maximum``.
    ///
    /// - Parameters:
    ///   - number: The value in the answer.
    ///   - name: The name of the field.
    /// - Returns: `nil` when the value is in its limits, or the sentence of
    ///   the failure.
    fileprivate func boundFailure(of number: Double, field name: String) -> String? {
        switch Bound.check(number, minimum: minimum, maximum: maximum) {
        case .within: nil
        case .below(let minimum): "\(FailureText.field(name)) must be \(FailureText.number(minimum)) or more"
        case .above(let maximum): "\(FailureText.field(name)) must be \(FailureText.number(maximum)) or less"
        }
    }
}

extension ElicitationSingleSelectSchema {
    /// Tells why `choice` is not one of ``values``.
    ///
    /// - Parameters:
    ///   - choice: The value in the answer.
    ///   - name: The name of the field.
    /// - Returns: `nil` when `choice` is one of the values, or the sentence of
    ///   the failure.
    fileprivate func failure(of choice: String, field name: String) -> String? {
        guard !values.contains(choice) else { return nil }
        return "\(FailureText.field(name)) must be one of these values: \(FailureText.quotedList(values))"
    }
}

extension ElicitationMultiSelectSchema {
    /// Tells why `choices` is not a valid selection: an item that is not one
    /// of ``values``, fewer items than ``minItems``, or more items than
    /// ``maxItems``.
    ///
    /// - Parameters:
    ///   - choices: The value in the answer.
    ///   - name: The name of the field.
    /// - Returns: `nil` when the selection is valid, or the sentence of its
    ///   failure.
    fileprivate func failure(of choices: [String], field name: String) -> String? {
        if let unknown = choices.first(where: { !values.contains($0) }) {
            return "\(FailureText.field(name)) has the value \(FailureText.quoted(unknown)), "
                + "which is not one of these values: \(FailureText.quotedList(values))"
        }
        return FailureText.countFailure(
            field: name, count: choices.count, minimum: minItems, maximum: maxItems, unit: "values")
    }
}

/// The parts of the sentences that the validation gives.
private enum FailureText {
    /// The end of the text of a `Double` that is a whole number.
    private static let wholeNumberSuffix = ".0"

    /// The words that name the field `name`.
    ///
    /// - Parameter name: The name of the field.
    /// - Returns: The words, for example `the field "zip"`.
    static func field(_ name: String) -> String {
        "the field \(quoted(name))"
    }

    /// `text` in double quotation marks.
    ///
    /// - Parameter text: The text.
    /// - Returns: The quoted text.
    static func quoted(_ text: String) -> String {
        "\"\(text)\""
    }

    /// Each of `values` in double quotation marks, with commas between them.
    ///
    /// - Parameter values: The values.
    /// - Returns: The list, for example `"red", "green"`.
    static func quotedList(_ values: [String]) -> String {
        values.map(quoted).joined(separator: ", ")
    }

    /// The text of `value`, with no `.0` at the end of a whole number.
    ///
    /// - Parameter value: The number.
    /// - Returns: The text, for example `150` or `0.5`.
    static func number(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(wholeNumberSuffix) ? String(text.dropLast(wholeNumberSuffix.count)) : text
    }

    /// Tells why `count` is less than `minimum` or more than `maximum`.
    ///
    /// - Parameters:
    ///   - name: The name of the field.
    ///   - count: The number of characters or items in the value.
    ///   - minimum: The smallest count that the field takes, or `nil`.
    ///   - maximum: The largest count that the field takes, or `nil`.
    ///   - unit: The word for what `count` counts, for example `characters`.
    /// - Returns: `nil` when the count is in its limits, or the sentence of
    ///   the failure.
    static func countFailure(field name: String, count: Int, minimum: Int?, maximum: Int?, unit: String) -> String? {
        switch Bound.check(count, minimum: minimum, maximum: maximum) {
        case .within: nil
        case .below(let minimum): "\(field(name)) must have \(minimum) or more \(unit)"
        case .above(let maximum): "\(field(name)) must have \(maximum) or fewer \(unit)"
        }
    }
}

/// Where a value is, relative to an optional minimum and an optional maximum.
private enum Bound<Value: Comparable> {
    /// The value is in its limits.
    case within

    /// The value is less than this minimum.
    case below(Value)

    /// The value is more than this maximum.
    case above(Value)

    /// Compares `value` with `minimum`, then with `maximum`.
    ///
    /// - Parameters:
    ///   - value: The value to compare.
    ///   - minimum: The smallest value that is in the limits, or `nil`.
    ///   - maximum: The largest value that is in the limits, or `nil`.
    /// - Returns: Where `value` is, relative to the limits.
    static func check(_ value: Value, minimum: Value?, maximum: Value?) -> Bound {
        if let minimum, value < minimum {
            return .below(minimum)
        }
        if let maximum, value > maximum {
            return .above(maximum)
        }
        return .within
    }
}
