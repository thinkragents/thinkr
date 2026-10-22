// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ThinkrBonds} from "../src/ThinkrBonds.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MockRegistry} from "./mocks/MockRegistry.sol";

/// @dev Drives the contract through every path a real caller could take, with reverts
///      swallowed, so the invariants only have to care about what the books say.
contract Handler is Test {
    ThinkrBonds public bonds;
    MockUSDG public usdg;

    uint256[] public agents;
    address[] public owners;
    address public attacker = makeAddr("attacker");

    struct Paid {
        uint256 agentId;
        address buyer;
        bytes32 ref;
        uint64 epoch;
    }

    Paid[] public paid;
    uint256[] public claimIds;
    uint256 public attackerWins;
    uint256 public claimCount;
    uint256 public discharged;
    uint256 public settled;

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
        vm.prank(owner);
        try bonds.bond(id, uint128(bound(amount, 1e6, 300e6))) {} catch {}
    }

    /// @dev One of the owners pays another agent (or its own, as a second wallet would).
    function pay(uint256 seed, uint256 buyerSeed, uint128 amount, uint256 nonce) external {
        (uint256 id,) = _agent(seed);
        address who = owners[buyerSeed % owners.length];
        bytes32 ref = keccak256(abi.encode("ref", nonce));
        uint64 epoch = bonds.currentEpoch();
        vm.prank(who);
        try bonds.pay(id, ref, uint128(bound(amount, 1e4, 200e6))) {
            paid.push(Paid(id, who, ref, epoch));
        } catch {}
    }

    /// @dev The seller seals a one-leaf root for a payment, if its window is still open.
    function seal(uint256 which, bytes32 digest) external {
        if (paid.length == 0) return;
        Paid memory p = paid[which % paid.length];
        address owner = owners[p.agentId - 1];
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(p.ref, digest))));
        vm.prank(owner);
        try bonds.attest(p.agentId, p.epoch, root) {} catch {}
    }

    function fileClaim(uint256 which) external {
        if (paid.length == 0) return;
        Paid memory p = paid[which % paid.length];
        vm.prank(p.buyer);
        try bonds.fileClaim(p.agentId, p.ref) returns (uint256 id) {
            claimIds.push(id);
            claimCount++;
        } catch {}
    }

    /// @dev The seller answers with the one-leaf root it sealed, if it sealed one.
    function discharge(uint256 which, bytes32 digest) external {
        if (claimIds.length == 0) return;
        uint256 id = claimIds[which % claimIds.length];
        (, uint256 agentId,, address seller,,, uint64 epoch,,) = bonds.claims(id);
        vm.prank(seller);
        try bonds.discharge(id, epoch, digest, new bytes32[](0)) {
            discharged++;
        } catch {}
        agentId;
    }

    function settle(uint256 which) external {
        if (claimIds.length == 0) return;
        try bonds.settle(claimIds[which % claimIds.length]) {
            settled++;
        } catch {}
    }

    function release(uint256 which) external {
        if (paid.length == 0) return;
        Paid memory p = paid[which % paid.length];
        try bonds.release(bonds.paymentIdOf(p.agentId, p.ref)) {} catch {}
    }

    function collect(uint256 seed) external {
        address who = seed % 4 == 3 ? attacker : owners[seed % owners.length];
        vm.prank(who);
        try bonds.collect() {} catch {}
    }

    /// @dev Someone who never paid tries to claim, on invented refs and on refs it has
    ///      seen others use. Must never work.
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

    function requestWithdraw(uint256 seed) external {
        (uint256 id, address owner) = _agent(seed);
        vm.prank(owner);
        try bonds.requestWithdraw(id) {} catch {}
    }

    function cancelWithdraw(uint256 seed) external {
        (uint256 id, address owner) = _agent(seed);
        vm.prank(owner);
        try bonds.cancelWithdraw(id) {} catch {}
    }

    function withdraw(uint256 seed, uint128 amount) external {
        (uint256 id, address owner) = _agent(seed);
        vm.prank(owner);
        try bonds.withdraw(id, uint128(bound(amount, 1, 300e6))) {} catch {}
    }

    function skipAhead(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 10 minutes, 2 days));
    }

    function paidCount() external view returns (uint256) {
        return paid.length;
    }

    function paidAt(uint256 i) external view returns (uint256 agentId, bytes32 ref) {
        return (paid[i].agentId, paid[i].ref);
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }

    function agentAt(uint256 i) external view returns (uint256) {
        return agents[i];
    }

    function ownerAt(uint256 i) external view returns (address) {
        return owners[i];
    }
}

