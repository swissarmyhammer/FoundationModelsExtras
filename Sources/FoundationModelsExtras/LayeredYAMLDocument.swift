import Foundation
import Yams

/// Errors thrown by `LayeredYAMLDocument.load` — the package's own error
/// type, mirroring the facade-error style of `IgnoreProcessorError`/
/// `AgentsMdError`: no Yams (or other internal) type ever crosses this
/// boundary, only this documented, `CustomStringConvertible` type.
public enum LayeredYAMLDocumentError: Error, Sendable, CustomStringConvertible {
  /// A layer's file was located (per `DotfolderStack.locate`) but could not
  /// be read as valid UTF-8 text.
  case fileNotReadable(path: String)

  /// A layer's text failed to render through `TemplateEngine` — the
  /// render-then-parse rule (plan.md §4) runs first, per layer, before this
  /// type ever hands the text to Yams. `message` carries the underlying
  /// `TemplateEngineError`'s description.
  case renderingFailed(path: String, message: String)

  /// A present layer's rendered text is malformed YAML — a hard error
  /// naming the file and, when Yams' own parse error carries one, the
  /// 1-based line number (plan.md §11: "a present-but-malformed layer
  /// names the file and line — never silently fall back over a typo'd
  /// config"). Also raised for a mapping whose key is not a string scalar
  /// (this type's `YAMLValue.dictionary` is keyed by `String`) and for an
  /// unresolved YAML alias.
  case malformed(path: String, line: Int?, message: String)

  /// A human-readable description naming the offending file (and line,
  /// when known).
  public var description: String {
    switch self {
    case .fileNotReadable(let path):
      return "layered YAML document: file not found or unreadable: \(path)"
    case .renderingFailed(let path, let message):
      return "layered YAML document: rendering failed for \(path): \(message)"
    case .malformed(let path, let line, let message):
      if let line {
        return "layered YAML document: malformed YAML at \(path):\(line): \(message)"
      }
      return "layered YAML document: malformed YAML at \(path): \(message)"
    }
  }
}

/// A YAML document resolved across a `DotfolderStack` — Pillar 5, the
/// family's one layered-merge rule (plan.md §11).
///
/// `load` locates every layer's copy of a relative path, renders each
/// through `TemplateEngine` under its layer's trust (`.trusted` for the
/// `defaults` layer, `.untrusted` for `user`/`project` — plan.md §4's
/// render-then-parse rule, so a templated value like an MCP server's
/// `env: { TOKEN: "{{ HOME }}" }` resolves per layer before parsing ever
/// sees it), parses each rendered layer with Yams, and merges the results
/// with the family's one rule:
///
/// - **Scalars and arrays replace wholesale.** A later (higher-precedence)
///   layer's value for a key entirely replaces an earlier layer's — arrays
///   are never concatenated or element-merged across layers.
/// - **Dictionaries (sections) merge by key**, recursively applying the
///   same rule to each key's value.
///
/// `root` is this package's own tree type, `YAMLValue` — Yams' `Node` never
/// crosses this type's public surface. Extras merges trees; consumers
/// decode: `root.decoded(as:)` re-encodes the merged tree into any
/// `Codable` type, so the schema stays the consumer's — only the merge
/// centralizes here.
///
/// A present-but-malformed layer is a hard error naming the file (and
/// line, when known) — never a silent fallback over a typo'd config.
/// Missing layers are simply absent from the merge.
public struct LayeredYAMLDocument: Sendable {
  /// The merged tree. Scalars and arrays replace wholesale when a later
  /// layer defines them; dictionaries (sections) merge by key.
  public var root: YAMLValue

  /// Per-key-path provenance: which layer supplied the winning value at
  /// each key path touched during the merge. Keyed by the same `[String]`
  /// shape `source(of:)` accepts.
  private var sourcesByKeyPath: [[String]: DotfolderStack.Source]

  /// Which layer supplied the winning value at `keyPath` — the
  /// source-tracking story (plan.md §3) extended to individual keys,
  /// feeding consumer diagnostics (e.g. `"/status: profile.standard ←
  /// project"`).
  ///
  /// For a scalar or array key, this is the layer whose value survived the
  /// wholesale replacement. For a dictionary (section) key, this is the
  /// layer that most recently introduced that key structurally — not
  /// necessarily the source of every value nested beneath it, since a
  /// dictionary is, by the merge rule, potentially assembled from several
  /// layers at once.
  ///
  /// - Parameter keyPath: The key path to look up, e.g. `["profile",
  ///   "standard"]` for a nested `profile: { standard: ... }` key, or `[]`
  ///   for the document root itself.
  /// - Returns: The winning layer, or `nil` if no layer ever touched
  ///   `keyPath` during the merge (including when `load` found no layers
  ///   at all).
  public func source(of keyPath: [String]) -> DotfolderStack.Source? {
    sourcesByKeyPath[keyPath]
  }

