// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ThinkrBonds} from "../src/ThinkrBonds.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MockRegistry} from "./mocks/MockRegistry.sol";

/// @notice The check that catches a drift between `sdk/tree.js` and this contract in
///         either direction: a seven-leaf tree built entirely in JavaScript, replayed
///         here as a real discharge. Regenerate with `node sdk/gen-discharge-vector.js`.
contract SdkParityTest is Test {
    ThinkrBonds internal bonds;
    MockUSDG internal usdg;
    MockRegistry internal registry;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    uint256 internal constant AGENT = 1;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MockRegistry();
        registry.register(AGENT, seller);
        bonds = new ThinkrBonds(
            IIdentityRegistry(address(registry)), IERC20(address(usdg)), 10e6, 25e4
        );
        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? seller : buyer;
            usdg.mint(a, 10_000e6);
            vm.prank(a);
            usdg.approve(address(bonds), type(uint256).max);
        }
        vm.warp(10 days);
    }

    function test_a_proof_built_in_javascript_discharges_a_claim() public {
        string memory json = vm.readFile("./sdk/discharge-vector.json");
        bytes32 root = vm.parseJsonBytes32(json, ".root");
        bytes32 ref = vm.parseJsonBytes32(json, ".ref");
        bytes32 digest = vm.parseJsonBytes32(json, ".digest");
        bytes32[] memory proof = vm.parseJsonBytes32Array(json, ".proof");

        vm.prank(seller);
        bonds.bond(AGENT, 500e6);

        uint64 epoch = bonds.currentEpoch();
        vm.prank(buyer);
        bonds.pay(AGENT, ref, 100e6);
        vm.warp((uint256(epoch) + 1) * bonds.EPOCH_LENGTH());
        vm.prank(seller);
        bonds.attest(AGENT, epoch, root);

        vm.warp(bonds.attestDeadline(epoch + 1));
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, ref);

        vm.prank(seller);
        bonds.discharge(id, epoch, digest, proof);

        (,,,,,,, ThinkrBonds.ClaimState state,) = bonds.claims(id);
        assertEq(
            uint8(state), uint8(ThinkrBonds.ClaimState.Discharged), "SDK and contract disagree"
        );
    }

    function test_a_proof_for_a_delivery_that_is_not_there_fails() public {
        string memory json = vm.readFile("./sdk/discharge-vector.json");
        bytes32 root = vm.parseJsonBytes32(json, ".root");
        bytes32 ref = vm.parseJsonBytes32(json, ".ref");
        bytes32[] memory proof = vm.parseJsonBytes32Array(json, ".proof");

        vm.prank(seller);
        bonds.bond(AGENT, 500e6);
        uint64 epoch = bonds.currentEpoch();
        vm.prank(buyer);
        bonds.pay(AGENT, ref, 100e6);
        vm.warp((uint256(epoch) + 1) * bonds.EPOCH_LENGTH());
        vm.prank(seller);
        bonds.attest(AGENT, epoch, root);
        vm.warp(bonds.attestDeadline(epoch + 1));
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, ref);

        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.BadProof.selector);
        bonds.discharge(id, epoch, keccak256("never delivered"), proof);
    }
}
