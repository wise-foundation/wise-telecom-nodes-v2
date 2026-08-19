// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralRegistryDeclarations} from "./ReferralRegistryDeclarations.sol";
import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";

/**
 * @dev The per-chain referral registry — ONE standalone
 * deployed contract closing the chain over
 * {ReferralRegistryDeclarations}. `assignReferrer` is the single
 * write path: allowlisted vaults forward `(user, referrer)` from
 * their referral deposit entrypoints (and, once cross-chain carry
 * ships, from the bridge-receive carry-set), and this contract alone
 * enforces the assignment semantics — zero rejected, self rejected,
 * first assignment sticks forever, later different referrers
 * silently ignored, event only on the actual first-set transition.
 * Validation runs BEFORE the write-once check so a zero/self
 * referrer reverts even for an already-assigned user, preserving
 * the vaults' revert priority. The hardening pair rejects the calling
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
 *
 * Carry staging: `stageCarry`/`consumeCarry` are the
 * same-chain move-attribution mailbox (threat model and lifecycle in
 * the declarations block). `stageCarry`'s guards are guard-class only
 * — reachable solely through a buggy allowlisted vault, since the
 * vaults construct payloads from their own storage: nonzero
 * endpoints, no self-destination, payload length within
 * `(0, MAX_CARRY_WORDS]`. `consumeCarry` is deliberately guard-free:
 * an empty key returns an empty payload, the natural answer, and the
 * destination's `stagedAt == block.timestamp` check rejects
 * everything else. Consume keys the destination as `msg.sender`, so
 * a rogue allowlisted vault can only ever drain payloads addressed
 * to itself.
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

    function stageCarry(
        address _dstVault,
        address _user,
        uint256[] calldata _payload
    )
        external
        onlyAllowedVault
    {
        require(
            _dstVault != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _user != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            _dstVault != msg.sender,
            CarryPayloadInvalid()
        );

        require(
            _payload.length > 0,
            CarryPayloadInvalid()
        );

        require(
            _payload.length <= CohortWeeks.MAX_CARRY_WORDS,
            CarryPayloadInvalid()
        );

        delete carryPayload[msg.sender][_dstVault][_user];

        carryPayload[msg.sender][_dstVault][_user] = _payload;

        carryStagedAt[msg.sender][_dstVault][_user] = block.timestamp;

        emit CarryStaged(
            msg.sender,
            _dstVault,
            _user,
            _payload.length
        );
    }

    function consumeCarry(
        address _srcVault,
        address _user
    )
        external
        onlyAllowedVault
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        stagedAt = carryStagedAt[_srcVault][msg.sender][_user];

        if (stagedAt == 0) {
            return (
                0,
                payload
            );
        }

        payload = carryPayload[_srcVault][msg.sender][_user];

        delete carryPayload[_srcVault][msg.sender][_user];

        delete carryStagedAt[_srcVault][msg.sender][_user];

        emit CarryConsumed(
            _srcVault,
            msg.sender,
            _user,
            stagedAt
        );
    }

    function getCarry(
        address _srcVault,
        address _dstVault,
        address _user
    )
        external
        view
        returns (
            uint256 stagedAt,
            uint256[] memory payload
        )
    {
        stagedAt = carryStagedAt[_srcVault][_dstVault][_user];

        payload = carryPayload[_srcVault][_dstVault][_user];
    }
}
