// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {Test, Vm} from "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {ICcipBridgeVault, IUsdDecimals} from "./utils/CcipForkInterfaces.sol";

import {IReferralHub} from "../../../src/hub/IReferralHub.sol";
import {ReferralHubReader} from "../../../src/hub/ReferralHubReader.sol";
import {CohortFlushCodec} from "../../../src/diamond/shared/CohortFlushCodec.sol";
import {CohortWeeks} from "../../../src/diamond/shared/CohortWeeks.sol";
import {CohortFlushFacet} from "../../../src/diamond/vault/facets/CohortFlushFacet.sol";
import {WiseTelecomNodesDiamondErrors} from "../../../src/diamond/vault/WiseTelecomNodesDiamondErrors.sol";
import {SelectorTimelockNotElapsed} from "../../../src/diamond/shared/DiamondErrors.sol";

import {UpgradeCohortFlushCourier} from "../../../script/diamond/UpgradeCohortFlushCourier.s.sol";
import {UpgradeReferralHubPayout} from "../../../script/hub/UpgradeReferralHubPayout.s.sol";
import {WiseTelecomNodesDiamondSelectors} from "../../../script/diamond/WiseTelecomNodesDiamondSelectors.sol";
import {ReferralHubSelectors} from "../../../script/hub/ReferralHubSelectors.sol";

/**
 * @dev Minimal local surface of the LIVE WiseTelecomNodes diamond used by
 * the courier open rehearsal, driven through the diamond's own dispatcher.
 */
interface IWtnCourierVault {

    function master()
        external
        view
        returns (address);

    function proposeOwner(
        address proposedOwner
    )
        external;

    function claimOwnership()
        external;

    function selectorToFacet(
        bytes4 selector
    )
        external
        view
        returns (address);

    function selectorChangeQueuedAt(
        bytes4 selector
    )
        external
        view
        returns (uint256);

    function executeSelectorChanges(
        bytes4[] memory selectors
    )
        external;

    function depositWithReferral(
        uint256 amount,
        address referrer
    )
        external;

    function advanceBook(
        address referrer,
        uint256 maxBoundaries
    )
        external;

    function getAllowedFlushBot(
        address bot
    )
        external
        view
        returns (bool);

    function setAllowedFlushBot(
        address bot,
        bool allowed
    )
        external;

    function getFlushedThroughWeek(
        address referrer
    )
        external
        view
        returns (uint256);

    function getFlushHub()
        external
        view
        returns (
            address,
            uint64
        );

    function flushReferrals(
        address[] calldata referrers
    )
        external
        payable;

    function quoteFlushFee(
        address[] calldata referrers
    )
        external
        view
        returns (uint256);

    function previewFlushEnvelope(
        address[] calldata referrers
    )
        external
        view
        returns (bytes memory);
}

interface IUsdErc20 {

    function balanceOf(
        address account
    )
        external
        view
        returns (uint256);
}

/**
 * @dev Rehearses the courier flush facet upgrade on a fork of every live
 * vault by driving the broadcast script itself: on the fork the live
 * master hands the master role to the test key (`proposeOwner` and
 * `claimOwnership`, the diamond's own two step handover), the key goes
 * into PRIVATE_KEY, and `UpgradeCohortFlushCourier.propose()` deploys the
 * new {CohortFlushFacet} and proposes the cohortFlush selector batch, a
 * premature execute reverts on the real 3-day timelock, `execute()` flips
 * the four selectors after it and post asserts the routing, and `abort()`
 * cancels a pending proposal while the live facet stays. Around the flip
 * the scenario pins the rule the build changes against the live state:
 * before it the live facet refuses a courier batch over a never flushed
 * book with its retired error; after it the allowed courier's batch opens
 * that book at the week before the current one, emitting the cursor event
 * exactly as the referrer's own batch would, a stranger stays refused, and
 * the courier's next batch a week later plans only the week closed since
 * the open and writes nothing. On the hub chain vaults the local delivery
 * reaches the LIVE hub, whose bucket for the referrer fills. A paused vault
 * is unpaused on the fork and the courier waits out the outage grace the
 * reopen starts, as it will on the chain. A live CCIP fee quoter may refuse
 * a clock warped weeks ahead, so a spoke flush probes the quoter first and
 * falls back to a mocked router fee and send; the cursor writes under test
 * do not depend on the message. Run one lane per invocation: the script
 * reads VAULT_PRODUCT and PRIVATE_KEY from the process environment.
 */
