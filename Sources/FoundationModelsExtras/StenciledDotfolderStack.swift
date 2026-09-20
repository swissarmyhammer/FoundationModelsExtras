import Foundation

/// A `DotfolderStacking` over a `DotfolderStack` that renders each text
/// with Stencil before it gives it back.
///
/// A consumer picks this implementation and then makes the same calls as
/// on the plain stack. It never names Stencil, it never names the trust,
/// and it never assembles the render itself:
///
/// ```swift
/// let stack = DotfolderStack(name: "myagent", workingDirectory: cwd)
/// let stenciled = StenciledDotfolderStack(
///   base: stack,
///   partialLocations: ["_partials"],
///   variables: ["project": "acme", "ARGUMENTS": "one two"])
///
/// stenciled.content("review/SKILL.md")          // rendered text
/// stenciled.items(in: nil, named: "SKILL.md")   // each <id>/SKILL.md, rendered
/// ```
///
/// ## What is rendered
///
/// `Item` is `String`, the same as the plain stack. Each text that a lookup
/// gives back is rendered: `content(_:)`, `item(at:)`, `items(in:named:)`
/// and `tree(_:)`. The URL view (`urls`), the byte lookups (`data`, the
/// ranged `data`, `size`) and the directory lookups give what the base stack
/// gives, unchanged. The frontmatter is not a concept at this layer.
///
/// ## Text that a consumer holds
///
/// `render(_:in:)` renders text that the caller holds, with the trust and
/// the partial scope of a layer of the stack. A consumer whose own format
/// runs passes of its own before Stencil marks what those passes spliced in
/// as quarantined, and the render then gives that text to Stencil as a
/// value, never as template text.
///
/// ## Variables
///
/// The render interpolates `variables` above the well-known values
/// (`working_directory`, `date`, `hostname`, `dotfolder_name`), thus a
/// value of the consumer wins over a well-known value of the same name.
/// The process environment is not a rung of this stack: a consumer that
/// wants an environment variable in a template puts it in `variables`.
///
/// ## Partials
///
/// An `{% include %}` finds a partial in `partialLocations`, the
/// directories relative to a layer root. The search follows the combined
/// view: the highest layer that holds the partial wins. The scope of the
/// search is the layer of the document plus the local layers: a document
/// of a `.marketplace` layer sees that one marketplace layer and every
/// local layer, with a local copy winning over the marketplace copy of the
/// same name; a document of a local layer sees the local layers only, so
/// it never reads the partial of a remote source.
///
/// ## Trust
///
/// The trust comes from the layer, not from the caller: a document of the
/// `.defaults` layer renders trusted, and a document of each other layer
/// renders untrusted, with the limits that `TemplateEngine.Trust.untrusted`
/// applies (the allowed tags, no filters, the include depth, the output
/// size, the loop count).
///
/// ## Failures
///
/// A render failure does not throw out of a lookup. The lookup gives `nil`
/// (or leaves the entry out of a dictionary result), and the failure goes
/// to the `onDiagnostic` hook with the file and the layer that failed.
///
/// Constructing a stenciled stack performs no file I/O, the same as
/// `DotfolderStack`, thus a caller can make one for each call, with the
/// variables of that call.
public struct StenciledDotfolderStack: DotfolderStacking {
  /// One render failure: the file that failed, the layer that holds it,
  /// and the text of the failure, as `TemplateEngineError` describes it.
  public typealias Diagnostic = DotfolderStack.Diagnostic

  /// The hook that receives each render failure.
  public typealias DiagnosticHandler = @Sendable (Diagnostic) -> Void

  /// The partial locations a stack searches when the caller names none:
  /// `["_partials"]`, the convention of `DotfolderLoader`.
  public static let defaultPartialLocations = DotfolderLoader.defaultPartialLocations

  /// The plain stack that reads the files.
  public let base: DotfolderStack

  /// The directories, relative to a layer root, where an `{% include %}`
  /// finds a partial.
  public let partialLocations: [String]

  /// The values that the render interpolates, above the well-known values.
  public let variables: [String: String]

