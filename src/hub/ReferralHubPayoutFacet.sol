// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReferralHubIntake} from "./ReferralHubIntake.sol";
import {ReferralHubFacetBase} from "./ReferralHubFacetBase.sol";

/**
 * @dev ReferralHubPayoutFacet: the claim rail (`claim`, `claimUpTo`,
 * `claimAll` over several source chains) and the hub chain's own payout
 * designation. Every bucket pays its owner's own address on the hub chain
 * until a designation from the bucket's chain redirects it (the registry's
 * `setPayoutAddress` on a spoke, carried by a flush or pushed, or this
 * facet's `setPayoutAddress` on the hub chain; the newest stamp wins), so
 * a referrer has to do nothing to be paid, and `payoutAddressOf` answers
 * the address a claim would pay. A contract wallet that owns a spoke
 * bucket (as referrer or as courier) and does not control the same
 * address on the hub chain has that bucket payable to the address here,
 * so such an owner designates on that spoke before its first commission
 * accrues; an externally owned account loses nothing.
 * The hub is its own pot: a claim pays from the USD the hub holds (funded
 * by plain transfers; `totalPayable - totalClaimed` is the amount owed,
 * `totalPayable` being kept equal to `totalAccrued` at every accrual and
 * every claim), `PotDry` when it holds less. It never reaches the pricing.
 */
contract ReferralHubPayoutFacet is
    ReferralHubIntake,
    ReferralHubFacetBase
{

    using SafeERC20 for IERC20;

    function claim(
        uint256 _chainId,
        address _referrer
    )
        external
        onlyDelegateCall
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
        onlyDelegateCall
    {
        uint256 entitled = claimable[_chainId][_referrer];

        uint256 amount = _amount < entitled
            ? _amount
            : entitled;

        require(
            amount > 0,
            NothingClaimable()
        );

        uint256 covered = _coveredAmount();

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

    /**
     * @dev Claims every listed bucket of `_referrer` that holds an amount
     * and accepts the caller (the referrer or that bucket's resolved
     * payout); every other bucket is skipped, a repeated chain id included.
     * Each bucket pays up to the cover left after the buckets before it, as
     * `claimUpTo` does, so a short pot pays what it can in list order and
     * leaves the rest claimable. Reverts `NothingClaimable` when it pays
     * nothing.
     */
    function claimAll(
        address _referrer,
        uint256[] calldata _chainIds
    )
        external
        onlyDelegateCall
        returns (uint256 total)
    {
        for (uint256 i; i < _chainIds.length; ++i) {

            uint256 chainId = _chainIds[i];

            uint256 amount = claimable[chainId][_referrer];

            if (
                amount == 0
                    || _claimSkipped(
                        chainId,
                        _referrer
                    )
            ) {
                continue;
            }

            uint256 covered = _coveredAmount();

            if (amount > covered) {
                amount = covered;
            }

            if (amount == 0) {
                continue;
            }

            _payClaim(
                chainId,
                _referrer,
                amount
            );

            total += amount;
        }

        require(
            total > 0,
            NothingClaimable()
        );
    }

    function setPayoutAddress(
        address _payout
    )
        external
        onlyDelegateCall
    {
        payoutStamp[block.chainid][msg.sender] = block.timestamp
            << PAYOUT_STAMP_SHIFT;

        payoutAddress[block.chainid][msg.sender] = _payout;

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

        totalPayable = totalAccrued;

        require(
            _amount <= USD_TOKEN.balanceOf(
                address(this)
            ),
            PotDry()
        );

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

    function _claimSkipped(
        uint256 _chainId,
        address _referrer
    )
        internal
        view
        returns (bool)
    {
        return msg.sender != _referrer
            && msg.sender != _resolvedPayout(
                _chainId,
                _referrer
            );
    }

    function _coveredAmount()
        internal
        view
        returns (uint256)
    {
        return USD_TOKEN.balanceOf(
            address(this)
        );
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
}
