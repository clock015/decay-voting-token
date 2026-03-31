// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

// 修复点 1: 在继承列表中必须显式包含 ERC20Permit
contract MockToken is ERC20, ERC20Permit, ERC20Votes {
    // 修复点 2: 构造函数正确调用父类构造器
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) ERC20Permit(name) {}

    // 铸造函数，方便测试
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    // 修复点 3: 必须重载 _update 函数，因为 ERC20 和 ERC20Votes 都实现了它
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    // 修复点 4: 必须重载 nonces 函数，因为 ERC20Permit 和 Nonces (由 Votes 引入) 都实现了它
    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
