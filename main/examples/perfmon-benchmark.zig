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
    const result1 = perfmon.Benchmark(total.sum0).run(checks, .{&numbers});

    std.log.info("Result = {}", .{result1});
    assert(result0 == result1);

    idf.rtos.Task.delayMs(2000);
    run_optimised_functions();

    log.info("The end!", .{});
}

const ARRAY_LENGTH: i32 = 400;
const EXPECTED: i32 = (ARRAY_LENGTH - 1) * (ARRAY_LENGTH / 2);

fn run_optimised_functions() void {
    var numbers: [ARRAY_LENGTH]i32 align(16) = undefined;
    for (&numbers, 0..) |*n, i| {
        n.* = @intCast(i);
    }

    {
        log.info("testFn0: zig loop", .{});
        const result = perfmon.Benchmark(total.sum0).run(checks, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    {
        log.info("testFn1: asm loop", .{});
        const result = perfmon.Benchmark(total.sum1).run(checks, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    {
        log.info("testFn2: zero-overhead loop", .{});
        const result = perfmon.Benchmark(total.sum2).run(checks, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    {
        log.info("testFn3: vectorised zero-overhead loop", .{});
        const result = perfmon.Benchmark(total.sum3).run(checks, .{&numbers});
        std.log.info("Result = {}", .{result});
        if (result != EXPECTED) @panic("");
    }
    {
        log.info("testFn4: better vectorisation", .{});
        const result = perfmon.Benchmark(total.sum4).run(checks, .{&numbers});
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

const total = struct {
    /// Zig `for` loop
    fn sum0(numbers: []const i32) i32 {
        assert(std.mem.isAligned(@intFromPtr(numbers.ptr), 16));
        assert(numbers.len % 4 == 0);
        assert(numbers.len > 0);

        var sum: i32 = 0;
        for (numbers) |n| {
            sum += n;
        }
        return sum;
    }

    /// Assembly loop - should be the same performance as zig `for`
    fn sum1(numbers: []const i32) i32 {
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
            \\lstart:
            \\l32i.n    a10, a8, 0 
            \\addi.n    a8, a8, 4
            \\add.n    %[sum], %[sum], a10
            \\addi.n    a9, a9, -1
            \\bnez      a9, lstart
            : [sum] "=r" (-> i32),
            : [start] "r" (start),
              [len] "r" (len),
            : .{
              .a8 = true,
              .a9 = true,
              .a10 = true,
            });
    }

    /// Zero-overhead loop. One less instruction, two less pipeline bubbles
    fn sum2(numbers: []const i32) i32 {
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
    fn sum3(numbers: []const i32) i32 {
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

    /// Vectorised zero-overhead loop
    fn sum4(numbers: []const i32) i32 {
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
            \\loopnez   a9, lend4
            \\ee.vadds.s32.ld.incp  q1, a8, q0, q0, q1      // (1) q0 = q0 + q1 (2) Read q1 from a8 (3) a8 += 16
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
};
