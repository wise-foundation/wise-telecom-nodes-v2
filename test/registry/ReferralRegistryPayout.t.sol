// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../src/registry/pending/ReferralRegistryDeclarations.sol";

import {NotMaster} from "../../src/diamond/shared/OwnableMaster.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/**
 * @dev Minimal CCIP router stand-in for the payout push tests:
 * quotes a fixed fee per message, requires each send to carry exactly
 * that fee, records the last send, and returns a deterministic
 * message id derived from the destination selector and a running send
 * counter so tests can predict emitted ids.
 */
contract MockPushCcipRouter {

    error UnexpectedFeeValue();

    uint256 public fee;

    uint256 public sendCount;

    uint64 public lastSelector;

    bytes public lastReceiver;

    bytes public lastData;

    constructor(
        uint256 _fee
    ) {
        fee = _fee;
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage calldata
    )
        external
        view
        returns (uint256)
    {
        return fee;
    }

    function ccipSend(
        uint64 _destChainSelector,
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32)
    {
        require(
            msg.value == fee,
            UnexpectedFeeValue()
        );

        sendCount += 1;

        lastSelector = _destChainSelector;

        lastReceiver = _message.receiver;

        lastData = _message.data;

        return keccak256(
            abi.encode(
                _destChainSelector,
                sendCount
            )
        );
    }
}

/**
 * @dev Caller without a receive function, used to force the excess
 * refund transfer inside `pushPayoutAddress` to fail.
 */
contract PushRefundRejector {

    ReferralRegistry internal immutable REGISTRY;

    constructor(
        ReferralRegistry _registry
    ) {
        REGISTRY = _registry;
    }

    function trigger(
        address _owner
    )
        external
        payable
    {
        REGISTRY.pushPayoutAddress{value: msg.value}(
            _owner
        );
    }
}

/**
 * @dev Payout-designation suite for {ReferralRegistry}: the
 * own-chain `setPayoutAddress` write (freshness stamp packed
 * `(block.timestamp << 8) | LOCAL_CHAIN_RANK`, redesignation always
 * overwrites and re-stamps, zero payout is a valid designation), the
 * caller-paid permissionless `pushPayoutAddress` transport with its
 * ordered guard chain (nothing staged, hub route detached, router
 * unset), exact-fee send with deterministic message id, excess
 * refund and refund-failure arms, `quotePushPayoutFee`,
 * `getPayoutDesignation`, and the payout-hub route trio
 * (propose/execute/cancel: instant while wiring, 3-day timelocked
 * after `finalizeSyncSetup`, half-zero proposals rejected, all-zero
 * detaches). The zero-designation push test also pins the
 * non-default sync gas limit branch of the push message builder.
 * Mock router and refund rejector live at the top of this file.
 */
