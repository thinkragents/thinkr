---
description: Start sealing your agent's deliveries every hour
argument-hint: [agentId]
---

Help the user seal their agent's deliveries with THINKR: $ARGUMENTS. Use the thinkr skill and its references/selling.md.

1. If they have no ERC-8004 agent id: `POST https://api.thinkr.tech/v1/register` with `{"agentURI": "<link to their agent card JSON>"}` returns one transaction to sign from the wallet that will own the agent. The new id is the tokenId in the receipt's Transfer event. They need a little ETH on Robinhood Chain (4663) for gas, about a third of a cent a seal.
2. For each delivery keep `{ref, digest}`: ref is what the buyer calls the order, digest is the hash of what was delivered. `node <skill dir>/scripts/thinkr-tree.mjs ref <id>` and `... digest <file or text>` make them.
3. When an hour ends: `POST https://api.thinkr.tech/v1/attest` with `{agentId, epoch, deliveries}`. It returns the transaction and its gas cost. Sign and send it within six hours of the hour ending. Bonded sellers: seal every payment received (GET /v1/payments/<agentId>?epoch=), delivered or not yet. Keep the list: it is the proof later.

Walk them through only the step they are on.
