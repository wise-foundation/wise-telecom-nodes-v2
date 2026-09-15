// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReferralHubMailbox} from "./ReferralHubMailbox.sol";
import {IReferralPayoutVault} from "./IReferralPayoutVault.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";
import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev The mainnet hub (scoreboard + paymaster) of the
 * referral commission system: ONE standalone deployed contract
 * closing the chain Declarations → Checkpoints → Rates →
 * Intake. Score aggregation, weekly checkpoint history, crumb/gap
 * pricing into claimable balances, and the payout rail (claims,
 * liability booking, funding pulls) all live in this one contract.
 * Year-1 pays the tier ladder capped at
 * 10%; year-2 (500 bps) and mature (100 bps) rates pay only in weeks
 * where the referrer's uncapped ladder sum reaches the cap; all
 * three knobs week-versioned behind `pushRateTable`.
 *
 * Payout rail: referrers claim the vault's USD at this hub, keyed
 * per (source chain, referrer): each chain's payout designation
 * moves only money earned on the chain where control of the address
 * was proven, so a same-address stranger on another chain can never
 * redirect it; score and rate aggregation stay global per address.
 * Freshly priced commission books as liability on the payout vault
 * (one `raisePendingReferralPayout` per delivery batch, measured as
 * the `totalAccrued − totalBooked` delta so pre-wiring accrual
 * catches up on the first booking; `bookLiability` is the
 * permissionless catch-up poke). A claim pays the resolved payout
 * address and pulls any shortfall through the vault's hub-gated
 * `fundReferralPayout` in the same transaction; the pot is the
 * vault's USD pool, `claim()` reverts when the full balance cannot
 * be covered and `claimUpTo` pays any covered amount.
 * `setPayoutAddress` designates where claims pay (default self;
 * `msg.sender` is the whole proof, stamped `setAt << 8 | chainRank`
 * so transported designations apply latest-wins against it); the
 * claim trigger is the referrer or the resolved payout address
 * itself; funds can never be directed anywhere else.
 * `totalAccrued − totalClaimed` equals the outstanding claimable
 * sum, and `totalAccrued − totalBooked` the not-yet-booked
 * liability, so the accrual anchor stays monotonic.
 *
 * Score honesty: reports expire after `REPORT_FRESHNESS_WEEKS`
 * without a refresh, the referred aggregate sums the fresh reports
 * (each already time-weighted over the last seven days by the
 * reporting vault) and the self aggregate takes the largest fresh
 * self report (an own stake sits in one vault at a time). A stake
 * relocated between vaults therefore counts once, and a vacated
 * source stops counting on its own even though an emptied book is
 * never worth flushing.
 * `sourceCountOf` / `sourceOfAt` enumerate a referrer's sources and
 * `lastReportWeekOf` exposes the freshness stamp.
 *
 * Cross-chain transport is live: the hub is its own CCIP endpoint
 * ({ReferralHubMailbox}). Spoke vault envelopes commit into the
 * mailbox on receive and apply lazily and permissionlessly through
 * `applyFlush` under `keccak256(chainId, vault)` source keys; spoke
 * registry designation pushes apply inline; both source classes are
 * master-registered (chain selector, sender, chain id) triples.
 * Remote deliveries thread their origin chain into the claimable
 * keying, and the courier share (`botShareBps`, deducted at
 * delivery pricing for remote non-own-book entries) credits the
 * envelope's stamped deliverer in its own source-chain bucket. The
 * hub-chain vaults report through the same reporter surface below;
 * their flush facet runs in local direct-call mode. Source keys
 * are readable through `sourceKeyOf` (the address-padded local key
 * for hub-chain reporters, `keccak256(chainId, vault)` for spokes),
 * and `paidCursorAtSource` / `lastReportOfSource` expose the
 * per-source paid state either class writes, so a keeper needs no
 * log index to price what a flush would still earn (the range and
 * batch readers `paidCursorsAtSource`, `weeklyRatesRange` and
 * `claimableOf` return whole windows in one call; cursor words keep
 * the crumb lane geometry, three 80-bit lanes); every courier
 * share event carries the applied envelope's message id (zero for
 * local deliveries, which never split).
 *
 * Deliberately outside this contract:
 * - Sybil countermeasure: attaches inside `_weeklyRates` as a
 *   policy-module change only.
 * - Per-event inline reporting on the hub-chain vaults (score
 *   deltas pushed inside every user flow rather than at flush
 *   time) remains a policy choice: the reporter surface is ready,
 *   the vaults' hot paths deliberately do not pay for it today.
 *
 * Threat model: master (two-step {OwnableMaster}) governs the
 * reporter allowlist, future rate tables and the future-week-only
 * dwell-min schedule: every rate lever is week-versioned and
 * future-only, so the pricing of any week whose opening boundary has
 * passed is a pure function of frozen data and can never change,
 * even for master. Master can NEVER
 * touch scores, cursors, checkpoints or claimables
 * directly. Master additionally wires the payout vault pointer
 * (`setPayoutVault`), a lever over where liability books and
 * funding pulls from, never over balances: every USD transfer out
 * of the hub goes to a claim's resolved payout address, and the
 * vault side bounds funding to the booked liability behind its own
 * timelocked hub gate. Reporters are trusted for their OWN source's
 * data only;
 * cursors and per-source score diffs contain a malicious reporter's
 * blast radius to its own source key. Claims follow
 * checks-effects-interactions: balances zero before the funding
 * pull and the payout transfer, so reentering finds nothing left.
 */
