// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IReferralHub} from "../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "./utils/HubLeverGrants.sol";
import {ReferralHub} from "../../src/hub/pending/ReferralHub.sol";
import {HubDiamondHarness} from "../hub/utils/HubDiamondHarness.sol";
import {ReferralHubReader} from "../../src/hub/pending/ReferralHubReader.sol";
import {ReferralHubDeclarations} from "../../src/hub/pending/ReferralHubDeclarations.sol";
import {CohortWeeks} from "../../src/diamond/shared/pending/CohortWeeks.sol";
import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

/**
 * @dev Six-decimal mintable USD stand-in for the hub tests.
 */
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
 * @dev Hub-local payout-rail suite: the claim surface against the
 * pre-funded pot (the hub holds the USD it pays; `totalPayable -
 * totalClaimed` is the amount it owes, a claim counts in `totalClaimed`
 * and never books anything anywhere):
 * claim authorization (referrer or resolved payout address, nobody
 * else), full claims, the hub-chain bucket needing no designation
 * (the spoke-bucket designation rule is pinned in the mailbox
 * suite) and joining `totalPayable` at once, `claimUpTo` clamping to
 * entitlement and to the hub's own balance (a short pot pays the
 * balance and leaves the rest claimable, then a full claim reverts
 * `PotDry`), the dry-pot and nothing-claimable reverts, the
 * designation stamp (an undesignated other chain reads zero from
 * `payoutAddressOf`), and the constructor zero-token guard.
 * Accrual here reuses the intake recipe: absolute score
 * report, two dwell-min boundary crossings, one crumb delivery
 * whose lane quantity prices to an exact whole amount (no dust).
 * The batch readers on the {ReferralHubReader} companion are pinned
 * against their single-value siblings on the hub.
 * `paidCursorsAtSource` over a window with two delivered weeks and
 * two untouched ones returns, per week, exactly the packed lanes of
 * `paidCursorAtSource`, with the untouched weeks reading zero. A
 * zero count yields an empty array without reverting. `claimableOf`
 * over three referrers on one chain id, two with distinct accruals
 * and one with nothing, equals `claimable` element by element. An
 * empty batch yields an empty array without reverting. `claimAll` pays
 * an undesignated hub-chain bucket to its owner, stamps that designation
 * and skips an empty other chain in the same call.
 */
