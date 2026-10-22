// Rewrites bondsAbi in src/abi.js from the compiled contract, so the API can never
// describe a different contract from the one deployed. Run after `forge build`.
import { readFileSync, writeFileSync } from 'node:fs';
const out = new URL('../../contracts/out/ThinkrBonds.sol/ThinkrBonds.json', import.meta.url);
const file = new URL('../src/abi.js', import.meta.url);
const { abi } = JSON.parse(readFileSync(out));
const src = readFileSync(file, 'utf8');
const start = src.indexOf('// Generated from');
const end = src.indexOf('];', src.indexOf('export const bondsAbi')) + 2;
writeFileSync(file, src.slice(0, start) +
  '// Generated from contracts/out/ThinkrBonds.sol/ThinkrBonds.json (version 2). Do not edit\n' +
  '// by hand: rebuild the contract and run `node scripts/gen-abi.mjs` in api/.\n' +
  `export const bondsAbi = ${JSON.stringify(abi, null, 2)};` + src.slice(end));
console.log(`bondsAbi: ${abi.length} entries`);
