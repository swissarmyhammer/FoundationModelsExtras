import Foundation

/// The layered dotfolder resolution stack shared across the family (plan.md
/// §3): shipped defaults, the user's home dotfolder, and the current
/// project's dotfolder, in increasing precedence — `defaults < user
/// (~/.<name>/) < project (<cwd>/.<name>/)`.
///
/// `DotfolderStack` only **locates** files; it never merges their contents.
/// Key-level config merging (scalars/arrays replace wholesale, sections merge
/// by key) is a consumer concern — the harness's codec policy, not this
/// type's. The stack is the only thing that touches disk, and only when
/// `nearest`, `locate`, or `enumerate` is called: constructing a stack never
/// performs file I/O, so consumers stay constructible in tests with none.
public struct DotfolderStack: Sendable {
    /// Which layer of the stack a location resolved from.
    public enum Source: Sendable, Equatable {
        /// The consumer-shipped defaults directory — a real directory read
        /// at runtime, never compiled-in content.
        case defaults
        /// The user's home dotfolder, `~/.<name>/`.
        case user
        /// The current project's dotfolder, `<workingDirectory>/.<name>/`.
        case project
    }

    /// One layer of the stack: a source kind and the directory it roots.
    public struct Layer: Sendable {
        /// Which layer this is.
        public var source: Source
        /// The directory this layer roots. May not exist on disk; lookups
        /// skip layers whose root is missing.
        public var root: URL

        /// Creates a layer. Exposed publicly so consumers can build fixtures
        /// and fakes (e.g. for their own tests) with a plain
        /// `import FoundationModelsExtras`, no `@testable` access required.
        public init(source: Source, root: URL) {
            self.source = source
            self.root = root
        }
    }

    /// A resolved location together with the layer that won it — the
    /// swissarmyhammer `FileSource` idea, so consumers can surface "where did
    /// this come from" in diagnostics (`/status`, `/memory` headers).
    public struct Located: Sendable {
        /// The winning file's URL.
        public var url: URL
        /// The layer that won.
        public var layer: Layer

        /// Creates a located value. Exposed publicly so consumers can build
        /// fixtures and fakes (e.g. for their own tests) with a plain
        /// `import FoundationModelsExtras`, no `@testable` access required.
        public init(url: URL, layer: Layer) {
            self.url = url
            self.layer = layer
        }
    }

    /// The stack's layers, `defaults < user < project`, lowest to highest
    /// precedence. Omits the `defaults` layer entirely when the consumer
    /// supplied no `defaultsDirectory` and no `<NAME>_DEFAULTS_DIR` override
    /// was set — there is no shipped-defaults directory to root it at.
    public var layers: [Layer]

    /// Derives a stack's layers from a bare name.
    ///
    /// - Parameters:
    ///   - name: The dotfolder name, e.g. `"myagent"` for `~/.myagent` and
    ///     `<workingDirectory>/.myagent`.
    ///   - workingDirectory: The current project directory; the project
    ///     layer roots at `<workingDirectory>/.<name>/`.
    ///   - defaultsDirectory: The lowest layer: a real, consumer-shipped
    ///     directory of shipped defaults. `nil` omits the defaults layer.
    ///     Overridden at runtime by the `<NAME>_DEFAULTS_DIR` environment
    ///     variable (`name` uppercased), the dev-override seam that lets
    ///     shipped defaults be repointed at a source checkout with no
    ///     rebuild.
    ///   - userDirectory: The user layer's root. `nil` derives
    ///     `~/.<name>/` from the current user's home directory. Callers that
    ///     must never touch the real home directory (tests, demos) pass an
    ///     explicit value.
    ///   - environment: The environment dictionary consulted for the
    ///     `<NAME>_DEFAULTS_DIR` override. Defaults to the process
    ///     environment; tests inject a fake dictionary to prove the override
    ///     works without depending on real process state.
    public init(
        name: String,
        workingDirectory: URL,
        defaultsDirectory: URL? = nil,
        userDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        var layers: [Layer] = []

        let overrideKey = "\(name.uppercased())_DEFAULTS_DIR"
        if let overridePath = environment[overrideKey], !overridePath.isEmpty {
            layers.append(Layer(source: .defaults, root: URL(fileURLWithPath: overridePath)))
        } else if let defaultsDirectory {
            layers.append(Layer(source: .defaults, root: defaultsDirectory))
        }

        let resolvedUserDirectory =
            userDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".\(name)", isDirectory: true)
        layers.append(Layer(source: .user, root: resolvedUserDirectory))

