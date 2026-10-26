// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {Permit2UserFacet} from "../../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {MoveFacet} from "../../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {AutoCompoundFacet} from "../../../src/diamond/vault/facets/AutoCompoundFacet.sol";
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortHookFacet} from "../../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortMoveHookFacet} from "../../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";

import {FacetNotFound, SelectorTimelockNotElapsed} from "../../../src/diamond/shared/DiamondErrors.sol";
import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

interface IPermit2Domain {

    function DOMAIN_SEPARATOR()
        external
        view
        returns (bytes32);
}

/**
 * @dev Minimal local surface of the LIVE WiseTelecomNodes diamond,
 * driven through its own dispatcher and fallback router. The cohort,
 * referral and registry-pointer entrypoints are declared even though
 * the live dispatcher does not know them yet; after the rehearsed
 * upgrade they resolve through the selector routing, which is what
 * this test proves.
 */
interface IWtnCohortVault {

    function master()
        external
        view
        returns (address);

    function USD_TOKEN()
        external
        view
        returns (address);

    function balanceOf(
        address account
    )
        external
        view
        returns (uint256);

    function totalSupply()
        external
        view
        returns (uint256);

    function depositsDisabled()
        external
        view
        returns (bool);

    function paused()
        external
        view
        returns (bool);

    function graceThresholdAmount()
        external
        view
        returns (uint256);

    function selectorToFacet(
        bytes4 selector
    )
        external
        view
        returns (address);

    function transferHookFacet()
        external
        view
        returns (address);

    function proposeSelectors(
        bytes4[] memory selectors,
        address facet
    )
        external;

    function executeSelectorChanges(
        bytes4[] memory selectors
    )
        external;

    function proposeTransferHookFacet(
        address facet
    )
        external;

    function executeTransferHookFacetChange()
        external;

    function proposeReferralRegistry(
        address registry
    )
        external;

    function executeReferralRegistryChange()
        external;

    function getReferralRegistry()
        external
        view
        returns (address);

    function getProposedReferralRegistry()
        external
        view
        returns (address);

    function getReferralRegistryChangeQueuedAt()
        external
        view
        returns (uint256);

    function setDepositsDisabled(
        bool disabled
    )
        external;

    function unpauseDeposits()
        external;

    function setTotalDepositCap(
        uint256 newCap
    )
        external;

    function setGraceFreezeEnabled(
        bool enabled
    )
        external;

    function setCohortSyncEnabled(
        bool enabled
    )
        external;

    function setBridgeGasLimit(
        uint256 gasLimit
    )
        external;

    function bridgeGasLimit()
        external
        view
        returns (uint64);

    function transfer(
        address to,
        uint256 amount
    )
        external
        returns (bool);

    function deposit(
        uint256 amount
    )
        external;

    function joinQue(
        uint256 amount,
        int256 incentive
    )
        external;

    function leaveQue(
        uint256 queMemberId,
        int256 incentive
    )
        external;

    function switchQueIncentive(
        uint256 queMemberId,
        int256 oldIncentive,
        int256 newIncentive
    )
        external;

    function minDepositAmount()
        external
        view
        returns (uint256);

    function earliestValidQueMemberByIncentive(
        int256 incentive
    )
        external
        view
        returns (uint256);

    function moveBetweenVaults(
        address dstVault,
        uint256 amount
    )
        external;

    function proposePeerVault(
        address peer
    )
        external;

    function executePeerVaultChange(
        address peer
    )
        external;

    function peerVault(
        address peer
    )
        external
        view
        returns (bool);

    function getReferrerOf(
        address user
    )
        external
        view
        returns (address);

    function depositWithReferral(
        uint256 amount,
        address referrer
    )
        external;

    function depositWithPermit2WithReferral(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        address referrer
    )
        external;

    function syncReferee(
        address user
    )
        external;

    function advanceBook(
        address referrer,
        uint256 maxBoundaries
    )
        external;

    function getCohortSyncEnabled()
        external
        view
        returns (bool);

    function getTrackedContribution(
        address user
    )
        external
        view
        returns (uint256);

    function getCohortBook(
        address referrer
    )
        external
        view
        returns (
            uint256 year1,
            uint256 year2,
            uint256 mature,
            uint256 lastSettleTimestamp
        );

    function getCohortScore(
        address referrer
    )
        external
        view
        returns (uint256);

    function getCohortRings(
        address referrer
    )
        external
        view
        returns (
            uint64[52] memory year1,
            uint64[52] memory year2
        );

    function getCohortWeekCrumb(
        address referrer,
        uint256 week
    )
        external
        view
        returns (uint256);
}

interface IUsdToken {

    function decimals()
        external
        view
        returns (uint8);
}

