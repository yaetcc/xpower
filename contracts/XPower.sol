// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/* ============================================================
   XPower v4 · 三币闭环 DApp 发射台 · 一键部署包（UUPS 可升级 · 全批量）
   资金流：
   - 盲盒开盒：用户指定代币 price×n → 90% 分红池(Mining) / 10% 创建者
   - 组装 PC ：8 类部件各 1 + 10 XPR/台 → 平台收款 0x594c2c32cb60a0d93f0ce1cc9f6088709b50addc
   - 质押挖矿：PC 质押按算力份额分 6h 分红池 → 产出用户指定代币
   - 市场交易：P2P 挂单（项目代币计价 · 零手续费 · 批量）
   v4 增强：
   - assembleWithTier(uint8 tier)：自选品质组装（指定档位 1-5，同价 10 XPR）
   - 批量全量：批量开盒(openBox n 盒) / batchAssemble / batchStake / batchUnstake /
     claim(数组) / batchSellParts / batchSellPCs / batchCancel
   - 抽卡统一走盲盒 XPowerBox（不再有 Circuit.mint 双入口）
   - 官方模板 = 本文件编译产物部署（前端 ABI 与链上严格同源）
   每个合约 = Implementation + ERC1967Proxy（UUPS），升级只换实现，storage 布局向后兼容
   ============================================================ */

interface IERC20 {
    function transferFrom(address s, address r, uint256 a) external returns (bool);
    function transfer(address r, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

// ============ 极简 UUPS 基建（自包含 · 零外部依赖） ============
library StorageSlot {
    struct AddressSlot { address value; }
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly { r.slot := slot }
    }
}
abstract contract Proxy {
    bytes32 private constant _IMPL = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    fallback() external payable { _delegate(StorageSlot.getAddressSlot(_IMPL).value); }
    receive() external payable { _delegate(StorageSlot.getAddressSlot(_IMPL).value); }
    function _delegate(address impl) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let r := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch r case 0 { revert(0, 0) } default { return(0, returndatasize()) }
        }
    }
}
contract ERC1967Proxy is Proxy {
    constructor(address logic, bytes memory data) payable {
        StorageSlot.getAddressSlot(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc).value = logic;
        if (data.length > 0) {
            (bool ok,) = logic.delegatecall(data);
            require(ok, "init fail");
        }
    }
}
abstract contract UUPSBase {
    bytes32 private constant _IMPL = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address private immutable __self = address(this);
    address private _owner;
    uint8 private _initd;
    modifier onlyOwner() { require(msg.sender == _owner, "!owner"); _; }
    modifier onlyProxy() { require(address(this) != __self, "not proxy"); _; }
    function owner() public view returns (address) { return _owner; }
    function _initOwner() internal { _owner = msg.sender; }
    function _markInit() internal { require(_initd == 0, "dup"); _initd = 1; }
    function transferOwnership(address nx) external onlyProxy onlyOwner { _owner = nx; }
    function upgradeToAndCall(address newImpl, bytes memory data) external payable onlyProxy onlyOwner {
        StorageSlot.getAddressSlot(_IMPL).value = newImpl;
        if (data.length > 0) {
            (bool ok,) = newImpl.delegatecall(data);
            require(ok, "upg fail");
        }
    }
    function upgradeTo(address newImpl) external payable onlyProxy onlyOwner {
        StorageSlot.getAddressSlot(_IMPL).value = newImpl;
    }
    function implementation() external view returns (address) { return StorageSlot.getAddressSlot(_IMPL).value; }
}

