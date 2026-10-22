// One small HTTP server. No framework, no database, nothing scheduled: it reads the
// chain and builds calldata, so it costs nothing when nobody is asking.

import { createServer } from 'node:http';
import * as demo from './demo.js';
import { ADDRESSES, CHAIN, NotDeployed } from './config.js';
import * as h from './handlers.js';
import { check, pricingEnabled } from './x402.js';

const PORT = Number(process.env.PORT ?? 8402);

// path, written the way it is documented; the matcher is derived from it.
const routes = [
  ['GET', '/v1/bond/:agentId', 'what a buyer reads before it pays; add ?amount= for that payment', ({ params, query }) =>
    h.getBond(params.agentId, query.get('amount') ?? undefined)],
  ['GET', '/v1/bonds', 'every agent ever bonded, with its bond now', () => h.listBonds()],
  ['GET', '/v1/demo/deliveries/:epoch', "the answers THINKR's demo agent sealed in an hour", ({ params }) =>
    demo.deliveriesFor(params.epoch)],
    ['GET', '/v1/stats', 'hours sealed and agents sealing, network wide', () => h.getStats()],
  ['GET', '/v1/seals/:agentId', 'how many hours an agent has sealed, and when', ({ params }) => h.getSeals(params.agentId)],
  ['POST', '/v1/verify', 'was this delivery sealed, and when', ({ body }) => h.verifySeal(body)],
  ['POST', '/v1/register', 'register an agent in the ERC-8004 registry', ({ body }) => h.buildRegister(body)],
  ['GET', '/v1/claims/:agentId', 'an agent\'s claim record', ({ params }) => h.getClaims(params.agentId)],
  ['GET', '/v1/claim/:claimId', 'one claim', ({ params }) => h.getClaim(params.claimId)],
  ['GET', '/v1/agent/:agentId', 'who owns an agent, per ERC-8004', ({ params }) => h.getAgentOwner(params.agentId)],
  ['POST', '/v1/bond', 'post or top up collateral', ({ body }) => h.buildBond(body)],
  ['POST', '/v1/attest', 'commit an epoch of deliveries', ({ body }) => h.buildAttest(body)],
  ['POST', '/v1/pay', 'pay an agent through THINKR, so the payment can be claimed', ({ body }) => h.buildPay(body)],
  ['GET', '/v1/payments/:agentId', 'payments an agent took; add ?epoch= for one hour', ({ params, query }) =>
    h.listPayments(params.agentId, query.get('epoch') ?? undefined)],
  ['POST', '/v1/claim', 'file a claim on a payment you made through THINKR', ({ body }) => h.buildClaim(body)],
  ['POST', '/v1/collect', 'collect what you are owed, to yourself or another address', ({ body }) => h.buildCollect(body)],
  ['POST', '/v1/sealer', 'appoint a key to seal for your agent', ({ body }) => h.buildSetSealer(body)],
  ['POST', '/v1/release/:agentId', "free a seller's cover held for expired payments", ({ params }) => h.buildRelease(params.agentId)],
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
  description: 'Sealed evidence with money behind it, for agent commerce: bonds and hourly delivery seals on Robinhood Chain.',
  chain: { id: CHAIN.id, name: CHAIN.name, explorer: CHAIN.explorer },
  contracts: { registry: ADDRESSES.registry, bonds: ADDRESSES.bonds, currency: ADDRESSES.currency },
  priced: pricingEnabled,
  endpoints: routes.map((r) => ({ method: r.method, path: r.path, summary: r.summary })),
  source: 'https://github.com/thinkragents/thinkr',
};

function send(res, status, body, { seal = false } = {}) {
  const payload = JSON.stringify(body, null, 2);
  // THINKR's demo agent seals the answers it gives; the headers say how to find them
  const sealed = seal && status === 200 ? demo.record(payload) : {};
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type, x-payment',
    'access-control-expose-headers': 'x-thinkr-agent, x-thinkr-epoch, x-thinkr-ref, x-thinkr-digest',
    'cache-control': status === 200 && !sealed['x-thinkr-ref'] ? 'public, max-age=5' : 'no-store',
    ...sealed,
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
    send(res, 200, await route.handler({ params, body, query: url.searchParams }), {
      seal: req.method === 'GET' && !url.pathname.startsWith('/v1/demo'),
    });
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
  demo.startDemoSealer();
  server.listen(PORT, () => {
    console.log(`THINKR api on :${PORT}  chain ${CHAIN.id}  bonds ${ADDRESSES.bonds ?? 'not deployed'}`);
  });
}
