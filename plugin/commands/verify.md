---
description: Prove a delivery was sealed, and when
argument-hint: <agentId> <epoch> <ref> <digest>  (or paste x-thinkr-* headers)
---

Verify a sealed delivery with THINKR: $ARGUMENTS. Use the thinkr skill.

Send `POST https://api.thinkr.tech/v1/verify` with `agentId`, `epoch`, `ref`, `digest`, and either `proof` or `deliveries` (the full list that was sealed for that hour).

- For THINKR's demo agent 9232 (answers from `GET https://api.thinkr.tech/v1/demo/answer`): the `x-thinkr-agent`, `x-thinkr-epoch`, `x-thinkr-ref` and `x-thinkr-digest` headers are all you need. Get the hour's list from `GET https://api.thinkr.tech/v1/demo/deliveries/<epoch>`. The hour is sealed a minute or two after it ends; until then the list says `sealed: false`.
- To check the digest is the answer you hold: `node <skill dir>/scripts/thinkr-tree.mjs digest '<the exact body>'`, or for a file, the file path.

Report: sealed or not, the hour, and when it was sealed. If not sealed yet because the hour has not ended or was just finishing, say when to try again.
