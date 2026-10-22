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
import { build, leaf, proof, verify as verifyProof } from '../../contracts/sdk/tree.js';

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

  const [record, free, now, minBond] = await Promise.all([
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'bonds', args: [id] }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'available', args: [id] }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'currentEpoch' }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'minBond' }),
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
    // The one line an agent should branch on. A bond it cannot claim against is not
    // cover, and an agent that has given notice may be gone before a claim ripens.
    // With a payment it also has to cover that payment.
    safeToPay: free >= minBond && !leaving && (payment === null || free >= payment),
    ...(payment === null ? {} : { payment: payment.toString(), covers: free >= payment }),
    // Only payments made through THINKR's pay call can be claimed: a claim has to name
    // a payment the contract recorded, by the address that made it.
    payWith: 'POST /v1/pay',
    chain: { id: CHAIN.id, name: CHAIN.name },
  };
}

/**
 * Every agent that has ever been bonded, with its bond as it stands now. Built from
 * the contract's own Bonded events, so the register is what the chain says and
 * nothing else. Largest bond first.
 */
export async function listBonds({ limit = 100 } = {}) {
  const bonds = requireBonds();
  const events = await eventsSince(ADDRESSES.deployedAt, { address: bonds, abi: bondsAbi, eventName: 'Bonded' });
  const ids = [...new Set(events.map((e) => e.args.agentId.toString()))];
  const all = await Promise.all(
    ids.slice(0, limit).map(async (id) => {
      const [bond, claims] = await Promise.all([getBond(id), getClaims(id)]);
      return { ...bond, claims: claims.summary };
    })
  );
  all.sort((a, b) => (BigInt(b.bonded) > BigInt(a.bonded) ? 1 : BigInt(b.bonded) < BigInt(a.bonded) ? -1 : 0));
  return { count: all.length, bonds: all };
}

/**
 * An agent's sealing record: how many hours it has sealed, when it started and when
 * it last did. Sealing is the habit that makes its evidence worth anything, so this
 * is the first thing to read about a seller.
 */
export async function getSeals(rawAgentId) {
  const id = agentId(rawAgentId);
  const bonds = requireBonds();
  const [events, now] = await Promise.all([
    eventsSince(ADDRESSES.deployedAt, { address: bonds, abi: bondsAbi, eventName: 'Attested', args: { agentId: id } }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'currentEpoch' }),
  ]);
  const epochs = events.map((e) => Number(e.args.epoch)).sort((a, b) => a - b);
  const current = Number(now);
  const within = (h) => epochs.filter((e) => e >= current - h).length;
  return {
    agentId: id.toString(),
    hoursSealed: epochs.length,
    firstSealed: epochs.length ? epochs[0] : null,
    lastSealed: epochs.length ? epochs[epochs.length - 1] : null,
    last24h: within(24),
    last7d: within(24 * 7),
    epoch: current,
    recent: events.slice(-24).map((e) => ({ epoch: Number(e.args.epoch), root: e.args.root, block: Number(e.blockNumber) })),
  };
}

/** Network totals for the site: hours sealed and how many agents seal. */
export async function getStats() {
  const bonds = requireBonds();
  const events = await eventsSince(ADDRESSES.deployedAt, { address: bonds, abi: bondsAbi, eventName: 'Attested' });
  return {
    hoursSealed: events.length,
    agentsSealing: new Set(events.map((e) => e.args.agentId.toString())).size,
  };
}

/**
 * Was this delivery sealed, and when? Send the agent, the hour, the ref and digest, and
 * either the proof or the full list that was sealed. Anyone can check this: it is the
 * evidence THINKR exists to make, and it does not depend on trusting the seller or us.
 */
