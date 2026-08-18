// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Subset of the per-chain standalone {ReferralRegistry} surface
 * the vault reaches through the slot-74 `referralRegistry` pointer:
 * `assignReferrer` from the write-once referral deposit path
 * ({ReferralFacetBase}, plain CALL — registry reverts bubble into
 * the deposit) and `referrerOf` from the cohort recorder's guarded
 * staticcall seam ({CohortRecorderBase}), the routed {ReferralFacet}
 * view getter and the pointer shape probe. The registry's
 * master/allowlist admin surface is deliberately absent — it is
 * operated directly on the registry, never through the diamonds.
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
}
