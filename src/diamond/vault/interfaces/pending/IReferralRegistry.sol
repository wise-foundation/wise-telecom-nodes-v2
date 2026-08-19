// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Subset of the per-chain standalone {ReferralRegistry} surface
 * the vault reaches through the slot-74 `referralRegistry` pointer:
 * `assignReferrer` from the write-once referral deposit path
 * ({ReferralFacetBase}, plain CALL — registry reverts bubble into
 * the deposit) and `referrerOf` from the cohort recorder's guarded
 * staticcall seam ({CohortRecorderBase}), the routed {ReferralFacet}
 * view getter and the pointer shape probe. The
 * same-chain move-carry mailbox pair: `stageCarry` from the source
 * vault's move-out capture and `consumeCarry` from the destination's
 * move-in replant — both reached ONLY through failure-tolerant
 * guarded CALLs ({CohortRecorderBase}), so registry reverts degrade
 * to attribution loss and never block the move. The registry's
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
}
