// A full run against a real chain, through the real API: register an agent in the
// live ERC-8004 registry, bond, deliver, seal, claim twice, answer one claim and let
// the other run to payout. The unit and e2e suites prove the logic on a local chain
// with a stand in registry; this proves it on the chain it will live on.
//
//   FAST=1   a fork (anvil --fork-url ...): skips the waits with evm_increaseTime
//   unset    a live chain: waits out the real hours, writes run.json, and leaves
//            the 48 hour payout for `node scripts/live-run.mjs --settle`
//
// Needs THINKR_RPC, THINKR_CHAIN_ID, THINKR_REGISTRY, THINKR_BONDS, THINKR_CURRENCY,
// SELLER_KEY, BUYER_KEY, and RUN_FILE for where to keep state between the two halves.

import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, defineChain, http, parseAbi, parseEther, formatEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { toRef, toDigest } from '../../contracts/sdk/tree.js';

const env = (k) => {
  const v = process.env[k];
  if (!v) throw new Error(`${k} is not set`);
  return v;
};

const RPC = env('THINKR_RPC');
const FAST = process.env.FAST === '1';
const RUN_FILE = process.env.RUN_FILE ?? './run.json';
const chain = defineChain({
  id: Number(env('THINKR_CHAIN_ID')),
  name: 'run',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
// Hours on a public RPC: expect dropped requests and ride them out. A resent signed
// transaction carries the same nonce, so a retry can never send twice.
const transport = () => http(RPC, { retryCount: 8, retryDelay: 1500, timeout: 30_000 });
const pub = createPublicClient({ chain, transport: transport() });
const SELLER = privateKeyToAccount(env('SELLER_KEY'));
const BUYER = privateKeyToAccount(env('BUYER_KEY'));
const wallet = (account) => createWalletClient({ account, chain, transport: transport() });

const registryAbi = parseAbi([
  'function register(string agentURI) returns (uint256)',
  'event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)',
]);
const tokenAbi = parseAbi([
  'function mint(address to, uint256 amount)',
  'function balanceOf(address) view returns (uint256)',
]);

const HOUR = 3600;
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

// ------------------------------------------------------------------ the API

const { server } = await import('../src/server.js');
const PORT = 8460 + Math.floor(Math.random() * 30);
await new Promise((r) => server.listen(PORT, r));
const API = `http://127.0.0.1:${PORT}`;

async function api(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: body ? { 'content-type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json();
  if (!res.ok) throw Object.assign(new Error(`${method} ${path} -> ${res.status} ${json.error}`), { body: json });
  return json;
}

/** Send what the API built, in order, from the given account. Returns gas spent in wei. */
async function sendAll({ transactions }, account) {
  let spent = 0n;
  for (const t of transactions) {
    const hash = await wallet(account).sendTransaction({ to: t.to, data: t.data, value: 0n });
    const r = await pub.waitForTransactionReceipt({ hash });
    assert.equal(r.status, 'success', t.note);
    spent += r.gasUsed * r.effectiveGasPrice;
    log(`  sent: ${t.note} (${hash.slice(0, 10)}…)`);
  }
  return spent;
}

async function chainNow() {
  return Number((await pub.getBlock()).timestamp);
}

/** Wait until chain time passes `t`. On a fork, move the clock; on a live chain, wait. */
async function until(t, why) {
  if (FAST) {
    const now = await chainNow();
    if (t > now) await pub.request({ method: 'evm_increaseTime', params: [t - now] });
    await pub.request({ method: 'evm_mine', params: [] });
    log(`clock moved to ${t}: ${why}`);
    return;
  }
  for (;;) {
    const left = t - (await chainNow());
    if (left <= 0) return;
    log(`waiting ${Math.ceil(left / 60)} min: ${why}`);
    await new Promise((r) => setTimeout(r, Math.min(left, 600) * 1000));
  }
}

// --------------------------------------------------------------- the run

async function run() {
  const report = { chain: chain.id, fast: FAST, steps: {} };

  // 1. a real identity in the live registry
  const regHash = await wallet(SELLER).writeContract({
    address: env('THINKR_REGISTRY'),
    abi: registryAbi,
    functionName: 'register',
    args: ['https://thinkr.tech/agents/testnet-seller.json'],
  });
  const regReceipt = await pub.waitForTransactionReceipt({ hash: regHash });
  const minted = regReceipt.logs.find(
    (l) => l.address.toLowerCase() === env('THINKR_REGISTRY').toLowerCase() && l.topics.length === 4
  );
  const agentId = BigInt(minted.topics[3]).toString();
  log(`registered agent ${agentId} in the ERC-8004 registry`);
  const owner = await api('GET', `/v1/agent/${agentId}`);
  log(`API reads its owner as ${owner.owner ?? JSON.stringify(owner)}`);
  report.steps.register = { agentId, tx: regHash };

  // 2. test USDG for both sides, and gas for the buyer
  for (const a of [SELLER, BUYER]) {
    const h = await wallet(SELLER).writeContract({
      address: env('THINKR_CURRENCY'), abi: tokenAbi, functionName: 'mint', args: [a.address, 100_000_000n],
    });
    await pub.waitForTransactionReceipt({ hash: h });
  }
  if ((await pub.getBalance({ address: BUYER.address })) < parseEther('0.0005')) {
    const h = await wallet(SELLER).sendTransaction({ to: BUYER.address, value: parseEther('0.002') });
    await pub.waitForTransactionReceipt({ hash: h });
    log('sent the buyer 0.002 ETH for gas');
  }

  // 3. a $10 bond, through the API
  await sendAll(await api('POST', '/v1/bond', { agentId, amount: '10000000' }), SELLER);
  const small = await api('GET', `/v1/bond/${agentId}?amount=40000`);
  const big = await api('GET', `/v1/bond/${agentId}?amount=50000000`);
  const tiny = await api('GET', `/v1/bond/${agentId}?amount=50000`);
  log(`bond: ${small.bonded} posted; 4c call safeToPay=${small.safeToPay} claimable=${small.claimable}; $50 job safeToPay=${big.safeToPay}`);
  assert.equal(small.safeToPay, true);
  assert.equal(small.claimable, false, '4c is under the 10c floor of a $10 bond');
  assert.equal(big.safeToPay, false);
  assert.equal(tiny.claimable, false);
  report.steps.bond = { bonded: small.bonded, safeSmall: small.safeToPay, safeBig: big.safeToPay };

  // 4. deliveries in three evidence formats, during the current hour
  const epoch = small.epoch;
  const deliveries = [
    { ref: toRef('fdd7f810499f06be24355ca8e2bfb8c4b965cc80c838f41fa074683443d89f5a'), digest: toDigest({ action: 'oracle.signal', scope: 'BTC' }) },
    { ref: toRef('7f9c2ba4-e88f-4a3d-9b1c-2f0e5d6a8c11'), digest: toDigest('{"result":"dataset delivered"}') },
    { ref: toRef(regHash), digest: toDigest({ run: 1, ok: true }) },
  ];
  log(`delivered 3 items in epoch ${epoch} (action_ref, UUID, tx hash)`);

  // 5. seal the hour once it has ended
  await until((epoch + 1) * HOUR + 30, `epoch ${epoch} to end so it can be sealed`);
  const sealed = await api('POST', '/v1/attest', { agentId, epoch, deliveries });
  log(`seal quoted at ${sealed.cost.eth ?? 'n/a'} ETH (${sealed.cost.gas ?? '?'} gas)${sealed.cost.reason ? ` reason: ${sealed.cost.reason}` : ''}`);
  const sealSpent = await sendAll(sealed, SELLER);
  log(`seal actually cost ${formatEther(sealSpent)} ETH`);
  report.steps.seal = { root: sealed.root, quotedWei: sealed.cost.wei, spentWei: sealSpent.toString() };

  // 6. claims open once the seal window has closed
  await until((epoch + 2) * HOUR + 30, `the seal window to close so claims can open`);
  const claimA = await api('POST', '/v1/claim', { agentId, ref: deliveries[1].ref, epoch, amount: '1000000' });
  await sendAll(claimA, BUYER);
  const claimB = await api('POST', '/v1/claim', { agentId, ref: toRef('paid-for-nothing'), epoch, amount: '1000000' });
  await sendAll(claimB, BUYER);
  const filed = await api('GET', `/v1/claims/${agentId}`);
  const [idA, idB] = filed.claims.slice(-2).map((c) => c.claimId);
  log(`filed claim ${idA} (was delivered) and ${idB} (was not), stake ${claimA.stake} each`);

  // 7. the seller answers the one it can, and is refused on the one it cannot
  await sendAll(await api('POST', `/v1/claim/${idA}/discharge`, { ref: deliveries[1].ref, deliveries }), SELLER);
  let refused = null;
  try {
    await api('POST', `/v1/claim/${idB}/discharge`, { ref: toRef('paid-for-nothing'), deliveries });
  } catch (e) {
    refused = e.body?.error;
  }
  assert.ok(refused, 'a claim with no sealed record must not be answerable');
  log(`claim ${idA} answered with the sealed proof; claim ${idB} refused: "${refused}"`);
  const mid = await api('GET', `/v1/claims/${agentId}`);
  report.steps.claims = { idA, idB, summary: mid.summary, refused };

  const state = { agentId, idB, stake: claimB.stake, filedAt: await chainNow(), buyerBefore: (await pub.readContract({ address: env('THINKR_CURRENCY'), abi: tokenAbi, functionName: 'balanceOf', args: [BUYER.address] })).toString(), report };
  if (!FAST) {
    writeFileSync(RUN_FILE, JSON.stringify(state, null, 2));
    log(`state saved to ${RUN_FILE}; run with --settle after 48 hours`);
    return report;
  }
  return settle(state);
}

// 8. silence pays out
async function settle(state) {
  await until(state.filedAt + 48 * HOUR + 60, 'the 48 hour challenge window to pass');
  await sendAll(await api('POST', `/v1/claim/${state.idB}/settle`, {}), BUYER);
  const after = await pub.readContract({ address: env('THINKR_CURRENCY'), abi: tokenAbi, functionName: 'balanceOf', args: [BUYER.address] });
  const gained = after - BigInt(state.buyerBefore);
  const bond = await api('GET', `/v1/bond/${state.agentId}`);
  const claims = await api('GET', `/v1/claims/${state.agentId}`);
  log(`claim ${state.idB} settled: buyer received ${gained} (claim + stake back); bond now ${bond.bonded}`);
  assert.equal(gained, 1_000_000n + BigInt(state.stake), 'the claim plus the stake back');
  state.report.steps.settle = { gained: gained.toString(), bondAfter: bond.bonded, summary: claims.summary };
  return state.report;
}

try {
  const report = process.argv.includes('--settle') ? await settle(JSON.parse(readFileSync(RUN_FILE))) : await run();
  console.log(JSON.stringify(report, null, 2));
} finally {
  server.close();
}
