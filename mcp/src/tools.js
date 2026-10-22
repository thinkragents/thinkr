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
      'Quotes your stake first, then builds the transaction. You stake 2% of what you claim. If the ' +
      'seller proves it delivered you lose the stake; if it stays quiet for 48 hours you get the stake ' +
      'back plus the claim, out of its bond.',
    schema: {
      agentId,
      ref: hash32.describe('the transaction that bought nothing: x402 payment, action_ref or receipt id, as 32 bytes'),
      epoch: z.number().int().nonnegative(),
      amount: units,
    },
    run: (args) => h.buildClaim(args),
  },
  {
    name: 'discharge_claim',
    title: 'Answer a claim with proof you delivered',
    description:
      'Send the claim id and the delivery list you attested for that epoch. The proof is built and ' +
      'checked against the root already on chain, so a transaction that would revert never goes out. ' +
      'The claimant\'s stake comes to you.',
    schema: { claimId: z.union([z.number().int().positive(), z.string()]), ref: hash32, deliveries: z.array(delivery).min(1) },
    run: (args) => h.buildDischarge(args),
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
