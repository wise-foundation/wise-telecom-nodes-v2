// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {BurnWiseFacet} from "../../src/diamond/vault/facets/BurnWiseFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {Permit2UserFacet} from "../../src/diamond/vault/facets/Permit2UserFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {ReferralPayoutFacet} from "../../src/diamond/vault/facets/pending/ReferralPayoutFacet.sol";
import {MulticallFacet} from "../../src/diamond/vault/facets/MulticallFacet.sol";
import {QueueAdminFacet} from "../../src/diamond/vault/facets/QueueAdminFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {QueueForecastFacet} from "../../src/diamond/vault/facets/QueueForecastFacet.sol";
import {InterestAdminFacet} from "../../src/diamond/vault/facets/InterestAdminFacet.sol";
import {RescueFacet} from "../../src/diamond/vault/facets/RescueFacet.sol";
import {AutoCompoundFacet} from "../../src/diamond/vault/facets/AutoCompoundFacet.sol";
import {WiseTelecomNodesQueueUIHelper} from "../../src/diamond/vault/helpers/WiseTelecomNodesQueueUIHelper.sol";
import {WiseTelecomNodesQueueHelper} from "../../src/diamond/vault/helpers/WiseTelecomNodesQueueHelper.sol";

/**
 * @dev Getter mirror of the auto-compound tail shard: Solidity
 * exposes no `.selector` for public state variables, so the routed
 * getter selectors come from here. Signature parity is asserted by
 * the facet tests and the live-fork getter reads.
 */
interface IAutoCompoundGetters {

    function isAutoCompoundBot(
        address _bot
    )
        external
        view
        returns (bool);

    function autoCompoundAllowed(
        address _user
    )
        external
        view
        returns (bool);

    function autoCompoundFeeBps()
        external
        view
        returns (uint256);
}

/**
 * @dev Single source of truth for WiseTelecomNodes facet selectors.
 * Deploy scripts and tests both import this library so the wiring
 * cannot drift.
 *
 * Counts: admin=34, proxy=3, user=8, sweep=2, cashedInterest=1,
 * burnWise=3, move=7, bridge=14, permit2=3, referral=4,
 * permit2Referral=3, cohortRecorder=11, cohortBridgeHook=3,
 * multicall=1, queueAdmin=2,
 * queueJoinLeave=5, queueFulfill=4, queueView=10, queueForecast=1,
 * interestAdmin=1, rescue=1, autoCompound=7 (4 functions + the 3
 * shard getters, which the frozen live dispatchers cannot serve),
 * referralPayout=1 — total 129, of which
 * 90 are wired at genesis (the genesis-era admin group had 27;
 * `setCohortSyncEnabled` ships with the cohort upgrade's AdminFacet
 * redeploy, and the referral-registry pointer six —
 * propose/execute/cancel plus the three routed getters backing the
 * slot-77 shard's `internal` fields — ship with the registry
 * round's AdminFacet redeploy). The referral groups (referral=4,
 * permit2Referral=3) and the cohortRecorder group are post-launch:
 * installed exclusively by the registry upgrade script (which
 * supersedes {UpgradeCohortRecorder}, which superseded
 * {UpgradeReferral}), never by the genesis deploy scripts, so the
 * genesis wiring stays identical to what is live in production.
 * The queueForecast and interestAdmin groups are also post-launch,
 * live on all nine diamonds since early August 2026; the rescue
 * group is live on usdt-base only.
 * The referralPayout group is post-launch and NOT yet installed
 * anywhere: it ships with the future payout upgrade script
 * alongside the `pendingReferralPayout` writer. `applyTransferHook`
 * and the slot-45 `applyCohort*` entrypoints are deliberately absent
 * from every group: {CohortHookFacet} is reached only through the
 * `transferHookFacet` pointer, never the dispatcher. That pointer-only
 * register grew to six entrypoints with the same-chain move-carry pair
 * (`applyCohortMoveOut` / `applyCohortMoveIn`). The cross-chain
 * engine slice ({CohortBridgeHookFacet}: `applyCohortFlip` and the
 * bridge-carry pair) is DISPATCHER-routed instead — the engine
 * outgrew one EIP-170 deployment, and routing the second slice
 * through `selectorToFacet` reuses the selector timelock rather than
 * adding a second pointer slot — but its three selectors still revert
 * on any direct external call (the transient `hookExecuting` bracket
 * only closes around the vault's own internal dispatch), so the
 * externally-REACHABLE surface grew only by `receiveReferrerFlip`
 * (registry-only caller), which took the cohortRecorder group to 11.
 *
 * `referralSelectors` includes the routed `getReferrerOf` view (the
 * registry-reading replacement for the retired slot-67
 * auto-getter): the live diamond keeps its genesis bytecode, so every
 * post-genesis read surface must be routed to a facet explicitly —
 * same story as the six pointer selectors in the admin group.
 */
