// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ReferralTokenDemo} from "./ReferralTokenDemo.sol";

/**
 * @dev ReferralCommissionDemo — sandbox for the per-vault RECORDER of
 * the referral commission system, on top of the transfer-hook
 * practice stack. NOT production code and NOT wired into the
 * diamond; it rehearses the mechanism before a real facet is
 * designed, like every sibling here.
 *
 * Under the claim-at-hub architecture a vault never prices anything:
 * rates, the ladder, bot shares and claimable balances all live in
 * the mainnet hub. The vault is a
 * measuring instrument. Its entire job is to answer, exactly and
 * loop-free, "how much referred principal did each referrer have on
 * each age track, for how long" — and to keep that answer honest
 * against every balance movement. Pricing those measurements is the
 * mainnet hub's job; this contract is the recorder shape.
 *
 * Engine ("three buckets, two rings"): per referrer the book tracks
 * bookY1/bookY2/bookM — total referred principal in its first year,
 * second year, and third year onward — plus per-week cohort rings
 * (slot = week mod 52). Deposits enter ringYear1 at the current week;
 * at each weekly boundary the cohort born 52 weeks earlier graduates
 * ringYear1 -> ringYear2 and the one born 104 weeks earlier graduates
 * ringYear2 -> bookM, via pure slot arithmetic (the slot rotated at
 * boundary b is exactly b mod 52 — no search, no loop over deposits).
 *
 * Crumbs: each settled week leaves one storage word per referrer —
 * three 80-bit lanes of token-seconds (time-weighted Y1, Y2, M) plus
 * a written flag. A crumb is a pure quantity: no rates, no status, no
 * referee identities. Lanes only ever grow until the walk crosses the
 * week's closing boundary, after which the crumb is final forever —
 * which is what makes it safe to ship to the hub cumulatively and
 * price idempotently behind a max-cursor. Dormant fast-forward spans
 * are recorded as compressed crumb runs in gapLog (fromWeek,
 * toWeekExclusive, constant mature principal) instead of per-week
 * words.
 *
 * Never-block settle: the boundary walk is capped at 104
 * steps — after 104 rotations both rings are provably empty, so
 * anything beyond is a closed-form M-only tail plus one gap record —
 * and the walk has no revert paths, because it runs inside the
 * amount-less transfer hook where a revert would veto the transfer
 * itself. `advanceBook` lets anyone pre-walk a dormant book in
 * bounded chunks so the hook path stays cheap in practice.
 *
 * Movement rules: the clamp is one-sided — any
 * ownership-changing movement (transfer, queue join, exit burn)
 * permanently reduces the referee's tracked contribution, the book
 * and the score by exactly tracked − held; NOTHING re-credits except
 * a fresh deposit or compound. Queue leave restores tokens but never
 * credit; queue fulfillment needs no referral action at all because
 * the discredit already happened at join. Book reductions consume the
 * youngest credit first — ringYear1 newest slot first, then ringYear2
 * newest first, then bookM — so every ambiguity resolves against the
 * beneficiary and a sell-plus-redeposit cycle cannot upgrade old
 * low-rate credit while fresh cover exists. System relocations
 * (moveBetweenVaults, bridge) are OUT of this sandbox's scope: they
 * carry attribution instead of destroying it.
 *
 * Ordering discipline: every path that mutates a referrer's score
 * settles the book FIRST. Settle-before-reduce keeps ring slot
 * indices meaningful (rotations current before the walk), and
 * settle-before-credit keeps crumb time-weights exact (the elapsed
 * window accrues at the balances that actually existed).
 *
 * Accounting invariant this sandbox exists to demonstrate: for every
 * referrer, sum of referredContribution over their referees
 * == bookY1 + bookY2 + bookM == referralScore. Credits add to all
 * three in the same transaction; clamp deltas subtract from all three
 * in the same transaction; graduations move principal between buckets
 * without changing the total.
 *
 * Deliberate divergences from production, process not mechanics: the
 * local referralScore stands in for the report to the chain registry
 * / mainnet hub (cross-chain accumulators and flush messages are not
 * modeled here); the queue is a two-function miniature (escrow in,
 * escrow out, P2P fulfill) that mirrors only the hook-and-balance
 * shape of the real queue paths; rings are unpacked uint256 slots for
 * legibility where the production facet packs uint64 lanes.
 */
