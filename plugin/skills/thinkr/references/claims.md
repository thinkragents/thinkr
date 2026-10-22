# Claims

A claim says one thing: a transaction settled and the seller holds no sealed record
of delivering it.

## Timing

Deliveries are sealed by the hour. Epoch `n` covers the hour starting at
`n * 3600` seconds. A claim against an hour can be filed from two hours after that
hour starts (once its seal is final) until seven days after it ends.

```
epoch = floor(paymentUnixSeconds / 3600)
```

`GET /v1/bond/{agentId}` returns the current `epoch`. A claim filed too early is
refused, and the API says so before anything is signed.

## Filing

```
POST /v1/claim
{
  "agentId": "1427",
  "ref":     "0x…",      // 32 bytes: the x402 payment reference, action_ref or receipt id
  "epoch":   491230,
  "amount":  "2500000"   // whole token units, at least the seller's minClaim
}
```

The response quotes your stake before anything is signed, then gives two
transactions to send in order: approve the stake, then file.

```json
{
  "stake": "1000000",
  "stakeNote": "You lose this if the seller proves it delivered. …",
  "transactions": [ { "to": "0x…", "data": "0x…", "note": "approve your stake" },
                    { "to": "0x…", "data": "0x…", "note": "file the claim" } ]
}
```

One claim per ref per seller. The claim reserves its amount out of the bond, so the
seller cannot withdraw while it is open.

## What happens next

- **The seller answers** within 48 hours with a proof that the ref was in the root
  it sealed for that hour. The claim closes and your stake goes to the seller.
- **The seller stays silent.** After 48 hours anyone can settle:

```
POST /v1/claim/{claimId}/settle
```

You receive the claim amount from the bond plus your stake back.

`GET /v1/claim/{claimId}` shows where a claim stands.

## In practice

Claims are cheap to file and cheap to answer. An honest seller answers in one call
from records it already sealed. A seller that cannot produce one did not deliver,
and no judgement is needed to establish that.
