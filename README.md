# THINKR

**Evidence that existed before the argument.**

Any agent can sign a record after the fact. THINKR seals it before anyone knows there
is a dispute. The accountability layer for agent commerce.

- **The seal (live).** Every hour a seller commits one root of everything it delivered.
  The window to seal an hour closes six hours after it ends, then the root can never be
  rewritten, so evidence provably cannot be written in answer to a dispute. Signed proves
  who. Sealed proves when. Anyone can verify a delivery was sealed, and when.
- **The bond (live, capped at $250).** Money posted behind a seller. A buyer who pays
  through THINKR has that amount of the bond reserved for its payment, and is paid from it
  if the seller seals nothing for the payment. The contract is unaudited, hence the cap.
  It replaces a first contract (`0xD5e4…9DDA`) that could be claimed against with an
  invented payment; the API never bonded into that one and no bond was posted to it.

**Live on Robinhood Chain:** [`0x41f3836260D04fa156D3ef2a4Ab7e5C1dEe0F95e`](https://robinhoodchain.blockscout.com/address/0x41f3836260D04fa156D3ef2a4Ab7e5C1dEe0F95e), source verified on [Sourcify](https://repo.sourcify.dev/4663/0x41f3836260D04fa156D3ef2a4Ab7e5C1dEe0F95e).
THINKR's own agent, **9232**, seals every answer `api.thinkr.tech` gives: each response
carries `x-thinkr-ref` and `x-thinkr-digest`, and `POST /v1/verify` proves it was sealed.

Evidence formats plug in unchanged. A delivery is a `ref` (an x402 payment, an
action_ref, a Tersign receipt id) and a `digest` of whatever evidence the seller
keeps. See `contracts/README.md`.

## Install the skill

In Claude Code:

```
/plugin install thinkr --marketplace thinkragents/thinkr
```

In any other agent that reads skills (Codex, Cursor, Cline, Amp and about 20 more):

```
npx skills add thinkragents/thinkr
```

Your agent then checks a seller's bond before it pays, seals what it delivers every
hour, and files or answers claims. The skill is in `plugin/skills/thinkr/`.

---

## How a claim works

1. Each hour a seller commits one merkle root of what it delivered.
2. It has one further hour to publish that root. After that the hour is sealed.
3. Only then can a claim be filed against it, so a seller can never see a claim and
   then write a root that answers it.
4. The seller has 48 hours to discharge the claim with a proof.
5. No proof, no answer: the claimant is paid out of the bond.

Silence pays out.

## The floor scales with the bond

A claim must be at least **1% of the bond**. A $10 bond accepts 10 cent claims, which is
the size agents actually pay today; a $5,000 bond requires $50 claims. Nothing has to
be redeployed when payments grow.

It is also the defence against flooding, and a better one than a fee: because every
open claim reserves at least a hundredth of the bond, and reservations can never exceed
it, **a seller can face at most 100 open claims at once.**

## What it cannot do

- **It cannot verify the payment happened.** No on chain link from an x402 settlement
  to a claim holds across facilitators. What makes a false claim unprofitable is the
  claimant's stake plus the seller's ability to kill it in one call. The alternative is
  routing payments through us, which is escrow, which breaks the thing x402 is for.
- **A trade made late in a notice period is thinly covered.** Notice is public from the
  moment it is given. Read the bond before you pay.
- **It does not judge quality.** This answers "did anything arrive", not "was it right".

---

## Repo

```
contracts/      ThinkrBonds.sol, tests, invariants
contracts/sdk/  the delivery tree, off chain
api/            reads the chain, builds calldata, holds no keys
mcp/            the same six operations as MCP tools
src/ index.html docs/ bonds/    the site
research/       the chain scanners behind FINDINGS.md (kept private)
plugin/         the Claude Code plugin and skill (also the Bankr skill)
.claude-plugin/ the marketplace entry, so the repo installs in one line
```

## Build and test

```sh
./setup.sh

cd contracts && forge test          # 45: unit, 2 invariants, SDK parity
cd contracts/sdk && npm test        # 14
bash api/test/anvil-up.sh           # local chain
# export the THINKR_* addresses it prints, plus THINKR_RPC=http://127.0.0.1:8545
# THINKR_CHAIN_ID=31337, or the API reads mainnet and every test fails
cd api && npm test                  # 8, end to end against a real EVM
cd mcp && npm test                  # 4, same environment
npm run dev                         # the site, :5190
```

Nothing in this repo is deployed.

## Design notes

- **No admin key.** Every parameter is fixed at deployment or derived from the bond.
- **No database.** The chain is the state; sellers keep their own delivery lists and
  resend them to answer a claim. There is nothing here to lose, leak or subpoena.
- **No keys in the API.** Write operations return unsigned calldata for the agent to
  sign. We can never move anyone's collateral.
- **Nothing scheduled.** The API scales to zero and costs nothing when idle, and runs
  on free public RPC.

## Reading

- [`FINDINGS.md`](FINDINGS.md): what x402 actually looks like on chain, measured.
  The published numbers are wrong by a factor of ~370 and this says why.
- [`PARAMETERS.md`](PARAMETERS.md): how the sizing was chosen, against that data.
- [`contracts/README.md`](contracts/README.md): the contract in detail.
