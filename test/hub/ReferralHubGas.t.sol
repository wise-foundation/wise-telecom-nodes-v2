// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {CohortFlushCodec} from "../../src/diamond/shared/pending/CohortFlushCodec.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Gas-bound proof for the mainnet referral hub, held to a strict
 * cold-measurement discipline: every measured scenario gets its OWN
 * freshly deployed {ReferralHub} instance, `setUp` performs all
 * unmeasured scaffolding (reporter allowances, seed deliveries and
 * self runs) in a transaction separate from the measured test, and
 * every measurement is a `gasleft()` delta wrapped strictly around a
 * raw low-level `.call` (payload built outside the window, assertions
 * after) so warm-storage noise never leaks into a number.
 *
 * Cells and measured worst cases:
 * 1. `reportSelf` of one closed week on a virgin instance: the source
 *    is listed (system tag read, chain id, source list push) and the
 *    week's self maximum and inputs take their first writes.
 * 2. `settleWeeks` after a self run raised a week that eight other
 *    sources had already priced: every listed source is re-settled at
 *    the raised rates, the fan-out the lazy top-up moved out of the
 *    apply path, so its cost scales with the referrer's listed
 *    sources and never with an envelope.
 * 3. `deliverCrumbs` for one closed week with one Y1 word, own book,
 *    first touch: the listing, the referred bucket, the cursor, the
 *    paid half and the claimable bucket all take first writes.
 * 4. `deliverGap` marginal per-week cost: two instances share a 60-week
 *    self run at 30,000 USD (tier 400) so the gap's 1,000,000 USD
 *    mature average lifts every week to the genesis cap and the mature
 *    lane pays at 100 bps; a courier delivers a 10-week and a 60-week
 *    window, so each priced week records its referred bucket, prices
 *    its cursor and pays the courier fee on top, and
 *    `(gas60 - gas10) / 50` bounds the per-week loop cost.
 * 5. `ccipReceive` mailbox commit of a MAXIMUM-size flush envelope
 *    (header, sixteen entries with designation words and the full
 *    work cap spent on two-word crumbs, 353 words, the largest byte
 *    count the caps admit): the receive does only the commitment
 *    hash, one SSTORE and the payload event, and the measurement pins
 *    it under the 300k FLUSH_GAS_LIMIT default every spoke pays, so
 *    this ceiling is semantic. The store never parses, so only the
 *    size is load-bearing.
 * 6. `ccipReceive` of a first designation push for an owner whose
 *    spoke bucket already holds a claimable backlog: the push releases
 *    the backlog into `totalPayable` and takes the first writes of the
 *    payout address and stamp, held under the 300,000 gas floor
 *    `setSyncGasLimit` enforces on every registry.
 * 7. `applyFlush` of a maximum-work envelope, cold: sixteen entries,
 *    each a five-week self run at the 1,000,000 USD self tier plus five
 *    crumbs of a 20,000 USD weekly referred average on the same weeks
 *    (the full MAX_FLUSH_WORK of 160), every week already priced by
 *    eight other sources, so each self run and each crumb raises the
 *    week's rates and the crumbs price at the genesis cap with the
 *    courier fee on top. Because raises only emit `WeekRatesRaised`
 *    and leave the re-settle to `settleWeeks`, the apply cost depends on
 *    the work alone; the ceiling is semantic: the largest envelope the
 *    caps admit must apply under the EIP-7825 transaction gas cap of
 *    16,777,216 with margin.
 *
 * Measured numbers, re-measured after ANY change to the hub sources:
 * reportSelf first touch (cell 1) 192,910; settleWeeks of one week over
 * eight sources (cell 2) 182,006; deliverCrumbs single week and word
 * (cell 3) 272,477; deliverGap marginal per week (cell 4) 83,223 (windows
 * of 10 and 60 weeks 1,008,965 and 5,170,138); ccipReceive max envelope
 * (cell 5) 143,243; ccipReceive first designation push (cell 6) 93,832;
 * applyFlush max work cold (cell 7) 12,227,125 (a self run re-settles its
 * own source cell inline). With inline top-ups of every source (as
 * first built) cell 7 measured 23,897,114,
 * over the transaction cap, which is why the re-settle is lazy.
 * Bound cells: settleWeeks of 104 weeks over ten listed sources (cell 8,
 * the nine vaults plus one more system) 7,068,901; applyFlush with the
 * whole work as gap weeks (cell 9, sixteen ten-week gap records at the
 * mature cap average, courier set, the heaviest unit) 14,011,883 under the
 * 14,100,000 ceiling (13,874,274 before the elevation whitelist, whose
 * window read costs one warm SLOAD per priced week); the local
 * deliverCrumbs and deliverGap of 104
 * weeks (cell 10) 9,113,501 and 8,233,174, above anything a vault sends
 * locally (its local work budget is 96 units).
 */
