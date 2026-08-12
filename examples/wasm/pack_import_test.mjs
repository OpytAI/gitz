import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const wasmPath = join(process.env.RUNFILES_DIR, process.env.GITZ_WASM);
const wasmBytes = await readFile(wasmPath);
const gzipBytes = gzipSync(wasmBytes, { level: 9 }).length;
assert.ok(wasmBytes.length <= 2 * 1024 * 1024, "pack import wasm exceeds 2 MiB budget");
assert.ok(gzipBytes <= 768 * 1024, "pack import gzip exceeds 768 KiB budget");
const module = await WebAssembly.compile(wasmBytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);
const instance = await WebAssembly.instantiate(module, {});
const e = instance.exports;
const scratch = e.gitz_buffer();
const decoder = new TextDecoder();

function readHandle(handle) {
  assert.notEqual(handle, 0);
  const length = e.gitz_result_len(handle);
  const output = new Uint8Array(length);
  for (let offset = 0; offset < length;) {
    const count = Math.min(e.gitz_buffer_capacity(), length - offset);
    assert.equal(e.gitz_result_read_at(handle, offset, scratch, count), count);
    output.set(new Uint8Array(e.memory.buffer, scratch, count), offset);
    offset += count;
  }
  e.gitz_result_free(handle);
  return output;
}

function readJson(handle) {
  return JSON.parse(decoder.decode(readHandle(handle)));
}

function feed(pack, pattern) {
  let offset = 0;
  let i = 0;
  while (offset < pack.length) {
    const count = Math.min(pattern[i % pattern.length], pack.length - offset);
    new Uint8Array(e.memory.buffer, scratch, count).set(pack.subarray(offset, offset + count));
    assert.equal(e.gitz_import_write(scratch, count), 0);
    offset += count;
    i += 1;
  }
}

const pack = readHandle(e.gitz_fixture_pack());
assert.equal(decoder.decode(pack.subarray(0, 4)), "PACK");

// The byte cap rejects input before any object or ref becomes visible.
assert.equal(e.gitz_import_begin(pack.length - 1), 0);
new Uint8Array(e.memory.buffer, scratch, pack.length).set(pack);
assert.equal(e.gitz_import_write(scratch, pack.length), 2);
assert.deepEqual(readJson(e.gitz_state()), { ok: true, objects: 0, main: false, tag: false, refs: 1 });

// Malformed and truncated finishes fail transactionally.
assert.equal(e.gitz_import_begin(pack.length), 0);
const malformed = pack.slice();
malformed[0] ^= 0xff;
feed(malformed, [1, 7, 2, 31, 3]);
const malformedResult = readJson(e.gitz_import_finish(0));
assert.equal(malformedResult.ok, false);
assert.deepEqual(readJson(e.gitz_state()), { ok: true, objects: 0, main: false, tag: false, refs: 1 });
e.gitz_import_abort();

feed(pack.subarray(0, pack.length - 7), [5, 1, 19, 2]);
assert.equal(readJson(e.gitz_import_finish(0)).ok, false);
assert.deepEqual(readJson(e.gitz_state()), { ok: true, objects: 0, main: false, tag: false, refs: 1 });
e.gitz_import_abort();

// A ref validation failure publishes neither the decoded objects nor first ref.
feed(pack, [1, 13, 2, 127, 3, 29]);
const atomicFailure = readJson(e.gitz_import_finish(1));
assert.equal(atomicFailure.ok, false);
assert.equal(atomicFailure.error, "ReferenceHasChanged");
const atomicState = readJson(e.gitz_state());
assert.deepEqual(atomicState, { ok: true, objects: 0, main: false, tag: false, refs: 1 });

// Abort makes the same session reusable; a fresh uneven feed succeeds.
e.gitz_import_abort();
feed(pack, [3, 64, 1, 9, 257, 2]);
const result = readJson(e.gitz_import_finish(0));
assert.equal(result.ok, true, JSON.stringify(result));
assert.match(result.head, /^[0-9a-f]{40}$/);
assert.ok(result.objects >= 4);
assert.equal(result.refs_updated, 2);
assert.equal(result.refs, 3);
assert.equal(result.content, "transactional pack import");

// A true REF_DELTA pack resolves its base from the existing destination.
const thinPack = readHandle(e.gitz_thin_fixture_pack());
assert.equal(decoder.decode(thinPack.subarray(0, 4)), "PACK");
assert.equal(e.gitz_import_begin(thinPack.length), 0);
feed(thinPack, [2, 1, 17, 3, 41]);
const thinResult = readJson(e.gitz_thin_import_finish());
assert.deepEqual(thinResult, { ok: true, objects: 1, content: "thin base!" });

const warmPages = e.memory.buffer.byteLength / 65536;
for (let i = 0; i < 24; i += 1) assert.equal(readJson(e.gitz_state()).ok, true);
assert.equal(e.memory.buffer.byteLength / 65536, warmPages);
e.gitz_shutdown();

console.log(JSON.stringify({
  ...result,
  uneven_chunks: true,
  malformed_rejected: true,
  truncated_rejected: true,
  oversized_rejected: true,
  atomic_refs: true,
  abort_retry: true,
  thin_pack_existing_base: true,
  imports: 0,
  wasm_bytes: wasmBytes.length,
  gzip_bytes: gzipBytes,
  fixture_pack_bytes: pack.length,
  memory_pages: warmPages,
}));
