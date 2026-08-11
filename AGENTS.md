# AGENTS.md

This file gives the rules for work in this project. Read this file before you change code.

## Project purpose

**gitz** is Git in Zig.

The goal is a full port of **go-git**. Use the latest suitable go-git source (see Reference pin). go-git covers the Git parts that this project needs. go-git uses the Apache 2.0 license. libgit2 does not use a license that this project accepts. Go is simple enough that a port is practical.

Do not invent a different Git model. Port the behavior of go-git.

## Repository structure

This project uses a bare git repository and worktrees. A reference clone of go-git sits as a sibling of the bare repository and the worktrees.

```
gitz.git/                 bare repository (shared object store, no working tree)
gitz-master/              worktree: master
gitz-develop/             worktree: develop
gitz-<name>/              worktree: feature or hotfix branch (temporary)
go-git/                   reference clone of go-git (read only for the port)
```

### Layout rules

- Never work inside the bare repository directory. It has no working tree.
- Each worktree checks out exactly one branch. Two worktrees must not share one branch.
- Treat `go-git/` as reference only. Do not commit project work into `go-git/`.
- Do not edit go-git to match gitz. Change gitz to match go-git.

## Reference pin (go-git)

Pin the go-git reference. Do not float on an untracked tip without a record.

### How to choose the pin

1. Prefer the **latest release** of go-git.
2. If that release is **not older than 6 months**, pin that release tag.
3. If that release is **older than 6 months**, pin the **latest commit** on the default branch instead.
4. Record the pin in the repository (tag or commit SHA, and the date of the decision).

### When the pin changes

- Change the pin only on purpose. Do not silent-update `go-git/` during feature work.
- After a pin change, update inventories and goldens so Bazel checks stay correct.
- Note the old pin and the new pin in the commit message or plan that performs the bump.

## Build system

Build and test only with **Bazel** and **rules_zig**. Use the Zig **0.16** toolchain that Bazel provides. Do not use the system `zig` binary for project builds or tests.

### Bazel output root

Use Bazel's platform default output root unless the local filesystem requires a different location. Do not commit a machine-specific output path.

Set a local output root in `user.bazelrc` when necessary. This file is ignored by Git. Use an absolute path so Bazel commands from workspace subdirectories use the same location.

```bazelrc
startup --output_user_root=/path/to/local/bazel-cache
```

The tracked `.bazelrc` imports `user.bazelrc` automatically. Do not add the startup option to each command.

Examples:

```bash
bazel build //...
bazel test //...
bazel shutdown
```

Do not delete or expunge a shared local cache unless the user requests it.

## Testing layout

Full rules: **`docs/TESTING.md`**.

Short form:

| Kind | Location |
|------|----------|
| Unit | Co-located `*_test.zig` in the production package |
| Shared fixtures / suites | `src/<area>/test/` as a **test-only** Bazel library |
| Cross-package e2e | Same `…/test/` package as go-git (e.g. `src/plumbing/transport/test`) |

Production `zig_library` targets must **not** depend on test packages. Prefer
shared fixtures over copy-pasted `populateRepo` helpers.

## Initializing a fresh project

If there is no repository yet:

```bash
# 1. Create the bare repository
git init --bare gitz.git

# 2. Create the master worktree and the first commit
cd gitz.git
git worktree add ../gitz-master -b master

cd ../gitz-master
# add initial files (.gitignore, README, AGENTS.md, MODULE.bazel, etc.)
git add .
git commit -m "Initial commit"

# 3. Create develop from master
cd ../gitz.git
git worktree add ../gitz-develop -b develop master
```

Note: `git init --bare` creates a repository with zero commits. Create and commit on master first. Then create develop.

### Clone the go-git reference

Clone go-git as a sibling. Then apply the pin rules in **Reference pin (go-git)**.

```bash
# From the parent of gitz.git (this folder level)
git clone https://github.com/go-git/go-git.git go-git
cd go-git
# checkout the chosen release tag, or the latest commit if the release is too old
```

## Common operations

### Add a worktree

```bash
cd gitz.git
git worktree add ../gitz-<name> <branch>

# Or create a new branch at the same time:
git worktree add ../gitz-<name> -b <new-branch> <start-point>
```

### List worktrees

```bash
cd gitz.git
git worktree list
```

### Remove a worktree

```bash
cd gitz.git
git worktree remove ../gitz-<name>
```

### Fetch and pull

Fetch from any worktree or the bare repository. They share the same remotes.

```bash
cd gitz.git
git fetch --all
```

Then pull inside a specific worktree:

```bash
cd ../gitz-master
git pull
```

### Prune stale worktree references

If a worktree directory was deleted by hand:

```bash
cd gitz.git
git worktree prune
```

## Branch naming schema

Branches follow a tiered promotion model. Code flows **upward** through each tier by merge. Never skip a tier.

```
master                    production: tagged releases only
  ↑ merge
develop                   integration: completed feature work lands here first
  ↑ merge
feature/*                 feature work
hotfix/*                  urgent production fixes (from master; merge to master AND develop)
```

### Branch prefixes

| Prefix | Branches from | Merges into | Purpose |
|---|---|---|---|
| `feature/<name>` | `develop` | `develop` | Feature work |
| `hotfix/<name>` | `master` | `master` + `develop` | Urgent production fixes |
| `develop` | — | `master` | Integration branch |
| `master` | — | — | Production |

### Naming conventions

Use lowercase kebab-case. Keep names descriptive.

```
feature/plumbing-objects
feature/packfile-reader
hotfix/index-checksum
```

### Release tag names

Every release tag must have a human codename. Use an Ubuntu-style alphabetized pair:  
`{funny adjective} {animal name}`.

