---
comments:
- actor: claude-code
  id: 01m2zkjf3j2a2x7wym4y0s3tnh
  text: |-
    ### finish — note on the push criterion
    - The finish loop commits a local checkpoint on each iteration and never pushes. The push to `main` is the step of the user after the loop.
    - next: the user pushes `main` after this card is in `done`.
  timestamp: 2026-09-20T14:29:54.418622+00:00
- actor: claude-code
  id: 01m2zksy5972rbctzs5kxn09jn
  text: |-
    ### research

    The read of the code before the work starts.

    - `QuarantinedText.swift` of Skills holds `QuarantinedText` (public) and `SpanBuilder` (internal). Skills uses `SpanBuilder` in `ArgumentSubstitution` and in `ShellInjection`, thus the moved copy makes `SpanBuilder` public as well; a consumer that runs its own passes cannot build spans without it.
    - The bridge of Skills is `StencilPass.template(for:injectingQuarantinedSpansInto:)`, with the two helpers `endsInsideOpenDelimiter(_:)` and `movingTrailingBraces(from:ontoFrontOf:)` and the list `delimiterPairs`. All of it is Stencil work, thus all of it moves.
    - `StenciledDotfolderStack` already holds `trust(of:)`, `partialsStack(for:)` and the context built from `variables`, thus the new entry point adds no rule of its own. The private `rendered(_:)` can call the new public `render(_:in:)`, so a file and consumer text take exactly the same path.
    - `WellKnownValues` is internal in `TemplateEngine.swift` and `current(partials:)` reads `DotfolderStack.projectDotfolderName`, a `fileprivate` value in the same file. A public `current(partials:)` reads it without a change of that value.
    - `TemplateContext.set(key:to:)` is public, thus the bridge can set each quarantine key last.
    - The tests of the package build a tree with `DotfolderStackTests.Fixture`, which holds `write(_:to:in:)`, `makeStack()` and `link(_:in:to:)`. `DiagnosticLog` records the diagnostics.
    - Stencil renders `{% now "yyyy" %}` as the year with four digits (`NowTag.swift`), thus one tag body drives the trusted half and the untrusted half of the trust test.
  timestamp: 2026-09-20T14:33:59.209043+00:00
- actor: claude-code
  id: 01m2zmcy4vr4cnnhqphhbcy73z
  text: |-
    ### decisions

    Each decision of the work, with its cause.

    1. **`SpanBuilder` is public.** `QuarantinedText` gives no other way to build the spans of a pass, and a consumer that runs passes of its own must build them. The copy in Skills was internal because the passes stood beside it in the same module; after the move they do not.
    2. **`Span.text` stays internal.** No file of Skills outside `QuarantinedText.swift` reads it, thus a public accessor would widen the surface for no caller. A consumer reads the cases of the public enum.
    3. **`quarantinedSpanContextKeyPrefix` is internal, not public.** The card says "a context key of this package's choice", thus the name is an implementation detail. The tests of the package reach it through `@testable import`. The value is `foundationModelsExtrasQuarantinedSpan`, the name of this package and not of a pass of a consumer.
    4. **`rendered(_:)` calls the new public `render(_:in:)`.** A file and the text of a consumer then take exactly one path: the same trust rule, the same scope rule, the same well-known values. The alternative, one engine build in each of the two methods, was a copy of five lines that could drift.
    5. **`wellKnownValues:` stands between `variables:` and `onDiagnostic:` in the initializer.** Each argument carries its label, thus a caller that names `base:`, `partialLocations:`, `variables:` and `onDiagnostic:` still compiles. `nil` keeps the behavior of today.
    6. **`WellKnownValues` stays in `TemplateEngine.swift`.** It is the lowest rung of the ladder of that engine, and `current(partials:)` reads the `fileprivate` `projectDotfolderName` of the same file. To move it would need that value to widen for no gain.
    7. **The trust test uses `{% now "yyyy" %}`.** The card asks for a tag that the untrusted whitelist refuses. Stencil renders that tag as the year with four digits (`NowTag.swift`), thus one body drives the trusted half (a match of `/\d{4}/`, which no clock breaks) and the untrusted half (the refusal names `now`).
    8. **Two tests cover the one-budget rule.** `manyQuarantinedSpansOfAnUntrustedTextRenderAsOneTemplate` renders 1,000 quarantined spans under one output budget, as the card names. `everySpanOfAnUntrustedTextDrawsOnOneOutputBudget` gives 50 spans a loop of 24 KiB each: one span alone renders (a third test pins that), and the 50 together cross the output limit. Together they show that the limits are of the render and not of the span.
    9. **The parameterized tests take a layer, not a source.** A test that took a source would need a table from a source to a root. The layer carries both, and the root of a layer for a quarantined span is never read, thus one constant root serves.
    10. **`plan.md` carries the date on the new bullet and in its header.** The card asks for the date 2026-09-20 on the rule; the header field `Updated` names the date of the last change of the document, thus it moves with it.
  timestamp: 2026-09-20T14:44:21.787606+00:00
