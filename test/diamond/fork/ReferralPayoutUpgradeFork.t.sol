// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {SweepFacet} from "../../../src/diamond/vault/facets/SweepFacet.sol";
import {ReferralPayoutFacet} from "../../../src/diamond/vault/facets/pending/ReferralPayoutFacet.sol";
import {ReferralHub} from "../../../src/hub/pending/ReferralHub.sol";

import {FacetNotFound} from "../../../src/diamond/shared/DiamondErrors.sol";
import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

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
 * @dev Rehearses the {UpgradeReferralPayout} rollout against a LIVE,
 * already-finalized diamond on a fork of a production chain. The
 * LIVE diamond entry contract is never redeployed: the round deploys
 * NEW facets (AdminFacet with the payout-hub pointer six, SweepFacet
 * with the liability buffer term, ReferralPayoutFacet with the
 * hub-gated writers), routes the three selector batches through the
 * real 3-day timelock, and — on the payout vault only — wires the
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
 *   4. payout vault only — the second clock: the pointer proposal
 *      through the freshly-routed trio, its premature-execute
 *      revert, execute with the real USD-token shape probe, then the
 *      full rail end-to-end: a standalone {ReferralHub} deployed
 *      on-fork against the vault's REAL underlying, score report and
 *      crumb pricing, liability booked into slot 76, and a claim
 *      that pulls real USD out of the live vault's pool and pays the
 *      referrer, leaving liability, claimable and balances exactly
 *      conserved.
 * The diamond address is read from config/vault.<product>.<network>
 * .json before forking so it can never drift to a wrong or stale
 * address.
 */
abstract contract ReferralPayoutUpgradeForkBase is Test {

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant PAYOUT_HUB_DELAY = 3 days;

    struct Cfg {
        string rpc;
        string product;
        string network;
        bool payoutVault;
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
            WiseTelecomNodesDiamondSelectors.adminSelectors(),
            adminFacet
        );

        v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.sweepSelectors(),
            sweepFacet
        );

        v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.referralPayoutSelectors(),
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
            WiseTelecomNodesDiamondSelectors.adminSelectors()
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.sweepSelectors()
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.referralPayoutSelectors()
        );

        vm.stopPrank();
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
            _rawSlot(76),
            bytes32(0),
            "slot 76 not virgin on the live diamond"
        );

        assertEq(
            _rawSlot(80),
            bytes32(0),
            "slot 80 not virgin on the live diamond"
        );

        assertEq(
            _rawSlot(81),
            bytes32(0),
            "slot 81 not virgin on the live diamond"
        );

        assertEq(
            _rawSlot(82),
            bytes32(0),
            "slot 82 not virgin on the live diamond"
        );

        uint256 overhangBefore = v.getOverhang();

        _executeSelectorRound();

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

    function test_payoutUpgrade_pointerAndClaimEndToEnd()
        public
    {
        Cfg memory cfg = _config();

        if (cfg.payoutVault == false) {
            vm.skip(true);
            return;
        }

        _executeSelectorRound();

        ReferralHub hub = new ReferralHub(
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

        vm.warp(
            block.timestamp + PAYOUT_HUB_DELAY + 1
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

        hub.setPayoutVault(
            address(v)
        );

        hub.setAllowedReporter(
            address(this),
            true
        );

        hub.reportScores(
            refA,
            6_000 * one,
            0
        );

        uint256 reportWeek = block.timestamp / CohortWeeks.WEEK;

        vm.warp(
            (reportWeek + 3) * CohortWeeks.WEEK + 1 hours
        );

        uint256[] memory weeksArr = new uint256[](1);
        weeksArr[0] = reportWeek + 2;

        uint256[] memory words = new uint256[](1);
        words[0] = CohortWeeks.packLanes(
            100 * CohortWeeks.YEAR * one,
            0,
            0
        );

        uint256 vaultUsdBefore = IUsdErc20(usd).balanceOf(
            address(v)
        );

        hub.deliverCrumbs(
            refA,
            weeksArr,
            words
        );

        assertEq(
            hub.claimable(block.chainid, refA),
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
            IUsdErc20(usd).balanceOf(refA),
            one,
            "claim must pay the referrer in the vault's real underlying"
        );

        assertEq(
            IUsdErc20(usd).balanceOf(address(v)),
            vaultUsdBefore - one,
            "funding must come out of the live vault's USD pool"
        );

        assertEq(
            v.getPendingReferralPayout(),
            0,
            "funding must lower the booked liability to zero"
        );

        assertEq(
            hub.claimable(block.chainid, refA),
            0,
            "claim must zero the claimable balance"
        );

        assertEq(
            hub.totalClaimed(),
            one,
            "totalClaimed must equal the paid amount"
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
            payoutVault: true
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
            payoutVault: false
        });
    }
}
