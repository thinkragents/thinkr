// The delivery tree. This file and ThinkrBonds.sol must agree exactly, so the
// convention is stated once and tested against the contract in sdk/tree.test.js.
//
//   leaf  = keccak256(keccak256(abi.encode(ref, digest)))
//   node  = keccak256(sorted(left, right))
//
// Double-hashed leaves, sorted pairs. Same as OpenZeppelin MerkleProof and
// merkletreejs, so a proof built here verifies on chain unchanged.
//
// `ref` is what both sides call the transaction: an x402 payment, an action_ref,
// a Tersign receipt id. `digest` is the evidence the seller holds, in any format
// and under any hash. The contract reads neither, it only proves the pair was
// sealed before the claim window opened. toRef and toDigest turn other formats
// into the two 32-byte values without changing the evidence itself.

import { keccak_256 } from '@noble/hashes/sha3';
import { bytesToHex, hexToBytes, concatBytes, utf8ToBytes } from '@noble/hashes/utils';

const hex = (b) => `0x${bytesToHex(b)}`;
const bytes = (h) => hexToBytes(h.replace(/^0x/, '').padStart(64, '0'));

const HEX32 = /^(0x)?[0-9a-fA-F]{64}$/;
const keccakHex = (b) => hex(keccak_256(b));

/**
 * A 32-byte ref from any identifier. Anything already 32 bytes of hex goes in as
 * it is, so an action_ref (SHA-256), a transaction hash or a Tersign id needs no
 * rehash and stays recomputable by whoever issued it. Anything else, a Fly
 * evidence_id UUID for example, is keccak256 of its UTF-8 bytes.
 */
export function toRef(id) {
  if (typeof id !== 'string' || id.length === 0) throw new Error('a ref is a non-empty string');
  return HEX32.test(id) ? `0x${id.replace(/^0x/, '').toLowerCase()}` : keccakHex(utf8ToBytes(id));
}

/**
 * A 32-byte digest of the evidence. A digest the format already computed passes
 * through. Raw bytes and strings are hashed as they are. An object is hashed as
 * RFC 8785 canonical JSON, so the same envelope gives the same digest whatever
 * order its keys were written in.
 */
export function toDigest(evidence) {
  if (evidence instanceof Uint8Array) return keccakHex(evidence);
  if (typeof evidence === 'string') {
    return HEX32.test(evidence) ? `0x${evidence.replace(/^0x/, '').toLowerCase()}` : keccakHex(utf8ToBytes(evidence));
  }
  if (evidence !== null && typeof evidence === 'object') return keccakHex(utf8ToBytes(canonical(evidence)));
  throw new Error('evidence is bytes, a string or a JSON object');
}

/** RFC 8785 JSON canonicalization. ES number and string serialization is what the RFC specifies. */
export function canonical(v) {
  if (v === null || typeof v !== 'object') {
    if (typeof v === 'number' && !Number.isFinite(v)) throw new Error('JSON has no NaN or Infinity');
    if (v === undefined) throw new Error('JSON has no undefined');
    return JSON.stringify(v);
  }
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  // RFC 8785 sorts by UTF-16 code units, which is what the default sort compares.
  const keys = Object.keys(v).filter((k) => v[k] !== undefined).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`;
}

/** A leaf for one delivery. Both arguments are 32-byte hex strings. */
export function leaf(ref, digest) {
  return hex(keccak_256(keccak_256(concatBytes(bytes(ref), bytes(digest)))));
}

function hashPair(a, b) {
  const [x, y] = a.toLowerCase() <= b.toLowerCase() ? [a, b] : [b, a];
  return hex(keccak_256(concatBytes(bytes(x), bytes(y))));
}

/**
 * Build the tree for one epoch.
 * @param {string[]} leaves 32-byte hex leaves, in any order
 * @returns {{root: string, layers: string[][]}}
 */
export function build(leaves) {
  if (leaves.length === 0) throw new Error('an epoch with no deliveries has no root');
  const layers = [[...leaves].sort()];
  while (layers.at(-1).length > 1) {
    const prev = layers.at(-1);
    const next = [];
    for (let i = 0; i < prev.length; i += 2) {
      // An odd node is carried up untouched, which is what OpenZeppelin verifies.
      next.push(i + 1 < prev.length ? hashPair(prev[i], prev[i + 1]) : prev[i]);
    }
    layers.push(next);
  }
  return { root: layers.at(-1)[0], layers };
}

/** The proof for one leaf, in the order the contract consumes it. */
export function proof(tree, target) {
  let index = tree.layers[0].indexOf(target);
  if (index === -1) throw new Error('that leaf is not in this tree');
  const out = [];
  for (let d = 0; d < tree.layers.length - 1; d++) {
    const layer = tree.layers[d];
    const sibling = index % 2 === 0 ? index + 1 : index - 1;
    if (sibling < layer.length) out.push(layer[sibling]);
    index = Math.floor(index / 2);
  }
  return out;
}

/** Verify locally before spending gas on a discharge that would revert. */
export function verify(prf, root, target) {
  return prf.reduce(hashPair, target) === root;
}
