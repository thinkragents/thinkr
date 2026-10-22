// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ThinkrBonds} from "../src/ThinkrBonds.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {MockUSDG} from "../test/mocks/MockUSDG.sol";
import {MockRegistry} from "../test/mocks/MockRegistry.sol";

/// @notice Stands the whole thing up on a local anvil so the API and the MCP server
///         can be driven end to end before anything is deployed to a real network.
///         Mocks only. Never point this at a public chain.
contract LocalScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address seller = vm.addr(pk);
        address buyer = vm.addr(vm.envUint("BUYER_KEY"));

        vm.startBroadcast(pk);
        MockUSDG usdg = new MockUSDG();
        MockRegistry registry = new MockRegistry();
        registry.register(1, seller);

        ThinkrBonds bonds = new ThinkrBonds(
            IIdentityRegistry(address(registry)), IERC20(address(usdg)), 10e6, 25e4
        );

        usdg.mint(seller, 1_000_000e6);
        usdg.mint(buyer, 1_000_000e6);
        vm.stopBroadcast();

        console.log("THINKR_REGISTRY=%s", address(registry));
        console.log("THINKR_CURRENCY=%s", address(usdg));
        console.log("THINKR_BONDS=%s", address(bonds));
    }
}
