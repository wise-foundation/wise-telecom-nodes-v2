// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev The one call the registry makes into a vault during a
 * referrer-flip migration: relocate the user's local book credit from
 * the old to the new referrer. The vault reverts while its cohort
 * recorder is disarmed, which the registry treats as "defer and
 * retry later" — the pending-flip marker is restored and the
 * migration stays poke-able forever.
 */
interface IVaultCohortFlip {

    function receiveReferrerFlip(
        address _user,
        address _oldReferrer,
        address _newReferrer
    )
        external;
}
