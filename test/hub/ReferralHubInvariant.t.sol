// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Six-decimal mintable USD stand-in for the hub tests.
 */
contract MockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Drives the mainnet referral hub through bounded random intake
 * across a closed universe of three allowlisted local reporters (the
 * second tagged vault system 1), one registered remote vault (also
 * system 1), four referrers and two couriers: local `deliverCrumbs`,
 * `deliverGap` and `reportSelf` on closed weeks, remote envelopes
 * carrying an optional one-week self run plus one crumb, received
 * through a pranked router and applied at once or held and applied
 * later in any order (replays included), the permissionless
 * `settleWeek`, future-only rate tables (and the two refused shapes),
 * the courier share cap, partial claims on both chains, a late remote
 * designation, and warps.
 *
 * The report ghosts are chosen by the handler, never read back from
 * the hub: per (source, referrer, week) cell the lane-wise high-water
 * cursor, the largest referred average any delivery reported and the
 * largest self average any run reported. These rebuild the week buckets
 * and the cursors exactly. The fee ghost and the exactness checks read
 * the hub's cursors and rates around a call; B2 and B3 pin those reads
 * after every call. After a delivery that moved its cell's cursor, and
 * after a self run that raised a week's rates (for the reporter's own
 * cell), the cell must hold exactly its due.
 * The courier fee ghost restates the fee rule independently of the
 * intake: a delivery whose deliverer is not the referrer earns the
 * increment it priced times the share of the table in force for the
 * priced week, clamped by the share cap the handler last set, credited
 * to the delivery's chain (every delivered week is closed at build, so
 * the build-window gate always passes here). The fee basis is the
 * delivered increment's own due at the week's rates after the call:
 * the due of the cursor after it less the due of the cursor before it,
 * both at those rates, never a pending top-up the delivery collects
 * for its source; the accrual law then pins the ghost to the cells'
 * paid halves.
 *
 * `settleWeek` is checked in the handler itself: right after the call
 * every listed source of the referrer must hold exactly the due of its
 * cursor at the week's current rates, which is the arrival-order
 * independence the lazy top-up promises once settled.
 */
