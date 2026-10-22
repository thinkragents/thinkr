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
  const priced = await api('GET', '/v1/bond/1?amount=40000');
  assert.equal(priced.claimable, false, 'nothing posted, nothing to claim against');
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
  // 500 posted, so claims start at 5. A 50 job is covered, a 600 job is not, and
  // a 1 call is safe to make but too small to claim: the bond vouches for the
  // seller, it just cannot be claimed against for that amount.
  const fits = await api('GET', '/v1/bond/1?amount=50000000');
  assert.equal(fits.safeToPay, true);
  assert.equal(fits.covers, true);

  const big = await api('GET', '/v1/bond/1?amount=600000000');
  assert.equal(big.safeToPay, false, 'a bond smaller than the payment is not cover for it');
  assert.equal(big.covers, false);

  const tiny = await api('GET', '/v1/bond/1?amount=1000000');
  assert.equal(tiny.safeToPay, true, 'a bigger bond must never read as less safe');
  assert.equal(tiny.claimable, false, 'below the claim floor there is no recourse');
});

test('a seller that answers keeps its money', async () => {
  const deliveries = deliveriesFor(5);
  const { epoch } = await api('GET', '/v1/bond/1');

  await jump(HOUR + 60);
  const attested = await api('POST', '/v1/attest', { agentId: 1, epoch, deliveries });
  assert.match(attested.root, /^0x[0-9a-f]{64}$/);
  assert.ok(BigInt(attested.cost.wei) > 0n, `the seal is priced before it is signed: ${JSON.stringify(attested.cost)}`);
  await sendAll(attested, SELLER);

  await jump(HOUR + 60); // the root is now final, claims open

  const quote = await api('POST', '/v1/claim', {
    agentId: 1,
    ref: deliveries[2].ref,
    epoch,
    amount: '100000000',
  });
  assert.equal(quote.stake, '2000000', '2% of 100');
  await sendAll(quote, BUYER);

  const open = await api('GET', '/v1/claims/1');
  assert.equal(open.summary.open, 1);
  assert.equal((await api('GET', '/v1/bond/1')).reserved, '100000000');

  // The seller sends back the same list it attested; the API finds the proof.
  const answer = await api('POST', '/v1/claim/1/discharge', {
    ref: deliveries[2].ref,
    deliveries,
  });
  assert.equal(answer.root, attested.root);
  await sendAll(answer, SELLER);

  const after = await api('GET', '/v1/claims/1');
  assert.equal(after.summary.discharged, 1);
  assert.equal(after.summary.open, 0);

  const bond = await api('GET', '/v1/bond/1');
  assert.equal(bond.reserved, '0');
  assert.equal(bond.bonded, '502000000', "the junk claim paid the seller its claimant's stake");
});

test('a seller that goes quiet pays out', async () => {
  const { epoch } = await api('GET', '/v1/bond/1');
  await jump(2 * HOUR + 120); // the epoch passes with nothing attested

  const quote = await api('POST', '/v1/claim', {
    agentId: 1,
    ref: keccak256(toHex('paid-for-nothing')),
    epoch,
    amount: '100000000',
  });
  await sendAll(quote, BUYER);

  const before = await pub.getBalance({ address: BUYER.address }).then(() => api('GET', '/v1/bond/1'));
  await jump(48 * HOUR + 60);
  await sendAll(await api('POST', '/v1/claim/2/settle'), BUYER);

  const after = await api('GET', '/v1/bond/1');
  assert.equal(BigInt(before.bonded) - BigInt(after.bonded), 100000000n, 'the bond paid the claim');
  assert.equal((await api('GET', '/v1/claims/1')).summary.paid, 1);
});

test('a discharge with the wrong delivery list is refused before it costs gas', async () => {
  await assert.rejects(
    () => api('POST', '/v1/claim/1/discharge', { ref: keccak256(toHex('x')), deliveries: deliveriesFor(3) }),
    /does not contain ref/
  );
});

test('a claim larger than the bond is refused before it costs gas', async () => {
  const { epoch } = await api('GET', '/v1/bond/1');
  await assert.rejects(
    () => api('POST', '/v1/claim', { agentId: 1, ref: keccak256(toHex('big')), epoch, amount: '99999000000' }),
    /will not cover/
  );
});

test('bad input is rejected with a reason, not a stack trace', async () => {
  await assert.rejects(() => api('POST', '/v1/claim', { agentId: 1, ref: 'nope', epoch: 1, amount: '1' }), /32-byte hex/);
  await assert.rejects(() => api('POST', '/v1/attest', { agentId: 1, epoch: 1, deliveries: [] }), /non-empty array/);
});

test('the claim floor is a share of the bond, not a fixed number', async () => {
  const { epoch, minClaim, bonded } = await api('GET', '/v1/bond/1');
  // 1% of whatever is posted, so it fits today's payments and tomorrow's.
  assert.equal(BigInt(minClaim), BigInt(bonded) / 100n);
  await assert.rejects(
    () => api('POST', '/v1/claim', {
      agentId: 1, ref: keccak256(toHex('tiny')), epoch,
      amount: (BigInt(minClaim) - 1n).toString(),
    }),
    /smallest claim this contract accepts/
  );
});
