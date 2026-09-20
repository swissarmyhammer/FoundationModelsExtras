import Foundation

/// A `DotfolderStacking` over a stack of texts that splits each text into
/// its frontmatter and its body, and decodes the frontmatter into
/// `Metadata`.
///
/// A consumer picks a base stack, gives the decode, and then makes the same
/// calls as on the base:
///
/// ```swift
/// let stack = DotfolderStack(name: "myagent", workingDirectory: cwd)
/// let stenciled = StenciledDotfolderStack(
///   base: stack, partialLocations: ["_partials"], variables: vars)
/// let documents = FrontmatterDocumentStack(
///   base: stenciled, decode: SkillFrontmatter.decode)
///
/// documents.items(in: nil, named: "SKILL.md")   // each <id>/SKILL.md, rendered, with its metadata
/// ```
///
/// ## What one lookup gives
///
/// `Item` is `FrontmatterDocument<Metadata>`: `metadata` is the decoded
/// frontmatter, `nil` when the file holds no frontmatter block or the decode
/// failed; `content` is the text after the closing fence, byte for byte, or
/// the full text when there is no frontmatter block. Each text lookup gives
/// a document: `item(at:)`, `items(in:named:)` and `tree(_:)`. The URL view
/// (`urls`), the byte lookups (`data`, the ranged `data`, `size`) and the
/// directory lookups give what the base stack gives, unchanged.
///
/// ## The split and the decode
///
/// The split is `FrontmatterDocument.split(text:)`, a textual fence
/// recognition. This stack holds no knowledge of YAML: `decode` is given by
/// the consumer and receives the raw text between the fences. Extras gives
/// a default decode into `YAMLValue` through `init(base:onDiagnostic:)`,
/// and a consumer with its own schema gives its own decode.
///
/// ## The order of the layers
///
/// Each layer is generic, thus the order is the choice of the consumer:
///
/// - Over `StenciledDotfolderStack`: the whole file renders, then the split
///   runs. A `{{ }}` in a value of the frontmatter is rendered, the same as
///   one in the body.
/// - Over `DotfolderStack`: the split runs on the raw text. A `{{ }}` in
///   the frontmatter is not rendered. A consumer that does not want a
///   render inside its frontmatter uses this order.
///
/// Caution: a render before the split can write a character that changes
/// the YAML, for example a `:` or a `#` from the value of a variable. The
/// decode then fails on a document that was valid before the render.
///
/// ## Failures
///
/// A decode failure is not an error. It does not throw, and it does not
/// leave the document out: the document has `metadata == nil` and its
/// content, and one diagnostic goes to the `onDiagnostic` hook with the
/// file and the layer. A file with no frontmatter block is not a failure:
/// it gives `metadata == nil` and no diagnostic. A failure of the base
/// stack, for example a render failure, leaves the document out, as the
/// base does.
///
/// Constructing a document stack performs no file I/O, the same as the
/// stacks below it.
public struct FrontmatterDocumentStack<Base: DotfolderStacking, Metadata: Sendable>:
  DotfolderStacking
