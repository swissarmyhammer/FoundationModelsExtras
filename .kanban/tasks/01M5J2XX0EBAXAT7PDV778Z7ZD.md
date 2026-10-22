---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5j71j77b20rrn3a7e4xjrr2
  text: |-
    Research (implement):
    - swift-huggingface `HubClient` has three inits. `init(session:userAgent:cache:)` hardcodes `tokenProvider: .environment` and host `Self.detectHost()`. The only init that takes a `TokenProvider` is `init(session:host:userAgent:tokenProvider:cache:)`, and it REQUIRES `host: URL`. `detectHost()` is private: it reads `HF_ENDPOINT` (via `URL(string:)`) else `HubClient.defaultHost` (public). So `hubClient()` must give the host itself to keep honoring `HF_ENDPOINT`; plan is a small static helper with a named `HF_ENDPOINT` constant, plus a test that `HF_ENDPOINT` still sets the host.
    - `HubClient.bearerToken` (public, `get async`) returns `try? await tokenProvider.getToken()`, so tests can read the token the client would send without network.
    - `TokenProvider` cases: `.fixed(token:)`, `.environment`, `.oauth(getToken:)`, `.composite([...])`, `.custom(@Sendable () async throws -> String?)`, `.none`. It is `Sendable`, so `MLXModelLoader` stays `Sendable`.
    - Callers of `MLXModelLoader(...)`: ModelPool default arg, unit tests, integration-test support. All use defaulted args, so adding a defaulted parameter in the middle breaks none. Internal `init(cache:tokenizerLoader:)` used by tests gets the parameter too.
  timestamp: 2026-10-22T16:27:55.495389+00:00
- actor: claude-code
  id: 01m5j7c0gf7n98t2t0fa3xm0mn
  text: |-
    Implementation notes:
    - `MLXModelLoader` stores `private let tokenProvider: TokenProvider`. Public init is `init(cacheDirectory:tokenProvider: = .environment, tokenizerLoader:)`, and the internal `init(cache:tokenProvider: = .environment, tokenizerLoader:)` gets the same parameter. `hubClient()` now builds `HubClient(host: Self.hubHost(), tokenProvider: tokenProvider, cache: cache)`.
    - Host: swift-huggingface's only init that takes a `TokenProvider` also requires `host`, and its `detectHost()` is private. To keep honoring `HF_ENDPOINT`, a new `private static func hubHost()` reads `HF_ENDPOINT` (named constant `endpointVariable`) and falls back to `HubClient.defaultHost`, the same behavior as the library's private detectHost. This is the "contract does not fit" case of the reuse rule: the library logic is private.
    - Gotcha: `HTTPClient` normalizes the host with a trailing slash (`https://hub.example.test/`), so the host tests compare `host.host()`, not URL equality.
    - Tests: new nested suite `MLXModelLoaderTests.HubClientTests` with the `.serialized` trait, because its tests set the process variables HF_TOKEN and HF_ENDPOINT. It checks: `.fixed` gives "t"; `.none` gives nil even when HF_TOKEN is set; the default reads HF_TOKEN; the host follows HF_ENDPOINT; with HF_ENDPOINT unset the host is the Hub. Tokens are read through `HubClient.bearerToken`, so no network. The `withEnvironment` helper is now async and takes `[String: String?]`, where nil unsets a variable. The one existing caller, `cacheFolderIsTheDownloadFolder`, is now `async`.
    - RED: compile failure "extra argument 'tokenProvider' in call". GREEN: 5/5 in the filtered suite.
    - Lint: FoundationModelsExtras has no `.swift-format`, so `swift format lint -s` uses the 2-space/100-column defaults and flags every line of these legacy 4-space files. Excluding Indentation and LineLength, the findings on both files are the same at HEAD and now (AddLines/OrderedImports/TrailingComma, all already there), so this change adds none. I kept each file's existing 4-space style; the longest added line is 118 characters.
    - README still documents only `MLXModelLoader(tokenizerLoader:)`. The card asks for the doc comment only, so the README is unchanged.
  timestamp: 2026-10-22T16:33:37.807638+00:00
