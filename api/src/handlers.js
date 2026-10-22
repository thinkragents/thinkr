// The six operations, as plain functions. The HTTP server and the MCP server both
// call these and neither adds logic of its own, so the two surfaces cannot drift.
//
// Nothing here signs anything. Write operations return the transaction an agent
// should send, and the agent sends it. We never hold a key, which means we can never
// move anyone's collateral and nobody has to trust us not to.

import { encodeFunctionData, formatEther, getAddress, maxUint256 } from 'viem';
import { client } from './chain.js';
import { bondsAbi, erc20Abi, registryAbi } from './abi.js';
import { ADDRESSES, CHAIN, requireBonds } from './config.js';
import { build, leaf, proof } from '../../contracts/sdk/tree.js';

const CLAIM_STATE = ['none', 'open', 'discharged', 'settled'];

export class BadRequest extends Error {
  constructor(message) {
    super(message);
    this.status = 400;
    this.code = 'bad_request';
  }
}

function agentId(value) {
  let n;
  try {
    n = BigInt(value);
  } catch {
    throw new BadRequest(`agentId must be a whole number, got ${JSON.stringify(value)}`);
  }
  if (n < 0n) throw new BadRequest('agentId must not be negative');
  return n;
}

function hash32(value, field) {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new BadRequest(`${field} must be a 32-byte hex string`);
  }
  return value.toLowerCase();
}

function amount(value, field) {
  let n;
  try {
    n = BigInt(value);
  } catch {
    throw new BadRequest(`${field} must be a whole number of token units`);
  }
  if (n <= 0n) throw new BadRequest(`${field} must be greater than zero`);
  return n;
}

function deliveries(list) {
  if (!Array.isArray(list) || list.length === 0) {
    throw new BadRequest('deliveries must be a non-empty array of {ref, digest}');
  }
  return list.map((d, i) => ({
    ref: hash32(d?.ref, `deliveries[${i}].ref`),
    digest: hash32(d?.digest, `deliveries[${i}].digest`),
  }));
}

function tx(to, data, note) {
  return { chainId: CHAIN.id, to: getAddress(to), data, value: '0', note };
}

// ------------------------------------------------------------------- reads

/**
 * The reading a buyer does before it pays. One round trip, and the answer is a
 * judgement rather than a row: `safeToPay` is what an agent actually wants to know.
 *
 * Pass the payment and the judgement is about that payment. The minimum bond is an
 * entry ticket, not cover: a seller with $1 posted is fine for a 4 cent call and
 * not for a $50 job, and only the payment can tell the two apart.
 */
export async function getBond(rawAgentId, rawPayment) {
  const id = agentId(rawAgentId);
  const payment = rawPayment === undefined || rawPayment === null || rawPayment === ''
    ? null
    : amount(rawPayment, 'amount');
  const bonds = requireBonds();

  const [record, free, now, minBond, minClaim] = await Promise.all([
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'bonds', args: [id] }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'available', args: [id] }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'currentEpoch' }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'minBond' }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'minClaimFor', args: [id] }),
  ]);

  const [total, reserved, bondedAt, withdrawAfter] = record;
  const leaving = withdrawAfter !== 0n;

  return {
    agentId: id.toString(),
    bonded: total.toString(),
    available: free.toString(),
    reserved: reserved.toString(),
    currency: ADDRESSES.currency,
    bondedAt: bondedAt === 0n ? null : Number(bondedAt),
    withdrawAfter: leaving ? Number(withdrawAfter) : null,
    status: total === 0n ? 'unbonded' : leaving ? 'winding_down' : 'active',
    epoch: Number(now),
    // The smallest claim this agent can be taken to task for. It is one percent of
    // what it has posted, so it tracks the size of business the agent is doing
    // rather than a number fixed at deployment.
    minClaim: minClaim.toString(),
    // The one line an agent should branch on. A bond it cannot claim against is not
    // cover, and an agent that has given notice may be gone before a claim ripens.
    // With a payment it also has to cover that payment. Whether the payment is large
    // enough to claim is reported apart, as `claimable`: folding it in made a bigger
    // bond read as less safe for small calls, since the claim floor is 1% of the bond.
    safeToPay: free >= minBond && !leaving && (payment === null || free >= payment),
    ...(payment === null
      ? {}
      : {
          payment: payment.toString(),
          covers: free >= payment,
          claimable: payment >= minClaim,
        }),
    chain: { id: CHAIN.id, name: CHAIN.name },
  };
}

/** Claim history for one agent, straight from the logs. */
/**
 * Every matching event since the contract was deployed, read in pages. RPCs cap how
 * many blocks one eth_getLogs may span (10m on Robinhood's), so a single call from
 * genesis fails outright on a chain this long. A refused page is halved and retried.
 */
