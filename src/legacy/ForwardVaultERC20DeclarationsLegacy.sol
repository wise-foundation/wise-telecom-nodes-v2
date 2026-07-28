// SPDX-License-Identifier: -- WISE --
// @author: René Hochmuth

pragma solidity =0.8.29;

import "./OwnableMasterLegacy.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ForwardVaultERC20Declarations
 * @dev Declaration contract containing all state variables, events, and error definitions for the Forward Vault ERC20 system.
 *
 * This contract defines:
 * - All state variables for vault management
 * - Events for tracking important state changes
 * - Custom errors for gas-efficient reverts
 * - Constants and configuration parameters
 * - Mappings for user data storage
 *
 * The contract serves as the foundation for:
 * - Interest rate tracking and calculation
 * - User balance and proxy balance management
 * - Access control and administrative functions
 * - Token transfer and interest handling
 *
 * @notice This contract inherits from multiple OpenZeppelin contracts to provide
 * the necessary functionality for a secure and feature-rich vault system.
 */
contract ForwardVaultERC20Declarations is OwnableMaster, Pausable, ReentrancyGuard, ERC20 {
    error NoRewards();
    error NotWhiteListed();
    error NoInterest();
    error InvalidValue();
    error InvalidPosition();
    error DepositExceedCap();

    error InsufficientBalanceInContract(
        uint256 attemptedWithdrawAmount,
        uint256 contractBalance
    );
    error CompoundNotAllowed();
    error WithdrawNotAllowed();
    error InsufficientBalance();
    error SupplyChangeNotAllowed();
    error InsufficientInterest();
    error InterestRateProxyAlreadySet();
    error NotInterestRateProxy();

    event ProxyBenefactorSet(
        address proxyBeneFactor
    );

    event TransferInterestWithTokensSet(
        address indexed user,
        bool transferInterestWithTokens
    );

    event WithdrawStatusChanged(
        bool withdrawAllowed
    );

    event InterestRateProxySet(
        address interestRateProxy
    );

    event SupplyChangeByOwnerNotAllowedSet(
        bool supplyChangeByOwnerNotAllowed
    );

    event MintSupply(
        address indexed to,
        uint256 amount
    );

    event BurnSupply(
        address indexed from,
        uint256 amount
    );

    event Deposited(
        address indexed user,
        uint256 amount
    );

    event ThirdPartyAddressSet(
        address thirdPartyAddress
    );

    event InterestRateSet(
        uint256 interestRate
    );

    event TotalDepositCapSet(
        uint256 totalDepositCap
    );

    event ClaimInterestSimple(
        address indexed user,
        uint256 interest
    );

    event ClaimInterestWithIncentive(
        address indexed user,
        address indexed destination,
        uint256 interest,
        uint256 incentive
    );

    event CompoundInterest(
        address indexed user,
        uint256 interest
    );

    event ClaimInterestExactAmount(
        address indexed user,
        uint256 amount
    );

    event AutoCompoundAllowedSet(
        address indexed user,
        bool isAllowed
    );

    event WhiteListAddressSet(
        address indexed user,
        bool isWhiteListed
    );

    event Withdrawn(
        address indexed user,
        uint256 amount
    );

    event ProxyBalanceIncreased(
        address indexed proxyUser,
        uint256 amount
    );

    event ProxyBalanceDecreased(
        address indexed proxyUser,
        uint256 amount
    );

    event ProxyBeneFactorSet(
        address indexed proxyBeneFactor
    );

    event InterestRateProxyProposal(
        address indexed proxy,
        bool isProposing
    );

    event InterestRateProxyClaimed(
        address indexed proxy,
        bool isClaimed
    );

    IERC20 public immutable USD_TOKEN;

    uint256 public interestRate;

    uint256 public autoCompoundIncentive;

    uint8 decimalsSet;

    address public thirdPartyAddress;

    address public InterestRateProxy;

    address public currentProxyBenefactor = ZERO_ADDRESS;

    bool public withdrawAllowed;

    bool public supplyChangeByOwnerNotAllowed;

    bool public interestRateProxyPermanent;

    bytes4 public constant IERC20Decimals = bytes4(
        keccak256("decimals()")
    );

    uint256 public totalDepositCap;

    uint256 constant SECONDS_IN_YEAR = 31_540_000;

    uint256 constant PRECISION_RATE = 10_000;

    uint256 constant PRECISION_FACTOR_E18 = 1e18;

    mapping(address => bool) public autoCompoundAllowed;

    mapping(address => bool) public isWhiteListed;

    mapping(address => uint256) public lastSyncTimeStamp;

    mapping(address => uint256) public cashedInterest;

    mapping(address => bool) public transferInterestWithTokens;

    mapping(address => uint256) public proxyBalance;

    constructor(
        address _usdAddress,
        address _thirdPartyAddress,
        address _oldVault,
        address[] memory _initialDistributionAddresses,
        uint256[] memory _initialDistributionAmounts,
        uint256 _totalDepositCap,
        uint256 _interestRate,
        uint256 _autoCompoundIncentive,
        uint8 _decimals,
        string memory _tokenName,
        string memory _tokenSymbol
    )
        OwnableMaster(
            msg.sender
        )
        ERC20(
            _tokenName,
            _tokenSymbol
        )
    {
        _validateConstructorInputs(
            _usdAddress,
            _thirdPartyAddress,
            _totalDepositCap,
            _interestRate
        );

        USD_TOKEN = IERC20(
            _usdAddress
        );

        thirdPartyAddress = _thirdPartyAddress;
        totalDepositCap = _totalDepositCap;
        interestRate = _interestRate;
        autoCompoundIncentive = _autoCompoundIncentive;
        decimalsSet = _decimals;

        _performInitialMinting(
            _initialDistributionAddresses,
            _initialDistributionAmounts
        );

        _migrateInterest(
            _oldVault,
            _initialDistributionAddresses
        );
    }

    function _validateConstructorInputs(
        address _usdAddress,
        address _thirdPartyAddress,
        uint256 _totalDepositCap,
        uint256 _interestRate
    )
        internal
        pure
    {
        if (
            _interestRate == 0 ||
            _totalDepositCap == 0 ||
            _usdAddress == ZERO_ADDRESS ||
            _thirdPartyAddress == ZERO_ADDRESS
        ) {
            revert InvalidValue();
        }
    }

    function _performInitialMinting(
        address[] memory _initialDistributionAddresses,
        uint256[] memory _initialDistributionAmounts
    )
        internal
    {
        for (uint256 i = 0; i < _initialDistributionAddresses.length; i++) {
            _mint(
                _initialDistributionAddresses[i],
                _initialDistributionAmounts[i]
            );

            lastSyncTimeStamp[_initialDistributionAddresses[i]] = block.timestamp;
        }
    }

    function _migrateInterest(
        address _oldVault,
        address[] memory _initialDistributionAddresses
    )
        internal
    {
        if (_oldVault != ZERO_ADDRESS) {
            for (uint256 i = 0; i < _initialDistributionAddresses.length; i++) {
                (
                    bool ok,
                    bytes memory returnValue
                ) = _oldVault.staticcall(
                    abi.encodeWithSignature(
                        "getTotalInterestUser(address)",
                        _initialDistributionAddresses[i]
                    )
                );

                require(
                    ok,
                    "old vault call failed"
                );

                cashedInterest[_initialDistributionAddresses[i]] = abi.decode(
                    returnValue,
                    (uint256)
                );
            }
        }
    }
}
