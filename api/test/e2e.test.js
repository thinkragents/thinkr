// Drives the whole stack against a local anvil: the API builds every transaction,
// a wallet signs and sends it, and the chain is read back through the API again.
// Nothing is mocked except the token and the identity registry.
//
// Run `bash test/anvil-up.sh` first; it prints the three addresses this expects.

import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createPublicClient, createWalletClient, defineChain, http, keccak256, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const RPC = 'http://127.0.0.1:8545';
const API = `http://127.0.0.1:${process.env.TEST_PORT ?? 8405}`;

const anvil = defineChain({
  id: 31337,
  name: 'anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const SELLER = privateKeyToAccount('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
const BUYER = privateKeyToAccount('0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d');

const pub = createPublicClient({ chain: anvil, transport: http(RPC) });
const wallet = (account) => createWalletClient({ account, chain: anvil, transport: http(RPC) });

let server;

before(async () => {
  ({ server } = await import('../src/server.js'));
  await new Promise((r) => server.listen(Number(process.env.TEST_PORT ?? 8405), r));
});

after(() => server?.close());

async function api(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: body ? { 'content-type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${json.error}`);
  return json;
}

/** Send every transaction the API handed back, in order, and wait for each. */
async function sendAll({ transactions }, account) {
  const w = wallet(account);
  for (const t of transactions) {
    const hash = await w.sendTransaction({ to: t.to, data: t.data, value: 0n });
    const receipt = await pub.waitForTransactionReceipt({ hash });
    assert.equal(receipt.status, 'success', t.note);
  }
}

async function jump(seconds) {
  await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'evm_increaseTime', params: [seconds] }),
  });
  await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'evm_mine', params: [] }),
  });
}

async function usdgBalance(address) {
  const currency = (await api('GET', '/')).contracts.currency;
  return pub.readContract({
    address: currency,
    abi: [{ type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] }],
    functionName: 'balanceOf',
    args: [address],
  });
}

const HOUR = 3600;
const deliveriesFor = (n) =>
  Array.from({ length: n }, (_, i) => ({
    ref: keccak256(toHex(`payment-${n}-${i}`)),
    digest: keccak256(toHex(`response-${n}-${i}`)),
  }));

// --------------------------------------------------------------------------

test('an unbonded agent reads as unbonded, not as an error', async () => {
  const bond = await api('GET', '/v1/bond/1');
  assert.equal(bond.status, 'unbonded');
  assert.equal(bond.safeToPay, false, 'nobody should pay an agent with nothing posted');
});

test('posting a bond, through the API, end to end', async () => {
  await sendAll(await api('POST', '/v1/bond', { agentId: 1, amount: '500000000' }), SELLER);

  const bond = await api('GET', '/v1/bond/1');
  assert.equal(bond.bonded, '500000000');
  assert.equal(bond.available, '500000000');
  assert.equal(bond.status, 'active');
  assert.equal(bond.safeToPay, true);

  const register = await api('GET', '/v1/bonds');
  assert.equal(register.count, 1, 'the register lists every agent ever bonded');
  assert.equal(register.bonds[0].agentId, '1');
  assert.equal(register.bonds[0].claims.filed, 0);
});

test('safeToPay is about the payment when the buyer names one', async () => {
  const fits = await api('GET', '/v1/bond/1?amount=50000000');
  assert.equal(fits.safeToPay, true);
  assert.equal(fits.covers, true);
  assert.equal(fits.payWith, 'POST /v1/pay');

  const big = await api('GET', '/v1/bond/1?amount=600000000');
  assert.equal(big.safeToPay, false, 'a bond smaller than the payment is not cover for it');
  assert.equal(big.covers, false);
});

/** Pay agent 1 through THINKR from the buyer. Returns the hour it was paid in. */
async function pay(ref, amount) {
  const quote = await api('POST', '/v1/pay', { agentId: 1, ref, amount });
  await sendAll(quote, BUYER);
  const { epoch } = await api('GET', '/v1/bond/1');
  return epoch;
}

