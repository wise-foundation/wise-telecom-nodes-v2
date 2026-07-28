// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Minimal WISE-burn surface of the LIVE WiseTelecomNodes diamond,
 * driven through its deployed fallback router.
 */
interface IWtnBurn {

    function burnWise()
        external
        returns (uint256);

    function getBurnableWise()
        external
        view
        returns (uint256);

    function getNextBurnPercentage()
        external
        view
        returns (uint256);

    function burnWiseIndex()
        external
        view
        returns (uint256);

    function WISE_TOKEN()
        external
        view
        returns (address);
}

/**
 * @title WiseBurnEthUsdcFork
 * @dev Forks Ethereum mainnet against the LIVE, deployed ETH USDC
 * WiseTelecomNodes diamond (0x7e1EFF43…) and exercises the real
 * `burnWise()` path end to end against the real mainnet WISE token:
 *
 *   1. seed the diamond with WISE (a plain ERC20 transfer into it),
 *   2. call `burnWise()` through the deployed router, and
 *   3. assert the exact rotating slice (5/10/20/15/5/1%) is truly BURNED
 *      — both the diamond's WISE balance AND WISE.totalSupply fall by the
 *      burned amount, proving a genuine supply burn, not a move.
 *
 * The rotation index is read live: at the pinned deploy it is 0, so the
 * first burn takes 5% (500 bps). A second test walks the whole six-slot
 * sequence with fresh callers (each fresh address sidesteps the 1-day
 * per-caller `BURN_WISE_COOLDOWN`).
 */
contract WiseBurnEthUsdcFork is Test {

    address internal constant VAULT =
        0x7e1EFF4301defc24936470B30bd1c686D2a295dc;

    uint256 internal constant PRECISION_RATE = 10_000;

    uint256 internal constant SEQUENCE_LENGTH = 6;

    IWtnBurn internal v;
    IERC20 internal wise;

    function setUp()
        public
    {
        vm.createSelectFork(
            "mainnet"
        );

        require(
            VAULT.code.length > 0,
            "eth usdc diamond not deployed on this fork"
        );

        v = IWtnBurn(
            VAULT
        );

        wise = IERC20(
            v.WISE_TOKEN()
        );

        require(
            address(wise) != address(0),
            "WISE_TOKEN not configured on the live vault"
        );
    }

    /**
     * @dev "Send WISE to the contract": mint WISE to a fresh sender via
     * `deal`, then have them ERC20-transfer it into the diamond. A plain
     * transfer runs no diamond code (transfer never calls the recipient),
     * so this credits the diamond's WISE balance exactly like a real send.
     */
    function _sendWiseToVault(
        uint256 _amount
    )
        internal
    {
        address sender = makeAddr(
            "wiseSender"
        );

        deal(
            address(wise),
            sender,
            _amount
        );

        require(
            wise.balanceOf(sender) == _amount,
            "could not mint WISE to sender (deal slot?)"
        );

        vm.prank(
            sender
        );

        wise.transfer(
            VAULT,
            _amount
        );
    }

    function _pctString(
        uint256 _bps
    )
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            vm.toString(_bps / 100),
            "%"
        );
    }

    // ---- one send + one burn: reports the slice actually burned ----

    function test_ethUsdc_sendWise_thenBurn_reportsPercentBurned()
        public
    {
        uint256 seed = 1_000 ether; // 1,000 WISE (18 decimals)

        _sendWiseToVault(
            seed
        );

        uint256 scheduledBps = v.getNextBurnPercentage();
        uint256 indexBefore = v.burnWiseIndex();
        uint256 balBefore = wise.balanceOf(VAULT);
        uint256 supplyBefore = wise.totalSupply();

        uint256 expectedBurn = balBefore
            * scheduledBps
            / PRECISION_RATE;

        address caller = makeAddr(
            "wiseBurner"
        );

        vm.prank(
            caller
        );

        uint256 amount = v.burnWise();

        emit log_string("--- burnWise() on LIVE ETH USDC vault ---");
        emit log_named_uint("WISE sent to vault (wei)", seed);
        emit log_named_uint("rotation index before", indexBefore);
        emit log_named_uint("scheduled slice (bps)", scheduledBps);
        emit log_named_string("scheduled slice (percent)", _pctString(scheduledBps));
        emit log_named_uint("WISE burned (wei)", amount);
        emit log_named_uint("vault WISE before", balBefore);
        emit log_named_uint("vault WISE after", wise.balanceOf(VAULT));
        emit log_named_uint("WISE totalSupply drop", supplyBefore - wise.totalSupply());
        emit log_named_uint("rotation index after", v.burnWiseIndex());

        assertEq(
            amount,
            expectedBurn,
            "burned amount != scheduled slice of balance"
        );

        assertEq(
            wise.balanceOf(VAULT),
            balBefore - amount,
            "vault WISE balance not reduced by the burn"
        );

        assertEq(
            supplyBefore - wise.totalSupply(),
            amount,
            "WISE totalSupply did not fall by the burn (not a real burn)"
        );

        assertEq(
            v.burnWiseIndex(),
            (indexBefore + 1) % SEQUENCE_LENGTH,
            "rotation index did not advance by one"
        );
    }

    // ---- full rotation: shows every slice 5/10/20/15/5/1% in order ----

    function test_ethUsdc_burnWise_fullRotationSequence()
        public
    {
        uint256[6] memory scheduleBps = [
            uint256(500),
            1000,
            2000,
            1500,
            500,
            100
        ];

        uint256 startIndex = v.burnWiseIndex();

        emit log_string("--- 6 sequential burns (fresh callers dodge the 1-day cooldown) ---");
        emit log_named_uint("starting rotation index", startIndex);

        for (uint256 i; i < SEQUENCE_LENGTH; ++i) {

            _sendWiseToVault(
                1_000 ether - wise.balanceOf(VAULT)
            );

            uint256 bps = v.getNextBurnPercentage();
            uint256 balBefore = wise.balanceOf(VAULT);
            uint256 supplyBefore = wise.totalSupply();

            address caller = makeAddr(
                string.concat("burner-", vm.toString(i))
            );

            vm.prank(
                caller
            );

            uint256 amount = v.burnWise();

            emit log_named_string(
                string.concat("slot ", vm.toString((startIndex + i) % SEQUENCE_LENGTH), " slice"),
                _pctString(bps)
            );
            emit log_named_uint(
                string.concat("slot ", vm.toString((startIndex + i) % SEQUENCE_LENGTH), " burned (wei)"),
                amount
            );

            assertEq(
                bps,
                scheduleBps[(startIndex + i) % SEQUENCE_LENGTH],
                "unexpected scheduled slice for this rotation slot"
            );

            assertEq(
                amount,
                balBefore * bps / PRECISION_RATE,
                "burned amount != slice of current balance"
            );

            assertEq(
                supplyBefore - wise.totalSupply(),
                amount,
                "totalSupply not reduced by the burn"
            );
        }
    }
}
