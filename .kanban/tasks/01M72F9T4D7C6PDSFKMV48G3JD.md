---
assignees:
- claude-code
position_column: done
position_ordinal: ffdc80
title: 'GraphQL: forgive a String variable at an ID position, and an ID variable at a String position'
---
From foundationmodelsacpagent-96 (planner24, django__django-14411 seq 21873–21882):

  mutation($col: String!) { moveTask(input: { id: "585j6dd", column: $col }) { column { name } } }
  variables: { col: "Done" }

fails with GRAPHQL_VALIDATION_FAILED `Variable "$col" of type "String!" used in position expecting type "ID".` The literal works.

Expected: the declared named type String reads as ID when the variable's reads are all at ID positions (and ID as String at String positions), list forms too, with a VARIABLE_TYPE_COERCED warning.

- [x] failing test: String! variable at an ID input field runs, warning
- [x] failing test: list form [String!] at [ID!]
- [x] failing test: ID variable at a String position
- [x] rewrite the declared named type in the variable definition
- [x] review findings: removed-parameter reads, two operations with one variable name
- [x] push, send sha to foundationmodelsacpagent-96

#graphql