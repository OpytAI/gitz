import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const wasmPath = join(process.env.RUNFILES_DIR, process.env.GITZ_WASM);
const wasmBytes = await readFile(wasmPath);
const gzipBytes = gzipSync(wasmBytes, { level: 9 }).length;
assert.ok(wasmBytes.length <= 2 * 1024 * 1024, "persistence wasm exceeds 2 MiB budget");
assert.ok(gzipBytes <= 768 * 1024, "persistence gzip exceeds 768 KiB budget");
const module = await WebAssembly.compile(wasmBytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);

function api(instance) {
  const e = instance.exports;
  const scratch = e.gitz_buffer();
  return {
    e,
    scratch,
    readHandle(handle) {
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
    },
  };
}

// Create the image, then discard the entire first instance.
let first = api(await WebAssembly.instantiate(module, {}));
const image = first.readHandle(first.e.gitz_create_image());
assert.equal(new TextDecoder().decode(image.subarray(0, 8)), "GITZIMG1");
const firstPages = first.e.memory.buffer.byteLength / 65536;
first = null;

// Instantiate the exact same module bytes and restore through uneven chunks.
const second = api(await WebAssembly.instantiate(module, {}));
second.e.gitz_restore_begin(image.length);
let offset = 0;
const pattern = [1, 31, 2, 257, 7, 1024, 3];
for (let i = 0; offset < image.length; i += 1) {
  const count = Math.min(pattern[i % pattern.length], image.length - offset);
  new Uint8Array(second.e.memory.buffer, second.scratch, count).set(image.subarray(offset, offset + count));
  assert.equal(second.e.gitz_restore_write(second.scratch, count), 0);
  offset += count;
}
const result = JSON.parse(new TextDecoder().decode(second.readHandle(second.e.gitz_restore_finish())));
assert.equal(result.ok, true, JSON.stringify(result));
assert.match(result.head_before, /^[0-9a-f]{40}$/);
assert.match(result.head_after, /^[0-9a-f]{40}$/);
assert.notEqual(result.head_after, result.head_before);
assert.ok(result.refs >= 1);
assert.ok(result.index_entries >= 4);
assert.equal(result.sparse, 1);
assert.equal(result.staged, 1);
assert.equal(result.dirty, 1);
assert.equal(result.untracked, 1);
assert.equal(result.index_exec, true);
assert.equal(result.fs_exec, true);
assert.equal(result.dirty_bytes, "dirty bytes");
assert.equal(result.untracked_bytes, "untracked bytes");
assert.equal(result.remote, true);
second.e.gitz_shutdown();

console.log(JSON.stringify({
  ...result,
  same_wasm_bytes: true,
  image_bytes: image.length,
  imports: 0,
  wasm_bytes: wasmBytes.length,
  gzip_bytes: gzipBytes,
  first_memory_pages: firstPages,
  restored_memory_pages: second.e.memory.buffer.byteLength / 65536,
}));
