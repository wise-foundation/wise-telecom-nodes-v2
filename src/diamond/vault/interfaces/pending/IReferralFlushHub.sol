// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Reporter subset of the mainnet referral hub, used only by the
 * {CohortFlushFacet}'s LOCAL delivery mode: when the flush-hub
 * pointer carries a zero chain selector the hub lives on this chain,
 * and the facet delivers scores, crumb words and gap records by
 * direct call instead of a CCIP envelope — the vault itself is the
 * allowed reporter, so the hub keys the data under the local
 * address-derived source key and no envelope, deliverer stamp or
 * designation word exists on this path (on the hub's own chain
 * referrers designate at the hub directly). Reverts bubble into the
 * flushing transaction on purpose: a local delivery that cannot land
 * must never be silently dropped.
 */
interface IReferralFlushHub {

    function reportScores(
        address _referrer,
        uint256 _referredScore,
        uint256 _selfScore
    )
        external;

    function deliverCrumbs(
        address _referrer,
        uint256[] calldata _weeks,
        uint256[] calldata _words
    )
        external;

    function deliverGap(
        address _referrer,
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks
    )
        external;
}
