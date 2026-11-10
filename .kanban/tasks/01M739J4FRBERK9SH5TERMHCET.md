---
assignees:
- claude-code
position_column: done
position_ordinal: ffdd80
title: 'GraphQL: an unknown field or argument error names the nearest real names'
---
From foundationmodelsacpagent-96 (planner24, django__django-14580 seq 27273), approved by the user:

  { board { task(id: "sxgwt0q") { id body columns: board_columns { name order } } } }

The unknown field gives no correction the model can act on. Expected: "Cannot query field "board_columns" on type "Task". Did you mean "column"? The fields of Task are: …". Pick the closest few by edit distance and token overlap (board_columns → column; status → column or progress). Same for an unknown argument. Never drop or guess the field silently.

Today: the error has the full list ("The fields of Note are: …") but no did-you-mean; graphql-swift's own suggestion does not fire for `note_states`.

- [x] check what the error says today (graphql-swift did-you-mean, our listing)
- [x] failing test: snake_case prefixed unknown field gets a did-you-mean
- [x] failing test: unknown argument gets a did-you-mean
- [x] nearest-name suggestion by token overlap and edit distance
- [x] review findings: magic number, shared edit distance, one NoMatchPlace init
- [x] push, send sha to foundationmodelsacpagent-96

#graphql