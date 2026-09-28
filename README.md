# XPower · 三币闭环 DApp 发射台

盲盒抽卡消耗用户指定代币 → 部件组装消耗平台币 XPR → 质押 PC 挖矿产出用户指定代币。用户从 IGNIX 发币后粘贴代币合约地址、配置盲盒参数，**一键部署**生成自有项目页（开盒 / 组装 / 质押挖矿 / 领取 / 市场）。

## 核心玩法（四步闭环）

1. **开盒抽卡**：消耗用户指定代币抽 8 类电脑部件（CPU / GPU / 内存 / 主板 / 硬盘 / 电源 / 机箱 / 散热），90% 进分红池、10% 归创建者
2. **组装整机**：消耗平台币 XPR（10 枚/台），费用进平台收款地址
3. **质押挖矿**：质押 PC NFT 按算力份额领取分红池奖励（每 6h 一轮）
4. **领取 / 市场**：领取用户指定代币奖励；部件与 PC NFT 挂单交易

## 链上地址（X Layer / ChainID 196）

| 合约 | 地址 |
|---|---|
| XPowerFactory（官方） | `0x1b1E7D8c3f1f7D0cd5AC4E77d267f10Ae1DFcbD3` |
| XPowerParts | `0x4a649C634460162558277b5B0c1E351a731DAa53` |
| XPowerCircuit | `0x796DF59a0115833Ab48d3CE091a971765C33c37d` |
| XPowerMining | `0xCd2596611e7371436F821d76C6Ba51fb86FB00aB` |
| XPowerBox | `0x803A85cD3388e2bdc42F9062ceB3fdD0727fFFD2` |
| XPowerMarket | `0xa6eB28Eed1Aa7a3Fd7818Dc3cCcA3E6468822181` |

- XPR 平台币：`0xFa24321d8f37B588a4f76FC18795Bcd441DCeEEe`
- 组装费收款：`0x594C2C32cB60a0d93F0Ce1CC9f6088709B50aDDC`
- RPC：`https://rpc.xlayer.tech`

## 一键部署（前端已内置官方 Factory）

填资料 → 连钱包 → 一键部署 = **仅 1 笔签名**（复用预部署 Factory，跳过 6 笔合约部署），部署后自动跳转项目页。

## 目录结构

```
index.html                  # 前端单文件（自包含，ethers 走 CDN）
contracts/
  XPower.sol                # 6 合约 + ERC1967Proxy + UUPSBase 单文件源码
  compile.js                # 本地编译脚本（node compile.js → out/）
  out/*.json                # 编译产物（部署字节码 + ABI）
  forge/                    # Foundry 测试（src + test，forge test 全绿）
assets/ethers.umd.min.js    # 本地 ethers 备用
docs/                       # 需求与方案文档
```

## 本地开发

```bash
cd contracts && npm install && node compile.js   # 编译
cd contracts/forge && forge test                 # 跑测试（11 passed）
```

## 线上访问

https://yaetcc.github.io/xpower/
