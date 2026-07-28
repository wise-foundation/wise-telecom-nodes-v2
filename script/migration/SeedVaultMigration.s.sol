// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VaultConfig} from "../vault/VaultConfig.sol";
import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesQueueStructs} from "../../src/diamond/vault/WiseTelecomNodesQueueStructs.sol";
import {MigrationSeedFacet} from "../../src/diamond/vault/facets/MigrationSeedFacet.sol";

/**
 * @title SeedVaultMigration
 * @dev Replicates a v2 ForwardVaultERC20 + QueContract onto the
 * canonical diamond for this product and network, id-identically, via
 * {MigrationSeedFacet}. The diamond must be deployed but NOT
 * finalized: the facet is wired through an instant
 * `proposeSelectors`/`executeSelectorChanges` pair, the batch setters
 * seed all holders (balances + live interest read from the old vault
 * in the same transaction + proxy locks) and the complete queue
 * (members at their explicit v2 ids, per-incentive pointers, globals,
 * orphan escrow), and the seed selectors are removed again in the
 * same broadcast so no migration write-surface survives.
 *
 * Must run BEFORE the old vault is taken over and its holders are
 * burned — `seedHolders` reads `getTotalInterestUser` live per
 * holder, which is what makes interest parity hold afterwards.
 *
 * The old vault is the LIVE v2 vault on mainnet and the mock v2 vault
 * on a testnet rehearsal; the escrow holder is the address whose
 * old-vault share balance is the queue escrow (the v2 QueContract
 * address as it appears in the balance snapshot). The escrow row is
 * EXCLUDED from holder seeding — the diamond is its own queue, so
 * those shares are minted once to the diamond via `seedQueTokens`,
 * conserving the v2 total supply.
 *
 * Preflight guards (all abort before any transaction): every
 * snapshot balance must equal the old vault's live balance (stale
 * snapshot = re-fetch, never bypass), the diamond total supply must
 * be zero (a partial seed broadcast must be finished with forge's
 * `--resume`, NEVER by re-running — `seedHolders` mints additively),
 * and a zero escrow with active queue orders aborts (wrong
 * `SEED_QUE_ESCROW_HOLDER`).
 *
 * Required env (no defaults — a missing value aborts):
 *   PRIVATE_KEY, VAULT_PRODUCT, SEED_OLD_VAULT,
 *   SEED_QUE_ESCROW_HOLDER, SEED_BALANCE_FILE, SEED_QUE_FILE
 *
 * Snapshot files are read through the same version-agnostic node
 * parsers as the fork E2E: run via `forge script --ffi` with node on
 * PATH. Broadcast with `--slow --gas-estimate-multiplier 200` (cold
 * first-write chunks under-estimate, the T1 `joinQue` lesson) and
 * `--skip-simulation` on arbitrum_sepolia.
 */