/**
 * @title ReferralRegistryUpgradeForkBase
 * @dev Rehearses the {UpgradeReferralRegistry} rollout
 * against a LIVE, already-finalized diamond on a
 * fork of each production chain, the one rehearsal embedding the
 * full recorder-plus-registry lifecycle.
 * The LIVE diamond entry contract is never
 * redeployed: the round deploys NEW facets, routes selectors through
 * the real 3-day timelock, and wires the slot-77 pointer, the first
 * rehearsal ever to deploy a standalone companion contract
 * ({ReferralRegistry}) on a live fork. Proves, per chain:
 *   1. the live dispatcher does NOT know the cohort, referral OR
 *      pointer surfaces, and the user's slot-67 mapping entry is
 *      raw-zero on the real bytecode;
 *   2. the standalone registry deploys on-fork and allowlists the
 *      diamond (mirroring {DeployReferralRegistry});
 *   3. the upgrade script's full selector manifest (all thirteen
 *      batches, the routed bridge-hook slice included, plus the
 *      transfer-hook swap) works under the real master and both real
 *      3-day timelocks;
 *   4. the SECOND clock: the pointer proposal through the
 *      freshly-routed {AdminFacet} trio, its premature-execute
 *      revert, and the pointer-unset intermediate state being
 *      default-off (plain deposits and transfers write zero recorder
 *      state, `getReferrerOf` returns zero WITHOUT reverting, and
 *      `depositWithReferral` reverts {ReferralRegistryNotSet} loudly,
 *      no silent referrer drop) with arming blocked until wired;
 *   5. after executePointer + arm, the full recorder lifecycle holds
 *      against the real USD token with the registry as sole truth:
 *      referred credit, write-once referrer (asserted on the
 *      REGISTRY's storage while slot 67 stays raw-zero), lazy clamp,
 *      clamp-before-credit re-deposit, queue-join discredit, 52-week
 *      graduation, grace-freeze preservation, a real
 *      Permit2-signature referral deposit, and the capped
 *      dormant-book walk staying under its gas budget;
 *   6. the tracked-equals-book and ring-equals-book-lane identities
 *      hold after every mutating step, and
 *      the registry's code persists across blocks (EIP-6780: no
 *      selfdestruct path exists; re-verify semantics per chain
 *      before any real broadcast on non-Cancun networks);
 *   7. the optional retirement leg: the genesis passthrough pair
 *      (`bridgeToVaultWithReferral`, `quoteBridgeFeeWithReferral`)
 *      is proposed to the zero facet through the same real 3-day
 *      selector timelock, executes only after the delay, then
 *      reverts {FacetNotFound} through the live fallback while
 *      `bridgeToVault` and `quoteBridgeFee` keep routing to the
 *      round's {BridgeFacet}.
 * The diamond address is read from config/vault.<product>.<network>
 * .json before forking so it can never drift to a wrong or stale
 * address. The rehearsal user is a labelled key from `makeAddrAndKey`,
 * never a toy constant: on 2026-09-28 the address of the toy key
 * 0xA11CE was found carrying an EIP-7702 delegation on Robinhood
 * mainnet, which sends Permit2 down the contract-signature path and
 * fails the permit deposit of this rehearsal on that chain.
 */
