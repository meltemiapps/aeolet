import * as openpgp from "openpgp";

openpgp.config.showVersion = false;
openpgp.config.showComment = false;
openpgp.config.commentString = "";

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function toBase64(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4)];
    out += i + 1 < bytes.length ? B64[((b & 15) << 2) | (c >> 6)] : "=";
    out += i + 2 < bytes.length ? B64[c & 63] : "=";
  }
  return out;
}
const DECODE = new Uint8Array(128);
for (let i = 0; i < B64.length; i++) DECODE[B64.charCodeAt(i)] = i;
function fromBase64(text) {
  const clean = text.replace(/[^A-Za-z0-9+/]/g, "");
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let bits = 0;
  let buffer = 0;
  let n = 0;
  for (let i = 0; i < clean.length; i++) {
    buffer = (buffer << 6) | DECODE[clean.charCodeAt(i)];
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[n++] = (buffer >> bits) & 255;
      buffer &= (1 << bits) - 1;
    }
  }
  return out.subarray(0, n);
}

const readAny = (armoredKey) => openpgp.readKey({ armoredKey });
const readAll = async (list) => (await Promise.all((list || []).map((armoredKeys) => openpgp.readKeys({ armoredKeys })))).flat();

async function unlock(privateKey, passphrase) {
  const key = await openpgp.readPrivateKey({ armoredKey: privateKey });
  if (key.isDecrypted()) return key;
  return openpgp.decryptKey({ privateKey: key, passphrase });
}

const HASHES = { 2: "pgp-sha1", 8: "pgp-sha256", 9: "pgp-sha384", 10: "pgp-sha512", 11: "pgp-sha224" };

async function signatureState(signatures) {
  if (!signatures || signatures.length === 0) return { state: "none", signer: "" };
  let last = { state: "invalid", signer: "" };
  for (const entry of signatures) {
    const signer = entry.keyID ? entry.keyID.toHex().toUpperCase() : "";
    try {
      await entry.verified;
      return { state: "valid", signer };
    } catch (error) {
      const unknown = /could not find signing key/i.test(String(error && error.message));
      last = { state: unknown ? "unknownKey" : "invalid", signer };
    }
  }
  return last;
}

const handlers = {
  async generateKey({ name, email, passphrase }) {
    if (!passphrase) throw new Error("A passphrase is required");
    const result = await openpgp.generateKey({
      type: "ecc",
      curve: "curve25519Legacy",
      userIDs: [{ name, email }],
      passphrase,
      format: "armored",
    });
    const key = await readAny(result.publicKey);
    return { privateKey: result.privateKey, publicKey: result.publicKey, fingerprint: key.getFingerprint().toUpperCase() };
  },

  async inspect({ armored }) {
    const key = await readAny(armored);
    const expires = await key.getExpirationTime();
    let canEncrypt = true;
    try { await key.getEncryptionKey(); } catch (_) { canEncrypt = false; }
    return {
      fingerprint: key.getFingerprint().toUpperCase(),
      userIDs: key.getUserIDs(),
      isPrivate: key.isPrivate(),
      isLocked: key.isPrivate() ? !key.isDecrypted() : false,
      canEncrypt,
      algorithm: key.getAlgorithmInfo().algorithm,
      expires: expires instanceof Date ? expires.toISOString() : "",
      publicKey: key.toPublic().armor(),
    };
  },

  async encrypt({ data, recipients, signingKey, passphrase }) {
    const encryptionKeys = await readAll(recipients);
    if (encryptionKeys.length === 0) throw new Error("No recipient keys");
    const options = { message: await openpgp.createMessage({ binary: fromBase64(data) }), encryptionKeys, format: "armored" };
    if (signingKey) options.signingKeys = await unlock(signingKey, passphrase);
    return { armored: await openpgp.encrypt(options) };
  },

  async decrypt({ armored, privateKey, passphrase, verificationKeys }) {
    const message = await openpgp.readMessage({ armoredMessage: armored });
    const result = await openpgp.decrypt({
      message,
      decryptionKeys: await unlock(privateKey, passphrase),
      verificationKeys: await readAll(verificationKeys),
      format: "binary",
    });
    const signature = await signatureState(result.signatures);
    return { data: toBase64(result.data), signature: signature.state, signer: signature.signer };
  },

  async signDetached({ data, privateKey, passphrase }) {
    const signature = await openpgp.sign({
      message: await openpgp.createMessage({ binary: fromBase64(data) }),
      signingKeys: await unlock(privateKey, passphrase),
      detached: true,
      format: "armored",
    });
    const parsed = await openpgp.readSignature({ armoredSignature: signature });
    const micalg = HASHES[parsed.packets[0].hashAlgorithm];
    if (!micalg) throw new Error("Unsupported signature hash");
    return { signature, micalg };
  },

  async verifyDetached({ data, signature, keys }) {
    const result = await openpgp.verify({
      message: await openpgp.createMessage({ binary: fromBase64(data) }),
      signature: await openpgp.readSignature({ armoredSignature: signature }),
      verificationKeys: await readAll(keys),
    });
    const state = await signatureState(result.signatures);
    return { signature: state.state, signer: state.signer };
  },

  async verifyCleartext({ armored, keys }) {
    const result = await openpgp.verify({
      message: await openpgp.readCleartextMessage({ cleartextMessage: armored }),
      verificationKeys: await readAll(keys),
    });
    const state = await signatureState(result.signatures);
    return { text: result.data, signature: state.state, signer: state.signer };
  },
};

// Native entry point, called through WKWebView.callAsyncJavaScript. Takes and returns JSON strings.
globalThis.__job = async (name, json) => {
  try {
    const handler = handlers[name];
    if (!handler) throw new Error("Unknown operation");
    return JSON.stringify({ ok: true, value: await handler(JSON.parse(json)) });
  } catch (error) {
    return JSON.stringify({ ok: false, error: String((error && error.message) || error) });
  }
};
