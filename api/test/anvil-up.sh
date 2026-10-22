#!/usr/bin/env bash
# Local only. Starts anvil and deploys the mocks plus ThinkrBonds, then prints the
# environment the API needs. Nothing here touches a public network.
set -euo pipefail
cd "$(dirname "$0")/../.."

pkill -f "anvil --silent --port 8545" 2>/dev/null || true
sleep 1
anvil --silent --port 8545 --block-time 1 >/tmp/anvil.log 2>&1 &
sleep 3

export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export BUYER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

cd contracts
forge script script/Local.s.sol --rpc-url http://127.0.0.1:8545 --broadcast 2>&1 \
  | grep -oE "THINKR_[A-Z]+=0x[0-9a-fA-F]{40}"
