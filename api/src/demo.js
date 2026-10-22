// THINKR's own agent, sealing what it says.
//
// GET /v1/demo/answer returns the demo agent's statement for the current minute, with
// x-thinkr-ref and x-thinkr-digest headers. At the end of each hour the agent seals
// that hour's sixty statements on chain, so anyone can later prove the exact answer
// they were given existed, unchanged, at the time: POST /v1/verify with the headers
// and the list from GET /v1/demo/deliveries/{epoch}.
//
// Every statement is a pure function of the hour and the minute. Nothing is held in
// memory, so a restart (the free host sleeps when idle) can always rebuild exactly the
// list that was sealed, and seal any hour it missed while its window is still open.
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
const MINUTES = 60;
// The contract accepts a seal for six hours after the hour ends. Stay clear of the edge.
const WINDOW_HOURS = 6;
const EMPTY = `0x${'0'.repeat(64)}`;

const epochNow = () => Math.floor(Date.now() / 1000 / HOUR);

/** The demo agent's answer for one minute: the same bytes every time it is asked. */
function statement(epoch, minute) {
  const ref = keccak256(toHex(`thinkr-demo:${AGENT}:${epoch}:${minute}`));
  const at = new Date((epoch * HOUR + minute * 60) * 1000).toISOString();
  const body = JSON.stringify(
    {
      agentId: String(AGENT),
      epoch,
      minute,
      at,
      ref,
      said: `THINKR demo agent ${AGENT}, ${at}. This exact answer is sealed on Robinhood Chain when hour ${epoch} ends.`,
      verify: `After the hour is sealed, POST /v1/verify with agentId, epoch, the x-thinkr-ref and x-thinkr-digest headers, and the deliveries from GET /v1/demo/deliveries/${epoch}.`,
    },
    null,
    2
  );
  return { ref, digest: keccak256(toHex(body)), body };
}

const listFor = (epoch) =>
  Array.from({ length: MINUTES }, (_, m) => {
    const { ref, digest } = statement(epoch, m);
    return { ref, digest };
  });

const rootFor = (epoch) => build(listFor(epoch).map((d) => leaf(d.ref, d.digest))).root;

/** This minute's answer and the headers that point to its seal. */
export function answer() {
  if (!DEMO) return null;
  const now = Math.floor(Date.now() / 1000);
  const epoch = Math.floor(now / HOUR);
  const minute = Math.floor((now % HOUR) / 60);
  const { ref, digest, body } = statement(epoch, minute);
  return {
    body,
    headers: {
      'x-thinkr-agent': String(AGENT),
      'x-thinkr-epoch': String(epoch),
      'x-thinkr-ref': ref,
      'x-thinkr-digest': digest,
    },
  };
}

/** The list sealed (or to be sealed) for an hour, so anyone can rebuild the proof. */
export async function deliveriesFor(raw) {
  const epoch = Number(raw);
  if (!DEMO) return { agentId: null, epoch, sealed: false, deliveries: [], note: 'the demo agent is not running on this server' };
  if (!Number.isInteger(epoch) || epoch < 0 || epoch > epochNow()) {
    const err = new Error('epoch must be an hour that has started: floor(unix seconds / 3600)');
    err.status = 400;
    err.code = 'bad_request';
    throw err;
  }
  const onChain = await client.readContract({ address: ADDRESSES.bonds, abi: bondsAbi, functionName: 'roots', args: [BigInt(AGENT), BigInt(epoch)] });
  const root = rootFor(epoch);
  const base = { agentId: String(AGENT), epoch };
  if (onChain === EMPTY) {
    return {
      ...base,
      sealed: false,
      root,
      deliveries: listFor(epoch),
      note: epoch >= epochNow() - WINDOW_HOURS
        ? 'Not sealed yet. The demo agent seals each hour a minute or two after it ends.'
        : 'This hour was never sealed.',
    };
  }
  if (onChain.toLowerCase() !== root.toLowerCase()) {
    // Sealed before the demo's answers were reproducible; that list was not kept.
    return { ...base, sealed: true, root: onChain, deliveries: null, note: 'Sealed, but its list was not kept, so no answer from this hour can be proven.' };
  }
  return { ...base, sealed: true, root, deliveries: listFor(epoch), note: 'Send these as deliveries to POST /v1/verify.' };
}

/** Seal one finished hour. Exported so the tests can drive it directly. */
export async function sealHour(epoch) {
  const onChain = await client.readContract({ address: ADDRESSES.bonds, abi: bondsAbi, functionName: 'roots', args: [BigInt(AGENT), BigInt(epoch)] });
  if (onChain !== EMPTY) return false;
  const account = privateKeyToAccount(KEY);
  const wallet = createWalletClient({ account, chain: robinhood, transport: http(CHAIN.rpc) });
  const hash = await wallet.sendTransaction({
    to: ADDRESSES.bonds,
    data: encodeFunctionData({ abi: bondsAbi, functionName: 'attest', args: [BigInt(AGENT), BigInt(epoch), rootFor(epoch)] }),
  });
  await client.waitForTransactionReceipt({ hash });
  console.log(`demo agent ${AGENT} sealed hour ${epoch}, ${hash}`);
  return true;
}

const done = new Set();

/** Seal every finished hour still inside its window, including any missed while asleep. */
async function sealPending() {
  const now = Date.now() / 1000;
  const current = epochNow();
  for (let e = current - WINDOW_HOURS; e < current; e++) {
    if (done.has(e)) continue;
    const sinceEnd = now - (e + 1) * HOUR;
    if (sinceEnd < 60 || sinceEnd > WINDOW_HOURS * HOUR - 600) continue; // a minute in, never near the deadline
    try {
      await sealHour(e);
      done.add(e);
    } catch (err) {
      console.error(`demo seal for hour ${e} failed: ${err.shortMessage ?? err.message}`);
    }
  }
  for (const e of done) if (e < current - WINDOW_HOURS) done.delete(e);
}

export function startDemoSealer() {
  if (!DEMO) return;
  console.log(`demo agent ${AGENT} sealing one answer a minute, every hour`);
  sealPending().catch(() => {});
  setInterval(() => sealPending().catch(() => {}), 60_000).unref();
}
