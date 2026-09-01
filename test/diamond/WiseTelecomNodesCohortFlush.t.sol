// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesDiamondErrors} from "../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortFlushFacet} from "../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";

import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";
import {OnlyDelegateCall, FacetNotFound} from "../../src/diamond/shared/DiamondErrors.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

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
 * @dev Records outbound CCIP sends without relaying them: `getFee`
 * returns a flat fee, `ccipSend` demands exactly that fee (the flush
 * facet forwards `{value: fee}`), stores the raw message fields for
 * envelope decoding by the test, and derives a deterministic
 * messageId so `CohortFlushSent` can be asserted with `expectEmit`.
 */
contract MockFlushCcipRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    uint256 public sendCount;

    uint64 public lastSelector;

    bytes public lastReceiver;

    bytes public lastData;

    bytes public lastExtraArgs;

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    )
        external
        pure
        returns (uint256)
    {
        return FIXED_FEE;
    }

    function ccipSend(
        uint64 _destChainSelector,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32 messageId)
    {
        require(
            msg.value == FIXED_FEE,
            "WRONG_FEE"
        );

        lastSelector = _destChainSelector;
        lastReceiver = _message.receiver;
        lastData = _message.data;
        lastExtraArgs = _message.extraArgs;

        messageId = keccak256(
            abi.encode(
                msg.sender,
                _destChainSelector,
                sendCount
            )
        );

        sendCount++;
    }
}

/**
 * @dev Records outbound CCIP sends with a payload-size-dependent
 * fee: `getFee` grows linearly with the message data length and
 * `ccipSend` demands exactly that fee, so the suite can prove that
 * `quoteFlushFee` — which plans on unsettled storage — is a strict
 * lower bound once execution settles and grows the envelope, and
 * that a window send over a subset slice never costs more than the
 * cursor-planned quote.
 */
contract SizeFeeCcipRouter {

    uint256 public constant BASE_FEE = 0.001 ether;

    uint256 public constant FEE_PER_BYTE = 1e12;

    uint256 public lastFee;

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory _message
    )
        external
        pure
        returns (uint256)
    {
        return BASE_FEE + _message.data.length * FEE_PER_BYTE;
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32)
    {
        require(
            msg.value == BASE_FEE + _message.data.length * FEE_PER_BYTE,
            "WRONG_FEE"
        );

        lastFee = msg.value;

        return bytes32(
            msg.value
        );
    }
}

/**
 * @dev Reverts on every call, used as etched code on the registry
 * address to prove the designation piggyback degrades silently.
 */
contract RevertingDesignationMock {

    fallback()
        external
    {
        revert();
    }
}

/**
 * @dev Returns a first word wider than an address, used as etched
 * code on the registry address to prove the guarded designation read
 * rejects dirty payout words.
 */
contract WideAddressDesignationMock {

    function getPayoutDesignation(
        address
    )
        external
        pure
        returns (
            uint256,
            uint256
        )
    {
        return (
            uint256(1) << 160,
            1
        );
    }
}

/**
 * @dev Returns a stamp whose timestamp half exceeds uint64, used as
 * etched code on the registry address to prove the guarded
 * designation read rejects out-of-range stamps.
 */
contract HugeStampDesignationMock {

    function getPayoutDesignation(
        address
    )
        external
        pure
        returns (
            uint256,
            uint256
        )
    {
        return (
            uint256(uint160(address(0xEE))),
            uint256(1) << 80
        );
    }
}

/**
 * @dev Calls `flushReferrals` on its own book with excess value and
 * rejects the native refund, exercising the `FlushRefundFailed`
 * revert path.
 */
contract FlushRefundRejector {

    function run(
        address _diamond
    )
        external
        payable
    {
        address[] memory refs = new address[](1);

        refs[0] = address(this);

        CohortFlushFacet(_diamond).flushReferrals{value: msg.value}(
            refs
        );
    }

    receive()
        external
        payable
    {
        revert();
    }
}

/**
 * @dev Vault-side flush transport suite: the flush-hub pointer's
 * propose/execute/cancel timelock (instant pre-finalize, 3-day
 * afterwards, zero-hub-nonzero-selector shape rejected at execute),
 * the flush policy levers (bot whitelist, public switch, CCIP gas
 * budget), the default-off guarantee while the pointer is unset, and
 * both delivery modes of {CohortFlushFacet}: LOCAL direct-call
 * delivery end-to-end against a REAL {ReferralHub} with every
 * expected claimable computed independently from recorder words and
 * `weeklyRates`, and REMOTE CCIP delivery asserted by decoding the
 * exact packed flush envelope out of a recording mock router —
 * header, entry, scores, designation, crumb pairs and pre-sliced gap
 * records word by word. Cursor behavior (catch-up window start,
 * ~104-week advance per flush, gap-record slicing across flushes,
 * work-budget degradation to scores-only entries) is pinned against
 * real recorder histories, never hand-built words. The window
 * entrypoint is additionally exercised in CCIP mode (payable fee and
 * exact-excess refund, envelope restricted to the requested slice
 * with the caller stamped as deliverer, the shared foreign-book
 * gate), and a size-dependent fee mock pins `quoteFlushFee` as a
 * strict lower bound when storage settles and grows between quote
 * and execution — the courier's mandatory over-funding margin.
 */
