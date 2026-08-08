//! Unit tests for submodule core (go-git submodule_test.go subset, hermetic Mem).

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const memory = @import("memory");
const fs_pkg = @import("fs");
const gitconfig = @import("gitconfig");
const index_format = @import("index");
const worktree = @import("worktree");

const submodule = @import("root.zig");

const Allocator = std.mem.Allocator;
const Host = submodule.Host;

const gitmodules_basic =
    "[submodule \"basic\"]\n" ++
    "\tpath = basic\n" ++
    "\turl = https://github.com/example/basic.git\n" ++
    "[submodule \"nested\"]\n" ++
    "\tpath = libs/nested\n" ++
    "\turl = https://github.com/example/nested.git\n" ++
    "\tbranch = main\n";


const expected_basic = "6ecf0ef2c2dffb796033e5a02219af86ec6584e5";
const expected_nested = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

const Fixture = struct {
    gpa: Allocator,
    sto: *memory.Storage,
    fs: *fs_pkg.Mem,
    host: Host,

    fn create(gpa: Allocator) !Fixture {
        const sto = try memory.newStorage(gpa);
        errdefer {
            sto.deinit();
            gpa.destroy(sto);
        }
        const fs = try gpa.create(fs_pkg.Mem);
        errdefer gpa.destroy(fs);
        fs.* = try fs_pkg.Mem.init(gpa);
        errdefer fs.deinit();

        // Write .gitmodules
        {
            var f = try fs.create(submodule.gitmodules_file);
            defer f.close() catch {};
            _ = try f.write(gitmodules_basic);
        }

        // Index gitlink entries (mode Submodule).
        const idx = try gpa.create(index_format.Index);
        idx.* = index_format.Index.init(gpa);
        idx.version = 2;
        {
            const e = try idx.add("basic");
            e.mode = filemode.Submodule;
            e.hash = plumbing.newHash(expected_basic);
        }
        {
            const e = try idx.add("libs/nested");
            e.mode = filemode.Submodule;
            e.hash = plumbing.newHash(expected_nested);
        }
        sto.setIndex(idx);

        return .{
            .gpa = gpa,
            .sto = sto,
            .fs = fs,
            .host = Host.init(gpa, sto, fs),
        };
    }

    fn deinit(self: *Fixture) void {
        self.host.deinit();
        self.fs.deinit();
        self.gpa.destroy(self.fs);
        self.sto.deinit();
        self.gpa.destroy(self.sto);
        self.* = undefined;
    }
};

test "listSubmodules reads .gitmodules" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    var list = try submodule.listSubmodules(&fx.host, null);
    defer list.free(gpa);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(!list.items[0].initialized);
    try std.testing.expect(!list.items[1].initialized);

    // Names present (hash map iteration order is not fixed).
    var saw_basic = false;
    var saw_nested = false;
    for (list.items) |sm| {
        const n = sm.config().name;
        if (std.mem.eql(u8, n, "basic")) {
            saw_basic = true;
            try std.testing.expectEqualStrings("basic", sm.config().path);
            try std.testing.expectEqualStrings("https://github.com/example/basic.git", sm.config().url);
        } else if (std.mem.eql(u8, n, "nested")) {
            saw_nested = true;
            try std.testing.expectEqualStrings("libs/nested", sm.config().path);
            try std.testing.expectEqualStrings("main", sm.config().branch);
        }
    }
    try std.testing.expect(saw_basic);
    try std.testing.expect(saw_nested);
}

test "getSubmodule by name and not found" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    const sm = try submodule.getSubmodule(&fx.host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }
    try std.testing.expectEqualStrings("basic", sm.config().name);

    try std.testing.expectError(error.SubmoduleNotFound, submodule.getSubmodule(&fx.host, "missing"));
}

test "Init records initialized; second Init errors" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    const sm = try submodule.getSubmodule(&fx.host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    try std.testing.expect(!sm.initialized);
    try sm.init();
    try std.testing.expect(sm.initialized);
    try std.testing.expect(fx.host.isInitialized("basic"));

    try std.testing.expectError(error.SubmoduleAlreadyInitialized, sm.init());

    // Re-list: basic is initialized, nested is not.
    var list = try submodule.listSubmodules(&fx.host, null);
    defer list.free(gpa);
    for (list.items) |m| {
        if (std.mem.eql(u8, m.config().name, "basic")) {
            try std.testing.expect(m.initialized);
        } else {
            try std.testing.expect(!m.initialized);
        }
    }
}

