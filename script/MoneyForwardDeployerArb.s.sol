// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ForwardVaultERC20} from "../src/legacy/ForwardVaultERC20Legacy.sol";
import {QueContract} from "../src/legacy/que/QueContractLegacy.sol";
import {MoneyForwardContract} from "../src/legacy/MoneyForwardContractLegacy.sol";
import {ForwardVaultERC20Migratable} from "../src/migration/ForwardVaultERC20Migratable.sol";
import {QueContractMigratable} from "../src/migration/QueContractMigratable.sol";
import {BalanceFileParser} from "../test/helpers/BalanceFileParser.sol";
import {QueStateParser} from "../test/helpers/QueStateParser.sol";
import {QueParityVerifier} from "../test/helpers/QueParityVerifier.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MoneyForwardDeployerArb is Script {

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    address constant OLD_VAULT_USDC = 0x025421D3e98D3bB7A33d6814Dd576eD8B9090077;

    address constant OLD_VAULT_USDT = 0xD69670d0eCaf032Ea8b1A6925E59dBacAA20f43A;

    address constant OLD_QUE_USDC   = 0xCfF3EdA95c3866bE10c8D3A29EDA665fc82EF72a;

    address constant OLD_QUE_USDT   = 0xc7960021229aDbacddfb57990815ab599A275533;

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000 * 1e6;

    uint256 constant INTEREST_RATE = 2000;

    uint256 constant AUTO_COMPOUND_INCENTIVE = 500;

    uint256 constant EXTRA_SUPPLY_MINT = 2e15;

    struct DeploymentContext {
        ForwardVaultERC20Migratable newVault;
        QueContractMigratable       newQue;
        ForwardVaultERC20            oldVault;
        MoneyForwardContract         forwarder;
        IERC20                       token;
        address[]                    airdropAddresses;
        uint256[]                    airdropAmounts;
        uint256[]                    proxyAmounts;
        bool                         isUsdc;
    }

    function run()
        external
    {
        bool isUsdc = vm.envBool(
            "IS_USDC"
        );
        run(
            isUsdc
        );
    }

    function run(
        bool isUsdc
    )
        public
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        DeploymentContext memory ctx = _prepareData(
            isUsdc
        );

        QueParityVerifier.verifyFileMatchesLive(
            QueContract(
                _oldQueAddress(isUsdc)
            ),
            _queStateFile(isUsdc)
        );

        vm.startBroadcast(
            privKey
        );

        _deploy(
            ctx
        );

        _replicateState(
            ctx,
            isUsdc
        );

        _executeMigration(
            ctx
        );

        vm.stopBroadcast();

        QueParityVerifier.verifyNewQueMatchesLiveOldQue(
            QueContract(
                _oldQueAddress(isUsdc)
            ),
            ctx.newQue
        );

        _logResults(
            ctx
        );
    }

    function _prepareData(
        bool isUsdc
    )
        internal
        returns (DeploymentContext memory ctx)
    {
        string memory file = isUsdc
            ? "data/USDCaddress_balances_arb.txt"
            : "data/USDTaddress_balances_arb.txt";

        (
            ctx.airdropAddresses,
            ctx.airdropAmounts,
            ctx.proxyAmounts
        ) = BalanceFileParser.read(
            file
        );

        ctx.isUsdc = isUsdc;
    }

    function _oldQueAddress(
        bool isUsdc
    )
        internal
        pure
        returns (address)
    {
        return isUsdc
            ? OLD_QUE_USDC
            : OLD_QUE_USDT;
    }

    function _queStateFile(
        bool isUsdc
    )
        internal
        pure
        returns (string memory)
    {
        return isUsdc
            ? "data/que_state_arb_usdc.txt"
            : "data/que_state_arb_usdt.txt";
    }

    function _deploy(
        DeploymentContext memory ctx
    )
        internal
    {
        address oldVaultAddr = ctx.isUsdc ? OLD_VAULT_USDC : OLD_VAULT_USDT;
        address tokenAddr    = ctx.isUsdc ? USDC : USDT;

        ctx.oldVault = ForwardVaultERC20(
            oldVaultAddr
        );

        ctx.token = IERC20(
            tokenAddr
        );

        string memory name = ctx.isUsdc
            ? "RWA WORLD MOBILE VAULT ERC20 USDC ARB"
            : "RWA WORLD MOBILE VAULT ERC20 USDT ARB";

        string memory symbol = ctx.isUsdc ? "RWAWMVERC20USDCARB" : "RWAWMVERC20USDTARB";

        bytes4 ierc20Decimals = bytes4(
            keccak256(
                "decimals()"
            )
        );

        (bool success, bytes memory data) = tokenAddr.staticcall(
            abi.encodeWithSelector(
                ierc20Decimals
            )
        );

        require(
            success,
            "Failed to call decimals"
        );

        uint8 decimals = abi.decode(
            data,
            (uint8)
        );

        ctx.newVault = new ForwardVaultERC20Migratable(
            tokenAddr,
            ctx.oldVault.thirdPartyAddress(),
            address(ctx.oldVault),
            ctx.airdropAddresses,
            ctx.airdropAmounts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INCENTIVE,
            decimals,
            name,
            symbol
        );

        ctx.newQue = new QueContractMigratable(
            address(ctx.newVault)
        );

        ctx.forwarder = new MoneyForwardContract(
            address(ctx.oldVault),
            tokenAddr,
            ctx.oldVault.master(),
            address(ctx.newVault),
            BALANCER_VAULT
        );
    }

    function _replicateState(
        DeploymentContext memory ctx,
        bool isUsdc
    )
        internal
    {
        _replicateProxyBalances(
            ctx
        );

        string memory queFile = _queStateFile(
            isUsdc
        );

        _replicateMembersAndMint(
            ctx,
            queFile
        );

        _replicatePointers(
            ctx,
            queFile
        );

        _replicateSummary(
            ctx,
            queFile
        );

        ctx.newVault.setInterestRateProxy(
            address(ctx.newQue)
        );
    }

    function _replicateProxyBalances(
        DeploymentContext memory ctx
    )
        internal
    {
        for (uint256 i; i < ctx.airdropAddresses.length; ++i) {
            if (ctx.proxyAmounts[i] > 0) {
                ctx.newVault.setProxyBalance(
                    ctx.airdropAddresses[i],
                    ctx.proxyAmounts[i]
                );
            }
        }
    }

    function _replicateMembersAndMint(
        DeploymentContext memory ctx,
        string memory queFile
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
        ) = QueStateParser.readMembers(queFile);

        for (uint256 j; j < mIncs.length; ++j) {
            ctx.newQue.setQueMember(
                mIds[j],
                mIncs[j],
                mAddrs[j],
                mAmounts[j],
                mTails[j],
                mHeads[j]
            );
        }

        // Match the old QueContract's vault token balance EXACTLY — uses
        // balanceOf(oldQue) rather than sum(member.amount) so any "orphan"
        // vault tokens directly transferred to the queContract are also
        // preserved in the new deployment.
        address oldQueAddr = _oldQueAddress(
            ctx.isUsdc
        );
        uint256 oldQueBal  = ctx.oldVault.balanceOf(oldQueAddr);
        if (oldQueBal > 0) {
            ctx.newVault.mintSupply(
                address(ctx.newQue),
                oldQueBal
            );
        }
    }

    function _replicatePointers(
        DeploymentContext memory ctx,
        string memory queFile
    )
        internal
    {
        (
            int256[]  memory incs,
            uint256[] memory earliest,
            uint256[] memory current,
            uint256[] memory active,
            bool[]    memory allowed
        ) = QueStateParser.readPointers(queFile);

        for (uint256 i; i < incs.length; ++i) {
            ctx.newQue.setPerIncentiveState(
                incs[i],
                earliest[i],
                current[i],
                active[i],
                allowed[i]
            );
        }
    }

    function _replicateSummary(
        DeploymentContext memory ctx,
        string memory queFile
    )
        internal
    {
        (
            uint256 totalActive,
            bool    negNotAllowed,
            uint256 minDeposit
        ) = QueStateParser.readSummary(queFile);

        ctx.newQue.setGlobalState(
            totalActive,
            minDeposit,
            negNotAllowed
        );
    }

    function _executeMigration(
        DeploymentContext memory ctx
    )
        internal
    {
        ctx.oldVault.proposeOwner(
            address(ctx.forwarder)
        );

        ctx.forwarder.acceptOwnerOldVault();

        ctx.forwarder.mintSupply(
            EXTRA_SUPPLY_MINT
        );

        ctx.forwarder.burnSupplyBulk(
            ctx.airdropAddresses,
            ctx.airdropAmounts
        );
    }

    function _logResults(
        DeploymentContext memory ctx
    )
        internal
        view
    {
        console2.log(
            "Deployment complete on Arbitrum",
            ctx.isUsdc ? "USDC" : "USDT"
        );

        console2.log(
            "  oldVault: ",
            address(ctx.oldVault)
        );

        console2.log(
            "  newVault: ",
            address(ctx.newVault)
        );

        console2.log(
            "  newQue:   ",
            address(ctx.newQue)
        );

        console2.log(
            "  forwarder:",
            address(ctx.forwarder)
        );

        console2.log(
            "  holders:  ",
            ctx.airdropAddresses.length
        );
    }
}