contract ReferralHubInvariantHandler is Test {

    struct Cell {
        bytes32 source;
        address referrer;
        uint256 week;
    }

    struct HeldEnvelope {
        bytes32 messageId;
        bytes payload;
        address deliverer;
        address referrer;
        uint256 week;
        uint256 word;
        uint256 selfAverage;
        uint256 stamp;
    }

    struct Delivery {
        bytes32 source;
        address referrer;
        address deliverer;
        uint256 week;
        uint256 chainId;
        uint256 cursorBefore;
    }

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal constant MAX_AVERAGE = 1_200_000 * 1e6;

    uint256 internal constant MAX_BOT_SHARE_BPS = 2_000;

    uint256 internal constant MAX_SHARE_CAP_DECADES = 9;

    uint256 internal constant WEEK_BACK = 6;

    uint256 internal constant MAX_ELEVATION_WINDOWS = 8;

    address public constant REMOTE_VAULT = address(0xE1);

    uint64 public constant REMOTE_SELECTOR = 7_777;

    uint256 public constant REMOTE_CHAIN_ID = 8_453;

    address public constant COURIER = address(0xE7);

    address public constant COURIER2 = address(0xE8);

    address public constant ROUTER = address(0xF1);

    address public constant REMOTE_REGISTRY = address(0xE2);

    address public constant LATE_REFERRER = address(0xB4);

    IReferralHub internal immutable hub;

    address[3] internal reporters;

    address[4] internal referrers;

    Cell[] public cells;

    mapping(bytes32 => bool) internal cellSeen;

    mapping(bytes32 => uint256) public ghostY1;

    mapping(bytes32 => uint256) public ghostY2;

    mapping(bytes32 => uint256) public ghostM;

    mapping(bytes32 => uint256) public ghostReferred;

    mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) public ghostSelf;

    mapping(address => mapping(uint256 => bool)) internal weekSeen;

    address[] public weekReferrers;

    uint256[] public weekList;

    mapping(uint256 => mapping(address => uint256)) public ghostFee;

    mapping(uint256 => mapping(address => uint256)) public ghostCourierClaimed;

    uint256 public ghostShareCap;

    uint256 public ghostSettleViolations;

    uint256 public ghostExactPayViolations;

    uint256 public inlineSelfTopUps;

    uint256 public ghostUndesignatedClaimViolations;

    uint256 public ghostTableGateViolations;

    HeldEnvelope[] internal held;

    uint256 public remoteNonce;

    uint256 public localCrumbs;

    uint256 public localGaps;

    uint256 public selfRuns;

    uint256 public remoteApplies;

    uint256 public heldApplies;

    uint256 public settles;

    uint256 public feesPaid;

    uint256 public tablesPushed;

    uint256 public refusedTables;

    uint256 public shareCapSets;

    uint256 public lateReleaseCount;

    uint256 public undesignatedClaimRefusals;

    mapping(address => uint256) public ghostElevatedFrom;

    mapping(address => uint256) public ghostElevatedUntil;

    mapping(address => uint256[]) internal ghostWindowFrom;

    mapping(address => uint256[]) internal ghostWindowUntil;

    uint256 public elevations;

    uint256 public elevationEnds;

    uint256 public refusedElevations;

    uint256 public ghostElevationGateViolations;

    constructor(
        IReferralHub _hub,
        address[3] memory _reporters,
        address[4] memory _referrers
    ) {
        hub = _hub;
        reporters = _reporters;
        referrers = _referrers;
    }

    // ---- views for the invariant contract ----

    function cellsLength()
        external
        view
        returns (uint256)
    {
        return cells.length;
    }

    function weeksLength()
        external
        view
        returns (uint256)
    {
        return weekList.length;
    }

    function cellKey(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _source,
                _referrer,
                _week
            )
        );
    }

    function sourceAt(
        uint256 _index
    )
        public
        view
        returns (bytes32)
    {
        if (_index < reporters.length) {
            return hub.sourceKeyOf(
                block.chainid,
                reporters[_index]
            );
        }

        return remoteSource();
    }

    function remoteSource()
        public
        view
        returns (bytes32)
    {
        return hub.sourceKeyOf(
            REMOTE_CHAIN_ID,
            REMOTE_VAULT
        );
    }

    function heldCount()
        external
        view
        returns (uint256)
    {
        return held.length;
    }

    // ---- local intake ----

    function deliverCrumbs(
        uint256 _reporterSeed,
        uint256 _referrerSeed,
        uint256 _weekSeed,
        uint256 _laneSeed,
        uint256 _delivererSeed
    )
        external
    {
        address reporter = reporters[_reporterSeed % reporters.length];

        address referrer = referrers[_referrerSeed % referrers.length];

        uint256 week = _closedWeek(
            _weekSeed
        );

        uint256 word = _laneWord(
            _laneSeed
        );

        Delivery memory delivery = _openDelivery(
            hub.sourceKeyOf(
                block.chainid,
                reporter
            ),
            referrer,
            _pickDeliverer(
                _delivererSeed,
                referrer
            ),
            week,
            block.chainid
        );

        uint256[] memory weeksArg = new uint256[](1);
        weeksArg[0] = week;

        uint256[] memory words = new uint256[](1);
        words[0] = word | CohortWeeks.CRUMB_WRITTEN_BIT;

        vm.prank(
            reporter
        );

        hub.deliverCrumbs(
            referrer,
            delivery.deliverer,
            weeksArg,
            words
        );

        _noteWord(
            delivery,
            word
        );

        _closeDelivery(
            delivery
        );

        ++localCrumbs;
    }

    function deliverGap(
        uint256 _reporterSeed,
        uint256 _referrerSeed,
        uint256 _weekSeed,
        uint256 _spanSeed,
        uint256 _matureSeed,
        uint256 _delivererSeed
    )
        external
    {
        address reporter = reporters[_reporterSeed % reporters.length];

        address referrer = referrers[_referrerSeed % referrers.length];

        uint256 toWeek = _closedWeek(_weekSeed) + 1;

        uint256 fromWeek = toWeek - bound(
            _spanSeed,
            1,
            3
        );

        uint256 mature = bound(
            _matureSeed,
            1,
            MAX_AVERAGE
        );

        address deliverer = _pickDeliverer(
            _delivererSeed,
            referrer
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            reporter
        );

        uint256[] memory cursorBefore = new uint256[](
            toWeek - fromWeek
        );

        for (uint256 week = fromWeek; week < toWeek; ++week) {
            cursorBefore[week - fromWeek] = _cursorOf(
                source,
                referrer,
                week
            );
        }

        vm.prank(
            reporter
        );

        hub.deliverGap(
            referrer,
            deliverer,
            fromWeek
                | (toWeek << CohortWeeks.GAP_TO_SHIFT)
                | (mature << CohortWeeks.GAP_MATURE_SHIFT),
            fromWeek,
            toWeek - fromWeek
        );

        for (uint256 week = fromWeek; week < toWeek; ++week) {

            Delivery memory delivery = Delivery({
                source: source,
                referrer: referrer,
                deliverer: deliverer,
                week: week,
                chainId: block.chainid,
                cursorBefore: cursorBefore[week - fromWeek]
            });

            _noteWord(
                delivery,
                CohortWeeks._packLanes(
                    0,
                    0,
                    mature * CohortWeeks.WEEK
                )
            );

            _closeDelivery(
                delivery
            );
        }

        ++localGaps;
    }

    function reportSelf(
        uint256 _reporterSeed,
        uint256 _referrerSeed,
        uint256 _weekSeed,
        uint256 _spanSeed,
        uint256 _averageSeed
    )
        external
    {
        address reporter = reporters[_reporterSeed % reporters.length];

        address referrer = referrers[_referrerSeed % referrers.length];

        uint256 toWeek = _closedWeek(_weekSeed) + 1;

        uint256 fromWeek = toWeek - bound(
            _spanSeed,
            1,
            3
        );

        uint256 average = bound(
            _averageSeed,
            0,
            MAX_AVERAGE
        );

        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            reporter
        );

        uint256[] memory ratesBefore = new uint256[](
            toWeek - fromWeek
        );

        for (uint256 week = fromWeek; week < toWeek; ++week) {
            ratesBefore[week - fromWeek] = _ratesWord(
                referrer,
                week
            );
        }

        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            fromWeek,
            toWeek,
            average
        );

        vm.prank(
            reporter
        );

        hub.reportSelf(
            referrer,
            runs
        );

        for (uint256 week = fromWeek; week < toWeek; ++week) {

            _noteSelf(
                source,
                referrer,
                week,
                average
            );

            if (_ratesWord(referrer, week) == ratesBefore[week - fromWeek]) {
                continue;
            }

            ++inlineSelfTopUps;

            if (_paidOf(source, referrer, week) != dueOf(source, referrer, week)) {
                ++ghostExactPayViolations;
            }
        }

        ++selfRuns;
    }

    // ---- remote intake ----

    function deliverRemote(
        uint256 _referrerSeed,
        uint256 _weekSeed,
        uint256 _laneSeed,
        uint256 _selfSeed,
        uint256 _delivererSeed,
        bool _hold
    )
        external
    {
        HeldEnvelope memory envelope;

        envelope.referrer = referrers[_referrerSeed % referrers.length];

        envelope.week = _closedWeek(
            _weekSeed
        );

        envelope.word = _laneWord(
            _laneSeed
        );

        envelope.selfAverage = _selfSeed % 2 == 0
            ? 0
            : bound(
                _selfSeed >> 1,
                1,
                MAX_AVERAGE
            );

        envelope.deliverer = _pickDeliverer(
            _delivererSeed,
            envelope.referrer
        );

        envelope.stamp = block.timestamp;

        envelope.payload = _packEnvelope(
            envelope
        );

        envelope.messageId = keccak256(
            abi.encode(
                "remote",
                remoteNonce
            )
        );

        ++remoteNonce;

        vm.prank(
            ROUTER
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: envelope.messageId,
                sourceChainSelector: REMOTE_SELECTOR,
                sender: abi.encode(
                    REMOTE_VAULT
                ),
                data: envelope.payload,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        held.push(
            envelope
        );

        if (_hold) {
            return;
        }

        _applyEnvelope(
            envelope
        );

        ++remoteApplies;
    }

    function applyHeld(
        uint256 _indexSeed
    )
        external
    {
        if (held.length == 0) {
            return;
        }

        _applyEnvelope(
            held[_indexSeed % held.length]
        );

        ++heldApplies;
    }

    function settleWeek(
        uint256 _referrerSeed,
        uint256 _weekSeed,
        uint256 _callerSeed
    )
        external
    {
        address referrer = referrers[_referrerSeed % referrers.length];

        uint256 week = _closedWeek(
            _weekSeed
        );

        vm.prank(
            address(
                uint160(
                    0xA000 + _callerSeed % 7
                )
            )
        );

        hub.settleWeeks(
            referrer,
            week,
            1
        );

        uint256 count = hub.sourceCountOf(
            referrer
        );

        for (uint256 i; i < count; ++i) {

            bytes32 source = hub.sourceOfAt(
                referrer,
                i
            );

            if (_paidOf(source, referrer, week) != dueOf(source, referrer, week)) {
                ++ghostSettleViolations;
            }
        }

        ++settles;
    }

    // ---- payout rail ----

    function claimUpTo(
        uint256 _ownerSeed,
        uint256 _amountSeed
    )
        external
    {
        uint256 pick = _ownerSeed % (referrers.length + 2);

        address owner = pick < referrers.length
            ? referrers[pick]
            : pick == referrers.length
                ? COURIER
                : COURIER2;

        uint256 entitled = hub.claimable(
            block.chainid,
            owner
        );

        if (entitled == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            entitled
        );

        vm.prank(
            owner
        );

        hub.claimUpTo(
            block.chainid,
            owner,
            amount
        );

        ghostCourierClaimed[block.chainid][owner] += amount;
    }

    function claimRemoteUpTo(
        uint256 _targetSeed,
        uint256 _amountSeed
    )
        external
    {
        uint256 pick = _targetSeed % (referrers.length + 2);

        if (pick == referrers.length + 1) {
            _claimUndesignatedCourier(
                _amountSeed
            );

            return;
        }

        address target = pick == referrers.length
            ? COURIER
            : referrers[pick];

        if (hub.payoutStamp(REMOTE_CHAIN_ID, target) == 0) {
            return;
        }

        uint256 entitled = hub.claimable(
            REMOTE_CHAIN_ID,
            target
        );

        if (entitled == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            entitled
        );

        vm.prank(
            target
        );

        hub.claimUpTo(
            REMOTE_CHAIN_ID,
            target,
            amount
        );

        ghostCourierClaimed[REMOTE_CHAIN_ID][target] += amount;
    }

    function _claimUndesignatedCourier(
        uint256 _amountSeed
    )
        internal
    {
        uint256 entitled = hub.claimable(
            REMOTE_CHAIN_ID,
            COURIER2
        );

        if (entitled == 0) {
            return;
        }

        uint256 amount = bound(
            _amountSeed,
            1,
            entitled
        );

        vm.prank(
            COURIER2
        );

        try hub.claimUpTo(
            REMOTE_CHAIN_ID,
            COURIER2,
            amount
        ) {
            ++ghostUndesignatedClaimViolations;
        } catch (bytes memory reason) {

            if (
                keccak256(reason) != keccak256(
                    abi.encodeWithSelector(
                        ReferralHubDeclarations.PayoutNotDesignated.selector
                    )
                )
            ) {
                ++ghostUndesignatedClaimViolations;
            } else {
                ++undesignatedClaimRefusals;
            }
        }
    }

    function designateLate(
        uint256 _seed
    )
        external
    {
        if (hub.payoutStamp(REMOTE_CHAIN_ID, LATE_REFERRER) != 0) {
            return;
        }

        if (bound(_seed, 0, 7) != 0) {
            return;
        }

        uint256 backlog = hub.claimable(
            REMOTE_CHAIN_ID,
            LATE_REFERRER
        );

        uint256 payableBefore = hub.totalPayable();

        if (backlog > 0) {
            lateReleaseCount += 1;
        }

        vm.prank(
            ROUTER
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: keccak256(
                    abi.encode(
                        "late designation",
                        block.timestamp
                    )
                ),
                sourceChainSelector: REMOTE_SELECTOR,
                sender: abi.encode(REMOTE_REGISTRY),
                data: abi.encode(
                    uint256(2),
                    LATE_REFERRER,
                    address(0),
                    block.timestamp,
                    uint256(1)
                ),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        assertEq(
            hub.totalPayable(),
            payableBefore + backlog,
            "designateLate: the landing must release exactly the backlog"
        );
    }

    // ---- master knobs and the clock ----

    function pushRateTable(
        uint256 _seed
    )
        external
    {
        if (bound(_seed, 0, 3) != 0) {
            return;
        }

        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        uint256 lastFrom = hub.rateTableAt(
            hub.rateTableCount() - 1
        ).effectiveFromWeek;

        uint256 variant = bound(
            _seed >> 100,
            0,
            2
        );

        if (variant == 1) {
            _pushRefusedTable(
                currentWeek,
                ReferralHubDeclarations.TableNotFuture.selector
            );

            return;
        }

        if (variant == 2) {

            if (lastFrom <= currentWeek) {
                return;
            }

            _pushRefusedTable(
                lastFrom,
                ReferralHubDeclarations.TableNotOrdered.selector
            );

            return;
        }

        uint256 effectiveFrom = currentWeek + bound(
            _seed >> 8,
            1,
            3
        );

        if (effectiveFrom <= lastFrom) {
            effectiveFrom = lastFrom + 1;
        }

        uint256 unit = bound(
            _seed >> 16,
            1,
            120
        );

        ReferralHubDeclarations.RateTable memory table;

        table.effectiveFromWeek = uint32(effectiveFrom);

        table.capBps = uint16(
            bound(
                _seed >> 24,
                100,
                2_000
            )
        );

        table.y2RateBps = uint16(
            bound(
                _seed >> 40,
                0,
                table.capBps
            )
        );

        table.mRateBps = uint16(
            bound(
                _seed >> 56,
                0,
                table.y2RateBps
            )
        );

        table.botShareBps = uint16(
            bound(
                _seed >> 72,
                0,
                MAX_BOT_SHARE_BPS
            )
        );

        for (uint256 i; i < 8; ++i) {
            table.tierBps[i] = uint16((i + 1) * unit);

            table.thresholds[i] = uint96((i + 1) * 5_000 * 1e6);
        }

        vm.prank(
            hub.master()
        );

        hub.pushRateTable(
            table
        );

        ++tablesPushed;
    }

    function _pushRefusedTable(
        uint256 _effectiveFrom,
        bytes4 _expected
    )
        internal
    {
        ReferralHubDeclarations.RateTable memory table = hub.rateTableAt(
            hub.rateTableCount() - 1
        );

        table.effectiveFromWeek = uint32(
            _effectiveFrom
        );

        vm.prank(
            hub.master()
        );

        try hub.pushRateTable(
            table
        ) {
            ++ghostTableGateViolations;
        } catch (bytes memory reason) {

            if (
                keccak256(reason) != keccak256(
                    abi.encodeWithSelector(
                        _expected
                    )
                )
            ) {
                ++ghostTableGateViolations;

                return;
            }

            ++refusedTables;
        }
    }

    function elevate(
        uint256 _referrerSeed,
        uint256 _seed
    )
        public
    {
        address referrer = referrers[_referrerSeed % referrers.length];

        uint256 offset = bound(
            _seed,
            1,
            3
        );

        uint256 week = block.timestamp / CohortWeeks.WEEK + offset;

        if (ghostElevatedFrom[referrer] != 0 && ghostElevatedUntil[referrer] == 0) {

            if (week < ghostElevatedFrom[referrer]) {
                week = ghostElevatedFrom[referrer];
            }

            vm.prank(
                hub.master()
            );

            hub.endElevation(
                referrer,
                week
            );

            ghostElevatedUntil[referrer] = week;

            ghostWindowUntil[referrer][ghostWindowUntil[referrer].length - 1] = week;

            ++elevationEnds;

            return;
        }

        week = (block.timestamp + HubLeverGrants.LEVER_DELAY) / CohortWeeks.WEEK + offset;

        if (ghostWindowFrom[referrer].length == MAX_ELEVATION_WINDOWS) {
            _refuseFullElevation(
                referrer,
                week
            );

            return;
        }

        vm.startPrank(
            hub.master()
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.elevateReferrer,
                (
                    referrer,
                    week
                )
            )
        );

        vm.stopPrank();

        ghostElevatedFrom[referrer] = week;

        ghostElevatedUntil[referrer] = 0;

        ghostWindowFrom[referrer].push(
            week
        );

        ghostWindowUntil[referrer].push(
            0
        );

        ++elevations;
    }

    function ghostWindowCount(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return ghostWindowFrom[_referrer].length;
    }

    function ghostElevatedAt(
        address _referrer,
        uint256 _week
    )
        public
        view
        returns (bool)
    {
        uint256 count = ghostWindowFrom[_referrer].length;

        for (uint256 i; i < count; ++i) {

            uint256 untilWeek = ghostWindowUntil[_referrer][i];

            if (
                _week >= ghostWindowFrom[_referrer][i]
                    && (untilWeek == 0 || _week < untilWeek)
            ) {
                return true;
            }
        }

        return false;
    }

    function _refuseFullElevation(
        address _referrer,
        uint256 _week
    )
        internal
    {
        bytes memory call = abi.encodeCall(
            IReferralHub.elevateReferrer,
            (
                _referrer,
                _week
            )
        );

        uint256 start = block.timestamp;

        vm.startPrank(
            hub.master()
        );

        HubLeverGrants._queue(
            address(hub),
            call
        );

        (
            bool success,
            bytes memory reason
        ) = address(hub).call(
            call
        );

        vm.stopPrank();

        vm.warp(
            start
        );

        if (
            success
                || keccak256(reason) != keccak256(
                    abi.encodeWithSelector(
                        ReferralHubDeclarations.ElevationHistoryFull.selector
                    )
                )
        ) {
            ++ghostElevationGateViolations;

            return;
        }

        ++refusedElevations;
    }

    function setShareCap(
        uint256 _seed
    )
        external
    {
        uint256 cap = bound(_seed, 0, 3) == 0
            ? 0
            : bound(
                _seed >> 8,
                1,
                10 ** bound(
                    _seed >> 72,
                    0,
                    MAX_SHARE_CAP_DECADES
                )
            );

        vm.prank(
            hub.master()
        );

        hub.setDelivererShareCap(
            cap
        );

        ghostShareCap = cap;

        ++shareCapSets;
    }

    function warpWeeks(
        uint256 _seed
    )
        external
    {
        vm.warp(
            block.timestamp + bound(_seed, 1, 2) * CohortWeeks.WEEK
        );
    }

    function warpHours(
        uint256 _seed
    )
        external
    {
        vm.warp(
            block.timestamp + bound(
                _seed,
                1 hours,
                6 days
            )
        );
    }

    // ---- oracle pieces shared with the invariant contract ----

    function dueOf(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        public
        view
        returns (uint256)
    {
        return _dueAtRates(
            _referrer,
            _week,
            _cursorOf(
                _source,
                _referrer,
                _week
            )
        );
    }

    function tableIndexFor(
        uint256 _week
    )
        public
        view
        returns (uint256 index)
    {
        index = hub.rateTableCount() - 1;

        while (index > 0 && hub.rateTableAt(index).effectiveFromWeek > _week) {
            --index;
        }
    }

    // ---- internals ----

    function _closedWeek(
        uint256 _seed
    )
        internal
        view
        returns (uint256)
    {
        return block.timestamp / CohortWeeks.WEEK - 1 - _seed % WEEK_BACK;
    }

    function _laneWord(
        uint256 _seed
    )
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks._packLanes(
            bound(uint64(_seed), 1, MAX_AVERAGE) * CohortWeeks.WEEK,
            bound(uint64(_seed >> 64), 0, MAX_AVERAGE / 4) * CohortWeeks.WEEK,
            bound(uint64(_seed >> 128), 0, MAX_AVERAGE / 8) * CohortWeeks.WEEK
        );
    }

    function _pickDeliverer(
        uint256 _seed,
        address _referrer
    )
        internal
        pure
        returns (address)
    {
        uint256 pick = _seed % 3;

        if (pick == 0) {
            return _referrer;
        }

        return pick == 1
            ? COURIER
            : COURIER2;
    }

    function _paidOf(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256 paidUnits)
    {
        (
            ,
            paidUnits
        ) = hub.weekReportOf(
            _source,
            _referrer,
            _week
        );
    }

    function _openDelivery(
        bytes32 _source,
        address _referrer,
        address _deliverer,
        uint256 _week,
        uint256 _chainId
    )
        internal
        view
        returns (Delivery memory delivery)
    {
        delivery.source = _source;
        delivery.referrer = _referrer;
        delivery.deliverer = _deliverer;
        delivery.week = _week;
        delivery.chainId = _chainId;
        delivery.cursorBefore = _cursorOf(
            _source,
            _referrer,
            _week
        );
    }

    function _closeDelivery(
        Delivery memory _delivery
    )
        internal
    {
        uint256 cursorAfter = _cursorOf(
            _delivery.source,
            _delivery.referrer,
            _delivery.week
        );

        if (
            cursorAfter != _delivery.cursorBefore
                && _paidOf(_delivery.source, _delivery.referrer, _delivery.week) != dueOf(_delivery.source, _delivery.referrer, _delivery.week)
        ) {
            ++ghostExactPayViolations;
        }

        if (_delivery.deliverer == _delivery.referrer) {
            return;
        }

        uint256 increment = _dueAtRates(
            _delivery.referrer,
            _delivery.week,
            _cursorOf(
                _delivery.source,
                _delivery.referrer,
                _delivery.week
            )
        ) - _dueAtRates(
            _delivery.referrer,
            _delivery.week,
            _delivery.cursorBefore
        );

        uint256 fee = increment * hub.rateTableAt(
            tableIndexFor(
                _delivery.week
            )
        ).botShareBps / BPS_DENOMINATOR;

        if (ghostShareCap > 0 && fee > ghostShareCap) {
            fee = ghostShareCap;
        }

        if (fee == 0) {
            return;
        }

        ghostFee[_delivery.chainId][_delivery.deliverer] += fee;

        ++feesPaid;
    }

    function _cursorOf(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1,
            uint256 y2,
            uint256 m
        ) = hub.paidCursorAtSource(
            _source,
            _referrer,
            _week
        );

        return CohortWeeks._packLanes(
            y1,
            y2,
            m
        );
    }

    function _ratesWord(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            _referrer,
            _week
        );

        return y1Bps | (y2Bps << 16) | (mBps << 32);
    }

    function _dueAtRates(
        address _referrer,
        uint256 _week,
        uint256 _cursorWord
    )
        internal
        view
        returns (uint256)
    {
        (
            uint256 y1Bps,
            uint256 y2Bps,
            uint256 mBps
        ) = hub.weeklyRates(
            _referrer,
            _week
        );

        return (
            CohortWeeks._laneY1(_cursorWord) * y1Bps
                + CohortWeeks._laneY2(_cursorWord) * y2Bps
                + CohortWeeks._laneM(_cursorWord) * mBps
        ) / (BPS_DENOMINATOR * CohortWeeks.YEAR);
    }

    function _noteWord(
        Delivery memory _delivery,
        uint256 _word
    )
        internal
    {
        bytes32 key = cellKey(
            _delivery.source,
            _delivery.referrer,
            _delivery.week
        );

        if (cellSeen[key] == false) {
            cellSeen[key] = true;

            cells.push(
                Cell({
                    source: _delivery.source,
                    referrer: _delivery.referrer,
                    week: _delivery.week
                })
            );
        }

        uint256 y1 = CohortWeeks._laneY1(
            _word
        );

        uint256 y2 = CohortWeeks._laneY2(
            _word
        );

        uint256 m = CohortWeeks._laneM(
            _word
        );

        if (y1 > ghostY1[key]) {
            ghostY1[key] = y1;
        }

        if (y2 > ghostY2[key]) {
            ghostY2[key] = y2;
        }

        if (m > ghostM[key]) {
            ghostM[key] = m;
        }

        uint256 average = (y1 + y2 + m) / CohortWeeks.WEEK;

        if (average > ghostReferred[key]) {
            ghostReferred[key] = average;
        }

        _noteWeek(
            _delivery.referrer,
            _delivery.week
        );
    }

    function _noteSelf(
        bytes32 _source,
        address _referrer,
        uint256 _week,
        uint256 _average
    )
        internal
    {
        if (_average > ghostSelf[_source][_referrer][_week]) {
            ghostSelf[_source][_referrer][_week] = _average;
        }

        _noteWeek(
            _referrer,
            _week
        );
    }

    function _noteWeek(
        address _referrer,
        uint256 _week
    )
        internal
    {
        if (weekSeen[_referrer][_week]) {
            return;
        }

        weekSeen[_referrer][_week] = true;

        weekReferrers.push(
            _referrer
        );

        weekList.push(
            _week
        );
    }

    function _packEnvelope(
        HeldEnvelope memory _envelope
    )
        internal
        pure
        returns (bytes memory)
    {
        uint256 runCount = _envelope.selfAverage == 0
            ? 0
            : 1;

        uint256[] memory out = new uint256[](4 + runCount);

        out[0] = CohortFlushCodec._packFlushHeader(
            _envelope.deliverer,
            1,
            _envelope.stamp
        );

        out[1] = CohortFlushCodec._packFlushEntry(
            _envelope.referrer,
            1,
            0,
            0,
            runCount
        );

        if (runCount == 1) {
            out[2] = CohortFlushCodec._packSelfRun(
                _envelope.week,
                _envelope.week + 1,
                _envelope.selfAverage
            );
        }

        out[2 + runCount] = _envelope.week;

        out[3 + runCount] = _envelope.word | CohortWeeks.CRUMB_WRITTEN_BIT;

        return abi.encodePacked(
            out
        );
    }

    function _applyEnvelope(
        HeldEnvelope memory _envelope
    )
        internal
    {
        Delivery memory delivery = _openDelivery(
            remoteSource(),
            _envelope.referrer,
            _envelope.deliverer,
            _envelope.week,
            REMOTE_CHAIN_ID
        );

        hub.applyFlush(
            _envelope.messageId,
            REMOTE_SELECTOR,
            REMOTE_CHAIN_ID,
            REMOTE_VAULT,
            _envelope.payload
        );

        if (_envelope.selfAverage > 0) {
            _noteSelf(
                remoteSource(),
                _envelope.referrer,
                _envelope.week,
                _envelope.selfAverage
            );
        }

        _noteWord(
            delivery,
            _envelope.word
        );

        _closeDelivery(
            delivery
        );
    }
}

