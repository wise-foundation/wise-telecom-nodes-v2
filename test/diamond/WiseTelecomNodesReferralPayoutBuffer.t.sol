// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {WiseTelecomNodesInitParams} from "../../src/diamond/vault/WiseTelecomNodesDiamondStructs.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {ProxyFacet} from "../../src/diamond/vault/facets/ProxyFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {SweepFacet} from "../../src/diamond/vault/facets/SweepFacet.sol";
import {CashedInterestFacet} from "../../src/diamond/vault/facets/CashedInterestFacet.sol";
import {ReferralPayoutFacet} from "../../src/diamond/vault/facets/pending/ReferralPayoutFacet.sol";

import {WiseTelecomNodesDiamondErrors} from "../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

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
 * @dev Dormant-accumulator suite: proves the `pendingReferralPayout`
 * tail shard (slot 76) enters `_calculateNeededBuffer` as one more
 * additive liability term (the exact `totalCashedInterest` pattern)
 * while remaining fully dormant (no writer exists yet, so
 * `vm.store` on slot 76 stands in for the not-yet-existing hub
 * payout intake). The slot-pin test couples every `vm.store` here to
 * the routed getter, so a future renumbering fails loudly in one
 * place. The dormancy test walks the real user flows (deposit, accrue,
 * claim, sweep) asserting the slot stays zero; it is the guard that
 * fires the day a writer is wired into any user path, forcing a
 * conscious migration of this suite. The gas-ceiling test pins
 * `sweepOverhang` with a nonzero accumulator so any future fattening
 * of the buffer calculation (loops, per-user mappings) fails a
 * regression instead of slipping into the sweep path unnoticed.
 */