where Base.Item == String {
  /// What one lookup gives back: the decoded frontmatter and the content.
  public typealias Item = FrontmatterDocument<Metadata>

  /// One decode failure: the file whose frontmatter did not decode, the
  /// layer that holds it, and the text of the failure.
  public typealias Diagnostic = DotfolderStack.Diagnostic

  /// The hook that receives each decode failure.
  public typealias DiagnosticHandler = @Sendable (Diagnostic) -> Void

  /// The decode of the raw frontmatter text into `Metadata`. It gives
  /// `nil` when the text does not decode.
  public typealias MetadataDecoder = @Sendable (String) -> Metadata?

  /// The stack that gives the texts.
  public let base: Base

  /// The decode of the raw frontmatter text.
  private let decode: MetadataDecoder

  /// The hook that receives each decode failure.
  private let onDiagnostic: DiagnosticHandler

  /// The text of the diagnostic for a decode failure.
  private static var decodeFailureMessage: String { "the frontmatter did not decode" }

  /// Creates a document stack over `base`.
  ///
  /// - Parameters:
  ///   - base: The stack that gives the texts.
  ///   - decode: The decode of the raw frontmatter text into `Metadata`.
  ///     `nil` means the text did not decode.
  ///   - onDiagnostic: The hook that receives each decode failure. Defaults
  ///     to a hook that ignores it.
  public init(
    base: Base,
    decode: @escaping MetadataDecoder,
    onDiagnostic: @escaping DiagnosticHandler = { _ in }
  ) {
    self.base = base
    self.decode = decode
    self.onDiagnostic = onDiagnostic
  }

  /// The layers of the base stack, lowest to highest precedence.
  public var layers: [DotfolderStack.Layer] { base.layers }

  /// The winning copy of `relativePath`, with the layer that gave it and
  /// its text split into a document.
  ///
  /// - Parameter relativePath: A path relative to a layer's root, as
  ///   accepted by the base stack.
  /// - Returns: The item of the base stack with its text split, or `nil`
  ///   when the base stack gives no item.
  public func item(at relativePath: String) -> Located<Item>? {
    base.item(at: relativePath).map(document)
  }

  /// For each child directory of `subdirectory` in the union of the layers,
  /// the winning copy of `fileName` in that child directory, split into a
  /// document.
  ///
  /// - Parameters:
  ///   - subdirectory: A directory relative to a layer's root, as accepted
  ///     by the base stack. `nil` means the layer root.
  ///   - fileName: The name of the file to find in each child directory.
  /// - Returns: The items of the base stack with each text split.
  public func items(
    in subdirectory: String? = nil, named fileName: String
  ) -> [String: Located<Item>] {
    base.items(in: subdirectory, named: fileName).mapValues(document)
  }

  /// The recursive combined view of `subdirectory`, with each text split
  /// into a document.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, as
  ///   accepted by the base stack. `nil` means the layer root.
  /// - Returns: The view of the base stack with each text split.
  public func tree(_ subdirectory: String? = nil) -> [String: Located<Item>] {
    base.tree(subdirectory).mapValues(document)
  }

  /// The recursive combined view of `subdirectory` as URLs, as the base
  /// stack gives it.
  ///
  /// This stack makes its item from text, thus it does not filter this view:
  /// it holds every file of the base stack, whether or not `tree(_:)` gives
  /// a document for it.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, or
  ///   `nil` for the layer root itself.
  /// - Returns: What the base stack's `urls(_:)` gives.
  public func urls(_ subdirectory: String? = nil) -> [String: Located<URL>] {
    base.urls(subdirectory)
  }

  /// The immediate child directories of `subdirectory`, as the base stack
  /// gives them.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, or
  ///   `nil` for the layer root itself.
  /// - Returns: What the base stack's `childDirectories(of:)` gives.
  public func childDirectories(of subdirectory: String? = nil) -> [String: [DotfolderStack.Layer]] {
    base.childDirectories(of: subdirectory)
  }

  /// The layers that hold `relativeDirectory`, as the base stack gives
  /// them.
  ///
  /// - Parameter relativeDirectory: A directory relative to a layer's root,
  ///   or `nil` for the layer root itself.
  /// - Returns: What the base stack's `layerDirectories(_:)` gives.
  public func layerDirectories(_ relativeDirectory: String? = nil) -> [DotfolderStack.Layer] {
    base.layerDirectories(relativeDirectory)
  }

  /// The bytes of the winning copy of `relativePath`, not split.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: What the base stack's `data(_:)` gives.
  public func data(_ relativePath: String) -> Data? {
    base.data(relativePath)
  }

  /// A part of the winning copy of `relativePath`, not split.
  ///
  /// - Parameters:
  ///   - relativePath: A path relative to a layer's root.
  ///   - range: The byte offsets to read.
  /// - Returns: What the base stack's `data(_:in:)` gives.
  public func data(_ relativePath: String, in range: Range<Int>) -> Data? {
    base.data(relativePath, in: range)
  }

  /// The size in bytes of the winning copy of `relativePath` on disk, not
  /// of its content.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: What the base stack's `size(of:)` gives.
  public func size(of relativePath: String) -> Int? {
    base.size(of: relativePath)
  }

  /// Reports whether the combined view holds `relativePath`.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: What the base stack's `exists(_:)` gives.
  public func exists(_ relativePath: String) -> Bool {
    base.exists(relativePath)
  }

  /// Reports whether the winning copy of `relativePath` has the execute
  /// bit. The split does not change the mode of a file.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: What the base stack's `isExecutable(_:)` gives.
  public func isExecutable(_ relativePath: String) -> Bool {
    base.isExecutable(relativePath)
  }

  /// Splits the text of `located` and decodes its frontmatter.
  ///
  /// Every text lookup routes through this helper, so each of them applies
  /// the same split rule and the same failure rule.
  ///
  /// - Parameter located: An item of the base stack.
  /// - Returns: The same item with its text split into a document.
  private func document(_ located: Located<String>) -> Located<Item> {
    let split = FrontmatterDocument.split(text: located.value)
    let metadata = split.frontmatter.flatMap { decoded($0, of: located) }
    return Located(
      url: located.url, layer: located.layer,
      value: Item(metadata: metadata, content: split.body))
  }

  /// Decodes `frontmatter`, and reports a failure to `onDiagnostic`.
  ///
  /// - Parameters:
  ///   - frontmatter: The raw text between the fences.
  ///   - located: The item of the base stack that holds `frontmatter`.
  /// - Returns: The decoded metadata, or `nil` when the decode failed, in
  ///   which case the failure went to `onDiagnostic`.
  private func decoded(_ frontmatter: String, of located: Located<String>) -> Metadata? {
    guard let metadata = decode(frontmatter) else {
      onDiagnostic(
        Diagnostic(url: located.url, layer: located.layer, message: Self.decodeFailureMessage))
      return nil
    }
    return metadata
  }
}

extension FrontmatterDocumentStack where Metadata == YAMLValue {
  /// Creates a document stack over `base` with the default decode into
  /// `YAMLValue`.
  ///
  /// The decode parses the raw frontmatter text as one YAML document with
  /// `YAMLValue.parse(_:)`. Text that is not valid YAML does not decode,
  /// thus it gives `metadata == nil` and one diagnostic.
  ///
  /// - Parameters:
  ///   - base: The stack that gives the texts.
  ///   - onDiagnostic: The hook that receives each decode failure. Defaults
  ///     to a hook that ignores it.
  public init(base: Base, onDiagnostic: @escaping DiagnosticHandler = { _ in }) {
    self.init(base: base, decode: { try? YAMLValue.parse($0) }, onDiagnostic: onDiagnostic)
  }
}