library WiseTelecomNodesDiamondSelectors {

    function adminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](34);
        sels[0] = AdminFacet.disAllowSupplyChangeByOwner.selector;
        sels[1] = AdminFacet.mintSupply.selector;
        sels[2] = AdminFacet.burnSupply.selector;
        sels[3] = AdminFacet.pauseDeposits.selector;
        sels[4] = AdminFacet.unpauseDeposits.selector;
        sels[5] = AdminFacet.proposeThirdPartyAddress.selector;
        sels[6] = AdminFacet.executeThirdPartyAddressChange.selector;
        sels[7] = AdminFacet.cancelThirdPartyAddressChange.selector;
        sels[8] = AdminFacet.setInterestRate.selector;
        sels[9] = AdminFacet.setTotalDepositCap.selector;
        sels[10] = AdminFacet.setProxyBenefactor.selector;
        sels[11] = AdminFacet.proposeWorkerAddress.selector;
        sels[12] = AdminFacet.executeWorkerAddressChange.selector;
        sels[13] = AdminFacet.cancelWorkerAddressChange.selector;
        sels[14] = AdminFacet.setWiseToken.selector;
        sels[15] = AdminFacet.proposeTransferHookFacet.selector;
        sels[16] = AdminFacet.executeTransferHookFacetChange.selector;
        sels[17] = AdminFacet.cancelTransferHookFacetChange.selector;
        sels[18] = AdminFacet.setDepositsDisabled.selector;
        sels[19] = AdminFacet.setGracePeriodDuration.selector;
        sels[20] = AdminFacet.setGraceThresholdAmount.selector;
        sels[21] = AdminFacet.setGraceFreezeEnabled.selector;
        sels[22] = AdminFacet.proposeDepositHookFacet.selector;
        sels[23] = AdminFacet.executeDepositHookFacetChange.selector;
        sels[24] = AdminFacet.cancelDepositHookFacetChange.selector;
        sels[25] = AdminFacet.setDepositAccumWindow.selector;
        sels[26] = AdminFacet.setSweeper.selector;
        sels[27] = AdminFacet.setCohortSyncEnabled.selector;
        sels[28] = AdminFacet.proposeReferralRegistry.selector;
        sels[29] = AdminFacet.executeReferralRegistryChange.selector;
        sels[30] = AdminFacet.cancelReferralRegistryChange.selector;
        sels[31] = AdminFacet.getReferralRegistry.selector;
        sels[32] = AdminFacet.getProposedReferralRegistry.selector;
        sels[33] = AdminFacet.getReferralRegistryChangeQueuedAt.selector;
    }

    function cohortRecorderSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](11);
        sels[0] = CohortRecorderFacet.syncReferee.selector;
        sels[1] = CohortRecorderFacet.advanceBook.selector;
        sels[2] = CohortRecorderFacet.getTrackedContribution.selector;
        sels[3] = CohortRecorderFacet.getCohortBook.selector;
        sels[4] = CohortRecorderFacet.getCohortScore.selector;
        sels[5] = CohortRecorderFacet.getCohortRings.selector;
        sels[6] = CohortRecorderFacet.getCohortWeekCrumb.selector;
        sels[7] = CohortRecorderFacet.getCohortGapLogLength.selector;
        sels[8] = CohortRecorderFacet.getCohortGapLogEntry.selector;
        sels[9] = CohortRecorderFacet.getCohortSyncEnabled.selector;
        sels[10] = CohortRecorderFacet.receiveReferrerFlip.selector;
    }

    function cohortBridgeHookSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = CohortBridgeHookFacet.applyCohortFlip.selector;
        sels[1] = CohortBridgeHookFacet.applyCohortBridgeOut.selector;
        sels[2] = CohortBridgeHookFacet.applyCohortBridgeIn.selector;
    }

    function proxySelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = ProxyFacet.triggerAssignInterest.selector;
        sels[1] = ProxyFacet.increaseProxyBalance.selector;
        sels[2] = ProxyFacet.decreaseProxyBalance.selector;
    }

    function userSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](8);
        sels[0] = UserFacet.deposit.selector;
        sels[1] = UserFacet.claimInterest.selector;
        sels[2] = UserFacet.claimInterestExactAmount.selector;
        sels[3] = UserFacet.claimInterestPartiallyAndCompound.selector;
        sels[4] = UserFacet.compoundInterest.selector;
        sels[5] = UserFacet.depositAndClaimInterest.selector;
        sels[6] = UserFacet.depositAndCompoundInterest.selector;
        sels[7] = UserFacet.moveMyInterestTo.selector;
    }

    function sweepSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](2);
        sels[0] = SweepFacet.sweepOverhang.selector;
        sels[1] = SweepFacet.getOverhang.selector;
    }

    function cashedInterestSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = CashedInterestFacet.getTotalCashedInterest.selector;
    }

    function referralPayoutSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = ReferralPayoutFacet.getPendingReferralPayout.selector;
    }

    function queueForecastSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = QueueForecastFacet.solveForAmountAfterFulfill.selector;
    }

    function interestAdminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = InterestAdminFacet.setCashedInterest.selector;
    }

    function rescueSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = RescueFacet.rescueToken.selector;
    }

    function autoCompoundSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](7);
        sels[0] = AutoCompoundFacet.compoundInterestOnBehalf.selector;
        sels[1] = AutoCompoundFacet.setAutoCompoundAllowed.selector;
        sels[2] = AutoCompoundFacet.setAutoCompoundBot.selector;
        sels[3] = AutoCompoundFacet.setAutoCompoundFeeBps.selector;
        sels[4] = IAutoCompoundGetters.isAutoCompoundBot.selector;
        sels[5] = IAutoCompoundGetters.autoCompoundAllowed.selector;
        sels[6] = IAutoCompoundGetters.autoCompoundFeeBps.selector;
    }

    function burnWiseSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = BurnWiseFacet.burnWise.selector;
        sels[1] = BurnWiseFacet.getBurnableWise.selector;
        sels[2] = BurnWiseFacet.getNextBurnPercentage.selector;
    }

    function moveSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](7);
        sels[0] = MoveFacet.proposePeerVault.selector;
        sels[1] = MoveFacet.executePeerVaultChange.selector;
        sels[2] = MoveFacet.cancelPeerVaultChange.selector;
        sels[3] = MoveFacet.removePeerVault.selector;
        sels[4] = MoveFacet.moveBetweenVaults.selector;
        sels[5] = MoveFacet.mintFromPeer.selector;
        sels[6] = MoveFacet.getMoveableBalance.selector;
    }

    function bridgeSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](14);
        sels[0] = BridgeFacet.setCcipRouter.selector;
        sels[1] = BridgeFacet.proposeCrossChainPeer.selector;
        sels[2] = BridgeFacet.executeCrossChainPeerChange.selector;
        sels[3] = BridgeFacet.cancelCrossChainPeerChange.selector;
        sels[4] = BridgeFacet.removeCrossChainPeer.selector;
        sels[5] = BridgeFacet.bridgeToVault.selector;
        sels[6] = BridgeFacet.ccipReceive.selector;
        sels[7] = BridgeFacet.quoteBridgeFee.selector;
        sels[8] = BridgeFacet.getBridgeableBalance.selector;
        sels[9] = BridgeFacet.supportsInterface.selector;
        sels[10] = BridgeFacet.bridgeToVaultWithReferral.selector;
        sels[11] = BridgeFacet.quoteBridgeFeeWithReferral.selector;
        sels[12] = BridgeFacet.setReferralEnabled.selector;
        sels[13] = BridgeFacet.setBridgeGasLimit.selector;
    }

    function permit2Selectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = Permit2UserFacet.depositWithPermit2.selector;
        sels[1] = Permit2UserFacet.depositAndClaimInterestWithPermit2.selector;
        sels[2] = Permit2UserFacet.depositAndCompoundInterestWithPermit2.selector;
    }

    function referralSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](4);
        sels[0] = ReferralFacet.depositWithReferral.selector;
        sels[1] = ReferralFacet.depositAndClaimInterestWithReferral.selector;
        sels[2] = ReferralFacet.depositAndCompoundInterestWithReferral.selector;
        sels[3] = ReferralFacet.getReferrerOf.selector;
    }

    function permit2ReferralSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](3);
        sels[0] = Permit2ReferralFacet.depositWithPermit2WithReferral.selector;
        sels[1] = Permit2ReferralFacet.depositAndClaimInterestWithPermit2WithReferral.selector;
        sels[2] = Permit2ReferralFacet.depositAndCompoundInterestWithPermit2WithReferral.selector;
    }

    function multicallSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](1);
        sels[0] = MulticallFacet.multicall.selector;
    }

    function queueAdminSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](2);
        sels[0] = QueueAdminFacet.changeMinDepositAmount.selector;
        sels[1] = QueueAdminFacet.setNegativeIncentivesNotAllowed.selector;
    }

    function queueJoinLeaveSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](5);
        sels[0] = QueueJoinLeaveFacet.joinQue.selector;
        sels[1] = QueueJoinLeaveFacet.leaveQue.selector;
        sels[2] = QueueJoinLeaveFacet.reduceQueAmount.selector;
        sels[3] = QueueJoinLeaveFacet.switchQueIncentive.selector;
        sels[4] = QueueJoinLeaveFacet.switchQueIncentivePartial.selector;
    }

    function queueFulfillSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](4);
        sels[0] = QueueFulfillFacet.fulfillOrder.selector;
        sels[1] = QueueFulfillFacet.partiallyFulfillOrder.selector;
        sels[2] = QueueFulfillFacet.fulfillOrderBulk.selector;
        sels[3] = QueueFulfillFacet.compoundInterestViaFulfillBulk.selector;
    }

    function queueViewSelectors()
        internal
        pure
        returns (bytes4[] memory sels)
    {
        sels = new bytes4[](10);
        sels[0] = WiseTelecomNodesQueueUIHelper.getFulfillmentPlanForIncentive.selector;
        sels[1] = WiseTelecomNodesQueueUIHelper.solveForAmount.selector;
        sels[2] = WiseTelecomNodesQueueUIHelper.predictDiscountedAmount.selector;
        sels[3] = WiseTelecomNodesQueueUIHelper.predictCostForTokens.selector;
        sels[4] = WiseTelecomNodesQueueUIHelper.predictTokensForCost.selector;
        sels[5] = WiseTelecomNodesQueueUIHelper.getAllOrdersfromAddress.selector;
        sels[6] = WiseTelecomNodesQueueUIHelper.getAllOrdersOverall.selector;
        sels[7] = WiseTelecomNodesQueueHelper._solveForAmountWithIncentive.selector;
        sels[8] = WiseTelecomNodesQueueUIHelper.getAllOrdersOverallWithId.selector;
        sels[9] = WiseTelecomNodesQueueUIHelper.getAllOrdersfromAddressWithId.selector;
    }
}
