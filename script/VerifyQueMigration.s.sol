// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {QueContract} from "../src/legacy/que/QueContractLegacy.sol";
import {QueParityVerifier} from "../test/helpers/QueParityVerifier.sol";

/**
 * @notice Read-only post-broadcast checker for the MoneyForward queue
 * migration. The deploy scripts run their parity checks in the
 * pre-broadcast simulation; this script re-runs the full old-vs-new view
 * parity sweep against the MINED contracts at the latest block, closing
 * the residual window between simulation and transaction inclusion.
 *
 * Run immediately after the MoneyForwardDeployer broadcast:
 *
 *   OLD_QUE=<live old que> NEW_QUE=<freshly deployed que> \
 *     forge script script/VerifyQueMigration.s.sol --rpc-url <mainnet|arbitrum>
 *
 * Reverts with a QueParityVerifier message naming the first mismatching
 * view if the migrated state diverged (e.g. a join/leave landed on the old
 * que between simulation and inclusion); logs success otherwise. Sends no
 * transactions.
 */
contract VerifyQueMigration is Script {

    function run()
        external
        view
    {
        address oldQue = vm.envAddress(
            "OLD_QUE"
        );

        address newQue = vm.envAddress(
            "NEW_QUE"
        );

        QueParityVerifier.verifyNewQueMatchesLiveOldQue(
            QueContract(oldQue),
            QueContract(newQue)
        );

        console2.log(
            "Que view parity verified between",
            oldQue,
            "and",
            newQue
        );
    }
}
