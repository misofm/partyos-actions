// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
// Real validator regression: the Move unit-test VM does not enforce accumulator solvency.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const sui = process.env.SUI_BIN ?? "sui";
const root = resolve(import.meta.dir, "../party_wallet");
const scratch = mkdtempSync(join(tmpdir(), "party-wallet-localnet-"));
const rpc = "http://127.0.0.1:19000";
const client = new SuiJsonRpcClient({ url: rpc, network: "localnet" });
const signer = Ed25519Keypair.generate();
const sender = signer.toSuiAddress();
const currency = "0x2::sui::SUI";
if (process.env.WALLET_EXTERNAL_LOCALNET !== "1") {
  const occupied = await fetch(rpc, { signal: AbortSignal.timeout(1000) }).catch(() => null);
  assert(!occupied, "port 19000 is occupied; use WALLET_EXTERNAL_LOCALNET=1 intentionally");
}
// This runner only ever connects to loopback, with an ephemeral, faucet-funded signer.
const node = process.env.WALLET_EXTERNAL_LOCALNET === "1" ? undefined : Bun.spawn([
  sui, "start", "--force-regenesis", "--committee-size", "1",
  "--fullnode-rpc-port", "19000", "--with-faucet=127.0.0.1:19123",
  "--epoch-duration-ms", "600000",
], { stdout: "ignore", stderr: "ignore" });

async function execute(tx: Transaction) {
  tx.setGasBudget(200_000_000);
  const result = await client.signAndExecuteTransaction({
    signer, transaction: tx,
    options: { showEffects: true, showEvents: true, showObjectChanges: true },
  });
  await client.waitForTransaction({ digest: result.digest });
  return result;
}
function success(result: Awaited<ReturnType<typeof execute>>) {
  assert.equal(result.effects?.status.status, "success", JSON.stringify(result.effects?.status));
  return result;
}
function build(path: string) {
  return JSON.parse(execFileSync(sui, ["move", "build", "--path", path,
    "--build-env", "testnet", "--dump-bytecode-as-base64", "--no-tree-shaking",
    "--no-lint", "--warnings-are-errors"], { encoding: "utf8" }));
}
async function publish(name: string) {
  const path = join(scratch, name);
  const artifact = build(path);
  const tx = new Transaction();
  const cap = tx.publish({ modules: artifact.modules, dependencies: artifact.dependencies });
  tx.moveCall({ target: "0x2::package::make_immutable", arguments: [cap] });
  const result = success(await execute(tx));
  const published = result.objectChanges?.find((change) => change.type === "published");
  assert(published && published.type === "published");
  // Build-environment label only: these temporary files are never release records.
  writeFileSync(join(path, "Published.toml"), `[published.testnet]\nchain-id = "69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD"\npublished-at = "${published.packageId}"\noriginal-id = "${published.packageId}"\nversion = 1\ntoolchain-version = "1.79.0"\nbuild-config = { flavor = "sui", edition = "2024" }\n`);
  return published.packageId;
}
async function balance(party: string) {
  return BigInt((await client.getBalance({ owner: party, coinType: currency })).totalBalance);
}
async function settled(party: string, expected: bigint) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (await balance(party) === expected) return;
    await Bun.sleep(200);
  }
  assert.equal(await balance(party), expected);
}

