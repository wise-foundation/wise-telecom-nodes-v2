// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";

/**
 * @dev Storage, events and errors for the Phase-1 per-chain referral
 * registry (docs/referral-commission-implementation-plan.md §4
 * Phase 1, rulings R1/R13/R19) — ONE standalone contract per chain,
 * the single source of referrer truth for every WiseTelecomNodes
 * vault on that chain; the diamonds' slot-64 `referrerOf` mapping
 * stays declared but forever virgin (R19). Never a facet, never
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
 * assignment immutable against master too (open ruling O8 records
 * that no correction path exists). Reads are permissionless and the
 * `referrerOf` auto-getter must remain a plain mapping read forever —
 * the vaults' cohort recorder staticcalls it inside the transfer
 * hook's revert-free budget (plan invariant I6); never add logic,
 * gating or reverts to the read path. The already-assigned early
 * return in `assignReferrer` is deliberately the R8 sticky-referrer
 * rule: when the Phase-5 bridge-receive carry-set assigns a carried
 * referrer, an existing local assignment wins by construction.
 * Phase-3 seam (documented only, no code): same-chain
 * `moveBetweenVaults` flush staging appends new storage and
 * vault-called surface behind this same allowlist, extending this
 * contract in place — the registry is NEVER repointed once a vault's
 * cohort recorder is armed against it.
 */
abstract contract ReferralRegistryDeclarations is OwnableMaster {

    // ---- Referrer book ----

    mapping(address => address) public referrerOf;

    // ---- Writer allowlist ----

    mapping(address => bool) public allowedVault;

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

    // ---- Errors ----

    error NotAllowedVault();

    error ZeroAddress();

    error SelfReferral();

    error InvalidReferrer();
}
