// The MCP surface, driven through a real client over an in-memory transport. Proves
// the tools are registered, described, and answering from the same chain the API reads.

import test from 'node:test';
import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createThinkrServer } from '../src/server.js';

async function connect() {
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: 'test', version: '0' });
  await Promise.all([createThinkrServer().connect(serverSide), client.connect(clientSide)]);
  return client;
}

test('every operation is exposed, and the read-only ones say so', async () => {
  const client = await connect();
  const { tools } = await client.listTools();
  const names = tools.map((t) => t.name).sort();
  assert.deepEqual(names, [
    'attest_deliveries',
    'check_bond',
    'check_claims',
    'discharge_claim',
    'file_claim',
    'post_bond',
    'settle_claim',
  ]);
  assert.equal(tools.find((t) => t.name === 'check_bond').annotations.readOnlyHint, true);
  assert.equal(tools.find((t) => t.name === 'post_bond').annotations.readOnlyHint, false);
});

test('every tool says when to reach for it, not just what it returns', async () => {
  const client = await connect();
  const { tools } = await client.listTools();
  for (const t of tools) {
    assert.ok(t.description.length > 80, `${t.name} needs a real description`);
    assert.ok(t.inputSchema, `${t.name} needs a schema`);
  }
});

test('check_bond reads the live chain', async () => {
  const client = await connect();
  const res = await client.callTool({ name: 'check_bond', arguments: { agentId: 1 } });
  const bond = JSON.parse(res.content[0].text);
  assert.equal(bond.agentId, '1');
  assert.equal(typeof bond.safeToPay, 'boolean');
  assert.ok(['active', 'unbonded', 'winding_down'].includes(bond.status));
});

test('a failure comes back marked, never as a clean answer', async () => {
  const client = await connect();
  const res = await client.callTool({
    name: 'file_claim',
    arguments: { agentId: 1, ref: '0xdeadbeef', epoch: 1, amount: '1' },
  });
  assert.equal(res.isError, true, 'an agent must not read a failure as a bond it can trust');
  assert.match(res.content[0].text, /32-byte hex/);
});
