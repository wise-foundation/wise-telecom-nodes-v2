// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {Script} from "forge-std/Script.sol";

import {WiseTelecomNodesQueueStructs} from "../../src/diamond/vault/WiseTelecomNodesQueueStructs.sol";
import {DiamondQueViewParity} from "../../test/migration/DiamondQueViewParity.sol";

/**
 * @title VerifyDiamondQueMigration
 * @notice Read-only post-seed queue-view parity checker for the v2 -> v3
 * DIAMOND migration. The legacy {VerifyQueMigration} script compares two
 * legacy QueContracts and asserts usdToken(), forwardVault() and the
 * public solveForAmountWithIncentive() wrapper as well, all three of which
 * the diamond intentionally does NOT expose (usdToken renamed USD_TOKEN,
 * que and vault unified into one contract, public solve wrapper dropped) -
 * so against a diamond it reverts on the first divergence and is the wrong
 * tool. This drives the diamond-aware {DiamondQueViewParity} sweep (the
 * same library proven byte-identical in the W2 fork test) against the LIVE
 * old que and the LIVE seeded diamond, closing the residual window between
 * the seed simulation and its inclusion. A revert names the first
 * mismatching view; logs success otherwise. Sends no transactions.
 *
 * Uses the BOUNDED sweep: it omits the getAllOrders* order-list views,
 * which walk id 0..earliestValid inside the contract - one lazy storage
 * fetch per slot against a remote diamond, impractical on high-domain legs
 * (arb-usdt inc=0 has earliestValid 11525). Every retained check touches
 * only the live linked list or a bounded slot set, so it stays fast live
 * on every leg. Pair it with the companion order-list byte-compare (a
 * single direct getAllOrdersOverall staticcall the node walks locally):
 *
 *   cast call $OLD_QUE "getAllOrdersOverall()" --rpc-url <net>
 *   cast call $DIAMOND  "getAllOrdersOverall()" --rpc-url <net>   # must be byte-identical
 *
 * getAllOrdersfromAddress equality follows, being a deterministic
 * member-filter of the same active-order set.
 *
 * Run immediately after the SeedVaultMigration broadcast:
 *
 *   OLD_QUE=<live old que> NEW_QUE=<seeded diamond> SEED_QUE_FILE=<snapshot> \
 *     forge script script/migration/VerifyDiamondQueMigration.s.sol:VerifyDiamondQueMigration \
 *     --rpc-url <mainnet|arbitrum> --ffi
 *
 * The snapshot member rows are read through the same version-agnostic node
 * parser as the seeder, so `node` must be on PATH and `--ffi` supplied.
 */
contract VerifyDiamondQueMigration is Script, WiseTelecomNodesQueueStructs {

    function run()
        external
    {
        address oldQue = vm.envAddress(
            "OLD_QUE"
        );

        address newQue = vm.envAddress(
            "NEW_QUE"
        );

        string memory queFile = vm.envString(
            "SEED_QUE_FILE"
        );

        QueMemberWithId[] memory members = _readQueMembers(
            queFile
        );

        DiamondQueViewParity.assertParityBounded(
            oldQue,
            newQue,
            members
        );

        console2.log(
            "Diamond que view parity (bounded) verified between",
            oldQue,
            "and",
            newQue
        );

        console2.log("members ", members.length);
    }

    function _readQueMembers(
        string memory _queFile
    )
        internal
        returns (
            QueMemberWithId[] memory members
        )
    {
        string[] memory cmd = new string[](4);
        cmd[0] = "node";
        cmd[1] = "tools/parse-que-state.mjs";
        cmd[2] = _queFile;
        cmd[3] = "members";

        bytes memory raw = vm.ffi(
            cmd
        );

        (
            int256[] memory incentive,
            uint256[] memory id,
            address[] memory member,
            uint256[] memory amount,
            uint256[] memory tailPointer,
            uint256[] memory headPointer
        ) = abi.decode(
            raw,
            (int256[], uint256[], address[], uint256[], uint256[], uint256[])
        );

        members = new QueMemberWithId[](
            id.length
        );

        for (uint256 i = 0; i < id.length; i++) {
            members[i] = QueMemberWithId({
                memberId: id[i],
                incentive: incentive[i],
                member: member[i],
                amount: amount[i],
                tailPointer: tailPointer[i],
                headPointer: headPointer[i]
            });
        }
    }
}
