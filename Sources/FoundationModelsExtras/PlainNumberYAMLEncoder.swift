import Foundation
import Yams

/// Encodes a value as YAML text in which each `Double` and `Float` is plain
/// decimal text: `6.0` and `0.25`, never `6e+0` and `2.5e-1`.
///
/// Yams' own `YAMLEncoder` writes a `Double` in scientific notation, and with
/// 15 significant digits only, so `0.1 + 0.2` reads back as `0.3`. This
/// encoder builds the Yams `Node` tree itself. A `Double` or a `Float` becomes
/// its shortest text that reads back as the same value, with the exponent
/// written out as digits; every other `YAMLEncodable` value, such as a `Date`,
/// a `String` or an `Int`, becomes the node that Yams gives it. The tree is
/// then written with Yams' default emitter options, the options that
/// `YAMLEncoder()` uses.
enum PlainNumberYAMLEncoder {
  /// Encodes `value` as YAML text.
  ///
  /// - Parameter value: The value to encode.
  /// - Returns: The YAML text, which ends with a line terminator.
  /// - Throws: The error of the encode of `value`, such as an
  ///   `EncodingError`, or the `YamlError` of the emitter.
  static func yaml<Value: Encodable>(of value: Value) throws -> String {
    let root = NodeSlot()
    try root.encode(value, at: [])
    return try Yams.serialize(node: root.node)
  }
}

/// The text of a floating-point number as YAML writes it: plain decimal text
/// with no exponent, or `.inf`, `-.inf` and `.nan`.
private enum PlainDecimal {
  /// The mark of the exponent in the `description` of a number.
  private static let exponentMark: Character = "e"

  /// The mark of the decimal point.
  private static let point: Character = "."

  /// The sign of a negative number.
  private static let minus = "-"

  /// The digit that fills the places the exponent moves the point across.
  private static let zero = "0"

  /// Gives the YAML text of `number`.
  ///
  /// A finite number gives its shortest text that reads back as the same
  /// value, with any exponent written out as digits. A whole number keeps
  /// its `.0`, so the text still reads as a float.
  ///
  /// - Parameter number: The number.
  /// - Returns: The text, such as `6.0`, `0.25`, `0.00001` or `.inf`.
  static func text<Number: BinaryFloatingPoint & LosslessStringConvertible>(
    of number: Number
  ) -> String {
    guard !number.isNaN else {
      return ".nan"
    }
    guard number.isFinite else {
      return number < 0 ? "-.inf" : ".inf"
    }
    return expanded(number.description)
  }

  /// Writes out the exponent of `text` as digits.
  ///
  /// - Parameter text: The `description` of a finite number, such as
  ///   `1.5e-05` or `0.25`.
  /// - Returns: `text` with no exponent, such as `0.000015`; `text` itself
  ///   when it holds no exponent.
  private static func expanded(_ text: String) -> String {
    guard let mark = text.firstIndex(of: exponentMark),
      let exponent = Int(text[text.index(after: mark)...])
    else {
      return text
    }
    let mantissa = text[..<mark]
    let sign = mantissa.hasPrefix(minus) ? minus : ""
    let parts = mantissa.dropFirst(sign.count).split(
      separator: point, omittingEmptySubsequences: false)
    let whole = parts.first.map(String.init) ?? ""
    let fraction = parts.dropFirst().first.map(String.init) ?? ""
    return sign + placingPoint(in: whole + fraction, at: whole.count + exponent)
  }

  /// Puts the decimal point into `digits`.
  ///
  /// - Parameters:
  ///   - digits: The significant digits, with no point.
  ///   - position: The number of digits in front of the point. Zero or less
  ///     puts zeros in front of `digits`; more than the count of `digits`
  ///     puts zeros behind them.
  /// - Returns: The decimal text, which always holds a point and a digit on
  ///   each side of it.
  private static func placingPoint(in digits: String, at position: Int) -> String {
    guard position > 0 else {
      return zero + String(point) + String(repeating: zero, count: -position) + digits
    }
    guard position < digits.count else {
      let zeros = String(repeating: zero, count: position - digits.count)
      return digits + zeros + String(point) + zero
    }
    let split = digits.index(digits.startIndex, offsetBy: position)
    return digits[..<split] + String(point) + digits[split...]
  }
}

