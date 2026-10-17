const std = @import("std");

const assert = std.debug.assert;

/// The ERI is a bus internal to each Xtensa core. It connects, amongst others, to the debug interface, where it
/// allows reading/writing the same registers as available over JTAG.
///
/// Rewritten from: esp-idf-v6.1/xtensa/components/xtensa/eri.c and include/eri.h
pub const eri = struct {

    // Note: as far as I can see, no register has an addr greater than 0x20000000
    // At least, none that the esp-idf uses.
    // Therefore, I have chosen u32 for convenience
    const Addr = u32;

    /// Read from an 'external register'
    pub inline fn read(addr: eri.Addr) u32 {
        return asm volatile (
            \\RER %[ret], %[addr]
            : [ret] "=r" (-> u32),
            : [addr] "r" (addr),
            : .{});
    }

    /// Write to an 'external register'
    pub inline fn write(addr: eri.Addr, data: u32) void {
        asm volatile (
            \\WER %[data], %[addr]
            :
            : [addr] "r" (addr),
              [data] "r" (data),
            : .{});
    }
};
