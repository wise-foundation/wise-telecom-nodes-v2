// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.36;

import {FacetBase} from "./FacetBase.sol";

/**
 * @dev Configuration surface. Every function is master-gated except
 * `setProxyBenefactor`, which is restricted to the interest-rate
 * proxy. Each function is a thin wrapper around an internal helper.
 */
contract AdminFacet is FacetBase {

    constructor()
        FacetBase()
    {}

    function disAllowSupplyChangeByOwner()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _disableSupplyChangeByOwner();
    }

    function mintSupply(
        address _to,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        assignInterest(_to)
        nonReentrant
        supplyChangeAllowed
    {
        _executeMintSupply(
            _to,
            _amount
        );
    }

    function burnSupply(
        address _from,
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        assignInterest(_from)
        nonReentrant
        supplyChangeAllowed
    {
        _executeBurnSupply(
            _from,
            _amount
        );
    }

    function pauseDeposits()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _pause();
    }

    function unpauseDeposits()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _unpause();
    }

    function proposeThirdPartyAddress(
        address _thirdPartyAddress
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeThirdPartyAddress(
            _thirdPartyAddress
        );
    }

    function executeThirdPartyAddressChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyThirdPartyAddressChange();
    }

    function cancelThirdPartyAddressChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelThirdPartyAddressChange();
    }

    function proposeTransferHookFacet(
        address _facet
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeTransferHookFacet(
            _facet
        );
    }

    function executeTransferHookFacetChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyTransferHookFacetChange();
    }

    function cancelTransferHookFacetChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelTransferHookFacetChange();
    }

    function proposeDepositHookFacet(
        address _facet
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeDepositHookFacet(
            _facet
        );
    }

    function executeDepositHookFacetChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyDepositHookFacetChange();
    }

    function cancelDepositHookFacetChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelDepositHookFacetChange();
    }

    function proposeReferralRegistry(
        address _registry
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeReferralRegistry(
            _registry
        );
    }

    function executeReferralRegistryChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyReferralRegistryChange();
    }

    function cancelReferralRegistryChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelReferralRegistryChange();
    }

    function getReferralRegistry()
        external
        view
        returns (address)
    {
        return referralRegistry;
    }

    function getProposedReferralRegistry()
        external
        view
        returns (address)
    {
        return proposedReferralRegistry;
    }

    function getReferralRegistryChangeQueuedAt()
        external
        view
        returns (uint256)
    {
        return referralRegistryChangeQueuedAt;
    }

    function proposePayoutHub(
        address _hub
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposePayoutHub(
            _hub
        );
    }

    function executePayoutHubChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyPayoutHubChange();
    }

    function cancelPayoutHubChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelPayoutHubChange();
    }

    function getPayoutHub()
        external
        view
        returns (address)
    {
        return payoutHub;
    }

    function getProposedPayoutHub()
        external
        view
        returns (address)
    {
        return proposedPayoutHub;
    }

    function getPayoutHubChangeQueuedAt()
        external
        view
        returns (uint256)
    {
        return payoutHubChangeQueuedAt;
    }

    function proposeFlushHub(
        address _hub,
        uint64 _chainSelector
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeFlushHub(
            _hub,
            _chainSelector
        );
    }

    function executeFlushHubChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyFlushHubChange();
    }

    function cancelFlushHubChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelFlushHubChange();
    }

    function getFlushHub()
        external
        view
        returns (
            address,
            uint64
        )
    {
        return (
            flushHub,
            flushHubChainSelector
        );
    }

    function getProposedFlushHub()
        external
        view
        returns (
            address,
            uint64
        )
    {
        return (
            proposedFlushHub,
            proposedFlushHubChainSelector
        );
    }

    function getFlushHubChangeQueuedAt()
        external
        view
        returns (uint256)
    {
        return flushHubChangeQueuedAt;
    }

    function proposeWorkerAddress(
        address _worker
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _proposeWorkerAddress(
            _worker
        );
    }

    function executeWorkerAddressChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _applyWorkerAddressChange();
    }

    function cancelWorkerAddressChange()
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _cancelWorkerAddressChange();
    }

    function setInterestRate(
        uint256 _interestRate
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _updateInterestRate(
            _interestRate
        );
    }

    function setTotalDepositCap(
        uint256 _totalDepositCap
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _updateTotalDepositCap(
            _totalDepositCap
        );
    }

    function setProxyBenefactor(
        address _proxyBeneFactor
    )
        external
        onlyDelegateCall
        nonReentrant
    {
        _validateInterestRateProxy();

        _updateProxyBenefactor(
            _proxyBeneFactor
        );
    }

    function setWiseToken(
        address _wiseToken
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _updateWiseToken(
            _wiseToken
        );
    }

    function setDepositsDisabled(
        bool _disabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setDepositsDisabled(
            _disabled
        );
    }

    function setGracePeriodDuration(
        uint256 _duration
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setGracePeriodDuration(
            _duration
        );
    }

    function setGraceThresholdAmount(
        uint256 _amount
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setGraceThresholdAmount(
            _amount
        );
    }

    function setGraceFreezeEnabled(
        bool _enabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setGraceFreezeEnabled(
            _enabled
        );
    }

    function setCohortSyncEnabled(
        bool _enabled
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setCohortSyncEnabled(
            _enabled
        );
    }

    function setSweeper(
        address _sweeper,
        bool _allowed
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setSweeper(
            _sweeper,
            _allowed
        );
    }

    function setDepositAccumWindow(
        uint256 _window
    )
        external
        onlyDelegateCall
        onlyMaster
        nonReentrant
    {
        _setDepositAccumWindow(
            _window
        );
    }
}
