// Local check of the demo agent against a fresh anvil (run after test/anvil-up.sh: node scripts/demo-check.mjs).
import { createPublicClient, createWalletClient, http, keccak256, toHex, encodeFunctionData } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import assert from 'node:assert/strict';

const KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const chain = { id: 31337, name: 'anvil', nativeCurrency: { name: 'E', symbol: 'E', decimals: 18 }, rpcUrls: { default: { http: ['http://127.0.0.1:8545'] } } };
const pub = createPublicClient({ chain, transport: http() });
const w = createWalletClient({ account: privateKeyToAccount(KEY), chain, transport: http() });
// Local.s.sol registers agent 1 to this key in the mock registry
process.env.DEMO_AGENT_ID = '1';
process.env.DEMO_SEALER_KEY = KEY;

const demo = await import('../src/demo.js');
const h = await import('../src/handlers.js');
const { bondsAbi } = await import('../src/abi.js');

const a = demo.answer();
assert.equal(a.headers['x-thinkr-digest'], keccak256(toHex(a.body)), 'digest is of the exact body');
assert.deepEqual(demo.answer().body, a.body, 'same minute, same bytes');
const epoch = Number(a.headers['x-thinkr-epoch']);

// The live hour: not sealed yet, list given
let d = await demo.deliveriesFor(epoch);
assert.equal(d.sealed, false); assert.equal(d.deliveries.length, 60);

// Move the chain past the hour and seal it, as the loop would after a restart
const t = Number((await pub.getBlock()).timestamp);
const target = (epoch + 1) * 3600 + 120;
await pub.request({ method: 'evm_setNextBlockTimestamp', params: [toHex(Math.max(target, t + 1))] });
await pub.request({ method: 'evm_mine', params: [] });
assert.equal(await demo.sealHour(epoch), true);
assert.equal(await demo.sealHour(epoch), false, 'never seals twice');

d = await demo.deliveriesFor(epoch);
assert.equal(d.sealed, true); assert.equal(d.deliveries.length, 60);
const v = await h.verifySeal({ agentId: process.env.DEMO_AGENT_ID, epoch, ref: a.headers['x-thinkr-ref'], digest: a.headers['x-thinkr-digest'], deliveries: d.deliveries });
assert.equal(v.sealed, true, JSON.stringify(v));
const bad = await h.verifySeal({ agentId: process.env.DEMO_AGENT_ID, epoch, ref: a.headers['x-thinkr-ref'], digest: keccak256(toHex(a.body + ' ')), deliveries: d.deliveries });
assert.equal(bad.sealed, false); assert.match(bad.reason, /not in the list/);

// An hour sealed under the old scheme: say the list is gone, never hand out a wrong one
const old = epoch - 1;
await w.sendTransaction({ to: process.env.THINKR_BONDS, data: encodeFunctionData({ abi: bondsAbi, functionName: 'attest', args: [BigInt(process.env.DEMO_AGENT_ID), BigInt(old), keccak256(toHex('old'))] }) });
await new Promise((r) => setTimeout(r, 1500));
d = await demo.deliveriesFor(old);
assert.equal(d.sealed, true); assert.equal(d.deliveries, null);
console.log('demo check passed: answer, seal, verify, tamper, old hour');
process.exit(0);
