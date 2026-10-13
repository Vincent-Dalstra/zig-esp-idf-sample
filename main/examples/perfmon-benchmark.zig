/// Benchmark code using perfmon
///
/// The XTensa CPU's have have an internal counter which can be used to
/// collect various statistics. You can use this to verify that your
/// hand-written assembly optimisations are in fact better!
///
/// To demonstrate how these counters work, I wrote a series of more-and-more
/// optimised functions.
///
/// Only works on XTensa targets with Vector instructions
const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const ver = idf.ver.Version;
const mem = std.mem;
const sys = idf.sys;

const perfmon = idf.perfmon;

const assert = std.debug.assert;

const log = std.log.scoped(.http_srv);

const checks = perfmon.pm_check.simple;

const REPEAT = 10;

/// Function to be benchmarked
fn add_up_numbers(numbers: []const i32) i32 {
    assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
    assert(numbers.len % 4 == 0);
    assert(numbers.len > 0);

    var sum: i32 = 0;
    for (numbers) |n| {
        sum += n;
    }
    return sum;
}

export fn app_main() callconv(.c) void {
    var numbers: [4]i32 align(16) = .{ 1, 2, 3, 4 };

    const result0 = add_up_numbers(&numbers);

    log.info("benchmark add_up_numbers()", .{});
    const result1 = perfmon.Benchmark(total.zig_loop).run(checks, REPEAT, .{&numbers}) catch {
        @panic("Benchmark failed");
    };

    std.log.info("Result = {}", .{result1});
    assert(result0 == result1);

    idf.rtos.Task.delayMs(2000);
    run_optimised_functions() catch {
        @panic("Benchmark failed");
    };
    log.info("The end!", .{});
}

const ARRAY_LENGTH: i32 = 1000;
const EXPECTED: i32 = (ARRAY_LENGTH - 1) * (ARRAY_LENGTH / 2);

