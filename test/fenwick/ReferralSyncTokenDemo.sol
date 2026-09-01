// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {ReferralTokenDemo} from "./ReferralTokenDemo.sol";

/**
 * @dev Lazy-sync referral accounting on top of the transfer-hook
 * sandbox, the mechanism under formal proof. Each referred user
 * carries `referredContribution` (their deposit-sourced credit toward
 * their referrer's score), and `_syncReferee` enforces the
 * clamp lazily at every touchpoint: if the tracked contribution
 * exceeds the user's current balance, both the contribution and the
 * referrer's score are reduced by exactly the difference, so
 * afterwards contribution == balance; if balance >= contribution
 * nothing changes. The clamp is strictly one-sided: no path ever
 * credits contribution for balance received outside deposit/compound.
 *
 * THE INVARIANT THIS SANDBOX EXISTS TO PROVE: `referredContribution`
 * (and with it the referrer's score) can increase ONLY inside
 * `depositWithReferral` and `compound`, by exactly the deposited or
 * compounded amount; every other operation leaves it unchanged or
 * strictly decreases it: transfer, transferFrom (both synced via the
 * swappable amount-less hook), mint (models transfers-in / unearned
 * balance), moveBetweenVaultsExit (burn, discredits immediately per
 * design decision), and the permissionless `syncReferee` poke.
 * The poke is grief-safe for the same reason: calling it on anyone
 * can only move state toward contribution == min(contribution,
 * balance), never away from it.
 *
 * Touchpoint placement mirrors the facet plan: the `syncContribution`
 * modifier runs the clamp BEFORE deposit/compound credit (this
 * ordering is what defeats the deposit -> sell -> redeposit wash: the
 * redeposit first clamps away the departed contribution, then credits
 * the new inflow, so score always equals real cumulative treasury
 * inflow still backing balances); transfers sync both parties via the
 * pre-transfer hook (installed as {ReferralSyncHookDemo}), needing no
 * amount because the clamp compares stored contribution against
 * current balance; the exit path syncs again after its burn so
 * moveBetweenVaults discredits immediately rather than lazily.
 *
 * The raw `addVolume` / `removeVolume` drivers inherited from the
 * base practice contract are disabled here so score can only move
 * through the contribution paths; the property space is closed.
 * Queue escrow and bridge attribution-carry are deliberately out of
 * scope for now.
 */
contract ReferralSyncTokenDemo is ReferralTokenDemo {

    mapping(address => address) public referrerOf;

    mapping(address => uint256) public referredContribution;

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

    error SelfReferral();

    error DriverDisabled();

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

    function syncReferee(
        address _user
    )
        external
    {
        _syncReferee(
            _user
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

        referredContribution[_user] += _amount;

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

        referredContribution[_user] = held;

        _setScore(
            referrer,
            referralScore[referrer] - (tracked - held)
        );

        emit ContributionSynced(
            _user,
            referrer,
            tracked,
            held
        );
    }
}

/**
 * @dev The referral-sync transfer hook: syncs BOTH transfer parties
 * before tokens move. Inherits {ReferralSyncTokenDemo} purely for
 * storage-layout alignment under DELEGATECALL, declares no storage,
 * and requires the transient `hookExecuting` guard like every
 * production hook. The from-side sync settles any prior unaccounted
 * decrease before this transfer creates a new one; the to-side sync
 * settles a receiver who is stale from an earlier hookless decrease
 * (e.g. a bridge burn).
 */
contract ReferralSyncHookDemo is ReferralSyncTokenDemo {

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
