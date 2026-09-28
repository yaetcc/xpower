// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import "forge-std/Test.sol";
import "../src/XPower.sol";

/* XPower v4 全流程验证
   覆盖：一键部署 → 开盒(90/10 分账) → 组装(费入平台) → 自选品质 → 质押 → 领取 →
         市场(挂单/购买/撤单) → 批量(组装/质押/解押/挂单/撤单) → 可升级 */
contract V4FlowTest is Test {
    XPowerParts parts; XPowerCircuit circuit; XPowerMining mining; XPowerBox box; XPowerMarket market; XPowerFactory fac;
    SimpleERC20 token; SimpleERC20 xpr;
    address creator = 0x3e85316251d3DE135F585104F7b9E45d4358104c;
    address player  = address(0xA11CE);
    address buyer   = address(0xB0B);
    address PLAT = 0x594C2C32cB60a0d93F0Ce1CC9f6088709B50aDDC;
    uint256[8] w = [uint256(1),1,1,1,1,1,1,1];

    function setUp() public {
        // 简易代币
        token = new SimpleERC20("PROJ", 18);
        xpr   = new SimpleERC20("XPR", 18);
        // 部署 5 实现
        XPowerParts pImpl = new XPowerParts();
        XPowerCircuit cImpl = new XPowerCircuit();
        XPowerMining mImpl = new XPowerMining();
        XPowerBox bImpl = new XPowerBox();
        XPowerMarket mkImpl = new XPowerMarket();
        address[] memory impls = new address[](5);
        impls[0] = address(pImpl); impls[1] = address(cImpl); impls[2] = address(mImpl); impls[3] = address(bImpl); impls[4] = address(mkImpl);
        fac = new XPowerFactory(impls);
        // 一键部署（创建者签名）
        vm.prank(creator);
        fac.deployProject(address(token), address(xpr), creator, 100, 1000, 10 ether, w);
        address[5] memory lp = fac.getLastProject();
        parts = XPowerParts(lp[0]); circuit = XPowerCircuit(lp[1]); mining = XPowerMining(lp[2]); box = XPowerBox(lp[3]); market = XPowerMarket(lp[4]);
        // 资金
        token.mint(creator, 1e24); token.mint(player, 1e24); token.mint(buyer, 1e24);
        xpr.mint(player, 1e24); xpr.mint(buyer, 1e24);
    }

    function _grantParts(address who, uint256 qtyPerType) internal {
        // 测试辅助：给 who 每种部件 qtyPerType 件（owner=creator 授权测试合约 mint）
        vm.prank(creator); parts.addMinter(address(this));
        for (uint i = 1; i <= 8; i++) parts.mint(who, i, qtyPerType);
    }

    function testDeploy_State() public {
        assertEq(parts.owner(), creator, "parts owner");
        assertEq(circuit.owner(), creator, "circuit owner");
        assertEq(mining.owner(), creator, "mining owner");
        assertEq(box.owner(), creator, "box owner");
        assertEq(market.owner(), creator, "market owner");
        (address cr, uint256 pr, uint256 tl, uint256 sd, bool cl) = box.boxes(1);
        assertEq(cr, creator, "box#1 creator");
        assertEq(pr, 10 ether, "box#1 price");
        assertEq(tl, 1000, "box#1 total");
        assertTrue(parts.minters(address(circuit)), "minter circuit");
        assertTrue(parts.minters(address(box)), "minter box");
        assertTrue(parts.minters(address(market)), "minter market");
        assertEq(address(circuit.poolAddr()), address(mining), "pool");
        assertEq(address(circuit.market()), address(market), "market");
    }

    function testOpenBox_Split() public {
        vm.startPrank(player);
        token.approve(address(box), 1e24);
        uint256 balP0 = token.balanceOf(player);
        uint256 balC0 = token.balanceOf(creator);
        uint256 balM0 = token.balanceOf(address(mining));
        uint256[] memory r = box.openBox(1, 5);
        vm.stopPrank();
        assertEq(r.length, 5, "5 parts");
        uint256 cost = 10 ether * 5;
        assertEq(token.balanceOf(player), balP0 - cost, "player paid full");
        assertEq(token.balanceOf(creator), balC0 + cost * 10 / 100, "creator 10%");
        assertEq(token.balanceOf(address(mining)), balM0 + cost * 90 / 100, "pool 90%");
        // 5 件部件入账
        uint256 got = 0;
        for (uint i = 1; i <= 8; i++) got += parts.balanceOf(player, i);
        assertEq(got, 5, "parts received");
        // sold 更新
        (, , , uint256 sd, ) = box.boxes(1);
        assertEq(sd, 5, "sold 5");
    }

    function testBatchOpenBox() public {
        vm.startPrank(player);
        token.approve(address(box), 1e24);
        uint256[] memory r = box.openBox(1, 20);
        vm.stopPrank();
        assertEq(r.length, 20, "20 parts in one tx");
        assertEq(box.MAX_OPEN(), 100, "max open");
    }

    function testAssemble_FeeToPlatform() public {
        _grantParts(player, 2);
        vm.startPrank(player);
        xpr.approve(address(circuit), 1e24);
        uint256 balX0 = xpr.balanceOf(player);
        uint256 balP0 = xpr.balanceOf(PLAT);
        circuit.assemble();
        vm.stopPrank();
        assertEq(xpr.balanceOf(player), balX0 - 10 ether, "10 XPR paid");
        assertEq(xpr.balanceOf(PLAT), balP0 + 10 ether, "fee to PLAT");
        uint256[] memory ids = circuit.pcsOfOwner(player);
        assertEq(ids.length, 1, "1 PC owned");
        (uint8 tier, uint32 hr, bool st) = circuit.pcs(ids[0]);
        assertTrue(tier >= 1 && tier <= 5, "tier 1-5");
        assertTrue(hr > 0, "hashRate > 0");
        assertFalse(st, "not staked");
    }

    function testAssembleWithTier() public {
        _grantParts(player, 4);
        vm.startPrank(player);
        xpr.approve(address(circuit), 1e24);
        circuit.assembleWithTier(5);
        vm.stopPrank();
        uint256[] memory ids = circuit.pcsOfOwner(player);
        (uint8 tier, , ) = circuit.pcs(ids[0]);
        assertEq(tier, 5, "specified tier 5");
    }

    function testBatchAssemble() public {
        _grantParts(player, 10);
        vm.startPrank(player);
        xpr.approve(address(circuit), 1e24);
        circuit.batchAssemble(3);
        vm.stopPrank();
        assertEq(circuit.pcsOfOwner(player).length, 3, "3 PCs");
        assertEq(xpr.balanceOf(PLAT), 30 ether, "30 XPR to PLAT");
    }

    function testStakeClaim() public {
        _grantParts(player, 2);
        vm.startPrank(player);
        xpr.approve(address(circuit), 1e24);
        circuit.assemble();
        uint256 id = circuit.pcsOfOwner(player)[0];
        // 质押
        mining.batchStake(toArr(id));
        assertEq(mining.stakedPCsOf(player).length, 1, "staked");
        (,, bool st) = circuit.pcs(id);
        assertTrue(st, "staked flag");
        // 分红池注入（模拟玩家开盒产生的 90%）
        token.mint(address(mining), 100 ether);
        vm.warp(block.timestamp + 3 hours);
        // 领取
        uint256 before = token.balanceOf(player);
        mining.claim(toArr(id));
        uint256 afterBal = token.balanceOf(player);
        assertTrue(afterBal > before, "claimed reward");
        vm.stopPrank();
        // 解押
        vm.prank(player);
        mining.batchUnstake(toArr(id));
        (,, bool st2) = circuit.pcs(id);
        assertFalse(st2, "unstaked");
    }

    function testMarket_SellBuy() public {
        // 玩家组装 1 台 PC 挂单卖
        _grantParts(player, 2);
        vm.startPrank(player);
        xpr.approve(address(circuit), 1e24);
        circuit.assemble();
        uint256 pcId = circuit.pcsOfOwner(player)[0];
        market.sellPC(pcId, 5 ether);
        uint256 oid = market.orderCount();
        vm.stopPrank();
        // 买家买
        vm.startPrank(buyer);
        token.approve(address(market), 1e24);
        market.buy(oid);
        vm.stopPrank();
        assertTrue(circuit.isOwner(buyer, pcId), "buyer owns PC");
        assertEq(token.balanceOf(player), 1e24 + 5 ether, "seller got paid"); // 初始1e24+卖价(组装费付的是XPR)
        // 订单失效
        (address s, uint8 k, uint256 sub, uint256 q, uint256 p, bool a) = market.orders(oid);
        assertFalse(a, "order inactive");
    }

    function testMarket_PartCancel() public {
        _grantParts(player, 4);
        vm.startPrank(player);
        market.sellPart(1, 2, 3 ether);
        uint256 oid = market.orderCount();
        market.batchCancel(toArr(oid));
        vm.stopPrank();
        assertEq(parts.balanceOf(player, 1), 4, "parts back on cancel");
        (,, , , , bool a) = market.orders(oid);
        assertFalse(a, "order cancelled");
    }

    function testBatchSellParts() public {
        _grantParts(player, 8);
        uint256[] memory ts = new uint256[](3); ts[0] = 1; ts[1] = 2; ts[2] = 3;
        uint256[] memory qtys = new uint256[](3); qtys[0] = 1; qtys[1] = 1; qtys[2] = 1;
        uint256[] memory prices = new uint256[](3); prices[0] = 1 ether; prices[1] = 2 ether; prices[2] = 3 ether;
        vm.prank(player);
        market.batchSellParts(ts, qtys, prices);
        assertEq(market.orderCount(), 3, "3 orders");
    }

    function testUpgrade_Circuit() public {
        // 部署新实现 → 升级（UUPS）
        XPowerCircuit newImpl = new XPowerCircuit();
        vm.prank(creator);
        circuit.upgradeToAndCall(address(newImpl), "");
        assertEq(circuit.implementation(), address(newImpl), "upgraded");
    }

    function toArr(uint256 a) internal pure returns (uint256[] memory r){ r = new uint256[](1); r[0] = a; }
}

/* 简易 ERC20（测试用） */
contract SimpleERC20 {
    string public name; string public symbol; uint8 public decimals;
    uint256 public totalSupply; mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, uint8 d){ name = n; symbol = n; decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function transfer(address r, uint256 a) external returns (bool){ balanceOf[msg.sender] -= a; balanceOf[r] += a; return true; }
    function transferFrom(address s, address r, uint256 a) external returns (bool){ require(allowance[s][msg.sender] >= a, "al"); allowance[s][msg.sender] -= a; balanceOf[s] -= a; balanceOf[r] += a; return true; }
    function approve(address sp, uint256 a) external returns (bool){ allowance[msg.sender][sp] = a; return true; }
}