test "Submodules.Init initializes all" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    var list = try submodule.listSubmodules(&fx.host, null);
    defer list.free(gpa);
    try list.initAll();

    for (list.items) |m| {
        try std.testing.expect(m.initialized);
    }

    var list2 = try submodule.listSubmodules(&fx.host, null);
    defer list2.free(gpa);
    for (list2.items) |m| {
        try std.testing.expect(m.initialized);
    }
}

test "Status uninitialized: expected from index gitlink, current zero" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    const sm = try submodule.getSubmodule(&fx.host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    const st = try sm.status();
    try std.testing.expectEqualStrings("basic", st.path);
    try std.testing.expect(st.current.isZero());
    try std.testing.expect(st.expected.eql(plumbing.newHash(expected_basic)));
    try std.testing.expect(!st.isClean());

    const line = try st.string(gpa);
    defer gpa.free(line);
    try std.testing.expect(line[0] == '-');
    try std.testing.expect(std.mem.indexOf(u8, line, expected_basic) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "basic") != null);
}

test "Status initialized with module HEAD matches expected is clean" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    const sm = try submodule.getSubmodule(&fx.host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }
    try sm.init();

    const mod = try fx.sto.module("basic");
    const h = plumbing.newHash(expected_basic);
    try mod.setReference(plumbing.Reference.newHashReference(plumbing.HEAD, h));

    const st = try sm.status();
    try std.testing.expect(st.current.eql(h));
    try std.testing.expect(st.expected.eql(h));
    try std.testing.expect(st.isClean());

    const line = try st.string(gpa);
    defer gpa.free(line);
    try std.testing.expect(line[0] == ' ');
}

test "Status initialized dirty when HEAD differs" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    const sm = try submodule.getSubmodule(&fx.host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }
    try sm.init();

    const mod = try fx.sto.module("basic");
    const other = plumbing.newHash("1111111111111111111111111111111111111111");
    try mod.setReference(plumbing.Reference.newHashReference(plumbing.HEAD, other));

    const st = try sm.status();
    try std.testing.expect(!st.isClean());
    const line = try st.string(gpa);
    defer gpa.free(line);
    try std.testing.expect(line[0] == '+');
}

test "Submodules.Status length and free" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    var list = try submodule.listSubmodules(&fx.host, null);
    defer list.free(gpa);

    var statuses = try list.status(gpa);
    defer statuses.free(gpa);
    try std.testing.expectEqual(@as(usize, 2), statuses.items.len);

    const multi = try statuses.string(gpa);
    defer gpa.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "basic") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "libs/nested") != null);
}

test "Update without Init returns SubmoduleNotInitialized" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    const sm = try submodule.getSubmodule(&fx.host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    const o = submodule.SubmoduleUpdateOptions{};
    try std.testing.expectError(error.SubmoduleNotInitialized, sm.update(&o));
}

test "Update with Init and NoFetch sets module HEAD and checkouts worktree" {
    // Objects already in module store: NoFetch still materializes files (go-git Checkout).
    const gpa = std.testing.allocator;

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const mod = try sto.module("basic");
    const head = try seedSimpleWorktree(mod, gpa, "hello", "hello.txt");

    const fs = try gpa.create(fs_pkg.Mem);
    defer {
        fs.deinit();
        gpa.destroy(fs);
    }
    fs.* = try fs_pkg.Mem.init(gpa);
    {
        var f = try fs.create(submodule.gitmodules_file);
        defer f.close() catch {};
        _ = try f.write(
            "[submodule \"basic\"]\n" ++
                "\tpath = basic\n" ++
                "\turl = https://github.com/example/basic.git\n",
        );
    }
    const idx = try gpa.create(index_format.Index);
    idx.* = index_format.Index.init(gpa);
    idx.version = 2;
    {
        const e = try idx.add("basic");
        e.mode = filemode.Submodule;
        e.hash = head;
    }
    sto.setIndex(idx);

    var host = Host.init(gpa, sto, fs);
    defer host.deinit();

    const sm = try submodule.getSubmodule(&host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    const o = submodule.SubmoduleUpdateOptions{ .init = true, .no_fetch = true };
    try sm.update(&o);
    try std.testing.expect(sm.initialized);

    const mod_head = try mod.reference(plumbing.HEAD);
    try std.testing.expect(mod_head.hash.eql(head));

    const content = try readHostFile(gpa, fs, "basic/hello.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hello", content);

    const st = try sm.status();
    try std.testing.expect(st.isClean());
}

test "Update empty URL when fetch required returns SubmoduleEmptyURL" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    const sm = try submodule.getSubmodule(&fx.host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }
    try sm.init();

    // Clear URL so fetch cannot open a remote.
    if (sm.c.url.len > 0) gpa.free(sm.c.url);
    sm.c.url = "";

    const o = submodule.SubmoduleUpdateOptions{ .no_fetch = false };
    try std.testing.expectError(error.SubmoduleEmptyURL, sm.update(&o));
}

