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
    uint128 internal constant MIN_BOND = 1 * ONE;
    uint128 internal constant MIN_CLAIM_BOND = ONE / 100; // 1 cent

    bytes32 internal constant REF = keccak256("order-1");
    bytes32 internal constant DIGEST = keccak256("the thing that was delivered");

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

        vm.warp(10 days);
    }

    // ------------------------------------------------------------- helpers

    function _bond(uint128 amount) internal {
        vm.prank(seller);
        bonds.bond(AGENT, amount);
    }

    /// @dev `who` pays the seller now. Returns the hour it was paid in.
    function _pay(address who, bytes32 ref, uint128 amount) internal returns (uint64 epoch) {
        epoch = bonds.currentEpoch();
        vm.prank(who);
        bonds.pay(AGENT, ref, amount);
    }

    /// @dev Let the current hour end, then seal a 4-leaf root with (ref, digest) at
    ///      index 0. Returns the hour sealed and the proof for that leaf.
    function _sealNow(bytes32 ref, bytes32 digest)
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
        vm.warp((uint256(epoch) + 1) * bonds.EPOCH_LENGTH()); // the hour ends
        vm.prank(seller);
        bonds.attest(AGENT, epoch, Merkle.root4(leaves));
        proof = Merkle.proof4(leaves, 0);
    }

    /// @dev The first instant claims on a payment made in `epoch` can be filed.
    function _openClaims(uint64 epoch) internal {
        vm.warp(bonds.attestDeadline(epoch + 1));
    }

    function _amount(uint256 agentId) internal view returns (uint128 a) {
        (a,,,) = bonds.bonds(agentId);
    }

    function _reserved(uint256 agentId) internal view returns (uint128 r) {
        (, r,,) = bonds.bonds(agentId);
    }

    function _state(uint256 claimId) internal view returns (ThinkrBonds.ClaimState s) {
        (,,,,,,, s,) = bonds.claims(claimId);
    }

    // ---------------------------------------------------------------- bond

    function test_bond_posts_collateral() public {
        _bond(500 * ONE);
        assertEq(_amount(AGENT), 500 * ONE);
        assertEq(usdg.balanceOf(address(bonds)), 500 * ONE);
    }

    function test_bond_anyone_can_top_up() public {
        _bond(500 * ONE);
        vm.prank(backer);
        bonds.bond(AGENT, 100 * ONE);
        assertEq(_amount(AGENT), 600 * ONE);
    }

    function test_bond_below_minimum_reverts() public {
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.BelowMinimum.selector);
        bonds.bond(AGENT, MIN_BOND - 1);
    }

    function test_bond_unregistered_agent_reverts() public {
        vm.prank(seller);
        vm.expectRevert();
        bonds.bond(999, 500 * ONE);
    }

    function test_withdraw_requires_notice_to_elapse() public {
        _bond(500 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NoticeNotElapsed.selector);
        bonds.withdraw(AGENT, 500 * ONE);
    }

    function test_withdraw_after_notice() public {
        _bond(500 * ONE);
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        uint256 before = usdg.balanceOf(seller);
        vm.prank(seller);
        bonds.withdraw(AGENT, 500 * ONE);
        assertEq(usdg.balanceOf(seller), before + 500 * ONE);
    }

    function test_withdraw_blocked_while_a_claim_is_open() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        vm.prank(buyer);
        bonds.fileClaim(AGENT, REF);

        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.ClaimsOpen.selector);
        bonds.withdraw(AGENT, 500 * ONE);
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

    // -------------------------------------------------------------- attest

    function test_attest_rejects_an_unfinished_epoch() public {
        uint64 epoch = bonds.currentEpoch();
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.EpochNotEnded.selector);
        bonds.attest(AGENT, epoch, keccak256("root"));
    }

    function test_attest_rejects_a_rewrite() public {
        (uint64 epoch,) = _sealNow(REF, DIGEST);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.RootAlreadySet.selector);
        bonds.attest(AGENT, epoch, keccak256("another root"));
    }

    function test_attest_only_owner() public {
        uint64 epoch = bonds.currentEpoch();
        vm.warp(block.timestamp + bonds.EPOCH_LENGTH());
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NotAgentOwner.selector);
        bonds.attest(AGENT, epoch, keccak256("root"));
    }

    /// @notice The property the design rests on: by the time a claim can be filed,
    ///         both roots that could answer it are fixed.
    function test_both_roots_are_final_before_a_claim_can_open() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        vm.prank(buyer);
        bonds.fileClaim(AGENT, REF);

        vm.startPrank(seller);
        vm.expectRevert(ThinkrBonds.AttestWindowClosed.selector);
        bonds.attest(AGENT, epoch, keccak256("invented after the fact"));
        vm.expectRevert(ThinkrBonds.AttestWindowClosed.selector);
        bonds.attest(AGENT, epoch + 1, keccak256("invented after the fact"));
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- pay

    function test_pay_sends_the_money_straight_to_the_seller() public {
        uint256 sellerBefore = usdg.balanceOf(seller);
        uint256 contractBefore = usdg.balanceOf(address(bonds));
        _pay(buyer, REF, 25 * ONE);
        assertEq(usdg.balanceOf(seller), sellerBefore + 25 * ONE);
        assertEq(usdg.balanceOf(address(bonds)), contractBefore, "nothing is held");
    }

    function test_pay_records_the_payment() public {
        uint64 epoch = _pay(buyer, REF, 25 * ONE);
        (uint256 agentId, address who, uint128 amount, uint64 e, bool claimed) =
            bonds.payments(bonds.paymentIdOf(AGENT, buyer, REF));
        assertEq(agentId, AGENT);
        assertEq(who, buyer);
        assertEq(amount, 25 * ONE);
        assertEq(e, epoch);
        assertFalse(claimed);
    }

    function test_pay_twice_with_the_same_ref_reverts() public {
        _pay(buyer, REF, 1 * ONE);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.PaymentExists.selector);
        bonds.pay(AGENT, REF, 1 * ONE);
    }

    function test_pay_zero_reverts() public {
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.AmountZero.selector);
        bonds.pay(AGENT, REF, 0);
    }

    function test_pay_an_unregistered_agent_reverts() public {
        vm.prank(buyer);
        vm.expectRevert();
        bonds.pay(999, REF, 1 * ONE);
    }

    // ---------------------------------------------------- the attacks (v1)

    /// @notice The attack that broke version 1: a claim on a payment that never
    ///         happened, against an honest seller with nothing to prove.
    function test_attack_a_claim_on_a_payment_that_never_happened_is_refused() public {
        _bond(100 * ONE);
        _sealNow(keccak256("a real order"), DIGEST);
        vm.warp(block.timestamp + 3 hours);

        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NoSuchPayment.selector);
        bonds.fileClaim(AGENT, keccak256("never happened"));
        assertEq(_amount(AGENT), 100 * ONE);
    }

    /// @notice Someone else's real payment cannot be claimed by an onlooker who read
    ///         its reference off chain.
    function test_attack_a_stranger_cannot_claim_a_buyers_payment() public {
        _bond(100 * ONE);
        uint64 epoch = _pay(buyer, REF, 50 * ONE);
        _openClaims(epoch);
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NoSuchPayment.selector);
        bonds.fileClaim(AGENT, REF);
    }

    function test_attack_one_payment_cannot_be_claimed_twice() public {
        _bond(100 * ONE);
        uint64 epoch = _pay(buyer, REF, 10 * ONE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(id);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.AlreadyClaimed.selector);
        bonds.fileClaim(AGENT, REF);
    }

    /// @notice The claim is for what was paid, never more.
    function test_attack_a_claim_cannot_exceed_the_payment() public {
        _bond(100 * ONE);
        uint64 epoch = _pay(buyer, REF, 3 * ONE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        (,,, uint128 amount,,,,,) = bonds.claims(id);
        assertEq(amount, 3 * ONE);
        assertEq(_reserved(AGENT), 3 * ONE);
    }

    /// @notice Paying first with someone else's reference does not take it from them:
    ///         payments are recorded per buyer.
    function test_attack_front_running_a_ref_does_not_block_the_buyer() public {
        _pay(stranger, REF, 1 * ONE);
        _pay(buyer, REF, 1 * ONE);
        (, address who,,,) = bonds.payments(bonds.paymentIdOf(AGENT, buyer, REF));
        assertEq(who, buyer);
    }

    // ------------------------------------------------------------- claims

    function test_file_claim_reserves_and_takes_a_stake() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        uint256 before = usdg.balanceOf(buyer);
        vm.prank(buyer);
        bonds.fileClaim(AGENT, REF);
        assertEq(_reserved(AGENT), 100 * ONE);
        assertEq(usdg.balanceOf(buyer), before - 2 * ONE, "2% stake");
    }

    function test_claim_bond_has_a_floor() public view {
        assertEq(bonds.claimBondFor(1), MIN_CLAIM_BOND);
    }

    function test_a_claim_before_both_roots_are_final_reverts() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 10 * ONE);
        vm.warp(bonds.attestDeadline(epoch + 1) - 1);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.AttestWindowOpen.selector);
        bonds.fileClaim(AGENT, REF);
    }

    function test_a_claim_after_the_claim_period_reverts() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 10 * ONE);
        vm.warp((uint256(epoch) + 1) * bonds.EPOCH_LENGTH() + bonds.CLAIM_PERIOD() + 1);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.ClaimPeriodElapsed.selector);
        bonds.fileClaim(AGENT, REF);
    }

    function test_claims_cannot_exceed_collateral() public {
        _bond(10 * ONE);
        uint64 epoch = _pay(buyer, REF, 11 * ONE);
        _openClaims(epoch);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.fileClaim(AGENT, REF);
    }

    // ----------------------------------------------------------- discharge

    function test_discharge_with_a_seal_from_the_payment_hour() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);

        vm.prank(seller);
        bonds.discharge(id, epoch, DIGEST, proof);
        assertEq(uint8(_state(id)), uint8(ThinkrBonds.ClaimState.Discharged));
        assertEq(_reserved(AGENT), 0);
        assertEq(_amount(AGENT), 502 * ONE, "the stake goes to the seller's bond");
    }

    /// @notice Paid at 10:59, delivered and sealed at 11:01: still answerable.
    function test_discharge_with_a_seal_from_the_hour_after() public {
        _bond(500 * ONE);
        uint64 paidIn = _pay(buyer, REF, 100 * ONE);
        vm.warp((uint256(paidIn) + 1) * bonds.EPOCH_LENGTH()); // next hour
        (uint64 sealedIn, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        assertEq(sealedIn, paidIn + 1);
        _openClaims(paidIn);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.prank(seller);
        bonds.discharge(id, sealedIn, DIGEST, proof);
        assertEq(uint8(_state(id)), uint8(ThinkrBonds.ClaimState.Discharged));
    }

    /// @notice A seal two hours late does not count: claims could already be open.
    function test_discharge_with_a_seal_two_hours_late_is_refused() public {
        _bond(500 * ONE);
        uint64 paidIn = _pay(buyer, REF, 100 * ONE);
        vm.warp((uint256(paidIn) + 2) * bonds.EPOCH_LENGTH());
        (uint64 sealedIn, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(paidIn);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NotTheRightHour.selector);
        bonds.discharge(id, sealedIn, DIGEST, proof);
    }

    function test_discharge_with_the_wrong_digest_fails() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.BadProof.selector);
        bonds.discharge(id, epoch, keccak256("something else"), proof);
    }

    /// @notice A proof for a different order in the same root does not answer this one.
    function test_discharge_with_another_orders_proof_fails() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(keccak256("another order"), DIGEST);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.BadProof.selector);
        bonds.discharge(id, epoch, DIGEST, proof);
    }

    function test_discharge_without_a_root_fails() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NoRoot.selector);
        bonds.discharge(id, epoch, DIGEST, new bytes32[](0));
    }

    function test_discharge_only_owner() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NotAgentOwner.selector);
        bonds.discharge(id, epoch, DIGEST, proof);
    }

    // -------------------------------------------------------------- settle

    function test_settle_pays_the_claimant_and_returns_the_stake() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        uint256 before = usdg.balanceOf(buyer);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(id);
        assertEq(usdg.balanceOf(buyer), before + 102 * ONE, "claim plus stake back");
        assertEq(_amount(AGENT), 400 * ONE);
        assertEq(_reserved(AGENT), 0);
    }

    function test_settle_before_the_window_closes_reverts() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW() - 1);
        vm.expectRevert(ThinkrBonds.ChallengeWindowOpen.selector);
        bonds.settle(id);
    }

    function test_a_discharged_claim_cannot_be_settled() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        vm.prank(seller);
        bonds.discharge(id, epoch, DIGEST, proof);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        vm.expectRevert(ThinkrBonds.ClaimNotOpen.selector);
        bonds.settle(id);
    }

    // ------------------------------------------------------------ the whole

    /// @notice The promise, end to end: a seller who delivers and seals keeps its money
    ///         and collects the stake; one who goes quiet pays out.
    function test_the_promise_end_to_end() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        bytes32 quiet = keccak256("order-2");
        _pay(buyer, quiet, 50 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);

        vm.startPrank(buyer);
        uint256 answered = bonds.fileClaim(AGENT, REF);
        uint256 silent = bonds.fileClaim(AGENT, quiet);
        vm.stopPrank();

        vm.prank(seller);
        bonds.discharge(answered, epoch, DIGEST, proof);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(silent);

        assertEq(_amount(AGENT), 500 * ONE + 2 * ONE - 50 * ONE);
        assertEq(_reserved(AGENT), 0);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_a_claim_never_exceeds_what_was_paid(uint128 paid) public {
        paid = uint128(bound(paid, 1, 1_000 * ONE));
        _bond(1_000 * ONE);
        uint64 epoch = _pay(buyer, REF, paid);
        _openClaims(epoch);
        vm.prank(buyer);
        uint256 id = bonds.fileClaim(AGENT, REF);
        (,,, uint128 amount,,,,,) = bonds.claims(id);
        assertEq(amount, paid);
    }

    function testFuzz_no_claim_without_a_payment(bytes32 ref, address who) public {
        vm.assume(who != address(0));
        _bond(100 * ONE);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(who);
        vm.expectRevert(ThinkrBonds.NoSuchPayment.selector);
        bonds.fileClaim(AGENT, ref);
    }

    function testFuzz_claim_bond_never_below_the_floor(uint128 amount) public view {
        assertGe(bonds.claimBondFor(amount), MIN_CLAIM_BOND);
    }
}