export async function verifySeal({ agentId: raw, epoch, ref, digest, proof: prf, deliveries: list }) {
  const id = agentId(raw);
  if (epoch === undefined || epoch === null) throw new BadRequest('epoch is required');
  const r = hash32(ref, 'ref');
  const d = hash32(digest, 'digest');
  const bonds = requireBonds();
  const target = leaf(r, d);

  let path = prf;
  if (!path && list) {
    const tree = build(deliveries(list).map((x) => leaf(x.ref, x.digest)));
    if (!tree.layers[0].includes(target)) throw new BadRequest('that delivery is not in the list you sent');
    path = proof(tree, target);
  }
  if (!Array.isArray(path)) throw new BadRequest('send the proof, or the deliveries that were sealed');
  path = path.map((p, i) => hash32(p, `proof[${i}]`));

  const root = await client.readContract({ address: bonds, abi: bondsAbi, functionName: 'roots', args: [id, BigInt(epoch)] });
  if (root === `0x${'0'.repeat(64)}`) return { sealed: false, reason: `agent ${id} sealed nothing for hour ${epoch}` };
  const sealed = verifyProof(path, root, target);
  let sealedAt = null;
  if (sealed) {
    const [e] = await eventsSince(ADDRESSES.deployedAt, { address: bonds, abi: bondsAbi, eventName: 'Attested', args: { agentId: id, epoch: BigInt(epoch) } });
    if (e) sealedAt = Number((await client.getBlock({ blockNumber: e.blockNumber })).timestamp);
  }
  return {
    sealed,
    agentId: id.toString(),
    epoch: Number(epoch),
    hourStarted: new Date(Number(epoch) * 3600 * 1000).toISOString(),
    root,
    ...(sealedAt ? { sealedAt: new Date(sealedAt * 1000).toISOString() } : {}),
    ...(sealed ? {} : { reason: 'the proof does not lead to the root sealed for that hour' }),
  };
}

/**
 * Register an agent in the ERC-8004 identity registry on Robinhood Chain, for sellers
 * that do not have an agent id yet. The new id is in the Transfer event of the receipt.
 */
