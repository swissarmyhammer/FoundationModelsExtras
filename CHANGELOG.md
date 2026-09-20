# Changelog

Each change to the public API of this package is recorded here. The newest
change is at the top.

## Unreleased

### Added: `DotfolderStack(layers:)` and the execute bit of the winning copy

`DotfolderStack` has a second initializer that takes an explicit list of
layers, and each stack of the family answers for the execute bit of the
winning copy.

**Cause.** `FoundationModelsSkills` held one shim for each gap: an internal
`init(layers:)` that called the derived initializer with a placeholder name
and then replaced the layers, and a direct read of `FileManager` for the
mode of a file. The rule of the family is that the raw work of loading lives
in Extras, thus both gaps close here.

**What changed.**

- `DotfolderStack.init(layers:)` is public. It stores the layers, lowest
  precedence first. It derives no layer, it applies no name rule, and it
  reads no file, the same as the derived initializer. A consumer that holds
  its own layers — a list of host directories, or the marketplace layers of
  a store below the local layers — makes a stack from them.
- The well-known template value `dotfolder_name` comes from the
  highest-precedence `.project` layer. A derived stack holds one `.project`
  layer, thus its value does not change. A stack from `init(layers:)` can
  hold more than one `.project` layer, and the last one names the stack. A
  stack with no `.project` layer has no name.
- `isExecutable(_:)` is a new requirement of `DotfolderStacking`, and
  `DotfolderStack`, `StenciledDotfolderStack` and `FrontmatterDocumentStack`
  each answer it. It reports the execute bit of the copy in the highest
  layer that holds the path, through the same path checks as `exists(_:)`:
  a path that is empty, absolute or that holds a `..` component, a copy that
  resolves through a symbolic link to a location outside its layer root, and
  a missing file each give `false`. A consumer that lists a file or that
  runs a script no longer needs `FileManager`.

**This change adds a requirement to a protocol.** A type outside this
package that conforms to `DotfolderStacking` does not compile until it adds
`isExecutable(_:)`. A stack that is layered over another stack passes the
call to its base.

### Added: the `Marketplace` product

`MarketplaceStore.init(sources:layout:cacheDirectory:policy:)` makes a store
over a source list, with no network work. `marketplaceLayers()` gives one
`MarketplaceLayer` for each source, lowest precedence first, from the disk
alone; `start()` brings each git source to its remote head one time;
`update(_:force:)`, `check()`, `pin(_:sha:)` and `unpin(_:)` are the
commands of a host; `events` and `layerUpdates` are the two streams. The
product is the separate `Marketplace` target, which carries libgit2 and
Yams; the core target does not change. The test doubles are the
`MarketplaceFixtures` product.

**Cause.** `FoundationModelsSkills` carried the whole marketplace: the git
transport, the catalog read, the cache, the snapshot writer, the store and
the config loader. Each of them reads files, and none of them knows what a
skill is. The decision of 2026-09-19 is that Extras owns all marketplace
file reading, thus the capability leaves Skills, and Skills reads a
materialized layer root the same way it reads a local layer. The one skill
fact of the old code, the name `SKILL.md`, became an input of
`MarketplaceLayout`.

**What changed.**

- `MarketplaceStore` is an actor that owns every marketplace of a host: the
  source list, the cache on the disk, and the layers that a consumer reads.
  `init(sources:layout:cacheDirectory:policy:)` reads only the disk;
  `cacheDirectory` has the default `cacheDirectory(environment:)`, which
  reads `SKILLS_MARKETPLACE_CACHE` and falls back to
  `~/.cache/skills/marketplaces`. A second initializer takes a `transport`,
  a `clock` and an `environment`, for a test. `start()` applies a pending
  snapshot and brings each git source to its remote head; `stop()` ends the
  periodic check; `check()` gives one `MarketplaceStatus` for each source
  and downloads nothing; `update(_:force:)` installs a new commit and gives
  the events of the pass; `pin(_:sha:)` and `unpin(_:)` hold or release one
  marketplace at one commit, and throw `MarketplacePinError`. `diagnostics`
  is the list of findings; no message holds a credential.
