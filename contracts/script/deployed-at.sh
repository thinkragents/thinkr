#!/usr/bin/env bash
# Prints THINKR_DEPLOYED_AT for the API, from the deploy receipt.
# On Robinhood Chain (Arbitrum Orbit) block.number inside a contract is the L1 block,
# so the script cannot print this itself. The receipt has the real L2 block.
#   bash script/deployed-at.sh Deploy.s.sol 4663
set -euo pipefail
cd "$(dirname "$0")/.."
f="broadcast/$1/$2/run-latest.json"
python3 -c "import json,sys; r=json.load(open('$f'))['receipts']; print('THINKR_DEPLOYED_AT=%d' % min(int(x['blockNumber'],16) for x in r))"
