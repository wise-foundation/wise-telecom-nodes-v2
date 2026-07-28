// SPDX-License-Identifier: MIT
pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {
    PetDiamond,
    DepositFacet,
    ReferralFacet,
    BadReferralFacet
} from "./PetDiamondDemo.sol";

// The union of all facet functions, cast onto the diamond's address so the
// diamond's fallback routes each call to the right facet by selector.
interface IPet {
    function deposit() external payable;
    function readCounter() external view returns (uint256);
    function depositOf(address who) external view returns (uint256);
    function setReferrer(address ref) external;
    function getReferrer(address who) external view returns (address);
    function readCounterViaReferralFacet() external view returns (uint256);
    function readCounterViaBadFacet() external view returns (uint256);
    function bumpCounterBad() external;
}

contract PetDiamondTest is Test {
    PetDiamond internal diamond;
    DepositFacet internal depositFacet;
    ReferralFacet internal referralFacet;
    BadReferralFacet internal badFacet;

    IPet internal pet; // = the diamond, viewed through the facet ABI

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    // Slot numbers of the shared PetDeclarations layout (0-5 used; 6 is the
    // next free slot the ReferralFacet appends).
    uint256 internal constant SLOT_COUNTER = 2;
    uint256 internal constant SLOT_TOTAL_DEPOSITED = 3;
    uint256 internal constant SLOT_DEPOSITS = 4;
    uint256 internal constant SLOT_DEPOSIT_COUNT = 5;
    uint256 internal constant SLOT_REFERRER = 6;

    function setUp() public {
        diamond = new PetDiamond();
        depositFacet = new DepositFacet();
        referralFacet = new ReferralFacet();
        badFacet = new BadReferralFacet();

        pet = IPet(address(diamond));

        // Wire the "already deployed" facet — the diamond ships knowing only
        // slots 0-5.
        diamond.setFacet(DepositFacet.deposit.selector, address(depositFacet));
        diamond.setFacet(DepositFacet.readCounter.selector, address(depositFacet));
        diamond.setFacet(DepositFacet.depositOf.selector, address(depositFacet));
    }

    // ----- helpers ---------------------------------------------------------

    function _mappingSlot(address _key, uint256 _slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(_key, _slot));
    }

    function _loadSlot(uint256 _slot) internal view returns (uint256) {
        return uint256(vm.load(address(diamond), bytes32(_slot)));
    }

    function _loadMapping(address _key, uint256 _slot) internal view returns (uint256) {
        return uint256(vm.load(address(diamond), _mappingSlot(_key, _slot)));
    }

    function _depositThrice() internal {
        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        pet.deposit{value: 1 ether}();
        pet.deposit{value: 1 ether}();
        pet.deposit{value: 1 ether}();
        vm.stopPrank();
    }

    // ----- 1. fresh diamond: everything is zero ----------------------------

    function test_freshDiamond_slotsAreZero() public view {
        assertEq(_loadSlot(SLOT_COUNTER), 0, "counter (slot 2) starts 0");
        assertEq(_loadMapping(alice, SLOT_REFERRER), 0, "referrerOf[alice] (slot 6) starts 0");
    }

    // ----- 2. the old facet uses slots 2-5 and is blind to slot 6 ----------

    function test_depositFacet_touchesSlots2to5_neverSlot6() public {
        _depositThrice();

        assertEq(_loadSlot(SLOT_COUNTER), 3, "counter (slot 2)");
        assertEq(_loadSlot(SLOT_TOTAL_DEPOSITED), 3 ether, "totalDeposited (slot 3)");
        assertEq(_loadMapping(alice, SLOT_DEPOSITS), 3 ether, "deposits[alice] (slot 4)");
        assertEq(_loadSlot(SLOT_DEPOSIT_COUNT), 3, "depositCount (slot 5)");

        // The deposit facet's bytecode cannot reference slot 6 — it was compiled
        // without it — so slot 6 stays zero no matter what deposits happen.
        assertEq(_loadMapping(alice, SLOT_REFERRER), 0, "referrerOf[alice] (slot 6) untouched");
    }

    // ----- 3. THE PROOF: a facet added after deploy writes diamond slot 6 ---

    function test_facetAddedAfterDeploy_writesSlot6OfDiamond() public {
        // The referral facet is wired now — AFTER the diamond was constructed
        // and already live. No redeploy of the diamond.
        diamond.setFacet(ReferralFacet.setReferrer.selector, address(referralFacet));
        diamond.setFacet(ReferralFacet.getReferrer.selector, address(referralFacet));

        vm.prank(alice);
        pet.setReferrer(bob);

        // (a) reachable through the facet ABI
        assertEq(pet.getReferrer(alice), bob, "getReferrer(alice) == bob");

        // (b) the physical proof: the referrer bytes sit in slot 6 OF THE
        //     DIAMOND, at keccak256(alice . 6) — computed independently here.
        bytes32 raw = vm.load(address(diamond), _mappingSlot(alice, SLOT_REFERRER));
        assertEq(
            raw,
            bytes32(uint256(uint160(bob))),
            "referrerOf[alice] physically lives in the diamond's slot 6"
        );
    }

    // ----- 4. the appended facet still agrees on the existing slots ---------

    function test_appendedFacet_agreesOnExistingSlots() public {
        diamond.setFacet(
            ReferralFacet.readCounterViaReferralFacet.selector,
            address(referralFacet)
        );

        vm.deal(alice, 2 ether);
        vm.startPrank(alice);
        pet.deposit{value: 1 ether}();
        pet.deposit{value: 1 ether}();
        vm.stopPrank();

        // DepositFacet bumped counter to 2 (slot 2). The later-added
        // ReferralFacet reads that SAME slot 2 while also owning slot 6.
        assertEq(pet.readCounterViaReferralFacet(), 2, "ReferralFacet reads counter via slot 2");
        assertEq(
            pet.readCounterViaReferralFacet(),
            _loadSlot(SLOT_COUNTER),
            "ReferralFacet's view matches the raw diamond slot 2"
        );
    }

    // ----- 5. the counterexample: inserting in the middle corrupts ----------

    function test_insertingInMiddle_corrupts() public {
        _depositThrice();

        // Real state before the bad facet is wired.
        assertEq(_loadSlot(SLOT_COUNTER), 3, "real counter (slot 2) == 3");
        assertEq(_loadSlot(SLOT_TOTAL_DEPOSITED), 3 ether, "real totalDeposited (slot 3) == 3 ether");

        diamond.setFacet(BadReferralFacet.readCounterViaBadFacet.selector, address(badFacet));
        diamond.setFacet(BadReferralFacet.bumpCounterBad.selector, address(badFacet));

        // BadReferralFacet declared its mapping FIRST, so every real field
        // shifted up one: its `counter` resolves to slot 3. Reading it returns
        // totalDeposited, NOT the real counter.
        uint256 badRead = pet.readCounterViaBadFacet();
        assertEq(badRead, 3 ether, "bad facet reads the shifted slot 3");
        assertTrue(badRead != 3, "bad facet does NOT return the real counter");

        // Writing "counter" through the bad facet hits slot 3, corrupting
        // totalDeposited, while the real counter at slot 2 is left untouched.
        pet.bumpCounterBad();
        assertEq(_loadSlot(SLOT_COUNTER), 3, "real counter (slot 2) untouched");
        assertEq(
            _loadSlot(SLOT_TOTAL_DEPOSITED),
            3 ether + 100,
            "totalDeposited (slot 3) corrupted by the bad facet"
        );
    }
}
