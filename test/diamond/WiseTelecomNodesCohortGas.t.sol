// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

import {DiamondTestHarness} from "./utils/DiamondTestHarness.sol";

contract MockUSD is ERC20 {

    constructor()
        ERC20("Mock USD", "MUSD")
    {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(
            _to,
            _amount
        );
    }
}

/**
 * @dev Gas-bound proof for the cohort recorder's dormancy handling.
 * Measurements are gasleft() deltas around a raw `.call()` with the
 * calldata encoded and the caller pranked strictly before the window,
 * mirroring the discipline in `test/fenwick/ReferralTopDecileGas.t.sol`.
 * Every cell pins one claim from {CohortRecorderBase}'s @dev block:
 * the settle walk is hard-capped at `MAX_SETTLE_BOUNDARIES = 104`
 * steps so a transfer hook can never be blocked by an arbitrarily
 * dormant book (cells 1-2, cell 2 showing the closed-form gap tail is
 * O(1) regardless of how far beyond the cap the dormancy runs);
 * `advanceBook` lets a keeper pre-walk that cost out of the hook path
 * in bounded chunks (cells 3-4); and the common case — tracked
 * balance already equal to held balance — exits `_syncRefereeCohort`
 * on two reads before touching any book state (cell 5). Ceilings are
 * committed constants set ~25% above measured gas on this commit;
 * `GAS_TABLE|` rows are logged at -vv so a regression shows the exact
 * delta against the last committed number.
 */
contract WiseTelecomNodesCohortGasTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant DIP_AMOUNT = 1 * 1e6;

    uint256 internal constant TRANSFER_HOOK_FULL_WALK_GAS_CEILING = 3_600_000;

    uint256 internal constant TRANSFER_HOOK_BEYOND_CAP_GAP_TOLERANCE = 150_000;

    uint256 internal constant TRANSFER_HOOK_PREWALKED_GAS_CEILING = 135_000;

    uint256 internal constant ADVANCE_BOOK_26_CHUNK_GAS_CEILING = 875_000;

    uint256 internal constant COMMON_TRANSFER_GAS_CEILING = 165_000;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);
    address internal outsider = address(0xC1);

    WiseTelecomNodesDiamond internal diamond;
    MockUSD internal usd;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            diamond,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );

        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    // ---- helpers ----

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        usd.approve(
            address(diamond),
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(diamond)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _transferAs(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        vm.prank(
            _from
        );

        diamond.transfer(
            _to,
            _amount
        );
    }

    function _measureTransfer(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
        returns (uint256 used)
    {
        bytes memory payload = abi.encodeWithSelector(
            diamond.transfer.selector,
            _to,
            _amount
        );

        vm.prank(
            _from
        );

        uint256 g = gasleft();

        (bool ok, ) = address(diamond).call(payload);

        used = g - gasleft();

        assertTrue(
            ok,
            "measured transfer reverted"
        );
    }

    function _measureAdvanceBook(
        address _referrer,
        uint256 _maxBoundaries
    )
        internal
        returns (uint256 used)
    {
        bytes memory payload = abi.encodeCall(
            CohortRecorderFacet.advanceBook,
            (_referrer, _maxBoundaries)
        );

        uint256 g = gasleft();

        (bool ok, ) = address(diamond).call(payload);

        used = g - gasleft();

        assertTrue(
            ok,
            "measured advanceBook reverted"
        );
    }

    function _prewalk(
        address _referrer
    )
        internal
    {
        for (uint256 i; i < 4; ++i) {

            (
                ,
                ,
                ,
                uint256 lastSettle
            ) = _recorder().getCohortBook(_referrer);

            if (lastSettle / 1 weeks == block.timestamp / 1 weeks) {
                return;
            }

            _recorder().advanceBook(
                _referrer,
                104
            );
        }
    }

    function _logGas(
        string memory _label,
        uint256 _used,
        uint256 _ceiling
    )
        internal
        pure
    {
        console2.log(
            string.concat(
                "GAS_TABLE|",
                _label,
                "|used="
            ),
            _used
        );

        console2.log(
            string.concat(
                "GAS_TABLE|",
                _label,
                "|ceiling="
            ),
            _ceiling
        );
    }

    // ---- cells ----

    function test_gas_transferHook_dormant104Weeks_fullWalk()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        _transferAs(
            user1,
            outsider,
            DIP_AMOUNT
        );

        uint256 used = _measureTransfer(
            user1,
            outsider,
            DIP_AMOUNT
        );

        _logGas(
            "transferHook_dormant104Weeks_fullWalk",
            used,
            TRANSFER_HOOK_FULL_WALK_GAS_CEILING
        );

        assertLe(
            used,
            TRANSFER_HOOK_FULL_WALK_GAS_CEILING,
            "gas: dormant 104-boundary full settle walk exceeded ceiling"
        );
    }

    function test_gas_transferHook_dormant156Weeks_flatBeyondCap()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        _transferAs(
            user1,
            outsider,
            DIP_AMOUNT
        );

        uint256 usedAtCap = _measureTransfer(
            user1,
            outsider,
            DIP_AMOUNT
        );

        _depositWithReferralAs(
            user2,
            DEPOSIT,
            refB
        );

        vm.warp(
            block.timestamp + 156 weeks
        );

        _transferAs(
            user2,
            outsider,
            DIP_AMOUNT
        );

        uint256 usedBeyondCap = _measureTransfer(
            user2,
            outsider,
            DIP_AMOUNT
        );

        _logGas(
            "transferHook_dormant156Weeks_flatBeyondCap",
            usedBeyondCap,
            usedAtCap + TRANSFER_HOOK_BEYOND_CAP_GAP_TOLERANCE
        );

        assertLe(
            usedBeyondCap,
            usedAtCap + TRANSFER_HOOK_BEYOND_CAP_GAP_TOLERANCE,
            "gas: dormancy beyond MAX_SETTLE_BOUNDARIES not flat"
        );
    }

    function test_gas_transferHook_afterAdvanceBookPrewalk_cheap()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        _prewalk(
            refA
        );

        _transferAs(
            user1,
            outsider,
            DIP_AMOUNT
        );

        uint256 used = _measureTransfer(
            user1,
            outsider,
            DIP_AMOUNT
        );

        _logGas(
            "transferHook_afterAdvanceBookPrewalk_cheap",
            used,
            TRANSFER_HOOK_PREWALKED_GAS_CEILING
        );

        assertLe(
            used,
            TRANSFER_HOOK_PREWALKED_GAS_CEILING,
            "gas: pre-walked dormant book transfer exceeded ceiling"
        );
    }

    function test_gas_advanceBook_26BoundaryChunk()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            BASE_TIME + 105 weeks
        );

        uint256 used = _measureAdvanceBook(
            refA,
            26
        );

        _logGas(
            "advanceBook_26BoundaryChunk",
            used,
            ADVANCE_BOOK_26_CHUNK_GAS_CEILING
        );

        assertLe(
            used,
            ADVANCE_BOOK_26_CHUNK_GAS_CEILING,
            "gas: 26-boundary advanceBook chunk exceeded ceiling"
        );
    }

    function test_gas_commonTransfer_noDeficitCheap()
        public
    {
        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 1 days
        );

        uint256 used = _measureTransfer(
            user1,
            outsider,
            DIP_AMOUNT
        );

        _logGas(
            "commonTransfer_noDeficitCheap",
            used,
            COMMON_TRANSFER_GAS_CEILING
        );

        assertLe(
            used,
            COMMON_TRANSFER_GAS_CEILING,
            "gas: common no-deficit transfer exceeded ceiling"
        );
    }
}