- `MarketplaceLayerProviding` is what a consumer needs from a store:
  `marketplaceLayers()`, lowest precedence first, and `layerUpdates`, one
  value for each change. A symlink swap sends no reliable file-system
  event, thus the signal, and not a file watcher, is what makes an update
  reach the consumer.
- `MarketplaceLayer` is one marketplace as the consumer sees it: `layer`, a
  `DotfolderStack.Layer` with the source `.marketplace`; `provenance`; and
  `isWatchable`, `true` for a folder on this computer and `false` for a
  cache-backed root. `MarketplaceProvenance` holds `id`, `url`, `sha` and
  `catalogVersion`, and `displayText` names the snapshot without the URL.
- `MarketplaceLayout` names the shape of a marketplace tree:
  `documentName`, the document that marks an entry folder, with no default;
  `excludedDirectoryNames`, with the default `.git` and `node_modules`; and
  `partialsDirectoryName`, with the default `_partials`.
- `MarketplaceSource` names one marketplace: `url`, `ref`, `sha`, `path`,
  `alias`, `select` and `autoUpdate`. It has no `grants` field: a
  marketplace layer always renders untrusted, and there is no
  per-marketplace permission. `SkillSelection` is `.all`, `.plugins(_:)` or
  `.skills(_:)`.
- `MarketplacePolicy` is what the host lets the store do: `snapshotLimits`,
  `allowedSources` and `blockedSources` over `SourcePattern` (`.exact`,
  `.owner(host:owner:)`, `.hostRegex`, `.pathPrefix`), `credentials`,
  `checkInterval`, `autoUpdate`, `checkOnly`, `applyUpdates`
  (`.immediately` or `.nextLaunch`) and `fetchTimeout`.
  `automaticUpdatesAllowed(environment:)` reads
  `SKILLS_MARKETPLACE_AUTOUPDATE`. `SnapshotLimits` holds `maxBytes` and
  `maxFiles`. `MarketplaceCredential` holds `username` and `token`, and its
  description, its debug description and its mirror show no secret.
- `MarketplaceConfig` is the `marketplaces.yaml` list of a stack:
  `load(from:includeProject:)` reads the user layer and the project layer,
  and `save(to:)` writes one file. A failure is a `MarketplaceConfigError`
  that names the file.
- `MarketplaceEvent` is `.checked`, `.updateAvailable`, `.updated` or
  `.failed`, each with the display id and the commits, and never a URL or
  a credential. `MarketplaceStatus` holds `id`, `current`, `latest`,
  `error` and `updateAvailable`. `MarketplaceDiagnostic` holds a
  `severity` of `.advisory`, `.warning` or `.error`, a `marketplaceID` and
  a `message`.
- `GitTransport` is the protocol of the fetch: `remoteHead` and `fetch`,
  each with a credential provider that is asked one time and only for the
  origin of the source. `LibGit2Transport` is the one implementation; it
  never starts the `git` binary. `GitTransportError` is `.unreachable`,
  `.refNotFound`, `.cancelled`, `.timedOut` or `.libgit2(code:message:)`.
- `MarketplaceFixtures` is a product for the tests of a consumer:
  `GitFixtureRepository` builds a bare repository with libgit2 only;
  `MarketplaceStoreFixture` builds a store over a temporary cache;
  `RecordingGitTransport`, `GatedGitTransport`, `ManualClock`,
  `MarketplaceEventLog` and `TestSignal` let a store test wait on no real
  time.

### Added: `ProcessRunner`, the family's process runner

`ProcessRunner.run(executable:arguments:workingDirectory:timeout:outputCap:registry:)`
runs one executable directly, with no shell, in its own process group. It
merges stdout and stderr into one bounded tail, kills the whole group with
`SIGKILL` at the timeout, and holds the pid in a `ProcessRegistry` from the
spawn to the reap. The `registry` parameter defaults to
`ProcessRegistry.global`, so the `atexit` sweep is the backstop for a run
that a normal exit of the host cuts short.