  /// The well-known values of each render, or `nil` to read the current
  /// values at the time of each render.
  public let wellKnownValues: WellKnownValues?

  /// The hook that receives each render failure.
  private let onDiagnostic: DiagnosticHandler

  /// The explicit context of each render, built once from `variables`.
  private let context: TemplateContext

  /// Creates a stenciled stack over `base`.
  ///
  /// - Parameters:
  ///   - base: The plain stack that reads the files.
  ///   - partialLocations: The directories, relative to a layer root, where
  ///     an `{% include %}` finds a partial. Defaults to
  ///     `defaultPartialLocations`.
  ///   - variables: The values that the render interpolates. A value here
  ///     wins over a well-known value of the same name. Defaults to none.
  ///   - wellKnownValues: The well-known values of each render. `nil`, the
  ///     default, reads the current values at the time of each render, thus
  ///     `date` is the date of the render. A consumer that must pin these
  ///     values, for example a test, gives them here.
  ///   - onDiagnostic: The hook that receives each render failure. Defaults
  ///     to a hook that ignores it.
  public init(
    base: DotfolderStack,
    partialLocations: [String] = defaultPartialLocations,
    variables: [String: String] = [:],
    wellKnownValues: WellKnownValues? = nil,
    onDiagnostic: @escaping DiagnosticHandler = { _ in }
  ) {
    self.base = base
    self.partialLocations = partialLocations
    self.variables = variables
    self.wellKnownValues = wellKnownValues
    self.onDiagnostic = onDiagnostic
    self.context = TemplateContext(values: variables.mapValues { .string($0) })
  }

  /// The layers of the base stack, lowest to highest precedence.
  public var layers: [DotfolderStack.Layer] { base.layers }

  /// The rendered text of the winning copy of `relativePath`.
  ///
  /// - Parameter relativePath: A path relative to a layer's root, as
  ///   accepted by `DotfolderStack.content(_:)`.
  /// - Returns: The rendered text, or `nil` when the base stack gives no
  ///   text for `relativePath` or the render fails.
  public func content(_ relativePath: String) -> String? {
    item(at: relativePath)?.value
  }

  /// The winning copy of `relativePath`, with the layer that gave it and
  /// its rendered text.
  ///
  /// - Parameter relativePath: A path relative to a layer's root, as
  ///   accepted by `DotfolderStack.item(at:)`.
  /// - Returns: The item of the base stack with its text rendered, or `nil`
  ///   when the base stack gives no item or the render fails.
  public func item(at relativePath: String) -> Located<String>? {
    base.item(at: relativePath).flatMap(rendered)
  }

  /// For each child directory of `subdirectory` in the union of the layers,
  /// the winning copy of `fileName` in that child directory, rendered.
  ///
  /// - Parameters:
  ///   - subdirectory: A directory relative to a layer's root, as accepted
  ///     by `DotfolderStack.items(in:named:)`. `nil` means the layer root.
  ///   - fileName: The name of the file to find in each child directory.
  /// - Returns: The items of the base stack with each text rendered. A
  ///   child directory whose file fails to render is not in the result.
  public func items(
    in subdirectory: String? = nil, named fileName: String
  ) -> [String: Located<String>] {
    base.items(in: subdirectory, named: fileName).compactMapValues(rendered)
  }

  /// The recursive combined view of `subdirectory`, with each text
  /// rendered.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, as
  ///   accepted by `DotfolderStack.tree(_:)`. `nil` means the layer root.
  /// - Returns: The view of the base stack with each text rendered. A file
  ///   that fails to render is not in the view.
  public func tree(_ subdirectory: String? = nil) -> [String: Located<String>] {
    base.tree(subdirectory).compactMapValues(rendered)
  }

  /// The recursive combined view of `subdirectory` as URLs, as the base
  /// stack gives it.
  ///
  /// This stack makes its item from text, thus it does not filter this view:
  /// it holds every file of the base stack, and a file that fails to render
  /// stays in it.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, or
  ///   `nil` for the layer root itself.
  /// - Returns: What `DotfolderStack.urls(_:)` gives.
  public func urls(_ subdirectory: String? = nil) -> [String: Located<URL>] {
    base.urls(subdirectory)
  }

