import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const wasmPath = join(process.env.RUNFILES_DIR, process.env.GITZ_WASM);
const bytes = await readFile(wasmPath);
const module = await WebAssembly.compile(bytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);

const instance = await WebAssembly.instantiate(module, {});
const { memory, probe_input: probeInput, probe_sha1: probeSha1, probe_digest: probeDigest } = instance.exports;
assert.ok(memory instanceof WebAssembly.Memory);

const input = Buffer.from("gitz wasm runtime probe", "utf8");
new Uint8Array(memory.buffer, probeInput(), input.length).set(input);
assert.equal(probeSha1(input.length), 1);

const actual = Buffer.from(new Uint8Array(memory.buffer, probeDigest(), 20)).toString("hex");
const expected = createHash("sha1").update(input).digest("hex");
assert.equal(actual, expected);
console.log(JSON.stringify({ imports: 0, sha1: actual, wasm_bytes: bytes.length }));
