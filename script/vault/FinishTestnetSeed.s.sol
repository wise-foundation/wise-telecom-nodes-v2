// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

/**
 * @dev Minimal surface of the deployed diamond + TestUSD the finisher
 * touches. The diamond is its own share token AND queue.
 */
interface ISeedTarget {

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);

    function activeOrderCountByIncentive(
        int256 _incentive
    )
        external
        view
        returns (uint256);

    function mintSupply(
        address _to,
        uint256 _amount
    )
        external;

    function joinQue(
        uint256 _amount,
        int256 _incentive
    )
        external
        returns (uint256, address, uint256);

    function mint(
        address _to,
        uint256 _amount
    )
        external;
}

/**
 * @title FinishTestnetSeed
 * @dev Idempotently completes the testnet deployer-queue seed that the
 * inline `_seedDeployerQueue` in {DeployVaultTestnet} can leave partial
 * when forge's warm-simulation gas estimate under-funds the
 * delegatecall-heavy `joinQue` on a cold chain (the queue insertion
 * needs ~33% more gas cold than forge estimates from its warm run). It
 * reads the deployed diamond (SEED_DIAMOND) and TestUSD (SEED_USD),
 * mints the deployer share supply only if missing, joins each incentive
 * tier only if that tier has no active order yet, and mints the TestUSD
 * balances only if zero — so it is safe to run repeatedly and on any
 * chain regardless of how far the original deploy got. Forge manages
 * nonces and gas (pass `--gas-estimate-multiplier 200`), avoiding the
 * public-RPC nonce races that plague a raw `cast send` loop.
 *
 * Run per chain:
 *   SEED_DIAMOND=0x.. SEED_USD=0x.. forge script \
 *     script/vault/FinishTestnetSeed.s.sol --rpc-url <net> \
 *     --broadcast --slow --gas-estimate-multiplier 200 \
 *     --private-key "$PRIVATE_KEY"
 */
contract FinishTestnetSeed is Script {

    uint256 constant SEED_SUPPLY = 500_000 * 1e6;

    uint256 constant QUEUE_ENTRY_AMOUNT = 20_000 * 1e6;

    function run()
        external
    {
        uint256 privKey = vm.envUint(
            "PRIVATE_KEY"
        );

        address deployer = vm.addr(
            privKey
        );

        ISeedTarget diamond = ISeedTarget(
            vm.envAddress("SEED_DIAMOND")
        );

        ISeedTarget usd = ISeedTarget(
            vm.envAddress("SEED_USD")
        );

        int256[5] memory tiers = [
            int256(0),
            int256(100),
            int256(500),
            int256(-100),
            int256(1000)
        ];

        vm.startBroadcast(
            privKey
        );

        uint256 needed = QUEUE_ENTRY_AMOUNT * tiers.length;

        if (diamond.balanceOf(deployer) < needed) {
            diamond.mintSupply(
                deployer,
                SEED_SUPPLY
            );

            console2.log(
                "minted deployer shares"
            );
        }

        for (uint256 i; i < tiers.length; ++i) {
            if (diamond.activeOrderCountByIncentive(tiers[i]) == 0) {
                diamond.joinQue(
                    QUEUE_ENTRY_AMOUNT,
                    tiers[i]
                );

                console2.log(
                    "joined tier"
                );

                console2.logInt(
                    tiers[i]
                );
            }
        }

        if (usd.balanceOf(deployer) == 0) {
            usd.mint(
                deployer,
                SEED_SUPPLY
            );

            console2.log(
                "minted deployer TestUSD"
            );
        }

        if (usd.balanceOf(address(diamond)) == 0) {
            usd.mint(
                address(diamond),
                SEED_SUPPLY
            );

            console2.log(
                "minted diamond TestUSD"
            );
        }

        vm.stopBroadcast();

        console2.log(
            "totalActiveOrders now",
            _totalActive(diamond, tiers)
        );
    }

    function _totalActive(
        ISeedTarget _diamond,
        int256[5] memory _tiers
    )
        internal
        view
        returns (uint256 total)
    {
        for (uint256 i; i < _tiers.length; ++i) {
            total += _diamond.activeOrderCountByIncentive(
                _tiers[i]
            );
        }
    }
}
