// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ReferralRegistry} from "../../src/registry/pending/ReferralRegistry.sol";
import {ReferralRegistryDeclarations} from "../../src/registry/pending/ReferralRegistryDeclarations.sol";

/**
 * @dev Tracked vault stand-in that holds a cohort book: answers the
 * registry's cohort-score probe with a nonzero book, so pending-flip
 * markers are written for it.
 */
contract MockBookVault {

    function getAttributedContribution(
        address
    )
        external
        pure
        returns (uint256)
    {
        return 1;
    }
}

/**
 * @dev Tracked vault stand-in that holds no cohort book: answers the
 * registry's cohort-score probe with zero, so no pending-flip marker
 * is ever written for it.
 */
contract MockBooklessVault {

    function getAttributedContribution(
        address
    )
        external
        pure
        returns (uint256)
    {
        return 0;
    }
}

/**
 * @dev Assignment-semantics suite for {ReferralRegistry}. Covers
 * the rules enforced registry-side: zero user/referrer
 * revert, self-referral revert, the InvalidReferrer hardening set
 * (calling vault, the registry itself, the recorded payout hub, any
 * other allowlisted vault,
 * a revoked vault, which stays a vault forever and so can never
 * become a referrer, and a referrer whose own referrer is the user,
 * the mutual pair, refused only for a user not yet assigned; the
 * same identity set also guards the mutual dissolve arm of the
 * merge lane, so a two-cycle delivery cannot adopt a system address
 * as a user referrer),
 * write-once with the loser
 * silently ignored (across repeat calls, different referrers,
 * different vaults, same-block races, and an already-assigned user
 * whose late code names a refused referrer: the write-once return
 * runs before every identity refusal, so the deposit path never
 * reverts on the assignment it already carries), the {ReferralAssigned}
 * event only on the actual first-set transition, and the
 * zero and self referrers still reverting even for an
 * already-assigned user. Includes the two-allowed-vaults same-block
 * race pin: first write wins and exactly one event is ever emitted
 * per user.
 */
