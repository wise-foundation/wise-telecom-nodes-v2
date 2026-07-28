// SPDX-License-Identifier: MIT
pragma solidity =0.8.36;

// ---------------------------------------------------------------------------
// Pet diamond — a minimal, self-contained mirror of this repo's CUSTOM diamond
// pattern (selectorToFacet + fallback delegatecall, inheritance-sequential
// storage). Its only job is to PROVE that a facet deployed AFTER the diamond can
// use a storage slot appended right after the ones the diamond already uses, and
// that the bytes land in the DIAMOND's storage (facets run via delegatecall in
// the diamond's context). It also proves the failure mode: inserting a variable
// in the middle instead of appending corrupts existing data.
//
// Nothing here is production code — it lives under test/ and touches no legacy
// or diamond src.
// ---------------------------------------------------------------------------

// The shared storage chain. EVERY contract that runs against the diamond's
// storage (the diamond itself and every facet) inherits this, so they all agree
// on slot numbers. Solidity assigns slots by declaration order:
//
//   slot 0: selectorToFacet   slot 1: owner            slot 2: counter
//   slot 3: totalDeposited     slot 4: deposits         slot 5: depositCount
//
// => six used slots (0-5); the next free slot is 6.
abstract contract PetDeclarations {
    mapping(bytes4 => address) internal selectorToFacet; // slot 0
    address internal owner;                              // slot 1
    uint256 internal counter;                            // slot 2
    uint256 internal totalDeposited;                     // slot 3
    mapping(address => uint256) internal deposits;       // slot 4
    uint256 internal depositCount;                       // slot 5
}

// The diamond. Holds the storage; routes unknown selectors to facets via
// delegatecall. `setFacet` is the demo's "cut" (no timelock — this is a proof,
// not production).
contract PetDiamond is PetDeclarations {
    constructor() {
        owner = msg.sender;
    }

    function setFacet(bytes4 _selector, address _facet) external {
        require(msg.sender == owner, "not owner");
        selectorToFacet[_selector] = _facet;
    }

    function facetFor(bytes4 _selector) external view returns (address) {
        return selectorToFacet[_selector];
    }

    fallback() external payable {
        address facet = selectorToFacet[msg.sig];
        require(facet != address(0), "no facet");

        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

// The "already deployed" facet. Uses only the six existing slots (0-5). It is
// compiled with NO knowledge of slot 6, so its bytecode can never touch slot 6.
contract DepositFacet is PetDeclarations {
    function deposit() external payable {
        counter += 1;
        totalDeposited += msg.value;
        deposits[msg.sender] += msg.value;
        depositCount += 1;
    }

    function readCounter() external view returns (uint256) {
        return counter;
    }

    function depositOf(address _who) external view returns (uint256) {
        return deposits[_who];
    }
}

// The appended tail shard — declared AFTER PetDeclarations in the referral
// facet's inheritance list, so `referrerOf` gets the next free slot: 6.
abstract contract PetReferralDecl {
    mapping(address => address) internal referrerOf; // slot 6 (appended at tail)
}

// The facet added AFTER the diamond is deployed. Inheritance order
// (PetDeclarations first, PetReferralDecl second) keeps slots 0-5 identical and
// places `referrerOf` at slot 6 — the correct, safe append.
contract ReferralFacet is PetDeclarations, PetReferralDecl {
    function setReferrer(address _ref) external {
        require(referrerOf[msg.sender] == address(0), "already set");
        referrerOf[msg.sender] = _ref;
    }

    function getReferrer(address _who) external view returns (address) {
        return referrerOf[_who];
    }

    // Proves this later-added facet still agrees on the existing slots: it reads
    // `counter` (slot 2) written by DepositFacet, while also owning slot 6.
    function readCounterViaReferralFacet() external view returns (uint256) {
        return counter;
    }
}

// The WRONG way — the shard is inherited FIRST, so `referrerOf` grabs slot 0 and
// every real field shifts up by one (counter -> slot 3, overlapping the real
// totalDeposited). This facet is the cautionary mirror: it demonstrates the
// corruption that append-at-tail avoids.
abstract contract PetReferralDeclBad {
    mapping(address => address) internal referrerOf; // slot 0 here (WRONG)
}

contract BadReferralFacet is PetReferralDeclBad, PetDeclarations {
    // In THIS contract's layout `counter` resolves to slot 3, but the diamond's
    // real counter lives at slot 2. So this reads the wrong slot.
    function readCounterViaBadFacet() external view returns (uint256) {
        return counter;
    }

    // Writes "counter" — but at slot 3, corrupting the real totalDeposited.
    function bumpCounterBad() external {
        counter += 100;
    }
}
