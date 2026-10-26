// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {IReferralHub} from "../../../src/hub/pending/IReferralHub.sol";
import {HubLeverGrants} from "../../hub/utils/HubLeverGrants.sol";
import {HubDiamondHarness} from "../../hub/utils/HubDiamondHarness.sol";
import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../../src/registry/pending/ReferralRegistryDeclarations.sol";

import {FacetNotFound} from "../../../src/diamond/shared/DiamondErrors.sol";
import {NotMaster} from "../../../src/diamond/shared/OwnableMaster.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

import {DeployReferralRegistry} from "../../../script/registry/DeployReferralRegistry.s.sol";

interface IWtnClaimVault {

    function master()
        external
        view
        returns (address);

    function USD_TOKEN()
        external
        view
        returns (address);

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
contract ClaimForkRouteScriptHarness is DeployReferralRegistry, HubDiamondHarness {

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
 * @dev Rehearses the hub claim rail and the registry phases against a
 * LIVE, already-finalized diamond on a fork of a production chain. The
 * hub is its own payout pot (the vault side of the payout rail was
 * removed before it shipped), so nothing is installed on the diamond
 * here. Proves, per chain:
 *   1. the retired rail is not routed and never was: the live
 *      dispatcher does not know `getPendingReferralPayout` or
 *      `getPayoutHub`, and slots 76 and 80 to 82 are raw-zero on the
 *      real bytecode;
 *   2. hub chain only, the claim rail end to end: a standalone
 *      {ReferralHub} deployed on-fork against the vault's REAL
 *      underlying and funded by a plain transfer, crumb pricing at the
 *      week's own tier, the owed amount `totalPayable - totalClaimed`,
 *      and a claim that pays the referrer real USD out of the hub's
 *      pot, leaving claimable, totals and balances exactly conserved;
 *   3. the seed latch phase of {DeployReferralRegistry}, the one
 *      script phase with no rehearsal elsewhere: the real registry
 *      bytecode is deployed on-fork under the live master and
 *      latched exactly as the script does (`latchSeeds`), proving
 *      the latch sets `seedsLatched` and emits {SeedsLatched}, that
 *      the registry refuses a second seed latch (the reason the
 *      script phase returns early once latched), and that the
 *      correction lane stays open afterwards: under the live master
 *      a vault is allowlisted, a referrer is assigned through it, a
 *      correction is proposed (and then cancelled so no proposal is
 *      left standing) and `correctionsLatched` is still false;
 *   4. spoke lanes only, the decision logic of {DeployReferralRegistry}'s
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
 *   5. the registry master handoff: the deploy key, which is the live
 *      master, fires the seed latch (the last scripted registry master
 *      operation) and proposes a Safe stand-in, the Safe claims, the
 *      deploy key is refused afterwards and the Safe operates the
 *      registry.
 * The diamond address is read from config/vault.<product>.<network>
 * .json before forking so it can never drift to a wrong or stale
 * address.
 */
abstract contract ReferralHubClaimForkBase is Test, HubDiamondHarness {

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
        bool hubChain;
        uint256 chainRank;
    }

    IWtnClaimVault internal v;
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

        v = IWtnClaimVault(
            diamond
        );

        usd = v.USD_TOKEN();

        master = v.master();

        one = 10 ** IUsdErc20(usd).decimals();

        refA = makeAddr(
            "claimForkRefA"
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

    function test_claimFork_retiredRailNeverRouted()
        public
    {
        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "getPendingReferralPayout()"
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "getPayoutHub()"
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
    }

    function test_claimFork_latchPhase_registrySeedLatchUnderMaster()
        public
    {
        _latchRegistry(
            _deployRegistry()
        );
    }

    function test_claimFork_potClaimEndToEnd()
        public
    {
        Cfg memory cfg = _config();

        if (cfg.hubChain == false) {

            vm.skip(
                true
            );

            return;
        }

        IReferralHub hub = _deployHub(
            usd
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

        deal(
            usd,
            address(hub),
            10 * one
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
            hub.totalPayable() - hub.totalClaimed(),
            one,
            "the pot must owe exactly the accrued unit"
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
                address(hub)
            ),
            9 * one,
            "the claim must come out of the hub's pot"
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

    function test_claimFork_wirePayoutRoute_strayProposalNeverExecutes()
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
            "claimForkRouteOperator"
        );

        address hubA = makeAddr(
            "claimForkRouteHubA"
        );

        address hubB = makeAddr(
            "claimForkRouteHubB"
        );

        address strayHub = makeAddr(
            "claimForkRouteStrayHub"
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

        ClaimForkRouteScriptHarness routeScript = new ClaimForkRouteScriptHarness();

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

    function test_claimFork_registryMasterHandoff_safeTakesOverAfterLatch()
        public
    {
        ReferralRegistry registry = _deployRegistry();

        address safe = makeAddr(
            "claimForkRegistrySafe"
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

contract ReferralHubClaimUsdcMainnetFork is ReferralHubClaimForkBase {

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
            hubChain: true,
            chainRank: 0
        });
    }
}

contract ReferralHubClaimUsdtBaseFork is ReferralHubClaimForkBase {

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
            hubChain: false,
            chainRank: 1
        });
    }
}
