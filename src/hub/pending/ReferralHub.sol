// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {ReferralHubIntake} from "./ReferralHubIntake.sol";
import {CohortWeeks} from "../../diamond/shared/pending/CohortWeeks.sol";
import {OwnableMaster} from "../../diamond/shared/OwnableMaster.sol";

/**
 * @dev The Phase-4 mainnet hub (scoreboard + paymaster) of the
 * referral commission plan — ONE standalone deployed contract closing
 * the chain Declarations → Ranking → Checkpoints → Rates → Intake.
 * This branch ships the structural groundwork: everything the frozen
 * recorder interface exercises (score aggregation, ranking, weekly
 * verdict history, crumb/gap pricing into claimable balances) is
 * live and fully tested; everything an open ruling blocks is a
 * documented seam, not code.
 *
 * Phase-4 completion register (the seams, in ruling order):
 * - O1 sybil countermeasure: attaches inside `_weeklyRates` /
 *   MIN_ACTIVE_SCORE — policy-module change only.
 * - O2 Year-2/mature rates: genesis table holds 0; landing O2 is one
 *   `pushRateTable` call. The decile gate is wired and tested now.
 * - O3 payout asset/funding: NO `claim()` exists — `claimable` is
 *   accrual-only accounting. A value-less claim would zero balances
 *   against nothing; the entrypoint ships with O3. `totalAccrued`
 *   is the anchor the O6 hub→vault `pendingReferralPayout` message
 *   will read (raise = accrual delta, lower = claims once O3 lands).
 * - O4 payout addresses: `setPayoutAddress` registry stub ships
 *   (default self); claim pays there when it exists.
 * - Phase-5 transport: reporters are the single trust boundary —
 *   the mailbox becomes an allowed reporter with `keccak256(chainId,
 *   vault)` source keys (see README register); envelope and
 *   crumbVersion checks live in that mailbox (R15); the R11 10% bot
 *   share attaches at the accrual site when cross-chain transport
 *   makes a non-100% deliverer reachable; R12's bot matrix gates
 *   that flush path, not this branch's intake.
 * - Mainnet-vault inline reporting: the vault becomes an allowed
 *   reporter calling `reportScores`/`deliverCrumbs` from its own
 *   flows — zero new hub surface.
 *
 * Threat model: master (two-step {OwnableMaster}) governs the
 * reporter allowlist, future rate tables (future-week-only, so past
 * pricing is immutable even against master) and the R14 dwell knob;
 * it can NEVER touch scores, cursors, checkpoints or claimables
 * directly. Reporters are trusted for their OWN source's data only —
 * cursors and per-source score diffs contain a malicious reporter's
 * blast radius to its own source key. `snapshotWeek` is the
 * permissionless keeper poke freezing a quiet week's cutoff exactly
 * as the first organic mutation would.
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
        dwellMinEnabled = true;

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

    function snapshotWeek()
        external
    {
        _snapshotCutoffIfNewWeek();
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

    function setDwellMinEnabled(
        bool _enabled
    )
        external
        onlyMaster
    {
        dwellMinEnabled = _enabled;

        emit DwellMinSet(
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
