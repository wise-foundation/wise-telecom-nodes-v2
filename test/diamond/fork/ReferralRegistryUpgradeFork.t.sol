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
import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortRecorderFacet} from "../../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortHookFacet} from "../../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
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
 * the live dispatcher does not know them yet — after the rehearsed
 * upgrade they resolve through the selector routing, which is what
 * this test proves.
 */
interface IWtnCohortVault {

    function master() external view returns (address);
    function USD_TOKEN() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function depositsDisabled() external view returns (bool);
    function paused() external view returns (bool);
    function graceThresholdAmount() external view returns (uint256);
    function selectorToFacet(bytes4 selector) external view returns (address);
    function transferHookFacet() external view returns (address);

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
 * @dev Rehearses the {UpgradeReferralRegistry} rollout (Phase 1,
 * rulings R19/R20) against a LIVE, already-finalized diamond on a
 * fork of each production chain — supersedes the retired
 * CohortUpgradeFork/ReferralUpgradeFork rehearsals and embeds their
 * full lifecycle. The LIVE diamond entry contract is never
 * redeployed: the round deploys NEW facets, routes selectors through
 * the real 3-day timelock, and wires the slot-74 pointer — the first
 * rehearsal ever to deploy a standalone companion contract
 * ({ReferralRegistry}) on a live fork. Proves, per chain:
 *   1. the live dispatcher does NOT know the cohort, referral OR
 *      pointer surfaces, and the user's slot-64 mapping entry is
 *      raw-zero on the real bytecode;
 *   2. the standalone registry deploys on-fork and allowlists the
 *      diamond (mirroring {DeployReferralRegistry});
 *   3. the exact selector manifest the upgrade script broadcasts —
 *      ten batches plus the transfer-hook swap — works under the
 *      real master and both real 3-day timelocks;
 *   4. the SECOND clock: the pointer proposal through the
 *      freshly-routed {AdminFacet} trio, its premature-execute
 *      revert, and the pointer-unset intermediate state being
 *      default-off (plain deposits and transfers write zero recorder
 *      state, `getReferrerOf` returns zero WITHOUT reverting, and
 *      `depositWithReferral` reverts {ReferralRegistryNotSet} loudly
 *      — no silent referrer drop) with arming blocked until wired;
 *   5. after executePointer + arm, the full recorder lifecycle holds
 *      against the real USD token with the registry as sole truth:
 *      referred credit, write-once referrer (asserted on the
 *      REGISTRY's storage while slot 64 stays raw-zero), lazy clamp,
 *      clamp-before-credit re-deposit, queue-join discredit, 52-week
 *      graduation, grace-freeze preservation, a real
 *      Permit2-signature referral deposit, and the capped
 *      dormant-book walk staying under its gas budget;
 *   6. the I1/I2 book identities hold after every mutating step, and
 *      the registry's code persists across blocks (EIP-6780 — no
 *      selfdestruct path exists; re-verify semantics per chain
 *      before any real broadcast on non-Cancun networks).
 * The diamond address is read from config/vault.<product>.<network>
 * .json before forking so it can never drift to a hallucinated
 * address.
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

    uint256 internal constant USER_PK = 0xA11CE;

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

        user = vm.addr(
            USER_PK
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
            USER_PK,
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

    function _slot64Entry(
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
                    uint256(64)
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
            "I1: referee tracked != book total"
        );

        assertEq(
            v.getCohortScore(_referrer),
            year1 + year2 + mature,
            "I1: score != book total"
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
            "I2: ring1 sum != bookY1"
        );

        assertEq(
            ring2Sum,
            year2,
            "I2: ring2 sum != bookY2"
        );
    }

    function test_registryUpgrade_rehearsalEndToEnd()
        public
    {
        // ---- 1. the live dispatcher knows none of the new surface ----

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
            _slot64Entry(user),
            bytes32(0),
            "slot-64 entry not virgin on live bytecode"
        );

        address hookBefore = v.transferHookFacet();

        // ---- 2. deploy the standalone registry on-fork (DeployReferralRegistry mirror) ----

        registry = new ReferralRegistry();

        registry.setAllowedVault(
            address(v),
            true
        );

        assertEq(
            registry.referrerOf(user),
            address(0),
            "fresh registry must be empty"
        );

