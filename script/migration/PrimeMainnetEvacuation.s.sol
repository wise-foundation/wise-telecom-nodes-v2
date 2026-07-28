// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Minimal admin slice of the LIVE v2 ForwardVaultERC20 the
 * migration drives. Declared locally so this script stays in the
 * =0.8.36 cluster and never imports the read-only =0.8.29 legacy
 * sources.
 */
interface IOldVault {

    function master()
        external
        view
        returns (address);

    function paused()
        external
        view
        returns (bool);

    function supplyChangeByOwnerNotAllowed()
        external
        view
        returns (bool);

    function proposeOwner(
        address _newOwner
    )
        external;
}

/**
 * @dev The already-deployed {MoneyForwardContractV4}. Its immutables
 * expose the old vault and USD token, so the buffer and EXTRA are
 * derived from the forwarder alone (no duplicate env addresses to keep
 * in sync with the `forge create` that deployed it).
 */
interface IForwarderV4 {

    function OLD_VAULT()
        external
        view
        returns (address);

    function USD_TOKEN()
        external
        view
        returns (address);

    function acceptOwnerOldVault()
        external;

    function mintSupply(
        uint256 _amount
    )
        external;

    function burnSupplyBulk(
        address[] calldata _users,
        uint256[] calldata _amounts
    )
        external;
}

/**
 * @title PrimeMainnetEvacuation
 * @dev Mainnet analog of the testnet {PrimeRehearsalEvacuation}: the
 * one Phase-B step that cannot be a hand-typed `cast` command because
 * it burns the full holder snapshot (hundreds to thousands of
 * addresses, chunked). Against an ALREADY-DEPLOYED
 * {MoneyForwardContractV4} (deploy it first via `forge create` so it
 * verifies as a top-level creation), in a single broadcast it:
 *   1. proposes the live v2 vault's ownership to the forwarder (the
 *      broadcasting key is still the v2 master),
 *   2. `acceptOwnerOldVault` (forwarder becomes the v2 master),
 *   3. `mintSupply(EXTRA)` — EXTRA sized from the LIVE buffer for a
 *      `PRIME_TARGET_SECONDS` (default 600) interest crossing,
 *   4. `burnSupplyBulk` every migrated holder from the snapshot,
 *      chunked, INCLUDING the v2 QueContract escrow row (its shares
 *      are real on the old vault), so afterwards the old vault's total
 *      supply is exactly EXTRA.
 *
 * The real-time wait, `initiateEvacuation`, the post-evacuation EXTRA
 * burn, ownership reclaim and diamond funding stay as discrete `cast`
 * steps in docs/MIGRATION_MAINNET.md (forge cannot sleep on a live
 * chain and the crossing is time-based).
 *
 * MUST run AFTER `SeedVaultMigration` + `VerifyVaultMigration` have
 * passed: `seedHolders` reads each holder's live `getTotalInterestUser`
 * from the old vault, so once holders are burned here the interest
 * parity comparison is void.
 *
 * NOT blindly re-runnable: once `acceptOwnerOldVault` has landed the v2
 * master is the forwarder and a fresh `proposeOwner` from the deployer
 * reverts — finish a partial broadcast with forge's `--resume`.
 *
 * Required env (no defaults — a missing value aborts):
 *   PRIVATE_KEY, PRIME_FORWARDER, SEED_BALANCE_FILE
 * Optional:
 *   PRIME_TARGET_SECONDS (default 600)
 *
 * The snapshot is read through the same version-agnostic node parser
 * as the seeder: run via `forge script --ffi` with node on PATH,
 * `--slow --gas-estimate-multiplier 200` (the cold-write chunk lesson),
 * and `--skip-simulation` on arbitrum.
 */
