// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/* ============================================================
   XPower v4.1 · 组装费改收 OKB（原生币）
   - XPowerCircuitV2：与原 Circuit storage 布局完全一致（UUPS 可升级替换）
     assemble / assembleWithTier / batchAssemble / batchAssembleTier
     改为收取 0.001 OKB/台（msg.value），原生币直接转发平台收款地址
   - XPRToken：标准无锁 ERC20（可自由转账）
   ============================================================ */

interface IERC20 {
    function transferFrom(address s, address r, uint256 a) external returns (bool);
    function transfer(address r, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

interface IParts {
    function burn(address from, uint256 t, uint256 amt) external;
}

// ============ 极简 UUPS 基建（与原合约一致） ============
library StorageSlot {
    struct AddressSlot { address value; }
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly { r.slot := slot }
    }
}
abstract contract UUPSBase2 {
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

// ---------- 组装合约 V2：收 0.001 OKB/台（原生币） ----------
contract XPowerCircuitV2 is UUPSBase2 {
    struct PC { uint8 tier; uint32 hashRate; bool staked; }
    // === 与原 XPowerCircuit storage 布局一致（禁止调整顺序/删除） ===
    IERC20 public xpwr;       // slot0（保留字段，V2 不再使用）
    IParts public parts;
    address public creator;
    address public poolAddr;
    uint256 public lastId;
    mapping(uint256 => PC) public pcs;
    mapping(address => uint256[]) public ownerPCs;
    address public market;
    // ============================================================
    uint256 public constant ASSEMBLE_FEE = 0.001 ether; // 0.001 OKB/台
    address public constant PLAT = 0x594C2C32cB60a0d93F0Ce1CC9f6088709B50aDDC; // 平台收款

    function initialize(address /*xpwr_*/, address parts_, address creator_) external {
        _markInit(); _initOwner();
        parts = IParts(parts_); creator = creator_;
    }
    function setPoolAddr(address p) external { require(msg.sender == creator || msg.sender == owner(), "!c"); poolAddr = p; }
    function roll() internal view returns (uint256){
        uint256 r = uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp, block.number, msg.sender, lastId, gasleft())));
        return r % 100;
    }
    function _charge() internal {
        require(msg.value >= ASSEMBLE_FEE, "fee");
        (bool ok,) = PLAT.call{value: ASSEMBLE_FEE}("");
        require(ok, "pay fail");
        if (msg.value > ASSEMBLE_FEE) {
            (bool r0,) = msg.sender.call{value: msg.value - ASSEMBLE_FEE}("");
            require(r0, "refund fail");
        }
    }
    // 组装：8 类各 1 件 + 0.001 OKB → PC NFT（档位 1–5 随机）
    function assemble() public payable {
        for (uint i = 1; i <= 8; i++) parts.burn(msg.sender, i, 1);
        _charge();
        uint256 id = ++lastId;
        uint8 tier = uint8(1 + roll() % 5);
        uint32 hr = uint32(tier) * uint32(150 + roll() % 50);
        pcs[id] = PC(tier, hr, false);
        ownerPCs[msg.sender].push(id);
    }
    // 自选品质组装：指定档位（1-5，同价 0.001 OKB）
    function assembleWithTier(uint8 tier) public payable {
        require(tier >= 1 && tier <= 5, "tier");
        for (uint i = 1; i <= 8; i++) parts.burn(msg.sender, i, 1);
        _charge();
        uint256 id = ++lastId;
        uint32 hr = uint32(tier) * uint32(150 + roll() % 50);
        pcs[id] = PC(tier, hr, false);
        ownerPCs[msg.sender].push(id);
    }
    // 批量组装（费用 = n × 0.001 OKB）
    function batchAssemble(uint256 n) external payable {
        require(n <= 500, "n");
        _batchPreCharge(n);
        for (uint i = 0; i < n; i++) _doAssemble();
    }
    function batchAssembleTier(uint256 n, uint8 tier) external payable {
        require(tier >= 1 && tier <= 5, "tier");
        require(n <= 500, "n");
        _batchPreCharge(n);
        for (uint i = 0; i < n; i++) _doAssembleTier(tier);
    }
    function _batchPreCharge(uint256 n) internal {
        uint256 total = ASSEMBLE_FEE * n;
        require(msg.value >= total, "fee");
        (bool ok,) = PLAT.call{value: total}("");
        require(ok, "pay fail");
        if (msg.value > total) {
            (bool r0,) = msg.sender.call{value: msg.value - total}("");
            require(r0, "refund fail");
        }
    }
    function _doAssemble() internal {
        for (uint i = 1; i <= 8; i++) parts.burn(msg.sender, i, 1);
        uint256 id = ++lastId;
        uint8 tier = uint8(1 + roll() % 5);
        uint32 hr = uint32(tier) * uint32(150 + roll() % 50);
        pcs[id] = PC(tier, hr, false);
        ownerPCs[msg.sender].push(id);
    }
    function _doAssembleTier(uint8 tier) internal {
        for (uint i = 1; i <= 8; i++) parts.burn(msg.sender, i, 1);
        uint256 id = ++lastId;
        uint32 hr = uint32(tier) * uint32(150 + roll() % 50);
        pcs[id] = PC(tier, hr, false);
        ownerPCs[msg.sender].push(id);
    }
    function pcsOfOwner(address a) external view returns (uint256[] memory){ return ownerPCs[a]; }
    function setStaked(uint256 id, bool v) external { require(msg.sender == creator || msg.sender == owner() || msg.sender == poolAddr, "!m"); pcs[id].staked = v; }
    function isOwner(address a, uint256 id) external view returns (bool){ uint256[] memory arr = ownerPCs[a]; for (uint i = 0; i < arr.length; i++) if (arr[i] == id) return true; return false; }
    function setMarket(address m) external { require(msg.sender == creator || msg.sender == owner(), "!c"); market = m; }
    function transferPC(address from, address to, uint256 id) external { require(msg.sender == market || msg.sender == creator, "!auth"); require(!pcs[id].staked, "staked"); uint256[] storage arr = ownerPCs[from]; for (uint i = 0; i < arr.length; i++){ if (arr[i] == id){ arr[i] = arr[arr.length-1]; arr.pop(); break; } } ownerPCs[to].push(id); }
}

// ---------- 标准无锁 ERC20（项目消耗币） ----------
contract XPRToken {
    string public constant name = "XPower Token";
    string public constant symbol = "XPR";
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address to, uint256 amount) {
        totalSupply = amount;
        balanceOf[to] = amount;
        emit Transfer(address(0), to, amount);
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 b = balanceOf[msg.sender];
        require(b >= amount, "bal");
        balanceOf[msg.sender] = b - amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "alw");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        uint256 b = balanceOf[from];
        require(b >= amount, "bal");
        balanceOf[from] = b - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
