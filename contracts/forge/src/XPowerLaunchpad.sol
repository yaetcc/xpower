// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// ============================================================
//  XPower Launchpad · 自研发射台
//  - 免费发币：任何人填名称/符号/总量/创建者份额，一键部署标准 ERC20
//  - 内置交易曲线（pump.fun 式 virtual-reserve 恒定乘积）：
//      买入付 OKB 进池、代币从曲线释放；卖出销毁代币、池子 OKB 回购
//  - 买卖 1% 协议费实时进平台地址（feeBps 可调）
//  - 创建者份额默认 20%（上限 30%），其余进曲线池
// ============================================================

// ---------- 最小标准 ERC20（独立部署，创建者完全可控） ----------
contract XPCoin {
    string  public name;
    string  public symbol;
    uint8   public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public launchpad;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint256 supply_, address lp_) {
        name = name_; symbol = symbol_;
        totalSupply = supply_;
        balanceOf[lp_] = supply_;
        launchpad = lp_;
        emit Transfer(address(0), lp_, supply_);
    }

    modifier onlyLP() { require(msg.sender == launchpad, "only launchpad"); _; }

    function transfer(address to, uint256 v) external returns (bool) {
        return _move(msg.sender, to, v);
    }
    function approve(address sp, uint256 v) external returns (bool) {
        allowance[msg.sender][sp] = v;
        emit Approval(msg.sender, sp, v);
        return true;
    }
    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) { require(a >= v, "allowance"); allowance[f][msg.sender] = a - v; }
        return _move(f, t, v);
    }
    function _move(address f, address t, uint256 v) internal returns (bool) {
        require(balanceOf[f] >= v, "balance");
        balanceOf[f] -= v;
        balanceOf[t] += v;
        emit Transfer(f, t, v);
        return true;
    }

    // 发射台专用：从 LP 合约持有的余额转出（创建者份额 / 支付买家）
    function lpSend(address to, uint256 v) external onlyLP returns (bool) {
        return _move(address(this), to, v);
    }
}

// ---------- 发射台（发币 + 曲线交易） ----------
contract XPowerLaunchpad {
    address public owner;
    address public platform;                 // 协议费收款地址
    uint256 public feeBps = 100;             // 1%
    uint256 public virtualBase = 30 ether;   // 每条曲线虚拟基础池（OKB 计价）

    struct Token {
        address coin;
        string  name;
        string  symbol;
        address creator;
        uint256 totalSupply;   // 代币总量
        uint256 creatorShare;  // 创建者所得
        uint256 virtualToken;  // 曲线池虚拟 token 储备
        uint256 virtualBase;   // 曲线池虚拟 OKB 储备
        uint256 sold;          // 已售出（曲线释放）
        bool    live;
    }
    Token[] public tokens;
    mapping(address => uint256) public tokenIndex;
    address[] public allTokens;

    event TokenCreated(address indexed coin, string name, string symbol, address indexed creator, uint256 totalSupply, uint256 creatorShare);
    event Buy(address indexed coin, address indexed buyer, uint256 okbIn, uint256 tokenOut);
    event Sell(address indexed coin, address indexed seller, uint256 tokenIn, uint256 okbOut);

    constructor(address platform_) { owner = msg.sender; platform = platform_; }

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }

    // ---------- 免费发币 ----------
    function createToken(string calldata name_, string calldata symbol_, uint256 totalSupply_, uint256 creatorShareBps)
        external returns (address coin)
    {
        require(bytes(name_).length > 0 && bytes(symbol_).length > 0, "name/symbol");
        require(totalSupply_ >= 1e18, "supply>=1");
        require(creatorShareBps <= 3000, "share<=30%");

        XPCoin c = new XPCoin(name_, symbol_, totalSupply_, address(this));
        uint256 cs = totalSupply_ * creatorShareBps / 10000;
        if (cs > 0) c.lpSend(msg.sender, cs);

        tokens.push(Token({
            coin: address(c), name: name_, symbol: symbol_, creator: msg.sender,
            totalSupply: totalSupply_, creatorShare: cs,
            virtualToken: totalSupply_ - cs, virtualBase: virtualBase, sold: 0, live: true
        }));
        tokenIndex[address(c)] = tokens.length - 1;
        allTokens.push(address(c));
        emit TokenCreated(address(c), name_, symbol_, msg.sender, totalSupply_, cs);
        return address(c);
    }

    // ---------- 曲线查询 ----------
    // 当前代币价格（OKB/token，1e18 精度）
    function getPrice(address coin) public view returns (uint256) {
        Token storage t = tokens[tokenIndex[coin]];
        return t.virtualBase * 1e18 / t.virtualToken;
    }
    // 付 okbIn 可得多少代币
    function getBuyAmount(address coin, uint256 okbIn) public view returns (uint256) {
        Token storage t = tokens[tokenIndex[coin]];
        uint256 net = okbIn - okbIn * feeBps / 10000;
        return net * t.virtualToken / (t.virtualBase + net);
    }
    // 卖 tokIn 代币可得多少 OKB
    function getSellAmount(address coin, uint256 tokIn) public view returns (uint256) {
        Token storage t = tokens[tokenIndex[coin]];
        uint256 gross = tokIn * t.virtualBase / (t.virtualToken + tokIn);
        return gross - gross * feeBps / 10000;
    }
    function tokenCount() external view returns (uint256) { return allTokens.length; }

    // ---------- 买入（付 OKB） ----------
    function buy(address coin) external payable {
        Token storage t = tokens[tokenIndex[coin]];
        require(t.live && msg.value > 0, "bad");
        uint256 fee = msg.value * feeBps / 10000;
        uint256 net = msg.value - fee;
        uint256 out = net * t.virtualToken / (t.virtualBase + net);
        require(out > 0, "0 out");

        t.virtualToken -= out;
        t.virtualBase  += net;
        t.sold         += out;
        if (fee > 0) payable(platform).transfer(fee);
        XPCoin(t.coin).lpSend(msg.sender, out);
        emit Buy(coin, msg.sender, msg.value, out);
    }

    // ---------- 卖出（销毁代币换 OKB） ----------
    function sell(address coin, uint256 tokIn) external {
        Token storage t = tokens[tokenIndex[coin]];
        require(t.live && tokIn > 0, "bad");
        XPCoin c = XPCoin(t.coin);
        require(c.balanceOf(msg.sender) >= tokIn, "balance");
        require(c.transferFrom(msg.sender, address(this), tokIn), "transfer");

        uint256 gross = tokIn * t.virtualBase / (t.virtualToken + tokIn);
        uint256 fee   = gross * feeBps / 10000;
        uint256 pay   = gross - fee;
        require(address(this).balance >= pay, "liquidity");

        t.virtualToken += tokIn;
        t.virtualBase  -= gross;
        if (fee > 0) payable(platform).transfer(fee);
        payable(msg.sender).transfer(pay);
        emit Sell(coin, msg.sender, tokIn, pay);
    }

    // ---------- 治理 ----------
    function setFee(uint256 bps) external onlyOwner { require(bps <= 500, "<=5%"); feeBps = bps; }
    function setPlatform(address p) external onlyOwner { require(p != address(0), "0"); platform = p; }
    function withdraw() external onlyOwner { payable(platform).transfer(address(this).balance); }
    function setVirtualBase(uint256 b) external onlyOwner { require(b > 0, "0"); virtualBase = b; }
}