test "Update fetches module objects via embedded MapLoader" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    const fixtures = @import("transport_test_fixtures");
    const server_pkg = @import("server");
    defer sync.deinitPools(gpa);

    // Remote repo with a real commit graph.
    const remote_sto = try memory.newStorage(gpa);
    defer {
        remote_sto.deinit();
        gpa.destroy(remote_sto);
    }
    const head = try fixtures.populateRepo(remote_sto, gpa);
    const sub_url = "file://submodule-basic-remote";

    // Superproject: .gitmodules + gitlink at remote tip.
    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const fs = try gpa.create(fs_pkg.Mem);
    defer {
        fs.deinit();
        gpa.destroy(fs);
    }
    fs.* = try fs_pkg.Mem.init(gpa);
    {
        var f = try fs.create(submodule.gitmodules_file);
        defer f.close() catch {};
        _ = try f.write(
            "[submodule \"basic\"]\n" ++
                "\tpath = basic\n" ++
                "\turl = file://submodule-basic-remote\n",
        );
    }
    const idx = try gpa.create(index_format.Index);
    idx.* = index_format.Index.init(gpa);
    idx.version = 2;
    {
        const e = try idx.add("basic");
        e.mode = filemode.Submodule;
        e.hash = head;
    }
    sto.setIndex(idx);

    var host = Host.init(gpa, sto, fs);
    defer host.deinit();

    var loader = server_pkg.MapLoader.init(gpa);
    defer loader.deinit();
    var ep = try fixtures.makeEndpoint(gpa, sub_url);
    defer ep.deinit();
    try loader.put(&ep, remote_sto);
    var client = server_pkg.newClient(gpa, loader.asLoader());

    const sm = try submodule.getSubmodule(&host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    const o = submodule.SubmoduleUpdateOptions{
        .init = true,
        .no_fetch = false,
        .embedded = &client,
    };
    try sm.update(&o);
    try std.testing.expect(sm.initialized);

    const mod = try sto.module("basic");
    const commit_obj = try mod.encodedObject(.commit, head);
    try std.testing.expect(commit_obj.hash().eql(head));

    const mod_head = try mod.reference(plumbing.HEAD);
    try std.testing.expect(mod_head.hash.eql(head));

    // Host FS materialization (go-git Worktree.Checkout after fetch).
    const content = try readHostFile(gpa, fs, "basic/hello.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hello", content);

    const st = try sm.status();
    try std.testing.expect(st.isClean());
    try std.testing.expect(st.expected.eql(head));
    try std.testing.expect(st.current.eql(head));
}

