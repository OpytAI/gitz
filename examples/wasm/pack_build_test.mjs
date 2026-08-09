import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const wasmPath = join(process.env.RUNFILES_DIR, process.env.GITZ_WASM);
const wasmBytes = await readFile(wasmPath);
const gzipBytes = gzipSync(wasmBytes, { level: 9 }).length;
assert.ok(wasmBytes.length <= 2 * 1024 * 1024, "pack build wasm exceeds 2 MiB budget");
assert.ok(gzipBytes <= 768 * 1024, "pack build gzip exceeds 768 KiB budget");
const module = await WebAssembly.compile(wasmBytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);
const instance = await WebAssembly.instantiate(module, {});
const e = instance.exports;
const scratch = e.gitz_result_buffer();

function readHandle(handle) {
  assert.notEqual(handle, 0);
  const length = e.gitz_result_len(handle);
  const out = new Uint8Array(length);
  for (let offset = 0; offset < length;) {
    const count = Math.min(e.gitz_result_buffer_capacity(), length - offset);
    assert.equal(e.gitz_result_read_at(handle, offset, scratch, count), count);
    out.set(new Uint8Array(e.memory.buffer, scratch, count), offset);
    offset += count;
  }
  e.gitz_result_free(handle);
  return out;
}

const metadata = JSON.parse(new TextDecoder().decode(readHandle(e.gitz_run())));
assert.equal(metadata.ok, true, JSON.stringify(metadata));
assert.match(metadata.have, /^[0-9a-f]{40}$/);
assert.match(metadata.want, /^[0-9a-f]{40}$/);
assert.match(metadata.tag, /^[0-9a-f]{40}$/);
assert.ok(metadata.selected >= 5);
assert.equal(metadata.parsed, metadata.selected);
assert.equal(metadata.empty_delta, 0);
assert.equal(metadata.deletion_objects, 0);

const pack = readHandle(e.gitz_pack_build());
assert.equal(new TextDecoder().decode(pack.subarray(0, 4)), "PACK");
assert.equal(new DataView(pack.buffer, pack.byteOffset, pack.byteLength).getUint32(4), 2);
assert.equal(new DataView(pack.buffer, pack.byteOffset, pack.byteLength).getUint32(8), metadata.selected);
assert.equal(
  Buffer.from(pack.subarray(pack.length - 20)).toString("hex"),
  createHash("sha1").update(pack.subarray(0, -20)).digest("hex"),
  "independent host checksum validation",
);

const warmPages = e.memory.buffer.byteLength / 65536;
for (let i = 0; i < 12; i += 1) readHandle(e.gitz_pack_build());
assert.equal(e.memory.buffer.byteLength / 65536, warmPages);

console.log(JSON.stringify({
  ...metadata,
  imports: 0,
  wasm_bytes: wasmBytes.length,
  gzip_bytes: gzipBytes,
  emitted_pack_bytes: pack.length,
  memory_pages: warmPages,
}));
