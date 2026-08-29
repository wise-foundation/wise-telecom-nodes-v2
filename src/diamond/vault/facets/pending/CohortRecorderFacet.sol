// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "../FacetBase.sol";
import {CohortWeeks} from "../../../shared/pending/CohortWeeks.sol";

/**
 * @dev CohortRecorderFacet — the routed public surface of the cohort
 * recorder: two permissionless mutations, the registry-only flip
 * entrance, and the view set the cohort test suites, keepers and
 * offchain monitoring read. The mutations do NOT carry engine code:
 * they bounce through the helper-chain stubs into an engine slice
 * ({CohortHookFacet} via the `transferHookFacet` pointer for
 * `syncReferee`/`advanceBook`, the dispatcher-routed
 * {CohortBridgeHookFacet} for `receiveReferrerFlip`), so routed path
 * and hook path can never diverge. The two permissionless mutations
 * are gated no-ops while `cohortSyncEnabled` is false — on a live
 * diamond with virgin tail storage this facet reads zeros and mutates
 * nothing; the flip entrance instead reverts while disarmed, see
 * below.
 *
 * `syncReferee` is the permissionless clamp poke (grief-safe: the
 * clamp is one-way and idempotent — a no-op unless the user's balance
 * is below their tracked contribution). `advanceBook` lets anyone
 * pre-walk a dormant referrer book in bounded chunks so the transfer
 * hook path stays cheap in practice. Views decode the
 * packed lanes via {CohortWeeks}; the referrer score is
 * definitionally the book lane sum, so `getCohortScore` cannot desync
 * from `getCohortBook`. Installed post-launch only, via the
 * `cohortRecorderSelectors()` group in the upgrade script — never by
 * the frozen genesis deploys.
 *
 * `receiveReferrerFlip` is the registry's one entrance for the
 * cross-chain referrer-flip migration: only the slot-77 registry may
 * call it, and it deliberately REVERTS while the recorder is disarmed
 * — the registry's poke machinery treats a revert as "defer and
 * retry", restoring the pending-flip marker, so a flip ordered before
 * arming is never silently dropped. The migration relocates the
 * user's local book credit from the old to the new referrer at
 * identical ring coordinates in one transaction, clamping against the
 * OLD referrer first so a lazy deficit is destroyed sale-like and can
 * never launder into new-referrer credit.
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