export async function buildRegister({ agentURI }) {
  if (typeof agentURI !== 'string' || agentURI.length === 0 || agentURI.length > 2048) {
    throw new BadRequest('agentURI is a link to your agent card (JSON describing your agent)');
  }
  return {
    registry: ADDRESSES.registry,
    note: 'Your agent id is the tokenId in the Transfer event of the receipt. The wallet that sends this owns the agent.',
    transactions: [
      tx(ADDRESSES.registry, encodeFunctionData({ abi: registryAbi, functionName: 'register', args: [agentURI] }), 'register your agent'),
    ],
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
  const [ref, agent, claimant, seller, amt, claimBond, epoch, filedAt, state] = await client.readContract({
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
    seller,
    ref,
    amount: amt.toString(),
    claimBond: claimBond.toString(),
    epoch: Number(epoch),
    filedAt: Number(filedAt),
    state: CLAIM_STATE[state],
  };
}

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
/**
 * The first mainnet contract cannot tell a real payment from an invented one, so a
 * claim on a payment that never happened pays out against an honest seller who has
 * nothing to prove. Until version 2 records payments on chain, the API will not build
 * a bond into it. Reads still work. The contract itself cannot be changed.
 */
const V1_UNSAFE_TO_BOND = '0xd5e4643e7e20c987a3da124b05a54cae57de9dda';

export async function buildBond({ agentId: raw, amount: rawAmount }) {
  if (ADDRESSES.bonds?.toLowerCase() === V1_UNSAFE_TO_BOND) {
    const err = new Error(
      'Bonding is paused. In this contract a claim on a payment that never happened cannot be ' +
        'answered, so a bond could be claimed by anyone. Version 2 records payments on chain and ' +
        'closes this; bond then. Nothing you have is affected.'
    );
    err.status = 423;
    err.code = 'bonding_paused';
    throw err;
  }
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
function wallet(value, field) {
  try {
    return getAddress(value);
  } catch {
    throw new BadRequest(`${field} must be an address`);
  }
}

/**
 * Pay a seller through THINKR, so the payment is on record. The money goes straight
 * to the agent's owner in the same transaction; nothing is held. Only payments made
 * this way can ever be claimed, which is what stops claims on payments that never
 * happened.
 */
export async function buildPay({ agentId: raw, ref, amount: rawAmount }) {
  const id = agentId(raw);
  const r = hash32(ref, 'ref');
  const value = amount(rawAmount, 'amount');
  const bonds = requireBonds();
  const bond = await getBond(id, value);
  if (bond.status === 'winding_down') throw new BadRequest(`agent ${id} has given notice to leave, so THINKR will not take payments for it. Pay it directly if you choose, without cover.`);
  if (!bond.covers) throw new BadRequest(`agent ${id} has ${bond.available} of bond free, which will not cover a payment of ${value}. Pay less, or pay it directly without cover.`);
  return {
    bond: { bonded: bond.bonded, available: bond.available, status: bond.status, covers: bond.covers, safeToPay: bond.safeToPay },
    note: 'Keep the ref: the seller seals its delivery under it, and a claim names it.',
    transactions: [
      tx(
        ADDRESSES.currency,
        encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [bonds, value] }),
        'approve the payment'
      ),
      tx(
        bonds,
        encodeFunctionData({ abi: bondsAbi, functionName: 'pay', args: [id, r, value] }),
        `pay agent ${id}, recorded under ${r.slice(0, 10)}`
      ),
    ],
  };
}

/** The payments an agent took, optionally for one hour: what a seller seals. */
export async function listPayments(rawAgentId, rawEpoch) {
  const id = agentId(rawAgentId);
  const bonds = requireBonds();
  const events = await eventsSince(ADDRESSES.deployedAt, {
    address: bonds, abi: bondsAbi, eventName: 'Paid', args: { agentId: id },
  });
  const epoch = rawEpoch === undefined || rawEpoch === null || rawEpoch === '' ? null : Number(rawEpoch);
  const items = events
    .filter((e) => epoch === null || Number(e.args.epoch) === epoch)
    .map((e) => ({
      paymentId: e.args.paymentId,
      buyer: e.args.buyer,
      ref: e.args.ref,
      amount: e.args.amount.toString(),
      epoch: Number(e.args.epoch),
      block: Number(e.blockNumber),
    }));
  return { agentId: id.toString(), ...(epoch === null ? {} : { epoch }), count: items.length, payments: items };
}

/**
 * File a claim on a payment you made through THINKR. The contract looks the payment
 * up by agent, your address and the ref, so there is nothing to choose but which
 * payment: the amount and the hour come from the record. Checked here first, so a
 * claim that would revert never costs gas.
 */
export async function buildClaim({ agentId: raw, ref, from }) {
  const id = agentId(raw);
  const r = hash32(ref, 'ref');
  const buyer = wallet(from, 'from');
  const bonds = requireBonds();

  const paymentId = await client.readContract({ address: bonds, abi: bondsAbi, functionName: 'paymentIdOf', args: [id, r] });
  const [[, payer, , value, epoch, state], block] = await Promise.all([
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'payments', args: [paymentId] }),
    client.getBlock(),
  ]);
  if (state === 0 || payer.toLowerCase() !== buyer.toLowerCase()) {
    throw new BadRequest(`there is no payment from ${buyer} to agent ${id} under that ref. Only payments made through THINKR's pay call can be claimed, by the address that paid.`);
  }
  if (state === 2) throw new BadRequest('that payment has already been claimed');
  if (state === 3) throw new BadRequest('the claim period for this payment has ended');

  // the contract's own clock, so the API can never disagree with it about the window
  const [opensAt, closesAt] = await Promise.all([
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'claimOpens', args: [epoch] }),
    client.readContract({ address: bonds, abi: bondsAbi, functionName: 'claimCloses', args: [epoch] }),
  ]);
  const opens = Number(opensAt);
  const closes = Number(closesAt);
  const now = Number(block.timestamp);
  if (now < opens) throw new BadRequest(`claims on this payment open at ${new Date(opens * 1000).toISOString()}, once the seller can no longer seal`);
  if (now > closes) throw new BadRequest('the claim period for this payment has ended');
  // the payment reserved its own cover when it was made, so there is nothing else to check

  const stake = await client.readContract({ address: bonds, abi: bondsAbi, functionName: 'claimBondFor', args: [value] });
  return {
    amount: value.toString(),
    stake: stake.toString(),
    stakeNote: 'You lose this if the seller proves it sealed a record of this payment. If it does not answer within 48 hours, settle the claim and collect the payment plus your stake.',
    transactions: [
      tx(
        ADDRESSES.currency,
        encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [bonds, stake] }),
        'approve your stake'
      ),
      tx(bonds, encodeFunctionData({ abi: bondsAbi, functionName: 'fileClaim', args: [id, r] }), 'file the claim'),
    ],
  };
}

/**
 * Answer a claim. Send back the delivery list you sealed and we find the proof. The
 * delivery may be in the hour of the payment or the hour after; the list is matched
 * against both roots. Verified here first, so a transaction that would revert never
 * goes out.
 */
