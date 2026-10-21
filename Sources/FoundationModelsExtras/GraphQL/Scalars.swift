import Foundation
import Graphiti
import GraphQL
import OrderedCollections

/// A point in time, as the GraphQL `DateTime` scalar.
///
/// The text form is RFC 3339 in UTC with milliseconds, for example `2026-10-06T14:49:10.690Z`. The value keeps whole
/// milliseconds only, so that the value and its text form always round-trip with no change.
///
/// The Codable form is the text form. Thus the default Graphiti scalar closures serialize and parse the value, and the
/// engine needs no date strategy in its coders.
public struct DateTime: Codable, Sendable, Hashable, Comparable {
    /// The number of milliseconds in one second.
    private static let millisecondsPerSecond: Int64 = 1000

    /// The format of the millisecond part of the text, after the seconds.
    private static let millisecondFormat = ".%03lldZ"

    /// The RFC 3339 format with fractional seconds, to read text.
    private static let fractionalFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The RFC 3339 format with whole seconds. The millisecond part of the text is written with integer math, because
    /// a `Date` holds a `Double`, and the formatter can write `.001` as `.000`.
    private static let wholeSecondFormat = Date.ISO8601FormatStyle()

    /// The time, as whole milliseconds since 1970-01-01T00:00:00Z.
    public let millisecondsSince1970: Int64

    /// Makes a value from a date. The value rounds the date to the nearest millisecond.
    ///
    /// - Parameter date: The point in time.
    public init(_ date: Date) {
        let milliseconds = date.timeIntervalSince1970 * Double(Self.millisecondsPerSecond)
        millisecondsSince1970 = Int64(milliseconds.rounded())
    }

    /// Makes a value from whole milliseconds since 1970-01-01T00:00:00Z.
    ///
    /// - Parameter millisecondsSince1970: The time in milliseconds.
    public init(millisecondsSince1970: Int64) {
        self.millisecondsSince1970 = millisecondsSince1970
    }

    /// Makes a value from RFC 3339 text.
    ///
    /// - Parameter text: The time as RFC 3339 text, for example `2026-10-06T14:49:10.690Z`.
    /// - Throws: ``DateTimeError/notRFC3339(_:)`` when the text is not RFC 3339.
    public init(rfc3339 text: String) throws {
        do {
            try self.init(Self.fractionalFormat.parse(text))
        } catch {
            throw DateTimeError.notRFC3339(text)
        }
    }

    /// The RFC 3339 text, in UTC with milliseconds.
    public var rfc3339: String {
        let (seconds, milliseconds) = millisecondsSince1970.flooredQuotientAndRemainder(
            dividingBy: Self.millisecondsPerSecond
        )
        let wholeSeconds = Self.wholeSecondFormat.format(Date(timeIntervalSince1970: Double(seconds)))
        return wholeSeconds.dropLast() + String(format: Self.millisecondFormat, milliseconds)
    }

    /// The point in time as a `Date`.
    public var date: Date {
        Date(timeIntervalSince1970: Double(millisecondsSince1970) / Double(Self.millisecondsPerSecond))
    }

    /// Decodes the value from its RFC 3339 text.
    ///
    /// - Parameter decoder: The decoder that holds the text.
    /// - Throws: ``DateTimeError/notRFC3339(_:)`` when the text is not RFC 3339.
    public init(from decoder: any Decoder) throws {
        try self.init(rfc3339: decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the value as its RFC 3339 text.
    ///
    /// - Parameter encoder: The encoder that gets the text.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rfc3339)
    }

    /// Tells if a value is before a different value.
    ///
    /// - Parameters:
    ///   - lhs: The first value.
    ///   - rhs: The second value.
    /// - Returns: `true` when `lhs` is before `rhs`.
    public static func < (lhs: DateTime, rhs: DateTime) -> Bool {
        lhs.millisecondsSince1970 < rhs.millisecondsSince1970
    }
}

extension Int64 {
    /// Divides with the quotient rounded down, so that the remainder is never negative. A time before 1970 thus has a
    /// millisecond part from 0 to 999.
    ///
    /// - Parameter divisor: The divisor. It must be more than 0.
    /// - Returns: The quotient, rounded down, and the remainder.
    fileprivate func flooredQuotientAndRemainder(dividingBy divisor: Int64) -> (Int64, Int64) {
        let (quotient, remainder) = quotientAndRemainder(dividingBy: divisor)
        guard remainder < 0 else {
            return (quotient, remainder)
        }
        return (quotient - 1, remainder + divisor)
    }
}

/// An id, as the GraphQL `ID` scalar of ``SchemaBuilder/addToolkitIDScalar()``.
///
/// The output is a String. The input is a String or an Int, as the GraphQL spec says for `ID`, and an Int input
/// becomes its decimal text. The Codable form is the text.
///
/// The type is not named `GraphQLID`, because the GraphQL package already gives a `GraphQLID`: its built-in `ID`
/// scalar, whose input rules the toolkit scalar uses.
public struct ToolkitID: Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The text of the id.
    public let text: String

    /// Makes an id from its text.
    ///
    /// - Parameter text: The text of the id.
    public init(_ text: String) {
        self.text = text
    }

