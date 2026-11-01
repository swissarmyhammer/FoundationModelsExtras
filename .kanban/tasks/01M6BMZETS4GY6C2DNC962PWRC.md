---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6byb09bfbks9begahccjnre
  text: |-
    ### implement — changed
    - Cause found: the stand-in tokenizer_config.json names no eos_token, so tokenizer.eosToken was nil. A text longer than 128 tokens was cut without its end token (id 1). The 6 other reference texts matched at once.
    - Fix: CoreMLTokenRow takes the pad token and the end token from the tokenizer (new init with tokenizer). The end token falls back to the vocabulary token "<eos>". CoreMLEmbedding uses this path.
    - Tests: unit test longRowKeepsTheVocabularyEndToken (red, then green). Integration test tokenIdsEqualPythonTokenizers with 7 reference texts (short, prefixes, 400 words, Japanese, French and German, spaces and newline) in Support/ReferenceTokenCases.swift; ids from Python tokenizers (venv in scratchpad, python -I).
    - Results: swift test: 131 and 40 and 44 tests pass. Integration CoreMLPooledEmbedderIntegrationTests: 10 tests pass.
    - next: /review
  timestamp: 2026-11-01T16:16:02.859559+00:00
position_column: doing
position_ordinal: '80'
title: Check that the Core ML tokenizer gives the same token ids as the Python tokenizers library
---
CoreMLEmbedding tokenizes with swift-transformers and a stand-in tokenizer_config.json (the PreTrainedTokenizer class), because erjigit17/embeddinggemma-300m-ane-coreml has no tokenizer_config.json. A text that is longer than the model length keeps its first tokens and its end token. Compare the ids for 5 or more sample texts (short, long, non-English, with the query and document prefixes) with the ids that the Python tokenizers library gives for the same tokenizer.json with padding to 128 and truncation to 128. Add a fixture-based unit test or an integration test with the expected ids. Fix any difference in the start token, the end token or the truncation.