async function eventsSince(fromBlock, query) {
  const head = await client.getBlockNumber();
  const out = [];
  let step = 5_000_000n;
  for (let from = fromBlock; from <= head; ) {
    const to = from + step - 1n > head ? head : from + step - 1n;
    try {
      out.push(...(await client.getContractEvents({ ...query, fromBlock: from, toBlock: to })));
      from = to + 1n;
    } catch (err) {
      if (step <= 10_000n) throw err;
      step /= 2n;
    }
  }
  return out;
}

export async function getClaims(rawAgentId, { fromBlock = ADDRESSES.deployedAt } = {}) {
  const id = agentId(rawAgentId);
  const bonds = requireBonds();

  const [filed, discharged, settled] = await Promise.all([
    eventsSince(fromBlock, { address: bonds, abi: bondsAbi, eventName: 'ClaimFiled', args: { agentId: id } }),
    eventsSince(fromBlock, { address: bonds, abi: bondsAbi, eventName: 'ClaimDischarged', args: { agentId: id } }),
    eventsSince(fromBlock, { address: bonds, abi: bondsAbi, eventName: 'ClaimSettled', args: { agentId: id } }),
  ]);

  const closed = new Map();
  for (const e of discharged) closed.set(e.args.claimId.toString(), 'discharged');
  for (const e of settled) closed.set(e.args.claimId.toString(), 'settled');

  const claims = filed.map((e) => {
    const claimId = e.args.claimId.toString();
    return {
      claimId,
      claimant: e.args.claimant,
      ref: e.args.ref,
      epoch: Number(e.args.epoch),
      amount: e.args.amount.toString(),
      state: closed.get(claimId) ?? 'open',
      block: Number(e.blockNumber),
    };
  });

  const count = (s) => claims.filter((c) => c.state === s).length;
  return {
    agentId: id.toString(),
    // What a buyer reads this for: not the list, the record.
    summary: { filed: claims.length, open: count('open'), discharged: count('discharged'), paid: count('settled') },
    claims,
  };
}

/** One claim, by id. */
export async function getClaim(rawClaimId) {
  const id = agentId(rawClaimId);
  const bonds = requireBonds();
  const [agent, claimant, amt, claimBond, epoch, filedAt, state] = await client.readContract({
    address: bonds,
    abi: bondsAbi,
    functionName: 'claims',
    args: [id],
  });
  if (CLAIM_STATE[state] === 'none') throw new BadRequest(`no claim with id ${id}`);
  return {
    claimId: id.toString(),
    agentId: agent.toString(),
    claimant,
    amount: amt.toString(),
    claimBond: claimBond.toString(),
    epoch: Number(epoch),
    filedAt: Number(filedAt),
    state: CLAIM_STATE[state],
  };
}

/** Who owns an agent, per ERC-8004. Works whether or not ThinkrBonds is deployed. */
export async function getAgentOwner(rawAgentId) {
  const id = agentId(rawAgentId);
  try {
    const owner = await client.readContract({
      address: ADDRESSES.registry,
      abi: registryAbi,
      functionName: 'ownerOf',
      args: [id],
    });
    return { agentId: id.toString(), owner, registered: true };
  } catch {
    return { agentId: id.toString(), owner: null, registered: false };
  }
}

// ------------------------------------------------------------------ writes

/** The two transactions that post a bond: approve the token, then bond it. */
export async function buildBond({ agentId: raw, amount: rawAmount }) {
  const id = agentId(raw);
  const value = amount(rawAmount, 'amount');
  const bonds = requireBonds();
  if (!ADDRESSES.currency) throw new BadRequest('no collateral token is configured');

  return {
    transactions: [
      tx(
        ADDRESSES.currency,
        encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [bonds, maxUint256] }),
        'approve the bond contract to pull your collateral'
      ),
      tx(
        bonds,
        encodeFunctionData({ abi: bondsAbi, functionName: 'bond', args: [id, value] }),
        'post the collateral'
      ),
    ],
  };
}

/**
 * Commit a finished epoch's deliveries.
 *
 * You send the list, we build the root, you send the transaction. We keep nothing:
 * when you need to answer a claim you send the same list again. There is no database
 * here to lose, leak, or be subpoenaed for.
 */
export async function buildAttest({ agentId: raw, epoch, deliveries: list }) {
  const id = agentId(raw);
  const items = deliveries(list);
  const bonds = requireBonds();
  if (epoch === undefined || epoch === null) throw new BadRequest('epoch is required');

  const leaves = items.map((d) => leaf(d.ref, d.digest));
  const { root } = build(leaves);
  const data = encodeFunctionData({ abi: bondsAbi, functionName: 'attest', args: [id, BigInt(epoch), root] });

  return {
    root,
    deliveries: items.length,
    keep: 'Store this delivery list. You will need it, unchanged, to answer a claim.',
    cost: await quote(id, bonds, data),
    transactions: [tx(bonds, data, `commit ${items.length} deliveries for epoch ${epoch}`)],
  };
}

