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
 * driven through its own dispatcher and fallback router. The cohort
 * and referral entrypoints are declared even though the live
 * dispatcher does not know them yet — after the rehearsed upgrade
 * they resolve through the selector routing, which is what this test
 * proves.
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

    function referrerOf(
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
 * @title CohortUpgradeForkBase
 * @dev Rehearses the {UpgradeCohortRecorder} rollout against a LIVE,
 * already-finalized diamond on a fork of each production chain — the
 * required basis before the cohort recorder ships (fork first, then
 * simulate with cheatcodes on the real deployed bytecode). Proves,
 * per chain:
 *   1. the live dispatcher does NOT know the cohort surface and the
 *      currently installed transfer hook is not the cohort hook;
 *   2. the exact one-round manifest the upgrade script broadcasts —
 *      ten selector batches plus the transfer-hook swap — works under
 *      the real master and both real 3-day timelocks;
 *   3. state S3 (executed, unarmed) is behaviorally identical to
 *      today: deposits and transfers write zero recorder state;
 *   4. after arming, the full recorder lifecycle holds against the
 *      real USD token: referred credit, write-once referrer, lazy
 *      clamp with newest-first reduction, clamp-before-credit
 *      re-deposit, queue-join immediate discredit, 52-week cohort
 *      graduation, grace-freeze preservation under the new hook, a
 *      real Permit2-signature referral deposit, and the capped
 *      dormant-book walk inside a transfer staying under its gas
 *      budget;
 *   5. the I1/I2 book identities (referee contributions == bookY1 +
 *      bookY2 + bookM == score, ring sums == book lanes) hold after
 *      every mutating step.
 * `moveBetweenVaults` reduction is deliberately left to the offline
 * unit suite: it needs a registered mock peer through the peer-vault
 * timelock, which adds nothing over the queue and transfer reduction
 * paths already rehearsed here.
 * The diamond address is read from config/vault.<product>.<network>
 * .json before forking so it can never drift to a hallucinated
 * address.
 */
abstract contract CohortUpgradeForkBase is Test {

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256(
        "TokenPermissions(address token,uint256 amount)"
    );

    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant USER_PK = 0xA11CE;

    uint256 internal constant DORMANT_WALK_GAS_BUDGET = 3_500_000;

    struct Cfg {
        string rpc;
        string product;
        string network;
    }

    IWtnCohortVault internal v;
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
            "cohortForkUser2"
        );

        refA = makeAddr(
            "cohortForkRefA"
        );

        refB = makeAddr(
            "cohortForkRefB"
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

    function test_cohortUpgrade_rehearsalEndToEnd()
        public
    {
        // ---- 1. the live dispatcher does not know the cohort surface ----

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

        address hookBefore = v.transferHookFacet();

        // ---- 2. the exact UpgradeCohortRecorder manifest under the real master ----

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

        // ---- 3. governance prep + S3 neutrality (executed, unarmed) ----

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

        assertFalse(
            v.getCohortSyncEnabled(),
            "must not be armed yet"
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
            "S3 must write no recorder state"
        );

        // ---- 4. arm and run the recorder lifecycle ----

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
            v.referrerOf(user),
            refA,
            "referrer not assigned"
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
            v.referrerOf(user),
            refA,
            "write-once violated"
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
            tracked
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

        _assertBookConsistent(
            refA,
            heldNow
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

        _assertBookConsistent(
            refA,
            heldNow + baseAmount
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

        _assertBookConsistent(
            refA,
            beforeJoin - baseAmount / 2
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

        assertEq(
            year2After,
            trackedAtWarp,
            "cohort did not graduate to year 2"
        );

        _assertBookConsistent(
            refA,
            trackedAtWarp
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

contract CohortUpgradeUsdcMainnetFork is CohortUpgradeForkBase {

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

contract CohortUpgradeUsdcBaseFork is CohortUpgradeForkBase {

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

contract CohortUpgradeUsdcArbitrumFork is CohortUpgradeForkBase {

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

contract CohortUpgradeUsdtMainnetFork is CohortUpgradeForkBase {

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

contract CohortUpgradeUsdtBaseFork is CohortUpgradeForkBase {

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

contract CohortUpgradeUsdtArbitrumFork is CohortUpgradeForkBase {

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

contract CohortUpgradeUsdgMainnetFork is CohortUpgradeForkBase {

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

contract CohortUpgradeUsdgArbitrumFork is CohortUpgradeForkBase {

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

contract CohortUpgradeUsdgRobinhoodFork is CohortUpgradeForkBase {

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
