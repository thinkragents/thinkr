// One small HTTP server. No framework, no database, nothing scheduled: it reads the
// chain and builds calldata, so it costs nothing when nobody is asking.

import { createServer } from 'node:http';
import { ADDRESSES, CHAIN, NotDeployed } from './config.js';
import * as h from './handlers.js';
import { check, pricingEnabled } from './x402.js';

const PORT = Number(process.env.PORT ?? 8402);

// path, written the way it is documented; the matcher is derived from it.
const routes = [
  ['GET', '/v1/bond/:agentId', 'what a buyer reads before it pays; add ?amount= for that payment', ({ params, query }) =>
    h.getBond(params.agentId, query.get('amount') ?? undefined)],
  ['GET', '/v1/claims/:agentId', 'an agent\'s claim record', ({ params }) => h.getClaims(params.agentId)],
  ['GET', '/v1/claim/:claimId', 'one claim', ({ params }) => h.getClaim(params.claimId)],
  ['GET', '/v1/agent/:agentId', 'who owns an agent, per ERC-8004', ({ params }) => h.getAgentOwner(params.agentId)],
  ['POST', '/v1/bond', 'post or top up collateral', ({ body }) => h.buildBond(body)],
  ['POST', '/v1/attest', 'commit an epoch of deliveries', ({ body }) => h.buildAttest(body)],
  ['POST', '/v1/claim', 'file a claim', ({ body }) => h.buildClaim(body)],
  ['POST', '/v1/claim/:claimId/discharge', 'answer a claim with a proof', ({ params, body }) =>
    h.buildDischarge({ ...body, claimId: params.claimId })],
  ['POST', '/v1/claim/:claimId/settle', 'pay out a claim the seller let run', ({ params }) =>
    h.buildSettle({ claimId: params.claimId })],
].map(([method, path, summary, handler]) => ({
  method,
  path,
  summary,
  handler,
  pattern: new RegExp(`^${path.replace(/:(\w+)/g, '(?<$1>[^/]+)')}$`),
}));

const index = {
  service: 'THINKR',
  description: 'Performance bonds for agents that take payment over x402.',
  chain: { id: CHAIN.id, name: CHAIN.name, explorer: CHAIN.explorer },
  contracts: { registry: ADDRESSES.registry, bonds: ADDRESSES.bonds },
  priced: pricingEnabled,
  endpoints: routes.map((r) => ({ method: r.method, path: r.path, summary: r.summary })),
  source: 'https://github.com/thinkragents/thinkr',
};

function send(res, status, body) {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type, x-payment',
    'cache-control': status === 200 ? 'public, max-age=5' : 'no-store',
  });
  res.end(payload);
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    const e = new Error('the request body is not valid JSON');
    e.status = 400;
    e.code = 'bad_request';
    throw e;
  }
}

export const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);

  if (req.method === 'OPTIONS') return send(res, 204, {});
  if (url.pathname === '/' || url.pathname === '/v1') return send(res, 200, index);
  if (url.pathname === '/health') return send(res, 200, { ok: true });

  const route = routes.find((r) => r.method === req.method && r.pattern.test(url.pathname));
  if (!route) return send(res, 404, { error: 'no such endpoint', code: 'not_found', see: '/' });

  const params = url.pathname.match(route.pattern).groups ?? {};

  const owed = check(req, url.pathname);
  if (owed) return send(res, 402, owed);

  try {
    const body = req.method === 'POST' ? await readBody(req) : {};
    send(res, 200, await route.handler({ params, body, query: url.searchParams }));
  } catch (err) {
    const status = err.status ?? (err instanceof NotDeployed ? 503 : 500);
    if (status === 500) console.error(err);
    send(res, status, {
      error: err.message,
      code: err.code ?? 'internal_error',
      ...(err instanceof NotDeployed ? { chain: CHAIN.name } : {}),
    });
  }
});

if (import.meta.url === `file://${process.argv[1]}`) {
  server.listen(PORT, () => {
    console.log(`THINKR api on :${PORT}  chain ${CHAIN.id}  bonds ${ADDRESSES.bonds ?? 'not deployed'}`);
  });
}