fn run_optimised_functions() !void {
    var numbers: [ARRAY_LENGTH]i32 align(16) = undefined;
    for (&numbers, 0..) |*n, i| {
        n.* = @intCast(i);
    }

    {
        log.info("do nothing", .{});
        const result = try perfmon.Benchmark(total.do_nothing).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
    }
    idf.rtos.Task.delayMs(0);
    {
        log.info("zig loop", .{});
        const result = try perfmon.Benchmark(total.zig_loop).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    idf.rtos.Task.delayMs(0);
    {
        log.info("asm loop (should be similar to zig loop)", .{});
        const result = try perfmon.Benchmark(total.basic_loop_0).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    idf.rtos.Task.delayMs(0);
    {
        log.info("asm loop, without the data hazard", .{});
        const result = try perfmon.Benchmark(total.basic_loop_1).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    idf.rtos.Task.delayMs(0);
    {
        log.info("zero-overhead loop", .{});
        const result = try perfmon.Benchmark(total.zero_overhead_loop_0).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    idf.rtos.Task.delayMs(0);
    {
        log.info("vectorised zero-overhead loop", .{});
        const result = try perfmon.Benchmark(total.vectorised_0).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    idf.rtos.Task.delayMs(0);
    {
        log.info("improved vector code", .{});
        const result = try perfmon.Benchmark(total.vectorised_1).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    idf.rtos.Task.delayMs(0);
    {
        log.info("Use more vector registers", .{});
        const result = try perfmon.Benchmark(total.vectorised_2).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    {
        log.info("Align zero-copy loop to prevent wasted cycle", .{});
        const result = try perfmon.Benchmark(total.vectorised_3).run(checks, REPEAT, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
}

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = idf.log.espLogFn,
};

/// Add up the numbers in a `[]i32`
///
/// Assumes the array is 128-bit aligned, to make the vectorised
/// code a bit simpler. Otherwise you need a special case
/// for head & tail.
const total = struct {
    /// Zig `for` loop
    fn zig_loop(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        assert(numbers.len > 0);

        var sum: i32 = 0;
        for (numbers) |n| {
            sum += n;
        }
        return sum;
    }

    /// Provides a baseline to compare the rest against
    fn do_nothing(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        assert(numbers.len > 0);

        const start = numbers.ptr;
        const len = numbers.len;
        assert(len > 0);

        return asm volatile (
            \\nop
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              .a10 = true,
            });
    }

    /// Assembly loop - intended to be as similar as possible to the
    /// zig loop, give or take a few cycles.
    fn basic_loop_0(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        assert(numbers.len > 0);

        const start = numbers.ptr;
        const len = numbers.len;
        assert(len > 0);

        return asm volatile (
            \\mov.n     a9, %[len]
            \\mov.n     a8, %[start]
            \\movi.n    %[sum], 0
            // Having this NOP saves one cycle per iteration.
            \\nop
            \\lstart0:
            \\l32i.n    a10, a8, 0
            // Pipeline bubble occurs here, because a10 is not yet ready
            \\add.n     %[sum], a10, %[sum]
            \\addi.n    a8, a8, 4
            \\addi.n    a9, a9, -1
            \\bnez      a9, lstart0
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              .a10 = true,
            });
    }

    /// Assembly loop
    /// Swapping two instructions prevents a 1-cycle read-hazard
    /// resulting in 1 less pipeline bubble per iteration.
    fn basic_loop_1(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        assert(numbers.len > 0);

        const start = numbers.ptr;
        const len = numbers.len;
        assert(len > 0);

        return asm volatile (
            \\mov.n     a9, %[len]
            \\mov.n     a8, %[start]
            \\movi.n    %[sum], 0
            \\nop.n
            \\lstart1:
            \\l32i.n    a10, a8, 0
            \\addi.n    a8, a8, 4
            \\add.n    %[sum], %[sum], a10
            \\addi.n    a9, a9, -1
            \\bnez      a9, lstart1
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              .a10 = true,
            });
    }

    /// Uses zero-overhead-loop instructions.
    ///
    /// Unlike branch instructions, the CPU can predict that the jump will be
    /// taken and fetch instructions from the start of the loop. This saves
    /// two bubbles per iteration.
    /// It also handles the loop counter automatically, saving another
    /// instruction.
    ///
    /// This comes with some restrictions: e.g. you cannot nest these loops
    ///
    /// For more, read Section 4.3.2 of the Xtensa® Instruction Set Architecture (ISA) Summary
    fn zero_overhead_loop_0(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        // assert(numbers.len > 0);

        const start = numbers.ptr;
        const len = numbers.len;
        assert(len > 0);

        return asm (
            \\mov.n     a9, %[len]
            \\mov.n     a8, %[start]
            \\movi.n    %[sum], 0
            \\loopnez   a9, lend2
            \\l32i.n    a10, a8, 0 
            \\addi.n    a8, a8, 4
            \\add.n    %[sum], %[sum], a10
            \\lend2:
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              .a10 = true,
              .memory = true,
            });
    }

    /// Vectorised zero-overhead loop
    ///
    /// Uses 128-bit vector instructions to load or add [4]i32 at the
    /// same time, then reduces them to a single value.
    ///
    /// The load instruction also increments the pointer, saving one
    /// instruction per iteration.
    ///
    /// Note: The array must be align(16) for the instruction to work.
    fn vectorised_0(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        // assert(numbers.len > 0);

        const start = numbers.ptr;
        const len = numbers.len;
        assert(len > 0);

        return asm (
            \\mov.n     a9, %[len]
            \\srli      a9, a9, 2
            \\mov.n     a8, %[start]
            \\ee.zero.q q0
            // Add [4]i32 per loop
            \\loopnez   a9, lend3
            \\ee.vld.128.ip     q1, a8, 16
            \\ee.vadds.s32      q0, q0, q1
            \\lend3:
            // Sum the 4 results
            \\ee.movi.32.a      q0, %[sum], 0
            \\ee.movi.32.a      q0, a11, 1
            \\add.n    %[sum], %[sum], a11
            \\ee.movi.32.a      q0, a12, 2
            \\add.n    %[sum], %[sum], a12
            \\ee.movi.32.a      q0, a13, 3
            \\add.n    %[sum], %[sum], a13
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              //   .a10 = true,
              .a11 = true,
              .a12 = true,
              .a13 = true,
              .q0 = true,
              .q1 = true,
              .memory = true,
            });
    }

    /// Combined ADD & READ vector instruction
    ///
    /// The `ee.vadds.s32.ld.incp` simultaneously adds [4]i32 and reads
    /// [4]i32 from memory, in a single cycle. It also increments the address
    /// byt 16 bytes - perfect for reading contiguous memory.
    ///
    /// Note that this loop takes THREE cycles per iteration, when it should be
    /// two. This is because instructions not aligned to 32-bits take two cycles to load.
    /// Usually, this overlaps with the previous instructions and so you don't notice.
    /// this doesn't work for zero-copy loops where the previous instruction is not
    /// contiguous memory.
    fn vectorised_1(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        // assert(numbers.len > 0);

        const start = numbers.ptr;
        const len = numbers.len;
        assert(len > 0);

        return asm (
            \\mov.n     a9, %[len]
            \\srli      a9, a9, 2
            \\mov.n     a8, %[start]
            \\ee.zero.q q0
            \\ee.vld.128.ip     q1, a8, 16
            // Align the first istruction in the loop to 32-bits
            \\_nop
            \\loopnez   a9, lend4
            // Combined instruction does 3 things in order:
            // (1) q0 = q0 + q1
            // (2) Read q1 from a8
            // (3) a8 += 16
            \\ee.vadds.s32.ld.incp  q1, a8, q0, q0, q1
            // There is actually a bubble here, but perfmon does not count it,
            // because it it happens during the zero-copy loop.
            // See the next function for more details.
            \\lend4:
            // Sum the 4 results
            \\ee.movi.32.a      q0, %[sum], 0
            \\ee.movi.32.a      q0, a11, 1
            \\add.n    %[sum], %[sum], a11
            \\ee.movi.32.a      q0, a12, 2
            \\add.n    %[sum], %[sum], a12
            \\ee.movi.32.a      q0, a13, 3
            \\add.n    %[sum], %[sum], a13
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              //   .a10 = true,
              .a11 = true,
              .a12 = true,
              .a13 = true,
              .q0 = true,
              .q1 = true,
              .memory = true,
            });
    }

    /// See if further improvements can be made
    ///
    /// This loop avoids a pipeline bubble by alternating between two sets of
    /// vector registers, allowing the instructions to execute far enough
    /// for the values to be ready on the next cycle.
    fn vectorised_2(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 8 == 0);
        // assert(numbers.len > 0);

        const start = numbers.ptr;
        const middle = numbers[(numbers.len / 2)..].ptr;
        const len = numbers.len / 2;
        assert(len > 0);

        return asm (
            \\mov.n     a9, %[len]
            \\srli      a9, a9, 2
            \\mov.n     a8, %[start]
            \\mov.n     a10, %[middle]
            \\ee.zero.q q0
            \\ee.zero.q q2
            \\ee.vld.128.ip     q1, a8, 16
            \\ee.vld.128.ip     q3, a10, 16
            \\loopnez   a9, lend5
            // Alternate the pairs
            \\ee.vadds.s32.ld.incp  q1, a8, q0, q0, q1
            \\ee.vadds.s32.ld.incp  q3, a10, q2, q2, q3
            \\lend5:
            // Sum the 8 results
            \\ee.vadds.s32          q0, q2, q0
            \\ee.movi.32.a      q0, %[sum], 0
            \\ee.movi.32.a      q0, a11, 1
            \\add.n    %[sum], %[sum], a11
            \\ee.movi.32.a      q0, a12, 2
            \\add.n    %[sum], %[sum], a12
            \\ee.movi.32.a      q0, a13, 3
            \\add.n    %[sum], %[sum], a13
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [middle] "r" (middle),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              .a10 = true,
              .a11 = true,
              .a12 = true,
              .a13 = true,
              .q0 = true,
              .q1 = true,
              .q2 = true,
              .q3 = true,
              .memory = true,
            });
    }

    /// See if further improvements can be made
    ///
    /// Zero-overhead loops are faster when the first instruction in the loop
    /// is 32-bit aligned. Otherwise, a single cycle is wasted on properly aligning
    /// the instruction.
    ///
    /// Perfmon doesn't record this wasted cycle on ANY counter other than the
    /// total 'Amount of cycles'!
    fn vectorised_3(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 8 == 0);
        // assert(numbers.len > 0);

        const start = numbers.ptr;
        const middle = numbers[(numbers.len / 2)..].ptr;
        const len = numbers.len / 2;
        assert(len > 0);

        return asm (
            \\mov.n     a9, %[len]
            \\srli      a9, a9, 2
            \\mov.n     a8, %[start]
            \\mov.n     a10, %[middle]
            \\ee.zero.q q0
            \\ee.zero.q q2
            \\ee.vld.128.ip     q1, a8, 16
            \\ee.vld.128.ip     q3, a10, 16
            // Use NOP instructions to align the loop start
            \\nop.n
            \\_nop
            \\loopnez   a9, lend6
            // Alternate the pairs
            \\ee.vadds.s32.ld.incp  q1, a8, q0, q0, q1
            \\ee.vadds.s32.ld.incp  q3, a10, q2, q2, q3
            \\lend6:
            // Sum the 8 results
            \\ee.vadds.s32          q0, q2, q0
            \\ee.movi.32.a      q0, %[sum], 0
            \\ee.movi.32.a      q0, a11, 1
            \\add.n    %[sum], %[sum], a11
            \\ee.movi.32.a      q0, a12, 2
            \\add.n    %[sum], %[sum], a12
            \\ee.movi.32.a      q0, a13, 3
            \\add.n    %[sum], %[sum], a13
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [middle] "r" (middle),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              .a10 = true,
              .a11 = true,
              .a12 = true,
              .a13 = true,
              .q0 = true,
              .q1 = true,
              .q2 = true,
              .q3 = true,
              .memory = true,
            });
    }
};