  /// The immediate child directories of `subdirectory`, as the base stack
  /// gives them.
  ///
  /// - Parameter subdirectory: A directory relative to a layer's root, or
  ///   `nil` for the layer root itself.
  /// - Returns: What `DotfolderStack.childDirectories(of:)` gives.
  public func childDirectories(of subdirectory: String? = nil) -> [String: [DotfolderStack.Layer]] {
    base.childDirectories(of: subdirectory)
  }

  /// The layers that hold `relativeDirectory`, as the base stack gives
  /// them.
  ///
  /// - Parameter relativeDirectory: A directory relative to a layer's root,
  ///   or `nil` for the layer root itself.
  /// - Returns: What `DotfolderStack.layerDirectories(_:)` gives.
  public func layerDirectories(_ relativeDirectory: String? = nil) -> [DotfolderStack.Layer] {
    base.layerDirectories(relativeDirectory)
  }

  /// The bytes of the winning copy of `relativePath`, not rendered.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: What `DotfolderStack.data(_:)` gives.
  public func data(_ relativePath: String) -> Data? {
    base.data(relativePath)
  }

  /// A part of the winning copy of `relativePath`, not rendered.
  ///
  /// - Parameters:
  ///   - relativePath: A path relative to a layer's root.
  ///   - range: The byte offsets to read.
  /// - Returns: What `DotfolderStack.data(_:in:)` gives.
  public func data(_ relativePath: String, in range: Range<Int>) -> Data? {
    base.data(relativePath, in: range)
  }

  /// The size in bytes of the winning copy of `relativePath` on disk, not
  /// of its rendered text.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: What `DotfolderStack.size(of:)` gives.
  public func size(of relativePath: String) -> Int? {
    base.size(of: relativePath)
  }

  /// Reports whether the combined view holds `relativePath`.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: What `DotfolderStack.exists(_:)` gives.
  public func exists(_ relativePath: String) -> Bool {
    base.exists(relativePath)
  }

  /// Reports whether the winning copy of `relativePath` has the execute
  /// bit. The render does not change the mode of a file.
  ///
  /// - Parameter relativePath: A path relative to a layer's root.
  /// - Returns: What `DotfolderStack.isExecutable(_:)` gives.
  public func isExecutable(_ relativePath: String) -> Bool {
    base.isExecutable(relativePath)
  }

  /// Renders `text`, which the caller holds, with the trust of `layer` and
  /// the partials in the scope of `layer`.
  ///
  /// The whole text becomes ONE template. Each `.original` span is template
  /// text. Each `.quarantined` span is data: the template holds a reference
  /// to a context key in its place, and the text of the span is the value
  /// of that key, thus Stencil never reads it as syntax. A `{{ x }}` or an
  /// `{% include %}` inside such a span stays as it is. The text on the two
  /// sides of a span is still one template, thus an `{% if %}` block may
  /// straddle a span.
  ///
  /// One template also means one render call, thus ONE set of the limits of
  /// an untrusted render: the output size, the loop count and the include
  /// depth. The engine gives fresh limits to each render call, thus to
  /// render N spans as N templates would give an untrusted text N times
  /// each limit, and a text can make spans for free.
  ///
  /// The variables and the well-known values are those of the stack, the
  /// same as for a file. The process environment is not a rung: a consumer
  /// puts each environment value that it wants into `variables`.
  ///
  /// - Parameters:
  ///   - text: The text to render, in spans.
  ///   - layer: The layer that the text belongs to. The trust comes from
  ///     this layer, and so does the scope of the partials.
  /// - Returns: The rendered text.
  /// - Throws: `TemplateEngineError.renderingFailed` when Stencil fails to
  ///   parse or to render the template, when the checks of an untrusted
  ///   render refuse it, or when a `.quarantined` span sits inside an open
  ///   Stencil delimiter.
  public func render(_ text: QuarantinedText, in layer: DotfolderStack.Layer) throws -> String {
    var renderContext = context
    let template = try Self.template(for: text, injectingQuarantinedSpansInto: &renderContext)
    let engine = TemplateEngine(
      partials: partialsStack(for: layer),
      partialLocations: partialLocations,
      environment: [:],
      wellKnownValues: wellKnownValues ?? .current(partials: base)
    )
    return try engine.render(template, context: renderContext, trust: Self.trust(of: layer))
  }

