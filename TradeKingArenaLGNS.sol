// SPDX-License-Identifier: MIT
// =============================================================
//  TradeKing Arena (Anubis Edition) - TradeKingArenaLGNS.sol
//
//  Official game ......... https://game.tradekingarena.com/anubis/
//  Block explorer ........ https://browser.anubispace.org/address/0x3884c464f5134b181b8a097ED930c35E5E6943ef
//
//  SECURITY AUDIT: 3 rounds completed before mainnet deployment -
//    Round 1: Guardian security audit ............ 72/100
//    Round 2: AuditAgent business-logic audit .... 82/100
//    Round 3: Guardian incremental re-audit ..... 94/100 (initial 91, +2 G-4 fix, +1 N-4 retest)
//  All blocking findings (WEEK_ALIGN, role-separation, oracle seed)
//  fixed and re-verified. Deployed 2026-09-20 on Anubis Chain.
//  Game token: LGNS (9 decimals). Maintained by Jimu Agent.
// =============================================================

pragma solidity ^0.8.24;

/// @title TradeKing Arena - LGNS Edition (Anubis Chain, EVM port)
/// @notice Mirrors the TON Game v3.13.1 semantics on an EVM chain:
///         LGNS entry fees split 60% track prize pool / 40% operations
///         treasury; dual-oracle consensus on final standings; weekly
///         settlement executable only inside the Monday 00:00-02:00 UTC
///         window; top-3 ranks pay 15% / 10% / 5% of the track pool; the
///         remainder rolls over into the active pool of the same track,
///         capped at POOL_CAP (100k LGNS) - any surplus above the cap is
///         burned automatically to the canonical LGNS burn address
///         (structural rule, no oracle/owner signature required).
/// @dev Feature map from TON v3.13:
///      EmergencyWithdraw          -> emergencyWithdraw() owner sweep
///      UpdateOracle dual+cooldown -> propose/confirm/activate (owner + signerB, 24h)
///      ClaimPrize order-free      -> pull-based claimable balances
///      Tracks 1-16 generic        -> trackId 1..16
///      Treasury seed injection    -> seed() bypasses the 60/40 split
///      Week counter               -> derived on-chain from block.timestamp
///                                     (TON version advanced it via oracle
///                                     submissions; deterministic here)
///      Missed settle window       -> a past unsettled week may still be
///                                     settled inside any later Monday
///                                     window; rollover joins the current
///                                     active pool so funds can never get
///                                     trapped in an already-settled week.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TradeKingArenaLGNS {
    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------
    address public owner;     // governance (Anye-controlled)
    address public signerB;   // co-signer for oracle rotation (Jimu)
    address public oracleA;
    address public oracleB;
    address public opsWallet; // operations treasury (40% share)

    IERC20 public immutable lgns;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    uint256 public constant WEEK           = 604800;  // 7 days
    uint256 public constant WEEK_ALIGN     = 259200;  // epoch=Thu; Mon 00:00 UTC has ts%WEEK==345600, so week=(ts+259200)/WEEK => 259200=WEEK-345600 (Guardian audit fix 2026-09-20)
    uint256 public constant SETTLE_WINDOW  = 7200;    // Mon 00:00-02:00 UTC
    uint256 public constant ORACLE_COOLDOWN = 24 hours;

    uint8   public constant N_TRACKS = 16;
    uint256 public constant BPS        = 10000;
    uint256 public constant SHARE_RANK1 = 1500; // 15%
    uint256 public constant SHARE_RANK2 = 1000; // 10%
    uint256 public constant SHARE_RANK3 = 500;  //  5%
    uint256 public constant OPS_SHARE   = 4000; // 40% operations treasury

    // Pool overflow auto-burn (owner rule 2026-09-20): each track's active
    // pool holds at most POOL_CAP; at settlement any rollover surplus above
    // the cap is transferred straight to BURN_ADDRESS. Fully structural -
    // no multisig, no oracle, no owner action.
    uint256 public constant POOL_CAP = 100_000 * 1e9; // 100k LGNS (9 dec) per-track
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD; // canonical LGNS burn sink (820.7M LGNS held, chain-verified 2026-09-20)

    // LGNS verified on-chain 2026-09-20: symbol LGNS, name "Longinus",
    // decimals 9, total supply ~3.71B. Fee amounts below are raw units.

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    uint256[3] public tierFees; // raw LGNS (9 decimals); 0 disables the tier

    // week => track => players
    mapping(uint256 => mapping(uint8 => address[])) private _players;
    // week => track => player => tier + 1 (0 = not enrolled)
    mapping(uint256 => mapping(uint8 => mapping(address => uint8))) public tierOf;
    // week => track => pool (raw LGNS)
    mapping(uint256 => mapping(uint8 => uint256)) public trackPool;
    // week => track => oracle => result root
    mapping(uint256 => mapping(uint8 => mapping(address => bytes32))) public resultRoot;
    // week => track => settled flag
    mapping(uint256 => mapping(uint8 => bool)) public settled;
    // pull-based prize bookkeeping
    mapping(address => uint256) public claimable;

    // oracle rotation proposal (dual-sig + cooldown)
    address public pendingOracleA;
    address public pendingOracleB;
    bool    public oracleProposalConfirmed;
    uint256 public oracleReadyAt;
    uint256 public lastOracleChange;

    bool public enrollmentPaused;

    // simple reentrancy guard
    uint256 private _locked;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event Enrolled(uint256 indexed week, uint8 indexed track, address indexed player, uint8 tier, uint256 fee, uint256 toPool);
    event Seeded(uint256 indexed week, uint8 indexed track, address indexed from, uint256 amount);
    event ResultSubmitted(uint256 indexed week, uint8 indexed track, address indexed oracle, bytes32 root);
    event Settled(uint256 indexed week, uint8 indexed track, uint256 pool, uint256 paidOut, uint256 rolledOver, address r1, address r2, address r3);
    event PoolOverflowBurned(uint256 indexed week, uint8 indexed track, uint256 amount);
    event PrizeClaimed(address indexed player, uint256 amount);
    event EmergencyWithdrawn(address indexed to, uint256 amount);
    event OracleProposed(address newA, address newB);
    event OracleConfirmed(address newA, address newB);
    event OracleActivated(address newA, address newB);
    event OracleUpdateCancelled();
    event TierFeesUpdated(uint256 f0, uint256 f1, uint256 f2);
    event OpsWalletUpdated(address indexed newOps);
    event EnrollmentPauseToggled(bool paused);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlySignerB() {
        require(msg.sender == signerB, "not signerB");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracleA || msg.sender == oracleB, "not oracle");
        _;
    }

    modifier noReentry() {
        require(_locked == 1, "reentry");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    constructor(
        address lgns_,
        address owner_,
        address signerB_,
        address oracleA_,
        address oracleB_,
        address opsWallet_,
        uint256 feeTier0,
        uint256 feeTier1,
        uint256 feeTier2
    ) {
        require(
            lgns_ != address(0) && owner_ != address(0) && signerB_ != address(0)
                && oracleA_ != address(0) && oracleB_ != address(0) && opsWallet_ != address(0),
            "zero address"
        );
        // Role distinctness (Guardian audit fix 2026-09-20): dual-sign paths
        // must not degenerate into single-signature control, and signerB has
        // no on-chain rotation path, so misassignment is unfixable.
        require(
            oracleA_ != oracleB_ && signerB_ != owner_ && signerB_ != oracleA_
                && signerB_ != oracleB_ && oracleA_ != owner_ && oracleB_ != owner_,
            "roles must be distinct"
        );
        lgns = IERC20(lgns_);
        owner = owner_;
        signerB = signerB_;
        oracleA = oracleA_;
        oracleB = oracleB_;
        opsWallet = opsWallet_;
        tierFees = [feeTier0, feeTier1, feeTier2];
        _locked = 1;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------
    // Time helpers
    // ------------------------------------------------------------------
    /// @dev Weeks are Monday 00:00 UTC aligned and derived from block time.
    function currentWeek() public view returns (uint256) {
        return (block.timestamp + WEEK_ALIGN) / WEEK;
    }

    /// @dev True only during Mon 00:00:00 - 01:59:59 UTC.
    function inSettleWindow() public view returns (bool) {
        return (block.timestamp + WEEK_ALIGN) % WEEK < SETTLE_WINDOW;
    }

    // ------------------------------------------------------------------
    // Enrollment
    // ------------------------------------------------------------------
    /// @notice Enroll for the current week on a track. Pulls the tier fee
    ///         via transferFrom: callers must approve this contract first.
    function enroll(uint8 trackId, uint8 tier) external noReentry {
        require(!enrollmentPaused, "enrollment paused");
        require(trackId >= 1 && trackId <= N_TRACKS, "bad track");
        require(tier < 3, "bad tier");
        uint256 fee = tierFees[tier];
        require(fee > 0, "tier disabled");

        uint256 w = currentWeek();
        require(tierOf[w][trackId][msg.sender] == 0, "already enrolled");

        // Effects first (CEI, audit hardening 2026-09-20), then interactions.
        _players[w][trackId].push(msg.sender);
        tierOf[w][trackId][msg.sender] = tier + 1;
        uint256 ops = (fee * OPS_SHARE) / BPS;
        uint256 toPool = fee - ops;
        trackPool[w][trackId] += toPool;

        require(lgns.transferFrom(msg.sender, address(this), fee), "fee pull failed");
        require(lgns.transfer(opsWallet, ops), "ops transfer failed");

        emit Enrolled(w, trackId, msg.sender, tier, fee, toPool);
    }

    // ------------------------------------------------------------------
    // Seed injection (bypasses the 60/40 split)
    // ------------------------------------------------------------------
    /// @notice Inject LGNS straight into a track pool for the current week.
    ///         Mirrors the TON treasury seed path: 100% goes to the pool.
    function seed(uint8 trackId, uint256 amount) external onlyOwner noReentry {
        require(trackId >= 1 && trackId <= N_TRACKS, "bad track");
        require(amount > 0, "zero amount");
        require(lgns.transferFrom(msg.sender, address(this), amount), "seed pull failed");
        uint256 w = currentWeek();
        trackPool[w][trackId] += amount;
        emit Seeded(w, trackId, msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Oracle result submission
    // ------------------------------------------------------------------
    /// @notice Submit (or correct) the final standings root for a closed
    ///         week. Both oracles must submit identical roots to form
    ///         consensus. Rank addresses must be contiguous from rank 1.
    function submitResult(uint256 weekId, uint8 trackId, address r1, address r2, address r3) external onlyOracle {
        require(trackId >= 1 && trackId <= N_TRACKS, "bad track");
        require(weekId < currentWeek(), "week not closed");
        require(!settled[weekId][trackId], "already settled");
        if (r1 == address(0)) {
            require(r2 == address(0) && r3 == address(0), "bad ranks");
        }
        if (r2 == address(0)) {
            require(r3 == address(0), "bad ranks");
        }
        // G-4 fix (2026-09-20 incremental re-audit): winners must be real
        // enrolled players of this week/track and mutually distinct.
        if (r1 != address(0)) {
            require(tierOf[weekId][trackId][r1] != 0, "rank1 not enrolled");
            if (r2 != address(0)) {
                require(r2 != r1 && tierOf[weekId][trackId][r2] != 0, "rank2 invalid");
            }
            if (r3 != address(0)) {
                require(r3 != r1 && r3 != r2 && tierOf[weekId][trackId][r3] != 0, "rank3 invalid");
            }
        }
        bytes32 root = keccak256(abi.encode(weekId, trackId, r1, r2, r3));
        resultRoot[weekId][trackId][msg.sender] = root;
        emit ResultSubmitted(weekId, trackId, msg.sender, root);
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------
    /// @notice Settle a closed week's track inside the Monday settle
    ///         window. Requires matching oracle roots; the caller passes
    ///         the standings which are verified against the stored root.
    ///         Top-3 receive 15/10/5%; the remainder rolls into the
    ///         current active pool of the same track, capped at POOL_CAP;
    ///         surplus above the cap auto-burns to BURN_ADDRESS.
    function triggerSettlement(uint256 weekId, uint8 trackId, address r1, address r2, address r3)
        external
        noReentry
    {
        require(trackId >= 1 && trackId <= N_TRACKS, "bad track");
        require(weekId < currentWeek(), "week not closed");
        require(inSettleWindow(), "not settle window");
        require(!settled[weekId][trackId], "already settled");

        bytes32 ra = resultRoot[weekId][trackId][oracleA];
        bytes32 rb = resultRoot[weekId][trackId][oracleB];
        require(ra != bytes32(0) && ra == rb, "no oracle consensus");

        bytes32 calc = keccak256(abi.encode(weekId, trackId, r1, r2, r3));
        require(calc == ra, "result mismatch");

        uint256 pool = trackPool[weekId][trackId];
        uint256 paid = 0;
        if (r1 != address(0)) {
            uint256 p = (pool * SHARE_RANK1) / BPS;
            claimable[r1] += p;
            paid += p;
        }
        if (r2 != address(0)) {
            uint256 p = (pool * SHARE_RANK2) / BPS;
            claimable[r2] += p;
            paid += p;
        }
        if (r3 != address(0)) {
            uint256 p = (pool * SHARE_RANK3) / BPS;
            claimable[r3] += p;
            paid += p;
        }

        uint256 roll = pool - paid;
        trackPool[weekId][trackId] = 0;
        uint256 injected = _rollWithCap(trackId, roll);
        settled[weekId][trackId] = true;

        emit Settled(weekId, trackId, pool, paid, injected, r1, r2, r3);
    }

    /// @dev Rollover with pool cap (owner rule 2026-09-20): injects `roll`
    ///      into the CURRENT active pool of the track, but the active pool
    ///      holds at most POOL_CAP; any surplus above the cap is burned
    ///      immediately to BURN_ADDRESS. Fully structural - no multisig.
    function _rollWithCap(uint8 trackId, uint256 roll) private returns (uint256 injected) {
        uint256 target = currentWeek();
        uint256 cur = trackPool[target][trackId];
        uint256 room = cur >= POOL_CAP ? 0 : POOL_CAP - cur;
        injected = roll <= room ? roll : room;
        uint256 burnAmt = roll - injected;
        trackPool[target][trackId] = cur + injected;
        if (burnAmt > 0) {
            require(lgns.transfer(BURN_ADDRESS, burnAmt), "burn transfer failed");
            emit PoolOverflowBurned(target, trackId, burnAmt);
        }
    }

    // ------------------------------------------------------------------
    // Claims (order-free pull pattern)
    // ------------------------------------------------------------------
    function claimPrize() external noReentry {
        uint256 amt = claimable[msg.sender];
        require(amt > 0, "nothing to claim");
        claimable[msg.sender] = 0;
        require(lgns.transfer(msg.sender, amt), "claim transfer failed");
        emit PrizeClaimed(msg.sender, amt);
    }

    // ------------------------------------------------------------------
    // Admin: emergency withdraw (mirrors TON EmergencyWithdraw)
    // ------------------------------------------------------------------
    /// @notice Owner-only last resort. Sweeps the ENTIRE contract balance
    ///         including unclaimed prizes and current pools.
    function emergencyWithdraw() external onlyOwner noReentry {
        uint256 bal = lgns.balanceOf(address(this));
        require(bal > 0, "empty");
        require(lgns.transfer(owner, bal), "sweep failed");
        emit EmergencyWithdrawn(owner, bal);
    }

    // ------------------------------------------------------------------
    // Admin: oracle rotation (dual-sig + cooldown, mirrors TON UpdateOracle)
    // ------------------------------------------------------------------
    function proposeOracleUpdate(address newA, address newB) external onlyOwner {
        require(newA != address(0) && newB != address(0), "zero address");
        require(block.timestamp >= lastOracleChange + ORACLE_COOLDOWN, "cooldown active");
        pendingOracleA = newA;
        pendingOracleB = newB;
        oracleProposalConfirmed = false;
        oracleReadyAt = 0;
        emit OracleProposed(newA, newB);
    }

    function confirmOracleUpdate() external onlySignerB {
        require(pendingOracleA != address(0), "no proposal");
        oracleProposalConfirmed = true;
        oracleReadyAt = block.timestamp + ORACLE_COOLDOWN;
        emit OracleConfirmed(pendingOracleA, pendingOracleB);
    }

    function activateOracleUpdate() external onlyOwner {
        require(pendingOracleA != address(0), "no proposal");
        require(oracleProposalConfirmed, "not confirmed by signerB");
        require(block.timestamp >= oracleReadyAt, "cooldown pending");
        oracleA = pendingOracleA;
        oracleB = pendingOracleB;
        lastOracleChange = block.timestamp;
        pendingOracleA = address(0);
        pendingOracleB = address(0);
        oracleProposalConfirmed = false;
        oracleReadyAt = 0;
        emit OracleActivated(oracleA, oracleB);
    }

    function cancelOracleUpdate() external onlyOwner {
        require(pendingOracleA != address(0), "no proposal");
        pendingOracleA = address(0);
        pendingOracleB = address(0);
        oracleProposalConfirmed = false;
        oracleReadyAt = 0;
        emit OracleUpdateCancelled();
    }

    // ------------------------------------------------------------------
    // Admin: parameters
    // ------------------------------------------------------------------
    /// @notice Tier fees in raw LGNS units (9 decimals). 0 disables a tier.
    function setTierFees(uint256 f0, uint256 f1, uint256 f2) external onlyOwner {
        tierFees = [f0, f1, f2];
        emit TierFeesUpdated(f0, f1, f2);
    }

    function setOpsWallet(address newOps) external onlyOwner {
        require(newOps != address(0), "zero address");
        opsWallet = newOps;
        emit OpsWalletUpdated(newOps);
    }

    function setEnrollmentPaused(bool p) external onlyOwner {
        enrollmentPaused = p;
        emit EnrollmentPauseToggled(p);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    function playerCount(uint256 weekId, uint8 trackId) external view returns (uint256) {
        return _players[weekId][trackId].length;
    }

    function players(uint256 weekId, uint8 trackId) external view returns (address[] memory) {
        return _players[weekId][trackId];
    }

    function poolOf(uint256 weekId, uint8 trackId) external view returns (uint256) {
        return trackPool[weekId][trackId];
    }

    function claimableOf(address player) external view returns (uint256) {
        return claimable[player];
    }
}
