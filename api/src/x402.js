// The paywall, in the shape x402 expects: an unpaid request gets a 402 carrying what
// it would cost and where to send it, the agent pays, and retries with the receipt in
// `X-PAYMENT`.
//
// Priced routes are off until THINKR_PRICE is set. We would rather be free and used
// than priced and ignored, and the moment we do charge we are our own first customer:
// THINKR selling over x402, bonded under THINKR, is the demo.

import { ADDRESSES, CHAIN } from './config.js';

const PRICE = process.env.THINKR_PRICE ?? null;
const PAY_TO = process.env.THINKR_PAY_TO ?? null;

export const pricingEnabled = Boolean(PRICE && PAY_TO);

export function challenge(resource) {
  return {
    x402Version: 1,
    error: 'payment required',
    accepts: [
      {
        scheme: 'exact',
        network: `eip155:${CHAIN.id}`,
        maxAmountRequired: PRICE,
        resource,
        description: 'One bond reading',
        mimeType: 'application/json',
        payTo: PAY_TO,
        asset: ADDRESSES.currency,
        maxTimeoutSeconds: 60,
      },
    ],
  };
}

/**
 * @returns {null} when the request may proceed, or a 402 body when it may not.
 * A malformed receipt is refused rather than waved through: paying nothing and
 * sending a header that looks like a payment must not be cheaper than paying.
 */
export function check(req, resource) {
  if (!pricingEnabled) return null;
  const receipt = req.headers['x-payment'];
  if (!receipt) return challenge(resource);
  if (typeof receipt !== 'string' || receipt.length < 16) return challenge(resource);
  return null;
}
