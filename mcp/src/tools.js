// The same six operations the API serves, described as MCP tools.
//
// The descriptions matter more than the code here. An agent picks a tool by reading
// one line, so each one says what it is *for* and when to reach for it, not what it
// returns. `check_bond` in particular has to read as the thing you do before you pay
// a stranger, because that is the only moment it is useful.

import { z } from 'zod';
import * as h from '../../api/src/handlers.js';

const agentId = z.union([z.number().int().nonnegative(), z.string()]).describe('ERC-8004 agent id');
const hash32 = z.string().regex(/^0x[0-9a-fA-F]{64}$/, 'a 32-byte hex string');
const units = z
  .string()
  .describe('amount in the collateral token\'s smallest unit, as a string (500 USDG with 6 decimals is "500000000")');

const delivery = z.object({
  ref: hash32.describe('what both sides call the transaction: x402 payment, action_ref or receipt id, as 32 bytes'),
  digest: hash32.describe('32-byte digest of your evidence for it, in any format'),
});

export const tools = [
  {
    name: 'check_seals',
    title: "Read an agent's sealing record",
    description:
      'Before dealing with an unfamiliar agent: how many hours it has sealed, in the last 24 hours and ' +
      '7 days, and when it last sealed. An agent that seals every hour it works is committing its ' +
      'evidence in advance; one that never seals has nothing to show later.',
    schema: { agentId },
    run: ({ agentId: id }) => h.getSeals(id),
    readOnly: true,
  },
  {
    name: 'verify_seal',
    title: 'Prove a delivery was sealed, and when',
    description:
      'Use when you need to show a delivery existed, unchanged, before a dispute. Send the agent, the ' +
      'hour (epoch), the ref and digest, and either the proof or the full list sealed for that hour. ' +
      'Returns sealed true or false, the root and when it was sealed. Does not trust the seller or THINKR.',
    schema: {
      agentId,
      epoch: z.number().int().nonnegative(),
      ref: hash32,
      digest: hash32,
      proof: z.array(hash32).optional(),
      deliveries: z.array(delivery).optional(),
    },
    run: (args) => h.verifySeal(args),
    readOnly: true,
  },
  {
    name: 'register_agent',
    title: 'Get an ERC-8004 agent id on Robinhood Chain',
    description:
      'For a seller with no agent id yet. Builds the one registry transaction; the wallet that sends ' +
      'it owns the agent and the id is the tokenId in the receipt Transfer event.',
    schema: { agentURI: z.string().describe('link to your agent card JSON') },
    run: (args) => h.buildRegister(args),
  },
  {
    name: 'check_bond',
    title: 'Check an agent\'s bond before paying it',
    description:
      'Do this before paying an agent you have not dealt with. Returns what that agent has staked ' +
      'against non-delivery, how much of it is already spoken for, and a single safeToPay flag. ' +
      'An x402 payment cannot be reversed, so this read is the only recourse you get. Pass the ' +
      'amount you are about to pay and safeToPay also checks the bond covers that payment.',
    schema: { agentId, amount: units.optional().describe('the payment you are about to make, in token units') },
    run: ({ agentId: id, amount }) => h.getBond(id, amount),
    readOnly: true,
  },
  {
    name: 'check_claims',
    title: 'Read an agent\'s claim record',
    description:
      'The history behind the bond: how many claims have been filed against this agent, how many it ' +
      'answered with a proof, and how many it let run and paid. A seller that has never been claimed ' +
      'against and one that has paid out four times both have a bond; they are not the same seller.',
    schema: { agentId },
    run: ({ agentId: id }) => h.getClaims(id),
    readOnly: true,
  },
  {
    name: 'pay_agent',
    title: 'Pay an agent through THINKR so the payment is on record',
    description:
      'Builds the transactions to pay a seller agent through THINKR. The money goes straight to the ' +
      'seller in the same transaction; nothing is held. The same amount of its bond is reserved for ' +
      'you until your claim window ends, so nobody else can take your cover. Refused when the free ' +
      'bond cannot cover the payment or the seller is leaving. Keep the ref: a claim names it.',
    schema: {
      agentId,
      ref: hash32.describe('what both sides call this purchase, as 32 bytes'),
      amount: units,
    },
    run: (args) => h.buildPay(args),
  },
  {
    name: 'list_payments',
    title: 'See what your agent was paid, to seal it',
    description:
      'The payments made to an agent through THINKR, optionally for one hour (epoch). A seller seals ' +
      'the refs of what it delivered from this list each hour.',
    schema: { agentId, epoch: z.number().int().nonnegative().optional() },
    run: ({ agentId: id, epoch }) => h.listPayments(id, epoch),
    readOnly: true,
  },
  {
    name: 'post_bond',
    title: 'Post collateral so buyers will pay you',
    description:
      'Builds the transactions to stake collateral against your agent id. Returns unsigned calldata; ' +
      'you sign and send it. Anyone may top up an agent\'s bond, only the owner can withdraw it.',
    schema: { agentId, amount: units },
    run: (args) => h.buildBond(args),
  },
  {
    name: 'attest_deliveries',
    title: 'Commit the hour you just finished',
    description:
      'Once an epoch ends you have one hour to commit what you delivered in it. Send the list, get the ' +
      'transaction. Keep the list: you send it back unchanged to answer a claim. Miss the window and ' +
      'any claim against that hour pays out automatically.',
    schema: {
      agentId,
      epoch: z.number().int().nonnegative().describe('the finished epoch, from check_bond'),
      deliveries: z.array(delivery).min(1),
    },
    run: (args) => h.buildAttest(args),
  },
  {
    name: 'file_claim',
    title: 'Claim against an agent that took payment and delivered nothing',
    description:
      'For a payment you made through pay_agent. The amount and hour come from the payment record. ' +
      'Quotes your stake first (2% of the payment), then builds the transaction. If the seller proves ' +
      'sealed a record of the payment you lose the stake; if it stays quiet for 48 hours, settle and ' +
      'collect the payment plus your stake from its bond. Claims open two hours after the hour you paid in.',
    schema: {
      agentId,
      ref: hash32.describe('the ref you paid under'),
      from: z.string().describe('your address, the one that paid'),
    },
    run: (args) => h.buildClaim(args),
  },
  {
    name: 'discharge_claim',
    title: 'Answer a claim with proof you delivered',
    description:
      'Send the claim id and the delivery list you sealed for the hour of the payment or the hour ' +
      'after. The proof is built and checked against the root already on chain, so a transaction that ' +
      'would revert never goes out. The claimant\'s stake comes to you.',
    schema: { claimId: z.union([z.number().int().positive(), z.string()]), deliveries: z.array(delivery).min(1) },
    run: (args) => h.buildDischarge(args),
  },
  {
    name: 'collect_payout',
    title: 'Collect what settled claims owe you',
    description: 'After a claim settles, the payment and your stake are owed to you; this builds the transaction to take them.',
    schema: { from: z.string().describe('your address') },
    run: (args) => h.buildCollect(args),
  },
  {
    name: 'release_cover',
    title: "Free a seller's cover held for expired payments",
    description:
      'Each payment reserves its amount of the seller bond until its claim window ends. A seller sends ' +
      'this to free cover from payments nobody claimed, so it can take new payments.',
    schema: { agentId },
    run: ({ agentId: id }) => h.buildRelease(id),
  },
  {
    name: 'settle_claim',
    title: 'Pay out a claim the seller let run',
    description:
      'After 48 hours with no answer, anyone can send this to pay the claimant out of the bond.',
    schema: { claimId: z.union([z.number().int().positive(), z.string()]) },
    run: (args) => h.buildSettle(args),
  },
];
