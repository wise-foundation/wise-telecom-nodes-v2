// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {DeployVaultDeterministic} from "../../script/vault/DeployVaultDeterministic.s.sol";

/**
 * @dev Tests for the usdg deposit-forwarding rule of the deterministic
 * deploy script: for the usdg product the deposit forward (thirdParty)
 * is forced to the worker address — the overhang-sweep receiver — and
 * a conflicting non-zero config value aborts. Other products keep the
 * configured thirdParty untouched. Inherits the deploy script so the
 * tests exercise the very helper the production script uses.
 */
contract DeployVaultDeterministicUsdgTest is Test, DeployVaultDeterministic {

    address internal constant THIRD_PARTY = address(0xCAFE);

    address internal constant WORKER = address(0xD00D);

    function exposedApplyUsdgForwarding(
        DeployCfg memory _dc,
        string memory _product
    )
        external
        pure
        returns (DeployCfg memory)
    {
        return _applyUsdgForwarding(
            _dc,
            _product
        );
    }

    function testUsdgForcesThirdPartyToWorker()
        public
    {
        DeployCfg memory dc;
        dc.worker = WORKER;

        DeployCfg memory result = this.exposedApplyUsdgForwarding(
            dc,
            "usdg"
        );

        assertEq(
            result.thirdParty,
            WORKER
        );

        assertEq(
            result.worker,
            WORKER
        );
    }

    function testUsdgAcceptsThirdPartyEqualToWorker()
        public
    {
        DeployCfg memory dc;
        dc.thirdParty = WORKER;
        dc.worker = WORKER;

        DeployCfg memory result = this.exposedApplyUsdgForwarding(
            dc,
            "usdg"
        );

        assertEq(
            result.thirdParty,
            WORKER
        );
    }

    function testUsdgRevertsOnMismatchedThirdParty()
        public
    {
        DeployCfg memory dc;
        dc.thirdParty = THIRD_PARTY;
        dc.worker = WORKER;

        vm.expectRevert(
            bytes("DeployVaultDeterministic: usdg thirdParty must equal worker")
        );

        this.exposedApplyUsdgForwarding(
            dc,
            "usdg"
        );
    }

    function testNonUsdgKeepsThirdParty()
        public
    {
        DeployCfg memory dc;
        dc.thirdParty = THIRD_PARTY;
        dc.worker = WORKER;

        DeployCfg memory result = this.exposedApplyUsdgForwarding(
            dc,
            "usdc"
        );

        assertEq(
            result.thirdParty,
            THIRD_PARTY
        );

        assertEq(
            result.worker,
            WORKER
        );
    }
}
