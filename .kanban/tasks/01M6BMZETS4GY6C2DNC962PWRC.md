---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Check that the Core ML tokenizer gives the same token ids as the Python tokenizers library
---
CoreMLEmbedding tokenizes with swift-transformers and a stand-in tokenizer_config.json (the PreTrainedTokenizer class), because erjigit17/embeddinggemma-300m-ane-coreml has no tokenizer_config.json. A text that is longer than the model length keeps its first tokens and its end token. Compare the ids for 5 or more sample texts (short, long, non-English, with the query and document prefixes) with the ids that the Python tokenizers library gives for the same tokenizer.json with padding to 128 and truncation to 128. Add a fixture-based unit test or an integration test with the expected ids. Fix any difference in the start token, the end token or the truncation.