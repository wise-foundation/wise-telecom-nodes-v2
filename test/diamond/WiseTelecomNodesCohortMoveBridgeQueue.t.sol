// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {UserFacet} from "../../src/diamond/vault/facets/UserFacet.sol";
import {MoveFacet} from "../../src/diamond/vault/facets/MoveFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {QueueJoinLeaveFacet} from "../../src/diamond/vault/facets/QueueJoinLeaveFacet.sol";
import {QueueFulfillFacet} from "../../src/diamond/vault/facets/QueueFulfillFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {IPermit2} from "../../src/diamond/vault/interfaces/IPermit2.sol";

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

contract MockPermit2 is IPermit2 {

    function permitTransferFrom(
        PermitTransferFrom calldata _permit,
        SignatureTransferDetails calldata _transferDetails,
        address _owner,
        bytes calldata
    )
        external
    {
        require(
            block.timestamp <= _permit.deadline,
            "deadline"
        );

        IERC20(_permit.permitted.token).transferFrom(
            _owner,
            _transferDetails.to,
            _transferDetails.requestedAmount
        );
    }
}

/**
 * @dev Minimal same-chain peer used to drive `moveBetweenVaults` /
 * `mintFromPeer` from the source diamond's perspective. `decimals()`
 * matches the source diamond's 6 decimals so `_scaleAmountForPeer`
 * passes through 1:1 and the cohort-recorder math in the tests below
 * stays in round numbers. `mintFromPeer` is never actually invoked on
 * this contract by the suite (it is only ever the peer being pranked),
 * but is implemented as a no-op to satisfy `IPeerVault`.
 */
contract MockPeerVault {

    function decimals()
        external
        pure
        returns (uint8)
    {
        return 6;
    }

    function mintFromPeer(
        address,
        uint256
    )
        external
    {}
}

/**
 * @dev Minimal CCIP router stand-in: a flat `getFee` and a `ccipSend`
 * that only needs to accept the fee and return a messageId, because
 * every `ccipReceive` in this suite is driven directly by pranking the
 * router with a hand-built `Client.Any2EVMMessage`, mirroring
 * `WiseTelecomNodesBridge.t.sol`'s `MockCCIPRouter` without the
 * synchronous cross-diamond relay (this suite only has one diamond).
 */
contract MockCCIPRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    )
        external
        pure
        returns (uint256)
    {
        return FIXED_FEE;
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage calldata
    )
        external
        payable
        returns (bytes32)
    {
        return bytes32(uint256(1));
    }
}

/**
 * @dev Phase-2b touchpoint suite for the cohort recorder: the
 * move/bridge/queue surfaces wired on top of the {CohortHookFacet}
 * engine installed as the transfer hook (see
 * `WiseTelecomNodesCohortTouchpoints.t.sol` for the deposit/compound
 * and lazy-clamp phase). `_executeMoveOut` / `_executeBridgeOut`
 * double-sync around their `_burn` (immediate discredit, no waiting
 * for the next poke); `_executeMintFromPeer` / `_executeBridgeReceive`
 * sync once BEFORE their `_mint` (clamp-before-heal, never re-credit);
 * `_transferTokensIn` syncs once AFTER the queue escrow leg
 * (immediate discredit on `joinQue`); queue leave/fulfill run the
 * ordinary two-party transfer hook via `_moveVaultTokens`, which never
 * re-credits; and `switchQueIncentive` moves no shares and runs no
 * hook at all, so recorder state must be byte-identical across it.
 *
 * `test_bridgeToVault_discreditsImmediately` additionally pins the
 * payable-delegatecall regression this suite originally uncovered:
 * `bridgeToVault` is the diamond's only payable surface and
 * `_executeBridgeOut` runs `_cohortSync` while `msg.value` still
 * carries the CCIP fee, so {CohortHookFacet}'s entrypoints must stay
 * `payable` — a non-payable engine would revert on the compiler's
 * callvalue guard and DoS bridging out on every fee-charging lane.
 */