test('a seller that answers keeps its money', async () => {
  const deliveries = deliveriesFor(5);
  const sellerBefore = await usdgBalance(SELLER.address);
  const epoch = await pay(deliveries[2].ref, '100000000');
  assert.equal(await usdgBalance(SELLER.address) - sellerBefore, 100000000n, 'the payment went straight to the seller');

  // the seller reads what it was paid for this hour, which is what it seals
  const paid = await api('GET', `/v1/payments/1?epoch=${epoch}`);
  assert.equal(paid.count, 1);
  assert.equal(paid.payments[0].ref, deliveries[2].ref);

  await jump(HOUR + 60);
  const attested = await api('POST', '/v1/attest', { agentId: 1, epoch, deliveries });
  assert.match(attested.root, /^0x[0-9a-f]{64}$/);
  assert.ok(BigInt(attested.cost.wei) > 0n, `the seal is priced before it is signed: ${JSON.stringify(attested.cost)}`);
  await sendAll(attested, SELLER);

  // the seal is now evidence anyone can check, without trusting the seller or us
  const seals = await api('GET', '/v1/seals/1');
  assert.equal(seals.hoursSealed, 1);
  assert.equal(seals.lastSealed, epoch);
  const ok = await api('POST', '/v1/verify', { agentId: 1, epoch, ref: deliveries[2].ref, digest: deliveries[2].digest, deliveries });
  assert.equal(ok.sealed, true);
  assert.ok(ok.sealedAt, 'and when it was sealed');
  const tampered = await api('POST', '/v1/verify', { agentId: 1, epoch, ref: deliveries[2].ref, digest: keccak256(toHex('a different file')), proof: [] });
  assert.equal(tampered.sealed, false, 'a delivery that was not sealed does not verify');

  await jump(2 * HOUR + 60); // both hours the seller could seal in are final: claims open

  const quote = await api('POST', '/v1/claim', { agentId: 1, ref: deliveries[2].ref, from: BUYER.address });
  assert.equal(quote.amount, '100000000', 'the claim is for what was paid');
  assert.equal(quote.stake, '2000000', '2% of 100');
  await sendAll(quote, BUYER);

  assert.equal((await api('GET', '/v1/claims/1')).summary.open, 1);
  assert.equal((await api('GET', '/v1/bond/1')).reserved, '100000000');

  // The seller sends back the same list it sealed; the API finds the hour and the proof.
  const answer = await api('POST', '/v1/claim/1/discharge', { deliveries });
  assert.equal(answer.root, attested.root);
  assert.equal(answer.sealedIn, epoch);
  await sendAll(answer, SELLER);

  const after = await api('GET', '/v1/claims/1');
  assert.equal(after.summary.discharged, 1);
  assert.equal(after.summary.open, 0);
  const bond = await api('GET', '/v1/bond/1');
  assert.equal(bond.reserved, '0');
  assert.equal(bond.bonded, '502000000', "a claim on delivered work paid the seller the claimant's stake");
});

test('a seller that goes quiet pays out', async () => {
  const ref = keccak256(toHex('paid-for-nothing'));
  await pay(ref, '100000000');
  await jump(3 * HOUR + 120); // the hours pass with nothing sealed

  await sendAll(await api('POST', '/v1/claim', { agentId: 1, ref, from: BUYER.address }), BUYER);
  const before = await api('GET', '/v1/bond/1');
  await jump(48 * HOUR + 60);
  await sendAll(await api('POST', '/v1/claim/2/settle'), BUYER);

  const after = await api('GET', '/v1/bond/1');
  assert.equal(BigInt(before.bonded) - BigInt(after.bonded), 100000000n, 'the bond paid the claim');
  assert.equal((await api('GET', '/v1/claims/1')).summary.paid, 1);
});

test('a claim on a payment that never happened is refused', async () => {
  await assert.rejects(
    () => api('POST', '/v1/claim', { agentId: 1, ref: keccak256(toHex('never paid')), from: BUYER.address }),
    /no payment from/
  );
});

test("nobody can claim someone else's payment", async () => {
  const ref = keccak256(toHex('a buyers order'));
  await pay(ref, '1000000');
  await jump(3 * HOUR + 120);
  await assert.rejects(
    () => api('POST', '/v1/claim', { agentId: 1, ref, from: SELLER.address }),
    /no payment from/
  );
});

test('a discharge with the wrong delivery list is refused before it costs gas', async () => {
  await assert.rejects(
    () => api('POST', '/v1/claim/1/discharge', { deliveries: deliveriesFor(3) }),
    /is discharged|does not contain ref/
  );
});

test('a claim larger than the bond is refused before it costs gas', async () => {
  const ref = keccak256(toHex('big'));
  await pay(ref, '450000000');
  await jump(3 * HOUR + 120);
  await assert.rejects(() => api('POST', '/v1/claim', { agentId: 1, ref, from: BUYER.address }), /will not cover/);
});

test('bad input is rejected with a reason, not a stack trace', async () => {
  await assert.rejects(() => api('POST', '/v1/claim', { agentId: 1, ref: 'nope', from: BUYER.address }), /32-byte hex/);
  await assert.rejects(() => api('POST', '/v1/claim', { agentId: 1, ref: keccak256(toHex('x')), from: 'nope' }), /must be an address/);
  await assert.rejects(() => api('POST', '/v1/attest', { agentId: 1, epoch: 1, deliveries: [] }), /non-empty array/);
});

test('registering an agent is one transaction for the seller to sign', async () => {
  const r = await api('POST', '/v1/register', { agentURI: 'https://example.com/agent.json' });
  assert.equal(r.transactions.length, 1);
  await assert.rejects(() => api('POST', '/v1/register', { agentURI: '' }), /agent card/);
});
