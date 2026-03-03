// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DecayVotingToken.sol"; // 请确保路径指向你的合约文件

contract DecayVotingTokenTest is Test {
    DecayVotingToken public token;

    // 测试账户
    address owner = address(0x1);
    address leaderA = address(0x2);
    address leaderB = address(0x3);
    address follower = address(0x4);
    address recipient = address(0x5);

    uint256 constant INITIAL_SUPPLY = 1000_000; // 100万个
    uint256 constant HALF_LIFE = 1 days; // 半衰期1天
    uint256 constant DECIMALS = 18;

    function setUp() public {
        // 以 owner 身份部署
        vm.startPrank(owner);
        token = new DecayVotingToken(
            "Decay Token",
            "DECAY",
            INITIAL_SUPPLY,
            HALF_LIFE
        );

        // 分发代币：每个账户 1000 个
        uint256 gift = 1000 * 10 ** DECIMALS;
        token.transfer(leaderA, gift);
        token.transfer(leaderB, gift);
        token.transfer(follower, gift);
        vm.stopPrank();
    }

    // --- 1. 基础衰减测试 ---

    function test_BalanceDecayOverTime() public {
        uint256 startBal = token.balanceOf(follower);

        // 时间流逝 1 天（一个半衰期）
        vm.warp(block.timestamp + HALF_LIFE);

        uint256 endBal = token.balanceOf(follower);

        // 验证：余额减半，允许 0.001 token 的计算误差
        assertApproxEqAbs(endBal, startBal / 2, 1e15);
    }

    // --- 2. 意见领袖 (OL) 资格测试 ---

    function test_BecomeOpinionLeader() public {
        vm.prank(leaderA);
        token.becomeOpinionLeader();
        assertTrue(token.isOpinionLeader(leaderA));
    }

    function test_RevertWhen_OLFollowsSomeone() public {
        // 1. 先让 leaderB 成为领袖（这样才能通过第一个 require 检查）
        vm.prank(leaderB);
        token.becomeOpinionLeader();

        // 2. 再让 leaderA 成为领袖
        vm.prank(leaderA);
        token.becomeOpinionLeader();

        // 3. 此时 leaderA 尝试跟随 leaderB
        vm.prank(leaderA);
        vm.expectRevert("Opinion Leader cannot follow others");
        token.follow(leaderB); // 此时会由于 leaderA 是 OL 而触发预期的报错
    }

    function test_RevertWhen_FollowingNonOL() public {
        // follower 尝试跟随一个还没注册成 OL 的地址
        vm.prank(follower);
        vm.expectRevert("Target is not an Opinion Leader");
        token.follow(leaderA);
    }

    // --- 3. 投票跟随 (Follow) 逻辑测试 ---

    function test_FollowIncreasesLeaderVotes() public {
        vm.prank(leaderA);
        token.becomeOpinionLeader();

        uint256 followerBal = token.balanceOf(follower);
        uint256 leaderBal = token.balanceOf(leaderA);

        vm.prank(follower);
        token.follow(leaderA);

        // 领袖的总投票权 = 自己的余额 + 跟随者的余额
        assertEq(token.getVotes(leaderA), leaderBal + followerBal);
    }

    function test_VotesDecayInSync() public {
        vm.prank(leaderA);
        token.becomeOpinionLeader();
        vm.prank(follower);
        token.follow(leaderA);

        uint256 totalVotesStart = token.getVotes(leaderA);

        // 经过 1 天
        vm.warp(block.timestamp + HALF_LIFE);

        // 总投票权也应该减半
        assertApproxEqAbs(token.getVotes(leaderA), totalVotesStart / 2, 1e15);
    }

    // --- 4. 动态转账逻辑测试 (最关键) ---

    function test_TransferUpdatesLeaderVotesAutomatically() public {
        // 1. 设置：LeaderA 被 follower 跟随
        vm.prank(leaderA);
        token.becomeOpinionLeader();
        vm.prank(follower);
        token.follow(leaderA);

        uint256 leaderVotesBefore = token.getVotes(leaderA);
        uint256 transferAmount = 100 * 10 ** DECIMALS;

        // 2. 动作：follower 向外转账
        vm.prank(follower);
        token.transfer(recipient, transferAmount);

        // 3. 验证：LeaderA 的投票权自动减少了 100
        assertApproxEqAbs(
            token.getVotes(leaderA),
            leaderVotesBefore - transferAmount,
            1e15
        );
    }

    function test_UnfollowRestoresLeaderVotes() public {
        vm.prank(leaderA);
        token.becomeOpinionLeader();
        vm.prank(follower);
        token.follow(leaderA);

        // follower 取消跟随
        vm.prank(follower);
        token.unfollow();

        // 领袖的投票权回到只有自己余额的状态
        assertEq(token.getVotes(leaderA), token.balanceOf(leaderA));
    }

    // --- 5. 极端情况测试 ---

    function test_ExtremeLongTimeDecay() public {
        // 经过很久很久（150倍半衰期）
        vm.warp(block.timestamp + HALF_LIFE * 150);

        // 应该都变成 0 了，且不会溢出崩溃
        assertEq(token.balanceOf(follower), 0);
        assertEq(token.getVotes(leaderA), 0);
    }

    function test_RevertWhen_FollowSelf() public {
        vm.prank(leaderA);
        token.becomeOpinionLeader();

        // 领袖不能 follow 自己（代码逻辑中禁止 OL follow 任何人）
        vm.prank(leaderA);
        vm.expectRevert("Opinion Leader cannot follow others");
        token.follow(leaderA);
    }
}