contract WiseTelecomNodesCohortMoveBridgeQueueTest is DiamondTestHarness {

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    uint256 internal constant DEPOSIT = 5_000 * 1e6;

    uint256 internal constant PEER_VAULT_CHANGE_DELAY = 3 days;

    uint256 internal constant CROSS_CHAIN_PEER_CHANGE_DELAY = 3 days;

    uint64 internal constant DEST_SELECTOR = 2222;

    address internal constant CROSS_CHAIN_PEER = address(0xB33F);

    bytes32 internal constant CREDITED_TOPIC = keccak256(
        "CohortContributionCredited(address,address,uint256)"
    );

    bytes32 internal constant SYNCED_TOPIC = keccak256(
        "CohortContributionSynced(address,address,uint256,uint256)"
    );

    bytes32 internal constant REDUCED_TOPIC = keccak256(
        "CohortBookReduced(address,uint256,uint256,uint256,uint256)"
    );

    address internal user1 = address(0xA1);
    address internal refA = address(0xB1);
    address internal outsider = address(0xC1);
    address internal buyer = address(0xC2);
    address internal poker = address(0xD1);

    WiseTelecomNodesDiamond internal diamond;
    MockUSD internal usd;
    MockPeerVault internal peer;
    MockCCIPRouter internal router;

    function setUp()
        public
    {
        vm.warp(
            BASE_TIME
        );

        usd = new MockUSD();

        MockPermit2 mock = new MockPermit2();

        vm.etch(
            CANONICAL_PERMIT2,
            address(mock).code
        );

        diamond = _newDiamond(
            address(usd)
        );

        _wireAllFacets(
            diamond
        );

        _wireQueueFacets(
            diamond
        );

        _wireOne(
            diamond,
            address(new BridgeFacet()),
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        _wireOne(
            diamond,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            diamond,
            address(new Permit2ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors()
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

        _wireReferralRegistry(
            diamond
        );

        diamond.finalizeSetup();

        usd.mint(
            address(diamond),
            100_000_000 * 1e6
        );

        peer = new MockPeerVault();

        MoveFacet(address(diamond)).proposePeerVault(
            address(peer)
        );

        vm.warp(
            block.timestamp + PEER_VAULT_CHANGE_DELAY
        );

        MoveFacet(address(diamond)).executePeerVaultChange(
            address(peer)
        );

        router = new MockCCIPRouter();

        BridgeFacet(address(diamond)).setCcipRouter(
            address(router)
        );

        BridgeFacet(address(diamond)).proposeCrossChainPeer(
            DEST_SELECTOR,
            CROSS_CHAIN_PEER,
            6
        );

        vm.warp(
            block.timestamp + CROSS_CHAIN_PEER_CHANGE_DELAY
        );

        BridgeFacet(address(diamond)).executeCrossChainPeerChange(
            DEST_SELECTOR
        );
    }

    // ---- helpers ----

    function _arm()
        internal
    {
        AdminFacet(address(diamond)).setCohortSyncEnabled(
            true
        );
    }

    function _recorder()
        internal
        view
        returns (CohortRecorderFacet)
    {
        return CohortRecorderFacet(
            address(diamond)
        );
    }

    function _fundAndApprove(
        address _user,
        uint256 _amount
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
    }

    function _depositAs(
        address _user,
        uint256 _amount
    )
        internal
    {
        _fundAndApprove(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        UserFacet(address(diamond)).deposit(
            _amount
        );
    }

    function _depositWithReferralAs(
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _fundAndApprove(
            _user,
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

    function _countTopic(
        Vm.Log[] memory _logs,
        bytes32 _topic
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].topics[0] == _topic) {
                ++count;
            }
        }
    }

    // ---- 1. moveBetweenVaults ----

    function test_moveBetweenVaults_discreditsImmediately()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamond)).moveBetweenVaults(
            address(peer),
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(refA),
            3_000 * 1e6
        );
    }

    function test_moveBetweenVaults_fullExit_zeroesTracked()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        MoveFacet(address(diamond)).moveBetweenVaults(
            address(peer),
            DEPOSIT
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            0
        );

        assertEq(
            _recorder().getCohortScore(refA),
            0
        );
    }

    // ---- 2. mintFromPeer ----

    function test_mintFromPeer_afterDeficit_clampsBeforeMint()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        vm.prank(
            address(peer)
        );

        MoveFacet(address(diamond)).mintFromPeer(
            user1,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            DEPOSIT
        );
    }

    function test_mintFromPeer_neverCredits()
        public
    {
        _arm();

        vm.prank(
            address(peer)
        );

        MoveFacet(address(diamond)).mintFromPeer(
            outsider,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(outsider),
            0
        );
    }

    // ---- 3. bridgeToVault ----

    function test_bridgeToVault_discreditsImmediately()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.deal(
            user1,
            1 ether
        );

        uint256 fee = router.FIXED_FEE();

        vm.prank(
            user1
        );

        BridgeFacet(address(diamond)).bridgeToVault{value: fee}(
            DEST_SELECTOR,
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(refA),
            3_000 * 1e6
        );
    }

    // ---- 4. ccipReceive ----

    function test_ccipReceive_afterDeficit_clampsBeforeMint()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        _transferAs(
            user1,
            outsider,
            2_000 * 1e6
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: DEST_SELECTOR,
            sender: abi.encode(CROSS_CHAIN_PEER),
            data: abi.encode(user1, uint256(2_000 * 1e6)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(diamond)).ccipReceive(
            message
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );

        assertEq(
            diamond.balanceOf(user1),
            DEPOSIT
        );
    }

    function test_ccipReceive_neverCredits()
        public
    {
        _arm();

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(2)),
            sourceChainSelector: DEST_SELECTOR,
            sender: abi.encode(CROSS_CHAIN_PEER),
            data: abi.encode(outsider, uint256(2_000 * 1e6)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(
            address(router)
        );

        BridgeFacet(address(diamond)).ccipReceive(
            message
        );

        assertEq(
            _recorder().getTrackedContribution(outsider),
            0
        );
    }

    // ---- 5. queue join / leave ----

    function test_joinQue_discreditsImmediatelyPostEscrow()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(refA),
            3_000 * 1e6
        );
    }

    function test_leaveQue_returnsEscrowWithoutRecredit()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).leaveQue(
            queId,
            0
        );

        assertEq(
            diamond.balanceOf(user1),
            DEPOSIT
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );

        assertEq(
            _recorder().getCohortScore(refA),
            3_000 * 1e6
        );

        vm.prank(
            poker
        );

        _recorder().syncReferee(
            user1
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );
    }

    // ---- 6. fulfillOrder ----

    function test_fulfillOrder_buyerGetsNoCreditSellerUnchanged()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );

        _fundAndApprove(
            buyer,
            2_000 * 1e6
        );

        vm.recordLogs();

        vm.prank(
            buyer
        );

        QueueFulfillFacet(address(diamond)).fulfillOrder(
            queId,
            0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            diamond.balanceOf(buyer),
            2_000 * 1e6
        );

        assertEq(
            _recorder().getTrackedContribution(buyer),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            3_000 * 1e6
        );
    }

    // ---- 7. switchQueIncentive ----

    function test_switchQueIncentive_recorderStateByteIdentical()
        public
    {
        _arm();

        _depositWithReferralAs(
            user1,
            DEPOSIT,
            refA
        );

        vm.prank(
            user1
        );

        (
            ,
            uint256 queId
        ) = QueueJoinLeaveFacet(address(diamond)).joinQue(
            2_000 * 1e6,
            0
        );

        uint256 trackedBefore = _recorder().getTrackedContribution(user1);

        uint256 scoreBefore = _recorder().getCohortScore(refA);

        (
            uint256 year1Before,
            uint256 year2Before,
            uint256 matureBefore,
            uint256 lastSettleBefore
        ) = _recorder().getCohortBook(refA);

        vm.recordLogs();

        vm.prank(
            user1
        );

        QueueJoinLeaveFacet(address(diamond)).switchQueIncentive(
            queId,
            0,
            100
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countTopic(
                logs,
                CREDITED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                SYNCED_TOPIC
            ),
            0
        );

        assertEq(
            _countTopic(
                logs,
                REDUCED_TOPIC
            ),
            0
        );

        assertEq(
            _recorder().getTrackedContribution(user1),
            trackedBefore
        );

        assertEq(
            _recorder().getCohortScore(refA),
            scoreBefore
        );

        (
            uint256 year1After,
            uint256 year2After,
            uint256 matureAfter,
            uint256 lastSettleAfter
        ) = _recorder().getCohortBook(refA);

        assertEq(
            year1After,
            year1Before
        );

        assertEq(
            year2After,
            year2Before
        );

        assertEq(
            matureAfter,
            matureBefore
        );

        assertEq(
            lastSettleAfter,
            lastSettleBefore
        );
    }
}