/// One place in the YAML tree that an encode fills: a scalar or other whole
/// node, a mapping or a sequence.
///
/// A class, because each container of the `Encoder` protocol writes into
/// the place of its parent after the parent has handed the container out:
/// the parent and its containers share the one place.
private final class NodeSlot {
  /// What a slot holds.
  enum Content {
    /// Nothing is encoded yet.
    case empty

    /// A whole node, such as a scalar.
    case node(Node)

    /// A mapping, in the order the keys were encoded.
    case mapping([(key: String, slot: NodeSlot)])

    /// A sequence, in the order the elements were encoded.
    case sequence([NodeSlot])
  }

  /// The node of a `nil` value.
  static var null: Node { Node("null", Tag(.null)) }

  /// What the slot holds.
  var content = Content.empty

  /// The Yams node of the slot. A slot with nothing encoded gives `null`.
  var node: Node {
    switch content {
    case .empty:
      return Self.null
    case .node(let node):
      return node
    case .mapping(let pairs):
      return Node(pairs.map { (Node($0.key), $0.slot.node) })
    case .sequence(let slots):
      return Node(slots.map(\.node))
    }
  }

  /// The pairs of the slot, empty when the slot holds no mapping.
  private var pairs: [(key: String, slot: NodeSlot)] {
    guard case .mapping(let pairs) = content else {
      return []
    }
    return pairs
  }

  /// The elements of the slot, empty when the slot holds no sequence.
  var elements: [NodeSlot] {
    guard case .sequence(let elements) = content else {
      return []
    }
    return elements
  }

  /// Makes the slot a mapping, unless it is one already.
  func makeMapping() {
    content = .mapping(pairs)
  }

  /// Makes the slot a sequence, unless it is one already.
  func makeSequence() {
    content = .sequence(elements)
  }

  /// Gives a new slot for the value of `key`, in place of any value the
  /// key had. Makes the slot a mapping.
  ///
  /// - Parameter key: The key.
  /// - Returns: The slot of the value.
  func child(named key: String) -> NodeSlot {
    let child = NodeSlot()
    var pairs = pairs
    if let index = pairs.firstIndex(where: { $0.key == key }) {
      pairs[index].slot = child
    } else {
      pairs.append((key, child))
    }
    content = .mapping(pairs)
    return child
  }

  /// Gives a new slot at the end of the sequence. Makes the slot a sequence.
  ///
  /// - Returns: The slot of the new element.
  func appendElement() -> NodeSlot {
    let element = NodeSlot()
    content = .sequence(elements + [element])
    return element
  }

  /// Encodes `value` into the slot: a floating-point number, such as a
  /// `Double` or a `Float`, as plain decimal text, another `YAMLEncodable`
  /// value as its Yams node, and any other value through its own
  /// `encode(to:)`.
  ///
  /// - Parameters:
  ///   - value: The value.
  ///   - codingPath: The coding path of the slot.
  /// - Throws: The error of the encode of `value`.
  func encode<Value: Encodable>(_ value: Value, at codingPath: [any CodingKey]) throws {
    if let number = value as? any BinaryFloatingPoint & LosslessStringConvertible {
      content = .node(Node(PlainDecimal.text(of: number), Tag(.float)))
    } else if let scalar = value as? any YAMLEncodable {
      content = .node(scalar.box())
    } else {
      try value.encode(to: NodeEncoder(slot: self, codingPath: codingPath))
    }
  }
}