// ---------- 1/6 部件 ERC-1155（8 类硬件 · 可升级） ----------
contract XPowerParts is UUPSBase {
    mapping(uint256 => mapping(address => uint256)) public bal;
    mapping(address => mapping(address => bool)) public isAppr;
    mapping(address => bool) public minters; // 多铸币方：Circuit / Box / Market
    event TransferSingle(address,address,address,uint256,uint256);
    function initialize() external { _markInit(); _initOwner(); minters[msg.sender] = true; }
    modifier onlyOwner2() { require(minters[msg.sender] || msg.sender == owner(), "!minter"); _; }
    function addMinter(address m) external onlyOwner { minters[m] = true; }
    function removeMinter(address m) external onlyOwner { minters[m] = false; }
    function mint(address to, uint256 t, uint256 amt) external onlyOwner2 { bal[t][to] += amt; emit TransferSingle(msg.sender, address(0), to, t, amt); }
    function burn(address from, uint256 t, uint256 amt) external onlyOwner2 { bal[t][from] -= amt; emit TransferSingle(msg.sender, from, address(0), t, amt); }
    function balanceOf(address a, uint256 t) external view returns (uint256){ return bal[t][a]; }
    function balanceOfBatch(address[] calldata aa, uint256[] calldata tt) external view returns (uint256[] memory r){ r = new uint256[](tt.length); for (uint i = 0; i < tt.length; i++) r[i] = bal[tt[i]][aa[i]]; }
    function setApprovalForAll(address o, bool v) external { isAppr[msg.sender][o] = v; }
    function isApprovedForAll(address a, address o) external view returns (bool){ return isAppr[a][o]; }
}

// ---------- 2/6 组装合约（8 部件 → PC NFT · 可升级 · 批量 + 自选品质） ----------
contract XPowerCircuit is UUPSBase {
    struct PC { uint8 tier; uint32 hashRate; bool staked; }
    IERC20 public xpwr;       // 平台币：组装费
    XPowerParts public parts;
    address public creator;   // 创建者
    address public poolAddr;  // 分红池（= Mining，接收盲盒 90%）
    uint256 public constant ASSEMBLE_FEE = 10 ether; // 10 XPR/台
    address public constant PLAT = 0x594C2C32cB60a0d93F0Ce1CC9f6088709B50aDDC; // 平台收款
    uint256 public lastId;
    mapping(uint256 => PC) public pcs;
    mapping(address => uint256[]) public ownerPCs;
    address public market; // 交易市场（PC 转移授权）
    function initialize(address xpwr_, address parts_, address creator_) external {
        _markInit(); _initOwner();
        xpwr = IERC20(xpwr_); parts = XPowerParts(parts_); creator = creator_;
    }
    function setPoolAddr(address p) external { require(msg.sender == creator || msg.sender == owner(), "!c"); poolAddr = p; }
    function roll() internal view returns (uint256){
        uint256 r = uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp, block.number, msg.sender, lastId, gasleft())));
        return r % 100;
    }
    // 组装：8 类各 1 件 + 10 XPR → PC NFT（档位 1–5 随机）
    function assemble() public {
        for (uint i = 1; i <= 8; i++) parts.burn(msg.sender, i, 1);
        xpwr.transferFrom(msg.sender, PLAT, ASSEMBLE_FEE);
        uint256 id = ++lastId;
        uint8 tier = uint8(1 + roll() % 5);
        uint32 hr = uint32(tier) * uint32(150 + roll() % 50);
        pcs[id] = PC(tier, hr, false);
        ownerPCs[msg.sender].push(id);
    }
    // 自选品质组装：指定档位（1-5，同价 10 XPR）
    function assembleWithTier(uint8 tier) public {
        require(tier >= 1 && tier <= 5, "tier");
        for (uint i = 1; i <= 8; i++) parts.burn(msg.sender, i, 1);
        xpwr.transferFrom(msg.sender, PLAT, ASSEMBLE_FEE);
        uint256 id = ++lastId;
        uint32 hr = uint32(tier) * uint32(150 + roll() % 50);
        pcs[id] = PC(tier, hr, false);
        ownerPCs[msg.sender].push(id);
    }
    // 批量组装（自选品质版：全部按指定档位）
    function batchAssemble(uint256 n) external { for (uint i = 0; i < n; i++) assemble(); }
    function batchAssembleTier(uint256 n, uint8 tier) external { for (uint i = 0; i < n; i++) assembleWithTier(tier); }
    function pcsOfOwner(address a) external view returns (uint256[] memory){ return ownerPCs[a]; }
    function setStaked(uint256 id, bool v) external { require(msg.sender == creator || msg.sender == owner() || msg.sender == poolAddr, "!m"); pcs[id].staked = v; }
    function isOwner(address a, uint256 id) external view returns (bool){ uint256[] memory arr = ownerPCs[a]; for (uint i = 0; i < arr.length; i++) if (arr[i] == id) return true; return false; }
    function setMarket(address m) external { require(msg.sender == creator || msg.sender == owner(), "!c"); market = m; }
    function transferPC(address from, address to, uint256 id) external { require(msg.sender == market || msg.sender == creator, "!auth"); require(!pcs[id].staked, "staked"); uint256[] storage arr = ownerPCs[from]; for (uint i = 0; i < arr.length; i++){ if (arr[i] == id){ arr[i] = arr[arr.length-1]; arr.pop(); break; } } ownerPCs[to].push(id); }
}

