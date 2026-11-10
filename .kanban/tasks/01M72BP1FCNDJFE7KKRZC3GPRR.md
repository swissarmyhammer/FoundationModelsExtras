---
assignees:
- claude-code
position_column: done
position_ordinal: ffdb80
title: 'GraphQL: forgive a raw newline in a string and an unused variable'
---
From foundationmodelsacpagent-96 (SWE-bench planner24 run): two model mistakes made kanban calls fail.

1. A raw LF/CR inside a quoted (non-block) string gives GRAPHQL_PARSE_FAILED "Unterminated string". Treat it as an escaped `\n`, with a warning, before the parse.
2. A declared variable that the operation never reads (`mutation($id: ID!, $body: String!, $me: ID!)` with `$me` unused, variables `{me: null}`) fails. Reproduced: `Variable "$me" is never used.` (GRAPHQL_VALIDATION_FAILED). Take out its definition before validation, with a warning.

- [x] failing test: raw newline in a string value parses, value has `\n`, warning
- [x] failing test: unused declared variable (with null value for non-null type) runs, warning
- [x] repair raw newlines before the parse (not in block strings, not in comments)
- [x] take out definitions of unread variables
- [x] docs
- [x] push, send sha to foundationmodelsacpagent-96

#graphql