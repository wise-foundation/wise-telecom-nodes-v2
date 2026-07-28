// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.29;

import "forge-std/Vm.sol";

import {QueContract} from "../../src/legacy/que/QueContractLegacy.sol";
import {QueContractDeclarations} from "../../src/legacy/que/QueContractDeclarationsLegacy.sol";
import {QueStateParser} from "./QueStateParser.sol";

/**
 * @title QueParityVerifier
 * @dev Verification library for the legacy QueContract migration. Two entry
 * points, both usable from fork tests and from the MoneyForwardDeployer
 * scripts (internal library functions inline into the caller, so no
 * deployment happens):
 *
 *   1. verifyFileMatchesLive — proves a data/que_state_*.txt snapshot still
 *      matches the LIVE deployed QueContract (drift guard: any join, leave,
 *      reduce or fulfill since the snapshot was fetched is detected). Reads
 *      the live contract with typed calls, so a codeless/wrong address
 *      reverts immediately.
 *
 *   2. verifyNewQueMatchesLiveOldQue — proves a freshly migrated QueContract
 *      answers every view function identically to the live old one: the
 *      globals (incl. usdToken), all four per-incentive getters, every
 *      QueMemberByIdAndIncentive slot from id 0 through earliestValid
 *      (sentinel included) on all 17 standard incentives, out-of-domain
 *      probes (ids past earliestValid, non-standard incentives — sampled;
 *      full-domain completeness follows from legacy never writing past
 *      earliestValid), and a branch-covering sweep of all derived views
 *      (fulfillment plans, solve/predict functions, order listings). Views
 *      are compared via raw symmetric staticcalls, so reverts must match
 *      too and no assumption about the live deployment's bytecode is
 *      needed. Intentionally NOT compared: master, proposedMaster,
 *      forwardVault (divergent by design on a fresh deployment).
 *
 * The 17 standard incentives are walked in the exact order used by
 * tools/fetch-que-state.ts, which also defines the file row order.
 */
