//! Non-path Type 2 operators. The interpreter owns the stack and its lifetime.
const std = @import("std");

pub const Error = error{ StackUnderflow, PushStackOverflow, InvalidCffOperand, CffNumericOverflow, UninitializedCffStorage };

pub fn integer(value: f64) Error!i32 {
    if (!std.math.isFinite(value) or @trunc(value) != value or value < -2147483648 or value > 2147483647)
        return error.InvalidCffOperand;
    return @intFromFloat(value);
}

/// Returns false when the operator belongs to another group.
pub fn arithmetic(op: u8, s: *[48]f64, sp: *u32) Error!bool {
    const required: u32 = switch (op) {
        9, 14, 18, 26, 27, 29 => 1,
        10, 11, 12, 24, 28, 30 => 2,
        else => return false,
    };
    if (sp.* < required) return error.StackUnderflow;
    const top = sp.* - 1;
    switch (op) {
        9 => s[top] = @abs(s[top]),
        10, 11, 12, 24 => {
            const a = s[top - 1];
            const b = s[top];
            if (op == 12 and b == 0) return error.InvalidCffOperand;
            const result = switch (op) {
                10 => a + b,
                11 => a - b,
                12 => a / b,
                24 => a * b,
                else => unreachable,
            };
            if (!std.math.isFinite(result)) return error.CffNumericOverflow;
            s[top - 1] = result;
            sp.* -= 1;
        },
        14 => s[top] = -s[top],
        18 => sp.* -= 1,
        26 => {
            if (s[top] < 0) return error.InvalidCffOperand;
            s[top] = @sqrt(s[top]);
        },
        27 => {
            if (sp.* == s.len) return error.PushStackOverflow;
            s[sp.*] = s[top];
            sp.* += 1;
        },
        28 => std.mem.swap(f64, &s[top], &s[top - 1]),
        29 => {
            const index: u32 = @intCast(@max(0, try integer(s[top])));
            if (index >= top) return error.InvalidCffOperand;
            s[top] = s[top - 1 - index];
        },
        30 => {
            const count = try integer(s[top - 1]);
            const shift = try integer(s[top]);
            if (count < 0 or count > sp.* - 2) return error.InvalidCffOperand;
            sp.* -= 2;
            if (count == 0) return true;
            const n: u32 = @intCast(count);
            const rotation: u32 = @intCast(@mod(shift, count));
            // At most 48 elements: a bounded stack copy avoids allocation.
            var copy: [48]f64 = undefined;
            const start = sp.* - n;
            @memcpy(copy[0..n], s[start..sp.*]);
            for (0..n) |i| s[start + (i + rotation) % n] = copy[i];
        },
        else => unreachable,
    }
    return true;
}

/// Fresh for every interpretation pass, shared by that pass's subroutines.
pub const State = struct {
    values: [32]f64 = @splat(0),
    initialized: u32 = 0,
    random_seed: u32,

    pub fn init(glyph: u16) State {
        return .{ .random_seed = @as(u32, glyph) + 1 };
    }

    pub fn apply(self: *State, op: u8, s: *[48]f64, sp: *u32) Error!bool {
        const required: u32 = switch (op) {
            3, 4, 15, 20 => 2,
            5, 21 => 1,
            22 => 4,
            23 => 0,
            else => return false,
        };
        if (sp.* < required) return error.StackUnderflow;
        const base = sp.* - required;
        switch (op) {
            3, 4, 15 => {
                const a = s[base];
                const b = s[base + 1];
                const result = switch (op) {
                    3 => a != 0 and b != 0,
                    4 => a != 0 or b != 0,
                    15 => a == b,
                    else => unreachable,
                };
                s[base] = if (result) 1 else 0;
                sp.* -= 1;
            },
            5 => s[base] = if (s[base] == 0) 1 else 0,
            20, 21 => {
                const i = try integer(s[sp.* - 1]);
                if (i < 0 or i >= self.values.len) return error.InvalidCffOperand;
                const index: u5 = @intCast(i);
                const bit = @as(u32, 1) << index;
                if (op == 20) {
                    self.values[index] = s[base];
                    self.initialized |= bit;
                    sp.* -= 2;
                } else {
                    if (self.initialized & bit == 0) return error.UninitializedCffStorage;
                    s[base] = self.values[index];
                }
            },
            22 => {
                s[base] = if (s[base + 2] <= s[base + 3]) s[base] else s[base + 1];
                sp.* -= 3;
            },
            23 => {
                if (sp.* == s.len) return error.PushStackOverflow;
                // Deterministic per glyph so bounds and outline passes agree.
                // Map all u32 values into (0, 1], as required by Type 2.
                self.random_seed = self.random_seed *% 1664525 +% 1013904223;
                s[sp.*] = (@as(f64, @floatFromInt(self.random_seed)) + 1) / 4294967296.0;
                sp.* += 1;
            },
            else => unreachable,
        }
        return true;
    }
};
