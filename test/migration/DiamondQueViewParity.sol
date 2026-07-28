// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.36;

import {WiseTelecomNodesQueueStructs} from "../../src/diamond/vault/WiseTelecomNodesQueueStructs.sol";

/**
 * @title DiamondQueViewParity
 * @dev Symmetric-staticcall parity sweep between the LIVE legacy
 * QueContract (old que) and the migrated WiseTelecomNodes diamond,
 * seeded to identical queue storage from the same snapshot. Both are
 * read at the SAME forked block (the que snapshot block), so identical
 * storage must yield byte-identical view returndata.
 *
 * Every legacy que view is compared EXCEPT the three documented
 * divergences the diamond intentionally does not expose:
 *   - solveForAmountWithIncentive(uint256,int256)  (public wrapper
 *     dropped; the internal _solveForAmountWithIncentive IS compared)
 *   - usdToken()                                   (renamed USD_TOKEN)
 *   - forwardVault()                               (que and vault are
 *                                                   one contract now)
 *
 * The cheap linked-list-following views (solve / predict / fulfillment
 * / discount) and the per-incentive getters and the snapshot member
 * slots are compared DIRECTLY old-vs-new. The getAllOrders* views walk
 * id 0..earliestValid inside the contract (up to ~11.5k ids on a live
 * leg, one lazy storage fetch each on a fork), so they are compared by
 * building the expected returndata from the seeded snapshot members
 * (proven == live because the diamond was seeded from them and the
 * fork is pinned to their block) and matching it byte-for-byte against
 * the diamond's own local answer.
 */
