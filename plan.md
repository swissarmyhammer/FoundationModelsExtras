# Plan: FoundationModelsExtras — the family's substrate leaf

A small Swift package at the **bottom** of the swissarmyhammer FoundationModels
family dependency graph. It holds the substrate every consumer shares and no
consumer should reimplement: the slash-command vocabulary, the layered
dotfolder stack, Stencil templating for the content that lives in those
folders, `AgentsMd` discovery of agent-instructions files (§10), and
`LayeredYAMLDocument` — the family's one layered-merge rule (§11).
Everything may import it; it imports almost nothing.

**Status:** pillars 1–3 built and pushed · pillars 4 (`AgentsMd`, §10) and 5
(`LayeredYAMLDocument`, §11) planned
· **Target:** Swift 6.2 tools, macOS 27+, Apple Silicon
· **Updated:** 2026-07-21

---

## 1. Why this package exists

Two forces meet here:

**The dependency diamond.** The family's dependency law says arrows only point
downward — the harness imports tool packages, never the reverse. Anything tool
packages and the harness must both name (a protocol tools conform to, a type
they exchange) therefore needs a home *below* both. A shared leaf: tool
packages depend on it downward when they choose to, the harness depends on
everything and adapts.

```
                FoundationModelsAgentHarness        (sole adapter at the top)
               /            |              \
   FoundationModelsFileTool | FoundationModelsSkills …
               \            |              /
                FoundationModelsExtras              (this package; leaf)
```

**The swissarmyhammer lessons.** The original `../swissarmyhammer` (Rust)
proved out a content substrate this package deliberately ports — and one
mistake it deliberately drops:

- *Keep* (from `swissarmyhammer-templating` + `swissarmyhammer-config`):
  templated content (Liquid there; Stencil here, §4 — the corpus carries over
  nearly verbatim); a pluggable partial system (`PartialLoader`, shared
  `_partials/` used across prompts, skills, and agents); a providable
  `TemplateContext`; environment variables injected with a clear precedence
  ladder (explicit args > env > config > well-known system variables); a
  trusted/untrusted split for template validation; layered file resolution
  (builtin < user < project) with per-item source tracking.
- *Drop*: **compiled-in builtins.** swissarmyhammer embeds its `builtin/`
  content into the binary at build time
  (`include!(concat!(env!("OUT_DIR"), "/builtin_partials.rs"))`) — which
  meant a full recompile to change a markdown file. Here, **every layer is a
  real directory read at runtime**; no content is ever a Swift string
  constant or an embedded resource blob. Shipped defaults are just the
  lowest-precedence directory (§3).

## 2. Pillar 1 — Slash commands (the cross-package vocabulary)

```swift
/// A user-invocable `/name` command contributed to a harness session.
public struct SlashCommand: Sendable {
    public var name: String          // "ps" → surfaced as /ps (no leading slash)
    public var description: String   // one line, shown in pickers and /help
    public var argumentHint: String? // e.g. "<pid>", shown as input hint
    public var body: Body

    public enum Body: Sendable {
        /// Expands into an ordinary model turn: the template (rendered by
        /// Pillar 3, untrusted) plus the user's arguments become the turn's
        /// prompt. The only body kind data sources (template files, MCP
        /// prompts) may produce.
        case prompt(template: String)
        /// Runs code, streams text output, never touches the model. Only
        /// linked Swift conformers can construct this — code is trusted
        /// because it is already in-process.
        case action(@Sendable (Invocation) -> AsyncThrowingStream<String, Error>)
    }

    public struct Invocation: Sendable {
        public var arguments: String     // raw text after "/name "
        public var workingDirectory: URL // the session's cwd
    }
}

/// Conformers contribute slash commands to whatever session context they are
/// registered in. Deliberately independent of `FoundationModels.Tool`: a
/// conformer may be a tool, a companion object, or a pure discovery engine
/// that ships no tool at all (Skills).
public protocol SlashCommandProviding: Sendable {
    func commands(workingDirectory: URL) async -> [SlashCommand]
    /// Pushed re-publications when the set changes mid-session. nil = static.
    var commandUpdates: AsyncStream<[SlashCommand]>? { get }
}
```

Nothing harness-shaped can appear in these signatures — this package sits
below the harness, and that constraint keeps command handlers honest.

## 3. Pillar 2 — `DotfolderStack` (moved here from the harness)