abstract contract CourierOpenVaultForkBase is Test {

    event CohortReferrerFlushed(
        address indexed referrer,
        uint256 flushedThroughWeek,
        uint256 flushedGapIndex,
        uint256 gapResumeWeek
    );

    struct Cfg {
        string rpc;
        string product;
        string network;
    }

    address internal constant LIVE_COURIER = 0xB5395cBf6B41bc9606aee98A0eBC37145729085a;

    bytes4 internal constant RETIRED_VIRGIN_ERROR = bytes4(
        keccak256(
            "FlushCursorVirgin()"
        )
    );

    uint256 internal constant DEPOSIT_UNITS = 100_000;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    uint256 internal constant MAX_GRACE_WEEKS = 12;

    IWtnCourierVault internal v;

    ICcipBridgeVault internal rails;

    address internal diamond;

    address internal usd;

    address internal liveMaster;

    uint256 internal one;

    address internal operator;

    uint256 internal operatorPk;

    address internal user;

    address internal referrer;

    address internal stranger;

    UpgradeCohortFlushCourier internal script;

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

        diamond = vm.parseJsonAddress(
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

        v = IWtnCourierVault(
            diamond
        );

        rails = ICcipBridgeVault(
            diamond
        );

        usd = rails.USD_TOKEN();

        liveMaster = rails.master();

        one = 10 ** IUsdDecimals(usd).decimals();

        (
            operator,
            operatorPk
        ) = makeAddrAndKey(
            "courierOpenOperator"
        );

        user = makeAddr(
            "courierOpenUser"
        );

        referrer = makeAddr(
            "courierOpenReferrer"
        );

        stranger = makeAddr(
            "courierOpenStranger"
        );

        script = new UpgradeCohortFlushCourier();

        vm.setEnv(
            "VAULT_PRODUCT",
            cfg.product
        );
    }

    function test_courierOpen_scriptUpgradeThenCourierOpensAndCarries()
        public
    {
        address liveFacet = v.selectorToFacet(
            CohortFlushFacet.flushReferrals.selector
        );

        assertTrue(
            liveFacet != address(0),
            "the flush round must be routed on the live vault"
        );

        _handOverMaster();

        _allowCourier();

        _referredDeposit();

        address[] memory refs = _oneRef(
            referrer
        );

        assertEq(
            v.getFlushedThroughWeek(
                referrer
            ),
            0,
            "a fresh book must start with no send cursor"
        );

        _waitOutGraceAndPinLiveRefusal(
            refs
        );

        _upgradeThroughScript(
            liveFacet
        );

        uint256 openWeek = block.timestamp / CohortWeeks.WEEK
            - 1;

        _courierFlush(
            refs,
            openWeek
        );

        assertEq(
            v.getFlushedThroughWeek(
                referrer
            ),
            openWeek,
            "the courier batch must open the book at the week before the current one"
        );

        vm.prank(
            stranger
        );

        vm.expectRevert(
            WiseTelecomNodesDiamondErrors.NotFlushBot.selector
        );

        v.flushReferrals(
            refs
        );

        vm.warp(
            block.timestamp + CohortWeeks.WEEK + 1 days
        );

        v.advanceBook(
            referrer,
            CohortWeeks.MAX_SETTLE_BOUNDARIES
        );

        bytes memory preview = v.previewFlushEnvelope(
            refs
        );

        uint256 entryWord = _envWord(
            preview,
            1
        );

        assertEq(
            CohortFlushCodec._flushEntryCrumbCount(
                entryWord
            ),
            1,
            "the next batch must plan exactly the one week closed since the open"
        );

        assertEq(
            _envWord(
                preview,
                _firstCrumbIndex(
                    entryWord
                )
            ),
            openWeek + 1,
            "the next batch must start right above the stored cursor"
        );

        vm.recordLogs();

        _courierFlush(
            refs,
            0
        );

        assertEq(
            _countReferrerFlushedLogs(),
            0,
            "a courier batch over a stored cursor must write nothing"
        );

        assertEq(
            v.getFlushedThroughWeek(
                referrer
            ),
            openWeek,
            "the stored cursor must stay where the open left it"
        );

        _assertLiveHubFilledOnHubChain();
    }

    function test_courierOpen_abortCancelsTheProposalAndKeepsTheLiveFacet()
        public
    {
        bytes4[] memory sels = WiseTelecomNodesDiamondSelectors._cohortFlushSelectors();

        address liveFacet = v.selectorToFacet(
            sels[0]
        );

        _handOverMaster();

        script.propose();

        assertTrue(
            v.selectorChangeQueuedAt(sels[0]) > 0,
            "propose must queue the cohortFlush batch"
        );

        script.abort();

        for (uint256 i; i < sels.length; ++i) {

            assertEq(
                v.selectorChangeQueuedAt(
                    sels[i]
                ),
                0,
                "abort must cancel every selector of the batch"
            );

            assertEq(
                v.selectorToFacet(
                    sels[i]
                ),
                liveFacet,
                "abort must leave the live facet routed"
            );
        }
    }

    // ---- the script driven upgrade ----

    function _handOverMaster()
        internal
    {
        vm.prank(
            liveMaster
        );

        v.proposeOwner(
            operator
        );

        vm.prank(
            operator
        );

        v.claimOwnership();

        assertEq(
            v.master(),
            operator,
            "the fork handover must make the test key the master"
        );

        vm.setEnv(
            "PRIVATE_KEY",
            vm.toString(
                operatorPk
            )
        );
    }

    function _upgradeThroughScript(
        address _liveFacet
    )
        internal
    {
        bytes4[] memory sels = WiseTelecomNodesDiamondSelectors._cohortFlushSelectors();

        script.status();

        script.propose();

        uint256 proposedAt = block.timestamp;

        assertTrue(
            v.selectorChangeQueuedAt(sels[0]) > 0,
            "propose must queue the cohortFlush batch"
        );

        vm.prank(
            operator
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        v.executeSelectorChanges(
            sels
        );

        vm.warp(
            proposedAt + SELECTOR_DELAY + 1
        );

        script.execute();

        vm.warp(
            proposedAt + 2
        );

        address routed = v.selectorToFacet(
            sels[0]
        );

        assertTrue(
            routed != _liveFacet
                && routed.code.length > 0,
            "execute must route the group to the new facet"
        );

        for (uint256 i; i < sels.length; ++i) {

            assertEq(
                v.selectorToFacet(
                    sels[i]
                ),
                routed,
                "every selector of the group must route to the new facet"
            );

            assertEq(
                v.selectorChangeQueuedAt(
                    sels[i]
                ),
                0,
                "nothing may stay queued after execute"
            );
        }

        script.status();
    }

    // ---- the scenario helpers ----

    function _allowCourier()
        internal
    {
        if (v.getAllowedFlushBot(LIVE_COURIER)) {
            return;
        }

        vm.prank(
            operator
        );

        v.setAllowedFlushBot(
            LIVE_COURIER,
            true
        );
    }

    function _referredDeposit()
        internal
    {
        uint256 amount = DEPOSIT_UNITS * one;

        if (rails.paused()) {

            vm.prank(
                operator
            );

            rails.unpauseDeposits();
        }

        if (rails.depositsDisabled()) {

            vm.prank(
                operator
            );

            rails.setDepositsDisabled(
                false
            );
        }

        vm.prank(
            operator
        );

        rails.setGraceFreezeEnabled(
            false
        );

        uint256 liftedCap = rails.totalSupply()
            + 100 * amount;

        vm.prank(
            operator
        );

        rails.setTotalDepositCap(
            liftedCap
        );

        deal(
            usd,
            user,
            amount
        );

        vm.prank(
            user
        );

        (
            bool ok,
        ) = usd.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                diamond,
                type(uint256).max
            )
        );

        require(
            ok,
            "usd approve failed"
        );

        vm.prank(
            user
        );

        v.depositWithReferral(
            amount,
            referrer
        );
    }

    /// @dev The live facet refuses a courier batch over a never flushed book
    /// with the error the new build retires; a vault unpaused on the fork
    /// first refuses every third party inside the outage grace its reopen
    /// started, so the courier waits week by week until the gate opens, as
    /// it will on the chain.
    function _waitOutGraceAndPinLiveRefusal(
        address[] memory _refs
    )
        internal
    {
        for (uint256 i; i < MAX_GRACE_WEEKS; ++i) {

            vm.prank(
                LIVE_COURIER
            );

            try v.flushReferrals(
                _refs
            ) {
                revert(
                    "the live facet accepted a courier batch over a never flushed book"
                );
            } catch (bytes memory reason) {

                if (keccak256(reason) == keccak256(abi.encodeWithSelector(RETIRED_VIRGIN_ERROR))) {
                    return;
                }

                require(
                    keccak256(reason) == keccak256(
                        abi.encodeWithSelector(
                            WiseTelecomNodesDiamondErrors.FlushOutageGraceActive.selector
                        )
                    ),
                    "the live facet refused the courier probe with an unexpected error"
                );

                vm.warp(
                    block.timestamp + CohortWeeks.WEEK
                );
            }
        }

        revert(
            "the outage grace did not end within the rehearsal horizon"
        );
    }

    function _courierFlush(
        address[] memory _refs,
        uint256 _expectedOpenWeek
    )
        internal
    {
        (
            ,
            uint64 selector
        ) = v.getFlushHub();

        uint256 fee;

        if (selector != 0) {
            fee = _spokeFee(
                _refs
            );
        }

        vm.deal(
            LIVE_COURIER,
            LIVE_COURIER.balance + fee
        );

        if (_expectedOpenWeek != 0) {

            vm.expectEmit(
                true,
                false,
                false,
                true,
                diamond
            );

            emit CohortReferrerFlushed(
                referrer,
                _expectedOpenWeek,
                0,
                0
            );
        }

        vm.prank(
            LIVE_COURIER
        );

        v.flushReferrals{value: fee}(
            _refs
        );

        vm.clearMockedCalls();
    }

    function _spokeFee(
        address[] memory _refs
    )
        internal
        returns (uint256 fee)
    {
        try v.quoteFlushFee(
            _refs
        ) returns (uint256 quoted) {
            return quoted;
        } catch {

            fee = 1 ether;

            address router = rails.ccipRouter();

            vm.mockCall(
                router,
                abi.encodeWithSelector(
                    IRouterClient.getFee.selector
                ),
                abi.encode(
                    fee
                )
            );

            vm.mockCall(
                router,
                abi.encodeWithSelector(
                    IRouterClient.ccipSend.selector
                ),
                abi.encode(
                    bytes32(
                        uint256(1)
                    )
                )
            );
        }
    }

    function _assertLiveHubFilledOnHubChain()
        internal
        view
    {
        (
            address hub,
            uint64 selector
        ) = v.getFlushHub();

        if (selector != 0) {
            return;
        }

        assertGt(
            IReferralHub(hub).claimable(
                block.chainid,
                referrer
            ),
            0,
            "the local courier batches must fill the referrer's bucket on the live hub"
        );
    }

    function _firstCrumbIndex(
        uint256 _entryWord
    )
        internal
        pure
        returns (uint256 index)
    {
        index = 2
            + CohortFlushCodec._flushEntrySelfRunCount(
                _entryWord
            );

        if (CohortFlushCodec._flushEntryFlags(_entryWord) & CohortFlushCodec.FLUSH_FLAG_DESIGNATION != 0) {
            ++index;
        }
    }

    function _envWord(
        bytes memory _data,
        uint256 _index
    )
        internal
        pure
        returns (uint256 w)
    {
        assembly {
            w := mload(
                add(
                    _data,
                    add(
                        0x20,
                        mul(
                            _index,
                            0x20
                        )
                    )
                )
            )
        }
    }

    function _countReferrerFlushedLogs()
        internal
        returns (uint256 count)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "CohortReferrerFlushed(address,uint256,uint256,uint256)"
        );

        for (uint256 i; i < logs.length; ++i) {

            if (logs[i].emitter == diamond && logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    function _oneRef(
        address _referrer
    )
        internal
        pure
        returns (address[] memory refs)
    {
        refs = new address[](1);

        refs[0] = _referrer;
    }
}

contract CourierOpenUsdcMainnetFork is CourierOpenVaultForkBase {

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

contract CourierOpenUsdtMainnetFork is CourierOpenVaultForkBase {

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

contract CourierOpenUsdgMainnetFork is CourierOpenVaultForkBase {

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

contract CourierOpenUsdcBaseFork is CourierOpenVaultForkBase {

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

contract CourierOpenUsdtBaseFork is CourierOpenVaultForkBase {

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

contract CourierOpenUsdcArbitrumFork is CourierOpenVaultForkBase {

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

contract CourierOpenUsdtArbitrumFork is CourierOpenVaultForkBase {

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

contract CourierOpenUsdgArbitrumFork is CourierOpenVaultForkBase {

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

contract CourierOpenUsdgRobinhoodFork is CourierOpenVaultForkBase {

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

/**
 * @dev Rehearses the hub payout rule round on a mainnet fork of the LIVE
 * {ReferralHub} by driving the broadcast script itself after the fork only
 * handover of the hub master role to the test key: `propose()` deploys the
 * new intake, mailbox and payout facets (the three that compile the shared
 * intake) and proposes their selector batches, a premature execute reverts
 * on the real 3-day timelock, `execute()` flips all three groups and
 * deploys the new reader, `abort()` cancels the pending proposals while the
 * live facets stay. Around the flip the
 * scenario pins the rule the build changes against the live hub: a spoke
 * bucket filled by an envelope delivered under the live base vault's real
 * source registration (received from the real router address and applied)
 * is refused by the live facet with its retired error and stays outside
 * the payable amount; after the flip the same bucket pays its owner
 * through `claim`, `claimUpTo` and `claimAll`, `payoutAddressOf` answers
 * the owner, the payable amount equals the accrued amount from the first
 * claim on, the new reader lists the owner as the payout and counts the
 * bucket as claimable now, and a designation pushed from the live base
 * registry's real source registration redirects a later claim. Run alone:
 * the script reads PRIVATE_KEY from the process environment.
 */
contract CourierOpenHubMainnetFork is Test {

    bytes4 internal constant RETIRED_NOT_DESIGNATED_ERROR = bytes4(
        keccak256(
            "PayoutNotDesignated()"
        )
    );

    uint256 internal constant BASE_CHAIN_ID = 8_453;

    uint256 internal constant SPOKE_AVERAGE = 100_000 * 1e6;

    uint256 internal constant POT_FUNDING = 1_000_000 * 1e6;

    uint256 internal constant SELECTOR_DELAY = 3 days;

    IReferralHub internal hub;

    address internal usd;

    address internal router;

    uint64 internal baseSelector;

    address internal baseVault;

    address internal baseRegistry;

    address internal operator;

    uint256 internal operatorPk;

    address internal refA;

    address internal refB;

    address internal refC;

    address internal designated;

    UpgradeReferralHubPayout internal script;

    uint256 internal nonce;

    function setUp()
        public
    {
        hub = IReferralHub(
            vm.parseJsonAddress(
                vm.readFile(
                    "config/hub.mainnet.json"
                ),
                ".hub"
            )
        );

        usd = vm.parseJsonAddress(
            vm.readFile(
                "config/vault.usdc.mainnet.json"
            ),
            ".usd"
        );

        baseVault = vm.parseJsonAddress(
            vm.readFile(
                "config/vault.usdc.base.json"
            ),
            ".diamond"
        );

        baseRegistry = vm.parseJsonAddress(
            vm.readFile(
                "config/registry.base.json"
            ),
            ".registry"
        );

        baseSelector = uint64(
            vm.parseUint(
                vm.parseJsonString(
                    vm.readFile(
                        "config/ccip.base.json"
                    ),
                    ".chainSelector"
                )
            )
        );

        vm.createSelectFork(
            "mainnet"
        );

        require(
            address(hub).code.length > 0,
            "hub not deployed on the mainnet fork"
        );

        router = hub.ccipRouter();

        require(
            hub.flushSourceChainId(baseSelector, baseVault) == BASE_CHAIN_ID,
            "the base usdc vault must be a registered flush source on the live hub"
        );

        require(
            hub.designationSourceChainId(baseSelector, baseRegistry) == BASE_CHAIN_ID,
            "the base registry must be a registered designation source on the live hub"
        );

        (
            operator,
            operatorPk
        ) = makeAddrAndKey(
            "courierOpenHubOperator"
        );

        refA = makeAddr(
            "courierOpenHubReferrerA"
        );

        refB = makeAddr(
            "courierOpenHubReferrerB"
        );

        refC = makeAddr(
            "courierOpenHubReferrerC"
        );

        designated = makeAddr(
            "courierOpenHubDesignated"
        );

        script = new UpgradeReferralHubPayout();
    }

    function test_hubUpgrade_undesignatedSpokeBucketPaysOwnerThroughEveryClaimShape()
        public
    {
        uint256 payableBefore = hub.totalPayable();

        uint256 amountA = _deliverSpokeCrumb(
            refA
        );

        assertEq(
            hub.payoutAddressOf(
                BASE_CHAIN_ID,
                refA
            ),
            address(0),
            "the live facet must answer zero for an undesignated spoke bucket"
        );

        assertEq(
            hub.totalPayable(),
            payableBefore,
            "the live intake must leave an undesignated spoke accrual outside the payable amount"
        );

        vm.prank(
            refA
        );

        vm.expectRevert(
            RETIRED_NOT_DESIGNATED_ERROR
        );

        hub.claim(
            BASE_CHAIN_ID,
            refA
        );

        _handOverHubMaster();

        _upgradeThroughScript();

        ReferralHubReader reader = new ReferralHubReader(
            address(hub)
        );

        assertEq(
            hub.payoutAddressOf(
                BASE_CHAIN_ID,
                refA
            ),
            refA,
            "the new facet must answer the owner for an undesignated spoke bucket"
        );

        deal(
            usd,
            address(hub),
            POT_FUNDING
        );

        vm.prank(
            refA
        );

        hub.claim(
            BASE_CHAIN_ID,
            refA
        );

        assertEq(
            IUsdErc20(usd).balanceOf(
                refA
            ),
            amountA,
            "claim must pay the owner its undesignated spoke bucket in real USD"
        );

        assertEq(
            hub.totalPayable(),
            hub.totalAccrued(),
            "the first claim after the flip must bring the payable amount to the accrued amount"
        );

        uint256 amountB = _deliverSpokeCrumb(
            refB
        );

        assertEq(
            hub.totalPayable(),
            hub.totalAccrued(),
            "an accrual after the flip must count toward the payable amount at once"
        );

        vm.prank(
            refB
        );

        hub.claimUpTo(
            BASE_CHAIN_ID,
            refB,
            amountB / 2
        );

        uint256[] memory chains = new uint256[](2);

        chains[0] = block.chainid;

        chains[1] = BASE_CHAIN_ID;

        vm.prank(
            refB
        );

        uint256 total = hub.claimAll(
            refB,
            chains
        );

        assertEq(
            total,
            amountB - amountB / 2,
            "claimAll must pay the remainder of the undesignated spoke bucket"
        );

        assertEq(
            IUsdErc20(usd).balanceOf(
                refB
            ),
            amountB,
            "claimUpTo and claimAll must pay the owner the whole bucket between them"
        );

        uint256 amountC = _deliverSpokeCrumb(
            refC
        );

        (
            uint256[] memory amounts,
            address[] memory payouts,
            uint256 totalC,
            uint256 claimableNow
        ) = reader.claimablesOf(
            refC,
            chains
        );

        assertEq(
            amounts[1],
            amountC,
            "the reader must list the spoke bucket"
        );

        assertEq(
            payouts[1],
            refC,
            "the reader must name the owner as the payout of an undesignated spoke bucket"
        );

        assertEq(
            claimableNow,
            totalC,
            "the reader must count an undesignated spoke bucket as claimable now"
        );

        _pushDesignation(
            refC,
            designated
        );

        assertEq(
            hub.payoutAddressOf(
                BASE_CHAIN_ID,
                refC
            ),
            designated,
            "a landed designation must redirect the bucket"
        );

        (
            ,
            payouts,
            ,
        ) = reader.claimablesOf(
            refC,
            chains
        );

        assertEq(
            payouts[1],
            designated,
            "the reader must follow the landed designation"
        );

        vm.prank(
            refC
        );

        hub.claim(
            BASE_CHAIN_ID,
            refC
        );

        assertEq(
            IUsdErc20(usd).balanceOf(
                designated
            ),
            amountC,
            "the claim after the designation must pay the designated address"
        );

        assertEq(
            hub.totalPayable(),
            hub.totalAccrued(),
            "the payable amount must track the accrued amount through every claim"
        );
    }

    function test_hubUpgrade_abortCancelsTheProposalsAndKeepsTheLiveFacets()
        public
    {
        bytes4[][] memory groups = _groups();

        address[] memory liveFacets = _routedFacets(
            groups
        );

        _handOverHubMaster();

        script.propose();

        for (uint256 i; i < groups.length; ++i) {
            assertTrue(
                hub.selectorChangeQueuedAt(groups[i][0]) > 0,
                "propose must queue every batch of the round"
            );
        }

        script.abort();

        for (uint256 i; i < groups.length; ++i) {

            for (uint256 k; k < groups[i].length; ++k) {

                assertEq(
                    hub.selectorChangeQueuedAt(
                        groups[i][k]
                    ),
                    0,
                    "abort must cancel every selector of the round"
                );

                assertEq(
                    hub.selectorToFacet(
                        groups[i][k]
                    ),
                    liveFacets[i],
                    "abort must leave the live facets routed"
                );
            }
        }
    }

    // ---- the script driven upgrade ----

    function _handOverHubMaster()
        internal
    {
        address liveMaster = hub.master();

        vm.prank(
            liveMaster
        );

        hub.proposeOwner(
            operator
        );

        vm.prank(
            operator
        );

        hub.claimOwnership();

        assertEq(
            hub.master(),
            operator,
            "the fork handover must make the test key the hub master"
        );

        vm.setEnv(
            "PRIVATE_KEY",
            vm.toString(
                operatorPk
            )
        );
    }

    function _upgradeThroughScript()
        internal
    {
        bytes4[][] memory groups = _groups();

        address[] memory liveFacets = _routedFacets(
            groups
        );

        script.status();

        script.propose();

        uint256 proposedAt = block.timestamp;

        for (uint256 i; i < groups.length; ++i) {
            assertTrue(
                hub.selectorChangeQueuedAt(groups[i][0]) > 0,
                "propose must queue every batch of the round"
            );
        }

        vm.prank(
            operator
        );

        vm.expectRevert(
            SelectorTimelockNotElapsed.selector
        );

        hub.executeSelectorChanges(
            groups[2]
        );

        vm.warp(
            proposedAt + SELECTOR_DELAY + 1
        );

        script.execute();

        for (uint256 i; i < groups.length; ++i) {

            address routed = hub.selectorToFacet(
                groups[i][0]
            );

            assertTrue(
                routed != liveFacets[i]
                    && routed.code.length > 0,
                "execute must route every group of the round to its new facet"
            );

            for (uint256 k; k < groups[i].length; ++k) {

                assertEq(
                    hub.selectorToFacet(
                        groups[i][k]
                    ),
                    routed,
                    "every selector of a group must route to its new facet"
                );

                assertEq(
                    hub.selectorChangeQueuedAt(
                        groups[i][k]
                    ),
                    0,
                    "nothing may stay queued after execute"
                );
            }
        }

        script.status();
    }

    function _groups()
        internal
        pure
        returns (bytes4[][] memory groups)
    {
        groups = new bytes4[][](3);

        groups[0] = ReferralHubSelectors._intakeSelectors();

        groups[1] = ReferralHubSelectors._mailboxSelectors();

        groups[2] = ReferralHubSelectors._payoutSelectors();
    }

    function _routedFacets(
        bytes4[][] memory _selectorGroups
    )
        internal
        view
        returns (address[] memory facets)
    {
        facets = new address[](
            _selectorGroups.length
        );

        for (uint256 i; i < _selectorGroups.length; ++i) {
            facets[i] = hub.selectorToFacet(
                _selectorGroups[i][0]
            );
        }
    }

    // ---- live hub intake through the real source registrations ----

    function _deliverSpokeCrumb(
        address _referrer
    )
        internal
        returns (uint256 amount)
    {
        uint256 week = block.timestamp / CohortWeeks.WEEK
            - 1;

        uint256[] memory words = new uint256[](4);

        words[0] = CohortFlushCodec._packFlushHeader(
            _referrer,
            1,
            block.timestamp
        );

        words[1] = CohortFlushCodec._packFlushEntry(
            _referrer,
            1,
            0,
            0,
            0
        );

        words[2] = week;

        words[3] = CohortWeeks._packLanes(
            SPOKE_AVERAGE * CohortWeeks.WEEK,
            0,
            0
        ) | CohortWeeks.CRUMB_WRITTEN_BIT;

        bytes memory payload = abi.encodePacked(
            words
        );

        bytes32 messageId = keccak256(
            abi.encode(
                "courier open hub rehearsal",
                _referrer,
                ++nonce
            )
        );

        vm.prank(
            router
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: messageId,
                sourceChainSelector: baseSelector,
                sender: abi.encode(
                    baseVault
                ),
                data: payload,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        uint256 before = hub.claimable(
            BASE_CHAIN_ID,
            _referrer
        );

        hub.applyFlush(
            messageId,
            baseSelector,
            BASE_CHAIN_ID,
            baseVault,
            payload
        );

        amount = hub.claimable(
            BASE_CHAIN_ID,
            _referrer
        )
            - before;

        (
            uint256 y1Bps,
            ,
        ) = hub.weeklyRates(
            _referrer,
            week
        );

        assertEq(
            amount,
            SPOKE_AVERAGE * CohortWeeks.WEEK * y1Bps / (10_000 * CohortWeeks.YEAR),
            "the live hub must price the delivered week at its own rate"
        );

        assertGt(
            amount,
            0,
            "the delivered week must accrue a nonzero amount"
        );
    }

    function _pushDesignation(
        address _owner,
        address _payout
    )
        internal
    {
        vm.prank(
            router
        );

        hub.ccipReceive(
            Client.Any2EVMMessage({
                messageId: keccak256(
                    abi.encode(
                        "courier open hub designation",
                        _owner,
                        ++nonce
                    )
                ),
                sourceChainSelector: baseSelector,
                sender: abi.encode(
                    baseRegistry
                ),
                data: abi.encode(
                    uint256(2),
                    _owner,
                    _payout,
                    block.timestamp,
                    uint256(1)
                ),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }
}
