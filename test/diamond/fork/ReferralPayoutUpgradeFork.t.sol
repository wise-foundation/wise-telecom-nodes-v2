// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {SweepFacet} from "../../../src/diamond/vault/facets/SweepFacet.sol";
import {ReferralPayoutFacet} from "../../../src/diamond/vault/facets/pending/ReferralPayoutFacet.sol";
import {IReferralHub} from "../../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "../../hub/utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../../hub/utils/HubDiamondHarness.sol";
import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../../src/registry/pending/ReferralRegistryDeclarations.sol";

import {FacetNotFound} from "../../../src/diamond/shared/DiamondErrors.sol";
import {NotMaster} from "../../../src/diamond/shared/OwnableMaster.sol";
import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";
import {DeployReferralRegistry} from "../../../script/registry/DeployReferralRegistry.s.sol";

interface IWtnPayoutVault {

    function master()
        external
        view
        returns (address);

    function USD_TOKEN()
        external
        view
        returns (address);

    function selectorToFacet(
        bytes4 selector
    )
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

    function proposePayoutHub(
        address hub
    )
        external;

    function executePayoutHubChange()
        external;

    function cancelPayoutHubChange()
        external;

    function getPayoutHub()
        external
        view
        returns (address);

    function getProposedPayoutHub()
        external
        view
        returns (address);

    function getPayoutHubChangeQueuedAt()
        external
        view
        returns (uint256);

    function getPendingReferralPayout()
        external
        view
        returns (uint256);

    function raisePendingReferralPayout(
        uint256 amount
    )
        external;

    function fundReferralPayout(
        uint256 amount
    )
        external;

    function getOverhang()
        external
        view
        returns (uint256);
}

interface IUsdErc20 {

    function decimals()
        external
        view
        returns (uint8);

    function balanceOf(
        address account
    )
        external
        view
        returns (uint256);
}

/**
 * @dev Exposes the decision logic of {DeployReferralRegistry}'s
 * `wirePayoutRoute()` with its inputs passed in, so the fork case
 * drives the very code the script broadcasts without a PRIVATE_KEY
 * variable or a config file. The script's broadcast runs inside the
 * harness, so every registry call it makes comes from the test key.
 */
contract PayoutForkRouteScriptHarness is DeployReferralRegistry, HubDiamondHarness {

    function wirePayoutRouteOn(
        ReferralRegistry _registry,
        address _hub,
        uint64 _chainSelector,
        uint256 _privKey
    )
        external
    {
        _wirePayoutRoute(
            _registry,
            _hub,
            _chainSelector,
            _privKey
        );
    }
}

