// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/interfaces/IERC6372.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UD60x18, ud, convert} from "prb-math/UD60x18.sol";

contract DecayVotesToken is ERC20, IVotes, IERC6372 {
    using SafeCast for uint256;

    struct AccountState {
        uint224 baseBalance;
        uint32 lastTimestamp;
    }

    struct DecayCheckpoint {
        uint32 fromTimestamp;
        uint224 baseValue;
    }

    uint256 public immutable halfLife;

    mapping(address => AccountState) private _states;
    mapping(address => DecayCheckpoint[]) private _votingCheckpoints;
    DecayCheckpoint[] private _totalSupplyCheckpoints;
    mapping(address => address) private _delegatees;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        uint256 halfLifeSeconds
    ) ERC20(name_, symbol_) {
        halfLife = halfLifeSeconds;
        _mint(msg.sender, initialSupply * 10 ** decimals());
    }

    // --- 数学逻辑 ---

    function _getDecayedValue(
        uint256 value,
        uint256 startTime,
        uint256 targetTime
    ) internal view returns (uint256) {
        if (value == 0 || startTime >= targetTime) return value;
        uint256 elapsed = targetTime - startTime;
        UD60x18 n = convert(elapsed).div(convert(halfLife));
        if (n.unwrap() > 130e18) return 0;
        return ud(value).div(n.exp2()).unwrap();
    }

    // --- ERC20 重写 ---

    function balanceOf(address account) public view override returns (uint256) {
        AccountState memory state = _states[account];
        return
            _getDecayedValue(
                state.baseBalance,
                state.lastTimestamp,
                block.timestamp
            );
    }

    function totalSupply() public view override returns (uint256) {
        if (_totalSupplyCheckpoints.length == 0) return 0;
        DecayCheckpoint memory last = _totalSupplyCheckpoints[
            _totalSupplyCheckpoints.length - 1
        ];
        return
            _getDecayedValue(
                last.baseValue,
                last.fromTimestamp,
                block.timestamp
            );
    }

    function _settle(address account) internal returns (uint256) {
        uint256 current = balanceOf(account);
        _states[account].baseBalance = current.toUint224();
        _states[account].lastTimestamp = uint32(block.timestamp);
        return current;
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // 1. 处理自转账：仅结算，不改变数值
        if (from == to && from != address(0)) {
            _settle(from);
            _updateTotalSupplyCheckpoints(0, true);
            emit Transfer(from, to, amount);
            return;
        }

        // 2. 捕获结算前的状态
        uint256 fromBalance = (from == address(0)) ? 0 : _settle(from);
        uint256 toBalance = (to == address(0)) ? 0 : _settle(to);

        // 3. 更新余额存储
        if (from != address(0)) {
            require(
                fromBalance >= amount,
                "ERC20: transfer amount exceeds decayed balance"
            );
            unchecked {
                _states[from].baseBalance = (fromBalance - amount).toUint224();
            }
        }
        if (to != address(0)) {
            unchecked {
                _states[to].baseBalance = (toBalance + amount).toUint224();
            }
        }

        // 4. 更新供应量检查点
        if (from == address(0)) _updateTotalSupplyCheckpoints(amount, true);
        else if (to == address(0)) _updateTotalSupplyCheckpoints(amount, false);
        else _updateTotalSupplyCheckpoints(0, true);

        // 5. 移动投票权
        _moveVotes(delegates(from), delegates(to), amount);

        emit Transfer(from, to, amount);
    }

    // --- IVotes & IERC6372 实现 ---

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function getVotes(address account) public view override returns (uint256) {
        DecayCheckpoint[] storage ckpts = _votingCheckpoints[account];
        if (ckpts.length == 0) return 0;
        DecayCheckpoint memory last = ckpts[ckpts.length - 1];
        return
            _getDecayedValue(
                last.baseValue,
                last.fromTimestamp,
                block.timestamp
            );
    }

    function getPastVotes(
        address account,
        uint256 timepoint
    ) public view override returns (uint256) {
        require(timepoint < block.timestamp, "DecayVotes: future lookup");
        DecayCheckpoint memory ckpt = _findCheckpoint(
            _votingCheckpoints[account],
            timepoint
        );
        return _getDecayedValue(ckpt.baseValue, ckpt.fromTimestamp, timepoint);
    }

    function getPastTotalSupply(
        uint256 timepoint
    ) public view override returns (uint256) {
        require(timepoint < block.timestamp, "DecayVotes: future lookup");
        DecayCheckpoint memory ckpt = _findCheckpoint(
            _totalSupplyCheckpoints,
            timepoint
        );
        return _getDecayedValue(ckpt.baseValue, ckpt.fromTimestamp, timepoint);
    }

    function delegates(address account) public view override returns (address) {
        return _delegatees[account];
    }

    function delegate(address delegatee) public override {
        address currentDelegate = delegates(msg.sender);
        uint256 delegatorBalance = balanceOf(msg.sender);
        _delegatees[msg.sender] = delegatee;
        emit DelegateChanged(msg.sender, currentDelegate, delegatee);
        _moveVotes(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveVotes(address from, address to, uint256 amount) internal {
        if (from == to || amount == 0) return;
        if (from != address(0)) {
            uint256 prevVotes = getVotes(from);
            uint256 newVotes = prevVotes > amount ? prevVotes - amount : 0;
            _pushCheckpoint(_votingCheckpoints[from], newVotes);
            emit DelegateVotesChanged(from, prevVotes, newVotes);
        }
        if (to != address(0)) {
            uint256 prevVotes = getVotes(to);
            uint256 newVotes = prevVotes + amount;
            _pushCheckpoint(_votingCheckpoints[to], newVotes);
            emit DelegateVotesChanged(to, prevVotes, newVotes);
        }
    }

    function _updateTotalSupplyCheckpoints(uint256 amount, bool add) internal {
        uint256 currentSupply = totalSupply();
        uint256 newSupply = add
            ? currentSupply + amount
            : currentSupply - amount;
        _pushCheckpoint(_totalSupplyCheckpoints, newSupply);
    }

    function _pushCheckpoint(
        DecayCheckpoint[] storage ckpts,
        uint256 newValue
    ) internal {
        uint32 batchTime = uint32(block.timestamp);
        if (
            ckpts.length > 0 &&
            ckpts[ckpts.length - 1].fromTimestamp == batchTime
        ) {
            ckpts[ckpts.length - 1].baseValue = newValue.toUint224();
        } else {
            ckpts.push(
                DecayCheckpoint({
                    fromTimestamp: batchTime,
                    baseValue: newValue.toUint224()
                })
            );
        }
    }

    function _findCheckpoint(
        DecayCheckpoint[] storage ckpts,
        uint256 timepoint
    ) internal view returns (DecayCheckpoint memory) {
        uint256 len = ckpts.length;
        if (len == 0) return DecayCheckpoint(0, 0);
        if (ckpts[len - 1].fromTimestamp <= timepoint) return ckpts[len - 1];
        if (ckpts[0].fromTimestamp > timepoint) return DecayCheckpoint(0, 0);
        uint256 low = 0;
        uint256 high = len - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (ckpts[mid].fromTimestamp <= timepoint) low = mid;
            else high = mid - 1;
        }
        return ckpts[low];
    }

    function delegateBySig(
        address,
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) public pure override {
        revert();
    }
}