The layered-locations type the harness plan §4 describes, now shared family
infrastructure (Shelltool's stacked `ShellPolicy` YAML is the obvious second
adopter). A consumer passes a bare name; the stack derives the layers in
precedence order:

```swift
public struct DotfolderStack: Sendable {
    public init(name: String,                  // "myagent" → ~/.config/myagent + <cwd>/.myagent
                workingDirectory: URL,
                defaultsDirectory: URL? = nil) // lowest layer: shipped defaults, a REAL directory

    /// defaults < user ($XDG_CONFIG_HOME/<name>/, default ~/.config/<name>/) < project (<cwd>/.<name>/), in precedence order.
    public var layers: [Layer]

    public func nearest(_ relativePath: String) -> URL?        // highest-precedence copy
    public func locate(_ relativePath: String) -> [URL]        // all copies, lowest → highest
    /// e.g. enumerate("commands", suffix: ".md") → name ⇒ winning URL + source layer
    public func enumerate(_ subdirectory: String, suffix: String) -> [String: Located]
}
```

- **No compiled-in builtins.** `defaultsDirectory` is how shipped content
  enters: a plain directory the consumer points at (materialized on first
  run, or an app-bundle *directory* read in place). Editing a default is
  editing a file. A dev override environment variable
  (`<NAME>_DEFAULTS_DIR`) points the lowest layer at a source checkout so
  iteration never involves a compile.
- **Source tracking.** Every resolved item knows which layer won (the
  swissarmyhammer `FileSource` idea) — consumers surface "where did this come
  from" in diagnostics (`/status`, `/memory` headers).
- **Merge semantics stay with consumers.** The stack locates and enumerates;
  key-level config merging (scalars/arrays replace wholesale, sections merge
  by key) is the harness's codec policy, not the stack's. The stack is the
  only thing that touches disk; consumers stay constructible in tests with
  no file I/O.

## 4. Pillar 3 — Templating (Stencil: partials, context, env)

Everything the dotfolder layers hold — `.md`, `.yaml`, and `.md`-with-YAML-
frontmatter — is **a template first, a document second**:

```swift
public struct TemplateContext: Sendable {
    public init()
    public mutating func set(key: String, to value: TemplateValue)  // string/number/bool/array/dictionary
}

public struct TemplateEngine: Sendable {
    /// Partials resolve through the stack: each layer may hold `_partials/`;
    /// `{% include "header.md" %}` finds the nearest `_partials/header.md`
    /// via a custom Stencil `Loader` over the stack — the shared-partials
    /// scheme swissarmyhammer uses across prompts, skills, and agents.
    public init(partials: DotfolderStack?)

    public enum Trust: Sendable { case trusted, untrusted }
    public func render(_ text: String,
                       context: TemplateContext,
                       trust: Trust) throws -> String
}

/// Textual frontmatter split — no YAML dependency here; consumers decode the
/// frontmatter text with their own codec (the harness has Yams).
public enum FrontmatterDocument {
    public static func split(text: String) -> (frontmatter: String?, body: String)
}
```

- **The engine is Stencil** (stencilproject/Stencil — the Jinja/Django-style
  engine behind Sourcery and SwiftGen), wrapped behind our `TemplateEngine`
  facade so consumers never touch Stencil types directly. Decision grounded
  in the corpus, not taste: a survey of swissarmyhammer's entire `builtin/`
  content (2026-07-18) found exactly `{% include %}` ×20, `{% if %}` ×3,
  `{% render %}` ×1, `{% for %}` ×1, and **zero filters** — and Stencil's
  syntax (`{{ var }}`, `{% if %}`, `{% for x in xs %}`, `{% include %}`,
  `|filter`) covers that corpus nearly verbatim. **One-time content
  migration:** the single `{% render %}` becomes `{% include %}`; nothing
  else changes. Golden tests check in the migrated corpus with expected
  outputs so the carryover stays pinned.
- **Partials via a custom `Loader`.** Stencil's `Environment(loader:)` seam
  takes a `DotfolderLoader` over the stack's layered `_partials/`
  directories, nearest layer wins — no filesystem convention of Stencil's
  leaks through; the stack stays the only thing that touches disk.
- **Untrusted mode is a restricted `Environment`**: whitelisted filters and
  tags only, the loader confined to `_partials/`, include-depth and
  output-size limits. Stencil has no filesystem/network/exec capability of
  its own, so the wrapper — which we own — is the whole enforcement surface.
