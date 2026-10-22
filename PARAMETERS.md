# Sizing, against real traffic

Written after checking what x402 payments actually look like rather than guessing.

## What the market is, measured

Not from press coverage. `research/scan-x402-sizes.py` reads EIP-3009
`AuthorizationUsed` events off Base and joins them to the USDC transfer in the same
transaction. That is the primitive x402's `exact` scheme settles with. 2,070 payments
over 1,000 blocks, about 33 minutes.

| size | txns | share | value | share of value |
|---|---:|---:|---:|---:|
| under 1c | 1,245 | 60.1% | $3.43 | 0.0% |
| 1c - 10c | 361 | 17.4% | $6.41 | 0.0% |
| 10c - $1 | 329 | 15.9% | $40.66 | 0.1% |
| $1 - $10 | 42 | 2.0% | $141.75 | 0.4% |
| $10 - $100 | 68 | 3.3% | $1,331 | 3.7% |
| $100 - $1k | 23 | 1.1% | $4,969 | 13.8% |
| over $1k | 2 | 0.1% | $29,406 | 81.9% |

**Median payment: half a cent.** The widely quoted 26 cent figure is a mean, pulled up
by a handful of very large transfers. p10 $0.001, p50 $0.005, p90 $0.10, p99 $112.

**6.5% of payments are $1 or more, and they carry 99.9% of the money.** Every payment
under a dollar, all 1,935 of them, adds up to $50.50.

### The tail is not ours

The table above is wrong by a factor of about 370, and the correction is in
`FINDINGS.md`. EIP-3009 is x402's settlement primitive but is not exclusive to it.
Once payments submitted by anything other than a real facilitator are removed, the
whole window is **$51.90**, not $19,267. About $2,500 a day across Base.

Seven genuine payments in that window were over a dollar. The largest was $10.79.

Read `FINDINGS.md` before trusting any sizing here. The numbers below were chosen for
a market that the measurement says does not exist yet.

## What that broke

The claimant's stake had a **$1 floor**. A buyer who lost the median payment would
have staked two hundred times the loss to claim it. Nobody files, and a mechanism
nobody uses guarantees nothing. Fixed.

## What it told us

Metered API calls are not the market for a guarantee, and pretending otherwise makes
the cheapest attack on this contract a flood of trivial claims locking up a seller's
collateral for pennies. So the floor is now explicit in the contract: `minClaim`.
Below it, take the loss and stop buying from that agent.

The market for a bond is the other end of agent commerce. One agent paying another
tens or hundreds of dollars for a job, a dataset, a run. Payments where the loss is
worth arguing about. The whole thing should be sized to that, not to the average.

## Values at deployment

All three are constructor immutables, so they are a deployment decision, not a code
change.

| | value | reasoning |
|---|---|---|
| `minClaim` | **$1** | 200x the median payment, and the exact line above which 99.9% of all value sits. Below it there is nothing worth insuring |
| `minClaimBond` | **$0.01** | small enough that a 1 cent claim is worth filing; the flood defence is the 1% claim floor, not this |
| `minBond` | **$1** | an entry ticket, not cover. A seller that is not legitimate will not risk even this; buyers check the bond against their own payment |

## Why $50 and not $500

$500 was a number from the diagram, not from anything. A bond is a standing reserve
covering everything an agent sells, not per-transaction cover, so what matters is
whether it covers the largest single loss a buyer could take, and on today's traffic
that is tens of dollars, not hundreds.

$50 is the floor to appear in the register at all. A seller doing larger work posts
more, and buyers read the number. Setting the floor high would only have kept small
sellers out of a register that is worth nothing while it is empty.

## Revised 2026-10-22: $1, and the check moved to the payment

$50 was still too much to ask of an agent wallet when the average payment is 4 cents.
The bond does two jobs. As a signal, the size barely matters: a seller that is not
legitimate will not lock even $1 against a record that pays out. As cover, only the
comparison with the payment matters, so `GET /v1/bond/{id}?amount=` now answers
`safeToPay` for that payment, and the minimum can be an entry ticket. `minClaim` is no
longer a constructor argument either: it is 1% of each bond, so a $1 bond accepts 1
cent claims.

## Robinhood Chain values, checked 2026-10-22

USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals, supply about 705m. The
ERC-8004 registry is live at `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`.
`script/Deploy.s.sol` simulates cleanly against mainnet: about 2.2m gas, 0.00009 ETH.
One hourly seal costs about $0.003 on a normal day.
