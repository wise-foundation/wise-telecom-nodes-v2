// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title DeployerBalances
 * @dev Gas-balance preflight for the multi-chain deploy. Derives the
 * deployer address from the `PRIVATE_KEY` in `.env` (the key never
 * leaves foundry's env handling), forks every target chain via its
 * `foundry.toml` RPC alias, and logs the deployer's native balance
 * plus canonical-Permit2 presence per chain. Chains whose RPC env is
 * not configured are logged and skipped rather than failing, so the
 * preflight is runnable with a partial .env. With no `PRIVATE_KEY` at
 * all there is no deployer to report on and the whole preflight skips,
 * which is what CI hits: it holds no deployer key by design.
 *
 * Run:
 *   forge test --match-test test_logDeployerBalances -vv
 */
contract DeployerBalancesTest is Test {

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function test_logDeployerBalances()
        public
    {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0)
        );

        if (deployerKey == 0) {
            console2.log(
                "SKIP (no PRIVATE_KEY configured)"
            );

            return;
        }

        address deployer = vm.addr(
            deployerKey
        );

        console2.log(
            "deployer",
            deployer
        );

        string[8] memory chains = [
            "mainnet",
            "base",
            "arbitrum",
            "sepolia",
            "base_sepolia",
            "arbitrum_sepolia",
            "robinhood",
            "robinhood_testnet"
        ];

        for (uint256 i = 0; i < chains.length; i++) {
            _logChain(
                chains[i],
                deployer
            );
        }
    }

    function _logChain(
        string memory _chain,
        address _deployer
    )
        internal
    {
        string memory url;

        try vm.rpcUrl(
            _chain
        ) returns (
            string memory resolved
        ) {
            url = resolved;
        } catch {
            console2.log(
                "SKIP (no rpc configured):",
                _chain
            );

            return;
        }

        try vm.createSelectFork(
            url
        ) returns (
            uint256
        ) {
            console2.log(
                "---",
                _chain
            );

            console2.log(
                "  gas balance (wei):",
                _deployer.balance
            );

            console2.log(
                "  permit2 present:",
                CANONICAL_PERMIT2.code.length > 0
            );
        } catch {
            console2.log(
                "SKIP (rpc unreachable):",
                _chain
            );
        }
    }
}