  /// Creates a document directly from an already-merged tree and its
  /// source map — the only initializer, used internally by `load`. Not
  /// exposed publicly: plan.md §11 specifies `load` as the sole
  /// construction path, so `root`'s shape and `source(of:)`'s answers
  /// always originate from an actual layered merge.
  private init(root: YAMLValue, sourcesByKeyPath: [[String]: DotfolderStack.Source]) {
    self.root = root
    self.sourcesByKeyPath = sourcesByKeyPath
  }

  /// Locates every layer's copy of `relativePath` in `stack`, renders each
  /// under its layer's trust, parses with Yams, and merges the results
  /// with the family's one layered-merge rule.
  ///
  /// - Parameters:
  ///   - relativePath: A path relative to a layer's root, e.g.
  ///     `"config.yaml"`, as accepted by `DotfolderStack.locate`. An unsafe
  ///     path (absolute, empty, or containing a `..` component) resolves
  ///     the same as if no layer had it — `root` is `.null` and
  ///     `source(of:)` answers `nil` everywhere.
  ///   - stack: The layered stack to resolve `relativePath` against.
  ///   - engine: The engine every layer's text renders through before
  ///     parsing — `.trusted` for the `defaults` layer, `.untrusted` for
  ///     `user`/`project` (plan.md §4).
  ///   - context: Explicit template values passed to every layer's render.
  /// - Returns: The merged document.
  /// - Throws: `LayeredYAMLDocumentError.fileNotReadable` if a located
  ///   layer's file cannot be read as UTF-8 text; `.renderingFailed` if a
  ///   layer's text fails to render; `.malformed` if a present layer's
  ///   rendered text is not valid YAML, contains a non-string mapping key,
  ///   or an unresolved alias.
  public static func load(
    _ relativePath: String,
    from stack: DotfolderStack,
    engine: TemplateEngine,
    context: TemplateContext
  ) throws -> LayeredYAMLDocument {
    var layerValues: [(source: DotfolderStack.Source, value: YAMLValue)] = []

    for url in stack.locate(relativePath) {
      guard let source = Self.source(ofLocated: url, in: stack) else { continue }

      guard let rawText = try? String(contentsOf: url, encoding: .utf8) else {
        throw LayeredYAMLDocumentError.fileNotReadable(path: url.path)
      }

      let renderedText: String
      do {
        renderedText = try engine.render(rawText, context: context, trust: Self.trust(for: source))
      } catch {
        throw LayeredYAMLDocumentError.renderingFailed(
          path: url.path, message: String(describing: error))
      }

      let value = try Self.parse(renderedText, path: url.path)
      layerValues.append((source, value))
    }

    guard !layerValues.isEmpty else {
      return LayeredYAMLDocument(root: .null, sourcesByKeyPath: [:])
    }

    var sourcesByKeyPath: [[String]: DotfolderStack.Source] = [:]
    var merged = layerValues[0].value
    Self.recordSources(
      value: merged, source: layerValues[0].source, keyPath: [], into: &sourcesByKeyPath)
    for layer in layerValues.dropFirst() {
      merged = Self.merge(
        lower: merged, higher: layer.value, higherSource: layer.source, keyPath: [],
        sourcesByKeyPath: &sourcesByKeyPath)
    }

    return LayeredYAMLDocument(root: merged, sourcesByKeyPath: sourcesByKeyPath)
  }

  // MARK: - Trust mapping

  /// `.trusted` for the `defaults` layer (consumer-shipped, no
  /// restriction — plan.md §4); `.untrusted` for `user`/`project` layers.
  private static func trust(for source: DotfolderStack.Source) -> TemplateEngine.Trust {
    source == .defaults ? .trusted : .untrusted
  }

  // MARK: - Layer/source recovery

  /// The layer whose root directory `url` resolved under. `locate`'s
  /// returned URLs each derive from exactly one layer's root joined with
  /// the requested relative path, so the layer whose root prefixes `url`'s
  /// path is the one that produced it — mirrors `extras-demo stack`'s own
  /// `StackCommand.winningSource(of:in:)` helper.
  private static func source(ofLocated url: URL, in stack: DotfolderStack) -> DotfolderStack.Source?
  {
    stack.layers.first { url.path.hasPrefix($0.root.path) }?.source
  }

  // MARK: - Parsing

  /// Parses `text` (already rendered) as YAML via Yams, converting its
  /// composed `Node` tree into this package's own `YAMLValue`.
  ///
  /// - Throws: `LayeredYAMLDocumentError.malformed` if `text` is not valid
  ///   YAML, its tree contains a mapping key that is not a string scalar,
  ///   or it contains an alias Yams left unresolved.
  private static func parse(_ text: String, path: String) throws -> YAMLValue {
    let node: Node?
    do {
      node = try Yams.compose(yaml: text)
    } catch {
      throw LayeredYAMLDocumentError.malformed(
        path: path, line: Self.line(from: error), message: String(describing: error))
    }
    guard let node else { return .null }
    return try Self.value(from: node, path: path)
  }

