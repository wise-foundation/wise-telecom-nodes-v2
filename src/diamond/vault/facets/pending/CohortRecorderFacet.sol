// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";
import {IReferralRegistry} from "../../interfaces/pending/IReferralRegistry.sol";

/**
 * @dev CohortRecorderFacet: the routed public surface of the cohort
 * recorder: two permissionless mutations, the registry-only flip
 * entrance, the master-only retroactive seed, and the view set the
 * cohort test suites, keepers and
 * offchain monitoring read. The mutations do NOT carry engine code:
 * they bounce through the helper-chain stubs into an engine slice
 * ({CohortHookFacet} via the `transferHookFacet` pointer for
 * `syncReferee`/`advanceBook`, the dispatcher-routed
 * {CohortBridgeHookFacet} for `receiveReferrerFlip`), so routed path
 * and hook path can never diverge. The two permissionless mutations
 * are gated no-ops while `cohortSyncEnabled` is false: on a live
 * diamond with virgin tail storage this facet reads zeros and mutates
 * nothing; the flip entrance instead reverts while disarmed, see
 * below.
 *
 * `syncReferee` is the permissionless clamp poke (grief-safe: the
 * clamp is one-way and idempotent, a no-op unless the user's balance
 * is below their tracked contribution). `advanceBook` lets anyone
 * pre-walk a dormant referrer book in bounded chunks so the transfer
 * hook path stays cheap in practice. Views decode the
 * packed lanes via {CohortWeeks}; the referrer score is
 * definitionally the book lane sum, so `getCohortScore` cannot desync
 * from `getCohortBook`. Installed post-launch only, via the
 * `cohortRecorderSelectors()` group in the upgrade script, never by
 * the frozen genesis deploys.
 *
 * `receiveReferrerFlip` is the registry's one entrance for the
 * cross-chain referrer-flip migration: only the slot-77 registry may
 * call it, and it deliberately REVERTS while the recorder is disarmed:
 * the registry's poke machinery treats a revert as "defer and
 * retry", restoring the pending-flip marker, so a flip ordered before
 * arming is never silently dropped. The migration relocates the
 * user's local book credit from the old to the new referrer at
 * identical ring coordinates in one transaction, clamping against the
 * OLD referrer first so a lazy deficit is destroyed sale-like and can
 * never launder into new-referrer credit.
 *
 * `seedCohortContribution` is the master-only retroactive
 * attribution entrance: it credits a user's pre-existing,
 * not-yet-tracked balance exactly as if that amount were deposited
 * in this instant (the SAME engine slice through the SAME credit
 * stub), so the credit lands in the current-week ring slot, ages from
 * now, and earns no retroactive crumb time. The clamp stub runs
 * FIRST and the credit is bounded by `min(amount, balance -
 * tracked)`, so a seed can never push tracked contribution above the
 * held balance and every recorder invariant survives structurally
 * (`type(uint256).max` means "seed the full headroom"). A degraded
 * clamp (the registry lookup failing inside the sync while a lazy
 * deficit stands) leaves tracked above held and the seed reverts
 * {NothingToSeed} instead of mis-crediting. There is deliberately NO
 * assignment carve-out: the referrer is resolved through the normal
 * flip-aware seam inside the engine credit, write-once assignment
 * stays with the deposit entrypoints, and seeding an unreferred user
 * backfills only their own self-stake ladder input (assign first via
 * a normal referred deposit, then seed, to credit a referrer). The
 * whole entrance dies with the registry's one-way correction latch
 * (a single per-chain switch ends every master attribution power,
 * corrections AND seeds, the moment payouts arm) and reverts,
 * never a silent no-op: named guard errors cover the disarmed
 * state and the zeroed slot-45 hook pointer (the armed-but-hookless
 * state the timelock permits; the stubs would silently skip there),
 * and a plain call failure covers an unset or codeless registry
 * pointer. Headroom is ANY untracked balance:
 * the recorder cannot distinguish a pre-arming deposit from a
 * balance received by transfer after a sender's one-way credit
 * destroy, so which headroom deserves seeding is master POLICY;
 * the permissionless flows keep the destroy-never-recredit rule
 * intact, and the latch bounds the discretion window.
 */
contract CohortRecorderFacet is FacetBase {

    function syncReferee(
        address _user
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        _cohortSync(
            _user
        );
    }

    function receiveReferrerFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        require(
            msg.sender == referralRegistry,
            NotReferralRegistry()
        );

        require(
            cohortSyncEnabled,
            CohortSyncDisabled()
        );

        _cohortFlip(
            _user,
            _oldReferrer,
            _newReferrer
        );
    }

    function advanceBook(
        address _referrer,
        uint256 _maxBoundaries
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        _cohortAdvance(
            _referrer,
            _maxBoundaries
        );
    }

    function seedCohortContribution(
        address _user,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        require(
            cohortSyncEnabled,
            CohortSyncDisabled()
        );

        require(
            transferHookFacet != ZERO_ADDRESS,
            CohortHookNotInstalled()
        );

        require(
            IReferralRegistry(referralRegistry).correctionsLatched() == false,
            SeedingLatched()
        );

        _cohortSync(
            _user
        );

        uint256 tracked = trackedContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        require(
            held > tracked,
            NothingToSeed()
        );

        uint256 delta = held - tracked;

        if (_amount < delta) {
            delta = _amount;
        }

        require(
            delta > 0,
            NothingToSeed()
        );

        _cohortCredit(
            _user,
            delta
        );

        emit CohortContributionSeeded(
            _user,
            delta
        );
    }

    function getCohortSyncEnabled()
        external
        view
        returns (bool)
    {
        return cohortSyncEnabled;
    }

    function getTrackedContribution(
        address _user
    )
        external
        view
        returns (uint256)
    {
        return trackedContribution[_user];
    }

    function getCohortBook(
        address _referrer
    )
        external
        view
        returns (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettleTimestamp
        )
    {
        uint256 book = cohortBook[_referrer];

        return (
            CohortWeeks.laneY1(book),
            CohortWeeks.laneY2(book),
            CohortWeeks.laneM(book),
            cohortLastSettle[_referrer]
        );
    }

    function getCohortScore(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        uint256 book = cohortBook[_referrer];

        return CohortWeeks.laneY1(book)
            + CohortWeeks.laneY2(book)
            + CohortWeeks.laneM(book);
    }

    function getCohortRings(
        address _referrer
    )
        external
        view
        returns (
            uint64[52] memory year1,
            uint64[52] memory year2
        )
    {
        return (
            cohortRingYear1[_referrer],
            cohortRingYear2[_referrer]
        );
    }

    function getCohortWeekCrumb(
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (uint256)
    {
        return cohortWeekLog[_referrer][_week];
    }

    function getCohortGapLogLength(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return cohortGapLog[_referrer].length;
    }

    function getCohortGapLogEntry(
        address _referrer,
        uint256 _index
    )
        external
        view
        returns (uint256)
    {
        return cohortGapLog[_referrer][_index];
    }
}