contract ReferralHubPayoutTest is Test, HubDiamondHarness {

    event PayoutClaimed(
        uint256 indexed chainId,
        address indexed referrer,
        address indexed payout,
        uint256 amount
    );

    event PayoutBacklogReleased(
        uint256 indexed chainId,
        address indexed owner,
        uint256 amount
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    address internal refA = address(0xB1);

    address internal refB = address(0xB2);

    address internal designated = address(0xF2);

    address internal stranger = address(0xC1);

    MockUSD internal usd;

    IReferralHub internal hub;

    ReferralHubReader internal reader;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        hub = _deployHub(
            address(usd)
        );

        reader = new ReferralHubReader(
            address(hub)
        );

        HubLeverGrants._grant(
            address(hub),
            abi.encodeCall(
                IReferralHub.setAllowedReporter,
                (
                    address(this),
                    true
                )
            )
        );
    }

    // ---- helpers ----

    function _accrueOneUsd()
        internal
        returns (uint256 expectedPaid)
    {
        uint256 reportWeek = block.timestamp / CohortWeeks.WEEK;

        vm.warp(
            (reportWeek + 1) * CohortWeeks.WEEK + 1 hours
        );

        vm.warp(
            (reportWeek + 3) * CohortWeeks.WEEK + 1 hours
        );

        uint256[] memory weeksArr = new uint256[](1);
        weeksArr[0] = reportWeek + 2;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks._packLanes(
            100 * CohortWeeks.YEAR * 1e6,
            0,
            0
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeksArr,
            words
        );

        expectedPaid = 1e6;
    }

    function _accrueUsd(
        address _referrer,
        uint256 _wholeUsd
    )
        internal
        returns (uint256 expectedPaid)
    {
        uint256 reportWeek = block.timestamp / CohortWeeks.WEEK;

        vm.warp(
            (reportWeek + 1) * CohortWeeks.WEEK + 1 hours
        );

        vm.warp(
            (reportWeek + 3) * CohortWeeks.WEEK + 1 hours
        );

        uint256[] memory weeksArr = new uint256[](1);
        weeksArr[0] = reportWeek + 2;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks._packLanes(
            _wholeUsd * 100 * CohortWeeks.YEAR * 1e6,
            0,
            0
        );

        hub.deliverCrumbs(
            _referrer,
            _referrer,
            weeksArr,
            words
        );

        (
            uint256 y1Bps,
            ,
        ) = hub.weeklyRates(
            _referrer,
            weeksArr[0]
        );

        expectedPaid = words[0] * y1Bps / (10_000 * CohortWeeks.YEAR);
    }

    // ---- constructor ----

    function test_constructor_storesUsdToken()
        public
    {
        assertEq(
            address(hub.USD_TOKEN()),
            address(usd)
        );
    }

    function test_RevertWhen_constructor_zeroToken()
        public
    {
        vm.expectRevert(
            ReferralHubDeclarations.ZeroAddress.selector
        );

        new ReferralHub(
            address(0)
        );
    }

    /**
     * @dev a hub-chain bucket whose owner never designated and never
     * claimed stays out of the amount the pot owes
     * the first claim is its owner liveness probe: it stamps the
     * designation, releases the backlog and pays in one step
     */
    function test_deliverCrumbs_hubChainBucket_undesignatedDoesNotBook()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        assertEq(
            hub.totalPayable(),
            0
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid
        );

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(hub)
        );

        emit PayoutBacklogReleased(
            block.chainid,
            refA,
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            hub.totalPayable(),
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );
    }

    /**
     * @dev a hub-chain designation releases the backlog into the amount
     * the pot owes in the same call
     */
    function test_setPayoutAddress_hubChainBacklog_joinsPayableOnDesignation()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        assertEq(
            hub.totalPayable(),
            0
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            refA
        );

        assertEq(
            hub.totalPayable(),
            expectedPaid
        );

        assertEq(
            hub.totalPayable() - hub.totalClaimed(),
            expectedPaid
        );
    }

    // ---- claim ----

    function test_claim_partialThenFull_releasesBacklogExactlyOnce()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid / 2
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid / 2
        );

        vm.recordLogs();

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.totalPayable(),
            expectedPaid
        );

        assertEq(
            hub.totalClaimed(),
            expectedPaid
        );
    }

    function test_claim_paysFullBalanceFromPreFundedPot()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(hub)
        );

        emit PayoutClaimed(
            block.chainid,
            refA,
            refA,
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );

        assertEq(
            hub.totalClaimed(),
            expectedPaid
        );

        assertEq(
            hub.totalAccrued(),
            expectedPaid
        );
    }

    function test_RevertWhen_claim_nothingClaimable()
        public
    {
        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        hub.claim(
            block.chainid,
            refA
        );
    }

    function test_RevertWhen_claim_dryPotWithoutVault()
        public
    {
        _accrueOneUsd();

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PotDry.selector
        );

        hub.claim(
            block.chainid,
            refA
        );
    }

    function test_RevertWhen_claim_calledByStranger()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotPayoutAuthorized.selector
        );

        hub.claim(
            block.chainid,
            refA
        );
    }

    function test_claim_referrerLockedOutAfterDesignation_payoutTriggers()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            designated
        );

        vm.prank(
            designated
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                designated
            ),
            expectedPaid
        );
    }

    function test_claim_referrerStillAuthorizedAfterDesignation()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            designated
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                designated
            ),
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            0
        );
    }

    function test_claim_hubBucket_needsNoDesignation()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        assertEq(
            hub.payoutStamp(
                block.chainid,
                refA
            ),
            0
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );
    }

    function test_claim_fromPot_paysAndCountsClaimed()
        public
    {
        uint256 potPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            potPaid
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            hub.totalClaimed(),
            potPaid
        );

        assertEq(
            hub.totalPayable(),
            potPaid
        );

        assertEq(
            usd.balanceOf(
                address(hub)
            ),
            0
        );

        vm.prank(
            refB
        );

        hub.setPayoutAddress(
            refB
        );

        uint256 laterPaid = _accrueUsd(
            refB,
            2
        );

        assertEq(
            hub.totalPayable() - hub.totalClaimed(),
            laterPaid
        );
    }

    function test_claimUpTo_shortPot_paysTheBalanceAndLeavesTheRest()
        public
    {
        uint256 firstPaid = _accrueOneUsd();

        uint256 secondPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            firstPaid
        );

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            firstPaid + secondPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            firstPaid
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            secondPaid
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PotDry.selector
        );

        hub.claim(
            block.chainid,
            refA
        );
    }

    // ---- claimUpTo ----

    function test_claimUpTo_clampsToEntitlement()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid * 10
        );

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid * 5
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );
    }

    function test_claimUpTo_clampsToHubBalanceWithoutVault()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        uint256 potFunds = expectedPaid / 4;

        usd.mint(
            address(hub),
            potFunds
        );

        vm.prank(
            refA
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            potFunds
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid - potFunds
        );

        assertEq(
            hub.totalClaimed(),
            potFunds
        );
    }

    function test_RevertWhen_claimUpTo_nothingClaimable()
        public
    {
        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            1e6
        );
    }

    function test_RevertWhen_claimUpTo_dryPot()
        public
    {
        _accrueOneUsd();

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.PotDry.selector
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            1e6
        );
    }

    function test_RevertWhen_claimUpTo_calledByStranger()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotPayoutAuthorized.selector
        );

        hub.claimUpTo(
            block.chainid,
            refA,
            expectedPaid
        );
    }

    // ---- designation keying ----

    function test_claim_otherChainBucketStaysUntouched()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        uint256 otherChain = block.chainid + 1;

        assertEq(
            hub.claimable(
                otherChain,
                refA
            ),
            0
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            ReferralHubDeclarations.NothingClaimable.selector
        );

        hub.claim(
            otherChain,
            refA
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            expectedPaid
        );
    }

    function test_designation_isPerChain()
        public
    {
        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            designated
        );

        assertEq(
            hub.payoutAddressOf(
                block.chainid,
                refA
            ),
            designated
        );

        assertEq(
            hub.payoutAddressOf(
                block.chainid + 1,
                refA
            ),
            address(0)
        );

        assertEq(
            hub.payoutStamp(
                block.chainid,
                refA
            ),
            block.timestamp << 8
        );

        assertEq(
            hub.payoutStamp(
                block.chainid + 1,
                refA
            ),
            0
        );
    }

    // ---- batch views ----

    function test_paidCursorsAtSource_matchesSingleViewAcrossWindow()
        public
    {
        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(this)
        );

        uint256 fromWeek = block.timestamp / CohortWeeks.WEEK - 4;

        uint256[] memory weeksArr = new uint256[](2);
        weeksArr[0] = fromWeek;
        weeksArr[1] = fromWeek + 2;

        uint256[] memory words = new uint256[](2);
        words[0] = CohortWeeks._packLanes(
            11 * CohortWeeks.YEAR,
            0,
            0
        );
        words[1] = CohortWeeks._packLanes(
            22 * CohortWeeks.YEAR,
            33 * CohortWeeks.YEAR,
            44 * CohortWeeks.YEAR
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeksArr,
            words
        );

        uint256[] memory cursorWords = reader.paidCursorsAtSource(
            source,
            refA,
            fromWeek,
            4
        );

        assertEq(
            cursorWords.length,
            4
        );

        for (uint256 i; i < 4; ++i) {

            (
                uint256 y1Cursor,
                uint256 y2Cursor,
                uint256 mCursor
            ) = hub.paidCursorAtSource(
                source,
                refA,
                fromWeek + i
            );

            assertEq(
                cursorWords[i],
                CohortWeeks._packLanes(
                    y1Cursor,
                    y2Cursor,
                    mCursor
                )
            );
        }

        assertEq(
            cursorWords[0],
            words[0]
        );

        assertEq(
            cursorWords[1],
            0
        );

        assertEq(
            cursorWords[2],
            words[1]
        );

        assertEq(
            cursorWords[3],
            0
        );

        assertEq(
            CohortWeeks._laneY1(
                cursorWords[2]
            ),
            22 * CohortWeeks.YEAR
        );

        assertEq(
            CohortWeeks._laneY2(
                cursorWords[2]
            ),
            33 * CohortWeeks.YEAR
        );

        assertEq(
            CohortWeeks._laneM(
                cursorWords[2]
            ),
            44 * CohortWeeks.YEAR
        );
    }

    function test_paidCursorsAtSource_zeroCount_returnsEmpty()
        public
        view
    {
        bytes32 source = hub.sourceKeyOf(
            block.chainid,
            address(this)
        );

        uint256[] memory cursorWords = reader.paidCursorsAtSource(
            source,
            refA,
            block.timestamp / CohortWeeks.WEEK,
            0
        );

        assertEq(
            cursorWords.length,
            0
        );
    }

    function test_claimableOf_matchesClaimableForBatch()
        public
    {
        uint256 paidA = _accrueOneUsd();

        uint256 paidB = _accrueUsd(
            refB,
            3
        );

        address[] memory referrers = new address[](3);
        referrers[0] = refA;
        referrers[1] = refB;
        referrers[2] = stranger;

        uint256[] memory amounts = reader.claimableOf(
            block.chainid,
            referrers
        );

        assertEq(
            amounts.length,
            3
        );

        for (uint256 i; i < 3; ++i) {

            assertEq(
                amounts[i],
                hub.claimable(
                    block.chainid,
                    referrers[i]
                )
            );
        }

        assertEq(
            amounts[0],
            paidA
        );

        assertEq(
            amounts[1],
            paidB
        );

        assertEq(
            amounts[2],
            0
        );
    }

    function test_claimAll_hubChainBucket_paysOwnerAndStampsDesignation()
        public
    {
        uint256 expectedPaid = _accrueOneUsd();

        usd.mint(
            address(hub),
            expectedPaid
        );

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = block.chainid;
        chainIds[1] = block.chainid + 1;

        assertEq(
            hub.payoutStamp(
                block.chainid,
                refA
            ),
            0
        );

        vm.prank(
            refA
        );

        uint256 total = hub.claimAll(
            refA,
            chainIds
        );

        assertEq(
            total,
            expectedPaid
        );

        assertEq(
            usd.balanceOf(
                refA
            ),
            expectedPaid
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0
        );

        assertTrue(
            hub.payoutStamp(
                block.chainid,
                refA
            ) != 0
        );
    }

    function test_claimableOf_emptyBatch_returnsEmpty()
        public
        view
    {
        address[] memory referrers = new address[](0);

        uint256[] memory amounts = reader.claimableOf(
            block.chainid,
            referrers
        );

        assertEq(
            amounts.length,
            0
        );
    }
}
