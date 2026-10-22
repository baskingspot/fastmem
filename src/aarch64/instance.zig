//! The package instance id in aarch64 inline-assembly labels.
//!
//! Zig compiles every module of one binary into one object, and the
//! assembler label namespace covers the whole object. Two fastmem package
//! copies in one link would therefore define the same `.Lfm_*` labels. The
//! instance id keeps the labels of each copy apart, so a content-hash
//! mismatch costs duplicated kernel bytes instead of a link error.
//! `build.zig` `instanceId` makes the id unique per package instance.

const std = @import("std");
const options = @import("fastmem_options");

pub const id = options.instance;

const needle = ".Lfm_";
const tag = ".L" ++ id ++ "_fm_";

fn outLen(comptime text: []const u8) usize {
    @setEvalBranchQuota(1_000_000);
    comptime var count: usize = 0;
    comptime var pos: usize = 0;
    inline while (std.mem.indexOfPosLinear(u8, text, pos, needle)) |at| {
        count += 1;
        pos = at + needle.len;
    }
    return text.len + count * (tag.len - needle.len);
}

/// `text` with every `.Lfm_` label and branch target tagged with the
/// instance id. The const seed keeps Zig from writing the text to
/// `.rodata`: the caller uses it only as an asm template.
pub fn instanced(comptime text: []const u8) *const [outLen(text)]u8 {
    @setEvalBranchQuota(1_000_000);
    const S = struct {
        const out: [outLen(text)]u8 = blk: {
            var buf: [outLen(text)]u8 = undefined;
            var src: usize = 0;
            var dst: usize = 0;
            while (std.mem.indexOfPosLinear(u8, text, src, needle)) |at| {
                const n = at - src;
                for (text[src..at], buf[dst .. dst + n]) |c, *o| o.* = c;
                dst += n;
                for (tag, buf[dst .. dst + tag.len]) |c, *o| o.* = c;
                dst += tag.len;
                src = at + needle.len;
            }
            for (text[src..], buf[dst .. dst + text.len - src]) |c, *o| o.* = c;
            dst += text.len - src;
            std.debug.assert(dst == buf.len);
            break :blk buf;
        };
    };
    return &S.out;
}
