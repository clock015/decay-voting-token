// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DecayVotesToken.sol"; // 假设你的文件名是这个

contract DecayVotesTokenTest is Test {
    DecayVotesToken public token;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    uint256 public constant INITIAL_SUPPLY = 1000_000e18;
    uint256 public constant HALF_LIFE = 1 days; // 设置半衰期为1天

    function setUp() public {
        token = new DecayVotesToken(
            "Decay Token",
            "DECAY",
            1000_000, // 1M tokens
            HALF_LIFE
        );
        // 分发代币
        token.transfer(alice, 100e18);
        token.transfer(bob, 100e18);
    }

    // --- 1. 基础衰减测试 ---

    function test_BalanceDecayOverTime() public {
        uint256 startBalance = token.balanceOf(alice);
        assertEq(startBalance, 100e18);

        // 时间经过 1 个半衰期 (1天)
        vm.warp(block.timestamp + HALF_LIFE);

        // 余额应该衰减到 50%
        // 注意：由于转账过程可能消耗了极少量秒数，这里使用近似匹配
        assertApproxEqAbs(token.balanceOf(alice), 50e18, 0.001e18);

        // 时间再经过 1 个半衰期 (共2天)
        vm.warp(block.timestamp + HALF_LIFE);
        assertApproxEqAbs(token.balanceOf(alice), 25e18, 0.001e18);
    }

    // --- 2. 刷新攻击测试 (Anti-Refresh) ---

    function test_SelfTransferDoesNotResetDecay() public {
        vm.warp(block.timestamp + HALF_LIFE);
        uint256 decayedBalance = token.balanceOf(alice);
        assertApproxEqAbs(decayedBalance, 50e18, 0.001e18);

        // Alice 尝试转账给自己，试图“刷新”余额回到 100
        vm.prank(alice);
        token.transfer(alice, decayedBalance);

        // 转账后的余额应该依然是衰减后的值，而不是 100
        assertApproxEqAbs(token.balanceOf(alice), decayedBalance, 0.001e18);
    }

    // --- 3. 委托逻辑测试 ---

    function test_DelegationAndVotes() public {
        // Alice 委托给 Charlie
        vm.prank(alice);
        token.delegate(charlie);

        // 初始投票权
        assertEq(token.getVotes(charlie), 100e18);

        // 经过一个半衰期
        vm.warp(block.timestamp + HALF_LIFE);

        // Charlie 的受托投票权应该也衰减了
        assertApproxEqAbs(token.getVotes(charlie), 50e18, 0.001e18);

        // Bob 也委托给 Charlie
        vm.prank(bob);
        token.delegate(charlie);

        // Charlie 现在的投票权 = Alice的衰减值 + Bob刚转入的衰减值
        // 50 (Alice) + 50 (Bob) = 100
        assertApproxEqAbs(token.getVotes(charlie), 100e18, 0.001e18);
    }

    // --- 4. 历史快照测试 (核心：对接 Governor) ---

    function test_PastVotesConsistency() public {
        vm.prank(alice);
        token.delegate(charlie);
        uint256 t0 = block.timestamp;

        vm.warp(block.timestamp + 12 hours);
        uint256 t1 = block.timestamp;
        uint256 expectedVotesT1 = token.getVotes(charlie);

        vm.warp(block.timestamp + 1 hours);

        // 修复点：先获取余额，确保 prank 作用于 transfer
        uint256 aliceBal = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, aliceBal);

        // 现在的投票权应该是 0
        assertApproxEqAbs(token.getVotes(charlie), 0, 1e15);

        // 历史快照依然有效
        assertEq(token.getPastVotes(charlie, t1), expectedVotesT1);
        assertEq(token.getPastVotes(charlie, t0), 100e18);
    }

    // --- 5. 总供应量衰减测试 ---

    function test_TotalSupplyDecay() public {
        uint256 initialTotal = token.totalSupply();
        vm.warp(block.timestamp + HALF_LIFE);

        // 总供应量也应该减半
        assertApproxEqAbs(token.totalSupply(), initialTotal / 2, 0.01e18);
    }

    // --- 6. 边缘情况：超长衰减 ---

    function test_LongTermDecayToZero() public {
        // 经过 140 倍半衰期 (超过代码中硬编码的 130 阈值)
        vm.warp(block.timestamp + (140 * HALF_LIFE));

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }
}
