## TWAPOracle: build, test, deploy, relayer

Files added in this change set:

- `src/TWAPOracle.sol` — on-chain TWAP + simple on-chain volatility estimator with keeper ACL
- `test/TWAPOracle.t.sol` — Foundry tests using `forge-std`
- `script/DeployTWAP.s.sol` — Foundry deployment script
- `scripts/relayer.js` — minimal Node.js relayer example (ethers.js)

Build & test

1. Install dependencies (if you use Node relayer):

```bash
npm install
```

2. Build contracts:

```bash
forge build
```

3. Run tests:

```bash
forge test
```

Deploy with Foundry

Use your RPC and private key:

```bash
forge script script/DeployTWAP.s.sol:Deploy --rpc-url $RPC --private-key $PK --broadcast
```

Relayer example

Set environment variables and run the example relayer (demo random walk price):

```bash
export ORACLE_ADDR=0xYourDeployedOracleAddress
export PRIVATE_KEY=0x...
export RPC_URL=https://...
node scripts/relayer.js
```

Notes

- The on-chain volatility estimator is a cheap approximation (average absolute returns between samples). For production use, compute realized volatility off-chain, sign it and verify on-chain.
- Consider adding replay protection, relayer rotation, and signed reports for secure aggregation.
