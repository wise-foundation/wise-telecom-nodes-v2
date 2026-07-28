// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesInitParams} from "../../src/diamond/vault/WiseTelecomNodesDiamondStructs.sol";
import {WiseTelecomNodesQueueStructs} from "../../src/diamond/vault/WiseTelecomNodesQueueStructs.sol";
import {MigrationSeedFacet} from "../../src/diamond/vault/facets/MigrationSeedFacet.sol";
import {MoneyForwardContractV4} from "../../src/migration-v3/MoneyForwardContractV4.sol";

import {DiamondTestHarness} from "../diamond/utils/DiamondTestHarness.sol";

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
 * @dev Diamond user surface exercised post-migration. `joinQue` is
 * declared without its return tuple: the selector is unchanged, so the
 * call encodes identically and the (ignored) returndata is simply not
 * decoded.
 */
interface IDiamondOps {

    function claimInterest()
        external
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

    function minDepositAmount()
        external
        view
        returns (uint256);

    function joinQue(
        uint256 _amount,
        int256 _incentive
    )
        external;
}

/**
 * @title PostDeployMigrationFork (execution-order step 7b)
 * @dev The last gate before the irreversible Phase B. Where
 * {DiamondMigrationForkE2E} proves the mechanism on a harness-defaulted
 * diamond, this proves it against a diamond deployed with the REAL
 * production init params (locked worker + WorldMobile custodian, the
 * per-leg deposit cap, the product token name/symbol) and finalized
 * like production, then drives the EXACT Phase-B command sequence from
 * docs/MIGRATION_MAINNET.md end to end:
 *   1. seed holders + full queue, assert balance/interest/supply parity,
 *   2. take over the old vault, mint EXTRA, burn the migrated holders,
 *   3. `initiateEvacuation` against the REAL Uniswap v4 PoolManager —
 *      old vault USD drains to exactly 0, buffer lands on the deployer,
 *   4. the post-evacuation EXTRA burn (the step the E2E omits) — assert
 *      the old vault's TOTAL SUPPLY is now exactly 0 (the locked v2
 *      end-state), then reclaim ownership,
 *   5. fund the diamond with the recovered buffer,
 *   6. REAL snapshot holders operate on the migrated diamond: claim
 *      interest, transfer shares, and a fresh depositor joins the
 *      seeded queue.
 *
 * Once Phase A is live this same test is repointed at the deployed
 * canonical (fork at a post-deploy block, `vm.etch`/load the canonical
 * instead of `_newRealDiamond`) so it exercises the on-chain bytecode;
 * pre-deploy it deploys the identical facet set + init params on a
 * throwaway fork, which is what makes it runnable now.
 */
