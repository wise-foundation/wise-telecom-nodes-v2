// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Internal} from "@chainlink/contracts-ccip/contracts/libraries/Internal.sol";

import {CcipForkHarness} from "./utils/CcipForkHarness.sol";
import {ICcipBridgeVault, ICcipRouterView} from "./utils/CcipForkInterfaces.sol";
import {CcipV2Shapes, ICcipOnRampV2Events} from "./utils/CcipV2Shapes.sol";

import {AdminFacet} from "../../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../../src/diamond/vault/facets/SweepFacet.sol";
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
import {CohortFlushFacet} from "../../../src/diamond/vault/facets/pending/CohortFlushFacet.sol";
import {ReferralPayoutFacet} from "../../../src/diamond/vault/facets/pending/ReferralPayoutFacet.sol";
import {ReferralRegistry} from "../../../src/registry/pending/ReferralRegistry.sol";
import {ReferralHub} from "../../../src/hub/pending/ReferralHub.sol";
import {ReferralHubDeclarations} from "../../../src/hub/pending/ReferralHubDeclarations.sol";

import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {CohortWeeks} from "../../../src/diamond/shared/pending/CohortWeeks.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

/**
 * @dev Minimal local surface of the LIVE WiseTelecomNodes diamond used
 * by the flush-transport rehearsal, driven through the diamond's own
 * dispatcher and fallback router. The referral, cohort, flush and
 * pointer entrypoints are declared even though the live dispatcher
 * does not know them before the rehearsed upgrade; after the
 * selector round they resolve through the routing table, which is
 * part of what this suite proves.
 */
interface IWtnFlushVault {

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

    function setCohortSyncEnabled(
        bool enabled
    )
        external;

    function depositWithReferral(
        uint256 amount,
        address referrer
    )
        external;

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

    function getCohortWeekCrumb(
        address referrer,
        uint256 week
    )
        external
        view
        returns (uint256);

    function getCohortGapLogEntry(
        address referrer,
        uint256 index
    )
        external
        view
        returns (uint256);

    function getCohortGapLogLength(
        address referrer
    )
        external
        view
        returns (uint256);

    function advanceBook(
        address referrer,
        uint256 maxBoundaries
    )
        external;

    function proposeFlushHub(
        address hub,
        uint64 chainSelector
    )
        external;

    function executeFlushHubChange()
        external;

    function getFlushHub()
        external
        view
        returns (
            address,
            uint64
        );

    function setAllowedFlushBot(
        address bot,
        bool allowed
    )
        external;

    function flushReferrals(
        address[] calldata referrers
    )
        external
        payable;

    function quoteFlushFee(
        address[] calldata referrers
    )
        external
        view
        returns (uint256);

    function getFlushedThroughWeek(
        address referrer
    )
        external
        view
        returns (uint256);

    function getFlushGapCursor(
        address referrer
    )
        external
        view
        returns (
            uint256,
            uint256
        );

    function proposePayoutHub(
        address hub
    )
        external;

    function executePayoutHubChange()
        external;

    function master()
        external
        view
        returns (address);

    function USD_TOKEN()
        external
        view
        returns (address);
}

interface IUsdBalance {

    function balanceOf(
        address account
    )
        external
        view
        returns (uint256);
}

/**
 * @dev Full-stack cross-chain flush-transport rehearsal: installs the
 * complete recorder-plus-registry-plus-flush upgrade on a LIVE spoke
 * diamond forked from a production chain, deploys the REAL standalone
 * {ReferralHub} on a mainnet fork against the payout vault's real
 * underlying, installs the payout rail on the LIVE usdc mainnet
 * diamond, and then proves the whole referral money pipeline on real
 * bytecode, real routers and the real per-message gas budget:
 * a referred deposit on the spoke, its book flushed over the wire,
 * the envelope committed into the hub mailbox, lazily applied under
 * the hashed remote source key, priced into a per-source-chain
 * claimable bucket, booked as liability on the live payout vault,
 * and claimed as REAL USD pulled out of that vault's pool.
 *
 * The spoke install ladder mirrors the flush upgrade rollout against
 * the live dispatcher: the carry-stack groups plus the cohortFlush
 * group and the settle-aware transfer hook under the real master and
 * the real 3-day timelock, then the flush-hub pointer through the
 * admin trio's own second clock (premature revert asserted), the
 * standalone registry with the chain's mesh rank, and the registry's
 * payout-hub route. Each timelock warp is rewound right after its
 * execute so the live fee quoters never see an artificially stale
 * clock.
 *
 * Score timing doctrine drives the scenario shape: a week's rates
 * are a pure function of the checkpoints in force at its opening
 * boundary, so the FIRST flush only lands the referrer's scores
 * (its own weeks price at the zero rates then in force; late
 * flushes affect later weeks only), and the priced money arrives
 * with a SECOND flush after the scores have stood through the
 * dwell-min window. The live CCIP fee quoters may refuse a clock
 * warped weeks ahead, so every post-aging flush probes the quoter
 * first and falls back to delivering the storage-reconstructed
 * envelope through a pranked router; the reconstruction is
 * byte-asserted against the real on-ramp wire whenever the lane's
 * on-ramp supports the scrape, so the fallback can never drift from
 * what the wire would carry.
 */
