// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {WiseTelecomNodesDiamond} from "../../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AutoCompoundFacet} from "../../../src/diamond/vault/facets/AutoCompoundFacet.sol";
import {BridgeFacet} from "../../../src/diamond/vault/facets/BridgeFacet.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";
import {ReferralPreflight} from "../../../script/preflight/ReferralPreflight.s.sol";

/**
 * @dev Runs the vault checks of {ReferralPreflight} without the closing revert, so a test reads
 * the three counters of one vault's run.
 */
contract ReferralPreflightHarness is ReferralPreflight {

    function checkVaultOnly(
        string memory _product,
        string memory _network
    )
        external
    {
        _begin();

        _checkVault(
            _product,
            _network
        );
    }
}

/**
 * @dev Proves on a fork of the live mainnet state that {ReferralPreflight} both passes the
 * real fleet and fails when the rollout state is wrong, so a green preflight means
 * something. Mainnet is the widest chain run: the three World Mobile vaults, the registry
 * record (absent before Phase 1) and the hub record are all read. The fork follows the
 * current head on purpose, like the upgrade rehearsals, because the preflight must read
 * today's live state.
 *
 * One test function runs every scenario in order, each from a state snapshot, because the
 * preflight reads `PREFLIGHT_PHASE` from the process environment, which parallel test
 * functions would share. Scenarios on the usdc mainnet vault, each counted against the
 * failures of the untouched vault at the same phase (the baseline: phase 0 has none, phase 1
 * fails only the items phase 1 makes due on today's state):
 * - the live chain at phase 0 passes;
 * - the auto compound batch queued to a fresh build of AutoCompoundFacet fails at phase 0
 *   and adds no failure at phase 1, which proves the build comparison accepts the shipped
 *   code with its own address in the immutable slot;
 * - the same batch queued to the live UserFacet adds one failure at phase 1;
 * - one selector of that batch queued adds one failure;
 * - the legacy pair queued to the zero facet, the retirement of runbook step 2.3b, adds no
 *   failure at phase 1 (the bridge batch is judged without the pair);
 * - the whole bridge batch, legacy pair included, queued to a fresh build of BridgeFacet, the
 *   registry round proposal of runbook step 2.1, adds no failure at phase 1;
 * - the rescue batch, which no rollout step proposes, queued to its live facet adds one
 *   failure at phase 1;
 * - the chain at phase 2 fails on today's state.
 * The rule that no peer crosses vault systems needs the Sovren config record and is read by
 * the live preflight runs once that record exists.
 */
contract ReferralPreflightFork is Test {

    string internal constant FAILED = "ReferralPreflight: at least one check failed";

    ReferralPreflightHarness internal preflight;

    WiseTelecomNodesDiamond internal usdcVault;

    address internal master;

    function setUp()
        public
    {
        vm.createSelectFork(
            "mainnet"
        );

        preflight = new ReferralPreflightHarness();

        usdcVault = WiseTelecomNodesDiamond(
            payable(
                vm.parseJsonAddress(
                    vm.readFile(
                        "config/vault.usdc.mainnet.json"
                    ),
                    ".diamond"
                )
            )
        );

        master = usdcVault.master();
    }

    function test_preflight_liveStateAndInjectedFaults()
        public
    {
        uint256 clean = vm.snapshotState();

        _setPhase(
            0
        );

        preflight.chain();

        assertEq(
            preflight.failCount(),
            0,
            "live chain fails at phase 0"
        );

        assertGt(
            preflight.passCount(),
            60,
            "live chain passes too few checks"
        );

        assertEq(
            _vaultFailures(),
            0,
            "live usdc vault fails at phase 0"
        );

        _setPhase(
            1
        );

        uint256 baseline = _vaultFailures();

        assertGt(
            baseline,
            0,
            "phase 1 items are due on the pre-rollout state"
        );

        bytes4[] memory batch = WiseTelecomNodesDiamondSelectors._autoCompoundSelectors();

        address shippedBuild = address(
            new AutoCompoundFacet()
        );

        _propose(
            batch,
            shippedBuild
        );

        assertEq(
            _vaultFailures(),
            baseline,
            "a batch queued to the shipped build fails after phase 0"
        );

        _setPhase(
            0
        );

        assertEq(
            _vaultFailures(),
            1,
            "a batch queued before the rollout passes at phase 0"
        );

        vm.revertToState(
            clean
        );

        _setPhase(
            1
        );

        address userFacet = usdcVault.selectorToFacet(
            WiseTelecomNodesDiamondSelectors._userSelectors()[0]
        );

        _propose(
            batch,
            userFacet
        );

        assertEq(
            _vaultFailures(),
            baseline + 1,
            "a batch queued to a foreign facet passes"
        );

        vm.revertToState(
            clean
        );

        bytes4[] memory single = new bytes4[](
            1
        );

        single[0] = batch[0];

        _propose(
            single,
            shippedBuild
        );

        _setPhase(
            1
        );

        assertEq(
            _vaultFailures(),
            baseline + 1,
            "a half queued batch passes"
        );

        vm.revertToState(
            clean
        );

        _propose(
            WiseTelecomNodesDiamondSelectors._legacyReferralBridgeSelectors(),
            address(0)
        );

        _setPhase(
            1
        );

        assertEq(
            _vaultFailures(),
            baseline,
            "the legacy pair retirement fails a batch"
        );

        vm.revertToState(
            clean
        );

        _propose(
            WiseTelecomNodesDiamondSelectors._bridgeSelectors(),
            address(
                new BridgeFacet()
            )
        );

        _setPhase(
            1
        );

        assertEq(
            _vaultFailures(),
            baseline,
            "the registry round bridge proposal fails a batch"
        );

        vm.revertToState(
            clean
        );

        bytes4[] memory rescue = WiseTelecomNodesDiamondSelectors._rescueSelectors();

        address rescueFacet = usdcVault.selectorToFacet(
            rescue[0]
        );

        _propose(
            rescue,
            rescueFacet
        );

        _setPhase(
            1
        );

        assertEq(
            _vaultFailures(),
            baseline + 1,
            "a queued batch outside the rollout passes"
        );

        vm.revertToState(
            clean
        );

        _setPhase(
            2
        );

        vm.expectRevert(
            bytes(FAILED)
        );

        preflight.chain();

        _setPhase(
            0
        );
    }

    function _propose(
        bytes4[] memory _selectors,
        address _facet
    )
        internal
    {
        vm.prank(
            master
        );

        usdcVault.proposeSelectors(
            _selectors,
            _facet
        );
    }

    function _vaultFailures()
        internal
        returns (uint256)
    {
        preflight.checkVaultOnly(
            "usdc",
            "mainnet"
        );

        return preflight.failCount();
    }

    function _setPhase(
        uint256 _phase
    )
        internal
    {
        vm.setEnv(
            "PREFLIGHT_PHASE",
            vm.toString(
                _phase
            )
        );
    }
}
