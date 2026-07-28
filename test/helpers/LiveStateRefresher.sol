// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Vm.sol";

/**
 * @title LiveStateRefresher
 * @dev Re-fetches the data/*.txt holder-balance and que-state snapshots
 * from the live chains via tools/refresh-live-state.mjs before a fork
 * test runs, so the tests always replay the newest state. The wrapper
 * throttles to one fetch per REFRESH_MAX_AGE_MINUTES (default 30) via
 * the gitignored data/.last-refresh marker and serializes concurrent
 * forge suites through a data/.refresh-lock directory, letting all test
 * entry points in one forge run share a single fetch.
 *
 * Status word returned on stdout:
 *   0 = snapshots already fresh, fetch skipped
 *   1 = snapshots refreshed from live chain
 *   2 = refresh unavailable (no ETHERSCAN_KEY or SKIP_LIVE_REFRESH=1),
 *       committed snapshots used as fallback
 *
 * A failed fetch exits non-zero, which reverts the calling test instead
 * of silently running on stale data.
 */
library LiveStateRefresher {

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

    uint256 internal constant STATUS_FRESH = 0;
    uint256 internal constant STATUS_REFRESHED = 1;
    uint256 internal constant STATUS_FALLBACK = 2;

    function refresh()
        internal
        returns (uint256 status)
    {
        string[] memory cmd = new string[](2);
        cmd[0] = "node";
        cmd[1] = "tools/refresh-live-state.mjs";

        (status) = abi.decode(
            vm.ffi(cmd),
            (uint256)
        );

        require(
            status <= STATUS_FALLBACK,
            "LiveStateRefresher: bad status"
        );
    }

    /**
     * @dev Proves a data/que_state_*.txt snapshot matches the LIVE
     * QueContract at the snapshot's pinned block, via
     * tools/verify-que-live.mjs: the full id domain is re-walked with
     * batched multicalls directly against the RPC and the regenerated
     * canonical file text is byte-compared with the on-disk file. A
     * handful of RPC round trips replaces the per-slot storage fetches a
     * through-the-fork walk would cost. Reverts on any drift.
     */
    function verifyQueFileMatchesLive(
        string memory _queFile
    )
        internal
    {
        string[] memory cmd = new string[](3);
        cmd[0] = "node";
        cmd[1] = "tools/verify-que-live.mjs";
        cmd[2] = _queFile;

        uint256 ok = abi.decode(
            vm.ffi(cmd),
            (uint256)
        );

        require(
            ok == 1,
            "LiveStateRefresher: que snapshot does not match live"
        );
    }
}