- actor: claude-code
  id: 01m5j7c346k7afdm647ycty3gn
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift, Tests/FoundationModelsExtrasTests/ModelPool/MLXModelLoaderTests.swift. `swift test --filter MLXModelLoaderTests.HubClientTests`: 5/5 pass. Full `swift test`: exit 0, 1542 tests in 159 suites passed, 0 failed. The only warning is SwiftPM's "missing creator for mutated node" on the mlx-swift_Cmlx.bundle dependency, which was already there. `swift format lint -s`: no new findings beyond the defaults applied with no config (see the notes above). Not committed.
    - next: /review
  timestamp: 2026-10-22T16:33:40.486300+00:00
- actor: claude-code
  id: 01m5j7dnnvs512m9angrfx0pdr
  text: |-
    ### test — green
    - evidence: swift test — 1542 tests in 159 suites passed, 0 failed, 0 skipped; no compiler warnings in our sources (only a SwiftPM build-system note about the mlx-swift_Cmlx bundle, from the dependency)
    - next: review
  timestamp: 2026-10-22T16:34:32.251164+00:00
- actor: claude-code
  id: 01m5j7e9hmpwp69ybx5426hgbe
  text: |-
    ### commit — changed
    - evidence: single local commit feat(modelpool): MLXModelLoader takes a Hugging Face token provider (source, tests, and .kanban state together; sha reported in the step block)
    - next: review
  timestamp: 2026-10-22T16:34:52.596793+00:00
- actor: claude-code
  id: 01m5j7jzx8z1t1ey3xyv7s4mad
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (ab910d7) — 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed; 2 .kanban files excluded by .reviewignore
    - next: done; send sha ab910d7 to Router session foundationmodelsrouter-08
  timestamp: 2026-10-22T16:37:26.568370+00:00
- actor: claude-code
  id: 01m5j7kef8s1r6rj5vh0hce3zs
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files (MLXModelLoader.swift, MLXModelLoaderTests.swift)
    - test: green — swift test, 1542 passed, 0 failed, 0 skipped
    - commit: ab910d7
    - review: clean — none
  timestamp: 2026-10-22T16:37:41.480644+00:00
position_column: done
position_ordinal: ffbe80
title: MLXModelLoader takes a Hugging Face token provider
---
Copied from FoundationModelsRouter card 01M5J0J48N3D4539V5D57DTGHB (Router ^d7dtghb). Router session (foundationmodelsrouter-08) waits on it; send it the sha when landed.

## Goal
A host with its own home (the Mac app, a CLI with `--home`) gives the Hugging Face token to the model loader. Today `MLXModelLoader.hubClient()` builds `HubClient(cache:)`, whose default token provider is `.environment`: it reads `HF_TOKEN` and `~/.cache/huggingface/token`, whatever folder the host chose. Requested by ACPAgent (AgentHome, f7f9932).

## What
- `Sources/FoundationModelsExtras/ModelPool/MLXModelLoader.swift`: `public init(cacheDirectory: URL? = nil, tokenProvider: TokenProvider = .environment, tokenizerLoader: (any TokenizerLoader)? = nil)`. `TokenProvider` is swift-huggingface's type (`.fixed`, `.custom`, `.none`, ...). Store it; `hubClient()` passes it to the `HubClient` init that takes a token provider and the cache.
- Doc comment: the default `.environment` reads `HF_TOKEN` and `~/.cache/huggingface/token`; a host with its own home passes `.custom { ... }` reading its own token file, or `.none`.

## Subtasks
- [x] Failing test first: a loader made with `.fixed(token: "t")` gives a hub client whose token provider yields "t"; `.none` yields nil.
- [x] Add the parameter and pass it through `hubClient()`.

## Acceptance Criteria
- [x] The token a download uses comes from the given provider, not from `~/.cache/huggingface/token`, when the host gives one.
- [x] The default stays `.environment`.

## Tests
- [x] `swift test` in FoundationModelsExtras passes.

## Workflow
- Use `/tdd`.

#extras #hosting