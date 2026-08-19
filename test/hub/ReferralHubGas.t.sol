// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev Gas-bound proof for the mainnet referral hub, ported from the
 * cold-measurement discipline of `test/fenwick/ReferralTopDecileGas.t.sol`
 * (its @dev lines 9-40 are the methodology this file replicates): every
 * measured scenario gets its OWN freshly deployed {ReferralHub}
 * instance, `setUp` performs all unmeasured scaffolding (population,
 * seed reports, rate-table pushes) in a transaction separate from the
 * measured test, and every measurement is a `gasleft()` delta wrapped
 * strictly around a raw low-level `.call` (payload built outside the
 * window, assertions after) so warm-storage noise never leaks into a
 * number. Forge reruns `setUp` fresh before every test function, so a
 * per-test `vm.warp` used to dwell a scenario forward never leaks into
 * a sibling test — only the seed calls placed INSIDE `setUp` share a
 * timestamp with the measured call of the test that depends on it
 * (cell 3's same-week repeat, cell 4/5's dwell-past setup).
 *
 * Cells and measured worst cases:
 * 1. `isTopTenPercent` on a crafted bucket-2048 referrer (query walks
 *    `prefixSum(2047)`, the maximum 11-node Fenwick descent, exactly
 *    the sandbox's worst case) across N = 10 / 100 / 1,000 active
 *    referrers on three distinct instances. Cold SLOAD costs the same
 *    2,100 gas whether the visited node is zero or nonzero, so this is
 *    expected to be N-invariant (tight flatness band).
 * 2. `reportScores` first-ever call on a virgin instance: new-week
 *    cutoff push + first checkpoint push + a 12-node Fenwick activation
 *    walk from bucket 1 (every node zero -> nonzero) — the single
 *    worst case for the function.
 * 3. `reportScores` same-week repeat that changes only `selfScore`:
 *    the referred score (and therefore the bucket) is unchanged, so
 *    `_setReferredScore` early-returns before touching the Fenwick
 *    tree, the cutoff snapshot short-circuits (an entry for the week
 *    already exists) and the checkpoint log updates its tail entry in
 *    place instead of pushing — much cheaper than cell 2 even though
 *    the measurement transaction is itself cold (every touched slot
 *    was last written in `setUp`'s transaction, not this one).
 * 4. `deliverCrumbs` for a single already-dwelled week (score reported
 *    at week W, delivered at W+2 per the dwell-min ladder) with one
 *    nonzero Y1 word: the intake choke point's cursor diff, rate
 *    lookup and `claimable`/`totalAccrued` SSTORE path all run once.
 * 5. `deliverGap` marginal per-week cost: two instances seeded
 *    identically (one active, always-qualified referrer — with a
 *    single active referrer `_targetTopCount(1) == 1` so it is always
 *    top-decile — plus a rate table with nonzero `mRateBps` so every
 *    iterated week actually pays) are delivered a 10-week and a
 *    60-week window respectively; `(gas60 - gas10) / 50` pins the
 *    linear per-week cost of the `_priceGapWindow` loop.
 *
 * Measured numbers on the current toolchain (documented so a future
 * regression shows in the diff, not only in a failing assertion):
 * isTopTenPercent worst bucket 34,577 gas, EXACTLY flat across
 * N=10/100/1000 (cold SLOAD cost is value-independent, so the query
 * is provably N-invariant, not merely close); reportScores
 * first-touch-of-week (virgin instance, bucket-1 12-node Fenwick
 * activation plus first cutoff push plus first checkpoint push)
 * 465,571; reportScores same-week repeat (self-score-only change, no
 * Fenwick write) 53,092; deliverCrumbs single week/word 143,823;
 * deliverGap 10-week window 491,346, 60-week window 2,554,634,
 * marginal per-week (gas60 - gas10) / 50 = 41,265 -- driven mostly by
 * one claimable and one totalAccrued SSTORE per iterated week once
 * the referrer is decile-qualified and the pushed table's mRateBps
 * is nonzero.
 */
contract ReferralHubGasTest is Test {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant MIN_ACTIVE_SCORE = 1_000 * 1e6;

    uint256 internal constant BUCKET_COUNT = 2_048;

    address internal constant REPORTER = address(0xD1);

    address internal constant REFERRER = address(0xB1);

    address internal constant WORST = address(0xB2);

    uint256 internal constant QUERY_GAS_CEILING = 36_000;

    uint256 internal constant QUERY_BAND = 500;

    uint256 internal constant FIRST_TOUCH_GAS_CEILING = 470_000;

    uint256 internal constant SAME_WEEK_REPEAT_GAS_CEILING = 55_000;

    uint256 internal constant CRUMB_GAS_CEILING = 148_000;

    uint256 internal constant GAP_PER_WEEK_GAS_CEILING = 43_000;

    ReferralHub internal hub10;

    ReferralHub internal hub100;

    ReferralHub internal hub1000;

    ReferralHub internal hubFirstTouch;

    ReferralHub internal hubRepeat;

    ReferralHub internal hubCrumb;

    ReferralHub internal hubGap10;

    ReferralHub internal hubGap60;

    uint256 internal score2048;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        ReferralHub probe = new ReferralHub();

        score2048 = _scoreForBucket(
            probe,
            BUCKET_COUNT
        );

        hub10 = new ReferralHub();
        hub100 = new ReferralHub();
        hub1000 = new ReferralHub();

        hub10.setAllowedReporter(REPORTER, true);
        hub100.setAllowedReporter(REPORTER, true);
        hub1000.setAllowedReporter(REPORTER, true);

        _populate(hub10, 10);
        _populate(hub100, 100);
        _populate(hub1000, 1_000);

        _craftWorst(hub10);
        _craftWorst(hub100);
        _craftWorst(hub1000);

        hubFirstTouch = new ReferralHub();

        hubFirstTouch.setAllowedReporter(
            REPORTER,
            true
        );

        hubRepeat = new ReferralHub();

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

        hubCrumb = new ReferralHub();

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

        hubGap10 = new ReferralHub();
        hubGap60 = new ReferralHub();

        _seedGap(hubGap10);
        _seedGap(hubGap60);
    }

    // ---- helpers ----

    function _scoreForBucket(
        ReferralHub _hub,
        uint256 _bucket
    )
        internal
        pure
        returns (uint256)
    {
        uint256 lo = MIN_ACTIVE_SCORE;

        uint256 hi = type(uint256).max;

        while (lo < hi) {

            uint256 mid = lo + (hi - lo) / 2;

            if (_hub.bucketForScore(mid) >= _bucket) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }

        return lo;
    }

    function _addr(
        uint256 _i
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(0xA000 + _i)
        );
    }

    function _populate(
        ReferralHub _hub,
        uint256 _n
    )
        internal
    {
        vm.startPrank(
            REPORTER
        );

        for (uint256 i; i < _n; ++i) {

            uint256 roll = uint256(
                keccak256(abi.encode("hub.gas.score", i))
            );

            uint256 exponent = roll % 20;

            uint256 offset = (roll >> 16) % (MIN_ACTIVE_SCORE << exponent);

            _hub.reportScores(
                _addr(i),
                (MIN_ACTIVE_SCORE << exponent) + offset,
                0
            );
        }

        vm.stopPrank();
    }

    function _craftWorst(
        ReferralHub _hub
    )
        internal
    {
        vm.prank(
            REPORTER
        );

        _hub.reportScores(
            WORST,
            score2048,
            0
        );
    }

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
            6_000 * 1e6,
            0
        );

        vm.warp(
            BASE_TIME + 1 weeks
        );

        _hub.snapshotWeek();

        vm.warp(
            BASE_TIME
        );

        ReferralHubDeclarations.RateTable memory table;

        table.effectiveFromWeek = uint32(BASE_TIME / CohortWeeks.WEEK + 1);
        table.capBps = 1_000;
        table.mRateBps = 100;

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

        _hub.pushRateTable(
            table
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

    function _band3(
        uint256 _a,
        uint256 _b,
        uint256 _c
    )
        internal
        pure
        returns (
            uint256 lo,
            uint256 hi
        )
    {
        lo = _a;
        hi = _a;

        if (_b < lo) {
            lo = _b;
        }

        if (_c < lo) {
            lo = _c;
        }

        if (_b > hi) {
            hi = _b;
        }

        if (_c > hi) {
            hi = _c;
        }
    }

    // ---- Cell 1: isTopTenPercent, flat across N ----

    function test_gas_isTopTenPercent_worstBucket_flatAcrossN()
        public
    {
        bytes memory payload = abi.encodeWithSelector(
            hub10.isTopTenPercent.selector,
            WORST
        );

        uint256 g10 = _measure(address(hub10), payload);
        uint256 g100 = _measure(address(hub100), payload);
        uint256 g1000 = _measure(address(hub1000), payload);

        (uint256 lo, uint256 hi) = _band3(g10, g100, g1000);

        assertLe(hi - lo, QUERY_BAND);
        assertLe(hi, QUERY_GAS_CEILING);

        console.log("GAS|isTopTenPercent N=10", g10);
        console.log("GAS|isTopTenPercent N=100", g100);
        console.log("GAS|isTopTenPercent N=1000", g1000);
    }

    // ---- Cell 2: reportScores first-touch-of-week worst case ----

    function test_gas_reportScores_firstTouchOfWeek()
        public
    {
        bytes memory payload = abi.encodeWithSelector(
            hubFirstTouch.reportScores.selector,
            REFERRER,
            MIN_ACTIVE_SCORE,
            0
        );

        vm.prank(
            REPORTER
        );

        uint256 g = _measure(address(hubFirstTouch), payload);

        assertLe(g, FIRST_TOUCH_GAS_CEILING);

        console.log("GAS|reportScores firstTouchOfWeek", g);
    }

    // ---- Cell 3: reportScores same-week repeat (warm tail update) ----

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

    // ---- Cell 4: deliverCrumbs single week single word ----

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

    // ---- Cell 5: deliverGap marginal per-week cost ----

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
}
