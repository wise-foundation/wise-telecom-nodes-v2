// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesQueueStructs} from "../../src/diamond/vault/WiseTelecomNodesQueueStructs.sol";
import {WiseTelecomNodesDiamondSelectors} from "../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";
import {MigrationSeedFacet} from "../../src/diamond/vault/facets/MigrationSeedFacet.sol";
import {MoneyForwardContractV4} from "../../src/migration-v3/MoneyForwardContractV4.sol";

import {DiamondTestHarness} from "../diamond/utils/DiamondTestHarness.sol";
import {DiamondQueViewParity} from "./DiamondQueViewParity.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/**
 * @dev The live v2 ForwardVaultERC20 surface the migration drives.
 * Declared locally so this =0.8.36 test never imports the read-only
 * =0.8.29 legacy sources.
 */
interface IOldVault {

    function master()
        external
        view
        returns (address);

    function proposeOwner(
        address _newOwner
    )
        external;

    function claimOwnership()
        external;

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

    function paused()
        external
        view
        returns (bool);

    function pauseDeposits()
        external;
}

/**
 * @dev Diamond user surface exercised post-migration.
 */
interface IDiamondUser {

    function claimInterest()
        external
        returns (uint256);

    function getTotalInterestUser(
        address _user
    )
        external
        view
        returns (uint256);
}

/**
 * @title DiamondMigrationForkE2E
 * @dev End-to-end v2 -> v3 migration on a mainnet/arb fork with
 * `vm.warp` standing in for the real-time wait. Per (chain, token):
 *   1. seed all live holders + the full queue onto a fresh diamond,
 *   2. assert per-holder balance/interest parity against live v2,
 *   3. take over the old vault via {MoneyForwardContractV4}, mint
 *      EXTRA, burn the migrated holders, warp past `t_min`,
 *   4. `initiateEvacuation` against the REAL Uniswap v4 PoolManager,
 *      asserting the old vault drains to exactly 0 and the buffer
 *      lands on the migration deployer,
 *   5. a seeded holder claims interest on the funded diamond,
 * plus the emergency escape hatch (broken/unfireable evacuation ->
 * `emergencyReturnOwnership` returns the old vault to the deployer;
 * non-master calls revert).
 */
