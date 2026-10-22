// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title ThinkrBonds (version 2)
/// @notice Sealed delivery evidence with a bond behind it, for agents that sell to agents.
///
/// A seller posts collateral against its ERC-8004 identity. A buyer pays the seller
/// through `pay`, which sends the money straight to the seller in the same call and
/// records that the payment happened. Nothing is held: this is a receipt, not escrow.
///
/// Each hour a seller commits one merkle root of what it delivered. A buyer whose
/// recorded payment bought nothing files a claim once that hour's root is final. The
/// seller discharges it by proving the delivery is in a root it already committed. It
/// cannot forge one after the fact, because the window to commit a root closes before
/// the window to claim against it opens.
///
/// Version 1 let anyone claim on any reference. A claim on a payment that never
/// happened could not be answered, since there is no delivery to prove, so it paid out
/// against honest sellers. Version 2 only accepts claims on payments this contract
/// recorded, from the address that made them, for exactly what was paid.
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

    struct Payment {
        uint256 agentId;
        address buyer;
        uint128 amount;
        uint64 epoch; // the hour it was paid in
        bool claimed;
    }

    struct Claim {
        bytes32 paymentId;
        uint256 agentId;
        address claimant;
        uint128 amount; // what was paid, reserved out of the bond
        uint128 claimBond; // the claimant's own stake
        uint64 epoch; // the hour of the payment
        uint64 filedAt;
        ClaimState state;
        bytes32 ref;
    }

    // ----------------------------------------------------------- parameters

    /// @notice One hour. Short enough that proofs stay small and a seller defends a
    ///         root an hour old, cheap enough to commit on this chain.
    uint64 public constant EPOCH_LENGTH = 1 hours;

    /// @notice How long after an epoch ends a seller may still commit its root.
    uint64 public constant ATTEST_WINDOW = 1 hours;

    /// @notice How long a seller has to answer a claim with a proof.
    uint64 public constant CHALLENGE_WINDOW = 48 hours;

    /// @notice How long after the payment's hour ends a claim may be filed.
    uint64 public constant CLAIM_PERIOD = 7 days;

    /// @notice You cannot take payment on Monday and pull the guarantee on Tuesday.
    uint64 public constant NOTICE_PERIOD = 7 days;

    /// @notice The claimant stakes 2% of what it claims. Lost if the seller proves
    ///         delivery, so claiming on work that arrived costs money.
    uint256 public constant CLAIM_BOND_BPS = 200;

    uint256 private constant BPS = 10_000;

    // -------------------------------------------------------------- storage

    /// @notice ERC-8004 identity registry. Ownership of an agent is ownership here.
    IIdentityRegistry public immutable registry;

    /// @notice Collateral and payment token. USDG on Robinhood Chain.
    IERC20 public immutable currency;

    /// @notice Smallest bond worth publishing.
    uint128 public immutable minBond;

    /// @notice Floor on the claimant's stake, so 2% of a small claim is still real.
    uint128 public immutable minClaimBond;

    mapping(uint256 agentId => Bond) public bonds;
    mapping(uint256 agentId => mapping(uint64 epoch => bytes32 root)) public roots;
    mapping(bytes32 paymentId => Payment) public payments;
    mapping(uint256 claimId => Claim) public claims;

    uint256 public nextClaimId = 1;

    // --------------------------------------------------------------- events

    event Bonded(uint256 indexed agentId, address indexed from, uint128 amount, uint128 total);
    event WithdrawRequested(uint256 indexed agentId, uint64 withdrawAfter);
    event WithdrawCancelled(uint256 indexed agentId);
    event Withdrawn(uint256 indexed agentId, address indexed to, uint128 amount, uint128 remaining);
    event Attested(uint256 indexed agentId, uint64 indexed epoch, bytes32 root);
    event Paid(
        bytes32 indexed paymentId,
        uint256 indexed agentId,
        address indexed buyer,
        address seller,
        bytes32 ref,
        uint128 amount,
        uint64 epoch
    );
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
    error NoticeNotGiven();
    error NoticeNotElapsed();
    error ClaimsOpen();
    error InsufficientCollateral();
    error EpochNotEnded();
    error AttestWindowClosed();
    error RootAlreadySet();
    error AttestWindowOpen();
    error ClaimPeriodElapsed();
    error PaymentExists();
    error NoSuchPayment();
    error AlreadyClaimed();
    error ClaimNotOpen();
    error NotTheRightHour();
    error NoRoot();
    error BadProof();
    error ChallengeWindowOpen();

    // ---------------------------------------------------------- constructor

    /// @param registry_ ERC-8004 identity registry
    /// @param currency_ collateral and payment token
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

    // --------------------------------------------------------------- epochs

    /// @notice The epoch a timestamp falls in.
    function epochOf(uint256 timestamp) public pure returns (uint64) {
        return uint64(timestamp / EPOCH_LENGTH);
    }

    /// @notice The epoch now.
    function currentEpoch() public view returns (uint64) {
        return epochOf(block.timestamp);
    }

    /// @notice The moment an epoch's root becomes final, sealed or not.
    function attestDeadline(uint64 epoch) public pure returns (uint256) {
        return (uint256(epoch) + 1) * EPOCH_LENGTH + ATTEST_WINDOW;
    }

    /// @notice The id a payment is recorded under. Namespaced by buyer, so nobody can
    ///         take a buyer's reference by paying first.
    function paymentIdOf(uint256 agentId, address buyer, bytes32 ref)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(agentId, buyer, ref));
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

    /// @notice Change your mind.
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

    // ------------------------------------------------------------- payments

    /// @notice Pay a seller and keep a record that you did.
    /// @dev The money goes from the buyer to the agent's owner in this call; the
    ///      contract never holds it. The record is what makes a claim possible: a
    ///      claim must name a payment recorded here, by the address that made it.
    /// @param ref what both sides call this purchase. The seller seals deliveries
    ///        under it, so it should be the reference the seller's service returns.
    function pay(uint256 agentId, bytes32 ref, uint128 amount)
        external
        nonReentrant
        returns (bytes32 paymentId)
    {
        if (amount == 0) revert AmountZero();
        address seller = registry.ownerOf(agentId); // reverts if never registered

        paymentId = paymentIdOf(agentId, msg.sender, ref);
        if (payments[paymentId].buyer != address(0)) revert PaymentExists();

        uint64 epoch = currentEpoch();
        payments[paymentId] = Payment({
            agentId: agentId, buyer: msg.sender, amount: amount, epoch: epoch, claimed: false
        });

        currency.safeTransferFrom(msg.sender, seller, amount);
        emit Paid(paymentId, agentId, msg.sender, seller, ref, amount, epoch);
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

    /// @notice Claim against a bond for a recorded payment that bought nothing.
    /// @dev Only the buyer who paid, only once, only for what was paid. Filing opens
    ///      once the roots for the payment's hour and the hour after are final, the
    ///      two hours a seller may seal the delivery in, so it can never answer a
    ///      claim with a root written after seeing it.
    function fileClaim(uint256 agentId, bytes32 ref)
        external
        nonReentrant
        returns (uint256 claimId)
    {
        bytes32 paymentId = paymentIdOf(agentId, msg.sender, ref);
        Payment storage p = payments[paymentId];
        if (p.buyer == address(0)) revert NoSuchPayment();
        if (p.claimed) revert AlreadyClaimed();

        uint64 epoch = p.epoch;
        if (block.timestamp < attestDeadline(epoch + 1)) revert AttestWindowOpen();
        if (block.timestamp > (uint256(epoch) + 1) * EPOCH_LENGTH + CLAIM_PERIOD) {
            revert ClaimPeriodElapsed();
        }

        uint128 amount = p.amount;
        Bond storage b = bonds[agentId];
        if (amount > b.amount - b.reserved) revert InsufficientCollateral();

        uint128 stake = claimBondFor(amount);
        p.claimed = true;
        b.reserved += amount;

        claimId = nextClaimId++;
        claims[claimId] = Claim({
            paymentId: paymentId,
            agentId: agentId,
            claimant: msg.sender,
            amount: amount,
            claimBond: stake,
            epoch: epoch,
            filedAt: uint64(block.timestamp),
            state: ClaimState.Open,
            ref: ref
        });

        currency.safeTransferFrom(msg.sender, address(this), stake);
        emit ClaimFiled(claimId, agentId, msg.sender, ref, epoch, amount, stake);
    }

    /// @notice What a claimant must stake to file.
    function claimBondFor(uint128 amount) public view returns (uint128) {
        uint256 pct = (uint256(amount) * CLAIM_BOND_BPS) / BPS;
        return uint128(pct < minClaimBond ? minClaimBond : pct);
    }

    /// @notice Answer a claim with the proof that the delivery is in a committed root.
    /// @dev The seller may prove it in the root for the payment's hour or the hour
    ///      after, so work paid at 10:59 and delivered at 11:01 still counts. The
    ///      claimant's stake goes to the bond: claiming on work that arrived costs.
    function discharge(uint256 claimId, uint64 sealedIn, bytes32 digest, bytes32[] calldata proof)
        external
    {
        Claim storage c = claims[claimId];
        if (c.state != ClaimState.Open) revert ClaimNotOpen();
        _onlyOwner(c.agentId);
        if (sealedIn != c.epoch && sealedIn != c.epoch + 1) revert NotTheRightHour();

        bytes32 root = roots[c.agentId][sealedIn];
        if (root == bytes32(0)) revert NoRoot();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(c.ref, digest))));
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