- **Maintenance risk, eyes open**: Stencil's release cadence has slowed and
  it brings PathKit transitively. Mitigations: pin the version; we use a
  small, stable slice of it; and the family already owns forks when upstream
  stalls (mlx-swift-lm) — a swissarmyhammer fork is the recorded escape
  hatch. Also surveyed and rejected: *LiquidKit* (true Liquid port but
  effectively orphaned, unaudited on the untrusted path), *swift-mustache*
  (maintained but logic-less, syntactically alien), *Jinja/johnmai-dev*
  (maintained, already in the family's transitive graph via
  swift-transformers, but chat-template-scoped), and an *in-house subset
  engine* (buildable — the corpus is a page of grammar — but owning a parser
  forever loses to wrapping a mature one; it remains the fallback if Stencil
  ever becomes untenable).
- **Variable precedence** (swissarmyhammer's ladder, kept): explicit
  `TemplateContext` values > environment variables > well-known system
  variables (dotfolder name, working directory, date, hostname). Consumers
  may extend the context (the harness adds session-shaped values; Skills
  adds skill arguments).
- **Trust split, kept**: `trusted` for consumer-shipped defaults, `untrusted`
  for user/project-layer files — untrusted rendering is validated and
  side-effect-free (no filesystem or network access exists in the engine at
  all; env vars are *values in the context*, not an exec capability).
- **Whole-file render, then parse.** A templated file renders as one text
  (frontmatter included, so YAML values can be templated), then splits/
  decodes. One rule, no per-format special cases.

## 5. Rules

- **Dependency budget: Foundation + Stencil + Yams (PathKit rides along
  transitively), pinned.** No family imports ever; anything else fights its
  way in. (Yams fought its way in 2026-07-21 for `LayeredYAMLDocument` §11 —
  three consumers needed the same layered merge: ACP's `AgentConfiguration`,
  Shelltool's `ShellPolicy`, future Skills. Frontmatter *splitting* remains
  textual; full-document *decoding* stays the consumer's — Extras merges
  trees, consumers decode `Codable`.)
- **Scope fights its way in.** The bar for a new type is a demonstrated
  consumer on both sides of the diamond. Deliberately deferred: status
  contributions, config-schema fragments.
- **Coordination point.** Changes ripple to all conformers and the harness
  adapter at once — additive evolution, breaking changes are a family event.
- **Trust boundary documented at the type.** `.action` bodies require linked
  Swift; data channels are `.prompt`-only; untrusted templates render under
  validation. These three sentences are the security story.

## 6. Known consumers (as planned today)

| Package | Uses |
|---|---|
| FoundationModelsACP (`../FoundationModelsACP/plan.md` — the composition layer: config + commands + wire over harness and Router) | all pillars: `SlashCommand` vocabulary for its registry, `DotfolderStack` + `LayeredYAMLDocument` (§11) for `AgentConfiguration`, rendering every dotfolder document before parse, `AgentsMd` when assembling session instructions |
| FoundationModelsAgents (plan-only) | `AgentsMd` (§10) when assembling per-sub-agent instructions, so sub-agents see the repo's agent-instructions files |
| FoundationModelsSkills (plan-only) | `SlashCommandProviding` conformer; renders SKILL.md through the same engine and `_partials/` |
| FoundationModelsShelltool | candidate adopter of `DotfolderStack` for its stacked `ShellPolicy` YAML; potential `/ps`-style `.action` commands — illustrative, not committed |

Note the 2026-07-21 re-scope: **FoundationModelsAgentHarness itself no longer
imports Extras.** The harness became a constructor-fed loop (router, tools,
instructions, compaction instructions — no file I/O; its only dependency is
Router), so the Extras-consuming composition moved up to the product layer
and the agents tool. The diamond in §1 still holds — Extras stays the leaf
both sides of it share — the top vertex is just the product/agents layer now.
Tool packages that need none of this never import it.

## 7. Examples

Family convention: an example is the living contract test — a small runnable
that proves the public surface end-to-end, kept compiling forever
(`Examples/HarnessDemo` plays this role for the harness). Extras ships one:

**`Examples/ExtrasDemo`** — a thin ArgumentParser executable with one
subcommand per pillar, run against a fixture dotfolder tree checked in beside
it (`Examples/ExtrasDemo/Fixtures/` with `defaults/`, `user/`, and `project/`
layers so no demo ever touches the real home directory):

- `extras-demo stack` — builds
  `DotfolderStack(name:workingDirectory:defaultsDirectory:)` over the
  fixtures, resolves `config.yaml` and enumerates `commands/*.md`, printing
  **which layer won each item** — source tracking made visible, the
  defaults-are-just-files story demonstrated by pointing
  `EXTRASDEMO_DEFAULTS_DIR` somewhere else and watching the answers change,
  no rebuild.
- `extras-demo render <file>` — renders a frontmatter+markdown template
  through the engine: a `{{ variable }}` from `--set key=value` context, an
  environment variable, a well-known value, and a `{% include "header.md" %}`
  partial resolved from the layered `_partials/` (the project fixture shadows
  the user one, proving nearest-wins). A `--untrusted` flag shows the trust
  split: the same file rendered under validation, with a deliberately bad
  fixture that renders trusted but is rejected untrusted.
- `extras-demo commands` — registers a demo `SlashCommandProviding` with one
  `.prompt` command (template rendered before display) and one `.action`
  command (streams a few lines), invokes both, then ticks `commandUpdates`
  to show a re-published set — the exact consumption pattern the harness's
  registry uses (harness plan §6.2).

The demo doubles as the copy-paste onboarding for the two audiences this
package serves: tool authors see the conformer side (`commands`), consumers
see the adapter side (`stack` + `render`).

## 8. Testing

swift-testing, hermetic, no gated tests (nothing touches a model or network):
stack layering and `enumerate` precedence against fixture directories with
source-tracking asserts; defaults-directory override via the env var;
`SlashCommand`/fake-provider static and streaming paths; template rendering —
variable-precedence ladder, partial resolution across layers (project
`_partials/` shadows user shadows defaults), untrusted-mode validation,
whole-file-render-then-split round-trips for md, yaml, and frontmatter+md.

## 9. Build order

1. **Stack + engine**: `DotfolderStack`, the Stencil wrap (`TemplateEngine`
   facade, `DotfolderLoader`, restricted untrusted `Environment`), the
   one-time corpus migration (`render`→`include`) with its golden fixtures —
   this is the long pole and unblocks harness build-order step 3
   (Configuration).
2. **Slash-command vocabulary**: the two types + provider tests — trivial,
   can land first if the harness wants the seam early.
3. **`Examples/ExtrasDemo`** (§7): lands with whichever of 1–2 finishes
   last; its fixture tree is shared with the unit tests where practical.
4. CI from swissarmyhammer/workflows like in sibling packages
5. **`AgentsMd`** (§10): the ancestor walk + alias preference + tests over
   fixture trees, plus an `extras-demo agents` subcommand. Independent of
   1–4 (steps 1–4 are done); unblocks instruction assembly in
   FoundationModelsACP and FoundationModelsAgents.
6. **`LayeredYAMLDocument`** (§11): Yams in, `YAMLValue` + merge + per-key
   source tracking + `extras-demo config`. Independent of 5; unblocks ACP's
   `AgentConfiguration` and Shelltool's `ShellPolicy` migration.

## 10. Pillar 4 — `AgentsMd` (agent-instructions discovery)

**What it is.** [agents.md](https://agents.md/) defines `AGENTS.md` as "a
README for agents: a dedicated, predictable place to provide the context and
instructions to help AI coding agents work on your project." It is
**instructions and context — not memory**; nothing in the format remembers
anything across sessions, so this pillar is deliberately named `AgentsMd`
after the file, never "memory."

**Why it lives here.** Two consumers assemble session instructions and need
the identical discovery walk: the product layer (root sessions) and
FoundationModelsAgents (per-sub-agent instructions — a sub-agent that hasn't
read the repo's `AGENTS.md` is worse at its job). The harness itself never
does this — it is constructor-fed and reads no files; callers fold the
result into the `instructions` value they pass in. One convention, two
consumers, and Extras is already the family's only disk-toucher: textbook
pillar.

```swift
/// Discovery of AGENTS.md agent-instructions files (https://agents.md/).
public enum AgentsMd {
    public struct Document: Sendable {
        public var url: URL        // the file that was read
        public var directory: URL  // the directory level it governs
        public var text: String
    }

    /// Walks from `workingDirectory` up to `root` — default: the enclosing
    /// git repository root (nearest ancestor containing `.git`; detected by
    /// directory entry, never by running git), else `workingDirectory`
    /// itself — reading at each level the first of `AGENTS.md`, `AGENT.md`,
    /// `CLAUDE.md`. One file per directory. Returned outermost-first, so a
    /// consumer concatenating in order gives the nearest file the last
    /// word — the spec's "the closest one takes precedence."
    public static func documents(
        from workingDirectory: URL, upTo root: URL? = nil
    ) throws -> [Document]
}
```

- **Names and precedence.** `AGENTS.md` is the format; `AGENT.md` is the
  spec's own migration alias; `CLAUDE.md` is the ecosystem-compatibility
  alias (Claude Code). Preference within a directory is that order, first
  match only. Symlinked aliases (the spec's suggested
  `ln -s AGENTS.md AGENT.md` migration) must not double-read: dedupe by
  resolved path.
- **Discovery only — no policy.** `AgentsMd` returns raw text with
  provenance. How consumers use it is theirs: concatenate into
  instructions, render `untrusted` through the `TemplateEngine` first, or
  filter by directory. A user-level file is *not* part of the spec — a
  consumer that wants `~/.config/<name>/AGENTS.md` composes it themselves
  via `DotfolderStack.content("AGENTS.md")` and prepends it (most-general
  first, so project files still win).
- **Testing** (hermetic, per §8): fixture trees exercising alias preference
  per directory, one-file-per-directory, nesting order
  (outermost-first/nearest-last), `.git` root detection vs explicit
  `root:`, walk stops at `root`, symlink dedupe, and empty results (no
  files, cwd == root).
- **Demo**: `extras-demo agents` walks a fixture tree and prints each
  discovered document with the directory it governs and which alias
  matched — provenance made visible, same spirit as `extras-demo stack`.

## 11. Pillar 5 — `LayeredYAMLDocument` (the family's one merge rule)

**Why (decision 2026-07-21, with FoundationModelsACP).** Three consumers
need the identical layered-YAML behavior over the stack: ACP's
`AgentConfiguration` (models, tools, MCP servers), Shelltool's stacked
`ShellPolicy`, and future Skills aggregation. Merge semantics belong with
the thing that defines the layers, written once — this is the change that
brought Yams into the dependency budget (§5).

```swift
/// A YAML document resolved across the stack: locate every layer's copy,
/// render each through the engine (trusted for the defaults layer,
/// untrusted above), parse, and merge with the family's one rule.
public struct LayeredYAMLDocument: Sendable {
    /// The merged tree. Scalars and ARRAYS replace wholesale when a later
    /// layer defines them; dictionaries (sections) merge by key.
    public var root: YAMLValue          // string/int/double/bool/array/dictionary/null

    /// Which layer supplied the winning value for a key path — the
    /// source-tracking story (§3) extended to individual keys, feeding
    /// consumer diagnostics ("/status: profile.standard ← project").
    public func source(of keyPath: [String]) -> DotfolderStack.Source?

    public static func load(
        _ relativePath: String,        // e.g. "config.yaml"
        from stack: DotfolderStack,
        engine: TemplateEngine,
        context: TemplateContext
    ) throws -> LayeredYAMLDocument
}
```

- **Extras merges trees; consumers decode.** `root` re-encodes into any
  `Codable` type (via a `YAMLValue` decoder) — the schema stays the
  consumer's, exactly as the stack left codec policy with consumers before;
  only the *merge* centralizes.
- **Errors are hard and located**: a present-but-malformed layer names the
  file and line — never silently fall back over a typo'd config. Missing
  layers are simply absent.
- **Render-then-parse per layer** (§4's one rule): each layer's text renders
  under its own trust before parsing, so templated values (e.g. an MCP
  server's `env: { TOKEN: "{{ env.TOKEN }}" }`) work per layer.
- **Testing** (hermetic, per §8): scalar/array wholesale replacement vs
  section merge-by-key across three fixture layers; per-key source
  tracking; malformed-layer hard error with file+line; templated values
  resolved before merge; round-trip into a fixture `Codable` schema.
- **Demo**: `extras-demo config` loads a fixture `config.yaml` across
  layers and prints the merged tree annotated per key with the winning
  layer.
