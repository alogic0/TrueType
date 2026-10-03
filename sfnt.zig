//! Font directory and fixed-size metadata validation.
const std = @import("std");
const Reader = @import("reader.zig");
pub const Error = Reader.Error || error{ MissingRequiredTable, UnsupportedFontVersion, DuplicateTable };
pub const TableId = enum { cmap, loca, head, glyf, hhea, hmtx, kern, GPOS, maxp };
pub const table_count = @typeInfo(TableId).@"enum".field_names.len;

pub const Directory = struct {
    bytes: []const u8,
    offsets: [table_count]u32 = @splat(0),
    lengths: [table_count]u32 = @splat(0),
    cff_offset: u32 = 0,
    cff_length: u32 = 0,

    pub fn table(self: Directory, id: TableId) Error!Reader {
        const i = @backingInt(id);
        if (self.offsets[i] == 0) return error.MissingRequiredTable;
        return .{ .bytes = try (Reader{ .bytes = self.bytes }).span(self.offsets[i], self.lengths[i]) };
    }

    pub fn init(bytes: []const u8) Error!Directory {
        const source: Reader = .{ .bytes = bytes };
        _ = try source.span(0, 12);
        if (bytes.len > std.math.maxInt(u32)) return error.InvalidFontData;
        switch (try source.read(u32, 0)) {
            0x00010000, 0x4f54544f, 0x74727565 => {}, // sfnt TrueType, OTTO, legacy true
            else => return error.UnsupportedFontVersion,
        }
        const count: usize = try source.read(u16, 4);
        _ = try source.records(12, count, 16);
        const directory_end = 12 + count * 16;
        var result: Directory = .{ .bytes = bytes };
        for (0..count) |i| {
            const record = 12 + i * 16;
            const tag = try source.span(record, 4);
            const offset = try source.read(u32, record + 8);
            const length = try source.read(u32, record + 12);
            _ = try source.span(offset, length);
            if (offset < directory_end) return error.InvalidFontData;
            if (std.mem.eql(u8, tag, "CFF ")) {
                if (result.cff_offset != 0) return error.DuplicateTable;
                result.cff_offset = offset;
                result.cff_length = length;
            }
            inline for (@typeInfo(TableId).@"enum".field_names, 0..) |name, index| {
                if (std.mem.eql(u8, tag, name)) {
                    if (result.offsets[index] != 0) return error.DuplicateTable;
                    result.offsets[index] = offset;
                    result.lengths[index] = length;
                }
            }
        }
        return result;
    }

    pub fn metadata(self: Directory) Error!struct { glyphs: u16, location_format: u16 } {
        const head = try self.table(.head);
        const hhea = try self.table(.hhea);
        const maxp = try self.table(.maxp);
        const hmtx = try self.table(.hmtx);
        _ = try head.span(0, 54);
        _ = try hhea.span(0, 36);
        if (try head.read(u32, 0) != 0x10000 or try hhea.read(u32, 0) != 0x10000)
            return error.UnsupportedFontVersion;
        const maxp_version = try maxp.read(u32, 0);
        if (maxp_version == 0x10000) {
            _ = try maxp.span(0, 32);
        } else if (maxp_version != 0x5000) return error.UnsupportedFontVersion;
        const glyphs = try maxp.read(u16, 4);
        const long_metrics = try hhea.read(u16, 34);
        if (glyphs == 0 or long_metrics == 0 or long_metrics > glyphs) return error.InvalidFontData;
        if (try hhea.read(i16, 4) <= try hhea.read(i16, 6)) return error.InvalidFontData;
        const metric_bytes = @as(usize, long_metrics) * 4 + @as(usize, glyphs - long_metrics) * 2;
        _ = try hmtx.span(0, metric_bytes);
        const location_format = try head.read(u16, 50);
        if (self.offsets[@backingInt(TableId.glyf)] != 0) {
            if (location_format > 1 or maxp_version != 0x10000) return error.InvalidFontData;
            const loca = try self.table(.loca);
            _ = try loca.records(0, @as(usize, glyphs) + 1, if (location_format == 0) 2 else 4);
        } else if (self.cff_offset == 0) return error.MissingRequiredTable;
        return .{ .glyphs = glyphs, .location_format = location_format };
    }
};