abstract contract CohortFlushUpgradeForkBase is CcipForkHarness {

    struct FlushWire {
        bytes32 messageId;
        bytes payload;
        bool synthetic;
    }

    struct FlushPlanSnapshot {
        uint256 fromWeek;
        uint256 flushedAt;
    }

    uint256 internal constant DEPOSIT_AMOUNT_UNITS = 6_000;

    ReferralRegistry internal spokeRegistry;

    ReferralHub internal hub;

    address internal payoutDiamond;

    address internal payoutUsd;

    address internal user;

    address internal referrer;

    address internal bot;

    uint256 internal syntheticNonce;

    function _spokeChainRank()
        internal
        pure
        virtual
        returns (uint256);

    function _afterForksReady()
        internal
        override
    {
        user = makeAddr(
            "flushForkUser"
        );

        referrer = makeAddr(
            "flushForkReferrer"
        );

        bot = makeAddr(
            "flushForkBot"
        );

        _installSpokeStack();

        _installHubSide();

        _wireSpokePointers();
    }

    // ---- spoke flow helpers ----

    function _laneUsable()
        internal
        returns (bool)
    {
        if (engine == RouteEngine.RouterShim) {
            return true;
        }

        _onSrc();

        return _offRampScrapeSupported(
            ICcipRouterView(src.router).getOnRamp(
                dst.chainSelector
            )
        );
    }

    function _referredDepositOnSpoke()
        internal
    {
        _onSrc();

        uint256 amount = DEPOSIT_AMOUNT_UNITS * src.one;

        _prepDepositRails(
            user,
            amount
        );

        vm.prank(
            user
        );

        IWtnFlushVault(src.diamond).depositWithReferral(
            amount,
            referrer
        );

        assertEq(
            IWtnFlushVault(src.diamond).getCohortScore(referrer),
            amount,
            "referred deposit must credit the spoke book"
        );
    }

    function _flushSpoke(
        address _referrer,
        address _caller
    )
        internal
        returns (FlushWire memory wire)
    {
        _onSrc();

        FlushPlanSnapshot memory plan;

        plan.fromWeek = _cursorFromWeekOnSpoke(
            _referrer
        );

        plan.flushedAt = block.timestamp;

        address[] memory referrers = new address[](1);
        referrers[0] = _referrer;

        if (_spokeQuoteWorks(referrers) == false) {

            wire = _synthesizeFlush(
                _referrer,
                _caller,
                plan
            );

            return wire;
        }

        uint256 fee = IWtnFlushVault(src.diamond).quoteFlushFee(
            referrers
        );

        vm.deal(
            _caller,
            fee * 2 + 1 ether
        );

        vm.recordLogs();

        vm.prank(
            _caller
        );

        IWtnFlushVault(src.diamond).flushReferrals{
            value: fee * 2 + 1 ether
        }(
            referrers
        );

        assertGt(
            _caller.balance,
            0,
            "the flush must refund the excess fee"
        );

        bytes memory reconstruction = _reconstructEnvelope(
            _referrer,
            _caller,
            plan
        );

        wire = _scrapeFlushWire(
            reconstruction
        );
    }

    function _synthesizeFlush(
        address _referrer,
        address _caller,
        FlushPlanSnapshot memory _plan
    )
        internal
        returns (FlushWire memory wire)
    {
        IWtnFlushVault(src.diamond).advanceBook(
            _referrer,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        wire.payload = _reconstructEnvelope(
            _referrer,
            _caller,
            _plan
        );

        wire.messageId = keccak256(
            abi.encode(src.diamond, syntheticNonce)
        );

        syntheticNonce += 1;

        wire.synthetic = true;
    }

    function _scrapeFlushWire(
        bytes memory _reconstruction
    )
        internal
        returns (FlushWire memory wire)
    {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool expectRamp = engine == RouteEngine.OffRampShim;

        bool sentFound;
        bool rampFound;

        for (uint256 i; i < entries.length; ++i) {

            if (
                entries[i].topics[0]
                    == keccak256("CohortFlushSent(bytes32,uint64,address,uint256)")
            ) {

                if (entries[i].emitter != src.diamond) {
                    continue;
                }

                wire.messageId = entries[i].topics[1];

                sentFound = true;

                continue;
            }

            if (expectRamp == false) {
                continue;
            }

            if (
                _scrapeV2Wire(
                    entries[i],
                    _reconstruction,
                    "the wire envelope must byte-match the storage reconstruction"
                )
            ) {
                rampFound = true;

                continue;
            }

            if (entries[i].topics[0] != CCIPMessageSent.selector) {
                continue;
            }

            Internal.EVM2AnyRampMessage memory ramp = abi.decode(
                entries[i].data,
                (Internal.EVM2AnyRampMessage)
            );

            assertEq(
                keccak256(ramp.data),
                keccak256(_reconstruction),
                "the wire envelope must byte-match the storage reconstruction"
            );

            assertEq(
                _decodeAddress(ramp.receiver),
                address(hub),
                "the wire receiver must be the hub"
            );

            emit CCIPMessageSent(
                ramp.header.destChainSelector,
                ramp.header.sequenceNumber,
                ramp
            );

            rampFound = true;
        }

        require(
            sentFound,
            "CohortFlushSent not emitted on the spoke"
        );

        require(
            rampFound || expectRamp == false,
            "CCIPMessageSent log not found for the flush message"
        );

        wire.payload = _reconstruction;

        wire.synthetic = expectRamp == false;
    }

    /**
     * @dev CCIP 2.0 arm of the wire scrape: recognizes the CCV-era
     * `CCIPMessageSent` log, decodes the packed `MessageV1` wire
     * bytes through the harness codec, asserts the payload byte-match
     * and the hub receiver, and RE-EMITS the event verbatim so the
     * harness's own off-ramp scrape (which drains a fresh log
     * recording) still finds it. Returns false for any other log so
     * the 1.6 arm keeps handling the legacy lanes.
     */
    function _scrapeV2Wire(
        Vm.Log memory _entry,
        bytes memory _expectedPayload,
        string memory _payloadMismatchMessage
    )
        internal
        returns (bool)
    {
        if (_entry.topics[0] != ICcipOnRampV2Events.CCIPMessageSent.selector) {
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

        CcipV2Shapes.MessageV1 memory wireMessage = this.decodeCcipV2Message(
            encodedMessage
        );

        assertEq(
            keccak256(wireMessage.data),
            keccak256(_expectedPayload),
            _payloadMismatchMessage
        );

        assertEq(
            _decodeAddress(wireMessage.receiver),
            address(hub),
            "the wire receiver must be the hub"
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

    function _deliverAndApply(
        FlushWire memory _wire
    )
        internal
    {
        _alignDstClockToSrc();

        if (_wire.synthetic || engine == RouteEngine.RouterShim) {

            _onDst();

            vm.prank(
                dst.router
            );

            hub.ccipReceive(
                _flushDelivery(
                    _wire.messageId,
                    src.diamond,
                    _wire.payload
                )
            );
        } else {

            SentMessage memory sent;

            sent.messageId = _wire.messageId;
            sent.srcChainSelector = src.chainSelector;
            sent.dstChainSelector = dst.chainSelector;

            _onSrc();

            sent.srcOnRamp = ICcipRouterView(src.router).getOnRamp(
                dst.chainSelector
            );

            uint256 gasBefore = gasleft();

            _routeViaOffRamp(
                sent
            );

            console2.log(
                "routed flush delivery gas (test-side routing overhead included):",
                gasBefore - gasleft()
            );
        }

        _onDst();

        assertTrue(
            hub.flushCommitment(_wire.messageId) != bytes32(0),
            "the mailbox must hold the flush commitment"
        );

        hub.applyFlush(
            _wire.messageId,
            src.chainId,
            src.diamond,
            _wire.payload
        );
    }

    function _pushDesignation(
        address _owner
    )
        internal
        returns (FlushWire memory wire)
    {
        _onSrc();

        (
            address payout,
            uint256 stamp
        ) = spokeRegistry.getPayoutDesignation(
            _owner
        );

        wire.payload = abi.encode(
            uint256(1),
            _owner,
            payout,
            stamp >> 8,
            stamp & 0xff
        );

        bool quoteWorks;

        try spokeRegistry.quotePushPayoutFee(
            _owner
        ) returns (uint256) {
            quoteWorks = true;
        } catch {}

        if (quoteWorks == false) {

            wire.messageId = keccak256(
                abi.encode(address(spokeRegistry), syntheticNonce)
            );

            syntheticNonce += 1;

            wire.synthetic = true;

            return wire;
        }

        uint256 fee = spokeRegistry.quotePushPayoutFee(
            _owner
        );

        vm.deal(
            user,
            fee
        );

        vm.recordLogs();

        vm.prank(
            user
        );

        spokeRegistry.pushPayoutAddress{value: fee}(
            _owner
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool rampFound;

        for (uint256 i; i < entries.length; ++i) {

            if (
                entries[i].topics[0]
                    == keccak256("PayoutPushed(address,uint64,address,uint256,bytes32)")
            ) {

                (
                    ,
                    ,
                    bytes32 messageId
                ) = abi.decode(
                    entries[i].data,
                    (address, uint256, bytes32)
                );

                wire.messageId = messageId;

                continue;
            }

            if (engine != RouteEngine.OffRampShim) {
                continue;
            }

            if (
                _scrapeV2Wire(
                    entries[i],
                    wire.payload,
                    "the push wire must carry the strict designation payload"
                )
            ) {
                rampFound = true;

                continue;
            }

            if (entries[i].topics[0] != CCIPMessageSent.selector) {
                continue;
            }

            Internal.EVM2AnyRampMessage memory ramp = abi.decode(
                entries[i].data,
                (Internal.EVM2AnyRampMessage)
            );

            assertEq(
                keccak256(ramp.data),
                keccak256(wire.payload),
                "the push wire must carry the strict designation payload"
            );

            emit CCIPMessageSent(
                ramp.header.destChainSelector,
                ramp.header.sequenceNumber,
                ramp
            );

            rampFound = true;
        }

        if (engine == RouteEngine.OffRampShim) {

            require(
                rampFound,
                "CCIPMessageSent log not found for the push message"
            );
        } else {

            wire.synthetic = true;
        }
    }

    function _deliverPush(
        FlushWire memory _wire
    )
        internal
    {
        _alignDstClockToSrc();

        if (_wire.synthetic || engine == RouteEngine.RouterShim) {

            _onDst();

            vm.prank(
                dst.router
            );

            hub.ccipReceive(
                _flushDelivery(
                    _wire.messageId,
                    address(spokeRegistry),
                    _wire.payload
                )
            );

            return;
        }

        SentMessage memory sent;

        sent.messageId = _wire.messageId;
        sent.srcChainSelector = src.chainSelector;
        sent.dstChainSelector = dst.chainSelector;

        _onSrc();

        sent.srcOnRamp = ICcipRouterView(src.router).getOnRamp(
            dst.chainSelector
        );

        _routeViaOffRamp(
            sent
        );
    }

    function _flushDelivery(
        bytes32 _messageId,
        address _sender,
        bytes memory _payload
    )
        internal
        view
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: src.chainSelector,
            sender: abi.encode(
                _sender
            ),
            data: _payload,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _spokeQuoteWorks(
        address[] memory _referrers
    )
        internal
        returns (bool)
    {
        _onSrc();

        try IWtnFlushVault(src.diamond).quoteFlushFee(
            _referrers
        ) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _ageSpokeWeeks(
        uint256 _weekCount
    )
        internal
    {
        _onSrc();

        vm.warp(
            block.timestamp + _weekCount * CohortWeeks.WEEK
        );
    }

    function _alignDstClockToSrc()
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

    // ---- envelope reconstruction ----

    function _cursorFromWeekOnSpoke(
        address _referrer
    )
        internal
        view
        returns (uint256)
    {
        uint256 stored = IWtnFlushVault(src.diamond).getFlushedThroughWeek(
            _referrer
        );

        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        if (stored == 0) {
            return currentWeek >= CohortWeeks.MAX_SETTLE_BOUNDARIES
                ? currentWeek - CohortWeeks.MAX_SETTLE_BOUNDARIES + 1
                : 0;
        }

        return stored + 1;
    }

    function _reconstructEnvelope(
        address _referrer,
        address _deliverer,
        FlushPlanSnapshot memory _plan
    )
        internal
        view
        returns (bytes memory)
    {
        uint256 currentWeek = _plan.flushedAt / CohortWeeks.WEEK;

        uint256 count;

        for (uint256 week = _plan.fromWeek; week <= currentWeek; ++week) {

            if (_spokeCrumb(_referrer, week) != 0) {
                ++count;
            }
        }

        uint256 designationWord = _spokeDesignationWord(
            _referrer
        );

        uint256 flags = designationWord != 0
            ? CohortWeeks.FLUSH_FLAG_DESIGNATION
            : 0;

        uint256[] memory out = new uint256[](
            3 + (designationWord != 0 ? 1 : 0) + count * 2
        );

        out[0] = CohortWeeks.packFlushHeader(
            _deliverer,
            1,
            _plan.flushedAt
        );

        out[1] = CohortWeeks.packFlushEntry(
            _referrer,
            count,
            0,
            flags
        );

        out[2] = CohortWeeks.packFlushScores(
            _spokeBookSum(
                _referrer
            ),
            IWtnFlushVault(src.diamond).getTrackedContribution(
                _referrer
            )
        );

        uint256 cursor = 3;

        if (designationWord != 0) {
            out[cursor] = designationWord;
            ++cursor;
        }

        for (uint256 week = _plan.fromWeek; week <= currentWeek; ++week) {

            uint256 word = _spokeCrumb(
                _referrer,
                week
            );

            if (word == 0) {
                continue;
            }

            out[cursor] = week;
            out[cursor + 1] = IWtnFlushVault(src.diamond).getCohortWeekCrumb(
                _referrer,
                week
            );

            cursor += 2;
        }

        return abi.encodePacked(
            out
        );
    }

    function _spokeCrumb(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        return IWtnFlushVault(src.diamond).getCohortWeekCrumb(
            _referrer,
            _week
        ) & ~CohortWeeks.CRUMB_WRITTEN_BIT;
    }

    function _spokeBookSum(
        address _referrer
    )
        internal
        view
        returns (uint256)
    {
        uint256 instant = IWtnFlushVault(src.diamond).getCohortScore(
            _referrer
        );

        uint256 week = block.timestamp / CohortWeeks.WEEK;

        uint256 elapsed = block.timestamp - week * CohortWeeks.WEEK;

        uint256 current = _crumbSecondsOnSpoke(
            IWtnFlushVault(src.diamond).getCohortWeekCrumb(
                _referrer,
                week
            )
        );

        uint256 previous = _previousWeekSecondsOnSpoke(
            _referrer,
            week - 1
        );

        uint256 rolling = (
            current
                + previous * (CohortWeeks.WEEK - elapsed) / CohortWeeks.WEEK
        ) / CohortWeeks.WEEK;

        return instant < rolling
            ? instant
            : rolling;
    }

    function _previousWeekSecondsOnSpoke(
        address _referrer,
        uint256 _week
    )
        internal
        view
        returns (uint256)
    {
        uint256 crumb = IWtnFlushVault(src.diamond).getCohortWeekCrumb(
            _referrer,
            _week
        );

        if (crumb & CohortWeeks.CRUMB_WRITTEN_BIT != 0) {
            return _crumbSecondsOnSpoke(
                crumb
            );
        }

        uint256 length = IWtnFlushVault(src.diamond).getCohortGapLogLength(
            _referrer
        );

        if (length == 0) {
            return 0;
        }

        uint256 last = IWtnFlushVault(src.diamond).getCohortGapLogEntry(
            _referrer,
            length - 1
        );

        if (
            CohortWeeks.gapRecordFromWeek(last) > _week
                || _week >= CohortWeeks.gapRecordToWeek(last)
        ) {
            return 0;
        }

        return CohortWeeks.gapRecordMature(last) * CohortWeeks.WEEK;
    }

    function _crumbSecondsOnSpoke(
        uint256 _crumb
    )
        internal
        pure
        returns (uint256)
    {
        return CohortWeeks.laneY1(_crumb)
            + CohortWeeks.laneY2(_crumb)
            + CohortWeeks.laneM(_crumb);
    }

    function _spokeDesignationWord(
        address _referrer
    )
        internal
        view
        returns (uint256)
    {
        (
            address payout,
            uint256 stamp
        ) = spokeRegistry.getPayoutDesignation(
            _referrer
        );

        if (stamp == 0) {
            return 0;
        }

        return CohortWeeks.packFlushDesignation(
            payout,
            stamp >> 8,
            stamp & 0xff
        );
    }

    function _syntheticEnvelope()
        internal
        returns (bytes memory)
    {
        _onDst();

        uint256 pastWeek = block.timestamp / CohortWeeks.WEEK - 1;

        uint256[] memory out = new uint256[](5);

        out[0] = CohortWeeks.packFlushHeader(
            referrer,
            1,
            block.timestamp
        );

        out[1] = CohortWeeks.packFlushEntry(
            referrer,
            1,
            0,
            0
        );

        out[2] = CohortWeeks.packFlushScores(
            0,
            0
        );

        out[3] = pastWeek;

        out[4] = CohortWeeks.packLanes(
            src.one * CohortWeeks.WEEK,
            0,
            0
        ) | CohortWeeks.CRUMB_WRITTEN_BIT;

        return abi.encodePacked(
            out
        );
    }

    function _expectedTotalFor(
        address _referrer
    )
        internal
        returns (uint256 expected)
    {
        _onSrc();

        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        uint256 firstWeek = currentWeek >= CohortWeeks.MAX_SETTLE_BOUNDARIES
            ? currentWeek - CohortWeeks.MAX_SETTLE_BOUNDARIES + 1
            : 0;

        uint256[] memory flushedWeeks = new uint256[](
            currentWeek - firstWeek + 1
        );

        uint256[] memory words = new uint256[](
            currentWeek - firstWeek + 1
        );

        uint256 count;

        for (uint256 week = firstWeek; week <= currentWeek; ++week) {

            uint256 word = _spokeCrumb(
                _referrer,
                week
            );

            if (word == 0) {
                continue;
            }

            flushedWeeks[count] = week;
            words[count] = word;

            ++count;
        }

        _onDst();

        for (uint256 i; i < count; ++i) {

            (
                uint256 y1Bps,
                uint256 y2Bps,
                uint256 mBps
            ) = hub.weeklyRates(
                _referrer,
                flushedWeeks[i]
            );

            expected += CohortWeeks.laneY1(words[i]) * y1Bps / 10_000 / CohortWeeks.YEAR
                + CohortWeeks.laneY2(words[i]) * y2Bps / 10_000 / CohortWeeks.YEAR
                + CohortWeeks.laneM(words[i]) * mBps / 10_000 / CohortWeeks.YEAR;
        }
    }

    function _expectedCourierShareFor(
        address _referrer
    )
        internal
        returns (uint256 courierShare)
    {
        _onSrc();

        uint256 currentWeek = block.timestamp / CohortWeeks.WEEK;

        uint256 firstWeek = currentWeek >= CohortWeeks.MAX_SETTLE_BOUNDARIES
            ? currentWeek - CohortWeeks.MAX_SETTLE_BOUNDARIES + 1
            : 0;

        uint256[] memory flushedWeeks = new uint256[](
            currentWeek - firstWeek + 1
        );

        uint256[] memory words = new uint256[](
            currentWeek - firstWeek + 1
        );

        uint256 count;

        for (uint256 week = firstWeek; week <= currentWeek; ++week) {

            uint256 word = _spokeCrumb(
                _referrer,
                week
            );

            if (word == 0) {
                continue;
            }

            flushedWeeks[count] = week;
            words[count] = word;

            ++count;
        }

        _onDst();

        uint256 shareBps = hub.botShareBps();

        for (uint256 i; i < count; ++i) {

            (
                uint256 y1Bps,
                uint256 y2Bps,
                uint256 mBps
            ) = hub.weeklyRates(
                _referrer,
                flushedWeeks[i]
            );

            uint256 paid = CohortWeeks.laneY1(words[i]) * y1Bps / 10_000 / CohortWeeks.YEAR
                + CohortWeeks.laneY2(words[i]) * y2Bps / 10_000 / CohortWeeks.YEAR
                + CohortWeeks.laneM(words[i]) * mBps / 10_000 / CohortWeeks.YEAR;

            courierShare += paid * shareBps / 10_000;
        }
    }

    // ---- install ladders ----

    function _prepDepositRails(
        address _user,
        uint256 _amount
    )
        internal
    {
        ICcipBridgeVault vault = ICcipBridgeVault(
            src.diamond
        );

        if (vault.paused()) {

            vm.prank(
                src.master
            );

            vault.unpauseDeposits();
        }

        if (vault.depositsDisabled()) {

            vm.prank(
                src.master
            );

            vault.setDepositsDisabled(
                false
            );
        }

        vm.prank(
            src.master
        );

        vault.setGraceFreezeEnabled(
            false
        );

        uint256 liftedCap = vault.totalSupply() + 100 * _amount;

        vm.prank(
            src.master
        );

        vault.setTotalDepositCap(
            liftedCap
        );

        deal(
            src.usd,
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        (
            bool ok,
        ) = src.usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                src.diamond,
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );
    }

    function _installSpokeStack()
        internal
    {
        _onSrc();

        IWtnFlushVault v = IWtnFlushVault(
            src.diamond
        );

        address m = src.master;

        uint256 startTime = block.timestamp;

        address cohortHookFacet = address(
            new CohortHookFacet()
        );

        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.adminSelectors(),
            address(new AdminFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.userSelectors(),
            address(new UserFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.permit2Selectors(),
            address(new Permit2UserFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.moveSelectors(),
            address(new MoveFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.bridgeSelectors(),
            address(new BridgeFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors(),
            address(new QueueJoinLeaveFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors(),
            address(new QueueFulfillFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.referralSelectors(),
            address(new ReferralFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors(),
            address(new Permit2ReferralFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors(),
            address(new CohortRecorderFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors(),
            address(new CohortBridgeHookFacet())
        );
        _proposeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.cohortFlushSelectors(),
            address(new CohortFlushFacet())
        );

        vm.prank(
            m
        );

        v.proposeTransferHookFacet(
            cohortHookFacet
        );

        vm.warp(
            startTime + 3 days + 1
        );

        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.adminSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.userSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.permit2Selectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.moveSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.queueJoinLeaveSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.queueFulfillSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()
        );
        _executeGroup(
            v,
            m,
            WiseTelecomNodesDiamondSelectors.cohortFlushSelectors()
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
            "settle-aware transfer hook not installed"
        );

        spokeRegistry = new ReferralRegistry(
            address(this),
            _spokeChainRank()
        );

        spokeRegistry.setAllowedVault(
            src.diamond,
            true
        );

        spokeRegistry.setCcipRouter(
            src.router
        );

        uint256 pointerTime = block.timestamp;

        vm.prank(
            m
        );

        v.proposeReferralRegistry(
            address(spokeRegistry)
        );

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

        vm.prank(
            m
        );

        v.setCohortSyncEnabled(
            true
        );
    }

    function _installHubSide()
        internal
    {
        _onDst();

        string memory json = vm.readFile(
            "config/vault.usdc.mainnet.json"
        );

        payoutDiamond = vm.parseJsonAddress(
            json,
            ".diamond"
        );

        require(
            payoutDiamond.code.length > 0,
            "usdc mainnet diamond not deployed on the hub fork"
        );

        IWtnFlushVault payoutVault = IWtnFlushVault(
            payoutDiamond
        );

        payoutUsd = payoutVault.USD_TOKEN();

        address m = payoutVault.master();

        uint256 startTime = block.timestamp;

        _proposeGroup(
            payoutVault,
            m,
            WiseTelecomNodesDiamondSelectors.adminSelectors(),
            address(new AdminFacet())
        );
        _proposeGroup(
            payoutVault,
            m,
            WiseTelecomNodesDiamondSelectors.sweepSelectors(),
            address(new SweepFacet())
        );
        _proposeGroup(
            payoutVault,
            m,
            WiseTelecomNodesDiamondSelectors.referralPayoutSelectors(),
            address(new ReferralPayoutFacet())
        );

        vm.warp(
            startTime + 3 days + 1
        );

        _executeGroup(
            payoutVault,
            m,
            WiseTelecomNodesDiamondSelectors.adminSelectors()
        );
        _executeGroup(
            payoutVault,
            m,
            WiseTelecomNodesDiamondSelectors.sweepSelectors()
        );
        _executeGroup(
            payoutVault,
            m,
            WiseTelecomNodesDiamondSelectors.referralPayoutSelectors()
        );

        vm.warp(
            startTime + 2
        );

        hub = new ReferralHub(
            payoutUsd
        );

        uint256 pointerTime = block.timestamp;

        vm.prank(
            m
        );

        payoutVault.proposePayoutHub(
            address(hub)
        );

        vm.warp(
            pointerTime + 3 days + 1
        );

        vm.prank(
            m
        );

        payoutVault.executePayoutHubChange();

        vm.warp(
            pointerTime + 2
        );

        hub.setPayoutVault(
            payoutDiamond
        );

        hub.setCcipRouter(
            dst.router
        );

        hub.setFlushSource(
            src.chainSelector,
            src.diamond,
            src.chainId
        );

        hub.setDesignationSource(
            src.chainSelector,
            address(spokeRegistry),
            src.chainId
        );
    }

    function _wireSpokePointers()
        internal
    {
        _onSrc();

        IWtnFlushVault v = IWtnFlushVault(
            src.diamond
        );

        address m = src.master;

        uint256 pointerTime = block.timestamp;

        vm.prank(
            m
        );

        v.proposeFlushHub(
            address(hub),
            dst.chainSelector
        );

        vm.prank(
            m
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.FlushHubTimelockNotElapsed.selector
        );

        v.executeFlushHubChange();

        vm.warp(
            pointerTime + 3 days + 1
        );

        vm.prank(
            m
        );

        v.executeFlushHubChange();

        vm.warp(
            pointerTime + 2
        );

        (
            address wiredHub,
            uint64 wiredSelector
        ) = v.getFlushHub();

        assertEq(
            wiredHub,
            address(hub),
            "flush hub pointer not wired"
        );

        assertEq(
            uint256(wiredSelector),
            uint256(dst.chainSelector),
            "flush hub selector not wired"
        );

        spokeRegistry.proposePayoutHub(
            address(hub),
            dst.chainSelector
        );

        spokeRegistry.executePayoutHubChange();

        assertEq(
            spokeRegistry.payoutHub(),
            address(hub),
            "registry payout route not wired"
        );
    }

    function _proposeGroup(
        IWtnFlushVault _v,
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
        IWtnFlushVault _v,
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

/**
 * @dev End-to-end scenario layer of the flush-transport rehearsal,
 * split from the helpers-only {CohortFlushUpgradeForkBase} so that
 * sibling suites reusing the install ladders and wire helpers (the
 * operator-bot ordering rehearsal) inherit the base WITHOUT
 * re-registering these four lane E2Es: running them twice per
 * lane would double the live-RPC cost and double the exposure to
 * parallel tests warping the same shared destination fork clock.
 */
abstract contract CohortFlushUpgradeForkE2E is CohortFlushUpgradeForkBase {

    // ---- scenarios ----

    function test_flushUpgrade_referredFlushEndToEndWithRealClaim()
        public
    {
        if (_laneUsable() == false) {

            vm.skip(
                true
            );

            return;
        }

        _referredDepositOnSpoke();

        _ageSpokeWeeks(
            2
        );

        FlushWire memory first = _flushSpoke(
            referrer,
            referrer
        );

        _deliverAndApply(
            first
        );

        _onDst();

        assertEq(
            hub.globalReferredScore(referrer),
            DEPOSIT_AMOUNT_UNITS * src.one,
            "first flush must land the absolute referred score"
        );

        assertEq(
            hub.claimable(src.chainId, referrer),
            0,
            "weeks before the score checkpoint must price at zero"
        );

        _ageSpokeWeeks(
            3
        );

        FlushWire memory second = _flushSpoke(
            referrer,
            referrer
        );

        _deliverAndApply(
            second
        );

        uint256 expected = _expectedTotalFor(
            referrer
        );

        _onDst();

        uint256 entitled = hub.claimable(
            src.chainId,
            referrer
        );

        assertEq(
            entitled,
            expected,
            "claimable must equal the frozen-rate pricing of every flushed crumb"
        );

        assertGt(
            entitled,
            0,
            "aged weeks past the dwell window must price at real rates"
        );

        assertEq(
            ReferralPayoutFacet(payoutDiamond).getPendingReferralPayout(),
            entitled,
            "the priced money must be booked as liability on the live payout vault"
        );

        uint256 poolBefore = IUsdBalance(payoutUsd).balanceOf(
            payoutDiamond
        );

        vm.prank(
            referrer
        );

        hub.claim(
            src.chainId,
            referrer
        );

        assertEq(
            IUsdBalance(payoutUsd).balanceOf(referrer),
            entitled,
            "claim must pay the referrer in the payout vault's real underlying"
        );

        assertEq(
            IUsdBalance(payoutUsd).balanceOf(payoutDiamond),
            poolBefore - entitled,
            "funding must come out of the live vault's USD pool"
        );

        assertEq(
            ReferralPayoutFacet(payoutDiamond).getPendingReferralPayout(),
            0,
            "funding must lower the booked liability to zero"
        );

        uint256 accruedBefore = hub.totalAccrued();

        hub.applyFlush(
            second.messageId,
            src.chainId,
            src.diamond,
            second.payload
        );

        assertEq(
            hub.totalAccrued(),
            accruedBefore,
            "re-applying the same envelope must accrue nothing"
        );

        assertEq(
            hub.claimable(src.chainId, referrer),
            0,
            "re-applying after the claim must not resurrect the balance"
        );
    }

    function test_flushUpgrade_botFlushSplitsCourierShare()
        public
    {
        if (_laneUsable() == false) {

            vm.skip(
                true
            );

            return;
        }

        _referredDepositOnSpoke();

        _ageSpokeWeeks(
            2
        );

        _deliverAndApply(
            _flushSpoke(
                referrer,
                referrer
            )
        );

        _ageSpokeWeeks(
            3
        );

        _onSrc();

        vm.prank(
            ICcipBridgeVault(src.diamond).master()
        );

        IWtnFlushVault(src.diamond).setAllowedFlushBot(
            bot,
            true
        );

        FlushWire memory wire = _flushSpoke(
            referrer,
            bot
        );

        _deliverAndApply(
            wire
        );

        uint256 expected = _expectedTotalFor(
            referrer
        );

        uint256 courierShare = _expectedCourierShareFor(
            referrer
        );

        _onDst();

        assertEq(
            hub.claimable(src.chainId, bot),
            courierShare,
            "the stamped courier must earn the delivery share"
        );

        assertEq(
            hub.claimable(src.chainId, referrer),
            expected - courierShare,
            "the referrer must earn the remainder"
        );

        assertGt(
            courierShare,
            0,
            "the rehearsed delivery must be large enough to split"
        );

        vm.prank(
            bot
        );

        hub.claim(
            src.chainId,
            bot
        );

        assertEq(
            IUsdBalance(payoutUsd).balanceOf(bot),
            courierShare,
            "the courier must claim its share in real USD"
        );
    }

    function test_flushUpgrade_designationPiggybackAndPush()
        public
    {
        if (_laneUsable() == false) {

            vm.skip(
                true
            );

            return;
        }

        _referredDepositOnSpoke();

        _ageSpokeWeeks(
            2
        );

        address payoutOne = makeAddr(
            "flushForkPayoutOne"
        );

        address payoutTwo = makeAddr(
            "flushForkPayoutTwo"
        );

        _onSrc();

        vm.prank(
            referrer
        );

        spokeRegistry.setPayoutAddress(
            payoutOne
        );

        _deliverAndApply(
            _flushSpoke(
                referrer,
                referrer
            )
        );

        _onDst();

        assertEq(
            hub.payoutAddressOf(src.chainId, referrer),
            payoutOne,
            "the flush envelope must piggyback the registry designation"
        );

        _onSrc();

        vm.warp(
            block.timestamp + 1 hours
        );

        vm.prank(
            referrer
        );

        spokeRegistry.setPayoutAddress(
            payoutTwo
        );

        FlushWire memory push = _pushDesignation(
            referrer
        );

        _deliverPush(
            push
        );

        _onDst();

        assertEq(
            hub.payoutAddressOf(src.chainId, referrer),
            payoutTwo,
            "the caller-paid push must apply latest-wins over the piggyback"
        );

        _ageSpokeWeeks(
            3
        );

        _deliverAndApply(
            _flushSpoke(
                referrer,
                referrer
            )
        );

        _onDst();

        assertEq(
            hub.payoutAddressOf(src.chainId, referrer),
            payoutTwo,
            "a later flush carrying the same designation must stay latest-wins"
        );

        uint256 entitled = hub.claimable(
            src.chainId,
            referrer
        );

        assertGt(
            entitled,
            0,
            "aged weeks must have priced before the designated claim"
        );

        vm.prank(
            referrer
        );

        hub.claim(
            src.chainId,
            referrer
        );

        assertEq(
            IUsdBalance(payoutUsd).balanceOf(payoutTwo),
            entitled,
            "the claim must pay the designated payout address in real USD"
        );
    }

    function test_flushUpgrade_hostileReceiveRejected()
        public
    {
        _onDst();

        bytes memory payload = _syntheticEnvelope();

        bytes32 messageId = keccak256(
            abi.encode(src.diamond, syntheticNonce)
        );

        syntheticNonce += 1;

        vm.prank(
            makeAddr(
                "flushForkStranger"
            )
        );

        vm.expectRevert(
            ReferralHubDeclarations.NotCcipRouter.selector
        );

        hub.ccipReceive(
            _flushDelivery(
                messageId,
                src.diamond,
                payload
            )
        );

        vm.prank(
            dst.router
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushSource.selector
        );

        hub.ccipReceive(
            _flushDelivery(
                messageId,
                makeAddr("flushForkUnknownVault"),
                payload
            )
        );

        vm.prank(
            dst.router
        );

        hub.ccipReceive(
            _flushDelivery(
                messageId,
                src.diamond,
                payload
            )
        );

        vm.prank(
            dst.router
        );

        vm.expectRevert(
            ReferralHubDeclarations.FlushAlreadyReceived.selector
        );

        hub.ccipReceive(
            _flushDelivery(
                messageId,
                src.diamond,
                payload
            )
        );

        bytes memory tampered = bytes.concat(
            payload
        );

        tampered[tampered.length - 1] = 0xFF;

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushCommitment.selector
        );

        hub.applyFlush(
            messageId,
            src.chainId,
            src.diamond,
            tampered
        );

        hub.applyFlush(
            messageId,
            src.chainId,
            src.diamond,
            payload
        );
    }
}

contract CohortFlushUsdcBaseMainnetFork is CohortFlushUpgradeForkE2E {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdc",
            srcNetwork: "base",
            dstNetwork: "mainnet",
            srcRpc: "base",
            dstRpc: "mainnet"
        });
    }

    function _spokeChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 1;
    }
}

contract CohortFlushUsdgArbitrumMainnetFork is CohortFlushUpgradeForkE2E {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdg",
            srcNetwork: "arbitrum",
            dstNetwork: "mainnet",
            srcRpc: "arbitrum",
            dstRpc: "mainnet"
        });
    }

    function _spokeChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 2;
    }
}

contract CohortFlushUsdgRobinhoodMainnetFork is CohortFlushUpgradeForkE2E {

    function _laneConfig()
        internal
        pure
        override
        returns (LaneCfg memory)
    {
        return LaneCfg({
            product: "usdg",
            srcNetwork: "robinhood",
            dstNetwork: "mainnet",
            srcRpc: "robinhood",
            dstRpc: "mainnet"
        });
    }

    function _spokeChainRank()
        internal
        pure
        override
        returns (uint256)
    {
        return 3;
    }
}

/**
 * @dev Three-fork mesh proof of the reserved remote source-key
 * encoding: CREATE3 gives the usdc product the SAME diamond address
 * on base and arbitrum, so an address-keyed hub would collapse both
 * spokes into one book, the exact collision the hashed
 * `keccak256(chainId, vault)` source keys and the per-source-chain
 * claimable/designation buckets exist to prevent. The test grounds
 * the premise on real forks (identical vault address, live bytecode
 * on both spokes), then drives the REAL hub on a mainnet fork with
 * envelopes and designation pushes delivered under the two spokes'
 * real chain selectors from that one shared sender address, and
 * proves every register keeps the two chains apart while the global
 * score aggregation still sums across them.
 */
contract CcipFlushMeshFork is Test {

    uint256 internal constant BASE_CHAIN_ID = 8_453;

    uint256 internal constant ARB_CHAIN_ID = 42_161;

    address internal vaultAddr;

    address internal baseRegistry = address(0xA1);

    address internal arbRegistry = address(0xA2);

    address internal referrer = address(0xB1);

    uint64 internal baseSelector;

    uint64 internal arbSelector;

    address internal mainnetRouter;

    ReferralHub internal hub;

    uint256 internal meshNonce;

    function setUp()
        public
    {
        address baseVault = vm.parseJsonAddress(
            vm.readFile("config/vault.usdc.base.json"),
            ".diamond"
        );

        address arbVault = vm.parseJsonAddress(
            vm.readFile("config/vault.usdc.arbitrum.json"),
            ".diamond"
        );

        assertEq(
            baseVault,
            arbVault,
            "the CREATE3 premise: one usdc vault address on both spokes"
        );

        vaultAddr = baseVault;

        baseSelector = uint64(
            vm.parseUint(
                vm.parseJsonString(
                    vm.readFile("config/ccip.base.json"),
                    ".chainSelector"
                )
            )
        );

        arbSelector = uint64(
            vm.parseUint(
                vm.parseJsonString(
                    vm.readFile("config/ccip.arbitrum.json"),
                    ".chainSelector"
                )
            )
        );

        mainnetRouter = vm.parseJsonAddress(
            vm.readFile("config/ccip.mainnet.json"),
            ".router"
        );

        uint256 baseFork = vm.createFork(
            "base"
        );

        uint256 arbFork = vm.createFork(
            "arbitrum"
        );

        uint256 mainFork = vm.createFork(
            "mainnet"
        );

        vm.selectFork(
            baseFork
        );

        require(
            vaultAddr.code.length > 0,
            "usdc vault not live on the base fork"
        );

        vm.selectFork(
            arbFork
        );

        require(
            vaultAddr.code.length > 0,
            "usdc vault not live on the arbitrum fork"
        );

        vm.selectFork(
            mainFork
        );

        address usd = IWtnFlushVault(
            vm.parseJsonAddress(
                vm.readFile("config/vault.usdc.mainnet.json"),
                ".diamond"
            )
        ).USD_TOKEN();

        hub = new ReferralHub(
            usd
        );

        hub.setCcipRouter(
            mainnetRouter
        );

        hub.setFlushSource(
            baseSelector,
            vaultAddr,
            BASE_CHAIN_ID
        );

        hub.setFlushSource(
            arbSelector,
            vaultAddr,
            ARB_CHAIN_ID
        );

        hub.setDesignationSource(
            baseSelector,
            baseRegistry,
            BASE_CHAIN_ID
        );

        hub.setDesignationSource(
            arbSelector,
            arbRegistry,
            ARB_CHAIN_ID
        );
    }

    function test_mesh_sameVaultAddressKeysSeparateSources()
        public
    {
        uint256 baseScore = 6_000 * 1e6;

        uint256 arbScore = 20_000 * 1e6;

        _deliverAndApply(
            baseSelector,
            BASE_CHAIN_ID,
            baseScore
        );

        _deliverAndApply(
            arbSelector,
            ARB_CHAIN_ID,
            arbScore
        );

        assertEq(
            hub.globalReferredScore(referrer),
            baseScore + arbScore,
            "global scores must sum across the two hashed sources"
        );

        bytes32 baseKey = keccak256(
            abi.encode(BASE_CHAIN_ID, vaultAddr)
        );

        bytes32 arbKey = keccak256(
            abi.encode(ARB_CHAIN_ID, vaultAddr)
        );

        assertTrue(
            baseKey != arbKey,
            "the hashed source keys must differ for one shared address"
        );

        assertGt(
            hub.appliedScoreStamp(baseKey, referrer),
            0,
            "the base source must have its own score stamp register"
        );

        assertGt(
            hub.appliedScoreStamp(arbKey, referrer),
            0,
            "the arbitrum source must have its own score stamp register"
        );

        _deliverAndApply(
            baseSelector,
            BASE_CHAIN_ID,
            0
        );

        assertEq(
            hub.globalReferredScore(referrer),
            arbScore,
            "a base clamp-to-zero must leave the arbitrum contribution intact"
        );
    }

    function test_mesh_designationsStayPerChain()
        public
    {
        address basePayout = address(0xC1);

        address arbPayout = address(0xC2);

        _pushDesignationFrom(
            baseSelector,
            baseRegistry,
            basePayout,
            block.timestamp
        );

        _pushDesignationFrom(
            arbSelector,
            arbRegistry,
            arbPayout,
            block.timestamp
        );

        assertEq(
            hub.payoutAddressOf(BASE_CHAIN_ID, referrer),
            basePayout,
            "the base designation must fill only the base bucket"
        );

        assertEq(
            hub.payoutAddressOf(ARB_CHAIN_ID, referrer),
            arbPayout,
            "the arbitrum designation must fill only the arbitrum bucket"
        );

        _pushDesignationFrom(
            baseSelector,
            baseRegistry,
            address(0xC3),
            block.timestamp - 2 hours
        );

        assertEq(
            hub.payoutAddressOf(BASE_CHAIN_ID, referrer),
            basePayout,
            "a staler base push must lose latest-wins in its own bucket"
        );

        vm.prank(
            mainnetRouter
        );

        vm.expectRevert(
            ReferralHubDeclarations.UnknownFlushSource.selector
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: keccak256(abi.encode(meshNonce)),
                sourceChainSelector: baseSelector,
                sender: abi.encode(arbRegistry),
                data: _designationPayload(address(0xC4), block.timestamp),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }

    function _deliverAndApply(
        uint64 _selector,
        uint256 _chainId,
        uint256 _referredScore
    )
        internal
    {
        uint256[] memory out = new uint256[](3);

        out[0] = CohortWeeks.packFlushHeader(
            referrer,
            1,
            block.timestamp
        );

        out[1] = CohortWeeks.packFlushEntry(
            referrer,
            0,
            0,
            0
        );

        out[2] = CohortWeeks.packFlushScores(
            _referredScore,
            0
        );

        bytes memory payload = abi.encodePacked(
            out
        );

        bytes32 messageId = keccak256(
            abi.encode(_selector, meshNonce)
        );

        meshNonce += 1;

        vm.prank(
            mainnetRouter
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: messageId,
                sourceChainSelector: _selector,
                sender: abi.encode(vaultAddr),
                data: payload,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        hub.applyFlush(
            messageId,
            _chainId,
            vaultAddr,
            payload
        );
    }

    function _pushDesignationFrom(
        uint64 _selector,
        address _registry,
        address _payout,
        uint256 _setAt
    )
        internal
    {
        vm.prank(
            mainnetRouter
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: keccak256(abi.encode(_selector, _registry, meshNonce)),
                sourceChainSelector: _selector,
                sender: abi.encode(_registry),
                data: _designationPayload(_payout, _setAt),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        meshNonce += 1;
    }

    function _designationPayload(
        address _payout,
        uint256 _setAt
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            uint256(1),
            referrer,
            _payout,
            _setAt,
            uint256(1)
        );
    }
}