test "Update remote_url override fetches when config URL empty" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    const fixtures = @import("transport_test_fixtures");
    const server_pkg = @import("server");
    defer sync.deinitPools(gpa);

    const remote_sto = try memory.newStorage(gpa);
    defer {
        remote_sto.deinit();
        gpa.destroy(remote_sto);
    }
    const head = try fixtures.populateRepo(remote_sto, gpa);
    const sub_url = "file://submodule-url-override";

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const fs = try gpa.create(fs_pkg.Mem);
    defer {
        fs.deinit();
        gpa.destroy(fs);
    }
    fs.* = try fs_pkg.Mem.init(gpa);
    {
        var f = try fs.create(submodule.gitmodules_file);
        defer f.close() catch {};
        // Empty url in modules; override via options.remote_url.
        _ = try f.write(
            "[submodule \"basic\"]\n" ++
                "\tpath = basic\n" ++
                "\turl = \n",
        );
    }
    const idx = try gpa.create(index_format.Index);
    idx.* = index_format.Index.init(gpa);
    idx.version = 2;
    {
        const e = try idx.add("basic");
        e.mode = filemode.Submodule;
        e.hash = head;
    }
    sto.setIndex(idx);

    var host = Host.init(gpa, sto, fs);
    defer host.deinit();

    var loader = server_pkg.MapLoader.init(gpa);
    defer loader.deinit();
    var ep = try fixtures.makeEndpoint(gpa, sub_url);
    defer ep.deinit();
    try loader.put(&ep, remote_sto);
    var client = server_pkg.newClient(gpa, loader.asLoader());

    const sm = try submodule.getSubmodule(&host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    // Config URL may be empty after parse; force override.
    if (sm.c.url.len > 0) gpa.free(sm.c.url);
    sm.c.url = "";

    const o = submodule.SubmoduleUpdateOptions{
        .init = true,
        .no_fetch = false,
        .embedded = &client,
        .remote_url = sub_url,
    };
    try sm.update(&o);

    const mod = try sto.module("basic");
    _ = try mod.encodedObject(.commit, head);
    const mod_head = try mod.reference(plumbing.HEAD);
    try std.testing.expect(mod_head.hash.eql(head));

    const content = try readHostFile(gpa, fs, "basic/hello.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hello", content);
}

test "GitModulesSymlink rejected" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    try fx.fs.remove(submodule.gitmodules_file);
    {
        var f = try fx.fs.create("badfile");
        defer f.close() catch {};
        _ = try f.write("x");
    }
    try fx.fs.symlink("badfile", submodule.gitmodules_file);

    try std.testing.expectError(error.GitModulesSymlink, submodule.listSubmodules(&fx.host, null));
}

test "missing .gitmodules yields empty list" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var fs = try fs_pkg.Mem.init(gpa);
    defer fs.deinit();
    var host = Host.init(gpa, sto, &fs);
    defer host.deinit();

    var list = try submodule.listSubmodules(&host, null);
    defer list.free(gpa);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "list with pre-parsed Modules" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    var modules = try gitconfig.Modules.create(gpa);
    defer modules.deinit();
    try modules.unmarshal(
        "[submodule \"only\"]\n" ++
            "\tpath = only\n" ++
            "\turl = https://example.com/only.git\n",
    );

    var list = try submodule.listSubmodules(&fx.host, &modules);
    defer list.free(gpa);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("only", list.items[0].config().name);
}

test "Host.fromWorktree shares storer and filesystem" {
    const gpa = std.testing.allocator;
    var fx = try Fixture.create(gpa);
    defer fx.deinit();

    var w = worktree.newWorktree(gpa, fx.sto, fx.fs);
    var host = Host.fromWorktree(&w);
    defer host.deinit();

    try std.testing.expect(host.storer == fx.sto);
    try std.testing.expect(host.filesystem == fx.fs);

    var list = try submodule.listFromWorktree(&host, &w);
    defer list.free(gpa);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "Status when path missing from index leaves expected zero" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var fs = try fs_pkg.Mem.init(gpa);
    defer fs.deinit();
    {
        var f = try fs.create(submodule.gitmodules_file);
        defer f.close() catch {};
        _ = try f.write(
            "[submodule \"solo\"]\n" ++
                "\tpath = solo\n" ++
                "\turl = https://example.com/solo.git\n",
        );
    }
    var host = Host.init(gpa, sto, &fs);
    defer host.deinit();

    const sm = try submodule.getSubmodule(&host, "solo");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }
    const st = try sm.status();
    try std.testing.expect(st.expected.isZero());
    try std.testing.expect(st.current.isZero());
}

test "expectedFromEntry returns hash" {
    var e: index_format.Entry = .{
        .mode = filemode.Submodule,
        .hash = plumbing.newHash(expected_basic),
        .name = "basic",
    };
    try std.testing.expect(submodule.expectedFromEntry(&e).eql(plumbing.newHash(expected_basic)));
}