abstract contract MigrationForkBase is DiamondTestHarness, WiseTelecomNodesQueueStructs {

    using stdStorage for StdStorage;

    address internal constant POOL_MANAGER_ETH = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POOL_MANAGER_ARB = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    uint256 internal constant SECONDS_PER_YEAR_SCALED = 157_700_000;
    uint256 internal constant CROSSING_TARGET_SECONDS = 600;

    address internal migrationDeployer = makeAddr("migrationDeployer");
    address internal stranger = makeAddr("stranger");

    struct Cfg {
        string rpc;
        address token;
        address oldVault;
        address oldQue;
        address poolManager;
        string balanceFile;
        string queFile;
    }

    Cfg internal cfg;

    function _config()
        internal
        view
        virtual
        returns (Cfg memory);

    // ---- fork pinning ----

    function _pinAndFork()
        internal
    {
        cfg = _config();

        uint256 pinnedBlock = _readBalanceFileBlock(
            cfg.balanceFile
        );

        vm.createSelectFork(
            cfg.rpc,
            pinnedBlock
        );

        assertGt(
            cfg.poolManager.code.length,
            0,
            "PoolManager has no code on this fork"
        );
    }

    function _readBalanceFileBlock(
        string memory _path
    )
        internal
        returns (uint256)
    {
        vm.readLine(_path);

        string memory blockLine = vm.readLine(
            _path
        );

        vm.closeFile(_path);

        return vm.parseUint(
            blockLine
        );
    }

    // ---- ffi snapshot readers (version-agnostic node scripts) ----

    function _readBalances()
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
        cmd[2] = cfg.balanceFile;

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

    function _readQueSummary()
        internal
        returns (
            uint256 totalActive,
            bool negNotAllowed,
            uint256 minDeposit
        )
    {
        bytes memory raw = _queFfi(
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

    function _readQuePointers()
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

    function _readQueMembers()
        internal
        returns (
            QueMemberWithId[] memory members
        )
    {
        bytes memory raw = _queFfi(
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
        string memory _section
    )
        internal
        returns (bytes memory)
    {
        string[] memory cmd = new string[](4);
        cmd[0] = "node";
        cmd[1] = "tools/parse-que-state.mjs";
        cmd[2] = cfg.queFile;
        cmd[3] = _section;

        return vm.ffi(
            cmd
        );
    }

    // ---- seeded diamond ----

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

    function _deploySeededDiamond(
        address[] memory _addrs,
        uint256[] memory _balances,
        uint256[] memory _proxyBalances
    )
        internal
        returns (WiseTelecomNodesDiamond d)
    {
        d = _newDiamond(
            cfg.token
        );

        _wireAllFacets(
            d
        );

        _wireQueueFacets(
            d
        );

        bytes4[] memory seedSels = _seedSelectors();

        _wireOne(
            d,
            address(new MigrationSeedFacet()),
            seedSels
        );

        MigrationSeedFacet seeder = MigrationSeedFacet(
            address(d)
        );

        seeder.seedHolders(
            cfg.oldVault,
            _addrs,
            _balances,
            _proxyBalances
        );

        _seedQueue(
            seeder
        );

        seeder.seedQueTokens(
            IOldVault(cfg.oldVault).balanceOf(cfg.oldQue)
        );

        d.proposeSelectors(
            seedSels,
            address(0)
        );

        d.executeSelectorChanges(
            seedSels
        );

        d.finalizeSetup();
    }

    function _seedQueue(
        MigrationSeedFacet _seeder
    )
        internal
    {
        (
            uint256 totalActive,
            bool negNotAllowed,
            uint256 minDeposit
        ) = _readQueSummary();

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
        ) = _readQuePointers();

        _seeder.seedPerIncentiveState(
            incentives,
            earliestValid,
            currentOrderId,
            activeOrderCount,
            allowed
        );

        _seeder.seedQueMembers(
            _readQueMembers()
        );
    }

    // ---- snapshot filtering ----

    /**
     * @dev The balance snapshots include the v2 QueContract itself as
     * a holder row whenever the queue escrow is non-zero. That row
     * must NOT be holder-seeded: the diamond is its own queue, so the
     * escrow is minted once to the diamond via `seedQueTokens` —
     * seeding it as a holder would double-count the escrow (and the
     * legacy vault freezes interest for its InterestRateProxy while
     * the diamond would accrue on the copy). The full unfiltered
     * arrays still drive `burnSupplyBulk`, which burns on the OLD
     * vault where the que's own balance is real.
     */
    function _stripQueRow(
        address[] memory _addrs,
        uint256[] memory _balances,
        uint256[] memory _proxyBalances
    )
        internal
        view
        returns (
            address[] memory addrs,
            uint256[] memory balances,
            uint256[] memory proxyBalances
        )
    {
        uint256 kept;

        for (uint256 i = 0; i < _addrs.length; i++) {
            if (_addrs[i] != cfg.oldQue) {
                kept++;
            }
        }

        addrs = new address[](kept);
        balances = new uint256[](kept);
        proxyBalances = new uint256[](kept);

        uint256 j;

        for (uint256 i = 0; i < _addrs.length; i++) {

            if (_addrs[i] == cfg.oldQue) {
                continue;
            }

            addrs[j] = _addrs[i];
            balances[j] = _balances[i];
            proxyBalances[j] = _proxyBalances[i];

            j++;
        }
    }

    // ---- shared assertions ----

    function _assertHolderParity(
        WiseTelecomNodesDiamond _d,
        address[] memory _addrs,
        uint256[] memory _balances
    )
        internal
        view
    {
        for (uint256 i = 0; i < _addrs.length; i++) {

            assertEq(
                IERC20(address(_d)).balanceOf(_addrs[i]),
                _balances[i],
                "balance parity"
            );

            assertEq(
                IDiamondUser(address(_d)).getTotalInterestUser(_addrs[i]),
                IOldVault(cfg.oldVault).getTotalInterestUser(_addrs[i]),
                "interest parity"
            );
        }
    }

    // ---- migration driver ----

    function _takeOverOldVault(
        MoneyForwardContractV4 _forwarder
    )
        internal
    {
        address owner = IOldVault(cfg.oldVault).master();

        vm.prank(
            owner
        );

        IOldVault(cfg.oldVault).proposeOwner(
            address(_forwarder)
        );

        _forwarder.acceptOwnerOldVault();
    }

    function _newForwarder()
        internal
        returns (MoneyForwardContractV4)
    {
        return new MoneyForwardContractV4(
            cfg.oldVault,
            cfg.token,
            IOldVault(cfg.oldVault).master(),
            migrationDeployer,
            cfg.poolManager
        );
    }

    // ---- tests ----

    function test_fork_fullMigration()
        public
    {
        _pinAndFork();

        (
            address[] memory addrs,
            uint256[] memory balances,
            uint256[] memory proxyBalances
        ) = _readBalances();

        (
            address[] memory seedAddrs,
            uint256[] memory seedBalances,
            uint256[] memory seedProxyBalances
        ) = _stripQueRow(
            addrs,
            balances,
            proxyBalances
        );

        WiseTelecomNodesDiamond d = _deploySeededDiamond(
            seedAddrs,
            seedBalances,
            seedProxyBalances
        );

        _assertHolderParity(
            d,
            seedAddrs,
            seedBalances
        );

        assertEq(
            IERC20(address(d)).balanceOf(address(d)),
            IOldVault(cfg.oldVault).balanceOf(cfg.oldQue),
            "diamond escrow != old que balance"
        );

        assertEq(
            IERC20(address(d)).totalSupply(),
            IOldVault(cfg.oldVault).totalSupply(),
            "total supply not conserved"
        );

        MoneyForwardContractV4 forwarder = _newForwarder();

        _takeOverOldVault(
            forwarder
        );

        uint256 buffer = IERC20(cfg.token).balanceOf(
            cfg.oldVault
        );

        assertGt(
            buffer,
            0,
            "old vault buffer must be non-zero"
        );

        uint256 extra = buffer
            * SECONDS_PER_YEAR_SCALED
            / CROSSING_TARGET_SECONDS;

        forwarder.mintSupply(
            extra
        );

        forwarder.burnSupplyBulk(
            addrs,
            balances
        );

        vm.warp(
            block.timestamp + 900
        );

        uint256 deployerBefore = IERC20(cfg.token).balanceOf(
            migrationDeployer
        );

        forwarder.initiateEvacuation();

        assertEq(
            IERC20(cfg.token).balanceOf(cfg.oldVault),
            0,
            "old vault not drained to zero"
        );

        assertEq(
            IERC20(cfg.token).balanceOf(migrationDeployer),
            deployerBefore + buffer,
            "buffer did not land on the migration deployer"
        );

        _assertSeededHolderCanClaim(
            d,
            addrs
        );
    }

    function _assertSeededHolderCanClaim(
        WiseTelecomNodesDiamond _d,
        address[] memory _addrs
    )
        internal
    {
        address holder = _firstInterestBearingHolder(
            _d,
            _addrs
        );

        if (holder == address(0)) {
            return;
        }

        deal(
            cfg.token,
            address(_d),
            10_000_000 * 1e6
        );

        vm.warp(
            block.timestamp + 30 days
        );

        uint256 before = IERC20(cfg.token).balanceOf(
            holder
        );

        vm.prank(
            holder
        );

        uint256 claimed = IDiamondUser(address(_d)).claimInterest();

        assertGt(
            claimed,
            0,
            "seeded holder claimed nothing"
        );

        assertEq(
            IERC20(cfg.token).balanceOf(holder),
            before + claimed,
            "claim payout mismatch"
        );
    }

    function _firstInterestBearingHolder(
        WiseTelecomNodesDiamond _d,
        address[] memory _addrs
    )
        internal
        view
        returns (address)
    {
        for (uint256 i = 0; i < _addrs.length; i++) {
            if (IERC20(address(_d)).balanceOf(_addrs[i]) > 0) {
                return _addrs[i];
            }
        }

        return address(0);
    }

    function test_fork_emergencyReturnOwnership()
        public
    {
        _pinAndFork();

        MoneyForwardContractV4 forwarder = _newForwarder();

        _takeOverOldVault(
            forwarder
        );

        vm.expectRevert(
            MoneyForwardContractV4.WouldNotEmptyVault.selector
        );

        forwarder.initiateEvacuation();

        vm.prank(
            stranger
        );

        vm.expectRevert();

        forwarder.emergencyReturnOwnership();

        forwarder.emergencyReturnOwnership();

        IOldVault(cfg.oldVault).claimOwnership();

        assertEq(
            IOldVault(cfg.oldVault).master(),
            address(this),
            "old vault ownership not returned"
        );
    }

    // ---- paused-start migration (deposits frozen before takeover) ----

    /**
     * @dev Proves the full evacuation still works when the live v2 is
     * paused for deposits BEFORE the migration starts (the operator's
     * "stop new deposits first" step). Mint/burn are not pause-gated on
     * the v2, and {MoneyForwardContractV4.unlockCallback} lifts and
     * restores the pause atomically around `claimInterest` (which IS
     * `whenNotPaused`), so the vault drains to zero and ends paused
     * with no window for a new deposit to interleave.
     */
    function test_fork_fullMigration_pausedStart()
        public
    {
        _pinAndFork();

        (
            address[] memory addrs,
            uint256[] memory balances,
            uint256[] memory proxyBalances
        ) = _readBalances();

        (
            address[] memory seedAddrs,
            uint256[] memory seedBalances,
            uint256[] memory seedProxyBalances
        ) = _stripQueRow(
            addrs,
            balances,
            proxyBalances
        );

        WiseTelecomNodesDiamond d = _deploySeededDiamond(
            seedAddrs,
            seedBalances,
            seedProxyBalances
        );

        address oldMaster = IOldVault(cfg.oldVault).master();

        vm.prank(oldMaster);
        IOldVault(cfg.oldVault).pauseDeposits();

        assertTrue(
            IOldVault(cfg.oldVault).paused(),
            "v2 deposits not frozen before migration"
        );

        MoneyForwardContractV4 forwarder = _newForwarder();

        _takeOverOldVault(
            forwarder
        );

        uint256 buffer = IERC20(cfg.token).balanceOf(
            cfg.oldVault
        );

        assertGt(
            buffer,
            0,
            "old vault buffer must be non-zero"
        );

        uint256 extra = buffer
            * SECONDS_PER_YEAR_SCALED
            / CROSSING_TARGET_SECONDS;

        forwarder.mintSupply(
            extra
        );

        forwarder.burnSupplyBulk(
            addrs,
            balances
        );

        vm.warp(
            block.timestamp + 900
        );

        uint256 deployerBefore = IERC20(cfg.token).balanceOf(
            migrationDeployer
        );

        forwarder.initiateEvacuation();

        assertEq(
            IERC20(cfg.token).balanceOf(cfg.oldVault),
            0,
            "old vault not drained to zero"
        );

        assertEq(
            IERC20(cfg.token).balanceOf(migrationDeployer),
            deployerBefore + buffer,
            "buffer did not land on the migration deployer"
        );

        assertTrue(
            IOldVault(cfg.oldVault).paused(),
            "v2 not left paused after evacuation"
        );

        _assertSeededHolderCanClaim(
            d,
            addrs
        );
    }

    // ---- queue view parity ----

    /**
     * @dev Pins the fork to the QUE snapshot block (not the balance
     * block) so the live old que's queue storage equals the snapshot
     * the diamond is seeded from — a prerequisite for a byte-identical
     * old-vs-new view comparison.
     */
    function _pinAndForkQue()
        internal
    {
        cfg = _config();

        uint256 pinnedBlock = _readBalanceFileBlock(
            cfg.queFile
        );

        vm.createSelectFork(
            cfg.rpc,
            pinnedBlock
        );
    }

    function _seedForParity()
        internal
        returns (
            WiseTelecomNodesDiamond d,
            QueMemberWithId[] memory members
        )
    {
        (
            address[] memory addrs,
            uint256[] memory balances,
            uint256[] memory proxyBalances
        ) = _readBalances();

        (
            address[] memory seedAddrs,
            uint256[] memory seedBalances,
            uint256[] memory seedProxyBalances
        ) = _stripQueRow(
            addrs,
            balances,
            proxyBalances
        );

        d = _deploySeededDiamond(
            seedAddrs,
            seedBalances,
            seedProxyBalances
        );

        members = _readQueMembers();
    }

    /**
     * @dev External boundary so {vm.expectRevert} can catch a revert
     * from the (internal, inlined) parity library in the negative
     * control below.
     */
    function externalAssertParity(
        address _oldQue,
        address _newQue,
        QueMemberWithId[] memory _members
    )
        external
        view
    {
        DiamondQueViewParity.assertParity(
            _oldQue,
            _newQue,
            _members
        );
    }

    /**
     * @dev Seeds the diamond from the live snapshot and proves every
     * legacy que view (minus the three documented divergences) answers
     * byte-identically to the live old que, after a time warp. The
     * queue views are time-independent, so the warp additionally
     * proves the seed introduced no timestamp coupling.
     */
    function test_fork_queViewParity()
        public
    {
        _pinAndForkQue();

        (
            WiseTelecomNodesDiamond d,
            QueMemberWithId[] memory members
        ) = _seedForParity();

        vm.warp(
            block.timestamp + 7 days
        );

        DiamondQueViewParity.assertParity(
            cfg.oldQue,
            address(d),
            members
        );
    }

    /**
     * @dev Negative control: corrupting a single compared value on the
     * otherwise byte-identical diamond MUST make the parity sweep
     * revert. Proves the comparator actually catches divergence rather
     * than passing vacuously.
     */
    function test_fork_queViewParity_catchesDivergence()
        public
    {
        _pinAndForkQue();

        (
            WiseTelecomNodesDiamond d,
            QueMemberWithId[] memory members
        ) = _seedForParity();

        uint256 corrupted = d.minDepositAmount() + 1;

        stdstore
            .target(address(d))
            .sig("minDepositAmount()")
            .checked_write(corrupted);

        assertEq(
            d.minDepositAmount(),
            corrupted,
            "corruption did not take"
        );

        vm.expectRevert(
            bytes("DiamondQueViewParity: returndata mismatch minDepositAmount")
        );

        this.externalAssertParity(
            cfg.oldQue,
            address(d),
            members
        );
    }
}

contract MigrationForkEthUsdcTest is MigrationForkBase {

    function _config()
        internal
        view
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            token: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            oldVault: 0x11cEeE394842d9492f2C97050f66dE0e3f89D3A6,
            oldQue: 0x4e601103590b8971c208bF06B64ba1ef1c85B7e6,
            poolManager: POOL_MANAGER_ETH,
            balanceFile: "data/USDCaddress_balances_eth.txt",
            queFile: "data/que_state_eth_usdc.txt"
        });
    }
}

