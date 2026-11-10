// Runs the shipped bundle in a real browser engine under the production CSP, then interoperates with GnuPG.
import { readFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import playwright from "playwright";
const { chromium } = playwright;

const bundle = readFileSync(new URL("../../../Aeolet/Resources/openpgp-bridge.js", import.meta.url), "utf8");
// Same page contract as PGPEngine.swift: HTTPS origin, strict CSP, bridge injected as a user script.
const CSP = "default-src 'none'; script-src 'wasm-unsafe-eval'";
const browser = await chromium.launch();
const page = await browser.newPage();
let outbound = [];
await page.route("**/*", (route) => {
  if (route.request().url() === "https://pgp.invalid/") {
    return route.fulfill({ contentType: "text/html", body: `<!doctype html><meta http-equiv="Content-Security-Policy" content="${CSP}"><title>x</title>` });
  }
  outbound.push(route.request().url());
  return route.abort();
});
await page.addInitScript(bundle);
await page.goto("https://pgp.invalid/");
assert.equal(await page.evaluate("isSecureContext && !!crypto.subtle"), true);
const blocked = await page.evaluate("fetch('https://example.com/x').then(()=>'sent',()=>'blocked')");
assert.equal(blocked, "blocked"); assert.deepEqual(outbound, [], "CSP must stop the request before it leaves the page");

async function call(name, payload) {
  const out = JSON.parse(await page.evaluate(([n, j]) => globalThis.__job(n, j), [name, JSON.stringify(payload)]));
  if (!out.ok) throw new Error(out.error);
  return out.value;
}
const b64 = (s) => Buffer.from(s).toString("base64");
const text = (s) => Buffer.from(s, "base64").toString();

let passed = 0;
const ok = (label) => { passed++; console.log("ok -", label); };
const rejects = async (promise, re, label) => { await assert.rejects(promise, re); ok(label); };

const alice = await call("generateKey", { name: "Alice", email: "alice@example.org", passphrase: "alice pass" });
const bob = await call("generateKey", { name: "Bób Ünïcode", email: "bob@example.org", passphrase: "bob pass" });
assert.match(alice.privateKey, /BEGIN PGP PRIVATE KEY/); assert.equal(alice.fingerprint.length, 40); ok("generate key");

const info = await call("inspect", { armored: alice.publicKey });
assert.equal(info.fingerprint, alice.fingerprint); assert.equal(info.isPrivate, false); assert.equal(info.canEncrypt, true);
assert.ok(info.userIDs[0].includes("alice@example.org")); ok("inspect public key");
const pinfo = await call("inspect", { armored: alice.privateKey });
assert.equal(pinfo.isPrivate, true); assert.equal(pinfo.isLocked, true); assert.doesNotMatch(pinfo.publicKey, /PRIVATE/); ok("inspect private key, derive public only");
assert.equal((await call("inspect", { armored: bob.publicKey })).userIDs[0].includes("Bób Ünïcode"), true); ok("unicode user ID");

const plain = "Grüße ✉️ 🦅\r\nline two\r\n";
const enc = await call("encrypt", { data: b64(plain), recipients: [bob.publicKey, alice.publicKey], signingKey: alice.privateKey, passphrase: "alice pass" });
assert.match(enc.armored, /BEGIN PGP MESSAGE/); assert.doesNotMatch(enc.armored, /Version:|Comment:/); ok("encrypt and sign, no version banner");
let dec = await call("decrypt", { armored: enc.armored, privateKey: bob.privateKey, passphrase: "bob pass", verificationKeys: [alice.publicKey] });
assert.equal(text(dec.data), plain); assert.equal(dec.signature, "valid"); ok("decrypt, signature valid");
dec = await call("decrypt", { armored: enc.armored, privateKey: alice.privateKey, passphrase: "alice pass", verificationKeys: [alice.publicKey] });
assert.equal(text(dec.data), plain); ok("sender can read own sent copy");
dec = await call("decrypt", { armored: enc.armored, privateKey: bob.privateKey, passphrase: "bob pass", verificationKeys: [] });
assert.equal(dec.signature, "unknownKey"); ok("unknown signer reported, never shown as valid");
dec = await call("decrypt", { armored: enc.armored, privateKey: bob.privateKey, passphrase: "bob pass", verificationKeys: [bob.publicKey] });
assert.equal(dec.signature, "unknownKey"); ok("wrong signer key not accepted");
await rejects(call("decrypt", { armored: enc.armored, privateKey: bob.privateKey, passphrase: "wrong", verificationKeys: [] }), /passphrase|decrypt/i, "wrong passphrase rejected");

const eve = await call("generateKey", { name: "Eve", email: "eve@example.org", passphrase: "e" });
await rejects(call("decrypt", { armored: enc.armored, privateKey: eve.privateKey, passphrase: "e", verificationKeys: [] }), /decrypt|key/i, "non-recipient cannot decrypt");

const tamper = enc.armored.split("\n"); const mid = Math.floor(tamper.length / 2);
tamper[mid] = (tamper[mid][0] === "A" ? "B" : "A") + tamper[mid].slice(1);
await rejects(call("decrypt", { armored: tamper.join("\n"), privateKey: bob.privateKey, passphrase: "bob pass", verificationKeys: [] }), /./, "tampered ciphertext rejected");

const unsigned = await call("encrypt", { data: b64("x"), recipients: [bob.publicKey] });
dec = await call("decrypt", { armored: unsigned.armored, privateKey: bob.privateKey, passphrase: "bob pass", verificationKeys: [alice.publicKey] });
assert.equal(dec.signature, "none"); ok("unsigned reported as none");

const big = randomBytes(300000);
const bigEnc = await call("encrypt", { data: big.toString("base64"), recipients: [bob.publicKey] });
dec = await call("decrypt", { armored: bigEnc.armored, privateKey: bob.privateKey, passphrase: "bob pass", verificationKeys: [] });
assert.equal(dec.data, big.toString("base64")); ok("binary attachment payload round trip");

const entity = "Content-Type: text/plain\r\n\r\nsigned body\r\n";
const sig = await call("signDetached", { data: b64(entity), privateKey: alice.privateKey, passphrase: "alice pass" });
assert.match(sig.micalg, /^pgp-sha/); ok("detached sign, micalg " + sig.micalg);
assert.equal((await call("verifyDetached", { data: b64(entity), signature: sig.signature, keys: [alice.publicKey] })).signature, "valid"); ok("detached verify valid");
assert.equal((await call("verifyDetached", { data: b64(entity + "x"), signature: sig.signature, keys: [alice.publicKey] })).signature, "invalid"); ok("altered data fails");
assert.equal((await call("verifyDetached", { data: b64(entity), signature: sig.signature, keys: [] })).signature, "unknownKey"); ok("detached unknown signer");

// GnuPG interoperability
const home = mkdtempSync(join(tmpdir(), "aeoletgpg-"));
const gpg = (args, input) => execFileSync("gpg", ["--homedir", home, "--batch", "--yes", "--pinentry-mode", "loopback", "--trust-model", "always", ...args], { input, stdio: ["pipe", "pipe", "pipe"] });
gpg(["--import"], bob.privateKey); gpg(["--import"], alice.publicKey);
let out = gpg(["--passphrase", "bob pass", "--decrypt"], enc.armored);
assert.equal(out.toString(), plain); ok("GnuPG decrypts and accepts Aeolet output");
const dir = mkdtempSync(join(tmpdir(), "aeoletdata-")); const d = join(dir, "d"), s = join(dir, "d.asc");
writeFileSync(d, entity); writeFileSync(s, sig.signature); gpg(["--verify", s, d]); ok("GnuPG verifies Aeolet detached signature");

gpg(["--passphrase", "x", "--quick-generate-key", "Carol <carol@example.org>", "rsa3072", "default", "never"]);
const carolFpr = gpg(["--with-colons", "--list-secret-keys", "carol@example.org"]).toString().split("\n").find((l) => l.startsWith("fpr:")).split(":")[9];
gpg(["--passphrase", "x", "--quick-add-key", carolFpr, "rsa3072", "encr", "never"]);
const carolPub = gpg(["--armor", "--export", "carol@example.org"]).toString();
const carolPriv = gpg(["--passphrase", "x", "--armor", "--export-secret-keys", "carol@example.org"]).toString();
const fromGpg = gpg(["--passphrase", "x", "--armor", "--local-user", "carol@example.org", "--recipient", "bob@example.org", "--sign", "--encrypt"], plain).toString();
dec = await call("decrypt", { armored: fromGpg, privateKey: bob.privateKey, passphrase: "bob pass", verificationKeys: [carolPub] });
assert.equal(text(dec.data), plain); assert.equal(dec.signature, "valid"); ok("Aeolet decrypts GnuPG RSA-signed mail");
const toCarol = await call("encrypt", { data: b64(plain), recipients: [carolPub], signingKey: bob.privateKey, passphrase: "bob pass" });
assert.equal(gpg(["--passphrase", "x", "--decrypt"], toCarol.armored).toString(), plain); ok("GnuPG RSA key receives Aeolet mail");
writeFileSync(d, "cleartext body\n");
const clear = gpg(["--passphrase", "x", "--armor", "--local-user", "carol@example.org", "--clearsign"], "cleartext body\n").toString();
const c = await call("verifyCleartext", { armored: clear, keys: [carolPub] });
assert.equal(c.signature, "valid"); assert.match(c.text, /cleartext body/); ok("verify inline clearsigned mail");
await call("inspect", { armored: carolPriv }).then((i) => assert.equal(i.isPrivate, true)); ok("import GnuPG private key");
await browser.close();
console.log(`\n${passed} PGP checks passed`);
