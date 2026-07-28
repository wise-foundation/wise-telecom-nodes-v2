// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.29;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ForwardVaultERC20Migratable} from "../../src/migration/ForwardVaultERC20Migratable.sol";
import {QueContractMigratable} from "../../src/migration/QueContractMigratable.sol";
import {QueContract} from "../../src/legacy/que/QueContractLegacy.sol";
import {BalanceFileParser} from "../../test/helpers/BalanceFileParser.sol";
import {QueStateParser} from "../../test/helpers/QueStateParser.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Openly-mintable TestUSD surface (the concrete =0.8.36 token is
 * deployed via `deployCode`).
 */
interface ITestUSD {

    function mint(
        address _to,
        uint256 _amount
    )
        external;
}

/**
 * @dev V4 evacuator surface (concrete =0.8.36 contract via
 * `deployCode`).
 */
interface IForwarderV4 {

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
 * @title RehearseEvacuationTestnet
 * @dev Stands up a COMPLETE mock of the live v2 system on a testnet so
 * the v2 -> v3 migration can be rehearsed in real wall-clock time
 * before mainnet. Deploys, over a fresh mintable `TestUSD`:
 *   - a mock v2 vault (`ForwardVaultERC20Migratable`) seeded with the
 *     real mainnet holder balances + proxy locks from the snapshot,
 *   - a mock v2 queue (`QueContractMigratable`) seeded with the full
 *     live queue state (members, per-incentive pointers, globals),
 *   - a `MockPoolManagerV4` pre-funded with a realistic borrowable L,
 *   - a `MoneyForwardContractV4` pointed at the mock vault + mock
 *     PoolManager.
 * Then, in-broadcast, it takes over the mock vault, mints EXTRA
 * (sized for a ~T_target crossing) and burns the migrated holders.
 * The real-time wait and `initiateEvacuation` are driven off-chain by
 * `tools/rehearse-evacuation.ts` (forge cannot sleep on a live chain).
 * Run with `forge script` (no `--broadcast`) for a local simulation of
 * the full mock stand-up, or with `--broadcast` on a testnet.
 *
 * Required env (no defaults — a missing value aborts):
 *   PRIVATE_KEY, REHEARSAL_BALANCE_FILE, REHEARSAL_QUE_FILE,
 *   REHEARSAL_PRIME — `true` runs the original single-broadcast
 *   takeover-and-prime tail; `false` skips it so the diamond can be
 *   migration-seeded against the intact mock first, with
 *   `PrimeRehearsalEvacuation` performing the deferred prime.
 *   Explicit on purpose: a silent default of true would burn the
 *   holders and poison a pending seed.
 *
 * Optional env:
 *   REHEARSAL_TARGET_SECONDS (default 600), REHEARSAL_BUFFER
 *   (default 100k * 1e6), REHEARSAL_USD — reuses an already-deployed
 *   mintable TestUSD (so the mock v2 system shares the canonical
 *   diamond's underlying, as mainnet does) instead of deploying a
 *   fresh one; the same name feeds `PrimeRehearsalEvacuation` and
 *   `tools/rehearse-evacuation.ts` downstream.
 */
contract RehearseEvacuationTestnet is Script {

    uint256 constant INTEREST_RATE = 2000;

    uint256 constant AUTO_COMPOUND_INCENTIVE = 500;

    uint8 constant USD_DECIMALS = 6;

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;

    uint256 constant SECONDS_PER_YEAR_SCALED = 157_700_000;

    struct Ctx {
        address usd;
        address mockVault;
        address mockQue;
        address poolManager;
        address forwarder;
        address[] addrs;
        uint256[] balances;
        uint256[] proxyBalances;
        uint256 buffer;
        uint256 extra;
        uint256 targetSeconds;
    }

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        string memory balanceFile = vm.envString(
            "REHEARSAL_BALANCE_FILE"
        );

        string memory queFile = vm.envString(
            "REHEARSAL_QUE_FILE"
        );

        Ctx memory c;

        c.targetSeconds = vm.envOr(
            "REHEARSAL_TARGET_SECONDS",
            uint256(600)
        );

        c.buffer = vm.envOr(
            "REHEARSAL_BUFFER",
            uint256(100_000 * 1e6)
        );

        (
            c.addrs,
            c.balances,
            c.proxyBalances
        ) = BalanceFileParser.read(
            balanceFile
        );

        vm.startBroadcast(
            privKey
        );

        _deployMockSystem(
            c
        );

        _seedQueue(
            c,
            queFile
        );

        _fundAndArm(
            c
        );

        if (vm.envBool("REHEARSAL_PRIME")) {
            _takeoverAndPrime(
                c
            );
        }

        vm.stopBroadcast();

        _log(
            c
        );
    }

    function _deployMockSystem(
        Ctx memory _c
    )
        internal
    {
        address usdOverride = vm.envOr(
            "REHEARSAL_USD",
            address(0)
        );

        _c.usd = usdOverride == address(0)
            ? deployCode(
                "TestUSD.sol:TestUSD",
                abi.encode(
                    "Rehearsal USD",
                    "rUSD",
                    USD_DECIMALS
                )
            )
            : usdOverride;

        ForwardVaultERC20Migratable mockVault = new ForwardVaultERC20Migratable(
            _c.usd,
            vm.addr(vm.envUint("PRIVATE_KEY")),
            address(0),
            _c.addrs,
            _c.balances,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INCENTIVE,
            USD_DECIMALS,
            "Mock V2 Vault",
            "MV2"
        );

        _c.mockVault = address(
            mockVault
        );

        QueContractMigratable mockQue = new QueContractMigratable(
            _c.mockVault
        );

        _c.mockQue = address(
            mockQue
        );

        for (uint256 i; i < _c.addrs.length; ++i) {
            if (_c.proxyBalances[i] > 0) {
                mockVault.setProxyBalance(
                    _c.addrs[i],
                    _c.proxyBalances[i]
                );
            }
        }

        mockVault.setInterestRateProxy(
            _c.mockQue
        );

        _c.poolManager = deployCode(
            "MockPoolManagerV4.sol:MockPoolManagerV4"
        );
    }

    function _seedQueue(
        Ctx memory _c,
        string memory _queFile
    )
        internal
    {
        _seedQueMembers(
            _c.mockQue,
            _queFile
        );

        _seedQuePointers(
            _c.mockQue,
            _queFile
        );

        _seedQueGlobals(
            _c.mockQue,
            _queFile
        );
    }

    function _seedQueMembers(
        address _mockQue,
        string memory _queFile
    )
        internal
    {
        (
            int256[] memory mIncs,
            uint256[] memory mIds,
            address[] memory mAddrs,
            uint256[] memory mAmounts,
            uint256[] memory mTails,
            uint256[] memory mHeads
        ) = QueStateParser.readMembers(
            _queFile
        );

        QueContractMigratable mockQue = QueContractMigratable(
            _mockQue
        );

        for (uint256 j; j < mIncs.length; ++j) {
            mockQue.setQueMember(
                mIds[j],
                mIncs[j],
                mAddrs[j],
                mAmounts[j],
                mTails[j],
                mHeads[j]
            );
        }
    }

    function _seedQuePointers(
        address _mockQue,
        string memory _queFile
    )
        internal
    {
        (
            int256[] memory incs,
            uint256[] memory earliest,
            uint256[] memory current,
            uint256[] memory active,
            bool[] memory allowed
        ) = QueStateParser.readPointers(
            _queFile
        );

        QueContractMigratable mockQue = QueContractMigratable(
            _mockQue
        );

        for (uint256 i; i < incs.length; ++i) {
            mockQue.setPerIncentiveState(
                incs[i],
                earliest[i],
                current[i],
                active[i],
                allowed[i]
            );
        }
    }

    function _seedQueGlobals(
        address _mockQue,
        string memory _queFile
    )
        internal
    {
        (
            uint256 totalActive,
            bool negNotAllowed,
            uint256 minDeposit
        ) = QueStateParser.readSummary(
            _queFile
        );

        QueContractMigratable(_mockQue).setGlobalState(
            totalActive,
            minDeposit,
            negNotAllowed
        );
    }

    function _fundAndArm(
        Ctx memory _c
    )
        internal
    {
        ITestUSD(_c.usd).mint(
            _c.mockVault,
            _c.buffer
        );

        ITestUSD(_c.usd).mint(
            _c.poolManager,
            _c.buffer * 50
        );

        address deployer = vm.addr(
            vm.envUint("PRIVATE_KEY")
        );

        _c.forwarder = deployCode(
            "MoneyForwardContractV4.sol:MoneyForwardContractV4",
            abi.encode(
                _c.mockVault,
                _c.usd,
                deployer,
                deployer,
                _c.poolManager
            )
        );
    }

    function _takeoverAndPrime(
        Ctx memory _c
    )
        internal
    {
        ForwardVaultERC20Migratable(_c.mockVault).proposeOwner(
            _c.forwarder
        );

        IForwarderV4(_c.forwarder).acceptOwnerOldVault();

        _c.extra = _c.buffer
            * SECONDS_PER_YEAR_SCALED
            / _c.targetSeconds;

        IForwarderV4(_c.forwarder).mintSupply(
            _c.extra
        );

        IForwarderV4(_c.forwarder).burnSupplyBulk(
            _c.addrs,
            _c.balances
        );
    }

    function _log(
        Ctx memory _c
    )
        internal
        view
    {
        console2.log(
            "REHEARSAL_USD",
            _c.usd
        );

        console2.log(
            "REHEARSAL_MOCK_VAULT",
            _c.mockVault
        );

        console2.log(
            "REHEARSAL_MOCK_QUE",
            _c.mockQue
        );

        console2.log(
            "REHEARSAL_POOL_MANAGER",
            _c.poolManager
        );

        console2.log(
            "REHEARSAL_FORWARDER",
            _c.forwarder
        );

        console2.log(
            "REHEARSAL_BUFFER",
            _c.buffer
        );

        console2.log(
            "REHEARSAL_EXTRA",
            _c.extra
        );

        console2.log(
            "REHEARSAL_TMIN_SECONDS",
            _c.targetSeconds
        );
    }
}
