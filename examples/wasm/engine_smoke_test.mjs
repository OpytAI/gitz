import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const wasmPath = join(process.env.RUNFILES_DIR, process.env.GITZ_WASM);
const bytes = await readFile(wasmPath);
const gzipBytes = gzipSync(bytes, { level: 9 }).length;
assert.ok(bytes.length <= 2 * 1024 * 1024, "engine smoke wasm exceeds 2 MiB budget");
assert.ok(gzipBytes <= 768 * 1024, "engine smoke gzip exceeds 768 KiB budget");
const module = await WebAssembly.compile(bytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);
const instance = await WebAssembly.instantiate(module, {});
const e = instance.exports;

function run() {
  const handle = e.gitz_run();
  assert.notEqual(handle, 0);
  const length = e.gitz_result_len(handle);
  assert.ok(length <= e.gitz_result_buffer_capacity());
  assert.equal(e.gitz_result_read(handle, e.gitz_result_buffer(), length), length);
  const result = JSON.parse(new TextDecoder().decode(
    new Uint8Array(e.memory.buffer, e.gitz_result_buffer(), length),
  ));
  e.gitz_result_free(handle);
  return result;
}

const first = run();
assert.equal(first.ok, true, JSON.stringify(first));
assert.match(first.head, /^[0-9a-f]{40}$/);
assert.ok(first.pack_objects >= 3);
assert.equal(first.imported_objects, first.pack_objects);
assert.ok(first.objects > first.imported_objects);
assert.equal(first.refs, 2);
assert.equal(first.content, "combined wasm engine");
assert.match(first.content_oid, /^[0-9a-f]{40}$/);
assert.ok(first.image_bytes > 0);

const warmPages = e.memory.buffer.byteLength / 65536;
for (let i = 0; i < 8; i += 1) assert.deepEqual(run(), first);
assert.equal(e.memory.buffer.byteLength / 65536, warmPages);

console.log(JSON.stringify({
  ...first,
  imports: 0,
  wasm_bytes: bytes.length,
  gzip_bytes: gzipBytes,
  memory_pages: warmPages,
}));