library DiamondQueViewParity {

    uint256 internal constant HUGE_AMOUNT = 1e30;
    uint256 internal constant FAR_OUT_OF_DOMAIN_OFFSET = 1000;
    address internal constant NEVER_MEMBER = address(0xDEAD);

    struct Sweep {
        int256[17]  incentives;
        uint256[17] earliestValid;
        uint256[17] liquidity;
        uint256     totalLiquidity;
        uint256     minDepositAmount;
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
     * @dev Top-level entry: reverts with a labelled message on the
     * first view whose old-que and diamond answers diverge. Includes
     * the getAllOrders* order-list views, which walk id
     * 0..earliestValid inside the contract. Use this against a LOCAL
     * (in-memory seeded) diamond, e.g. the W2 fork test.
     */
    function assertParity(
        address _oldQue,
        address _newQue,
        WiseTelecomNodesQueueStructs.QueMemberWithId[] memory _members
    )
        internal
        view
    {
        _assertCore(
            _oldQue,
            _newQue,
            _members,
            true
        );
    }

    /**
     * @dev Live-verification entry: identical to {assertParity} EXCEPT
     * it omits the getAllOrders* order-list views. Those walk id
     * 0..earliestValid inside the contract, which against a REMOTE live
     * diamond (a forge-script fork) is one lazy storage fetch per slot -
     * ~earliestValid*4 round trips, impractical on high-domain legs
     * (e.g. arb-usdt inc=0 has earliestValid 11525). Every retained
     * check touches only the live linked list or a bounded slot set, so
     * it stays cheap against a remote contract. Order-list equality is
     * proven elsewhere: byte-identically in the W2 fork test, and live
     * by a direct getAllOrdersOverall staticcall byte-compare (the node
     * executes the walk locally in one call) - and getAllOrdersfromAddress
     * equality follows, being a deterministic member-filter of the same
     * active-order set.
     */
    function assertParityBounded(
        address _oldQue,
        address _newQue,
        WiseTelecomNodesQueueStructs.QueMemberWithId[] memory _members
    )
        internal
        view
    {
        _assertCore(
            _oldQue,
            _newQue,
            _members,
            false
        );
    }

    function _assertCore(
        address _oldQue,
        address _newQue,
        WiseTelecomNodesQueueStructs.QueMemberWithId[] memory _members,
        bool _includeOrderLists
    )
        private
        view
    {
        require(
            _oldQue.code.length > 0,
            "DiamondQueViewParity: old que has no code"
        );

        require(
            _newQue.code.length > 0,
            "DiamondQueViewParity: new que has no code"
        );

        Sweep memory s;
        s.incentives = _standardIncentives();

        _requireGlobalsMatch(
            _oldQue,
            _newQue,
            s
        );

        _requirePerIncentiveGettersMatch(
            _oldQue,
            _newQue,
            s
        );

        _requireMemberSlotsMatch(
            _oldQue,
            _newQue,
            s,
            _members
        );

        _requireDerivedViewsMatch(
            _oldQue,
            _newQue,
            s
        );

        if (_includeOrderLists) {
            _requireOrderListsMatch(
                _newQue,
                s,
                _members
            );
        }

        _requireOutOfDomainZero(
            _oldQue,
            _newQue,
            s
        );
    }

    // ---- globals ----

    function _requireGlobalsMatch(
        address _oldQue,
        address _newQue,
        Sweep memory _s
    )
        private
        view
    {
        _same(
            _oldQue,
            _newQue,
            abi.encodeWithSignature("totalActiveOrders()"),
            "totalActiveOrders"
        );

        _same(
            _oldQue,
            _newQue,
            abi.encodeWithSignature("minDepositAmount()"),
            "minDepositAmount"
        );

        _same(
            _oldQue,
            _newQue,
            abi.encodeWithSignature("negativeIncentivesNotAllowed()"),
            "negativeIncentivesNotAllowed"
        );

        (
            bool ok,
            bytes memory ret
        ) = _newQue.staticcall(
            abi.encodeWithSignature("minDepositAmount()")
        );

        require(
            ok && ret.length == 32,
            "DiamondQueViewParity: minDepositAmount read failed"
        );

        _s.minDepositAmount = abi.decode(
            ret,
            (uint256)
        );
    }

    // ---- per-incentive getters ----

    function _requirePerIncentiveGettersMatch(
        address _oldQue,
        address _newQue,
        Sweep memory _s
    )
        private
        view
    {
        for (uint256 i; i < _s.incentives.length; ++i) {

            int256 inc = _s.incentives[i];

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature("earliestValidQueMemberByIncentive(int256)", inc),
                _lbl("earliestValidQueMemberByIncentive/", inc)
            );

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature("currentOrderIdByIncentive(int256)", inc),
                _lbl("currentOrderIdByIncentive/", inc)
            );

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature("activeOrderCountByIncentive(int256)", inc),
                _lbl("activeOrderCountByIncentive/", inc)
            );

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature("incentiveAllowed(int256)", inc),
                _lbl("incentiveAllowed/", inc)
            );

            (
                bool ok,
                bytes memory ret
            ) = _newQue.staticcall(
                abi.encodeWithSignature("earliestValidQueMemberByIncentive(int256)", inc)
            );

            require(
                ok && ret.length == 32,
                "DiamondQueViewParity: earliestValid read failed"
            );

            _s.earliestValid[i] = abi.decode(
                ret,
                (uint256)
            );
        }
    }

    // ---- member slots ----

    function _requireMemberSlotsMatch(
        address _oldQue,
        address _newQue,
        Sweep memory _s,
        WiseTelecomNodesQueueStructs.QueMemberWithId[] memory _members
    )
        private
        view
    {
        for (uint256 j; j < _members.length; ++j) {

            WiseTelecomNodesQueueStructs.QueMemberWithId memory m = _members[j];

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature(
                    "QueMemberByIdAndIncentive(uint256,int256)",
                    m.memberId,
                    m.incentive
                ),
                _lbl2("QueMemberByIdAndIncentive/", m.incentive, m.memberId)
            );

            if (m.amount > 0) {
                uint256 idx = _incentiveIndex(
                    _s,
                    m.incentive
                );

                _s.liquidity[idx] += m.amount;
                _s.totalLiquidity += m.amount;
            }
        }
    }

    // ---- derived views ----

    function _requireDerivedViewsMatch(
        address _oldQue,
        address _newQue,
        Sweep memory _s
    )
        private
        view
    {
        for (uint256 i; i < _s.incentives.length; ++i) {
            _requirePerIncentiveDerived(
                _oldQue,
                _newQue,
                _s.incentives[i],
                _amountGrid(
                    _s.liquidity[i],
                    _s.minDepositAmount
                )
            );
        }

        int256[2] memory extra = [
            int256(750),
            int256(-750)
        ];

        for (uint256 i; i < extra.length; ++i) {
            _requirePerIncentiveDerived(
                _oldQue,
                _newQue,
                extra[i],
                _amountGrid(
                    0,
                    _s.minDepositAmount
                )
            );
        }

        _requireGlobalDerived(
            _oldQue,
            _newQue,
            _amountGrid(
                _s.totalLiquidity,
                _s.minDepositAmount
            )
        );

        _requireDiscountMatch(
            _oldQue,
            _newQue,
            _s
        );
    }

    function _requirePerIncentiveDerived(
        address _oldQue,
        address _newQue,
        int256 _incentive,
        uint256[7] memory _grid
    )
        private
        view
    {
        for (uint256 j; j < _grid.length; ++j) {

            uint256 amount = _grid[j];

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature(
                    "getFulfillmentPlanForIncentive(uint256,int256,uint256)",
                    amount,
                    _incentive,
                    uint256(0)
                ),
                _lbl2("getFulfillmentPlanForIncentive/0/", _incentive, amount)
            );

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature(
                    "getFulfillmentPlanForIncentive(uint256,int256,uint256)",
                    amount,
                    _incentive,
                    uint256(100)
                ),
                _lbl2("getFulfillmentPlanForIncentive/100/", _incentive, amount)
            );

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature(
                    "_solveForAmountWithIncentive(uint256,int256)",
                    amount,
                    _incentive
                ),
                _lbl2("_solveForAmountWithIncentive/", _incentive, amount)
            );
        }
    }

    function _requireGlobalDerived(
        address _oldQue,
        address _newQue,
        uint256[7] memory _grid
    )
        private
        view
    {
        for (uint256 j; j < _grid.length; ++j) {

            uint256 amount = _grid[j];

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature("solveForAmount(uint256)", amount),
                _lbl1("solveForAmount/", amount)
            );

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature("predictCostForTokens(uint256)", amount),
                _lbl1("predictCostForTokens/", amount)
            );

            _same(
                _oldQue,
                _newQue,
                abi.encodeWithSignature("predictTokensForCost(uint256)", amount),
                _lbl1("predictTokensForCost/", amount)
            );
        }
    }

    function _requireDiscountMatch(
        address _oldQue,
        address _newQue,
        Sweep memory _s
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

        for (uint256 i; i < _s.incentives.length; ++i) {
            for (uint256 j; j < amounts.length; ++j) {
                _same(
                    _oldQue,
                    _newQue,
                    abi.encodeWithSignature(
                        "predictDiscountedAmount(uint256,int256)",
                        amounts[j],
                        _s.incentives[i]
                    ),
                    _lbl2("predictDiscountedAmount/", _s.incentives[i], amounts[j])
                );
            }
        }

        int256[2] memory extra = [
            int256(750),
            int256(-750)
        ];

        for (uint256 i; i < extra.length; ++i) {
            for (uint256 j; j < amounts.length; ++j) {
                _same(
                    _oldQue,
                    _newQue,
                    abi.encodeWithSignature(
                        "predictDiscountedAmount(uint256,int256)",
                        amounts[j],
                        extra[i]
                    ),
                    _lbl2("predictDiscountedAmount/", extra[i], amounts[j])
                );
            }
        }
    }

    // ---- order-list views (built from seeded snapshot) ----

    function _requireOrderListsMatch(
        address _newQue,
        Sweep memory _s,
        WiseTelecomNodesQueueStructs.QueMemberWithId[] memory _members
    )
        private
        view
    {
        _requireOrderListCall(
            _newQue,
            abi.encodeWithSignature("getAllOrdersOverall()"),
            _s,
            _members,
            address(0),
            false,
            "getAllOrdersOverall"
        );

        for (uint256 j; j < _members.length; ++j) {

            if (_members[j].amount == 0) {
                continue;
            }

            address user = _members[j].member;

            _requireOrderListCall(
                _newQue,
                abi.encodeWithSignature("getAllOrdersfromAddress(address)", user),
                _s,
                _members,
                user,
                true,
                _lblAddr("getAllOrdersfromAddress/", user)
            );
        }

        _requireOrderListCall(
            _newQue,
            abi.encodeWithSignature("getAllOrdersfromAddress(address)", NEVER_MEMBER),
            _s,
            _members,
            NEVER_MEMBER,
            true,
            "getAllOrdersfromAddress/never"
        );
    }

    function _requireOrderListCall(
        address _newQue,
        bytes memory _callData,
        Sweep memory _s,
        WiseTelecomNodesQueueStructs.QueMemberWithId[] memory _members,
        address _user,
        bool _checkUser,
        string memory _label
    )
        private
        view
    {
        (
            bool ok,
            bytes memory ret
        ) = _newQue.staticcall(
            _callData
        );

        require(
            ok,
            string.concat("DiamondQueViewParity: order list call failed ", _label)
        );

        require(
            keccak256(ret) == keccak256(
                _buildExpectedOrders(
                    _s,
                    _members,
                    _user,
                    _checkUser
                )
            ),
            string.concat("DiamondQueViewParity: order list mismatch ", _label)
        );
    }

    function _buildExpectedOrders(
        Sweep memory _s,
        WiseTelecomNodesQueueStructs.QueMemberWithId[] memory _members,
        address _user,
        bool _checkUser
    )
        private
        pure
        returns (bytes memory)
    {
        uint256 count;

        for (uint256 j; j < _members.length; ++j) {
            if (_orderIncluded(_s, _members[j], _user, _checkUser)) {
                ++count;
            }
        }

        WiseTelecomNodesQueueStructs.QueMember[] memory orders = new WiseTelecomNodesQueueStructs.QueMember[](count);
        int256[] memory incs = new int256[](count);

        uint256 idx;

        for (uint256 j; j < _members.length; ++j) {

            if (!_orderIncluded(_s, _members[j], _user, _checkUser)) {
                continue;
            }

            orders[idx] = WiseTelecomNodesQueueStructs.QueMember({
                member:      _members[j].member,
                amount:      _members[j].amount,
                tailPointer: _members[j].tailPointer,
                headPointer: _members[j].headPointer
            });

            incs[idx] = _members[j].incentive;

            ++idx;
        }

        return abi.encode(
            orders,
            incs
        );
    }

    function _orderIncluded(
        Sweep memory _s,
        WiseTelecomNodesQueueStructs.QueMemberWithId memory _m,
        address _user,
        bool _checkUser
    )
        private
        pure
        returns (bool)
    {
        if (_m.amount == 0) {
            return false;
        }

        if (_checkUser ? _m.member != _user : _m.member == address(0)) {
            return false;
        }

        for (uint256 i; i < _s.incentives.length; ++i) {
            if (_s.incentives[i] == _m.incentive) {
                return _m.memberId < _s.earliestValid[i];
            }
        }

        return false;
    }

    // ---- out-of-domain probes ----

    function _requireOutOfDomainZero(
        address _oldQue,
        address _newQue,
        Sweep memory _s
    )
        private
        view
    {
        for (uint256 i; i < _s.incentives.length; ++i) {

            _requireSlotZeroOnBoth(
                _oldQue,
                _newQue,
                _s.earliestValid[i] + 1,
                _s.incentives[i]
            );

            _requireSlotZeroOnBoth(
                _oldQue,
                _newQue,
                _s.earliestValid[i] + FAR_OUT_OF_DOMAIN_OFFSET,
                _s.incentives[i]
            );
        }
    }

    function _requireSlotZeroOnBoth(
        address _oldQue,
        address _newQue,
        uint256 _id,
        int256 _incentive
    )
        private
        view
    {
        bytes memory callData = abi.encodeWithSignature(
            "QueMemberByIdAndIncentive(uint256,int256)",
            _id,
            _incentive
        );

        _same(
            _oldQue,
            _newQue,
            callData,
            _lbl2("outOfDomainSlot/", _incentive, _id)
        );

        (
            bool ok,
            bytes memory ret
        ) = _oldQue.staticcall(
            callData
        );

        require(
            ok && ret.length == 128,
            "DiamondQueViewParity: out-of-domain read failed"
        );

        (
            address member,
            uint256 amount,
            uint256 tail,
            uint256 head
        ) = abi.decode(
            ret,
            (address, uint256, uint256, uint256)
        );

        require(
            member == address(0) && amount == 0 && tail == 0 && head == 0,
            _lbl2("DiamondQueViewParity: out-of-domain slot not empty ", _incentive, _id)
        );
    }

    // ---- core comparator ----

    function _same(
        address _oldQue,
        address _newQue,
        bytes memory _callData,
        string memory _label
    )
        private
        view
    {
        (
            bool okOld,
            bytes memory retOld
        ) = _oldQue.staticcall(
            _callData
        );

        (
            bool okNew,
            bytes memory retNew
        ) = _newQue.staticcall(
            _callData
        );

        require(
            okOld == okNew,
            string.concat("DiamondQueViewParity: success mismatch ", _label)
        );

        require(
            keccak256(retOld) == keccak256(retNew),
            string.concat("DiamondQueViewParity: returndata mismatch ", _label)
        );
    }

    // ---- helpers ----

    function _incentiveIndex(
        Sweep memory _s,
        int256 _incentive
    )
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < _s.incentives.length; ++i) {
            if (_s.incentives[i] == _incentive) {
                return i;
            }
        }

        revert("DiamondQueViewParity: non-standard incentive in snapshot");
    }

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

    function _lbl(
        string memory _prefix,
        int256 _v
    )
        private
        pure
        returns (string memory)
    {
        return string.concat(
            _prefix,
            _toStringInt(_v)
        );
    }

    function _lbl1(
        string memory _prefix,
        uint256 _v
    )
        private
        pure
        returns (string memory)
    {
        return string.concat(
            _prefix,
            _toStringUint(_v)
        );
    }

    function _lbl2(
        string memory _prefix,
        int256 _a,
        uint256 _b
    )
        private
        pure
        returns (string memory)
    {
        return string.concat(
            _prefix,
            _toStringInt(_a),
            "/",
            _toStringUint(_b)
        );
    }

    function _lblAddr(
        string memory _prefix,
        address _a
    )
        private
        pure
        returns (string memory)
    {
        return string.concat(
            _prefix,
            _toStringUint(uint256(uint160(_a)))
        );
    }

    function _toStringUint(
        uint256 _value
    )
        private
        pure
        returns (string memory)
    {
        if (_value == 0) {
            return "0";
        }

        uint256 temp = _value;
        uint256 digits;

        while (temp != 0) {
            ++digits;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);

        while (_value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + _value % 10));
            _value /= 10;
        }

        return string(buffer);
    }

    function _toStringInt(
        int256 _value
    )
        private
        pure
        returns (string memory)
    {
        if (_value < 0) {
            return string.concat(
                "-",
                _toStringUint(uint256(-_value))
            );
        }

        return _toStringUint(
            uint256(_value)
        );
    }
}
