// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Gas-bound proof for the mainnet referral hub, held to a strict
 * cold-measurement discipline: every measured scenario gets its OWN
 * freshly deployed {ReferralHub} instance, `setUp` performs all
 * unmeasured scaffolding (reporter allowances, seed reports) in a
 * transaction separate from the measured test, and every measurement
 * is a `gasleft()` delta wrapped strictly around a raw low-level
 * `.call` (payload built outside the window, assertions after) so
 * warm-storage noise never leaks into a number. Forge reruns `setUp`
 * fresh before every test function, so a per-test `vm.warp` used to
 * dwell a scenario forward never leaks into a sibling test; the seed
 * reports placed INSIDE `setUp` land at `BASE_TIME`, which is what
 * lets cell 2 repeat within the seed's week and cells 3/4 warp past
 * the dwell-min window.
 *
 * Cells and measured worst cases:
 * 1. `reportScores` first-ever call on a virgin instance: first write
 *    of the per-source report and the global aggregates plus the
 *    first checkpoint push; every touched slot goes zero -> nonzero,
 *    the single worst case for the function.
 * 2. `reportScores` same-week repeat that changes only `selfScore`:
 *    the packed report differs, so the report slot and the global
 *    aggregates rewrite in place and the checkpoint log updates its
 *    same-week tail entry instead of pushing, much cheaper than
 *    cell 1 even though the measurement transaction is itself cold
 *    (every touched slot was last written in `setUp`'s transaction,
 *    not this one).
 * 3. `deliverCrumbs` for a single already-dwelled week (score reported
 *    at week W, delivered at W+2 per the dwell-min ladder) with one
 *    nonzero Y1 word: the intake choke point's cursor diff, rate
 *    lookup and `claimable`/`totalAccrued` SSTORE path all run once.
 * 4. `deliverGap` marginal per-week cost: two instances seeded
 *    identically with a referrer whose dwelled ladder sum sits at the
 *    genesis cap (referred 1M + self 30k USD, tiers 800 + 400 against
 *    capBps 1000), so the year-2 and mature rates unlock and every
 *    iterated week actually pays the mature lane at the genesis
 *    100 bps; the instances are delivered a 10-week and a 60-week
 *    window respectively and `(gas60 - gas10) / 50` pins the linear
 *    per-week cost of the `_priceGapWindow` loop. The delivered
 *    window opens two weeks after the seed report so dwell-min has
 *    matured for every priced week.
 * 5. `ccipReceive` mailbox commit of a MAXIMUM-size flush envelope
 *    (465 words, 16 entries at the full work cap with designation
 *    words, the largest byte count the caps admit): the receive path
 *    does only the commitment hash, one SSTORE and the payload
 *    event, and the measurement pins it under the 300k
 *    FLUSH_GAS_LIMIT default, the budget every spoke pays for
 *    cross-chain delivery, so this ceiling is semantic, not merely a
 *    regression guard. The store never parses, so the words carry
 *    arbitrary values; only the size is load-bearing.
 *
 * Measured numbers are documented next to the ceilings so a future
 * regression shows in the review diff, not only in a failing
 * assertion; they are re-measured (and this table re-pasted) after
 * ANY change to the hub sources: reportScores first-ever (cell 1)
 * 150,336; reportScores same-week repeat (cell 2) 56,138;
 * deliverCrumbs single week/word (cell 3) 115,106; deliverGap
 * 10-week window 413,770, 60-week window 2,105,708, marginal
 * per-week (cell 4) 33,838; ccipReceive max envelope (cell 5)
 * 168,990.
 */
