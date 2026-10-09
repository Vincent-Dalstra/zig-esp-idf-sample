const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const ver = idf.ver.Version;
const mem = std.mem;
const sys = idf.sys;

const perfmon = idf.perfmon;

const assert = std.debug.assert;

const log = std.log.scoped(.http_srv);

const TOTAL_CALL_AMOUNT: c_int = 1;
const PERFMON_TRACELEVEL: c_int = -1;

// export var repeat_count: usize = 100; // Defeat constant loop unrolling

const ARRAY_LENGTH: i32 = 400;
const EXPECTED: i32 = (ARRAY_LENGTH - 1) * (ARRAY_LENGTH / 2);

const Params = struct {
    numbers: []i32,
    sum_out: *i32,
};

const pm_check_table: [14]u32 = .{
    sys.XTPERF_CNT_CYCLES, sys.XTPERF_MASK_CYCLES, // total cycles
    sys.XTPERF_CNT_INSN, sys.XTPERF_MASK_INSN_ALL, // total instructions
    sys.XTPERF_CNT_D_LOAD_U1, sys.XTPERF_MASK_D_LOAD_LOCAL_MEM, // Mem read
    sys.XTPERF_CNT_D_STORE_U1, sys.XTPERF_MASK_D_STORE_LOCAL_MEM, // Mem write
    sys.XTPERF_CNT_BUBBLES, sys.XTPERF_MASK_BUBBLES_ALL & (~sys.XTPERF_MASK_BUBBLES_R_HOLD_REG_DEP), // wait for other reasons
    sys.XTPERF_CNT_BUBBLES, sys.XTPERF_MASK_BUBBLES_R_HOLD_REG_DEP, // Wait for register dependency
    sys.XTPERF_CNT_OVERFLOW, sys.XTPERF_MASK_OVERFLOW, // Last test cycle
};

export fn app_main() callconv(.c) void {
    var numbers: [ARRAY_LENGTH]i32 align(16) = undefined;
    var sum: i32 = undefined;

    for (&numbers, 0..) |*n, i| {
        n.* = @intCast(i);
    }

    log.info("testFn0: zig loop", .{});
    sum = perfmon.Benchmark(sum0).run(.{&numbers});
    std.log.info("Result = {}", .{sum});

    idf.rtos.Task.delayMs(1000);
    for (&numbers, 0..) |*n, i| {
        n.* = @intCast(i);
    }

    log.info("testFn1: asm loop", .{});
    sum = perfmon.Benchmark(sum0).run(.{&numbers});

    std.log.info("Result = {}", .{sum});

    idf.rtos.Task.delayMs(1000);

    for (&numbers, 0..) |*n, i| {
        n.* = @intCast(i);
    }

    log.info("testFn2: zero-overhead loop", .{});
    sum = perfmon.Benchmark(sum2).run(.{&numbers});
    std.log.info("Result = {}", .{sum});

    idf.rtos.Task.delayMs(1000);

    for (&numbers, 0..) |*n, i| {
        n.* = @intCast(i);
    }

    log.info("testFn3: vectorised zero-overhead loop", .{});
    sum = perfmon.Benchmark(sum3).run(.{&numbers});
    std.log.info("Result = {}", .{sum});
    idf.rtos.Task.delayMs(1000);

    for (&numbers, 0..) |*n, i| {
        n.* = @intCast(i);
    }

    log.info("testFn4: better vectorisation", .{});
    sum = perfmon.Benchmark(sum4).run(.{&numbers});
    std.log.info("Result = {}", .{sum});

    idf.rtos.Task.delayMs(1000);
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

/// Zig `for` loop
fn sum0(numbers: []i32) i32 {
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
fn sum1(numbers: []i32) i32 {
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
fn sum2(numbers: []i32) i32 {
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
fn sum3(numbers: []i32) i32 {
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
fn sum4(numbers: []i32) i32 {
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
