// SPDX-License-Identifier: MIT
pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {PetDiamond, DepositFacet, ReferralFacet} from "./PetDiamondDemo.sol";
import {
    LibPetReferral,
    PinnedReferralFacet,
    PinnedGateFacet,
    BadPinnedFacet
} from "./PetDiamondPinned.sol";

interface IPetPinned {
    function deposit() external payable;
    function depositOf(address who) external view returns (uint256);
    // inheritance-based referral (Part 1 facet)
    function setReferrer(address ref) external;
    function getReferrer(address who) external view returns (address);
    // slot-pinned referral (this variant)
    function setReferrerPinned(address ref) external;
    function getReferrerPinned(address who) external view returns (address);
    function setActivePinned(bool v) external;
    function isActivePinned() external view returns (bool);
    // wrong pins
    function setActiveBad(bool v) external;
    function setReferrerBad(address ref) external;
}

contract PetDiamondPinnedTest is Test {
    PetDiamond internal diamond;
    DepositFacet internal depositFacet;
    ReferralFacet internal referralFacet; // inheritance-based (Part 1)
    PinnedReferralFacet internal pinnedFacet;
    PinnedGateFacet internal gateFacet;
    BadPinnedFacet internal badFacet;

    IPetPinned internal pet;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal dan = address(0xDA4);

    uint256 internal constant SLOT_COUNTER = 2;
    uint256 internal constant SLOT_TOTAL_DEPOSITED = 3;
    uint256 internal constant SLOT_DEPOSITS = 4;
    uint256 internal constant SLOT_REFERRER = 6;
    uint256 internal constant SLOT_ACTIVE = 7;

    function setUp() public {
        diamond = new PetDiamond();
        depositFacet = new DepositFacet();
        referralFacet = new ReferralFacet();
        pinnedFacet = new PinnedReferralFacet();
        gateFacet = new PinnedGateFacet();
        badFacet = new BadPinnedFacet();

        pet = IPetPinned(address(diamond));

        diamond.setFacet(DepositFacet.deposit.selector, address(depositFacet));
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

    function _wirePinnedReferral() internal {
        diamond.setFacet(PinnedReferralFacet.setReferrerPinned.selector, address(pinnedFacet));
        diamond.setFacet(PinnedReferralFacet.getReferrerPinned.selector, address(pinnedFacet));
    }

    function _wireInheritanceReferral() internal {
        diamond.setFacet(ReferralFacet.setReferrer.selector, address(referralFacet));
        diamond.setFacet(ReferralFacet.getReferrer.selector, address(referralFacet));
    }

    function _depositThrice() internal {
        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        pet.deposit{value: 1 ether}();
        pet.deposit{value: 1 ether}();
        pet.deposit{value: 1 ether}();
        vm.stopPrank();
    }

    // ----- 1. pinned struct writes exactly slot 6 --------------------------

    function test_pinnedStruct_writesExactSlot6() public {
        _wirePinnedReferral();

        vm.prank(alice);
        pet.setReferrerPinned(bob);

        assertEq(pet.getReferrerPinned(alice), bob, "pinned getter returns bob");

        bytes32 raw = vm.load(address(diamond), _mappingSlot(alice, SLOT_REFERRER));
        assertEq(
            raw,
            bytes32(uint256(uint160(bob))),
            "pinned Layout at slot 6 addresses the diamond's slot 6"
        );
    }

    // ----- 2. the library's mapping derivation matches the compiler --------

    function test_pinnedMapping_derivationMatchesCompiler() public {
        _wirePinnedReferral();

        // Write straight to the slot the LIBRARY computes, then read via the
        // compiler-generated getter. Equality proves the pin math is correct.
        vm.store(
            address(diamond),
            keccak256(abi.encode(alice, LibPetReferral.SLOT)),
            bytes32(uint256(uint160(carol)))
        );

        assertEq(pet.getReferrerPinned(alice), carol, "library slot math == compiler slot math");
    }

    // ----- 3. explicit-pin slot 6 == inheritance slot 6 --------------------

    function test_pinnedEqualsInheritance_sameSlot6() public {
        _wirePinnedReferral();
        _wireInheritanceReferral();

        // write via the PINNED facet, read via the INHERITANCE facet
        vm.prank(alice);
        pet.setReferrerPinned(bob);
        assertEq(pet.getReferrer(alice), bob, "inheritance getter sees pinned write");

        // write via the INHERITANCE facet, read via the PINNED facet
        vm.prank(dan);
        pet.setReferrer(carol);
        assertEq(pet.getReferrerPinned(dan), carol, "pinned getter sees inheritance write");
    }

    // ----- 4. scalar pin lands exactly at slot 7 ---------------------------

    function test_pinnedScalar_gateAtSlot7() public {
        diamond.setFacet(PinnedGateFacet.setActivePinned.selector, address(gateFacet));
        diamond.setFacet(PinnedGateFacet.isActivePinned.selector, address(gateFacet));

        pet.setActivePinned(true);

        assertEq(_loadSlot(SLOT_ACTIVE), 1, "active bool physically at slot 7");
        assertTrue(pet.isActivePinned(), "pinned gate reads back true");
    }

    // ----- 5. the slim facet touches only its pinned slot ------------------

    function test_pinnedFacet_noInheritance_leavesBaseIntact() public {
        _depositThrice();
        _wirePinnedReferral();

        vm.prank(alice);
        pet.setReferrerPinned(bob);

        // base slots 2-5 untouched by the pinned facet
        assertEq(_loadSlot(SLOT_COUNTER), 3, "counter (slot 2) intact");
        assertEq(_loadSlot(SLOT_TOTAL_DEPOSITED), 3 ether, "totalDeposited (slot 3) intact");
        assertEq(_loadMapping(alice, SLOT_DEPOSITS), 3 ether, "deposits[alice] (slot 4) intact");
        // only slot 6 was written
        assertEq(_loadMapping(alice, SLOT_REFERRER), uint256(uint160(bob)), "referrerOf at slot 6");
    }

    // ----- 6. wrong scalar pin clobbers an occupied slot -------------------

    function test_wrongScalarPin_clobbersSlot3() public {
        _depositThrice();
        assertEq(_loadSlot(SLOT_TOTAL_DEPOSITED), 3 ether, "totalDeposited starts at 3 ether");

        diamond.setFacet(BadPinnedFacet.setActiveBad.selector, address(badFacet));

        pet.setActiveBad(true); // pinned to slot 3 == totalDeposited

        assertEq(_loadSlot(SLOT_TOTAL_DEPOSITED), 1, "totalDeposited (slot 3) clobbered to 1");
        assertEq(_loadSlot(SLOT_COUNTER), 3, "counter (slot 2) untouched");
    }

    // ----- 7. wrong mapping pin collides with an occupied mapping ----------

    function test_wrongMappingPin_collidesWithDeposits() public {
        diamond.setFacet(BadPinnedFacet.setReferrerBad.selector, address(badFacet));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        pet.deposit{value: 1 ether}();
        assertEq(pet.depositOf(alice), 1 ether, "deposits[alice] == 1 ether");

        // referrerOf pinned to slot 4 derives keccak256(alice, 4) == the deposits entry
        vm.prank(alice);
        pet.setReferrerBad(bob);

        assertEq(
            pet.depositOf(alice),
            uint256(uint160(bob)),
            "deposits[alice] silently corrupted by the colliding pin"
        );
    }
}