// ---------- 3/6 矿池（质押 PC 按算力份额分 6h 分红池 · 可升级 · 批量） ----------
contract XPowerMining is UUPSBase {
    IERC20 public reward;
    XPowerCircuit public circ;
    uint256 public totalShare;
    uint256 public constant EPOCH = 6 hours;
    mapping(uint256 => uint256) public stakeTime;
    mapping(uint256 => uint32) public stakeHash;
    mapping(address => uint256[]) public stakedPCs;
    function stakedPCsOf(address a) external view returns (uint256[] memory){ return stakedPCs[a]; }
    function initialize(address token_, address circ_) external { _markInit(); _initOwner(); reward = IERC20(token_); circ = XPowerCircuit(circ_); }
    function owned(address a, uint256 id) internal view returns (bool ok){ uint256[] memory arr = circ.pcsOfOwner(a); for (uint i = 0; i < arr.length; i++) if (arr[i] == id) return true; }
    function stake(uint256 id) public {
        require(owned(msg.sender, id), "!owner");
        (uint8 _t, uint32 _hr, bool _st) = circ.pcs(id);
        require(!_st, "staked");
        circ.setStaked(id, true);
        stakeTime[id] = block.timestamp; stakeHash[id] = _hr;
        totalShare += stakeHash[id];
        stakedPCs[msg.sender].push(id);
    }
    function batchStake(uint256[] calldata ids) external { for (uint i = 0; i < ids.length; i++) stake(ids[i]); }
    function unstake(uint256 id) public {
        require(owned(msg.sender, id), "!owner");
        circ.setStaked(id, false); totalShare -= stakeHash[id]; stakeHash[id] = 0;
    }
    function batchUnstake(uint256[] calldata ids) external { for (uint i = 0; i < ids.length; i++) unstake(ids[i]); }
    function earned(uint256 id) public view returns (uint256){
        if (stakeHash[id] == 0 || totalShare == 0) return 0;
        uint256 pool = reward.balanceOf(address(this));
        uint256 elapsed = block.timestamp - stakeTime[id]; if (elapsed > EPOCH) elapsed = EPOCH;
        return pool * stakeHash[id] / totalShare * elapsed / EPOCH;
    }
    // 批量领取：按算力份额 + 质押时长分配，领取后重置计时
    function claim(uint256[] calldata ids) external returns (uint256 tot){
        for (uint i = 0; i < ids.length; i++){
            uint256 id = ids[i]; require(owned(msg.sender, id), "!owner");
            uint256 e = earned(id);
            if (e > 0){ reward.transfer(msg.sender, e); tot += e; }
            stakeTime[id] = block.timestamp;
        }
    }
}

