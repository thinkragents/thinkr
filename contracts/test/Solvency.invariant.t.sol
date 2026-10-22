// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ThinkrBonds} from "../src/ThinkrBonds.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MockRegistry} from "./mocks/MockRegistry.sol";

/// @dev Drives the contract through every path a real caller could take, with the
///      reverts swallowed, so the invariant runner only has to care about what the
///      books say afterwards.
contract Handler is Test {
    ThinkrBonds public bonds;
    MockUSDG public usdg;

    uint256[] public agents;
    address[] public owners;
    uint256 public claimCount;

    constructor(ThinkrBonds b, MockUSDG u, uint256[] memory a, address[] memory o) {
        bonds = b;
        usdg = u;
        agents = a;
        owners = o;
    }

    function _agent(uint256 seed) internal view returns (uint256 id, address owner) {
        uint256 i = seed % agents.length;
        return (agents[i], owners[i]);
    }

    function postBond(uint256 seed, uint128 amount) external {
        (uint256 id, address owner) = _agent(seed);
        amount = uint128(bound(amount, 1, 5_000e6));
        vm.prank(owner);
        try bonds.bond(id, amount) {} catch {}
    }

    struct Paid {
        uint256 agentId;
        address buyer;
        bytes32 ref;
    }

    Paid[] public paid;
    uint256 public attackerWins;
    address public attacker = makeAddr("attacker");

    /// @dev A buyer (one of the owners, paying another agent) pays and is recorded.
    function pay(uint256 seed, uint256 buyerSeed, uint128 amount, uint256 nonce) external {
        (uint256 id,) = _agent(seed);
        address who = owners[buyerSeed % owners.length];
        bytes32 ref = keccak256(abi.encode("ref", nonce));
        amount = uint128(bound(amount, 1, 2_000e6));
        vm.prank(who);
        try bonds.pay(id, ref, amount) {
            paid.push(Paid(id, who, ref));
        } catch {}
    }

    /// @dev A buyer claims on one of its own recorded payments.
    function fileClaim(uint256 which) external {
        if (paid.length == 0) return;
        Paid memory p = paid[which % paid.length];
        vm.prank(p.buyer);
        try bonds.fileClaim(p.agentId, p.ref) returns (uint256) {
            claimCount++;
        } catch {}
    }

    /// @dev Someone who never paid tries to claim, on invented refs and on refs it
    ///      has seen others use. Must never work.
    function attack(uint256 seed, uint256 which, bool useSeen) external {
        (uint256 id,) = _agent(seed);
        bytes32 ref = useSeen && paid.length > 0
            ? paid[which % paid.length].ref
            : keccak256(abi.encode("invented", which));
        vm.prank(attacker);
        try bonds.fileClaim(id, ref) returns (uint256) {
            attackerWins++;
        } catch {}
    }

    function paidCount() external view returns (uint256) {
        return paid.length;
    }

    function settle(uint256 id) external {
        try bonds.settle(bound(id, 1, bonds.nextClaimId())) {} catch {}
    }

    function requestWithdraw(uint256 seed) external {
        (uint256 id, address owner) = _agent(seed);
        vm.prank(owner);
        try bonds.requestWithdraw(id) {} catch {}
    }

    function withdraw(uint256 seed, uint128 amount) external {
        (uint256 id, address owner) = _agent(seed);
        vm.prank(owner);
        try bonds.withdraw(id, uint128(bound(amount, 1, 5_000e6))) {} catch {}
    }

    function skipAhead(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 3 days));
    }

    function agentAt(uint256 i) external view returns (uint256) {
        return agents[i];
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }
}

/// @notice The only invariant that matters: the contract can always pay what its own
///         books say it owes. Every bond, plus every stake it is holding for an open
///         claim, must be covered by the tokens it actually has.
contract SolvencyInvariantTest is Test {
    ThinkrBonds internal bonds;
    MockUSDG internal usdg;
    MockRegistry internal registry;
    Handler internal handler;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MockRegistry();
        bonds =
            new ThinkrBonds(IIdentityRegistry(address(registry)), IERC20(address(usdg)), 1e6, 1e4);

        uint256[] memory agents = new uint256[](3);
        address[] memory owners = new address[](3);
        for (uint256 i; i < 3; ++i) {
            agents[i] = i + 1;
            owners[i] = makeAddr(string(abi.encodePacked("owner", i)));
            registry.register(agents[i], owners[i]);
            usdg.mint(owners[i], 1_000_000e6);
            vm.prank(owners[i]);
            usdg.approve(address(bonds), type(uint256).max);
        }
        address att = makeAddr("attacker");
        usdg.mint(att, 1_000_000e6);
        vm.prank(att);
        usdg.approve(address(bonds), type(uint256).max);

        vm.warp(30 days);
        handler = new Handler(bonds, usdg, agents, owners);
        targetContract(address(handler));
    }

    function invariant_contract_can_pay_what_it_owes() public view {
        uint256 owed;
        for (uint256 i; i < handler.agentCount(); ++i) {
            (uint128 amount,,,) = bonds.bonds(handler.agentAt(i));
            owed += amount;
        }
        for (uint256 id = 1; id < bonds.nextClaimId(); ++id) {
            (,,,, uint128 stake,,, ThinkrBonds.ClaimState state,) = bonds.claims(id);
            if (state == ThinkrBonds.ClaimState.Open) owed += stake;
        }
        assertGe(usdg.balanceOf(address(bonds)), owed, "contract is short");
    }

    /// @dev Guards against a vacuous suite. If the handler cannot reach a filed
    ///      claim, the solvency invariant above is only checking an empty contract.
    ///      Driven by hand rather than asserted as an invariant, because an invariant
    ///      is also evaluated once before any call is made.
    function test_handler_can_reach_a_filed_claim() public {
        handler.postBond(0, 500e6);
        handler.pay(0, 1, 100e6, 7);
        handler.skipAhead(3 hours);
        handler.fileClaim(0);
        assertGt(handler.claimCount(), 0, "the handler never files a claim");
    }

    function invariant_reserved_never_exceeds_the_bond() public view {
        for (uint256 i; i < handler.agentCount(); ++i) {
            (uint128 amount, uint128 reserved,,) = bonds.bonds(handler.agentAt(i));
            assertLe(reserved, amount);
        }
    }

    /// @notice Version 1's hole, as an invariant: whoever calls, whatever they name,
    ///         nobody who did not pay ever opens a claim.
    function invariant_nobody_claims_without_paying() public view {
        assertEq(handler.attackerWins(), 0, "a claim was opened without a payment");
    }

    /// @notice Every claim on the books matches a real payment, by the claimant, for
    ///         exactly what was paid, and that payment is marked claimed.
    function invariant_every_claim_is_a_real_payment() public view {
        for (uint256 id = 1; id < bonds.nextClaimId(); ++id) {
            (bytes32 paymentId, uint256 agentId, address claimant, uint128 amount,,,,,) =
                bonds.claims(id);
            (uint256 pAgent, address pBuyer, uint128 pAmount,, bool claimed) =
                bonds.payments(paymentId);
            assertEq(pBuyer, claimant, "claimant did not pay");
            assertEq(pAgent, agentId, "claim on another agent");
            assertEq(pAmount, amount, "claim differs from the payment");
            assertTrue(claimed, "payment not marked claimed");
        }
    }
}
