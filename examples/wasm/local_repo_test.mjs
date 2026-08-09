import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const wasmPath = join(process.env.RUNFILES_DIR, process.env.GITZ_WASM);
const bytes = await readFile(wasmPath);
const gzipBytes = gzipSync(bytes, { level: 9 }).length;
assert.ok(bytes.length <= 2 * 1024 * 1024, "local repo wasm exceeds 2 MiB budget");
assert.ok(gzipBytes <= 768 * 1024, "local repo gzip exceeds 768 KiB budget");
const module = await WebAssembly.compile(bytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);

const instance = await WebAssembly.instantiate(module, {});
const e = instance.exports;
assert.ok(e.memory instanceof WebAssembly.Memory);
assert.equal(e.gitz_result_buffer_capacity(), 4096);

function run() {
  const handle = e.gitz_run();
  assert.notEqual(handle, 0);
  const length = e.gitz_result_len(handle);
  assert.ok(length > 0 && length <= e.gitz_result_buffer_capacity());
  const copied = e.gitz_result_read(handle, e.gitz_result_buffer(), length);
  assert.equal(copied, length);
  const json = new TextDecoder().decode(
    new Uint8Array(e.memory.buffer, e.gitz_result_buffer(), length),
  );
  e.gitz_result_free(handle);
  return JSON.parse(json);
}

const first = run();
console.log(JSON.stringify(first));
assert.equal(first.ok, true, JSON.stringify(first));
assert.match(first.head, /^[0-9a-f]{40}$/);
assert.equal(first.commits, 1);
assert.ok(first.objects >= 7);
assert.ok(first.refs >= 4);
assert.equal(first.untracked, 2);
assert.equal(first.dirty, 1);
assert.equal(first.diff, 1);
assert.equal(first.clean, true);
assert.equal(first.mode & 0o111, 0o111);
assert.equal(first.branch, true);
assert.equal(first.tag, true);
assert.equal(first.config, true);
assert.equal(first.remote, true);
assert.equal(first.content, "hello from wasm");
assert.match(first.content_oid, /^[0-9a-f]{40}$/);

const warmPages = e.memory.buffer.byteLength / 65536;
for (let i = 0; i < 24; i += 1) assert.deepEqual(run(), first);
const finalPages = e.memory.buffer.byteLength / 65536;
assert.equal(finalPages, warmPages, "repeated open/run/free must not grow wasm memory");

console.log(JSON.stringify({
  ...first,
  imports: 0,
  wasm_bytes: bytes.length,
  gzip_bytes: gzipBytes,
  memory_pages: finalPages,
}));
