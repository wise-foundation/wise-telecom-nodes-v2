// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {WiseTelecomNodesDiamond} from "../../src/diamond/vault/WiseTelecomNodesDiamond.sol";
import {AdminFacet} from "../../src/diamond/vault/facets/AdminFacet.sol";
import {BridgeFacet} from "../../src/diamond/vault/facets/BridgeFacet.sol";
import {ReferralFacet} from "../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {CohortHookFacet} from "../../src/diamond/vault/facets/pending/CohortHookFacet.sol";
import {CohortBridgeHookFacet} from "../../src/diamond/vault/facets/pending/CohortBridgeHookFacet.sol";
import {CohortRecorderFacet} from "../../src/diamond/vault/facets/pending/CohortRecorderFacet.sol";
import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";

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
 * @dev Records the wire `data` of the last `ccipSend` instead of
 * relaying it synchronously, so a test can rebuild the exact
 * `Any2EVMMessage` the DON would deliver and measure the destination
 * `ccipReceive` as its own cold call — a synchronous relay would fold
 * the delivery gas into the source-side send. `getFee` returns a flat
 * fee like the bridge suite's relaying mock.
 */
contract RecordingCcipRouter {

    uint256 public constant FIXED_FEE = 0.01 ether;

    bytes public lastData;

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
        Client.EVM2AnyMessage calldata _message
    )
        external
        payable
        returns (bytes32)
    {
        lastData = _message.data;

        return bytes32(
            uint256(1)
        );
    }
}

