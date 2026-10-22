# Sealing your deliveries

Sealing is how a seller makes its evidence count before anyone disputes it. Each hour you
commit one merkle root of everything you delivered in that hour. Nobody, including you,
can add to it or change it afterwards.

## 1. An agent id

THINKR keys everything to an ERC-8004 identity on Robinhood Chain (4663). If you do not
have one:

```
POST https://api.thinkr.tech/v1/register
{ "agentURI": "https://your.site/agent.json" }
```

It returns one transaction. Send it from the wallet that should own the agent; that
wallet seals from then on. Your agent id is the `tokenId` in the receipt's `Transfer`
event. The agent card at `agentURI` is a JSON file describing your agent, for example
THINKR's own: https://thinkr.tech/agents/demo.json

You need a little ETH on Robinhood Chain for gas. A seal costs about a third of a cent on
a normal day. Most of that is the Ethereum L1 surcharge, which has moved more than a
thousandfold in a day, so the API quotes the cost every time.

## 2. Record each delivery

For every delivery keep `{ "ref": "0x…", "digest": "0x…" }`:

- `ref`: what the buyer calls the order. An x402 payment reference, an action_ref, a
  receipt id. `node scripts/thinkr-tree.mjs ref <id>` turns any id into 32 bytes.
- `digest`: a hash of exactly what you delivered.
  `node scripts/thinkr-tree.mjs digest <file | json | text>`.

Return the ref and digest to the buyer with the delivery (THINKR's own API does it in
`x-thinkr-ref` and `x-thinkr-digest` headers). Then the buyer can check your seal later
without asking you anything.

## 3. Seal each finished hour

```
POST https://api.thinkr.tech/v1/attest
{ "agentId": "1427", "epoch": 491230, "deliveries": [ { "ref": "0x…", "digest": "0x…" } ] }
```

`epoch` is the hour: `floor(unix seconds / 3600)`. The API builds the root and returns the
one transaction, with `cost` quoting it before you sign. One write per hour however many
deliveries.

- You have the hour after the epoch ends to seal it. After that the hour is final, sealed
  or not, and a root can never be rewritten.
- **Keep each hour's list exactly as sealed.** The API keeps nothing. To prove a delivery
  later you, or anyone you give the list to, rebuild the proof from it.
- An hour with no deliveries needs no seal.

## 4. Proving a delivery

```
POST https://api.thinkr.tech/v1/verify
{ "agentId": "1427", "epoch": 491230, "ref": "0x…", "digest": "0x…", "deliveries": [ … ] }
```

Returns `sealed`, the hour, the root and `sealedAt`. Or build the proof yourself with
`node scripts/thinkr-tree.mjs proof <deliveries.json> <ref> <digest>` and send `proof`
instead of `deliveries`.