contract WiseTelecomNodesReferralPayoutBufferTest is Test {

    MockUSD usd;
    WiseTelecomNodesDiamond diamond;

    address thirdPty = address(0xCAFE);
    address worker = address(0xD00D);
    address user1 = address(0xA1);
    address randomEOA = address(0xBADCAFE);

    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000_000 * 1e6;
    uint256 constant INTEREST_RATE = 2000;
    uint256 constant SECONDS_IN_YEAR = 31_540_000;
    uint256 constant SECONDS_IN_TWO_WEEKS = 14 days;
    uint256 constant PRECISION_RATE = 10_000;
    uint256 constant PRECISION_FACTOR_E18 = 1e18;
    uint256 constant PENDING_REFERRAL_PAYOUT_SLOT = 76;
    uint256 constant SWEEP_GAS_CEILING = 90_000;

    function setUp()
        public
    {
        usd = new MockUSD();

        vm.warp(
            1_700_000_000
        );

        diamond = _deployFromTest(
            worker
        );
    }

    function _buildInitParams(
        address _worker
    )
        internal
        view
        returns (WiseTelecomNodesInitParams memory)
    {
        return WiseTelecomNodesInitParams({
            usdAddress: address(usd),
            thirdPartyAddress: thirdPty,
            workerAddress: _worker,
            oldVault: address(0),
            initialDistributionAddresses: new address[](0),
            initialDistributionAmounts: new uint256[](0),
            totalDepositCap: TOTAL_DEPOSIT_CAP,
            interestRate: INTEREST_RATE,
            decimalsValue: 6,
            tokenName: "Wise Telecom Nodes",
            tokenSymbol: "WTN"
        });
    }

    function _deployFromTest(
        address _worker
    )
        internal
        returns (WiseTelecomNodesDiamond d)
    {
        AdminFacet admin = new AdminFacet();
        ProxyFacet proxyF = new ProxyFacet();
        UserFacet userF = new UserFacet();
        SweepFacet sweepF = new SweepFacet();
        CashedInterestFacet cashedF = new CashedInterestFacet();
        ReferralPayoutFacet payoutF = new ReferralPayoutFacet();

        d = new WiseTelecomNodesDiamond(
            _buildInitParams(
                _worker
            )
        );

        bytes4[] memory adminSels = WiseTelecomNodesDiamondSelectors._adminSelectors();
        bytes4[] memory proxySels = WiseTelecomNodesDiamondSelectors._proxySelectors();
        bytes4[] memory userSels = WiseTelecomNodesDiamondSelectors._userSelectors();
        bytes4[] memory sweepSels = WiseTelecomNodesDiamondSelectors._sweepSelectors();
        bytes4[] memory cashedSels = WiseTelecomNodesDiamondSelectors._cashedInterestSelectors();
        bytes4[] memory payoutSels = WiseTelecomNodesDiamondSelectors._referralPayoutSelectors();

        d.proposeSelectors(
            adminSels,
            address(admin)
        );

        d.proposeSelectors(
            proxySels,
            address(proxyF)
        );

        d.proposeSelectors(
            userSels,
            address(userF)
        );

        d.proposeSelectors(
            sweepSels,
            address(sweepF)
        );

        d.proposeSelectors(
            cashedSels,
            address(cashedF)
        );

        d.proposeSelectors(
            payoutSels,
            address(payoutF)
        );

        d.executeSelectorChanges(
            adminSels
        );

        d.executeSelectorChanges(
            proxySels
        );

        d.executeSelectorChanges(
            userSels
        );

        d.executeSelectorChanges(
            sweepSels
        );

        d.executeSelectorChanges(
            cashedSels
        );

        d.executeSelectorChanges(
            payoutSels
        );

        d.finalizeSetup();
    }

    function _expectedBuffer(
        uint256 _principal,
        uint256 _interestRate
    )
        internal
        pure
        returns (uint256)
    {
        if (_principal == 0) {
            return 0;
        }

        uint256 yearFactor = SECONDS_IN_TWO_WEEKS
            * PRECISION_FACTOR_E18
            / SECONDS_IN_YEAR;

        return _principal
            * _interestRate
            * yearFactor
            / PRECISION_RATE
            / PRECISION_FACTOR_E18;
    }

    function _accrueCashedInterest(
        address _user,
        uint256 _warpSeconds
    )
        internal
        returns (uint256)
    {
        vm.warp(
            block.timestamp + _warpSeconds
        );

        vm.prank(
            address(diamond)
        );

        ProxyFacet(address(diamond)).triggerAssignInterest(
            _user
        );

        return diamond.cashedInterest(
            _user
        );
    }

    function _setPendingPayout(
        uint256 _value
    )
        internal
    {
        vm.store(
            address(diamond),
            bytes32(PENDING_REFERRAL_PAYOUT_SLOT),
            bytes32(_value)
        );
    }

    function _pendingPayoutSlotValue()
        internal
        view
        returns (uint256)
    {
        return uint256(
            vm.load(
                address(diamond),
                bytes32(PENDING_REFERRAL_PAYOUT_SLOT)
            )
        );
    }

    // ---- 1. slot pin: slot 76 backs the routed getter ----

    function test_storageSlot76_backsPendingReferralPayout()
        public
    {
        uint256 value = 777_777 * 1e6;

        _setPendingPayout(
            value
        );

        assertEq(
            ReferralPayoutFacet(address(diamond)).getPendingReferralPayout(),
            value
        );
    }

    // ---- 2. getter default ----

    function test_getPendingReferralPayout_defaultZero()
        public
        view
    {
        assertEq(
            ReferralPayoutFacet(address(diamond)).getPendingReferralPayout(),
            0
        );
    }

    // ---- 3. reserve grows by exactly the pending payout ----

    function test_getOverhang_pendingPayout_growsReserveByExactlyPending()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 funded = 300_000 * 1e6;
        uint256 pending = 40_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + funded
        );

        uint256 overhangBefore = SweepFacet(address(diamond)).getOverhang();

        assertEq(
            overhangBefore,
            funded
        );

        _setPendingPayout(
            pending
        );

        assertEq(
            overhangBefore - SweepFacet(address(diamond)).getOverhang(),
            pending
        );
    }

    // ---- 4. overhang is zero at exactly the full three-term reserve ----

    function test_getOverhang_zeroAtExactFullReserve_withPendingPayout()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 pending = 12_345 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 cashed = _accrueCashedInterest(
            user1,
            SECONDS_IN_YEAR
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        _setPendingPayout(
            pending
        );

        usd.mint(
            address(diamond),
            buffer + cashed + pending
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            0
        );
    }

    // ---- 5. balance covering only the payout liability: no sweep ----

    function test_sweepOverhang_balanceOnlyCoversPendingPayout_revertsNoOverhang()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 pending = 55_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        _setPendingPayout(
            pending
        );

        usd.mint(
            address(diamond),
            pending
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();
    }

    // ---- 6. sweep reserves the payout, takes only the excess ----

    function test_sweepOverhang_reservesPendingPayout_sweepsOnlyExcess()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 pending = 80_000 * 1e6;
        uint256 excess = 50_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        _setPendingPayout(
            pending
        );

        usd.mint(
            address(diamond),
            buffer + pending + excess
        );

        AdminFacet(address(diamond)).setSweeper(
            randomEOA,
            true
        );

        vm.prank(
            randomEOA
        );

        uint256 swept = SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            swept,
            excess
        );

        assertEq(
            usd.balanceOf(
                address(diamond)
            ),
            buffer + pending
        );

        vm.prank(
            randomEOA
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NoOverhang.selector
        );

        SweepFacet(address(diamond)).sweepOverhang();
    }

    // ---- 7. zero supply: early return reserves the payout ----

    function test_getOverhang_zeroSupply_reservesPendingPayout()
        public
    {
        uint256 pending = 9_000 * 1e6;
        uint256 excess = 4_000 * 1e6;

        _setPendingPayout(
            pending
        );

        usd.mint(
            address(diamond),
            pending + excess
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            excess
        );
    }

    // ---- 8. zero supply: balance == payout boundary ----

    function test_getOverhang_zeroSupply_balanceEqualsPending_returnsZero()
        public
    {
        uint256 pending = 9_000 * 1e6;

        _setPendingPayout(
            pending
        );

        usd.mint(
            address(diamond),
            pending
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            0
        );
    }

    // ---- 9. both liabilities add, not replace ----

    function test_getOverhang_pendingAndCashedInterest_liabilitiesAdd()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 funded = 200_000 * 1e6;
        uint256 pending = 30_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + funded
        );

        uint256 cashed = _accrueCashedInterest(
            user1,
            SECONDS_IN_YEAR / 4
        );

        _setPendingPayout(
            pending
        );

        assertEq(
            SweepFacet(address(diamond)).getOverhang(),
            funded - cashed - pending
        );
    }

    // ---- 10. dormancy: no user flow ever writes slot 76 ----

    function test_pendingReferralPayout_dormantThroughUserFlows()
        public
    {
        uint256 amount = 100_000 * 1e6;

        usd.mint(
            user1,
            amount
        );

        vm.prank(
            user1
        );

        usd.approve(
            address(diamond),
            amount
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).deposit(
            amount
        );

        assertEq(
            _pendingPayoutSlotValue(),
            0
        );

        uint256 cashed = _accrueCashedInterest(
            user1,
            SECONDS_IN_YEAR
        );

        assertEq(
            _pendingPayoutSlotValue(),
            0
        );

        uint256 buffer = _expectedBuffer(
            amount,
            INTEREST_RATE
        );

        usd.mint(
            address(diamond),
            buffer + cashed + 10_000 * 1e6
        );

        vm.prank(
            user1
        );

        UserFacet(address(diamond)).claimInterest();

        assertEq(
            _pendingPayoutSlotValue(),
            0
        );

        AdminFacet(address(diamond)).setSweeper(
            randomEOA,
            true
        );

        vm.prank(
            randomEOA
        );

        SweepFacet(address(diamond)).sweepOverhang();

        assertEq(
            _pendingPayoutSlotValue(),
            0
        );
    }

    // ---- 11. direct facet call reads the facet's own zero storage ----

    function test_getPendingReferralPayout_directFacetCall_readsFacetStorageZero()
        public
    {
        ReferralPayoutFacet payoutF = new ReferralPayoutFacet();

        _setPendingPayout(
            123 * 1e6
        );

        assertEq(
            payoutF.getPendingReferralPayout(),
            0
        );
    }

    // ---- 12. gas ceiling: the extra liability term stays one SLOAD ----

    function test_sweepOverhang_gasCeiling_withPendingPayout()
        public
    {
        uint256 principal = 1_000_000 * 1e6;
        uint256 pending = 80_000 * 1e6;
        uint256 excess = 50_000 * 1e6;

        AdminFacet(address(diamond)).mintSupply(
            user1,
            principal
        );

        uint256 buffer = _expectedBuffer(
            principal,
            INTEREST_RATE
        );

        _setPendingPayout(
            pending
        );

        usd.mint(
            address(diamond),
            buffer + pending + excess
        );

        usd.mint(
            worker,
            1
        );

        AdminFacet(address(diamond)).setSweeper(
            randomEOA,
            true
        );

        vm.prank(
            randomEOA
        );

        uint256 gasBefore = gasleft();

        SweepFacet(address(diamond)).sweepOverhang();

        uint256 gasUsed = gasBefore - gasleft();

        assertLe(
            gasUsed,
            SWEEP_GAS_CEILING
        );
    }
}
