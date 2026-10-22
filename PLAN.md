# THINKR: build plan

The guarantee layer for agent-to-agent payments. A seller posts a performance bond
against its ERC-8004 identity. A buyer reads it before paying over x402. If the
seller takes payment and delivers nothing, the buyer claims against the bond.

Not escrow: the buyer's payment is never held, delayed or routed. The bond is the
seller's own money, posted once, covering everything it sells.

Chain: **Robinhood Chain, 4663** (decided 2026-10-22). Collateral: USDG. Deploy script: `contracts/script/Deploy.s.sol`.

> Deploy target changed from Robinhood Chain after a count that said three agents had
> ever registered there. **That count was wrong**: it ran over the public RPC, which
> keeps no history. 8004scan.io/networks on 2026-10-22: Robinhood 9,104 agents and
> 1,392 feedbacks, Base 472,934 and 592,454. Robinhood chosen on 2026-10-22, alongside
> the token launch there.

---

## 1. Contract

One contract, `ThinkrBonds.sol`. Bonds, attestations and claims are tightly coupled
because claims pay out of bonds, so splitting them adds surface without benefit.

### State

| | |
|---|---|
| `registry` | ERC-8004 identity registry. Ownership is `ownerOf(agentId)` |
| `currency` | USDG |
| `bonds[agentId]` | `{ amount, reserved, bondedAt, withdrawAfter }` |
| `roots[agentId][epoch]` | the delivery root for that epoch |
| `claims[id]` | `{ agentId, claimant, amount, ref, epoch, filedAt, state }` |

`reserved` is the sum of open claims against that bond. Available collateral is
`amount - reserved`. Without it, ten claims of 100 could be filed against a bond of
500 and all of them would expect to pay.

### Functions

| | who | what |
|---|---|---|
| `bond(agentId, amount)` | anyone | adds collateral. Anyone may top up, only the owner withdraws, so a backer can sponsor an agent |
| `requestWithdraw(agentId)` | owner | starts the notice period |
| `withdraw(agentId)` | owner | after notice, only if `reserved == 0` |
| `attest(agentId, epoch, root)` | owner | publishes one delivery root for the epoch |
| `fileClaim(agentId, ref, epoch, amount)` | anyone | reserves `amount`, takes a claim bond from the claimant |
| `discharge(claimId, ref, digest, proof)` | owner | merkle proof that the payment is in that epoch's root. Closes the claim, returns the claim bond to the seller |
| `settle(claimId)` | anyone | after the window with no discharge, pays the claimant from the bond and returns their claim bond |

### Leaf format

`keccak256(abi.encode(ref, digest))`

`ref` is any 32 byte id both sides know the transaction by (x402 payment, action_ref,
receipt id). `digest` is the seller's evidence in any format. See `contracts/README.md`.

The claimant knows only `ref`, so the seller supplies `digest` and the
proof when discharging. That is deliberate: the seller holds the evidence and the
burden sits with the seller throughout.

### Parameters

| | proposed | why |
|---|---|---|
| `CHALLENGE_WINDOW` | 48h | long enough for a seller on a daily attestation cadence to respond |
| `NOTICE_PERIOD` | 7d | you cannot take payment on Monday and pull the guarantee on Tuesday |
| `CLAIM_BOND` | 2% of claim, min 0.01 USDG | makes speculative claims against honest sellers unprofitable |
| `MIN_BOND` | 1 USDG | an entry ticket; buyers check the bond against their payment (`?amount=`) |

### Security

- `ReentrancyGuard` on every function that moves tokens
- checks, effects, interactions, in that order
- claims cannot exceed available collateral
- withdrawal blocked while any claim is open
- epochs are append only, a root cannot be rewritten once published

### The honest limitation, to be stated publicly

**The contract cannot verify that the x402 payment happened.** There is no on chain
link from an x402 settlement to a claim that holds across facilitators. What makes
a false claim unprofitable is the claim bond plus the seller's ability to discharge
in one call. This is a deliberate trade: the alternative is routing payments through
us, which is escrow, which breaks the thing x402 is for.

---

## 2. API

Thin. Reads the chain, serves JSON, paid per call over x402. No database: the chain
is the state and the attestation roots are published by sellers.

```
GET  /v1/bond/{agentId}              the reading a buyer does before paying
GET  /v1/claims/{agentId}            history
POST /v1/claim                       file
POST /v1/claim/{id}/discharge        seller rebuts with a proof
POST /v1/bond                        post or top up
POST /v1/attest                      publish an epoch root
```

Serverless functions. Nothing watches anything, nothing is scheduled, so it scales
to zero and costs nothing when idle.

---

## 3. MCP server

The same surface exposed as tools, because MCP is how agent builders wire things in.
One config line and any MCP agent can check a bond. Same handlers as the API.

---

## 4. Bankr skill

Built, in `plugin/skills/thinkr/`. PR to `BankrBot/skills` **after** the endpoint is live,
because the first thing a reviewer does is run the demo in `catalog.json`.

---

## 5. Discovery

| | effort | reach |
|---|---|---|
| Bankr Skills catalog | done, pending live API | their agents already pay x402 on this chain |
| MCP server | ~1h on top of the API | widest, because builders wire tools by config |
| ERC-8004 registry entry | minutes, under $1 | agents discover it on chain, no directory |
| x402 resource index, AgentIndex, x402 Bazaar, Agent.market | a day of forms | low effort, non zero |

---

## 6. Site

Homepage done. Outstanding: `/docs` (the spec, and the place the scope boundary is
stated precisely), `/bonds` (the register, mostly the DGNS floor page with different
columns), deploy.

---

## 7. Order

1. Contract plus tests
2. Public repo, from the first commit
3. Deploy to Robinhood testnet
4. API and MCP against the testnet
5. `/docs` and `/bonds`
6. Bankr PR
7. Mainnet

---

## Decisions, made

| | decided | why |
|---|---|---|
| **Collateral** | USDG only | a bond in the agent's own token is worth least exactly when a claim lands. That is not a guarantee. Revisit at a haircut later, not in v1 |
| **Claim bond** | 2% of claim, min 0.01 USDG | flat does not scale, 1 USDG is nothing against a 10,000 claim. Percentage alone punishes small claims. Both |
| **Who can top up** | anyone, owner alone withdraws | free to build, and it is what lets a backer stake an agent. That is the integration worth having |
| **Epoch** | one hour | an attest costs pennies on this chain. Hourly keeps the tree small, the proofs tiny, and a seller defends against a root an hour old rather than a day old |

## The thing that is not engineering

A register with nothing in it is worth nothing. Priors' backers stake real money on
agents today with nothing to price the risk with, and they are already on this chain.
That conversation matters more than the Solidity and should start before it is
finished.
