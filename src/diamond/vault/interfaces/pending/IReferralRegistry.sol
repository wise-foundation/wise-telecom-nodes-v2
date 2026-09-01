// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Subset of the per-chain standalone {ReferralRegistry} surface
 * the vault reaches through the slot-77 `referralRegistry` pointer:
 * `assignReferrer` from the write-once referral deposit path
 * ({ReferralFacetBase}, plain CALL — registry reverts bubble into
 * the deposit) and `referrerOf` from the routed {ReferralFacet}
 * view getter and the pointer shape probe. The cohort recorder's
 * guarded staticcall seam resolves `effectiveReferrerOf` instead —
 * the flip-aware read that answers the OLD referrer for this vault
 * while a cross-chain referrer flip awaits its book migration, so
 * every clamp keeps reducing the book that actually holds the cover.
 * The same-chain move-carry mailbox pair: `stageCarry` from the
 * source vault's move-out capture and `consumeCarry` from the
 * destination's move-in replant — both reached ONLY through
 * failure-tolerant guarded CALLs ({CohortRecorderBase}), so registry
 * reverts degrade to attribution loss and never block the move. The
 * cross-chain bridge carry adds `getReferrerPair` (the origin sync
 * key packed into the outbound bridge payload) and `mergeReferrer`
 * (the earliest-assignment merge applied on arrival) — the merge is
 * a guarded CALL too, and a failed merge only means the local answer
 * stands. The flush transport adds `getPayoutDesignation` — the
 * {CohortFlushFacet} reads a referrer's own-chain payout designation
 * through a guarded staticcall at envelope build time (the
 * designation piggyback word), and a failed or unset read only means
 * the envelope carries no designation. The retroactive seed adds
 * `correctionsLatched` — {CohortRecorderFacet}'s master-only
 * `seedCohortContribution` reverts once the registry's one-way
 * correction latch has fired, so a single per-chain latch ends every
 * master attribution power (corrections AND seeds) the moment payouts
 * arm; this read is a plain interface call on purpose — an unset or
 * unreachable registry makes seeding loudly impossible rather than
 * silently permitted. The registry's master/allowlist
 * admin surface is deliberately absent — it is operated directly on
 * the registry, never through the diamonds.
 */
interface IReferralRegistry {

    function assignReferrer(
        address _user,
        address _referrer
    )
        external;

    function referrerOf(
        address _user
    )
        external
        view
        returns (address);

    function effectiveReferrerOf(
        address _user,
        address _vault
    )
        external
        view
        returns (address);

    function getReferrerPair(
        address _user
    )
        external
        view
        returns (
            address referrer,
            uint256 assignedAt,
            uint256 rank
        );

    function mergeReferrer(
        address _user,
        address _referrer,
        uint256 _assignedAt,
        uint256 _rank
    )
        external;

    function stageCarry(
        address _dstVault,
        address _user,
        uint256[] calldata _payload
    )
        external;

    function consumeCarry(
        address _srcVault,
        address _user
    )
        external
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        );

    function getPayoutDesignation(
        address _owner
    )
        external
        view
        returns (
            address payout,
            uint256 stamp
        );

    function correctionsLatched()
        external
        view
        returns (bool);
}
