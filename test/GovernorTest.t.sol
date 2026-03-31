// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/FinalGovernor.sol"; // 指向你的合约路径
import "./mocks/MockToken.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract GovernorTest is Test {
    FinalGovernor governor;
    TimelockController timelock;
    MockToken tokenA;
    MockToken tokenB;

    address admin = address(1);
    address proposer = address(2);
    address voterAlice = address(3);
    address voterBob = address(4);

    uint256 constant INITIAL_SUPPLY = 10000 ether;

    function setUp() public {
        vm.startPrank(admin);

        // 1. 部署代币
        tokenA = new MockToken("Token A", "TK_A");
        tokenB = new MockToken("Token B", "TK_B");

        // 2. 部署 Timelock (设置延迟为 1天)
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        timelock = new TimelockController(1 days, proposers, executors, admin);

        // 3. 部署 Governor (使用 UUPS 代理模式)
        FinalGovernor implementation = new FinalGovernor();
        bytes memory initData = abi.encodeWithSelector(
            FinalGovernor.initialize.selector,
            tokenA,
            tokenB,
            timelock
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        governor = FinalGovernor(payable(address(proxy)));

        // 4. 设置 Timelock 权限：Governor 是唯一的提议者
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // 任何人都可以执行

        vm.stopPrank();

        // 5. 分发代币并【必须执行委托】才能激活投票权
        _setupVoters();
    }

    function _setupVoters() internal {
        // Alice: 1000 A, 10 B (失衡)
        tokenA.mint(voterAlice, 1000 ether);
        tokenB.mint(voterAlice, 10 ether);

        // Bob: 10 A, 1000 B (失衡)
        tokenA.mint(voterBob, 10 ether);
        tokenB.mint(voterBob, 1000 ether);

        // Proposer: 100 A (刚好够发起提案，假设 threshold 是 0)
        tokenA.mint(proposer, 100 ether);

        vm.prank(voterAlice);
        tokenA.delegate(voterAlice);
        vm.prank(voterAlice);
        tokenB.delegate(voterAlice);
        vm.prank(voterBob);
        tokenA.delegate(voterBob);
        vm.prank(voterBob);
        tokenB.delegate(voterBob);
        vm.prank(proposer);
        tokenA.delegate(proposer);

        vm.roll(block.number + 1); // 推进一个区块以激活快照
    }

    // --- 测试 1: 熔断器是否生效 ---
    function testRevertOnStandardGetVotes() public {
        vm.expectRevert("Use getVotesA/B");
        governor.getVotes(voterAlice, block.number - 1);
    }

    // --- 测试 2: 发起提案权限 ---
    function testProposeThreshold() public {
        address poorUser = address(9);
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(tokenA);
        values[0] = 0;
        calldatas[0] = "";

        // 没有币的人发起会失败
        vm.prank(poorUser);
        vm.expectRevert(); // 会触发我们重写的 threshold 检查
        governor.propose(targets, values, calldatas, "Test Proposal");

        // 有 A 币的人发起会成功 (即使他没有 B 币)
        vm.prank(proposer);
        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            "Test Proposal"
        );
        assertNotEq(proposalId, 0);
    }

    // --- 测试 3: 核心计票逻辑 Min(A, B) ---
    function testDualTokenMinLogic() public {
        // 1. 发起提案
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(0);
        values[0] = 0;
        calldatas[0] = "";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            "Min Logic Test"
        );

        // 2. 等待投票延迟 (Voting Delay)
        vm.roll(block.number + governor.votingDelay() + 1);

        // 3. 投票
        // Alice 投赞成：A=1000, B=10
        vm.prank(voterAlice);
        governor.castVote(proposalId, 1);

        // Bob 投赞成：A=10, B=1000
        vm.prank(voterBob);
        governor.castVote(proposalId, 1);

        // 4. 检查结果
        // 统计：
        // Total For A = 1000 + 10 = 1010
        // Total For B = 10 + 1000 = 1010
        // Effective For C = Min(1010, 1010) = 1010

        (, uint256 forVotes, ) = governor.proposalVotes(proposalId);

        console.log("Effective For Votes:", forVotes / 1e18);
        assertEq(forVotes, 1010 ether);
    }

    // --- 测试 4: 极端失衡情况 ---
    function testExtremeImbalance() public {
        // 创建一个只有 Token A 的巨鲸
        address whaleA = address(10);
        tokenA.mint(whaleA, 1000000 ether);
        vm.prank(whaleA);
        tokenA.delegate(whaleA);
        vm.roll(block.number + 1);

        // 发起提案
        address[] memory targets = new address[](1);
        vm.prank(proposer);
        uint256 proposalId = governor.propose(
            targets,
            new uint256[](1),
            new bytes[](1),
            "Whale Test"
        );

        vm.roll(block.number + governor.votingDelay() + 1);

        // 巨鲸投票
        vm.prank(whaleA);
        governor.castVote(proposalId, 1);

        // 即使 A 投了 100万票，因为 B 是 0，Min(100W, 0) 应该等于 0
        (, uint256 forVotes, ) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 0);
        console.log("Whale with only Token A effective votes:", forVotes);
    }
}
