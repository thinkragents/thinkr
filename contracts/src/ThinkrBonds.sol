// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title ThinkrBonds
/// @notice Performance bonds for agents that take payment over x402.
///
/// A seller posts collateral against its ERC-8004 identity. A buyer reads the bond
/// before it pays. The payment itself never touches this contract: x402 settles
/// directly, as it is meant to. What sits here is the seller's own money, posted in
/// advance, covering everything it sells.
///
/// Each hour a seller commits one merkle root of what it delivered. Each leaf is a
/// pair: a `ref` both sides know the transaction by (an x402 payment, an action_ref,
/// a receipt id) and a `digest` of the seller's evidence, in whatever format it keeps.
/// The contract reads neither. A buyer who paid and received nothing files a claim
/// once that hour's root is final. The seller
/// discharges the claim by proving the delivery is in the root it already committed.
/// It cannot forge one after the fact, because the window to commit a root closes
/// before the window to claim against it opens.
///
/// Silence pays out. That is the point.
contract ThinkrBonds is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    enum ClaimState {
        None,
        Open,
        Discharged,
        Settled
    }

    struct Bond {
        uint128 amount; // collateral held
        uint128 reserved; // sum of open claims against it
        uint64 bondedAt; // first time this agent posted
        uint64 withdrawAfter; // 0 unless notice has been given
    }

    struct Claim {
        uint256 agentId;
        address claimant;
        uint128 amount; // claimed, reserved out of the bond
        uint128 claimBond; // the claimant's own stake
        uint64 epoch;
        uint64 filedAt;
        ClaimState state;
    }

    // ----------------------------------------------------------- parameters

    /// @notice One hour. Short enough that proofs stay small and a seller defends a
    ///         root an hour old, cheap enough to commit on this chain.
    uint64 public constant EPOCH_LENGTH = 1 hours;

    /// @notice How long after an epoch ends a seller may still commit its root.
    ///         Claims against that epoch cannot be filed until it closes, so the
    ///         seller is never racing a claimant for the same block.
    uint64 public constant ATTEST_WINDOW = 1 hours;

    /// @notice How long a seller has to answer a claim with a proof.
    uint64 public constant CHALLENGE_WINDOW = 48 hours;

    /// @notice How long after an epoch ends a claim may be filed against it.
    uint64 public constant CLAIM_PERIOD = 7 days;

    /// @notice You cannot take payment on Monday and pull the guarantee on Tuesday.
    uint64 public constant NOTICE_PERIOD = 7 days;

    /// @notice The claimant stakes 2% of what it claims. Enough that filing junk at
    ///         an honest seller costs more than it can ever return.
    uint256 public constant CLAIM_BOND_BPS = 200;

    uint256 private constant BPS = 10_000;

    // -------------------------------------------------------------- storage

    /// @notice ERC-8004 identity registry. Ownership of an agent is ownership here.
    IIdentityRegistry public immutable registry;

    /// @notice Collateral token. USDG on Robinhood Chain.
    IERC20 public immutable currency;

    /// @notice Smallest bond worth publishing. Below it the signal means nothing.
    uint128 public immutable minBond;

    /// @notice A claim must be at least this share of the bond it is filed against.
    /// @dev One percent, and it is the only thing standing between a seller and a
    ///      flood of trivial claims locking up its collateral. Because every open
    ///      claim reserves at least a hundredth of the bond, and reservations can
    ///      never exceed the bond, **a seller can face at most 100 open claims at
    ///      once**. The attack is bounded by arithmetic rather than by a fee.
    ///
    ///      It also scales on its own. A $10 bond accepts 10 cent claims, which is
    ///      the size agents actually pay today. A $5,000 bond requires $50 claims.
    ///      The contract does not need to be redeployed when payments grow.
    uint256 public constant MIN_CLAIM_BPS = 100;

    /// @notice Floor on the claimant's stake, so 2% of a small claim is still real.
    uint128 public immutable minClaimBond;

    mapping(uint256 agentId => Bond) public bonds;
    mapping(uint256 agentId => mapping(uint64 epoch => bytes32 root)) public roots;
    mapping(uint256 claimId => Claim) public claims;
    mapping(uint256 agentId => mapping(bytes32 ref => bool)) public claimedRefs;

    uint256 public nextClaimId = 1;

    // --------------------------------------------------------------- events

    event Bonded(uint256 indexed agentId, address indexed from, uint128 amount, uint128 total);
    event WithdrawRequested(uint256 indexed agentId, uint64 withdrawAfter);
    event WithdrawCancelled(uint256 indexed agentId);
    event Withdrawn(uint256 indexed agentId, address indexed to, uint128 amount, uint128 remaining);
    event Attested(uint256 indexed agentId, uint64 indexed epoch, bytes32 root);
    event ClaimFiled(
        uint256 indexed claimId,
        uint256 indexed agentId,
        address indexed claimant,
        bytes32 ref,
        uint64 epoch,
        uint128 amount,
        uint128 claimBond
    );
    event ClaimDischarged(uint256 indexed claimId, uint256 indexed agentId, bytes32 digest);
    event ClaimSettled(uint256 indexed claimId, uint256 indexed agentId, uint128 paid);

    // --------------------------------------------------------------- errors

    error NotAgentOwner();
    error AmountZero();
    error BelowMinimum();
    error ClaimTooSmall();
    error NoticeNotGiven();
    error NoticeNotElapsed();
    error ClaimsOpen();
    error InsufficientCollateral();
    error EpochNotEnded();
    error AttestWindowClosed();
    error RootAlreadySet();
    error AttestWindowOpen();
    error ClaimPeriodElapsed();
    error RefAlreadyClaimed();
    error ClaimNotOpen();
    error NoRoot();
    error BadProof();
    error ChallengeWindowOpen();

    // ---------------------------------------------------------- constructor

    /// @param registry_ ERC-8004 identity registry
    /// @param currency_ collateral token
    /// @param minBond_ smallest bond, in `currency_` units
    /// @param minClaimBond_ floor on a claimant's stake, in `currency_` units
    constructor(
        IIdentityRegistry registry_,
        IERC20 currency_,
        uint128 minBond_,
        uint128 minClaimBond_
    ) {
        registry = registry_;
        currency = currency_;
        minBond = minBond_;
        minClaimBond = minClaimBond_;
    }

    /// @notice The smallest claim that may be filed against this agent, right now.
    ///         Scales with the bond, so the contract works at today's payment sizes
    ///         and still works when they are a hundred times larger.
    function minClaimFor(uint256 agentId) public view returns (uint128) {
        return uint128((uint256(bonds[agentId].amount) * MIN_CLAIM_BPS) / BPS);
    }

    // --------------------------------------------------------------- epochs

    /// @notice The epoch a timestamp falls in.
    function epochOf(uint256 timestamp) public pure returns (uint64) {
        return uint64(timestamp / EPOCH_LENGTH);
    }

    /// @notice The epoch now.
    function currentEpoch() public view returns (uint64) {
        return epochOf(block.timestamp);
    }

    /// @notice The moment an epoch's root becomes final, published or not.
    function attestDeadline(uint64 epoch) public pure returns (uint256) {
        return (uint256(epoch) + 1) * EPOCH_LENGTH + ATTEST_WINDOW;
    }

    // ---------------------------------------------------------------- bonds

    /// @notice Post or top up collateral for an agent.
    /// @dev Open to anyone on purpose. Only the owner ever withdraws, so a backer can
    ///      stake an agent it believes in without taking custody of anything.
    function bond(uint256 agentId, uint128 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        registry.ownerOf(agentId); // reverts if the agent was never registered

        Bond storage b = bonds[agentId];
        uint128 total = b.amount + amount;
        if (total < minBond) revert BelowMinimum();

        if (b.bondedAt == 0) b.bondedAt = uint64(block.timestamp);
        b.amount = total;

        currency.safeTransferFrom(msg.sender, address(this), amount);
        emit Bonded(agentId, msg.sender, amount, total);
    }

    /// @notice Start the notice period. The bond stays live and claimable throughout,
    ///         and a buyer can see the agent is winding down before it pays.
    function requestWithdraw(uint256 agentId) external {
        _onlyOwner(agentId);
        uint64 at = uint64(block.timestamp) + NOTICE_PERIOD;
        bonds[agentId].withdrawAfter = at;
        emit WithdrawRequested(agentId, at);
    }

    /// @notice Change your mind. An agent that quietly stays in notice forever would
    ///         read as leaving to every buyer that checks.
    function cancelWithdraw(uint256 agentId) external {
        _onlyOwner(agentId);
        if (bonds[agentId].withdrawAfter == 0) revert NoticeNotGiven();
        bonds[agentId].withdrawAfter = 0;
        emit WithdrawCancelled(agentId);
    }

    /// @notice Take collateral back, after notice, with nothing outstanding.
    function withdraw(uint256 agentId, uint128 amount) external nonReentrant {
        address owner = _onlyOwner(agentId);
        Bond storage b = bonds[agentId];

        if (b.withdrawAfter == 0) revert NoticeNotGiven();
        if (block.timestamp < b.withdrawAfter) revert NoticeNotElapsed();
        if (b.reserved != 0) revert ClaimsOpen();
        if (amount == 0) revert AmountZero();
        if (amount > b.amount) revert InsufficientCollateral();

        uint128 remaining = b.amount - amount;
        if (remaining != 0 && remaining < minBond) revert BelowMinimum();
        b.amount = remaining;

        currency.safeTransfer(owner, amount);
        emit Withdrawn(agentId, owner, amount, remaining);
    }

    // --------------------------------------------------------- attestations

    /// @notice Commit the delivery root for a finished epoch.
    /// @dev Only for an epoch that has ended and whose window is still open, and only
    ///      once. A root that could be written late, or rewritten, would let a seller
    ///      invent a delivery the moment a claim landed.
    function attest(uint256 agentId, uint64 epoch, bytes32 root) external {
        _onlyOwner(agentId);
        if (epoch >= currentEpoch()) revert EpochNotEnded();
        if (block.timestamp >= attestDeadline(epoch)) revert AttestWindowClosed();
        if (roots[agentId][epoch] != bytes32(0)) revert RootAlreadySet();

        roots[agentId][epoch] = root;
        emit Attested(agentId, epoch, root);
    }

    // --------------------------------------------------------------- claims

    /// @notice Claim against a bond for a transaction that bought nothing.
    /// @param ref what the buyer knows the transaction by, as 32 bytes
    /// @dev Filing opens only once the epoch's root is final, so the seller cannot
    ///      answer a claim with a root it wrote after seeing it.
    function fileClaim(uint256 agentId, bytes32 ref, uint64 epoch, uint128 amount)
        external
        nonReentrant
        returns (uint256 claimId)
    {
        if (amount == 0) revert AmountZero();
        if (amount < minClaimFor(agentId)) revert ClaimTooSmall();
        if (block.timestamp < attestDeadline(epoch)) revert AttestWindowOpen();
        if (block.timestamp > (uint256(epoch) + 1) * EPOCH_LENGTH + CLAIM_PERIOD) {
            revert ClaimPeriodElapsed();
        }
        if (claimedRefs[agentId][ref]) revert RefAlreadyClaimed();

        Bond storage b = bonds[agentId];
        if (amount > b.amount - b.reserved) revert InsufficientCollateral();

        uint128 stake = claimBondFor(amount);
        b.reserved += amount;
        claimedRefs[agentId][ref] = true;

        claimId = nextClaimId++;
        claims[claimId] = Claim({
            agentId: agentId,
            claimant: msg.sender,
            amount: amount,
            claimBond: stake,
            epoch: epoch,
            filedAt: uint64(block.timestamp),
            state: ClaimState.Open
        });

        currency.safeTransferFrom(msg.sender, address(this), stake);
        emit ClaimFiled(claimId, agentId, msg.sender, ref, epoch, amount, stake);
    }

    /// @notice What a claimant must stake to file.
    function claimBondFor(uint128 amount) public view returns (uint128) {
        uint256 pct = (uint256(amount) * CLAIM_BOND_BPS) / BPS;
        return uint128(pct < minClaimBond ? minClaimBond : pct);
    }

    /// @notice Answer a claim with the proof that the delivery was in the committed root.
    /// @dev The claimant knows only the ref. The seller holds the evidence and
    ///      supplies its digest, so the burden sits with the seller from end to end.
    ///      The claimant's stake goes to the bond: filing at an honest seller costs.
    function discharge(uint256 claimId, bytes32 ref, bytes32 digest, bytes32[] calldata proof)
        external
    {
        Claim storage c = claims[claimId];
        if (c.state != ClaimState.Open) revert ClaimNotOpen();
        _onlyOwner(c.agentId);

        bytes32 root = roots[c.agentId][c.epoch];
        if (root == bytes32(0)) revert NoRoot();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(ref, digest))));
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert BadProof();

        c.state = ClaimState.Discharged;

        Bond storage b = bonds[c.agentId];
        b.reserved -= c.amount;
        b.amount += c.claimBond;

        emit ClaimDischarged(claimId, c.agentId, digest);
    }

    /// @notice Pay a claim the seller never answered. Anyone may call it.
    function settle(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.state != ClaimState.Open) revert ClaimNotOpen();
        if (block.timestamp < uint256(c.filedAt) + CHALLENGE_WINDOW) revert ChallengeWindowOpen();

        c.state = ClaimState.Settled;

        Bond storage b = bonds[c.agentId];
        b.reserved -= c.amount;
        b.amount -= c.amount;

        uint128 payout = c.amount + c.claimBond;
        currency.safeTransfer(c.claimant, payout);
        emit ClaimSettled(claimId, c.agentId, c.amount);
    }

    // ----------------------------------------------------------------- read

    /// @notice The reading a buyer does before it pays.
    function available(uint256 agentId) external view returns (uint128) {
        Bond storage b = bonds[agentId];
        return b.amount - b.reserved;
    }

    // -------------------------------------------------------------- private

    function _onlyOwner(uint256 agentId) private view returns (address owner) {
        owner = registry.ownerOf(agentId);
        if (owner != msg.sender) revert NotAgentOwner();
    }
}
