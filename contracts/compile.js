// XPower v4 编译脚本：产出 ABI + bytecode（viaIR · optimizer 200）
const solc = require('solc');
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, 'XPower.sol'), 'utf8');
const input = {
  language: 'Solidity',
  sources: { 'XPower.sol': { content: src } },
  settings: {
    optimizer: { enabled: true, runs: 200 },
    viaIR: true,
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object'] } }
  }
};
const output = JSON.parse(solc.compile(JSON.stringify(input)));
if (output.errors) {
  const errs = output.errors.filter(e => e.severity === 'error');
  if (errs.length) { console.error('COMPILE ERRORS:'); errs.forEach(e => console.error(e.formattedMessage)); process.exit(1); }
  output.errors.forEach(e => console.warn('warn:', e.formattedMessage));
}
const outDir = path.join(__dirname, 'out');
fs.mkdirSync(outDir, { recursive: true });
const targets = ['XPowerParts', 'XPowerCircuit', 'XPowerMining', 'XPowerBox', 'XPowerMarket', 'XPowerFactory'];
const abiMap = {};
for (const name of targets) {
  const c = output.contracts['XPower.sol'][name];
  const artifact = {
    abi: c.abi,
    bytecode: '0x' + c.evm.bytecode.object,
    deployedBytecode: '0x' + c.evm.deployedBytecode.object
  };
  fs.writeFileSync(path.join(outDir, name + '.json'), JSON.stringify(artifact, null, 2));
  abiMap[name] = c.abi;
  console.log(name, 'OK bytecode len:', c.evm.bytecode.object.length / 2);
}
// 前端同源 ABI（供 XPower DApp.html 内嵌）
fs.writeFileSync(path.join(outDir, 'abi-embedded.js'), 'window.XP4_ABI = ' + JSON.stringify(abiMap) + ';');
console.log('DONE');
