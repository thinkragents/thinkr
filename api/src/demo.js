// THINKR's own agent, sealing the answers this API gives.
//
// Every answer to a read carries x-thinkr-ref and x-thinkr-digest headers. At the end
// of each hour the API seals that hour's answers on chain as THINKR's demo agent, so
// anyone can later prove the exact answer they were given existed, unchanged, at the
// time: POST /v1/verify with the headers and GET /v1/demo/deliveries for the hour.
//
// It is off unless DEMO_SEALER_KEY and DEMO_AGENT_ID are set. The key belongs to a
// small wallet that owns the demo agent and does nothing but seal; it holds a little
// ETH for gas and no user money. Nothing here touches anyone else's keys.

import { createWalletClient, encodeFunctionData, http, keccak256, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { client, robinhood } from './chain.js';
import { bondsAbi } from './abi.js';
import { ADDRESSES, CHAIN } from './config.js';
import { build, leaf } from '../../contracts/sdk/tree.js';

const KEY = process.env.DEMO_SEALER_KEY;
const AGENT = process.env.DEMO_AGENT_ID;
export const DEMO = Boolean(KEY && AGENT && ADDRESSES.bonds);

const HOUR = 3600;
const KEEP_HOURS = 48; // sealed lists are kept in memory this long for /v1/demo/deliveries
// A flood of requests must not be able to run the server out of memory. Past this many
// answers in an hour, answers are still given but no longer sealed (and say nothing).
const MAX_PER_HOUR = 20_000;

/** epoch -> { deliveries: [{ref, digest}], root?, tx? } */
const hours = new Map();
let counter = 0;

const epochNow = () => Math.floor(Date.now() / 1000 / HOUR);

/**
 * Record one answer. Returns the headers to send with it. The ref is unique per
 * answer; the digest is keccak256 of the exact bytes of the body.
 */
export function record(body) {
  if (!DEMO) return {};
  const epoch = epochNow();
  const ref = keccak256(toHex(`thinkr-api:${epoch}:${Date.now()}:${counter++}`));
  const digest = keccak256(toHex(body));
  if (!hours.has(epoch)) hours.set(epoch, { deliveries: [] });
  if (hours.get(epoch).deliveries.length >= MAX_PER_HOUR) return {};
  hours.get(epoch).deliveries.push({ ref, digest });
  return {
    'x-thinkr-agent': AGENT,
    'x-thinkr-epoch': String(epoch),
    'x-thinkr-ref': ref,
    'x-thinkr-digest': digest,
  };
}

/** The list sealed (or to be sealed) for an hour, so anyone can rebuild the proof. */
export function deliveriesFor(epoch) {
  const h = hours.get(Number(epoch));
  return {
    agentId: AGENT ?? null,
    epoch: Number(epoch),
    sealed: Boolean(h?.root),
    root: h?.root ?? null,
    tx: h?.tx ?? null,
    deliveries: h?.deliveries ?? [],
    note: 'Kept for 48 hours after the hour ends. Verify with POST /v1/verify, sending these as deliveries.',
  };
}

async function sealFinishedHour() {
  const epoch = epochNow() - 1; // the hour that just ended; its window is open for an hour
  const sinceEnd = Date.now() / 1000 - (epoch + 1) * HOUR;
  if (sinceEnd < 60 || sinceEnd > HOUR - 300) return; // a minute in, never near the deadline
  await sealHour(epoch);
}

/** Seal one finished hour's answers. Exported so the tests can drive it directly. */
export async function sealHour(epoch) {
  if (!hours.has(epoch)) hours.set(epoch, { deliveries: [] });
  const h = hours.get(epoch);
  if (h.root || h.sealing) return;

  // A heartbeat leaf, so the agent seals every hour even when nobody asked anything.
  h.deliveries.push({ ref: keccak256(toHex(`thinkr-heartbeat:${epoch}`)), digest: keccak256(toHex(`epoch ${epoch}`)) });
  const { root } = build(h.deliveries.map((d) => leaf(d.ref, d.digest)));

  h.sealing = true;
  try {
    const onChain = await client.readContract({ address: ADDRESSES.bonds, abi: bondsAbi, functionName: 'roots', args: [BigInt(AGENT), BigInt(epoch)] });
    if (onChain !== `0x${'0'.repeat(64)}`) {
      h.root = onChain; // sealed already, by an earlier run of this process
      return;
    }
    const account = privateKeyToAccount(KEY);
    const wallet = createWalletClient({ account, chain: robinhood, transport: http(CHAIN.rpc) });
    const hash = await wallet.sendTransaction({
      to: ADDRESSES.bonds,
      data: encodeFunctionData({ abi: bondsAbi, functionName: 'attest', args: [BigInt(AGENT), BigInt(epoch), root] }),
    });
    await client.waitForTransactionReceipt({ hash });
    h.root = root;
    h.tx = hash;
    console.log(`demo agent ${AGENT} sealed hour ${epoch}: ${h.deliveries.length} answers, ${hash}`);
  } catch (err) {
    console.error(`demo seal for hour ${epoch} failed: ${err.shortMessage ?? err.message}`);
  } finally {
    h.sealing = false;
  }

  for (const e of hours.keys()) if (e < epoch - KEEP_HOURS) hours.delete(e);
}

export function startDemoSealer() {
  if (!DEMO) return;
  console.log(`demo agent ${AGENT} sealing this API's answers every hour`);
  setInterval(() => sealFinishedHour().catch(() => {}), 60_000).unref();
}