  /// Renders `text`, which the caller holds and every byte of which is
  /// template text, with the trust of `layer` and the partials in the scope
  /// of `layer`.
  ///
  /// - Parameters:
  ///   - text: The text to render. All of it is `.original`, thus Stencil
  ///     scans all of it.
  ///   - layer: The layer that the text belongs to. The trust comes from
  ///     this layer, and so does the scope of the partials.
  /// - Returns: The rendered text.
  /// - Throws: `TemplateEngineError.renderingFailed`, as
  ///   `render(_:in:)` for a `QuarantinedText` does.
  public func render(_ text: String, in layer: DotfolderStack.Layer) throws -> String {
    try render(QuarantinedText(original: text), in: layer)
  }

  /// The prefix of the context key under which a render gives the text of
  /// each `.quarantined` span to Stencil as a value. The number of the span
  /// follows the prefix (`<prefix>0`, `<prefix>1`, and so on).
  ///
  /// A variable of the stack that carries such a name loses nothing: the
  /// render sets these keys last, thus they always win, and the value that
  /// each one carries is text that the same render spliced in.
  static let quarantinedSpanContextKeyPrefix = "foundationModelsExtrasQuarantinedSpan"

  /// The three delimiter pairs of Stencil — the variable, the tag and the
  /// comment — as `(opener, closer)`. `endsInsideOpenDelimiter(_:)` reads
  /// them to tell whether the template text stops inside one of them.
  private static let delimiterPairs: [(opener: String, closer: String)] = [
    (opener: "{{", closer: "}}"), (opener: "{%", closer: "%}"), (opener: "{#", closer: "#}"),
  ]

  /// Builds the one template that a render gives to Stencil: the
  /// `.original` spans of `text` as they are, and a `{{ <key> }}` reference
  /// in place of each `.quarantined` span, whose text goes into `context`
  /// under that key.
  ///
  /// A span that would sit inside an open delimiter pair — template text
  /// that has opened a `{{`, a `{%` or a `{#` and has not closed it — is
  /// refused here, as a `TemplateEngineError.renderingFailed`. Text that a
  /// pass spliced in may name a variable, steer a tag or disappear, and the
  /// reader of Stencil does not know a quotation mark, thus to let the
  /// reference through would render nonsense in place of a failure.
  ///
  /// A run of bare `{` at the very end of the text before a span moves out
  /// of the template and onto the front of the value of that span. It is
  /// always literal text there: a `{` that opened real syntax is part of an
  /// open delimiter, which the rule above refuses. To leave it in the
  /// template would join it to the `{{` of the reference (`{$1}` becomes
  /// `{{{ key }}}`), which Stencil reads as a broken variable; to move it
  /// renders `{value}`.
  ///
  /// - Parameters:
  ///   - text: The text to render, in spans.
  ///   - context: The context of the render. It receives one `.string`
  ///     entry for each `.quarantined` span, keyed by
  ///     `quarantinedSpanContextKeyPrefix` and the number of the span. The
  ///     entries are set after every other rung, thus nothing can shadow a
  ///     key.
  /// - Returns: The template text.
  /// - Throws: `TemplateEngineError.renderingFailed` when a `.quarantined`
  ///   span sits inside an open Stencil delimiter pair.
  private static func template(
    for text: QuarantinedText, injectingQuarantinedSpansInto context: inout TemplateContext
  ) throws -> String {
    var template = ""
    var quarantinedSpanCount = 0
    for span in text.spans {
      switch span {
      case .original(let spanText):
        template += spanText
      case .quarantined(let spliced):
        guard !endsInsideOpenDelimiter(template) else {
          throw TemplateEngineError.renderingFailed(
            message:
              "a spliced value sits inside a Stencil variable, tag or comment; spliced text can never form template syntax"
          )
        }
        let key = "\(quarantinedSpanContextKeyPrefix)\(quarantinedSpanCount)"
        quarantinedSpanCount += 1
        let value = movingTrailingBraces(from: &template, ontoFrontOf: spliced)
        context.set(key: key, to: .string(value))
        template += "{{ \(key) }}"
      }
    }
    return template
  }

