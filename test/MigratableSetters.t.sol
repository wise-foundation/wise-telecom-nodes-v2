// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ForwardVaultERC20Migratable} from "../src/migration/ForwardVaultERC20Migratable.sol";
import {QueContractMigratable} from "../src/migration/QueContractMigratable.sol";

contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "MUSD") {}

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 6;
    }
}

contract MigratableSettersTest is Test {

    MockUSD usd;
    ForwardVaultERC20Migratable vault;
    QueContractMigratable       que;

    address master    = address(this);
    address user1     = address(0xA1);
    address user2     = address(0xA2);
    address user3     = address(0xA3);
    address nonMaster = address(0xBEEF);

    address constant THIRD_PARTY = address(0xDEAD);

    uint256 constant TOTAL_DEPOSIT_CAP        = 1_000_000 * 1e6;
    uint256 constant INTEREST_RATE            = 2000;
    uint256 constant AUTO_COMPOUND_INCENTIVE  = 500;

    function setUp()
        public
    {
        usd = new MockUSD();

        address[] memory addrs = new address[](0);
        uint256[] memory amts  = new uint256[](0);

        vault = new ForwardVaultERC20Migratable(
            address(usd),
            THIRD_PARTY,
            address(0),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INCENTIVE,
            6,
            "Vault",
            "V"
        );

        que = new QueContractMigratable(
            address(vault)
        );
    }

    // ============================================================
    // ForwardVaultERC20Migratable.setProxyBalance
    // ============================================================

    function test_setProxyBalance_master_writes()
        public
    {
        assertEq(
            vault.proxyBalance(user1),
            0,
            "initial"
        );

        vault.setProxyBalance(
            user1,
            1_000_000
        );

        assertEq(
            vault.proxyBalance(user1),
            1_000_000,
            "after set"
        );
    }

    function test_setProxyBalance_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        vault.setProxyBalance(user1, 1);
    }

    function test_setProxyBalance_overwrite()
        public
    {
        vault.setProxyBalance(user1, 100);
        vault.setProxyBalance(user1, 999);

        assertEq(
            vault.proxyBalance(user1),
            999,
            "overwrite"
        );
    }

    function test_setProxyBalance_zero()
        public
    {
        vault.setProxyBalance(user1, 100);
        vault.setProxyBalance(user1, 0);

        assertEq(
            vault.proxyBalance(user1),
            0,
            "zeroed"
        );
    }

    function test_setProxyBalance_multipleUsers_independent()
        public
    {
        vault.setProxyBalance(user1, 111);
        vault.setProxyBalance(user2, 222);
        vault.setProxyBalance(user3, 333);

        assertEq(vault.proxyBalance(user1), 111, "user1");
        assertEq(vault.proxyBalance(user2), 222, "user2");
        assertEq(vault.proxyBalance(user3), 333, "user3");
    }

    function testFuzz_setProxyBalance(
        address _user,
        uint256 _amount
    )
        public
    {
        vault.setProxyBalance(_user, _amount);
        assertEq(vault.proxyBalance(_user), _amount);
    }

    // ============================================================
    // QueContractMigratable.setQueMember
    // ============================================================

    function test_setQueMember_master_writesAllFields()
        public
    {
        que.setQueMember(
            7,
            500,
            user1,
            12345,
            6,
            8
        );

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = que.QueMemberByIdAndIncentive(7, 500);

        assertEq(m, user1, "member");
        assertEq(a, 12345, "amount");
        assertEq(t, 6,     "tail");
        assertEq(h, 8,     "head");
    }

    function test_setQueMember_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setQueMember(0, 0, user1, 1, 0, 0);
    }

    function test_setQueMember_negativeIncentive()
        public
    {
        que.setQueMember(
            3,
            -2500,
            user2,
            777,
            2,
            4
        );

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = que.QueMemberByIdAndIncentive(3, -2500);

        assertEq(m, user2, "negIncentive member");
        assertEq(a, 777,   "negIncentive amount");
        assertEq(t, 2,     "negIncentive tail");
        assertEq(h, 4,     "negIncentive head");
    }

    function test_setQueMember_isolated_acrossSlots()
        public
    {
        que.setQueMember(0, 100, user1, 1, 0, 1);
        que.setQueMember(1, 100, user2, 2, 0, 2);
        que.setQueMember(2, 100, user3, 3, 1, 3);

        (address m0,,,) = que.QueMemberByIdAndIncentive(0, 100);
        (address m1,,,) = que.QueMemberByIdAndIncentive(1, 100);
        (address m2,,,) = que.QueMemberByIdAndIncentive(2, 100);

        assertEq(m0, user1, "slot 0");
        assertEq(m1, user2, "slot 1");
        assertEq(m2, user3, "slot 2");
    }

    function test_setQueMember_isolated_acrossIncentives()
        public
    {
        que.setQueMember(0, 100,  user1, 1, 0, 0);
        que.setQueMember(0, 200,  user2, 2, 0, 0);
        que.setQueMember(0, -300, user3, 3, 0, 0);

        (address m100,,,)  = que.QueMemberByIdAndIncentive(0, 100);
        (address m200,,,)  = que.QueMemberByIdAndIncentive(0, 200);
        (address mn300,,,) = que.QueMemberByIdAndIncentive(0, -300);

        assertEq(m100,  user1, "inc=100");
        assertEq(m200,  user2, "inc=200");
        assertEq(mn300, user3, "inc=-300");
    }

    function test_setQueMember_overwrite()
        public
    {
        que.setQueMember(0, 100, user1, 11, 0, 0);
        que.setQueMember(0, 100, user2, 22, 1, 2);

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = que.QueMemberByIdAndIncentive(0, 100);

        assertEq(m, user2, "overwritten member");
        assertEq(a, 22,    "overwritten amount");
        assertEq(t, 1,     "overwritten tail");
        assertEq(h, 2,     "overwritten head");
    }

    // ============================================================
    // QueContractMigratable.setEarliestValidQueMemberByIncentive
    // ============================================================

    function test_setEarliestValid_master()
        public
    {
        que.setEarliestValidQueMemberByIncentive(500, 42);
        assertEq(
            que.earliestValidQueMemberByIncentive(500),
            42
        );
    }

    function test_setEarliestValid_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setEarliestValidQueMemberByIncentive(500, 42);
    }

    function test_setEarliestValid_perIncentiveIsolated()
        public
    {
        que.setEarliestValidQueMemberByIncentive(100, 5);
        que.setEarliestValidQueMemberByIncentive(200, 9);

        assertEq(que.earliestValidQueMemberByIncentive(100), 5);
        assertEq(que.earliestValidQueMemberByIncentive(200), 9);
    }

    // ============================================================
    // QueContractMigratable.setCurrentOrderIdByIncentive
    // ============================================================

    function test_setCurrentOrderId_master()
        public
    {
        que.setCurrentOrderIdByIncentive(500, 13);
        assertEq(
            que.currentOrderIdByIncentive(500),
            13
        );
    }

    function test_setCurrentOrderId_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setCurrentOrderIdByIncentive(500, 1);
    }

    // ============================================================
    // QueContractMigratable.setActiveOrderCountByIncentive
    // ============================================================

    function test_setActiveOrderCount_master()
        public
    {
        que.setActiveOrderCountByIncentive(500, 7);
        assertEq(
            que.activeOrderCountByIncentive(500),
            7
        );
    }

    function test_setActiveOrderCount_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setActiveOrderCountByIncentive(500, 1);
    }

    // ============================================================
    // QueContractMigratable.setTotalActiveOrders
    // ============================================================

    function test_setTotalActiveOrders_master()
        public
    {
        que.setTotalActiveOrders(99);
        assertEq(que.totalActiveOrders(), 99);
    }

    function test_setTotalActiveOrders_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setTotalActiveOrders(1);
    }

    // ============================================================
    // QueContractMigratable.setMinDepositAmount
    // ============================================================

    function test_setMinDepositAmount_master()
        public
    {
        que.setMinDepositAmount(123_456);
        assertEq(que.minDepositAmount(), 123_456);
    }

    function test_setMinDepositAmount_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setMinDepositAmount(1);
    }

    // ============================================================
    // QueContractMigratable.setIncentiveAllowed
    // ============================================================

    function test_setIncentiveAllowed_master()
        public
    {
        // Default constructor allows all 17 standard incentives;
        // setter must be able to flip both directions.
        que.setIncentiveAllowed(500, false);
        assertFalse(que.incentiveAllowed(500));

        que.setIncentiveAllowed(500, true);
        assertTrue(que.incentiveAllowed(500));

        // Add a non-default incentive.
        que.setIncentiveAllowed(7777, true);
        assertTrue(que.incentiveAllowed(7777));
    }

    function test_setIncentiveAllowed_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setIncentiveAllowed(500, false);
    }

    // ============================================================
    // QueContractMigratable.setPerIncentiveState (bundle of 4)
    // ============================================================

    function test_setPerIncentiveState_writesAllFields()
        public
    {
        que.setPerIncentiveState(
            -1500,
            9,
            7,
            5,
            true
        );

        assertEq(que.earliestValidQueMemberByIncentive(-1500), 9, "earliest");
        assertEq(que.currentOrderIdByIncentive(-1500),         7, "current");
        assertEq(que.activeOrderCountByIncentive(-1500),       5, "active");
        assertTrue(que.incentiveAllowed(-1500),                   "allowed");
    }

    function test_setPerIncentiveState_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setPerIncentiveState(0, 1, 1, 1, true);
    }

    function test_setPerIncentiveState_perIncentiveIsolated()
        public
    {
        que.setPerIncentiveState(100, 1, 2, 3, true);
        que.setPerIncentiveState(200, 4, 5, 6, false);

        assertEq(que.earliestValidQueMemberByIncentive(100), 1);
        assertEq(que.currentOrderIdByIncentive(100),         2);
        assertEq(que.activeOrderCountByIncentive(100),       3);
        assertTrue(que.incentiveAllowed(100));

        assertEq(que.earliestValidQueMemberByIncentive(200), 4);
        assertEq(que.currentOrderIdByIncentive(200),         5);
        assertEq(que.activeOrderCountByIncentive(200),       6);
        assertFalse(que.incentiveAllowed(200));
    }

    // ============================================================
    // QueContractMigratable.setGlobalState (bundle of 3)
    // ============================================================

    function test_setGlobalState_writesAllFields()
        public
    {
        que.setGlobalState(
            42,
            12_345,
            true
        );

        assertEq(que.totalActiveOrders(),            42,     "totalActive");
        assertEq(que.minDepositAmount(),             12_345, "minDeposit");
        assertTrue(que.negativeIncentivesNotAllowed(),       "negNotAllowed");
    }

    function test_setGlobalState_nonMaster_reverts()
        public
    {
        vm.prank(nonMaster);
        vm.expectRevert();
        que.setGlobalState(1, 1, true);
    }

    function test_setGlobalState_overwrite()
        public
    {
        que.setGlobalState(1,   100, true);
        que.setGlobalState(99, 9000, false);

        assertEq(que.totalActiveOrders(),                  99,    "overwritten total");
        assertEq(que.minDepositAmount(),                   9000,  "overwritten min");
        assertFalse(que.negativeIncentivesNotAllowed(),           "overwritten neg");
    }

    // ============================================================
    // Round-trip: set many slots, read each back, all match
    // ============================================================

    function test_bulk_setQueMember_roundTrip_all_match()
        public
    {
        uint256 N = 25;
        address[] memory addrs   = new address[](N);
        uint256[] memory amounts = new uint256[](N);
        uint256[] memory tails   = new uint256[](N);
        uint256[] memory heads   = new uint256[](N);

        for (uint256 i; i < N; ++i) {
            addrs[i]   = address(uint160(0xC0FFEE + i));
            amounts[i] = (i + 1) * 1e6;
            tails[i]   = i == 0 ? 0 : i - 1;
            heads[i]   = i + 1;
        }

        for (uint256 i; i < N; ++i) {
            que.setQueMember(
                i,
                500,
                addrs[i],
                amounts[i],
                tails[i],
                heads[i]
            );
        }

        for (uint256 i; i < N; ++i) {
            (
                address m,
                uint256 a,
                uint256 t,
                uint256 h
            ) = que.QueMemberByIdAndIncentive(i, 500);

            assertEq(m, addrs[i],   "member");
            assertEq(a, amounts[i], "amount");
            assertEq(t, tails[i],   "tail");
            assertEq(h, heads[i],   "head");
        }
    }

    function test_bulk_setPerIncentiveState_acrossAll17_roundTrip()
        public
    {
        int256[17] memory incs = [
            int256(100), int256(200), int256(300), int256(500), int256(1000),
            int256(1500), int256(2500), int256(5000),
            int256(0),
            int256(-100), int256(-200), int256(-300), int256(-500),
            int256(-1000), int256(-1500), int256(-2500), int256(-5000)
        ];

        for (uint256 i; i < incs.length; ++i) {
            que.setPerIncentiveState(
                incs[i],
                100 + i,
                200 + i,
                300 + i,
                i % 2 == 0
            );
        }

        for (uint256 i; i < incs.length; ++i) {
            assertEq(
                que.earliestValidQueMemberByIncentive(incs[i]),
                100 + i,
                "earliest mismatch"
            );
            assertEq(
                que.currentOrderIdByIncentive(incs[i]),
                200 + i,
                "current mismatch"
            );
            assertEq(
                que.activeOrderCountByIncentive(incs[i]),
                300 + i,
                "active mismatch"
            );
            assertEq(
                que.incentiveAllowed(incs[i]),
                i % 2 == 0,
                "allowed mismatch"
            );
        }
    }
}
