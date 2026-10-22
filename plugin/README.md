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
  seals one answer a minute at `api.thinkr.tech/v1/demo/answer`.

- **Bonds, live and capped at $250:** a seller posts money behind its record; a buyer who
  pays through THINKR is paid from it if the seller seals nothing for the payment. The
  contract is unaudited, hence the cap.

## Where it runs

- Chain: Robinhood Chain (4663), collateral USDG
- Contract: [`0x41f3836260D04fa156D3ef2a4Ab7e5C1dEe0F95e`](https://robinhoodchain.blockscout.com/address/0x41f3836260D04fa156D3ef2a4Ab7e5C1dEe0F95e), source verified on [Sourcify](https://repo.sourcify.dev/4663/0x41f3836260D04fa156D3ef2a4Ab7e5C1dEe0F95e), no admin key
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
