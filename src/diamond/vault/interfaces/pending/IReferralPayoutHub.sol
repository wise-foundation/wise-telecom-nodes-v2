// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

/**
 * @dev Vault-facing subset of the mainnet referral hub, used only by
 * the payout-hub pointer's execute-time shape probe: `USD_TOKEN()`
 * must return exactly 32 bytes decoding to this vault's own USD
 * token, so a hub built for a different asset — or any unrelated
 * contract — cannot be wired. The probe staticcall is guarded at
 * the call site ({WiseTelecomNodesBaseHelper._probePayoutHub}):
 * failures and wrong shapes return false and the execute reverts
 * {InvalidValue}; nothing bubbles.
 */
interface IReferralPayoutHub {

    function USD_TOKEN()
        external
        view
        returns (address);
}