/**
 * @dev Invariant suite for the week-bucket hub ({ReferralHubIntake},
 * {ReferralHubRates}, {ReferralHubCheckpoints}, the mailbox and the
 * payout rail) driven by {ReferralHubInvariantHandler}. B1 rebuilds
 * every touched week bucket from the handler's own report ghosts: the
 * referred input is the sum over sources of each source's largest
 * referred average for the week, the self input the sum over vault
 * systems of each system's largest self average. B2 restates the
 * ladder: a week's rates are the tier of its self input plus the tier
 * of its referred input under the table in force for that week, capped
 * at the table's cap, with the year-2 and mature rates open only at
 * the cap. B3 pins every touched cursor to the ghost lane maxima and
 * bounds every paid half by the due of its cursor at the week's
 * current rates (a lazy top-up may leave a source below its due,
 * never above it). B4 pins `totalAccrued` to the sum of the cells'
 * paid halves plus the courier fee ghost, and the courier law pins
 * each courier bucket to that ghost less its claims. The payout laws
 * pin the claimable buckets, the payable base, the booked liability
 * and the vault's pending payout against real token movements. The
 * handler's own gates (`settleWeek` leaving every listed source at
 * exactly its due, the undesignated courier refusal, the table
 * ordering refusals) must never have tripped.
 */