/**
 * @dev Rehearses the {UpgradeReferralPayout} rollout against a LIVE,
 * already-finalized diamond on a fork of a production chain. The
 * LIVE diamond entry contract is never redeployed: the round deploys
 * NEW facets (AdminFacet with the payout-hub pointer six, SweepFacet
 * with the liability buffer term, ReferralPayoutFacet with the
 * hub-gated writers), routes the three selector batches through the
 * real 3-day timelock, and (on the payout vault only) wires the
 * slot-80 pointer through the second real 3-day clock. Proves, per
 * chain:
 *   1. the live dispatcher does NOT know the payout surfaces and
 *      slots 76 and 80-82 are raw-zero on the real bytecode;
 *   2. the exact selector manifest the upgrade script broadcasts
 *      works under the real master and the real timelock;
 *   3. the intermediate states are default-off: after the selector
 *      round both writers revert {NotPayoutHub} while the pointer is
 *      unset, and the redeployed SweepFacet's overhang equals the
 *      pre-upgrade reading exactly (the buffer term is `+ 0`);
 *   4. payout vault only, the second clock: the pointer proposal
 *      through the freshly-routed trio, its premature-execute
 *      revert, execute with the real USD-token shape probe, then the
 *      full rail end-to-end: a standalone {ReferralHub} deployed
 *      on-fork against the vault's REAL underlying, crumb pricing at
 *      the week's own tier, liability booked into slot 76, and a claim
 *      that pulls real USD out of the live vault's pool and pays the
 *      referrer, leaving liability, claimable and balances exactly
 *      conserved;
 *   5. the seed latch phase of {DeployReferralRegistry}, the one
 *      script phase with no rehearsal elsewhere: the real registry
 *      bytecode is deployed on-fork under the live master and
 *      latched exactly as the script does (`latchSeeds`), proving
 *      the latch sets `seedsLatched` and emits {SeedsLatched}, that
 *      the registry refuses a second seed latch (the reason the
 *      script phase returns early once latched), and that the
 *      correction lane stays open afterwards: under the live master
 *      a vault is allowlisted, a referrer is assigned through it, a
 *      correction is proposed (and then cancelled so no proposal is
 *      left standing) and `correctionsLatched` is still false. On
 *      the payout vault the seed latch runs inside the pointer
 *      clock, before the hub pointer executes, in the order the
 *      rollout requires: every registry fires its seed latch before
 *      payouts arm at the hub;
 *   6. the payout selector preflight of {DeployReferralHub}'s `wire()`:
 *      all three payout selectors route to no facet before the
 *      selector round and to a facet after it, which is exactly what
 *      the preflight reads through `selectorToFacet` before it lets
 *      `setPayoutVault` run, checked on both lanes and again on the
 *      payout vault right before the hub wires it;
 *   7. spoke lanes only, the decision logic of {DeployReferralRegistry}'s
 *      `wirePayoutRoute()`, driven through a harness that inherits the
 *      script with the registry, the hub, the chain selector and a
 *      test key passed in, so the case sets no PRIVATE_KEY and writes
 *      no config file (a written config/registry.<network>.json or
 *      config/hub.mainnet.json would outlive a failed run as a
 *      phantom record that later scripts read as real): a mismatched
 *      pending proposal seeded before finalize is overwritten and the
 *      config hub wired at once; a mismatched proposal seeded after
 *      finalize and left to mature is overwritten, never executed,
 *      and the fresh proposal waits its own 3 days (a re-run inside
 *      that window neither executes nor proposes again); once wired,
 *      a stray proposal is cancelled, and a re-run with nothing
 *      queued returns without a cancel;
 *   8. the registry master handoff: the deploy key, which is the live
 *      master, fires the seed latch (the last scripted registry master
 *      operation) and proposes a Safe stand-in, the Safe claims, the
 *      deploy key is refused afterwards and the Safe operates the
 *      registry.
 * The diamond address is read from config/vault.<product>.<network>
 * .json before forking so it can never drift to a wrong or stale
 * address.
 */
