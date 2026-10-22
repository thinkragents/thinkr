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
    address internal sellerAlt = makeAddr("sellerAlt"); // the seller's second wallet
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal backer = makeAddr("backer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AGENT = 42;
    uint128 internal constant ONE = 1e6; // USDG has 6 decimals
    uint128 internal constant MIN_BOND = 1 * ONE;
    uint128 internal constant MAX_BOND = 1_000 * ONE;
    uint128 internal constant MIN_PAYMENT = ONE / 100; // 1 cent
    uint128 internal constant MIN_CLAIM_BOND = ONE / 100; // 1 cent

    bytes32 internal constant REF = keccak256("order-1");
    bytes32 internal constant DIGEST = keccak256("the thing that was delivered");

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MockRegistry();
        registry.register(AGENT, seller);

        bonds = new ThinkrBonds(
            IIdentityRegistry(address(registry)),
            IERC20(address(usdg)),
            MIN_BOND,
            MAX_BOND,
            MIN_PAYMENT,
            MIN_CLAIM_BOND
        );

        address[6] memory who = [seller, sellerAlt, buyer, buyer2, backer, stranger];
        for (uint256 i; i < who.length; ++i) {
            usdg.mint(who[i], 10_000 * ONE);
            vm.prank(who[i]);
            usdg.approve(address(bonds), type(uint256).max);
        }
        vm.warp(10 days);
    }

    // ------------------------------------------------------------- helpers

    function _bond(uint128 amount) internal {
        vm.prank(seller);
        bonds.bond(AGENT, amount);
    }

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
        vm.warp((uint256(epoch) + 1) * bonds.EPOCH_LENGTH());
        vm.prank(seller);
        bonds.attest(AGENT, epoch, Merkle.root4(leaves));
        proof = Merkle.proof4(leaves, 0);
    }

    function _openClaims(uint64 epoch) internal {
        vm.warp(bonds.claimOpens(epoch));
    }

    function _claim(address who, bytes32 ref) internal returns (uint256 id) {
        vm.prank(who);
        id = bonds.fileClaim(AGENT, ref);
    }

    function _amount() internal view returns (uint128 a) {
        (a,,,,) = bonds.bonds(AGENT);
    }

    function _reserved() internal view returns (uint128 r) {
        (, r,,,) = bonds.bonds(AGENT);
    }

    function _state(uint256 claimId) internal view returns (ThinkrBonds.ClaimState s) {
        (,,,,,,,, s) = bonds.claims(claimId);
    }

    function _notice() internal {
        vm.prank(seller);
        bonds.requestWithdraw(AGENT);
    }

    // ---------------------------------------------------------------- bond

    function test_bond_posts_collateral() public {
        _bond(500 * ONE);
        assertEq(_amount(), 500 * ONE);
        assertEq(usdg.balanceOf(address(bonds)), 500 * ONE);
    }

    function test_bond_anyone_can_top_up() public {
        _bond(500 * ONE);
        vm.prank(backer);
        bonds.bond(AGENT, 100 * ONE);
        assertEq(_amount(), 600 * ONE);
    }

    function test_bond_below_minimum_reverts() public {
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.BelowMinimum.selector);
        bonds.bond(AGENT, MIN_BOND - 1);
    }

    function test_bond_above_the_cap_reverts() public {
        _bond(MAX_BOND);
        vm.prank(backer);
        vm.expectRevert(ThinkrBonds.AboveMaximum.selector);
        bonds.bond(AGENT, 1);
    }

    function test_bond_unregistered_agent_reverts() public {
        vm.prank(seller);
        vm.expectRevert();
        bonds.bond(999, 500 * ONE);
    }

    // ------------------------------------------------------------- withdraw

    function test_withdraw_needs_notice_to_elapse() public {
        _bond(500 * ONE);
        _notice();
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NoticeNotElapsed.selector);
        bonds.withdraw(AGENT, 500 * ONE);
    }

    function test_withdraw_after_notice() public {
        _bond(500 * ONE);
        _notice();
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        uint256 before = usdg.balanceOf(seller);
        vm.prank(seller);
        bonds.withdraw(AGENT, 500 * ONE);
        assertEq(usdg.balanceOf(seller), before + 500 * ONE);
    }

    function test_withdraw_only_owner() public {
        _bond(500 * ONE);
        _notice();
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        vm.prank(backer);
        vm.expectRevert(ThinkrBonds.NotAgentOwner.selector);
        bonds.withdraw(AGENT, 500 * ONE);
    }

    /// @notice Review R3: an elapsed notice used to stay usable forever.
    function test_R3_a_notice_is_used_up_by_the_withdrawal() public {
        _bond(500 * ONE);
        _notice();
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        vm.prank(seller);
        bonds.withdraw(AGENT, 100 * ONE);

        vm.warp(block.timestamp + 90 days);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NoticeNotGiven.selector);
        bonds.withdraw(AGENT, 400 * ONE);
    }

    /// @notice Review R3b: no payment can be taken while the seller is leaving.
    function test_R3b_no_payments_during_notice() public {
        _bond(500 * ONE);
        _notice();
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.SellerLeaving.selector);
        bonds.pay(AGENT, REF, 10 * ONE);
    }

    /// @notice Cover reserved before notice cannot be withdrawn while it is reserved.
    function test_R3b_reserved_cover_cannot_be_withdrawn() public {
        _bond(100 * ONE);
        _pay(buyer, REF, 60 * ONE);
        _notice();
        vm.warp(block.timestamp + 2 hours); // still inside the payment's claim window
        // shorten nothing: the notice is 7 days, the window 1 day, so check reservation
        // directly by trying to withdraw everything once notice has elapsed but before
        // anyone released the payment
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.withdraw(AGENT, 100 * ONE);
        vm.prank(seller);
        bonds.withdraw(AGENT, 40 * ONE); // the free part can go
        assertEq(_amount(), 60 * ONE);
    }

    /// @notice Review R5: dust claims can no longer block a withdrawal, which only ever
    ///         needs the unreserved part.
    function test_R5_open_claims_only_lock_their_own_cover() public {
        _bond(100 * ONE);
        uint64 epoch = _pay(stranger, REF, MIN_PAYMENT);
        _openClaims(epoch);
        _claim(stranger, REF);
        _notice();
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        // everything but the minimum bond can go while the dust claim is open; the bond
        // never drops below the minimum, so the last dollar waits for the claim to resolve
        vm.prank(seller);
        bonds.withdraw(AGENT, 100 * ONE - MIN_BOND);
        assertEq(_amount(), MIN_BOND);
    }

    function test_R5_payments_below_the_minimum_revert() public {
        _bond(100 * ONE);
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.BelowMinimum.selector);
        bonds.pay(AGENT, REF, MIN_PAYMENT - 1);
    }

    /// @notice Review R9: after the agent changes hands, the old owner's notice is no use
    ///         to the new owner.
    function test_R9_notice_does_not_pass_with_the_agent() public {
        _bond(500 * ONE);
        _notice();
        registry.register(AGENT, stranger); // transferred
        vm.warp(block.timestamp + bonds.NOTICE_PERIOD());
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NoticeNotGiven.selector);
        bonds.withdraw(AGENT, 500 * ONE);
    }

    // ----------------------------------------------------------------- pay

    function test_pay_sends_the_money_straight_to_the_seller() public {
        _bond(100 * ONE);
        uint256 sellerBefore = usdg.balanceOf(seller);
        uint256 held = usdg.balanceOf(address(bonds));
        _pay(buyer, REF, 25 * ONE);
        assertEq(usdg.balanceOf(seller), sellerBefore + 25 * ONE);
        assertEq(usdg.balanceOf(address(bonds)), held, "the payment is not held");
        assertEq(_reserved(), 25 * ONE, "the same amount of the bond is reserved");
    }

    /// @notice Review R4: a payment the bond cannot cover is refused up front.
    function test_R4_a_payment_the_bond_cannot_cover_is_refused() public {
        _bond(100 * ONE);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.pay(AGENT, REF, 101 * ONE);
    }

    function test_an_unbonded_seller_cannot_be_paid_through_thinkr() public {
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.pay(AGENT, REF, 1 * ONE);
    }

    /// @notice Review R8: a ref answers one payment, so one sealed leaf can never answer
    ///         two buyers.
    function test_R8_a_ref_is_unique_per_agent() public {
        _bond(100 * ONE);
        _pay(buyer, REF, 1 * ONE);
        vm.prank(buyer2);
        vm.expectRevert(ThinkrBonds.PaymentExists.selector);
        bonds.pay(AGENT, REF, 1 * ONE);
    }

    function test_release_frees_cover_after_the_window() public {
        _bond(100 * ONE);
        uint64 epoch = _pay(buyer, REF, 40 * ONE);
        bytes32 id = bonds.paymentIdOf(AGENT, REF);
        vm.expectRevert(ThinkrBonds.ClaimPeriodOpen.selector);
        bonds.release(id);
        vm.warp(bonds.claimCloses(epoch) + 1);
        bonds.release(id);
        assertEq(_reserved(), 0);
        vm.expectRevert(ThinkrBonds.NotReserved.selector);
        bonds.release(id);
    }

    // ------------------------------------------------------------ attacks

    /// @notice The version 1 hole: a claim on a payment that never happened.
    function test_attack_a_claim_on_a_payment_that_never_happened_is_refused() public {
        _bond(100 * ONE);
        _sealNow(keccak256("a real order"), DIGEST);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NoSuchPayment.selector);
        bonds.fileClaim(AGENT, keccak256("never happened"));
    }

    function test_attack_a_stranger_cannot_claim_a_buyers_payment() public {
        _bond(100 * ONE);
        uint64 epoch = _pay(buyer, REF, 50 * ONE);
        _openClaims(epoch);
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NotThePayer.selector);
        bonds.fileClaim(AGENT, REF);
    }

    function test_attack_one_payment_cannot_be_claimed_twice() public {
        _bond(100 * ONE);
        uint64 epoch = _pay(buyer, REF, 10 * ONE);
        _openClaims(epoch);
        _claim(buyer, REF);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.AlreadyClaimed.selector);
        bonds.fileClaim(AGENT, REF);
    }

    /// @notice Review R1: the seller's second wallet pays itself first and claims first.
    ///         It can only take cover it reserved itself; the real buyer is paid in full.
    function test_R1_a_sellers_second_wallet_cannot_take_a_buyers_cover() public {
        _bond(100 * ONE);
        uint64 alt = _pay(sellerAlt, keccak256("alt"), 40 * ONE);
        vm.warp(block.timestamp + 1 hours);
        uint64 real = _pay(buyer, REF, 60 * ONE);
        assertEq(_reserved(), 100 * ONE, "both payments hold their own cover");

        _openClaims(alt);
        uint256 a = _claim(sellerAlt, keccak256("alt"));
        _openClaims(real);
        uint256 r = _claim(buyer, REF);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(a);
        bonds.settle(r);

        uint256 before = usdg.balanceOf(buyer);
        vm.prank(buyer);
        bonds.collect();
        assertEq(usdg.balanceOf(buyer), before + 60 * ONE + (60 * ONE * 2) / 100, "paid in full");
    }

    /// @notice Review R1, the starving half: once the bond is fully reserved, no new buyer
    ///         can pay into it, so nobody pays for cover that is not there.
    function test_R1_a_fully_reserved_bond_refuses_new_payments() public {
        _bond(100 * ONE);
        _pay(sellerAlt, keccak256("alt"), 100 * ONE);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.InsufficientCollateral.selector);
        bonds.pay(AGENT, REF, 1 * ONE);
    }

    // -------------------------------------------------------------- claims

    function test_file_claim_takes_a_stake_and_keeps_the_cover() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        uint256 before = usdg.balanceOf(buyer);
        _claim(buyer, REF);
        assertEq(_reserved(), 100 * ONE);
        assertEq(usdg.balanceOf(buyer), before - 2 * ONE, "2% stake");
    }

    function test_a_claim_before_both_roots_are_final_reverts() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 10 * ONE);
        vm.warp(bonds.claimOpens(epoch) - 1);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.AttestWindowOpen.selector);
        bonds.fileClaim(AGENT, REF);
    }

    function test_a_claim_after_the_claim_period_reverts() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 10 * ONE);
        vm.warp(bonds.claimCloses(epoch) + 1);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.ClaimPeriodElapsed.selector);
        bonds.fileClaim(AGENT, REF);
    }

    function test_both_roots_are_final_before_a_claim_can_open() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 10 * ONE);
        _openClaims(epoch);
        _claim(buyer, REF);
        vm.startPrank(seller);
        vm.expectRevert(ThinkrBonds.AttestWindowClosed.selector);
        bonds.attest(AGENT, epoch, keccak256("invented"));
        vm.expectRevert(ThinkrBonds.AttestWindowClosed.selector);
        bonds.attest(AGENT, epoch + 1, keccak256("invented"));
        vm.stopPrank();
    }

    // ----------------------------------------------------------- discharge

    function test_discharge_with_a_seal_from_the_payment_hour() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.prank(seller);
        bonds.discharge(id, epoch, DIGEST, proof);
        assertEq(uint8(_state(id)), uint8(ThinkrBonds.ClaimState.Discharged));
        assertEq(_reserved(), 0);
        assertEq(_amount(), 502 * ONE, "the stake goes to the seller's bond");
    }

    function test_discharge_with_a_seal_from_the_hour_after() public {
        _bond(500 * ONE);
        uint64 paidIn = _pay(buyer, REF, 100 * ONE);
        vm.warp((uint256(paidIn) + 1) * bonds.EPOCH_LENGTH());
        (uint64 sealedIn, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(paidIn);
        uint256 id = _claim(buyer, REF);
        vm.prank(seller);
        bonds.discharge(id, sealedIn, DIGEST, proof);
        assertEq(uint8(_state(id)), uint8(ThinkrBonds.ClaimState.Discharged));
    }

    function test_discharge_with_a_seal_two_hours_late_is_refused() public {
        _bond(500 * ONE);
        uint64 paidIn = _pay(buyer, REF, 100 * ONE);
        vm.warp((uint256(paidIn) + 2) * bonds.EPOCH_LENGTH());
        (uint64 sealedIn, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(paidIn);
        uint256 id = _claim(buyer, REF);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.NotTheRightHour.selector);
        bonds.discharge(id, sealedIn, DIGEST, proof);
    }

    function test_discharge_with_another_orders_proof_fails() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(keccak256("another order"), DIGEST);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.BadProof.selector);
        bonds.discharge(id, epoch, DIGEST, proof);
    }

    function test_discharge_by_a_stranger_fails() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.prank(stranger);
        vm.expectRevert(ThinkrBonds.NotTheSeller.selector);
        bonds.discharge(id, epoch, DIGEST, proof);
    }

    /// @notice Review R9: the seller that was paid, and sealed honestly, can still answer
    ///         after it has transferred the agent.
    function test_R9_the_paid_seller_answers_after_a_transfer() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        registry.register(AGENT, stranger);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.prank(seller);
        bonds.discharge(id, epoch, DIGEST, proof);
        assertEq(uint8(_state(id)), uint8(ThinkrBonds.ClaimState.Discharged));
    }

    /// @notice Review R10: once the window has closed, silence is final.
    function test_R10_no_discharge_after_the_challenge_window() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        vm.prank(seller);
        vm.expectRevert(ThinkrBonds.ChallengeWindowClosed.selector);
        bonds.discharge(id, epoch, DIGEST, proof);
    }

    /// @notice Review R6: a burned agent's buyers are still paid; only the owner's own
    ///         withdrawal is lost, as with any burned token.
    function test_R6_a_burned_agents_buyers_are_still_paid() public {
        _bond(100 * ONE);
        uint64 epoch = _pay(buyer, REF, 30 * ONE);
        registry.register(AGENT, address(0)); // burned
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(id);
        assertEq(bonds.owed(buyer), 30 * ONE + (30 * ONE * 2) / 100);
    }

    // -------------------------------------------------------------- settle

    function test_settle_owes_the_claimant_the_payment_and_its_stake() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(id);
        assertEq(bonds.owed(buyer), 102 * ONE);
        assertEq(_amount(), 400 * ONE);
        assertEq(_reserved(), 0);
        uint256 before = usdg.balanceOf(buyer);
        vm.prank(buyer);
        bonds.collect();
        assertEq(usdg.balanceOf(buyer), before + 102 * ONE);
        vm.prank(buyer);
        vm.expectRevert(ThinkrBonds.NothingOwed.selector);
        bonds.collect();
    }

    function test_settle_before_the_window_closes_reverts() public {
        _bond(500 * ONE);
        uint64 epoch = _pay(buyer, REF, 100 * ONE);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW() - 1);
        vm.expectRevert(ThinkrBonds.ChallengeWindowOpen.selector);
        bonds.settle(id);
    }

    function test_a_discharged_claim_cannot_be_settled() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        vm.prank(seller);
        bonds.discharge(id, epoch, DIGEST, proof);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        vm.expectRevert(ThinkrBonds.ClaimNotOpen.selector);
        bonds.settle(id);
    }

    // -------------------------------------------------------------- whole

    function test_the_promise_end_to_end() public {
        _bond(500 * ONE);
        _pay(buyer, REF, 100 * ONE);
        bytes32 quiet = keccak256("order-2");
        _pay(buyer, quiet, 50 * ONE);
        (uint64 epoch, bytes32[] memory proof) = _sealNow(REF, DIGEST);
        _openClaims(epoch);
        uint256 answered = _claim(buyer, REF);
        uint256 silent = _claim(buyer, quiet);
        vm.prank(seller);
        bonds.discharge(answered, epoch, DIGEST, proof);
        vm.warp(block.timestamp + bonds.CHALLENGE_WINDOW());
        bonds.settle(silent);
        assertEq(_amount(), 500 * ONE + 2 * ONE - 50 * ONE);
        assertEq(_reserved(), 0);
        assertEq(bonds.owed(buyer), 50 * ONE + 1 * ONE);
    }

    // --------------------------------------------------------------- fuzz

    function testFuzz_a_claim_is_exactly_what_was_paid(uint128 paid) public {
        paid = uint128(bound(paid, MIN_PAYMENT, 1_000 * ONE));
        _bond(1_000 * ONE);
        uint64 epoch = _pay(buyer, REF, paid);
        _openClaims(epoch);
        uint256 id = _claim(buyer, REF);
        (,,,, uint128 amount,,,,) = bonds.claims(id);
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