contract ReferralHubInvariantTest is Test, HubDiamondHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant POT_FUNDING = 1e30;

    MockUSD internal usdToken;

    IReferralHub internal hub;

    ReferralHubInvariantHandler internal handler;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usdToken = new MockUSD();

        hub = _deployHub(
            address(usdToken)
        );

        usdToken.mint(
            address(hub),
            POT_FUNDING
        );

        address[3] memory reporters = [
            address(0xD1),
            address(0xD2),
            address(0xD3)
        ];

        for (uint256 i; i < reporters.length; ++i) {
            HubLeverGrants._grant(
                address(hub),
                abi.encodeCall(
                    IReferralHub.setAllowedReporter,
                    (
                        reporters[i],
                        true
                    )
                )
            );
        }

        handler = new ReferralHubInvariantHandler(
            hub,
            reporters,
            _referrers()
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    handler.ROUTER()
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    handler.REMOTE_SELECTOR(),
                    handler.REMOTE_VAULT(),
                    handler.REMOTE_CHAIN_ID()
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    handler.REMOTE_SELECTOR(),
                    handler.REMOTE_REGISTRY(),
                    handler.REMOTE_CHAIN_ID()
                )
            )
        );

        hub.setSourceSystem(
            hub.sourceKeyOf(
                block.chainid,
                reporters[1]
            ),
            1
        );

        hub.setSourceSystem(
            handler.remoteSource(),
            1
        );

        address[4] memory referrers = _referrers();

        for (uint256 i; i + 1 < referrers.length; ++i) {
            _pushZeroDesignation(
                referrers[i]
            );
        }

        _pushZeroDesignation(
            handler.COURIER()
        );

        assertEq(
            hub.payoutStamp(
                handler.REMOTE_CHAIN_ID(),
                handler.LATE_REFERRER()
            ),
            0,
            "setUp: the late referrer must start undesignated on the remote chain"
        );

        targetContract(
            address(handler)
        );
    }

    function _referrers()
        internal
        pure
        returns (address[4] memory)
    {
        return [
            address(0xB1),
            address(0xB2),
            address(0xB3),
            address(0xB4)
        ];
    }

    function _pushZeroDesignation(
        address _owner
    )
        internal
    {
        address router = handler.ROUTER();

        uint64 selector = handler.REMOTE_SELECTOR();

        address registry = handler.REMOTE_REGISTRY();

        vm.prank(
            router
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: keccak256(
                    abi.encode(
                        "designation",
                        _owner
                    )
                ),
                sourceChainSelector: selector,
                sender: abi.encode(
                    registry
                ),
                data: abi.encode(
                    uint256(2),
                    _owner,
                    address(0),
                    block.timestamp,
                    uint256(1)
                ),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    // ---- scripted reach ----

    function test_handlerReach_everyArmLands()
        public
    {
        handler.deliverCrumbs(
            0,
            0,
            0,
            50_000 * 1e6,
            1
        );

        handler.deliverCrumbs(
            1,
            0,
            0,
            60_000 * 1e6,
            0
        );

        handler.deliverGap(
            2,
            1,
            1,
            2,
            5_000 * 1e6,
            2
        );

        handler.reportSelf(
            0,
            0,
            0,
            1,
            900_000 * 1e6
        );

        handler.reportSelf(
            1,
            0,
            0,
            1,
            1 * 1e6
        );

        handler.deliverRemote(
            0,
            0,
            70_000 * 1e6,
            3,
            1,
            false
        );

        handler.deliverRemote(
            1,
            1,
            80_000 * 1e6,
            5,
            2,
            true
        );

        handler.applyHeld(
            1
        );

        handler.applyHeld(
            0
        );

        handler.settleWeek(
            0,
            0,
            0
        );

        handler.elevate(
            0,
            1
        );

        handler.elevate(
            0,
            2
        );

        handler.setShareCap(
            1
        );

        handler.deliverRemote(
            2,
            2,
            90_000 * 1e6,
            0,
            1,
            false
        );

        handler.pushRateTable(
            0
        );

        handler.pushRateTable(
            1 << 100
        );

        handler.claimUpTo(
            0,
            1
        );

        handler.claimRemoteUpTo(
            handler.cellsLength() % 4,
            1
        );

        handler.designateLate(
            0
        );

        handler.warpWeeks(
            1
        );

        handler.settleWeek(
            0,
            1,
            3
        );

        assertGt(
            handler.localCrumbs(),
            0
        );

        assertGt(
            handler.localGaps(),
            0
        );

        assertGt(
            handler.selfRuns(),
            0
        );

        assertGt(
            handler.remoteApplies(),
            0
        );

        assertGt(
            handler.heldApplies(),
            0
        );

        assertGt(
            handler.settles(),
            0
        );

        assertGt(
            handler.inlineSelfTopUps(),
            0
        );

        assertGt(
            handler.feesPaid(),
            0
        );

        assertGt(
            handler.tablesPushed(),
            0
        );

        assertGt(
            handler.refusedTables(),
            0
        );

        invariant_B1_bucketsFoldTheGhostReports();
        invariant_B2_ratesFollowTheLadder();
        invariant_B3_cursorsMatchGhostAndNeverOverpay();
        invariant_B4_accruedIsPaidHalvesPlusFees();
        invariant_courier_bucketsMatchTheFeeGhost();
        invariant_totalAccrued_equalsClaimedPlusClaimable();
        invariant_totalPayable_equalsClaimedPlusPayableClaimable();
        invariant_handlerGates_neverTripped();
    }

    // ---- bucket laws ----

    function _ghostInputs(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (
            uint256 referredSum,
            uint256 selfSum
        )
    {
        uint256 count = handler.cellsLength();

        for (uint256 i; i < count; ++i) {

            (
                bytes32 source,
                address referrer,
                uint256 week
            ) = handler.cells(i);

            if (referrer == _referrer && week == _week) {
                referredSum += handler.ghostReferred(
                    handler.cellKey(
                        source,
                        referrer,
                        week
                    )
                );
            }
        }

        for (uint256 i; i < 4; ++i) {
            selfSum += handler.ghostSelf(
                handler.sourceAt(
                    i
                ),
                _referrer,
                _week
            );
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_B1_bucketsFoldTheGhostReports()
        public
        view
    {
        uint256 count = handler.weeksLength();

        for (uint256 i; i < count; ++i) {

            address referrer = handler.weekReferrers(
                i
            );

            uint256 week = handler.weekList(
                i
            );

            (
                uint256 referredGhost,
                uint256 selfGhost
            ) = _ghostInputs(
                referrer,
                week
            );

            (
                uint256 referredInput,
                uint256 selfInput
            ) = hub.ladderInputsAt(
                referrer,
                week
            );

            assertEq(
                referredInput,
                referredGhost,
                "B1: referred input != sum over sources of the largest referred average"
            );

            assertEq(
                selfInput,
                selfGhost,
                "B1: self input != sum over sources of each source's largest self average"
            );
        }
    }

    function _tierOf(
        ReferralHubDeclarations.RateTable memory _table,
        uint256 _value
    )
        internal
        pure
        returns (uint256)
    {
        for (uint256 i = 8; i > 0; --i) {

            if (_value >= _table.thresholds[i - 1]) {
                return _table.tierBps[i - 1];
            }
        }

        return 0;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_B2_ratesFollowTheLadder()
        public
        view
    {
        uint256 count = handler.weeksLength();

        for (uint256 i; i < count; ++i) {

            address referrer = handler.weekReferrers(
                i
            );

            uint256 week = handler.weekList(
                i
            );

            (
                uint256 referredGhost,
                uint256 selfGhost
            ) = _ghostInputs(
                referrer,
                week
            );

            ReferralHubDeclarations.RateTable memory table = hub.rateTableAt(
                handler.tableIndexFor(
                    week
                )
            );

            uint256 y1 = _tierOf(table, selfGhost) + _tierOf(table, referredGhost);

            if (y1 > table.capBps) {
                y1 = table.capBps;
            }

            if (
                handler.ghostElevatedAt(
                    referrer,
                    week
                )
            ) {
                y1 = table.capBps;
            }

            (
                uint256 y1Bps,
                uint256 y2Bps,
                uint256 mBps
            ) = hub.weeklyRates(
                referrer,
                week
            );

            assertEq(
                y1Bps,
                y1,
                "B2: y1 rate != capped tier sum of the week's own inputs (or the cap inside an elevation window)"
            );

            assertEq(
                y2Bps,
                y1 == table.capBps ? table.y2RateBps : 0,
                "B2: the year-2 rate must open exactly at the cap"
            );

            assertEq(
                mBps,
                y1 == table.capBps ? table.mRateBps : 0,
                "B2: the mature rate must open exactly at the cap"
            );
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_B3_cursorsMatchGhostAndNeverOverpay()
        public
        view
    {
        uint256 count = handler.cellsLength();

        for (uint256 i; i < count; ++i) {

            (
                bytes32 source,
                address referrer,
                uint256 week
            ) = handler.cells(i);

            bytes32 key = handler.cellKey(
                source,
                referrer,
                week
            );

            (
                uint256 y1,
                uint256 y2,
                uint256 m
            ) = hub.paidCursorAtSource(
                source,
                referrer,
                week
            );

            assertEq(
                y1,
                handler.ghostY1(
                    key
                ),
                "B3: y1 cursor != ghost lane maximum"
            );

            assertEq(
                y2,
                handler.ghostY2(
                    key
                ),
                "B3: y2 cursor != ghost lane maximum"
            );

            assertEq(
                m,
                handler.ghostM(
                    key
                ),
                "B3: m cursor != ghost lane maximum"
            );

            (
                ,
                uint256 paidUnits
            ) = hub.weekReportOf(
                source,
                referrer,
                week
            );

            assertLe(
                paidUnits,
                handler.dueOf(
                    source,
                    referrer,
                    week
                ),
                "B3: a source was paid above the due of its cursor at current rates"
            );
        }
    }

    function _feeGhostTotal()
        internal
        view
        returns (uint256 total)
    {
        uint256[2] memory chains = [
            block.chainid,
            handler.REMOTE_CHAIN_ID()
        ];

        address[2] memory couriers = [
            handler.COURIER(),
            handler.COURIER2()
        ];

        for (uint256 c; c < chains.length; ++c) {
            for (uint256 k; k < couriers.length; ++k) {
                total += handler.ghostFee(
                    chains[c],
                    couriers[k]
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_B4_accruedIsPaidHalvesPlusFees()
        public
        view
    {
        uint256 count = handler.cellsLength();

        uint256 paidSum;

        for (uint256 i; i < count; ++i) {

            (
                bytes32 source,
                address referrer,
                uint256 week
            ) = handler.cells(i);

            (
                ,
                uint256 paidUnits
            ) = hub.weekReportOf(
                source,
                referrer,
                week
            );

            paidSum += paidUnits;
        }

        assertEq(
            hub.totalAccrued(),
            paidSum + _feeGhostTotal(),
            "B4: totalAccrued != sum of paid halves + courier fee ghost"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_courier_bucketsMatchTheFeeGhost()
        public
        view
    {
        uint256[2] memory chains = [
            block.chainid,
            handler.REMOTE_CHAIN_ID()
        ];

        address[2] memory couriers = [
            handler.COURIER(),
            handler.COURIER2()
        ];

        for (uint256 c; c < chains.length; ++c) {
            for (uint256 k; k < couriers.length; ++k) {
                assertEq(
                    hub.claimable(
                        chains[c],
                        couriers[k]
                    )
                        + handler.ghostCourierClaimed(chains[c], couriers[k]),
                    handler.ghostFee(
                        chains[c],
                        couriers[k]
                    ),
                    "courier: bucket plus claims != fee ghost"
                );
            }
        }
    }

    // ---- payout laws ----

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalAccrued_equalsClaimedPlusClaimable()
        public
        view
    {
        address[4] memory referrers = _referrers();

        uint256 remoteChainId = handler.REMOTE_CHAIN_ID();

        uint256 sumClaimable;
        uint256 sumPaidOut;

        for (uint256 i; i < referrers.length; ++i) {
            sumClaimable += hub.claimable(
                block.chainid,
                referrers[i]
            );

            sumClaimable += hub.claimable(
                remoteChainId,
                referrers[i]
            );

            sumPaidOut += usdToken.balanceOf(
                referrers[i]
            );
        }

        address[2] memory couriers = [
            handler.COURIER(),
            handler.COURIER2()
        ];

        for (uint256 i; i < couriers.length; ++i) {
            sumClaimable += hub.claimable(
                block.chainid,
                couriers[i]
            );

            sumClaimable += hub.claimable(
                remoteChainId,
                couriers[i]
            );

            sumPaidOut += usdToken.balanceOf(
                couriers[i]
            );
        }

        assertEq(
            hub.totalAccrued(),
            hub.totalClaimed() + sumClaimable,
            "totalAccrued != totalClaimed + sum(claimable)"
        );

        assertEq(
            hub.totalClaimed(),
            sumPaidOut,
            "totalClaimed != sum of USD actually paid out"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalPayable_equalsClaimedPlusPayableClaimable()
        public
        view
    {
        address[6] memory owners = [
            address(0xB1),
            address(0xB2),
            address(0xB3),
            address(0xB4),
            handler.COURIER(),
            handler.COURIER2()
        ];

        uint256[2] memory chains = [
            block.chainid,
            handler.REMOTE_CHAIN_ID()
        ];

        uint256 sumPayable;
        uint256 sumLocked;

        for (uint256 i; i < owners.length; ++i) {
            for (uint256 c; c < chains.length; ++c) {

                uint256 amount = hub.claimable(
                    chains[c],
                    owners[i]
                );

                if (hub.payoutStamp(chains[c], owners[i]) != 0) {
                    sumPayable += amount;
                } else {
                    sumLocked += amount;
                }
            }
        }

        assertEq(
            hub.totalPayable(),
            hub.totalClaimed() + sumPayable,
            "totalPayable != totalClaimed + sum(claimable of buckets that can pay)"
        );

        assertEq(
            hub.totalAccrued() - hub.totalPayable(),
            sumLocked,
            "accrual outside totalPayable != sum(claimable of undesignated buckets)"
        );

        assertLe(
            hub.totalClaimed(),
            hub.totalPayable(),
            "totalClaimed must never exceed totalPayable"
        );

        assertEq(
            usdToken.balanceOf(
                address(hub)
            ),
            POT_FUNDING - hub.totalClaimed(),
            "the pot balance != its funding minus every claim paid"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_handlerGates_neverTripped()
        public
        view
    {
        assertEq(
            handler.ghostSettleViolations(),
            0,
            "settleWeeks left a listed source away from its due"
        );

        assertEq(
            handler.ghostExactPayViolations(),
            0,
            "a delivery or a raising self run left its own cell away from its due"
        );

        assertEq(
            handler.ghostUndesignatedClaimViolations(),
            0,
            "an undesignated spoke bucket paid or failed with the wrong error"
        );

        assertEq(
            handler.ghostTableGateViolations(),
            0,
            "a refused rate table was accepted or failed with the wrong error"
        );

        assertEq(
            handler.ghostElevationGateViolations(),
            0,
            "a grant over a full elevation history was accepted or failed with the wrong error"
        );
    }
}