**Cause.** `FoundationModelsSkills` carried a runner of its own, with no
link to `ProcessRegistry`: a session that ended while a script ran left the
process group behind. The runner is not skill semantics. It belongs beside
the registry, so each consumer of the family gets the same limits and the
same backstop.

**What changed.**

- `ProcessRunner.OutputCap` names the two limits of the kept output: the
  count of complete lines, and the most bytes the run holds at one time.
  The read cuts at the byte limit while it runs, so a process that writes
  without end does not grow the memory of the caller.
- `ProcessRunner.Outcome` names what happened: `termination` is
  `.exited(code:)`, `.signaled(_:)`, or `.timedOut`; `lineCount` is the
  count of all the lines the process wrote; `output` is the kept tail; and
  `isTruncated` marks a cut. `duration` is the wall-clock time of the run.
- `ProcessRunner.Failure` is thrown when the spawn did not reach exec
  (`.spawnFailed(status:)`), or when the reap failed (`.waitFailed(errno:)`).

### Added: `DotfolderStack` is directory-shaped, and `DotfolderStacking` is its interface

This change breaks the source of a consumer that names the type
`DotfolderStack.Located`. That type is now the generic `Located<Item>` at the
top level of the module, and `enumerate(_:suffix:)` gives
`[String: Located<String>]`. A consumer that reads `url` and `layer` from an
`enumerate` result, and does not name the type, compiles with no change.
`nearest`, `content`, `locate` and `enumerate` keep their signatures and their
results.

**Cause.** The stack was file-shaped and flat. It could find one file, and it
could list the files of one subdirectory by suffix, but it could not give a
view of a directory tree. A layer is a directory tree, and a consumer that
holds a skill at `<root>/<id>/SKILL.md` with scripts and references beside it
needs one combined view of the trees of all the layers.

**What changed.**

- The stack is directory-shaped. It gives one combined view of the directory
  trees of all the layers. The unit of override is the file: for a path
  relative to a layer root, the copy in the highest layer that holds that path
  wins. A directory is never replaced; it holds the union of the names of all
  the layers. The view is computed at the time of the call. The stack holds no
  cache, thus it needs no file watcher; a consumer that caches a result keeps
  its own watcher.
- `DotfolderStack.tree(_:)` is new. It gives the recursive combined view of a
  subdirectory, or of the layer roots when the argument is `nil`. The key is
  the file path relative to the subdirectory, at every depth.
- `DotfolderStack.childDirectories(of:)` is new. It gives each immediate child
  directory name of the union, with the layers that hold it, lowest precedence
  first.
- `DotfolderStack.layerDirectories(_:)` is new. It gives the layers that hold
  a directory, lowest precedence first, and an empty array when no layer holds
  it.
- `DotfolderStacking` is a new protocol, generic in `Item`, what one lookup
  gives back. It has `layers`, `item(at:)`, `items(in:named:)`, `tree(_:)`,
  `childDirectories(of:)`, `layerDirectories(_:)`, `data(_:)`, `data(_:in:)`,
  `size(of:)` and `exists(_:)`. `DotfolderStack` conforms with
  `Item == String`.
- `Located<Item>` is new, and it replaces `DotfolderStack.Located`. It holds
  `url`, `layer` and `value`, the value the stack made from the winning file.
- `DotfolderStack.item(at:)` is new. It gives the winning copy of a path with
  its layer and its text. `items(in:named:)` gives, for each child directory
  of the union that holds a named file, that file; one call gives each
  `<id>/SKILL.md` of a skill directory.
- `DotfolderStack.data(_:)`, `data(_:in:)`, `size(of:)` and `exists(_:)` are
  new. They give the bytes, a byte range, the size, and the presence of the
  winning copy, thus a consumer never needs `FileManager`.
- Each lookup resolves the symbolic links of its candidate and refuses a path
  that leaves its layer root, in addition to the text check that refuses an
  empty path, an absolute path, and a `..` component. This rule came from the
  `PathConfinement` type of `FoundationModelsSkills`.
- `enumerate(_:suffix:)` is now the top level of `tree(_:)`, filtered by
  suffix. Its result does not change.
