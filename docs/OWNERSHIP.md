# Ownership contract

**go-git is the feature oracle; Zig owns the lifetime contract.**

gitz ports go-git **features and Git behavior** (history walk, pack import,
merge-base, storage, remotes, worktrees). go-git is **not** a lifetime or free
API reference. Go assumes a garbage collector. Zig requires a single owner for
every heap object, free companions, and GPA-clean tests.

Do not invent a different Git model. Do invent Zig-safe free surfaces when
go-git would rely on GC.

Related: [`ARCHITECTURE.md`](../ARCHITECTURE.md), [`AGENTS.md`](../AGENTS.md),
[`TESTING.md`](TESTING.md), [`GATES.md`](GATES.md).

---

## Canonical rules (R1–R9)

| ID | Rule |
| --- | --- |
| **R1 Caller owns yield** | Iterator `next()` that returns a heap object transfers ownership of that object to the caller when the object is heap-owned. |
| **R2 Free-on-internal-drop** | When an iterator loads an object then skips it (`continue` for seen, seen_external, invalid filter, path/limit skip), it must free that object before continuing. |
| **R3 Free-on-close** | `close` / `deinit` free every remaining **unyielded** heap object still held in stacks, queues, heaps, or path lists. Already-yielded objects are never freed by close (caller owns them). |
| **R4 forEach policy (`*Commit` / ObjectIter)** | For `CommitIter` / concrete commit walkers and `ObjectIter`: **borrow during callback**. Free each yield after the callback returns **including Stop and error paths**, then `close` frees only unyielded remainder. Callbacks must **not** free the yielded object. |
| **R4b CommitNodeIter forEach** | **Same free-after-cb model as R4** for heap-owned nodes. Always `defer close()`. Call sites must not retain nodes after a successful callback as if they own them. |
| **R5 Free companions** | Every public heap return type has a package-level free companion matching in-tree shape (`freeTree(allocator, t)`, `freeReference` backend-aware). Prefer one public symbol; delete private duplicates. |
| **R6 Backend-uniform EncodedObject** | Memory and filesystem share one create/set/lookup/discard contract; transactional commit **clones** (or transfers with remove-from-temporal) so two storages never free the same pointer. |
| **R7 Hash pad invariant** | `Hash.bytes[digestSize()..]` is always zero under the active format. Public construction only via `fromBytes` / `fromHex` / `ZeroHash`. Debug assert in `eql` under safety builds. |
| **R8 Process globals** | Pools and transport registries are process-scoped; hosts must drain them at shutdown with the same allocator used for get/put. The library does not drain on every call or on `Repository.deinit`. |
| **R9 GPA tests gate ownership** | Ownership work ends with tests that fail under the old behavior: production loaders, both backends where applicable, early exit, error paths, full deinit, zero leaks, no double-free. Prefer at least one **cross-module** GPA test when the fix spans packages. |

Replace “same as go-git GC” comments with the applicable rule above.

---

## R4 forEach algorithm

Normative shape for **`CommitIter.forEach` / `forEachCommit`** only
(`freeCommit` on each yield):

```zig
// CommitIter.forEach / forEachCommit — borrow-during-callback
pub fn forEachCommit(iter: anytype, cb: anytype) !void {
    defer iter.close(); // R3: frees only unyielded holds
    while (true) {
        const c = iter.next() catch |err| {
            if (err == error.EndOfStream) return;
            return err;
        };
        // Ownership is with forEach for the duration of the callback.
        var freed = false;
        defer if (!freed) freeCommit(c.allocator, c);
        cb(c) catch |err| {
            // Stop and error both free c via defer, then propagate.
            if (err == error.Stop) return; // success stop after free
            return err;
        };
        freeCommit(c.allocator, c);
        freed = true;
    }
}
```

`ObjectIter.forEach` and `CommitNodeIter.forEach` (R4b) use the **same**
free-after-cb control flow (`defer close()`, free after callback including
Stop/error). They free with that yield type’s companion (object/encoded free or
node free), not `freeCommit`.

Acceptance: GPA with callback `error.Stop` after N yields; GPA with a random
callback error; both show zero leaks. Callbacks that free the yielded object
are wrong under R4/R4b.

### Iterator transfer (R1–R3)

```text
next() loads heap object
  ├─ yield  → caller owns; close must NOT free this pointer
  └─ skip   → free before continue (R2)

close / deinit → free only unyielded holds (R3)
```

---

## EncodedObject ownership (unified)

Memory and filesystem use one contract:

| Operation | Ownership |
| --- | --- |
| `newEncodedObject` | **Caller owns** until successful `setEncodedObject` **or** `discardEncodedObject`. Neither backend registers in `owned[]` / maps until set succeeds. |
| `setEncodedObject` | Storage **takes ownership** on success (and on go-git-compatible “kept but error” cases where the store retains the object). Caller must not free. On pure pre-insert / pre-write failure, caller retains. |
| `encodedObject` / lookup | Return is a **borrow**; storage owns. Caller must not destroy. |
| `discardEncodedObject(store, obj)` | Safe abandon of a caller-owned create that was never successfully set. Removes from any mid-migration registration then destroy. |
| Storage `deinit` | Frees only objects the storage owns. |

Capability intent after unify:

- `set_encoded_object_takes_ownership = true` on memory, FS, and tx wrappers.
- `new_encoded_object_storage_owned = false` (create does not register early).

Transactional commit (both backends): **clone-on-commit** so base and temporal
never free the same pointer. Rollback/temporal deinit free only temporal-owned
objects.