// ---------- 4/6 盲盒协议（创建者配置权重 / 价格 / 盒数 · 可升级） ----------
contract XPowerBox is UUPSBase {
    struct Box { address creator; uint256 price; uint256 total; uint256 sold; uint256[8] weights; bool closed; }
    IERC20 public payToken;
    XPowerParts public parts;
    address public poolAddr; // = Mining 合约（收 90%）
    uint256 public boxCount;
    mapping(uint256 => Box) public boxes;
    uint256 public MAX_OPEN; // 单次开盒上限
    function initialize(address token_, address parts_, address pool_, uint256 maxOpen_, uint256 total_, uint256 price_, uint256[8] calldata w_, address creator_) external { _markInit(); _initOwner(); payToken = IERC20(token_); parts = XPowerParts(parts_); poolAddr = pool_; MAX_OPEN = maxOpen_;
        // 代理初始化时自动创建盲盒 #1（规避 Factory 内 createBox 调用问题）
        uint256 s_ = 0; for (uint i_ = 0; i_ < 8; i_++) s_ += w_[i_]; require(s_ > 0, "w"); require(total_ > 0 && total_ <= 10000, "total");
        boxCount = 1; boxes[1] = Box(creator_, price_, total_, 0, w_, false);
    }
    // 创建盲盒（免创建费 · 部署后再创建用）
    function createBox(uint256 total, uint256 price, uint256[8] calldata w) external returns (uint256 id){
        uint256 s = 0; for (uint i = 0; i < 8; i++) s += w[i]; require(s > 0, "w");
        require(total > 0 && total <= 10000, "total");
        id = ++boxCount; boxes[id] = Box(msg.sender, price, total, 0, w, false);
    }
    function setCreator(uint256 id, address c) external onlyOwner { require(id > 0 && id <= boxCount, "id"); boxes[id].creator = c; }
    // 批量开盒：扣 price × n 项目代币 → 90% 池 / 10% 创建者 → 按盲盒权重随机部件
    function openBox(uint256 id, uint256 n) external returns (uint256[] memory r){
        Box storage b = boxes[id]; require(!b.closed && b.sold + n <= b.total, "soldout"); require(n > 0 && n <= MAX_OPEN, "n");
        uint256 cost = b.price * n;
        payToken.transferFrom(msg.sender, b.creator, cost * 10 / 100);
        payToken.transferFrom(msg.sender, poolAddr, cost * 90 / 100);
        r = new uint256[](n);
        for (uint i = 0; i < n; i++){ uint t = rollW(b.weights); parts.mint(msg.sender, t, 1); r[i] = t; }
        b.sold += n;
    }
    function rollW(uint256[8] memory w) internal view returns (uint256){
        uint s; for (uint i = 0; i < 8; i++) s += w[i];
        uint256 r = uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp, block.number, msg.sender, gasleft())));
        if (s == 0) return r % 8 + 1; // 权重和为 0 时按平均概率抽 8 类部件
        r %= s;
        for (uint i = 0; i < 8; i++){ if (r < w[i]) return i + 1; r -= w[i]; }
        return 8;
    }
    function closeBox(uint256 id) external { require(msg.sender == boxes[id].creator, "!c"); boxes[id].closed = true; }
}

// ---------- 5/6 交易市场（P2P 挂单 · 项目代币计价 · 零手续费 · 可升级 · 批量） ----------
contract XPowerMarket is UUPSBase {
    struct Order { address seller; uint8 kind; uint256 sub; uint256 qty; uint256 price; bool active; } // kind: 1=部件 2=PC
    IERC20 public payToken; XPowerParts public parts; XPowerCircuit public circ;
    uint256 public orderCount; mapping(uint256 => Order) public orders;
    function initialize(address token_, address parts_, address circ_) external { _markInit(); _initOwner(); payToken = IERC20(token_); parts = XPowerParts(parts_); circ = XPowerCircuit(circ_); }
    function sellPart(uint256 t, uint256 qty, uint256 price) public { require(qty > 0 && price > 0, "!"); parts.burn(msg.sender, t, qty); orders[++orderCount] = Order(msg.sender, 1, t, qty, price, true); }
    function sellPC(uint256 id, uint256 price) public { require(price > 0 && circ.isOwner(msg.sender, id), "!"); circ.transferPC(msg.sender, address(this), id); orders[++orderCount] = Order(msg.sender, 2, id, 1, price, true); }
    function buy(uint256 oid) external { Order storage o = orders[oid]; require(o.active && o.seller != msg.sender, "!"); payToken.transferFrom(msg.sender, o.seller, o.price * o.qty); if (o.kind == 1){ parts.mint(msg.sender, o.sub, o.qty); } else { circ.transferPC(address(this), msg.sender, o.sub); } o.active = false; }
    function cancel(uint256 oid) public { Order storage o = orders[oid]; require(o.active && msg.sender == o.seller, "!"); if (o.kind == 1){ parts.mint(msg.sender, o.sub, o.qty); } else { circ.transferPC(address(this), msg.sender, o.sub); } o.active = false; }
    function batchSellParts(uint256[] calldata ts, uint256[] calldata qtys, uint256[] calldata prices) external { require(ts.length == qtys.length && qtys.length == prices.length, "len"); for (uint i = 0; i < ts.length; i++) sellPart(ts[i], qtys[i], prices[i]); }
    function batchSellPCs(uint256[] calldata ids, uint256[] calldata prices) external { require(ids.length == prices.length, "len"); for (uint i = 0; i < ids.length; i++) sellPC(ids[i], prices[i]); }
    function batchCancel(uint256[] calldata oids) external { for (uint i = 0; i < oids.length; i++) cancel(oids[i]); }
}

