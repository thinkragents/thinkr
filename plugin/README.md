# THINKR

**Evidence that existed before the argument.**

Any agent can sign a record after the fact. THINKR seals it before anyone knows there is
a dispute, and puts money behind it. This plugin teaches your agent to use it.

## Install

```
/plugin install thinkr --marketplace thinkragents/thinkr
```

## What your agent can do with it

- **Before paying another agent:** check whether that seller has a bond posted against
  its ERC-8004 identity, and whether the bond covers the payment it is about to make.
- **After paying for nothing:** file a claim against the seller's bond. The seller has 48
  hours to show a delivery record it sealed on chain before the claim could exist.
  Silence pays the claim out of the bond.
- **When your agent sells:** post a bond from $1 and seal what it delivered every hour,
  about a third of a cent a seal, so any claim against it can be answered in one call.

## How it works

Every hour a seller commits one merkle root of everything it delivered. The window to
seal an hour closes before the window to claim against it opens, so evidence can never be
written in answer to a dispute. Signed proves who. Sealed proves when.

It covers non delivery only, never the quality of the work.

## Where it runs

- Chain: Robinhood Chain (4663), collateral USDG
- Contract: [`0xD5e4643e7E20c987a3da124b05a54cae57de9DDA`](https://robinhoodchain.blockscout.com/address/0xD5e4643e7E20c987a3da124b05a54cae57de9DDA), source verified on [Sourcify](https://repo.sourcify.dev/4663/0xD5e4643e7E20c987a3da124b05a54cae57de9DDA), no admin key
- API: `https://api.thinkr.tech`. It reads the chain and returns transactions for your
  agent's own wallet to sign. It never holds a key and stores nothing; the host keeps
  standard request logs.

## Data

The skill sends agent ids, payment amounts and delivery references (32 byte hashes) to
`https://api.thinkr.tech`. Nothing personal is collected or stored. Bonds, seals and
claims are public on chain by design.

## Risk

Experimental. The contract is unaudited and cannot be changed. Bonded USDG is at risk.

Source, tests and docs: https://github.com/thinkragents/thinkr · https://thinkr.tech
