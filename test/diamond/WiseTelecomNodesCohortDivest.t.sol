// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
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
 * @dev Deferred divestment of the cohort recorder. The entry contract
 * runs the transfer hook before the balance moves and passes no
 * amount, so a plain transfer used to leave the sender's tracked
 * contribution and the referrer's book untouched forever: deposit
 * under a referrer, transfer the shares to a second address, sell
 * them at par through the queue, repeat, and the book stacked one
 * full deposit per cycle on capital that came straight back. The hook
 * now parks the sender in tail slot 91 and every engine touchpoint by
 * anyone drains that slot first, syncing the parked user at the exact
 * post-transfer balance. The scenarios pin the park, every kind of
 * drain (a stranger's deposit, the recipient's queue join, a further
 * transfer, a poke), chained and partial transfers, `transferFrom`,
 * the untracked-sender skip, the lookup-failure keep and skip rules,
 * the pre-receipt drain, the disabled recorder, the router-initiated
 * skip, and the release of a parked user whose balance recovered.
 */
contract WiseTelecomNodesCohortDivestTest is DiamondTestHarness {

    event CohortDivestParked(
        address indexed user
    );

    event CohortDivestDrained(
        address indexed user
    );

    event CohortDivestParkSkipped(
        address indexed user,
        address indexed parked
    );

    event CohortContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant ONE = 1e6;

    uint256 internal constant DIVEST_SLOT = 91;

    address internal referee = address(0xA1);
    address internal second = address(0xA2);
    address internal sink = address(0xA3);
    address internal third = address(0xC1);
    address internal spender = address(0xC2);
    address internal router = address(0xC3);
    address internal referrer = address(0xB1);
    address internal otherReferrer = address(0xB2);

    WiseTelecomNodesDiamond internal diamond;
    MockUSD internal usd;
    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
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
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortBridgeHookFacet()),
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()
        );

        _wireOne(
            diamond,
            address(new QueueJoinLeaveFacet()),
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        _wireOne(
            diamond,
            address(new BridgeFacet()),
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        registry = _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            100_000_000 * ONE
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    // ---- helpers ----

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _parked()
        internal
        view
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    vm.load(
                        address(diamond),
                        bytes32(DIVEST_SLOT)
                    )
                )
            )
        );
    }

    function _plainDepositAs(
        address _user,
        uint256 _amount
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(diamond),
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(diamond)).deposit(
            _amount
        );
    }

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(diamond),
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _transferAs(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _from
        );

        diamond.transfer(
            _to,
            _amount
        );
    }

    function _pokeAs(
        address _caller,
        address _user
    )
        internal
    {
        vm.prank(
            _caller
        );

        _recorder().syncReferee(
            _user
        );
    }

    function _stageReferee()
        internal
    {
        _depositWithReferralAs(
            referee,
            10_000 * ONE,
            referrer
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            10_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            10_000 * ONE
        );
    }

    function _stageSecond()
        internal
    {
        _depositWithReferralAs(
            second,
            7_000 * ONE,
            otherReferrer
        );

        assertEq(
            _recorder().getCohortScore(otherReferrer),
            7_000 * ONE
        );
    }

    function _breakRegistry()
        internal
        returns (bytes memory realCode)
    {
        realCode = address(registry).code;

        vm.etch(
            address(registry),
            hex"60006000fd"
        );
    }

    function _restoreRegistry(
        bytes memory _realCode
    )
        internal
    {
        vm.etch(
            address(registry),
            _realCode
        );
    }

    // ---- park ----

    function test_transfer_parksTrackedSender()
        public
    {
        _stageReferee();

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestParked(
            referee
        );

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            diamond.balanceOf(referee),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            10_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            10_000 * ONE
        );
    }

    function test_transferFrom_parksSender()
        public
    {
        _stageReferee();

        vm.prank(
            referee
        );

        diamond.approve(
            spender,
            10_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestParked(
            referee
        );

        vm.prank(
            spender
        );

        diamond.transferFrom(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );
    }

    function test_untrackedSender_isNotParked()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        _transferAs(
            sink,
            third,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            0
        );
    }

    function test_syncDisabled_parksNothing()
        public
    {
        _stageReferee();

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            false
        );

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            address(0)
        );
    }

    // ---- drain ----

    function test_strangerDeposit_drainsParkedSender()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        usd.mint(
            third,
            ONE
        );

        vm.prank(
            third
        );

        usd.approve(
            address(diamond),
            ONE
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionSynced(
            referee,
            referrer,
            10_000 * ONE,
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        vm.prank(
            third
        );

        UserFacet(address(diamond)).deposit(
            ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            0
        );

        assertEq(
            _recorder().getAttributedContribution(referee),
            0
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );
    }

    function test_recipientQueueJoin_drainsParkedSenderBeforeEscrow()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        vm.prank(
            sink
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            10_000 * ONE,
            0
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(sink),
            0
        );
    }

    function test_chainedTransfers_drainThePreviousSender()
        public
    {
        _stageReferee();

        _stageSecond();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        _transferAs(
            second,
            sink,
            7_000 * ONE
        );

        assertEq(
            _parked(),
            second
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );

        assertEq(
            _recorder().getCohortScore(otherReferrer),
            7_000 * ONE
        );

        _plainDepositAs(
            third,
            ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(otherReferrer),
            0
        );
    }

    function test_partialTransfers_drainAtExactBalanceEachTime()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            10_000 * ONE
        );

        _transferAs(
            referee,
            sink,
            6_000 * ONE
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            6_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            6_000 * ONE
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            0
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );
    }

    function test_transferBackBeforeDrain_clampsAtPreReceiptBalance()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        _transferAs(
            sink,
            referee,
            10_000 * ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            diamond.balanceOf(referee),
            10_000 * ONE
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            0
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );
    }

    function test_balanceRestoredBySupplyMint_drainReleasesWithoutClamp()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        AdminFacet(address(diamond)).mintSupply(
            referee,
            4_000 * ONE
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            10_000 * ONE
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            10_000 * ONE
        );
    }

    // ---- lookup failure ----

    function test_lookupFailure_keepsParkedAndSkipsNewPark()
        public
    {
        _stageReferee();

        _stageSecond();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        bytes memory realCode = _breakRegistry();

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestParkSkipped(
            second,
            referee
        );

        _transferAs(
            second,
            sink,
            7_000 * ONE
        );

        _restoreRegistry(
            realCode
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            10_000 * ONE
        );

        _plainDepositAs(
            third,
            ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );

        assertEq(
            _recorder().getCohortScore(otherReferrer),
            7_000 * ONE
        );

        _pokeAs(
            third,
            second
        );

        assertEq(
            _recorder().getCohortScore(otherReferrer),
            0
        );
    }

    function test_lookupFailure_sameSenderAgain_staysParkedSilently()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            4_000 * ONE
        );

        bytes memory realCode = _breakRegistry();

        vm.recordLogs();

        _transferAs(
            referee,
            sink,
            6_000 * ONE
        );

        _restoreRegistry(
            realCode
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 skipped = keccak256(
            "CohortDivestParkSkipped(address,address)"
        );

        bytes32 parkedSig = keccak256(
            "CohortDivestParked(address)"
        );

        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != skipped
            );

            assertTrue(
                logs[i].topics[0] != parkedSig
            );
        }

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            10_000 * ONE
        );

        _plainDepositAs(
            third,
            ONE
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );
    }

    // ---- router-initiated calls never drain ----

    function test_routerCaller_skipsDrain()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        BridgeFacet(address(diamond)).setCcipRouter(
            router
        );

        _pokeAs(
            router,
            sink
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            10_000 * ONE
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );
    }

    function test_routerCaller_parkedUserStillClampsItself()
        public
    {
        _stageReferee();

        _transferAs(
            referee,
            sink,
            10_000 * ONE
        );

        BridgeFacet(address(diamond)).setCcipRouter(
            router
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(diamond)
        );

        emit CohortContributionSynced(
            referee,
            referrer,
            10_000 * ONE,
            0
        );

        _pokeAs(
            router,
            referee
        );

        assertEq(
            _parked(),
            referee
        );

        assertEq(
            _recorder().getTrackedContribution(referee),
            0
        );

        assertEq(
            _recorder().getCohortScore(referrer),
            0
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(diamond)
        );

        emit CohortDivestDrained(
            referee
        );

        _pokeAs(
            third,
            sink
        );

        assertEq(
            _parked(),
            address(0)
        );
    }
}