/* ============ 6/6 平台 Factory：一键部署（项目仅 1 笔签名） ============ */
contract XPowerFactory {
    address public owner;
    address public partsImpl;
    address public circuitImpl;
    address public miningImpl;
    address public boxImpl;
    address public marketImpl;
    event ProjectDeployed(address indexed creator, address parts, address circuit, address mining, address box, address market);
    address[5] public lastProject;
    function getLastProject() external view returns (address[5] memory) { return lastProject; }
    constructor(address[] memory impls) {
        owner = msg.sender;
        require(impls.length == 5, "len");
        partsImpl = impls[0]; circuitImpl = impls[1]; miningImpl = impls[2]; boxImpl = impls[3]; marketImpl = impls[4];
    }
    function setImpls(address[] memory impls) external {
        require(msg.sender == owner, "!owner");
        require(impls.length == 5, "len");
        partsImpl = impls[0]; circuitImpl = impls[1]; miningImpl = impls[2]; boxImpl = impls[3]; marketImpl = impls[4];
    }
    function deployProject(
        address token_, address xpr_, address creator_,
        uint256 openMax_, uint256 total_, uint256 price_,
        uint256[8] memory w_
    ) external returns (address parts_, address circuit_, address mining_, address box_, address market_) {
        parts_ = address(new ERC1967Proxy(partsImpl, abi.encodeCall(XPowerParts.initialize, ())));
        circuit_ = address(new ERC1967Proxy(circuitImpl, abi.encodeCall(XPowerCircuit.initialize, (xpr_, parts_, creator_))));
        mining_ = address(new ERC1967Proxy(miningImpl, abi.encodeCall(XPowerMining.initialize, (token_, circuit_))));
        box_ = address(new ERC1967Proxy(boxImpl, abi.encodeCall(XPowerBox.initialize, (token_, parts_, mining_, openMax_, total_, price_, w_, creator_))));
        market_ = address(new ERC1967Proxy(marketImpl, abi.encodeCall(XPowerMarket.initialize, (token_, parts_, circuit_))));
        XPowerParts(parts_).addMinter(circuit_);
        XPowerParts(parts_).addMinter(box_);
        XPowerParts(parts_).addMinter(market_);
        XPowerCircuit(circuit_).setPoolAddr(mining_);
        XPowerCircuit(circuit_).setMarket(market_);
        XPowerParts(parts_).transferOwnership(creator_);
        XPowerCircuit(circuit_).transferOwnership(creator_);
        XPowerMining(mining_).transferOwnership(creator_);
        XPowerBox(box_).transferOwnership(creator_);
        XPowerMarket(market_).transferOwnership(creator_);
        lastProject = [parts_, circuit_, mining_, box_, market_];
        emit ProjectDeployed(creator_, parts_, circuit_, mining_, box_, market_);
    }
}