  /// Reports whether `template` stops inside one of `delimiterPairs`: an
  /// opener stands after every closer.
  ///
  /// - Parameter template: The template text built so far.
  /// - Returns: `true` when no closer follows the last opener of
  ///   `template`.
  private static func endsInsideOpenDelimiter(_ template: String) -> Bool {
    let lastOpener = delimiterPairs.compactMap {
      template.range(of: $0.opener, options: .backwards)?.lowerBound
    }.max()
    let lastCloser = delimiterPairs.compactMap {
      template.range(of: $0.closer, options: .backwards)?.lowerBound
    }.max()
    guard let lastOpener else { return false }
    return lastCloser.map { $0 < lastOpener } ?? true
  }

  /// Takes each `{` from the end of `template`, and gives `value` with
  /// those braces in front of it.
  ///
  /// - Parameters:
  ///   - template: The template text built so far. The braces at its end go
  ///     away.
  ///   - value: The spliced value that comes after `template`.
  /// - Returns: `value`, with the braces that `template` lost in front of
  ///   it.
  private static func movingTrailingBraces(
    from template: inout String, ontoFrontOf value: String
  ) -> String {
    var moved = ""
    while template.last == "{" {
      template.removeLast()
      moved.append("{")
    }
    return moved + value
  }

  /// Renders the text of `located` with the trust of its layer and the
  /// partials in the scope of its layer.
  ///
  /// Every text lookup routes through this helper, so each of them applies
  /// the same trust rule, the same scope rule and the same failure rule. A
  /// file takes the same path as the text of a consumer: all of its bytes
  /// are template text, thus it holds one `.original` span.
  ///
  /// - Parameter located: An item of the base stack.
  /// - Returns: The same item with its text rendered, or `nil` when the
  ///   render fails, in which case the failure went to `onDiagnostic`.
  private func rendered(_ located: Located<String>) -> Located<String>? {
    do {
      let text = try render(located.value, in: located.layer)
      return Located(url: located.url, layer: located.layer, value: text)
    } catch {
      onDiagnostic(
        Diagnostic(url: located.url, layer: located.layer, message: String(describing: error)))
      return nil
    }
  }

  /// The trust of a document of `layer`: `.trusted` for the `.defaults`
  /// layer, `.untrusted` for each other layer.
  ///
  /// - Parameter layer: The layer that holds the document.
  /// - Returns: The trust the render applies.
  private static func trust(of layer: DotfolderStack.Layer) -> TemplateEngine.Trust {
    layer.source == .defaults ? .trusted : .untrusted
  }

  /// The stack that resolves `{% include %}` for a document of `layer`.
  ///
  /// A document of a `.marketplace` layer gets that one marketplace layer
  /// plus every local layer — `marketplace < defaults < user < project` —
  /// so it never reads a partial of a different marketplace, and a local
  /// copy of the same name still wins. A document of a local layer gets
  /// the local layers only, so it stays independent of a remote source: an
  /// include of a name that only a marketplace ships is a render failure,
  /// not that marketplace's text.
  ///
  /// - Parameter layer: The layer that holds the document.
  /// - Returns: The base stack narrowed to the layers in scope, or `nil`
  ///   when no layer is in scope.
  private func partialsStack(for layer: DotfolderStack.Layer) -> DotfolderStack? {
    let localLayers = base.layers.filter { $0.source != .marketplace }
    let scopedLayers = layer.source == .marketplace ? [layer] + localLayers : localLayers
    guard !scopedLayers.isEmpty else { return nil }
    var stack = base
    stack.layers = scopedLayers
    return stack
  }
}
