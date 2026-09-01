// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

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
 * @dev Minimal payout-vault stand-in recording the hub's liability
 * bookings: accumulates `raisePendingReferralPayout` into a readable
 * pending amount, counts calls, and remembers the last raised delta
 * so tests can assert one booking per delivery batch.
 */
contract MockPayoutVault {

    uint256 public pendingReferralPayout;

    uint256 public raiseCallCount;

    uint256 public lastRaisedAmount;

    function raisePendingReferralPayout(
        uint256 _amount
    )
        external
    {
        pendingReferralPayout = pendingReferralPayout + _amount;

        raiseCallCount = raiseCallCount + 1;

        lastRaisedAmount = _amount;
    }

    function fundReferralPayout(
        uint256
    )
        external
    {}

    function getPendingReferralPayout()
        external
        view
        returns (uint256)
    {
        return pendingReferralPayout;
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
 * cap, and the self-healing future-week revert), remote application
 * through the shared intake internals under `keccak256(chainId,
 * vault)` source keys (absolute scores gated by the envelope build
 * stamp with greater-or-equal semantics, crumb and gap pricing into
 * per-source-chain claimable buckets, one liability booking per
 * apply), idempotent re-application and out-of-order envelope
 * convergence, the courier bot-share split for remote non-own-book
 * deliveries across the full bps range, the designation rails
 * (latest-wins stamps, strict-greater replay no-ops, skip anomalies
 * for zero / far-future / rank-overflowing pairs, push payload
 * validation, and local-versus-remote bucket independence proven
 * through a real claim), and cross-source isolation for the same
 * vault address registered under two chain selectors. Also covered:
 * reconstructing a full `applyFlush` call exclusively from the
 * decoded `FlushReceived` log (with a wrong-chain log join failing
 * closed), the two-courier redelivery race on one crumb window
 * (exhausted cursors price zero and pay the losing courier nothing;
 * a grown word pays the second courier on the increment only), an
 * envelope at exactly the total work cap, and the courier claimable
 * bucket lifecycle across two source chains (independent buckets,
 * partial claims, courier-own designations, stranger lockout).
 * Rates come from the genesis table via locally reported scores
 * under the dwell-min boundary recipe; `address(this)` is master
 * and the local reporter.
 */
contract ReferralHubMailboxTest is Test {

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

    event BotShareBpsSet(
        uint256 botShareBps
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

    event DelivererSharePaid(
        uint256 indexed chainId,
        address indexed deliverer,
        address indexed referrer,
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

    uint256 internal constant HIGH_SCORE = 100_000 * 1e6;

    uint256 internal constant TIER6_BPS = 600;

    uint256 internal constant AT_CAP_REFERRED = 1_000_000 * 1e6;

    uint256 internal constant AT_CAP_SELF = 10_000 * 1e6;

    uint256 internal constant CAP_BPS = 1_000;

    uint256 internal constant Y2_GENESIS_BPS = 500;

    uint256 internal constant M_GENESIS_BPS = 100;

    uint256 internal constant GENESIS_BOT_SHARE_BPS = 1_000;

    uint256 internal constant DESIGNATION_VERSION = 1;

    uint64 internal constant SEL_BASE = 10_001;

    uint64 internal constant SEL_ARB = 10_002;

    uint256 internal constant CHAIN_BASE = 8_453;

    uint256 internal constant CHAIN_ARB = 42_161;

    uint256 internal constant TIER6_QUANTITY = 100 * 1e6 * CohortWeeks.YEAR;

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

    MockPayoutVault internal payoutVaultMock;

    ReferralHub internal hub;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        payoutVaultMock = new MockPayoutVault();

        hub = new ReferralHub(
            address(usd)
        );

        hub.setAllowedReporter(
            address(this),
            true
        );

        hub.setCcipRouter(
            routerEoa
        );

        hub.setFlushSource(
            SEL_BASE,
            spokeVault,
            CHAIN_BASE
        );

        hub.setDesignationSource(
            SEL_BASE,
            spokeRegistry,
            CHAIN_BASE
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
        return CohortWeeks.packLanes(
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
        vm.prank(
            routerEoa
        );

        hub.ccipReceive(
            _flushMessage(
                bytes32(uint256(0xD0)),
                SEL_BASE,
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
        uint256 _referred,
        uint256 _self,
        uint256 _week,
        uint256 _crumbWord
    )
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory words = new uint256[](5);

        words[0] = CohortWeeks.packFlushHeader(
            _deliverer,
            1,
            _stamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            _referrer,
            1,
            0,
            0
        );

        words[2] = CohortWeeks.packFlushScores(
            _referred,
            _self
        );

        words[3] = _week;
        words[4] = _crumbWord;

        return abi.encodePacked(
            words
        );
    }

    function _scoresPayload(
        address _deliverer,
        uint256 _stamp,
        address _referrer,
        uint256 _referred,
        uint256 _self
    )
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory words = new uint256[](3);

        words[0] = CohortWeeks.packFlushHeader(
            _deliverer,
            1,
            _stamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            _referrer,
            0,
            0,
            0
        );

        words[2] = CohortWeeks.packFlushScores(
            _referred,
            _self
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
        uint256[] memory words = new uint256[](4);

        words[0] = CohortWeeks.packFlushHeader(
            _deliverer,
            1,
            _stamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            _referrer,
            0,
            1,
            0
        );

        words[2] = CohortWeeks.packFlushScores(
            0,
            0
        );

        words[3] = _record;

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
        uint256[] memory words = new uint256[](7);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            _stamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            1,
            1,
            CohortWeeks.FLUSH_FLAG_DESIGNATION
        );

        words[2] = CohortWeeks.packFlushScores(
            1_000 * 1e6,
            500 * 1e6
        );

        words[3] = CohortWeeks.packFlushDesignation(
            designated,
            _designationSetAt,
            2
        );

        words[4] = _crumbWeek;

        words[5] = _word(
            100 * 1e6 * YEAR,
            40 * 1e6 * YEAR,
            20 * 1e6 * YEAR
        );

        words[6] = CohortWeeks.packGapRecord(
            _crumbWeek + 1,
            _crumbWeek + 2,
            5_200 * 1e6
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
        return 100 * 1e6 * YEAR * CAP_BPS / 10_000 / YEAR
            + 40 * 1e6 * YEAR * Y2_GENESIS_BPS / 10_000 / YEAR
            + 20 * 1e6 * YEAR * M_GENESIS_BPS / 10_000 / YEAR
            + 5_200 * 1e6 * WEEK * M_GENESIS_BPS / 10_000 / YEAR;
    }

    function _establishTier6(
        address _referrer
    )
        internal
        returns (uint256 week)
    {
        hub.reportScores(
            _referrer,
            HIGH_SCORE,
            0
        );

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
        uint256 reportWeek = block.timestamp / WEEK;

        hub.reportScores(
            _referrer,
            AT_CAP_REFERRED,
            AT_CAP_SELF
        );

        vm.warp(
            block.timestamp + 4 weeks
        );

        return reportWeek + 2;
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

    function _accrueCourierShareTwoChains()
        internal
        returns (uint256 expectedShare)
    {
        hub.setFlushSource(
            SEL_ARB,
            spokeVault,
            CHAIN_ARB
        );

        uint256 week = _establishTier6(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
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
            CHAIN_BASE,
            spokeVault,
            payload
        );

        hub.applyFlush(
            bytes32(uint256(0xC9)),
            CHAIN_ARB,
            spokeVault,
            payload
        );

        expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;
    }

    // ---- constructor seed ----

    function test_constructor_seedsGenesisBotShare()
        public
    {
        assertEq(hub.botShareBps(), GENESIS_BOT_SHARE_BPS);

        vm.expectEmit(
            false,
            false,
            false,
            true
        );

        emit BotShareBpsSet(
            GENESIS_BOT_SHARE_BPS
        );

        new ReferralHub(
            address(usd)
        );
    }

    // ---- setCcipRouter ----

    function test_setCcipRouter_setsAndEmits()
        public
    {
        ReferralHub freshHub = new ReferralHub(
            address(usd)
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

        assertEq(freshHub.ccipRouter(), routerEoa);
    }

    function test_RevertWhen_setCcipRouter_zeroAddress()
        public
    {
        ReferralHub freshHub = new ReferralHub(
            address(usd)
        );

        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        freshHub.setCcipRouter(
            address(0)
        );
    }

    function test_RevertWhen_setCcipRouter_alreadySet()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.RouterAlreadySet.selector
        );

        hub.setCcipRouter(
            address(0xF9)
        );
    }

    function test_RevertWhen_setCcipRouter_calledByStranger()
        public
    {
        ReferralHub freshHub = new ReferralHub(
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

        assertEq(hub.flushSourceChainId(SEL_ARB, spokeVault), CHAIN_ARB);
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

        assertEq(hub.flushSourceChainId(SEL_BASE, spokeVault), 0);

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

        assertEq(hub.designationSourceChainId(SEL_ARB, spokeRegistry), CHAIN_ARB);

        hub.setDesignationSource(
            SEL_ARB,
            spokeRegistry,
            0
        );

        assertEq(hub.designationSourceChainId(SEL_ARB, spokeRegistry), 0);
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

    // ---- setBotShareBps ----

    function test_setBotShareBps_setsAndEmits()
        public
    {
        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(hub)
        );

        emit BotShareBpsSet(
            2_500
        );

        hub.setBotShareBps(
            2_500
        );

        assertEq(hub.botShareBps(), 2_500);
    }

    function test_RevertWhen_setBotShareBps_aboveDenominator()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.BotShareTooHigh.selector
        );

        hub.setBotShareBps(
            10_001
        );
    }

    function test_RevertWhen_setBotShareBps_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        hub.setBotShareBps(
            0
        );
    }

    // ---- supportsInterface ----

    function test_supportsInterface_matchesReceiverAndErc165()
        public
        view
    {
        assertTrue(hub.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(hub.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hub.supportsInterface(0xffffffff));
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
        bytes memory payload = _scoresPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6,
            0
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
            hub.flushCommitment(messageId),
            keccak256(
                abi.encode(
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
        bytes memory payload = _scoresPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6,
            0
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

        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), designated);
        assertEq(hub.payoutStamp(CHAIN_BASE, refA), (setAt << 8) | 5);
    }

    // ---- applyFlush commitment ----

    function test_RevertWhen_applyFlush_commitmentMismatch()
        public
    {
        bytes memory payload = _crumbPayload(
            refB,
            block.timestamp,
            refB,
            0,
            0,
            block.timestamp / WEEK,
            _word(1, 0, 0)
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
            CHAIN_BASE,
            spokeVault,
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            messageId,
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
            CHAIN_ARB,
            spokeVault,
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            messageId,
            CHAIN_BASE,
            address(0xEE),
            payload
        );

        hub.applyFlush(
            messageId,
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
            | (2 << CohortWeeks.FLUSH_VERSION_SHIFT)
            | (CohortWeeks.CRUMB_VERSION << CohortWeeks.FLUSH_CRUMB_VERSION_SHIFT)
            | (1 << CohortWeeks.FLUSH_ENTRY_COUNT_SHIFT);

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
            | (CohortWeeks.FLUSH_VERSION << CohortWeeks.FLUSH_VERSION_SHIFT)
            | (2 << CohortWeeks.FLUSH_CRUMB_VERSION_SHIFT)
            | (1 << CohortWeeks.FLUSH_ENTRY_COUNT_SHIFT);

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

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            block.timestamp
        ) | (1 << CohortWeeks.FLUSH_HEADER_RESERVED_SHIFT);

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

        words[0] = CohortWeeks.packFlushHeader(
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

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            CohortWeeks.MAX_FLUSH_ENTRIES + 1,
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

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            address(0),
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
        uint256[] memory words = new uint256[](3);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            0,
            0,
            0
        ) | (1 << CohortWeeks.FLUSH_ENTRY_RESERVED_SHIFT);

        words[2] = CohortWeeks.packFlushScores(
            0,
            0
        );

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
        uint256[] memory words = new uint256[](3);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            0,
            0,
            2
        );

        words[2] = CohortWeeks.packFlushScores(
            0,
            0
        );

        _receiveThenApplyInvalid(
            bytes32(uint256(0x38)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_scoresReservedBits()
        public
    {
        uint256[] memory words = new uint256[](3);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            0,
            0,
            0
        );

        words[2] = 1 << CohortWeeks.FLUSH_SCORE_RESERVED_SHIFT;

        _receiveThenApplyInvalid(
            bytes32(uint256(0x39)),
            abi.encodePacked(
                words
            )
        );
    }

    function test_RevertWhen_applyFlush_designationReservedBits()
        public
    {
        uint256[] memory words = new uint256[](4);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            0,
            0,
            CohortWeeks.FLUSH_FLAG_DESIGNATION
        );

        words[2] = CohortWeeks.packFlushScores(
            0,
            0
        );

        words[3] = CohortWeeks.packFlushDesignation(
            designated,
            block.timestamp,
            1
        ) | (1 << CohortWeeks.FLUSH_DESIGNATION_RESERVED_SHIFT);

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
        uint256[] memory words = new uint256[](3);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            1,
            0,
            0
        );

        words[2] = CohortWeeks.packFlushScores(
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
        uint256[] memory words = new uint256[](4);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            1,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            0,
            0,
            0
        );

        words[2] = CohortWeeks.packFlushScores(
            0,
            0
        );

        words[3] = 0;

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
                CohortWeeks.packGapRecord(
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
                CohortWeeks.packGapRecord(
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
        uint256[] memory words = new uint256[](9);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            2,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            0,
            1,
            0
        );

        words[2] = CohortWeeks.packFlushScores(
            0,
            0
        );

        words[3] = CohortWeeks.packGapRecord(
            2_800,
            2_904,
            0
        );

        words[4] = CohortWeeks.packFlushEntry(
            refB,
            1,
            1,
            0
        );

        words[5] = CohortWeeks.packFlushScores(
            0,
            0
        );

        words[6] = 3_000;

        words[7] = _word(
            1,
            0,
            0
        );

        words[8] = CohortWeeks.packGapRecord(
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

    function test_applyFlush_futureWeekRevert_selfHealsAfterBoundary()
        public
    {
        bytes memory payload = _crumbPayload(
            refB,
            block.timestamp,
            refB,
            0,
            0,
            block.timestamp / WEEK + 1,
            _word(5, 0, 0)
        );

        bytes32 messageId = bytes32(
            uint256(0x41)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        vm.expectRevert(
            ReferralHubDeclarations.FutureWeek.selector
        );

        hub.applyFlush(
            messageId,
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
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(hub.claimable(CHAIN_BASE, refB), 0);
    }

    // ---- happy path application ----

    function test_applyFlush_richEnvelope_appliesScoresCrumbsGapAndDesignation()
        public
    {
        uint256 crumbWeek = _establishAtCapAndWarp(
            refA
        );

        hub.setPayoutVault(
            address(payoutVaultMock)
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
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(hub.globalReferredScore(refA), AT_CAP_REFERRED + 1_000 * 1e6);
        assertEq(hub.globalSelfScore(refA), AT_CAP_SELF + 500 * 1e6);
        assertEq(hub.appliedScoreStamp(source, refA), stamp);
        assertEq(hub.claimable(CHAIN_BASE, refA), expectedPaid);
        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), designated);
        assertEq(hub.payoutStamp(CHAIN_BASE, refA), (setAt << 8) | 2);
        assertEq(hub.totalAccrued(), expectedPaid);
        assertEq(hub.totalBooked(), expectedPaid);
        assertEq(payoutVaultMock.lastRaisedAmount(), expectedPaid);
        assertEq(payoutVaultMock.raiseCallCount(), 1);

        hub.bookLiability();

        assertEq(payoutVaultMock.raiseCallCount(), 1);
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
            CHAIN_BASE,
            spokeVault,
            payload
        );

        bytes32 source = _remoteSourceOf(
            CHAIN_BASE,
            spokeVault
        );

        uint256 claimableAfterFirst = hub.claimable(CHAIN_BASE, refA);

        uint256 referredAfterFirst = hub.globalReferredScore(refA);

        uint256 accruedAfterFirst = hub.totalAccrued();

        uint256 payoutStampAfterFirst = hub.payoutStamp(CHAIN_BASE, refA);

        vm.recordLogs();

        hub.applyFlush(
            messageId,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(hub.claimable(CHAIN_BASE, refA), claimableAfterFirst);
        assertEq(hub.globalReferredScore(refA), referredAfterFirst);
        assertEq(hub.totalAccrued(), accruedAfterFirst);
        assertEq(hub.payoutStamp(CHAIN_BASE, refA), payoutStampAfterFirst);
        assertEq(hub.appliedScoreStamp(source, refA), stamp);
    }

    function test_applyFlush_staleScoreStamp_skipsScoresStillPricesCrumbs()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        uint256 freshStamp = block.timestamp;

        uint256 staleStamp = freshStamp - 100;

        bytes memory freshPayload = _scoresPayload(
            refA,
            freshStamp,
            refA,
            6_000 * 1e6,
            0
        );

        bytes memory stalePayload = _crumbPayload(
            refA,
            staleStamp,
            refA,
            9_000 * 1e6,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
        );

        _receiveFlushAs(
            bytes32(uint256(0x61)),
            freshPayload
        );

        _receiveFlushAs(
            bytes32(uint256(0x62)),
            stalePayload
        );

        hub.applyFlush(
            bytes32(uint256(0x61)),
            CHAIN_BASE,
            spokeVault,
            freshPayload
        );

        hub.applyFlush(
            bytes32(uint256(0x62)),
            CHAIN_BASE,
            spokeVault,
            stalePayload
        );

        bytes32 source = _remoteSourceOf(
            CHAIN_BASE,
            spokeVault
        );

        assertEq(hub.globalReferredScore(refA), HIGH_SCORE + 6_000 * 1e6);
        assertEq(hub.appliedScoreStamp(source, refA), freshStamp);
        assertEq(hub.claimable(CHAIN_BASE, refA), TIER6_PAID);
    }

    function test_applyFlush_equalScoreStamp_reappliesScores()
        public
    {
        uint256 stamp = block.timestamp;

        bytes memory firstPayload = _scoresPayload(
            refA,
            stamp,
            refA,
            6_000 * 1e6,
            0
        );

        bytes memory secondPayload = _scoresPayload(
            refA,
            stamp,
            refA,
            7_000 * 1e6,
            0
        );

        _receiveFlushAs(
            bytes32(uint256(0x63)),
            firstPayload
        );

        _receiveFlushAs(
            bytes32(uint256(0x64)),
            secondPayload
        );

        hub.applyFlush(
            bytes32(uint256(0x63)),
            CHAIN_BASE,
            spokeVault,
            firstPayload
        );

        hub.applyFlush(
            bytes32(uint256(0x64)),
            CHAIN_BASE,
            spokeVault,
            secondPayload
        );

        assertEq(hub.globalReferredScore(refA), 7_000 * 1e6);
    }

    // ---- bot share ----

    function test_applyFlush_remoteDeliverer_splitsBotShare()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
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
            expectedShare
        );

        hub.applyFlush(
            messageId,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(hub.claimable(CHAIN_BASE, courier), expectedShare);
        assertEq(hub.claimable(CHAIN_BASE, refA), TIER6_PAID - expectedShare);
        assertEq(hub.totalAccrued(), TIER6_PAID);
    }

    function test_applyFlush_delivererIsReferrer_paysReferrerFully()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        bytes memory payload = _crumbPayload(
            refA,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
        );

        bytes32 messageId = bytes32(
            uint256(0x72)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(hub.claimable(CHAIN_BASE, refA), TIER6_PAID);
        assertEq(hub.totalAccrued(), TIER6_PAID);
    }

    function test_applyFlush_botShareZero_noSplit()
        public
    {
        hub.setBotShareBps(
            0
        );

        uint256 week = _establishTier6(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
        );

        bytes32 messageId = bytes32(
            uint256(0x73)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(hub.claimable(CHAIN_BASE, refA), TIER6_PAID);
        assertEq(hub.claimable(CHAIN_BASE, courier), 0);
    }

    function test_applyFlush_botShareFull_paysDelivererFully()
        public
    {
        hub.setBotShareBps(
            10_000
        );

        uint256 week = _establishTier6(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
        );

        bytes32 messageId = bytes32(
            uint256(0x74)
        );

        _receiveFlushAs(
            messageId,
            payload
        );

        hub.applyFlush(
            messageId,
            CHAIN_BASE,
            spokeVault,
            payload
        );

        assertEq(hub.claimable(CHAIN_BASE, courier), TIER6_PAID);
        assertEq(hub.claimable(CHAIN_BASE, refA), 0);
        assertEq(hub.totalAccrued(), TIER6_PAID);
    }

    function test_deliverCrumbs_localDelivery_neverSplits()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        uint256[] memory weeks_ = new uint256[](1);

        uint256[] memory words_ = new uint256[](1);

        weeks_[0] = week;
        words_[0] = _word(TIER6_QUANTITY, 0, 0);

        hub.deliverCrumbs(
            refA,
            weeks_,
            words_
        );

        assertEq(hub.claimable(block.chainid, refA), TIER6_PAID);
        assertEq(hub.claimable(block.chainid, address(this)), 0);
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

        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), designated);
        assertEq(hub.payoutStamp(CHAIN_BASE, refA), setAt << 8);
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

        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), designated);
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

        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), refA);
    }

    function test_designationPush_farFutureSetAt_skipsBoundaryApplies()
        public
    {
        uint256 tooFar = block.timestamp + 1 hours + 1;

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

        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), refA);

        _pushDesignation(
            refA,
            designated,
            block.timestamp + 1 hours,
            0
        );

        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), designated);
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

        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), refA);
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
                    uint256(2),
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

    function test_designation_localAndRemoteBucketsIndependent_claimPaysRemoteDesignation()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        bytes memory payload = _crumbPayload(
            refA,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
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

        assertEq(hub.payoutAddressOf(block.chainid, refA), address(0xF3));
        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), designated);

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

        assertEq(usd.balanceOf(designated), TIER6_PAID);
        assertEq(hub.claimable(CHAIN_BASE, refA), 0);
    }

    // ---- cross-source isolation ----

    function test_applyFlush_sameVaultTwoChains_sourcesIsolated()
        public
    {
        hub.setFlushSource(
            SEL_ARB,
            spokeVault,
            CHAIN_ARB
        );

        uint256 week = _establishTier6(
            refA
        );

        uint256 stamp = block.timestamp;

        bytes memory payload = _crumbPayload(
            refA,
            stamp,
            refA,
            6_000 * 1e6,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
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
            CHAIN_BASE,
            spokeVault,
            payload
        );

        hub.applyFlush(
            bytes32(uint256(0xA2)),
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

        assertEq(hub.claimable(CHAIN_BASE, refA), TIER6_PAID);
        assertEq(hub.claimable(CHAIN_ARB, refA), TIER6_PAID);
        assertEq(hub.appliedScoreStamp(baseSource, refA), stamp);
        assertEq(hub.appliedScoreStamp(arbSource, refA), stamp);
        assertEq(hub.globalReferredScore(refA), HIGH_SCORE + 12_000 * 1e6);
    }

    // ---- log-only reconstruction ----

    function test_applyFlush_reconstructedFromLogsOnly_appliesAndMatchesCommitment()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        bytes memory payload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
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

        (
            uint256 loggedChainId,
            bytes memory loggedPayload
        ) = abi.decode(
            logged.data,
            (uint256, bytes)
        );

        assertEq(loggedId, bytes32(uint256(0xC1)));
        assertEq(loggedVault, spokeVault);
        assertEq(loggedChainId, CHAIN_BASE);
        assertEq(loggedPayload, payload);

        assertEq(
            hub.flushCommitment(loggedId),
            keccak256(
                abi.encode(
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
            loggedChainId,
            loggedVault,
            loggedPayload
        );

        uint256 expectedShare = TIER6_PAID * GENESIS_BOT_SHARE_BPS / 10_000;

        assertEq(hub.claimable(CHAIN_BASE, refA), TIER6_PAID - expectedShare);
        assertEq(hub.claimable(CHAIN_BASE, courier), expectedShare);
    }

    function test_RevertWhen_applyFlush_logJoinWrongSourceChainId()
        public
    {
        hub.setFlushSource(
            SEL_ARB,
            spokeVault,
            CHAIN_ARB
        );

        bytes memory payload = _scoresPayload(
            refA,
            block.timestamp,
            refA,
            6_000 * 1e6,
            0
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
            CHAIN_ARB,
            loggedVault,
            loggedPayload
        );
    }

    // ---- courier redelivery race ----

    function test_applyFlush_secondCourierSameWindow_pricesZeroNoShare()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        bytes memory firstPayload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
        );

        bytes memory secondPayload = _crumbPayload(
            courier2,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
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
            CHAIN_BASE,
            spokeVault,
            firstPayload
        );

        uint256 referrerAfterFirst = hub.claimable(CHAIN_BASE, refA);

        uint256 courierAfterFirst = hub.claimable(CHAIN_BASE, courier);

        uint256 accruedAfterFirst = hub.totalAccrued();

        vm.recordLogs();

        hub.applyFlush(
            bytes32(uint256(0xC4)),
            CHAIN_BASE,
            spokeVault,
            secondPayload
        );

        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(hub.claimable(CHAIN_BASE, refA), referrerAfterFirst);
        assertEq(hub.claimable(CHAIN_BASE, courier), courierAfterFirst);
        assertEq(hub.claimable(CHAIN_BASE, courier2), 0);
        assertEq(hub.totalAccrued(), accruedAfterFirst);
    }

    function test_applyFlush_secondCourierGrownWord_shareOnIncrementOnly()
        public
    {
        uint256 week = _establishTier6(
            refA
        );

        bytes memory firstPayload = _crumbPayload(
            courier,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(TIER6_QUANTITY, 0, 0)
        );

        bytes memory secondPayload = _crumbPayload(
            courier2,
            block.timestamp,
            refA,
            0,
            0,
            week,
            _word(2 * TIER6_QUANTITY, 0, 0)
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
            expectedShare
        );

        hub.applyFlush(
            bytes32(uint256(0xC6)),
            CHAIN_BASE,
            spokeVault,
            secondPayload
        );

        assertEq(hub.claimable(CHAIN_BASE, courier), expectedShare);
        assertEq(hub.claimable(CHAIN_BASE, courier2), expectedShare);
        assertEq(hub.claimable(CHAIN_BASE, refA), 2 * (TIER6_PAID - expectedShare));
        assertEq(hub.totalAccrued(), 2 * TIER6_PAID);
    }

    function test_applyFlush_workExactlyMax_applies()
        public
    {
        uint256[] memory words = new uint256[](7);

        words[0] = CohortWeeks.packFlushHeader(
            refA,
            2,
            block.timestamp
        );

        words[1] = CohortWeeks.packFlushEntry(
            refA,
            0,
            1,
            0
        );

        words[2] = CohortWeeks.packFlushScores(
            0,
            0
        );

        words[3] = CohortWeeks.packGapRecord(
            2_800,
            2_904,
            0
        );

        words[4] = CohortWeeks.packFlushEntry(
            refB,
            0,
            1,
            0
        );

        words[5] = CohortWeeks.packFlushScores(
            0,
            0
        );

        words[6] = CohortWeeks.packGapRecord(
            2_600,
            2_704,
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
            CHAIN_BASE,
            spokeVault,
            payload
        );
    }

    // ---- courier buckets across source chains ----

    function test_courierBuckets_twoSourceChains_accumulateIndependently()
        public
    {
        uint256 share = _accrueCourierShareTwoChains();

        assertEq(hub.claimable(CHAIN_BASE, courier), share);
        assertEq(hub.claimable(CHAIN_ARB, courier), share);
        assertEq(hub.claimable(block.chainid, courier), 0);
        assertEq(hub.claimable(CHAIN_BASE, refA), TIER6_PAID - share);
        assertEq(hub.claimable(CHAIN_ARB, refA), TIER6_PAID - share);
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

        assertEq(usd.balanceOf(courier), share / 2);
        assertEq(hub.claimable(CHAIN_BASE, courier), share - share / 2);
        assertEq(hub.claimable(CHAIN_ARB, courier), share);

        vm.prank(
            courier
        );

        hub.claim(
            CHAIN_ARB,
            courier
        );

        assertEq(usd.balanceOf(courier), share / 2 + share);
        assertEq(hub.claimable(CHAIN_BASE, courier), share - share / 2);
        assertEq(hub.claimable(CHAIN_ARB, courier), 0);
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

        assertEq(hub.payoutAddressOf(CHAIN_BASE, courier), address(0xF4));
        assertEq(hub.payoutAddressOf(CHAIN_BASE, refA), designated);

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

        assertEq(usd.balanceOf(address(0xF4)), share);
        assertEq(usd.balanceOf(courier), 0);
        assertEq(hub.claimable(CHAIN_BASE, courier), 0);
        assertEq(hub.claimable(CHAIN_BASE, refA), TIER6_PAID - share);
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
}
