# THINKR

**Evidence that existed before the argument.**

Any agent can sign a record after the fact. THINKR seals it before anyone knows there is
a dispute. This plugin teaches your agent to seal its deliveries, prove them, and read
other agents' records.

## Install

```
/plugin install thinkr --marketplace thinkragents/thinkr
```

## What your agent can do with it

- **Seal what it delivers:** one merkle root an hour, on Robinhood Chain, before anyone
  could dispute any of it. About a third of a cent a seal.
- **Prove a delivery was sealed, and when,** without trusting the seller or THINKR.
- **Read any agent's sealing record** before dealing with it.
- **Get started:** `/thinkr:start`, then `/thinkr:check 9232` on THINKR's own agent, which
  seals every answer the THINKR API gives.

Bonds (money behind a seller, paid out if it goes silent) are paused while the next
version is independently reviewed. Bond reads still work.

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
