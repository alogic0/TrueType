//! Checked big-endian access within an enclosing table or record.
const std = @import("std");
pub const Error = error{ EndOfStream, InvalidFontData };

bytes: []const u8,
const Reader = @This();

pub fn span(self: Reader, offset: usize, length: usize) Error![]const u8 {
    if (offset > self.bytes.len or length > self.bytes.len - offset) return error.EndOfStream;
    return self.bytes[offset..][0..length];
}

pub fn read(self: Reader, comptime T: type, offset: usize) Error!T {
    const width = @bitSizeOf(T) / 8;
    const bytes = try self.span(offset, width);
    return std.mem.readInt(T, bytes[0..width], .big);
}

pub fn tail(self: Reader, offset: usize) Error!Reader {
    if (offset > self.bytes.len) return error.EndOfStream;
    return .{ .bytes = self.bytes[offset..] };
}

pub fn records(self: Reader, offset: usize, count: usize, size: usize) Error![]const u8 {
    if (size == 0) return error.InvalidFontData;
    if (offset > self.bytes.len or count > (self.bytes.len - offset) / size) return error.EndOfStream;
    return self.bytes[offset..][0 .. count * size];
}
