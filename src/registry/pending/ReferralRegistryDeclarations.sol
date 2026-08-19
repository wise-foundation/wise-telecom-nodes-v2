// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";

/**
 * @dev Storage, events and errors for the per-chain referral
 * registry — ONE standalone contract per chain,
 * the single source of referrer truth for every WiseTelecomNodes
 * vault on that chain; the diamonds' slot-64 `referrerOf` mapping
 * stays declared but forever virgin. Never a facet, never
 * delegatecalled, so this chain owns its layout outright and
 * `check_storage_layout.sh` deliberately does not cover it. Inherits
 * {OwnableMaster} (slots 0-1) as the house two-step ownership base.
 *
 * Threat model: assignments enter ONLY through `allowedVault`
 * (master-gated allowlist — the single trust boundary; at most the
 * chain's up-to-three CREATE3 diamonds, whose addresses repeat across
 * chains but never collide inside one chain's registry). Write-once
 * is enforced HERE, atomically with the write, so no writer — however
 * buggy — can ever displace or clear an existing assignment, and two
 * vaults racing in one block resolve first-write-wins with the loser
 * silently ignored. Master governs only the allowlist and its own
 * succession; NO admin path touches `referrerOf`, making every
 * assignment immutable against master too — no correction path
 * exists, by design. Reads are permissionless and the
 * `referrerOf` auto-getter must remain a plain mapping read forever —
 * the vaults' cohort recorder staticcalls it inside the transfer
 * hook's revert-free budget; never add logic,
 * gating or reverts to the read path. The already-assigned early
 * return in `assignReferrer` is deliberately the sticky-referrer
 * rule: when a future bridge-receive carry-set assigns a carried
 * referrer, an existing local assignment wins by construction.
 *
 * Carry staging: same-chain `moveBetweenVaults`
 * attribution payloads stage here behind the SAME allowlist — slots
 * 4-5 hold `carryPayload`/`carryStagedAt` keyed
 * `[srcVault][dstVault][user]`, written by `stageCarry`
 * (delete-then-write, stamps `block.timestamp`) and drained by
 * `consumeCarry` (read + delete, deliberately NOT idempotent — a
 * payload is deliverable at most once). The registry never interprets
 * payload words (codec lives in the vaults' CohortWeeks library);
 * staleness is the DESTINATION's check (`stagedAt` must equal its own
 * `block.timestamp` — stage and consume are synchronous inside one
 * move transaction, so any orphan from a not-yet-carry-aware
 * destination is structurally inert and simply overwritten by the
 * next move on the same key). Both carry functions are pure storage
 * plus event with NO external calls, extending the `assignReferrer`
 * posture; the `referrerOf` read path is untouched. Consequence of
 * reusing the allowlist: `setAllowedVault(vault, false)` now also
 * soft-disables that vault's carry staging and consuming — the
 * vaults reach both functions through failure-tolerant guarded CALLs,
 * so a revoked vault's moves still succeed and only the attribution
 * degrades (anomaly event vault-side). The registry is NEVER
 * repointed once a vault's cohort recorder is armed against it.
 */
abstract contract ReferralRegistryDeclarations is OwnableMaster {

    // ---- Referrer book ----

    mapping(address => address) public referrerOf;

    // ---- Writer allowlist ----

    mapping(address => bool) public allowedVault;

    // ---- Move-carry staging ----

    mapping(address => mapping(address => mapping(address => uint256[]))) internal carryPayload;

    mapping(address => mapping(address => mapping(address => uint256))) internal carryStagedAt;

    // ---- Events ----

    event ReferralAssigned(
        address indexed user,
        address indexed referrer,
        address indexed vault
    );

    event VaultAllowedSet(
        address indexed vault,
        bool allowed
    );

    event CarryStaged(
        address indexed srcVault,
        address indexed dstVault,
        address indexed user,
        uint256 words
    );

    event CarryConsumed(
        address indexed srcVault,
        address indexed dstVault,
        address indexed user,
        uint256 stagedAt
    );

    // ---- Errors ----

    error NotAllowedVault();

    error ZeroAddress();

    error SelfReferral();

    error InvalidReferrer();

    error CarryPayloadInvalid();
}
