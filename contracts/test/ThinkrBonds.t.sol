// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ThinkrBonds} from "../src/ThinkrBonds.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MockRegistry} from "./mocks/MockRegistry.sol";
import {Merkle} from "./Merkle.sol";

contract ThinkrBondsTest is Test {
    ThinkrBonds internal bonds;
    MockUSDG internal usdg;
    MockRegistry internal registry;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal backer = makeAddr("backer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AGENT = 42;
    uint128 internal constant ONE = 1e6; // USDG has 6 decimals
    uint128 internal constant MIN_BOND = 10 * ONE; // cheap to join while the market is small
    uint128 internal constant MIN_CLAIM_BOND = ONE / 4; // 25c

    bytes32 internal constant PAYMENT = keccak256("payment-1");
    bytes32 internal constant RESPONSE = keccak256("the thing that was delivered");

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MockRegistry();
        registry.register(AGENT, seller);

        bonds = new ThinkrBonds(
            IIdentityRegistry(address(registry)), IERC20(address(usdg)), MIN_BOND, MIN_CLAIM_BOND
        );

        for (uint256 i; i < 4; ++i) {
            address a = [seller, buyer, backer, stranger][i];
            usdg.mint(a, 10_000 * ONE);
            vm.prank(a);
            usdg.approve(address(bonds), type(uint256).max);
        }

        // Start somewhere with room to warp backwards within an epoch.
        vm.warp(10 days);
    }

    // ------------------------------------------------------------- helpers

    function _bond(uint128 amount) internal {
        vm.prank(seller);
        bonds.bond(AGENT, amount);
    }

    /// @dev Finish the current epoch and commit a 4-leaf root containing `ref`
    ///      at index 0. Returns the epoch and the proof for that leaf.
    function _attestWith(bytes32 ref, bytes32 digest)
        internal
        returns (uint64 epoch, bytes32[] memory proof)
    {
        epoch = bonds.currentEpoch();
        bytes32[4] memory leaves = [
            Merkle.leaf(ref, digest),
            Merkle.leaf(keccak256("p2"), keccak256("r2")),
            Merkle.leaf(keccak256("p3"), keccak256("r3")),
            Merkle.leaf(keccak256("p4"), keccak256("r4"))
        ];
        vm.warp(block.timestamp + bonds.EPOCH_LENGTH()); // epoch ends
        vm.prank(seller);
        bonds.attest(AGENT, epoch, Merkle.root4(leaves));
        proof = Merkle.proof4(leaves, 0);
    }

    /// @dev Move past the moment the epoch's root became final so claims can be filed.
    function _openClaims(uint64 epoch) internal {
        vm.warp(bonds.attestDeadline(epoch));
    }

    function _amount(uint256 agentId) internal view returns (uint128 a) {
        (a,,,) = bonds.bonds(agentId);
    }

    function _reserved(uint256 agentId) internal view returns (uint128 r) {
        (, r,,) = bonds.bonds(agentId);
    }

    // ---------------------------------------------------------------- bond

    function test_bond_posts_collateral() public {
        _bond(500 * ONE);
        assertEq(_amount(AGENT), 500 * ONE);
        assertEq(bonds.available(AGENT), 500 * ONE);
        assertEq(usdg.balanceOf(address(bonds)), 500 * ONE);
    }

    function test_bond_anyone_can_top_up() public {
        _bond(500 * ONE);
        vm.prank(backer);
        bonds.bond(AGENT, 250 * ONE);
        assertEq(_amount(AGENT), 750 * ONE);
    }

    function test_bond_below_minimum_reverts() public {
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.BelowMinimum.selector);
        bonds.bond(AGENT, MIN_BOND - 1);
    }

    function test_bond_zero_reverts() public {
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.AmountZero.selector);
        bonds.bond(AGENT, 0);
    }

    function test_bond_unregistered_agent_reverts() public {
        vm.prank(seller);
        vm.expectRevert(MockRegistry.NonexistentAgent.selector);
        bonds.bond(999, 500 * ONE);
    }

    function test_bond_records_first_bonded_at_once() public {
        _bond(500 * ONE);
        (,, uint64 first,) = bonds.bonds(AGENT);
        vm.warp(block.timestamp + 30 days);
        _bond(100 * ONE);
        (,, uint64 after_,) = bonds.bonds(AGENT);
        assertEq(after_, first);
    }

    // ------------------------------------------------------------ withdraw

    function test_withdraw_requires_notice() public {
        _bond(500 * ONE);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NoticeNotGiven.selector);
        bonds.withdraw(AGENT, 500 * ONE);
    }

    function test_withdraw_requires_notice_to_elapse() public {
        _bond(500 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD() - 1);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NoticeNotElapsed.selector);
        bonds.withdraw(AGENT, 500 * ONE);
    }

    function test_withdraw_after_notice() public {
        _bond(500 * ONE);
        uint256 before = usdg.balanceOf(seller);
        vm.startPrank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        bonds.withdraw(AGENT, 500 * ONE);
        vm.stopPrank();
        assertEq(_amount(AGENT), 0);
        assertEq(usdg.balanceOf(seller), before + 500 * ONE);
    }

    function test_withdraw_blocked_while_a_claim_is_open() public {
        _bond(500 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);

        vm.prank(buyer);
        bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());

        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.ClaimsOpen.selector);
        bonds.withdraw(AGENT, 500 * ONE);
    }

    function test_withdraw_cannot_leave_a_dust_bond() public {
        _bond(500 * ONE);
        vm.startPrank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        vm.expectRevert(ThinkrBonds.BelowMinimum.selector);
        bonds.withdraw(AGENT, 500 * ONE - (MIN_BOND - 1));
        vm.stopPrank();
    }

    function test_withdraw_only_owner() public {
        _bond(500 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        vm.prank(backer);
        vm.expectRevert(ThinkrBonds.NotAgentOwner.selector);
        bonds.withdraw(AGENT, 500 * ONE);
    }

    function test_cancel_withdraw_clears_notice() public {
        _bond(500 * ONE);
        vm.startPrank(seller);
        bonds.requestWithdraw(AGENT);
        bonds.cancelWithdraw(AGENT);
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        vm.expectRevert(ThinkrBonds.NoticeNotGiven.selector);
        bonds.withdraw(AGENT, 500 * ONE);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- attest

    function test_attest_rejects_an_unfinished_epoch() public {
        _bond(500 * ONE);
        uint64 epoch = bonds.currentEpoch();
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.EpochNotEnded.selector);
        bonds.attest(AGENT, epoch, keccak256("root"));
    }

    function test_attest_rejects_a_rewrite() public {
        _bond(500 * ONE);
        uint64 epoch = bonds.currentEpoch();
        vm.warp(block.timestamp + bonds.EPOCH_LENGTH());
        vm.startPrank(seller);
        bonds.attest(AGENT, epoch, keccak256("root"));
        vm.expectRevert(ThinkrBonds.RootAlreadySet.selector);
        bonds.attest(AGENT, epoch, keccak256("other root"));
        vm.stopPrank();
    }

    function test_attest_only_owner() public {
        uint64 epoch = bonds.currentEpoch();
        vm.warp(block.timestamp + bonds.EPOCH_LENGTH());
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NotAgentOwner.selector);
        bonds.attest(AGENT, epoch, keccak256("root"));
    }

    /// @notice The property the whole design rests on: by the time a claim can be
    ///         filed, the root is already fixed. A seller can never see a claim and
    ///         then write a root that answers it.
    function test_attest_window_closes_before_claims_open() public {
        _bond(500 * ONE);
        uint64 epoch = bonds.currentEpoch();
        _openClaims(epoch); // the first instant a claim can be filed

        vm.prank(buyer);
        bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.AttestWindowClosed.selector);
        bonds.attest(AGENT, epoch, keccak256("a root invented after the fact"));
    }

    // ----------------------------------------------------------- fileClaim

    function test_file_claim_reserves_and_takes_a_stake() public {
        _bond(500 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);

        uint256 before = usdg.balanceOf(buyer);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        uint128 stake = bonds.claimBondFor(100 * ONE);
        assertEq(stake, 2 * ONE, "2% of 100");
        assertEq(usdg.balanceOf(buyer), before - stake);
        assertEq(_reserved(AGENT), 100 * ONE);
        assertEq(bonds.available(AGENT), 400 * ONE);
        assertEq(id, 1);
    }

    function test_claim_bond_has_a_floor() public view {
        assertEq(bonds.claimBondFor(ONE), MIN_CLAIM_BOND, "2% of a dollar is below the floor");
        assertEq(bonds.claimBondFor(1000 * ONE), 20 * ONE);
    }

    /// @notice The floor is a share of the bond, so it fits the payments agents make
    ///         today and still fits them when they are a hundred times larger.
    function test_the_claim_floor_scales_with_the_bond() public {
        _bond(10 * ONE);
        assertEq(bonds.minClaimFor(AGENT), ONE / 10, "a $10 bond accepts 10c claims");
        _bond(4990 * ONE);
        assertEq(bonds.minClaimFor(AGENT), 50 * ONE, "a $5000 bond requires $50 claims");
    }

    function test_a_claim_below_the_floor_is_refused() public {
        _bond(500 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.ClaimTooSmall.selector);
        bonds.fileClaim(AGENT, PAYMENT, epoch, 4 * ONE); // under 1% of a $500 bond
    }

    /// @notice The property that makes flooding impossible rather than merely costly:
    ///         every open claim reserves at least 1% of the bond and reservations can
    ///         never exceed it, so no seller can face more than 100 open claims.
    function test_a_seller_can_never_face_more_than_100_open_claims() public {
        _bond(100 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        uint256 filed;
        for (uint256 i; i < 150; ++i) {
            vm.prank(buyer);
            try bonds.fileClaim(
                AGENT, keccak256(abi.encode(i)), epoch, bonds.minClaimFor(AGENT)
            ) returns (
                uint256
            ) {
                filed++;
            }
                catch {
                break;
            }
        }
        assertLe(filed, 100, "more than 100 claims got through");
        assertLe(_reserved(AGENT), _amount(AGENT));
    }

    function test_file_claim_before_the_root_is_final_reverts() public {
        _bond(500 * ONE);
        uint64 epoch = bonds.currentEpoch();
        vm.warp(block.timestamp + bonds.EPOCH_LENGTH());
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.AttestWindowOpen.selector);
        bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);
    }

    function test_file_claim_after_the_claim_period_reverts() public {
        _bond(500 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        vm.warp(block.timestamp + bonds.CLAIM_PERIOD() + 1);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.ClaimPeriodElapsed.selector);
        bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);
    }

    function test_one_claim_per_payment() public {
        _bond(500 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        vm.prank(buyer);
        bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.RefAlreadyClaimed.selector);
        bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);
    }

    /// @notice Without `reserved`, five claims of 100 could each expect to be paid
    ///         from a bond of 200.
    function test_claims_cannot_exceed_collateral() public {
        _bond(200 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);

        vm.prank(buyer);
        bonds.fileClaim(AGENT, keccak256("a"), epoch, 150 * ONE);
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.fileClaim(AGENT, keccak256("b"), epoch, 100 * ONE);
    }

    // ----------------------------------------------------------- discharge

    function test_discharge_releases_the_reserve_and_pays_the_seller() public {
        _bond(500 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);

        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);
        uint128 stake = bonds.claimBondFor(100 * ONE);

        vm.prank(seller);
        bonds.discharge(id, PAYMENT, RESPONSE, proof);

        assertEq(_reserved(AGENT), 0);
        assertEq(_amount(AGENT), 500 * ONE + stake, "the junk claim paid the seller");
        assertEq(bonds.available(AGENT), 500 * ONE + stake);
        (,,,,,, ThinkrBonds.ClaimState state) = bonds.claims(id);
        assertEq(uint8(state), uint8(ThinkrBonds.ClaimState.Discharged));
    }

    function test_discharge_with_the_wrong_response_fails() public {
        _bond(500 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.BadProof.selector);
        bonds.discharge(id, PAYMENT, keccak256("something else"), proof);
    }

    function test_discharge_without_a_root_fails() public {
        _bond(500 * ONE);
        uint64 epoch = bonds.currentEpoch();
        _openClaims(epoch); // epoch passed with nothing attested
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NoRoot.selector);
        bonds.discharge(id, PAYMENT, RESPONSE, new bytes32[](2));
    }

    function test_discharge_only_owner() public {
        _bond(500 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NotAgentOwner.selector);
        bonds.discharge(id, PAYMENT, RESPONSE, proof);
    }

    function test_discharge_twice_fails() public {
        _bond(500 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        vm.startPrank(seller);
        bonds.discharge(id, PAYMENT, RESPONSE, proof);
        vm.expectRevert(ThinkrBonds.ClaimNotOpen.selector);
        bonds.discharge(id, PAYMENT, RESPONSE, proof);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- settle

    function test_settle_pays_the_claimant_and_returns_the_stake() public {
        _bond(500 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);

        uint256 before = usdg.balanceOf(buyer);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(id); // anyone may call it

        assertEq(usdg.balanceOf(buyer), before + 100 * ONE, "stake back, claim paid");
        assertEq(_amount(AGENT), 400 * ONE);
        assertEq(_reserved(AGENT), 0);
    }

    function test_settle_before_the_window_closes_reverts() public {
        _bond(500 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);

        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW() - 1);
        vm.expectRevert(ThinkrBonds.ChallengeWindowOpen.selector);
        bonds.settle(id);
    }

    function test_a_discharged_claim_cannot_be_settled() public {
        _bond(500 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, PAYMENT, epoch, 100 * ONE);
        vm.prank(seller);
        bonds.discharge(id, PAYMENT, RESPONSE, proof);

        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        vm.expectRevert(ThinkrBonds.ClaimNotOpen.selector);
        bonds.settle(id);
    }

    /// @notice A seller that answers inside the window keeps its money. One that goes
    ///         quiet does not. That is the entire promise.
    function test_the_promise_end_to_end() public {
        _bond(500 * ONE);

        // honest: delivered, attested, answered
        (uint64 e1, bytes32[] memory p1) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(e1);
        vm.prank(buyer);
        uint256 honest = bonds.fileClaim(AGENT, PAYMENT, e1, 100 * ONE);
        vm.prank(seller);
        bonds.discharge(honest, PAYMENT, RESPONSE, p1);
        assertGt(_amount(AGENT), 500 * ONE);

        // silent: took the money, attested nothing, said nothing
        uint128 held = _amount(AGENT);
        uint64 e2 = bonds.currentEpoch();
        _openClaims(e2);
        vm.prank(stranger);
        uint256 silent = bonds.fileClaim(AGENT, keccak256("payment-2"), e2, 100 * ONE);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(silent);
        assertEq(_amount(AGENT), held - 100 * ONE);
    }

    // --------------------------------------------------------------- epochs

    function test_epoch_boundaries() public view {
        uint64 len = bonds.EPOCH_LENGTH();
        assertEq(bonds.epochOf(0), 0);
        assertEq(bonds.epochOf(len - 1), 0);
        assertEq(bonds.epochOf(len), 1);
        assertEq(bonds.epochOf(block.timestamp), bonds.currentEpoch());
        // An epoch's root is final one full epoch after it ends.
        assertEq(bonds.attestDeadline(0), uint256(len) + bonds.ATTEST_WINDOW());
    }

    // --------------------------------------------------------------- fuzz

    function testFuzz_a_claim_below_the_floor_is_always_refused(uint128 amount) public {
        amount = uint128(bound(amount, 1, 5 * ONE - 1)); // under 1% of a $500 bond
        _bond(500 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.ClaimTooSmall.selector);
        bonds.fileClaim(AGENT, PAYMENT, epoch, amount);
    }

    function testFuzz_claim_bond_never_below_the_floor(uint128 amount) public view {
        amount = uint128(bound(amount, 1, type(uint96).max));
        assertGe(bonds.claimBondFor(amount), MIN_CLAIM_BOND);
    }

    function testFuzz_reserved_never_exceeds_collateral(uint128 a, uint128 b) public {
        a = uint128(bound(a, 1, 400 * ONE));
        b = uint128(bound(b, 1, 400 * ONE));
        _bond(400 * ONE);
        (uint64 epoch,) = _attestWith(PAYMENT, RESPONSE);
        _openClaims(epoch);

        vm.prank(buyer);
        try bonds.fileClaim(AGENT, keccak256("a"), epoch, a) {} catch {}
        vm.prank(stranger);
        try bonds.fileClaim(AGENT, keccak256("b"), epoch, b) {} catch {}

        assertLe(_reserved(AGENT), _amount(AGENT));
    }
}
