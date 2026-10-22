// Everything that changes between networks lives here and nowhere else.
//
// `bonds` is intentionally unset until the contract is deployed. Every read path
// checks it and says so plainly rather than returning a confident zero, because a
// bond of zero and a bond we cannot see are very different answers to give an agent
// that is deciding whether to pay someone.

export const CHAIN = {
  // Overridable so the whole stack can be driven against a local anvil in tests.
  // Nothing else in the service knows which network it is on.
  id: Number(process.env.THINKR_CHAIN_ID ?? 4663),
  name: process.env.THINKR_CHAIN_NAME ?? 'Robinhood Chain',
  rpc: process.env.THINKR_RPC ?? 'https://rpc.mainnet.chain.robinhood.com',
  explorer: 'https://robinhoodchain.blockscout.com',
};

export const ADDRESSES = {
  // ERC-8004 identity registry, verified live on 4663 at the deterministic address.
  registry: process.env.THINKR_REGISTRY ?? '0x8004A169FB4a3325136EB29fA0ceB6D2e539a432',
    // ThinkrBonds on Robinhood Chain mainnet, deployed 2026-10-22. Overridable so the
  // tests and the testnet rehearsal can point the same code at their own deploys.
  bonds: process.env.THINKR_BONDS ?? '0xD5e4643e7E20c987a3da124b05a54cae57de9DDA',
  // USDG, the collateral token it was deployed with.
  currency: process.env.THINKR_CURRENCY ?? '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',
  // The block ThinkrBonds was deployed in. Claim history is read from events, and no
  // public RPC will search a hundred million blocks from genesis, so reads start here.
  deployedAt: BigInt(process.env.THINKR_DEPLOYED_AT ?? 94996670),
};

export class NotDeployed extends Error {
  constructor(what) {
    super(`${what} is not deployed on ${CHAIN.name} yet`);
    this.status = 503;
    this.code = 'not_deployed';
  }
}

export function requireBonds() {
  if (!ADDRESSES.bonds) throw new NotDeployed('ThinkrBonds');
  return ADDRESSES.bonds;
}
