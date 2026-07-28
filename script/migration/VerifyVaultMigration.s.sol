// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";

/**
 * @dev Minimal view surface shared by the v2 vault and the diamond.
 */
interface IVaultViews {

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);

    function totalSupply()
        external
        view
        returns (uint256);

    function getTotalInterestUser(
        address _user
    )
        external
        view
        returns (uint256);

    function proxyBalance(
        address _user
    )
        external
        view
        returns (uint256);
}

/**
 * @title VerifyVaultMigration
 * @dev Read-only post-seed checker for the vault half of the v2 -> v3
 * migration (the queue half is covered by {VerifyQueMigration}). Runs
 * the holder sweep against the MINED state, per snapshot holder: the
 * diamond balance and proxy lock must equal the snapshot exactly, the
 * OLD vault's live balance must still equal the snapshot (drift since
 * the seed simulation aborts the gate), and `getTotalInterestUser`
 * must match the old vault within 1 wei (the seeded `cashedInterest`
 * was floored at the seed block, so the split accrual may round one
 * wei below the old vault's unbroken span).
 *
 * The escrow row (the v2 QueContract as it appears in the snapshot)
 * is checked separately, mirroring the seeding: it is skipped in the
 * holder sweep — the legacy vault freezes interest for its
 * InterestRateProxy while the diamond accrues, so the per-holder
 * comparison does not apply — and instead the diamond must hold
 * exactly the live escrow as its own balance, with total supply equal
 * to the snapshot sum outside the escrow row plus that escrow (i.e.
 * the v2 supply, conserved). Sends no transactions.
 *
 * Must run BETWEEN seeding and the old-vault takeover: once holders
 * are burned on the old vault its interest values freeze while the
 * diamond keeps accruing, and the comparison is void.
 *
 * Required env (no defaults — a missing value aborts):
 *   VAULT_PRODUCT, SEED_OLD_VAULT, SEED_QUE_ESCROW_HOLDER,
 *   SEED_BALANCE_FILE
 *
 * The snapshot is read through the same version-agnostic node parser
 * as the seeder: run via `forge script --ffi` with node on PATH.
 */
contract VerifyVaultMigration is VaultConfig {

    function run()
        external
    {
        vm.envString(
            "VAULT_PRODUCT"
        );

        address oldVault = vm.envAddress(
            "SEED_OLD_VAULT"
        );

        address escrowHolder = vm.envAddress(
            "SEED_QUE_ESCROW_HOLDER"
        );

        (
            address diamond,
        ) = _loadVault(
            _networkName()
        );

        (
            address[] memory holders,
            uint256[] memory balances,
            uint256[] memory proxyBalances
        ) = _readBalances(
            vm.envString(
                "SEED_BALANCE_FILE"
            )
        );

        uint256 total = _verifyHolders(
            diamond,
            oldVault,
            escrowHolder,
            holders,
            balances,
            proxyBalances
        );

        uint256 escrow = IVaultViews(oldVault).balanceOf(
            escrowHolder
        );

        require(
            IVaultViews(diamond).balanceOf(diamond) == escrow,
            "VerifyVaultMigration: diamond escrow mismatch"
        );

        require(
            IVaultViews(diamond).totalSupply() == total + escrow,
            "VerifyVaultMigration: total supply not conserved"
        );

        console2.log(
            "Vault holder parity verified between",
            oldVault,
            "and",
            diamond
        );

        console2.log("holders  ", holders.length);
        console2.log("escrow   ", escrow);
        console2.log("supply   ", total + escrow);
    }

    function _verifyHolders(
        address _diamond,
        address _oldVault,
        address _escrowHolder,
        address[] memory _holders,
        uint256[] memory _balances,
        uint256[] memory _proxyBalances
    )
        internal
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < _holders.length; i++) {

            address holder = _holders[i];

            if (holder == _escrowHolder) {
                continue;
            }

            require(
                IVaultViews(_oldVault).balanceOf(holder) == _balances[i],
                "VerifyVaultMigration: old vault drifted from snapshot"
            );

            require(
                IVaultViews(_diamond).balanceOf(holder) == _balances[i],
                "VerifyVaultMigration: balance mismatch"
            );

            require(
                IVaultViews(_diamond).proxyBalance(holder) == _proxyBalances[i],
                "VerifyVaultMigration: proxy balance mismatch"
            );

            uint256 diamondInterest = IVaultViews(_diamond).getTotalInterestUser(
                holder
            );

            uint256 oldInterest = IVaultViews(_oldVault).getTotalInterestUser(
                holder
            );

            require(
                _absDiff(
                    diamondInterest,
                    oldInterest
                ) <= 1,
                "VerifyVaultMigration: interest mismatch"
            );

            total += _balances[i];
        }
    }

    function _absDiff(
        uint256 _a,
        uint256 _b
    )
        internal
        pure
        returns (uint256)
    {
        return _a > _b
            ? _a - _b
            : _b - _a;
    }

    function _readBalances(
        string memory _balanceFile
    )
        internal
        returns (
            address[] memory addrs,
            uint256[] memory balances,
            uint256[] memory proxyBalances
        )
    {
        string[] memory cmd = new string[](3);
        cmd[0] = "node";
        cmd[1] = "tools/parse-balance-file.mjs";
        cmd[2] = _balanceFile;

        bytes memory raw = vm.ffi(
            cmd
        );

        (
            addrs,
            balances,
            proxyBalances
        ) = abi.decode(
            raw,
            (address[], uint256[], uint256[])
        );
    }
}