  /// Converts a composed Yams `Node` into `YAMLValue`, recursively.
  private static func value(from node: Node, path: String) throws -> YAMLValue {
    switch node {
    case .scalar(let scalar):
      // `Tag.name` itself is not public API (only `Tag`'s `Equatable`
      // conformance, comparing by name, is), so resolved scalar type is
      // recovered by comparing the whole `Tag` against a freshly built one
      // for each well-known name rather than switching on `.name` directly.
      let tag = node.tag
      if tag == Tag(.bool) {
        return .bool(node.bool ?? false)
      } else if tag == Tag(.int) {
        return .int(node.int ?? 0)
      } else if tag == Tag(.float) {
        return .double(node.float ?? 0)
      } else if tag == Tag(.null) {
        return .null
      } else {
        return .string(scalar.string)
      }
    case .mapping(let mapping):
      var values: [String: YAMLValue] = [:]
      for (keyNode, valueNode) in mapping {
        guard let key = keyNode.string else {
          throw LayeredYAMLDocumentError.malformed(
            path: path, line: keyNode.mark?.line, message: "mapping key is not a string scalar")
        }
        values[key] = try Self.value(from: valueNode, path: path)
      }
      return .dictionary(values)
    case .sequence(let sequence):
      return .array(try sequence.map { try Self.value(from: $0, path: path) })
    case .alias:
      throw LayeredYAMLDocumentError.malformed(
        path: path, line: node.mark?.line, message: "unresolved YAML alias")
    }
  }

  /// Extracts the 1-based line number from a `YamlError`, when the
  /// specific failure case carries a `Mark` (`.scanner`/`.parser`/
  /// `.composer`/`.duplicatedKeysInMapping`); other cases (`.reader`,
  /// `.writer`, `.emitter`, ...) carry no line, and non-`YamlError` errors
  /// never do either.
  private static func line(from error: Error) -> Int? {
    guard let yamlError = error as? YamlError else { return nil }
    switch yamlError {
    case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
      return mark.line
    case .duplicatedKeysInMapping(_, let context):
      return context.mark.line
    default:
      return nil
    }
  }

  // MARK: - Merge

  /// Merges `higher` (from `higherSource`, a later, higher-precedence
  /// layer) onto `lower` (an already-merged accumulation of earlier
  /// layers), recording per-key-path provenance as it goes.
  ///
  /// The family's one rule: when both sides are dictionaries, merge by
  /// key, recursing per key; otherwise (scalar, array, or a type change
  /// between layers) `higher` replaces `lower` wholesale.
  private static func merge(
    lower: YAMLValue, higher: YAMLValue, higherSource: DotfolderStack.Source,
    keyPath: [String], sourcesByKeyPath: inout [[String]: DotfolderStack.Source]
  ) -> YAMLValue {
    guard case .dictionary(let lowerDictionary) = lower,
      case .dictionary(let higherDictionary) = higher
    else {
      Self.recordSources(
        value: higher, source: higherSource, keyPath: keyPath, into: &sourcesByKeyPath)
      return higher
    }

    var merged = lowerDictionary
    for (key, higherValue) in higherDictionary {
      let childKeyPath = keyPath + [key]
      if let lowerValue = lowerDictionary[key] {
        merged[key] = Self.merge(
          lower: lowerValue, higher: higherValue, higherSource: higherSource,
          keyPath: childKeyPath, sourcesByKeyPath: &sourcesByKeyPath)
      } else {
        merged[key] = higherValue
        Self.recordSources(
          value: higherValue, source: higherSource, keyPath: childKeyPath,
          into: &sourcesByKeyPath)
      }
    }
    return .dictionary(merged)
  }

  /// Records `source` as the provenance of `keyPath` and, when `value` is
  /// a dictionary, every key path nested beneath it — the baseline a fresh
  /// (not-yet-merged-into) subtree gets when a layer introduces it, whether
  /// as the very first layer folded in or as a key a later layer defines
  /// that no earlier layer had.
  private static func recordSources(
    value: YAMLValue, source: DotfolderStack.Source, keyPath: [String],
    into sourcesByKeyPath: inout [[String]: DotfolderStack.Source]
  ) {
    sourcesByKeyPath[keyPath] = source
    guard case .dictionary(let dictionary) = value else { return }
    for (key, childValue) in dictionary {
      Self.recordSources(
        value: childValue, source: source, keyPath: keyPath + [key], into: &sourcesByKeyPath)
    }
  }
}
