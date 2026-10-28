/// Benchmark code using perfmon
///
/// The XTensa CPU's have have an internal counter which can be used to
/// collect various statistics. You can use this to verify that your
/// hand-written assembly optimisations are in fact better!
///
/// To demonstrate how these counters work, I wrote some example functions
/// in the `total` namespace, which all do the same thing; add up the numbers
/// in an []i32. They show how performance data can guide optimisation decisions
/// step-by-step to produce faster code. The final SIMD code runs 32x faster than
/// the initial 'for' loop (ESP32-S3, ReleaseSafe).
///
///
/// Requirements:
/// - XTensa
/// Recommended
/// - ESP32-S3 (enables SIMD optimisations)
const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const ver = idf.ver.Version;
const mem = std.mem;
const sys = idf.sys;

const perfmon = idf.perfmon;

// Places code into IRAM instead of flash
const IRAM_ATTR = ".iram1";
// Forces code into IRAM instead of flash
// const FORCE_IRAM_ATTR = ".iram1"; // Combine IRAM_ATTR with 'noinline'

const assert = std.debug.assert;

const log = std.log.scoped(.perfmon_example);

const checks = &perfmon.perfmon_check_table.new_simple;

const benchmark = perfmon.benchmark(checks);

const REPEAT = 20;

var write_buffer: [64 * 1024]u8 = undefined;

export fn app_main() callconv(.c) void {
    var console = serialConsole.writer(&write_buffer);
    const console_writer = &console;

    basic_benchmark(console_writer) catch |err| {
        @panic(@errorName(err));
    };

    idf.rtos.Task.delayMs(2000);
    run_optimised_functions(console_writer) catch |err| {
        @panic(@errorName(err));
    };

    console.flush() catch |err| {
        @panic(@errorName(err));
    };

    log.info("The end!", .{});
}

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = idf.log.espLogFn,
};

fn basic_benchmark(stats_out: *std.Io.Writer) !void {
    var numbers: [4]i32 = .{ 1, 2, 3, 4 };

    // The simplest way to benchmark a function
    // For each statistic, run the function multiple times, and collect the min/max/average
    // If it detects an 'IRAM busy stall' (i.e. instructions are in flash and not yet cached)
    // it will discard the result and retry.
    {
        const expected_result = add_up_numbers(&numbers);

        log.info("benchmark add_up_numbers()", .{});
        const results, const return_value = try benchmark.FnPure(add_up_numbers).run(3, .{&numbers});
        log.info("return_value = {}", .{return_value});
        try stats_out.print("{f}", .{results});

        if (expected_result != return_value) @panic("");
    }

    // If the function modifies data that is pointed-to by its arguments,
    // provide another function to reset this data.
    {
        const expected_result = running_total(&numbers);
        log.info("benchmark running_total(), resetting arguments between runs", .{});
        const results, const return_value = try benchmark.FnReset(running_total, reset_numbers).run(3, .{&numbers});
        log.info("return_value = {}", .{return_value});
        try stats_out.print("{f}", .{results});

        if (expected_result != return_value) @panic("");
        if (!std.mem.eql(i32, &numbers, &[4]i32{ 1, 3, 6, 10 })) @panic("");
    }
}

/// Function to be benchmarked
noinline fn add_up_numbers(numbers: []const i32) linksection(IRAM_ATTR) i32 {
    var sum: i32 = 0;
    for (numbers) |n| {
        sum += n;
    }
    return sum;
}

/// A function that edits its arguments
noinline fn running_total(numbers: []i32) linksection(IRAM_ATTR) i32 {
    var sum: i32 = 0;
    for (numbers) |*n| {
        sum += n.*;
        n.* = sum;
    }
    return sum;
}

// Reset arguments to ensure each run is the same
noinline fn reset_numbers(numbers: []i32) linksection(IRAM_ATTR) void {
    const reset: [4]i32 = .{ 1, 2, 3, 4 };
    @memcpy(numbers, &reset);
}

