// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ThinkrBonds} from "../src/ThinkrBonds.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {MockUSDG} from "../test/mocks/MockUSDG.sol";

/// @notice Robinhood Chain testnet, 46630. The real ERC-8004 registry, a stand in for
///         USDG (which is not on testnet), and the mainnet parameters, so a run here
///         rehearses exactly what Deploy.s.sol will put on 4663.
contract TestnetScript is Script {
    uint256 internal constant ROBINHOOD_TESTNET = 46630;

    /// @dev ERC-8004 identity registry at its testnet address. Checked 2026-10-22:
    ///      AgentIdentity v2.0.0.
    address internal constant REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    uint128 internal constant MIN_BOND = 1e6;
    uint128 internal constant MIN_CLAIM_BOND = 1e4;

    function run() external {
        require(block.chainid == ROBINHOOD_TESTNET, "not Robinhood Chain testnet");
        require(REGISTRY.code.length != 0, "no registry at that address");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        MockUSDG usdg = new MockUSDG();
        ThinkrBonds bonds = new ThinkrBonds(
            IIdentityRegistry(REGISTRY), IERC20(address(usdg)), MIN_BOND, MIN_CLAIM_BOND
        );
        vm.stopBroadcast();

        console.log("THINKR_REGISTRY=%s", REGISTRY);
        console.log("THINKR_CURRENCY=%s", address(usdg));
        console.log("THINKR_BONDS=%s", address(bonds));
    }
}