contract ReferralRegistryPayoutTest is Test {

    event PayoutAddressSet(
        address indexed owner,
        address indexed payout,
        uint256 stamp
    );

    event PayoutPushed(
        address indexed owner,
        uint64 indexed destChainSelector,
        address payout,
        uint256 stamp,
        bytes32 messageId
    );

    event PayoutHubProposed(
        address indexed hub,
        uint64 chainSelector,
        uint256 queuedAt
    );

    event PayoutHubSet(
        address indexed hub,
        uint64 chainSelector
    );

    event PayoutHubProposalCancelled(
        address indexed hub
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint64 internal constant SEL_HUB = 5_009;

    uint256 internal constant PUSH_FEE = 0.01 ether;

    address internal ownerA = address(0xA1);

    address internal ownerB = address(0xA2);

    address internal payoutA = address(0xB1);

    address internal payoutB = address(0xB2);

    address internal stranger = address(0xC1);

    address internal hubAddress = address(0xE5);

    address internal routerEoa = address(0xF1);

    ReferralRegistry internal registry;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        registry = new ReferralRegistry(
            address(this),
            0
        );
    }

    receive()
        external
        payable
    {}

    // ---- helpers ----

    function _stamp(
        uint256 _timestamp,
        uint256 _rank
    )
        internal
        pure
        returns (uint256)
    {
        return (_timestamp << 8) | _rank;
    }

    function _wireRoute()
        internal
    {
        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        registry.executePayoutHubChange();
    }

    function _armPush()
        internal
        returns (MockPushCcipRouter router)
    {
        router = new MockPushCcipRouter(
            PUSH_FEE
        );

        registry.setCcipRouter(
            address(router)
        );

        _wireRoute();

        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            payoutA
        );
    }

    // ---- setPayoutAddress ----

    function test_setPayoutAddress_storesPayoutAndStamp()
        public
    {
        uint256 stamp = _stamp(
            BASE_TIME,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit PayoutAddressSet(
            ownerA,
            payoutA,
            stamp
        );

        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            payoutA
        );

        assertEq(registry.payoutAddress(ownerA), payoutA);
        assertEq(registry.payoutStamp(ownerA), stamp);

        (
            address payout,
            uint256 storedStamp
        ) = registry.getPayoutDesignation(
            ownerA
        );

        assertEq(payout, payoutA);
        assertEq(storedStamp, stamp);

        assertEq(registry.payoutAddress(ownerB), address(0));
        assertEq(registry.payoutStamp(ownerB), 0);
    }

    function test_setPayoutAddress_stampCarriesLocalChainRank()
        public
    {
        ReferralRegistry ranked = new ReferralRegistry(
            address(this),
            3
        );

        vm.prank(
            ownerA
        );

        ranked.setPayoutAddress(
            payoutA
        );

        uint256 stamp = ranked.payoutStamp(
            ownerA
        );

        assertEq(stamp, _stamp(BASE_TIME, 3));
        assertEq(stamp & 0xff, 3);
        assertEq(stamp >> 8, BASE_TIME);
    }

    function test_setPayoutAddress_redesignationOverwritesAndRestamps()
        public
    {
        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            payoutA
        );

        vm.warp(
            BASE_TIME + 5 days
        );

        uint256 newStamp = _stamp(
            BASE_TIME + 5 days,
            0
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit PayoutAddressSet(
            ownerA,
            payoutB,
            newStamp
        );

        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            payoutB
        );

        assertEq(registry.payoutAddress(ownerA), payoutB);
        assertEq(registry.payoutStamp(ownerA), newStamp);
    }

    function test_setPayoutAddress_zeroPayoutIsValidDesignation()
        public
    {
        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            address(0)
        );

        (
            address payout,
            uint256 stamp
        ) = registry.getPayoutDesignation(
            ownerA
        );

        assertEq(payout, address(0));
        assertEq(stamp, _stamp(BASE_TIME, 0));
        assertGt(stamp, 0);
    }

    // ---- pushPayoutAddress guards ----

    function test_pushPayoutAddress_revertsWhenNothingToPush()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.NothingToPush.selector
        );

        registry.pushPayoutAddress(
            ownerA
        );
    }

    function test_pushPayoutAddress_revertsWhenPayoutHubNotSet()
        public
    {
        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            payoutA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.PayoutHubNotSet.selector
        );

        registry.pushPayoutAddress(
            ownerA
        );
    }

    function test_pushPayoutAddress_revertsWhenRouterNotSet()
        public
    {
        _wireRoute();

        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            payoutA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.RouterNotSet.selector
        );

        registry.pushPayoutAddress(
            ownerA
        );
    }

    // ---- pushPayoutAddress sends ----

    function test_pushPayoutAddress_sendsAndEmits()
        public
    {
        MockPushCcipRouter router = _armPush();

        uint256 stamp = _stamp(
            BASE_TIME,
            0
        );

        bytes32 messageId = keccak256(
            abi.encode(
                SEL_HUB,
                uint256(1)
            )
        );

        vm.deal(
            address(this),
            1 ether
        );

        vm.expectEmit(
            true,
            true,
            false,
            true,
            address(registry)
        );

        emit PayoutPushed(
            ownerA,
            SEL_HUB,
            payoutA,
            stamp,
            messageId
        );

        registry.pushPayoutAddress{value: PUSH_FEE}(
            ownerA
        );

        assertEq(router.sendCount(), 1);
        assertEq(router.lastSelector(), SEL_HUB);
        assertEq(router.lastReceiver(), abi.encode(hubAddress));
        assertEq(router.lastData().length, 160);
        assertEq(address(router).balance, PUSH_FEE);
        assertEq(address(registry).balance, 0);

        (
            uint256 version,
            address owner,
            address payout,
            uint256 setAt,
            uint256 rank
        ) = abi.decode(
            router.lastData(),
            (uint256, address, address, uint256, uint256)
        );

        assertEq(version, 1);
        assertEq(owner, ownerA);
        assertEq(payout, payoutA);
        assertEq(setAt, BASE_TIME);
        assertEq(rank, 0);
    }

    function test_pushPayoutAddress_thirdPartyCallerPays()
        public
    {
        MockPushCcipRouter router = _armPush();

        vm.deal(
            stranger,
            1 ether
        );

        vm.prank(
            stranger
        );

        registry.pushPayoutAddress{value: PUSH_FEE}(
            ownerA
        );

        assertEq(router.sendCount(), 1);
        assertEq(stranger.balance, 1 ether - PUSH_FEE);
        assertEq(address(router).balance, PUSH_FEE);

        (
            ,
            address owner,
            address payout,
            ,
        ) = abi.decode(
            router.lastData(),
            (uint256, address, address, uint256, uint256)
        );

        assertEq(owner, ownerA);
        assertEq(payout, payoutA);
    }

    function test_pushPayoutAddress_refundsExcess()
        public
    {
        MockPushCcipRouter router = _armPush();

        vm.deal(
            address(this),
            10 ether
        );

        uint256 balanceBefore = address(this).balance;

        registry.pushPayoutAddress{value: PUSH_FEE + 0.5 ether}(
            ownerA
        );

        assertEq(address(this).balance, balanceBefore - PUSH_FEE);
        assertEq(address(router).balance, PUSH_FEE);
        assertEq(address(registry).balance, 0);
    }

    function test_pushPayoutAddress_revertsWhenFeeInsufficient()
        public
    {
        _armPush();

        vm.deal(
            address(this),
            1 ether
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InsufficientPushFee.selector
        );

        registry.pushPayoutAddress{value: PUSH_FEE - 1}(
            ownerA
        );
    }

    function test_pushPayoutAddress_revertsWhenRefundRejected()
        public
    {
        _armPush();

        PushRefundRejector rejector = new PushRefundRejector(
            registry
        );

        vm.deal(
            address(this),
            1 ether
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.PushRefundFailed.selector
        );

        rejector.trigger{value: PUSH_FEE + 0.1 ether}(
            ownerA
        );
    }

    function test_pushPayoutAddress_zeroPayoutDesignationPushes()
        public
    {
        MockPushCcipRouter router = _armPush();

        registry.setSyncGasLimit(
            400_000
        );

        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            address(0)
        );

        vm.deal(
            address(this),
            1 ether
        );

        registry.pushPayoutAddress{value: PUSH_FEE}(
            ownerA
        );

        assertEq(router.sendCount(), 1);

        (
            uint256 version,
            address owner,
            address payout,
            uint256 setAt,
            uint256 rank
        ) = abi.decode(
            router.lastData(),
            (uint256, address, address, uint256, uint256)
        );

        assertEq(version, 1);
        assertEq(owner, ownerA);
        assertEq(payout, address(0));
        assertEq(setAt, BASE_TIME);
        assertEq(rank, 0);
    }

    // ---- quotePushPayoutFee ----

    function test_quotePushPayoutFee_revertsWhenPayoutHubNotSet()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.PayoutHubNotSet.selector
        );

        registry.quotePushPayoutFee(
            ownerA
        );
    }

    function test_quotePushPayoutFee_returnsRouterFee()
        public
    {
        _armPush();

        assertEq(
            registry.quotePushPayoutFee(
                ownerA
            ),
            PUSH_FEE
        );
    }

    // ---- payout hub route ----

    function test_proposePayoutHub_storesProposalAndEmits()
        public
    {
        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(registry)
        );

        emit PayoutHubProposed(
            hubAddress,
            SEL_HUB,
            BASE_TIME
        );

        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        assertEq(registry.proposedPayoutHub(), hubAddress);
        assertEq(registry.proposedPayoutHubChainSelector(), SEL_HUB);
        assertEq(registry.payoutHubChangeQueuedAt(), BASE_TIME);
    }

    function test_executePayoutHubChange_instantPreFinalize()
        public
    {
        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(registry)
        );

        emit PayoutHubSet(
            hubAddress,
            SEL_HUB
        );

        registry.executePayoutHubChange();

        assertEq(registry.payoutHub(), hubAddress);
        assertEq(registry.payoutHubChainSelector(), SEL_HUB);
        assertEq(registry.proposedPayoutHub(), address(0));
        assertEq(registry.proposedPayoutHubChainSelector(), 0);
        assertEq(registry.payoutHubChangeQueuedAt(), 0);
    }

    function test_executePayoutHubChange_revertsWhenNoneProposed()
        public
    {
        vm.expectRevert(
            ReferralRegistryDeclarations.NoPayoutHubProposed.selector
        );

        registry.executePayoutHubChange();
    }

    function test_executePayoutHubChange_timelockAfterFinalize()
        public
    {
        registry.setCcipRouter(
            routerEoa
        );

        registry.finalizeSyncSetup();

        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.PayoutHubTimelockNotElapsed.selector
        );

        registry.executePayoutHubChange();

        vm.warp(
            BASE_TIME + 3 days + 1
        );

        registry.executePayoutHubChange();

        assertEq(registry.payoutHub(), hubAddress);
        assertEq(registry.payoutHubChainSelector(), SEL_HUB);
    }

    function test_executePayoutHubChange_revertsWhenHubZeroSelectorNonzero()
        public
    {
        registry.proposePayoutHub(
            address(0),
            SEL_HUB
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidPayoutHub.selector
        );

        registry.executePayoutHubChange();
    }

    function test_executePayoutHubChange_revertsWhenHubNonzeroSelectorZero()
        public
    {
        registry.proposePayoutHub(
            hubAddress,
            0
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidPayoutHub.selector
        );

        registry.executePayoutHubChange();
    }

    function test_executePayoutHubChange_allZeroProposalDetaches()
        public
    {
        _armPush();

        registry.proposePayoutHub(
            address(0),
            0
        );

        registry.executePayoutHubChange();

        assertEq(registry.payoutHub(), address(0));
        assertEq(registry.payoutHubChainSelector(), 0);

        vm.deal(
            address(this),
            1 ether
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.PayoutHubNotSet.selector
        );

        registry.pushPayoutAddress{value: PUSH_FEE}(
            ownerA
        );
    }

    function test_cancelPayoutHubChange_clearsProposal()
        public
    {
        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        vm.expectEmit(
            true,
            false,
            false,
            true,
            address(registry)
        );

        emit PayoutHubProposalCancelled(
            hubAddress
        );

        registry.cancelPayoutHubChange();

        assertEq(registry.proposedPayoutHub(), address(0));
        assertEq(registry.proposedPayoutHubChainSelector(), 0);
        assertEq(registry.payoutHubChangeQueuedAt(), 0);

        vm.expectRevert(
            ReferralRegistryDeclarations.NoPayoutHubProposed.selector
        );

        registry.executePayoutHubChange();
    }

    function test_payoutHubRoute_revertsWhenNotMaster()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.executePayoutHubChange();

        vm.prank(
            stranger
        );

        vm.expectRevert(
            NotMaster.selector
        );

        registry.cancelPayoutHubChange();
    }

    // ---- fuzz ----

    function testFuzz_setPayoutAddress_redesignationRestamps(
        address _payout,
        uint256 _delta
    )
        public
    {
        uint256 delta = bound(
            _delta,
            1,
            52 weeks
        );

        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            payoutA
        );

        uint256 stampBefore = registry.payoutStamp(
            ownerA
        );

        vm.warp(
            BASE_TIME + delta
        );

        vm.prank(
            ownerA
        );

        registry.setPayoutAddress(
            _payout
        );

        uint256 stampAfter = registry.payoutStamp(
            ownerA
        );

        assertEq(registry.payoutAddress(ownerA), _payout);
        assertEq(stampAfter, _stamp(BASE_TIME + delta, 0));
        assertGt(stampAfter, stampBefore);
    }
}
