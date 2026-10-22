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

    function fileClaim(uint256 seed, uint128 amount, uint256 nonce) external {
        (uint256 id,) = _agent(seed);
        amount = uint128(bound(amount, 1, 5_000e6));
        uint64 epoch = bonds.currentEpoch() > 2 ? bonds.currentEpoch() - 2 : 0;
        vm.prank(owners[nonce % owners.length]);
        try bonds.fileClaim(id, keccak256(abi.encode(nonce, seed)), epoch, amount) returns (
            uint256
        ) {
            claimCount++;
        } catch {}
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
        bonds = new ThinkrBonds(
            IIdentityRegistry(address(registry)), IERC20(address(usdg)), 10e6, 25e4
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
            (,,, uint128 stake,,, ThinkrBonds.ClaimState state) = bonds.claims(id);
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
        handler.skipAhead(3 hours);
        handler.fileClaim(0, 100e6, 1);
        assertGt(handler.claimCount(), 0, "the handler never files a claim");
    }

    function invariant_reserved_never_exceeds_the_bond() public view {
        for (uint256 i; i < handler.agentCount(); ++i) {
            (uint128 amount, uint128 reserved,,) = bonds.bonds(handler.agentAt(i));
            assertLe(reserved, amount);
        }
    }
}
