// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Vm.sol";

/**
 * @title QueStateParser
 * @dev Reads the txt files produced by tools/fetch-que-state.ts via vm.ffi.
 * The off-chain helper at tools/parse-que-state.ts reads the txt and emits
 * abi-encoded chunks on stdout based on a section argument:
 *   - "block"    → (uint256 block)
 *   - "summary"  → (uint256 totalActive, bool negNotAllowed, uint256 minDeposit)
 *   - "pointers" → (int256[] incentives, uint256[] earliest, uint256[] current,
 *                   uint256[] active, bool[] allowed)
 *   - "members"  → (int256[] incentive, uint256[] id, address[] member,
 *                   uint256[] amount, uint256[] tail, uint256[] head)
 *
 * Format produced by fetch-que-state.ts:
 *   Block:
 *   <num>
 *   TotalActiveOrders:
 *   <num>
 *   NegativeIncentivesNotAllowed:
 *   <true|false>
 *   MinDepositAmount:
 *   <num>
 *   Incentives:
 *   [100,200,...,-5000]
 *   EarliestValid:
 *   [...]
 *   CurrentOrderId:
 *   [...]
 *   ActiveOrderCount:
 *   [...]
 *   IncentiveAllowed:
 *   [...]
 *   QueMembers:
 *   <incentive>|<id>|<member>|<amount>|<tail>|<head>
 *   ...
 */
library QueStateParser {

    Vm constant vm = Vm(
        address(
            uint160(
                uint256(
                    keccak256(
                        "hevm cheat code"
                    )
                )
            )
        )
    );

    function readBlock(
        string memory _path
    )
        internal
        returns (uint256 blockNumber)
    {
        bytes memory raw = _ffi(_path, "block");
        (blockNumber) = abi.decode(
            raw,
            (uint256)
        );
    }

    function readSummary(
        string memory _path
    )
        internal
        returns (
            uint256 totalActive,
            bool    negNotAllowed,
            uint256 minDeposit
        )
    {
        bytes memory raw = _ffi(_path, "summary");
        (totalActive, negNotAllowed, minDeposit) = abi.decode(
            raw,
            (uint256, bool, uint256)
        );
    }

    function readPointers(
        string memory _path
    )
        internal
        returns (
            int256[]  memory incentives,
            uint256[] memory earliestValid,
            uint256[] memory currentOrderId,
            uint256[] memory activeOrderCount,
            bool[]    memory allowed
        )
    {
        bytes memory raw = _ffi(_path, "pointers");
        (
            incentives,
            earliestValid,
            currentOrderId,
            activeOrderCount,
            allowed
        ) = abi.decode(
            raw,
            (int256[], uint256[], uint256[], uint256[], bool[])
        );

        require(
            incentives.length == earliestValid.length &&
            incentives.length == currentOrderId.length &&
            incentives.length == activeOrderCount.length &&
            incentives.length == allowed.length,
            "QueStateParser: pointers length mismatch"
        );
    }

    function readMembers(
        string memory _path
    )
        internal
        returns (
            int256[]  memory incentive,
            uint256[] memory id,
            address[] memory member,
            uint256[] memory amount,
            uint256[] memory tailPointer,
            uint256[] memory headPointer
        )
    {
        bytes memory raw = _ffi(_path, "members");
        (
            incentive,
            id,
            member,
            amount,
            tailPointer,
            headPointer
        ) = abi.decode(
            raw,
            (int256[], uint256[], address[], uint256[], uint256[], uint256[])
        );

        require(
            incentive.length == id.length &&
            incentive.length == member.length &&
            incentive.length == amount.length &&
            incentive.length == tailPointer.length &&
            incentive.length == headPointer.length,
            "QueStateParser: members length mismatch"
        );
    }

    function _ffi(
        string memory _path,
        string memory _section
    )
        private
        returns (bytes memory)
    {
        string[] memory cmd = new string[](4);
        cmd[0] = "node";
        cmd[1] = "tools/parse-que-state.mjs";
        cmd[2] = _path;
        cmd[3] = _section;
        return vm.ffi(cmd);
    }
}