- actor: claude-code
  id: 01m2zmd34p20vecp26sb7ad39r
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsExtras/QuarantinedText.swift (new), StenciledDotfolderStack.swift, TemplateEngine.swift; Tests/FoundationModelsExtrasTests/QuarantinedTextTests.swift (new), StenciledDotfolderStackRenderTests.swift (new); README.md, plan.md, CHANGELOG.md. The tests were written first and each one failed to compile before the code landed. `swift build --build-tests` gives 0 errors and 0 warnings; `swift test` gives 125, 34, 44, 26, 332 and 414 tests, all passed, 0 failures. `swift format lint` of the changed Swift files reports only `AmbiguousTrailingClosureOverload` on the two `mappingOriginalSpans` overloads, which the contract of the card holds. No file of FoundationModelsSkills changed.
    - next: `/review`. The card stays in `doing`. The commit and the push are not steps of this card.
  timestamp: 2026-09-20T14:44:26.902030+00:00
- actor: claude-code
  id: 01m2zmj2wqxmyh3a52ban0nfr7
  text: |-
    ### test — green
    - evidence: swift build --build-tests (0 warnings, 0 errors); swift test — 414 tests in 32 suites passed, 0 failed, 0 skipped
    - next: ready for review
  timestamp: 2026-09-20T14:47:10.487043+00:00
position_column: doing
position_ordinal: '80'
title: 'Render text that a consumer holds: quarantined spans, under the trust and the partial scope of a layer'
---
## What

`StenciledDotfolderStack` renders only a file that it reads itself. Its trust rule (`trust(of:)`), its partial scope rule (`partialsStack(for:)`), its context and its well-known values are all private. A consumer that holds text of its own has no supported way to render it with the trust and the partial scope of a layer.

`FoundationModelsSkills` is such a consumer. A `SKILL.md` body goes through two passes of the skill format first (`$ARGUMENTS` / `$1` / `$name` substitution, then `` !`command` `` shell injection), and only then through Stencil. The text that those passes splice in is data: Stencil must never scan it as template syntax. Because this package gives no entry point, Skills rebuilt the generic half itself, in `../FoundationModelsSkills/Sources/FoundationModelsSkills/Render/StencilPass.swift` (a mirror of the internal `WellKnownValues`, a copy of the precedence ladder, a copy of `partialsStack(for:)`, a copy of the trust mapping, and the bridge from quarantined spans to one Stencil template) and in `Render/QuarantinedText.swift`. None of that names a skill. It is Stencil work, thus it belongs here. The two grammar passes stay in Skills: they are the schema of the skill format.

1. **Move `QuarantinedText`** from `../FoundationModelsSkills/Sources/FoundationModelsSkills/Render/QuarantinedText.swift` into `Sources/FoundationModelsExtras/QuarantinedText.swift`, as a public type, with 2-space indentation. Keep its contract: `Span` is `.original(String)` (eligible for the next scan) or `.quarantined(String)` (copied verbatim, never scanned again); `init(spans:)` drops empty spans and joins adjacent `.original` runs; `mappingOriginalSpans(_:)` (sync) and `mappingOriginalSpans(awaiting:)` (async) are the only seam a pass uses; each `.original` span gets the last character of the flattened text before it; `SpanBuilder` buffers literal runs; `flattened` gives the text. No comment in it names a skill.
2. **Add the render entry point** to `StenciledDotfolderStack`:
   `public func render(_ text: QuarantinedText, in layer: DotfolderStack.Layer) throws -> String`
   and the convenience `public func render(_ text: String, in layer: DotfolderStack.Layer) throws -> String` (all of the text is `.original`). The trust comes from the layer (`.defaults` is trusted, each other source is untrusted). The partial scope comes from `partialsStack(for:)`. The variables and the well-known values are those of the stack, the same as for a file. It throws `TemplateEngineError`; it does not give `nil` with a diagnostic, because the caller owns the text and needs the message for its own error.