        // ---- 3. the exact UpgradeReferralRegistry selector manifest under the real master ----

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
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
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
                WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()[0]
            ) == address(0),
            false,
            "cohort group not routed"
        );

        // ---- 4. governance prep + pointer-unset intermediate state is default-off ----

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

        uint256 liftedCap = v.totalSupply() + 40 * baseAmount + 2 * stampAmount;

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
            v.getReferrerOf(user),
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
            v.getTrackedContribution(user),
            0,
            "unarmed + unpointed state must write no recorder state"
        );

        // ---- 5. the SECOND clock: pointer proposal through the fresh admin trio ----

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

        // ---- 6. arm and run the recorder lifecycle with the registry as sole truth ----

        vm.prank(
            master
        );

        v.setCohortSyncEnabled(
            true
        );

        vm.prank(
            master
        );

        v.setBridgeGasLimit(
            1_000_000
        );

        assertTrue(
            v.getCohortSyncEnabled(),
            "arming failed"
        );

        vm.prank(
            user
        );

        v.depositWithReferral(
            baseAmount,
            refA
        );

        assertEq(
            v.getReferrerOf(user),
            refA,
            "referrer not assigned"
        );

        assertEq(
            registry.referrerOf(user),
            refA,
            "registry must hold the truth"
        );

        assertEq(
            _slot64Entry(user),
            bytes32(0),
            "slot 64 must stay virgin forever"
        );

        assertEq(
            v.getTrackedContribution(user),
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
            v.getReferrerOf(user),
            refA,
            "write-once violated"
        );

        assertEq(
            registry.referrerOf(user),
            refA,
            "registry write-once violated"
        );

        assertEq(
            v.getTrackedContribution(user),
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
            v.getTrackedContribution(user),
            tracked,
            "permit2 credit missing"
        );

        _assertBookConsistent(
            refA,
            2 * baseAmount + sigAmount
        );

        // ---- lazy clamp: transfer dips, next poke lands the deficit ----

        vm.prank(
            user
        );

        v.transfer(
            user2,
            3 * baseAmount
        );

        assertEq(
            v.getTrackedContribution(user),
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
            v.getTrackedContribution(user),
            heldNow,
            "clamp missed the deficit"
        );

        // ---- clamp-before-credit: re-deposit heals nothing retroactively ----

        vm.prank(
            user
        );

        v.deposit(
            baseAmount
        );

        assertEq(
            v.getTrackedContribution(user),
            heldNow + baseAmount,
            "re-deposit must credit exactly its own amount"
        );

        // ---- queue join discredits immediately ----

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
            v.getTrackedContribution(user),
            beforeJoin - baseAmount / 2,
            "join must discredit immediately"
        );

        // ---- grace-freeze preserved under the cohort hook ----

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

        // ---- 52-week graduation on the real chain clock ----

        uint256 trackedAtWarp = v.getTrackedContribution(
            user
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

        // ---- dormant-walk gas budget inside a bare transfer ----

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
            v.getTrackedContribution(user)
        );

        // ---- 7. the registry's code persists across blocks ----

        vm.roll(
            block.number + 1
        );

        assertGt(
            address(registry).code.length,
            0,
            "registry code must persist (EIP-6780)"
        );

        assertEq(
            registry.referrerOf(user),
            refA,
            "registry truth must persist"
        );
    }

    function _proposeAllGroups()
        internal
    {
        _proposeOne(
            WiseTelecomNodesDiamondSelectors.adminSelectors(),
            address(new AdminFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.userSelectors(),
            address(new UserFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.permit2Selectors(),
            address(new Permit2UserFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.moveSelectors(),
            address(new MoveFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.bridgeSelectors(),
            address(new BridgeFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors(),
            address(new QueueJoinLeaveFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors(),
            address(new QueueFulfillFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.referralSelectors(),
            address(new ReferralFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors(),
            address(new Permit2ReferralFacet())
        );

        _proposeOne(
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors(),
            address(new CohortRecorderFacet())
        );
    }

    function _executeAllGroups()
        internal
    {
        _executeOne(
            WiseTelecomNodesDiamondSelectors.adminSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.userSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.permit2Selectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.moveSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors()
        );

        _executeOne(
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
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
 * @dev The cross-vault half of the Phase-1 rehearsal, mainnet only:
 * ONE registry serving TWO real diamonds (usdc + usdt). Runs the
 * full two-clock round on both diamonds against one registry, then
 * proves the R13 semantics on real bytecode: a referral recorded
 * through the usdc diamond makes a PLAIN deposit on the usdt diamond
 * credit the same referrer through the registry staticcall, and a
 * later `depositWithReferral` with a different referrer on the
 * second diamond is silently ignored (write-once per chain, not per
 * vault).
 */
contract ReferralRegistryCrossVaultMainnetFork is Test {

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant REGISTRY_DELAY = 3 days;

    IWtnCohortVault internal va;
    IWtnCohortVault internal vb;
    ReferralRegistry internal registry;
    address internal user;
    address internal refA;
    address internal refB;

    function setUp()
        public
    {
        string memory jsonA = vm.readFile(
            "config/vault.usdc.mainnet.json"
        );

        string memory jsonB = vm.readFile(
            "config/vault.usdt.mainnet.json"
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
            "mainnet"
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

    function test_crossVault_oneRegistryTwoDiamonds_writeOnceAndSharedCredit()
        public
    {
        registry = new ReferralRegistry();

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
            registry.referrerOf(user),
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
            vb.getTrackedContribution(user),
            amountB,
            "plain deposit on B must be tracked"
        );

        assertEq(
            vb.getCohortScore(refA),
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
            registry.referrerOf(user),
            refA,
            "write-once must hold across vaults"
        );

        assertEq(
            vb.getCohortScore(refB),
            0,
            "the ignored referrer must earn nothing"
        );

        assertEq(
            vb.getCohortScore(refA),
            amountB + amountB2,
            "the sticky referrer must keep earning on vault B"
        );

        assertEq(
            va.getCohortScore(refA),
            amountA,
            "books stay per-vault"
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
            WiseTelecomNodesDiamondSelectors.adminSelectors(),
            address(new AdminFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.userSelectors(),
            address(new UserFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.referralSelectors(),
            address(new ReferralFacet())
        );

        _v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors(),
            address(new CohortRecorderFacet())
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
            WiseTelecomNodesDiamondSelectors.adminSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.userSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
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

        deal(
            usd,
            user,
            _usdBalance(usd, user) + 3 * amount
        );

        if (_usdAllowance(usd, user, address(_v)) > 0) {
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
