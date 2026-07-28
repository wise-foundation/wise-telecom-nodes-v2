// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.36;

contract VerifyProbe {

    address public immutable DEPLOYER;

    uint256 public immutable VERSION;

    uint256 public pingCount;

    event Pinged(
        address indexed caller,
        uint256 newCount
    );

    constructor(
        uint256 _version
    ) {
        DEPLOYER = msg.sender;
        VERSION = _version;
    }

    function ping()
        external
    {
        pingCount = pingCount + 1;

        emit Pinged(
            msg.sender,
            pingCount
        );
    }
}