// Below is a demonstration of how perfmon can be used to verify and guide
// the process of hand-optimizing a function in assembly.

const ARRAY_LENGTH: i32 = 1000;
const EXPECTED: i32 = (ARRAY_LENGTH - 1) * (ARRAY_LENGTH / 2);

fn run_optimised_functions(stats_out: *std.Io.Writer) linksection(IRAM_ATTR) !void {
    var numbers: [ARRAY_LENGTH]i32 align(16) = undefined;
    for (&numbers, 0..) |*n, i| {
        n.* = @intCast(i);
    }

    {
        log.info("do nothing", .{});
        const results, const return_value = try benchmark.FnPure(total.do_nothing).runAverage(REPEAT, .{&numbers});
        log.info("return_value = {}", .{return_value});
        try stats_out.print("{f}", .{results});
        // log.warn("{f}", .{results.subtract(prev_results)}); // No previous results yet
    }
    idf.rtos.Task.yield();
    {
        log.info("zig loop", .{});
        const results, const return_value = try benchmark.FnPure(total.zig_loop).run(REPEAT, .{&numbers});
        if (return_value != EXPECTED) @panic("");
        log.info("return_value = {}", .{return_value});
        try stats_out.print("{f}", .{results});
    }
    idf.rtos.Task.yield();
    {
        log.info("asm loop (should be similar to zig loop)", .{});
        const results, const return_value = try benchmark.FnPure(total.basic_loop_0).run(REPEAT, .{&numbers});
        if (return_value != EXPECTED) @panic("");
        log.info("return_value = {}", .{return_value});
        try stats_out.print("{f}", .{results});
    }
    idf.rtos.Task.yield();
    {
        log.info("asm loop, without the data hazard", .{});
        const results, const return_value = try benchmark.FnPure(total.basic_loop_1).run(REPEAT, .{&numbers});
        if (return_value != EXPECTED) @panic("");
        log.info("return_value = {}", .{return_value});
        try stats_out.print("{f}", .{results});
    }
    idf.rtos.Task.yield();
    {
        log.info("zero-overhead loop", .{});
        const results, const return_value = try benchmark.FnPure(total.zero_overhead_loop_0).run(REPEAT, .{&numbers});
        if (return_value != EXPECTED) @panic("");
        log.info("return_value = {}", .{return_value});
        try stats_out.print("{f}", .{results});
    }
    idf.rtos.Task.yield();
    {
        log.info("mis-aligned instruction at zero-overhead loop start", .{});
        const results, const return_value = try benchmark.FnPure(total.zero_overhead_loop_1).run(REPEAT, .{&numbers});
        if (return_value != EXPECTED) @panic("");
        log.info("return_value = {}", .{return_value});
        try stats_out.print("{f}", .{results});
    }

    // Further optimisations require SIMD, which is only available on the ESP32-S3
    if (@hasDecl(sys, "SOC_SIMD_INSTRUCTION_SUPPORTED") and sys.SOC_SIMD_INSTRUCTION_SUPPORTED != 0) {
        assert(sys.SOC_SIMD_INSTRUCTION_SUPPORTED == 1);

        idf.rtos.Task.yield();
        {
            log.info("zig loop, @Vector", .{});
            // This function sometimes gives inconsistent results. runAverage() collects min/max/total
            const results, const return_value = try benchmark.FnPure(total.zig_loop_vec).runAverage(REPEAT, .{&numbers});
            log.info("return_value = {}", .{return_value});
            try stats_out.print("{f}", .{results});
            if (return_value != EXPECTED) @panic("");
        }
        idf.rtos.Task.yield();
        {
            log.info("vectorised zero-overhead loop", .{});
            const results, const return_value = try benchmark.FnPure(total.vectorised_0).run(REPEAT, .{&numbers});
            log.info("return_value = {}", .{return_value});
            try stats_out.print("{f}", .{results});
            if (return_value != EXPECTED) @panic("");
        }
        idf.rtos.Task.yield();
        {
            log.info("improved vector code", .{});
            const results, const return_value = try benchmark.FnPure(total.vectorised_1).run(REPEAT, .{&numbers});
            log.info("return_value = {}", .{return_value});
            try stats_out.print("{f}", .{results});
            if (return_value != EXPECTED) @panic("");
        }
        idf.rtos.Task.yield();
        {
            log.info("Use more vector registers", .{});
            // This function sometimes gives inconsistent results. runAverage() collects min/max/total
            const results, const return_value = try benchmark.FnPure(total.vectorised_2).runAverage(REPEAT, .{&numbers});
            log.info("return_value = {}", .{return_value});
            try stats_out.print("{f}", .{results});
            if (return_value != EXPECTED) @panic("");
        }
        {
            log.info("Align zero-copy loop to prevent wasted cycle", .{});
            const results, const return_value = try benchmark.FnPure(total.vectorised_3).run(REPEAT, .{&numbers});
            log.info("return_value = {}", .{return_value});
            try stats_out.print("{f}", .{results});
            if (return_value != EXPECTED) @panic("");
        }
    }
}

