// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BridgeToken is ERC20 {

    address public immutable CCIP_ADMIN;

    address public pool;

    event PoolSet(
        address indexed pool
    );

    error NotAdmin();

    error NotPool();

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _preMint
    )
        ERC20(_name, _symbol)
    {
        CCIP_ADMIN = msg.sender;

        if (_preMint != 0) {
            _mint(
                msg.sender,
                _preMint
            );
        }
    }

    function setPool(
        address _pool
    )
        external
    {
        if (msg.sender != CCIP_ADMIN) {
            revert NotAdmin();
        }

        pool = _pool;

        emit PoolSet(
            _pool
        );
    }

    function mint(
        address _account,
        uint256 _amount
    )
        external
    {
        if (msg.sender != pool) {
            revert NotPool();
        }

        _mint(
            _account,
            _amount
        );
    }

    function burn(
        uint256 _amount
    )
        external
    {
        if (msg.sender != pool) {
            revert NotPool();
        }

        _burn(
            msg.sender,
            _amount
        );
    }

    function getCCIPAdmin()
        external
        view
        returns (address)
    {
        return CCIP_ADMIN;
    }
}
