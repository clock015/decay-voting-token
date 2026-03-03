// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import {UD60x18, ud, convert} from "prb-math/UD60x18.sol";

contract DecayVotingToken is Context, IERC20, IERC20Metadata {
    string private _name;
    string private _symbol;
    uint256 public immutable halfLife;

    struct AccountState {
        uint256 lastBalance; // 上次结算时的余额
        uint32 lastUpdateTime; // 上次结算的时间戳
    }

    mapping(address => AccountState) private _states;
    mapping(address => mapping(address => uint256)) private _allowances;

    // --- 投票与委托相关变量 ---

    // 意见领袖状态
    mapping(address => bool) public isOpinionLeader;
    // 用户当前 follow 的对象
    mapping(address => address) public following;
    // 意见领袖收到的受托总票数（衰减追踪）
    mapping(address => AccountState) private _delegatedStates;

    AccountState private _totalState;

    event Follow(address indexed follower, address indexed leader);
    event Unfollow(address indexed follower, address indexed leader);
    event NewOpinionLeader(address indexed leader);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        uint256 halfLifeSeconds
    ) {
        _name = name_;
        _symbol = symbol_;
        halfLife = halfLifeSeconds;

        uint256 amount = initialSupply * 10 ** decimals();

        _totalState = AccountState(amount, uint32(block.timestamp));
        _states[_msgSender()] = AccountState(amount, uint32(block.timestamp));

        emit Transfer(address(0), _msgSender(), amount);
    }

    // --- 核心数学逻辑 ---

    function _getDecayedValue(
        uint256 lastValue,
        uint256 lastTime
    ) internal view returns (uint256) {
        if (lastValue == 0 || lastTime >= block.timestamp) return lastValue;
        uint256 elapsed = block.timestamp - lastTime;
        UD60x18 n = convert(elapsed).div(convert(halfLife));
        if (n.unwrap() > 130e18) return 0; // 超过约130倍半衰期趋近于0
        UD60x18 factor = n.exp2();
        return ud(lastValue).div(factor).unwrap();
    }

    // 结算个人余额
    function _settle(address account) internal returns (uint256) {
        uint256 current = _getDecayedValue(
            _states[account].lastBalance,
            _states[account].lastUpdateTime
        );
        _states[account].lastBalance = current;
        _states[account].lastUpdateTime = uint32(block.timestamp);
        return current;
    }

    // 结算委托总额
    function _settleDelegated(address leader) internal returns (uint256) {
        uint256 current = _getDecayedValue(
            _delegatedStates[leader].lastBalance,
            _delegatedStates[leader].lastUpdateTime
        );
        _delegatedStates[leader].lastBalance = current;
        _delegatedStates[leader].lastUpdateTime = uint32(block.timestamp);
        return current;
    }

    function _settleTotalSupply() internal returns (uint256) {
        uint256 current = _getDecayedValue(
            _totalState.lastBalance,
            _totalState.lastUpdateTime
        );
        _totalState.lastBalance = current;
        _totalState.lastUpdateTime = uint32(block.timestamp);
        return current;
    }

    // --- 外部查看函数 ---

    function totalSupply() public view override returns (uint256) {
        return
            _getDecayedValue(
                _totalState.lastBalance,
                _totalState.lastUpdateTime
            );
    }

    function balanceOf(address account) public view override returns (uint256) {
        return
            _getDecayedValue(
                _states[account].lastBalance,
                _states[account].lastUpdateTime
            );
    }

    /**
     * @dev 获取一个地址的总投票权 = 个人余额 + 受托余额
     */
    function getVotes(address account) public view returns (uint256) {
        uint256 personal = balanceOf(account);
        uint256 delegated = _getDecayedValue(
            _delegatedStates[account].lastBalance,
            _delegatedStates[account].lastUpdateTime
        );
        return personal + delegated;
    }

    // --- 意见领袖与委托逻辑 ---

    /**
     * @dev 注册成为意见领袖
     */
    function becomeOpinionLeader() external {
        require(!isOpinionLeader[_msgSender()], "Already an OL");
        require(
            following[_msgSender()] == address(0),
            "Cannot be OL while following others"
        );

        isOpinionLeader[_msgSender()] = true;
        _delegatedStates[_msgSender()].lastUpdateTime = uint32(block.timestamp);

        emit NewOpinionLeader(_msgSender());
    }

    /**
     * @dev Follow 意见领袖
     */
    function follow(address leader) external {
        require(isOpinionLeader[leader], "Target is not an Opinion Leader");
        require(
            !isOpinionLeader[_msgSender()],
            "Opinion Leader cannot follow others"
        );
        require(
            following[_msgSender()] == address(0),
            "Already following someone, unfollow first"
        );
        require(leader != _msgSender(), "Cannot follow self");

        // 结算
        uint256 myBalance = _settle(_msgSender());
        uint256 leaderDelegated = _settleDelegated(leader);

        // 更新状态
        following[_msgSender()] = leader;
        _delegatedStates[leader].lastBalance = leaderDelegated + myBalance;

        emit Follow(_msgSender(), leader);
    }

    /**
     * @dev 取消 Follow
     */
    function unfollow() external {
        address leader = following[_msgSender()];
        require(leader != address(0), "Not following anyone");

        // 结算
        uint256 myBalance = _settle(_msgSender());
        uint256 leaderDelegated = _settleDelegated(leader);

        // 更新状态
        following[_msgSender()] = address(0);

        // 确保不会溢出（由于衰减精度问题，理论上 current 不会超过 leaderDelegated）
        if (leaderDelegated >= myBalance) {
            _delegatedStates[leader].lastBalance = leaderDelegated - myBalance;
        } else {
            _delegatedStates[leader].lastBalance = 0;
        }

        emit Unfollow(_msgSender(), leader);
    }

    // --- ERC20 核心逻辑重写 ---

    function _executeTransfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        require(from != address(0), "Transfer from zero");
        require(to != address(0), "Transfer to zero");

        _settleTotalSupply();
        uint256 fromBalance = _settle(from);
        uint256 toBalance = _settle(to);

        require(fromBalance >= amount, "Exceeds decayed balance");

        // 【关键逻辑】：如果发送者正在 follow 某人，减去该领袖的受托票数
        address fromLeader = following[from];
        if (fromLeader != address(0)) {
            uint256 leaderDel = _settleDelegated(fromLeader);
            _delegatedStates[fromLeader].lastBalance = (leaderDel > amount)
                ? (leaderDel - amount)
                : 0;
        }

        // 【关键逻辑】：如果接收者正在 follow 某人，增加该领袖的受托票数
        address toLeader = following[to];
        if (toLeader != address(0)) {
            uint256 leaderDel = _settleDelegated(toLeader);
            _delegatedStates[toLeader].lastBalance = leaderDel + amount;
        }

        unchecked {
            _states[from].lastBalance = fromBalance - amount;
            _states[to].lastBalance = toBalance + amount;
        }

        emit Transfer(from, to, amount);
    }

    // --- 其他标准函数 ---

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        _executeTransfer(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _executeTransfer(from, to, amount);
        return true;
    }

    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        _allowances[_msgSender()][spender] = amount;
        emit Approval(_msgSender(), spender, amount);
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "Insufficient allowance");
            unchecked {
                _allowances[owner][spender] = currentAllowance - amount;
            }
        }
    }

    function mint(address account, uint256 amount) external {
        // 仅作演示，实际应加权限控制
        _settleTotalSupply();
        uint256 accountBalance = _settle(account);

        address leader = following[account];
        if (leader != address(0)) {
            uint256 leaderDel = _settleDelegated(leader);
            _delegatedStates[leader].lastBalance = leaderDel + amount;
        }

        _totalState.lastBalance += amount;
        _states[account].lastBalance = accountBalance + amount;
        emit Transfer(address(0), account, amount);
    }

    function name() public view override returns (string memory) {
        return _name;
    }
    function symbol() public view override returns (string memory) {
        return _symbol;
    }
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
