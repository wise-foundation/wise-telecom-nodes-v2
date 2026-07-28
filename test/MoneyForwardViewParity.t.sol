// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Test.sol";

import {ForwardVaultERC20} from "../src/legacy/ForwardVaultERC20Legacy.sol";
import {QueContract} from "../src/legacy/que/QueContractLegacy.sol";
import {ForwardVaultERC20Migratable} from "../src/migration/ForwardVaultERC20Migratable.sol";
import {QueContractMigratable} from "../src/migration/QueContractMigratable.sol";
import {BalanceFileParser} from "./helpers/BalanceFileParser.sol";
import {QueStateParser} from "./helpers/QueStateParser.sol";
import {LiveStateRefresher} from "./helpers/LiveStateRefresher.sol";
import {QueParityVerifier} from "./helpers/QueParityVerifier.sol";

/**
 * @title MoneyForwardViewParityTest
 * @dev Mirrors the MoneyForwardDeployer deploy + replicate flow on a fork
 * pinned at each snapshot's block, then proves the freshly migrated
 * QueContract answers EVERY view function identically to the LIVE deployed
 * one — raw mapping getters over the full walked domain, out-of-domain
 * probes, and all derived views (fulfillment plans, solve/predict
 * functions, order listings) — via QueParityVerifier.
 *
 * Also proves the deploy scripts' pre-broadcast drift guard
 * (verifyFileMatchesLive) passes against the live contract at the pinned
 * block, and two negative tests prove both verifiers actually fail on
 * mismatched input.
 */