3. **Move the bridge** from `StencilPass.template(for:injectingQuarantinedSpansInto:)` of Skills: the whole text becomes **one** template; each `.quarantined` span becomes a reference to a context key of this package's choice, and its text is set in the context last, so no variable can shadow it; a splice that lands inside an open `{{`, `{%` or `{#` throws `TemplateEngineError.renderingFailed`; a bare `{` directly before a splice moves onto the front of the spliced value, so `{$1}` gives `{value}`. One template means one render call, thus one set of the untrusted budgets. A render of N spans as N templates would give an untrusted text N times each limit.
4. **A public seam for the well-known values.** The stack reads `WellKnownValues.current(partials:)` at each render, and that type is internal. A consumer test cannot fix `hostname`, `date` and `working_directory`, thus it cannot assert the order of the rungs. Make `WellKnownValues` a public value type (`workingDirectory`, `date`, `hostname`, `dotfolderName`, a public init, and the public `current(partials:)`), and give `StenciledDotfolderStack.init` a parameter `wellKnownValues: WellKnownValues? = nil`. `nil` means: read the current values at each render, as today. `FoundationModelsSkills` injects such values in about fifteen places of its `StencilPassTests` today; those tests use this seam after the move.
5. **The environment stays out.** The stack passes `environment: [:]` to the engine today. Keep that. State in the doc comment that a consumer puts each environment value that it wants into `variables`.
6. **Tests.** Move the generic cases of `../FoundationModelsSkills/Tests/FoundationModelsSkillsTests/StencilPassTests.swift` (trust by layer, partial scope with a marketplace layer, the quarantine bridge, the open-delimiter refusal, the trailing brace, the one-budget rule) and of `RenderPipelineNoRescanTests.swift` (a quarantined span that holds `{{ x }}` or `{% include %}` comes out verbatim) into `Tests/FoundationModelsExtrasTests/`. Add tests of `QuarantinedText` itself.
7. `README.md`: extend the templating text with a short example of `render(_:in:)`. `plan.md` §4: add the rule "a consumer runs the passes of its own format first, marks what it spliced in as quarantined, and gives the text to the stack; the stack owns Stencil, the trust and the partial scope", with the date 2026-09-20. `CHANGELOG.md`: one entry under `## Unreleased`.
8. Commit and push to `main`.

Do not edit `FoundationModelsSkills` in this card. A card on that board deletes its copies after this lands.

## Acceptance Criteria

- [ ] `QuarantinedText` is public in the core target, and no file of it names a skill.
- [ ] `render(_:in:)` renders consumer text with the trust and the partial scope of the given layer, and with the variables of the stack.
- [ ] A quarantined span that holds template syntax comes out byte for byte, for a trusted layer and for an untrusted layer.
- [ ] An untrusted text with many quarantined spans gets one set of limits, not one set for each span.
- [ ] A splice inside an open delimiter throws `TemplateEngineError.renderingFailed`.
- [ ] `WellKnownValues` is public, and a stack with injected values renders them for a file and for consumer text.
- [ ] The core target still depends on Foundation, Stencil and Yams only.
- [ ] `swift build --build-tests` gives 0 warnings, and `swift test` is green.
- [ ] The work is committed and pushed to `main` of this repository.

## Tests

- [ ] `Tests/FoundationModelsExtrasTests/QuarantinedTextTests.swift` (new): normalization, the two mapping seams, the preceding character, the builder, `flattened`.
- [ ] `Tests/FoundationModelsExtrasTests/StenciledDotfolderStackRenderTests.swift` (new): text for a `.defaults` layer can use a tag that the untrusted whitelist refuses, and the same text for a `.project` layer throws.
- [ ] Same file: `{% include "header" %}` in consumer text for a `.marketplace` layer resolves from that marketplace and the local layers, and never from a different marketplace layer.
- [ ] Same file: a quarantined `{{ secret }}` and a quarantined `{% include "x" %}` come out verbatim.
- [ ] Same file: injected well-known values are below a value of `variables` with the same name, and they show when no variable has that name.
- [ ] Same file: 1,000 quarantined spans in an untrusted text render under one output budget.
- [ ] Same file: a splice inside `{{ ` throws, and `{` before a splice gives `{value}`.
- [ ] `swift test` — all tests pass, 0 failures.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Record each decision in a comment on this card. Do not ask the user about an implementation detail.

#loading-boundary #cross-repo