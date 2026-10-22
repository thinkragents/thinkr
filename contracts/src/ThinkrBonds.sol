// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title ThinkrBonds (version 3)
/// @notice Sealed delivery evidence, with a bond that pays a buyer when a paid seller
///         goes silent.
///
/// A seller posts collateral against its ERC-8004 identity. A buyer pays the seller
/// through `pay`, which sends the money straight to the seller and reserves the same
/// amount of the seller's bond for that payment. Nothing the buyer pays is held.
///
/// Each hour a seller seals one merkle root of what it delivered. If a paid seller seals
/// nothing for the payment, in the hour of payment or the next, the buyer can claim and,
/// after 48 hours, is paid from the reserved bond.
///
/// After a second review: a six hour seal window and an appointable sealer key, so an
/// outage does not cost an honest seller; anyone may submit a valid proof; payouts go
/// wherever the owed account says; stakes from answered claims are owed to the seller.
///
/// After a third review: the owner may replace a root its sealer wrote while the window is
/// open, and a sealer only seals hours that ended after it was appointed.
///
/// Known limits: a sealer is valid again if the agent returns to the same owner, so clear
/// it before transferring. A seller should seal before transferring an agent, since only
/// the owner and its sealer can seal. An outage longer than the six hour window can still
/// cost a seller its seals. Stakes owed to a seller are collected by that address.
///
/// What this does not do: tell whether sealed work was good, or sent. A seller that seals
/// a record of every payment keeps its bond; the seal fixes that record in time, before any
/// dispute, which is the evidence an adjudicator needs. Sellers should seal every payment
/// they receive, so a payment made without an order cannot be claimed against them.
///
/// Version 1 accepted claims on payments that never happened. Version 2 recorded payments
/// but let a seller's second wallet push real buyers aside, dodge the notice period, and
/// left several ways to lock funds. Version 3 reserves cover per payment, so what a buyer
/// paid for stays reserved for that buyer until its claim window ends.
contract ThinkrBonds is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    enum PaymentState {
        None,
        Reserved, // paid, cover held, claimable in its window
        Claimed, // a claim was filed; the claim now holds the cover
        Released // the window passed unclaimed; the cover was released
    }

    enum ClaimState {
        None,
        Open,
        Discharged,
        Settled
    }

    struct Bond {
        uint128 amount; // collateral held
        uint128 reserved; // cover held for payments and open claims
        uint64 bondedAt; // first time this agent posted
        uint64 withdrawAfter; // 0 unless notice has been given
        address noticeBy; // the owner who gave notice; only it may act on it
    }

    struct Payment {
        uint256 agentId;
        address buyer;
        address seller; // who was paid, so it can answer a claim even after a transfer
        uint128 amount;
        uint64 epoch; // the hour it was paid in
        PaymentState state;
    }

    struct Claim {
        bytes32 ref;
        uint256 agentId;
        address claimant;
        address seller;
        uint128 amount; // what was paid, the cover this claim holds
        uint128 claimBond; // the claimant's own stake
        uint64 epoch; // the hour of the payment
        uint64 filedAt;
        ClaimState state;
    }

    // ----------------------------------------------------------- parameters

    /// @notice One hour per sealed root.
    uint64 public constant EPOCH_LENGTH = 1 hours;

    /// @notice How long after an hour ends a seller may still seal it. Six hours, so a
    ///         sequencer outage or an offline key does not cost an honest seller a claim.
    uint64 public constant ATTEST_WINDOW = 6 hours;

    /// @notice How long a seller has to answer a claim with a proof.
    uint64 public constant CHALLENGE_WINDOW = 48 hours;

    /// @notice How long after the payment's hour ends a claim may be filed. Agent
    ///         purchases resolve in minutes, and a long window would hold the seller's
    ///         cover for a week per payment.
    uint64 public constant CLAIM_PERIOD = 1 days;

    /// @notice You cannot take payment on Monday and pull the guarantee on Tuesday.
    uint64 public constant NOTICE_PERIOD = 7 days;

    /// @notice The claimant stakes 2% of what it claims, lost if the seller answers.
    uint256 public constant CLAIM_BOND_BPS = 200;

    uint256 private constant BPS = 10_000;

    // -------------------------------------------------------------- storage

    IIdentityRegistry public immutable registry;

    /// @notice Collateral and payment token. USDG on Robinhood Chain.
    IERC20 public immutable currency;

    /// @notice Smallest bond worth publishing.
    uint128 public immutable minBond;

    /// @notice Largest bond one agent may hold, while this contract is unaudited.
    uint128 public immutable maxBond;

    /// @notice Smallest payment, so dust payments cannot pile up claims.
    uint128 public immutable minPayment;

    /// @notice Floor on the claimant's stake, so 2% of a small claim is still real.
    uint128 public immutable minClaimBond;

    mapping(uint256 agentId => Bond) public bonds;
    mapping(uint256 agentId => mapping(uint64 epoch => bytes32 root)) public roots;
    mapping(bytes32 paymentId => Payment) public payments;
    mapping(uint256 claimId => Claim) public claims;
    mapping(address account => uint256 amount) public owed;

    struct Sealer {
        address owner; // the owner that appointed it; a transfer makes it void
        address sealer;
        uint64 since; // the first hour it may seal: hours that ended after it was appointed
    }

    /// @notice A key an agent's owner lets seal for it, so the owner key need not sign
    ///         every hour.
    mapping(uint256 agentId => Sealer) public sealers;

    /// @notice Whether an hour's root was written by the owner itself. A root an appointed
    ///         sealer wrote can be replaced by the owner while the hour's window is open,
    ///         so a leaked sealer key cannot lock the owner out of its own seal.
    mapping(uint256 agentId => mapping(uint64 epoch => bool)) public sealedByOwner;

    /// @notice The owner whose key or sealer wrote an hour's root. Only that same owner may
    ///         replace a sealer's root, so a new owner cannot overwrite the previous owner's
    ///         record after a transfer.
    mapping(uint256 agentId => mapping(uint64 epoch => address)) public sealedFor;

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
    event Released(bytes32 indexed paymentId, uint256 indexed agentId, uint128 amount);
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
    event Collected(address indexed account, address indexed to, uint256 amount);
    event SealerSet(uint256 indexed agentId, address indexed owner, address sealer);

    // --------------------------------------------------------------- errors

    error NotAgentOwner();
    error AmountZero();
    error BelowMinimum();
    error AboveMaximum();
    error NoticeNotGiven();
    error NoticeNotElapsed();
    error SellerLeaving();
    error InsufficientCollateral();
    error EpochNotEnded();
    error AttestWindowClosed();
    error RootAlreadySet();
    error AttestWindowOpen();
    error ClaimPeriodElapsed();
    error ClaimPeriodOpen();
    error PaymentExists();
    error NoSuchPayment();
    error NotThePayer();
    error AlreadyClaimed();
    error NotReserved();
    error ClaimNotOpen();
    error NotTheRightHour();
    error NoRoot();
    error BadProof();
    error ChallengeWindowOpen();
    error ChallengeWindowClosed();
    error NothingOwed();
    error EmptyRoot();
    error NotASealer();
    error SellerIsThisContract();
    error BadRecipient();

    // ---------------------------------------------------------- constructor

    constructor(
        IIdentityRegistry registry_,
        IERC20 currency_,
        uint128 minBond_,
        uint128 maxBond_,
        uint128 minPayment_,
        uint128 minClaimBond_
    ) {
        registry = registry_;
        currency = currency_;
        minBond = minBond_;
        maxBond = maxBond_;
        minPayment = minPayment_;
        minClaimBond = minClaimBond_;
    }

    // --------------------------------------------------------------- epochs

    function epochOf(uint256 timestamp) public pure returns (uint64) {
        return uint64(timestamp / EPOCH_LENGTH);
    }

    function currentEpoch() public view returns (uint64) {
        return epochOf(block.timestamp);
    }

    /// @notice The moment an hour's root becomes final, sealed or not.
    function attestDeadline(uint64 epoch) public pure returns (uint256) {
        return (uint256(epoch) + 1) * EPOCH_LENGTH + ATTEST_WINDOW;
    }

    /// @notice The first moment a claim on a payment made in `epoch` can be filed: once
    ///         both hours a seller may seal its delivery in are final.
    function claimOpens(uint64 epoch) public pure returns (uint256) {
        return attestDeadline(epoch + 1);
    }

    /// @notice The last moment a claim on a payment made in `epoch` can be filed.
    function claimCloses(uint64 epoch) public pure returns (uint256) {
        return (uint256(epoch) + 1) * EPOCH_LENGTH + CLAIM_PERIOD;
    }

    /// @notice A ref is unique per agent: one delivery record answers one payment.
    function paymentIdOf(uint256 agentId, bytes32 ref) public pure returns (bytes32) {
        return keccak256(abi.encode(agentId, ref));
    }

    // ---------------------------------------------------------------- bonds

    /// @notice Post or top up collateral. Open to anyone; only the owner withdraws.
    function bond(uint256 agentId, uint128 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        // reverts if the agent was never registered
        if (registry.ownerOf(agentId) == address(this)) revert SellerIsThisContract();

        Bond storage b = bonds[agentId];
        uint128 total = b.amount + amount;
        if (total < minBond) revert BelowMinimum();
        if (total > maxBond) revert AboveMaximum();

        if (b.bondedAt == 0) b.bondedAt = uint64(block.timestamp);
        b.amount = total;

        currency.safeTransferFrom(msg.sender, address(this), amount);
        emit Bonded(agentId, msg.sender, amount, total);
    }

    /// @notice Start the notice period. No new payments are accepted from here on;
    ///         cover already reserved stays reserved until its window ends.
    function requestWithdraw(uint256 agentId) external {
        address owner = _onlyOwner(agentId);
        Bond storage b = bonds[agentId];
        uint64 at = uint64(block.timestamp) + NOTICE_PERIOD;
        b.withdrawAfter = at;
        b.noticeBy = owner;
        emit WithdrawRequested(agentId, at);
    }

    function cancelWithdraw(uint256 agentId) external {
        _onlyOwner(agentId);
        Bond storage b = bonds[agentId];
        if (b.withdrawAfter == 0) revert NoticeNotGiven();
        b.withdrawAfter = 0;
        b.noticeBy = address(0);
        emit WithdrawCancelled(agentId);
    }

    /// @notice Take back collateral nobody is relying on, after notice the current owner
    ///         gave. Uses up the notice: the next withdrawal needs fresh notice.
    function withdraw(uint256 agentId, uint128 amount) external nonReentrant {
        address owner = _onlyOwner(agentId);
        Bond storage b = bonds[agentId];

        if (b.withdrawAfter == 0 || b.noticeBy != owner) revert NoticeNotGiven();
        if (block.timestamp < b.withdrawAfter) revert NoticeNotElapsed();
        if (amount == 0) revert AmountZero();
        if (amount > b.amount - b.reserved) revert InsufficientCollateral();

        uint128 remaining = b.amount - amount;
        if (remaining != 0 && remaining < minBond) revert BelowMinimum();
        b.amount = remaining;
        b.withdrawAfter = 0;
        b.noticeBy = address(0);

        currency.safeTransfer(owner, amount);
        emit Withdrawn(agentId, owner, amount, remaining);
    }

    // ------------------------------------------------------------- payments

    /// @notice Pay a seller, keep a record, and reserve the same amount of its bond.
    /// @dev The money goes from the buyer to the agent's owner in this call. Refuses a
    ///      payment the seller's unreserved bond cannot cover, or one made while the
    ///      seller is leaving: either way the buyer can still pay it directly, without
    ///      cover, and knows it.
    /// @param ref what both sides call this purchase; unique per agent. The seller seals
    ///        a record under it.
    function pay(uint256 agentId, bytes32 ref, uint128 amount)
        external
        nonReentrant
        returns (bytes32 paymentId)
    {
        if (amount < minPayment || amount == 0) revert BelowMinimum();
        address seller = registry.ownerOf(agentId); // reverts if never registered
        // a payment to an agent this contract owns would sit here owned by nobody
        if (seller == address(this)) revert SellerIsThisContract();

        Bond storage b = bonds[agentId];
        if (b.withdrawAfter != 0) revert SellerLeaving();
        if (amount > b.amount - b.reserved) revert InsufficientCollateral();

        paymentId = paymentIdOf(agentId, ref);
        if (payments[paymentId].state != PaymentState.None) revert PaymentExists();

        uint64 epoch = currentEpoch();
        b.reserved += amount;
        payments[paymentId] = Payment({
            agentId: agentId,
            buyer: msg.sender,
            seller: seller,
            amount: amount,
            epoch: epoch,
            state: PaymentState.Reserved
        });

        currency.safeTransferFrom(msg.sender, seller, amount);
        emit Paid(paymentId, agentId, msg.sender, seller, ref, amount, epoch);
    }

    /// @notice Release the cover held for a payment whose claim window passed unclaimed.
    ///         Anyone may call it; the seller has every reason to.
    function release(bytes32 paymentId) public {
        Payment storage p = payments[paymentId];
        if (p.state != PaymentState.Reserved) revert NotReserved();
        if (block.timestamp <= claimCloses(p.epoch)) revert ClaimPeriodOpen();
        p.state = PaymentState.Released;
        bonds[p.agentId].reserved -= p.amount;
        emit Released(paymentId, p.agentId, p.amount);
    }

    function releaseMany(bytes32[] calldata paymentIds) external {
        for (uint256 i; i < paymentIds.length; ++i) {
            release(paymentIds[i]);
        }
    }

    // --------------------------------------------------------- attestations

    /// @notice Appoint a key to seal for this agent, or clear it with address(0). Void
    ///         from the moment the agent changes hands.
    function setSealer(uint256 agentId, address sealer) external {
        address owner = _onlyOwner(agentId);
        sealers[agentId] = Sealer({owner: owner, sealer: sealer, since: currentEpoch()});
        emit SealerSet(agentId, owner, sealer);
    }

    /// @notice Seal the delivery root for a finished hour. Once, within six hours after.
    ///         The owner may seal, or the sealer it appointed.
    ///         Within the window the owner may replace a root its sealer wrote, never the
    ///         other way round, and nothing can change once the window closes, before any
    ///         claim on that hour can open.
    function attest(uint256 agentId, uint64 epoch, bytes32 root) external {
        address owner = registry.ownerOf(agentId);
        bool byOwner = msg.sender == owner;
        if (!byOwner) {
            Sealer memory appointed = sealers[agentId];
            if (appointed.sealer != msg.sender || appointed.owner != owner) revert NotASealer();
            if (epoch < appointed.since) revert NotASealer();
        }
        if (root == bytes32(0)) revert EmptyRoot();
        if (epoch >= currentEpoch()) revert EpochNotEnded();
        if (block.timestamp >= attestDeadline(epoch)) revert AttestWindowClosed();
        if (
            roots[agentId][epoch] != bytes32(0)
                && (!byOwner || sealedByOwner[agentId][epoch] || sealedFor[agentId][epoch] != owner)
        ) revert RootAlreadySet();

        roots[agentId][epoch] = root;
        sealedFor[agentId][epoch] = owner;
        if (byOwner) sealedByOwner[agentId][epoch] = true;
        emit Attested(agentId, epoch, root);
    }

    // --------------------------------------------------------------- claims

    /// @notice Claim on a payment you made, if the seller sealed nothing for it.
    function fileClaim(uint256 agentId, bytes32 ref)
        external
        nonReentrant
        returns (uint256 claimId)
    {
        bytes32 paymentId = paymentIdOf(agentId, ref);
        Payment storage p = payments[paymentId];
        if (p.state == PaymentState.None) revert NoSuchPayment();
        if (p.state == PaymentState.Claimed) revert AlreadyClaimed();
        if (p.state == PaymentState.Released) revert ClaimPeriodElapsed();
        if (p.buyer != msg.sender) revert NotThePayer();

        uint64 epoch = p.epoch;
        if (block.timestamp < claimOpens(epoch)) revert AttestWindowOpen();
        if (block.timestamp > claimCloses(epoch)) revert ClaimPeriodElapsed();

        uint128 amount = p.amount;
        uint128 stake = claimBondFor(amount);
        p.state = PaymentState.Claimed; // the cover it reserved now belongs to the claim

        claimId = nextClaimId++;
        claims[claimId] = Claim({
            ref: ref,
            agentId: agentId,
            claimant: msg.sender,
            seller: p.seller,
            amount: amount,
            claimBond: stake,
            epoch: epoch,
            filedAt: uint64(block.timestamp),
            state: ClaimState.Open
        });

        currency.safeTransferFrom(msg.sender, address(this), stake);
        emit ClaimFiled(claimId, agentId, msg.sender, ref, epoch, amount, stake);
    }

    function claimBondFor(uint128 amount) public view returns (uint128) {
        uint256 pct = (uint256(amount) * CLAIM_BOND_BPS) / BPS;
        return uint128(pct < minClaimBond ? minClaimBond : pct);
    }

    /// @notice Answer a claim with the proof that the record is in a sealed root, from the
    ///         hour of payment or the hour after, within the challenge window. Anyone may
    ///         send it: a valid proof is the same proof whoever submits it, so a seller's
    ///         defence never depends on one key being online.
    function discharge(uint256 claimId, uint64 sealedIn, bytes32 digest, bytes32[] calldata proof)
        external
    {
        Claim storage c = claims[claimId];
        if (c.state != ClaimState.Open) revert ClaimNotOpen();
        if (block.timestamp >= uint256(c.filedAt) + CHALLENGE_WINDOW) {
            revert ChallengeWindowClosed();
        }
        if (sealedIn != c.epoch && sealedIn != c.epoch + 1) revert NotTheRightHour();

        bytes32 root = roots[c.agentId][sealedIn];
        if (root == bytes32(0)) revert NoRoot();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(c.ref, digest))));
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert BadProof();

        c.state = ClaimState.Discharged;
        bonds[c.agentId].reserved -= c.amount;
        // the claimant's stake is the seller's to collect, not added to the bond, so a
        // bond never grows past its cap on its own
        owed[c.seller] += c.claimBond;

        emit ClaimDischarged(claimId, c.agentId, digest);
    }

    /// @notice Settle a claim the seller did not answer. Anyone may call it. The claimant
    ///         collects with `collect`, so nothing about one address can block a bond.
    function settle(uint256 claimId) external {
        Claim storage c = claims[claimId];
        if (c.state != ClaimState.Open) revert ClaimNotOpen();
        if (block.timestamp < uint256(c.filedAt) + CHALLENGE_WINDOW) revert ChallengeWindowOpen();

        c.state = ClaimState.Settled;
        Bond storage b = bonds[c.agentId];
        b.reserved -= c.amount;
        b.amount -= c.amount;
        owed[c.claimant] += uint256(c.amount) + c.claimBond;

        emit ClaimSettled(claimId, c.agentId, c.amount);
    }

    /// @notice Take what you are owed: a settled claim's payout, or the stakes of claims
    ///         you answered. Sent wherever you say, so a frozen or contract account can
    ///         still move it.
    function collect(address to) external nonReentrant {
        // sent here or nowhere, it would be off the books and lost
        if (to == address(this) || to == address(0)) revert BadRecipient();
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        currency.safeTransfer(to, amount);
        emit Collected(msg.sender, to, amount);
    }

    // ----------------------------------------------------------------- read

    /// @notice Cover a new payment can reserve right now.
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