/**
 * @dev Gas-bound proof for the cohort recorder's dormancy handling.
 * Measurements are gasleft() deltas around a raw `.call()` with the
 * calldata encoded and the caller pranked strictly before the window,
 * so nothing but the measured call's own execution lands inside it.
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
 *
 * Two cross-machinery cells extend the table with BUDGET-derived
 * ceilings (fixed by external gas limits rather than measured-plus-
 * margin; their GAS_TABLE rows log the measured numbers for
 * recalibration). Cell 6 measures the worst-case armed bridge-carry
 * apply as the destination's cold `ccipReceive`: a two-diamond pair
 * wired through a recording router, the destination referrer's book
 * cap-dormant at delivery (105 weeks) so the apply's settle walks the
 * full 104-boundary cap before landing the carry — ceiling 3,000,000,
 * 75% of the 4,000,000 CCIP delivery gas limit the arming script
 * commits via `setBridgeGasLimit`, because a delivery that outgrows
 * that limit strands the carry. Cell 7 measures the registry's
 * permissionless `pokeMigration` single-vault worst case: the old
 * referrer's rings populated across forty weekly cohorts, then
 * cap-dormant, so the flip migration settles the full walk, drains
 * the matured book and replants it under the new referrer — ceiling
 * 3,500,000, sized to the same dormant-full-walk budget band as
 * cell 1's 3,600,000 transfer-hook ceiling.
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

    uint256 internal constant CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING = 3_000_000;

    uint256 internal constant POKE_MIGRATION_FLIP_GAS_CEILING = 3_500_000;

    uint256 internal constant WEEKLY_DEPOSIT = 100 * 1e6;

    uint256 internal constant POPULATED_WEEKS = 40;

    uint256 internal constant BRIDGE_FEE = 0.01 ether;

    uint64 internal constant SRC_SELECTOR = 1111;

    uint64 internal constant DST_SELECTOR = 2222;

    address internal user1 = address(0xA1);
    address internal user2 = address(0xA2);
    address internal refA = address(0xB1);
    address internal refB = address(0xB2);
    address internal outsider = address(0xC1);

    WiseTelecomNodesDiamond internal diamond;
    MockUSD internal usd;
    ReferralRegistry internal registry;

    WiseTelecomNodesDiamond internal bridgeSrc;
    WiseTelecomNodesDiamond internal bridgeDst;
    MockUSD internal usdSrc;
    MockUSD internal usdDst;
    RecordingCcipRouter internal bridgeRouter;

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

        _wireOne(
            diamond,
            address(new CohortBridgeHookFacet()),
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()
        );

        AdminFacet(address(diamond)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(diamond)).executeTransferHookFacetChange();

        registry = _wireReferralRegistry(
            diamond
        );

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

    function _deployArmedBridgePair()
        internal
    {
        bridgeRouter = new RecordingCcipRouter();

        usdSrc = new MockUSD();

        usdDst = new MockUSD();

        bridgeSrc = _deployArmedBridgeVault(
            address(usdSrc)
        );

        bridgeDst = _deployArmedBridgeVault(
            address(usdDst)
        );

        _peerInstant(
            bridgeSrc,
            DST_SELECTOR,
            address(bridgeDst)
        );

        _peerInstant(
            bridgeDst,
            SRC_SELECTOR,
            address(bridgeSrc)
        );

        bridgeSrc.finalizeSetup();

        bridgeDst.finalizeSetup();

        AdminFacet(address(bridgeSrc)).setCohortSyncEnabled(
            true
        );

        AdminFacet(address(bridgeDst)).setCohortSyncEnabled(
            true
        );
    }

    function _deployArmedBridgeVault(
        address _usd
    )
        internal
        returns (WiseTelecomNodesDiamond d)
    {
        d = _newDiamond(
            _usd
        );

        _wireAllFacets(
            d
        );

        _wireOne(
            d,
            address(new ReferralFacet()),
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        _wireOne(
            d,
            address(new CohortRecorderFacet()),
            WiseTelecomNodesDiamondSelectors.cohortRecorderSelectors()
        );

        _wireOne(
            d,
            address(new CohortBridgeHookFacet()),
            WiseTelecomNodesDiamondSelectors.cohortBridgeHookSelectors()
        );

        _wireOne(
            d,
            address(new BridgeFacet()),
            WiseTelecomNodesDiamondSelectors.bridgeSelectors()
        );

        AdminFacet(address(d)).proposeTransferHookFacet(
            address(new CohortHookFacet())
        );

        AdminFacet(address(d)).executeTransferHookFacetChange();

        _wireReferralRegistry(
            d
        );

        BridgeFacet(address(d)).setCcipRouter(
            address(bridgeRouter)
        );
    }

    function _peerInstant(
        WiseTelecomNodesDiamond _vault,
        uint64 _selector,
        address _peer
    )
        internal
    {
        BridgeFacet(address(_vault)).proposeCrossChainPeer(
            _selector,
            _peer,
            6
        );

        BridgeFacet(address(_vault)).executeCrossChainPeerChange(
            _selector
        );
    }

    function _depositWithReferralOn(
        WiseTelecomNodesDiamond _vault,
        MockUSD _usd,
        address _user,
        uint256 _amount,
        address _referrer
    )
        internal
    {
        _usd.mint(
            _user,
            _amount
        );

        vm.prank(
            _user
        );

        _usd.approve(
            address(_vault),
            _amount
        );

        vm.prank(
            _user
        );

        ReferralFacet(address(_vault)).depositWithReferral(
            _amount,
            _referrer
        );
    }

    function _measureCcipReceive(
        bytes memory _payload
    )
        internal
        returns (uint256 used)
    {
        vm.prank(
            address(bridgeRouter)
        );

        uint256 g = gasleft();

        (bool ok, ) = address(bridgeDst).call(_payload);

        used = g - gasleft();

        assertTrue(
            ok,
            "measured ccipReceive reverted"
        );
    }

    function _measurePokeMigration(
        address _user
    )
        internal
        returns (uint256 used)
    {
        bytes memory payload = abi.encodeCall(
            ReferralRegistry.pokeMigration,
            (_user)
        );

        uint256 g = gasleft();

        (bool ok, ) = address(registry).call(payload);

        used = g - gasleft();

        assertTrue(
            ok,
            "measured pokeMigration reverted"
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

    function test_gas_ccipReceive_armedCarryApply_dormantDestination()
        public
    {
        _deployArmedBridgePair();

        _depositWithReferralOn(
            bridgeDst,
            usdDst,
            user2,
            DEPOSIT,
            refA
        );

        _depositWithReferralOn(
            bridgeSrc,
            usdSrc,
            user1,
            DEPOSIT,
            refA
        );

        vm.warp(
            block.timestamp + 105 weeks
        );

        vm.deal(
            user1,
            1 ether
        );

        vm.prank(
            user1
        );

        BridgeFacet(address(bridgeSrc)).bridgeToVault{value: BRIDGE_FEE}(
            DST_SELECTOR,
            DEPOSIT
        );

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(0xCA11)),
            sourceChainSelector: SRC_SELECTOR,
            sender: abi.encode(
                address(bridgeSrc)
            ),
            data: bridgeRouter.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        uint256 used = _measureCcipReceive(
            abi.encodeCall(
                BridgeFacet.ccipReceive,
                (message)
            )
        );

        _logGas(
            "ccipReceive_armedCarryApply_dormantDestination",
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING
        );

        assertLe(
            used,
            CCIP_RECEIVE_ARMED_APPLY_GAS_CEILING,
            "gas: armed dormant-destination carry apply exceeded ceiling"
        );

        assertEq(
            CohortRecorderFacet(address(bridgeDst)).getTrackedContribution(
                user1
            ),
            DEPOSIT,
            "carry was not applied on the destination"
        );

        (
            ,
            ,
            uint256 mature,
        ) = CohortRecorderFacet(address(bridgeDst)).getCohortBook(
            refA
        );

        assertEq(
            mature,
            2 * DEPOSIT,
            "carried book credit did not land on the destination referrer"
        );
    }

    function test_gas_pokeMigration_flipAfterDormantPopulatedRings()
        public
    {
        for (uint256 i; i < POPULATED_WEEKS; ++i) {

            _depositWithReferralAs(
                user1,
                WEEKLY_DEPOSIT,
                refA
            );

            vm.warp(
                block.timestamp + 1 weeks
            );
        }

        vm.warp(
            block.timestamp + 105 weeks
        );

        uint256 loweredAssignedAt = BASE_TIME - 1 days;

        vm.prank(
            address(diamond)
        );

        registry.mergeReferrer(
            user1,
            refB,
            loweredAssignedAt,
            0
        );

        assertEq(
            registry.pendingFlip(
                address(diamond),
                user1
            ),
            refA,
            "flip marker missing before the poke"
        );

        uint256 used = _measurePokeMigration(
            user1
        );

        _logGas(
            "pokeMigration_flipAfterDormantPopulatedRings",
            used,
            POKE_MIGRATION_FLIP_GAS_CEILING
        );

        assertLe(
            used,
            POKE_MIGRATION_FLIP_GAS_CEILING,
            "gas: dormant flip migration exceeded ceiling"
        );

        assertEq(
            registry.pendingFlip(
                address(diamond),
                user1
            ),
            address(0),
            "flip migration was deferred instead of applied"
        );

        (
            ,
            ,
            uint256 mature,
        ) = _recorder().getCohortBook(
            refB
        );

        assertEq(
            mature,
            POPULATED_WEEKS * WEEKLY_DEPOSIT,
            "migrated mature credit mismatch on the new referrer"
        );
    }
}