abstract contract PostDeployForkBase is DiamondTestHarness, WiseTelecomNodesQueueStructs {

    address internal constant POOL_MANAGER_ETH = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POOL_MANAGER_ARB = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    uint256 internal constant SECONDS_PER_YEAR_SCALED = 157_700_000;
    uint256 internal constant CROSSING_TARGET_SECONDS = 600;

    address internal constant LOCKED_WORKER = 0x331444ac19A4E61cd13840D5c379ef20fae99809;
    address internal constant LOCKED_THIRD_PARTY = 0x28839A860DBF95e013d6EA528f6140e7340d0880;

    address internal migrationDeployer = makeAddr("migrationDeployer");
    address internal shareRecipient = makeAddr("shareRecipient");

    struct Cfg {
        string rpc;
        address token;
        address oldVault;
        address oldQue;
        address poolManager;
        string balanceFile;
        string queFile;
        uint256 totalDepositCap;
        string tokenName;
        string tokenSymbol;
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

    // ---- snapshot filtering ----

    /**
     * @dev The balance snapshot carries the v2 QueContract itself as a
     * holder row (its own share balance is the queue escrow). That row
     * is dropped from holder seeding — the diamond is its own queue, so
     * the escrow is minted once via `seedQueTokens` — but kept for the
     * `burnSupplyBulk` arrays, which burn on the OLD vault where the
     * que's balance is real. See {DiamondMigrationForkE2E}.
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

    // ---- real-config seeded diamond ----

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

    /**
     * @dev News the diamond with the LOCKED production init params
     * instead of the harness defaults ({DiamondTestHarness._newDiamond}
     * uses placeholder roles + a 1e15 cap). This is the material
     * difference from the E2E gate: the migration runs against the
     * exact worker / custodian / cap / token identity that Phase A
     * deploys.
     */
    function _newRealDiamond()
        internal
        returns (WiseTelecomNodesDiamond d)
    {
        _ensurePermit2();

        d = new WiseTelecomNodesDiamond(
            WiseTelecomNodesInitParams({
                usdAddress: cfg.token,
                thirdPartyAddress: LOCKED_THIRD_PARTY,
                workerAddress: LOCKED_WORKER,
                oldVault: address(0),
                initialDistributionAddresses: new address[](0),
                initialDistributionAmounts: new uint256[](0),
                totalDepositCap: cfg.totalDepositCap,
                interestRate: INTEREST_RATE,
                decimalsValue: DEFAULT_DECIMALS,
                tokenName: cfg.tokenName,
                tokenSymbol: cfg.tokenSymbol
            })
        );
    }

    function _deploySeededDiamond(
        address[] memory _addrs,
        uint256[] memory _balances,
        uint256[] memory _proxyBalances
    )
        internal
        returns (WiseTelecomNodesDiamond d)
    {
        d = _newRealDiamond();

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

    // ---- shared assertions ----

    function _assertHolderParity(
        WiseTelecomNodesDiamond _d,
        address[] memory _addrs,
        uint256[] memory _balances,
        uint256[] memory _proxyBalances
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
                IDiamondOps(address(_d)).proxyBalance(_addrs[i]),
                _proxyBalances[i],
                "proxy balance parity"
            );

            assertEq(
                IDiamondOps(address(_d)).getTotalInterestUser(_addrs[i]),
                IOldVault(cfg.oldVault).getTotalInterestUser(_addrs[i]),
                "interest parity"
            );
        }
    }

    // ---- migration driver ----

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

    // ---- the step-7b gate ----

    function test_fork_postDeployMigration()
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
            seedBalances,
            seedProxyBalances
        );

        assertEq(
            IERC20(address(d)).balanceOf(address(d)),
            IOldVault(cfg.oldVault).balanceOf(cfg.oldQue),
            "diamond escrow != old que balance"
        );

        assertEq(
            IERC20(address(d)).totalSupply(),
            IOldVault(cfg.oldVault).totalSupply(),
            "total supply not conserved at seed"
        );

        address realOwner = IOldVault(cfg.oldVault).master();

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
            "old vault USD not drained to zero"
        );

        assertEq(
            IERC20(cfg.token).balanceOf(migrationDeployer),
            deployerBefore + buffer,
            "buffer did not land on the migration deployer"
        );

        _finishV2EndState(
            forwarder,
            realOwner,
            extra
        );

        _fundDiamond(
            d,
            buffer
        );

        _realHolderOps(
            d,
            addrs
        );
    }

    /**
     * @dev The post-evacuation tail the E2E gate omits: burn the EXTRA
     * still held by the forwarder (the vault's whole remaining supply
     * after the migrated holders were burned), assert the locked v2
     * end-state — total supply exactly 0 — then reclaim ownership to the
     * original deployer. The forwarder is still the v2 master here
     * (`initiateEvacuation` only PROPOSES ownership back), so its
     * master-gated `burnSupplyBulk` still lands.
     */
    function _finishV2EndState(
        MoneyForwardContractV4 _forwarder,
        address _realOwner,
        uint256 _extra
    )
        internal
    {
        address[] memory residual = new address[](1);
        uint256[] memory residualAmounts = new uint256[](1);

        residual[0] = address(_forwarder);
        residualAmounts[0] = _extra;

        _forwarder.burnSupplyBulk(
            residual,
            residualAmounts
        );

        assertEq(
            IOldVault(cfg.oldVault).totalSupply(),
            0,
            "v2 total supply not zero after EXTRA burn"
        );

        vm.prank(
            _realOwner
        );

        IOldVault(cfg.oldVault).claimOwnership();

        assertEq(
            IOldVault(cfg.oldVault).master(),
            _realOwner,
            "v2 ownership not returned to deployer"
        );
    }

    /**
     * @dev Mirrors the "separate verified funding tx" step: the buffer
     * recovered onto the migration deployer is transferred into the
     * diamond, which now backs the migrated interest.
     */
    function _fundDiamond(
        WiseTelecomNodesDiamond _d,
        uint256 _buffer
    )
        internal
    {
        uint256 before = IERC20(cfg.token).balanceOf(
            address(_d)
        );

        _rawTokenCall(
            migrationDeployer,
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                address(_d),
                _buffer
            )
        );

        assertEq(
            IERC20(cfg.token).balanceOf(address(_d)),
            before + _buffer,
            "diamond not funded with the recovered buffer"
        );
    }

    /**
     * @dev USD leg-agnostic token call from `_from`. USDT's `transfer`
     * and `approve` return no data, so calling them through a
     * bool-returning ERC20 interface reverts on the return decode; a
     * low-level call that ignores the return works for both USDC and
     * USDT.
     */
    function _rawTokenCall(
        address _from,
        bytes memory _data
    )
        internal
    {
        vm.prank(
            _from
        );

        (
            bool ok,
        ) = cfg.token.call(
            _data
        );

        require(
            ok,
            "raw token call failed"
        );
    }

    /**
     * @dev Real snapshot holders operate on the migrated diamond:
     * claim interest, transfer shares, and a fresh depositor joins the
     * seeded queue on top of the migrated state.
     */
    function _realHolderOps(
        WiseTelecomNodesDiamond _d,
        address[] memory _addrs
    )
        internal
    {
        address holder = _firstShareHolder(
            _d,
            _addrs
        );

        if (holder == address(0)) {
            return;
        }

        deal(
            cfg.token,
            address(_d),
            IERC20(cfg.token).balanceOf(address(_d)) + 10_000_000 * 1e6
        );

        vm.warp(
            block.timestamp + 30 days
        );

        _claimAndTransfer(
            _d,
            holder
        );

        _existingHolderJoinsQueue(
            _d,
            _addrs
        );
    }

    function _claimAndTransfer(
        WiseTelecomNodesDiamond _d,
        address _holder
    )
        internal
    {
        uint256 tokenBefore = IERC20(cfg.token).balanceOf(
            _holder
        );

        vm.prank(
            _holder
        );

        uint256 claimed = IDiamondOps(address(_d)).claimInterest();

        assertGt(
            claimed,
            0,
            "seeded holder claimed nothing"
        );

        assertEq(
            IERC20(cfg.token).balanceOf(_holder),
            tokenBefore + claimed,
            "claim payout mismatch"
        );

        uint256 shares = IERC20(address(_d)).balanceOf(
            _holder
        );

        uint256 sendShares = shares / 2;

        if (sendShares == 0) {
            return;
        }

        vm.prank(
            _holder
        );

        IERC20(address(_d)).transfer(
            shareRecipient,
            sendShares
        );

        assertEq(
            IERC20(address(_d)).balanceOf(shareRecipient),
            sendShares,
            "share transfer did not land"
        );

        assertEq(
            IERC20(address(_d)).balanceOf(_holder),
            shares - sendShares,
            "sender share balance wrong after transfer"
        );
    }

    /**
     * @dev `joinQue` is a capital-neutral move of the caller's EXISTING
     * vault shares into the queue escrow (not a fresh USD deposit), so
     * a real migrated shareholder joins: the escrow (the diamond's own
     * share balance) grows by the joined amount and the holder's shrinks
     * by it, proving the migrated share ledger and the seeded queue
     * accept a new order on top of the migrated state.
     */
    function _existingHolderJoinsQueue(
        WiseTelecomNodesDiamond _d,
        address[] memory _addrs
    )
        internal
    {
        uint256 amount = IDiamondOps(address(_d)).minDepositAmount() + 1;

        address joiner = _holderWithAtLeast(
            _d,
            _addrs,
            amount
        );

        if (joiner == address(0)) {
            return;
        }

        uint256 joinerBefore = IERC20(address(_d)).balanceOf(
            joiner
        );

        uint256 escrowBefore = IERC20(address(_d)).balanceOf(
            address(_d)
        );

        vm.prank(
            joiner
        );

        IDiamondOps(address(_d)).joinQue(
            amount,
            int256(0)
        );

        assertEq(
            IERC20(address(_d)).balanceOf(joiner),
            joinerBefore - amount,
            "joiner shares not moved into the queue"
        );

        assertEq(
            IERC20(address(_d)).balanceOf(address(_d)),
            escrowBefore + amount,
            "queue escrow did not grow by the joined amount"
        );
    }

    function _holderWithAtLeast(
        WiseTelecomNodesDiamond _d,
        address[] memory _addrs,
        uint256 _min
    )
        internal
        view
        returns (address)
    {
        for (uint256 i = 0; i < _addrs.length; i++) {

            if (_addrs[i] == cfg.oldQue) {
                continue;
            }

            if (IERC20(address(_d)).balanceOf(_addrs[i]) >= _min) {
                return _addrs[i];
            }
        }

        return address(0);
    }

    function _firstShareHolder(
        WiseTelecomNodesDiamond _d,
        address[] memory _addrs
    )
        internal
        view
        returns (address)
    {
        for (uint256 i = 0; i < _addrs.length; i++) {

            if (_addrs[i] == cfg.oldQue) {
                continue;
            }

            if (IERC20(address(_d)).balanceOf(_addrs[i]) > 0) {
                return _addrs[i];
            }
        }

        return address(0);
    }
}

contract PostDeployForkEthUsdcTest is PostDeployForkBase {

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
            queFile: "data/que_state_eth_usdc.txt",
            totalDepositCap: 10_000_000 * 1e6,
            tokenName: "Wise Telecom Nodes USDC",
            tokenSymbol: "wtnUSDC"
        });
    }
}

contract PostDeployForkEthUsdtTest is PostDeployForkBase {

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
            queFile: "data/que_state_eth_usdt.txt",
            totalDepositCap: 3_000_000 * 1e6,
            tokenName: "Wise Telecom Nodes USDT",
            tokenSymbol: "wtnUSDT"
        });
    }
}

contract PostDeployForkArbUsdcTest is PostDeployForkBase {

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
            queFile: "data/que_state_arb_usdc.txt",
            totalDepositCap: 3_000_000 * 1e6,
            tokenName: "Wise Telecom Nodes USDC",
            tokenSymbol: "wtnUSDC"
        });
    }
}

contract PostDeployForkArbUsdtTest is PostDeployForkBase {

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
            queFile: "data/que_state_arb_usdt.txt",
            totalDepositCap: 3_000_000 * 1e6,
            tokenName: "Wise Telecom Nodes USDT",
            tokenSymbol: "wtnUSDT"
        });
    }
}
