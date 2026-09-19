import Foundation

/// A resolved location together with the layer that won it and the value
/// the stack made from it: the swissarmyhammer `FileSource` idea, so that a
/// consumer can show "where did this come from" in diagnostics (`/status`,
/// `/memory` headers).
///
/// `Item` is what one lookup gives back. `DotfolderStack` gives the text of
/// the file (`Item == String`). A stack that is layered on top of it gives
/// the same shape with a richer item, for example a rendered text or a
/// `(metadata, content)` pair. The layer is present at each level: a
/// consumer needs it for the trust decision and for its own provenance.
public struct Located<Item: Sendable>: Sendable {
  /// The winning file's URL, as joined onto its layer root.
  public var url: URL
  /// The layer that won.
  public var layer: DotfolderStack.Layer
  /// The value the stack made from the winning file.
  public var value: Item

  /// Creates a located value. Exposed publicly so that a consumer can build
  /// fixtures and fakes (for example for its own tests) with a plain
  /// `import FoundationModelsExtras`, no `@testable` access required.
  ///
  /// - Parameters:
  ///   - url: The winning file's URL.
  ///   - layer: The layer that won.
  ///   - value: The value made from the winning file.
  public init(url: URL, layer: DotfolderStack.Layer, value: Item) {
    self.url = url
    self.layer = layer
    self.value = value
  }
}

extension DotfolderStack {
  /// One failure of a stack that is layered over `DotfolderStack`: the file
  /// that failed, the layer that holds it, and the text of the failure.
  ///
  /// `StenciledDotfolderStack` gives one for a render failure, and
  /// `FrontmatterDocumentStack` gives one for a decode failure. The failure
  /// does not throw out of a lookup; it goes to the `onDiagnostic` hook of
  /// the stack.
  public struct Diagnostic: Sendable {
    /// The URL of the file that failed.
    public var url: URL
    /// The layer that holds the file.
    public var layer: Layer
    /// The text of the failure.
    public var message: String

    /// Creates a diagnostic. Exposed publicly so that a consumer can build
    /// fixtures and fakes with a plain `import FoundationModelsExtras`.
    ///
    /// - Parameters:
    ///   - url: The URL of the file that failed.
    ///   - layer: The layer that holds the file.
    ///   - message: The text of the failure.
    public init(url: URL, layer: Layer, message: String) {
      self.url = url
      self.layer = layer
      self.message = message
    }
  }
}

/// The interface of a layered dotfolder stack: one combined view of the
/// directory trees of all the layers, and the only file access a consumer
/// needs.
///
/// Each conforming stack has the same shape and differs only in `Item`, what
/// one lookup gives back. `DotfolderStack` gives the text of the winning
/// file. A stack layered on top of it gets its files from its base and gives
/// a richer item, thus a consumer composes the layers that it needs and only
/// `DotfolderStack` touches the disk.
///
/// The unit of override is the file: for a path relative to a layer root,
/// the copy in the highest layer that holds it wins. A directory is never
/// replaced; it holds the union of the names of all the layers. Each lookup
/// refuses a path that is empty, absolute or has a `..` component, and a
/// path that resolves through a symbolic link to a location outside its
/// layer root. Such a path gives `nil`, `false` or an empty result, never a
/// URL.
public protocol DotfolderStacking: Sendable {
  /// What one lookup gives back for a winning file.
  associatedtype Item: Sendable

  /// The stack's layers, lowest to highest precedence.
  var layers: [DotfolderStack.Layer] { get }

  /// The winning copy of `relativePath`, with the layer that gave it.
  ///
  /// - Parameter relativePath: A path relative to a layer's root, for
  ///   example `"review/SKILL.md"`.
  /// - Returns: The item made from the copy in the highest layer that holds
  ///   `relativePath`, or `nil` when no layer holds it, when the path is not
  ///   safe, or when the stack cannot make an item from the copy.
  func item(at relativePath: String) -> Located<Item>?

  /// For each child directory of `subdirectory` in the union of the layers,
  /// the winning copy of `fileName` in that child directory.
  ///
  /// One call gives each `<id>/SKILL.md` of a skill directory.
  ///
  /// - Parameters:
  ///   - subdirectory: A directory relative to a layer's root, or `nil` for
  ///     the layer root itself.
  ///   - fileName: The name of the file to find in each child directory.
  /// - Returns: A dictionary from the name of the child directory to the
  ///   winning copy of `fileName` in it. A child directory that does not
  ///   hold `fileName` is not in the result.
  func items(in subdirectory: String?, named fileName: String) -> [String: Located<Item>]

  /// The recursive combined view of `subdirectory`, as items.
  ///
  /// This view holds the files the stack can make an item from. A file the
  /// stack cannot make an item from, for example one whose bytes are not
  /// UTF-8 text, is not in it. `urls(_:)` holds every file.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, or
  ///   `nil` for the layer root itself.
  /// - Returns: A dictionary from the file path relative to `subdirectory`,
  ///   at every depth, to the winning copy and the layer that holds it.
  func tree(_ subdirectory: String?) -> [String: Located<Item>]

  /// The recursive combined view of `subdirectory`, as URLs.
  ///
  /// This view applies the same override rule as `tree(_:)`, and it holds
  /// every file: the stack reads no file to make it, thus a file whose bytes
  /// are not text is in it. A consumer that lists the files of a directory
  /// tree uses this view, and reads the bytes it needs with `data(_:)`.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, or
  ///   `nil` for the layer root itself.
  /// - Returns: A dictionary from the file path relative to `subdirectory`,
  ///   at every depth, to the URL of the winning copy and the layer that
  ///   holds it.
  func urls(_ subdirectory: String?) -> [String: Located<URL>]

  /// The immediate child directories of `subdirectory` in the union of all
  /// the layers, with the layers that hold each one.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, or
  ///   `nil` for the layer root itself.
  /// - Returns: A dictionary from the child directory name to the layers
  ///   that hold that name, lowest precedence first.
  func childDirectories(of subdirectory: String?) -> [String: [DotfolderStack.Layer]]

  /// The layers that hold `relativeDirectory`.
  ///
  /// - Parameter relativeDirectory: A directory relative to a layer's root,
  ///   or `nil` for the layer root itself.
  /// - Returns: The layers that hold `relativeDirectory` as a directory,
  ///   lowest precedence first. Empty when no layer holds it.
  func layerDirectories(_ relativeDirectory: String?) -> [DotfolderStack.Layer]

  /// The bytes of the winning copy of `relativePath`, for a file that is not
  /// text.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: The bytes of the copy in the highest layer that holds
  ///   `relativePath`, or `nil` when no layer holds it or the path is not
  ///   safe.
  func data(_ relativePath: String) -> Data?

  /// A part of the winning copy of `relativePath`, for a consumer that pages
  /// a large file.
  ///
  /// - Parameters:
  ///   - relativePath: A path relative to a layer's root.
  ///   - range: The byte offsets to read. The result is shorter than
  ///     `range` when the file ends inside it.
  /// - Returns: The bytes of the winning copy in `range`, or `nil` when no
  ///   layer holds `relativePath` or the path is not safe.
  func data(_ relativePath: String, in range: Range<Int>) -> Data?

  /// The size in bytes of the winning copy of `relativePath`.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: The size of the copy in the highest layer that holds
  ///   `relativePath`, or `nil` when no layer holds it or the path is not
  ///   safe.
  func size(of relativePath: String) -> Int?

  /// Reports whether the combined view holds `relativePath`.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: `true` if at least one layer holds `relativePath` and the
  ///   path is safe.
  func exists(_ relativePath: String) -> Bool
}