try {
  let ready = false;
  for (let attempt = 0; attempt < 120; attempt++) {
    try {
      await client.getChainIdentifier();
      await fetch("http://127.0.0.1:19123/", { signal: AbortSignal.timeout(1000) });
      ready = true;
      break;
    } catch { await Bun.sleep(500); }
  }
  assert(ready, "localnet did not start");
  const faucet = await fetch("http://127.0.0.1:19123/v2/gas", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ FixedAmountRequest: { recipient: sender } }),
  });
  assert(faucet.ok, "localnet faucet failed");
  // Populate the exact manifest-pinned dependency cache, then copy production sources unchanged.
  build(root);
  const manifest = readFileSync(join(root, "Move.toml"), "utf8");
  for (const name of ["partyos", "hikida", "party_wallet"]) {
    let source = root;
    if (name !== "party_wallet") {
      const match = manifest.match(new RegExp(`${name} = \\{ git = "([^"]+)", rev = "([^"]+)"`));
      assert(match, `missing pinned ${name}`);
      source = join(homedir(), ".move/git", `${match[1]!.replace(/[^a-zA-Z0-9]/g, "_")}_${match[2]}`);
    }
    const path = join(scratch, name);
    mkdirSync(path);
    cpSync(join(source, "sources"), join(path, "sources"), { recursive: true });
    writeFileSync(join(path, "Move.toml"), `[package]\nname = "${name}"\nedition = "2024"\n` +
      (name === "party_wallet" ? '\n[dependencies]\npartyos = { local = "../partyos" }\nhikida = { local = "../hikida" }\n' : ""));
  }
  const partyos = await publish("partyos");
  await publish("hikida");
  const wallet = await publish("party_wallet");
  const create = new Transaction();
  const kind = create.moveCall({ target: `${partyos}::party::new_individual_kind` });
  const [party, admin] = create.moveCall({ target: `${partyos}::party::new`,
    arguments: [kind, create.pure.string("Wallet regression"), create.object("0x6")] });
  create.moveCall({ target: `${partyos}::party::share`, arguments: [party!, admin!] });
  create.transferObjects([admin!], sender);
  const created = success(await execute(create));
  const objects = created.objectChanges?.filter((c) => c.type === "created") ?? [];
  const partyId = objects.find((c) => c.type === "created" && c.objectType === `${partyos}::party::Party`);
  const adminId = objects.find((c) => c.type === "created" && c.objectType === `${partyos}::party::PartyAdminCap`);
  assert(partyId?.type === "created" && adminId?.type === "created");
  const fund = new Transaction();
  const [coin] = fund.splitCoins(fund.gas, [500]);
  const funds = fund.moveCall({ target: "0x2::coin::into_balance", typeArguments: [currency], arguments: [coin!] });
  fund.moveCall({ target: "0x2::balance::send_funds", typeArguments: [currency],
    arguments: [funds, fund.pure.address(partyId.objectId)] });
  success(await execute(fund));
  await settled(partyId.objectId, 500n);

  const redeem = (amount: number) => {
    const tx = new Transaction();
    const funds = tx.moveCall({ target: `${wallet}::party_wallet::redeem_balance`, typeArguments: [currency],
      arguments: [tx.object(partyId.objectId), tx.object(adminId.objectId), tx.pure.u64(amount)] });
    const coin = tx.moveCall({ target: "0x2::coin::from_balance", typeArguments: [currency], arguments: [funds] });
    tx.transferObjects([coin], sender);
    return tx;
  };
  const failed = await execute(redeem(501));
  assert.equal(failed.effects?.status.status, "failure", "overdraw must fail on the validator");
  assert.match(failed.effects?.status.error ?? "", /Insufficient.*(Balance|Funds)|InsufficientFundsForWithdraw/i);
  assert.equal(failed.events?.length ?? 0, 0, "failed withdrawal committed an event");
  assert.equal(failed.objectChanges?.filter((c) => c.type === "created").length ?? 0, 0,
    "failed withdrawal created an asset");
  assert.equal(await balance(partyId.objectId), 500n, "overdraw consumed Party funds");

  const valid = success(await execute(redeem(500)));
  const event = valid.events?.filter((e) => e.type === `${wallet}::party_wallet::FundsRedeemedEvent<${currency}>`);
  assert.equal(event?.length, 1);
  assert.deepEqual(event![0]!.parsedJson, { party_id: partyId.objectId, amount: "500" });
  await settled(partyId.objectId, 0n);
  console.log(JSON.stringify({ result: "PASS", overdraw: failed.digest, fullRedemption: valid.digest }));
} finally {
  node?.kill();
  rmSync(scratch, { recursive: true, force: true });
}
