---
position_column: todo
position_ordinal: '80'
title: FrontmatterDocument save writes a whole-number Double as 6e+0
---
Reported by agentviewkit-05 while adopting Router index.md (AgentViewKit ^b36r42y). Router's SessionConfiguration.inlineSettleGrace (a TimeInterval, value 6) is saved in the index.md frontmatter through FrontmatterDocument.save(to:) / rendered() as `6e+0`. It decodes back correctly, but index.md is meant to be read by people, so a Double should render as plain decimal text (`6`, or `6.0`, and `0.25` rather than `2.5e-1`).

- [ ] Failing test: rendering Encodable metadata holding a Double 6 and 0.25 gives `6`/`6.0` and `0.25`, with no exponent
- [ ] The rendered value still decodes back to the same Double
- [ ] Fix the Double/Float encoding in the frontmatter writer