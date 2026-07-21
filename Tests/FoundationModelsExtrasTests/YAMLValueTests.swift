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
}
