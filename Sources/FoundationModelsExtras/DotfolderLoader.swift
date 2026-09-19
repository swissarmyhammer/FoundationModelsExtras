import Foundation
import Stencil

/// The package's own error for a partial that no layer holds — thrown by
/// `DotfolderLoader.loadTemplate`, never surfaced directly (it is not
/// `public`): `TemplateEngine.render` catches it along with every other
/// Stencil-adjacent failure and re-describes it inside
/// `TemplateEngineError.renderingFailed`, so no Stencil-internal error ever
/// crosses the facade (plan.md §4).
enum DotfolderLoaderError: Error, Sendable, CustomStringConvertible {
  /// No partial location of any layer held any of the name variants tried
  /// for `name` — the literal include argument, exactly as written in the
  /// template. `directoriesSearched` lists every directory consulted, in
  /// the stack's layer order, for diagnostics.
  case partialNotFound(name: String, directoriesSearched: [String])

  /// A human-readable description naming the missing include and the
  /// directories searched for it.
  var description: String {
    switch self {
    case .partialNotFound(let name, let directoriesSearched):
      let searched = directoriesSearched.joined(separator: ", ")
      return "partial \"\(name)\" not found; searched: \(searched)"
    }
  }
}

/// Resolves Stencil `{% include %}` partials through the partial locations
/// of a `DotfolderStack`'s layers, nearest layer wins (plan.md §4): a
/// project's copy shadows the user's, which shadows the shipped defaults'.
/// Conforms to Stencil's `Loader` protocol so it plugs directly into
/// `Environment(loader:)` — no filesystem convention of Stencil's leaks
/// through; the stack stays the only thing that touches disk.
///
/// ## Partial locations
///
/// A partial location is a directory relative to a layer root, `_partials`
/// by default. The search follows the combined view of the stack: the
/// highest layer that holds a partial wins, whichever location and name
/// variant it holds it under. Inside one layer the locations are searched
/// in the order given, and the name variants below in their order.
///
/// ## Name resolution
///
/// The swissarmyhammer corpus this package ports (plan.md §4) writes includes
/// two ways: extensionless (`{% include "header" %}`) and with a redundant
/// leading location (`{% include "_partials/coding-standards" %}`).
/// `loadTemplate` tries, in order, stopping at the first candidate a
/// location of the layer holds:
///
/// 1. the literal include name, e.g. `"header.md"`
/// 2. the literal name with `.md` appended, e.g. `"header"` → `"header.md"`
/// 3. the literal name with a leading `"<location>/"` stripped, for each
///    location it starts with
/// 4. that stripped name with `.md` appended
final class DotfolderLoader: Loader, Sendable {
  /// The partial locations a loader searches when the caller names none:
  /// the `_partials/` convention of the swissarmyhammer corpus.
  static let defaultPartialLocations = ["_partials"]

  /// The extension the name resolution appends to an extensionless include.
  private static let markdownExtension = ".md"

  /// The stack whose layers this loader resolves includes against.
  private let stack: DotfolderStack

  /// The directories, relative to a layer root, that hold the partials.
  private let partialLocations: [String]

  /// Creates a loader over `stack`.
  ///
  /// - Parameters:
  ///   - stack: The stack whose layers hold the partials.
  ///   - partialLocations: The directories, relative to a layer root, to
  ///     search for a partial. Defaults to `defaultPartialLocations`.
  init(stack: DotfolderStack, partialLocations: [String] = defaultPartialLocations) {
    self.stack = stack
    self.partialLocations = partialLocations
  }

  /// Resolves `name` per the partial locations and the name-resolution
  /// scheme documented on this type, returning the nearest layer's content
  /// as a Stencil `Template`.
  ///
  /// - Parameters:
  ///   - name: The literal include argument, exactly as written in the
  ///     template (e.g. `"header.md"`, `"header"`, or
  ///     `"_partials/coding-standards"`).
  ///   - environment: The Stencil environment the loaded template renders
  ///     under; forwarded unchanged so nested includes resolve through
  ///     this same loader.
  /// - Returns: The resolved template, named `name` (not the resolved
  ///   candidate) so diagnostics report what the template actually wrote.
  /// - Throws: `DotfolderLoaderError.partialNotFound` when no partial
  ///   location of any layer holds any name variant tried.
  func loadTemplate(name: String, environment: Environment) throws -> Template {
    guard let content = partialContent(named: name) else {
      throw DotfolderLoaderError.partialNotFound(
        name: name, directoriesSearched: searchedDirectories)
    }
    return environment.templateClass.init(
      templateString: content, environment: environment, name: name)
  }

  /// The text of the partial `name` in the highest layer that holds it,
  /// under any partial location and any name variant.
  ///
  /// Each layer is searched on its own, highest precedence first, so a
  /// copy in a higher layer wins over a copy in a lower layer even when the
  /// two sit under different locations or different name variants.
  ///
  /// - Parameter name: The literal include argument.
  /// - Returns: The text of the winning copy, or `nil` when no layer holds
  ///   the partial.
  private func partialContent(named name: String) -> String? {
    let relativePaths = partialPaths(for: name)
    for layer in stack.layers.reversed() {
      var layerStack = stack
      layerStack.layers = [layer]
      if let content = relativePaths.lazy.compactMap(layerStack.content).first {
        return content
      }
    }
    return nil
  }

  /// The paths, relative to a layer root, at which a layer may hold the
  /// partial `name`: each partial location joined with each name variant,
  /// locations in the order given and variants in resolution order.
  ///
  /// - Parameter name: The literal include argument.
  /// - Returns: The relative paths to try, in order.
  private func partialPaths(for name: String) -> [String] {
    let candidates = candidateNames(for: name)
    return partialLocations.flatMap { location in
      candidates.map { "\(location)/\($0)" }
    }
  }

  /// Builds the ordered name variants `loadTemplate` tries for `name`, per
  /// this type's documented resolution scheme: the literal name, the
  /// literal name with `.md` appended, and — for each partial location
  /// that `name` redundantly starts with — both again with that prefix
  /// stripped.
  ///
  /// - Parameter name: The literal include argument.
  /// - Returns: The name variants to try, in order.
  private func candidateNames(for name: String) -> [String] {
    let strippedNames = partialLocations.compactMap { location -> String? in
      let prefix = location + "/"
      guard name.hasPrefix(prefix) else { return nil }
      return String(name.dropFirst(prefix.count))
    }
    return ([name] + strippedNames).flatMap { [$0, $0 + Self.markdownExtension] }
  }

  /// Every directory a lookup consults, in the stack's layer order, for
  /// the diagnostic of a partial that no layer holds.
  private var searchedDirectories: [String] {
    stack.layers.flatMap { layer in
      partialLocations.map { layer.root.appendingPathComponent($0).path }
    }
  }
}