contract ReferralHubGasTest is Test, HubDiamondHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant WEEK = CohortWeeks.WEEK;

    uint256 internal constant YEAR = CohortWeeks.YEAR;

    address internal constant REPORTER = address(0xD1);

    address internal constant SELF_REPORTER = address(0xD2);

    address internal constant REFERRER = address(0xB1);

    address internal constant USD_STUB = address(0xF01);

    address internal constant ROUTER = address(0xF1);

    address internal constant COURIER = address(0xD9);

    address internal constant DESIGNATION_SOURCE = address(0xE2);

    uint256 internal constant DESIGNATION_VERSION = 2;

    uint256 internal constant TOPUP_SOURCES = 8;

    uint256 internal constant SETTLE_MAX_SOURCES = 10;

    uint256 internal constant SETTLE_MAX_WEEKS = 104;

    uint256 internal constant GAP_WORK_WEEKS = 10;

    uint256 internal constant SEED_AVERAGE = 1_000 * 1e6;

    uint256 internal constant CAP_SELF_AVERAGE = 1_000_000 * 1e6;

    uint256 internal constant CAP_CRUMB_AVERAGE = 20_000 * 1e6;

    uint256 internal constant GAP_WINDOW_WEEKS = 60;

    uint256 internal constant MAX_WORK_WEEKS = 5;

    uint256 internal constant SELF_FIRST_TOUCH_GAS_CEILING = 198_000;

    uint256 internal constant SETTLE_WEEK_GAS_CEILING = 184_000;

    uint256 internal constant CRUMB_GAS_CEILING = 276_000;

    uint256 internal constant GAP_PER_WEEK_GAS_CEILING = 86_000;

    uint256 internal constant FLUSH_RECEIVE_GAS_CEILING = 300_000;

    uint256 internal constant DESIGNATION_RECEIVE_GAS_CEILING = 300_000;

    uint256 internal constant FLUSH_APPLY_GAS_CEILING = 14_100_000;

    uint256 internal constant SETTLE_MAX_GAS_CEILING = 7_800_000;

    uint256 internal constant LOCAL_MAX_WEEKS_GAS_CEILING = 10_000_000;

    IReferralHub internal hubFirstTouch;

    IReferralHub internal hubTopUp;

    IReferralHub internal hubCrumb;

    IReferralHub internal hubGap10;

    IReferralHub internal hubGap60;

    IReferralHub internal hubReceive;

    IReferralHub internal hubDesignation;

    IReferralHub internal hubApply;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        hubFirstTouch = _deployHub(
            USD_STUB
        );

        HubLeverGrants._grant(
            address(hubFirstTouch),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    REPORTER,
                    true
                )
            )
        );

        hubTopUp = _deployHub(
            USD_STUB
        );

        _seedTopUp();

        hubCrumb = _deployHub(
            USD_STUB
        );

        HubLeverGrants._grant(
            address(hubCrumb),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    REPORTER,
                    true
                )
            )
        );

        hubGap10 = _deployHub(
            USD_STUB
        );

        hubGap60 = _deployHub(
            USD_STUB
        );

        _seedGap(
            hubGap10
        );

        _seedGap(
            hubGap60
        );

        hubReceive = _deployHub(
            USD_STUB
        );

        HubLeverGrants._grant(
            address(hubReceive),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    ROUTER
                )
            )
        );

        HubLeverGrants._grant(
            address(hubReceive),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    7_777,
                    address(0xE1),
                    8_453
                )
            )
        );

        hubDesignation = _deployHub(
            USD_STUB
        );

        _seedDesignationBacklog();

        hubApply = _deployHub(
            USD_STUB
        );

        _seedMaxWorkApply();
    }

    // ---- helpers ----

    function _seedReporter(
        uint256 _index
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                0xC0 + _index
            )
        );
    }

    function _maxWorkReferrer(
        uint256 _index
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint160(REFERRER) + _index
            )
        );
    }

    function _crumbWord(
        uint256 _average
    )
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks._packLanes(
            _average * WEEK,
            0,
            0
        );
    }

    function _seedCrumbs(
        IReferralHub _hub,
        address _referrer,
        uint256 _fromWeek,
        uint256 _weekCount
    )
        internal
    {
        uint256[] memory weeksArg = new uint256[](
            _weekCount
        );

        uint256[] memory words = new uint256[](
            _weekCount
        );

        for (uint256 k; k < _weekCount; ++k) {
            weeksArg[k] = _fromWeek + k;
            words[k] = _crumbWord(
                SEED_AVERAGE
            );
        }

        for (uint256 i; i < TOPUP_SOURCES; ++i) {

            vm.prank(
                _seedReporter(
                    i
                )
            );

            _hub.deliverCrumbs(
                _referrer,
                _referrer,
                weeksArg,
                words
            );
        }
    }

    function _allowSeedReporters(
        IReferralHub _hub
    )
        internal
    {
        for (uint256 i; i < TOPUP_SOURCES; ++i) {
            HubLeverGrants._grant(
                address(_hub),
                abi.encodeCall(
                    IReferralHub.setAllowedReporter,
                    (
                        _seedReporter(
                            i
                        ),
                        true
                    )
                )
            );
        }
    }

    function _seedTopUp()
        internal
    {
        HubLeverGrants._grant(
            address(hubTopUp),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    REPORTER,
                    true
                )
            )
        );

        _allowSeedReporters(
            hubTopUp
        );

        uint256 week = BASE_TIME / WEEK - 1;

        _seedCrumbs(
            hubTopUp,
            REFERRER,
            week,
            1
        );

        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            week,
            week + 1,
            CAP_SELF_AVERAGE
        );

        vm.prank(
            REPORTER
        );

        hubTopUp.reportSelf(
            REFERRER,
            runs
        );
    }

    function _seedGap(
        IReferralHub _hub
    )
        internal
    {
        HubLeverGrants._grant(
            address(_hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    REPORTER,
                    true
                )
            )
        );

        HubLeverGrants._grant(
            address(_hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    SELF_REPORTER,
                    true
                )
            )
        );

        uint256 fromWeek = BASE_TIME / WEEK - GAP_WINDOW_WEEKS - 2;

        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            fromWeek,
            fromWeek + GAP_WINDOW_WEEKS,
            30_000 * 1e6
        );

        vm.prank(
            SELF_REPORTER
        );

        _hub.reportSelf(
            REFERRER,
            runs
        );
    }

    function _seedDesignationBacklog()
        internal
    {
        HubLeverGrants._grant(
            address(hubDesignation),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    ROUTER
                )
            )
        );

        HubLeverGrants._grant(
            address(hubDesignation),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    7_777,
                    address(0xE1),
                    8_453
                )
            )
        );

        HubLeverGrants._grant(
            address(hubDesignation),
            abi.encodeCall(
                IReferralHub.setDesignationSource,
                (
                    7_777,
                    DESIGNATION_SOURCE,
                    8_453
                )
            )
        );

        uint256[] memory words = new uint256[](4);

        words[0] = CohortFlushCodec._packFlushHeader(
            REFERRER,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            REFERRER,
            1,
            0,
            0,
            0
        );

        words[2] = block.timestamp / WEEK - 1;

        words[3] = _crumbWord(
            6_000 * 1e6
        ) | CohortWeeks.CRUMB_WRITTEN_BIT;

        bytes memory payload = abi.encodePacked(
            words
        );

        vm.prank(
            ROUTER
        );

        hubDesignation.ccipReceive(
            Client.Any2EVMMessage({
                messageId: bytes32(uint256(2)),
                sourceChainSelector: 7_777,
                sender: abi.encode(
                    address(0xE1)
                ),
                data: payload,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        hubDesignation.applyFlush(
            bytes32(uint256(2)),
            7_777,
            8_453,
            address(0xE1),
            payload
        );
    }

    function _maxWorkFromWeek()
        internal
        view
        returns (uint256)
    {
        return block.timestamp / WEEK - MAX_WORK_WEEKS;
    }

    function _maxWorkFlushPayload()
        internal
        view
        returns (bytes memory)
    {
        uint256 entryCount = CohortFlushCodec.MAX_FLUSH_ENTRIES;

        uint256 fromWeek = _maxWorkFromWeek();

        uint256[] memory words = new uint256[](
            1 + entryCount * (2 + 2 * MAX_WORK_WEEKS)
        );

        words[0] = CohortFlushCodec._packFlushHeader(
            COURIER,
            entryCount,
            block.timestamp
        );

        uint256 index = 1;

        for (uint256 i; i < entryCount; ++i) {

            words[index] = CohortFlushCodec._packFlushEntry(
                _maxWorkReferrer(
                    i
                ),
                MAX_WORK_WEEKS,
                0,
                0,
                1
            );

            words[index + 1] = CohortFlushCodec._packSelfRun(
                fromWeek,
                fromWeek + MAX_WORK_WEEKS,
                CAP_SELF_AVERAGE
            );

            index += 2;

            for (uint256 k; k < MAX_WORK_WEEKS; ++k) {

                words[index] = fromWeek + k;

                words[index + 1] = _crumbWord(
                    CAP_CRUMB_AVERAGE
                ) | CohortWeeks.CRUMB_WRITTEN_BIT;

                index += 2;
            }
        }

        return abi.encodePacked(
            words
        );
    }

    function _seedMaxWorkApply()
        internal
    {
        HubLeverGrants._grant(
            address(hubApply),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    ROUTER
                )
            )
        );

        HubLeverGrants._grant(
            address(hubApply),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    7_777,
                    address(0xE1),
                    8_453
                )
            )
        );

        _allowSeedReporters(
            hubApply
        );

        for (uint256 j; j < CohortFlushCodec.MAX_FLUSH_ENTRIES; ++j) {
            _seedCrumbs(
                hubApply,
                _maxWorkReferrer(
                    j
                ),
                _maxWorkFromWeek(),
                MAX_WORK_WEEKS
            );
        }

        vm.prank(
            ROUTER
        );

        hubApply.ccipReceive(
            Client.Any2EVMMessage({
                messageId: bytes32(uint256(4)),
                sourceChainSelector: 7_777,
                sender: abi.encode(
                    address(0xE1)
                ),
                data: _maxWorkFlushPayload(),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function _priced(
        uint256 _average,
        uint256 _bps
    )
        internal
        pure
        returns (uint256)
    {
        return _average * WEEK * _bps / (10_000 * YEAR);
    }

    function _gapRecord(
        uint256 _fromWeek,
        uint256 _toWeekExclusive,
        uint256 _mature
    )
        internal
        pure
        returns (uint256)
    {
        return _fromWeek
            | (_toWeekExclusive << CohortWeeks.GAP_TO_SHIFT)
            | (_mature << CohortWeeks.GAP_MATURE_SHIFT);
    }

    function _measure(
        address _target,
        bytes memory _payload
    )
        internal
        returns (uint256)
    {
        uint256 before = gasleft();

        (bool ok, ) = _target.call(_payload);

        uint256 used = before - gasleft();

        assertTrue(
            ok
        );

        return used;
    }

    // ---- Cell 1: reportSelf first touch of one closed week ----

    function test_gas_reportSelf_singleWeekFirstTouch()
        public
    {
        uint256 week = block.timestamp / WEEK - 1;

        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            week,
            week + 1,
            30_000 * 1e6
        );

        bytes memory payload = abi.encodeWithSelector(
            hubFirstTouch.reportSelf.selector,
            REFERRER,
            runs
        );

        vm.prank(
            REPORTER
        );

        uint256 g = _measure(
            address(hubFirstTouch),
            payload
        );

        assertEq(
            hubFirstTouch.weekSelfOf(
                hubFirstTouch.sourceKeyOf(
                    block.chainid,
                    REPORTER
                ),
                REFERRER,
                week
            ),
            30_000 * 1e6
        );

        assertLe(
            g,
            SELF_FIRST_TOUCH_GAS_CEILING
        );

        console.log(
            "GAS|reportSelf singleWeekFirstTouch",
            g
        );
    }

    // ---- Cell 2: settleWeek topping up every seeded source after a raise ----

    function test_gas_settleWeek_topsUpEveryListedSource()
        public
    {
        uint256 week = block.timestamp / WEEK - 1;

        bytes memory payload = abi.encodeWithSelector(
            hubTopUp.settleWeeks.selector,
            REFERRER,
            week,
            uint256(1)
        );

        uint256 accruedBefore = hubTopUp.totalAccrued();

        uint256 g = _measure(
            address(hubTopUp),
            payload
        );

        assertGt(
            hubTopUp.totalAccrued(),
            accruedBefore
        );

        assertEq(
            hubTopUp.totalAccrued(),
            TOPUP_SOURCES * _priced(SEED_AVERAGE, 900)
        );

        assertLe(
            g,
            SETTLE_WEEK_GAS_CEILING
        );

        console.log(
            "GAS|settleWeek topsUpEightSources",
            g
        );
    }

    // ---- Cell 3: deliverCrumbs single closed week single word ----

    function test_gas_deliverCrumbs_singleWeekSingleWord()
        public
    {
        uint256[] memory weeksArg = new uint256[](1);
        weeksArg[0] = block.timestamp / WEEK - 1;

        uint256[] memory words = new uint256[](1);

        words[0] = _crumbWord(
            6_000 * 1e6
        );

        bytes memory payload = abi.encodeWithSelector(
            hubCrumb.deliverCrumbs.selector,
            REFERRER,
            REFERRER,
            weeksArg,
            words
        );

        vm.prank(
            REPORTER
        );

        uint256 g = _measure(
            address(hubCrumb),
            payload
        );

        assertEq(
            hubCrumb.totalAccrued(),
            _priced(
                6_000 * 1e6,
                100
            )
        );

        assertLe(
            g,
            CRUMB_GAS_CEILING
        );

        console.log(
            "GAS|deliverCrumbs singleWeekSingleWord",
            g
        );
    }

    // ---- Cell 4: deliverGap marginal per-week cost ----

    function test_gas_deliverGap_marginalPerWeekCost()
        public
    {
        uint256 fromWeek = BASE_TIME / WEEK - GAP_WINDOW_WEEKS - 2;

        uint256 record = _gapRecord(
            fromWeek,
            fromWeek + GAP_WINDOW_WEEKS,
            1_000_000 * 1e6
        );

        bytes memory payload10 = abi.encodeWithSelector(
            hubGap10.deliverGap.selector,
            REFERRER,
            COURIER,
            record,
            fromWeek,
            uint256(10)
        );

        bytes memory payload60 = abi.encodeWithSelector(
            hubGap60.deliverGap.selector,
            REFERRER,
            COURIER,
            record,
            fromWeek,
            uint256(GAP_WINDOW_WEEKS)
        );

        vm.prank(
            REPORTER
        );

        uint256 g10 = _measure(
            address(hubGap10),
            payload10
        );

        vm.prank(
            REPORTER
        );

        uint256 g60 = _measure(
            address(hubGap60),
            payload60
        );

        uint256 weekPaid = _priced(
            1_000_000 * 1e6,
            100
        );

        assertEq(
            hubGap60.totalAccrued(),
            GAP_WINDOW_WEEKS * (weekPaid + weekPaid * 500 / 10_000)
        );

        uint256 perWeek = (g60 - g10) / (GAP_WINDOW_WEEKS - 10);

        assertLe(
            perWeek,
            GAP_PER_WEEK_GAS_CEILING
        );

        console.log(
            "GAS|deliverGap window10",
            g10
        );

        console.log(
            "GAS|deliverGap window60",
            g60
        );

        console.log(
            "GAS|deliverGap perWeekMarginal",
            perWeek
        );
    }

    // ---- Cell 5: mailbox receive of a maximum-size envelope ----

    function test_gas_ccipReceive_maxEnvelopeUnderFlushBudget()
        public
    {
        uint256[] memory words = new uint256[](
            1 + CohortFlushCodec.MAX_FLUSH_ENTRIES * 2 + CohortFlushCodec.MAX_FLUSH_WORK * 2
        );

        for (uint256 i; i < words.length; ++i) {
            words[i] = i + 1;
        }

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: 7_777,
            sender: abi.encode(
                address(0xE1)
            ),
            data: abi.encodePacked(
                words
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        bytes memory payload = abi.encodeWithSelector(
            hubReceive.ccipReceive.selector,
            message
        );

        vm.prank(
            ROUTER
        );

        uint256 g = _measure(
            address(hubReceive),
            payload
        );

        assertLe(
            g,
            FLUSH_RECEIVE_GAS_CEILING
        );

        console.log(
            "GAS|ccipReceive maxEnvelope",
            g
        );
    }

    // ---- Cell 6: first designation push releasing a claimable backlog ----

    function test_gas_ccipReceive_designationPushUnderSyncFloor()
        public
    {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(3)),
            sourceChainSelector: 7_777,
            sender: abi.encode(
                DESIGNATION_SOURCE
            ),
            data: abi.encode(
                DESIGNATION_VERSION,
                REFERRER,
                address(0xF2),
                block.timestamp,
                uint256(1)
            ),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        bytes memory payload = abi.encodeWithSelector(
            hubDesignation.ccipReceive.selector,
            message
        );

        vm.prank(
            ROUTER
        );

        uint256 g = _measure(
            address(hubDesignation),
            payload
        );

        assertGt(
            hubDesignation.totalPayable(),
            0
        );

        assertEq(
            hubDesignation.totalPayable(),
            hubDesignation.claimable(
                8_453,
                REFERRER
            )
        );

        assertEq(
            hubDesignation.payoutStamp(
                8_453,
                REFERRER
            ),
            (block.timestamp << 8) | 1
        );

        assertLe(
            g,
            DESIGNATION_RECEIVE_GAS_CEILING
        );

        console.log(
            "GAS|ccipReceive designationPush",
            g
        );
    }

    // ---- Cell 7: cold apply of a maximum-work flush envelope ----

    function test_gas_applyFlush_maxWorkCold()
        public
    {
        bytes memory payload = abi.encodeWithSelector(
            hubApply.applyFlush.selector,
            bytes32(uint256(4)),
            7_777,
            8_453,
            address(0xE1),
            _maxWorkFlushPayload()
        );

        uint256 accruedBefore = hubApply.totalAccrued();

        uint256 g = _measure(
            address(hubApply),
            payload
        );

        uint256 crumbPaid = _priced(
            CAP_CRUMB_AVERAGE,
            1_000
        );

        assertEq(
            hubApply.totalAccrued() - accruedBefore,
            CohortFlushCodec.MAX_FLUSH_ENTRIES * MAX_WORK_WEEKS * (
                crumbPaid + crumbPaid * 500 / 10_000
            )
        );

        assertLe(
            g,
            FLUSH_APPLY_GAS_CEILING
        );

        console.log(
            "GAS|applyFlush maxWorkCold",
            g
        );
    }

    // ---- Cell 8: settleWeeks of 104 weeks over the largest realistic source list ----

    function _seedSettleMax(
        IReferralHub _hub,
        uint256 _fromWeek
    )
        internal
    {
        uint256[] memory weeksArg = new uint256[](
            SETTLE_MAX_WEEKS
        );

        uint256[] memory words = new uint256[](
            SETTLE_MAX_WEEKS
        );

        for (uint256 k; k < SETTLE_MAX_WEEKS; ++k) {
            weeksArg[k] = _fromWeek + k;
            words[k] = _crumbWord(
                SEED_AVERAGE
            );
        }

        for (uint256 i; i < SETTLE_MAX_SOURCES; ++i) {

            HubLeverGrants._grant(
                address(_hub),
                abi.encodeCall(
                    IReferralHub.setAllowedReporter,
                    (
                        _seedReporter(
                            i
                        ),
                        true
                    )
                )
            );

            vm.prank(
                _seedReporter(
                    i
                )
            );

            _hub.deliverCrumbs(
                REFERRER,
                REFERRER,
                weeksArg,
                words
            );
        }

        HubLeverGrants._grant(
            address(_hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    REPORTER,
                    true
                )
            )
        );

        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            _fromWeek,
            _fromWeek + SETTLE_MAX_WEEKS,
            CAP_SELF_AVERAGE
        );

        vm.prank(
            REPORTER
        );

        _hub.reportSelf(
            REFERRER,
            runs
        );
    }

    function test_gas_settleWeeks_maxWeeksOverTenSources()
        public
    {
        IReferralHub hubSettleMax = _deployHub(
            USD_STUB
        );

        uint256 fromWeek = block.timestamp / WEEK - SETTLE_MAX_WEEKS;

        _seedSettleMax(
            hubSettleMax,
            fromWeek
        );

        uint256 accruedBefore = hubSettleMax.totalAccrued();

        uint256 g = _measure(
            address(hubSettleMax),
            abi.encodeWithSelector(
                hubSettleMax.settleWeeks.selector,
                REFERRER,
                fromWeek,
                SETTLE_MAX_WEEKS
            )
        );

        assertGt(
            hubSettleMax.totalAccrued(),
            accruedBefore
        );

        assertLe(
            g,
            SETTLE_MAX_GAS_CEILING
        );

        console.log(
            "GAS|settleWeeks 104 weeks x 10 sources",
            g
        );
    }

    // ---- Cell 9: applyFlush max work as gap weeks only ----

    function _seedSelfOver(
        IReferralHub _hub,
        address _referrer,
        uint256 _fromWeek,
        uint256 _weekCount
    )
        internal
    {
        uint256[] memory runs = new uint256[](1);

        runs[0] = CohortFlushCodec._packSelfRun(
            _fromWeek,
            _fromWeek + _weekCount,
            30_000 * 1e6
        );

        vm.prank(
            SELF_REPORTER
        );

        _hub.reportSelf(
            _referrer,
            runs
        );
    }

    function _gapWorkFlushPayload(
        uint256 _fromWeek
    )
        internal
        view
        returns (bytes memory)
    {
        uint256 entryCount = CohortFlushCodec.MAX_FLUSH_ENTRIES;

        uint256[] memory words = new uint256[](
            1 + entryCount * 2
        );

        words[0] = CohortFlushCodec._packFlushHeader(
            COURIER,
            entryCount,
            block.timestamp
        );

        for (uint256 i; i < entryCount; ++i) {

            words[1 + 2 * i] = CohortFlushCodec._packFlushEntry(
                _maxWorkReferrer(
                    i
                ),
                0,
                1,
                0,
                0
            );

            words[2 + 2 * i] = _gapRecord(
                _fromWeek,
                _fromWeek + GAP_WORK_WEEKS,
                1_000_000 * 1e6
            );
        }

        return abi.encodePacked(
            words
        );
    }

    function test_gas_applyFlush_maxWorkGapWeeksOnly()
        public
    {
        IReferralHub hubGapApply = _deployHub(
            USD_STUB
        );

        HubLeverGrants._grant(
            address(hubGapApply),
            abi.encodeCall(
                IReferralHub.setCcipRouter,
                (
                    ROUTER
                )
            )
        );

        HubLeverGrants._grant(
            address(hubGapApply),
            abi.encodeCall(
                IReferralHub.setFlushSource,
                (
                    7_777,
                    address(0xE1),
                    8_453
                )
            )
        );

        HubLeverGrants._grant(
            address(hubGapApply),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    SELF_REPORTER,
                    true
                )
            )
        );

        uint256 fromWeek = block.timestamp / WEEK - GAP_WORK_WEEKS - 2;

        for (uint256 i; i < CohortFlushCodec.MAX_FLUSH_ENTRIES; ++i) {
            _seedSelfOver(
                hubGapApply,
                _maxWorkReferrer(
                    i
                ),
                fromWeek,
                GAP_WORK_WEEKS
            );
        }

        bytes memory envelope = _gapWorkFlushPayload(
            fromWeek
        );

        vm.prank(
            ROUTER
        );

        hubGapApply.ccipReceive(
            Client.Any2EVMMessage({
                messageId: bytes32(uint256(9)),
                sourceChainSelector: 7_777,
                sender: abi.encode(
                    address(0xE1)
                ),
                data: envelope,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        uint256 g = _measure(
            address(hubGapApply),
            abi.encodeWithSelector(
                hubGapApply.applyFlush.selector,
                bytes32(uint256(9)),
                7_777,
                8_453,
                address(0xE1),
                envelope
            )
        );

        uint256 weekPaid = _priced(
            1_000_000 * 1e6,
            100
        );

        assertEq(
            hubGapApply.totalAccrued(),
            CohortFlushCodec.MAX_FLUSH_ENTRIES * GAP_WORK_WEEKS * (weekPaid + weekPaid * 500 / 10_000)
        );

        assertLe(
            g,
            FLUSH_APPLY_GAS_CEILING
        );

        console.log(
            "GAS|applyFlush maxWorkGapWeeksOnly",
            g
        );
    }

    // ---- Cell 10: local deliveries at the 104-week bound ----

    function test_gas_localDeliveries_maxWeeks()
        public
    {
        IReferralHub hubLocalMax = _deployHub(
            USD_STUB
        );

        HubLeverGrants._grant(
            address(hubLocalMax),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    REPORTER,
                    true
                )
            )
        );

        HubLeverGrants._grant(
            address(hubLocalMax),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    SELF_REPORTER,
                    true
                )
            )
        );

        uint256 maxWeeks = CohortWeeks.MAX_SETTLE_BOUNDARIES;

        uint256 fromWeek = block.timestamp / WEEK - maxWeeks - 1;

        address gapReferrer = _maxWorkReferrer(
            1
        );

        _seedSelfOver(
            hubLocalMax,
            REFERRER,
            fromWeek,
            maxWeeks
        );

        _seedSelfOver(
            hubLocalMax,
            gapReferrer,
            fromWeek,
            maxWeeks
        );

        uint256[] memory weeksArg = new uint256[](
            maxWeeks
        );

        uint256[] memory words = new uint256[](
            maxWeeks
        );

        for (uint256 k; k < maxWeeks; ++k) {
            weeksArg[k] = fromWeek + k;
            words[k] = _crumbWord(
                CAP_CRUMB_AVERAGE
            );
        }

        vm.prank(
            REPORTER
        );

        uint256 crumbs = _measure(
            address(hubLocalMax),
            abi.encodeWithSelector(
                hubLocalMax.deliverCrumbs.selector,
                REFERRER,
                COURIER,
                weeksArg,
                words
            )
        );

        vm.prank(
            REPORTER
        );

        uint256 gap = _measure(
            address(hubLocalMax),
            abi.encodeWithSelector(
                hubLocalMax.deliverGap.selector,
                gapReferrer,
                COURIER,
                _gapRecord(
                    fromWeek,
                    fromWeek + maxWeeks,
                    1_000_000 * 1e6
                ),
                fromWeek,
                maxWeeks
            )
        );

        assertLe(
            crumbs,
            LOCAL_MAX_WEEKS_GAS_CEILING
        );

        assertLe(
            gap,
            LOCAL_MAX_WEEKS_GAS_CEILING
        );

        console.log(
            "GAS|deliverCrumbs 104 weeks",
            crumbs
        );

        console.log(
            "GAS|deliverGap 104 weeks",
            gap
        );
    }
}