/// Add up the numbers in a `[]i32`
///
/// Assumes the array is 128-bit aligned, to make the vectorised
/// code a bit simpler. Otherwise you need a special case
/// for head & tail.
const total = struct {
    /// Zig `for` loop
    noinline fn zig_loop(numbers: []const i32) linksection(IRAM_ATTR) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        assert(numbers.len > 0);

        var sum: i32 = 0;
        for (numbers) |n| {
            sum += n;
        }
        return sum;
    }

    /// Get an idea of how much overhead the perfmon calls have
    noinline fn do_nothing(numbers: []const i32) linksection(IRAM_ATTR) i32 {
        _ = numbers;
        asm volatile (
            \\nop
            ::: .{});
        return 0;
    }

    /// Assembly loop - intended to be as similar as possible to the
    /// zig loop, give or take a few cycles.
    noinline fn basic_loop_0(numbers: []const i32) linksection(IRAM_ATTR) i32 {
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
    ///
    /// Look for: "R hold caused by register dependency"
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
    /// two bubbles per iteration. It also decrements the loop counter
    /// automatically, saving one more instruction.
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
            \\loopnez   a9, lend_zol_0
            \\l32i.n    a10, a8, 0 
            \\addi.n    a8, a8, 4
            \\add.n    %[sum], %[sum], a10
            \\lend_zol_0:
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

    /// Zero-overhead loops are sensitive to instruction alignment
    ///
    /// This takes an additional cycle per iteration, which is not
    /// recorded in any other counter.
    ///
    /// The reason for this is that the first instruction in the
    /// loop does not sit within a 32-bit boundary. The instruction
    /// bus is both 32-bit wide and aligned, so two cycles are required
    /// to load the instruction.
    ///
    /// Normally, in sequential code, these cycles overlap between instructions
    /// so that overall throughput is unaffected. This doesn't work for zero-copy
    /// loops where the previous instruction is not in contiguous memory.
    fn zero_overhead_loop_1(numbers: []const i32) i32 {
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
            \\nop.n
            \\nop
            \\loopnez   a9, lend_zol_1
            \\l32i.n    a10, a8, 0 
            \\addi.n    a8, a8, 4
            \\add.n    %[sum], %[sum], a10
            \\lend_zol_1:
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

    const Simd_block = @Vector(4, i32);

    /// See what zig @Vector() does
    ///
    /// Answer: does not emit SIMD. There is a slight performance boost
    /// simply because it unrolls the loop a bit.
    fn zig_loop_vec(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        assert(numbers.len > 0);

        const as_vec: []const Simd_block = @ptrCast(@alignCast(numbers));

        var accumulate: Simd_block = @splat(0);
        for (as_vec) |el| {
            accumulate += el;
        }

        return @reduce(.Add, accumulate);
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
    /// Note that this loop takes TWO cycles per iteration, when there is only
    /// a single instruction. The instruction loads q1 from memory, but it's not
    /// available in time for the next instruction to use it as an operand. The
    /// processor must wait for one extra cycle a.k.a. a pipeline bubble.
    ///
    /// Look for: "R hold caused by register dependency"
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
            // Align the first instruction in the loop to 32-bits.
            // Otherwise, a wasted cycle would prevent the bubble from
            // showing up in the perfmon statistics.
            \\_nop
            \\loopnez   a9, lend4
            // Combined instruction equivalent to doing 3 things in order:
            // (1) q0 = q0 + q1
            // (2) Read q1 from a8
            // (3) a8 += 16
            \\ee.vadds.s32.ld.incp  q1, a8, q0, q0, q1
            // Single pipeline bubble to allow q1 to load from memory
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

    /// Resolve data dependency in vectorised loop
    ///
    /// This loop avoids a pipeline bubble by alternating between two sets of
    /// vector registers, allowing the instructions to execute far enough
    /// for the values to be ready on the next cycle.
    ///
    /// However, this loop takes THREE cycles per iteration, when it should be
    /// two. This is because instructions not aligned to 32-bits take two cycles to load.
    /// Usually, this overlaps with the previous instructions and so you don't notice.
    /// but this doesn't work for zero-copy loops because the previous instruction
    /// is in a different spot in memory.
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

    /// Prevent the wasted cycle from unaligned loop start
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

/// This should be moved into its own component at some point
const serialConsole = struct {
    const Writer = std.Io.Writer;
    const Error = Writer.Error;

    const FILENO = 1; // stdout

    fn writer(buffer: []u8) Writer {
        return .{
            .vtable = &.{
                .drain = drain,
                // .flush = std.Io.Writer.noopFlush,
            },
            .buffer = buffer,
        };
    }

    // TODO: Make this blocking (instead of busy-wait)
    // Currently this will busy-wait for space in the UART FIFO.
    // https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/stdio.html#blocking-and-non-blocking-i-o
    inline fn c_write(fd: std.c.fd_t, buf: []const u8) Error!usize {
        const written_or_error = std.c.write(fd, buf.ptr, buf.len);
        if (written_or_error < 0) return Error.WriteFailed;
        return @intCast(written_or_error);
    }

    /// This will wait until the UART FIFO is empty before returning
    inline fn c_flush(fd: std.c.fd_t) Error!void {
        const err = std.c.fsync(fd);
        if (err != 0) return Error.WriteFailed;
    }

    /// Note: currently this busy-waits until all data is written, because of how the underlying esp-idf does things
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) Error!usize {
        // First the already-buffered data:
        if (w.end > 0) {
            const buffered = w.buffer[0..w.end];
            const written = try c_write(FILENO, buffered);

            if (written < buffered.len) {
                const remaining = buffered[written..];
                @memmove(buffered[0..remaining.len], remaining);
                w.end -= written;
                return 0; // If stdout is cockblocking us then there's no point trying to write more data now
            } else {
                w.end -= written;
                assert(w.end == 0);
            }
        }

        // Is there actually new data?
        if (data.len == 0) return 0;
        if (data.len == 1 and splat == 0) return 0;

        var ret: usize = 0;

        // The last slice could be splatted. Deal with it afterwards
        const todo: []const []const u8 = data[0 .. data.len - 1];
        const splat_slice: []const u8 = data[data.len - 1];
        for (todo) |slice| {
            const written = try c_write(FILENO, slice);
            ret += written;

            if (written < slice.len) {
                return ret;
            } else {
                assert(written == slice.len);
            }
        }

        // Did we need to splat a slice?
        for (0..splat) |_| {
            const slice = splat_slice;
            const written = try c_write(FILENO, slice);
            ret += written;

            if (written < slice.len) {
                return ret;
            } else {
                assert(written == slice.len);
            }
        }
        return ret;
    }

    fn flush(w: *Writer) Error!void {
        const drainFn = w.vtable.drain;
        while (w.end != 0) _ = try drainFn(w, &.{""}, 1);
        try c_flush(FILENO);
    }
};
