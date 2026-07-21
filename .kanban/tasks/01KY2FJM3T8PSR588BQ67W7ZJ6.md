---
comments:
- actor: claude-code
  id: 01ky30hv1wcsd1nrtjcanbh2xs
  text: |-
    Implemented AgentsMd (Sources/FoundationModelsExtras/AgentsMd.swift) + AgentsMdError, TDD-first with 13 hermetic swift-testing cases in Tests/FoundationModelsExtrasTests/AgentsMdTests.swift covering: alias preference per directory (AGENTS.md > AGENT.md > CLAUDE.md), no-alias directories contributing no document, outermost-first/nearest-last ordering, .git root detection (directory-entry existence check only, never running git), explicit root: overriding detection and walking past a nearer .git, walk stopping at root, same-directory symlink alias (naturally never read since first-match wins), cross-directory symlink dedup by realpath(3)-resolved path, empty results (cwd==root, and multi-level with no files), and a fileNotReadable error on invalid UTF-8.

    Design notes:
    - Root/workingDirectory canonicalized once via realpath(3) (mirrors TestSupport.canonicalize's firmlink-safe approach already used by DotfolderStackTests) so the walk's stopping comparison and .git detection are robust to /var vs /private/var-style firmlinks.
    - Symlink dedupe tracks realpath(3) of each chosen alias file across the whole walk (nearest-to-outermost internally, reversed for output); the nearest occurrence of a given physical file wins, later (further-out) duplicates are dropped.
    - All 13 AgentsMd tests pass on first implementation; full `swift test` is green at 207/207 tests. `swift format -i -r Sources Tests` made no changes.

    No demo subcommand added (extras-demo agents) — not part of this task's stated public-surface/testing scope per the task description; plan.md §10 mentions it but the task text quoted here doesn't require it, so left out to stay in scope.
  timestamp: 2026-07-21T18:55:59.548271+00:00
position_column: doing
position_ordinal: '80'
title: 'AgentsMd: agent-instructions discovery (plan §10)'
---
Implement Pillar 4 per plan.md §10. Public surface: enum AgentsMd with struct Document { url, directory, text } and static func documents(from workingDirectory: URL, upTo root: URL? = nil) throws -> [Document]. Behavior: walk cwd up to root (default: nearest ancestor containing a .git entry, detected by directory entry — never by running git — else workingDirectory itself); at each level read the FIRST of AGENTS.md > AGENT.md > CLAUDE.md (AGENTS.md is the format per https://agents.md/, AGENT.md is the spec's migration alias, CLAUDE.md the ecosystem-compatibility alias); one file per directory; return outermost-first so nearest-last = the spec's closest-wins when consumers concatenate; dedupe symlinked aliases by resolved path (the spec suggests ln -s AGENTS.md AGENT.md). Discovery only, no policy: raw text with provenance; no templating, no user-level layer (consumers compose DotfolderStack.content("AGENTS.md") themselves). NOT named memory — this is agent instructions/context. Hermetic swift-testing per §10: alias preference per directory, one-per-directory, ordering, .git root detection vs explicit root:, walk stops at root, symlink dedupe, empty results (no files; cwd == root). Full doc coverage (DocCoverageTests will enforce).

## Review Findings

Round 1 (`mcp__sah__review` op `review sha` HEAD~1..HEAD):
- [x] `AgentsMd.swift`: `realPath(of:)` and `canonicalize(_:)` duplicated the identical `realpath(3)` buffer/decode pattern — extracted a shared private `resolvedPath(_:)` helper; both now delegate to it. Fixed.
- [ ] (not acted on) Doc-comment "blank line between summary and elaboration" on `Document.init` — contradicts the established, already-in-tree convention in `DotfolderStack.swift`'s `Layer.init`/`Located.init` doc comments (no blank line there either), which this file was explicitly written to mirror. Treated as a false positive against actual codebase convention.