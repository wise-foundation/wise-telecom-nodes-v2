// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Internal} from "@chainlink/contracts-ccip/contracts/libraries/Internal.sol";

import {CcipForkHarness} from "./utils/CcipForkHarness.sol";
import {ICcipBridgeVault} from "./utils/CcipForkInterfaces.sol";
import {CcipV2Shapes, ICcipOnRampV2Events} from "./utils/CcipV2Shapes.sol";

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
import {CohortBridgeHookFacet} from "../../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortHookFacet} from "../../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortMoveHookFacet} from "../../../src/diamond/vault/facets/pending/CohortMoveHookFacet.sol";
import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";

import {SelectorTimelockNotElapsed} from "../../../src/diamond/shared/DiamondErrors.sol";
import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

/**
 * @dev Minimal local surface of the LIVE WiseTelecomNodes diamond used
 * by the cross-chain carry rehearsal, driven through the diamond's own
 * dispatcher and fallback router. The referral, cohort and
 * registry-pointer entrypoints are declared even though the live
 * dispatcher does not know them before the rehearsed upgrade; after
 * the selector round they resolve through the routing table, which is
 * part of what this suite proves.
 */
interface IWtnCarryVault {

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

    function setCohortSyncEnabled(
        bool enabled
    )
        external;

    function getCohortSyncEnabled()
        external
        view
        returns (bool);

    function depositWithReferral(
        uint256 amount,
        address referrer
    )
        external;

    function getReferrerOf(
        address user
    )
        external
        view
        returns (address);

    function getTrackedContribution(
        address user
    )
        external
        view
        returns (uint256);

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
}

/**
 * @dev Full-stack cross-chain referral-carry rehearsal: installs the
 * complete recorder-plus-registry-plus-bridge-carry upgrade on LIVE
 * diamonds forked on BOTH ends of a real usdc CCIP lane, then bridges
 * a referred user across and proves the attribution carry end to end
 * on real bytecode, real routers and the real off-ramp gas budget.
 *
 * Per fork, the install ladder mirrors the registry upgrade rollout
 * against the live dispatcher: deploy the pending facet set, propose
 * all twelve selector groups plus the transfer-hook swap under the
 * real master, assert that a premature execute of each
 * dispatcher-routed engine slice (the bridge slice and the move
 * slice) reverts {SelectorTimelockNotElapsed}, warp past the 3-day
 * delay, execute
 * everything; then deploy a standalone {ReferralRegistry} with that
 * chain's mesh rank, allowlist the diamond, and wire the registry
 * pointer through the admin trio's own second 3-day clock (premature
 * revert asserted) before arming cohort sync and the 5M bridge gas
 * budget. Each timelock warp is rewound right after its execute so
 * the real fee quoter never sees an artificially stale gas price.
 *
 * The scenarios then prove, across forks:
 *   1. a referred deposit bridges with the armed capture: the source
 *      clamps tracked state and carries the whole book slice, the
 *      wire's `referralData` is the version 3 envelope, the carry
 *      header plus one pair word (asserted by decoding the scraped
 *      on-ramp log), the destination mints, grows tracked by the
 *      carried delta, adopts the source-stamped registry pair
 *      (earliest-wins key intact), and lands the carried pair at its
 *      own slot aged by the weekly boundaries crossed between the
 *      capture week and the arrival week; the clocks are aligned, so
 *      the pair keeps the credit slot of the deposit week whether or
 *      not the source week aging moved the send into the next week,
 *      with
 *      {CohortBridgeCarrySent} (the charged book included) and
 *      {CohortBridgeCarryApplied} pinned on their respective forks;
 *   2. an unreferred user still bridges a zero-referrer carry: the
 *      destination tracked contribution grows, both registries stay
 *      unassigned and no book credit exists anywhere;
 *   3. the delivery runs through the real off-ramp under the armed
 *      per-message gas limit: successful execution IS the budget
 *      proof, with the observed routing gas logged for reference.
 *
 * The wire assertion consumes the recorded on-ramp log of either live
 * on-ramp generation (the abi-encoded ramp message of OnRamp 1.6.0 or
 * the packed wire message of OnRamp 2.0.0, read exactly as the shared
 * harness reads them), so the suite re-emits the decoded log unchanged
 * before routing; the off-ramp engine then scrapes and delivers it
 * exactly as it would have. A
 * week of aging between deposit and bridge is probed against the
 * live fee quoter first and rewound if the aged clock would trip a
 * gas-price staleness guard on this lane. All scenarios self-skip
 * unless the lane is vault-peered in both directions under the
 * default off-ramp routing engine.
 */