contract ReferralCommissionDemo is ReferralTokenDemo {

    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant RING_SLOTS = 52;

    uint256 internal constant YEAR = RING_SLOTS * WEEK;

    uint256 internal constant MAX_SETTLE_BOUNDARIES = 104;

    uint256 internal constant CRUMB_AMOUNT_MASK = (1 << 80) - 1;

    uint256 internal constant CRUMB_Y2_SHIFT = 80;

    uint256 internal constant CRUMB_M_SHIFT = 160;

    uint256 internal constant CRUMB_WRITTEN_BIT = 1 << 252;

    mapping(address => address) public referrerOf;

    mapping(address => uint256) public referredContribution;

    mapping(address => uint256) public queuedAmount;

    mapping(address => uint256) public bookY1;

    mapping(address => uint256) public bookY2;

    mapping(address => uint256) public bookM;

    mapping(address => uint256) public lastSettle;

    mapping(address => mapping(uint256 => uint256)) public ringYear1;

    mapping(address => mapping(uint256 => uint256)) public ringYear2;

    mapping(address => mapping(uint256 => uint256)) public weekLog;

    mapping(address => uint256[]) internal gapLog;

    event ReferralSet(
        address indexed user,
        address indexed referrer
    );

    event ContributionCredited(
        address indexed user,
        address indexed referrer,
        uint256 amount
    );

    event ContributionSynced(
        address indexed user,
        address indexed referrer,
        uint256 oldContribution,
        uint256 newContribution
    );

    event BookSettled(
        address indexed referrer,
        uint256 fromTimestamp,
        uint256 toTimestamp,
        uint256 boundariesWalked
    );

    event BookReduced(
        address indexed referrer,
        uint256 amount,
        uint256 fromYear1,
        uint256 fromYear2,
        uint256 fromMature
    );

    event GapRecorded(
        address indexed referrer,
        uint256 fromWeek,
        uint256 toWeekExclusive,
        uint256 maturePrincipal
    );

    event QueueJoined(
        address indexed user,
        uint256 amount
    );

    event QueueLeft(
        address indexed user,
        uint256 amount
    );

    event QueueFulfilled(
        address indexed seller,
        address indexed buyer,
        uint256 amount
    );

    error SelfReferral();

    error DriverDisabled();

    error NothingQueued();

    modifier syncContribution(
        address _user
    ) {
        _syncReferee(
            _user
        );
        _;
    }

    function depositWithReferral(
        uint256 _amount,
        address _referrer
    )
        external
        syncContribution(msg.sender)
    {
        require(
            _amount > 0,
            InvalidValue()
        );

        require(
            _referrer != address(0),
            ZeroAddress()
        );

        require(
            _referrer != msg.sender,
            SelfReferral()
        );

        if (referrerOf[msg.sender] == address(0)) {
            referrerOf[msg.sender] = _referrer;

            emit ReferralSet(
                msg.sender,
                _referrer
            );
        }

        _mint(
            msg.sender,
            _amount
        );

        _creditContribution(
            msg.sender,
            _amount
        );
    }

    function compound(
        uint256 _amount
    )
        external
        syncContribution(msg.sender)
    {
        require(
            _amount > 0,
            InvalidValue()
        );

        _mint(
            msg.sender,
            _amount
        );

        _creditContribution(
            msg.sender,
            _amount
        );
    }

    function moveBetweenVaultsExit(
        uint256 _amount
    )
        external
        syncContribution(msg.sender)
    {
        require(
            _amount > 0,
            InvalidValue()
        );

        _burn(
            msg.sender,
            _amount
        );

        _syncReferee(
            msg.sender
        );
    }

    function joinQue(
        uint256 _amount
    )
        external
        syncContribution(msg.sender)
    {
        require(
            _amount > 0,
            InvalidValue()
        );

        _runTransferHook(
            msg.sender,
            address(this)
        );

        _transfer(
            msg.sender,
            address(this),
            _amount
        );

        queuedAmount[msg.sender] += _amount;

        _syncReferee(
            msg.sender
        );

        emit QueueJoined(
            msg.sender,
            _amount
        );
    }

    function leaveQue()
        external
    {
        uint256 amount = queuedAmount[msg.sender];

        require(
            amount > 0,
            NothingQueued()
        );

        queuedAmount[msg.sender] = 0;

        _runTransferHook(
            address(this),
            msg.sender
        );

        _transfer(
            address(this),
            msg.sender,
            amount
        );

        emit QueueLeft(
            msg.sender,
            amount
        );
    }

    function fulfillOrder(
        address _seller,
        address _buyer
    )
        external
    {
        uint256 amount = queuedAmount[_seller];

        require(
            amount > 0,
            NothingQueued()
        );

        queuedAmount[_seller] = 0;

        _runTransferHook(
            address(this),
            _buyer
        );

        _transfer(
            address(this),
            _buyer,
            amount
        );

        emit QueueFulfilled(
            _seller,
            _buyer,
            amount
        );
    }

    function syncReferee(
        address _user
    )
        external
    {
        _syncReferee(
            _user
        );
    }

    function advanceBook(
        address _referrer,
        uint256 _maxBoundaries
    )
        external
    {
        uint256 last = lastSettle[_referrer];

        if (last == 0) {
            return;
        }

        uint256 cursor = last;

        uint256 steps;

        while (steps < _maxBoundaries && steps < MAX_SETTLE_BOUNDARIES) {

            uint256 next = (cursor / WEEK + 1) * WEEK;

            if (next > block.timestamp) {
                break;
            }

            _recordSegment(
                _referrer,
                cursor,
                next
            );

            _rotate(
                _referrer,
                next / WEEK
            );

            cursor = next;

            ++steps;
        }

        if (cursor == last) {
            return;
        }

        lastSettle[_referrer] = cursor;

        emit BookSettled(
            _referrer,
            last,
            cursor,
            steps
        );
    }

    function addVolume(
        address,
        uint256
    )
        external
        pure
        override
    {
        revert DriverDisabled();
    }

    function removeVolume(
        address,
        uint256
    )
        external
        pure
        override
    {
        revert DriverDisabled();
    }

    function gapLogLength(
        address _referrer
    )
        external
        view
        returns (uint256)
    {
        return gapLog[_referrer].length;
    }

    function gapLogEntry(
        address _referrer,
        uint256 _index
    )
        external
        view
        returns (uint256)
    {
        return gapLog[_referrer][_index];
    }

    function _creditContribution(
        address _user,
        uint256 _amount
    )
        internal
    {
        address referrer = referrerOf[_user];

        if (referrer == address(0)) {
            return;
        }

        _settleBook(
            referrer
        );

        referredContribution[_user] += _amount;

        uint256 week = block.timestamp / WEEK;

        ringYear1[referrer][week % RING_SLOTS] += _amount;

        bookY1[referrer] += _amount;

        _setScore(
            referrer,
            referralScore[referrer] + _amount
        );

        emit ContributionCredited(
            _user,
            referrer,
            _amount
        );
    }

    function _syncReferee(
        address _user
    )
        internal
    {
        address referrer = referrerOf[_user];

        if (referrer == address(0)) {
            return;
        }

        uint256 tracked = referredContribution[_user];

        uint256 held = balanceOf(
            _user
        );

        if (held >= tracked) {
            return;
        }

        uint256 delta = tracked - held;

        _settleBook(
            referrer
        );

        referredContribution[_user] = held;

        _reduceBook(
            referrer,
            delta
        );

        _setScore(
            referrer,
            referralScore[referrer] - delta
        );

        emit ContributionSynced(
            _user,
            referrer,
            tracked,
            held
        );
    }

    function _settleBook(
        address _referrer
    )
        internal
    {
        uint256 last = lastSettle[_referrer];

        if (last == block.timestamp) {
            return;
        }

        if (last == 0) {
            lastSettle[_referrer] = block.timestamp;
            return;
        }

        uint256 cursor = last;

        uint256 steps;

        while (steps < MAX_SETTLE_BOUNDARIES) {

            uint256 next = (cursor / WEEK + 1) * WEEK;

            if (next > block.timestamp) {
                break;
            }

            _recordSegment(
                _referrer,
                cursor,
                next
            );

            _rotate(
                _referrer,
                next / WEEK
            );

            cursor = next;

            ++steps;
        }

        uint256 latestBoundary = (block.timestamp / WEEK) * WEEK;

        if (latestBoundary > cursor) {
            cursor = _recordGap(
                _referrer,
                cursor,
                latestBoundary
            );
        }

        if (block.timestamp > cursor) {
            _recordSegment(
                _referrer,
                cursor,
                block.timestamp
            );
        }

        lastSettle[_referrer] = block.timestamp;

        emit BookSettled(
            _referrer,
            last,
            block.timestamp,
            steps
        );
    }

    function _recordSegment(
        address _referrer,
        uint256 _from,
        uint256 _to
    )
        internal
    {
        uint256 y1 = bookY1[_referrer];

        uint256 y2 = bookY2[_referrer];

        uint256 mature = bookM[_referrer];

        if (y1 == 0 && y2 == 0 && mature == 0) {
            return;
        }

        uint256 dt = _to - _from;

        _writeCrumb(
            _referrer,
            _from / WEEK,
            y1 * dt,
            y2 * dt,
            mature * dt
        );
    }

    function _writeCrumb(
        address _referrer,
        uint256 _week,
        uint256 _y1Seconds,
        uint256 _y2Seconds,
        uint256 _mSeconds
    )
        internal
    {
        uint256 crumb = weekLog[_referrer][_week];

        if (crumb & CRUMB_WRITTEN_BIT == 0) {
            crumb = CRUMB_WRITTEN_BIT;
        }

        uint256 y1Total = (crumb & CRUMB_AMOUNT_MASK) + _y1Seconds;

        uint256 y2Total = ((crumb >> CRUMB_Y2_SHIFT) & CRUMB_AMOUNT_MASK) + _y2Seconds;

        uint256 mTotal = ((crumb >> CRUMB_M_SHIFT) & CRUMB_AMOUNT_MASK) + _mSeconds;

        weekLog[_referrer][_week] = (
            crumb & ~(
                CRUMB_AMOUNT_MASK
                    | (CRUMB_AMOUNT_MASK << CRUMB_Y2_SHIFT)
                    | (CRUMB_AMOUNT_MASK << CRUMB_M_SHIFT)
            )
        )
            | y1Total
            | (y2Total << CRUMB_Y2_SHIFT)
            | (mTotal << CRUMB_M_SHIFT);
    }

    function _recordGap(
        address _referrer,
        uint256 _from,
        uint256 _toBoundary
    )
        internal
        returns (uint256)
    {
        uint256 mature = bookM[_referrer];

        uint256 fromWeek = _from / WEEK;

        uint256 toWeekExclusive = _toBoundary / WEEK;

        if (mature > 0) {
            gapLog[_referrer].push(
                fromWeek
                    | (toWeekExclusive << 32)
                    | (mature << 64)
            );

            emit GapRecorded(
                _referrer,
                fromWeek,
                toWeekExclusive,
                mature
            );
        }

        return _toBoundary;
    }

    function _rotate(
        address _referrer,
        uint256 _boundaryWeek
    )
        internal
    {
        uint256 slot = _boundaryWeek % RING_SLOTS;

        uint256 graduatingYear2 = ringYear2[_referrer][slot];

        uint256 graduatingYear1 = ringYear1[_referrer][slot];

        if (graduatingYear2 > 0) {
            bookM[_referrer] += graduatingYear2;
            bookY2[_referrer] -= graduatingYear2;
        }

        if (graduatingYear1 > 0) {
            bookY2[_referrer] += graduatingYear1;
            bookY1[_referrer] -= graduatingYear1;
            ringYear1[_referrer][slot] = 0;
        }

        if (graduatingYear1 != graduatingYear2) {
            ringYear2[_referrer][slot] = graduatingYear1;
        }
    }

    function _reduceBook(
        address _referrer,
        uint256 _delta
    )
        internal
    {
        uint256 remaining = _delta;

        uint256 currentWeek = block.timestamp / WEEK;

        uint256 fromYear1;

        uint256 fromYear2;

        uint256 fromMature;

        for (uint256 back; back < RING_SLOTS; ++back) {

            if (remaining == 0 || back > currentWeek) {
                break;
            }

            uint256 slot = (currentWeek - back) % RING_SLOTS;

            uint256 held = ringYear1[_referrer][slot];

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            ringYear1[_referrer][slot] = held - take;

            remaining -= take;

            fromYear1 += take;
        }

        if (fromYear1 > 0) {
            bookY1[_referrer] -= fromYear1;
        }

        for (uint256 back; back < RING_SLOTS; ++back) {

            if (remaining == 0 || back > currentWeek) {
                break;
            }

            uint256 slot = (currentWeek - back) % RING_SLOTS;

            uint256 held = ringYear2[_referrer][slot];

            if (held == 0) {
                continue;
            }

            uint256 take = held < remaining
                ? held
                : remaining;

            ringYear2[_referrer][slot] = held - take;

            remaining -= take;

            fromYear2 += take;
        }

        if (fromYear2 > 0) {
            bookY2[_referrer] -= fromYear2;
        }

        if (remaining > 0) {
            bookM[_referrer] -= remaining;
            fromMature = remaining;
        }

        emit BookReduced(
            _referrer,
            _delta,
            fromYear1,
            fromYear2,
            fromMature
        );
    }
}

/**
 * @dev The commission transfer hook: syncs BOTH transfer parties
 * before tokens move, exactly like {ReferralSyncHookDemo}, but the
 * sync it inherits also settles and reduces the commission book.
 * Inherits {ReferralCommissionDemo} purely for storage-layout
 * alignment under DELEGATECALL, declares no storage, and requires the
 * transient `hookExecuting` guard like every production hook. The
 * settle walk it can trigger is hard-bounded (104 boundary steps plus
 * a closed-form tail) and revert-free by construction, because a
 * revert here would veto the transfer itself.
 */
contract ReferralCommissionHookDemo is ReferralCommissionDemo {

    error NotHookExecution();

    function applyTransferHook(
        address _from,
        address _to
    )
        external
    {
        require(
            hookExecuting,
            NotHookExecution()
        );

        _syncReferee(
            _from
        );

        _syncReferee(
            _to
        );
    }
}
