// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "./IForwardVaultERC20Legacy.sol";
import "./OwnableMasterLegacy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

interface IBalancerVault {
    function flashLoan(
        IFlashLoanRecipient recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

contract MoneyForwardContract is OwnableMaster, IFlashLoanRecipient {
    using SafeERC20 for IERC20;

    IForwardVaultERC20 public immutable oldVault;
    IERC20 public immutable usdToken;
    address public immutable originalVaultOwner;
    address public immutable newVaultSystemAddress;
    IBalancerVault public immutable balancerVault;
    bool transferOngoing = false;

    constructor(
        address _oldVault,
        address _usdToken,
        address _originalVaultOwner,
        address _newVaultSystemAddress,
        address _balancerVault
    )
        OwnableMaster(msg.sender)
    {
        oldVault = IForwardVaultERC20(_oldVault);
        usdToken = IERC20(_usdToken);
        originalVaultOwner = _originalVaultOwner;
        newVaultSystemAddress = _newVaultSystemAddress;
        balancerVault = IBalancerVault(_balancerVault);
    }

    function burnSupplyBulk(
        address[] memory users,
        uint256[] memory amounts
    )
        public
        onlyMaster
    {
        for (uint256 i = 0; i < users.length; i++) {
            oldVault.burnSupply(users[i], amounts[i]);
        }
    }

    function mintSupply(
        uint256 amount
    )
        public
        onlyMaster
    {
        oldVault.mintSupply(address(this), amount);
    }

    function initiateEvacuation(
    )
        external
    {
        require(
            msg.sender == master,
            "EvacuationContract: Not owner"
        );

        uint256 totalInterestToClaim = oldVault.getTotalInterestUser(
            address(this)
        );

        uint256 cashedBalance = usdToken.balanceOf(address(oldVault));

        require(
            totalInterestToClaim > cashedBalance,
            "EvacuationContract: It wouldnt empty it"
        );

        uint256 flashAmount = totalInterestToClaim - cashedBalance;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashAmount;

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdToken);

        bytes memory userData = abi.encode(totalInterestToClaim);

        transferOngoing = true;

        balancerVault.flashLoan(
            this,
            tokens,
            amounts,
            userData
        );

        oldVault.proposeOwner(originalVaultOwner);

        transferOngoing = false;
    }

    function proposeOwnerOldVault(
        address newOwner
    )
        public
        onlyMaster
    {
        oldVault.proposeOwner(newOwner);
    }

    function acceptOwnerOldVault(
    )
        public
        onlyMaster
    {
        oldVault.claimOwnership();
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    )
        external
        override
    {
        require(
            transferOngoing,
            "EvacuationContract: Transfer not ongoing"
        );

        require(
            msg.sender == address(balancerVault),
            "EvacuationContract: Only Balancer Vault"
        );
        require(
            tokens.length == 1 && tokens[0] == address(usdToken),
            "EvacuationContract: Invalid token"
        );

        usdToken.safeTransfer(address(oldVault), amounts[0]);

        uint256 flashloanAmount = amounts[0];
        uint256 flashloanFee = 0;

        oldVault.claimInterest();

        uint256 repaymentAmount = flashloanAmount + flashloanFee;
        usdToken.safeTransfer(
            address(balancerVault),
            repaymentAmount
        );

        uint256 leftOverBalance = usdToken.balanceOf(address(this));

        require(
            leftOverBalance > 0,
            "EvacuationContract: No left over balance"
        );

        require(
            usdToken.balanceOf(address(oldVault)) == 0,
            "EvacuationContract: Old vault has balance"
        );

        usdToken.safeTransfer(
            newVaultSystemAddress,
            leftOverBalance
        );
    }

    function _testMoneyForwardProcess(
        uint256 flashloanAmount,
        uint256 flashloanFee
    )
        internal
        view
        returns (uint256)
    {
        uint256 repaymentAmount = flashloanAmount + flashloanFee;
        uint256 leftOverBalance = usdToken.balanceOf(address(this)) - repaymentAmount;
        return leftOverBalance;
    }
}
