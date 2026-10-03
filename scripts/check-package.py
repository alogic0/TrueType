#!/usr/bin/env python3
"""Build a consumer using only package-manifest paths, outside the checkout."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
zig = shutil.which(os.environ.get("ZIG", "zig"))
if zig is None:
    raise SystemExit("Zig compiler not found")
zig = str(Path(zig).resolve())
manifest = (root / "build.zig.zon").read_text()
paths = re.findall(r'"([^"]+)"', manifest.split(".paths = .{", 1)[1])
with tempfile.TemporaryDirectory(prefix="truetype-package-") as work:
    work = Path(work)
    package = work / "package"
    package.mkdir()
    for name in paths:
        source = root / name
        target = package / name
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    (work / "build.zig.zon").write_text('''.{
    .name = .consumer,
    .fingerprint = 0x705b3727ff2b9938,
    .version = "0.0.0",
    .dependencies = .{ .TrueType = .{ .path = "package" } },
    .paths = .{ "" },
}
''')
    (work / "build.zig").write_text('''const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const dependency = b.dependency("TrueType", .{ .target = target });
    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target }),
    });
    exe.root_module.addImport("TrueType", dependency.module("TrueType"));
    b.default_step.dependOn(&b.addRunArtifact(exe).step);
}
''')
    (work / "main.zig").write_text('''const std = @import("std");
const TrueType = @import("TrueType");
pub fn main() !void {
    if (TrueType.load(&.{})) |_| return error.AcceptedEmptyFont else |err| {
        if (err != error.EndOfStream) return err;
    }
    var workspace: TrueType.RasterizerWorkspace = .init(std.heap.page_allocator);
    defer workspace.deinit();
    workspace.release();
}
''')
    subprocess.run([zig, "build", "--summary", "all"], cwd=work, check=True)
    subprocess.run([zig, "build", "examples", "--summary", "all"], cwd=package, check=True)
print("Manifest-only consumer and packaged example passed")
