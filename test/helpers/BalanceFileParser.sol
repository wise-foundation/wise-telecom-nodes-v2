// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Vm.sol";

/**
 * @title BalanceFileParser
 * @dev Reads the txt files produced by tools/fetch-balances.ts via vm.ffi.
 * The off-chain helper at tools/parse-balance-file.ts reads the txt and
 * emits abi.encode(address[], uint256[], uint256[]) on stdout, which we
 * decode here.
 *
 * Format produced by fetch-balances.ts:
 *   Block:
 *   <num>
 *   Addresses:
 *   [0xaaa,0xbbb,...]
 *   Balances:
 *   [123,456,...]
 *   ProxyBalances:
 *   [...]
 *   CashedInterest:
 *   [...]
 *   PendingInterest:
 *   [...]
 *   TotalInterest:
 *   [...]
 *
 * Only Addresses + Balances + ProxyBalances are decoded into Solidity here;
 * the interest sections are diagnostic and consumed by manual review.
 */
library BalanceFileParser {

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

    function read(
        string memory _path
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
        cmd[2] = _path;

        bytes memory raw = vm.ffi(
            cmd
        );

        (addrs, balances, proxyBalances) = abi.decode(
            raw,
            (address[], uint256[], uint256[])
        );

        require(
            addrs.length == balances.length,
            "BalanceFileParser: addr/bal length mismatch"
        );

        require(
            addrs.length == proxyBalances.length,
            "BalanceFileParser: addr/proxy length mismatch"
        );

        require(
            addrs.length > 0,
            "BalanceFileParser: empty file"
        );
    }
}