abstract contract ReferralPayoutUpgradeForkBase is Test, HubDiamondHarness {

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant PAYOUT_HUB_DELAY = 3 days;

    event SeedsLatched();

    event ReferralCorrectionProposed(
        address indexed user,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 queuedAt
    );

    struct Cfg {
        string rpc;
        string product;
        string network;
        bool payoutVault;
        uint256 chainRank;
    }

    IWtnPayoutVault internal v;
    address internal usd;
    address internal master;
    uint256 internal one;
    address internal refA;

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

        v = IWtnPayoutVault(
            diamond
        );

        usd = v.USD_TOKEN();

        master = v.master();

        one = 10 ** IUsdErc20(usd).decimals();

        refA = makeAddr(
            "payoutForkRefA"
        );
    }

    // ---- helpers ----

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

    function _rawSlot(
        uint256 _slot
    )
        internal
        view
        returns (bytes32)
    {
        return vm.load(
            address(v),
            bytes32(
                _slot
            )
        );
    }

    function _assertPayoutSelectorsRouted(
        bool _routed
    )
        internal
        view
    {
        bytes4[] memory sels = WiseTelecomNodesDiamondSelectors._referralPayoutSelectors();

        for (uint256 i; i < sels.length; ++i) {

            assertEq(
                v.selectorToFacet(sels[i]) != address(0),
                _routed,
                "payout selector routing differs from what the hub wire() preflight expects"
            );
        }
    }

    function _executeSelectorRound()
        internal
    {
        address adminFacet = address(new AdminFacet());
        address sweepFacet = address(new SweepFacet());
        address referralPayoutFacet = address(new ReferralPayoutFacet());

        vm.startPrank(
            master
        );

        v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._adminSelectors(),
            adminFacet
        );

        v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._sweepSelectors(),
            sweepFacet
        );

        v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors._referralPayoutSelectors(),
            referralPayoutFacet
        );

        vm.stopPrank();

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        vm.startPrank(
            master
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._adminSelectors()
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._sweepSelectors()
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._referralPayoutSelectors()
        );

        vm.stopPrank();
    }

    function _deployRegistry()
        internal
        returns (ReferralRegistry registry)
    {
        Cfg memory cfg = _config();

        registry = new ReferralRegistry(
            master,
            cfg.chainRank
        );

        assertEq(
            registry.master(),
            master,
            "registry master must be the live vault master"
        );
    }

    function _latchRegistry(
        ReferralRegistry _registry
    )
        internal
    {
        assertGt(
            address(_registry).code.length,
            0,
            "registry has no code on the fork"
        );

        assertFalse(
            _registry.seedsLatched(),
            "seeds must start unlatched"
        );

        assertFalse(
            _registry.correctionsLatched(),
            "corrections must start unlatched"
        );

        vm.expectEmit(
            false,
            false,
            false,
            true,
            address(_registry)
        );

        emit SeedsLatched();

        vm.prank(
            master
        );

        _registry.latchSeeds();

        assertTrue(
            _registry.seedsLatched(),
            "latch must set seedsLatched"
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SeedsAlreadyLatched.selector
        );

        _registry.latchSeeds();

        vm.prank(
            master
        );

        _registry.setAllowedVault(
            address(v),
            true
        );

        vm.prank(
            address(v)
        );

        _registry.assignReferrer(
            refA,
            address(0xB2)
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(_registry)
        );

        emit ReferralCorrectionProposed(
            refA,
            address(0xB2),
            address(0xB3),
            block.timestamp
        );

        vm.prank(
            master
        );

        _registry.proposeCorrectReferrer(
            refA,
            address(0xB3)
        );

        vm.prank(
            master
        );

        _registry.cancelCorrectReferrer(
            refA
        );

        assertFalse(
            _registry.correctionsLatched(),
            "the seed latch must leave the correction lane open"
        );

        assertTrue(
            _registry.seedsLatched(),
            "a refused second latch must leave the seed latch set"
        );
    }

    // ---- rehearsal ----

    function test_payoutUpgrade_selectorRound_defaultOffEverywhere()
        public
    {
        _assertSelectorUnknown(
            abi.encodeWithSelector(
                IWtnPayoutVault.getPendingReferralPayout.selector
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSelector(
                IWtnPayoutVault.getPayoutHub.selector
            )
        );

        assertEq(
            _rawSlot(
                76
            ),
            bytes32(0),
            "slot 76 not virgin on the live diamond"
        );

        assertEq(
            _rawSlot(
                80
            ),
            bytes32(0),
            "slot 80 not virgin on the live diamond"
        );

        assertEq(
            _rawSlot(
                81
            ),
            bytes32(0),
            "slot 81 not virgin on the live diamond"
        );

        assertEq(
            _rawSlot(
                82
            ),
            bytes32(0),
            "slot 82 not virgin on the live diamond"
        );

        _assertPayoutSelectorsRouted(
            false
        );

        uint256 overhangBefore = v.getOverhang();

        _executeSelectorRound();

        _assertPayoutSelectorsRouted(
            true
        );

        assertEq(
            v.getPendingReferralPayout(),
            0,
            "pending payout must read zero on virgin storage"
        );

        assertEq(
            v.getPayoutHub(),
            address(0),
            "hub pointer must read zero on virgin storage"
        );

        assertEq(
            v.getOverhang(),
            overhangBefore,
            "overhang must be unchanged while the liability term is zero"
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotPayoutHub.selector
        );

        v.raisePendingReferralPayout(
            one
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotPayoutHub.selector
        );

        v.fundReferralPayout(
            one
        );
    }

    function test_payoutUpgrade_latchPhase_registrySeedLatchUnderMaster()
        public
    {
        _latchRegistry(
            _deployRegistry()
        );
    }

    function test_payoutUpgrade_pointerAndClaimEndToEnd()
        public
    {
        Cfg memory cfg = _config();

        if (cfg.payoutVault == false) {

            vm.skip(
                true
            );

            return;
        }

        _executeSelectorRound();

        IReferralHub hub = _deployHub(
            usd
        );

        vm.prank(
            master
        );

        v.proposePayoutHub(
            address(hub)
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.PayoutHubTimelockNotElapsed.selector
        );

        v.executePayoutHubChange();

        ReferralRegistry registry = _deployRegistry();

        _latchRegistry(
            registry
        );

        vm.warp(
            block.timestamp + PAYOUT_HUB_DELAY + 1
        );

        assertTrue(
            registry.seedsLatched(),
            "the seed latch must be set before the hub pointer executes"
        );

        vm.prank(
            master
        );

        v.executePayoutHubChange();

        assertEq(
            v.getPayoutHub(),
            address(hub),
            "hub pointer not wired"
        );

        _assertPayoutSelectorsRouted(
            true
        );

        hub.setPayoutVault(
            address(v)
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
            100 * CohortWeeks.YEAR * one,
            0,
            0
        );

        vm.prank(
            refA
        );

        hub.setPayoutAddress(
            refA
        );

        uint256 vaultUsdBefore = IUsdErc20(usd).balanceOf(
            address(v)
        );

        hub.deliverCrumbs(
            refA,
            refA,
            weeksArr,
            words
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            one,
            "expected exactly one whole USD unit accrued"
        );

        assertEq(
            v.getPendingReferralPayout(),
            one,
            "delivery must book the accrued liability on the vault"
        );

        vm.prank(
            refA
        );

        hub.claim(
            block.chainid,
            refA
        );

        assertEq(
            IUsdErc20(usd).balanceOf(
                refA
            ),
            one,
            "claim must pay the referrer in the vault's real underlying"
        );

        assertEq(
            IUsdErc20(usd).balanceOf(
                address(v)
            ),
            vaultUsdBefore - one,
            "funding must come out of the live vault's USD pool"
        );

        assertEq(
            v.getPendingReferralPayout(),
            0,
            "funding must lower the booked liability to zero"
        );

        assertEq(
            hub.claimable(
                block.chainid,
                refA
            ),
            0,
            "claim must zero the claimable balance"
        );

        assertEq(
            hub.totalClaimed(),
            one,
            "totalClaimed must equal the paid amount"
        );
    }

    function test_payoutUpgrade_wirePayoutRoute_strayProposalNeverExecutes()
        public
    {
        Cfg memory cfg = _config();

        if (keccak256(bytes(cfg.network)) == keccak256(bytes("mainnet"))) {

            vm.skip(
                true
            );

            return;
        }

        (
            address operator,
            uint256 operatorKey
        ) = makeAddrAndKey(
            "payoutForkRouteOperator"
        );

        address hubA = makeAddr(
            "payoutForkRouteHubA"
        );

        address hubB = makeAddr(
            "payoutForkRouteHubB"
        );

        address strayHub = makeAddr(
            "payoutForkRouteStrayHub"
        );

        uint64 mainnetSelector = uint64(
            vm.parseUint(
                vm.parseJsonString(
                    vm.readFile(
                        "config/ccip.mainnet.json"
                    ),
                    ".chainSelector"
                )
            )
        );

        address router = vm.parseJsonAddress(
            vm.readFile(
                string.concat(
                    "config/ccip.",
                    cfg.network,
                    ".json"
                )
            ),
            ".router"
        );

        ReferralRegistry registry = new ReferralRegistry(
            operator,
            cfg.chainRank
        );

        PayoutForkRouteScriptHarness routeScript = new PayoutForkRouteScriptHarness();

        vm.prank(
            operator
        );

        registry.setCcipRouter(
            router
        );

        vm.prank(
            operator
        );

        registry.proposePayoutHub(
            strayHub,
            mainnetSelector
        );

        routeScript.wirePayoutRouteOn(
            registry,
            hubA,
            mainnetSelector,
            operatorKey
        );

        assertEq(
            registry.payoutHub(),
            hubA,
            "before finalize the config hub must be wired, never the stray proposal"
        );

        assertEq(
            uint256(registry.payoutHubChainSelector()),
            uint256(mainnetSelector),
            "before finalize the wired selector must be the config selector"
        );

        assertEq(
            registry.proposedPayoutHub(),
            address(0),
            "the execute must clear the proposal"
        );

        assertEq(
            registry.payoutHubChangeQueuedAt(),
            0,
            "the execute must clear the queue time"
        );

        vm.prank(
            operator
        );

        registry.finalizeSyncSetup();

        vm.prank(
            operator
        );

        registry.proposePayoutHub(
            hubB,
            mainnetSelector + 1
        );

        vm.warp(
            block.timestamp + PAYOUT_HUB_DELAY + 1
        );

        uint256 reproposedAt = block.timestamp;

        routeScript.wirePayoutRouteOn(
            registry,
            hubB,
            mainnetSelector,
            operatorKey
        );

        assertEq(
            registry.payoutHub(),
            hubA,
            "a matured mismatched proposal must never execute"
        );

        assertEq(
            registry.proposedPayoutHub(),
            hubB,
            "the mismatched proposal must be overwritten with the config hub"
        );

        assertEq(
            uint256(registry.proposedPayoutHubChainSelector()),
            uint256(mainnetSelector),
            "the overwrite must carry the config selector"
        );

        assertEq(
            registry.payoutHubChangeQueuedAt(),
            reproposedAt,
            "the overwrite must restart the 3-day window"
        );

        vm.warp(
            reproposedAt + 1 days
        );

        routeScript.wirePayoutRouteOn(
            registry,
            hubB,
            mainnetSelector,
            operatorKey
        );

        assertEq(
            registry.payoutHub(),
            hubA,
            "a re-run inside the window must not execute"
        );

        assertEq(
            registry.payoutHubChangeQueuedAt(),
            reproposedAt,
            "a matching pending proposal must not be proposed again"
        );

        vm.warp(
            reproposedAt + PAYOUT_HUB_DELAY
        );

        routeScript.wirePayoutRouteOn(
            registry,
            hubB,
            mainnetSelector,
            operatorKey
        );

        assertEq(
            registry.payoutHub(),
            hubB,
            "the matching proposal must execute once its window has elapsed"
        );

        assertEq(
            uint256(registry.payoutHubChainSelector()),
            uint256(mainnetSelector),
            "the executed route must carry the config selector"
        );

        assertEq(
            registry.payoutHubChangeQueuedAt(),
            0,
            "the execute must clear the queue time after finalize too"
        );

        vm.prank(
            operator
        );

        registry.proposePayoutHub(
            strayHub,
            mainnetSelector
        );

        routeScript.wirePayoutRouteOn(
            registry,
            hubB,
            mainnetSelector,
            operatorKey
        );

        assertEq(
            registry.payoutHub(),
            hubB,
            "an already wired route must stay wired"
        );

        assertEq(
            registry.proposedPayoutHub(),
            address(0),
            "an already wired route must cancel a mismatched pending proposal"
        );

        assertEq(
            registry.payoutHubChangeQueuedAt(),
            0,
            "the cancel must clear the queue time"
        );

        routeScript.wirePayoutRouteOn(
            registry,
            hubB,
            mainnetSelector,
            operatorKey
        );

        assertEq(
            registry.payoutHub(),
            hubB,
            "a re-run with nothing queued must return without a cancel"
        );
    }

    function test_payoutUpgrade_registryMasterHandoff_safeTakesOverAfterLatch()
        public
    {
        ReferralRegistry registry = _deployRegistry();

        address safe = makeAddr(
            "payoutForkRegistrySafe"
        );

        vm.prank(
            master
        );

        registry.latchSeeds();

        vm.prank(
            master
        );

        registry.proposeOwner(
            safe
        );

        assertEq(
            registry.master(),
            master,
            "the deploy key must stay master until the Safe claims"
        );

        assertEq(
            registry.proposedMaster(),
            safe,
            "the proposal must name the Safe"
        );

        vm.prank(
            safe
        );

        registry.claimOwnership();

        assertEq(
            registry.master(),
            safe,
            "the claim must make the Safe the registry master"
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.setAllowedVault(
            address(v),
            true
        );

        vm.prank(
            safe
        );

        registry.setAllowedVault(
            address(v),
            true
        );

        assertTrue(
            registry.allowedVault(
                address(v)
            ),
            "the Safe must operate the registry after the handoff"
        );
    }
}

contract ReferralPayoutUpgradeUsdcMainnetFork is ReferralPayoutUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            product: "usdc",
            network: "mainnet",
            payoutVault: true,
            chainRank: 0
        });
    }
}

contract ReferralPayoutUpgradeUsdtBaseFork is ReferralPayoutUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "base",
            product: "usdt",
            network: "base",
            payoutVault: false,
            chainRank: 1
        });
    }
}
