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
  log(`bond: ${small.bonded} posted; 4c payment covered=${small.covers}; $50 payment covered=${big.covers}`);
  assert.equal(small.safeToPay, true);
  assert.equal(big.safeToPay, false);
  report.steps.bond = { bonded: small.bonded, safeSmall: small.safeToPay, safeBig: big.safeToPay };

  // 4. the buyer pays twice through THINKR; each payment reserves its own cover
  const epoch = small.epoch;
  const delivered = toRef('7f9c2ba4-e88f-4a3d-9b1c-2f0e5d6a8c11');
  const silent = toRef(`paid-for-nothing-${regHash}`);
  for (const ref of [delivered, silent]) await sendAll(await api('POST', '/v1/pay', { agentId, ref, amount: '1000000' }), BUYER);
  const afterPay = await api('GET', `/v1/bond/${agentId}`);
  log(`buyer paid $1 twice through THINKR; ${afterPay.reserved} of the bond is reserved for those payments`);
  assert.equal(afterPay.reserved, '2000000');

  // 5. the seller delivers one of them, plus other work, and seals the hour once it ends
  const deliveries = [
    { ref: toRef('fdd7f810499f06be24355ca8e2bfb8c4b965cc80c838f41fa074683443d89f5a'), digest: toDigest({ action: 'oracle.signal', scope: 'BTC' }) },
    { ref: delivered, digest: toDigest('{"result":"dataset delivered"}') },
    { ref: toRef(regHash), digest: toDigest({ run: 1, ok: true }) },
  ];
  await until((epoch + 1) * HOUR + 30, `hour ${epoch} to end so it can be sealed`);
  const sealed = await api('POST', '/v1/attest', { agentId, epoch, deliveries });
  log(`seal quoted at ${sealed.cost.eth ?? 'n/a'} ETH${sealed.cost.reason ? ` reason: ${sealed.cost.reason}` : ''}`);
  const sealSpent = await sendAll(sealed, SELLER);
  log(`seal actually cost ${formatEther(sealSpent)} ETH`);
  const verified = await api('POST', '/v1/verify', { agentId, epoch, ref: delivered, digest: deliveries[1].digest, deliveries });
  assert.equal(verified.sealed, true);
  log(`verify: the delivered order is sealed, at ${verified.sealedAt}`);
  report.steps.seal = { root: sealed.root, quotedWei: sealed.cost.wei, spentWei: sealSpent.toString(), sealedAt: verified.sealedAt };

  // 6. the attacks, on the live chain: an invented payment, and someone else's payment
  for (const [name, body] of [
    ['invented payment', { agentId, ref: toRef('never paid'), from: BUYER.address }],
    ["someone else's payment", { agentId, ref: delivered, from: SELLER.address }],
  ]) {
    let refused = null;
    try { await api('POST', '/v1/claim', body); } catch (e) { refused = e.body?.error; }
    assert.ok(refused, `${name} must be refused`);
    log(`attack refused (${name}): "${refused.slice(0, 80)}…"`);
  }

  // 7. claims open once both hours a seller could seal in are final
  await until((epoch + 8) * HOUR + 30, 'both seal windows (six hours each) to close so claims can open');
  const claimA = await api('POST', '/v1/claim', { agentId, ref: delivered, from: BUYER.address });
  await sendAll(claimA, BUYER);
  const claimB = await api('POST', '/v1/claim', { agentId, ref: silent, from: BUYER.address });
  await sendAll(claimB, BUYER);
  const filed = await api('GET', `/v1/claims/${agentId}`);
  if (filed.claims.length < 2) throw new Error(`the claims list came back with ${filed.claims.length} claims: ${JSON.stringify(filed)}`);
  const [idA, idB] = filed.claims.slice(-2).map((c) => c.claimId);
  log(`filed claim ${idA} (sealed) and ${idB} (never sealed), stake ${claimA.stake} each`);

  // 8. the seller answers the one it sealed, and cannot answer the one it did not
  await sendAll(await api('POST', `/v1/claim/${idA}/discharge`, { deliveries }), SELLER);
  let refused = null;
  try { await api('POST', `/v1/claim/${idB}/discharge`, { deliveries }); } catch (e) { refused = e.body?.error; }
  assert.ok(refused, 'a claim with no sealed record must not be answerable');
  log(`claim ${idA} answered with the seal; claim ${idB} cannot be: "${refused.slice(0, 80)}…"`);
  report.steps.claims = { idA, idB, summary: (await api('GET', `/v1/claims/${agentId}`)).summary };

  const state = { agentId, idB, stake: claimB.stake, filedAt: await chainNow(), report };
  if (!FAST) {
    writeFileSync(RUN_FILE, JSON.stringify(state, null, 2));
    log(`state saved to ${RUN_FILE}; run with --settle after 48 hours`);
    return report;
  }
  return settle(state);
}

// 9. silence pays out, and the buyer collects
async function settle(state) {
  await until(state.filedAt + 48 * HOUR + 60, 'the 48 hour challenge window to pass');
  await sendAll(await api('POST', `/v1/claim/${state.idB}/settle`, {}), BUYER);
  const before = await pub.readContract({ address: env('THINKR_CURRENCY'), abi: tokenAbi, functionName: 'balanceOf', args: [BUYER.address] });
  const owed = await api('POST', '/v1/collect', { from: BUYER.address });
  await sendAll(owed, BUYER);
  const after = await pub.readContract({ address: env('THINKR_CURRENCY'), abi: tokenAbi, functionName: 'balanceOf', args: [BUYER.address] });
  const gained = after - before;
  const bond = await api('GET', `/v1/bond/${state.agentId}`);
  log(`claim ${state.idB} settled and collected: buyer received ${gained} (payment + stake back); bond now ${bond.bonded}, reserved ${bond.reserved}`);
  assert.equal(gained, 1_000_000n + BigInt(state.stake), 'the payment plus the stake back');
  assert.equal(bond.reserved, '0', 'no cover left behind');
  state.report.steps.settle = { gained: gained.toString(), bondAfter: bond.bonded };
  return state.report;
}

try {
  const report = process.argv.includes('--settle') ? await settle(JSON.parse(readFileSync(RUN_FILE))) : await run();
  console.log(JSON.stringify(report, null, 2));
} finally {
  server.close();
}
