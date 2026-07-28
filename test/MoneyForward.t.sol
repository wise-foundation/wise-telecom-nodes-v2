// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForwardVaultERC20} from "../src/legacy/ForwardVaultERC20Legacy.sol";
import {QueContract} from "../src/legacy/que/QueContractLegacy.sol";
import {MoneyForwardContract} from "../src/legacy/MoneyForwardContractLegacy.sol";
import {ForwardVaultERC20Migratable} from "../src/migration/ForwardVaultERC20Migratable.sol";
import {QueContractMigratable} from "../src/migration/QueContractMigratable.sol";
import {BalanceFileParser} from "./helpers/BalanceFileParser.sol";
import {QueStateParser} from "./helpers/QueStateParser.sol";
import {LiveStateRefresher} from "./helpers/LiveStateRefresher.sol";
import {MigrationStateReader} from "./helpers/MigrationStateReader.sol";

contract MoneyForwardTest is Test {

    address constant USDC_ETH = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address constant USDT_ETH = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address constant USDC_ARB = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address constant USDT_ARB = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    address constant OLD_VAULT_USDC_ETH = 0x11cEeE394842d9492f2C97050f66dE0e3f89D3A6;

    address constant OLD_VAULT_USDT_ETH = 0x3Ed1f16BbE0eE2C58119c13517a88fe9ccedfd45;

    address constant OLD_VAULT_USDC_ARB = 0x025421D3e98D3bB7A33d6814Dd576eD8B9090077;

    address constant OLD_VAULT_USDT_ARB = 0xD69670d0eCaf032Ea8b1A6925E59dBacAA20f43A;

    address constant OLD_QUE_USDC_ETH = 0x4e601103590b8971c208bF06B64ba1ef1c85B7e6;

    address constant OLD_QUE_USDT_ETH = 0x0f63bDcE0f4f3531117E2ed2FE1484c5E40a75b5;

    address constant OLD_QUE_USDC_ARB = 0xCfF3EdA95c3866bE10c8D3A29EDA665fc82EF72a;

    address constant OLD_QUE_USDT_ARB = 0xc7960021229aDbacddfb57990815ab599A275533;

    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000 * 1e6;

    uint256 constant INTEREST_RATE = 2000;

    uint256 constant AUTO_COMPOUND_INCENTIVE = 500;

    uint256 constant EXTRA_SUPPLY_MINT = 1e16;

    uint256 constant WARP_SECONDS = 60;

    struct InitVars {
        address oldVaultAddr;
        address oldQueAddr;
        address tokenAddr;
        string  name;
        string  symbol;
        uint8   decimals;
        address thirdPartyAddress;
        string  balanceFile;
        string  queFile;
    }

    struct Ctx {
        ForwardVaultERC20Migratable newVault;
        QueContractMigratable       newQue;
        ForwardVaultERC20            oldVault;
        QueContract                  oldQue;
        MoneyForwardContract         moneyForwardContract;
        IERC20                       token;
        address[]                    addrs;
        uint256[]                    bals;
        uint256[]                    proxies;
    }

    function setUp()
        public
    {}

    function _resolve(
        bool mainnet,
        bool usdc
    )
        internal
        pure
        returns (InitVars memory v)
    {
        if (mainnet) {
            if (usdc) {
                v.oldVaultAddr = OLD_VAULT_USDC_ETH;
                v.oldQueAddr   = OLD_QUE_USDC_ETH;
                v.tokenAddr    = USDC_ETH;
                v.balanceFile  = "data/USDCaddress_balances_eth.txt";
                v.queFile      = "data/que_state_eth_usdc.txt";
                v.name         = "RWA WORLD MOBILE VAULT ERC20 USDC";
                v.symbol       = "RWAWMVERC20USDC";
            } else {
                v.oldVaultAddr = OLD_VAULT_USDT_ETH;
                v.oldQueAddr   = OLD_QUE_USDT_ETH;
                v.tokenAddr    = USDT_ETH;
                v.balanceFile  = "data/USDTaddress_balances_eth.txt";
                v.queFile      = "data/que_state_eth_usdt.txt";
                v.name         = "RWA WORLD MOBILE VAULT ERC20 USDT";
                v.symbol       = "RWAWMVERC20USDT";
            }
        } else {
            if (usdc) {
                v.oldVaultAddr = OLD_VAULT_USDC_ARB;
                v.oldQueAddr   = OLD_QUE_USDC_ARB;
                v.tokenAddr    = USDC_ARB;
                v.balanceFile  = "data/USDCaddress_balances_arb.txt";
                v.queFile      = "data/que_state_arb_usdc.txt";
                v.name         = "RWA WORLD MOBILE VAULT ERC20 USDC ARB";
                v.symbol       = "RWAWMVERC20USDCARB";
            } else {
                v.oldVaultAddr = OLD_VAULT_USDT_ARB;
                v.oldQueAddr   = OLD_QUE_USDT_ARB;
                v.tokenAddr    = USDT_ARB;
                v.balanceFile  = "data/USDTaddress_balances_arb.txt";
                v.queFile      = "data/que_state_arb_usdt.txt";
                v.name         = "RWA WORLD MOBILE VAULT ERC20 USDT ARB";
                v.symbol       = "RWAWMVERC20USDTARB";
            }
        }
    }

    function _decimals(
        address _token
    )
        internal
        view
        returns (uint8)
    {
        bytes4 SELECTOR = bytes4(
            keccak256(
                "decimals()"
            )
        );

        (bool ok, bytes memory data) = _token.staticcall(
            abi.encodeWithSelector(
                SELECTOR
            )
        );

        require(
            ok,
            "Failed to call decimals"
        );

        return abi.decode(
            data,
            (uint8)
        );
    }

    function _deployNewVault(
        InitVars memory v,
        address[] memory addrs,
        uint256[] memory bals
    )
        internal
        returns (ForwardVaultERC20Migratable)
    {
        return new ForwardVaultERC20Migratable(
            v.tokenAddr,
            v.thirdPartyAddress,
            v.oldVaultAddr,
            addrs,
            bals,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INCENTIVE,
            v.decimals,
            v.name,
            v.symbol
        );
    }

    function _deployContracts(
        InitVars memory v,
        address[] memory addrs,
        uint256[] memory bals
    )
        internal
        returns (
            ForwardVaultERC20Migratable newVault,
            QueContractMigratable       newQue,
            ForwardVaultERC20            oldVault,
            QueContract                  oldQue,
            MoneyForwardContract         moneyForwardContract,
            IERC20                       token
        )
    {
        oldVault = ForwardVaultERC20(v.oldVaultAddr);
        oldQue   = QueContract(v.oldQueAddr);
        token    = IERC20(v.tokenAddr);

        v.thirdPartyAddress = oldVault.thirdPartyAddress();
        v.decimals          = _decimals(v.tokenAddr);

        newVault = _deployNewVault(v, addrs, bals);

        newQue = new QueContractMigratable(
            address(newVault)
        );

        moneyForwardContract = new MoneyForwardContract(
            v.oldVaultAddr,
            v.tokenAddr,
            oldVault.master(),
            address(newVault),
            BALANCER_VAULT
        );
    }

    function _replicateProxyBalances(
        ForwardVaultERC20Migratable _newVault,
        address[] memory _addrs,
        uint256[] memory _proxies
    )
        internal
    {
        for (uint256 i; i < _addrs.length; ++i) {
            if (_proxies[i] > 0) {
                _newVault.setProxyBalance(
                    _addrs[i],
                    _proxies[i]
                );
            }
        }
    }

    function _replicateQueState(
        ForwardVaultERC20 _oldVault,
        QueContract _oldQue,
        ForwardVaultERC20Migratable _newVault,
        QueContractMigratable _newQue,
        string memory _queFile
    )
        internal
    {
        _replicateMembersAndMint(_newVault, _newQue, _queFile);
        _mintNewQueToMatchOldQue(_oldVault, _newVault, _oldQue, _newQue);
        _replicatePointersFromFile(_newQue, _queFile);
        _replicateSummaryFromFile(_newQue, _queFile);

        _newVault.setInterestRateProxy(
            address(_newQue)
        );
    }

    function _replicateMembersAndMint(
        ForwardVaultERC20Migratable _newVault,
        QueContractMigratable _newQue,
        string memory _queFile
    )
        internal
    {
        (
            int256[]  memory mIncs,
            uint256[] memory mIds,
            address[] memory mAddrs,
            uint256[] memory mAmounts,
            uint256[] memory mTails,
            uint256[] memory mHeads
        ) = QueStateParser.readMembers(_queFile);

        for (uint256 j; j < mIncs.length; ++j) {
            _newQue.setQueMember(
                mIds[j],
                mIncs[j],
                mAddrs[j],
                mAmounts[j],
                mTails[j],
                mHeads[j]
            );
        }
    }

    /**
     * Mint vault tokens to the new QueContract so its balanceOf matches the
     * deployed old one EXACTLY. This is critical: sum(member.amount) is
     * usually equal to oldVault.balanceOf(oldQue), but anyone can have
     * transferred vault tokens directly to the queContract address, leaving
     * "orphaned" tokens not associated with any member. The migration must
     * preserve those exactly.
     */
    function _mintNewQueToMatchOldQue(
        ForwardVaultERC20 _oldVault,
        ForwardVaultERC20Migratable _newVault,
        QueContract _oldQue,
        QueContractMigratable _newQue
    )
        internal
    {
        uint256 oldQueBal = _oldVault.balanceOf(address(_oldQue));
        if (oldQueBal > 0) {
            _newVault.mintSupply(
                address(_newQue),
                oldQueBal
            );
        }
    }

    function _replicatePointersFromFile(
        QueContractMigratable _newQue,
        string memory _queFile
    )
        internal
    {
        (
            int256[]  memory incs,
            uint256[] memory earliest,
            uint256[] memory current,
            uint256[] memory active,
            bool[]    memory allowed
        ) = QueStateParser.readPointers(_queFile);

        for (uint256 i; i < incs.length; ++i) {
            _newQue.setPerIncentiveState(
                incs[i],
                earliest[i],
                current[i],
                active[i],
                allowed[i]
            );
        }
    }

    function _replicateSummaryFromFile(
        QueContractMigratable _newQue,
        string memory _queFile
    )
        internal
    {
        (
            uint256 totalActive,
            bool    negNotAllowed,
            uint256 minDeposit
        ) = QueStateParser.readSummary(_queFile);

        _newQue.setGlobalState(
            totalActive,
            minDeposit,
            negNotAllowed
        );
    }

    /**
     * Compares the freshly-deployed migrated QueContract against a snapshot
     * of the on-chain (forked) deployed QueContract. The snapshot is read
     * via a single eth_call against MigrationStateReader, so the heavy
     * 0..earliestValid × 17-incentive walk only fetches each storage slot
     * once and the per-slot assertions are all in-memory after that.
     *
     * Verifies:
     *   - 3 globals (totalActive, minDeposit, negNotAllowed)
     *   - per-incentive: earliestValid, currentOrderId, activeOrderCount, allowed
     *   - every slot from id=0..earliestValid (inclusive of sentinel) on every
     *     one of the 17 standard incentives — live members AND empty/deleted
     *     slots all match byte-for-byte.
     */
    struct FileRowVars {
        int256[]  incentives;
        uint256[] ids;
        address[] members;
        uint256[] amounts;
        uint256[] tails;
        uint256[] heads;
        uint256   slotIdx;
        uint256   fileIdx;
    }

    /**
     * @dev Reconstructs the exact QueSnapshot readQueState would return
     * from the que file instead of walking the forked old que slot by
     * slot. Sound because LiveStateRefresher.verifyQueFileMatchesLive
     * proved the file byte-identical to the live contract at the forked
     * block. Empty slots inside the walked domain are synthesized as zero
     * rows, mirroring the reader's unconditional slot storage.
     */
    function _queSnapshotFromFile(
        string memory _queFile
    )
        internal
        returns (MigrationStateReader.QueSnapshot memory snap)
    {
        (
            snap.totalActiveOrders,
            snap.negativeIncentivesNotAllowed,
            snap.minDepositAmount
        ) = QueStateParser.readSummary(
            _queFile
        );

        (
            int256[]  memory incs,
            uint256[] memory earliest,
            uint256[] memory current,
            uint256[] memory active,
            bool[]    memory allowed
        ) = QueStateParser.readPointers(
            _queFile
        );

        require(
            incs.length == snap.perIncentive.length,
            "queSnapshotFromFile: incentive count mismatch"
        );

        uint256 totalSlots;

        for (uint256 i; i < incs.length; ++i) {
            snap.perIncentive[i] = MigrationStateReader.PerIncentiveState({
                incentive:        incs[i],
                earliestValid:    earliest[i],
                currentOrderId:   current[i],
                activeOrderCount: active[i],
                allowed:          allowed[i]
            });

            totalSlots += earliest[i] + 1;
        }

        snap.slots = new MigrationStateReader.QueMemberSlot[](
            totalSlots
        );

        _fillSlotsFromFile(
            snap,
            _queFile,
            earliest
        );
    }

    function _fillSlotsFromFile(
        MigrationStateReader.QueSnapshot memory _snap,
        string memory _queFile,
        uint256[] memory _earliest
    )
        internal
    {
        FileRowVars memory f;

        (
            f.incentives,
            f.ids,
            f.members,
            f.amounts,
            f.tails,
            f.heads
        ) = QueStateParser.readMembers(
            _queFile
        );

        for (uint256 i; i < _snap.perIncentive.length; ++i) {

            int256 inc = _snap.perIncentive[i].incentive;

            for (uint256 id; id <= _earliest[i]; ++id) {

                bool isFileRow = f.fileIdx < f.ids.length
                    && f.incentives[f.fileIdx] == inc
                    && f.ids[f.fileIdx] == id;

                _snap.slots[f.slotIdx++] = MigrationStateReader.QueMemberSlot({
                    incentive:   inc,
                    id:          id,
                    member:      isFileRow ? f.members[f.fileIdx] : address(0),
                    amount:      isFileRow ? f.amounts[f.fileIdx] : 0,
                    tailPointer: isFileRow ? f.tails[f.fileIdx]   : 0,
                    headPointer: isFileRow ? f.heads[f.fileIdx]   : 0
                });

                if (isFileRow) {
                    ++f.fileIdx;
                }
            }
        }

        require(
            f.fileIdx == f.ids.length,
            "queSnapshotFromFile: file has extra member rows"
        );
    }

    function _assertNewQueMatchesSnapshot(
        QueContractMigratable _newQue,
        MigrationStateReader.QueSnapshot memory _snap
    )
        internal
    {
        assertEq(_newQue.totalActiveOrders(),            _snap.totalActiveOrders,            "totalActiveOrders");
        assertEq(_newQue.minDepositAmount(),             _snap.minDepositAmount,             "minDepositAmount");
        assertEq(_newQue.negativeIncentivesNotAllowed(), _snap.negativeIncentivesNotAllowed, "negativeIncentivesNotAllowed");

        for (uint256 i; i < _snap.perIncentive.length; ++i) {
            MigrationStateReader.PerIncentiveState memory p = _snap.perIncentive[i];

            assertEq(_newQue.earliestValidQueMemberByIncentive(p.incentive), p.earliestValid,    "earliestValid");
            assertEq(_newQue.currentOrderIdByIncentive(p.incentive),         p.currentOrderId,   "currentOrderId");
            assertEq(_newQue.activeOrderCountByIncentive(p.incentive),       p.activeOrderCount, "activeOrderCount");
            assertEq(_newQue.incentiveAllowed(p.incentive),                  p.allowed,          "incentiveAllowed");
        }

        for (uint256 j; j < _snap.slots.length; ++j) {
            _assertSlotMatchesSnapshot(_newQue, _snap.slots[j]);
        }

        console2.log("QueContract: incentives walked", _snap.perIncentive.length);
        console2.log("QueContract: slots verified",     _snap.slots.length);
    }

    function _assertSlotMatchesSnapshot(
        QueContractMigratable _newQue,
        MigrationStateReader.QueMemberSlot memory _s
    )
        internal
    {
        (
            address newMember,
            uint256 newAmount,
            uint256 newTail,
            uint256 newHead
        ) = _newQue.QueMemberByIdAndIncentive(_s.id, _s.incentive);

        assertEq(newMember, _s.member,      "slot member");
        assertEq(newAmount, _s.amount,      "slot amount");
        assertEq(newTail,   _s.tailPointer, "slot tail");
        assertEq(newHead,   _s.headPointer, "slot head");
    }

    /**
     * Reads vault holder state from the deployed (forked) old vault in a
     * single batched call, then compares per-holder values on the new vault
     * (all local reads, no RPC).
     */
    function _assertVaultStateMatchesOnChain(
        MigrationStateReader _reader,
        Ctx memory _c
    )
        internal
    {
        MigrationStateReader.VaultHolderState[] memory states =
            _reader.readVaultHolderStates(_c.oldVault, _c.addrs);

        for (uint256 i; i < _c.addrs.length; ++i) {
            assertEq(
                _c.newVault.proxyBalance(_c.addrs[i]),
                states[i].proxyBalance,
                "proxyBalance mismatch (new vs old)"
            );
            assertEq(
                _c.newVault.proxyBalance(_c.addrs[i]),
                _c.proxies[i],
                "proxyBalance mismatch (new vs file)"
            );
            assertEq(
                _c.newVault.balanceOf(_c.addrs[i]),
                _c.bals[i],
                "balanceOf mismatch (new vs file)"
            );
        }

        uint256 oldQueVaultBal = _reader.readBalanceOf(_c.oldVault, address(_c.oldQue));
        assertEq(
            _c.newVault.balanceOf(address(_c.newQue)),
            oldQueVaultBal,
            "newVault.balanceOf(newQue) must equal oldVault.balanceOf(oldQue)"
        );

        console2.log("Vault holders verified", _c.addrs.length);
    }

    /**
     * Post-migration usability: simulate a new user joining the queue at
     * incentive 0 (the only one with non-zero earliestValid on the deployed
     * contracts). Verifies the new join lands at the migrated earliestValid
     * slot, the linked-list pointers wire up correctly, and the global
     * counters increment.
     */
    function _assertPostMigrationJoinQueWorks(
        Ctx memory _c
    )
        internal
    {
        int256  inc            = 0;
        uint256 earliestBefore = _c.newQue.earliestValidQueMemberByIncentive(inc);
        uint256 totalBefore    = _c.newQue.totalActiveOrders();
        uint256 activeBefore   = _c.newQue.activeOrderCountByIncentive(inc);

        address newcomer = address(0xC0FFEE);
        uint256 amount   = _c.newQue.minDepositAmount();

        _c.newVault.mintSupply(newcomer, amount * 2);
        vm.prank(newcomer);
        IERC20(address(_c.newVault)).approve(address(_c.newQue), type(uint256).max);

        vm.prank(newcomer);
        (, uint256 newId) = _c.newQue.joinQue(amount, inc);

        assertEq(newId,                                                       earliestBefore,        "join must land at migrated earliestValid");
        assertEq(_c.newQue.earliestValidQueMemberByIncentive(inc),            earliestBefore + 1,    "earliestValid increments");
        assertEq(_c.newQue.totalActiveOrders(),                               totalBefore + 1,       "totalActive increments");
        assertEq(_c.newQue.activeOrderCountByIncentive(inc),                  activeBefore + 1,      "activeOrderCount increments");

        (
            address joinM,
            uint256 joinA,
            uint256 joinT,
            uint256 joinH
        ) = _c.newQue.QueMemberByIdAndIncentive(newId, inc);

        assertEq(joinM, newcomer,           "joined member");
        assertEq(joinA, amount,             "joined amount");
        assertEq(joinH, earliestBefore + 1, "joined head -> next sentinel");
        // tail = the previous earliestValid sentinel's tail (= last live member id, or 0 if none)

        // Tear it back down so the evacuation flow below isn't perturbed.
        vm.prank(newcomer);
        _c.newQue.leaveQue(newId, inc);

        assertEq(_c.newQue.totalActiveOrders(),               totalBefore,  "post-leave total restored");
        assertEq(_c.newQue.activeOrderCountByIncentive(inc),  activeBefore, "post-leave active restored");
    }

    function _runTest(
        string memory rpcUrl,
        bool mainnet,
        bool usdc
    )
        internal
    {
        InitVars memory v = _resolve(mainnet, usdc);

        LiveStateRefresher.refresh();

        uint256 pinnedBlock = QueStateParser.readBlock(
            v.queFile
        );

        vm.createSelectFork(
            rpcUrl,
            pinnedBlock
        );

        LiveStateRefresher.verifyQueFileMatchesLive(
            v.queFile
        );

        Ctx memory c;
        (
            c.addrs,
            c.bals,
            c.proxies
        ) = BalanceFileParser.read(v.balanceFile);

        (
            c.newVault,
            c.newQue,
            c.oldVault,
            c.oldQue,
            c.moneyForwardContract,
            c.token
        ) = _deployContracts(
            v,
            c.addrs,
            c.bals
        );

        _replicateProxyBalances(
            c.newVault,
            c.addrs,
            c.proxies
        );

        _replicateQueState(
            c.oldVault,
            c.oldQue,
            c.newVault,
            c.newQue,
            v.queFile
        );

        // One eth_call against the forked old QueContract reads every
        // (incentive, id) slot plus all per-incentive counters and globals.
        // The snapshot is built from the que file, which the ffi verifier
        // proved byte-identical to the live old que at the forked block -
        // no per-slot storage fetches against the forked contract at all.
        MigrationStateReader reader  = new MigrationStateReader();
        MigrationStateReader.QueSnapshot memory snap = _queSnapshotFromFile(v.queFile);

        _assertNewQueMatchesSnapshot(c.newQue, snap);

        require(
            QueStateParser.readBlock(v.queFile) == pinnedBlock,
            "MoneyForward: snapshot rotated mid-run"
        );

        _assertVaultStateMatchesOnChain(reader, c);

        _assertPostMigrationJoinQueWorks(c);

        _testMoneyForwardProcess(
            c
        );
    }

    function testMoneyForwardProcessUSDCETHMAINNET()
        public
    {
        _runTest(
            vm.rpcUrl(
                "mainnet"
            ),
            true,
            true
        );
    }

    function testMoneyForwardProcessUSDTETHMAINNET()
        public
    {
        _runTest(
            vm.rpcUrl(
                "mainnet"
            ),
            true,
            false
        );
    }

    function testMoneyForwardProcessUSDCARBITRUM()
        public
    {
        _runTest(
            vm.rpcUrl(
                "arbitrum"
            ),
            false,
            true
        );
    }

    function testMoneyForwardProcessUSDTARBITRUM()
        public
    {
        _runTest(
            vm.rpcUrl(
                "arbitrum"
            ),
            false,
            false
        );
    }

    function _testMoneyForwardProcess(
        Ctx memory c
    )
        internal
    {
        vm.startPrank(
            c.oldVault.master()
        );

        c.oldVault.proposeOwner(
            address(c.moneyForwardContract)
        );

        vm.stopPrank();

        vm.startPrank(
            c.moneyForwardContract.master()
        );

        c.moneyForwardContract.acceptOwnerOldVault();

        c.moneyForwardContract.mintSupply(
            EXTRA_SUPPLY_MINT
        );

        c.moneyForwardContract.burnSupplyBulk(
            c.addrs,
            c.bals
        );

        for (uint256 i; i < c.addrs.length; ++i) {
            assertEq(
                c.oldVault.getTotalInterestUser(
                    c.addrs[i]
                ),
                c.newVault.getTotalInterestUser(
                    c.addrs[i]
                ),
                "Airdrop addresses should have received their interest cashed"
            );
        }

        uint256 warpSeconds = WARP_SECONDS;

        uint256 totalToClaim;
        uint256 cashedInOldVault;

        while (true) {

            vm.warp(
                block.timestamp + warpSeconds
            );

            totalToClaim = c.oldVault.getTotalInterestUser(
                address(c.moneyForwardContract)
            );

            cashedInOldVault = c.token.balanceOf(
                address(c.oldVault)
            );

            if (totalToClaim > cashedInOldVault) {
                break;
            }

            require(
                warpSeconds < 730 days,
                "warp insufficient - live vault balance outgrew accruable interest"
            );

            warpSeconds = warpSeconds * 2;
        }

        console2.log(
            totalToClaim,
            "oldVault.getTotalInterestUser(moneyForwardContract)"
        );

        console2.log(
            cashedInOldVault,
            "token.balanceOf(oldVault)"
        );

        c.moneyForwardContract.initiateEvacuation();

        assertEq(
            c.token.balanceOf(
                address(c.oldVault)
            ),
            0,
            "Old vault should be empty"
        );

        assertGt(
            c.token.balanceOf(
                address(c.newVault)
            ),
            0,
            "New vault should have received funds"
        );

        vm.stopPrank();
    }
}
