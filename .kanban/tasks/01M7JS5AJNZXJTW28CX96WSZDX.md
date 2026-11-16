---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Elicitation: the decline reason of a form answer that is not valid must not hold a value of the answer to a sensitive question'
---
## Why

`ToolContext.elicit` checks an accepted form answer with `ElicitationRequestedSchema.validationFailure(of:)`. When the check fails, the run gets a decline whose reason is `invalidAnswerReasonPrefix` followed by the failure text. The failure text of `ElicitationValidationIssue.Kind.itemNotAllowed(value:allowed:)` holds a value of the answer: `the field "x" has the value "...", which is not one of these values: ...`. A tool usually gives a decline reason to the model, thus the reason can go into the transcript. For a question with `ElicitationRequest.sensitive == true`, that value can be a part of the secret.

## What

- When the request is sensitive, the reason of the decline must not hold a value of the answer. For example, `failureText` gets a form with no value for a sensitive request, or `checked(_:to:)` gives a reason with the field name only.
- Look at each other kind of `ElicitationValidationIssue` and make sure that no other text holds a value of the answer.

## Acceptance

- [ ] A test, written before the code: a sensitive form request with a multi select, and an accepted answer with an item that is not allowed, gives a decline whose reason does not hold that item.
- [ ] A request that is not sensitive keeps the reason that it has now.
- [ ] `swift test` is green with no compiler warnings.

#elicitation