contract WiseTelecomNodesCohortFlushTest is DiamondTestHarness {

    event FlushHubSet(
        address flushHub,
        uint64 flushHubChainSelector
    );

    event FlushHubProposed(
        address indexed proposedFlushHub,
        uint64 proposedFlushHubChainSelector,
        uint256 executableAt
    );

    event FlushHubProposalCancelled(
        address indexed cancelledFlushHub
    );

    event FlushBotAllowedSet(
        address indexed bot,
        bool allowed
    );

    event PublicFlushEnabledSet(
        bool enabled
    );

    event FlushGasLimitSet(
        uint64 flushGasLimit
    );

    event CohortFlushSent(
        bytes32 indexed messageId,
        uint64 indexed destChainSelector,
        address indexed deliverer,
        uint256 entryCount
    );

    event CohortFlushDelivered(
        address indexed flushHub,
        address indexed deliverer,
        uint256 entryCount
    );

    event CohortReferrerFlushed(
        address indexed referrer,
        uint256 flushedThroughWeek,
        uint256 flushedGapIndex,
        uint256 gapResumeWeek
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant FLUSH_HUB_DELAY = 3 days;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint64 internal constant REMOTE_SELECTOR = 4242;

    uint256 internal constant FIXED_FEE = 0.01 ether;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal user3 = address(0xA3);
    address internal user4 = address(0xA4);
    address internal refA = address(0xB1);
    address internal bigR = address(0xB5);
    address internal smallR = address(0xB6);
    address internal refD = address(0xB7);
    address internal refE = address(0xB8);
    address internal stranger = address(0xC1);
    address internal bot = address(0xD1);

    MockUSD internal usd;
    ReferralHub internal hub;
    MockFlushCcipRouter internal router;

    WiseTelecomNodesDiamond internal diamond;
    WiseTelecomNodesDiamond internal rdiamond;

    ReferralRegistry internal localRegistry;
    ReferralRegistry internal remoteRegistry;

    receive()
        external
        payable
    {}

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        hub = new ReferralHub(
            address(usd)
        );

        router = new MockFlushCcipRouter();

        (
            diamond,
            localRegistry
        ) = _buildFlushDiamond(
            0,
            false
        );

        (
            rdiamond,
            remoteRegistry
        ) = _buildFlushDiamond(
            REMOTE_SELECTOR,
            true
        );

        hub.setAllowedReporter(
            address(diamond),
            true
        );

        vm.deal(
            address(this),
            100 ether
        );
    }

    // ---- helpers ----

    function _buildFlushDiamond(
        uint64 _selector,
        bool _withRouter
    )
        internal
        returns (
            WiseTelecomNodesDiamond d,
            ReferralRegistry reg
        )
    {
        d = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        reg = _wireReferralRegistry(
            d
        );

        _wireOne(
            d,
            address(new CohortFlushFacet()),
            WiseTelecomNodesDiamondSelectors.cohortFlushSelectors()
        );

        if (_withRouter) {

            _wireOne(
                d,
                address(new BridgeFacet()),
                WiseTelecomNodesDiamondSelectors.bridgeSelectors()
            );

            BridgeFacet(address(d)).setCcipRouter(
                address(router)
            );
        }

        AdminFacet(address(d)).proposeFlushHub(
            address(hub),
            _selector
        );

        AdminFacet(address(d)).executeFlushHubChange();

        d.finalizeSetup();

        AdminFacet(address(d)).setCohortSyncEnabled(
            true
        );
    }

    function _flush(
        WiseTelecomNodesDiamond _d
    )
        internal
        pure
        returns (CohortFlushFacet)
    {
        return CohortFlushFacet(
            address(_d)
        );
    }

    function _admin(
        WiseTelecomNodesDiamond _d
    )
        internal
        pure
        returns (AdminFacet)
    {
        return AdminFacet(
            address(_d)
        );
    }

    function _rec(
        WiseTelecomNodesDiamond _d
    )
        internal
        pure
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(_d)
        );
    }

    function _depositWithReferralOn(
        WiseTelecomNodesDiamond _d,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(_d),
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(_d)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _depositOn(
        WiseTelecomNodesDiamond _d,
        address _user,
        uint256 _amount
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(_d),
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(_d)).deposit(
            _amount
        );
    }

    function _oneRef(
        address _referrer
    )
        internal
        pure
        returns (address[] memory refs)
    {
        refs = new address[](1);

        refs[0] = _referrer;
    }

    function _flushOwnLocal(
        address _referrer
    )
        internal
    {
        address[] memory refs = _oneRef(
            _referrer
        );

        vm.prank(
            _referrer
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function _flushOwnRemote(
        address _referrer
    )
        internal
    {
        address[] memory refs = _oneRef(
            _referrer
        );

        vm.deal(
            _referrer,
            _referrer.balance + FIXED_FEE
        );

        vm.prank(
            _referrer
        );

        _flush(rdiamond).flushReferrals{value: FIXED_FEE}(
            refs
        );
    }

    function _flushBotRemote(
        address[] memory _refs
    )
        internal
    {
        _flush(rdiamond).flushReferrals{value: FIXED_FEE}(
            _refs
        );
    }

    function _expectedPay(
        uint256 _word,
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

        return CohortWeeks.laneY1(_word) * y1Bps / 10_000 / CohortWeeks.YEAR
            + CohortWeeks.laneY2(_word) * y2Bps / 10_000 / CohortWeeks.YEAR
            + CohortWeeks.laneM(_word) * mBps / 10_000 / CohortWeeks.YEAR;
    }

    function _expectedGapPay(
        uint256 _mature,
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        return _expectedPay(
            CohortWeeks.packLanes(
                0,
                0,
                _mature * CohortWeeks.WEEK
            ),
            _referrer,
            _week
        );
    }

    function _expectedCrumbRangePay(
        WiseTelecomNodesDiamond _d,
        address _referrer,
        uint256 _fromWeek,
        uint256 _toWeekInclusive
    )
        internal
        view
        returns (uint256 expected)
    {
        for (uint256 week = _fromWeek; week <= _toWeekInclusive; ++week) {

            expected += _expectedPay(
                _rec(_d).getCohortWeekCrumb(
                    _referrer,
                    week
                ),
                _referrer,
                week
            );
        }
    }

    function _expectedGapRangePay(
        uint256 _mature,
        address _referrer,
        uint256 _fromWeek,
        uint256 _toWeekExclusive
    )
        internal
        view
        returns (uint256 expected)
    {
        for (uint256 week = _fromWeek; week < _toWeekExclusive; ++week) {

            expected += _expectedGapPay(
                _mature,
                _referrer,
                week
            );
        }
    }

    function _envWord(
        bytes memory _data,
        uint256 _index
    )
        internal
        pure
        returns (uint256 w)
    {
        assembly {
            w := mload(
                add(
                    _data,
                    add(
                        0x20,
                        mul(
                            _index,
                            0x20
                        )
                    )
                )
            )
        }
    }

    function _countReferrerFlushedLogs()
        internal
        view
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "CohortReferrerFlushed(address,uint256,uint256,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    function _newBareFlushDiamond(
        uint64 _selector
    )
        internal
        returns (WiseTelecomNodesDiamond d)
    {
        d = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new CohortFlushFacet()),
            WiseTelecomNodesDiamondSelectors.cohortFlushSelectors()
        );

        AdminFacet(address(d)).proposeFlushHub(
            address(hub),
            _selector
        );

        AdminFacet(address(d)).executeFlushHubChange();

        d.finalizeSetup();
    }

    function _buildSizeFeeDiamond()
        internal
        returns (
            WiseTelecomNodesDiamond d,
            SizeFeeCcipRouter sizeRouter
        )
    {
        sizeRouter = new SizeFeeCcipRouter();

        d = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            d
        );

        _wireOne(
            d,
            address(new CohortFlushFacet()),
            WiseTelecomNodesDiamondSelectors.cohortFlushSelectors()
        );

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        BridgeFacet(address(d)).setCcipRouter(
            address(sizeRouter)
        );

        AdminFacet(address(d)).proposeFlushHub(
            address(hub),
            REMOTE_SELECTOR
        );

        AdminFacet(address(d)).executeFlushHubChange();

        d.finalizeSetup();

        AdminFacet(address(d)).setCohortSyncEnabled(
            true
        );
    }

    // ---- pointer lifecycle ----

    function test_flushHubPointer_wiredInstantlyPreFinalize()
        public
        view
    {
        (
            address localHub,
            uint64 localSelector
        ) = _admin(diamond).getFlushHub();

        assertEq(
            localHub,
            address(hub)
        );

        assertEq(
            localSelector,
            0
        );

        (
            address remoteHub,
            uint64 remoteSelector
        ) = _admin(rdiamond).getFlushHub();

        assertEq(
            remoteHub,
            address(hub)
        );

        assertEq(
            remoteSelector,
            REMOTE_SELECTOR
        );

        (
            address proposedHub,
            uint64 proposedSelector
        ) = _admin(diamond).getProposedFlushHub();

        assertEq(
            proposedHub,
            address(0)
        );

        assertEq(
            proposedSelector,
            0
        );

        assertEq(
            _admin(diamond).getFlushHubChangeQueuedAt(),
            0
        );
    }

    function test_flushHubPointer_lifecycleGettersAndCancel()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushHubProposed(
            address(0xF1),
            7,
            block.timestamp + FLUSH_HUB_DELAY
        );

        _admin(diamond).proposeFlushHub(
            address(0xF1),
            7
        );

        (
            address proposedHub,
            uint64 proposedSelector
        ) = _admin(diamond).getProposedFlushHub();

        assertEq(
            proposedHub,
            address(0xF1)
        );

        assertEq(
            proposedSelector,
            7
        );

        assertEq(
            _admin(diamond).getFlushHubChangeQueuedAt(),
            block.timestamp
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushHubProposalCancelled(
            address(0xF1)
        );

        _admin(diamond).cancelFlushHubChange();

        (
            proposedHub,
            proposedSelector
        ) = _admin(diamond).getProposedFlushHub();

        assertEq(
            proposedHub,
            address(0)
        );

        assertEq(
            proposedSelector,
            0
        );

        assertEq(
            _admin(diamond).getFlushHubChangeQueuedAt(),
            0
        );

        (
            address keptHub,
            uint64 keptSelector
        ) = _admin(diamond).getFlushHub();

        assertEq(
            keptHub,
            address(hub)
        );

        assertEq(
            keptSelector,
            0
        );
    }

    function test_flushHubPointer_timelockedExecuteAfterFinalize()
        public
    {
        _admin(diamond).proposeFlushHub(
            address(0xF1),
            9
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushHubTimelockNotElapsed.selector
        );

        _admin(diamond).executeFlushHubChange();

        vm.warp(
            block.timestamp + FLUSH_HUB_DELAY + 1
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushHubSet(
            address(0xF1),
            9
        );

        _admin(diamond).executeFlushHubChange();

        (
            address newHub,
            uint64 newSelector
        ) = _admin(diamond).getFlushHub();

        assertEq(
            newHub,
            address(0xF1)
        );

        assertEq(
            newSelector,
            9
        );
    }

    function test_RevertWhen_executeFlushHubChange_nothingProposed()
        public
    {
        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NoFlushHubChangeProposed.selector
        );

        _admin(diamond).executeFlushHubChange();
    }

    function test_RevertWhen_executeFlushHubChange_zeroHubNonzeroSelector()
        public
    {
        _admin(diamond).proposeFlushHub(
            address(0),
            7
        );

        vm.warp(
            block.timestamp + FLUSH_HUB_DELAY + 1
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        _admin(diamond).executeFlushHubChange();
    }

    function test_flushHubPointer_zeroProposal_detachesToOffState()
        public
    {
        _admin(diamond).proposeFlushHub(
            address(0),
            0
        );

        vm.warp(
            block.timestamp + FLUSH_HUB_DELAY + 1
        );

        _admin(diamond).executeFlushHubChange();

        (
            address detachedHub,
            uint64 detachedSelector
        ) = _admin(diamond).getFlushHub();

        assertEq(
            detachedHub,
            address(0)
        );

        assertEq(
            detachedSelector,
            0
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_RevertWhen_flushHubPointer_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin(diamond).proposeFlushHub(
            address(0xF1),
            0
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin(diamond).executeFlushHubChange();

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _admin(diamond).cancelFlushHubChange();
    }

    // ---- flush policy ----

    function test_setAllowedFlushBot_setsAndEmits()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushBotAllowedSet(
            bot,
            true
        );

        _flush(diamond).setAllowedFlushBot(
            bot,
            true
        );

        assertTrue(
            _flush(diamond).getAllowedFlushBot(
                bot
            )
        );

        _flush(diamond).setAllowedFlushBot(
            bot,
            false
        );

        assertFalse(
            _flush(diamond).getAllowedFlushBot(
                bot
            )
        );
    }

    function test_RevertWhen_setAllowedFlushBot_zeroBot()
        public
    {
        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        _flush(diamond).setAllowedFlushBot(
            address(0),
            true
        );
    }

    function test_setPublicFlushEnabled_setsAndEmits()
        public
    {
        assertFalse(
            _flush(diamond).getPublicFlushEnabled()
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit PublicFlushEnabledSet(
            true
        );

        _flush(diamond).setPublicFlushEnabled(
            true
        );

        assertTrue(
            _flush(diamond).getPublicFlushEnabled()
        );

        _flush(diamond).setPublicFlushEnabled(
            false
        );

        assertFalse(
            _flush(diamond).getPublicFlushEnabled()
        );
    }

    function test_setFlushGasLimit_boundsAndEmits()
        public
    {
        assertEq(
            _flush(diamond).getFlushGasLimit(),
            0
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(diamond)
        );

        emit FlushGasLimitSet(
            300_000
        );

        _flush(diamond).setFlushGasLimit(
            300_000
        );

        assertEq(
            _flush(diamond).getFlushGasLimit(),
            300_000
        );

        _flush(diamond).setFlushGasLimit(
            2_000_000
        );

        assertEq(
            _flush(diamond).getFlushGasLimit(),
            2_000_000
        );
    }

    function test_RevertWhen_setFlushGasLimit_outOfBounds()
        public
    {
        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidFlushGasLimit.selector
        );

        _flush(diamond).setFlushGasLimit(
            299_999
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidFlushGasLimit.selector
        );

        _flush(diamond).setFlushGasLimit(
            2_000_001
        );
    }

    function test_RevertWhen_flushPolicy_calledByStranger()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _flush(diamond).setAllowedFlushBot(
            bot,
            true
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _flush(diamond).setPublicFlushEnabled(
            true
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        _flush(diamond).setFlushGasLimit(
            300_000
        );
    }

    // ---- default-off ----

    function test_RevertWhen_flushHubUnset_allEntrypoints()
        public
    {
        WiseTelecomNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        _wireOne(
            bare,
            address(new CohortFlushFacet()),
            WiseTelecomNodesDiamondSelectors.cohortFlushSelectors()
        );

        bare.finalizeSetup();

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(bare).flushReferrals(
            refs
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(bare).flushReferralWindow(
            refA,
            0,
            0
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushHubNotSet.selector
        );

        _flush(bare).quoteFlushFee(
            refs
        );
    }

    // ---- gating ----

    function test_RevertWhen_flushReferrals_emptyBatch()
        public
    {
        address[] memory refs = new address[](0);

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NothingToFlush.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NothingToFlush.selector
        );

        _flush(diamond).quoteFlushFee(
            refs
        );
    }

    function test_RevertWhen_flushReferrals_batchTooLarge()
        public
    {
        address[] memory refs = new address[](17);

        for (uint256 i; i < 17; ++i) {
            refs[i] = address(
                uint160(0x1000 + i)
            );
        }

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushBatchTooLarge.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushBatchTooLarge.selector
        );

        _flush(diamond).quoteFlushFee(
            refs
        );
    }

    function test_RevertWhen_flushReferrals_zeroReferrer()
        public
    {
        address[] memory refs = _oneRef(
            address(0)
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InvalidValue.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_RevertWhen_flushReferrals_strangerFlushesForeignBook()
        public
    {
        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotFlushBot.selector
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferrals_allowedBotPasses()
        public
    {
        _flush(diamond).setAllowedFlushBot(
            bot,
            true
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            bot,
            1
        );

        vm.prank(
            bot
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferrals_publicFlushPasses()
        public
    {
        _flush(diamond).setPublicFlushEnabled(
            true
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            stranger,
            1
        );

        vm.prank(
            stranger
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_flushReferrals_ownBookAlwaysPasses()
        public
    {
        address[] memory refs = _oneRef(
            stranger
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            stranger,
            1
        );

        vm.prank(
            stranger
        );

        _flush(diamond).flushReferrals(
            refs
        );
    }

    function test_RevertWhen_flush_paused()
        public
    {
        _admin(diamond).pauseDeposits();

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        _flush(diamond).flushReferrals(
            refs
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            bytes("Pausable: paused")
        );

        _flush(diamond).flushReferralWindow(
            refA,
            0,
            0
        );
    }

    // ---- settle entrypoint guards ----

    function test_RevertWhen_applyCohortSettle_directFacetCall()
        public
    {
        CohortHookFacet facet = new CohortHookFacet();

        vm.expectRevert(
            OnlyDelegateCall.selector
        );

        facet.applyCohortSettle(
            refA
        );
    }

    function test_applyCohortSettle_unroutedThenRoutedStaysGuarded()
        public
    {
        (
            bool ok,
            bytes memory ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                CohortHookFacet.applyCohortSettle.selector,
                refA
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector
        );

        diamond.proposeSelector(
            CohortHookFacet.applyCohortSettle.selector,
            address(new CohortHookFacet())
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        diamond.executeSelectorChange(
            CohortHookFacet.applyCohortSettle.selector
        );

        (
            ok,
            ret
        ) = address(diamond).call(
            abi.encodeWithSelector(
                CohortHookFacet.applyCohortSettle.selector,
                refA
            )
        );

        assertFalse(
            ok
        );

        assertEq(
            bytes4(ret),
            WiseTelecomNodesDiamondErrors.NotHookExecution.selector
        );
    }

    // ---- local delivery end-to-end ----

    function test_localFlush_endToEnd_exactPricingAndCursors()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            12_000 * 1e6
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            0
        );

        assertEq(
            hub.globalReferredScore(refA),
            10_000 * 1e6
        );

        assertEq(
            hub.globalSelfScore(refA),
            _rec(diamond).getTrackedContribution(
                refA
            )
        );

        assertEq(
            _rec(diamond).getTrackedContribution(
                refA
            ),
            12_000 * 1e6
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            2_999
        );

        vm.warp(
            BASE_TIME + 4 weeks + 12 hours
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortReferrerFlushed(
            refA,
            3_003,
            0,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            refA,
            1
        );

        _flushOwnLocal(
            refA
        );

        uint256 expected = _expectedCrumbRangePay(
            diamond,
            refA,
            3_000,
            3_004
        );

        assertGt(
            expected,
            0
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            expected
        );

        (
            uint256 y1Cursor,
            ,

        ) = hub.paidCursorAt(
            address(diamond),
            refA,
            3_004
        );

        assertEq(
            y1Cursor,
            10_000 * 1e6 * (block.timestamp - 3_004 weeks)
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            3_003
        );
    }

    function test_localFlush_sameWeekReflush_paysOnlyIncrement()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 4 weeks + 12 hours
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableBase = hub.claimable(
            block.chainid,
            refA
        );

        uint256 wordBase = _rec(diamond).getCohortWeekCrumb(
            refA,
            3_004
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableBase
        );

        vm.warp(
            block.timestamp + 5 hours
        );

        _flushOwnLocal(
            refA
        );

        uint256 wordGrown = _rec(diamond).getCohortWeekCrumb(
            refA,
            3_004
        );

        (
            uint256 y1Bps,
            ,

        ) = hub.weeklyRates(
            refA,
            3_004
        );

        uint256 expectedIncrement = (
            CohortWeeks.laneY1(wordGrown) - CohortWeeks.laneY1(wordBase)
        ) * y1Bps / 10_000 / CohortWeeks.YEAR;

        assertGt(
            expectedIncrement,
            0
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableBase + expectedIncrement
        );
    }

    function test_localFlush_disarmedRecorder_deliversFrozenBook()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableArmed = hub.claimable(
            block.chainid,
            refA
        );

        uint256 scoreArmed = hub.globalReferredScore(
            refA
        );

        _admin(diamond).setCohortSyncEnabled(
            false
        );

        vm.warp(
            BASE_TIME + 5 weeks
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableArmed
        );

        assertEq(
            hub.globalReferredScore(refA),
            scoreArmed
        );

        assertEq(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_004
            ),
            0
        );

        assertEq(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_005
            ),
            0
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            3_004
        );

        vm.warp(
            BASE_TIME + 6 weeks
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableArmed
        );
    }

    function test_localFlush_neverCreditedReferrer_scoresOnlyCursorPin()
        public
    {
        address virgin = address(0xE1);

        address[] memory refs = _oneRef(
            virgin
        );

        vm.recordLogs();

        vm.prank(
            virgin
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _countReferrerFlushedLogs(),
            1
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                virgin
            ),
            2_999
        );

        (
            uint256 referredScore,
            uint256 selfScore
        ) = hub.lastReportOf(
            address(diamond),
            virgin
        );

        assertEq(
            referredScore,
            0
        );

        assertEq(
            selfScore,
            0
        );

        assertEq(
            hub.claimable(block.chainid, virgin),
            0
        );

        vm.recordLogs();

        vm.prank(
            virgin
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                virgin
            ),
            2_999
        );
    }

    function test_localFlush_zeroRegistryDiamond_succeeds()
        public
    {
        WiseTelecomNodesDiamond bare = _newBareFlushDiamond(
            0
        );

        hub.setAllowedReporter(
            address(bare),
            true
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(bare)
        );

        emit CohortFlushDelivered(
            address(hub),
            refA,
            1
        );

        vm.prank(
            refA
        );

        _flush(bare).flushReferrals(
            refs
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            0
        );
    }

    function test_localFlush_designationNeverDelivered()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.prank(
            refA
        );

        localRegistry.setPayoutAddress(
            address(0xF2)
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 3 weeks
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.payoutAddressOf(
                block.chainid,
                refA
            ),
            refA
        );

        assertEq(
            hub.payoutStamp(
                block.chainid,
                refA
            ),
            0
        );
    }

    function test_localFlush_windowReflush_idempotentKeepsCursorMax()
        public
    {
        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            BASE_TIME + 4 weeks
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableBefore = hub.claimable(
            block.chainid,
            refA
        );

        assertGt(
            claimableBefore,
            0
        );

        vm.prank(
            refA
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableBefore
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            3_003
        );
    }

    function test_RevertWhen_flushWindow_futureFromWeek()
        public
    {
        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushWindowInvalid.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            currentWeek + 1,
            0
        );
    }

    function test_RevertWhen_flushWindow_gapIndexBeyondLog()
        public
    {
        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushWindowInvalid.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            1
        );
    }

    function test_flushWindow_virginReferrer_scoresOnly()
        public
    {
        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortFlushDelivered(
            address(hub),
            stranger,
            1
        );

        vm.prank(
            stranger
        );

        _flush(diamond).flushReferralWindow(
            stranger,
            3_000,
            0
        );

        assertEq(
            hub.claimable(block.chainid, stranger),
            0
        );
    }

    function test_localFlush_earlyChain_virginCursorClampsToWeekZero()
        public
    {
        vm.warp(
            50 weeks + 1 hours
        );

        address[] memory refs = _oneRef(
            stranger
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortReferrerFlushed(
            stranger,
            49,
            0,
            0
        );

        vm.prank(
            stranger
        );

        _flush(diamond).flushReferrals(
            refs
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                stranger
            ),
            49
        );
    }

    function test_RevertWhen_localFlush_refundRejected()
        public
    {
        FlushRefundRejector rejector = new FlushRefundRejector();

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushRefundFailed.selector
        );

        rejector.run{value: 0.1 ether}(
            address(diamond)
        );
    }

    // ---- gap machinery + cursor catch-up (local) ----

    function _buildDormantMatureBook()
        internal
    {
        _depositWithReferralOn(
            diamond,
            user1,
            100_000 * 1e6,
            refA
        );

        _depositOn(
            diamond,
            refA,
            100_000 * 1e6
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            3_104 weeks + 1 hours
        );

        _rec(diamond).advanceBook(
            refA,
            104
        );

        vm.warp(
            3_358 weeks + 5 hours
        );
    }

    function test_localFlush_gapMachinery_slicesCursorsAndExactPay()
        public
    {
        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        assertEq(
            _rec(diamond).getCohortGapLogLength(
                refA
            ),
            1
        );

        uint256 record = _rec(diamond).getCohortGapLogEntry(
            refA,
            0
        );

        assertEq(
            CohortWeeks.gapRecordFromWeek(
                record
            ),
            3_208
        );

        assertEq(
            CohortWeeks.gapRecordToWeek(
                record
            ),
            3_358
        );

        uint256 mature = CohortWeeks.gapRecordMature(
            record
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            3_103
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flush(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            3_312
        );

        uint256 expectedStage1 = _expectedCrumbRangePay(
            diamond,
            refA,
            3_000,
            3_103
        ) + _expectedGapRangePay(
            mature,
            refA,
            3_208,
            3_312
        );

        assertGt(
            expectedStage1,
            0
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            expectedStage1
        );

        _continueGapWalkAndAssertFinal(
            mature
        );
    }

    function _continueGapWalkAndAssertFinal(
        uint256 _mature
    )
        internal
    {
        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            3_207
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flush(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            1
        );

        assertEq(
            gapResumeWeek,
            0
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            3_311
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            3_357
        );

        uint256 expectedFinal = _expectedCrumbRangePay(
            diamond,
            refA,
            3_000,
            3_207
        ) + _expectedGapRangePay(
            _mature,
            refA,
            3_208,
            3_358
        ) + _expectedPay(
            _rec(diamond).getCohortWeekCrumb(
                refA,
                3_358
            ),
            refA,
            3_358
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            expectedFinal
        );
    }

    function test_localFlush_gapCursor_staleResumeSkipsExhaustedSlice()
        public
    {
        _buildDormantMatureBook();

        _flushOwnLocal(
            refA
        );

        vm.store(
            address(diamond),
            keccak256(
                abi.encode(
                    refA,
                    uint256(87)
                )
            ),
            bytes32(
                uint256(3_358) << 128
            )
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnLocal(
            refA
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flush(diamond).getFlushGapCursor(
            refA
        );

        assertEq(
            gapIndex,
            1
        );

        assertEq(
            gapResumeWeek,
            0
        );
    }

    // ---- remote delivery (mock router) ----

    function test_remoteFlush_envelopeExactContent()
        public
    {
        _depositWithReferralOn(
            rdiamond,
            user1,
            8_000 * 1e6,
            refD
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        bytes32 expectedId = keccak256(
            abi.encode(
                address(rdiamond),
                REMOTE_SELECTOR,
                uint256(0)
            )
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(rdiamond)
        );

        emit CohortFlushSent(
            expectedId,
            REMOTE_SELECTOR,
            refD,
            1
        );

        _flushOwnRemote(
            refD
        );

        assertEq(
            router.sendCount(),
            1
        );

        assertEq(
            router.lastSelector(),
            REMOTE_SELECTOR
        );

        assertEq(
            router.lastReceiver(),
            abi.encode(
                address(hub)
            )
        );

        bytes memory data = router.lastData();

        assertEq(
            data.length,
            9 * 32
        );

        assertEq(
            _envWord(data, 0),
            CohortWeeks.packFlushHeader(
                refD,
                1,
                block.timestamp
            )
        );

        assertEq(
            _envWord(data, 1),
            CohortWeeks.packFlushEntry(
                refD,
                3,
                0,
                0
            )
        );

        assertEq(
            _envWord(data, 2),
            CohortWeeks.packFlushScores(
                8_000 * 1e6,
                0
            )
        );

        for (uint256 i; i < 3; ++i) {

            assertEq(
                _envWord(data, 3 + 2 * i),
                3_000 + i
            );

            assertEq(
                _envWord(data, 4 + 2 * i),
                _rec(rdiamond).getCohortWeekCrumb(
                    refD,
                    3_000 + i
                )
            );
        }

        assertEq(
            _flush(rdiamond).getFlushedThroughWeek(
                refD
            ),
            3_001
        );

        assertEq(
            hub.claimable(block.chainid, refD),
            0
        );
    }

    function test_remoteFlush_quoteAndFees()
        public
    {
        address[] memory refs = _oneRef(
            refD
        );

        assertEq(
            _flush(rdiamond).quoteFlushFee(
                refs
            ),
            FIXED_FEE
        );

        assertEq(
            _flush(diamond).quoteFlushFee(
                refs
            ),
            0
        );

        vm.deal(
            refD,
            1 ether
        );

        vm.prank(
            refD
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InsufficientFlushFee.selector
        );

        _flush(rdiamond).flushReferrals{value: FIXED_FEE - 1}(
            refs
        );

        vm.prank(
            refD
        );

        _flush(rdiamond).flushReferrals{value: 0.5 ether}(
            refs
        );

        assertEq(
            refD.balance,
            1 ether - FIXED_FEE
        );
    }

    function test_RevertWhen_remoteFlush_routerUnset()
        public
    {
        WiseTelecomNodesDiamond bare = _newBareFlushDiamond(
            REMOTE_SELECTOR
        );

        address[] memory refs = _oneRef(
            refA
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.RouterNotSet.selector
        );

        _flush(bare).flushReferrals(
            refs
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.RouterNotSet.selector
        );

        _flush(bare).quoteFlushFee(
            refs
        );
    }

    function test_remoteFlush_gasLimitExtraArgs()
        public
    {
        _flushOwnRemote(
            refD
        );

        assertEq(
            router.lastExtraArgs(),
            Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 300_000,
                    allowOutOfOrderExecution: true
                })
            )
        );

        _flush(rdiamond).setFlushGasLimit(
            1_500_000
        );

        vm.warp(
            block.timestamp + 1 hours
        );

        _flushOwnRemote(
            refD
        );

        assertEq(
            router.lastExtraArgs(),
            Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 1_500_000,
                    allowOutOfOrderExecution: true
                })
            )
        );
    }

    function test_remoteFlush_designationPiggyback()
        public
    {
        uint256 setAt = block.timestamp;

        vm.prank(
            refE
        );

        remoteRegistry.setPayoutAddress(
            address(0xF2)
        );

        _flushOwnRemote(
            refE
        );

        bytes memory data = router.lastData();

        assertEq(
            data.length,
            4 * 32
        );

        assertEq(
            CohortWeeks.flushEntryFlags(
                _envWord(data, 1)
            ),
            CohortWeeks.FLUSH_FLAG_DESIGNATION
        );

        assertEq(
            _envWord(data, 3),
            CohortWeeks.packFlushDesignation(
                address(0xF2),
                setAt,
                0
            )
        );

        _flushOwnRemote(
            refD
        );

        data = router.lastData();

        assertEq(
            data.length,
            3 * 32
        );

        assertEq(
            CohortWeeks.flushEntryFlags(
                _envWord(data, 1)
            ),
            0
        );
    }

    function test_remoteFlush_hostileRegistry_degradesSilently()
        public
    {
        vm.prank(
            refE
        );

        remoteRegistry.setPayoutAddress(
            address(0xF2)
        );

        vm.etch(
            address(remoteRegistry),
            address(new RevertingDesignationMock()).code
        );

        _assertDesignationSkipped();

        vm.etch(
            address(remoteRegistry),
            hex"00"
        );

        _assertDesignationSkipped();

        vm.etch(
            address(remoteRegistry),
            address(new WideAddressDesignationMock()).code
        );

        _assertDesignationSkipped();

        vm.etch(
            address(remoteRegistry),
            address(new HugeStampDesignationMock()).code
        );

        _assertDesignationSkipped();
    }

    function _assertDesignationSkipped()
        internal
    {
        _flushOwnRemote(
            refE
        );

        bytes memory data = router.lastData();

        assertEq(
            data.length,
            3 * 32
        );

        assertEq(
            CohortWeeks.flushEntryFlags(
                _envWord(data, 1)
            ),
            0
        );
    }

    function test_remoteFlush_catchUp_startsAtWindowEdge()
        public
    {
        vm.warp(
            3_254 weeks + 1 hours
        );

        _depositWithReferralOn(
            rdiamond,
            user2,
            5_000 * 1e6,
            refE
        );

        vm.warp(
            3_358 weeks + 3 hours
        );

        _flushOwnRemote(
            refE
        );

        assertEq(
            _rec(rdiamond).getCohortGapLogLength(
                refE
            ),
            0
        );

        bytes memory data = router.lastData();

        uint256 entryWord = _envWord(
            data,
            1
        );

        assertEq(
            CohortWeeks.flushEntryCrumbCount(
                entryWord
            ),
            104
        );

        assertEq(
            _envWord(data, 3),
            3_255
        );

        assertGt(
            _rec(rdiamond).getCohortWeekCrumb(
                refE,
                3_254
            ),
            0
        );

        assertEq(
            _flush(rdiamond).getFlushedThroughWeek(
                refE
            ),
            3_357
        );

        vm.warp(
            block.timestamp + 2 hours
        );

        _flushOwnRemote(
            refE
        );

        data = router.lastData();

        assertEq(
            CohortWeeks.flushEntryCrumbCount(
                _envWord(data, 1)
            ),
            1
        );

        assertEq(
            _envWord(data, 3),
            3_358
        );
    }

    function test_remoteFlush_workBudget_leavesLaterEntriesScoresOnly()
        public
    {
        _flush(rdiamond).setAllowedFlushBot(
            address(this),
            true
        );

        _depositWithReferralOn(
            rdiamond,
            user3,
            10_000 * 1e6,
            bigR
        );

        _depositWithReferralOn(
            rdiamond,
            user4,
            5_000 * 1e6,
            smallR
        );

        _flushBotRemote(
            _oneRef(
                bigR
            )
        );

        vm.warp(
            3_104 weeks + 1 hours
        );

        _rec(rdiamond).advanceBook(
            bigR,
            104
        );

        vm.warp(
            3_358 weeks + 5 hours
        );

        address[] memory pair = new address[](2);

        pair[0] = bigR;
        pair[1] = smallR;

        _flushBotRemote(
            pair
        );

        _assertBudgetEnvelope();

        _flushBotRemote(
            _oneRef(
                smallR
            )
        );

        bytes memory data = router.lastData();

        uint256 entryWord = _envWord(
            data,
            1
        );

        assertEq(
            CohortWeeks.flushEntryCrumbCount(
                entryWord
            ),
            1
        );

        assertEq(
            CohortWeeks.flushEntryGapCount(
                entryWord
            ),
            2
        );

        (
            uint256 gapIndex,
            uint256 gapResumeWeek
        ) = _flush(rdiamond).getFlushGapCursor(
            smallR
        );

        assertEq(
            gapIndex,
            0
        );

        assertEq(
            gapResumeWeek,
            3_311
        );
    }

    function _assertBudgetEnvelope()
        internal
        view
    {
        bytes memory data = router.lastData();

        assertEq(
            data.length,
            214 * 32
        );

        assertEq(
            CohortWeeks.flushHeaderEntryCount(
                _envWord(data, 0)
            ),
            2
        );

        assertEq(
            CohortWeeks.flushHeaderDeliverer(
                _envWord(data, 0)
            ),
            address(this)
        );

        assertEq(
            _envWord(data, 1),
            CohortWeeks.packFlushEntry(
                bigR,
                104,
                1,
                0
            )
        );

        for (uint256 i; i < 104; ++i) {

            assertEq(
                _envWord(data, 3 + 2 * i),
                3_000 + i
            );

            assertEq(
                _envWord(data, 4 + 2 * i),
                _rec(rdiamond).getCohortWeekCrumb(
                    bigR,
                    3_000 + i
                )
            );
        }

        uint256 record = _rec(rdiamond).getCohortGapLogEntry(
            bigR,
            0
        );

        assertEq(
            _envWord(data, 211),
            CohortWeeks.packGapRecord(
                3_208,
                3_312,
                CohortWeeks.gapRecordMature(
                    record
                )
            )
        );

        assertEq(
            _envWord(data, 212),
            CohortWeeks.packFlushEntry(
                smallR,
                0,
                0,
                0
            )
        );

        assertEq(
            CohortWeeks.flushScoreReferred(
                _envWord(data, 213)
            ),
            5_000 * 1e6
        );
    }

    // ---- window CCIP delivery ----

    function test_remoteFlushWindow_chargesFeeAndRefundsExcess()
        public
    {
        _depositWithReferralOn(
            rdiamond,
            user1,
            8_000 * 1e6,
            refD
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        _flushOwnRemote(
            refD
        );

        vm.deal(
            refD,
            1 ether
        );

        vm.prank(
            refD
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InsufficientFlushFee.selector
        );

        _flush(rdiamond).flushReferralWindow{value: FIXED_FEE - 1}(
            refD,
            3_000,
            0
        );

        bytes32 expectedId = keccak256(
            abi.encode(
                address(rdiamond),
                REMOTE_SELECTOR,
                uint256(1)
            )
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(rdiamond)
        );

        emit CohortFlushSent(
            expectedId,
            REMOTE_SELECTOR,
            refD,
            1
        );

        vm.prank(
            refD
        );

        _flush(rdiamond).flushReferralWindow{value: 0.5 ether}(
            refD,
            3_000,
            0
        );

        assertEq(
            refD.balance,
            1 ether - FIXED_FEE
        );

        assertEq(
            router.sendCount(),
            2
        );
    }

    function test_remoteFlushWindow_envelopeRestrictedToWindowSlice()
        public
    {
        _flush(rdiamond).setAllowedFlushBot(
            bot,
            true
        );

        _depositWithReferralOn(
            rdiamond,
            user1,
            8_000 * 1e6,
            refD
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        vm.deal(
            bot,
            FIXED_FEE
        );

        vm.prank(
            bot
        );

        _flush(rdiamond).flushReferralWindow{value: FIXED_FEE}(
            refD,
            3_001,
            0
        );

        bytes memory data = router.lastData();

        assertEq(
            data.length,
            7 * 32
        );

        assertEq(
            _envWord(data, 0),
            CohortWeeks.packFlushHeader(
                bot,
                1,
                block.timestamp
            )
        );

        assertEq(
            _envWord(data, 1),
            CohortWeeks.packFlushEntry(
                refD,
                2,
                0,
                0
            )
        );

        assertEq(
            _envWord(data, 2),
            CohortWeeks.packFlushScores(
                8_000 * 1e6,
                0
            )
        );

        assertGt(
            _rec(rdiamond).getCohortWeekCrumb(
                refD,
                3_000
            ),
            0
        );

        for (uint256 i; i < 2; ++i) {

            assertEq(
                _envWord(data, 3 + 2 * i),
                3_001 + i
            );

            assertEq(
                _envWord(data, 4 + 2 * i),
                _rec(rdiamond).getCohortWeekCrumb(
                    refD,
                    3_001 + i
                )
            );
        }
    }

    function test_RevertWhen_flushWindow_strangerFlushesForeignBook()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotFlushBot.selector
        );

        _flush(diamond).flushReferralWindow(
            refA,
            3_000,
            0
        );
    }

    function test_RevertWhen_flushReferrals_mixedBatchOwnThenForeign()
        public
    {
        address[] memory pair = new address[](2);

        pair[0] = stranger;
        pair[1] = refA;

        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotFlushBot.selector
        );

        _flush(diamond).flushReferrals(
            pair
        );
    }

    // ---- quote lower bound (size-dependent fee) ----

    function test_quoteFlushFee_lowerBound_depositBetweenQuoteAndFlush()
        public
    {
        (
            WiseTelecomNodesDiamond sdiamond,
            SizeFeeCcipRouter sizeRouter
        ) = _buildSizeFeeDiamond();

        _depositWithReferralOn(
            sdiamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        address[] memory refs = _oneRef(
            refA
        );

        uint256 quoted = _flush(sdiamond).quoteFlushFee(
            refs
        );

        assertEq(
            quoted,
            sizeRouter.BASE_FEE() + 3 * 32 * sizeRouter.FEE_PER_BYTE()
        );

        _depositWithReferralOn(
            sdiamond,
            user2,
            5_000 * 1e6,
            refA
        );

        vm.deal(
            refA,
            1 ether
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.InsufficientFlushFee.selector
        );

        _flush(sdiamond).flushReferrals{value: quoted}(
            refs
        );

        vm.prank(
            refA
        );

        _flush(sdiamond).flushReferrals{value: 0.5 ether}(
            refs
        );

        assertEq(
            sizeRouter.lastFee(),
            sizeRouter.BASE_FEE() + 9 * 32 * sizeRouter.FEE_PER_BYTE()
        );

        assertEq(
            refA.balance,
            1 ether - sizeRouter.lastFee()
        );
    }

    function test_flushWindow_subsetCostsNoMoreThanCursorQuote()
        public
    {
        (
            WiseTelecomNodesDiamond sdiamond,
            SizeFeeCcipRouter sizeRouter
        ) = _buildSizeFeeDiamond();

        _depositWithReferralOn(
            sdiamond,
            user1,
            10_000 * 1e6,
            refA
        );

        vm.warp(
            BASE_TIME + 2 weeks + 3 hours
        );

        _depositWithReferralOn(
            sdiamond,
            user2,
            5_000 * 1e6,
            refA
        );

        uint256 quoted = _flush(sdiamond).quoteFlushFee(
            _oneRef(
                refA
            )
        );

        vm.deal(
            refA,
            quoted
        );

        vm.prank(
            refA
        );

        _flush(sdiamond).flushReferralWindow{value: quoted}(
            refA,
            3_001,
            0
        );

        uint256 windowFee = sizeRouter.lastFee();

        assertEq(
            windowFee,
            sizeRouter.BASE_FEE() + 7 * 32 * sizeRouter.FEE_PER_BYTE()
        );

        assertLt(
            windowFee,
            quoted
        );

        assertEq(
            refA.balance,
            quoted - windowFee
        );
    }

    // ---- fuzz ----

    function testFuzz_localFlush_reflushIdempotent(
        uint256 _warpHours
    )
        public
    {
        _warpHours = bound(
            _warpHours,
            1,
            1_000
        );

        _depositWithReferralOn(
            diamond,
            user1,
            10_000 * 1e6,
            refA
        );

        _flushOwnLocal(
            refA
        );

        vm.warp(
            block.timestamp + _warpHours * 1 hours
        );

        _flushOwnLocal(
            refA
        );

        uint256 claimableAfter = hub.claimable(
            block.chainid,
            refA
        );

        uint256 cursorAfter = _flush(diamond).getFlushedThroughWeek(
            refA
        );

        _flushOwnLocal(
            refA
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            claimableAfter
        );

        assertEq(
            _flush(diamond).getFlushedThroughWeek(
                refA
            ),
            cursorAfter
        );
    }
}