contract ReferralHub is
    ReferralHubMailbox,
    IAny2EVMMessageReceiver,
    IERC165
{
    using SafeERC20 for IERC20;

    IERC20 public immutable USD_TOKEN;

    modifier onlyReporter() {
        require(
            allowedReporter[msg.sender],
            NotReporter()
        );
        _;
    }

    constructor(
        address _usdToken
    )
        OwnableMaster(
            msg.sender
        )
    {
        require(
            _usdToken != ZERO_ADDRESS,
            ZeroAddress()
        );

        USD_TOKEN = IERC20(
            _usdToken
        );

        _seedGenesisDwellMin();

        _seedGenesisRateTable();

        botShareBps = GENESIS_BOT_SHARE_BPS;

        emit BotShareBpsSet(
            GENESIS_BOT_SHARE_BPS
        );
    }

    function reportScores(
        address _referrer,
        uint256 _referredScore,
        uint256 _selfScore
    )
        external
        onlyReporter
    {
        require(
            _referrer != ZERO_ADDRESS,
            ZeroAddress()
        );

        bytes32 source = _sourceKey(
            msg.sender
        );

        _applyScoreReport(
            source,
            _referrer,
            _referredScore,
            _selfScore
        );
    }

    function deliverCrumbs(
        address _referrer,
        uint256[] calldata _weeks,
        uint256[] calldata _words
    )
        external
        onlyReporter
    {
        require(
            _weeks.length == _words.length,
            LengthMismatch()
        );

        require(
            _weeks.length <= CohortWeeks.MAX_SETTLE_BOUNDARIES,
            BatchTooLarge()
        );

        bytes32 source = _sourceKey(
            msg.sender
        );

        for (uint256 i; i < _weeks.length; ++i) {

            _deliverCrumb(
                source,
                _referrer,
                _weeks[i],
                _words[i],
                _localOrigin()
            );
        }

        _bookAccrual();
    }

    function deliverGap(
        address _referrer,
        uint256 _record,
        uint256 _fromWeek,
        uint256 _maxWeeks
    )
        external
        onlyReporter
    {
        bytes32 source = _sourceKey(
            msg.sender
        );

        _deliverGap(
            source,
            _referrer,
            _record,
            _fromWeek,
            _maxWeeks,
            _localOrigin()
        );

        _bookAccrual();
    }

    function ccipReceive(
        Client.Any2EVMMessage calldata _message
    )
        external
    {
        require(
            msg.sender == ccipRouter,
            NotCcipRouter()
        );

        uint64 srcChainSelector = _message.sourceChainSelector;

        address srcSender = abi.decode(
            _message.sender,
            (address)
        );

        uint256 chainId = flushSourceChainId[srcChainSelector][srcSender];

        if (chainId != 0) {

            _receiveFlush(
                _message.messageId,
                srcChainSelector,
                srcSender,
                chainId,
                _message.data
            );

            return;
        }

        chainId = designationSourceChainId[srcChainSelector][srcSender];

        require(
            chainId != 0,
            UnknownFlushSource()
        );

        _receiveDesignationPush(
            srcChainSelector,
            chainId,
            _message.data
        );
    }

    function applyFlush(
        bytes32 _messageId,
        uint256 _chainId,
        address _vault,
        bytes calldata _payload
    )
        external
    {
        _applyFlushEnvelope(
            _messageId,
            _chainId,
            _vault,
            _payload
        );
    }

    function supportsInterface(
        bytes4 _interfaceId
    )
        external
        pure
        returns (bool)
    {
        return _interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || _interfaceId == type(IERC165).interfaceId;
    }

    function setCcipRouter(
        address _router
    )
        external
        onlyMaster
    {
        require(
            _router != ZERO_ADDRESS,
            ZeroAddress()
        );

        require(
            ccipRouter == ZERO_ADDRESS,
            RouterAlreadySet()
        );

        ccipRouter = _router;

        emit CcipRouterSet(
            _router
        );
    }

    function setFlushSource(
        uint64 _chainSelector,
        address _vault,
        uint256 _chainId
    )
        external
        onlyMaster
    {
        require(
            _vault != ZERO_ADDRESS,
            ZeroAddress()
        );

        flushSourceChainId[_chainSelector][_vault] = _chainId;

        emit FlushSourceSet(
            _chainSelector,
            _vault,
            _chainId
        );
    }

    function setDesignationSource(
        uint64 _chainSelector,
        address _registry,
        uint256 _chainId
    )
        external
        onlyMaster
    {
        require(
            _registry != ZERO_ADDRESS,
            ZeroAddress()
        );

        designationSourceChainId[_chainSelector][_registry] = _chainId;

        emit DesignationSourceSet(
            _chainSelector,
            _registry,
            _chainId
        );
    }

    function setBotShareBps(
        uint256 _botShareBps
    )
        external
        onlyMaster
    {
        require(
            _botShareBps <= BPS_DENOMINATOR,
            BotShareTooHigh()
        );

        botShareBps = _botShareBps;

        emit BotShareBpsSet(
            _botShareBps
        );
    }

    function claim(
        uint256 _chainId,
        address _referrer
    )
        external
    {
        uint256 amount = claimable[_chainId][_referrer];

        require(
            amount > 0,
            NothingClaimable()
        );

        _payClaim(
            _chainId,
            _referrer,
            amount
        );
    }

    function claimUpTo(
        uint256 _chainId,
        address _referrer,
        uint256 _amount
    )
        external
    {
        uint256 entitled = claimable[_chainId][_referrer];

        uint256 amount = _amount < entitled
            ? _amount
            : entitled;

        require(
            amount > 0,
            NothingClaimable()
        );

        uint256 covered = USD_TOKEN.balanceOf(
            address(this)
        ) + _fundableAmount();

        if (amount > covered) {
            amount = covered;
        }

        require(
            amount > 0,
            PotDry()
        );

        _payClaim(
            _chainId,
            _referrer,
            amount
        );
    }

    function bookLiability()
        external
    {
        _bookAccrual();
    }

    /**
     * @dev Wires the vault that liability books against and funding
     * pulls from. Zero unwires the rail back to accrual-only mode:
     * pricing keeps accruing claimables, but nothing books and claims
     * cannot pull funding. Rotating the vault does not migrate
     * already-booked liability: `totalBooked` stays with the old
     * vault, the new vault starts unbooked while outstanding
     * claimables persist, so claims exceeding the hub balance revert
     * until the new vault is funded or reconciled.
     */
    function setPayoutVault(
        address _vault
    )
        external
        onlyMaster
    {
        payoutVault = _vault;

        emit PayoutVaultSet(
            _vault
        );
    }

    function pushRateTable(
        RateTable calldata _table
    )
        external
        onlyMaster
    {
        _pushRateTable(
            _table
        );
    }

    function setAllowedReporter(
        address _reporter,
        bool _allowed
    )
        external
        onlyMaster
    {
        require(
            _reporter != ZERO_ADDRESS,
            ZeroAddress()
        );

        allowedReporter[_reporter] = _allowed;

        emit ReporterAllowedSet(
            _reporter,
            _allowed
        );
    }

    function scheduleDwellMin(
        uint256 _effectiveFromWeek,
        bool _enabled
    )
        external
        onlyMaster
    {
        _scheduleDwellMin(
            _effectiveFromWeek,
            _enabled
        );
    }

    function setPayoutAddress(
        address _payout
    )
        external
    {
        payoutAddress[block.chainid][msg.sender] = _payout;

        payoutStamp[block.chainid][msg.sender] = block.timestamp << PAYOUT_STAMP_SHIFT;

        emit PayoutAddressSet(
            block.chainid,
            msg.sender,
            _payout
        );
    }

    function payoutAddressOf(
        uint256 _chainId,
        address _owner
    )
        external
        view
        returns (address)
    {
        return _resolvedPayout(
            _chainId,
            _owner
        );
    }

    function lastReportOf(
        address _reporter,
        address _referrer
    )
        external
        view
        returns (
            uint256 referredScore,
            uint256 selfScore
        )
    {
        uint256 packed = lastSourceReport[_sourceKey(_reporter)][_referrer];

        return (
            (packed >> REPORT_REFERRED_SHIFT) & REPORT_REFERRED_MASK,
            packed & REPORT_VALUE_MASK
        );
    }

    function paidCursorAt(
        address _reporter,
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        )
    {
        uint256 word = paidCursor[_sourceKey(_reporter)][_referrer][_week];

        return (
            CohortWeeks.laneY1(word),
            CohortWeeks.laneY2(word),
            CohortWeeks.laneM(word)
        );
    }

    function sourceKeyOf(
        uint256 _chainId,
        address _vault
    )
        external
        view
        returns (bytes32)
    {
        if (_chainId == block.chainid) {
            return _sourceKey(
                _vault
            );
        }

        return keccak256(
            abi.encode(
                _chainId,
                _vault
            )
        );
    }

    function lastReportOfSource(
        bytes32 _source,
        address _referrer
    )
        external
        view
        returns (
            uint256 referredScore,
            uint256 selfScore
        )
    {
        uint256 packed = lastSourceReport[_source][_referrer];

        return (
            (packed >> REPORT_REFERRED_SHIFT) & REPORT_REFERRED_MASK,
            packed & REPORT_VALUE_MASK
        );
    }

    function lastReportWeekOf(
        bytes32 _source,
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return lastSourceReport[_source][_referrer] >> REPORT_WEEK_SHIFT;
    }

    function sourceCountOf(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return sourcesOf[_referrer].length;
    }

    function sourceOfAt(
        address _referrer,
        uint256 _index
    )
        external
        view
        returns (bytes32)
    {
        return sourcesOf[_referrer][_index];
    }

    function paidCursorAtSource(
        bytes32 _source,
        address _referrer,
        uint256 _week
    )
        external
        view
        returns (
            uint256 y1Cursor,
            uint256 y2Cursor,
            uint256 mCursor
        )
    {
        uint256 word = paidCursor[_source][_referrer][_week];

        return (
            CohortWeeks.laneY1(word),
            CohortWeeks.laneY2(word),
            CohortWeeks.laneM(word)
        );
    }

    function paidCursorsAtSource(
        bytes32 _source,
        address _referrer,
        uint256 _fromWeek,
        uint256 _count
    )
        external
        view
        returns (uint256[] memory cursorWords)
    {
        cursorWords = new uint256[](
            _count
        );

        for (uint256 i; i < _count; ++i) {
            cursorWords[i] = paidCursor[_source][_referrer][_fromWeek + i];
        }
    }

    function claimableOf(
        uint256 _chainId,
        address[] calldata _referrers
    )
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](
            _referrers.length
        );

        for (uint256 i; i < _referrers.length; ++i) {
            amounts[i] = claimable[_chainId][_referrers[i]];
        }
    }

    function _localOrigin()
        internal
        view
        returns (DeliveryOrigin memory)
    {
        return DeliveryOrigin({
            chainId: block.chainid,
            deliverer: msg.sender,
            messageId: bytes32(0)
        });
    }

    function _payClaim(
        uint256 _chainId,
        address _referrer,
        uint256 _amount
    )
        internal
    {
        address payout = _resolvedPayout(
            _chainId,
            _referrer
        );

        require(
            msg.sender == _referrer
                || msg.sender == payout,
            NotPayoutAuthorized()
        );

        claimable[_chainId][_referrer] = claimable[_chainId][_referrer]
            - _amount;

        totalClaimed = totalClaimed
            + _amount;

        uint256 balance = USD_TOKEN.balanceOf(
            address(this)
        );

        if (_amount > balance) {

            require(
                payoutVault != ZERO_ADDRESS,
                PotDry()
            );

            IReferralPayoutVault(payoutVault).fundReferralPayout(
                _amount - balance
            );
        }

        USD_TOKEN.safeTransfer(
            payout,
            _amount
        );

        emit PayoutClaimed(
            _chainId,
            _referrer,
            payout,
            _amount
        );
    }

    function _fundableAmount()
        internal
        view
        returns (uint256)
    {
        address vault = payoutVault;

        if (vault == ZERO_ADDRESS) {
            return 0;
        }

        uint256 pending = IReferralPayoutVault(vault).getPendingReferralPayout();

        uint256 vaultBalance = USD_TOKEN.balanceOf(
            vault
        );

        return pending < vaultBalance
            ? pending
            : vaultBalance;
    }

    function _resolvedPayout(
        uint256 _chainId,
        address _owner
    )
        internal
        view
        returns (address)
    {
        address payout = payoutAddress[_chainId][_owner];

        return payout == ZERO_ADDRESS
            ? _owner
            : payout;
    }

    function _sourceKey(
        address _reporter
    )
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(
                uint160(
                    _reporter
                )
            )
        );
    }
}
