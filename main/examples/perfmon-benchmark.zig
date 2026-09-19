const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const ver = idf.ver.Version;
const mem = std.mem;
const sys = idf.sys;

const assert = std.debug.assert;

const log = std.log.scoped(.http_srv);

const TOTAL_CALL_AMOUNT: c_int = 200;
const PERFMON_TRACELEVEL: c_int = -1;

export var loop_len: usize = 100; // Defeat constant loop unrolling

fn testFn0(params: ?*anyopaque) callconv(.c) void {
    _ = params;
    const ll = loop_len;
    assert(ll > 0);
    for (0..ll) |_| {
        asm volatile (
            \\nop
            \\nop
            ::: .{});
    }
}

fn testFn1(params: ?*anyopaque) callconv(.c) void {
    _ = params;
    const ll = loop_len;
    assert(ll > 0);
    asm volatile (
        \\mov.n     a7, %[ll]
        \\lstart:
        \\nop
        \\nop
        \\addi.n    a7, a7, -1
        \\bnez      a7, lstart
        :
        : [ll] "r" (ll),
        : .{ .a7 = true });
}

fn testFn2(params: ?*anyopaque) callconv(.c) void {
    _ = params;
    const ll = loop_len;
    assert(ll > 0);
    asm volatile (
        \\loop      %[ll], lend
        \\nop
        \\nop
        \\lend:
        :
        : [ll] "r" (ll),
        : .{});
}

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
    var pm_config: sys.xtensa_perfmon_config_t = .{
        .counters_size = pm_check_table.len / 2,
        .select_mask = &pm_check_table,
        .repeat_count = TOTAL_CALL_AMOUNT,
        .max_deviation = 1,
        .call_function = undefined,
        .callback = sys.xtensa_perfmon_view_cb,
        .callback_params = null, // stdout
        .tracelevel = PERFMON_TRACELEVEL,
    };

    log.info("testFn0: zig loop", .{});
    pm_config.call_function = testFn0;
    _ = sys.xtensa_perfmon_exec(&pm_config);

    idf.rtos.Task.delayMs(5000);

    log.info("testFn1: asm loop", .{});
    pm_config.call_function = testFn1;
    _ = sys.xtensa_perfmon_exec(&pm_config);

    idf.rtos.Task.delayMs(5000);

    log.info("testFn2: zero-overhead loop", .{});
    pm_config.call_function = testFn2;
    _ = sys.xtensa_perfmon_exec(&pm_config);

    log.info("The end!", .{});
}

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .debug => .debug,
        else => .info,
    },
    .logFn = idf.log.espLogFn,
};
