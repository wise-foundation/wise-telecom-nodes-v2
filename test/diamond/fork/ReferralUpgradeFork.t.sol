// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test} from "forge-std/Test.sol";

import {ReferralFacet} from "../../../src/diamond/vault/facets/pending/ReferralFacet.sol";
import {Permit2ReferralFacet} from "../../../src/diamond/vault/facets/pending/Permit2ReferralFacet.sol";
import {FacetNotFound, SelectorTimelockNotElapsed} from "../../../src/diamond/shared/DiamondErrors.sol";

import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";

interface IPermit2Domain {

    function DOMAIN_SEPARATOR()
        external
        view
        returns (bytes32);
}

/**
 * @dev Minimal local surface of the LIVE WiseTelecomNodes diamond,
 * driven through its own dispatcher and fallback router exactly as a
 * real integration would. The referral entrypoints are declared here
 * even though the live dispatcher does not know them — after the
 * rehearsed upgrade they resolve through the selector routing, which
 * is precisely what this test proves.
 */
interface IWtnLiveVault {

    function master() external view returns (address);
    function USD_TOKEN() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalDepositCap() external view returns (uint256);
    function depositsDisabled() external view returns (bool);
    function paused() external view returns (bool);
    function gracePeriodDuration() external view returns (uint256);
    function selectorToFacet(bytes4 selector) external view returns (address);

    function proposeSelectors(
        bytes4[] memory selectors,
        address facet
    )
        external;

    function executeSelectorChanges(
        bytes4[] memory selectors
    )
        external;

    function setDepositsDisabled(
        bool disabled
    )
        external;

    function unpauseDeposits()
        external;

    function setTotalDepositCap(
        uint256 newCap
    )
        external;

    function transfer(
        address to,
        uint256 amount
    )
        external
        returns (bool);

    function referrerOf(
        address user
    )
        external
        view
        returns (address);

    function depositWithReferral(
        uint256 amount,
        address referrer
    )
        external;

    function depositWithPermit2WithReferral(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        address referrer
    )
        external;
}

interface IUsdToken {

    function decimals()
        external
        view
        returns (uint8);
}

/**
 * @title ReferralUpgradeForkBase
 * @dev Rehearses the {UpgradeReferral} rollout against a LIVE,
 * already-finalized diamond on a fork of each production chain —
 * this is the required basis before any facet addition ships: fork
 * first, then simulate with cheatcodes on the real deployed
 * bytecode. Proves, per chain:
 *   1. the live dispatcher does NOT know the referral selectors
 *      (raw calls revert {FacetNotFound}), so the routed `referrerOf`
 *      getter is load-bearing, not decorative;
 *   2. the exact propose / 3-day-timelock / execute sequence the
 *      upgrade script broadcasts works under the real master
 *      (impersonated) against the real selector routing;
 *   3. the deposit-time referral rule holds against the real USD
 *      token: the first referrer sets and sticks — write-once, no
 *      later deposit of any size displaces it — including through
 *      a REAL Permit2 signature the canonical deployment recovers;
 *   4. transfers never touch the registry, under whatever transfer
 *      hook the live chain actually has installed.
 *
 * The diamond address is read from config/vault.<product>.<network>
 * .json — the same deployment record the ops scripts use — so the
 * test can never drift to a hallucinated address. Master-only
 * cheatcode preps (open a dormant deposit gate, unpause, raise the
 * cap) mirror what governance would do before the feature is usable
 * on that chain.
 */