/**
 * What a seal costs right now, in the chain's gas token. On Robinhood Chain most of
 * a transaction's price is the Ethereum L1 surcharge, which has moved more than a
 * thousandfold in a day, so a seller is shown the price before it signs rather than
 * after. Estimated as the agent's owner, the only address the contract accepts.
 * Never blocks the seal: a quote that cannot be had comes back as null with a reason.
 */
async function quote(id, bonds, data) {
  try {
    const owner = await client.readContract({ address: ADDRESSES.registry, abi: registryAbi, functionName: 'ownerOf', args: [id] });
    const [gas, price] = await Promise.all([
      client.estimateGas({ account: owner, to: bonds, data }),
      client.getGasPrice(),
    ]);
    const wei = gas * price;
    return { gas: gas.toString(), gasPrice: price.toString(), wei: wei.toString(), eth: formatEther(wei) };
  } catch (err) {
    return { wei: null, reason: (err.shortMessage ?? err.message ?? 'estimate failed').split('\n')[0] };
  }
}

/** File a claim. The stake is quoted before you sign anything. */
export async function buildClaim({ agentId: raw, ref, epoch, amount: rawAmount }) {
  const id = agentId(raw);
  const payment = hash32(ref, 'ref');
  const value = amount(rawAmount, 'amount');
  const bonds = requireBonds();
  if (epoch === undefined || epoch === null) throw new BadRequest('epoch is required');

  const [free, stake, floor] = await Promise.all([
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'available', args: [id] }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'claimBondFor', args: [value] }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'minClaimFor', args: [id] }),
  ]);
  if (value < floor) {
    throw new BadRequest(
      `the smallest claim this contract accepts is ${floor} and you asked for ${value}. ` +
        'Below that, take the loss and stop buying from that agent.'
    );
  }
  if (value > free) {
    throw new BadRequest(`that agent has ${free} unreserved, which will not cover a claim of ${value}`);
  }

  return {
    stake: stake.toString(),
    stakeNote: 'You lose this if the seller proves it delivered. You get it back, plus the claim, if it does not answer.',
    transactions: [
      tx(
        ADDRESSES.currency ?? bonds,
        encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [bonds, stake] }),
        'approve your stake'
      ),
      tx(
        bonds,
        encodeFunctionData({ abi: bondsAbi, functionName: 'fileClaim', args: [id, payment, BigInt(epoch), value] }),
        'file the claim'
      ),
    ],
  };
}

/**
 * Answer a claim. Send back the same delivery list you attested and we find the
 * proof. Verified here first, so a transaction that would revert never goes out.
 */
export async function buildDischarge({ claimId, ref, deliveries: list }) {
  const id = agentId(claimId);
  const payment = hash32(ref, 'ref');
  const items = deliveries(list);
  const bonds = requireBonds();

  const match = items.find((d) => d.ref === payment);
  if (!match) throw new BadRequest(`that delivery list does not contain ref ${payment}`);

  const leaves = items.map((d) => leaf(d.ref, d.digest));
  const tree = build(leaves);
  const target = leaf(match.ref, match.digest);

  const onChain = await client
    .readContract({ address: bonds, abi: bondsAbi, functionName: 'claims', args: [id] })
    .then(([agent, , , , epoch]) =>
      client.readContract({ address: bonds, abi: bondsAbi, functionName: 'roots', args: [agent, epoch] })
    );

  if (onChain !== tree.root) {
    throw new BadRequest(
      `this list builds root ${tree.root}, but the epoch you attested is ${onChain}. ` +
        'The list must be exactly the one you committed, including deliveries unrelated to this claim.'
    );
  }

  return {
    root: tree.root,
    digest: match.digest,
    transactions: [
      tx(
        bonds,
        encodeFunctionData({
          abi: bondsAbi,
          functionName: 'discharge',
          args: [id, payment, match.digest, proof(tree, target)],
        }),
        'prove the delivery and close the claim'
      ),
    ],
  };
}

/** Pay out a claim the seller let run. Anyone can send it. */
export async function buildSettle({ claimId }) {
  const id = agentId(claimId);
  const bonds = requireBonds();
  return {
    transactions: [
      tx(bonds, encodeFunctionData({ abi: bondsAbi, functionName: 'settle', args: [id] }), 'settle the claim'),
    ],
  };
}