contract ReferralHubGasTest is Test {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    address internal constant REPORTER = address(0xD1);

    address internal constant REFERRER = address(0xB1);

    address internal constant USD_STUB = address(0xF01);

    uint256 internal constant FIRST_TOUCH_GAS_CEILING = 155_000;

    uint256 internal constant SAME_WEEK_REPEAT_GAS_CEILING = 60_000;

    uint256 internal constant CRUMB_GAS_CEILING = 116_000;

    uint256 internal constant GAP_PER_WEEK_GAS_CEILING = 34_600;

    uint256 internal constant FLUSH_RECEIVE_GAS_CEILING = 300_000;

    address internal constant ROUTER = address(0xF1);

    ReferralHub internal hubReceive;

    ReferralHub internal hubFirstTouch;

    ReferralHub internal hubRepeat;

    ReferralHub internal hubCrumb;

    ReferralHub internal hubGap10;

    ReferralHub internal hubGap60;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        hubFirstTouch = new ReferralHub(
            USD_STUB
        );

        hubFirstTouch.setAllowedReporter(
            REPORTER,
            true
        );

        hubRepeat = new ReferralHub(
            USD_STUB
        );

        hubRepeat.setAllowedReporter(
            REPORTER,
            true
        );

        vm.prank(
            REPORTER
        );

        hubRepeat.reportScores(
            REFERRER,
            6_000 * 1e6,
            0
        );

        hubCrumb = new ReferralHub(
            USD_STUB
        );

        hubCrumb.setAllowedReporter(
            REPORTER,
            true
        );

        vm.prank(
            REPORTER
        );

        hubCrumb.reportScores(
            REFERRER,
            6_000 * 1e6,
            0
        );

        hubGap10 = new ReferralHub(
            USD_STUB
        );

        hubGap60 = new ReferralHub(
            USD_STUB
        );

        _seedGap(hubGap10);
        _seedGap(hubGap60);

        hubReceive = new ReferralHub(
            USD_STUB
        );

        hubReceive.setCcipRouter(
            ROUTER
        );

        hubReceive.setFlushSource(
            7_777,
            address(0xE1),
            8_453
        );
    }

    // ---- helpers ----

    function _seedGap(
        ReferralHub _hub
    )
        internal
    {
        _hub.setAllowedReporter(
            REPORTER,
            true
        );

        vm.prank(
            REPORTER
        );

        _hub.reportScores(
            REFERRER,
            1_000_000 * 1e6,
            30_000 * 1e6
        );
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

        assertTrue(ok);

        return used;
    }

    // ---- Cell 1: reportScores first-touch-of-week worst case ----

    function test_gas_reportScores_firstTouchOfWeek()
        public
    {
        bytes memory payload = abi.encodeWithSelector(
            hubFirstTouch.reportScores.selector,
            REFERRER,
            1_000 * 1e6,
            0
        );

        vm.prank(
            REPORTER
        );

        uint256 g = _measure(address(hubFirstTouch), payload);

        assertLe(g, FIRST_TOUCH_GAS_CEILING);

        console.log("GAS|reportScores firstTouchOfWeek", g);
    }

    // ---- Cell 2: reportScores same-week repeat (warm tail update) ----

    function test_gas_reportScores_sameWeekRepeat()
        public
    {
        bytes memory payload = abi.encodeWithSelector(
            hubRepeat.reportScores.selector,
            REFERRER,
            6_000 * 1e6,
            1 * 1e6
        );

        vm.prank(
            REPORTER
        );

        uint256 g = _measure(address(hubRepeat), payload);

        assertLe(g, SAME_WEEK_REPEAT_GAS_CEILING);

        console.log("GAS|reportScores sameWeekRepeat", g);
    }

    // ---- Cell 3: deliverCrumbs single week single word ----

    function test_gas_deliverCrumbs_singleWeekSingleWord()
        public
    {
        vm.warp(
            BASE_TIME + 2 weeks
        );

        uint256 week = block.timestamp / CohortWeeks.WEEK;

        uint256[] memory weeksArg = new uint256[](1);
        weeksArg[0] = week;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks.packLanes(6_000 * 1e6 * CohortWeeks.WEEK, 0, 0);

        bytes memory payload = abi.encodeWithSelector(
            hubCrumb.deliverCrumbs.selector,
            REFERRER,
            weeksArg,
            words
        );

        vm.prank(
            REPORTER
        );

        uint256 g = _measure(address(hubCrumb), payload);

        assertLe(g, CRUMB_GAS_CEILING);

        console.log("GAS|deliverCrumbs singleWeekSingleWord", g);
    }

    // ---- Cell 4: deliverGap marginal per-week cost ----

    function test_gas_deliverGap_marginalPerWeekCost()
        public
    {
        vm.warp(
            BASE_TIME + 100 weeks
        );

        uint256 fromWeek = BASE_TIME / CohortWeeks.WEEK + 2;

        uint256 record = _gapRecord(
            fromWeek,
            fromWeek + 90,
            5_000 * 1e6
        );

        bytes memory payload10 = abi.encodeWithSelector(
            hubGap10.deliverGap.selector,
            REFERRER,
            record,
            fromWeek,
            uint256(10)
        );

        bytes memory payload60 = abi.encodeWithSelector(
            hubGap60.deliverGap.selector,
            REFERRER,
            record,
            fromWeek,
            uint256(60)
        );

        vm.prank(
            REPORTER
        );

        uint256 g10 = _measure(address(hubGap10), payload10);

        vm.prank(
            REPORTER
        );

        uint256 g60 = _measure(address(hubGap60), payload60);

        uint256 perWeek = (g60 - g10) / 50;

        assertLe(perWeek, GAP_PER_WEEK_GAS_CEILING);

        console.log("GAS|deliverGap window10", g10);
        console.log("GAS|deliverGap window60", g60);
        console.log("GAS|deliverGap perWeekMarginal", perWeek);
    }

    // ---- Cell 5: mailbox receive of a maximum-size envelope ----

    function test_gas_ccipReceive_maxEnvelopeUnderFlushBudget()
        public
    {
        uint256[] memory words = new uint256[](465);

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

        uint256 g = _measure(address(hubReceive), payload);

        assertLe(g, FLUSH_RECEIVE_GAS_CEILING);

        console.log("GAS|ccipReceive maxEnvelope", g);
    }
}
