---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: StenciledDotfolderStack takes structured template values (bool, dictionary)
---
A skill must render conditionally on the session's tool config: `{% if tools.kanban.enabled %}…{% endif %}`. StenciledDotfolderStack takes `variables: [String: String]` only, and the string "false" is truthy in Stencil, with no nested keys.

- [ ] New init parameter `values: [String: TemplateValue]`, merged at the rung of `variables` (above the well-known values); `values` wins over `variables` on the same key; `variables` stays source-compatible
- [ ] Included text (a partial, and the IncludeResolver text) renders with the same context
- [ ] Tests: `{% if tools.kanban.enabled %}K{% endif %}` gives "K" for true, "" for false and for no key, in the main text and in an include

Requested by foundationmodelsacpagent-96; foundationmodelsskills-d7 passes it through StencilPass/SkillsRegistry.