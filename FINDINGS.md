# What x402 actually looks like on chain

Measured 2026-10-13 against Base. Scanners in `research/`, re-runnable.

## Method

x402's `exact` scheme settles as an EIP-3009 `transferWithAuthorization` on USDC. The
buyer signs off chain, hands the signature over in an HTTP header, and a facilitator
submits it and pays the gas. So every x402 payment leaves an `AuthorizationUsed` log
on the USDC contract, joined to a `Transfer` in the same transaction.

That primitive is not exclusive to x402, which is the trap. Anyone can use a gasless
USDC transfer. Separating the two is the whole difficulty, and the naive scan is wrong
by a factor of about 370.

## Separating x402 from everything else on the same rail

Two independent tests, agreeing.

**1. Submitter overlap.** Only 5% of payments at $1 or more came from a submitter that
also handles sub-$1 traffic. A facilitator serves many sellers at many prices; these
two populations barely touch.

**2. Lifetime transaction count.** A facilitator is a service and its wallet shows it.

| submitters of sub-$1 payments | txs ever sent | | submitters of $1+ payments | txs ever sent |
|---|---:|---|---|---:|
| `0x7f72a02c` | 1,928,924 | | `0x4ceff75b` | 314 |
| `0x68efafe8` | 1,612,165 | | `0x9f0237b4` | 10,773 |
| `0x59b7ebc6` | 1,611,804 | | `0x734713ed` | 28,411 |
| `0xb87e1a2c` | 1,610,406 | | `0x3e32f474` | 33,385 |
| `0x8cda3672` | 1,610,013 | | `0x46616a05` | 43,300 |
| `0x93f66011` | 1,609,855 | | `0x3210d7b2` | 87,225 |

Five of the left column sit within 2,300 transactions of each other: a rotating pool
of sibling facilitator wallets. Coinbase's labelled "x402 Facilitator 1" and
"Facilitator 8" show the same pattern at 4.0m and 4.5m transactions, both now out of
gas, rotated out.

The right column is scattered. Not a service. One-off senders using the same rail.

## The result

One 33 minute window, 1,869 gasless USDC payments:

| | payments | value |
|---|---:|---:|
| everything the naive scan caught | 1,869 | $19,267.91 |
| sub-$1, via real facilitators | 1,734 | **$23.61** |
| $1+, via real facilitators | 7 | **$28.29** |
| $1+, via submitters that never do small traffic | 107 | $17,750.04 (not x402) |

**Plausibly x402: $51.90.** 0.27% of what the naive scan reported. About **$2,500 a
day** across all of Base.

The seven genuine payments over a dollar were: $1.00, $1.00, $1.00, $3.50, $5.00,
$6.00, $10.79.

## What it means

x402 is enormous in count and negligible in value. Roughly 83,000 payments a day on
Base, worth about $2,500 in total. Median payment half a cent.

**An insurance product does not survive this.** There are no losses worth covering.
Nobody posts $50 of collateral to protect transactions worth half a cent, and batching
claims does not help: two hundred batched half-cent calls is still one dollar. The
largest genuine agent-to-agent payment in the whole window was $10.79.

**The trust problem is still real.** 83,000 times a day an agent pays a counterparty
it knows nothing about, with no recourse. That is true at any ticket size. What it
supports is a register and a signal, where a bond's job is to be costly rather than to
be collected, the way a tradesman's bond is. It does not support pricing as a share of
value insured, because there is no value to insure.

That is a different product from the one in `PLAN.md`, and the difference should be
settled before any more is built.