export async function buildDischarge({ claimId, deliveries: list }) {
  const id = agentId(claimId);
  const items = deliveries(list);
  const bonds = requireBonds();

  const c = await getClaim(id);
  if (c.state !== 'open') throw new BadRequest(`claim ${id} is ${c.state}`);
  const match = items.find((d) => d.ref === c.ref.toLowerCase());
  if (!match) throw new BadRequest(`that delivery list does not contain ref ${c.ref}`);

  const tree = build(items.map((d) => leaf(d.ref, d.digest)));
  const target = leaf(match.ref, match.digest);
  const agent = BigInt(c.agentId);
  const candidates = [c.epoch, c.epoch + 1];
  const roots = await Promise.all(
    candidates.map((e) => client.readContract({ address: bonds, abi: bondsAbi, functionName: 'roots', args: [agent, BigInt(e)] }))
  );
  const i = roots.findIndex((r) => r === tree.root);
  if (i === -1) {
    throw new BadRequest(
      `this list builds root ${tree.root}, which is neither hour ${candidates[0]} (${roots[0]}) nor hour ${candidates[1]} (${roots[1]}). ` +
        'Send exactly the list you sealed for the hour this delivery is in.'
    );
  }

  return {
    root: tree.root,
    sealedIn: candidates[i],
    digest: match.digest,
    transactions: [
      tx(
        bonds,
        encodeFunctionData({
          abi: bondsAbi,
          functionName: 'discharge',
          args: [id, BigInt(candidates[i]), match.digest, proof(tree, target)],
        }),
        'prove the delivery and close the claim'
      ),
    ],
  };
}

/**
 * Appoint a key to seal for your agent, so the owner key does not have to sign every
 * hour. Void if the agent changes hands. Send address(0) to clear it.
 */
export async function buildSetSealer({ agentId: raw, sealer }) {
  const id = agentId(raw);
  const key = wallet(sealer, 'sealer');
  const bonds = requireBonds();
  return {
    transactions: [tx(bonds, encodeFunctionData({ abi: bondsAbi, functionName: 'setSealer', args: [id, key] }), `let ${key} seal for agent ${id}`)],
  };
}

/** Take what settled claims owe you. */
export async function buildCollect({ from, to }) {
  const who = wallet(from, 'from');
  const dest = to ? wallet(to, 'to') : who;
  const bonds = requireBonds();
  const owed = await client.readContract({ address: bonds, abi: bondsAbi, functionName: 'owed', args: [who] });
  if (owed === 0n) throw new BadRequest(`nothing is owed to ${who}`);
  return {
    owed: owed.toString(),
    to: dest,
    transactions: [tx(bonds, encodeFunctionData({ abi: bondsAbi, functionName: 'collect', args: [dest] }), `collect what you are owed, to ${dest}`)],
  };
}

/**
 * Free a seller's cover held for payments whose claim window ended unclaimed. Anyone may
 * send it; it only ever releases what the contract agrees has expired.
 */
export async function buildRelease(rawAgentId) {
  const id = agentId(rawAgentId);
  const bonds = requireBonds();
  const [events, block] = await Promise.all([
    eventsSince(ADDRESSES.deployedAt, { address: bonds, abi: bondsAbi, eventName: 'Paid', args: { agentId: id } }),
    client.getBlock(),
  ]);
  const now = Number(block.timestamp);
  const period = Number(await client.readContract({ address: bonds, abi: bondsAbi, functionName: 'CLAIM_PERIOD' }));
  const expired = events.filter((e) => now > (Number(e.args.epoch) + 1) * 3600 + period);
  const states = await Promise.all(
    expired.map((e) => client.readContract({ address: bonds, abi: bondsAbi, functionName: 'payments', args: [e.args.paymentId] }))
  );
  const ids = expired.filter((_, i) => states[i][5] === 1).map((e) => e.args.paymentId);
  if (ids.length === 0) return { released: 0, note: 'no cover is waiting to be released', transactions: [] };
  return {
    released: ids.length,
    transactions: [tx(bonds, encodeFunctionData({ abi: bondsAbi, functionName: 'releaseMany', args: [ids] }), `release cover held for ${ids.length} expired payments`)],
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