Expose `discardEncodedObject` on concrete storage, type-erased `RepoStorer`, and
repository facades (same discipline as `freeReference`).

---

## Free companions

| Type / surface | Free API | Notes |
| --- | --- | --- |
| `*Tree` | `freeTree(allocator, t)` | Existing pattern. |
| `*Commit` | `freeCommit(allocator, c)` | Public; no-op when `heap_owned == false`; matches `freeTree` shape. |
| Reference | `freeReference` (backend-aware) | Always pair with the storer/facade that returned the ref. |
| EncodedObject create | `discardEncodedObject` | Only for never-set creates; not for lookup borrows. |
| Merge-base results | Caller free contract below | Optional helpers may free slice + owned elements. |

One public symbol per type. Delete private free duplicates when the public
companion lands.

### AdvRefs and other dual returns

| Surface | Rule |
| --- | --- |
| Session-owned AdvRefs | Do not free; session/storage owns. |
| Heap AdvRefs | Free with package `freeAdvRefs` when the API documents heap ownership. |
| `objectPacks` | Document heap vs empty static return; free only heap results. |
| Repository object getters | Free companions next to `freeReference` on the facade. |

---

## AllIter: single path-list channel

**Hard rule:** Tips and walk-loaded commits live only in the path-list structure
(or one equivalent list). There is **no** parallel `owned_tips` ownership
channel.

| Operation | Ownership |
| --- | --- |
| Insert tip / node | Path list only. |
| `next()` | Transfers ownership of the current path node’s commit to the caller and advances so the node is no longer held. |
| `close` / `deinit` | Free only commits still on the remaining path (`curr` → tail), via `freeCommit` (no-op when `heap_owned=false`). |

Do not reintroduce dual free APIs such as `freeUnyielded` / `disownTips` with a
second ownership list.

---

## CommitNode ownership

| API | Rule |
| --- | --- |
| `CommitNode.commit()` | **Always** returns a heap-owned `*Commit` the caller must `freeCommit`. No dual borrow-vs-owned split between object-backed and graph-backed nodes. |
| `CommitNodeIter.forEach` | **R4b:** free-after-cb for heap-owned nodes. Always `defer close()`. |
| `CommitNodeIter.close` | Free internal unyielded holds (walker stacks)—same R3. |
| `ParentCommitNodeIter` | `next()` loads and returns a node immediately; the iter does **not** buffer a stack of unyielded parents. `close` need not invent a free stack. Free the last yield on Stop/error inside forEach (R4b). If close later gains buffered state, free that state. |

---

## mergeBase / independents free contract

Under production loaders, walker yields are **owned transfers (R1)**. Feature
parity still returns commit objects; Zig requires an explicit free contract.

### During any walk

`freeCommit(allocator, c)` every `next()` / filter yield that is **not**
retained as a result candidate.

### mergeBase / mergeBaseWithLoader

- API never freeCommits the self/other inputs.
- During walk: free every non-retained yield.
- IsReachable short path: return a **cloned** `*Commit` in a 1-element slice
  (`heap_owned=true`). Caller always `freeCommit`s every result element, then
  frees the slice. Inputs remain solely caller-owned.
- Normal path: returned elements are walk-derived (after independents); caller
  freeCommits each, then frees the slice.

### independents / independentsWithLoader

- API never freeCommits original inputs.
- Walk yields while testing reachability: freeCommit every yield (none of them
  are returned).
- When the returned set is a subset of inputs (common case): return those input
  pointers; caller **frees the slice only** and does not freeCommit elements
  (caller still owns the tips).
- When mergeBase feeds independents with walk-derived commits: those are the
  independents “inputs” for eliminate/free rules—freeCommit eliminated ones;
  survivors stay owned for the mergeBase caller, who freeCommits them.

### Consumer loops (isAncestor pattern)

Close does **not** free already-yielded commits (R3). Every successful `next()`
must be freed by the consumer on continue **and** on break/match.

---

## Process lifecycle

| Item | Rule |
| --- | --- |
| `utils/sync` pools (`deinitPools`) | Process-scoped. Host/engine close calls with the **same allocator** used for get/put. |
| Transport `client.deinit` | Same after network use. |
| `Repository.deinit` | **Must not** call `deinitPools` (would thrash multi-repo hosts). |
| Wasm / embedders | Drain pools (and transport client after network) on engine close. |
| Freestanding wasm | Allocators may not enforce leak checks; native GPA tests still require clean drain. |

```text
Host process
  Engine / main ──session──► Repositories ──get/put──► sync pools
                          └──remote ops──► transport client registry
  Engine shutdown ──drain──► pools + client registry
```

---

## Testing requirements (R9)

Ownership changes require:

1. **`std.testing.allocator` (GPA)** or equivalent debug allocator so leaks and
   double-frees fail the test.
2. **Production loaders** (`heap_owned=true`) for walker and merge-base paths.
   Stack/map-only tips alone are insufficient.
3. **Both storage backends** where the contract spans memory and filesystem.
4. Early exit, error, Stop, and full deinit paths.
5. Cross-module GPA when a fix spans packages (for example walker + remote FF).

See [`TESTING.md`](TESTING.md).

---

## What success is not

- Matching go-git **function names** or **non-free** pointer APIs is not success.
- Inventory **API-name mapping ratios** are navigation / hygiene, not a project
  success metric. See [`GATES.md`](GATES.md).
- Behavioral goldens, Bazel gates, and ownership GPA cleanliness measure
  progress.
