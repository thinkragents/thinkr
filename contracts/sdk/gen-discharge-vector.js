// Builds a tree in JavaScript and writes the root and one proof for the Solidity
// test to replay. If the SDK and the contract ever disagree, the discharge in
// test/SdkParity.t.sol reverts and the suite fails. That is the only check that
// catches a drift in either direction.
import { writeFileSync } from 'node:fs';
import { leaf, build, proof } from './tree.js';

const h = (n) => `0x${n.toString(16).padStart(64, '0')}`;
const deliveries = Array.from({ length: 7 }, (_, i) => ({
  ref: h(0xaa00 + i),
  digest: h(0xbb00 + i),
}));

const leaves = deliveries.map((d) => leaf(d.ref, d.digest));
const tree = build(leaves);
const target = 3;

writeFileSync(
  new URL('./discharge-vector.json', import.meta.url),
  `${JSON.stringify(
    {
      root: tree.root,
      ref: deliveries[target].ref,
      digest: deliveries[target].digest,
      proof: proof(tree, leaves[target]),
    },
    null,
    2
  )}\n`
);