contract ReferralRegistryAssignTest is Test {
    event ReferralAssigned(
        address indexed user,
        address indexed referrer,
        address indexed vault
    );

    event ReferralMutualDissolved(
        address indexed user,
        address indexed oldReferrer,
        uint256 winnerKey
    );

    uint256 internal constant BASE_TIME = 3_000 weeks + 1 hours;

    address internal user1 = address(0xA1);

    address internal refA = address(0xB1);

    address internal refB = address(0xB2);

    address internal refC = address(0xB3);

    address internal stranger = address(0xC1);

    MockBookVault internal bookVaultA;

    MockBooklessVault internal booklessB;

    address internal vaultA;

    address internal vaultB;

    address internal hubAddress = address(0xE1);

    uint64 internal constant SEL_HUB = 50_001;

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

        bookVaultA = new MockBookVault();

        booklessB = new MockBooklessVault();

        vaultA = address(
            bookVaultA
        );

        vaultB = address(
            booklessB
        );

        registry.setAllowedVault(
            vaultA,
            true
        );

        registry.setAllowedVault(
            vaultB,
            true
        );
    }

    // ---- helpers ----

    function _assignedEventCount()
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "ReferralAssigned(address,address,address)"
        );

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    // ---- defaults ----

    function test_referrerOf_defaultZero()
        public
    {
        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );
    }

    // ---- first assignment ----

    function test_assignReferrer_firstAssign_setsAndEmits()
        public
    {
        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralAssigned(
            user1,
            refA,
            vaultA
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    // ---- write-once ----

    function test_assignReferrer_secondDifferentReferrer_keepsFirstNoEvent()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.recordLogs();

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refB
        );

        assertEq(
            _assignedEventCount(),
            0
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    function test_assignReferrer_sameReferrerAgain_noEvent()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.recordLogs();

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        assertEq(
            _assignedEventCount(),
            0
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    function test_assignReferrer_secondVault_sameUser_keepsFirst()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultB
        );

        registry.assignReferrer(
            user1,
            refB
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    function test_RevertWhen_assignReferrer_mutualPair()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            refA,
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.referrerOf(
                refA
            ),
            address(0)
        );

        assertEq(
            registry.referrerKey(
                refA
            ),
            0
        );
    }

    // ---- validation ----

    function test_RevertWhen_assignReferrer_zeroUser()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.assignReferrer(
            address(0),
            refA
        );
    }

    function test_RevertWhen_assignReferrer_zeroReferrer()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.assignReferrer(
            user1,
            address(0)
        );
    }

    function test_RevertWhen_assignReferrer_selfReferral()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SelfReferral.selector
        );

        registry.assignReferrer(
            user1,
            user1
        );
    }

    function test_RevertWhen_assignReferrer_referrerIsCallingVault()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            user1,
            vaultA
        );
    }

    function test_RevertWhen_assignReferrer_referrerIsRegistry()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            user1,
            address(registry)
        );
    }

    function test_RevertWhen_assignReferrer_referrerIsAllowedVault()
        public
    {
        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            user1,
            vaultB
        );
    }

    function test_RevertWhen_assignReferrer_referrerIsRevokedVault()
        public
    {
        registry.setAllowedVault(
            vaultB,
            false
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            user1,
            vaultB
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );
    }

    function test_assignReferrer_zeroReferrerRevertsEvenWhenAssigned()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ZeroAddress.selector
        );

        registry.assignReferrer(
            user1,
            address(0)
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.SelfReferral.selector
        );

        registry.assignReferrer(
            user1,
            user1
        );
    }

    function test_assignReferrer_mutualPair_assignedUserReturnsSilently()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            refA,
            refB
        );

        vm.recordLogs();

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            refA,
            user1
        );

        assertEq(
            vm.getRecordedLogs().length,
            0
        );

        assertEq(
            registry.referrerOf(
                refA
            ),
            refB
        );
    }

    function test_RevertWhen_assignReferrer_payoutHubAsReferrer()
        public
    {
        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        registry.executePayoutHubChange();

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            user1,
            hubAddress
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );
    }

    function test_assignReferrer_ordinaryReferrerPassesWithPayoutHubSet()
        public
    {
        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        registry.executePayoutHubChange();

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    /**
     * @dev the earlier-minted direction wins the whole mesh: the
     * local losing edge dissolves (markers route the book out)
     * and the incoming pair adopts
     */
    function test_mergeReferrer_mutualPair_smallerKeyDissolvesAndAdopts()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.expectEmit(
            true,
            true,
            true,
            true,
            address(registry)
        );

        emit ReferralMutualDissolved(
            user1,
            refA,
            (BASE_TIME - 1 days) << 8 | 1
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            refA,
            user1,
            BASE_TIME - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            0
        );

        assertEq(
            registry.referrerOf(
                refA
            ),
            user1
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            refA
        );
    }

    /**
     * @dev the incoming direction minted later: the delivery is
     * processed and ignored, and the local pair stands
     */
    function test_mergeReferrer_mutualPair_largerKeyIgnored()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        uint256 keyBefore = registry.referrerKey(
            user1
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            refA,
            user1,
            block.timestamp + 30 minutes,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            keyBefore
        );

        assertEq(
            registry.referrerOf(
                refA
            ),
            address(0)
        );

        assertEq(
            registry.referrerKey(
                refA
            ),
            0
        );
    }

    /**
     * @dev the laundering shape: an allowed vault first delivers the
     * system address as a REFEREE (unguarded, the referrer is the
     * user), then rides the mutual dissolve arm to adopt the
     * system address as the user referrer
     */
    function test_RevertWhen_mergeReferrer_mutualArmRefusesSystemReferrer()
        public
    {
        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            vaultA,
            user1,
            BASE_TIME - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                vaultA
            ),
            user1
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.mergeReferrer(
            user1,
            vaultA,
            BASE_TIME - 2 days,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );

        vm.prank(
            vaultB
        );

        registry.mergeReferrer(
            address(registry),
            user1,
            BASE_TIME - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                address(registry)
            ),
            user1
        );

        vm.prank(
            vaultB
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.mergeReferrer(
            user1,
            address(registry),
            BASE_TIME - 2 days,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );
    }

    /**
     * @dev the losing local edge dissolves and the winning direction
     * also flips the incoming user own older referrer away
     */
    function test_mergeReferrer_mutualPairOverAssignedLoser_dissolvesBoth()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            refA,
            refB
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            refA,
            user1,
            BASE_TIME - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            0
        );

        assertEq(
            registry.referrerOf(
                refA
            ),
            user1
        );

        assertEq(
            registry.pendingFlip(
                vaultA,
                refA
            ),
            refB
        );
        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            refA
        );
    }

    /**
     * @dev the incoming direction beats the reverse edge but not the
     * user own older key: the delivery is refused for the user,
     * and a refused sync never dissolves, so the reverse edge
     * stands with its key, no marker moves and no book leaves
     */
    function test_mergeReferrer_mutualPair_refusedSyncKeepsReverseEdge()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refB
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            refA,
            user1,
            BASE_TIME + 1 hours,
            1
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            user1,
            refA,
            BASE_TIME + 30 minutes,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refB
        );

        assertEq(
            registry.referrerKey(
                user1
            ),
            BASE_TIME << 8
        );

        assertEq(
            registry.referrerOf(
                refA
            ),
            user1
        );

        assertEq(
            registry.referrerKey(
                refA
            ),
            (BASE_TIME + 1 hours) << 8 | 1
        );
        assertEq(
            registry.pendingFlip(
                vaultA,
                refA
            ),
            address(0)
        );
        assertEq(
            registry.pendingFlip(
                vaultA,
                user1
            ),
            address(0)
        );
    }

    /**
     * @dev a deep but acyclic chain assigns fine: the walk runs to
     * the root under the gas the caller supplies
     */
    function test_assignReferrer_deepChain_refusesRingAtAnyDepth()
        public
    {
        address u2 = address(0xA41);
        address u3 = address(0xA42);
        address u4 = address(0xA43);
        address u5 = address(0xA44);
        address u6 = address(0xA45);
        address u7 = address(0xA46);
        address u8 = address(0xA47);
        address u9 = address(0xA48);

        address[9] memory users = [
            user1,
            u2,
            u3,
            u4,
            u5,
            u6,
            u7,
            u8,
            u9
        ];

        for (uint256 i; i < users.length - 1; ++i) {

            vm.prank(
                vaultA
            );

            registry.assignReferrer(
                users[i],
                users[i + 1]
            );
        }

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            u9,
            user1
        );

        address outsider = address(0xA60);

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            outsider,
            u9
        );

        assertEq(
            registry.referrerOf(
                outsider
            ),
            u9
        );
    }

    /**
     * @dev with gas for the whole depth the same assignment walks to
     * the root and succeeds
     */
    function test_RevertWhen_assignReferrer_starvedWalk_revertsGasCap()
        public
    {
        address chainTail = user1;

        for (uint256 i; i < 300; ++i) {

            address next = address(uint160(0xA900 + i));

            vm.prank(
                vaultA
            );

            registry.assignReferrer(
                chainTail,
                next
            );

            chainTail = next;
        }

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.ReferralWalkGasCap.selector
        );

        registry.assignReferrer{gas: 50_000}(
            address(0xA80),
            user1
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            address(0xA80),
            user1
        );

        assertEq(
            registry.referrerOf(
                address(0xA80)
            ),
            user1
        );
    }

    function test_RevertWhen_mergeReferrer_payoutHubAsReferrer()
        public
    {
        registry.proposePayoutHub(
            hubAddress,
            SEL_HUB
        );

        registry.executePayoutHubChange();

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.mergeReferrer(
            user1,
            hubAddress,
            BASE_TIME - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            address(0)
        );
    }

    function test_RevertWhen_assignReferrer_threeAddressCycle()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            refA,
            refB
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            refB,
            user1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );

        assertEq(
            registry.referrerOf(
                refA
            ),
            refB
        );

        assertEq(
            registry.referrerOf(
                refB
            ),
            address(0)
        );
    }

    function test_RevertWhen_assignReferrer_fiveAddressCycle()
        public
    {
        address u2 = address(0xA21);
        address u3 = address(0xA22);
        address u4 = address(0xA23);
        address u5 = address(0xA24);

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            u2
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            u2,
            u3
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            u3,
            u4
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            u4,
            u5
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            u5,
            user1
        );

        assertEq(
            registry.referrerOf(
                u5
            ),
            address(0)
        );
    }

    function test_RevertWhen_mergeReferrer_ringThroughSyncLane()
        public
    {
        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            refB,
            refA
        );

        vm.prank(
            vaultA
        );

        registry.mergeReferrer(
            refA,
            refC,
            BASE_TIME - 1 days,
            1
        );

        assertEq(
            registry.referrerOf(
                refA
            ),
            refC
        );

        assertEq(
            registry.referrerOf(
                refB
            ),
            refA
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.mergeReferrer(
            refC,
            refB,
            BASE_TIME - 2 days,
            1
        );

        assertEq(
            registry.referrerOf(
                refC
            ),
            address(0)
        );
    }

    /**
     * @dev the walk runs to the root now, so the ring closes in no
     * lane and the sixth assignment stays refused
     */
    function test_RevertWhen_assignReferrer_cycleBeyondDepth_refused()
        public
    {
        address u2 = address(0xA31);
        address u3 = address(0xA32);
        address u4 = address(0xA33);
        address u5 = address(0xA34);
        address u6 = address(0xA35);

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            u2
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            u2,
            u3
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            u3,
            u4
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            u4,
            u5
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            u5,
            u6
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.InvalidReferrer.selector
        );

        registry.assignReferrer(
            u6,
            user1
        );

        assertEq(
            registry.referrerOf(
                u6
            ),
            address(0)
        );
    }

    // ---- allowlist gating ----

    function test_RevertWhen_assignReferrer_callerNotAllowlisted()
        public
    {
        vm.prank(
            stranger
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        registry.assignReferrer(
            user1,
            refA
        );
    }

    function test_RevertWhen_assignReferrer_revokedVault()
        public
    {
        registry.setAllowedVault(
            vaultA,
            false
        );

        vm.prank(
            vaultA
        );

        vm.expectRevert(
            ReferralRegistryDeclarations.NotAllowedVault.selector
        );

        registry.assignReferrer(
            user1,
            refA
        );
    }

    // ---- fuzz ----

    function testFuzz_assignReferrer_writeOnceRule(
        address _secondReferrer,
        bool _useVaultB
    )
        public
    {
        _secondReferrer = address(
            uint160(
                bound(
                    uint256(uint160(_secondReferrer)),
                    1,
                    type(uint160).max
                )
            )
        );

        vm.assume(
            _secondReferrer != user1
        );

        vm.assume(
            _secondReferrer != vaultA
        );

        vm.assume(
            _secondReferrer != vaultB
        );

        vm.assume(
            _secondReferrer != address(registry)
        );

        vm.prank(
            vaultA
        );

        registry.assignReferrer(
            user1,
            refA
        );

        vm.prank(
            _useVaultB
                ? vaultB
                : vaultA
        );

        registry.assignReferrer(
            user1,
            _secondReferrer
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            refA
        );
    }

    function testFuzz_assignReferrer_twoVaultsSameBlock_firstWins(
        bool _vaultAFirst
    )
        public
    {
        address firstVault = _vaultAFirst
            ? vaultA
            : vaultB;

        address secondVault = _vaultAFirst
            ? vaultB
            : vaultA;

        address firstReferrer = _vaultAFirst
            ? refA
            : refB;

        address secondReferrer = _vaultAFirst
            ? refB
            : refA;

        vm.recordLogs();

        vm.prank(
            firstVault
        );

        registry.assignReferrer(
            user1,
            firstReferrer
        );

        vm.prank(
            secondVault
        );

        registry.assignReferrer(
            user1,
            secondReferrer
        );

        assertEq(
            _assignedEventCount(),
            1
        );

        assertEq(
            registry.referrerOf(
                user1
            ),
            firstReferrer
        );
    }
}
