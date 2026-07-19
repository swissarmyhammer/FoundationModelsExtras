import Foundation
import Stencil

/// The package's own error for missing `_partials/` resolution — thrown by
/// `DotfolderLoader.loadTemplate`, never surfaced directly (it is not
/// `public`): `TemplateEngine.render` catches it along with every other
/// Stencil-adjacent failure and re-describes it inside
/// `TemplateEngineError.renderingFailed`, so no Stencil-internal error ever
/// crosses the facade (plan.md §4).
enum DotfolderLoaderError: Error, Sendable, CustomStringConvertible {
    /// No layer's `_partials/` held any of the name variants tried for
    /// `name` — the literal include argument, exactly as written in the
    /// template. `directoriesSearched` lists every `_partials/` directory
    /// consulted, in the stack's layer order, for diagnostics.
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

/// Resolves Stencil `{% include %}` partials through a `DotfolderStack`'s
/// layered `_partials/` directories, nearest layer wins (plan.md §4): a
/// project's `_partials/` shadows the user's, which shadows the shipped
/// defaults'. Conforms to Stencil's `Loader` protocol so it plugs directly
/// into `Environment(loader:)` — no filesystem convention of Stencil's leaks
/// through; the stack stays the only thing that touches disk.
///
/// ## Name resolution
///
/// The swissarmyhammer corpus this package ports (plan.md §4) writes includes
/// two ways: extensionless (`{% include "header" %}`) and with a redundant
/// leading `_partials/` (`{% include "_partials/coding-standards" %}`).
/// `loadTemplate` tries, in order, stopping at the first candidate any
/// layer's `_partials/` holds:
///
/// 1. the literal include name, e.g. `"header.md"`
/// 2. the literal name with `.md` appended, e.g. `"header"` → `"header.md"`
/// 3. the literal name with a leading `"_partials/"` stripped
/// 4. that stripped name with `.md` appended
final class DotfolderLoader: Loader, Sendable {
    /// The stack whose layered `_partials/` directories this loader resolves
    /// includes against.
    private let stack: DotfolderStack

    /// Creates a loader over `stack`.
    init(stack: DotfolderStack) {
        self.stack = stack
    }

    /// Resolves `name` per the name-resolution scheme documented on this
    /// type, returning the nearest layer's content as a Stencil `Template`.
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
    /// - Throws: `DotfolderLoaderError.partialNotFound` when no layer's
    ///   `_partials/` holds any name variant tried.
    func loadTemplate(name: String, environment: Environment) throws -> Template {
        for candidate in candidateNames(for: name) {
            guard let content = stack.content("_partials/" + candidate) else { continue }
            return environment.templateClass.init(
                templateString: content, environment: environment, name: name)
        }
        throw DotfolderLoaderError.partialNotFound(
            name: name,
            directoriesSearched: stack.layers.map {
                $0.root.appendingPathComponent("_partials").path
            }
        )
    }

    /// Builds the ordered name variants `loadTemplate` tries for `name`, per
    /// this type's documented resolution scheme: the literal name, the
    /// literal name with `.md` appended, and — only when `name` carries a
    /// redundant leading `"_partials/"` — both again with that prefix
    /// stripped.
    private func candidateNames(for name: String) -> [String] {
        let partialsPrefix = "_partials/"
        var candidates = [name, name + ".md"]
        if name.hasPrefix(partialsPrefix) {
            let stripped = String(name.dropFirst(partialsPrefix.count))
            candidates.append(stripped)
            candidates.append(stripped + ".md")
        }
        return candidates
    }
}
