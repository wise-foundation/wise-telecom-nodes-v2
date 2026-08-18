// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralRegistryDeclarations} from "./ReferralRegistryDeclarations.sol";
import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";

/**
 * @dev The Phase-1 per-chain referral registry — ONE standalone
 * deployed contract closing the chain over
 * {ReferralRegistryDeclarations}. `assignReferrer` is the single
 * write path: allowlisted vaults forward `(user, referrer)` from
 * their referral deposit entrypoints (and, in Phase 5, from the
 * bridge-receive carry-set), and this contract alone enforces the
 * R1 semantics — zero rejected, self rejected, first assignment
 * sticks forever, later different referrers silently ignored, event
 * only on the actual first-set transition. Validation runs BEFORE
 * the write-once check so a zero/self referrer reverts even for an
 * already-assigned user, preserving the vault-side revert priority
 * pinned since develop-02. The hardening pair rejects the calling
 * vault and this registry as referrers so cohort credit can never be
 * laundered into system addresses. `assignReferrer` performs a pure
 * storage write plus event and makes NO external call — the vaults'
 * reentrancy reasoning relies on this staying true.
 *
 * `setAllowedVault` is the master kill-switch for NEW assignments
 * from one vault; it is deliberately instant (no timelock) and
 * deliberately asymmetric: reads stay permissionless, so a revoked
 * vault's cohort recorder keeps resolving existing referrers and
 * only fresh `...WithReferral` deposits on that vault revert.
 */
contract ReferralRegistry is ReferralRegistryDeclarations {

    modifier onlyAllowedVault() {
        require(
            allowedVault[msg.sender],
            NotAllowedVault()
        );
        _;
    }

    constructor()
        OwnableMaster(
            msg.sender
        )
    {}

    function assignReferrer(
        address _user,
        address _referrer
    )
        external
        onlyAllowedVault
    {
        require(
            _user != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _referrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _referrer != _user,
            SelfReferral()
        );

        require(
            _referrer != msg.sender,
            InvalidReferrer()
        );

        require(
            _referrer != address(this),
            InvalidReferrer()
        );

        if (referrerOf[_user] != ZERO_ADDRESS) {
            return;
        }

        referrerOf[_user] = _referrer;

        emit ReferralAssigned(
            _user,
            _referrer,
            msg.sender
        );
    }

    function setAllowedVault(
        address _vault,
        bool _allowed
    )
        external
        onlyMaster
    {
        require(
            _vault != ZERO_ADDRESS,
            ZeroAddress()
        );

        allowedVault[_vault] = _allowed;

        emit VaultAllowedSet(
            _vault,
            _allowed
        );
    }
}
