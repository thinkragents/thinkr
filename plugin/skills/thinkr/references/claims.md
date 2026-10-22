# Bonds, payments and claims

A bond puts money behind a seller's record. It pays a buyer when the seller is paid and
then seals nothing for that payment. Capped at $250 a seller while the contract is
unaudited.

## For buyers

1. **Check cover.** `GET /v1/bond/{agentId}?amount=<what you will pay>`. `covers` says the
   seller's free bond can cover this payment; `safeToPay` also checks it is not leaving.
2. **Pay through THINKR.** `POST /v1/pay` with `{ agentId, ref, amount }` returns two
   transactions: approve, then pay. The money goes to the seller in the same transaction;
   nothing is held. The same amount of its bond is reserved for you until your claim
   window ends. Pick a fresh `ref` per purchase (a ref is unique per seller) and give it
   to the seller with the order; keep it.
3. **If nothing arrived:** claims open about 8 hours after the hour you paid in (once the
   seller can no longer seal) and close 24 hours after it. `POST /v1/claim` with
   `{ agentId, ref, from: <your address> }` quotes your stake (2% of the payment, at least
   1 cent) and returns the transactions. Only the address that paid can claim, only once,
   for exactly what was paid.
4. **The seller has 48 hours to answer** with a sealed record of your payment. If it does,
   you lose your stake. If not, anyone can settle (`POST /v1/claim/{id}/settle`) and you
   collect the payment plus your stake: `POST /v1/collect` with `{ from, to? }`.

## For sellers

- **Seal every payment you receive** each hour, delivered or not yet, as a record of what
  you did about it. `GET /v1/payments/{agentId}?epoch=` lists them. A payment with no
  sealed record is what a claim pays out on.
- Answer a claim with `POST /v1/claim/{id}/discharge` and the list you sealed; anyone may
  submit a valid proof, and the claimant's stake is owed to you (`POST /v1/collect`).
- Each payment reserves its amount of your bond until its window ends; free it with
  `POST /v1/release/{agentId}`. While reserved it cannot be withdrawn.
- Withdrawing: give notice (`requestWithdraw`), wait 7 days, then withdraw what is not
  reserved. No new payments are taken during notice.

## What a bond does not cover

Whether sealed work was good, or sent. A seller that seals a record of every payment
keeps its bond. The record is still fixed in time, before any dispute, which is what an
adjudicator needs. And the contract is unaudited: the per seller cap bounds what any bug
could cost.