library QueParityVerifier {

    Vm constant vm = Vm(
        address(
            uint160(
                uint256(
                    keccak256(
                        "hevm cheat code"
                    )
                )
            )
        )
    );

    uint256 constant HUGE_AMOUNT = 1e30;

    uint256 constant FAR_OUT_OF_DOMAIN_OFFSET = 1000;

    address constant NEVER_MEMBER = address(0xDEAD);

    struct FileMembers {
        int256[]  incentives;
        uint256[] ids;
        address[] members;
        uint256[] amounts;
        uint256[] tails;
        uint256[] heads;
    }

    struct ParityVars {
        int256[17]  incentives;
        uint256[17] earliestValid;
        uint256[17] liquidity;
        uint256     totalLiquidity;
        uint256     minDepositAmount;
        address[]   liveMembers;
        uint256     liveMemberCount;
    }

    function _standardIncentives()
        private
        pure
        returns (int256[17] memory)
    {
        return [
            int256(100), int256(200), int256(300), int256(500), int256(1000),
            int256(1500), int256(2500), int256(5000),
            int256(0),
            int256(-100), int256(-200), int256(-300), int256(-500),
            int256(-1000), int256(-1500), int256(-2500), int256(-5000)
        ];
    }

    /**
     * @dev Entry point 1: reverts unless the snapshot file matches the live
     * QueContract exactly — globals, per-incentive pointers/counters, and
     * every non-empty member slot in the walked domain.
     */
    function verifyFileMatchesLive(
        QueContract _oldQue,
        string memory _queFile
    )
        internal
    {
        _requireSummaryMatchesFile(
            _oldQue,
            _queFile
        );

        _requirePointersMatchFile(
            _oldQue,
            _queFile
        );

        _requireMembersMatchFile(
            _oldQue,
            _queFile
        );
    }

    function _requireSummaryMatchesFile(
        QueContract _oldQue,
        string memory _queFile
    )
        private
    {
        (
            uint256 totalActive,
            bool    negNotAllowed,
            uint256 minDeposit
        ) = QueStateParser.readSummary(
            _queFile
        );

        require(
            _oldQue.totalActiveOrders() == totalActive,
            "QueParityVerifier: totalActiveOrders drift"
        );

        require(
            _oldQue.minDepositAmount() == minDeposit,
            "QueParityVerifier: minDepositAmount drift"
        );

        require(
            _oldQue.negativeIncentivesNotAllowed() == negNotAllowed,
            "QueParityVerifier: negativeIncentivesNotAllowed drift"
        );
    }

    function _requirePointersMatchFile(
        QueContract _oldQue,
        string memory _queFile
    )
        private
    {
        (
            int256[]  memory incs,
            uint256[] memory earliest,
            uint256[] memory current,
            uint256[] memory active,
            bool[]    memory allowed
        ) = QueStateParser.readPointers(
            _queFile
        );

        int256[17] memory canonical = _standardIncentives();

        require(
            incs.length == canonical.length,
            "QueParityVerifier: incentive count drift"
        );

        for (uint256 i; i < incs.length; ++i) {

            require(
                incs[i] == canonical[i],
                string.concat(
                    "QueParityVerifier: incentive order drift ",
                    vm.toString(incs[i])
                )
            );

            require(
                _oldQue.earliestValidQueMemberByIncentive(incs[i]) == earliest[i],
                string.concat(
                    "QueParityVerifier: earliestValid drift ",
                    vm.toString(incs[i])
                )
            );

            require(
                _oldQue.currentOrderIdByIncentive(incs[i]) == current[i],
                string.concat(
                    "QueParityVerifier: currentOrderId drift ",
                    vm.toString(incs[i])
                )
            );

            require(
                _oldQue.activeOrderCountByIncentive(incs[i]) == active[i],
                string.concat(
                    "QueParityVerifier: activeOrderCount drift ",
                    vm.toString(incs[i])
                )
            );

            require(
                _oldQue.incentiveAllowed(incs[i]) == allowed[i],
                string.concat(
                    "QueParityVerifier: incentiveAllowed drift ",
                    vm.toString(incs[i])
                )
            );
        }
    }

    /**
     * @dev Walks every slot id 0..earliestValid (inclusive of the sentinel)
     * per incentive — the entire domain the legacy contract can ever have
     * written — applies the same 4-field emptiness filter as
     * tools/fetch-que-state.ts, and compares the non-empty slots
     * sequentially against the file rows. The pointer stage already pinned
     * earliestValid per incentive, so both sides walk an identical domain
     * in an identical order and the sequential compare is exact.
     */
    function _requireMembersMatchFile(
        QueContract _oldQue,
        string memory _queFile
    )
        private
    {
        FileMembers memory f;

        (
            f.incentives,
            f.ids,
            f.members,
            f.amounts,
            f.tails,
            f.heads
        ) = QueStateParser.readMembers(
            _queFile
        );

        int256[17] memory canonical = _standardIncentives();

        uint256 fileIdx;

        for (uint256 i; i < canonical.length; ++i) {
            fileIdx = _walkIncentiveSlots(
                _oldQue,
                canonical[i],
                f,
                fileIdx
            );
        }

        require(
            fileIdx == f.ids.length,
            "QueParityVerifier: file has extra member rows"
        );
    }

    function _walkIncentiveSlots(
        QueContract _oldQue,
        int256 _incentive,
        FileMembers memory _f,
        uint256 _fileIdx
    )
        private
        view
        returns (uint256)
    {
        uint256 earliest = _oldQue.earliestValidQueMemberByIncentive(
            _incentive
        );

        for (uint256 id; id <= earliest; ++id) {

            (
                address member,
                uint256 amount,
                uint256 tail,
                uint256 head
            ) = _oldQue.QueMemberByIdAndIncentive(
                id,
                _incentive
            );

            if (member == address(0) && amount == 0 && tail == 0 && head == 0) {
                continue;
            }

            _requireRowMatches(
                _f,
                _fileIdx,
                _incentive,
                id,
                member,
                amount,
                tail,
                head
            );

            ++_fileIdx;
        }

        return _fileIdx;
    }

    function _requireRowMatches(
        FileMembers memory _f,
        uint256 _idx,
        int256 _incentive,
        uint256 _id,
        address _member,
        uint256 _amount,
        uint256 _tail,
        uint256 _head
    )
        private
        pure
    {
        string memory label = string.concat(
            vm.toString(_incentive),
            "/",
            vm.toString(_id)
        );

        require(
            _idx < _f.ids.length,
            string.concat(
                "QueParityVerifier: live slot missing from file ",
                label
            )
        );

        require(
            _f.incentives[_idx] == _incentive && _f.ids[_idx] == _id,
            string.concat(
                "QueParityVerifier: member row order drift ",
                label
            )
        );

        require(
            _f.members[_idx] == _member,
            string.concat(
                "QueParityVerifier: member address drift ",
                label
            )
        );

        require(
            _f.amounts[_idx] == _amount,
            string.concat(
                "QueParityVerifier: member amount drift ",
                label
            )
        );

        require(
            _f.tails[_idx] == _tail,
            string.concat(
                "QueParityVerifier: member tailPointer drift ",
                label
            )
        );

        require(
            _f.heads[_idx] == _head,
            string.concat(
                "QueParityVerifier: member headPointer drift ",
                label
            )
        );
    }

    /**
     * @dev Entry point 3: bounded fork-test variant of
     * verifyNewQueMatchesLiveOldQue. Identical coverage EXCEPT the full
     * per-slot domain walk against the live old que is not performed
     * through the fork (each cold slot there is one RPC round trip;
     * arb/usdt has 11k+ ids). Instead:
     *   - LiveStateRefresher.verifyQueFileMatchesLive must have proven
     *     file == live off-fork (caller's responsibility, batched
     *     multicalls, seconds);
     *   - the new que's ENTIRE domain is walked locally (free) and
     *     required to match the file exactly - non-empty slots row by
     *     row, everything else zero;
     *   - the live old que is still staticcalled on globals,
     *     per-incentive getters, every FILE member row, the linked-list
     *     derived views (solve/predict/fulfillment/discount) and the
     *     out-of-domain probes;
     *   - the getAllOrders* views walk id 0..earliestValid INSIDE the
     *     legacy contract, so on the live que they are replaced by
     *     comparing the NEW que's answers against expectations built
     *     from the proven file rows.
     * Deploy scripts keep using the unbounded entry points 1 and 2.
     */
    function verifyNewQueMatchesLiveOldQueBounded(
        QueContract _oldQue,
        QueContract _newQue,
        string memory _queFile
    )
        internal
    {
        require(
            address(_oldQue).code.length > 0,
            "QueParityVerifier: old que has no code"
        );

        require(
            address(_newQue).code.length > 0,
            "QueParityVerifier: new que has no code"
        );

        ParityVars memory v;

        v.incentives = _standardIncentives();

        v.minDepositAmount = _oldQue.minDepositAmount();

        _requireGlobalsMatch(
            _oldQue,
            _newQue
        );

        _requirePerIncentiveGettersMatch(
            _oldQue,
            _newQue,
            v
        );

        FileMembers memory f;

        (
            f.incentives,
            f.ids,
            f.members,
            f.amounts,
            f.tails,
            f.heads
        ) = QueStateParser.readMembers(
            _queFile
        );

        _requireFileSlotsMatchBoth(
            _oldQue,
            _newQue,
            v,
            f
        );

        _requireAmountAndDiscountViewsMatch(
            _oldQue,
            _newQue,
            v
        );

        _requireOrderListViewsMatchFile(
            _newQue,
            f,
            v
        );

        _requireOutOfDomainZero(
            _oldQue,
            _newQue,
            v
        );
    }

    /**
     * @dev Walks the NEW que's full domain locally: every (incentive, id)
     * either matches the next file row exactly (and, for those few live
     * ids, the old and new que answer the raw staticcall identically) or
     * is required to be fully zero. Collects liquidity and live members
     * from the file rows for the derived-view sweep.
     */
    function _requireFileSlotsMatchBoth(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v,
        FileMembers memory f
    )
        private
    {
        _v.liveMembers = new address[](
            f.ids.length
        );

        uint256 fileIdx;

        for (uint256 i; i < _v.incentives.length; ++i) {
            fileIdx = _walkNewQueSlots(
                _oldQue,
                _newQue,
                _v,
                f,
                fileIdx,
                i
            );
        }

        require(
            fileIdx == f.ids.length,
            "QueParityVerifier: file has extra member rows"
        );
    }

    function _walkNewQueSlots(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v,
        FileMembers memory _f,
        uint256 _fileIdx,
        uint256 _i
    )
        private
        returns (uint256)
    {
        int256 inc = _v.incentives[_i];

        for (uint256 id; id <= _v.earliestValid[_i]; ++id) {

            bool isFileRow = _fileIdx < _f.ids.length
                && _f.incentives[_fileIdx] == inc
                && _f.ids[_fileIdx] == id;

            if (isFileRow) {
                _requireLiveSlotRowMatches(
                    _oldQue,
                    _newQue,
                    _f,
                    _fileIdx,
                    inc,
                    id
                );

                if (_f.amounts[_fileIdx] > 0) {
                    _v.liquidity[_i] += _f.amounts[_fileIdx];
                    _v.totalLiquidity += _f.amounts[_fileIdx];
                    _v.liveMembers[_v.liveMemberCount++] = _f.members[_fileIdx];
                }

                ++_fileIdx;
                continue;
            }

            _requireNewQueSlotZero(
                _newQue,
                inc,
                id
            );
        }

        return _fileIdx;
    }

    function _requireLiveSlotRowMatches(
        QueContract _oldQue,
        QueContract _newQue,
        FileMembers memory _f,
        uint256 _fileIdx,
        int256 _inc,
        uint256 _id
    )
        private
        view
    {
        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.QueMemberByIdAndIncentive,
                (_id, _inc)
            ),
            string.concat(
                "QueMemberByIdAndIncentive/",
                vm.toString(_inc),
                "/",
                vm.toString(_id)
            )
        );

        (
            address member,
            uint256 amount,
            uint256 tail,
            uint256 head
        ) = _newQue.QueMemberByIdAndIncentive(
            _id,
            _inc
        );

        _requireRowMatches(
            _f,
            _fileIdx,
            _inc,
            _id,
            member,
            amount,
            tail,
            head
        );
    }

    function _requireNewQueSlotZero(
        QueContract _newQue,
        int256 _inc,
        uint256 _id
    )
        private
        view
    {
        (
            address member,
            uint256 amount,
            uint256 tail,
            uint256 head
        ) = _newQue.QueMemberByIdAndIncentive(
            _id,
            _inc
        );

        require(
            member == address(0) && amount == 0 && tail == 0 && head == 0,
            string.concat(
                "QueParityVerifier: new que phantom slot ",
                vm.toString(_inc),
                "/",
                vm.toString(_id)
            )
        );
    }

    /**
     * @dev Entry point 2: reverts unless the new QueContract answers every
     * view function identically to the live old one.
     */
    function verifyNewQueMatchesLiveOldQue(
        QueContract _oldQue,
        QueContract _newQue
    )
        internal
        view
    {
        require(
            address(_oldQue).code.length > 0,
            "QueParityVerifier: old que has no code"
        );

        require(
            address(_newQue).code.length > 0,
            "QueParityVerifier: new que has no code"
        );

        ParityVars memory v;

        v.incentives = _standardIncentives();

        v.minDepositAmount = _oldQue.minDepositAmount();

        _requireGlobalsMatch(
            _oldQue,
            _newQue
        );

        _requirePerIncentiveGettersMatch(
            _oldQue,
            _newQue,
            v
        );

        _requireAllSlotsMatch(
            _oldQue,
            _newQue,
            v
        );

        _requireDerivedViewsMatch(
            _oldQue,
            _newQue,
            v
        );

        _requireOutOfDomainZero(
            _oldQue,
            _newQue,
            v
        );
    }

    function _requireGlobalsMatch(
        QueContract _oldQue,
        QueContract _newQue
    )
        private
        view
    {
        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.totalActiveOrders,
                ()
            ),
            "totalActiveOrders"
        );

        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.minDepositAmount,
                ()
            ),
            "minDepositAmount"
        );

        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.negativeIncentivesNotAllowed,
                ()
            ),
            "negativeIncentivesNotAllowed"
        );

        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.usdToken,
                ()
            ),
            "usdToken"
        );
    }

    function _requirePerIncentiveGettersMatch(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v
    )
        private
        view
    {
        for (uint256 i; i < _v.incentives.length; ++i) {

            int256 inc = _v.incentives[i];

            _v.earliestValid[i] = _oldQue.earliestValidQueMemberByIncentive(
                inc
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.earliestValidQueMemberByIncentive,
                    (inc)
                ),
                string.concat(
                    "earliestValidQueMemberByIncentive/",
                    vm.toString(inc)
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.currentOrderIdByIncentive,
                    (inc)
                ),
                string.concat(
                    "currentOrderIdByIncentive/",
                    vm.toString(inc)
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.activeOrderCountByIncentive,
                    (inc)
                ),
                string.concat(
                    "activeOrderCountByIncentive/",
                    vm.toString(inc)
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.incentiveAllowed,
                    (inc)
                ),
                string.concat(
                    "incentiveAllowed/",
                    vm.toString(inc)
                )
            );
        }
    }

    /**
     * @dev Compares every QueMemberByIdAndIncentive slot in the walked
     * domain and collects per-incentive liquidity plus the live member
     * addresses, which parameterize the derived-view sweep afterwards.
     */
    function _requireAllSlotsMatch(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v
    )
        private
        view
    {
        uint256 totalSlots;

        for (uint256 i; i < _v.incentives.length; ++i) {
            totalSlots += _v.earliestValid[i] + 1;
        }

        _v.liveMembers = new address[](
            totalSlots
        );

        for (uint256 i; i < _v.incentives.length; ++i) {

            int256 inc = _v.incentives[i];

            for (uint256 id; id <= _v.earliestValid[i]; ++id) {

                _requireSameCall(
                    _oldQue,
                    _newQue,
                    abi.encodeCall(
                        _oldQue.QueMemberByIdAndIncentive,
                        (id, inc)
                    ),
                    string.concat(
                        "QueMemberByIdAndIncentive/",
                        vm.toString(inc),
                        "/",
                        vm.toString(id)
                    )
                );

                (
                    address member,
                    uint256 amount,
                    ,
                ) = _oldQue.QueMemberByIdAndIncentive(
                    id,
                    inc
                );

                if (amount > 0) {
                    _v.liquidity[i] += amount;
                    _v.totalLiquidity += amount;
                    _v.liveMembers[_v.liveMemberCount++] = member;
                }
            }
        }
    }

    function _requireDerivedViewsMatch(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v
    )
        private
        view
    {
        _requireAmountAndDiscountViewsMatch(
            _oldQue,
            _newQue,
            _v
        );

        _requireOrderListViewsMatch(
            _oldQue,
            _newQue,
            _v
        );
    }

    /**
     * @dev The traversal, prediction and discount view sweeps. These all
     * follow the queue's linked list from currentOrderId via headPointer,
     * touching only live members - cheap even on a forked contract, so
     * both the bounded and unbounded entry points compare them on the
     * live old que directly. The getAllOrders* views are NOT here: those
     * walk id 0..earliestValid inside the legacy contract, which on a
     * fork costs one storage fetch per slot.
     */
    function _requireAmountAndDiscountViewsMatch(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v
    )
        private
        view
    {
        for (uint256 i; i < _v.incentives.length; ++i) {
            _requirePerIncentiveViewsMatch(
                _oldQue,
                _newQue,
                _v.incentives[i],
                _amountGrid(
                    _v.liquidity[i],
                    _v.minDepositAmount
                )
            );
        }

        int256[2] memory extraIncs = [
            int256(750),
            int256(-750)
        ];

        for (uint256 i; i < extraIncs.length; ++i) {
            _requirePerIncentiveViewsMatch(
                _oldQue,
                _newQue,
                extraIncs[i],
                _amountGrid(
                    0,
                    _v.minDepositAmount
                )
            );
        }

        _requireGlobalAmountViewsMatch(
            _oldQue,
            _newQue,
            _amountGrid(
                _v.totalLiquidity,
                _v.minDepositAmount
            )
        );

        _requireDiscountViewsMatch(
            _oldQue,
            _newQue,
            _v
        );
    }

    /**
     * @dev Bounded replacement for _requireOrderListViewsMatch: the
     * getAllOrders* views walk id 0..earliestValid INSIDE the legacy
     * contract, so calling them on the forked live que costs one storage
     * fetch per domain slot. Instead the expected returndata is built
     * from the file rows (proven equal to live by verify-que-live) using
     * the exact _shouldIncludeOrder semantics - amount > 0, id strictly
     * below earliestValid, canonical incentive order - and compared
     * byte-for-byte against the NEW que's local answers.
     */
    function _requireOrderListViewsMatchFile(
        QueContract _newQue,
        FileMembers memory _f,
        ParityVars memory _v
    )
        private
        view
    {
        _requireOrderListCallMatchesFile(
            _newQue,
            abi.encodeCall(
                _newQue.getAllOrdersOverall,
                ()
            ),
            _f,
            _v,
            address(0),
            false,
            "getAllOrdersOverall"
        );

        for (uint256 k; k < _v.liveMemberCount; ++k) {
            _requireOrderListCallMatchesFile(
                _newQue,
                abi.encodeCall(
                    _newQue.getAllOrdersfromAddress,
                    (_v.liveMembers[k])
                ),
                _f,
                _v,
                _v.liveMembers[k],
                true,
                string.concat(
                    "getAllOrdersfromAddress/",
                    vm.toString(_v.liveMembers[k])
                )
            );
        }

        _requireOrderListCallMatchesFile(
            _newQue,
            abi.encodeCall(
                _newQue.getAllOrdersfromAddress,
                (address(0))
            ),
            _f,
            _v,
            address(0),
            true,
            "getAllOrdersfromAddress/zero"
        );

        _requireOrderListCallMatchesFile(
            _newQue,
            abi.encodeCall(
                _newQue.getAllOrdersfromAddress,
                (NEVER_MEMBER)
            ),
            _f,
            _v,
            NEVER_MEMBER,
            true,
            "getAllOrdersfromAddress/never"
        );
    }

    function _requireOrderListCallMatchesFile(
        QueContract _newQue,
        bytes memory _callData,
        FileMembers memory _f,
        ParityVars memory _v,
        address _user,
        bool _checkUser,
        string memory _label
    )
        private
        view
    {
        (
            bool success,
            bytes memory returned
        ) = address(_newQue).staticcall(
            _callData
        );

        require(
            success,
            string.concat(
                "QueParityVerifier: order list call failed ",
                _label
            )
        );

        require(
            keccak256(returned) == keccak256(
                _buildExpectedOrders(
                    _f,
                    _v,
                    _user,
                    _checkUser
                )
            ),
            string.concat(
                "QueParityVerifier: order list mismatch vs file ",
                _label
            )
        );
    }

    function _buildExpectedOrders(
        FileMembers memory _f,
        ParityVars memory _v,
        address _user,
        bool _checkUser
    )
        private
        pure
        returns (bytes memory)
    {
        uint256 count;

        for (uint256 j; j < _f.ids.length; ++j) {
            if (_orderIncluded(_f, _v, j, _user, _checkUser)) {
                ++count;
            }
        }

        QueContractDeclarations.QueMember[] memory orders = new QueContractDeclarations.QueMember[](count);
        int256[] memory incs = new int256[](count);

        uint256 idx;

        for (uint256 j; j < _f.ids.length; ++j) {
            if (!_orderIncluded(_f, _v, j, _user, _checkUser)) {
                continue;
            }

            orders[idx] = QueContractDeclarations.QueMember({
                member:      _f.members[j],
                amount:      _f.amounts[j],
                tailPointer: _f.tails[j],
                headPointer: _f.heads[j]
            });
            incs[idx] = _f.incentives[j];

            ++idx;
        }

        return abi.encode(
            orders,
            incs
        );
    }

    function _orderIncluded(
        FileMembers memory _f,
        ParityVars memory _v,
        uint256 _j,
        address _user,
        bool _checkUser
    )
        private
        pure
        returns (bool)
    {
        if (_f.amounts[_j] == 0) {
            return false;
        }

        if (_checkUser ? _f.members[_j] != _user : _f.members[_j] == address(0)) {
            return false;
        }

        for (uint256 i; i < _v.incentives.length; ++i) {
            if (_v.incentives[i] == _f.incentives[_j]) {
                return _f.ids[_j] < _v.earliestValid[i];
            }
        }

        return false;
    }

    /**
     * @dev Amount grid touching each traversal view's distinct control-flow
     * classes: zero early-return, first-order partial, mixed full+partial,
     * exact-exhaustion boundary, over-liquidity, and far-over-liquidity.
     */
    function _amountGrid(
        uint256 _liquidity,
        uint256 _minDeposit
    )
        private
        pure
        returns (uint256[7] memory grid)
    {
        grid[0] = 0;
        grid[1] = 1;
        grid[2] = _minDeposit;
        grid[3] = _liquidity / 2;
        grid[4] = _liquidity;
        grid[5] = _liquidity + 1;
        grid[6] = HUGE_AMOUNT;
    }

    function _requirePerIncentiveViewsMatch(
        QueContract _oldQue,
        QueContract _newQue,
        int256 _incentive,
        uint256[7] memory _grid
    )
        private
        view
    {
        for (uint256 j; j < _grid.length; ++j) {

            uint256 amount = _grid[j];

            string memory label = string.concat(
                vm.toString(_incentive),
                "/",
                vm.toString(amount)
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.getFulfillmentPlanForIncentive,
                    (amount, _incentive, 0)
                ),
                string.concat(
                    "getFulfillmentPlanForIncentive/0/",
                    label
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.getFulfillmentPlanForIncentive,
                    (amount, _incentive, 1)
                ),
                string.concat(
                    "getFulfillmentPlanForIncentive/1/",
                    label
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.getFulfillmentPlanForIncentive,
                    (amount, _incentive, 100)
                ),
                string.concat(
                    "getFulfillmentPlanForIncentive/100/",
                    label
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.solveForAmountWithIncentive,
                    (amount, _incentive)
                ),
                string.concat(
                    "solveForAmountWithIncentive/",
                    label
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue._solveForAmountWithIncentive,
                    (amount, _incentive)
                ),
                string.concat(
                    "_solveForAmountWithIncentive/",
                    label
                )
            );
        }
    }

    function _requireGlobalAmountViewsMatch(
        QueContract _oldQue,
        QueContract _newQue,
        uint256[7] memory _grid
    )
        private
        view
    {
        for (uint256 j; j < _grid.length; ++j) {

            uint256 amount = _grid[j];

            string memory label = vm.toString(
                amount
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.solveForAmount,
                    (amount)
                ),
                string.concat(
                    "solveForAmount/",
                    label
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.predictCostForTokens,
                    (amount)
                ),
                string.concat(
                    "predictCostForTokens/",
                    label
                )
            );

            _requireSameCall(
                _oldQue,
                _newQue,
                abi.encodeCall(
                    _oldQue.predictTokensForCost,
                    (amount)
                ),
                string.concat(
                    "predictTokensForCost/",
                    label
                )
            );
        }
    }

    /**
     * @dev predictDiscountedAmount over all standard incentives plus two
     * non-standard ones; type(uint256).max forces a symmetric mulDiv
     * overflow revert on negative incentives, exercising the revert path
     * of the comparator.
     */
    function _requireDiscountViewsMatch(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v
    )
        private
        view
    {
        uint256[4] memory amounts = [
            uint256(0),
            1,
            1e6,
            type(uint256).max
        ];

        for (uint256 i; i < _v.incentives.length; ++i) {
            for (uint256 j; j < amounts.length; ++j) {
                _requireDiscountCallMatches(
                    _oldQue,
                    _newQue,
                    amounts[j],
                    _v.incentives[i]
                );
            }
        }

        int256[2] memory extraIncs = [
            int256(750),
            int256(-750)
        ];

        for (uint256 i; i < extraIncs.length; ++i) {
            for (uint256 j; j < amounts.length; ++j) {
                _requireDiscountCallMatches(
                    _oldQue,
                    _newQue,
                    amounts[j],
                    extraIncs[i]
                );
            }
        }
    }

    function _requireDiscountCallMatches(
        QueContract _oldQue,
        QueContract _newQue,
        uint256 _amount,
        int256 _incentive
    )
        private
        view
    {
        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.predictDiscountedAmount,
                (_amount, _incentive)
            ),
            string.concat(
                "predictDiscountedAmount/",
                vm.toString(_incentive),
                "/",
                vm.toString(_amount)
            )
        );
    }

    function _requireOrderListViewsMatch(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v
    )
        private
        view
    {
        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.getAllOrdersOverall,
                ()
            ),
            "getAllOrdersOverall"
        );

        for (uint256 k; k < _v.liveMemberCount; ++k) {
            _requireOrdersFromAddressMatch(
                _oldQue,
                _newQue,
                _v.liveMembers[k]
            );
        }

        _requireOrdersFromAddressMatch(
            _oldQue,
            _newQue,
            address(0)
        );

        _requireOrdersFromAddressMatch(
            _oldQue,
            _newQue,
            NEVER_MEMBER
        );
    }

    function _requireOrdersFromAddressMatch(
        QueContract _oldQue,
        QueContract _newQue,
        address _user
    )
        private
        view
    {
        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.getAllOrdersfromAddress,
                (_user)
            ),
            string.concat(
                "getAllOrdersfromAddress/",
                vm.toString(_user)
            )
        );
    }

    /**
     * @dev Legacy never writes slot ids past earliestValid (the sentinel),
     * and non-standard incentives can never gain members (incentiveAllowed
     * has no setter on the legacy contract). Probe both regions: equal on
     * both contracts AND zero on the live one.
     */
    function _requireOutOfDomainZero(
        QueContract _oldQue,
        QueContract _newQue,
        ParityVars memory _v
    )
        private
        view
    {
        for (uint256 i; i < _v.incentives.length; ++i) {

            _requireSlotZeroOnBoth(
                _oldQue,
                _newQue,
                _v.earliestValid[i] + 1,
                _v.incentives[i]
            );

            _requireSlotZeroOnBoth(
                _oldQue,
                _newQue,
                _v.earliestValid[i] + FAR_OUT_OF_DOMAIN_OFFSET,
                _v.incentives[i]
            );
        }

        int256[2] memory extraIncs = [
            int256(750),
            int256(-750)
        ];

        for (uint256 i; i < extraIncs.length; ++i) {
            _requireNonStandardIncentiveEmpty(
                _oldQue,
                _newQue,
                extraIncs[i]
            );
        }
    }

    function _requireSlotZeroOnBoth(
        QueContract _oldQue,
        QueContract _newQue,
        uint256 _id,
        int256 _incentive
    )
        private
        view
    {
        string memory label = string.concat(
            vm.toString(_incentive),
            "/",
            vm.toString(_id)
        );

        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.QueMemberByIdAndIncentive,
                (_id, _incentive)
            ),
            string.concat(
                "outOfDomainSlot/",
                label
            )
        );

        (
            address member,
            uint256 amount,
            uint256 tail,
            uint256 head
        ) = _oldQue.QueMemberByIdAndIncentive(
            _id,
            _incentive
        );

        require(
            member == address(0) && amount == 0 && tail == 0 && head == 0,
            string.concat(
                "QueParityVerifier: out-of-domain slot not empty ",
                label
            )
        );
    }

    function _requireNonStandardIncentiveEmpty(
        QueContract _oldQue,
        QueContract _newQue,
        int256 _incentive
    )
        private
        view
    {
        string memory label = vm.toString(
            _incentive
        );

        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.earliestValidQueMemberByIncentive,
                (_incentive)
            ),
            string.concat(
                "nonStandardEarliestValid/",
                label
            )
        );

        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.currentOrderIdByIncentive,
                (_incentive)
            ),
            string.concat(
                "nonStandardCurrentOrderId/",
                label
            )
        );

        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.activeOrderCountByIncentive,
                (_incentive)
            ),
            string.concat(
                "nonStandardActiveOrderCount/",
                label
            )
        );

        _requireSameCall(
            _oldQue,
            _newQue,
            abi.encodeCall(
                _oldQue.incentiveAllowed,
                (_incentive)
            ),
            string.concat(
                "nonStandardIncentiveAllowed/",
                label
            )
        );

        require(
            _oldQue.earliestValidQueMemberByIncentive(_incentive) == 0,
            string.concat(
                "QueParityVerifier: non-standard incentive has state ",
                label
            )
        );

        require(
            _oldQue.incentiveAllowed(_incentive) == false,
            string.concat(
                "QueParityVerifier: non-standard incentive allowed ",
                label
            )
        );

        _requireSlotZeroOnBoth(
            _oldQue,
            _newQue,
            0,
            _incentive
        );
    }

    /**
     * @dev Core comparator: issues the identical raw staticcall against
     * both contracts and requires the same success flag and identical
     * returndata. Reverts therefore have to match symmetrically, and
     * struct-returning views compare as raw bytes without decoding.
     */
    function _requireSameCall(
        QueContract _oldQue,
        QueContract _newQue,
        bytes memory _callData,
        string memory _label
    )
        private
        view
    {
        (
            bool successOld,
            bytes memory returnOld
        ) = address(_oldQue).staticcall(
            _callData
        );

        (
            bool successNew,
            bytes memory returnNew
        ) = address(_newQue).staticcall(
            _callData
        );

        require(
            successOld == successNew,
            string.concat(
                "QueParityVerifier: success mismatch ",
                _label
            )
        );

        require(
            keccak256(returnOld) == keccak256(returnNew),
            string.concat(
                "QueParityVerifier: returndata mismatch ",
                _label
            )
        );
    }
}
