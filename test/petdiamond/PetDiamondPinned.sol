// SPDX-License-Identifier: MIT
pragma solidity =0.8.36;

// ---------------------------------------------------------------------------
// Slot-pinned variant of the pet diamond proof — the pattern used in
// C:\code\Github\World-Mobile-Airnode-NFTs (the "...-Sparknode" repo).
//
// Instead of inheriting the base declarations to get a matching slot, a slim
// facet PINS its storage to an explicit slot number and reaches it directly,
// inheriting nothing. The new facet only needs to know the ONE free slot it
// claims — it is fully decoupled from slots 0-5. This proves the same
// "add storage after deployment" property from the other direction, and shows
// the cautionary case: with explicit pins, choosing an occupied slot silently
// corrupts existing data.
//
// Reuses the diamond + DepositFacet + inheritance-based ReferralFacet from the
// Part 1 demo so we can prove that an explicitly-pinned slot 6 and an
// inheritance-derived slot 6 are literally the same storage.
// ---------------------------------------------------------------------------

import {PetDiamond, DepositFacet, ReferralFacet} from "./PetDiamondDemo.sol";

// Struct-pin (their LibSalesTax / LibTransferLock pattern): a whole Layout
// struct anchored at an explicit integer slot.
library LibPetReferral {
    bytes32 internal constant SLOT = bytes32(uint256(6)); // next free slot after PetDeclarations (0-5)

    struct Layout {
        mapping(address => address) referrerOf;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}

// Scalar-pin (their LibAuth pattern): a single value pinned to a slot, reached
// with raw sload / sstore.
library LibPetGate {
    bytes32 internal constant SLOT_ACTIVE = bytes32(uint256(7));

    function active() internal view returns (bool v) {
        bytes32 s = SLOT_ACTIVE;
        assembly {
            v := sload(s)
        }
    }

    function setActive(bool v) internal {
        bytes32 s = SLOT_ACTIVE;
        assembly {
            sstore(s, v)
        }
    }
}

// The slim facet: inherits NOTHING. It reaches the diamond's slot 6 purely
// through the pinned library, in the diamond's storage context under
// delegatecall.
contract PinnedReferralFacet {
    function setReferrerPinned(address _ref) external {
        require(LibPetReferral.layout().referrerOf[msg.sender] == address(0), "already set");
        LibPetReferral.layout().referrerOf[msg.sender] = _ref;
    }

    function getReferrerPinned(address _who) external view returns (address) {
        return LibPetReferral.layout().referrerOf[_who];
    }
}

contract PinnedGateFacet {
    function setActivePinned(bool _v) external {
        LibPetGate.setActive(_v);
    }

    function isActivePinned() external view returns (bool) {
        return LibPetGate.active();
    }
}

// ---- the cautionary mirror: wrong pins hit occupied slots ----

// Scalar pinned to slot 3, which the base already uses for `totalDeposited`.
library LibBadGate {
    bytes32 internal constant SLOT = bytes32(uint256(3));

    function setActive(bool v) internal {
        bytes32 s = SLOT;
        assembly {
            sstore(s, v)
        }
    }
}

// Mapping pinned to slot 4, which the base already uses for `deposits`. Both
// mappings derive entries at keccak256(key, 4), so they collide.
library LibBadReferralPin {
    bytes32 internal constant SLOT = bytes32(uint256(4));

    struct Layout {
        mapping(address => address) referrerOf;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}

contract BadPinnedFacet {
    function setActiveBad(bool _v) external {
        LibBadGate.setActive(_v); // clobbers totalDeposited (slot 3)
    }

    function setReferrerBad(address _ref) external {
        LibBadReferralPin.layout().referrerOf[msg.sender] = _ref; // collides with deposits[msg.sender]
    }
}
