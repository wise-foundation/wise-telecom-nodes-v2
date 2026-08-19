// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubIntake} from "./ReferralHubIntake.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";
import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";

/**
 * @dev The mainnet hub (scoreboard + paymaster) of the
 * referral commission system — ONE standalone deployed contract
 * closing the chain Declarations → Checkpoints → Rates →
 * Intake. It ships the structural groundwork: everything the frozen
 * recorder interface exercises (score aggregation, weekly
 * checkpoint history, crumb/gap pricing into claimable balances) is
 * live and fully tested; everything still undecided is a
 * documented seam, not code. Year-1 pays the tier ladder capped at
 * 10%; year-2 (500 bps) and mature (100 bps) rates pay only in weeks
 * where the referrer's uncapped ladder sum reaches the cap — all
 * three knobs week-versioned behind `pushRateTable`.
 *
 * Completion register (the open seams):
 * - Sybil countermeasure: attaches inside `_weeklyRates` —
 *   policy-module change only.
 * - Payout asset/funding: NO `claim()` exists — `claimable` is
 *   accrual-only accounting. A value-less claim would zero balances
 *   against nothing; the entrypoint ships with the funding decision.
 *   `totalAccrued` is the anchor the hub→vault
 *   `pendingReferralPayout` message will read (raise = accrual
 *   delta, lower = claims once claiming lands).
 * - Payout addresses: `setPayoutAddress` registry stub ships
 *   (default self); claim pays there when it exists.
 * - Cross-chain transport: reporters are the single trust boundary —
 *   the mailbox becomes an allowed reporter with `keccak256(chainId,
 *   vault)` source keys; envelope and crumbVersion checks live in
 *   that mailbox; the 10% bot share attaches at the accrual site
 *   when cross-chain transport makes a non-100% deliverer
 *   reachable, and the keeper-bot policy matrix gates that flush
 *   path, not this intake.
 * - Mainnet-vault inline reporting: the vault becomes an allowed
 *   reporter calling `reportScores`/`deliverCrumbs` from its own
 *   flows — zero new hub surface.
 *
 * Threat model: master (two-step {OwnableMaster}) governs the
 * reporter allowlist, future rate tables and the future-week-only
 * dwell-min schedule — every rate lever is week-versioned and
 * future-only, so the pricing of any week whose opening boundary has
 * passed is a pure function of frozen data and can never change,
 * even for master. Master can NEVER
 * touch scores, cursors, checkpoints or claimables
 * directly. Reporters are trusted for their OWN source's data only —
 * cursors and per-source score diffs contain a malicious reporter's
 * blast radius to its own source key.
 */
contract ReferralHub is ReferralHubIntake {

    modifier onlyReporter() {
        require(
            allowedReporter[msg.sender],
            NotReporter()
        );
        _;
    }

    constructor()
        OwnableMaster(
            msg.sender
        )
    {
        _seedGenesisDwellMin();

        _seedGenesisRateTable();
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

        _applyScoreReport(
            _sourceKey(msg.sender),
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
                _words[i]
            );
        }
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
        _deliverGap(
            _sourceKey(msg.sender),
            _referrer,
            _record,
            _fromWeek,
            _maxWeeks
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
        payoutAddress[msg.sender] = _payout;

        emit PayoutAddressSet(
            msg.sender,
            _payout
        );
    }

    function payoutAddressOf(
        address _owner
    )
        external
        view
        returns (address)
    {
        address payout = payoutAddress[_owner];

        return payout == ZERO_ADDRESS
            ? _owner
            : payout;
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
            packed >> REPORT_REFERRED_SHIFT,
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