abstract contract ReferralUpgradeForkBase is Test {

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256(
        "TokenPermissions(address token,uint256 amount)"
    );

    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant USER_PK = 0xA11CE;

    struct Cfg {
        string rpc;
        string product;
        string network;
    }

    IWtnLiveVault internal v;
    address internal usd;
    address internal master;
    uint256 internal one;
    address internal user;
    address internal user2;
    address internal refA;
    address internal refB;

    function _config()
        internal
        pure
        virtual
        returns (Cfg memory);

    function setUp()
        public
    {
        Cfg memory cfg = _config();

        string memory json = vm.readFile(
            string.concat(
                "config/vault.",
                cfg.product,
                ".",
                cfg.network,
                ".json"
            )
        );

        address diamond = vm.parseJsonAddress(
            json,
            ".diamond"
        );

        vm.createSelectFork(
            cfg.rpc
        );

        require(
            diamond.code.length > 0,
            "diamond not deployed on this fork"
        );

        v = IWtnLiveVault(
            diamond
        );

        usd = v.USD_TOKEN();

        master = v.master();

        one = 10 ** IUsdToken(usd).decimals();

        user = vm.addr(
            USER_PK
        );

        user2 = makeAddr(
            "referralForkRecipient"
        );

        refA = makeAddr(
            "referralForkRefA"
        );

        refB = makeAddr(
            "referralForkRefB"
        );
    }

    /**
     * @dev Approve `_spender` to pull USD from `_from`. USDT's
     * `approve` returns no data, so a bool-returning interface call
     * would revert on the decode; a low-level call that ignores the
     * return works for every underlying in the mesh.
     */
    function _approveUsd(
        address _from,
        address _spender
    )
        internal
    {
        vm.prank(
            _from
        );

        (
            bool ok,
        ) = usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                _spender,
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );
    }

    function _signPermit2(
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(
                TOKEN_PERMISSIONS_TYPEHASH,
                usd,
                _amount
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                tokenPermissionsHash,
                address(v),
                _nonce,
                _deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IPermit2Domain(CANONICAL_PERMIT2).DOMAIN_SEPARATOR(),
                structHash
            )
        );

        (
            uint8 sigV,
            bytes32 sigR,
            bytes32 sigS
        ) = vm.sign(
            USER_PK,
            digest
        );

        return abi.encodePacked(
            sigR,
            sigS,
            sigV
        );
    }

    function _assertSelectorUnknown(
        bytes memory _calldata
    )
        internal
    {
        (
            bool ok,
            bytes memory ret
        ) = address(v).call(
            _calldata
        );

        assertFalse(
            ok,
            "selector already live before the upgrade"
        );

        assertEq(
            bytes4(ret),
            FacetNotFound.selector,
            "expected FacetNotFound from the live fallback"
        );
    }

    function test_referralUpgrade_rehearsalEndToEnd()
        public
    {
        // ---- 1. the live dispatcher does not know the referral surface ----

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "referrerOf(address)",
                user
            )
        );

        _assertSelectorUnknown(
            abi.encodeWithSignature(
                "depositWithReferral(uint256,address)",
                one,
                refA
            )
        );

        // ---- 2. the exact UpgradeReferral sequence under the real master ----

        address referralFacet = address(
            new ReferralFacet()
        );

        address permit2ReferralFacet = address(
            new Permit2ReferralFacet()
        );

        vm.prank(
            master
        );

        v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.referralSelectors(),
            referralFacet
        );

        vm.prank(
            master
        );

        v.proposeSelectors(
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors(),
            permit2ReferralFacet
        );

        vm.prank(
            master
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        vm.warp(
            block.timestamp + SELECTOR_DELAY + 1
        );

        vm.prank(
            master
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.referralSelectors()
        );

        vm.prank(
            master
        );

        v.executeSelectorChanges(
            WiseTelecomNodesDiamondSelectors.permit2ReferralSelectors()
        );

        assertEq(
            v.selectorToFacet(
                bytes4(
                    keccak256("referrerOf(address)")
                )
            ),
            referralFacet,
            "referrerOf getter not routed"
        );

        assertEq(
            v.referrerOf(user),
            address(0),
            "routed getter must read virgin slot 64 as zero"
        );

        // ---- 3. master preps the chain for deposits (cheatcode governance) ----

        if (v.paused()) {

            vm.prank(
                master
            );

            v.unpauseDeposits();
        }

        if (v.depositsDisabled()) {

            vm.prank(
                master
            );

            v.setDepositsDisabled(
                false
            );
        }

        uint256 baseAmount = 1_000 * one;

        uint256 liftedCap = v.totalSupply() + 20 * baseAmount;

        vm.prank(
            master
        );

        v.setTotalDepositCap(
            liftedCap
        );

        // ---- 4. deposit-time referral rule against the real USD token ----

        deal(
            usd,
            user,
            12 * baseAmount
        );

        _approveUsd(
            user,
            address(v)
        );

        _approveUsd(
            user,
            CANONICAL_PERMIT2
        );

        uint256 supplyBefore = v.totalSupply();

        vm.prank(
            user
        );

        v.depositWithReferral(
            baseAmount,
            refA
        );

        assertEq(
            v.referrerOf(user),
            refA,
            "first referrer not set"
        );

        vm.prank(
            user
        );

        v.depositWithReferral(
            2 * baseAmount,
            refB
        );

        assertEq(
            v.referrerOf(user),
            refA,
            "bigger-than-balance deposit must not displace the referrer"
        );

        vm.prank(
            user
        );

        v.depositWithReferral(
            baseAmount,
            refA
        );

        assertEq(
            v.referrerOf(user),
            refA,
            "smaller-than-balance deposit must not displace the referrer"
        );

        // ---- 5. write-once holds through a REAL Permit2 signature ----

        uint256 permitNonce = uint256(
            keccak256("wtn.referral.fork.nonce")
        );

        uint256 permitDeadline = block.timestamp + 1 hours;

        bytes memory sig = _signPermit2(
            8 * baseAmount,
            permitNonce,
            permitDeadline
        );

        vm.prank(
            user
        );

        v.depositWithPermit2WithReferral(
            8 * baseAmount,
            permitNonce,
            permitDeadline,
            sig,
            refB
        );

        assertEq(
            v.referrerOf(user),
            refA,
            "permit2 deposit above balance must not displace the referrer"
        );

        assertEq(
            v.balanceOf(user),
            12 * baseAmount,
            "shares not minted 1:1 across all referral deposits"
        );

        assertEq(
            v.totalSupply(),
            supplyBefore + 12 * baseAmount,
            "total supply drifted from the deposits"
        );

        // ---- 6. transfers never touch the registry ----

        vm.warp(
            block.timestamp + v.gracePeriodDuration() + 1
        );

        vm.prank(
            user
        );

        v.transfer(
            user2,
            baseAmount
        );

        assertEq(
            v.balanceOf(user2),
            baseAmount,
            "transfer did not move shares"
        );

        assertEq(
            v.referrerOf(user2),
            address(0),
            "transfer must never assign a referrer"
        );

        assertEq(
            v.referrerOf(user),
            refA,
            "transfer must never change the sender referrer"
        );
    }
}

contract ReferralUpgradeUsdcMainnetFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            product: "usdc",
            network: "mainnet"
        });
    }
}

contract ReferralUpgradeUsdcBaseFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "base",
            product: "usdc",
            network: "base"
        });
    }
}

contract ReferralUpgradeUsdcArbitrumFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            product: "usdc",
            network: "arbitrum"
        });
    }
}

contract ReferralUpgradeUsdtMainnetFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            product: "usdt",
            network: "mainnet"
        });
    }
}

contract ReferralUpgradeUsdtBaseFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "base",
            product: "usdt",
            network: "base"
        });
    }
}

contract ReferralUpgradeUsdtArbitrumFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            product: "usdt",
            network: "arbitrum"
        });
    }
}

contract ReferralUpgradeUsdgMainnetFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "mainnet",
            product: "usdg",
            network: "mainnet"
        });
    }
}

contract ReferralUpgradeUsdgArbitrumFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "arbitrum",
            product: "usdg",
            network: "arbitrum"
        });
    }
}

contract ReferralUpgradeUsdgRobinhoodFork is ReferralUpgradeForkBase {

    function _config()
        internal
        pure
        override
        returns (Cfg memory)
    {
        return Cfg({
            rpc: "robinhood",
            product: "usdg",
            network: "robinhood"
        });
    }
}
