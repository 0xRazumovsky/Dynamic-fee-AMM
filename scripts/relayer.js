"use strict";
const { ethers } = require("ethers");
require("dotenv").config();

// Minimal relayer example: reads/generates a price, converts to WAD, and calls update(priceWAD)
// Usage: PRIVATE_KEY=... RPC_URL=... ORACLE_ADDR=... node scripts/relayer.js

const ORACLE_ADDR = process.env.ORACLE_ADDR;
const RPC = process.env.RPC_URL || "http://127.0.0.1:8545";
const PK = process.env.PRIVATE_KEY;

if (!ORACLE_ADDR || !PK) {
  console.error("Set ORACLE_ADDR and PRIVATE_KEY in env to run the relayer");
  process.exit(1);
}

const ABI = [
  "function update(uint256 priceNowWAD) external",
  "function addKeeper(address) external",
];

function toWad(n) {
  // accepts number or string decimal
  return ethers.parseUnits(String(n), 18);
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(PK, provider);
  const oracle = new ethers.Contract(ORACLE_ADDR, ABI, wallet);

  console.log("Relayer connected to", ORACLE_ADDR, "as", wallet.address);

  // Example: generate a synthetic price series and push updates each 60s (real relayer would read an oracle)
  let price = 1.0;
  setInterval(async () => {
    // simple random walk for demo
    const shock = (Math.random() - 0.5) * 0.02; // +/-1%
    price = Math.max(0.0001, price * (1 + shock));
    const priceWAD = toWad(price);
    try {
      const tx = await oracle.update(priceWAD);
      console.log(
        new Date().toISOString(),
        "update tx:",
        tx.hash,
        "price:",
        price
      );
      await tx.wait();
    } catch (err) {
      console.error("update failed:", err?.message || err);
    }
  }, 60_000);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