test "Update second fetch is AlreadyUpToDate and status stays clean" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    const fixtures = @import("transport_test_fixtures");
    const server_pkg = @import("server");
    defer sync.deinitPools(gpa);

    const remote_sto = try memory.newStorage(gpa);
    defer {
        remote_sto.deinit();
        gpa.destroy(remote_sto);
    }
    const head = try fixtures.populateRepo(remote_sto, gpa);
    const sub_url = "file://submodule-already-up-to-date";

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const fs = try gpa.create(fs_pkg.Mem);
    defer {
        fs.deinit();
        gpa.destroy(fs);
    }
    fs.* = try fs_pkg.Mem.init(gpa);
    {
        var f = try fs.create(submodule.gitmodules_file);
        defer f.close() catch {};
        _ = try f.write(
            "[submodule \"basic\"]\n" ++
                "\tpath = basic\n" ++
                "\turl = file://submodule-already-up-to-date\n",
        );
    }
    const idx = try gpa.create(index_format.Index);
    idx.* = index_format.Index.init(gpa);
    idx.version = 2;
    {
        const e = try idx.add("basic");
        e.mode = filemode.Submodule;
        e.hash = head;
    }
    sto.setIndex(idx);

    var host = Host.init(gpa, sto, fs);
    defer host.deinit();

    var loader = server_pkg.MapLoader.init(gpa);
    defer loader.deinit();
    var ep = try fixtures.makeEndpoint(gpa, sub_url);
    defer ep.deinit();
    try loader.put(&ep, remote_sto);
    var client = server_pkg.newClient(gpa, loader.asLoader());

    const sm = try submodule.getSubmodule(&host, "basic");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    const o = submodule.SubmoduleUpdateOptions{
        .init = true,
        .no_fetch = false,
        .embedded = &client,
    };
    try sm.update(&o);
    // Second update: remote returns AlreadyUpToDate; still succeeds.
    try sm.update(&o);

    const st = try sm.status();
    try std.testing.expect(st.isClean());
    try std.testing.expect(st.current.eql(head));
}

test "Update recurse discovers nested gitlink from module commit" {
    // Superproject gitlink → parent commit in module storage that embeds:
    //   .gitmodules naming "child" + tree gitlink at path "child".
    // Recurse=1 sets nested module HEAD and materializes under parent/child/.
    const gpa = std.testing.allocator;

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    // Parent graph lives in superproject's module storage for "parent".
    const mod = try sto.module("parent");
    const child_mod = try mod.module("child");
    const nested_commit = try seedSimpleWorktree(child_mod, gpa, "nested-body", "nested.txt");
    const parent_hash = try seedNestedParentIn(mod, gpa, nested_commit);

    const fs = try gpa.create(fs_pkg.Mem);
    defer {
        fs.deinit();
        gpa.destroy(fs);
    }
    fs.* = try fs_pkg.Mem.init(gpa);
    {
        var f = try fs.create(submodule.gitmodules_file);
        defer f.close() catch {};
        _ = try f.write(
            "[submodule \"parent\"]\n" ++
                "\tpath = parent\n" ++
                "\turl = https://example.com/parent.git\n",
        );
    }
    const idx = try gpa.create(index_format.Index);
    idx.* = index_format.Index.init(gpa);
    idx.version = 2;
    {
        const e = try idx.add("parent");
        e.mode = filemode.Submodule;
        e.hash = parent_hash;
    }
    sto.setIndex(idx);

    var host = Host.init(gpa, sto, fs);
    defer host.deinit();

    const sm = try submodule.getSubmodule(&host, "parent");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    const o = submodule.SubmoduleUpdateOptions{
        .init = true,
        .no_fetch = true,
        .recurse_submodules = 1,
    };
    try sm.update(&o);

    // Parent module HEAD at parent commit.
    const parent_head = try mod.reference(plumbing.HEAD);
    try std.testing.expect(parent_head.hash.eql(parent_hash));

    // Nested module (under parent storage) HEAD at nested gitlink.
    const child_head = try child_mod.reference(plumbing.HEAD);
    try std.testing.expect(child_head.hash.eql(nested_commit));

    // Nested files land under parent module path on host FS.
    const nested_content = try readHostFile(gpa, fs, "parent/child/nested.txt");
    defer gpa.free(nested_content);
    try std.testing.expectEqualStrings("nested-body", nested_content);

    // Parent tree also materializes .gitmodules at parent path.
    const gm = try readHostFile(gpa, fs, "parent/.gitmodules");
    defer gpa.free(gm);
    try std.testing.expect(std.mem.indexOf(u8, gm, "child") != null);
}