        layers.append(
            Layer(
                source: .project,
                root: workingDirectory.appendingPathComponent(".\(name)", isDirectory: true)))

        self.layers = layers
    }

    /// Reports whether `path` is safe to join onto a layer root: non-empty,
    /// not rooted (no leading `/`), and free of `..` traversal components.
    ///
    /// Every entry point that joins a caller-supplied path onto a layer's
    /// root (`nearest`, `locate`, `enumerate`) routes through this check
    /// first, so none of them can be walked outside the layer root via a
    /// `"../"` segment or an absolute path.
    ///
    /// - Parameter path: The caller-supplied relative path or subdirectory
    ///   name to validate.
    /// - Returns: `true` if `path` is safe to join onto a layer root.
    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
    }

    /// The highest-precedence existing copy of `relativePath`.
    ///
    /// - Parameter relativePath: A path relative to a layer's root, e.g.
    ///   `"config.yaml"` or `"_partials/header.md"`. Rejected (returns
    ///   `nil`) if it is empty, absolute, or contains a `..` component —
    ///   such paths could otherwise escape the layer root.
    /// - Returns: The winning layer's file URL, or `nil` if no layer has it.
    public func nearest(_ relativePath: String) -> URL? {
        guard Self.isSafeRelativePath(relativePath) else { return nil }
        for layer in layers.reversed() {
            let candidate = layer.root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Every existing copy of `relativePath` across the stack.
    ///
    /// - Parameter relativePath: A path relative to a layer's root.
    ///   Rejected (returns an empty array) if it is empty, absolute, or
    ///   contains a `..` component — such paths could otherwise escape the
    ///   layer root.
    /// - Returns: File URLs for each layer that has `relativePath`, ordered
    ///   lowest to highest precedence.
    public func locate(_ relativePath: String) -> [URL] {
        guard Self.isSafeRelativePath(relativePath) else { return [] }
        return layers.compactMap { layer in
            let candidate = layer.root.appendingPathComponent(relativePath)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    /// Lists every file matching `suffix` under `subdirectory` in each layer,
    /// keyed by name with `suffix` stripped, with higher layers shadowing
    /// lower ones by name.
    ///
    /// - Parameters:
    ///   - subdirectory: A directory relative to a layer's root, e.g.
    ///     `"commands"`. Rejected (returns an empty dictionary) if it is
    ///     empty, absolute, or contains a `..` component — such paths could
    ///     otherwise escape the layer root.
    ///   - suffix: The filename suffix to match and strip, e.g. `".md"`.
    ///     Files without this suffix are ignored.
    /// - Returns: A dictionary from name (without `suffix`) to the winning
    ///   file's location and the layer that won it.
    public func enumerate(_ subdirectory: String, suffix: String) -> [String: Located] {
        guard Self.isSafeRelativePath(subdirectory) else { return [:] }
        var results: [String: Located] = [:]
        for layer in layers {
            let directoryURL = layer.root.appendingPathComponent(subdirectory, isDirectory: true)
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: directoryURL, includingPropertiesForKeys: nil)
            else {
                continue
            }
            for fileURL in contents {
                let fileName = fileURL.lastPathComponent
                guard fileName.hasSuffix(suffix) else { continue }
                let name = String(fileName.dropLast(suffix.count))
                results[name] = Located(url: fileURL, layer: layer)
            }
        }
        return results
    }
}