The adjective and the animal must start with the same letter. Advance alphabetically across releases. You may reuse Ubuntu animal names. Do not reuse Ubuntu adjectives. Choose a fresh funny adjective.

Never choose or apply the tag name alone. First propose a small set of candidate names. Then wait for the user to select one.

### Recommended worktree layout

```
gitz.git/                 bare repository
gitz-master/              worktree: master (always present)
gitz-develop/             worktree: develop (always present)
gitz-plumbing-objects/    worktree: feature/plumbing-objects (temporary)
gitz-hotfix-index/        worktree: hotfix/index-checksum (temporary)
go-git/                   reference clone (sibling, pinned)
```

## Concurrent work

- Parallel tasks must own disjoint files.
- Run changes to shared files sequentially.
- Use isolated worktrees for concurrent write tasks.
- Never let two writers share a dirty worktree.

### Git operations

- **Subagents / worker agents must not run git.** No `git add`, `commit`, `checkout`, `restore`, `reset`, `switch`, `merge`, `rebase`, `push`, `pull`, `clean`, or `worktree` from a worker.
- Only the **orchestrator** (main agent, with the human’s request) may run git, and only for the requested operation.
- Workers that “clean up” with `git restore` / `git checkout --` destroy other agents’ uncommitted work. That is forbidden.

## Progressive merging workflow

### Feature work to production

```bash
# 1. Create feature branch and worktree from develop
cd gitz.git
git worktree add ../gitz-my-feature -b feature/my-feature develop

# 2. Do work in the feature worktree
cd ../gitz-my-feature
# ... commit, iterate, run Bazel checks ...

# 3. Merge feature into develop
cd ../gitz-develop
git merge feature/my-feature

# 4. Clean up the feature worktree
cd ../gitz.git
git worktree remove ../gitz-my-feature
git branch -d feature/my-feature

# 5. When develop is ready, promote to master
cd ../gitz-master
git merge develop
git tag -a v1.2.0 -m "Release 1.2.0"
```

### Hotfix workflow

Hotfixes branch from master. Merge them into **master** and **develop**.

```bash
# 1. Create hotfix from master
cd gitz.git
git worktree add ../gitz-hotfix-xyz -b hotfix/xyz master

# 2. Fix and commit
cd ../gitz-hotfix-xyz
# ... fix, commit, run Bazel checks ...

# 3. Merge into master
cd ../gitz-master
git merge hotfix/xyz
git tag -a v1.1.1 -m "Hotfix 1.1.1"

# 4. Merge into develop so the fix is not lost
cd ../gitz-develop
git merge hotfix/xyz

# 5. Clean up
cd ../gitz.git
git worktree remove ../gitz-hotfix-xyz
git branch -d hotfix/xyz
```

### Merge direction rules

- Always merge upward: `feature → develop → master`.
- Never merge downward (for example master into develop) unless you complete a hotfix path.
- Never skip tiers. Do not merge a feature directly into master.
- Always merge from inside the **target** worktree. Change directory into the branch that receives the merge. Then run `git merge <source>`.
- Never merge from inside the bare repository. There is no working tree for conflict resolution.

## Checks and balances

Port quality is enforced by **Bazel tests under `//check:…`**, not by hand-run scripts or documentation checklists.

Run the complete acceptance suite:

```bash
bazel test //check:all
```

Required classes of check:

| Check | Bazel target (examples) | Role |
|---|---|---|
| **File inventory** | `//check:file_inventory` | Compare gitz surface to inventory; fail on missing/hollow packages |
| **Function / API inventory** | `//check:api_inventory` | Semantic IDs / exports for due packages |
| **Behavioral goldens** | `//check:goldens_smoke` | Known Git cases; fail on mismatch |
| **Metrics / allowlists** | `//check:metrics`, `//check:allowlists` | Thresholds, pin, overdue gaps |

### Rules for these checks

- Do not weaken, skip, or disable these targets without user approval.
- Prefer genrules and tests that read the pinned `go-git/` tree and gitz sources.
- When you add a go-git area to gitz, extend the inventories and goldens in the same change set when possible.
- Do not treat markdown text as a substitute for failing Bazel checks.

## Rules for AI agents

- When the user names a branch, work inside the matching worktree.
- Do not run `git checkout` or `git switch` in a worktree to a branch that another worktree already has checked out. That command fails.
- If a worktree for the needed branch does not exist, create it with `git worktree add`.
- Run git metadata commands (`log`, `status`, `diff`, `fetch`) from the relevant worktree so context is correct.
- Commits, stashes, and refs are shared across worktrees. They use one object store.
- Follow the progressive merge order: feature → develop → master. Never skip tiers.
- Create new feature branches from `develop`, not from `master`.
- Hotfix branches are the only exception. They branch from `master` and merge into `master` and `develop`.
- Always merge from inside the **target** worktree.
- After you merge a feature, remove its worktree and delete the branch.
- Keep the long-lived worktrees (`gitz-master`, `gitz-develop`) present. Feature and hotfix worktrees are temporary.
- Read go-git only from the sibling `go-git/` reference at the pinned revision.
- Port go-git behavior. Do not redesign Git semantics.
- Run concurrent tasks only when they own disjoint files.
- Always build and test with Bazel, rules_zig, and Zig 0.16. Honor the local `user.bazelrc` when it exists.
- Do not use system Zig for project verification.
- Do not treat markdown text as a substitute for failing Bazel checks.

## Writing style for new agent docs

Write new project procedure docs in **ASD-STE100** style when practical:

- Use short sentences.
- Use active voice.
- Use simple present tense for descriptions.
- Use imperative mood for procedures.
- Put one main idea in each sentence.
- Use the same technical term for the same thing every time.
- Prefer concrete steps over abstract policy essays.