contract PrimeMainnetEvacuation is Script {

    uint256 constant SECONDS_PER_YEAR_SCALED = 157_700_000;

    uint256 constant BURN_CHUNK = 50;

    struct Ctx {
        address deployer;
        address forwarder;
        address oldVault;
        address usd;
        uint256 buffer;
        uint256 extra;
        uint256 targetSeconds;
        address[] holders;
        uint256[] balances;
    }

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        Ctx memory c = _loadCtx(
            privKey
        );

        _checkPreflight(
            c
        );

        _logResolved(
            c
        );

        vm.startBroadcast(
            privKey
        );

        IOldVault(c.oldVault).proposeOwner(
            c.forwarder
        );

        IForwarderV4(c.forwarder).acceptOwnerOldVault();

        IForwarderV4(c.forwarder).mintSupply(
            c.extra
        );

        _burnHoldersChunked(
            c
        );

        vm.stopBroadcast();

        console2.log("PRIME_BUFFER       ", c.buffer);
        console2.log("PRIME_EXTRA        ", c.extra);
        console2.log("PRIME_TMIN_SECONDS ", c.targetSeconds);
        console2.log("holders burned     ", c.holders.length);
        console2.log("done: takeover + mint + burn landed");
    }

    function _loadCtx(
        uint256 _privKey
    )
        internal
        returns (Ctx memory c)
    {
        c.deployer = vm.addr(
            _privKey
        );

        c.forwarder = vm.envAddress(
            "PRIME_FORWARDER"
        );

        c.targetSeconds = vm.envOr(
            "PRIME_TARGET_SECONDS",
            uint256(600)
        );

        c.oldVault = IForwarderV4(c.forwarder).OLD_VAULT();
        c.usd = IForwarderV4(c.forwarder).USD_TOKEN();

        c.buffer = IERC20(c.usd).balanceOf(
            c.oldVault
        );

        c.extra = c.buffer
            * SECONDS_PER_YEAR_SCALED
            / c.targetSeconds;

        (
            c.holders,
            c.balances
        ) = _readBalances(
            vm.envString(
                "SEED_BALANCE_FILE"
            )
        );
    }

    function _checkPreflight(
        Ctx memory _c
    )
        internal
        view
    {
        require(
            _c.forwarder.code.length > 0,
            "PrimeMainnetEvacuation: forwarder has no code - deploy it via forge create first"
        );

        require(
            _c.oldVault.code.length > 0,
            "PrimeMainnetEvacuation: old vault has no code"
        );

        require(
            _c.targetSeconds > 0,
            "PrimeMainnetEvacuation: PRIME_TARGET_SECONDS is zero"
        );

        require(
            _c.buffer > 0,
            "PrimeMainnetEvacuation: old vault buffer is zero - nothing to evacuate"
        );

        require(
            _c.holders.length > 0,
            "PrimeMainnetEvacuation: empty balance snapshot"
        );

        require(
            IOldVault(_c.oldVault).master() == _c.deployer,
            "PrimeMainnetEvacuation: old vault master is not the deployer - already taken over?"
        );

        require(
            IOldVault(_c.oldVault).supplyChangeByOwnerNotAllowed() == false,
            "PrimeMainnetEvacuation: supply change latched off - mint/burn would revert"
        );
    }

    function _burnHoldersChunked(
        Ctx memory _c
    )
        internal
    {
        uint256 length = _c.holders.length;

        for (uint256 start = 0; start < length; start += BURN_CHUNK) {

            uint256 end = start + BURN_CHUNK > length
                ? length
                : start + BURN_CHUNK;

            IForwarderV4(_c.forwarder).burnSupplyBulk(
                _sliceAddresses(
                    _c.holders,
                    start,
                    end
                ),
                _sliceUints(
                    _c.balances,
                    start,
                    end
                )
            );
        }
    }

    function _logResolved(
        Ctx memory _c
    )
        internal
        view
    {
        console2.log("deployer     ", _c.deployer);
        console2.log("forwarder    ", _c.forwarder);
        console2.log("old vault    ", _c.oldVault);
        console2.log("usd          ", _c.usd);
        console2.log("paused (info)", IOldVault(_c.oldVault).paused());
        console2.log("buffer       ", _c.buffer);
        console2.log("extra        ", _c.extra);
        console2.log("target sec   ", _c.targetSeconds);
        console2.log("holders      ", _c.holders.length);
    }

    function _sliceAddresses(
        address[] memory _values,
        uint256 _start,
        uint256 _end
    )
        internal
        pure
        returns (address[] memory out)
    {
        out = new address[](
            _end - _start
        );

        for (uint256 i = _start; i < _end; i++) {
            out[i - _start] = _values[i];
        }
    }

    function _sliceUints(
        uint256[] memory _values,
        uint256 _start,
        uint256 _end
    )
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](
            _end - _start
        );

        for (uint256 i = _start; i < _end; i++) {
            out[i - _start] = _values[i];
        }
    }

    function _readBalances(
        string memory _balanceFile
    )
        internal
        returns (
            address[] memory addrs,
            uint256[] memory balances
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
        ) = abi.decode(
            raw,
            (address[], uint256[], uint256[])
        );
    }
}
