import { createPublicClient, defineChain, http } from 'viem';
import { CHAIN } from './config.js';

export const robinhood = defineChain({
  id: CHAIN.id,
  name: CHAIN.name,
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [CHAIN.rpc] } },
  blockExplorers: { default: { name: 'Blockscout', url: CHAIN.explorer } },
});

// One client, reused. The public RPC rate limits aggressively, so batching matters:
// a bond read is four calls and an agent checking before it pays wants one round trip.
export const client = createPublicClient({
  chain: robinhood,
  transport: http(CHAIN.rpc, { batch: true, retryCount: 4, retryDelay: 400 }),
});
