// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import "forge-std/console2.sol";

import {DeployWiseTelecomNodesDiamond} from "../diamond/DeployWiseTelecomNodesDiamond.s.sol";
import {VaultConfig} from "./VaultConfig.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesInitParams} from "../../src/diamond/vault/WiseTelecomNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";

import {TestUSD} from "../../src/bridgetest/TestUSD.sol";
import {MockWise} from "../../src/bridgetest/MockWise.sol";

/// @notice Deploys one WiseTelecomNodes diamond per testnet with a mintable {TestUSD} underlying
/// through the SAME deterministic CreateX CREATE3 path as production, so the testnet mesh also
/// lands on one canonical address per product (recorded in config/vault_mesh.<product>.testnet.json;
/// testnet salt tags are bumpable — a fresh mesh iteration bumps the tag because CREATE3 cannot
/// redeploy at a used address on the same chain). The deployer is seeded as a stand-in for every
/// user: mainnet has real holders whose keys we don't have, so on testnet a single signer holds
/// the supply and populates the queue across incentive tiers so the UI sees a realistic, live
/// vault. Chains flagged inactive in the manifest deploy dormant and skip the seed. The diamond
/// is left un-finalized so {RegisterCrossChainPeers} can wire the mesh instantly before
/// {FinalizeVault} locks the timelocks in.
contract DeployVaultTestnet is DeployWiseTelecomNodesDiamond, VaultConfig {

    address constant DEFAULT_WORKER = 0x000000000000000000000000000000000000dEaD;

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;

    uint256 constant INTEREST_RATE = 2000;

    uint8 constant USD_DECIMALS = 6;

    uint256 constant SEED_SUPPLY = 500_000 * 1e6;

    uint256 constant QUEUE_ENTRY_AMOUNT = 20_000 * 1e6;

    uint256 constant SEPOLIA_CHAIN_ID = 11155111;

    uint256 constant WISE_SEED = 1_000_000 * 1e18;

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        address deployer = vm.addr(
            privKey
        );

        string memory network = _networkName();

        ChainCfg memory cfg = _loadCfg(
            network
        );

        VaultMesh memory mesh = _loadMesh();

        bytes32 salt = makeSalt(
            deployer,
            mesh.saltTag
        );

        (
            ,
            address predicted
        ) = preflightDeterministic(
            deployer,
            salt
        );

        if (mesh.canonical != address(0)) {
            require(
                predicted == mesh.canonical,
                "DeployVaultTestnet: predicted address != mesh canonical"
            );
        }

        bool dormant = _isActiveInMesh(
            mesh,
            network
        ) == false;

        vm.startBroadcast(
            privKey
        );

        TestUSD usd = new TestUSD(
            "Test USD",
            "tUSD",
            USD_DECIMALS
        );

        address wiseAddr;

        if (block.chainid == SEPOLIA_CHAIN_ID) {
            wiseAddr = address(
                new MockWise()
            );
        }

        (
            WiseTelecomNodesDiamond diamond,
        ) = deployDeterministic(
            _buildParams(
                address(usd),
                deployer,
                network
            ),
            DeterministicCfg({
                salt: salt,
                expectedDiamond: mesh.canonical,
                ccipRouter: cfg.router,
                wiseToken: wiseAddr,
                startDormant: dormant,
                pendingMaster: deployer
            })
        );

        if (wiseAddr != address(0)) {
            MockWise(wiseAddr).mint(
                address(diamond),
                WISE_SEED
            );
        }

        if (dormant == false) {
            if (vm.envOr("SEED_QUEUE", true)) {
                _seedDeployerQueue(
                    diamond,
                    deployer
                );
            }

            usd.mint(
                deployer,
                SEED_SUPPLY
            );

            usd.mint(
                address(diamond),
                SEED_SUPPLY
            );
        }

        vm.stopBroadcast();

        _saveVault(
            network,
            address(diamond),
            address(usd),
            wiseAddr
        );

        console2.log("product ", _vaultProduct());
        console2.log("network ", network);
        console2.log("diamond ", address(diamond));
        console2.log("dormant ", dormant);
        console2.log("usd     ", address(usd));
        console2.log("router  ", cfg.router);
        console2.log("wise    ", wiseAddr);
    }

    function _buildParams(
        address _usd,
        address _deployer,
        string memory _network
    )
        internal
        view
        returns (WiseTelecomNodesInitParams memory)
    {
        address worker = vm.envOr(
            "WORKER_ADDRESS",
            DEFAULT_WORKER
        );

        return WiseTelecomNodesInitParams({
            usdAddress: _usd,
            thirdPartyAddress: _sameString(_vaultProduct(), "usdg")
                ? worker
                : _deployer,
            workerAddress: worker,
            oldVault: address(0),
            initialDistributionAddresses: new address[](0),
            initialDistributionAmounts: new uint256[](0),
            totalDepositCap: TOTAL_DEPOSIT_CAP,
            interestRate: INTEREST_RATE,
            decimalsValue: USD_DECIMALS,
            tokenName: string.concat(
                "Wise Telecom Nodes ",
                _network
            ),
            tokenSymbol: _sameString(_vaultProduct(), "usdt")
                ? "wtnUSDT"
                : _sameString(_vaultProduct(), "usdg")
                    ? "wtnUSDG"
                    : "wtnUSDC"
        });
    }

    function _seedDeployerQueue(
        WiseTelecomNodesDiamond diamond,
        address deployer
    )
        internal
    {
        AdminFacet(address(diamond)).mintSupply(
            deployer,
            SEED_SUPPLY
        );

        int256[] memory tiers = new int256[](5);
        tiers[0] = 0;
        tiers[1] = 100;
        tiers[2] = 500;
        tiers[3] = -100;
        tiers[4] = 1000;

        for (uint256 i; i < tiers.length; ++i) {
            QueueJoinLeaveFacet(address(diamond)).joinQue(
                QUEUE_ENTRY_AMOUNT,
                tiers[i]
            );
        }
    }
}
