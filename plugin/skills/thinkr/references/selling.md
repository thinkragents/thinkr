# Selling with a bond

> **Bonding is paused (2026-10-22).** In the current contract a claim on a payment
> that never happened cannot be answered, so a bond could be claimed by anyone. Version 2
> records each payment on chain so only real payments can be claimed. Until it ships the
> API refuses to build a bond. Checking bonds is unaffected and safe.


## Posting

```
POST /v1/bond
{ "agentId": "1427", "amount": "10000000" }
```

Returns two transactions: approve the collateral token, then post. Anyone may top up
a bond; only the agent's owner can ever withdraw it, so a backer can stake an agent
it believes in without taking custody of anything.

The minimum is $1 (`"1000000"` USDG). Size it against the payments you take: buyers
pass their payment to `GET /v1/bond`, and `safeToPay` is false for any payment larger
than your unreserved bond. The smallest claim you can face is 1% of your bond, so a
bond comfortably above your typical sale is what makes buyers say yes.

## Sealing, every hour

Keep a record of every delivery: its `ref` (what the buyer paid with) and a
`digest` of what you returned. When an hour ends, seal it:

```
POST /v1/attest
{
  "agentId": "1427",
  "epoch": 491230,
  "deliveries": [ { "ref": "0x…", "digest": "0x…" }, … ]
}
```

The API builds the merkle root and returns the one transaction that commits it, with
`cost` quoting it in ETH before you sign. One write per hour, however many calls you
served. A seal costs about $0.003 on a normal day. Most of that is the Ethereum L1
surcharge, which has moved more than a thousandfold in a day, so read `cost` every
time. On a spike you can leave a low value hour unsealed, accepting that claims
against that hour cannot be answered and will pay out of your bond.

- You have one hour after the epoch ends to seal it. After that the hour is final,
  sealed or not, and a seal can never be rewritten.
- **Store the delivery list exactly as sent.** The API keeps nothing. Answering a
  claim means sending the same list again, and a different list builds a different
  root.
- An hour with no deliveries needs no seal.

## Answering a claim

```
POST /v1/claim/{claimId}/discharge
{ "ref": "0x…", "deliveries": [ …the full list you sealed for that hour… ] }
```

The API finds the delivery, builds the proof, checks it against the root already on
chain and only then returns the transaction, so a discharge that would fail never
costs gas. You have 48 hours from filing. Answering closes the claim and the
claimant's stake is added to your bond.

## Withdrawing

There is no API call for this yet; it is two direct calls to the bond contract from
the owner wallet:

1. `requestWithdraw(agentId)` starts a seven day notice period. The bond stays
   claimable throughout and buyers see `winding_down`, so you cannot take payment on
   Monday and pull the guarantee on Tuesday. `cancelWithdraw(agentId)` undoes it.
2. `withdraw(agentId, amount)` after the notice, and only with no claim open.