abstract contract ReferralRegistryUpgradeForkBase is Test {

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256(
        "TokenPermissions(address token,uint256 amount)"
    );

    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant REGISTRY_DELAY = 3 days;

    uint256 internal userPk;

    uint256 internal constant DORMANT_WALK_GAS_BUDGET = 3_500_000;

    struct Cfg {
        string rpc;
        string product;
        string network;
    }

    IWtnCohortVault internal v;
    ReferralRegistry internal registry;
    address internal usd;
    address internal master;
    uint256 internal one;
    address internal user;
    address internal user2;
    address internal refA;
    address internal refB;

    function _config()
        internal
        pure
        virtual
        returns (Cfg memory);

    function setUp()
        public
    {
        Cfg memory cfg = _config();

        string memory json = vm.readFile(
            string.concat(
                "config/vault.",
                cfg.product,
                ".",
                cfg.network,
                ".json"
            )
        );

        address diamond = vm.parseJsonAddress(
            json,
            ".diamond"
        );

        vm.createSelectFork(
            cfg.rpc
        );

        require(
            diamond.code.length > 0,
            "diamond not deployed on this fork"
        );

        v = IWtnCohortVault(
            diamond
        );

        usd = v.USD_TOKEN();

        master = v.master();

        one = 10 ** IUsdToken(usd).decimals();

        (
            user,
            userPk
        ) = makeAddrAndKey(
            "registryForkUser"
        );

        user2 = makeAddr(
            "registryForkUser2"
        );

        refA = makeAddr(
            "registryForkRefA"
        );

        refB = makeAddr(
            "registryForkRefB"
        );
    }

    function _approveUsd(
        address _from,
        address _spender
    )
        internal
    {
        vm.prank(
            _from
        );

        (
            bool ok,
        ) = usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                _spender,
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );
    }

    function _signPermit2(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(
                TOKEN_PERMISSIONS_TYPEHASH,
                usd,
                _amount
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                tokenPermissionsHash,
                address(v),
                _nonce,
                _deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IPermit2Domain(CANONICAL_PERMIT2).DOMAIN_SEPARATOR(),
                structHash
            )
        );

        (
            uint8 sigV,
            bytes32 sigR,
            bytes32 sigS
        ) = vm.sign(
            userPk,
            digest
        );

        return abi.encodePacked(
            sigR,
            sigS,
            sigV
        );
    }

    function _assertSelectorUnknown(
        bytes memory _calldata
    )
        internal
    {
        (
            bool ok,
            bytes memory ret
        ) = address(v).call(
            _calldata
        );

        assertFalse(
            ok,
            "selector already live before the upgrade"
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector,
            "expected FacetNotFound from the live fallback"
        );
    }

    function _slot67Entry(
        address _user
    )
        internal
        view
        returns (bytes32)
    {
        return vm.load(
            address(v),
            keccak256(
                abi.encode(
                    _user,
                    uint256(67)
                )
            )
        );
    }

    function _assertBookConsistent(
        address _referrer,
        uint256 _expectedRefereeTracked
    )
        internal
        view
    {
        (
            uint256 year1,
            uint256 year2,
            uint256 mature,

        ) = v.getCohortBook(_referrer);

        assertEq(
            _expectedRefereeTracked,
            year1 + year2 + mature,
            "tracked-equals-book: referee tracked != book total"
        );

        assertEq(
            v.getCohortScore(
                _referrer
            ),
            year1 + year2 + mature,
            "tracked-equals-book: score != book total"
        );

        (
            uint64[52] memory ring1,
            uint64[52] memory ring2
        ) = v.getCohortRings(_referrer);

        uint256 ring1Sum;

        uint256 ring2Sum;

        for (uint256 i; i < 52; ++i) {
            ring1Sum += uint256(ring1[i]);
            ring2Sum += uint256(ring2[i]);
        }

        assertEq(
            ring1Sum,
            year1,
            "ring-equals-lane: ring1 sum != bookY1"
        );

        assertEq(
            ring2Sum,
            year2,
            "ring-equals-lane: ring2 sum != bookY2"
        );
    }

    function test_registryUpgrade_rehearsalEndToEnd()
        public
    {

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "getTrackedContribution(address)",
                user
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "syncReferee(address)",
                user
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "depositWithReferral(uint256,address)",
                one,
                refA
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "getReferrerOf(address)",
                user
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "proposeReferralRegistry(address)",
                address(0)
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "getReferralRegistry()"
            )
        );

        assertEq(
            _slot67Entry(
                user
            ),
            bytes32(0),
            "slot-67 entry not virgin on live bytecode"
        );

        address hookBefore = v.transferHookFacet();

        registry = new ReferralRegistry(
            address(this),
            0
        );

        registry.setAllowedVault(
            address(v),
            true
        );

        assertEq(
            registry.referrerOf(
                user
            ),
            address(0),
            "fresh registry must be empty"
        );

        address cohortHookFacet = address(
            new CohortHookFacet()
        );

        _proposeAllGroups();

        vm.prank(
            master
        );

        v.proposeTransferHookFacet(
            cohortHookFacet
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.TransferHookTimelockNotElapsed.selector
        );

        v.executeTransferHookFacetChange();

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        _executeAllGroups();

        vm.prank(
            master
        );

        v.executeTransferHookFacetChange();

        assertEq(
            v.transferHookFacet(),
            cohortHookFacet,
            "cohort hook not installed"
        );

        assertTrue(
            v.transferHookFacet() != hookBefore,
            "hook unchanged"
        );

        assertEq(
            v.selectorToFacet(
                WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()[0]
            ) == address(0),
            false,
            "cohort group not routed"
        );

        assertEq(
            v.selectorToFacet(
                WiseTelecomNodesDiamondSelectors._cohortBridgeHookSelectors()[0]
            ) == address(0),
            false,
            "bridge-hook group not routed"
        );

        if (v.paused()) {

            vm.prank(
                master
            );

            v.unpauseDeposits();
        }

        if (v.depositsDisabled()) {

            vm.prank(
                master
            );

            v.setDepositsDisabled(
                false
            );
        }

        uint256 baseAmount = 1_000 * one;

        uint256 stampAmount = v.graceThresholdAmount();

        uint256 liftedCap = v.totalSupply()
            + 40 * baseAmount
            + 2 * stampAmount;

        vm.prank(
            master
        );

        v.setTotalDepositCap(
            liftedCap
        );

        deal(
            usd,
            user,
            20 * baseAmount
        );

        deal(
            usd,
            user2,
            2 * stampAmount
        );

        _approveUsd(
            user,
            address(v)
        );

        _approveUsd(
            user,
            CANONICAL_PERMIT2
        );

        _approveUsd(
            user2,
            address(v)
        );

        assertEq(
            v.getReferralRegistry(),
            address(0),
            "pointer must start unset"
        );

        assertEq(
            v.getReferrerOf(
                user
            ),
            address(0),
            "unset pointer must read as zero, not revert"
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ReferralRegistryNotSet.selector
        );

        v.setCohortSyncEnabled(
            true
        );

        vm.prank(
            user
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ReferralRegistryNotSet.selector
        );

        v.depositWithReferral(
            baseAmount,
            refA
        );

        vm.prank(
            user
        );

        v.deposit(
            baseAmount
        );

        vm.prank(
            user
        );

        v.transfer(
            user2,
            one
        );

        assertEq(
            v.getTrackedContribution(
                user
            ),
            0,
            "unarmed + unpointed state must write no recorder state"
        );

        vm.prank(
            master
        );

        v.proposeReferralRegistry(
            address(registry)
        );

        assertEq(
            v.getProposedReferralRegistry(),
            address(registry),
            "pointer proposal not staged"
        );

        assertGt(
            v.getReferralRegistryChangeQueuedAt(),
            0,
            "pointer clock not started"
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ReferralRegistryTimelockNotElapsed.selector
        );

        v.executeReferralRegistryChange();

        vm.warp(
            block.timestamp + REGISTRY_DELAY + 1
        );

        vm.prank(
            master
        );

        v.executeReferralRegistryChange();

        assertEq(
            v.getReferralRegistry(),
            address(registry),
            "pointer not wired"
        );

        vm.prank(
            master
        );

        v.setBridgeGasLimit(
            5_000_000
        );

        vm.prank(
            master
        );

        v.setCohortSyncEnabled(
            true
        );

        assertTrue(
            v.getCohortSyncEnabled(),
            "arming failed"
        );

        assertEq(
            uint256(v.bridgeGasLimit()),
            5_000_000,
            "armed bridge gas limit not set"
        );

        vm.prank(
            user
        );

        v.depositWithReferral(
            baseAmount,
            refA
        );

        assertEq(
            v.getReferrerOf(
                user
            ),
            refA,
            "referrer not assigned"
        );

        assertEq(
            registry.referrerOf(
                user
            ),
            refA,
            "registry must hold the truth"
        );

        assertEq(
            _slot67Entry(
                user
            ),
            bytes32(0),
            "slot 67 must stay virgin forever"
        );

        assertEq(
            v.getTrackedContribution(
                user
            ),
            baseAmount,
            "credit missing"
        );

        _assertBookConsistent(
            refA,
            baseAmount
        );

        vm.prank(
            user
        );

        v.depositWithReferral(
            baseAmount,
            refB
        );

        assertEq(
            v.getReferrerOf(
                user
            ),
            refA,
            "write-once violated"
        );

        assertEq(
            registry.referrerOf(
                user
            ),
            refA,
            "registry write-once violated"
        );

        assertEq(
            v.getTrackedContribution(
                user
            ),
            2 * baseAmount,
            "second credit missing"
        );

        _assertBookConsistent(
            refA,
            2 * baseAmount
        );

        uint256 sigAmount = baseAmount / 2;

        bytes memory sig = _signPermit2(
            sigAmount,
            777,
            block.timestamp + 1 hours
        );

        vm.prank(
            user
        );

        v.depositWithPermit2WithReferral(
            sigAmount,
            777,
            block.timestamp + 1 hours,
            sig,
            refB
        );

        uint256 tracked = 2 * baseAmount + sigAmount;

        assertEq(
            v.getTrackedContribution(
                user
            ),
            tracked,
            "permit2 credit missing"
        );

        _assertBookConsistent(
            refA,
            2 * baseAmount + sigAmount
        );

        vm.prank(
            user
        );

        v.transfer(
            user2,
            3 * baseAmount
        );

        assertEq(
            v.getTrackedContribution(
                user
            ),
            tracked,
            "clamp must be lazy"
        );

        v.syncReferee(
            user
        );

        uint256 heldNow = v.balanceOf(
            user
        );

        assertEq(
            v.getTrackedContribution(
                user
            ),
            heldNow,
            "clamp missed the deficit"
        );

        vm.prank(
            user
        );

        v.deposit(
            baseAmount
        );

        assertEq(
            v.getTrackedContribution(
                user
            ),
            heldNow + baseAmount,
            "re-deposit must credit exactly its own amount"
        );

        uint256 beforeJoin = v.getTrackedContribution(
            user
        );

        vm.prank(
            user
        );

        v.joinQue(
            baseAmount / 2,
            0
        );

        assertEq(
            v.getTrackedContribution(
                user
            ),
            beforeJoin - baseAmount / 2,
            "join must discredit immediately"
        );

        vm.prank(
            user2
        );

        v.deposit(
            stampAmount
        );

        vm.prank(
            master
        );

        v.setGraceFreezeEnabled(
            true
        );

        vm.prank(
            user2
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.GracePeriodNotElapsed.selector
        );

        v.transfer(
            user,
            one
        );

        vm.prank(
            master
        );

        v.setGraceFreezeEnabled(
            false
        );

        vm.prank(
            user2
        );

        v.transfer(
            user,
            one
        );

        uint256 depositWeek = block.timestamp / CohortWeeks.WEEK;

        vm.warp(
            block.timestamp + 53 weeks
        );

        v.advanceBook(
            refA,
            104
        );

        (
            ,
            uint256 year2After,
            ,
        ) = v.getCohortBook(refA);

        assertGt(
            year2After,
            0,
            "cohort did not graduate to year 2"
        );

        assertTrue(
            v.getCohortWeekCrumb(
                refA,
                depositWeek
            ) & CohortWeeks.CRUMB_WRITTEN_BIT != 0,
            "deposit week crumb missing"
        );

        vm.warp(
            block.timestamp + 120 weeks
        );

        vm.prank(
            user
        );

        v.transfer(
            user2,
            one
        );

        vm.prank(
            user
        );

        uint256 gasBefore = gasleft();

        v.transfer(
            user2,
            one
        );

        uint256 gasUsed = gasBefore - gasleft();

        assertLt(
            gasUsed,
            DORMANT_WALK_GAS_BUDGET,
            "dormant-book walk exceeds the hook gas budget"
        );

        v.syncReferee(
            user
        );

        _assertBookConsistent(
            refA,
            v.getTrackedContribution(
                user
            )
        );

        vm.roll(
            block.number + 1
        );

        assertGt(
            address(registry).code.length,
            0,
            "registry code must persist (EIP-6780)"
        );

        assertEq(
            registry.referrerOf(
                user
            ),
            refA,
            "registry truth must persist"
        );
    }

    function test_registryUpgrade_retireLegacyReferralBridge_timelockedRemoval()
        public
    {
        _proposeAllGroups();

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        _executeAllGroups();

        address bridgeFacet = v.selectorToFacet(
            BridgeFacet.bridgeToVault.selector
        );

        assertTrue(
            bridgeFacet != address(0),
            "bridge group not routed"
        );

        assertEq(
            v.selectorToFacet(
                BridgeFacet.bridgeToVaultWithReferral.selector
            ),
            bridgeFacet,
            "legacy bridgeToVaultWithReferral not on the round's BridgeFacet"
        );

        assertEq(
            v.selectorToFacet(
                BridgeFacet.quoteBridgeFeeWithReferral.selector
            ),
            bridgeFacet,
            "legacy quoteBridgeFeeWithReferral not on the round's BridgeFacet"
        );

        bytes4[] memory pair = WiseTelecomNodesDiamondSelectors._legacyReferralBridgeSelectors();

        vm.prank(
            master
        );

        v.proposeSelectors(
            pair,
            address(0)
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        v.executeSelectorChanges(
            pair
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        vm.prank(
            master
        );

        v.executeSelectorChanges(
            pair
        );

        assertEq(
            v.selectorToFacet(
                BridgeFacet.bridgeToVaultWithReferral.selector
            ),
            address(0),
            "bridgeToVaultWithReferral still routed after retirement"
        );

        assertEq(
            v.selectorToFacet(
                BridgeFacet.quoteBridgeFeeWithReferral.selector
            ),
            address(0),
            "quoteBridgeFeeWithReferral still routed after retirement"
        );

        assertEq(
            v.selectorToFacet(
                BridgeFacet.bridgeToVault.selector
            ),
            bridgeFacet,
            "bridgeToVault lost its route"
        );

        assertEq(
            v.selectorToFacet(
                BridgeFacet.quoteBridgeFee.selector
            ),
            bridgeFacet,
            "quoteBridgeFee lost its route"
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "bridgeToVaultWithReferral(uint64,uint256,bytes)",
                uint64(1),
                uint256(1),
                bytes("")
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "quoteBridgeFeeWithReferral(uint64,uint256,bytes)",
                uint64(1),
                uint256(1),
                bytes("")
            )
        );

        assertTrue(
            v.selectorToFacet(
                BridgeFacet.quoteBridgeFee.selector
            ) != address(0),
            "quoteBridgeFee must still resolve to the facet"
        );
    }

    function _proposeAllGroups()
        internal
    {
        _proposeOne(
            WiseTelecomNodesDiamondSelectors._adminSelectors(),
            address(new AdminFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._userSelectors(),
            address(new UserFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._permit2Selectors(),
            address(new Permit2UserFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._moveSelectors(),
            address(new MoveFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._bridgeSelectors(),
            address(new BridgeFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors(),
            address(new QueueJoinLeaveFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._queueFulfillSelectors(),
            address(new QueueFulfillFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._referralSelectors(),
            address(new ReferralFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors(),
            address(new Permit2ReferralFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors(),
            address(new CohortRecorderFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._cohortBridgeHookSelectors(),
            address(new CohortBridgeHookFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors(),
            address(new CohortMoveHookFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors._autoCompoundSelectors(),
            address(new AutoCompoundFacet())
        );
    }

    function _executeAllGroups()
        internal
    {
        _executeOne(
            WiseTelecomNodesDiamondSelectors._adminSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._userSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._permit2Selectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._moveSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._bridgeSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._queueFulfillSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._referralSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        address autoCompoundBefore = v.selectorToFacet(
            AutoCompoundFacet.compoundInterestOnBehalf.selector
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors._autoCompoundSelectors()
        );

        assertTrue(
            v.selectorToFacet(
                AutoCompoundFacet.compoundInterestOnBehalf.selector
            ) != autoCompoundBefore,
            "auto compound batch not rerouted"
        );
    }

    function _proposeOne(
        bytes4[] memory _sels,
        address _facet
    )
        internal
    {
        vm.prank(
            master
        );

        v.proposeSelectors(
            _sels,
            _facet
        );
    }

    function _executeOne(
        bytes4[] memory _sels
    )
        internal
    {
        vm.prank(
            master
        );

        v.executeSelectorChanges(
            _sels
        );
    }
}

/**
 * @dev The cross-vault half of the rehearsal, parameterized per
 * chain via `_pairConfig` (mainnet and Base pair usdc + usdt,
 * Arbitrum pairs usdc + usdg): ONE registry serving TWO real
 * diamonds. Runs the
 * full two-clock round on both diamonds against one registry, then
 * proves write-once-per-chain on real bytecode: a referral recorded
 * through the first diamond makes a PLAIN deposit on the second
 * credit the same referrer through the registry staticcall, and a
 * later `depositWithReferral` with a different referrer on the
 * second diamond is silently ignored (write-once per chain, not per
 * vault). The rehearsal then registers the two diamonds as peers
 * through the real 3-day peer timelock, runs a same-chain
 * `moveBetweenVaults` round trip (carry out, carry back, books and
 * tracked restored exactly, mailbox drained in-transaction) and a
 * queue phase (join discredits, `switchQueIncentive` stays
 * recorder-silent, leave restores tokens but never credit).
 */
abstract contract ReferralRegistryCrossVaultForkBase is Test {

    struct PairCfg {
        string rpc;
        string configPathA;
        string configPathB;
    }

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant REGISTRY_DELAY = 3 days;

    uint256 internal constant PEER_DELAY = 3 days;

    int256 internal constant QUE_INCENTIVE = 100;

    IWtnCohortVault internal va;
    IWtnCohortVault internal vb;
    ReferralRegistry internal registry;
    address internal user;
    address internal refA;
    address internal refB;

    function _pairConfig()
        internal
        pure
        virtual
        returns (PairCfg memory);

    function setUp()
        public
    {
        PairCfg memory cfg = _pairConfig();

        string memory jsonA = vm.readFile(
            cfg.configPathA
        );

        string memory jsonB = vm.readFile(
            cfg.configPathB
        );

        address diamondA = vm.parseJsonAddress(
            jsonA,
            ".diamond"
        );

        address diamondB = vm.parseJsonAddress(
            jsonB,
            ".diamond"
        );

        vm.createSelectFork(
            cfg.rpc
        );

        require(
            diamondA.code.length > 0 && diamondB.code.length > 0,
            "diamonds not deployed on this fork"
        );

        va = IWtnCohortVault(
            diamondA
        );

        vb = IWtnCohortVault(
            diamondB
        );

        user = makeAddr(
            "crossVaultUser"
        );

        refA = makeAddr(
            "crossVaultRefA"
        );

        refB = makeAddr(
            "crossVaultRefB"
        );
    }

    function test_crossVault_registryWriteOnceMoveCarryAndQueue_endToEnd()
        public
    {
        registry = new ReferralRegistry(
            address(this),
            0
        );

        registry.setAllowedVault(
            address(va),
            true
        );

        registry.setAllowedVault(
            address(vb),
            true
        );

        _installRound(
            va
        );

        _installRound(
            vb
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        _executeRound(
            va
        );

        _executeRound(
            vb
        );

        _proposePointer(
            va
        );

        _proposePointer(
            vb
        );

        vm.warp(
            block.timestamp + REGISTRY_DELAY + 1
        );

        _executePointerAndArm(
            va
        );

        _executePointerAndArm(
            vb
        );

        uint256 amountA = _prepDeposit(
            va
        );

        uint256 amountB = _prepDeposit(
            vb
        );

        vm.prank(
            user
        );

        va.depositWithReferral(
            amountA,
            refA
        );

        assertEq(
            registry.referrerOf(
                user
            ),
            refA,
            "assignment through diamond A missing"
        );

        vm.prank(
            user
        );

        vb.deposit(
            amountB
        );

        assertEq(
            vb.getTrackedContribution(
                user
            ),
            amountB,
            "plain deposit on B must be tracked"
        );

        assertEq(
            vb.getCohortScore(
                refA
            ),
            amountB,
            "plain deposit on B must credit A's referrer through the registry"
        );

        uint256 amountB2 = _prepDeposit(
            vb
        );

        vm.prank(
            user
        );

        vb.depositWithReferral(
            amountB2,
            refB
        );

        assertEq(
            registry.referrerOf(
                user
            ),
            refA,
            "write-once must hold across vaults"
        );

        assertEq(
            vb.getCohortScore(
                refB
            ),
            0,
            "the ignored referrer must earn nothing"
        );

        assertEq(
            vb.getCohortScore(
                refA
            ),
            amountB + amountB2,
            "the sticky referrer must keep earning on vault B"
        );

        assertEq(
            va.getCohortScore(
                refA
            ),
            amountA,
            "books stay per-vault"
        );

        _registerPeers();

        _movePhase(
            amountA,
            amountB + amountB2
        );

        _queuePhase(
            amountA
        );
    }

    function _registerPeers()
        internal
    {
        bool aToB = va.peerVault(
            address(vb)
        );

        bool bToA = vb.peerVault(
            address(va)
        );

        if (aToB && bToA) {
            return;
        }

        if (aToB == false) {

            vm.prank(
                va.master()
            );

            va.proposePeerVault(
                address(vb)
            );
        }

        if (bToA == false) {

            vm.prank(
                vb.master()
            );

            vb.proposePeerVault(
                address(va)
            );
        }

        vm.warp(
            block.timestamp + PEER_DELAY + 1
        );

        if (aToB == false) {

            vm.prank(
                va.master()
            );

            va.executePeerVaultChange(
                address(vb)
            );
        }

        if (bToA == false) {

            vm.prank(
                vb.master()
            );

            vb.executePeerVaultChange(
                address(va)
            );
        }

        assertEq(
            va.peerVault(
                address(vb)
            ),
            true,
            "A->B peer link must be live after registration"
        );

        assertEq(
            vb.peerVault(
                address(va)
            ),
            true,
            "B->A peer link must be live after registration"
        );
    }

    function _movePhase(
        uint256 _sliceA,
        uint256 _restB
    )
        internal
    {
        vm.prank(
            user
        );

        va.moveBetweenVaults(
            address(vb),
            _sliceA
        );

        assertEq(
            va.getCohortScore(
                refA
            ),
            0,
            "move must carry the whole A slice"
        );

        assertEq(
            vb.getCohortScore(
                refA
            ),
            _sliceA + _restB,
            "carry must land on B in full"
        );

        assertEq(
            va.getTrackedContribution(
                user
            ),
            0,
            "tracked must leave A"
        );

        assertEq(
            vb.getTrackedContribution(
                user
            ),
            _sliceA + _restB,
            "tracked must arrive on B"
        );

        (
            uint256 stagedAt,
        ) = registry.getCarry(
            address(va),
            address(vb),
            user
        );

        assertEq(
            stagedAt,
            0,
            "mailbox must be drained in the same transaction"
        );

        vm.prank(
            user
        );

        vb.moveBetweenVaults(
            address(va),
            _sliceA
        );

        assertEq(
            va.getCohortScore(
                refA
            ),
            _sliceA,
            "round trip must restore the A book exactly"
        );

        assertEq(
            vb.getCohortScore(
                refA
            ),
            _restB,
            "round trip must restore the B book exactly"
        );

        assertEq(
            va.getTrackedContribution(
                user
            ),
            _sliceA,
            "round trip must restore A tracked"
        );

        assertEq(
            vb.getTrackedContribution(
                user
            ),
            _restB,
            "round trip must restore B tracked"
        );
    }

    function _queuePhase(
        uint256 _amount
    )
        internal
    {
        require(
            va.minDepositAmount() <= _amount,
            "queue phase needs joinable amount"
        );

        vm.prank(
            user
        );

        va.joinQue(
            _amount,
            QUE_INCENTIVE
        );

        assertEq(
            va.getTrackedContribution(
                user
            ),
            0,
            "join must discredit post-escrow"
        );

        assertEq(
            va.getCohortScore(
                refA
            ),
            0,
            "join discredit must reduce the book"
        );

        uint256 orderId = va.earliestValidQueMemberByIncentive(
            QUE_INCENTIVE
        ) - 1;

        (
            uint256 year1Before,
            uint256 year2Before,
            uint256 matureBefore,
            uint256 lastSettleBefore
        ) = va.getCohortBook(
            refA
        );

        vm.prank(
            user
        );

        va.switchQueIncentive(
            orderId,
            QUE_INCENTIVE,
            200
        );

        (
            uint256 year1After,
            uint256 year2After,
            uint256 matureAfter,
            uint256 lastSettleAfter
        ) = va.getCohortBook(
            refA
        );

        assertEq(
            year1After,
            year1Before,
            "switch must be recorder-silent (Y1)"
        );

        assertEq(
            year2After,
            year2Before,
            "switch must be recorder-silent (Y2)"
        );

        assertEq(
            matureAfter,
            matureBefore,
            "switch must be recorder-silent (M)"
        );

        assertEq(
            lastSettleAfter,
            lastSettleBefore,
            "switch must not settle the book"
        );

        orderId = va.earliestValidQueMemberByIncentive(
            200
        ) - 1;

        vm.prank(
            user
        );

        va.leaveQue(
            orderId,
            200
        );

        assertEq(
            va.balanceOf(
                user
            ),
            _amount,
            "escrow must return on leave"
        );

        assertEq(
            va.getTrackedContribution(
                user
            ),
            0,
            "leave must not re-credit tracked"
        );

        assertEq(
            va.getCohortScore(
                refA
            ),
            0,
            "leave must not re-credit the book"
        );
    }

    function _installRound(
        IWtnCohortVault _v
    )
        internal
    {
        address m = _v.master();

        vm.startPrank(
            m
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._adminSelectors(),
            address(new AdminFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._userSelectors(),
            address(new UserFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._referralSelectors(),
            address(new ReferralFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors(),
            address(new CohortRecorderFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors(),
            address(new CohortMoveHookFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._moveSelectors(),
            address(new MoveFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors(),
            address(new QueueJoinLeaveFacet())
        );

        _v.proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        vm.stopPrank();
    }

    function _executeRound(
        IWtnCohortVault _v
    )
        internal
    {
        address m = _v.master();

        vm.startPrank(
            m
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._adminSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._userSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._referralSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._moveSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors()
        );

        _v.executeTransferHookFacetChange();

        vm.stopPrank();
    }

    function _proposePointer(
        IWtnCohortVault _v
    )
        internal
    {
        vm.prank(
            _v.master()
        );

        _v.proposeReferralRegistry(
            address(registry)
        );
    }

    function _executePointerAndArm(
        IWtnCohortVault _v
    )
        internal
    {
        address m = _v.master();

        vm.startPrank(
            m
        );

        _v.executeReferralRegistryChange();

        _v.setBridgeGasLimit(
            5_000_000
        );

        _v.setCohortSyncEnabled(
            true
        );

        vm.stopPrank();
    }

    function _prepDeposit(
        IWtnCohortVault _v
    )
        internal
        returns (uint256 amount)
    {
        address m = _v.master();

        if (_v.paused()) {

            vm.prank(
                m
            );

            _v.unpauseDeposits();
        }

        if (_v.depositsDisabled()) {

            vm.prank(
                m
            );

            _v.setDepositsDisabled(
                false
            );
        }

        address usd = _v.USD_TOKEN();

        amount = 1_000 * 10 ** IUsdToken(usd).decimals();

        uint256 liftedCap = _v.totalSupply() + 10 * amount;

        vm.prank(
            m
        );

        _v.setTotalDepositCap(
            liftedCap
        );

        uint256 topped = _usdBalance(
            usd,
            user
        ) + 3 * amount;

        deal(
            usd,
            user,
            topped
        );

        uint256 allowance = _usdAllowance(
            usd,
            user,
            address(_v)
        );

        if (allowance > 0) {
            return amount;
        }

        vm.prank(
            user
        );

        (
            bool ok,
        ) = usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(_v),
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );
    }

    function _usdAllowance(
        address _usd,
        address _owner,
        address _spender
    )
        internal
        view
        returns (uint256)
    {
        (
            bool ok,
            bytes memory ret
        ) = _usd.staticcall(
            abi.encodeWithSignature(
                "allowance(address,address)",
                _owner,
                _spender
            )
        );

        require(
            ok && ret.length == 32,
            "usd allowance failed"
        );

        return abi.decode(
            ret,
            (uint256)
        );
    }

    function _usdBalance(
        address _usd,
        address _holder
    )
        internal
        view
        returns (uint256)
    {
        (
            bool ok,
            bytes memory ret
        ) = _usd.staticcall(
            abi.encodeWithSignature(
                "balanceOf(address)",
                _holder
            )
        );

        require(
            ok && ret.length == 32,
            "usd balanceOf failed"
        );

        return abi.decode(
            ret,
            (uint256)
        );
    }
}

contract ReferralRegistryUpgradeUsdcMainnetFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            product: "usdc",
            network: "mainnet"
        });
    }
}

contract ReferralRegistryUpgradeUsdcBaseFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "base",
            product: "usdc",
            network: "base"
        });
    }
}

contract ReferralRegistryUpgradeUsdcArbitrumFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            product: "usdc",
            network: "arbitrum"
        });
    }
}

contract ReferralRegistryUpgradeUsdtMainnetFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            product: "usdt",
            network: "mainnet"
        });
    }
}

contract ReferralRegistryUpgradeUsdtBaseFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "base",
            product: "usdt",
            network: "base"
        });
    }
}