test "Update recurse zero is intentional no-op for nested" {
    const gpa = std.testing.allocator;

    const nested_commit = plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc");
    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const mod = try sto.module("parent");
    const parent_hash = try seedNestedParentIn(mod, gpa, nested_commit);

    const fs = try gpa.create(fs_pkg.Mem);
    defer {
        fs.deinit();
        gpa.destroy(fs);
    }
    fs.* = try fs_pkg.Mem.init(gpa);
    {
        var f = try fs.create(submodule.gitmodules_file);
        defer f.close() catch {};
        _ = try f.write(
            "[submodule \"parent\"]\n" ++
                "\tpath = parent\n" ++
                "\turl = https://example.com/parent.git\n",
        );
    }
    const idx = try gpa.create(index_format.Index);
    idx.* = index_format.Index.init(gpa);
    idx.version = 2;
    {
        const e = try idx.add("parent");
        e.mode = filemode.Submodule;
        e.hash = parent_hash;
    }
    sto.setIndex(idx);

    var host = Host.init(gpa, sto, fs);
    defer host.deinit();

    const sm = try submodule.getSubmodule(&host, "parent");
    defer {
        sm.deinit();
        gpa.destroy(sm);
    }

    const o = submodule.SubmoduleUpdateOptions{
        .init = true,
        .no_fetch = true,
        .recurse_submodules = submodule.no_recurse_submodules,
    };
    try sm.update(&o);

    // Nested module may exist empty from module() calls, but HEAD must not be set.
    const child_mod = try mod.module("child");
    try std.testing.expectError(error.ReferenceNotFound, child_mod.reference(plumbing.HEAD));
}

// ---------------------------------------------------------------------------
// Object-graph helpers for recursion tests
// ---------------------------------------------------------------------------

fn storeBlob(s: *memory.Storage, content: []const u8) !plumbing.Hash {
    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write(content);
    return s.setEncodedObject(obj);
}

fn appendTreeEntry(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    mode_octal: []const u8,
    name: []const u8,
    hash: plumbing.Hash,
) !void {
    try buf.appendSlice(allocator, mode_octal);
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, 0);
    try buf.appendSlice(allocator, hash.slice());
}

fn storeTree(s: *memory.Storage, allocator: Allocator, entries: []const struct {
    mode: []const u8,
    name: []const u8,
    hash: plumbing.Hash,
}) !plumbing.Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (entries) |e| {
        try appendTreeEntry(&buf, allocator, e.mode, e.name, e.hash);
    }
    const obj = try s.newEncodedObject();
    obj.setType(.tree);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn storeCommit(
    s: *memory.Storage,
    allocator: Allocator,
    tree: plumbing.Hash,
    message: []const u8,
) !plumbing.Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var tree_hex: [plumbing.MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "author Test <test@example.com> 1000000000 +0000\n");
    try buf.appendSlice(allocator, "committer Test <test@example.com> 1000000000 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, message);

    const obj = try s.newEncodedObject();
    obj.setType(.commit);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

/// Parent commit: tree with `.gitmodules` + gitlink `child` → nested_commit.
fn seedNestedParentIn(s: *memory.Storage, allocator: Allocator, nested_commit: plumbing.Hash) !plumbing.Hash {
    const gm_blob = try storeBlob(s,
        "[submodule \"child\"]\n" ++
            "\tpath = child\n" ++
            "\turl = https://example.com/child.git\n",
    );
    // Tree entries must be sorted: .gitmodules before child (git name order).
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = ".gitmodules", .hash = gm_blob },
        .{ .mode = "160000", .name = "child", .hash = nested_commit },
    });
    return try storeCommit(s, allocator, tree, "parent with nested\n");
}

/// Blob → tree → commit (no refs) for NoFetch / nested object graphs.
fn seedSimpleWorktree(
    s: *memory.Storage,
    allocator: Allocator,
    content: []const u8,
    path: []const u8,
) !plumbing.Hash {
    const blob = try storeBlob(s, content);
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = path, .hash = blob },
    });
    return try storeCommit(s, allocator, tree, "seed worktree\n");
}

/// Read entire file from host Mem FS (test helper).
fn readHostFile(allocator: Allocator, filesystem: *fs_pkg.Mem, path: []const u8) ![]u8 {
    var f = try filesystem.open(path);
    defer f.close() catch {};
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}
