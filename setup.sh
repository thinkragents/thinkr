#!/usr/bin/env bash
# Everything needed to build and test from a clean checkout. No deploy.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> site"
npm install

echo "==> contracts"
cd contracts
[ -d lib/forge-std ] || forge install foundry-rs/forge-std --no-git
[ -d lib/openzeppelin-contracts ] || forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
forge build
cd ..

echo "==> sdk + api + mcp"
(cd contracts/sdk && npm install)
(cd api && npm install)
(cd mcp && npm install)

echo
echo "run the tests:"
echo "  cd contracts && forge test"
echo "  cd contracts/sdk && npm test"
echo "  bash api/test/anvil-up.sh      # local chain, then:"
echo "  cd api && npm test"