contract ReferralRegistryUpgradeUsdtArbitrumFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            product: "usdt",
            network: "arbitrum"
        });
    }
}

contract ReferralRegistryUpgradeUsdgMainnetFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            product: "usdg",
            network: "mainnet"
        });
    }
}

contract ReferralRegistryUpgradeUsdgArbitrumFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            product: "usdg",
            network: "arbitrum"
        });
    }
}

contract ReferralRegistryUpgradeUsdgRobinhoodFork is ReferralRegistryUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "robinhood",
            product: "usdg",
            network: "robinhood"
        });
    }
}

contract ReferralRegistryCrossVaultMainnetFork is ReferralRegistryCrossVaultForkBase {

    function _pairConfig()
        internal
        pure
        override
        returns (PairCfg memory)
    {
        return PairCfg({
            rpc: "mainnet",
            configPathA: "config/vault.usdc.mainnet.json",
            configPathB: "config/vault.usdt.mainnet.json"
        });
    }
}

contract ReferralRegistryCrossVaultBaseFork is ReferralRegistryCrossVaultForkBase {

    function _pairConfig()
        internal
        pure
        override
        returns (PairCfg memory)
    {
        return PairCfg({
            rpc: "base",
            configPathA: "config/vault.usdc.base.json",
            configPathB: "config/vault.usdt.base.json"
        });
    }
}

