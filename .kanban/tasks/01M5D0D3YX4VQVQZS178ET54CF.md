---
assignees:
- claude-code
depends_on:
- 01M5D0CW33WWDS2S15F1EYX4KY
position_column: done
position_ordinal: ffb280
title: 'EXTRAS-6b: the forgiving name rewrite engine with alias tables as data'
---
Move the name rewrite engine of FoundationModelsKanban (`NameMatcher.swift`, `NameRewrite.swift`, `VariableReads.swift`, `JSONListText.swift`, the `AliasScope` of `FieldAliases.swift`) to Extras. All parts that are only for Kanban become data that a package gives in one `GraphQLNameRules` value:

- the alias tables: `everywhere`, `inEachInput`, `byType` and `byField`;
- the verb synonyms of a top-level mutation, and the verb synonyms for one noun (Kanban: `board` create → init);
- the query verbs (Kanban: `search` and `next` with the default noun `task`);
- the root container: the root query field that holds the fields that a root query moves into (Kanban: `board`), with the prefix of the added response key;
- the removed parameters: a name and the replacement text of its warning (Kanban: the old Rust parameters). The warning code is `REMOVED_PARAMETER`.

`GraphQLNameRules.standard` holds only the general verbs (create → add, get → the singular field, list → the plural field, and so on), no aliases, no root container and no removed parameters. The rewrite gives `extensions.rewrites` items `{from, to, path}`, the `AMBIGUOUS_NAME` tie errors, and the list of the canonical names for a name with no match.

## Acceptance criteria
- [ ] Port the general Kanban tests of `NameMatcherTests`, `NameRewriteTests`, `VariableRewriteTests` and `ListInStringTests` to a small test schema in Extras, with the rules as data.
- [ ] A test with a root container and a removed parameter in the rules proves the move and the warning.
- [ ] With `GraphQLNameRules.standard`, a document with only canonical names gives no rewrite. #graphql #feature