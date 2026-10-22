# ThinkrBonds

Performance bonds for agents that take payment over x402.

A seller posts collateral against its ERC-8004 identity. A buyer reads the bond before
it pays. The payment itself never touches this contract: x402 settles directly, as it
is meant to. What sits here is the seller's own money, posted in advance, covering
everything it sells.

This is not escrow. Nobody holds the buyer's money, nothing is delayed, and there is
no arbiter.

## How a claim works

1. Every hour a seller commits one merkle root of what it delivered that hour.
2. The window to commit a root closes one hour after the epoch ends.
3. Only then can a claim be filed against that epoch. The root is already fixed, so a
   seller can never see a claim and write a root that answers it.
4. The seller has 48 hours to discharge the claim with a proof that the delivery is in
   the root it already committed.
5. No proof, no answer: the claimant is paid out of the bond.

Silence pays out. That is the point.

## Leaf format

```
keccak256(bytes.concat(keccak256(abi.encode(ref, digest))))
```

Double hashed, pairs sorted before hashing. Same convention as OpenZeppelin's
`MerkleProof` and `merkletreejs`, so the off-chain SDK and the contract cannot drift.

- `ref` is what both sides know the transaction by: an x402 payment, an
  [action_ref](https://datatracker.ietf.org/doc/draft-etcheverry-action-ref/), a
  Tersign receipt id.
- `digest` is the seller's evidence, in whatever format it already keeps and under
  whatever hash that format uses.

The contract reads neither. It only proves the pair was sealed before the claim
window opened. Evidence formats that sign records prove who wrote them; sealing
proves when, and nothing about the envelope has to change for it.

`sdk/tree.js` converts other shapes. `toRef` passes any 32 byte hex id through as
it is, so an action_ref stays recomputable by its issuer, and hashes anything else
(a UUID, say) with keccak256. `toDigest` passes a ready digest through, hashes bytes
and strings as they are, and hashes a JSON envelope as RFC 8785 canonical JSON.

The claimant knows only the `ref`. The seller holds the evidence and supplies its
digest with the proof, so the burden sits with the seller end to end.

## Parameters

| | value | why |
|---|---|---|
| `EPOCH_LENGTH` | 1 hour | small trees, tiny proofs, and a seller defends a root an hour old |
| `ATTEST_WINDOW` | 1 hour | the grace to commit a root after the epoch ends |
| `CHALLENGE_WINDOW` | 48 hours | time to answer a claim with a proof |
| `CLAIM_PERIOD` | 7 days | how long after an epoch a claim may be filed |
| `NOTICE_PERIOD` | 7 days | you cannot take payment on Monday and pull the guarantee on Tuesday |
| `CLAIM_BOND_BPS` | 200 (2%) | the claimant's stake, with a floor set at deployment |

`minBond` and `minClaimBond` are immutables set at deployment, so the contract is not
tied to one token's decimals. `minClaim` is not a parameter: it is 1% of each bond.

## Sizing, against real agent payments

The median x402 payment is half a cent and the average about 4 cents (`FINDINGS.md`).
Agents do not carry hundreds of dollars, so on Robinhood Chain the minimum bond is
**$1** and the claimant's minimum stake **$0.01**. A $1 bond accepts 1 cent claims.

The minimum is an entry ticket, not cover. As a signal its size barely matters: a seller
that is not legitimate will not lock even $1 against a record that pays out. As cover,
only the comparison with the payment matters, which is why the API answers `safeToPay`
for a named payment (`GET /v1/bond/{id}?amount=`): a $1 bond is fine for a 4 cent call
and correctly unsafe for a $50 job. Flooding stays bounded by the 1% floor, which caps a
seller at 100 open claims whatever its bond.

## What this contract cannot do

**It cannot verify that the x402 payment happened.** There is no on chain link from an
x402 settlement to a claim that holds across facilitators. What makes a false claim
unprofitable is the claimant's stake plus the seller's ability to kill the claim in a
single call. The alternative is routing payments through us, which is escrow, which
breaks the thing x402 exists for.

**A trade made in the last days of a notice period is thinly covered.** Notice is
visible on chain from the moment it is given, and a buyer that reads a bond sees an
agent that is winding down. Read before you pay.

## Build

```
forge build
forge test
forge test --match-path 'test/*.invariant.t.sol'
```

**Deployed on Robinhood Chain (4663): `0xD5e4643e7E20c987a3da124b05a54cae57de9DDA`**, block 94996670, source verified
(exact match) on [Sourcify](https://repo.sourcify.dev/4663/0xD5e4643e7E20c987a3da124b05a54cae57de9DDA). `script/Deploy.s.sol` is the script that deployed
it; `script/Testnet.s.sol` rehearses the same thing on testnet 46630.

## Repo

```
src/ThinkrBonds.sol              the contract
src/interfaces/                  the slice of ERC-8004 it depends on
sdk/tree.js                      the delivery tree, off chain
sdk/vectors.json                 written by Solidity, asserted in JavaScript
sdk/discharge-vector.json        written by JavaScript, replayed in Solidity
test/ThinkrBonds.t.sol           unit tests
test/Solvency.invariant.t.sol    the contract can always pay what it owes
test/SdkParity.t.sol             a JS-built proof discharges a real claim
```

The two vector files point in opposite directions on purpose. One proves the SDK
agrees with the contract's leaf format; the other proves a proof the SDK builds is
accepted on chain. A drift in either direction fails the suite.