contract ReferralRegistryCrossVaultArbitrumFork is ReferralRegistryCrossVaultForkBase {

    function _pairConfig()
        internal
        pure
        override
        returns (PairCfg memory)
    {
        return PairCfg({
            rpc: "arbitrum",
            configPathA: "config/vault.usdc.arbitrum.json",
            configPathB: "config/vault.usdg.arbitrum.json"
        });
    }
}

/**
 * @dev Robinhood is the single-diamond chain: same-chain moves cannot
 * exist there, and the move-carry rollout's pre-broadcast check
 * ("no live peer links anywhere") is pinned here against the real
 * bytecode: the sibling products' CREATE3 addresses (identical per
 * product across chains) must not be registered peers, and
 * `moveBetweenVaults` must revert {PeerVaultNotEnabled} through the
 * live genesis dispatcher.
 */
contract ReferralRegistryRobinhoodNoPeerFork is Test {

    IWtnCohortVault internal vault;

    address internal usdcAddress;

    address internal usdtAddress;

    function setUp()
        public
    {
        string memory json = vm.readFile(
            "config/vault.usdg.robinhood.json"
        );

        address diamond = vm.parseJsonAddress(
            json,
            ".diamond"
        );

        usdcAddress = vm.parseJsonAddress(
            vm.readFile(
                "config/vault.usdc.mainnet.json"
            ),
            ".diamond"
        );

        usdtAddress = vm.parseJsonAddress(
            vm.readFile(
                "config/vault.usdt.mainnet.json"
            ),
            ".diamond"
        );

        vm.createSelectFork(
            "robinhood"
        );

        require(
            diamond.code.length > 0,
            "usdg diamond not deployed on this fork"
        );

        vault = IWtnCohortVault(
            diamond
        );
    }

    function test_robinhood_singleDiamond_noPeerLinksAndMoveReverts()
        public
    {
        assertEq(
            vault.peerVault(
                usdcAddress
            ),
            false,
            "unexpected live peer link to usdc address"
        );

        assertEq(
            vault.peerVault(
                usdtAddress
            ),
            false,
            "unexpected live peer link to usdt address"
        );

        address mover = makeAddr(
            "robinhoodMover"
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.PeerVaultNotEnabled.selector
        );

        vm.prank(
            mover
        );

        vault.moveBetweenVaults(
            usdcAddress,
            1
        );
    }
}
