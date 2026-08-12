# Freestanding WebAssembly acceptance gate

These targets compile normal Gitz code for `wasm32-freestanding`. They run in
the JavaScript `WebAssembly` runtime. They do not use WASI or Emscripten.

Run both the release-small and safety-enabled debug gates:

```sh
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache --batch test //examples/wasm:all
```

Run only the release-small gate:

```sh
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache --batch test //examples/wasm:release
```

Run only the debug gate:

```sh
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache --batch test //examples/wasm:debug
```

The aggregate contains five independent artifacts:

| Target | Proof |
| --- | --- |
| `local_repo_test` | Repository and worktree operations, refs, config, modes, status, and deterministic time |
| `pack_import_test` | Bounded uneven input, checksum validation, abort and retry, thin-pack base resolution, and atomic multi-ref publication |
| `pack_build_test` | Wants/haves reachability, tags, deletion, empty delta, pack encoding, and independent parsing |
| `persistence_test` | Complete opaque memory image export and restore in a new instance of the same module |
| `engine_smoke_test` | One linked init-to-pack-to-import-to-checkout-to-persistence workflow |

Each JavaScript test fails when the module imports a host capability. Each test
uses only scalar ABI values and copies owned result handles before it frees
them. Repeated operations check that linear memory reaches a stable size.
Pack import uses the parser's non-seekable source. It releases raw input chunks
as the parser consumes them, so it does not retain the complete pack beside the
complete decoded repository.

Each focused module has an uncompressed budget of 2 MiB and a gzip budget of
768 KiB. Tests print both measured sizes with semantic results. These are
regression ceilings. They do not claim that Gitz is smaller than another Git
engine.

The public artifact targets use Zig `ReleaseSmall`. The debug targets compile
the same source and run the same JavaScript assertions with Zig safety checks.

The memory repository uses explicit timestamps or an injected storage clock.
The modules have no network, process, environment, thread, filesystem, random,
or wall-clock imports. Native callers use the same `RepositoryFor` and
`WorktreeFor` surface with filesystem storage and `fs.Os`; see
`//src/repo:backend_test` for the on-disk proof.

## Process lifecycle and allocators

`utils/sync` free lists and (when used) the transport `client` registry are
process-scoped. Each wasm example uses **one** process allocator
(`std.heap.wasm_allocator`) for storage, pack work, and pool get/put. On engine
or one-shot session close, the example calls `sync.deinitPools(allocator)` with
that same allocator. `Repository` / store deinit does **not** drain pools.

| Host | Allocator | Why drain |
|------|-----------|-----------|
| These freestanding wasm modules | `std.heap.wasm_allocator` | Free-list nodes stay live until drained; wasm has no GPA, so leaks are silent, but drain still keeps linear memory stable across repeated runs |
| Native tests / tools | `std.testing.allocator` or a process GPA | Required for zero leaks under the GPA |

These examples do not open network transports. Hosts that call
`client.init` / `installDefaults` must also call `client.deinit()` once at
process shutdown (after remotes/sessions are gone), then `deinitPools`.
