// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ThinkrBonds} from "../src/ThinkrBonds.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";

/// @notice Robinhood Chain mainnet. Every parameter is a constructor immutable, so what
///         is written here is what the contract is for its whole life. See PARAMETERS.md.
///
///         forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com
///         adds --broadcast only when deploying for real.
contract DeployScript is Script {
    uint256 internal constant ROBINHOOD = 4663;

    /// @dev ERC-8004 identity registry, at its deterministic address. Live on 4663.
    address internal constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    /// @dev USDG, 6 decimals. Checked on chain 2026-10-22: supply about 705m.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev $1. An entry ticket, not cover: buyers check the bond against the payment.
    uint128 internal constant MIN_BOND = 1e6;

    /// @dev $250 per agent while the contract is unaudited: a bound on what any bug can cost.
    uint128 internal constant MAX_BOND = 250e6;

    /// @dev $0.01, so dust payments cannot pile up claims.
    uint128 internal constant MIN_PAYMENT = 1e4;

    /// @dev $0.01. Enough that filing costs something, small enough for a 1 cent claim.
    uint128 internal constant MIN_CLAIM_BOND = 1e4;

    function run() external returns (ThinkrBonds bonds) {
        require(block.chainid == ROBINHOOD, "not Robinhood Chain");
        require(REGISTRY.code.length != 0, "no registry at that address");
        require(USDG.code.length != 0, "no USDG at that address");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        bonds = new ThinkrBonds(
            IIdentityRegistry(REGISTRY),
            IERC20(USDG),
            MIN_BOND,
            MAX_BOND,
            MIN_PAYMENT,
            MIN_CLAIM_BOND
        );
        vm.stopBroadcast();

        console.log("THINKR_BONDS=%s", address(bonds));
        console.log("THINKR_CURRENCY=%s", USDG);
    }
}
