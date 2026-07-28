// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.29;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ForwardVaultERC20Migratable} from "../../src/migration/ForwardVaultERC20Migratable.sol";
import {BalanceFileParser} from "../../test/helpers/BalanceFileParser.sol";
import {IForwarderV4} from "./RehearseEvacuationTestnet.s.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PrimeRehearsalEvacuation
 * @dev Broadcast 2 of the SPLIT testnet rehearsal. When the mock v2
 * system was stood up with `REHEARSAL_PRIME=false` (so the diamond
 * could be migration-seeded and parity-gated against the mock while
 * its holders still held), this script performs the deferred
 * takeover-and-prime exactly as the inline path would have: propose
 * the mock vault's ownership to the forwarder, accept it, mint EXTRA
 * sized from the LIVE buffer for a ~`REHEARSAL_TARGET_SECONDS`
 * crossing, and burn the migrated holders from the snapshot. The
 * real-time wait and `initiateEvacuation` remain with
 * `tools/rehearse-evacuation.ts`.
 *
 * NOT blindly re-runnable: once `acceptOwnerOldVault` has landed the
 * mock vault's master is the forwarder and a fresh `proposeOwner`
 * from the deployer reverts — finish a partial broadcast with forge's
 * `--resume`.
 *
 * Required env (no defaults — a missing value aborts):
 *   PRIVATE_KEY, REHEARSAL_MOCK_VAULT, REHEARSAL_FORWARDER,
 *   REHEARSAL_USD, REHEARSAL_BALANCE_FILE, REHEARSAL_TARGET_SECONDS
 */
contract PrimeRehearsalEvacuation is Script {

    uint256 constant SECONDS_PER_YEAR_SCALED = 157_700_000;

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        address mockVault = vm.envAddress(
            "REHEARSAL_MOCK_VAULT"
        );

        address forwarder = vm.envAddress(
            "REHEARSAL_FORWARDER"
        );

        address usd = vm.envAddress(
            "REHEARSAL_USD"
        );

        uint256 targetSeconds = vm.envUint(
            "REHEARSAL_TARGET_SECONDS"
        );

        require(
            targetSeconds > 0,
            "PrimeRehearsalEvacuation: target seconds is zero"
        );

        (
            address[] memory addrs,
            uint256[] memory balances,
        ) = BalanceFileParser.read(
            vm.envString(
                "REHEARSAL_BALANCE_FILE"
            )
        );

        require(
            address(ForwardVaultERC20Migratable(mockVault).USD_TOKEN()) == usd,
            "PrimeRehearsalEvacuation: REHEARSAL_USD is not the mock vault's USD token"
        );

        uint256 buffer = IERC20(usd).balanceOf(
            mockVault
        );

        require(
            buffer > 0,
            "PrimeRehearsalEvacuation: mock vault buffer is zero"
        );

        uint256 extra = buffer
            * SECONDS_PER_YEAR_SCALED
            / targetSeconds;

        console2.log("mock vault ", mockVault);
        console2.log("forwarder  ", forwarder);
        console2.log("usd        ", usd);
        console2.log("holders    ", addrs.length);

        vm.startBroadcast(
            privKey
        );

        ForwardVaultERC20Migratable(mockVault).proposeOwner(
            forwarder
        );

        IForwarderV4(forwarder).acceptOwnerOldVault();

        IForwarderV4(forwarder).mintSupply(
            extra
        );

        IForwarderV4(forwarder).burnSupplyBulk(
            addrs,
            balances
        );

        vm.stopBroadcast();

        console2.log(
            "REHEARSAL_BUFFER",
            buffer
        );

        console2.log(
            "REHEARSAL_EXTRA",
            extra
        );

        console2.log(
            "REHEARSAL_TMIN_SECONDS",
            targetSeconds
        );
    }
}