contract MigrationForkEthUsdtTest is MigrationForkBase {

    function _config()
        internal
        view
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            token: 0xdAC17F958D2ee523a2206206994597C13D831ec7,
            oldVault: 0x3Ed1f16BbE0eE2C58119c13517a88fe9ccedfd45,
            oldQue: 0x0f63bDcE0f4f3531117E2ed2FE1484c5E40a75b5,
            poolManager: POOL_MANAGER_ETH,
            balanceFile: "data/USDTaddress_balances_eth.txt",
            queFile: "data/que_state_eth_usdt.txt"
        });
    }
}

contract MigrationForkArbUsdcTest is MigrationForkBase {

    function _config()
        internal
        view
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            token: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            oldVault: 0x025421D3e98D3bB7A33d6814Dd576eD8B9090077,
            oldQue: 0xCfF3EdA95c3866bE10c8D3A29EDA665fc82EF72a,
            poolManager: POOL_MANAGER_ARB,
            balanceFile: "data/USDCaddress_balances_arb.txt",
            queFile: "data/que_state_arb_usdc.txt"
        });
    }
}

contract MigrationForkArbUsdtTest is MigrationForkBase {

    function _config()
        internal
        view
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            token: 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
            oldVault: 0xD69670d0eCaf032Ea8b1A6925E59dBacAA20f43A,
            oldQue: 0xc7960021229aDbacddfb57990815ab599A275533,
            poolManager: POOL_MANAGER_ARB,
            balanceFile: "data/USDTaddress_balances_arb.txt",
            queFile: "data/que_state_arb_usdt.txt"
        });
    }
}