abstract contract CcipCarryUpgradeRehearsalForkBase is CcipForkHarness {

    struct CarryWire {
        address user;
        uint64 dstChainSelector;
        address referrer;
        uint256 trackedDelta;
        uint256 year1;
        uint256 year2;
        uint256 mature;
        address bookReferrer;
        uint256 wireBytes;
    }

    event CohortBridgeCarrySent(
        address indexed user,
        uint64 indexed dstChainSelector,
        address indexed referrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature,
        address bookReferrer
    );

    event CohortBridgeCarryApplied(
        address indexed user,
        uint64 indexed srcChainSelector,
        address indexed effectiveReferrer,
        address carriedReferrer,
        uint256 trackedDelta,
        uint256 year1,
        uint256 year2,
        uint256 mature
    );

    ReferralRegistry internal srcRegistry;
    ReferralRegistry internal dstRegistry;
    address internal user;
    address internal referrer;

    function _srcChainRank()
        internal
        pure
        virtual
        returns (uint256);

    function _dstChainRank()
        internal
        pure
        virtual
        returns (uint256);

    function _afterForksReady()
        internal
        override
    {
        user = makeAddr(
            "carryForkUser"
        );

        referrer = makeAddr(
            "carryForkReferrer"
        );

        srcRegistry = _installCarryStack(
            src,
            _srcChainRank()
        );

        dstRegistry = _installCarryStack(
            dst,
            _dstChainRank()
        );
    }

    function test_carryBridge_referredUserEndToEnd()
        public
        virtual
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        uint256 amount = 1_000 * src.one;

        uint256 srcAssignedAt = _referredSourceSetup(
            amount
        );

        _onDst();

        uint256 dstBalanceBefore = ICcipBridgeVault(dst.diamond).balanceOf(
            user
        );

        uint256 dstTrackedBefore = IWtnCarryVault(dst.diamond).getTrackedContribution(
            user
        );

        SentMessage memory sent = _bridgeOut(
            user,
            amount,
            ""
        );

        _assertSourceDrained();

        CarryWire memory wire = _scrapeWireAndReplay(
            sent
        );

        _assertReferredWire(
            wire,
            sent
        );

        _alignDstClock();

        _route(
            sent
        );

        _assertReferredDestination(
            sent,
            srcAssignedAt,
            dstBalanceBefore,
            dstTrackedBefore
        );

        _assertCarryApplied(
            sent,
            referrer,
            referrer,
            sent.dstAmount,
            sent.dstAmount
        );
    }

    function test_carryBridge_unreferredUser_trackedOnly()
        public
        virtual
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        _onSrc();

        uint256 amount = 1_000 * src.one;

        _prepShares(
            src,
            user,
            amount
        );

        assertEq(
            IWtnCarryVault(src.diamond).getTrackedContribution(
                user
            ),
            amount,
            "plain deposit must be tracked on the source"
        );

        assertEq(
            srcRegistry.referrerOf(
                user
            ),
            address(0),
            "unreferred user must stay unassigned on the source registry"
        );

        _onDst();

        uint256 dstBalanceBefore = ICcipBridgeVault(dst.diamond).balanceOf(
            user
        );

        uint256 dstTrackedBefore = IWtnCarryVault(dst.diamond).getTrackedContribution(
            user
        );

        SentMessage memory sent = _bridgeOut(
            user,
            amount,
            ""
        );

        _assertSourceDrained();

        CarryWire memory wire = _scrapeWireAndReplay(
            sent
        );

        _assertUnreferredWire(
            wire,
            sent
        );

        _alignDstClock();

        _route(
            sent
        );

        _onDst();

        assertEq(
            ICcipBridgeVault(dst.diamond).balanceOf(user) - dstBalanceBefore,
            sent.dstAmount,
            "destination must mint the bridged amount"
        );

        assertTrue(
            ICcipBridgeVault(dst.diamond).processedMessageId(
                sent.messageId
            ),
            "message not marked processed on the destination"
        );

        assertEq(
            IWtnCarryVault(dst.diamond).getTrackedContribution(user) - dstTrackedBefore,
            sent.dstAmount,
            "destination tracked must grow with no book credit"
        );

        assertEq(
            dstRegistry.referrerOf(
                user
            ),
            address(0),
            "destination registry must stay unassigned"
        );

        assertEq(
            IWtnCarryVault(dst.diamond).getReferrerOf(
                user
            ),
            address(0),
            "diamond view must stay unassigned on the destination"
        );

        _assertCarryApplied(
            sent,
            address(0),
            address(0),
            sent.dstAmount,
            0
        );
    }

    function test_carryBridge_gasUnderArmedBudget()
        public
        virtual
    {
        if (_laneReady() == false) {

            vm.skip(
                true
            );

            return;
        }

        uint256 amount = 1_000 * src.one;

        _prepDepositRails(
            src,
            user,
            amount
        );

        vm.prank(
            user
        );

        IWtnCarryVault(src.diamond).depositWithReferral(
            amount,
            referrer
        );

        _onDst();

        uint256 dstBalanceBefore = ICcipBridgeVault(dst.diamond).balanceOf(
            user
        );

        SentMessage memory sent = _bridgeOut(
            user,
            amount,
            ""
        );

        _onSrc();

        assertEq(
            uint256(ICcipBridgeVault(src.diamond).bridgeGasLimit()),
            5_000_000,
            "the wire must carry the armed 5M gas budget"
        );

        _alignDstClock();

        uint256 gasBefore = gasleft();

        _route(
            sent
        );

        uint256 gasUsed = gasBefore - gasleft();

        _onDst();

        assertEq(
            ICcipBridgeVault(dst.diamond).balanceOf(user) - dstBalanceBefore,
            sent.dstAmount,
            "delivery under the armed budget must mint"
        );

        assertTrue(
            ICcipBridgeVault(dst.diamond).processedMessageId(
                sent.messageId
            ),
            "delivery under the armed budget must mark the message processed"
        );

        console2.log(
            "routed ccipReceive delivery gas (test-side routing overhead included):",
            gasUsed
        );
    }

    function _laneReady()
        internal
        returns (bool)
    {
        if (engine != RouteEngine.OffRampShim) {
            return false;
        }

        _onSrc();

        if (ICcipBridgeVault(src.diamond).crossChainPeerEnabled(dst.chainSelector) == false) {
            return false;
        }

        _onDst();

        if (ICcipBridgeVault(dst.diamond).crossChainPeerEnabled(src.chainSelector) == false) {
            return false;
        }

        return true;
    }

    function _referredSourceSetup(
        uint256 _amount
    )
        internal
        returns (uint256 srcAssignedAt)
    {
        _prepDepositRails(
            src,
            user,
            _amount
        );

        vm.prank(
            user
        );

        IWtnCarryVault(src.diamond).depositWithReferral(
            _amount,
            referrer
        );

        (
            address assignedReferrer,
            uint256 assignedAt,
            uint256 rank
        ) = srcRegistry.getReferrerPair(
            user
        );

        assertEq(
            assignedReferrer,
            referrer,
            "source registry must record the referrer"
        );

        assertEq(
            rank,
            _srcChainRank(),
            "source registry must stamp the local chain rank"
        );

        assertGt(
            assignedAt,
            0,
            "source registry must stamp the assignment time"
        );

        assertEq(
            IWtnCarryVault(src.diamond).getTrackedContribution(
                user
            ),
            _amount,
            "referred deposit must be tracked on the source"
        );

        assertEq(
            IWtnCarryVault(src.diamond).getCohortScore(
                referrer
            ),
            _amount,
            "referred deposit must credit the source book"
        );

        _ageSourceWeek(
            _amount
        );

        srcAssignedAt = assignedAt;
    }

    function _assertSourceDrained()
        internal
    {
        _onSrc();

        assertEq(
            ICcipBridgeVault(src.diamond).balanceOf(
                user
            ),
            0,
            "source must burn the bridged shares"
        );

        assertEq(
            IWtnCarryVault(src.diamond).getTrackedContribution(
                user
            ),
            0,
            "bridge-out capture must clamp the source tracked contribution"
        );

        assertEq(
            IWtnCarryVault(src.diamond).getCohortScore(
                referrer
            ),
            0,
            "source book slice must be fully carried or empty"
        );
    }

    function _assertReferredWire(
        CarryWire memory _wire,
        SentMessage memory _sent
    )
        internal
    {
        assertEq(
            _wire.user,
            user,
            "carry-sent user mismatch"
        );

        assertEq(
            uint256(_wire.dstChainSelector),
            uint256(dst.chainSelector),
            "carry-sent destination selector mismatch"
        );

        assertEq(
            _wire.referrer,
            referrer,
            "carry-sent referrer mismatch"
        );

        assertEq(
            _wire.bookReferrer,
            referrer,
            "carry-sent book referrer must be the charged source book"
        );

        assertEq(
            _wire.trackedDelta,
            _sent.dstAmount,
            "carried tracked delta must equal the scaled bridged amount"
        );

        assertEq(
            _wire.year1,
            _sent.dstAmount,
            "the whole slice must ride the first-year lane"
        );

        assertEq(
            _wire.year2,
            0,
            "no second-year credit expected on the wire"
        );

        assertEq(
            _wire.mature,
            0,
            "no mature credit expected on the wire"
        );

        assertEq(
            _wire.wireBytes,
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES + 32,
            "wire referralData must be the carry header plus one pair word"
        );
    }

    function _assertUnreferredWire(
        CarryWire memory _wire,
        SentMessage memory _sent
    )
        internal
    {
        assertEq(
            _wire.user,
            user,
            "carry-sent user mismatch"
        );

        assertEq(
            _wire.referrer,
            address(0),
            "unreferred wire must carry a zero referrer"
        );

        assertEq(
            _wire.bookReferrer,
            address(0),
            "unreferred wire must name no charged book"
        );

        assertEq(
            _wire.trackedDelta,
            _sent.dstAmount,
            "carried tracked delta must equal the scaled bridged amount"
        );

        assertEq(
            _wire.year1,
            0,
            "unreferred wire must carry no book lanes"
        );

        assertEq(
            _wire.year2,
            0,
            "unreferred wire must carry no book lanes"
        );

        assertEq(
            _wire.mature,
            0,
            "unreferred wire must carry no book lanes"
        );

        assertEq(
            _wire.wireBytes,
            CohortWeeks.BRIDGE_CARRY_HEADER_BYTES,
            "wire referralData must be the bare carry header"
        );
    }

    function _assertReferredDestination(
        SentMessage memory _sent,
        uint256 _srcAssignedAt,
        uint256 _dstBalanceBefore,
        uint256 _dstTrackedBefore
    )
        internal
    {
        _onDst();

        assertEq(
            ICcipBridgeVault(dst.diamond).balanceOf(user) - _dstBalanceBefore,
            _sent.dstAmount,
            "destination must mint the bridged amount"
        );

        assertTrue(
            ICcipBridgeVault(dst.diamond).processedMessageId(
                _sent.messageId
            ),
            "message not marked processed on the destination"
        );

        assertEq(
            IWtnCarryVault(dst.diamond).getTrackedContribution(user) - _dstTrackedBefore,
            _sent.dstAmount,
            "destination tracked contribution must grow by the carried delta"
        );

        assertEq(
            dstRegistry.referrerOf(
                user
            ),
            referrer,
            "carry must assign the referrer on the destination registry"
        );

        (
            address carriedReferrer,
            uint256 assignedAt,
            uint256 rank
        ) = dstRegistry.getReferrerPair(
            user
        );

        assertEq(
            carriedReferrer,
            referrer,
            "destination pair referrer mismatch"
        );

        assertEq(
            assignedAt,
            _srcAssignedAt,
            "carry must keep the source-stamped assignment time"
        );

        assertEq(
            rank,
            _srcChainRank(),
            "carry must keep the source-stamped chain rank"
        );

        assertEq(
            IWtnCarryVault(dst.diamond).getReferrerOf(
                user
            ),
            referrer,
            "diamond view must resolve the carried referrer"
        );

        uint256 slot = (_srcAssignedAt / CohortWeeks.WEEK) % CohortWeeks.RING_SLOTS;

        (
            uint64[52] memory ringYear1,
        ) = IWtnCarryVault(dst.diamond).getCohortRings(
            referrer
        );

        assertEq(
            uint256(ringYear1[slot]),
            _sent.dstAmount,
            "carried pair must land at its own credit slot, the deposit week under aligned clocks"
        );

        assertEq(
            IWtnCarryVault(dst.diamond).getCohortScore(
                referrer
            ),
            _sent.dstAmount,
            "destination book total must equal the carried slice"
        );
    }

    function _scrapeWireAndReplay(
        SentMessage memory _sent
    )
        internal
        returns (CarryWire memory wire)
    {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool carryFound;
        bool rampFound;

        for (uint256 i; i < entries.length; ++i) {

            if (entries[i].topics.length == 0) {
                continue;
            }

            if (entries[i].topics[0] == CohortBridgeCarrySent.selector) {

                if (entries[i].emitter != _sent.srcDiamond) {
                    continue;
                }

                wire.user = address(
                    uint160(uint256(entries[i].topics[1]))
                );

                wire.dstChainSelector = uint64(
                    uint256(entries[i].topics[2])
                );

                wire.referrer = address(
                    uint160(uint256(entries[i].topics[3]))
                );

                (
                    wire.trackedDelta,
                    wire.year1,
                    wire.year2,
                    wire.mature,
                    wire.bookReferrer
                ) = abi.decode(
                    entries[i].data,
                    (uint256, uint256, uint256, uint256, address)
                );

                carryFound = true;

                continue;
            }

            if (entries[i].topics[0] == CCIPMessageSent.selector) {

                if (
                    _scrapeRampV16(
                        entries[i],
                        _sent,
                        wire
                    )
                ) {
                    rampFound = true;
                }

                continue;
            }

            if (entries[i].topics[0] == ICcipOnRampV2Events.CCIPMessageSent.selector) {

                if (
                    _scrapeRampV20(
                        entries[i],
                        _sent,
                        wire
                    )
                ) {
                    rampFound = true;
                }
            }
        }

        require(
            carryFound,
            "CohortBridgeCarrySent not emitted on the source"
        );

        require(
            rampFound,
            "CCIPMessageSent log not found for the bridge message"
        );
    }

    function _scrapeRampV16(
        Vm.Log memory _entry,
        SentMessage memory _sent,
        CarryWire memory _wire
    )
        internal
        returns (bool)
    {
        Internal.EVM2AnyRampMessage memory ramp = abi.decode(
            _entry.data,
            (Internal.EVM2AnyRampMessage)
        );

        if (ramp.header.messageId != _sent.messageId) {
            return false;
        }

        _wire.wireBytes = _referralBytesOf(
            ramp.data
        );

        emit CCIPMessageSent(
            ramp.header.destChainSelector,
            ramp.header.sequenceNumber,
            ramp
        );

        return true;
    }

    function _scrapeRampV20(
        Vm.Log memory _entry,
        SentMessage memory _sent,
        CarryWire memory _wire
    )
        internal
        returns (bool)
    {
        if (_entry.topics.length < 4 || _entry.topics[3] != _sent.messageId) {
            return false;
        }

        (
            address feeToken,
            uint256 amountBeforeFees,
            bytes memory encodedMessage,
            CcipV2Shapes.Receipt[] memory receipts,
            bytes[] memory verifierBlobs
        ) = abi.decode(
            _entry.data,
            (address, uint256, bytes, CcipV2Shapes.Receipt[], bytes[])
        );

        CcipV2Shapes.MessageV1 memory message = this.decodeCcipV2Message(
            encodedMessage
        );

        _wire.wireBytes = _referralBytesOf(
            message.data
        );

        emit ICcipOnRampV2Events.CCIPMessageSent(
            uint64(uint256(_entry.topics[1])),
            address(uint160(uint256(_entry.topics[2]))),
            _entry.topics[3],
            feeToken,
            amountBeforeFees,
            encodedMessage,
            receipts,
            verifierBlobs
        );

        return true;
    }

    function _referralBytesOf(
        bytes memory _data
    )
        internal
        pure
        returns (uint256)
    {
        (
            ,
            ,
            bytes memory referralData
        ) = abi.decode(
            _data,
            (address, uint256, bytes)
        );

        return referralData.length;
    }

    function _assertCarryApplied(
        SentMessage memory _sent,
        address _effectiveReferrer,
        address _carriedReferrer,
        uint256 _trackedDelta,
        uint256 _year1
    )
        internal
    {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        for (uint256 i; i < entries.length; ++i) {

            if (entries[i].topics[0] != CohortBridgeCarryApplied.selector) {
                continue;
            }

            if (entries[i].emitter != _sent.dstDiamond) {
                continue;
            }

            assertEq(
                address(uint160(uint256(entries[i].topics[1]))),
                _sent.user,
                "carry-applied user mismatch"
            );

            assertEq(
                uint256(entries[i].topics[2]),
                uint256(_sent.srcChainSelector),
                "carry-applied source selector mismatch"
            );

            assertEq(
                address(uint160(uint256(entries[i].topics[3]))),
                _effectiveReferrer,
                "carry-applied effective referrer mismatch"
            );

            (
                address carriedReferrer,
                uint256 trackedDelta,
                uint256 year1,
                uint256 year2,
                uint256 mature
            ) = abi.decode(
                entries[i].data,
                (address, uint256, uint256, uint256, uint256)
            );

            assertEq(
                carriedReferrer,
                _carriedReferrer,
                "carry-applied carried referrer mismatch"
            );

            assertEq(
                trackedDelta,
                _trackedDelta,
                "carry-applied tracked delta mismatch"
            );

            assertEq(
                year1,
                _year1,
                "carry-applied first-year lane mismatch"
            );

            assertEq(
                year2,
                0,
                "carry-applied second-year lane must be empty"
            );

            assertEq(
                mature,
                0,
                "carry-applied mature lane must be empty"
            );

            return;
        }

        revert(
            "CohortBridgeCarryApplied not emitted on the destination"
        );
    }

    function _alignDstClock()
        internal
    {
        _onSrc();

        uint256 srcNow = block.timestamp;

        _onDst();

        if (block.timestamp < srcNow) {

            vm.warp(
                srcNow
            );
        }
    }

    function _ageSourceWeek(
        uint256 _amount
    )
        internal
    {
        _onSrc();

        uint256 aged = block.timestamp + 1 weeks;

        vm.warp(
            aged
        );

        try ICcipBridgeVault(src.diamond).quoteBridgeFeeWithReferral(
            dst.chainSelector,
            _amount,
            ""
        ) returns (uint256) {
            return;
        } catch {
            vm.warp(
                aged - 1 weeks + 90
            );
        }
    }

    function _prepDepositRails(
        ChainCtx storage _ctx,
        address _user,
        uint256 _amount
    )
        internal
    {
        vm.selectFork(
            _ctx.forkId
        );

        ICcipBridgeVault vault = ICcipBridgeVault(
            _ctx.diamond
        );

        if (vault.paused()) {

            vm.prank(
                _ctx.master
            );

            vault.unpauseDeposits();
        }

        if (vault.depositsDisabled()) {

            vm.prank(
                _ctx.master
            );

            vault.setDepositsDisabled(
                false
            );
        }

        vm.prank(
            _ctx.master
        );

        vault.setGraceFreezeEnabled(
            false
        );

        uint256 liftedCap = vault.totalSupply() + 100 * _amount;

        vm.prank(
            _ctx.master
        );

        vault.setTotalDepositCap(
            liftedCap
        );

        deal(
            _ctx.usd,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        (
            bool ok,
        ) = _ctx.usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                _ctx.diamond,
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );
    }

    function _installCarryStack(
        ChainCtx storage _ctx,
        uint256 _chainRank
    )
        internal
        returns (ReferralRegistry registry)
    {
        vm.selectFork(
            _ctx.forkId
        );

        IWtnCarryVault v = IWtnCarryVault(
            _ctx.diamond
        );

        address m = _ctx.master;

        uint256 startTime = block.timestamp;

        address cohortHookFacet = address(
            new CohortHookFacet()
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._adminSelectors(),
            address(new AdminFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._userSelectors(),
            address(new UserFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._permit2Selectors(),
            address(new Permit2UserFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._moveSelectors(),
            address(new MoveFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._bridgeSelectors(),
            address(new BridgeFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors(),
            address(new QueueJoinLeaveFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._queueFulfillSelectors(),
            address(new QueueFulfillFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._referralSelectors(),
            address(new ReferralFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors(),
            address(new Permit2ReferralFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors(),
            address(new CohortRecorderFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._cohortBridgeHookSelectors(),
            address(new CohortBridgeHookFacet())
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors(),
            address(new CohortMoveHookFacet())
        );

        vm.prank(
            m
        );

        v.proposeTransferHookFacet(
            cohortHookFacet
        );

        vm.prank(
            m
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        vm.prank(
            m
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        vm.warp(
            startTime + 3 days + 1
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._adminSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._userSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._permit2Selectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._moveSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._bridgeSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._queueJoinLeaveSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._queueFulfillSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._referralSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._permit2ReferralSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._cohortRecorderSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._cohortBridgeHookSelectors()
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors._cohortMoveHookSelectors()
        );

        vm.prank(
            m
        );

        v.executeTransferHookFacetChange();

        vm.warp(
            startTime + 2
        );

        assertEq(
            v.transferHookFacet(),
            cohortHookFacet,
            "cohort transfer hook not installed"
        );

        registry = new ReferralRegistry(
            address(this),
            _chainRank
        );

        registry.setAllowedVault(
            _ctx.diamond,
            true
        );

        uint256 pointerTime = block.timestamp;

        vm.prank(
            m
        );

        v.proposeReferralRegistry(
            address(registry)
        );

        vm.prank(
            m
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.ReferralRegistryTimelockNotElapsed.selector
        );

        v.executeReferralRegistryChange();

        vm.warp(
            pointerTime + 3 days + 1
        );

        vm.prank(
            m
        );

        v.executeReferralRegistryChange();

        vm.warp(
            pointerTime + 2
        );

        assertEq(
            v.getReferralRegistry(),
            address(registry),
            "registry pointer not wired"
        );

        vm.prank(
            m
        );

        v.setCohortSyncEnabled(
            true
        );

        assertTrue(
            v.getCohortSyncEnabled(),
            "cohort sync arming failed"
        );

        _raiseBridgeGasLimit(
            _ctx,
            5_000_000
        );

        assertEq(
            uint256(ICcipBridgeVault(_ctx.diamond).bridgeGasLimit()),
            5_000_000,
            "bridge gas limit not armed"
        );
    }

    function _proposeGroup(
        IWtnCarryVault _v,
        address _m,
        bytes4[] memory _sels,
        address _facet
    )
        internal
    {
        vm.prank(
            _m
        );

        _v.proposeSelectors(
            _sels,
            _facet
        );
    }

    function _executeGroup(
        IWtnCarryVault _v,
        address _m,
        bytes4[] memory _sels
    )
        internal
    {
        vm.prank(
            _m
        );

        _v.executeSelectorChanges(
            _sels
        );
    }
}

contract CcipCarryUsdcMainnetBaseFork is CcipCarryUpgradeRehearsalForkBase {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdc",
            srcNetwork: "mainnet",
            dstNetwork: "base",
            srcRpc: "mainnet",
            dstRpc: "base"
        });
    }

    function _srcChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function _dstChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 1;
    }
}