    /// Makes an id from a string literal.
    ///
    /// - Parameter value: The text of the id.
    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Decodes the id from its text.
    ///
    /// - Parameter decoder: The decoder that holds the text.
    /// - Throws: A decoding error when the value is not a String.
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    /// Encodes the id as its text.
    ///
    /// - Parameter encoder: The encoder that gets the text.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    /// The text of the id.
    public var description: String {
        text
    }
}

/// An error from the `DateTime` scalar.
public enum DateTimeError: Error, Equatable {
    /// The text is not RFC 3339. The value is the text.
    case notRFC3339(String)
}

/// An error from the `JSON` scalar.
public enum JSONScalarError: Error, Equatable {
    /// A resolver gave a value that is not a `Map`. The value is the name of its Swift type.
    case notAMap(String)
}

/// The `JSON` scalar: any JSON value. A `Map` value in Swift is a `JSON` value in GraphQL.
///
/// The scalar does not use the default Graphiti closures, because they send the value through `MapEncoder`, and
/// `MapEncoder` changes each `Bool` to a number. The scalar also writes each object with its keys in sorted order.
/// `MapDecoder` loses the key order of an object in the arguments, so a sorted order is the one order that is
/// deterministic.
public enum JSONScalar {
    /// The GraphQL name of the scalar.
    public static let name = "JSON"

    /// Gives the output value of a resolver in its canonical form.
    ///
    /// - Parameters:
    ///   - value: The value that a resolver gave.
    ///   - coders: The coders of the schema. The scalar does not use them.
    /// - Returns: The value with each object in sorted key order.
    /// - Throws: ``JSONScalarError/notAMap(_:)`` when the value is not a `Map`.
    @Sendable
    public static func serialize(_ value: Any, coders _: Coders) throws -> Map {
        guard let map = value as? Map else {
            throw JSONScalarError.notAMap(String(describing: type(of: value)))
        }
        return canonical(map)
    }

    /// Gives a value from the variables in its canonical form.
    ///
    /// - Parameters:
    ///   - map: The value from the variables.
    ///   - coders: The coders of the schema. The scalar does not use them.
    /// - Returns: The value with each object in sorted key order.
    @Sendable
    public static func parseValue(_ map: Map, coders _: Coders) -> Map {
        canonical(map)
    }

    /// Gives a literal value of the document in its canonical form.
    ///
    /// - Parameters:
    ///   - literal: The literal value in the document.
    ///   - coders: The coders of the schema. The scalar does not use them.
    /// - Returns: The value with each object in sorted key order.
    /// - Throws: A GraphQL error when a number in the literal is not valid.
    @Sendable
    public static func parseLiteral(_ literal: GraphQL.Value, coders _: Coders) throws -> Map {
        try canonical(valueFromASTUntyped(valueAST: literal))
    }

    /// Puts the keys of each object in a value in sorted order.
    ///
    /// - Parameter map: The value.
    /// - Returns: The same value with each object in sorted key order.
    public static func canonical(_ map: Map) -> Map {
        switch map {
        case .array(let items):
            return .array(items.map(canonical))
        case .dictionary(let fields):
            var sorted = fields.mapValues(canonical)
            sorted.sort { $0.key < $1.key }
            return .dictionary(sorted)
        case .undefined, .null, .bool, .number, .string:
            return map
        }
    }
}

extension SchemaBuilder {
    /// Adds the `DateTime` and `JSON` scalars of the toolkit to the schema.
    ///
    /// It does not add an `ID` scalar, because a package can register its own scalar named `ID`, and a second type
    /// of that name breaks the schema. ``addToolkitIDScalar()`` adds the toolkit `ID` scalar.
    ///
    /// - Returns: This builder, for method chaining.
    @discardableResult
    public func addToolkitScalars() -> Self {
        add {
            Scalar(DateTime.self)
                .description("A point in time: RFC 3339 text in UTC with milliseconds, like 2026-10-06T14:49:10.690Z.")
            Scalar(
                Map.self,
                as: JSONScalar.name,
                serialize: JSONScalar.serialize,
                parseValue: JSONScalar.parseValue,
                parseLiteral: JSONScalar.parseLiteral
            )
            .description("Any JSON value. The keys of each object are in sorted order.")
        }
    }

    /// Adds the toolkit `ID` scalar to the schema: a ``ToolkitID`` in Swift is an `ID` in GraphQL.
    ///
    /// The scalar gives a String, and takes a String or an Int, as the GraphQL spec says for `ID`. An endpoint that
    /// maps ``IDChange`` calls this method, so that its `added`, `changed` and `removed` are `[ID!]!`. A package
    /// that registers its own scalar named `ID` does not call it.
    ///
    /// - Returns: This builder, for method chaining.
    @discardableResult
    public func addToolkitIDScalar() -> Self {
        add {
            Scalar(
                ToolkitID.self,
                as: GraphQL.GraphQLID.name,
                parseValue: { map, _ in try GraphQL.GraphQLID.parseValue(map) },
                parseLiteral: { literal, _ in try GraphQL.GraphQLID.parseLiteral(literal) }
            )
            .description("A unique id: a String in the output, and a String or an Int in the input.")
        }
    }
}