contract MoneyForwardViewParityTest is Test {

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

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000 * 1e6;

    uint256 constant INTEREST_RATE = 2000;

    uint256 constant AUTO_COMPOUND_INCENTIVE = 500;

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

    /**
     * @dev Deploys the migratable pair and replicates the queue state in
     * the exact sequence the MoneyForwardDeployer scripts use: proxy
     * balances, member slots, balance-matching mint, per-incentive
     * pointers, globals, interest-rate proxy.
     */
    function _deployAndReplicate(
        InitVars memory v
    )
        internal
        returns (
            ForwardVaultERC20Migratable newVault,
            QueContractMigratable newQue
        )
    {
        (
            address[] memory addrs,
            uint256[] memory bals,
            uint256[] memory proxies
        ) = BalanceFileParser.read(
            v.balanceFile
        );

        ForwardVaultERC20 oldVault = ForwardVaultERC20(
            v.oldVaultAddr
        );

        v.thirdPartyAddress = oldVault.thirdPartyAddress();

        v.decimals = _decimals(
            v.tokenAddr
        );

        newVault = _deployNewVault(
            v,
            addrs,
            bals
        );

        newQue = new QueContractMigratable(
            address(newVault)
        );

        _replicateProxyBalances(
            newVault,
            addrs,
            proxies
        );

        _replicateMembersAndMint(
            oldVault,
            newVault,
            newQue,
            v
        );

        _replicatePointersFromFile(
            newQue,
            v.queFile
        );

        _replicateSummaryFromFile(
            newQue,
            v.queFile
        );

        newVault.setInterestRateProxy(
            address(newQue)
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

    function _replicateMembersAndMint(
        ForwardVaultERC20 _oldVault,
        ForwardVaultERC20Migratable _newVault,
        QueContractMigratable _newQue,
        InitVars memory v
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
        ) = QueStateParser.readMembers(v.queFile);

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

        uint256 oldQueBal = _oldVault.balanceOf(
            v.oldQueAddr
        );

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

    function _runViewParity(
        string memory rpcUrl,
        bool mainnet,
        bool usdc
    )
        internal
    {
        InitVars memory v = _resolve(
            mainnet,
            usdc
        );

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

        (
            ,
            QueContractMigratable newQue
        ) = _deployAndReplicate(
            v
        );

        QueParityVerifier.verifyNewQueMatchesLiveOldQueBounded(
            QueContract(v.oldQueAddr),
            newQue,
            v.queFile
        );

        require(
            QueStateParser.readBlock(v.queFile) == pinnedBlock,
            "ViewParity: snapshot rotated mid-run"
        );
    }

    function testViewParityUSDCETHMAINNET()
        public
    {
        _runViewParity(
            vm.rpcUrl(
                "mainnet"
            ),
            true,
            true
        );
    }

    function testViewParityUSDTETHMAINNET()
        public
    {
        _runViewParity(
            vm.rpcUrl(
                "mainnet"
            ),
            true,
            false
        );
    }

    function testViewParityUSDCARBITRUM()
        public
    {
        _runViewParity(
            vm.rpcUrl(
                "arbitrum"
            ),
            false,
            true
        );
    }

    function testViewParityUSDTARBITRUM()
        public
    {
        _runViewParity(
            vm.rpcUrl(
                "arbitrum"
            ),
            false,
            false
        );
    }

    /**
     * @dev External wrappers so vm.expectRevert can catch the library
     * reverts — internal library calls inline into the test frame where
     * expectRevert cannot see them.
     */
    function exposedVerifyFileMatchesLive(
        address _oldQue,
        string memory _queFile
    )
        external
    {
        QueParityVerifier.verifyFileMatchesLive(
            QueContract(_oldQue),
            _queFile
        );
    }

    function exposedVerifyParity(
        address _oldQue,
        address _newQue
    )
        external
        view
    {
        QueParityVerifier.verifyNewQueMatchesLiveOldQue(
            QueContract(_oldQue),
            QueContract(_newQue)
        );
    }

    function exposedVerifyParityBounded(
        address _oldQue,
        address _newQue,
        string memory _queFile
    )
        external
    {
        QueParityVerifier.verifyNewQueMatchesLiveOldQueBounded(
            QueContract(_oldQue),
            QueContract(_newQue),
            _queFile
        );
    }

    function testFileGuardRevertsOnMismatchedFile()
        public
    {
        InitVars memory v = _resolve(
            false,
            true
        );

        vm.createSelectFork(
            vm.rpcUrl(
                "arbitrum"
            ),
            QueStateParser.readBlock(v.queFile)
        );

        vm.expectRevert();
        this.exposedVerifyFileMatchesLive(
            v.oldQueAddr,
            "data/que_state_arb_usdt.txt"
        );
    }

    function testParityRevertsOnCorruptedSlot()
        public
    {
        InitVars memory v = _resolve(
            false,
            true
        );

        vm.createSelectFork(
            vm.rpcUrl(
                "arbitrum"
            ),
            QueStateParser.readBlock(v.queFile)
        );

        (
            ,
            QueContractMigratable newQue
        ) = _deployAndReplicate(
            v
        );

        (
            int256 corruptedInc,
            uint256 corruptedId
        ) = _corruptFirstLiveMember(
            newQue,
            v.queFile
        );

        vm.expectRevert(
            bytes(
                string.concat(
                    "QueParityVerifier: returndata mismatch QueMemberByIdAndIncentive/",
                    vm.toString(corruptedInc),
                    "/",
                    vm.toString(corruptedId)
                )
            )
        );
        this.exposedVerifyParityBounded(
            v.oldQueAddr,
            address(newQue),
            v.queFile
        );
    }

    function _corruptFirstLiveMember(
        QueContractMigratable _newQue,
        string memory _queFile
    )
        internal
        returns (
            int256 corruptedInc,
            uint256 corruptedId
        )
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
            if (mAmounts[j] > 0) {
                _newQue.setQueMember(
                    mIds[j],
                    mIncs[j],
                    mAddrs[j],
                    mAmounts[j] + 1,
                    mTails[j],
                    mHeads[j]
                );
                return (
                    mIncs[j],
                    mIds[j]
                );
            }
        }

        if (mIncs.length > 0) {
            _newQue.setQueMember(
                mIds[0],
                mIncs[0],
                mAddrs[0],
                mAmounts[0] + 1,
                mTails[0],
                mHeads[0]
            );
            return (
                mIncs[0],
                mIds[0]
            );
        }

        revert(
            "no member row in file"
        );
    }
}
