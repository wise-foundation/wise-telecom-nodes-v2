// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ForwardVaultERC20Migratable} from "../../src/migration/ForwardVaultERC20Migratable.sol";
import {QueContractMigratable}       from "../../src/migration/QueContractMigratable.sol";
import {QueContract}                 from "../../src/legacy/que/QueContractLegacy.sol";

contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "MUSD") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address _to, uint256 _amount) external { _mint(_to, _amount); }
}

/**
 * Targeted tests for branches in QueContract* helper files that
 * QueContractFunctional.t.sol misses. Focuses on:
 *   - predictCostForTokens with liquidity gaps
 *   - predictTokensForCost across multiple incentive tiers
 *   - solveForAmountWithIncentive direct access
 *   - getAllOrdersfromAddress / getAllOrdersOverall edge cases
 *   - Empty-order traversal branches in plan / solve helpers
 *   - Linked-list edge cases on leaveQue/reduceQueAmount/fulfillOrder
 *   - changeMinDepositAmount + setNegativeIncentivesNotAllowed admin coverage
 */
contract QueContractGapsTest is Test {

    MockUSD                     usd;
    ForwardVaultERC20Migratable vault;
    QueContractMigratable       que;

    address master   = address(this);
    address thirdPty = address(0xCAFE);

    address user1 = address(0xA1);
    address user2 = address(0xA2);
    address user3 = address(0xA3);
    address user4 = address(0xA4);
    address fulf  = address(0xF1);

    uint256 constant TOTAL_DEPOSIT_CAP = 100_000_000 * 1e6;
    uint256 constant INTEREST_RATE     = 2000;
    uint256 constant AUTO_COMPOUND_INC = 500;
    uint256 constant MIN_DEPOSIT       = 50 * 1e6;

    function setUp() public {
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

        que = new QueContractMigratable(address(vault));
        vault.setInterestRateProxy(address(que));

        _fundUser(user1, 10_000 * 1e6);
        _fundUser(user2, 10_000 * 1e6);
        _fundUser(user3, 10_000 * 1e6);
        _fundUser(user4, 10_000 * 1e6);

        usd.mint(fulf, 1_000_000 * 1e6);
        vm.prank(fulf);
        usd.approve(address(que), type(uint256).max);
    }

    function _fundUser(address _user, uint256 _amount) internal {
        vault.mintSupply(_user, _amount);
        vm.prank(_user);
        IERC20(address(vault)).approve(address(que), type(uint256).max);
    }

    function _join(address _user, uint256 _amount, int256 _incentive) internal returns (uint256) {
        vm.prank(_user);
        (, uint256 id) = que.joinQue(_amount, _incentive);
        return id;
    }

    // -------------------------------------------------------------------
    // 1. solveForAmountWithIncentive direct
    // -------------------------------------------------------------------

    function test_solveForAmountWithIncentive_emptyLevel_returnsEmpty() public view {
        (uint256[] memory full, uint256[] memory partial_) =
            que.solveForAmountWithIncentive(1_000 * 1e6, 0);
        assertEq(full.length, 0);
        assertEq(partial_.length, 0);
    }

    function test_solveForAmountWithIncentive_oneFull_noPartial() public {
        _join(user1, 100 * 1e6, 0);
        (uint256[] memory full, uint256[] memory partial_) =
            que.solveForAmountWithIncentive(100 * 1e6, 0);
        assertEq(full.length, 1);
        assertEq(partial_.length, 0);
    }

    function test_solveForAmountWithIncentive_multipleFullAndPartial() public {
        _join(user1, 100 * 1e6, 0);
        _join(user2, 150 * 1e6, 0);
        _join(user3, 300 * 1e6, 0);

        // request 200 -> consumes user1 fully (100), then partially user2 (100/150)
        (uint256[] memory full, uint256[] memory partial_) =
            que.solveForAmountWithIncentive(200 * 1e6, 0);
        assertEq(full.length, 1);
        assertEq(partial_.length, 1);
    }

    function test_solveForAmountWithIncentive_skipsEmptyOrders() public {
        uint256 id1 = _join(user1, 100 * 1e6, 0);
        _join(user2, 100 * 1e6, 0);
        _join(user3, 100 * 1e6, 0);

        // emptied order via leaveQue while not currentOrder (so member stays in linked list as empty)
        vm.prank(user1);
        que.leaveQue(id1, 0);

        (uint256[] memory full, ) = que.solveForAmountWithIncentive(150 * 1e6, 0);
        // user1 entry now empty, user2 (100) + user3 partial(50) — 1 full
        assertEq(full.length, 1);
    }

    // -------------------------------------------------------------------
    // 2. predictTokensForCost across tiers + budget exhaustion
    // -------------------------------------------------------------------

    function test_predictTokensForCost_zero_returnsZero() public view {
        uint256 t = que.predictTokensForCost(0);
        assertEq(t, 0);
    }

    function test_predictTokensForCost_noOrders_returnsZero() public view {
        uint256 t = que.predictTokensForCost(1_000 * 1e6);
        assertEq(t, 0);
    }

    function test_predictTokensForCost_singleOrderFullyAffordable() public {
        _join(user1, 1_000 * 1e6, 500); // 5% discount
        uint256 tokens = que.predictTokensForCost(1_000 * 1e6);
        // Should acquire close to all 1_000 tokens (since cost is discounted)
        assertGt(tokens, 0);
        assertLe(tokens, 1_000 * 1e6);
    }

    function test_predictTokensForCost_traversesMultipleIncentives() public {
        _join(user1, 200 * 1e6, 5000);
        _join(user2, 200 * 1e6, 1000);
        _join(user3, 200 * 1e6, 0);
        uint256 tokens = que.predictTokensForCost(500 * 1e6);
        assertGt(tokens, 0);
    }

    // -------------------------------------------------------------------
    // 3. predictCostForTokens with insufficient liquidity
    // -------------------------------------------------------------------

    function test_predictCostForTokens_insufficientLiquidity_returnsPartial() public {
        _join(user1, 100 * 1e6, 0);
        (uint256 cost, uint256 tokens) = que.predictCostForTokens(500 * 1e6);
        assertEq(tokens, 100 * 1e6);
        assertGt(cost, 0);
    }

    function test_predictCostForTokens_exactlyAvailable() public {
        _join(user1, 100 * 1e6, 1000);
        (uint256 cost, uint256 tokens) = que.predictCostForTokens(100 * 1e6);
        assertEq(tokens, 100 * 1e6);
        assertGt(cost, 0);
    }

    function test_predictCostForTokens_partialOrderUsed() public {
        _join(user1, 100 * 1e6, 0);
        _join(user2, 100 * 1e6, 0);
        (uint256 cost, uint256 tokens) = que.predictCostForTokens(150 * 1e6);
        assertEq(tokens, 150 * 1e6);
        assertGt(cost, 0);
    }

    function test_predictCostForTokens_zero_returnsZero() public view {
        (uint256 cost, uint256 tokens) = que.predictCostForTokens(0);
        assertEq(cost, 0);
        assertEq(tokens, 0);
    }

    // -------------------------------------------------------------------
    // 4. getAllOrdersfromAddress / getAllOrdersOverall
    // -------------------------------------------------------------------

    function test_getAllOrdersfromAddress_noOrders() public view {
        (QueContract.QueMember[] memory ms, int256[] memory incs) = que.getAllOrdersfromAddress(user1);
        assertEq(ms.length, 0);
        assertEq(incs.length, 0);
    }

    function test_getAllOrdersfromAddress_filtered() public {
        _join(user1, 100 * 1e6, 0);
        _join(user1, 100 * 1e6, 500);
        _join(user2, 100 * 1e6, 0);

        (QueContract.QueMember[] memory ms, int256[] memory incs) = que.getAllOrdersfromAddress(user1);
        assertEq(ms.length, 2);
        assertEq(incs.length, 2);

        for (uint256 i; i < ms.length; ++i) {
            assertEq(ms[i].member, user1);
        }
    }

    function test_getAllOrdersOverall_includesAll() public {
        _join(user1, 100 * 1e6, 0);
        _join(user2, 100 * 1e6, 500);
        _join(user3, 100 * 1e6, 1000);

        (QueContract.QueMember[] memory ms, int256[] memory incs) = que.getAllOrdersOverall();
        assertEq(ms.length, 3);
        assertEq(incs.length, 3);
    }

    function test_getAllOrdersOverall_excludesEmpty() public {
        uint256 id1 = _join(user1, 100 * 1e6, 0);
        _join(user2, 100 * 1e6, 0);

        vm.prank(user1);
        que.leaveQue(id1, 0);

        (QueContract.QueMember[] memory ms, ) = que.getAllOrdersOverall();
        // Only user2 should remain
        assertEq(ms.length, 1);
        assertEq(ms[0].member, user2);
    }

    // -------------------------------------------------------------------
    // 5. getFulfillmentPlanForIncentive edge cases
    // -------------------------------------------------------------------

    function test_getFulfillmentPlan_emptyLevel_returnsEmpty() public view {
        (uint256[] memory full, uint256[] memory partial_, ) =
            que.getFulfillmentPlanForIncentive(100, 0, 10);
        assertEq(full.length, 0);
        assertEq(partial_.length, 0);
    }

    function test_getFulfillmentPlan_maxOrdersZero_clampedToDefault() public {
        _join(user1, 50 * 1e6, 0);
        _join(user2, 50 * 1e6, 0);

        (uint256[] memory full, , ) = que.getFulfillmentPlanForIncentive(50 * 1e6, 0, 0);
        assertEq(full.length, 1);
    }

    function test_getFulfillmentPlan_traversesAndStopsAtLimit() public {
        _join(user1, 100 * 1e6, 0);
        _join(user2, 100 * 1e6, 0);
        _join(user3, 100 * 1e6, 0);

        // Ask for 250, limit to 2 orders considered
        (uint256[] memory full, uint256[] memory partial_, ) =
            que.getFulfillmentPlanForIncentive(250 * 1e6, 0, 2);
        // Should return 2 full orders, no partial considered if hit limit
        assertEq(full.length, 2);
        assertEq(partial_.length, 0);
    }

    function test_getFulfillmentPlan_withEmptyOrders() public {
        uint256 id1 = _join(user1, 100 * 1e6, 0);
        _join(user2, 100 * 1e6, 0);

        vm.prank(user1);
        que.leaveQue(id1, 0);

        (uint256[] memory full, , ) = que.getFulfillmentPlanForIncentive(100 * 1e6, 0, 10);
        assertEq(full.length, 1);
    }

    // -------------------------------------------------------------------
    // 6. Linked-list & state edge cases on leave/reduce/fulfill
    // -------------------------------------------------------------------

    function test_leaveQue_currentOrder_advancesPointer() public {
        uint256 id1 = _join(user1, 100 * 1e6, 0);
        uint256 id2 = _join(user2, 100 * 1e6, 0);

        // id1 is the current order; leaving it should advance to id2
        vm.prank(user1);
        que.leaveQue(id1, 0);

        assertEq(que.currentOrderIdByIncentive(0), id2);
    }

    function test_leaveQue_doubleLeaveReverts() public {
        uint256 id = _join(user1, 100 * 1e6, 0);
        vm.prank(user1);
        que.leaveQue(id, 0);

        vm.prank(user1);
        vm.expectRevert();
        que.leaveQue(id, 0);
    }

    function test_leaveQue_wrongIncentiveReverts() public {
        uint256 id = _join(user1, 100 * 1e6, 0);
        vm.prank(user1);
        vm.expectRevert();
        que.leaveQue(id, 500);
    }

    function test_reduceQueAmount_belowOrEqualMinReverts() public {
        uint256 id = _join(user1, 60 * 1e6, 0);
        vm.prank(user1);
        vm.expectRevert();
        que.reduceQueAmount(id, 0, 50 * 1e6);
    }

    function test_reduceQueAmount_wrongIncentiveReverts() public {
        uint256 id = _join(user1, 200 * 1e6, 0);
        vm.prank(user1);
        vm.expectRevert();
        que.reduceQueAmount(id, 500, 50 * 1e6);
    }

    function test_partiallyFulfillOrder_lastOrderRemainsActive() public {
        uint256 id = _join(user1, 200 * 1e6, 0);

        vm.prank(fulf);
        que.partiallyFulfillOrder(id, 0, 50 * 1e6);

        assertEq(que.currentOrderIdByIncentive(0), id);
        assertEq(que.totalActiveOrders(), 1);
    }

    function test_fulfillOrder_advancesPointerOnFull() public {
        uint256 id1 = _join(user1, 100 * 1e6, 0);
        uint256 id2 = _join(user2, 100 * 1e6, 0);

        vm.prank(fulf);
        que.fulfillOrder(id1, 0);

        assertEq(que.currentOrderIdByIncentive(0), id2);
        assertEq(que.totalActiveOrders(), 1);
    }

    function test_fulfillOrderBulk_zeroPartialAmount_skipsPartial() public {
        uint256 id1 = _join(user1, 100 * 1e6, 0);
        uint256 id2 = _join(user2, 100 * 1e6, 0);

        int256[] memory incs = new int256[](2);
        incs[0] = 0;
        incs[1] = 0;

        uint256[] memory orders = new uint256[](2);
        orders[0] = id1;
        orders[1] = id2;

        uint256[] memory partials = new uint256[](0);

        vm.prank(fulf);
        (uint256 received, uint256 spent) = que.fulfillOrderBulk(
            incs,
            orders,
            partials,
            0,
            0,
            type(uint256).max
        );

        assertEq(received, 200 * 1e6);
        assertEq(spent, 200 * 1e6);
    }

    function test_fulfillOrderBulk_emptyOrders_emptyPartials_reverts() public {
        int256[] memory incs = new int256[](0);
        uint256[] memory orders = new uint256[](0);
        uint256[] memory partials = new uint256[](0);

        vm.prank(fulf);
        vm.expectRevert();
        que.fulfillOrderBulk(incs, orders, partials, 0, 0, type(uint256).max);
    }

    function test_fulfillOrderBulk_maxUsdExceeded_reverts() public {
        uint256 id1 = _join(user1, 100 * 1e6, 0);

        int256[] memory incs = new int256[](1);
        incs[0] = 0;
        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;
        uint256[] memory partials = new uint256[](0);

        vm.prank(fulf);
        vm.expectRevert();
        que.fulfillOrderBulk(incs, orders, partials, 0, 0, 50 * 1e6);
    }

    function test_fulfillOrderBulk_withPartial() public {
        uint256 id1 = _join(user1, 100 * 1e6, 0);
        uint256 id2 = _join(user2, 200 * 1e6, 0);

        int256[] memory incs = new int256[](1);
        incs[0] = 0;
        uint256[] memory orders = new uint256[](1);
        orders[0] = id1;
        uint256[] memory partials = new uint256[](1);
        partials[0] = id2;

        vm.prank(fulf);
        (uint256 received, ) = que.fulfillOrderBulk(
            incs,
            orders,
            partials,
            50 * 1e6,
            0,
            type(uint256).max
        );

        assertEq(received, 150 * 1e6);
    }

    // -------------------------------------------------------------------
    // 7. setNegativeIncentivesNotAllowed coverage
    // -------------------------------------------------------------------

    function test_setNegativeIncentivesNotAllowed_blocksThenAllows() public {
        que.setNegativeIncentivesNotAllowed(true);
        assertTrue(que.negativeIncentivesNotAllowed());

        vm.prank(user1);
        vm.expectRevert();
        que.joinQue(100 * 1e6, -500);

        que.setNegativeIncentivesNotAllowed(false);
        // After flipping, should work
        vm.prank(user1);
        (QueContract.QueMember memory member, ) = que.joinQue(100 * 1e6, -500);
        assertEq(member.member, user1);
        assertEq(member.amount, 100 * 1e6);
    }

    function test_setNegativeIncentivesNotAllowed_nonMasterReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        que.setNegativeIncentivesNotAllowed(true);
    }

    // -------------------------------------------------------------------
    // 8. changeMinDepositAmount affects join validation
    // -------------------------------------------------------------------

    function test_changeMinDepositAmount_takesEffect() public {
        que.changeMinDepositAmount(200 * 1e6);
        assertEq(que.minDepositAmount(), 200 * 1e6);

        vm.prank(user1);
        vm.expectRevert();
        que.joinQue(100 * 1e6, 0);

        // 200 succeeds
        vm.prank(user1);
        (QueContract.QueMember memory member, ) = que.joinQue(200 * 1e6, 0);
        assertEq(member.member, user1);
        assertEq(member.amount, 200 * 1e6);
    }

    // -------------------------------------------------------------------
    // 9. proxyBalance reset by modifier after each call
    // -------------------------------------------------------------------

    function test_setProxyBenefactor_resetAfterCall() public {
        _join(user1, 100 * 1e6, 0);
        assertEq(vault.currentProxyBenefactor(), address(0));
    }

    // -------------------------------------------------------------------
    // 10. solveForAmount across positive + negative incentives
    // -------------------------------------------------------------------

    function test_solveForAmount_acrossTiers() public {
        _join(user1, 100 * 1e6, 5000);
        _join(user2, 100 * 1e6, 500);
        _join(user3, 100 * 1e6, 0);

        (int256[] memory incs, uint256[] memory orders, uint256[] memory partials) =
            que.solveForAmount(250 * 1e6);
        assertGt(orders.length, 0);
        // incs aggregates one entry per (full + partial) — so length should be
        // orders.length + partials.length.
        assertEq(incs.length, orders.length + partials.length);
    }

    function test_solveForAmount_partialFinishes() public {
        _join(user1, 100 * 1e6, 0);
        _join(user2, 200 * 1e6, 0);

        (, uint256[] memory orders, uint256[] memory partials) = que.solveForAmount(150 * 1e6);
        // 1 full + 1 partial = total 150
        assertEq(orders.length, 1);
        assertEq(partials.length, 1);
    }
}
