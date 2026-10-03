//! Replay a raw font, or run seeded mutations: zig build fuzz-replay -- [file]
const std = @import("std");
const harness = @import("fuzz/harness.zig");
const seeds = @import("fuzz/seeds.zig");

var current_seed: u64 = 0;
var current_iteration: usize = 0;
pub const panic = std.debug.FullPanic(reportPanic);
fn reportPanic(message: []const u8, address: ?usize) noreturn {
    std.log.err("mutation failure: seed=0x{x}, iteration={d}", .{ current_seed, current_iteration });
    std.debug.defaultPanic(message, address);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    const smith_input = args.len == 3 and std.mem.eql(u8, args[1], "--smith");
    if (args.len == 2 or smith_input) {
        const path = args[if (smith_input) 2 else 1];
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(harness.max_input + 5));
        defer init.gpa.free(bytes);
        var input = bytes;
        if (smith_input) {
            if (bytes.len < 4) return error.InvalidArguments;
            const length = std.mem.readInt(u32, bytes[0..4], .little);
            if (length > bytes.len - 4) return error.InvalidArguments;
            input = bytes[4..][0..length];
        }
        if (input.len > harness.max_input) return error.InputTooLarge;
        harness.exercise(input, .bitmap);
        std.log.info("replayed {s} ({d} bytes)", .{ path, input.len });
        return;
    }
    if (args.len != 1 and args.len != 4) return error.InvalidArguments;
    const seed: u64 = if (args.len == 4) try std.fmt.parseInt(u64, args[1], 0) else 0x3abb56a7;
    const count: usize = if (args.len == 4) try std.fmt.parseInt(usize, args[2], 0) else 2000;
    // Optional third argument selects exactly one reproducible mutation index.
    const replay: ?usize = if (args.len == 4 and !std.mem.eql(u8, args[3], "all")) try std.fmt.parseInt(usize, args[3], 0) else null;
    if (replay) |index| if (index >= count) return error.InvalidArguments;
    current_seed = seed;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var storage: [harness.max_input]u8 = undefined;
    harness.exercise(&seeds.tt, .bitmap);
    harness.exercise(seeds.cff, .bitmap);
    for (0..count) |iteration| {
        current_iteration = iteration;
        const source: []const u8 = if (iteration % 2 == 0) &seeds.tt else seeds.cff;
        @memcpy(storage[0..source.len], source);
        var len = source.len;
        const changes = random.intRangeAtMost(usize, 1, 8);
        for (0..changes) |_| {
            const at = random.uintLessThan(usize, len);
            switch (random.uintLessThan(u8, 4)) {
                0 => storage[at] ^= @as(u8, 1) << random.int(u3),
                1 => storage[at] = random.int(u8),
                2 => @memset(storage[at..@min(at + 4, len)], 0xff),
                3 => @memset(storage[at..@min(at + 4, len)], 0),
                else => unreachable,
            }
        }
        if (iteration % 5 == 0) len = random.intRangeAtMost(usize, 0, len);
        if (replay == null or replay.? == iteration) {
            // Print before execution so a crash records its reproduction key.
            if (replay != null) std.log.info("seed=0x{x} iteration={d} bytes={d}", .{ seed, iteration, len });
            harness.exercise(storage[0..len], .bitmap);
        }
    }
    std.log.info("mutation campaign complete: seed=0x{x}, iterations={d}, replay={?d}", .{ seed, count, replay });
}
