import Foundation
import Testing

@testable import FoundationModelsExtras

/// Behavioral tests for `YAMLValue.decoded(as:)` — the "YAMLValue decoder"
/// plan.md §11 calls for: re-encoding a `YAMLValue` tree into any
/// `Decodable` type. Exercised directly here (independent of
/// `LayeredYAMLDocument`, whose own Codable round-trip test covers the
/// merged-tree path).
@Suite struct YAMLValueTests {
  private struct Nested: Decodable, Equatable {
    let flag: Bool
    let count: Int
    let ratio: Double
    let name: String
    let items: [String]
  }

  @Test func decodesEveryScalarShapeIntoAMatchingStruct() throws {
    let value = YAMLValue.dictionary([
      "flag": .bool(true),
      "count": .int(7),
      "ratio": .double(2.5),
      "name": .string("hello"),
      "items": .array([.string("a"), .string("b")]),
    ])

    let decoded = try value.decoded(as: Nested.self)

    #expect(
      decoded == Nested(flag: true, count: 7, ratio: 2.5, name: "hello", items: ["a", "b"]))
  }

  @Test func decodesNestedDictionariesRecursively() throws {
    struct Outer: Decodable, Equatable {
      struct Inner: Decodable, Equatable {
        let value: Int
      }
      let inner: Inner
    }

    let value = YAMLValue.dictionary(["inner": .dictionary(["value": .int(42)])])

    let decoded = try value.decoded(as: Outer.self)

    #expect(decoded == Outer(inner: .init(value: 42)))
  }

  @Test func decodesNullIntoAnOptionalAsNil() throws {
    struct WithOptional: Decodable, Equatable {
      let maybe: String?
    }

    let value = YAMLValue.dictionary(["maybe": .null])

    let decoded = try value.decoded(as: WithOptional.self)

    #expect(decoded == WithOptional(maybe: nil))
  }

  @Test func decodingFailureThrowsYAMLValueDecodingErrorWithAMessage() throws {
    struct RequiresInt: Decodable {
      let count: Int
    }

    let value = YAMLValue.dictionary(["count": .string("not a number")])

    #expect(throws: YAMLValueDecodingError.self) {
      _ = try value.decoded(as: RequiresInt.self)
    }
  }

  @Test func decodesATopLevelArrayOfStrings() throws {
    let value = YAMLValue.array([.string("x"), .string("y"), .string("z")])

    let decoded = try value.decoded(as: [String].self)

    #expect(decoded == ["x", "y", "z"])
  }

  // MARK: - Parsing text

  @Test func parsesEachScalarShapeAMappingAndASequence() throws {
    let text = "flag: true\ncount: 3\nratio: 1.5\nname: x\nnothing: ~\nitems:\n  - a\n  - b\n"

    let value = try YAMLValue.parse(text)

    #expect(
      value
        == .dictionary([
          "flag": .bool(true),
          "count": .int(3),
          "ratio": .double(1.5),
          "name": .string("x"),
          "nothing": .null,
          "items": .array([.string("a"), .string("b")]),
        ]))
  }

  @Test func parsesEmptyTextAsNull() throws {
    #expect(try YAMLValue.parse("") == .null)
  }

  @Test func parsingMalformedTextThrowsWithTheLine() {
    #expect {
      try YAMLValue.parse("name: [unclosed\nnext: 1\n")
    } throws: { error in
      guard let parsingError = error as? YAMLValueParsingError else { return false }
      switch parsingError {
      case .malformed(let line, let message):
        return line != nil && !message.isEmpty
      }
    }
  }

  @Test func parsingAMappingWithASequenceKeyThrows() {
    #expect(throws: YAMLValueParsingError.self) {
      _ = try YAMLValue.parse("? [a, b]\n: value\n")
    }
  }
}