/// @notice What the books say must always be true, whatever anyone does.
contract SolvencyInvariantTest is Test {
    ThinkrBonds internal bonds;
    MockUSDG internal usdg;
    MockRegistry internal registry;
    Handler internal handler;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MockRegistry();
        bonds = new ThinkrBonds(
            IIdentityRegistry(address(registry)), IERC20(address(usdg)), 1e6, 1_000e6, 1e4, 1e4
        );

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

    /// @notice The contract can always pay what it owes: every bond, every stake held for
    ///         an open claim, and every settled payout not yet collected.
    function invariant_contract_can_pay_what_it_owes() public view {
        uint256 owedTotal;
        for (uint256 i; i < handler.agentCount(); ++i) {
            (uint128 amount,,,,) = bonds.bonds(handler.agentAt(i));
            owedTotal += amount;
            owedTotal += bonds.owed(handler.ownerAt(i));
        }
        owedTotal += bonds.owed(handler.attacker());
        for (uint256 id = 1; id < bonds.nextClaimId(); ++id) {
            (,,,,, uint128 stake,,, ThinkrBonds.ClaimState state) = bonds.claims(id);
            if (state == ThinkrBonds.ClaimState.Open) owedTotal += stake;
        }
        assertEq(usdg.balanceOf(address(bonds)), owedTotal, "books and balance disagree");
    }

    function invariant_reserved_never_exceeds_the_bond() public view {
        for (uint256 i; i < handler.agentCount(); ++i) {
            (uint128 amount, uint128 reserved,,,) = bonds.bonds(handler.agentAt(i));
            assertLe(reserved, amount);
        }
    }

    /// @notice An agent's reserved cover is exactly its live payments plus its open
    ///         claims: no cover is lost, double counted, or left behind.
    function invariant_reserved_is_exactly_live_payments_and_open_claims() public view {
        for (uint256 i; i < handler.agentCount(); ++i) {
            uint256 agentId = handler.agentAt(i);
            uint256 sum;
            for (uint256 j; j < handler.paidCount(); ++j) {
                (uint256 a, bytes32 ref) = handler.paidAt(j);
                if (a != agentId) continue;
                (,,, uint128 amt,, ThinkrBonds.PaymentState s) =
                    bonds.payments(bonds.paymentIdOf(a, ref));
                if (s == ThinkrBonds.PaymentState.Reserved) sum += amt;
            }
            for (uint256 id = 1; id < bonds.nextClaimId(); ++id) {
                (, uint256 a,,, uint128 amt,,,, ThinkrBonds.ClaimState s) = bonds.claims(id);
                if (a == agentId && s == ThinkrBonds.ClaimState.Open) sum += amt;
            }
            (, uint128 reserved,,,) = bonds.bonds(agentId);
            assertEq(reserved, sum, "reserved cover drifted from what it is held for");
        }
    }

    function invariant_nobody_claims_without_paying() public view {
        assertEq(handler.attackerWins(), 0, "a claim was opened without a payment");
    }

    function invariant_every_claim_is_a_real_payment() public view {
        for (uint256 id = 1; id < bonds.nextClaimId(); ++id) {
            (bytes32 ref, uint256 agentId, address claimant,, uint128 amount,,,,) = bonds.claims(id);
            (uint256 pAgent, address pBuyer,, uint128 pAmount,, ThinkrBonds.PaymentState s) =
                bonds.payments(bonds.paymentIdOf(agentId, ref));
            assertEq(pBuyer, claimant, "claimant did not pay");
            assertEq(pAgent, agentId, "claim on another agent");
            assertEq(pAmount, amount, "claim differs from the payment");
            assertEq(uint8(s), uint8(ThinkrBonds.PaymentState.Claimed));
        }
    }

    /// @dev Guards against a vacuous suite: the handler must be able to reach a filed,
    ///      a discharged and a settled claim.
    function test_handler_reaches_every_outcome() public {
        handler.postBond(0, 200e6);
        handler.pay(0, 1, 50e6, 1);
        handler.pay(0, 1, 30e6, 2);
        handler.skipAhead(61 minutes); // the hour ends; its seal window is open
        handler.seal(0, keccak256("d"));
        handler.skipAhead(2 hours); // both roots final: claims open
        handler.fileClaim(0);
        handler.fileClaim(1);
        handler.discharge(0, keccak256("d"));
        handler.skipAhead(2 days);
        handler.settle(1);
        assertEq(handler.claimCount(), 2, "claims filed");
        assertEq(handler.discharged(), 1, "a claim discharged");
        assertEq(handler.settled(), 1, "a claim settled");
    }
}
