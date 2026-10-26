// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

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
 * @dev Cross-chain mailbox suite for {ReferralHub} /
 * {ReferralHubMailbox}: the CCIP receive surface (router gate,
 * master-registered flush and designation sources, O(1) commitment
 * storage doubling as the replay guard, inline designation pushes),
 * the permissionless commitment-proved `applyFlush` with its
 * wholesale envelope validation (version bytes, reserved bits, entry
 * counts, exact payload length, per-slice gap spans, the total work
 * cap, and the self-healing open-week revert, the hub taking closed
 * weeks only), remote application
 * through the shared intake internals under `keccak256(chainId,
 * vault)` source keys (self runs into the week buckets, crumb and
 * gap pricing from the priced week's own buckets into
 * per-source-chain claimable buckets), idempotent re-application and out-of-order envelope
 * convergence, a stamp ahead of the hub clock never widening the
 * courier fee,
 * the courier fee for remote non-own-book deliveries (the rate
 * table's week-versioned share: genesis, zero, at the cap, a closed
 * week keeping the share of its own table under a later table, a
 * two-week envelope whose older week is priced late paying each
 * week its own table's share,
 * and the courier fee whatever the envelope's build stamp (the hub only
 * takes closed weeks, so the stamp never decided it), pinned at the
 * closing boundary itself, one day past close, on a stale week and on a
 * late apply, and on the one thing the stamp never fixed: which of two
 * envelopes carrying the same week prices the
 * shared quantity follows the apply order, pinned as hub mechanics
 * for an own flush overtaken by a closed-build courier and for a
 * straddling courier pair applied in reverse (on a real spoke the
 * window gate keeps a third party from re-sending a closed week the
 * referrer already shipped, so only weeks carried by envelopes that
 * write no spoke cursor overlap a referrer's envelope); a courier gap
 * record pays the fee on every priced week the build had closed; an own-book apply emits no share
 * event; a hub-chain or other-spoke designation never unlocks a
 * spoke bucket), the designation rails
 * (latest-wins stamps, strict-greater replay no-ops, skip anomalies
 * for zero / far-future / rank-overflowing pairs, push payload
 * validation including a version 1 payload shaped like a registry
 * sync refused as a wrong version, and local-versus-remote bucket
 * independence proven
 * through a real claim), and cross-source isolation for the same
 * vault address registered under two chain selectors. Also covered:
 * reconstructing a full `applyFlush` call exclusively from the
 * decoded `FlushReceived` log (with a wrong-chain log join failing
 * closed), the two-courier redelivery race on one crumb window
 * (exhausted cursors price zero and pay the losing courier nothing;
 * a grown word pays the second courier on the increment only), an
 * envelope at exactly the total work cap, an envelope that lists one
 * referrer twice pricing each week once, and the courier claimable
 * bucket lifecycle across two source chains (independent buckets,
 * partial claims, courier-own designations, stranger lockout), and
 * the designation rule of spoke buckets: a spoke chain's bucket pays
 * a claim only once a designation from that chain has landed, both
 * claim shapes revert `PayoutNotDesignated` before that, and a zero
 * payout with a stamp pays the owner itself. The reader's
 * `claimablesOf` lists such a bucket in its total with a zero payout
 * and leaves it out of `claimableNow` until the designation lands,
 * then reports the designated payout and counts it; an empty chain
 * list returns empty arrays and zero sums. `claimAll` pays every
 * designated bucket the caller may claim in one call and skips the
 * empty, the undesignated, the repeated and, for a payout address, the
 * other chains' buckets (a courier clears two source chains at once);
 * a short pot pays the cover in list order and leaves the remainder
 * claimable; a stranger, an undesignated-only list, an empty list and
 * an empty pot revert `NothingClaimable`.
 * The source-keyed views are pinned as well: `sourceKeyOf` returns
 * the mailbox key for a remote source (matching the source topic of
 * the `FlushApplied` log) and the address-padded key for a local
 * reporter (under which `paidCursorAtSource` agrees with the reader
 * companion's `paidCursorAt` after a local crumb delivery); `paidCursorAtSource`
 * exposes a remote source's advanced cursor lanes, unchanged by
 * re-application; and `DelivererSharePaid` carries the applied
 * envelope's message id in its data words.
 * Rates come from the genesis table and the priced week's own
 * buckets: a TIER6 crumb averages 100k referred over its week, which
 * alone reaches the 600 bps tier, and the at-cap fixture reports a
 * 10k self run for the crumb week and the gap week while the rich
 * payload's crumb and gap each carry a 1M referred average;
 * `address(this)` is master and the local reporter. Also pinned: the
 * source setters refusing the hub's own chain id; the apply-time
 * source re-check and the selector bound into the commitment; the
 * zero header deliverer paying no courier fee; the re-pointable router; a self run in an
 * envelope recording the week buckets and its reserved bits
 * refused; the
 * payable liability base with its
 * first-designation backlog release by push and by envelope; and
 * `payoutAddressOf` reading zero for an undesignated spoke bucket.
 */
contract ReferralHubMailboxTest is Test, HubDiamondHarness {

    event CcipRouterSet(
        address indexed router
    );

    event FlushSourceSet(
        uint64 indexed chainSelector,
        address indexed vault,
        uint256 chainId
    );

    event DesignationSourceSet(
        uint64 indexed chainSelector,
        address indexed registry,
        uint256 chainId
    );

    event FlushReceived(
        bytes32 indexed messageId,
        uint64 indexed srcChainSelector,
        address indexed vault,
        uint256 chainId,
        bytes payload
    );

    event FlushApplied(
        bytes32 indexed messageId,
        bytes32 indexed source,
        uint256 entryCount
    );

    event DesignationPushReceived(
        uint64 indexed srcChainSelector,
        uint256 indexed chainId,
        address indexed owner
    );

    event PayoutAddressSet(
        uint256 indexed chainId,
        address indexed owner,
        address indexed payout
    );

    event FlushDesignationSkipped(
        uint256 indexed chainId,
        address indexed owner,
        uint256 stamp
    );

    event PayoutBacklogReleased(
        uint256 indexed chainId,
        address indexed owner,
        uint256 amount
    );

    event DelivererSharePaid(
        uint256 indexed chainId,
        address indexed deliverer,
        address indexed referrer,
        bytes32 messageId,
        uint256 amount
    );

    event PayoutClaimed(
        uint256 indexed chainId,
        address indexed referrer,
        address indexed payout,
        uint256 amount
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant WEEK = CohortWeeks.WEEK;

    uint256 internal constant YEAR = CohortWeeks.YEAR;

    uint256 internal constant WRITTEN_BIT = CohortWeeks.CRUMB_WRITTEN_BIT;

    uint256 internal constant TIER6_BPS = 600;

    uint256 internal constant AT_CAP_REFERRED = 1_000_000 * 1e6;

    uint256 internal constant AT_CAP_SELF = 10_000 * 1e6;

    uint256 internal constant CAP_BPS = 1_000;

    uint256 internal constant Y2_GENESIS_BPS = 500;

    uint256 internal constant M_GENESIS_BPS = 100;

    uint256 internal constant GENESIS_BOT_SHARE_BPS = 500;

    uint16 internal constant MAX_BOT_SHARE_BPS = 2_000;

    uint256 internal constant CLOSE_PLUS_ONE_DAY = 1 days;

    uint256 internal constant MAX_FUTURE_DRIFT = 1 hours;

    uint256 internal constant DESIGNATION_VERSION = 2;

    uint64 internal constant SEL_BASE = 10_001;

    uint64 internal constant SEL_ARB = 10_002;

    uint256 internal constant CHAIN_BASE = 8_453;

    uint256 internal constant CHAIN_ARB = 42_161;

    uint256 internal constant TIER6_QUANTITY = 100_000 * 1e6 * CohortWeeks.WEEK;

    uint256 internal constant TIER6_PAID = TIER6_QUANTITY * TIER6_BPS / 10_000 / CohortWeeks.YEAR;

    address internal refA = address(0xB1);

    address internal refB = address(0xB2);

    address internal courier = address(0xD7);

    address internal courier2 = address(0xD8);

    address internal stranger = address(0xC1);

    address internal designated = address(0xF2);

    address internal routerEoa = address(0xF1);

    address internal spokeVault = address(0xE1);

    address internal spokeRegistry = address(0xE2);

    MockUSD internal usd;

    IReferralHub internal hub;

    ReferralHubReader internal reader;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        hub = _deployHub(
            address(usd)
        );

        reader = new ReferralHubReader(
            address(hub)
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    routerEoa
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_BASE,
                    spokeVault,
                    CHAIN_BASE
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_BASE,
                    spokeRegistry,
                    CHAIN_BASE
                )
            )
        );
    }

    // ---- helpers ----

    function _word(
        uint256 _y1,
        uint256 _y2,
        uint256 _m
    )
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks._packLanes(
            _y1,
            _y2,
            _m
        ) | WRITTEN_BIT;
    }

    function _remoteSourceOf(
        uint256 _chainId,
        address _vault
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _chainId,
                _vault
            )
        );
    }

    function _flushMessage(
        bytes32 _messageId,
        uint64 _selector,
        address _sender,
        bytes memory _data
    )
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: _selector,
            sender: abi.encode(
                _sender
            ),
            data: _data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _receiveFlushFrom(
        bytes32 _messageId,
        uint64 _selector,
        address _sender,
        bytes memory _payload
    )
        internal
    {
        vm.prank(
            routerEoa
        );

        hub.ccipReceive(
            _flushMessage(
                _messageId,
                _selector,
                _sender,
                _payload
            )
        );
    }

    function _receiveFlushAs(
        bytes32 _messageId,
        bytes memory _payload
    )
        internal
    {
        _receiveFlushFrom(
            _messageId,
            SEL_BASE,
            spokeVault,
            _payload
        );
    }

    function _receiveThenApplyInvalid(
        bytes32 _messageId,
        bytes memory _payload
    )
        internal
    {
        _receiveFlushAs(
            _messageId,
            _payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.FlushPayloadInvalid.selector
        );

        hub.applyFlush(
            _messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            _payload
        );
    }

    function _pushDesignation(
        address _owner,
        address _payout,
        uint256 _setAt,
        uint256 _rank
    )
        internal
    {
        _pushDesignationFrom(
            SEL_BASE,
            _owner,
            _payout,
            _setAt,
            _rank
        );
    }

    function _pushDesignationFrom(
        uint64 _selector,
        address _owner,
        address _payout,
        uint256 _setAt,
        uint256 _rank
    )
        internal
    {
        vm.prank(
            routerEoa
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(0xD0)),
                _selector,
                spokeRegistry,
                abi.encode(
                    DESIGNATION_VERSION,
                    _owner,
                    _payout,
                    _setAt,
                    _rank
                )
            )
        );
    }

    function _crumbPayload(
        address _deliverer,
        uint256 _stamp,
        address _referrer,
        uint256 _week,
        uint256 _crumbWord
    )
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory words = new uint256[](4);

        words[0] = CohortFlushCodec._packFlushHeader(
            _deliverer,
            1,
            _stamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            _referrer,
            1,
            0,
            0,
            0
        );

        words[2] = _week;
        words[3] = _crumbWord;

        return abi.encodePacked(
            words
        );
    }

    function _selfPayload(
        address _deliverer,
        uint256 _stamp,
        address _referrer,
        uint256 _average
    )
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory words = new uint256[](3);

        words[0] = CohortFlushCodec._packFlushHeader(
            _deliverer,
            1,
            _stamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            _referrer,
            0,
            0,
            0,
            1
        );

        words[2] = CohortFlushCodec._packSelfRun(
            _stamp / CohortWeeks.WEEK - 1,
            _stamp / CohortWeeks.WEEK,
            _average
        );

        return abi.encodePacked(
            words
        );
    }

    function _gapPayload(
        address _deliverer,
        uint256 _stamp,
        address _referrer,
        uint256 _record
    )
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory words = new uint256[](3);

        words[0] = CohortFlushCodec._packFlushHeader(
            _deliverer,
            1,
            _stamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            _referrer,
            0,
            1,
            0,
            0
        );

        words[2] = _record;

        return abi.encodePacked(
            words
        );
    }

    function _richPayload(
        uint256 _stamp,
        uint256 _crumbWeek,
        uint256 _designationSetAt
    )
        internal
        view
        returns (bytes memory)
    {
        uint256[] memory words = new uint256[](6);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            _stamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            1,
            1,
            CohortFlushCodec.FLUSH_FLAG_DESIGNATION,
            0
        );

        words[2] = CohortFlushCodec._packFlushDesignation(
            designated,
            _designationSetAt,
            2
        );

        words[3] = _crumbWeek;

        words[4] = _word(
            AT_CAP_REFERRED * WEEK,
            40 * 1e6 * YEAR,
            20 * 1e6 * YEAR
        );

        words[5] = CohortWeeks._packGapRecord(
            _crumbWeek + 1,
            _crumbWeek + 2,
            AT_CAP_REFERRED
        );

        return abi.encodePacked(
            words
        );
    }

    function _richExpectedPaid()
        internal
        pure
        returns (uint256)
    {
        return (
            AT_CAP_REFERRED * WEEK * CAP_BPS
                + 40 * 1e6 * YEAR * Y2_GENESIS_BPS
                + 20 * 1e6 * YEAR * M_GENESIS_BPS
        ) / (10_000 * YEAR)
            + AT_CAP_REFERRED * WEEK * M_GENESIS_BPS / (10_000 * YEAR);
    }

    function _assertRichBuckets(
        uint256 _crumbWeek
    )
        internal
        view
    {
        (
            uint256 referredInput,
            uint256 selfInput
        ) = hub.ladderInputsAt(
            refA,
            _crumbWeek
        );

        (
            uint256 gapReferredInput,
            uint256 gapSelfInput
        ) = hub.ladderInputsAt(
            refA,
            _crumbWeek + 1
        );

        assertEq(
            referredInput,
            AT_CAP_REFERRED + 60 * 1e6 * YEAR / WEEK
        );

        assertEq(
            selfInput,
            AT_CAP_SELF
        );

        assertEq(
            gapReferredInput,
            AT_CAP_REFERRED
        );

        assertEq(
            gapSelfInput,
            AT_CAP_SELF
        );
    }

    function _referredInputAt(
        uint256 _week
    )
        internal
        view
        returns (uint256 referredInput)
    {
        (
            referredInput,
        ) = hub.ladderInputsAt(
            refA,
            _week
        );
    }

    function _assertRichCursor(
        bytes32 _source,
        uint256 _crumbWeek
    )
        internal
        view
    {
        (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        ) = hub.paidCursorAtSource(
            _source,
            refA,
            _crumbWeek
        );

        assertEq(
            y1Cursor,
            AT_CAP_REFERRED * WEEK
        );

        assertEq(
            y2Cursor,
            40 * 1e6 * YEAR
        );

        assertEq(
            mCursor,
            20 * 1e6 * YEAR
        );
    }

    function _establishTier6(
        address
    )
        internal
        returns (uint256 week)
    {
        vm.warp(
            block.timestamp + 2 weeks
        );

        return block.timestamp / WEEK;
    }

    function _establishAtCapAndWarp(
        address _referrer
    )
        internal
        returns (uint256 crumbWeek)
    {
        crumbWeek = block.timestamp / WEEK + 2;

        vm.warp(
            block.timestamp + 4 weeks
        );

        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            crumbWeek,
            crumbWeek + 2,
            AT_CAP_SELF
        );

        hub.reportSelf(
            _referrer,
            runs
        );
    }

    function _establishTier6OneDayPastClose(
        address _referrer
    )
        internal
        returns (uint256 week)
    {
        week = _establishTier6(
            _referrer
        );

        vm.warp(
            (week + 1) * WEEK + CLOSE_PLUS_ONE_DAY
        );
    }

    function _establishTier6Cadence(
        address
    )
        internal
        returns (uint256 week)
    {
        vm.warp(
            block.timestamp + 2 weeks
        );

        return block.timestamp / WEEK;
    }

    function _tableWithBotShare(
        uint32 _effectiveFromWeek,
        uint16 _botShareBps
    )
        internal
        pure
        returns (ReferralHubDeclarations.RateTable memory table)
    {
        table.effectiveFromWeek = _effectiveFromWeek;
        table.capBps = 1_000;
        table.y2RateBps = 500;
        table.mRateBps = 100;
        table.botShareBps = _botShareBps;

        table.tierBps = [
            uint16(100),
            200,
            300,
            400,
            500,
            600,
            700,
            800
        ];

        table.thresholds = [
            uint96(5_000 * 1e6),
            10_000 * 1e6,
            20_000 * 1e6,
            30_000 * 1e6,
            50_000 * 1e6,
            100_000 * 1e6,
            500_000 * 1e6,
            1_000_000 * 1e6
        ];
    }

    function _remoteCrumbApply(
        bytes32 _messageId,
        address _deliverer,
        uint256 _stamp,
        uint256 _week
    )
        internal
    {
        bytes memory payload = _crumbPayload(
            _deliverer,
            _stamp,
            refA,
            _week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            _messageId,
            payload
        );

        hub.applyFlush(
            _messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );
    }

    function _twoCrumbPayload(
        address _deliverer,
        uint256 _stamp,
        address _referrer,
        uint256 _firstWeek,
        uint256 _firstWord,
        uint256 _secondWeek,
        uint256 _secondWord
    )
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory words = new uint256[](6);

        words[0] = CohortFlushCodec._packFlushHeader(
            _deliverer,
            1,
            _stamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            _referrer,
            2,
            0,
            0,
            0
        );

        words[2] = _firstWeek;
        words[3] = _firstWord;
        words[4] = _secondWeek;
        words[5] = _secondWord;

        return abi.encodePacked(
            words
        );
    }

    function _findFlushReceivedLog()
        internal
        returns (Vm.Log memory)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "FlushReceived(bytes32,uint64,address,uint256,bytes)"
        );

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics[0] == topic) {
                return logs[i];
            }
        }

        revert(
            "FlushReceived log not found"
        );
    }

    function _findLogByTopic(
        bytes32 _topic
    )
        internal
        returns (Vm.Log memory)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics[0] == _topic) {
                return logs[i];
            }
        }

        revert(
            "log not found"
        );
    }

    function _cursorWordAtSource(
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

    function _accrueCourierShareTwoChains()
        internal
        returns (uint256 expectedShare)
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_ARB,
                    spokeVault,
                    CHAIN_ARB
                )
            )
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_ARB,
                    spokeRegistry,
                    CHAIN_ARB
                )
            )
        );

        _pushDesignationFrom(
            SEL_BASE,
            courier,
            address(0),
            block.timestamp - 1 days,
            0
        );

        _pushDesignationFrom(
            SEL_ARB,
            courier,
            address(0),
            block.timestamp - 1 days,
            0
        );

        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0xC8)),
            payload
        );

        _receiveFlushFrom(
            bytes32(uint256(0xC9)),
            SEL_ARB,
            spokeVault,
            payload
        );

        hub.applyFlush(
            bytes32(uint256(0xC8)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        hub.applyFlush(
            bytes32(uint256(0xC9)),
            SEL_ARB,
            CHAIN_ARB,
            spokeVault,
            payload
        );

        expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;
    }

    function _backlogReleasedCount()
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "PayoutBacklogReleased(uint256,address,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    // ---- constructor seed ----

    function test_constructor_seedsGenesisBotShare()
        public
    {
        IReferralHub freshHub = _deployHub(
            address(usd)
        );

        assertEq(
            freshHub.rateTableCount(),
            1
        );

        assertEq(
            freshHub.rateTableAt(
                0
            ).botShareBps,
            GENESIS_BOT_SHARE_BPS
        );

        assertEq(
            hub.rateTableAt(
                0
            ).botShareBps,
            GENESIS_BOT_SHARE_BPS
        );
    }

    // ---- setCcipRouter ----

    function test_setCcipRouter_setsAndEmits()
        public
    {
        IReferralHub freshHub = _deployHub(
            address(usd)
        );

        HubLeverGrants._queue(
            address(freshHub),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    routerEoa
                )
            )
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(freshHub)
        );

        emit CcipRouterSet(
            routerEoa
        );

        freshHub.setCcipRouter(
            routerEoa
        );

        assertEq(
            freshHub.ccipRouter(),
            routerEoa
        );
    }

    function test_RevertWhen_setCcipRouter_zeroAddress()
        public
    {
        IReferralHub freshHub = _deployHub(
            address(usd)
        );

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        freshHub.setCcipRouter(
            address(0)
        );
    }

    function test_setCcipRouter_rePointsAndEmits()
        public
    {
        address newRouter = address(0xF9);

        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    newRouter
                )
            )
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(hub)
        );

        emit CcipRouterSet(
            newRouter
        );

        hub.setCcipRouter(
            newRouter
        );

        assertEq(
            hub.ccipRouter(),
            newRouter
        );

        bytes memory payload = _selfPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotCcipRouter.selector
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(0xA1)),
                SEL_BASE,
                spokeVault,
                payload
            )
        );

        vm.prank(
            newRouter
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(0xA1)),
                SEL_BASE,
                spokeVault,
                payload
            )
        );

        assertTrue(hub.flushCommitment(bytes32(uint256(0xA1))) != bytes32(0));
    }

    function test_RevertWhen_setCcipRouter_calledByStranger()
        public
    {
        IReferralHub freshHub = _deployHub(
            address(usd)
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        freshHub.setCcipRouter(
            routerEoa
        );
    }

    // ---- setFlushSource ----

    function test_setFlushSource_setsAndEmits()
        public
    {
        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_ARB,
                    spokeVault,
                    CHAIN_ARB
                )
            )
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushSourceSet(
            SEL_ARB,
            spokeVault,
            CHAIN_ARB
        );

        hub.setFlushSource(
            SEL_ARB,
            spokeVault,
            CHAIN_ARB
        );

        assertEq(
            hub.flushSourceChainId(
                SEL_ARB,
                spokeVault
            ),
            CHAIN_ARB
        );
    }

    function test_setFlushSource_removalViaChainIdZero()
        public
    {
        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushSourceSet(
            SEL_BASE,
            spokeVault,
            0
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            0
        );

        assertEq(
            hub.flushSourceChainId(
                SEL_BASE,
                spokeVault
            ),
            0
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushSource.selector
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(1)),
                SEL_BASE,
                spokeVault,
                hex""
            )
        );
    }

    function test_RevertWhen_setFlushSource_zeroVault()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.setFlushSource(
            SEL_BASE,
            address(0),
            CHAIN_BASE
        );
    }

    function test_RevertWhen_setFlushSource_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            CHAIN_BASE
        );
    }

    // ---- setDesignationSource ----

    function test_setDesignationSource_setsAndEmitsAndRemoves()
        public
    {
        HubLeverGrants._queue(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_ARB,
                    spokeRegistry,
                    CHAIN_ARB
                )
            )
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit DesignationSourceSet(
            SEL_ARB,
            spokeRegistry,
            CHAIN_ARB
        );

        hub.setDesignationSource(
            SEL_ARB,
            spokeRegistry,
            CHAIN_ARB
        );

        assertEq(
            hub.designationSourceChainId(
                SEL_ARB,
                spokeRegistry
            ),
            CHAIN_ARB
        );

        hub.setDesignationSource(
            SEL_ARB,
            spokeRegistry,
            0
        );

        assertEq(
            hub.designationSourceChainId(
                SEL_ARB,
                spokeRegistry
            ),
            0
        );
    }

    function test_RevertWhen_setDesignationSource_zeroRegistry()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        hub.setDesignationSource(
            SEL_BASE,
            address(0),
            CHAIN_BASE
        );
    }

    function test_RevertWhen_setDesignationSource_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.setDesignationSource(
            SEL_BASE,
            spokeRegistry,
            CHAIN_BASE
        );
    }

    // ---- courier share as a rate-table field ----

    function test_pushRateTable_botShare_schedulesFromEffectiveWeek()
        public
    {
        uint256 week = block.timestamp / WEEK;

        hub.pushRateTable(
            _tableWithBotShare(
                uint32(week + 1),
                MAX_BOT_SHARE_BPS
            )
        );

        assertEq(
            hub.rateTableCount(),
            2
        );

        assertEq(
            hub.rateTableAt(
                0
            ).botShareBps,
            GENESIS_BOT_SHARE_BPS
        );

        assertEq(
            hub.rateTableAt(
                1
            ).botShareBps,
            MAX_BOT_SHARE_BPS
        );

        assertEq(
            hub.rateTableAt(
                1
            ).effectiveFromWeek,
            week + 1
        );
    }

    function test_RevertWhen_pushRateTable_botShareAboveCap()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.BotShareTooHigh.selector
        );

        hub.pushRateTable(
            _tableWithBotShare(
                uint32(block.timestamp / WEEK + 1),
                MAX_BOT_SHARE_BPS + 1
            )
        );
    }

    // ---- supportsInterface ----

    function test_supportsInterface_matchesReceiverAndErc165()
        public
        view
    {
        assertTrue(
            hub.supportsInterface(
                type(IAny2EVMMessageReceiver).interfaceId
            )
        );

        assertTrue(
            hub.supportsInterface(
                type(IERC165).interfaceId
            )
        );

        assertFalse(
            hub.supportsInterface(
                0xffffffff
            )
        );
    }

    // ---- ccipReceive ----

    function test_RevertWhen_ccipReceive_callerNotRouter()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotCcipRouter.selector
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(1)),
                SEL_BASE,
                spokeVault,
                hex""
            )
        );
    }

    function test_RevertWhen_ccipReceive_unknownSource()
        public
    {
        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushSource.selector
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(1)),
                SEL_BASE,
                address(0xEE),
                hex""
            )
        );
    }

    function test_ccipReceive_flushSource_storesCommitmentAndEmits()
        public
    {
        bytes memory payload = _selfPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6
        );

        bytes32 messageId = bytes32(
            uint256(0x11)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit FlushReceived(
            messageId,
            SEL_BASE,
            spokeVault,
            CHAIN_BASE,
            payload
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        assertEq(
            hub.flushCommitment(
                messageId
            ),
            keccak256(
                abi.encode(
                    SEL_BASE,
                    CHAIN_BASE,
                    spokeVault,
                    payload
                )
            )
        );
    }

    function test_RevertWhen_ccipReceive_duplicateMessageId()
        public
    {
        bytes memory payload = _selfPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6
        );

        bytes32 messageId = bytes32(
            uint256(0x12)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralHubDeclarations.FlushAlreadyReceived.selector
        );

        hub.ccipReceive(
            _flushMessage(
                messageId,
                SEL_BASE,
                spokeVault,
                payload
            )
        );
    }

    function test_ccipReceive_designationPush_appliesInline()
        public
    {
        uint256 setAt = block.timestamp - 10;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit DesignationPushReceived(
            SEL_BASE,
            CHAIN_BASE,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit PayoutAddressSet(
            CHAIN_BASE,
            refA,
            designated
        );

        _pushDesignation(
            refA,
            designated,
            setAt,
            5
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            designated
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            (setAt << 8) | 5
        );
    }

    // ---- applyFlush commitment ----

    function test_RevertWhen_applyFlush_commitmentMismatch()
        public
    {
        bytes memory payload = _crumbPayload(
            refB,
            block.timestamp,
            refB,
            block.timestamp / WEEK - 1,
            _word(
                1,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x22)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            bytes32(uint256(0xDEAD)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            abi.encodePacked(
                payload,
                uint256(0)
            )
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            messageId,
            SEL_ARB,
            CHAIN_ARB,
            spokeVault,
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            address(0xEE),
            payload
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );
    }

    // ---- envelope validation ----

    function test_RevertWhen_applyFlush_wrongFlushVersion()
        public
    {
        uint256[] memory words = new uint256[](1);

        words[0] = uint256(uint160(refA))
            | (2 << CohortFlushCodec.FLUSH_VERSION_SHIFT)
            | (CohortWeeks.CRUMB_VERSION << CohortFlushCodec.FLUSH_CRUMB_VERSION_SHIFT)
            | (1 << CohortFlushCodec.FLUSH_ENTRY_COUNT_SHIFT);

        _receiveThenApplyInvalid(
            bytes32(uint256(0x31)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_wrongCrumbVersion()
        public
    {
        uint256[] memory words = new uint256[](1);

        words[0] = uint256(uint160(refA))
            | (CohortFlushCodec.FLUSH_VERSION << CohortFlushCodec.FLUSH_VERSION_SHIFT)
            | (2 << CohortFlushCodec.FLUSH_CRUMB_VERSION_SHIFT)
            | (1 << CohortFlushCodec.FLUSH_ENTRY_COUNT_SHIFT);

        _receiveThenApplyInvalid(
            bytes32(uint256(0x32)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_headerReservedBits()
        public
    {
        uint256[] memory words = new uint256[](1);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        ) | (1 << CohortFlushCodec.FLUSH_HEADER_RESERVED_SHIFT);

        _receiveThenApplyInvalid(
            bytes32(uint256(0x33)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_entryCountZero()
        public
    {
        uint256[] memory words = new uint256[](1);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            0,
            block.timestamp
        );

        _receiveThenApplyInvalid(
            bytes32(uint256(0x34)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_entryCountAboveMax()
        public
    {
        uint256[] memory words = new uint256[](1);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            CohortFlushCodec.MAX_FLUSH_ENTRIES + 1,
            block.timestamp
        );

        _receiveThenApplyInvalid(
            bytes32(uint256(0x35)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_zeroReferrer()
        public
    {
        uint256[] memory words = new uint256[](2);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            address(0),
            0,
            0,
            0,
            0
        );

        _receiveThenApplyInvalid(
            bytes32(uint256(0x36)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_entryReservedBits()
        public
    {
        uint256[] memory words = new uint256[](2);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            0,
            0,
            0,
            0
        ) | (1 << CohortFlushCodec.FLUSH_ENTRY_RESERVED_SHIFT);

        _receiveThenApplyInvalid(
            bytes32(uint256(0x37)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_unknownFlagBit()
        public
    {
        uint256[] memory words = new uint256[](2);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            0,
            0,
            2,
            0
        );

        _receiveThenApplyInvalid(
            bytes32(uint256(0x38)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_selfRunReservedBits()
        public
    {
        uint256 week = block.timestamp / WEEK;

        uint256[] memory words = new uint256[](3);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            0,
            0,
            0,
            1
        );

        words[2] = CohortFlushCodec._packSelfRun(
            week - 1,
            week,
            1_000 * 1e6
        ) | (1 << CohortFlushCodec.SELF_RUN_RESERVED_SHIFT);

        bytes memory payload = abi.encodePacked(
            words
        );

        _receiveFlushAs(
            bytes32(uint256(0x39)),
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.InvalidSelfRun.selector
        );

        hub.applyFlush(
            bytes32(uint256(0x39)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );
    }

    function test_applyFlush_selfRun_recordsEveryWeekOfTheRun()
        public
    {
        uint256 week = block.timestamp / WEEK;

        uint256[] memory words = new uint256[](3);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            0,
            0,
            0,
            1
        );

        words[2] = CohortFlushCodec._packSelfRun(
            week - 3,
            week - 1,
            50_000 * 1e6
        );

        bytes memory payload = abi.encodePacked(
            words
        );

        _receiveFlushAs(
            bytes32(uint256(0x3A9)),
            payload
        );

        hub.applyFlush(
            bytes32(uint256(0x3A9)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        bytes32 source = _remoteSourceOf(
            CHAIN_BASE,
            spokeVault
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                week - 3
            ),
            50_000 * 1e6
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                week - 2
            ),
            50_000 * 1e6
        );

        assertEq(
            hub.weekSelfOf(
                source,
                refA,
                week - 1
            ),
            0
        );

        assertEq(
            hub.sourceChainIdOf(
                _remoteSourceOf(
                    CHAIN_BASE,
                    spokeVault
                )
            ),
            CHAIN_BASE
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            0
        );
    }

    function test_RevertWhen_applyFlush_designationReservedBits()
        public
    {
        uint256[] memory words = new uint256[](3);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            0,
            0,
            CohortFlushCodec.FLUSH_FLAG_DESIGNATION,
            0
        );

        words[2] = CohortFlushCodec._packFlushDesignation(
            designated,
            block.timestamp,
            1
        ) | (1 << CohortFlushCodec.FLUSH_DESIGNATION_RESERVED_SHIFT);

        _receiveThenApplyInvalid(
            bytes32(uint256(0x3A)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_truncatedPayload()
        public
    {
        uint256[] memory words = new uint256[](2);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            1,
            0,
            0,
            0
        );

        _receiveThenApplyInvalid(
            bytes32(uint256(0x3B)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_trailingGarbage()
        public
    {
        uint256[] memory words = new uint256[](3);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            0,
            0,
            0,
            0
        );

        words[2] = 0;

        _receiveThenApplyInvalid(
            bytes32(uint256(0x3C)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_gapFromNotBeforeTo()
        public
    {
        _receiveThenApplyInvalid(
            bytes32(uint256(0x3D)),
            _gapPayload(
                refA,
                block.timestamp,
                refA,
                CohortWeeks._packGapRecord(
                    2_900,
                    2_900,
                    0
                )
            )
        );
    }

    function test_RevertWhen_applyFlush_gapSpanAboveMax()
        public
    {
        _receiveThenApplyInvalid(
            bytes32(uint256(0x3E)),
            _gapPayload(
                refA,
                block.timestamp,
                refA,
                CohortWeeks._packGapRecord(
                    2_800,
                    2_905,
                    0
                )
            )
        );
    }

    function test_RevertWhen_applyFlush_workAboveMax()
        public
    {
        uint256[] memory words = new uint256[](7);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            2,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            0,
            1,
            0,
            0
        );

        words[2] = CohortWeeks._packGapRecord(
            2_800,
            2_904,
            0
        );

        words[3] = CohortFlushCodec._packFlushEntry(
            refB,
            1,
            1,
            0,
            0
        );

        words[4] = 2_999;

        words[5] = _word(
            1,
            0,
            0
        );

        words[6] = CohortWeeks._packGapRecord(
            2_600,
            2_704,
            0
        );

        _receiveThenApplyInvalid(
            bytes32(uint256(0x3F)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_applyFlush_openWeekRevert_selfHealsAfterBoundary()
        public
    {
        bytes memory payload = _crumbPayload(
            refB,
            block.timestamp,
            refB,
            block.timestamp / WEEK,
            _word(
                5,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x41)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.WeekNotClosed.selector
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        vm.warp(
            block.timestamp + 1 weeks
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushApplied(
            messageId,
            _remoteSourceOf(
                CHAIN_BASE,
                spokeVault
            ),
            1
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refB
            ),
            0
        );
    }

    // ---- happy path application ----

    function test_applyFlush_richEnvelope_appliesCrumbGapAndDesignation()
        public
    {
        uint256 crumbWeek = _establishAtCapAndWarp(
            refA
        );

        uint256 stamp = block.timestamp;

        uint256 setAt = block.timestamp - 1 hours;

        bytes memory payload = _richPayload(
            stamp,
            crumbWeek,
            setAt
        );

        bytes32 messageId = bytes32(
            uint256(0x51)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        bytes32 source = _remoteSourceOf(
            CHAIN_BASE,
            spokeVault
        );

        uint256 expectedPaid = _richExpectedPaid();

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit PayoutAddressSet(
            CHAIN_BASE,
            refA,
            designated
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushApplied(
            messageId,
            source,
            1
        );

        vm.prank(
            stranger
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        _assertRichBuckets(
            crumbWeek
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            designated
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            (setAt << 8) | 2
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid
        );

        assertEq(
            hub.totalPayable(),
            expectedPaid
        );
    }

    // ---- idempotence and ordering ----

    function test_applyFlush_reapply_isIdempotent()
        public
    {
        uint256 crumbWeek = _establishAtCapAndWarp(
            refA
        );

        uint256 stamp = block.timestamp;

        uint256 setAt = block.timestamp - 1 hours;

        bytes memory payload = _richPayload(
            stamp,
            crumbWeek,
            setAt
        );

        bytes32 messageId = bytes32(
            uint256(0x52)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        bytes32 source = _remoteSourceOf(
            CHAIN_BASE,
            spokeVault
        );

        uint256 claimableAfterFirst = hub.claimable(
            CHAIN_BASE,
            refA
        );

        uint256 referredAfterFirst = _referredInputAt(
            crumbWeek
        );

        uint256 accruedAfterFirst = hub.totalAccrued();

        uint256 payoutStampAfterFirst = hub.payoutStamp(
            CHAIN_BASE,
            refA
        );

        vm.recordLogs();

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            vm.getRecordedLogs().length,
            1
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            claimableAfterFirst
        );

        assertEq(
            _referredInputAt(
                crumbWeek
            ),
            referredAfterFirst
        );

        assertEq(
            hub.totalAccrued(),
            accruedAfterFirst
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            payoutStampAfterFirst
        );

        _assertRichCursor(
            source,
            crumbWeek
        );
    }

    // ---- bot share ----

    function test_applyFlush_remoteDeliverer_paysFeeOnTopOfFullCommission()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x71)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit DelivererSharePaid(
            CHAIN_BASE,
            courier,
            refA,
            messageId,
            expectedShare
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + expectedShare
        );
    }

    function test_applyFlush_delivererIsReferrer_paysReferrerFully()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        bytes memory payload = _crumbPayload(
            refA,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x72)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        vm.recordLogs();

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0]
                    != keccak256("DelivererSharePaid(uint256,address,address,bytes32,uint256)")
            );
        }

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID
        );
    }

    function test_applyFlush_botShareZero_noFee()
        public
    {
        uint256 week = _establishTier6Cadence(
            refA
        );

        hub.pushRateTable(
            _tableWithBotShare(
                uint32(week + 1),
                0
            )
        );

        vm.warp(
            (week + 2) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        _remoteCrumbApply(
            bytes32(uint256(0x73)),
            courier,
            block.timestamp,
            week + 1
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            0
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID
        );
    }

    function test_applyFlush_botShareAtCap_paysMaxFeeOnTop()
        public
    {
        uint256 week = _establishTier6Cadence(
            refA
        );

        hub.pushRateTable(
            _tableWithBotShare(
                uint32(week + 1),
                MAX_BOT_SHARE_BPS
            )
        );

        vm.warp(
            (week + 2) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        _remoteCrumbApply(
            bytes32(uint256(0x74)),
            courier,
            block.timestamp,
            week + 1
        );

        uint256 expectedShare = TIER6_PAID * MAX_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + expectedShare
        );
    }

    function test_applyFlush_botShare_closedWeekKeepsItsShare()
        public
    {
        uint256 week = _establishTier6Cadence(
            refA
        );

        hub.pushRateTable(
            _tableWithBotShare(
                uint32(week + 1),
                MAX_BOT_SHARE_BPS
            )
        );

        vm.warp(
            (week + 2) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        _remoteCrumbApply(
            bytes32(uint256(0x75)),
            courier,
            block.timestamp,
            week
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_applyFlush_botShare_lazyOldWeek_usesThatWeeksShare()
        public
    {
        uint256 week = _establishTier6Cadence(
            refA
        );

        hub.pushRateTable(
            _tableWithBotShare(
                uint32(week + 1),
                MAX_BOT_SHARE_BPS
            )
        );

        vm.warp(
            (week + 2) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        bytes memory payload = _twoCrumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            ),
            week + 1,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x7E)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000
            + TIER6_PAID * MAX_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            2 * TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            2 * TIER6_PAID + expectedShare
        );
    }

    function test_applyFlush_shareCap_clampsFeeReferrerKeepsFullCommission()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        uint256 cap = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000 / 2;

        hub.setDelivererShareCap(
            cap
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x7C1)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit DelivererSharePaid(
            CHAIN_BASE,
            courier,
            refA,
            messageId,
            cap
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            cap
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + cap
        );
    }

    function test_applyFlush_shareCapAtShare_paysFullShare()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        hub.setDelivererShareCap(
            expectedShare
        );

        _remoteCrumbApply(
            bytes32(uint256(0x7C2)),
            courier,
            block.timestamp,
            week
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_applyFlush_shareCap_appliesPerPricedWeek()
        public
    {
        uint256 week = _establishTier6Cadence(
            refA
        );

        vm.warp(
            (week + 2) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        uint256 cap = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000 / 4;

        hub.setDelivererShareCap(
            cap
        );

        bytes memory payload = _twoCrumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            ),
            week + 1,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x7C3)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            2 * cap
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            2 * TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            2 * TIER6_PAID + 2 * cap
        );
    }

    function test_deliverCrumbs_localCourierShareCap_clamps()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        hub.setDelivererShareCap(
            1
        );

        _localCrumbDelivery(
            courier,
            week
        );

        assertEq(
            hub.claimable(
                block.chainid,
                courier
            ),
            1
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + 1
        );
    }

    function test_applyFlush_shareCapSetAfterReceive_appliesAtApply()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x7C4)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.setDelivererShareCap(
            7
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            7
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_localCourierBucket_firstClaimStampsReleasesAndPays()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _localCrumbDelivery(
            courier,
            week
        );

        uint256 share = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.payoutStamp(
                block.chainid,
                courier
            ),
            0
        );

        assertEq(
            hub.totalPayable(),
            0
        );

        usd.mint(
            address(hub),
            share
        );

        vm.prank(
            courier
        );

        hub.claim(
            block.chainid,
            courier
        );

        assertEq(
            usd.balanceOf(
                courier
            ),
            share
        );

        assertEq(
            hub.claimable(
                block.chainid,
                courier
            ),
            0
        );

        assertTrue(hub.payoutStamp(block.chainid, courier) != 0);

        assertEq(
            hub.totalPayable(),
            share
        );

        assertEq(
            hub.totalClaimed(),
            share
        );
    }

    function test_shareCap_appliesPerSourceOfOneReferrerWeek()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        hub.setDelivererShareCap(
            3
        );

        _localCrumbDelivery(
            courier,
            week
        );

        _remoteCrumbApply(
            bytes32(uint256(0x7C5)),
            courier,
            block.timestamp,
            week
        );

        assertEq(
            hub.claimable(
                block.chainid,
                courier
            ),
            3
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            3
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_deliverCrumbs_localSelfFlush_paysReferrerFully()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        vm.recordLogs();

        _localCrumbDelivery(
            refA,
            week
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0]
                    != keccak256("DelivererSharePaid(uint256,address,address,bytes32,uint256)")
            );
        }

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                block.chainid,
                address(this)
            ),
            0
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID
        );
    }

    function test_deliverCrumbs_localCourier_paysFeeOnTop()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit DelivererSharePaid(
            block.chainid,
            courier,
            refA,
            bytes32(0),
            expectedShare
        );

        _localCrumbDelivery(
            courier,
            week
        );

        assertEq(
            hub.claimable(
                block.chainid,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                block.chainid,
                address(this)
            ),
            0
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + expectedShare
        );
    }

    function test_RevertWhen_deliverCrumbs_localCourierOpenWeek()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.WeekNotClosed.selector
        );

        _localCrumbDelivery(
            courier,
            week
        );
    }

    function test_deliverGap_localCourier_paysFeeEveryClosedWeek()
        public
    {
        uint256 fromWeek = _establishAtCapAndWarp(
            refA
        );

        hub.deliverGap(
            refA,
            courier,
            CohortWeeks._packGapRecord(
                fromWeek,
                fromWeek + 2,
                AT_CAP_REFERRED
            ),
            fromWeek,
            2
        );

        uint256 weekPaid = AT_CAP_REFERRED * WEEK * M_GENESIS_BPS / 10_000 / YEAR;

        uint256 expectedShare = 2 * (weekPaid * GENESIS_BOT_SHARE_BPS / 10_000);

        assertEq(
            hub.claimable(
                block.chainid,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            2 * weekPaid
        );

        assertEq(
            hub.totalAccrued(),
            2 * weekPaid + expectedShare
        );
    }

    function _localCrumbDelivery(
        address _deliverer,
        uint256 _week
    )
        internal
    {
        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = _week;

        words_[0] = _word(
            TIER6_QUANTITY,
            0,
            0
        );

        hub.deliverCrumbs(
            refA,
            _deliverer,
            weeks_,
            words_
        );
    }

    // ---- courier build window ----

    function test_applyFlush_courier_buildAtClosingBoundary_paysFee()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0x76)),
            courier,
            (week + 1) * WEEK,
            week
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + expectedShare
        );
    }

    function test_applyFlush_zeroHeaderDeliverer_paysNoCourierFee()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0x7a)),
            address(0),
            block.timestamp,
            week
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                address(0)
            ),
            0
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID
        );
    }

    function test_applyFlush_courier_oneDayPastClose_paysFee()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        assertEq(
            block.timestamp,
            (week + 1) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        _remoteCrumbApply(
            bytes32(uint256(0x77)),
            courier,
            block.timestamp,
            week
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + expectedShare
        );
    }

    function test_applyFlush_courier_staleWeek_paysFee()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            block.timestamp + 3 weeks
        );

        _remoteCrumbApply(
            bytes32(uint256(0x79)),
            courier,
            block.timestamp,
            week
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_applyFlush_courier_lateApply_pricesByBuildStamp()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        bytes memory earlyBuild = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0x7C)),
            earlyBuild
        );

        vm.warp(
            (week + 1) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        bytes memory lateBuild = _crumbPayload(
            courier2,
            block.timestamp,
            refA,
            week,
            _word(
                2 * TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0x7D)),
            lateBuild
        );

        vm.warp(
            block.timestamp + 2 weeks
        );

        hub.applyFlush(
            bytes32(uint256(0x7C)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            earlyBuild
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        hub.applyFlush(
            bytes32(uint256(0x7D)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            lateBuild
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier2
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            2 * TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            2 * TIER6_PAID + 2 * expectedShare
        );
    }

    function test_applyFlush_courier_closedBuildAppliedBeforeOwnFlush_takesShare()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        bytes memory ownFlush = _crumbPayload(
            refA,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0xA1)),
            ownFlush
        );

        vm.warp(
            (week + 1) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        _remoteCrumbApply(
            bytes32(uint256(0xA2)),
            courier,
            block.timestamp,
            week
        );

        hub.applyFlush(
            bytes32(uint256(0xA1)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            ownFlush
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + expectedShare
        );
    }

    function test_applyFlush_courier_straddlingPairReversed_laterBuildEnvelopeTakesWholeWord()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        bytes memory earlyBuild = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0xA3)),
            earlyBuild
        );

        vm.warp(
            (week + 1) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        _remoteCrumbApply(
            bytes32(uint256(0xA4)),
            courier2,
            block.timestamp,
            week
        );

        hub.applyFlush(
            bytes32(uint256(0xA3)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            earlyBuild
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier2
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            0
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + expectedShare
        );
    }

    function test_applyFlush_courier_gapRecord_paysFeeEveryClosedWeek()
        public
    {
        uint256 fromWeek = _establishAtCapAndWarp(
            refA
        );

        bytes memory payload = _gapPayload(
            courier,
            block.timestamp,
            refA,
            CohortWeeks._packGapRecord(
                fromWeek,
                fromWeek + 2,
                AT_CAP_REFERRED
            )
        );

        bytes32 messageId = bytes32(
            uint256(0xA5)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        uint256 weekPaid = AT_CAP_REFERRED * WEEK * M_GENESIS_BPS / 10_000 / YEAR;

        uint256 expectedShare = 2 * (weekPaid * GENESIS_BOT_SHARE_BPS / 10_000);

        assertEq(
            block.timestamp,
            (fromWeek + 2) * WEEK + 1 hours
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            2 * weekPaid
        );

        assertEq(
            hub.totalAccrued(),
            2 * weekPaid + expectedShare
        );
    }

    // ---- designation rails ----

    function test_designationPush_latestWins_olderStampIsNoop()
        public
    {
        uint256 setAt = block.timestamp - 10;

        _pushDesignation(
            refA,
            designated,
            setAt,
            0
        );

        vm.recordLogs();

        _pushDesignation(
            refA,
            address(0xF3),
            setAt - 100,
            0
        );

        assertEq(
            vm.getRecordedLogs().length,
            1
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            designated
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            setAt << 8
        );
    }

    function test_designationPush_equalStamp_isNoop()
        public
    {
        uint256 setAt = block.timestamp - 10;

        _pushDesignation(
            refA,
            designated,
            setAt,
            3
        );

        _pushDesignation(
            refA,
            address(0xF3),
            setAt,
            3
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            designated
        );
    }

    function test_designationPush_zeroSetAt_skipsWithEvent()
        public
    {
        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushDesignationSkipped(
            CHAIN_BASE,
            refA,
            1
        );

        _pushDesignation(
            refA,
            designated,
            0,
            1
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            address(0)
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            0
        );
    }

    function test_designationPush_farFutureSetAt_skipsBoundaryApplies()
        public
    {
        uint256 tooFar = block.timestamp
            + 1 hours
            + 1;

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushDesignationSkipped(
            CHAIN_BASE,
            refA,
            tooFar << 8
        );

        _pushDesignation(
            refA,
            designated,
            tooFar,
            0
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            address(0)
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            0
        );

        _pushDesignation(
            refA,
            designated,
            block.timestamp + 1 hours,
            0
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            designated
        );
    }

    function test_designationPush_rankOverflow_skipsWithEvent()
        public
    {
        uint256 setAt = block.timestamp - 10;

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushDesignationSkipped(
            CHAIN_BASE,
            refA,
            (setAt << 8) | 256
        );

        _pushDesignation(
            refA,
            designated,
            setAt,
            256
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            address(0)
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            0
        );
    }

    function test_RevertWhen_designationPush_payloadInvalid()
        public
    {
        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralHubDeclarations.FlushPayloadInvalid.selector
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(0x81)),
                SEL_BASE,
                spokeRegistry,
                abi.encode(
                    DESIGNATION_VERSION,
                    refA,
                    designated,
                    block.timestamp
                )
            )
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralHubDeclarations.FlushPayloadInvalid.selector
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(0x82)),
                SEL_BASE,
                spokeRegistry,
                abi.encode(
                    DESIGNATION_VERSION + 1,
                    refA,
                    designated,
                    block.timestamp,
                    uint256(0)
                )
            )
        );

        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralHubDeclarations.FlushPayloadInvalid.selector
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(0x83)),
                SEL_BASE,
                spokeRegistry,
                abi.encode(
                    DESIGNATION_VERSION,
                    address(0),
                    designated,
                    block.timestamp,
                    uint256(0)
                )
            )
        );
    }

    function test_RevertWhen_designationPush_syncShapedVersionOne()
        public
    {
        vm.prank(
            routerEoa
        );

        vm.expectRevert(
            ReferralHubDeclarations.FlushPayloadInvalid.selector
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(0x84)),
                SEL_BASE,
                spokeRegistry,
                abi.encode(
                    uint256(1),
                    refB,
                    refA,
                    block.timestamp - 1 days,
                    uint256(1)
                )
            )
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refB
            ),
            address(0)
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refB
            ),
            0
        );
    }

    function test_designation_localAndRemoteBucketsIndependent_claimPaysRemoteDesignation()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        bytes memory payload = _crumbPayload(
            refA,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0x91)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        usd.mint(
            address(hub),
            TIER6_PAID
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            address(0xF3)
        );

        _pushDesignation(
            refA,
            designated,
            block.timestamp - 10,
            1
        );

        assertEq(
            hub.payoutAddressOf(
                block.chainid,
                refA
            ),
            address(0xF3)
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            designated
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit PayoutClaimed(
            CHAIN_BASE,
            refA,
            designated,
            TIER6_PAID
        );

        vm.prank(
            refA
        );

        hub.claim(
            CHAIN_BASE,
            refA
        );

        assertEq(
            usd.balanceOf(
                designated
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            0
        );
    }

    // ---- spoke buckets pay only after a designation landed ----

    function test_RevertWhen_claim_undesignatedRemoteBucket()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0x92)),
            refA,
            block.timestamp,
            week
        );

        usd.mint(
            address(hub),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            0
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PayoutNotDesignated.selector
        );

        hub.claim(
            CHAIN_BASE,
            refA
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_RevertWhen_claimUpTo_undesignatedRemoteBucket()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0x93)),
            refA,
            block.timestamp,
            week
        );

        usd.mint(
            address(hub),
            TIER6_PAID
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PayoutNotDesignated.selector
        );

        hub.claimUpTo(
            CHAIN_BASE,
            refA,
            1
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_claimablesOf_remoteBucketCountsOnlyOnceDesignated()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0x95)),
            refA,
            block.timestamp,
            week
        );

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = block.chainid;
        chainIds[1] = CHAIN_BASE;

        (
            uint256[] memory amounts,
            address[] memory payouts,
            uint256 total,
            uint256 claimableNow
        ) = reader.claimablesOf(
            refA,
            chainIds
        );

        assertEq(
            amounts[0],
            hub.claimable(
                block.chainid,
                refA
            )
        );

        assertEq(
            amounts[1],
            TIER6_PAID
        );

        assertEq(
            payouts[0],
            refA
        );

        assertEq(
            payouts[1],
            address(0)
        );

        assertEq(
            total,
            amounts[0] + TIER6_PAID
        );

        assertEq(
            claimableNow,
            amounts[0]
        );

        _pushDesignation(
            refA,
            designated,
            block.timestamp - 10,
            1
        );

        (
            amounts,
            payouts,
            total,
            claimableNow
        ) = reader.claimablesOf(
            refA,
            chainIds
        );

        assertEq(
            payouts[1],
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            )
        );

        assertEq(
            payouts[1],
            designated
        );

        assertEq(
            claimableNow,
            total
        );

        assertEq(
            total,
            amounts[0] + TIER6_PAID
        );
    }

    function test_claimablesOf_emptyChainList_returnsEmpty()
        public
        view
    {
        uint256[] memory chainIds = new uint256[](0);

        (
            uint256[] memory amounts,
            address[] memory payouts,
            uint256 total,
            uint256 claimableNow
        ) = reader.claimablesOf(
            refA,
            chainIds
        );

        assertEq(
            amounts.length,
            0
        );

        assertEq(
            payouts.length,
            0
        );

        assertEq(
            total,
            0
        );

        assertEq(
            claimableNow,
            0
        );
    }

    function test_claimAll_paysDesignatedBucketSkipsTheRest()
        public
    {
        _accrueCourierShareTwoChains();

        _pushDesignation(
            refA,
            designated,
            block.timestamp - 10,
            1
        );

        usd.mint(
            address(hub),
            2 * TIER6_PAID
        );

        uint256[] memory chainIds = new uint256[](4);
        chainIds[0] = block.chainid;
        chainIds[1] = CHAIN_BASE;
        chainIds[2] = CHAIN_ARB;
        chainIds[3] = CHAIN_BASE;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit PayoutClaimed(
            CHAIN_BASE,
            refA,
            designated,
            TIER6_PAID
        );

        vm.prank(
            refA
        );

        uint256 total = hub.claimAll(
            refA,
            chainIds
        );

        assertEq(
            total,
            TIER6_PAID
        );

        assertEq(
            usd.balanceOf(
                designated
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            0
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_claimAll_courierClaimsBothChainsInOneCall()
        public
    {
        uint256 share = _accrueCourierShareTwoChains();

        usd.mint(
            address(hub),
            2 * share
        );

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = CHAIN_BASE;
        chainIds[1] = CHAIN_ARB;

        vm.prank(
            courier
        );

        uint256 total = hub.claimAll(
            courier,
            chainIds
        );

        assertEq(
            total,
            2 * share
        );

        assertEq(
            usd.balanceOf(
                courier
            ),
            2 * share
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            0
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                courier
            ),
            0
        );
    }

    function test_claimAll_shortPot_paysTheCoverInListOrder()
        public
    {
        uint256 share = _accrueCourierShareTwoChains();

        usd.mint(
            address(hub),
            share + share / 2
        );

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = CHAIN_BASE;
        chainIds[1] = CHAIN_ARB;

        vm.prank(
            courier
        );

        uint256 total = hub.claimAll(
            courier,
            chainIds
        );

        assertEq(
            total,
            share + share / 2
        );

        assertEq(
            usd.balanceOf(
                courier
            ),
            share + share / 2
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            0
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                courier
            ),
            share - share / 2
        );

        assertEq(
            usd.balanceOf(
                address(hub)
            ),
            0
        );
    }

    function test_RevertWhen_claimAll_emptyPot()
        public
    {
        uint256 share = _accrueCourierShareTwoChains();

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = CHAIN_BASE;
        chainIds[1] = CHAIN_ARB;

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        vm.prank(
            courier
        );

        hub.claimAll(
            courier,
            chainIds
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            share
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                courier
            ),
            share
        );
    }

    function test_claimAll_payoutAddressClaimsOnlyItsOwnBuckets()
        public
    {
        _accrueCourierShareTwoChains();

        _pushDesignation(
            refA,
            designated,
            block.timestamp - 10,
            1
        );

        _pushDesignationFrom(
            SEL_ARB,
            refA,
            address(0),
            block.timestamp - 10,
            1
        );

        usd.mint(
            address(hub),
            2 * TIER6_PAID
        );

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = CHAIN_BASE;
        chainIds[1] = CHAIN_ARB;

        vm.prank(
            designated
        );

        uint256 total = hub.claimAll(
            refA,
            chainIds
        );

        assertEq(
            total,
            TIER6_PAID
        );

        assertEq(
            usd.balanceOf(
                designated
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                refA
            ),
            TIER6_PAID
        );

        vm.prank(
            refA
        );

        total = hub.claimAll(
            refA,
            chainIds
        );

        assertEq(
            total,
            TIER6_PAID
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            TIER6_PAID
        );
    }

    function test_RevertWhen_claimAll_strangerOrNothingPayable()
        public
    {
        _accrueCourierShareTwoChains();

        _pushDesignation(
            refA,
            designated,
            block.timestamp - 10,
            1
        );

        usd.mint(
            address(hub),
            2 * TIER6_PAID
        );

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = CHAIN_BASE;
        chainIds[1] = CHAIN_ARB;

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        vm.prank(
            stranger
        );

        hub.claimAll(
            refA,
            chainIds
        );

        uint256[] memory undesignatedOnly = new uint256[](1);
        undesignatedOnly[0] = CHAIN_ARB;

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        vm.prank(
            refA
        );

        hub.claimAll(
            refA,
            undesignatedOnly
        );

        uint256[] memory none = new uint256[](0);

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        vm.prank(
            refA
        );

        hub.claimAll(
            refA,
            none
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_claim_zeroDesignationRemoteBucket_paysOwner()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0x94)),
            refA,
            block.timestamp,
            week
        );

        usd.mint(
            address(hub),
            TIER6_PAID
        );

        _pushDesignation(
            refA,
            address(0),
            block.timestamp - 10,
            1
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            refA
        );

        assertTrue(hub.payoutStamp(CHAIN_BASE, refA) != 0);

        vm.prank(
            refA
        );

        hub.claim(
            CHAIN_BASE,
            refA
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            0
        );
    }

    function test_RevertWhen_claim_hubChainDesignationDoesNotUnlockSpokeBucket()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0x95)),
            refA,
            block.timestamp,
            week
        );

        usd.mint(
            address(hub),
            TIER6_PAID
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            designated
        );

        assertTrue(hub.payoutStamp(block.chainid, refA) != 0);

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            0
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PayoutNotDesignated.selector
        );

        hub.claim(
            CHAIN_BASE,
            refA
        );
    }

    function test_RevertWhen_claim_otherSpokeDesignationDoesNotUnlockBucket()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0x96)),
            refA,
            block.timestamp,
            week
        );

        usd.mint(
            address(hub),
            TIER6_PAID
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    SEL_ARB,
                    spokeRegistry,
                    CHAIN_ARB
                )
            )
        );

        _pushDesignationFrom(
            SEL_ARB,
            refA,
            designated,
            block.timestamp - 10,
            2
        );

        assertTrue(hub.payoutStamp(CHAIN_ARB, refA) != 0);

        assertEq(
            hub.payoutStamp(
                CHAIN_BASE,
                refA
            ),
            0
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PayoutNotDesignated.selector
        );

        hub.claim(
            CHAIN_BASE,
            refA
        );
    }

    // ---- cross-source isolation ----

    function test_applyFlush_sameVaultTwoChains_sourcesIsolated()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_ARB,
                    spokeVault,
                    CHAIN_ARB
                )
            )
        );

        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256 stamp = block.timestamp;

        bytes memory payload = _crumbPayload(
            refA,
            stamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0xA1)),
            payload
        );

        _receiveFlushFrom(
            bytes32(uint256(0xA2)),
            SEL_ARB,
            spokeVault,
            payload
        );

        hub.applyFlush(
            bytes32(uint256(0xA1)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        hub.applyFlush(
            bytes32(uint256(0xA2)),
            SEL_ARB,
            CHAIN_ARB,
            spokeVault,
            payload
        );

        bytes32 baseSource = _remoteSourceOf(
            CHAIN_BASE,
            spokeVault
        );

        bytes32 arbSource = _remoteSourceOf(
            CHAIN_ARB,
            spokeVault
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                refA
            ),
            TIER6_PAID
        );

        (
            uint256 baseAverage,
        ) = hub.weekReportOf(
            baseSource,
            refA,
            week
        );

        (
            uint256 arbAverage,
        ) = hub.weekReportOf(
            arbSource,
            refA,
            week
        );

        (
            uint256 referredInput,
        ) = hub.ladderInputsAt(
            refA,
            week
        );

        assertEq(
            baseAverage,
            TIER6_QUANTITY / WEEK
        );

        assertEq(
            arbAverage,
            TIER6_QUANTITY / WEEK
        );

        assertEq(
            referredInput,
            2 * TIER6_QUANTITY / WEEK
        );
    }

    // ---- log-only reconstruction ----

    function test_applyFlush_reconstructedFromLogsOnly_appliesAndMatchesCommitment()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        vm.recordLogs();

        _receiveFlushAs(
            bytes32(uint256(0xC1)),
            payload
        );

        Vm.Log memory logged = _findFlushReceivedLog();

        bytes32 loggedId = logged.topics[1];

        address loggedVault = address(
            uint160(
                uint256(
                    logged.topics[3]
                )
            )
        );

        uint64 loggedSelector = uint64(
            uint256(
                logged.topics[2]
            )
        );

        (
            uint256 loggedChainId,
            bytes memory loggedPayload
        ) = abi.decode(
            logged.data,
            (uint256, bytes)
        );

        assertEq(
            loggedId,
            bytes32(uint256(0xC1))
        );

        assertEq(
            loggedSelector,
            SEL_BASE
        );

        assertEq(
            loggedVault,
            spokeVault
        );

        assertEq(
            loggedChainId,
            CHAIN_BASE
        );

        assertEq(
            loggedPayload,
            payload
        );

        assertEq(
            hub.flushCommitment(
                loggedId
            ),
            keccak256(
                abi.encode(
                    loggedSelector,
                    loggedChainId,
                    loggedVault,
                    loggedPayload
                )
            )
        );

        vm.prank(
            stranger
        );

        hub.applyFlush(
            loggedId,
            loggedSelector,
            loggedChainId,
            loggedVault,
            loggedPayload
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );
    }

    function test_RevertWhen_applyFlush_logJoinWrongSourceChainId()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_ARB,
                    spokeVault,
                    CHAIN_ARB
                )
            )
        );

        bytes memory payload = _selfPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6
        );

        vm.recordLogs();

        _receiveFlushAs(
            bytes32(uint256(0xC2)),
            payload
        );

        Vm.Log memory logged = _findFlushReceivedLog();

        address loggedVault = address(
            uint160(
                uint256(
                    logged.topics[3]
                )
            )
        );

        (
            ,
            bytes memory loggedPayload
        ) = abi.decode(
            logged.data,
            (uint256, bytes)
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            logged.topics[1],
            SEL_ARB,
            CHAIN_ARB,
            loggedVault,
            loggedPayload
        );
    }

    // ---- courier redelivery race ----

    function test_applyFlush_secondCourierSameWindow_pricesZeroNoShare()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        bytes memory firstPayload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes memory secondPayload = _crumbPayload(
            courier2,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0xC3)),
            firstPayload
        );

        _receiveFlushAs(
            bytes32(uint256(0xC4)),
            secondPayload
        );

        hub.applyFlush(
            bytes32(uint256(0xC3)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            firstPayload
        );

        uint256 referrerAfterFirst = hub.claimable(
            CHAIN_BASE,
            refA
        );

        uint256 courierAfterFirst = hub.claimable(
            CHAIN_BASE,
            courier
        );

        uint256 accruedAfterFirst = hub.totalAccrued();

        vm.recordLogs();

        hub.applyFlush(
            bytes32(uint256(0xC4)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            secondPayload
        );

        assertEq(
            vm.getRecordedLogs().length,
            1
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            referrerAfterFirst
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            courierAfterFirst
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier2
            ),
            0
        );

        assertEq(
            hub.totalAccrued(),
            accruedAfterFirst
        );
    }

    function test_applyFlush_secondCourierGrownWord_shareOnIncrementOnly()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        bytes memory firstPayload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes memory secondPayload = _crumbPayload(
            courier2,
            block.timestamp,
            refA,
            week,
            _word(
                2 * TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0xC5)),
            firstPayload
        );

        _receiveFlushAs(
            bytes32(uint256(0xC6)),
            secondPayload
        );

        hub.applyFlush(
            bytes32(uint256(0xC5)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            firstPayload
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit DelivererSharePaid(
            CHAIN_BASE,
            courier2,
            refA,
            bytes32(uint256(0xC6)),
            expectedShare
        );

        hub.applyFlush(
            bytes32(uint256(0xC6)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            secondPayload
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier2
            ),
            expectedShare
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            2 * TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            2 * TIER6_PAID + 2 * expectedShare
        );
    }

    function test_applyFlush_workExactlyMax_applies()
        public
    {
        uint256[] memory words = new uint256[](5);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            2,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            0,
            1,
            0,
            0
        );

        words[2] = CohortWeeks._packGapRecord(
            2_800,
            2_880,
            0
        );

        words[3] = CohortFlushCodec._packFlushEntry(
            refB,
            0,
            1,
            0,
            0
        );

        words[4] = CohortWeeks._packGapRecord(
            2_600,
            2_680,
            0
        );

        bytes memory payload = abi.encodePacked(
            words
        );

        bytes32 messageId = bytes32(
            uint256(0xC7)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit FlushApplied(
            messageId,
            _remoteSourceOf(
                CHAIN_BASE,
                spokeVault
            ),
            2
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );
    }

    function test_applyFlush_duplicateReferrerEntries_priceEachWeekOnce()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256[] memory words = new uint256[](7);

        words[0] = CohortFlushCodec._packFlushHeader(
            refA,
            2,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            refA,
            1,
            0,
            0,
            0
        );

        words[2] = week;

        words[3] = _word(
            TIER6_QUANTITY,
            0,
            0
        );

        words[4] = CohortFlushCodec._packFlushEntry(
            refA,
            1,
            0,
            0,
            0
        );

        words[5] = week;

        words[6] = _word(
            TIER6_QUANTITY,
            0,
            0
        );

        bytes memory payload = abi.encodePacked(
            words
        );

        bytes32 messageId = bytes32(
            uint256(0xCA)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID
        );
    }

    // ---- courier buckets across source chains ----

    function test_courierBuckets_twoSourceChains_accumulateIndependently()
        public
    {
        uint256 share = _accrueCourierShareTwoChains();

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            share
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                courier
            ),
            share
        );

        assertEq(
            hub.claimable(
                block.chainid,
                courier
            ),
            0
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_courierClaimUpTo_partialBaseLeavesArbBucketIntact()
        public
    {
        uint256 share = _accrueCourierShareTwoChains();

        usd.mint(
            address(hub),
            2 * share
        );

        vm.prank(
            courier
        );

        hub.claimUpTo(
            CHAIN_BASE,
            courier,
            share / 2
        );

        assertEq(
            usd.balanceOf(
                courier
            ),
            share / 2
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            share - share / 2
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                courier
            ),
            share
        );

        vm.prank(
            courier
        );

        hub.claim(
            CHAIN_ARB,
            courier
        );

        assertEq(
            usd.balanceOf(
                courier
            ),
            share / 2 + share
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            share - share / 2
        );

        assertEq(
            hub.claimable(
                CHAIN_ARB,
                courier
            ),
            0
        );
    }

    function test_courierDesignation_redirectsCourierShareClaimOnly()
        public
    {
        uint256 share = _accrueCourierShareTwoChains();

        usd.mint(
            address(hub),
            share
        );

        _pushDesignation(
            courier,
            address(0xF4),
            block.timestamp - 10,
            0
        );

        _pushDesignation(
            refA,
            designated,
            block.timestamp - 10,
            1
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                courier
            ),
            address(0xF4)
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            designated
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit PayoutClaimed(
            CHAIN_BASE,
            courier,
            address(0xF4),
            share
        );

        vm.prank(
            courier
        );

        hub.claim(
            CHAIN_BASE,
            courier
        );

        assertEq(
            usd.balanceOf(
                address(0xF4)
            ),
            share
        );

        assertEq(
            usd.balanceOf(
                courier
            ),
            0
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            0
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_RevertWhen_claim_strangerOnCourierBucket()
        public
    {
        _accrueCourierShareTwoChains();

        usd.mint(
            address(hub),
            TIER6_PAID
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotPayoutAuthorized.selector
        );

        hub.claim(
            CHAIN_BASE,
            courier
        );
    }

    // ---- source keys and source-keyed views ----

    function test_sourceKeyOf_remoteMatchesMailboxKey()
        public
    {
        bytes memory payload = _selfPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6
        );

        bytes32 messageId = bytes32(
            uint256(0xE1)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        bytes32 viewKey = hub.sourceKeyOf(
            CHAIN_BASE,
            spokeVault
        );

        vm.recordLogs();

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        Vm.Log memory applied = _findLogByTopic(
            keccak256(
                "FlushApplied(bytes32,bytes32,uint256)"
            )
        );

        assertEq(
            viewKey,
            keccak256(
                abi.encode(
                    CHAIN_BASE,
                    spokeVault
                )
            )
        );

        assertEq(
            applied.topics[1],
            messageId
        );

        assertEq(
            applied.topics[2],
            viewKey
        );
    }

    function test_sourceKeyOf_localMatchesReporterKey()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = week;

        words_[0] = _word(
            TIER6_QUANTITY,
            0,
            0
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeks_,
            words_
        );

        bytes32 localKey = hub.sourceKeyOf(
            block.chainid,
            address(this)
        );

        (
            uint256 y1ByReporter,
            uint256 y2ByReporter,
            uint256 mByReporter
        ) = reader.paidCursorAt(
            address(this),
            refA,
            week
        );

        uint256 sourceWord = _cursorWordAtSource(
            localKey,
            refA,
            week
        );

        assertEq(
            localKey,
            bytes32(uint256(uint160(address(this))))
        );

        assertEq(
            y1ByReporter,
            TIER6_QUANTITY
        );

        assertEq(
            sourceWord,
            CohortWeeks._packLanes(
                y1ByReporter,
                y2ByReporter,
                mByReporter
            )
        );
    }

    function test_paidCursorAtSource_remoteSourceReadable()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + 1 hours
        );

        uint256 crumbWord = _word(
            TIER6_QUANTITY,
            40 * 1e6 * YEAR,
            20 * 1e6 * YEAR
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            crumbWord
        );

        bytes32 messageId = bytes32(
            uint256(0xE2)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        bytes32 sourceKey = hub.sourceKeyOf(
            CHAIN_BASE,
            spokeVault
        );

        uint256 cursorBefore = _cursorWordAtSource(
            sourceKey,
            refA,
            week
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        uint256 cursorAfter = _cursorWordAtSource(
            sourceKey,
            refA,
            week
        );

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        uint256 cursorAgain = _cursorWordAtSource(
            sourceKey,
            refA,
            week
        );

        assertEq(
            cursorBefore,
            0
        );

        assertEq(
            cursorAfter,
            crumbWord & ~WRITTEN_BIT
        );

        assertEq(
            CohortWeeks._laneY1(
                cursorAfter
            ),
            TIER6_QUANTITY
        );

        assertEq(
            CohortWeeks._laneY2(
                cursorAfter
            ),
            40 * 1e6 * YEAR
        );

        assertEq(
            CohortWeeks._laneM(
                cursorAfter
            ),
            20 * 1e6 * YEAR
        );

        assertEq(
            cursorAgain,
            cursorAfter
        );
    }

    // ---- courier share message id ----

    function test_delivererSharePaid_carriesMessageId()
        public
    {
        uint256 week = _establishTier6OneDayPastClose(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        bytes32 messageId = bytes32(
            uint256(0xE4)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit DelivererSharePaid(
            CHAIN_BASE,
            courier,
            refA,
            messageId,
            expectedShare
        );

        vm.recordLogs();

        hub.applyFlush(
            messageId,
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        Vm.Log memory shareLog = _findLogByTopic(
            keccak256(
                "DelivererSharePaid(uint256,address,address,bytes32,uint256)"
            )
        );

        (
            bytes32 loggedMessageId,
            uint256 loggedAmount
        ) = abi.decode(
            shareLog.data,
            (bytes32, uint256)
        );

        assertEq(
            shareLog.topics[1],
            bytes32(CHAIN_BASE)
        );

        assertEq(
            shareLog.topics[2],
            bytes32(uint256(uint160(courier)))
        );

        assertEq(
            shareLog.topics[3],
            bytes32(uint256(uint160(refA)))
        );

        assertEq(
            loggedMessageId,
            messageId
        );

        assertEq(
            loggedAmount,
            expectedShare
        );
    }

    // ---- hardening: source setters, the apply re-check and the deliverer guard ----

    function test_RevertWhen_setFlushSource_hubChainId()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.SourceOnHubChain.selector
        );

        hub.setFlushSource(
            SEL_ARB,
            spokeVault,
            block.chainid
        );
    }

    function test_RevertWhen_setDesignationSource_hubChainId()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.SourceOnHubChain.selector
        );

        hub.setDesignationSource(
            SEL_ARB,
            spokeRegistry,
            block.chainid
        );
    }

    function test_RevertWhen_applyFlush_sourceRemovedAfterCommit()
        public
    {
        uint256 week = block.timestamp / WEEK - 1;

        bytes memory payload = _crumbPayload(
            refA,
            block.timestamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0xA2)),
            payload
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            0
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushSource.selector
        );

        hub.applyFlush(
            bytes32(uint256(0xA2)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_BASE,
                    spokeVault,
                    CHAIN_BASE
                )
            )
        );

        hub.applyFlush(
            bytes32(uint256(0xA2)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );
    }

    function test_RevertWhen_applyFlush_wrongSelectorForCommitment()
        public
    {
        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    SEL_ARB,
                    spokeVault,
                    CHAIN_BASE
                )
            )
        );

        bytes memory payload = _selfPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6
        );

        _receiveFlushAs(
            bytes32(uint256(0xA3)),
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            bytes32(uint256(0xA3)),
            SEL_ARB,
            CHAIN_BASE,
            spokeVault,
            payload
        );
    }

    function test_applyFlush_farFutureStamp_paysFeeOnHubClock()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        vm.warp(
            (week + 1) * WEEK + CLOSE_PLUS_ONE_DAY - 30 minutes
        );

        uint256 stamp = block.timestamp + MAX_FUTURE_DRIFT + 1;

        bytes memory payload = _crumbPayload(
            courier,
            stamp,
            refA,
            week,
            _word(
                TIER6_QUANTITY,
                0,
                0
            )
        );

        _receiveFlushAs(
            bytes32(uint256(0xA6)),
            payload
        );

        hub.applyFlush(
            bytes32(uint256(0xA6)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                refA
            ),
            TIER6_PAID
        );

        assertEq(
            hub.claimable(
                CHAIN_BASE,
                courier
            ),
            expectedShare
        );
    }

    // ---- payable amount: a spoke bucket joins what the pot owes only once its designation has landed ----

    function test_applyFlush_undesignatedBuckets_joinPayableAtDesignation()
        public
    {
        uint256 week = _establishTier6Cadence(
            refA
        );

        vm.warp(
            (week + 2) * WEEK + CLOSE_PLUS_ONE_DAY
        );

        _remoteCrumbApply(
            bytes32(uint256(0xD1)),
            courier,
            block.timestamp,
            week
        );

        uint256 share = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(
            hub.totalAccrued(),
            TIER6_PAID + share
        );

        assertEq(
            hub.totalPayable(),
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit PayoutBacklogReleased(
            CHAIN_BASE,
            refA,
            TIER6_PAID
        );

        _pushDesignation(
            refA,
            address(0),
            block.timestamp,
            1
        );

        assertEq(
            hub.totalPayable(),
            TIER6_PAID
        );

        _pushDesignation(
            courier,
            address(0),
            block.timestamp,
            1
        );

        assertEq(
            hub.totalPayable(),
            TIER6_PAID + share
        );

        vm.recordLogs();

        _pushDesignation(
            courier,
            designated,
            block.timestamp + 1,
            1
        );

        assertEq(
            _backlogReleasedCount(),
            0
        );

        assertEq(
            hub.totalPayable(),
            TIER6_PAID + share
        );

        _remoteCrumbApply(
            bytes32(uint256(0xD2)),
            courier,
            block.timestamp,
            week + 1
        );

        assertEq(
            hub.totalAccrued(),
            2 * (TIER6_PAID + share)
        );

        assertEq(
            hub.totalPayable(),
            2 * (TIER6_PAID + share)
        );
    }

    function test_designationPush_emptyBucket_releasesNothing()
        public
    {
        vm.recordLogs();

        _pushDesignation(
            refB,
            address(0),
            block.timestamp,
            1
        );

        assertEq(
            _backlogReleasedCount(),
            0
        );

        assertEq(
            hub.totalPayable(),
            0
        );

        assertTrue(hub.payoutStamp(CHAIN_BASE, refB) != 0);
    }

    function test_payoutAddressOf_undesignatedSpokeBucket_isZero()
        public
    {
        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            address(0)
        );

        assertEq(
            hub.payoutAddressOf(
                block.chainid,
                refA
            ),
            refA
        );

        _pushDesignation(
            refA,
            address(0),
            block.timestamp,
            1
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            refA
        );

        _pushDesignation(
            refA,
            designated,
            block.timestamp + 1,
            1
        );

        assertEq(
            hub.payoutAddressOf(
                CHAIN_BASE,
                refA
            ),
            designated
        );
    }

    // ---- triage pins: the boundary second, the range check, envelope release, reader parity ----

    function test_applyFlush_envelopeDesignation_releasesBacklog()
        public
    {
        uint256 crumbWeek = _establishAtCapAndWarp(
            refA
        );

        _remoteCrumbApply(
            bytes32(uint256(0xD7)),
            refA,
            block.timestamp,
            crumbWeek
        );

        uint256 backlog = hub.claimable(
            CHAIN_BASE,
            refA
        );

        assertGt(
            backlog,
            0
        );

        assertEq(
            hub.totalPayable(),
            0
        );

        bytes memory payload = _richPayload(
            block.timestamp,
            crumbWeek,
            block.timestamp - 1 hours
        );

        _receiveFlushAs(
            bytes32(uint256(0xD8)),
            payload
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(hub)
        );

        emit PayoutBacklogReleased(
            CHAIN_BASE,
            refA,
            backlog
        );

        hub.applyFlush(
            bytes32(uint256(0xD8)),
            SEL_BASE,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(
            hub.totalPayable(),
            hub.claimable(
                CHAIN_BASE,
                refA
            )
        );

        assertEq(
            hub.totalAccrued(),
            hub.totalPayable()
        );
    }

}