contract SeedVaultMigration is VaultConfig, WiseTelecomNodesQueueStructs {

    uint256 constant HOLDER_CHUNK = 50;

    uint256 constant MEMBER_CHUNK = 100;

    struct Ctx {
        address diamond;
        address oldVault;
        address escrowHolder;
        uint256 escrowAmount;
        string balanceFile;
        string queFile;
        address[] holders;
        uint256[] balances;
        uint256[] proxyBalances;
    }

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        Ctx memory c = _loadCtx();

        _logResolved(
            c
        );

        vm.startBroadcast(
            privKey
        );

        address facet = address(
            new MigrationSeedFacet()
        );

        bytes4[] memory sels = _seedSelectors();

        WiseTelecomNodesDiamond diamond = WiseTelecomNodesDiamond(
            payable(c.diamond)
        );

        diamond.proposeSelectors(
            sels,
            facet
        );

        diamond.executeSelectorChanges(
            sels
        );

        MigrationSeedFacet seeder = MigrationSeedFacet(
            c.diamond
        );

        _seedHoldersChunked(
            seeder,
            c
        );

        _seedQueue(
            seeder,
            c.queFile
        );

        seeder.seedQueTokens(
            c.escrowAmount
        );

        diamond.proposeSelectors(
            sels,
            address(0)
        );

        diamond.executeSelectorChanges(
            sels
        );

        vm.stopBroadcast();

        console2.log("seed facet   ", facet);
        console2.log("escrow seeded", c.escrowAmount);
        console2.log("holders seeded", c.holders.length);
        console2.log("done: seed selectors removed");
    }

    function _loadCtx()
        internal
        returns (Ctx memory c)
    {
        vm.envString(
            "VAULT_PRODUCT"
        );

        c.oldVault = vm.envAddress(
            "SEED_OLD_VAULT"
        );

        c.escrowHolder = vm.envAddress(
            "SEED_QUE_ESCROW_HOLDER"
        );

        c.balanceFile = vm.envString(
            "SEED_BALANCE_FILE"
        );

        c.queFile = vm.envString(
            "SEED_QUE_FILE"
        );

        (
            c.diamond,
        ) = _loadVault(
            _networkName()
        );

        (
            c.holders,
            c.balances,
            c.proxyBalances
        ) = _readBalances(
            c.balanceFile
        );

        require(
            c.oldVault.code.length > 0,
            "SeedVaultMigration: old vault has no code"
        );

        require(
            c.holders.length > 0,
            "SeedVaultMigration: empty balance snapshot"
        );

        _checkPreflight(
            c
        );

        _dropEscrowRow(
            c
        );
    }

    function _checkPreflight(
        Ctx memory _c
    )
        internal
    {
        for (uint256 i = 0; i < _c.holders.length; i++) {
            require(
                IERC20(_c.oldVault).balanceOf(_c.holders[i]) == _c.balances[i],
                "SeedVaultMigration: snapshot drifted from live old vault - re-fetch, never bypass"
            );
        }

        require(
            IERC20(_c.diamond).totalSupply() == 0,
            "SeedVaultMigration: diamond already holds supply - finish a partial seed with forge --resume, never re-run"
        );

        _c.escrowAmount = IERC20(_c.oldVault).balanceOf(
            _c.escrowHolder
        );

        (
            uint256 totalActive,
            ,
        ) = _readQueSummary(
            _c.queFile
        );

        require(
            _c.escrowAmount > 0 || totalActive == 0,
            "SeedVaultMigration: zero escrow with active queue orders - wrong SEED_QUE_ESCROW_HOLDER?"
        );
    }

    function _dropEscrowRow(
        Ctx memory _c
    )
        internal
        pure
    {
        uint256 kept;
        uint256 length = _c.holders.length;

        address[] memory holders = new address[](length);
        uint256[] memory balances = new uint256[](length);
        uint256[] memory proxyBalances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {

            if (_c.holders[i] == _c.escrowHolder) {
                continue;
            }

            holders[kept] = _c.holders[i];
            balances[kept] = _c.balances[i];
            proxyBalances[kept] = _c.proxyBalances[i];

            kept++;
        }

        _c.holders = _shrinkAddresses(
            holders,
            kept
        );

        _c.balances = _shrinkUints(
            balances,
            kept
        );

        _c.proxyBalances = _shrinkUints(
            proxyBalances,
            kept
        );
    }

    function _logResolved(
        Ctx memory _c
    )
        internal
        view
    {
        console2.log("product      ", _vaultProduct());
        console2.log("network      ", _networkName());
        console2.log("diamond      ", _c.diamond);
        console2.log("old vault    ", _c.oldVault);
        console2.log("escrow holder", _c.escrowHolder);
        console2.log("escrow amount", _c.escrowAmount);
        console2.log("balance file ", _c.balanceFile);
        console2.log("que file     ", _c.queFile);
        console2.log("holders      ", _c.holders.length);
    }

    function _seedSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](5);
        sels[0] = MigrationSeedFacet.seedHolders.selector;
        sels[1] = MigrationSeedFacet.seedQueTokens.selector;
        sels[2] = MigrationSeedFacet.seedQueMembers.selector;
        sels[3] = MigrationSeedFacet.seedPerIncentiveState.selector;
        sels[4] = MigrationSeedFacet.seedQueueGlobals.selector;
    }

    function _seedHoldersChunked(
        MigrationSeedFacet _seeder,
        Ctx memory _c
    )
        internal
    {
        uint256 length = _c.holders.length;

        for (uint256 start = 0; start < length; start += HOLDER_CHUNK) {

            uint256 end = start + HOLDER_CHUNK > length
                ? length
                : start + HOLDER_CHUNK;

            _seeder.seedHolders(
                _c.oldVault,
                _sliceAddresses(
                    _c.holders,
                    start,
                    end
                ),
                _sliceUints(
                    _c.balances,
                    start,
                    end
                ),
                _sliceUints(
                    _c.proxyBalances,
                    start,
                    end
                )
            );
        }
    }

    function _seedQueue(
        MigrationSeedFacet _seeder,
        string memory _queFile
    )
        internal
    {
        (
            uint256 totalActive,
            bool negNotAllowed,
            uint256 minDeposit
        ) = _readQueSummary(
            _queFile
        );

        _seeder.seedQueueGlobals(
            totalActive,
            minDeposit,
            negNotAllowed
        );

        (
            int256[] memory incentives,
            uint256[] memory earliestValid,
            uint256[] memory currentOrderId,
            uint256[] memory activeOrderCount,
            bool[] memory allowed
        ) = _readQuePointers(
            _queFile
        );

        _seeder.seedPerIncentiveState(
            incentives,
            earliestValid,
            currentOrderId,
            activeOrderCount,
            allowed
        );

        _seedMembersChunked(
            _seeder,
            _readQueMembers(
                _queFile
            )
        );
    }

    function _seedMembersChunked(
        MigrationSeedFacet _seeder,
        QueMemberWithId[] memory _members
    )
        internal
    {
        uint256 length = _members.length;

        for (uint256 start = 0; start < length; start += MEMBER_CHUNK) {

            uint256 end = start + MEMBER_CHUNK > length
                ? length
                : start + MEMBER_CHUNK;

            QueMemberWithId[] memory chunk = new QueMemberWithId[](
                end - start
            );

            for (uint256 i = start; i < end; i++) {
                chunk[i - start] = _members[i];
            }

            _seeder.seedQueMembers(
                chunk
            );
        }
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

    function _shrinkAddresses(
        address[] memory _values,
        uint256 _kept
    )
        internal
        pure
        returns (address[] memory out)
    {
        out = new address[](
            _kept
        );

        for (uint256 i = 0; i < _kept; i++) {
            out[i] = _values[i];
        }
    }

    function _shrinkUints(
        uint256[] memory _values,
        uint256 _kept
    )
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](
            _kept
        );

        for (uint256 i = 0; i < _kept; i++) {
            out[i] = _values[i];
        }
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

    function _readQueSummary(
        string memory _queFile
    )
        internal
        returns (
            uint256 totalActive,
            bool negNotAllowed,
            uint256 minDeposit
        )
    {
        bytes memory raw = _queFfi(
            _queFile,
            "summary"
        );

        (
            totalActive,
            negNotAllowed,
            minDeposit
        ) = abi.decode(
            raw,
            (uint256, bool, uint256)
        );
    }

    function _readQuePointers(
        string memory _queFile
    )
        internal
        returns (
            int256[] memory incentives,
            uint256[] memory earliestValid,
            uint256[] memory currentOrderId,
            uint256[] memory activeOrderCount,
            bool[] memory allowed
        )
    {
        bytes memory raw = _queFfi(
            _queFile,
            "pointers"
        );

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
    }

    function _readQueMembers(
        string memory _queFile
    )
        internal
        returns (QueMemberWithId[] memory members)
    {
        bytes memory raw = _queFfi(
            _queFile,
            "members"
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

    function _queFfi(
        string memory _queFile,
        string memory _section
    )
        internal
        returns (bytes memory)
    {
        string[] memory cmd = new string[](4);
        cmd[0] = "node";
        cmd[1] = "tools/parse-que-state.mjs";
        cmd[2] = _queFile;
        cmd[3] = _section;

        return vm.ffi(
            cmd
        );
    }
}
