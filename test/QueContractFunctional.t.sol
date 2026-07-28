// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ForwardVaultERC20Migratable} from "../src/migration/ForwardVaultERC20Migratable.sol";
import {QueContractMigratable}       from "../src/migration/QueContractMigratable.sol";
import {QueContract}                 from "../src/legacy/que/QueContractLegacy.sol";

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

    function mint(
        address _to,
        uint256 _amount
    )
        external
    {
        _mint(_to, _amount);
    }
}

/**
 * Comprehensive functional + post-migration tests for QueContractMigratable.
 *
 * Setup is fully local (no fork): MockUSD, fresh vault + que. Users are
 * funded with vault tokens via `mintSupply`, and approve the queContract.
 * Fulfillers are funded with USD and approve the queContract.
 *
 * Sections:
 *   1. joinQue / leaveQue / reduceQueAmount
 *   2. fulfillOrder / partiallyFulfillOrder / fulfillOrderBulk
 *   3. View helpers (predict / solve / list)
 *   4. Master-only functions
 *   5. Mimicry — naturally-built state vs setter-replicated state byte-equal
 *   6. Post-migration usability — after replication, normal flows still work
 */
contract QueContractFunctionalTest is Test {

    MockUSD                       usd;
    ForwardVaultERC20Migratable   vault;
    QueContractMigratable         que;

    address master   = address(this);
    address thirdPty = address(0xCAFE);

    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);
    address fulf  = address(0xF1);

    uint256 constant TOTAL_DEPOSIT_CAP = 100_000_000 * 1e6;
    uint256 constant INTEREST_RATE     = 2000;
    uint256 constant AUTO_COMPOUND_INC = 500;

    uint256 constant MIN_DEPOSIT       = 50 * 1e6;

    function setUp()
        public
    {
        usd = new MockUSD();

        address[] memory addrs = new address[](0);
        uint256[] memory amts  = new uint256[](0);

        vault = new ForwardVaultERC20Migratable(
            address(usd),
            thirdPty,
            address(0),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INC,
            6,
            "Vault",
            "V"
        );

        que = new QueContractMigratable(
            address(vault)
        );

        vault.setInterestRateProxy(
            address(que)
        );

        _fundUserWithVaultTokens(user1, 10_000 * 1e6);
        _fundUserWithVaultTokens(user2, 10_000 * 1e6);
        _fundUserWithVaultTokens(user3, 10_000 * 1e6);

        usd.mint(fulf, 100_000 * 1e6);
        vm.prank(fulf);
        usd.approve(address(que), type(uint256).max);
    }

    function _fundUserWithVaultTokens(
        address _user,
        uint256 _amount
    )
        internal
    {
        vault.mintSupply(_user, _amount);

        vm.prank(_user);
        IERC20(address(vault)).approve(address(que), type(uint256).max);
    }

    // ============================================================
    // 1. joinQue / leaveQue / reduceQueAmount
    // ============================================================

    function test_joinQue_happyPath()
        public
    {
        uint256 amount = 100 * 1e6;

        vm.prank(user1);
        (, uint256 newId) = que.joinQue(amount, 500);

        assertEq(newId, 0, "first member id is 0");
        assertEq(que.totalActiveOrders(), 1, "total active");
        assertEq(que.activeOrderCountByIncentive(500), 1, "active per inc");
        assertEq(que.earliestValidQueMemberByIncentive(500), 1, "earliest advanced");

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = que.QueMemberByIdAndIncentive(0, 500);

        assertEq(m, user1,     "member");
        assertEq(a, amount,    "amount");
        assertEq(t, 0,         "tail");
        assertEq(h, 1,         "head");

        assertEq(IERC20(address(vault)).balanceOf(address(que)), amount, "que holds vault tokens");
        assertEq(vault.proxyBalance(user1),                       amount, "proxy balance set");
    }

    function test_joinQue_belowMinDeposit_reverts()
        public
    {
        vm.prank(user1);
        vm.expectRevert();
        que.joinQue(1, 500);
    }

    function test_joinQue_zeroAmount_reverts()
        public
    {
        vm.prank(user1);
        vm.expectRevert();
        que.joinQue(0, 500);
    }

    function test_joinQue_disallowedIncentive_reverts()
        public
    {
        vm.prank(user1);
        vm.expectRevert();
        que.joinQue(MIN_DEPOSIT, 999);
    }

    function test_joinQue_negativeIncentive_blockedByFlag()
        public
    {
        que.setNegativeIncentivesNotAllowed(true);

        vm.prank(user1);
        vm.expectRevert();
        que.joinQue(MIN_DEPOSIT, -500);

        que.setNegativeIncentivesNotAllowed(false);

        vm.prank(user1);
        que.joinQue(MIN_DEPOSIT, -500);

        assertEq(que.totalActiveOrders(), 1);
    }

    function test_joinQue_threeUsers_linkedListIntact()
        public
    {
        vm.prank(user1); que.joinQue(100 * 1e6, 500);
        vm.prank(user2); que.joinQue(200 * 1e6, 500);
        vm.prank(user3); que.joinQue(300 * 1e6, 500);

        assertEq(que.totalActiveOrders(),               3);
        assertEq(que.activeOrderCountByIncentive(500),  3);
        assertEq(que.earliestValidQueMemberByIncentive(500), 3);
        assertEq(que.currentOrderIdByIncentive(500),    0, "first order");

        (address m0,, uint256 t0, uint256 h0) = que.QueMemberByIdAndIncentive(0, 500);
        (address m1,, uint256 t1, uint256 h1) = que.QueMemberByIdAndIncentive(1, 500);
        (address m2,, uint256 t2, uint256 h2) = que.QueMemberByIdAndIncentive(2, 500);

        assertEq(m0, user1); assertEq(t0, 0); assertEq(h0, 1);
        assertEq(m1, user2); assertEq(t1, 0); assertEq(h1, 2);
        assertEq(m2, user3); assertEq(t2, 1); assertEq(h2, 3);

        // Sentinel slot at id=3 has tail set to 2.
        (,,uint256 sentinelTail,) = que.QueMemberByIdAndIncentive(3, 500);
        assertEq(sentinelTail, 2, "sentinel tail = last live");
    }

    function test_leaveQue_happyPath()
        public
    {
        vm.prank(user1);
        (, uint256 id) = que.joinQue(100 * 1e6, 500);

        uint256 vaultBalBefore = IERC20(address(vault)).balanceOf(user1);

        vm.prank(user1);
        que.leaveQue(id, 500);

        assertEq(que.totalActiveOrders(),              0);
        assertEq(que.activeOrderCountByIncentive(500), 0);

        (address m, uint256 a, uint256 t, uint256 h) = que.QueMemberByIdAndIncentive(id, 500);
        assertEq(m, address(0), "slot zeroed (member)");
        assertEq(a, 0,          "slot zeroed (amount)");
        assertEq(t, 0,          "slot zeroed (tail)");
        assertEq(h, 0,          "slot zeroed (head)");

        assertEq(
            IERC20(address(vault)).balanceOf(user1),
            vaultBalBefore + 100 * 1e6,
            "vault tokens returned"
        );
        assertEq(vault.proxyBalance(user1), 0, "proxy balance cleared");
    }

    function test_leaveQue_notMember_reverts()
        public
    {
        vm.prank(user1);
        que.joinQue(100 * 1e6, 500);

        vm.prank(user2);
        vm.expectRevert();
        que.leaveQue(0, 500);
    }

    function test_leaveQue_invalidId_reverts()
        public
    {
        vm.prank(user1);
        vm.expectRevert();
        que.leaveQue(99, 500);
    }

    function test_reduceQueAmount_happyPath()
        public
    {
        vm.prank(user1);
        que.joinQue(200 * 1e6, 500);

        uint256 balBefore = IERC20(address(vault)).balanceOf(user1);

        vm.prank(user1);
        que.reduceQueAmount(0, 500, 60 * 1e6);

        (, uint256 a,,) = que.QueMemberByIdAndIncentive(0, 500);
        assertEq(a, 140 * 1e6, "reduced amount");

        assertEq(
            IERC20(address(vault)).balanceOf(user1),
            balBefore + 60 * 1e6,
            "got tokens back"
        );
        assertEq(vault.proxyBalance(user1), 140 * 1e6, "proxy reduced");
    }

    function test_reduceQueAmount_belowMinDeposit_reverts()
        public
    {
        vm.prank(user1);
        que.joinQue(60 * 1e6, 500);

        // Reducing by 20 leaves 40 (below MIN_DEPOSIT of 50).
        vm.prank(user1);
        vm.expectRevert();
        que.reduceQueAmount(0, 500, 20 * 1e6);
    }

    // ============================================================
    // 2. fulfillOrder / partiallyFulfillOrder / fulfillOrderBulk
    // ============================================================

    function test_fulfillOrder_zeroIncentive_paysFull()
        public
    {
        uint256 amount = 100 * 1e6;

        vm.prank(user1);
        que.joinQue(amount, 0);

        uint256 user1UsdBefore = usd.balanceOf(user1);
        uint256 fulfVaultBefore = IERC20(address(vault)).balanceOf(fulf);

        vm.prank(fulf);
        (uint256 vt, uint256 sc) = que.fulfillOrder(0, 0);

        assertEq(vt, amount,              "vault tokens out = order amount");
        assertEq(sc, amount,              "USD in = full amount (zero discount)");
        assertEq(usd.balanceOf(user1),  user1UsdBefore + amount,  "user1 received USD");
        assertEq(IERC20(address(vault)).balanceOf(fulf), fulfVaultBefore + amount, "fulf received vault");

        (address m, uint256 a,,) = que.QueMemberByIdAndIncentive(0, 0);
        assertEq(m, address(0), "slot zeroed (member)");
        assertEq(a, 0,          "slot zeroed (amount)");
        assertEq(que.totalActiveOrders(), 0);
    }

    function test_fulfillOrder_positiveIncentive_givesDiscount()
        public
    {
        uint256 amount = 100 * 1e6;
        int256  inc    = 500;       // 5% discount → fulfiller pays 95% of amount

        vm.prank(user1);
        que.joinQue(amount, inc);

        uint256 user1UsdBefore = usd.balanceOf(user1);

        vm.prank(fulf);
        (uint256 vt, uint256 sc) = que.fulfillOrder(0, inc);

        uint256 expectedUsd = amount * (10_000 - uint256(inc)) / 10_000;
        assertEq(vt, amount,      "vault out");
        assertEq(sc, expectedUsd, "discounted USD");
        assertEq(usd.balanceOf(user1) - user1UsdBefore, expectedUsd, "user1 USD delta");
    }

    function test_fulfillOrder_negativeIncentive_takesPremium()
        public
    {
        uint256 amount = 100 * 1e6;
        int256  inc    = -300;      // -3% → fulfiller pays 103% of amount

        vm.prank(user1);
        que.joinQue(amount, inc);

        uint256 user1UsdBefore = usd.balanceOf(user1);

        vm.prank(fulf);
        (uint256 vt, uint256 sc) = que.fulfillOrder(0, inc);

        uint256 expectedUsd = amount * (10_000 + 300) / 10_000;
        assertEq(vt, amount,      "vault out");
        assertEq(sc, expectedUsd, "premium USD");
        assertEq(usd.balanceOf(user1) - user1UsdBefore, expectedUsd, "user1 USD delta");
    }

    function test_fulfillOrder_notCurrentOrder_reverts()
        public
    {
        vm.prank(user1); que.joinQue(100 * 1e6, 500);
        vm.prank(user2); que.joinQue(100 * 1e6, 500);

        // currentOrderId = 0; fulfilling id=1 first must revert.
        vm.prank(fulf);
        vm.expectRevert();
        que.fulfillOrder(1, 500);
    }

    function test_partiallyFulfillOrder_happyPath()
        public
    {
        uint256 total = 200 * 1e6;
        int256  inc   = 500;

        vm.prank(user1);
        que.joinQue(total, inc);

        uint256 partialAmt = 50 * 1e6;

        vm.prank(fulf);
        (uint256 vt, uint256 sc) = que.partiallyFulfillOrder(0, inc, partialAmt);

        assertEq(vt, partialAmt, "vault out = partial");
        assertEq(sc, partialAmt * (10_000 - 500) / 10_000, "discounted USD");

        (, uint256 remaining,,) = que.QueMemberByIdAndIncentive(0, inc);
        assertEq(remaining, total - partialAmt, "remaining amount");

        assertEq(que.totalActiveOrders(), 1, "still active");
    }

    function test_partiallyFulfillOrder_amountTooHigh_reverts()
        public
    {
        vm.prank(user1);
        que.joinQue(100 * 1e6, 500);

        vm.prank(fulf);
        vm.expectRevert();
        que.partiallyFulfillOrder(0, 500, 100 * 1e6);
    }

    function test_fulfillOrderBulk_happyPath()
        public
    {
        // Three orders at incentive 500 → fulfiller takes the first two fully
        // and skips the rest by passing only ids 0 and 1.
        vm.prank(user1); que.joinQue(100 * 1e6, 500);
        vm.prank(user2); que.joinQue(150 * 1e6, 500);
        vm.prank(user3); que.joinQue(200 * 1e6, 500);

        int256[] memory incs    = new int256[](2);
        uint256[] memory ids    = new uint256[](2);
        uint256[] memory partials = new uint256[](0);
        incs[0] = 500; incs[1] = 500;
        ids[0]  = 0;   ids[1]  = 1;

        vm.prank(fulf);
        (uint256 vtTotal, uint256 sc) = que.fulfillOrderBulk(
            incs,
            ids,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(vtTotal, 250 * 1e6, "bulk vault total");
        assertEq(sc, (100 * 1e6 + 150 * 1e6) * 9_500 / 10_000, "bulk USD total");
        assertEq(que.totalActiveOrders(), 1, "one remains");
        assertEq(que.currentOrderIdByIncentive(500), 2, "current pointer advanced past 0,1");
    }

    function test_fulfillOrderBulk_minReceiveTooLow_reverts()
        public
    {
        vm.prank(user1);
        que.joinQue(100 * 1e6, 500);

        int256[] memory incs    = new int256[](1);
        uint256[] memory ids    = new uint256[](1);
        uint256[] memory partials = new uint256[](0);
        incs[0] = 500; ids[0] = 0;

        vm.prank(fulf);
        vm.expectRevert();
        que.fulfillOrderBulk(
            incs,
            ids,
            partials,
            0,                  // partialAmount
            999 * 1e6,          // minReceiveAmount — too high (order is only 100e6)
            type(uint256).max   // maxUsdToSpend
        );
    }

    // ============================================================
    // 3. View helpers
    // ============================================================

    function test_predictDiscountedAmount()
        public
        view
    {
        assertEq(que.predictDiscountedAmount(100 * 1e6, 500),  95 * 1e6,  "5% discount");
        assertEq(que.predictDiscountedAmount(100 * 1e6, 0),    100 * 1e6, "no change");
        assertEq(que.predictDiscountedAmount(100 * 1e6, -500), 105 * 1e6, "5% premium");
    }

    function test_predictCostForTokens_andTokensForCost_roundTrip()
        public
    {
        vm.prank(user1); que.joinQue(100 * 1e6, 500);
        vm.prank(user2); que.joinQue(100 * 1e6, 500);

        (uint256 cost, uint256 acquirable) = que.predictCostForTokens(150 * 1e6);
        assertEq(acquirable, 150 * 1e6, "acquirable");
        assertEq(cost,       150 * 1e6 * 9_500 / 10_000, "cost");

        uint256 tokens = que.predictTokensForCost(cost);
        assertEq(tokens, 150 * 1e6, "round-trip");
    }

    function test_solveForAmount_returnsExpectedShape()
        public
    {
        vm.prank(user1); que.joinQue(100 * 1e6, 500);
        vm.prank(user2); que.joinQue(50 * 1e6,  500);

        (
            int256[]  memory incentives,
            uint256[] memory orders,
            uint256[] memory partials
        ) = que.solveForAmount(150 * 1e6);

        assertEq(incentives.length, 2, "two orders");
        assertEq(orders.length,     2, "both full");
        assertEq(partials.length,   0, "no partial");
        assertEq(incentives[0], 500); assertEq(incentives[1], 500);
        assertEq(orders[0], 0);       assertEq(orders[1], 1);
    }

    function test_getAllOrders_returnsActiveOnly()
        public
    {
        vm.prank(user1); que.joinQue(100 * 1e6, 500);
        vm.prank(user2); que.joinQue(200 * 1e6, 500);
        vm.prank(user1); que.joinQue(80 * 1e6, 1000);

        // user1 leaves the inc=500 order
        vm.prank(user1);
        que.leaveQue(0, 500);

        (
            QueContract.QueMember[] memory mine,
        ) = que.getAllOrdersfromAddress(user1);

        assertEq(mine.length, 1, "only inc=1000 left");
        assertEq(mine[0].member, user1);
        assertEq(mine[0].amount, 80 * 1e6);

        (
            QueContract.QueMember[] memory all,
        ) = que.getAllOrdersOverall();

        assertEq(all.length, 2, "user2 inc=500 + user1 inc=1000");
    }

    // ============================================================
    // 4. Master-only functions
    // ============================================================

    function test_changeMinDepositAmount_master()
        public
    {
        que.changeMinDepositAmount(1234);
        assertEq(que.minDepositAmount(), 1234);
    }

    function test_changeMinDepositAmount_nonMaster_reverts()
        public
    {
        vm.prank(user1);
        vm.expectRevert();
        que.changeMinDepositAmount(1);
    }

    function test_setNegativeIncentivesNotAllowed_master()
        public
    {
        que.setNegativeIncentivesNotAllowed(true);
        assertTrue(que.negativeIncentivesNotAllowed());

        que.setNegativeIncentivesNotAllowed(false);
        assertFalse(que.negativeIncentivesNotAllowed());
    }

    // ============================================================
    // 5. Mimicry — natural state vs setter-replicated state
    //    Build state on contract A via natural calls; deploy B fresh and
    //    apply migration setters using A's snapshot; assert byte-equality
    //    across every storage slot we care about.
    // ============================================================

    function test_mimicry_storageBitForBitMatch()
        public
    {
        _buildNaturalStateOn_A();

        ForwardVaultERC20Migratable vaultB;
        QueContractMigratable       queB;

        (vaultB, queB) = _deployFreshPair();

        _migrateAFromOnto_B(vaultB, queB);

        _assertStorageMatch(que, queB);
        _assertProxyBalancesMatch(vault, vaultB);
    }

    function test_postMigration_canJoinQue_atCorrectSlot()
        public
    {
        _buildNaturalStateOn_A();

        ForwardVaultERC20Migratable vaultB;
        QueContractMigratable       queB;
        (vaultB, queB) = _deployFreshPair();
        _migrateAFromOnto_B(vaultB, queB);

        // Fund a new user on vaultB and have them joinQue.
        address newUser = address(0xBEEF);
        vaultB.mintSupply(newUser, 1_000 * 1e6);
        vm.prank(newUser);
        IERC20(address(vaultB)).approve(address(queB), type(uint256).max);

        uint256 expectedSlot = queB.earliestValidQueMemberByIncentive(500);

        vm.prank(newUser);
        (, uint256 newId) = queB.joinQue(100 * 1e6, 500);

        assertEq(newId, expectedSlot, "new joinQue lands at migrated earliestValid");

        (
            address m,
            uint256 a,
            uint256 t,
            uint256 h
        ) = queB.QueMemberByIdAndIncentive(newId, 500);
        assertEq(m, newUser);
        assertEq(a, 100 * 1e6);
        // Tail = previous earliestValid sentinel's tail (= last live id on A)
        assertEq(t, expectedSlot - 1, "linked back to prior tail");
        assertEq(h, expectedSlot + 1, "head points at next slot");
    }

    function test_postMigration_canFulfill()
        public
    {
        _buildNaturalStateOn_A();

        ForwardVaultERC20Migratable vaultB;
        QueContractMigratable       queB;
        (vaultB, queB) = _deployFreshPair();
        _migrateAFromOnto_B(vaultB, queB);

        // Fulfiller ready
        usd.mint(fulf, 100_000 * 1e6);
        vm.prank(fulf);
        usd.approve(address(queB), type(uint256).max);

        uint256 currentId = queB.currentOrderIdByIncentive(500);
        (, uint256 amt,,) = queB.QueMemberByIdAndIncentive(currentId, 500);
        require(amt > 0, "no order to fulfill (test sanity)");

        vm.prank(fulf);
        (uint256 vt, uint256 sc) = queB.fulfillOrder(currentId, 500);

        assertEq(vt, amt, "vault out matches order");
        assertGt(sc, 0,   "non-zero USD paid");

        (address m,,,) = queB.QueMemberByIdAndIncentive(currentId, 500);
        assertEq(m, address(0), "slot zeroed after full fulfill");
    }

    function test_postMigration_canLeave()
        public
    {
        _buildNaturalStateOn_A();

        ForwardVaultERC20Migratable vaultB;
        QueContractMigratable       queB;
        (vaultB, queB) = _deployFreshPair();
        _migrateAFromOnto_B(vaultB, queB);

        // user2 has an inc=500 order from _buildNaturalState; check + leave it.
        // Find their (id, incentive) by walking getAllOrdersfromAddress.
        (
            QueContract.QueMember[] memory orders,
            int256[] memory incentives
        ) = queB.getAllOrdersfromAddress(user2);

        require(orders.length > 0, "user2 has no orders (test sanity)");

        uint256 idToLeave;
        int256  incToLeave = incentives[0];

        // Find the matching id for this incentive by walking slots.
        uint256 maxId = queB.earliestValidQueMemberByIncentive(incToLeave);
        for (uint256 id; id < maxId; ++id) {
            (address m, uint256 a,,) = queB.QueMemberByIdAndIncentive(id, incToLeave);
            if (m == user2 && a > 0) {
                idToLeave = id;
                break;
            }
        }

        uint256 vaultBalBefore = IERC20(address(vaultB)).balanceOf(user2);

        vm.prank(user2);
        queB.leaveQue(idToLeave, incToLeave);

        assertGt(IERC20(address(vaultB)).balanceOf(user2), vaultBalBefore, "got tokens back");

        (address m,,,) = queB.QueMemberByIdAndIncentive(idToLeave, incToLeave);
        assertEq(m, address(0), "slot zeroed");
    }

    // ============================================================
    // Helpers for the mimicry/post-migration block
    // ============================================================

    function _buildNaturalStateOn_A()
        internal
    {
        // 5 orders across 3 incentives. Then user1 leaves to create
        // a hole in the middle; user2 reduces; partial fulfill burns part of one.
        vm.prank(user1); que.joinQue(100 * 1e6, 500);  // id 0, inc 500
        vm.prank(user2); que.joinQue(200 * 1e6, 500);  // id 1, inc 500
        vm.prank(user3); que.joinQue(150 * 1e6, 500);  // id 2, inc 500

        vm.prank(user1); que.joinQue(80 * 1e6, 1000); // id 0, inc 1000
        vm.prank(user2); que.joinQue(120 * 1e6, 0);   // id 0, inc 0

        // user1 leaves inc=500 → slot 0 zeroed, linked-list patched
        vm.prank(user1); que.leaveQue(0, 500);

        // user2 reduces their inc=500 order
        vm.prank(user2); que.reduceQueAmount(1, 500, 50 * 1e6);

        // Partial fulfill of the inc=0 order (currentOrderId = 0 at inc=0)
        vm.prank(fulf);
        que.partiallyFulfillOrder(0, 0, 30 * 1e6);
    }

    function _deployFreshPair()
        internal
        returns (
            ForwardVaultERC20Migratable vB,
            QueContractMigratable       qB
        )
    {
        address[] memory addrs = new address[](0);
        uint256[] memory amts  = new uint256[](0);

        vB = new ForwardVaultERC20Migratable(
            address(usd),
            thirdPty,
            address(0),
            addrs,
            amts,
            TOTAL_DEPOSIT_CAP,
            INTEREST_RATE,
            AUTO_COMPOUND_INC,
            6,
            "VaultB",
            "VB"
        );

        qB = new QueContractMigratable(
            address(vB)
        );
    }

    function _migrateAFromOnto_B(
        ForwardVaultERC20Migratable _vB,
        QueContractMigratable _qB
    )
        internal
    {
        // ---- mirror proxyBalance for every user ----
        address[3] memory users = [user1, user2, user3];
        for (uint256 i; i < users.length; ++i) {
            uint256 px = vault.proxyBalance(users[i]);
            if (px > 0) {
                _vB.setProxyBalance(users[i], px);
            }
        }

        // ---- replicate global state ----
        _qB.setGlobalState(
            que.totalActiveOrders(),
            que.minDepositAmount(),
            que.negativeIncentivesNotAllowed()
        );

        // ---- replicate per-incentive state and member slots ----
        int256[17] memory incs = [
            int256(100), int256(200), int256(300), int256(500), int256(1000),
            int256(1500), int256(2500), int256(5000),
            int256(0),
            int256(-100), int256(-200), int256(-300), int256(-500),
            int256(-1000), int256(-1500), int256(-2500), int256(-5000)
        ];

        uint256 totalQueAmount;

        for (uint256 i; i < incs.length; ++i) {
            int256 inc = incs[i];

            uint256 earliest = que.earliestValidQueMemberByIncentive(inc);
            uint256 current  = que.currentOrderIdByIncentive(inc);
            uint256 active   = que.activeOrderCountByIncentive(inc);
            bool    allowed  = que.incentiveAllowed(inc);

            _qB.setPerIncentiveState(inc, earliest, current, active, allowed);

            for (uint256 id; id <= earliest; ++id) {
                (
                    address m,
                    uint256 a,
                    uint256 t,
                    uint256 h
                ) = que.QueMemberByIdAndIncentive(id, inc);

                if (m == address(0) && a == 0 && t == 0 && h == 0) continue;

                _qB.setQueMember(id, inc, m, a, t, h);
                totalQueAmount += a;
            }
        }

        // ---- mint vault tokens to the new queContract so its balanceOf
        //      matches the original — these are the tokens it must hand
        //      back when members leave or are fulfilled.
        if (totalQueAmount > 0) {
            _vB.mintSupply(address(_qB), totalQueAmount);
        }

        _vB.setInterestRateProxy(address(_qB));
    }

    function _assertStorageMatch(
        QueContractMigratable _a,
        QueContractMigratable _b
    )
        internal
    {
        assertEq(_a.totalActiveOrders(),            _b.totalActiveOrders(),            "totalActive");
        assertEq(_a.minDepositAmount(),             _b.minDepositAmount(),             "minDeposit");
        assertEq(_a.negativeIncentivesNotAllowed(), _b.negativeIncentivesNotAllowed(), "negNotAllowed");

        int256[17] memory incs = [
            int256(100), int256(200), int256(300), int256(500), int256(1000),
            int256(1500), int256(2500), int256(5000),
            int256(0),
            int256(-100), int256(-200), int256(-300), int256(-500),
            int256(-1000), int256(-1500), int256(-2500), int256(-5000)
        ];

        uint256 totalSlotsChecked;

        for (uint256 i; i < incs.length; ++i) {
            int256 inc = incs[i];

            assertEq(_a.earliestValidQueMemberByIncentive(inc), _b.earliestValidQueMemberByIncentive(inc), "earliest mismatch");
            assertEq(_a.currentOrderIdByIncentive(inc),         _b.currentOrderIdByIncentive(inc),         "current mismatch");
            assertEq(_a.activeOrderCountByIncentive(inc),       _b.activeOrderCountByIncentive(inc),       "active mismatch");
            assertEq(_a.incentiveAllowed(inc),                  _b.incentiveAllowed(inc),                  "allowed mismatch");

            uint256 maxId = _a.earliestValidQueMemberByIncentive(inc);

            for (uint256 id; id <= maxId; ++id) {
                _assertSlotEqual(_a, _b, inc, id);
                totalSlotsChecked++;
            }
        }

        console2.log("Mimicry slot-walk verified", totalSlotsChecked);
    }

    function _assertSlotEqual(
        QueContractMigratable _a,
        QueContractMigratable _b,
        int256 _inc,
        uint256 _id
    )
        internal
    {
        (address aM, uint256 aA, uint256 aT, uint256 aH) = _a.QueMemberByIdAndIncentive(_id, _inc);
        (address bM, uint256 bA, uint256 bT, uint256 bH) = _b.QueMemberByIdAndIncentive(_id, _inc);

        assertEq(aM, bM, "member mismatch");
        assertEq(aA, bA, "amount mismatch");
        assertEq(aT, bT, "tail mismatch");
        assertEq(aH, bH, "head mismatch");
    }

    function _assertProxyBalancesMatch(
        ForwardVaultERC20Migratable _a,
        ForwardVaultERC20Migratable _b
    )
        internal
    {
        address[3] memory users = [user1, user2, user3];
        for (uint256 i; i < users.length; ++i) {
            assertEq(
                _a.proxyBalance(users[i]),
                _b.proxyBalance(users[i]),
                "proxyBalance mismatch"
            );
        }
    }
}