/// The `Encoder` that fills one ``NodeSlot``.
private struct NodeEncoder: Encoder {
  /// The slot the encode fills.
  let slot: NodeSlot

  let codingPath: [any CodingKey]

  var userInfo: [CodingUserInfoKey: Any] { [:] }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    slot.makeMapping()
    return KeyedEncodingContainer(KeyedNodeContainer<Key>(slot: slot, codingPath: codingPath))
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    slot.makeSequence()
    return UnkeyedNodeContainer(slot: slot, codingPath: codingPath)
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    SingleValueNodeContainer(slot: slot, codingPath: codingPath)
  }
}

/// The keyed container that fills a mapping ``NodeSlot``.
private struct KeyedNodeContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  /// The key of the encoder of a superclass.
  private static var superKey: String { "super" }

  /// The mapping slot.
  let slot: NodeSlot

  let codingPath: [any CodingKey]

  mutating func encodeNil(forKey key: Key) throws {
    slot.child(named: key.stringValue).content = .node(NodeSlot.null)
  }

  mutating func encode<Value: Encodable>(_ value: Value, forKey key: Key) throws {
    try slot.child(named: key.stringValue).encode(value, at: codingPath + [key])
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type, forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    encoder(forKey: key).container(keyedBy: keyType)
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    encoder(forKey: key).unkeyedContainer()
  }

  mutating func superEncoder() -> any Encoder {
    NodeEncoder(slot: slot.child(named: Self.superKey), codingPath: codingPath)
  }

  mutating func superEncoder(forKey key: Key) -> any Encoder {
    encoder(forKey: key)
  }

  /// Gives the encoder of the value of `key`.
  ///
  /// - Parameter key: The key.
  /// - Returns: An encoder that fills a new slot for the value.
  private func encoder(forKey key: Key) -> NodeEncoder {
    NodeEncoder(slot: slot.child(named: key.stringValue), codingPath: codingPath + [key])
  }
}

/// The unkeyed container that fills a sequence ``NodeSlot``.
private struct UnkeyedNodeContainer: UnkeyedEncodingContainer {
  /// The sequence slot.
  let slot: NodeSlot

  let codingPath: [any CodingKey]

  var count: Int { slot.elements.count }

  mutating func encodeNil() throws {
    slot.appendElement().content = .node(NodeSlot.null)
  }

  mutating func encode<Value: Encodable>(_ value: Value) throws {
    let path = codingPath + [IndexCodingKey(intValue: count)]
    try slot.appendElement().encode(value, at: path)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type
  ) -> KeyedEncodingContainer<NestedKey> {
    nextEncoder().container(keyedBy: keyType)
  }

  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    nextEncoder().unkeyedContainer()
  }

  mutating func superEncoder() -> any Encoder {
    nextEncoder()
  }

  /// Gives the encoder of a new element at the end of the sequence.
  ///
  /// - Returns: An encoder that fills the slot of the new element.
  private func nextEncoder() -> NodeEncoder {
    let path = codingPath + [IndexCodingKey(intValue: count)]
    return NodeEncoder(slot: slot.appendElement(), codingPath: path)
  }
}

/// The single-value container that fills one ``NodeSlot``.
private struct SingleValueNodeContainer: SingleValueEncodingContainer {
  /// The slot.
  let slot: NodeSlot

  let codingPath: [any CodingKey]

  mutating func encodeNil() throws {
    slot.content = .node(NodeSlot.null)
  }

  mutating func encode<Value: Encodable>(_ value: Value) throws {
    try slot.encode(value, at: codingPath)
  }
}

/// The coding key of an element of a sequence: its index.
private struct IndexCodingKey: CodingKey {
  /// The index of the element.
  let index: Int

  var intValue: Int? { index }

  var stringValue: String { String(index) }

  init(intValue: Int) {
    index = intValue
  }

  init?(stringValue: String) {
    guard let index = Int(stringValue) else {
      return nil
    }
    self.index = index
  }
}
