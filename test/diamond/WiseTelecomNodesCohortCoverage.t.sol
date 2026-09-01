// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";

import {WiseTelecomNodesDiamondErrors} from "../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {CohortLaneHarness} from "./utils/CohortLaneHarness.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

contract MockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Coverage-closure suite for the cohort recorder (pattern:
 * {WiseTelecomNodesAdminCoverage}): the residual arms the behavioral
 * suites cannot reach through normal drivers: the `NotHookExecution`
 * guard on an engine entrypoint reached OUTSIDE the transient
 * `hookExecuting` bracket (requires deliberately routing an engine
 * selector, which production never does); the `getCohortSyncEnabled`
 * view through the routed dispatcher; the credit-path book-lane clip
 * (a saturating Y1 add during `_creditRingCohort`, distinct from the
 * rotate/reduce clips the saturation suite covers); and the
 * `back > currentWeek` reduction-walk guard, unreachable on any real
 * chain clock (currentWeek is in the thousands) but live at
 * timestamps below one ring revolution.
 */
contract WiseTelecomNodesCohortCoverageTest is DiamondTestHarness {

    event CohortLaneSaturated(
        address indexed referrer,
        uint256 laneKind,
        uint256 index,
        uint256 clippedAmount
    );

    address internal user1 = address(0xA1);
    address internal refA = address(0xB1);

    WiseTelecomNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            3_000 weeks + 1 hours
        );

        usd = new MockUSD();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();
    }

    function test_engineEntrypoint_outsideHookBracket_reverts()
        public
    {
        WiseTelecomNodesDiamond bare = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            bare
        );

        CohortHookFacet hook = new CohortHookFacet();

        bytes4[] memory sels = new bytes4[](1);

        sels[0] = CohortHookFacet.applyCohortSync.selector;

        bare.proposeSelectors(
            sels,
            address(hook)
        );

        bare.executeSelectorChanges(
            sels
        );

        bare.finalizeSetup();

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotHookExecution.selector
        );

        CohortHookFacet(payable(address(bare))).applyCohortSync(
            user1
        );
    }

    function test_getCohortSyncEnabled_tracksArmSwitch()
        public
    {
        CohortRecorderFacet recorder = CohortRecorderFacet(
            address(diamond)
        );

        assertFalse(
            recorder.getCohortSyncEnabled()
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );

        assertTrue(
            recorder.getCohortSyncEnabled()
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        assertFalse(
            recorder.getCohortSyncEnabled()
        );
    }

    function test_creditRing_bookLaneClipEmitsAnomaly()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetBookLanes(
            refA,
            CohortWeeks.LANE_MASK_80 - 5,
            0,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            refA,
            2,
            0,
            95
        );

        harness.exposedCreditRing(
            refA,
            100
        );

        assertEq(
            CohortWeeks.laneY1(
                harness.viewBookWord(
                    refA
                )
            ),
            CohortWeeks.LANE_MASK_80
        );
    }

    function test_zeroAmountCredit_isSilentNoop()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        ReferralRegistry laneRegistry = new ReferralRegistry(
            address(this),
            0
        );

        laneRegistry.setAllowedVault(
            address(harness),
            true
        );

        harness.harnessSetRegistry(
            address(laneRegistry)
        );

        harness.harnessSetReferrer(
            user1,
            refA
        );

        vm.recordLogs();

        harness.exposedCreditContribution(
            user1,
            0
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            harness.viewTracked(
                user1
            ),
            0
        );

        assertEq(
            harness.viewBookWord(
                refA
            ),
            0
        );
    }

    function test_reduceWalk_ringMirrorClipEmitsBookAnomaly()
        public
    {
        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetLastSettle(
            refA,
            block.timestamp
        );

        harness.harnessSetRingYear1(
            refA,
            (block.timestamp / 1 weeks) % 52,
            100
        );

        harness.harnessSetBookLanes(
            refA,
            50,
            0,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(harness)
        );

        emit CohortLaneSaturated(
            refA,
            2,
            0,
            50
        );

        harness.exposedReduceBook(
            refA,
            100
        );

        assertEq(
            CohortWeeks.laneY1(
                harness.viewBookWord(
                    refA
                )
            ),
            0
        );
    }

    function test_reduceWalk_belowOneRingRevolution_breaksOnWeekGuard()
        public
    {
        vm.warp(
            2 weeks + 1 hours
        );

        CohortLaneHarness harness = new CohortLaneHarness();

        harness.harnessSetLastSettle(
            refA,
            block.timestamp
        );

        harness.harnessSetRingYear1(
            refA,
            2,
            1_000
        );

        harness.harnessSetBookLanes(
            refA,
            1_000,
            0,
            0
        );

        harness.exposedReduceBook(
            refA,
            5_000
        );

        assertEq(
            uint256(
                harness.viewRingYear1(
                    refA,
                    2
                )
            ),
            0
        );

        assertEq(
            harness.viewBookWord(
                refA
            ),
            0
        );
    }
}
