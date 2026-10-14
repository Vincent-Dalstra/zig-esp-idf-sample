const std = @import("std");
const sys = @import("sys");

const assert = std.debug.assert;

const log = std.log.scoped(.perfmon);

// Places code into IRAM instead of flash
const IRAM_ATTR = ".iram1";
// Forces code into IRAM instead of flash
// const FORCE_IRAM_ATTR = ".iram1"; // Combine IRAM_ATTR with 'noinline'

// if (@hasDecl(sys, "CONFIG_IDF_TARGET_ARCH_XTENSA")) {
//     ;
// } else if (@hasDecl(sys, "CONFIG_IDF_TARGET_ARCH_RISCV")) {
//     @compileError("Perfmon is not supported on RISC-V tasks");
// } else {
//     @compileError("Unexpected target architecture: " ++ sys.CONFIG_IDF_TARGET_ARCH);
// }

/// To make things easy, pass an array of which statistics to collect
/// Only one statistic can be collected at a time, so it has to repeat the
/// test for each statistic.
///
/// Statistics are defined as pairs of 'category' and 'mask', where the mask
/// depends on the category and controls which ones are collected (combined).
pub const perfmon_check_table = struct {
    pub const all: []const [2]u32 = @ptrCast(&sys.xtensa_perfmon_select_mask_all);

    /// A smaller set of counters that is good for checking how efficiently
    /// a block of assembly runs on the processor.
    pub const simple: []const [2]u32 = @ptrCast(&pm_check_table_simple);
    const pm_check_table_simple: [7][2]u32 = .{
        .{ sys.XTPERF_CNT_CYCLES, sys.XTPERF_MASK_CYCLES }, // total cycles
        .{ sys.XTPERF_CNT_INSN, sys.XTPERF_MASK_INSN_ALL }, // total instructions
        .{ sys.XTPERF_CNT_D_LOAD_U1, sys.XTPERF_MASK_D_LOAD_LOCAL_MEM }, // Mem read
        .{ sys.XTPERF_CNT_D_STORE_U1, sys.XTPERF_MASK_D_STORE_LOCAL_MEM }, // Mem write
        .{ sys.XTPERF_CNT_BUBBLES, sys.XTPERF_MASK_BUBBLES_ALL & (~sys.XTPERF_MASK_BUBBLES_R_HOLD_REG_DEP) }, // wait for other reasons
        .{ sys.XTPERF_CNT_BUBBLES, sys.XTPERF_MASK_BUBBLES_R_HOLD_REG_DEP }, // Wait for register dependency
        .{ sys.XTPERF_CNT_OVERFLOW, sys.XTPERF_MASK_OVERFLOW }, // Last test cycle
    };
};

const PERFMON_TRACELEVEL: c_int = -1;

const BenchmarkError = error{
    Failed,
    InconsistentResults, // see `run_not_pure()`
    IramBusyStall,
};

pub const Benchmark = NewBenchmark;

/// Note: `function` will be executed multiple times!
/// This is necessary to collect each of the different statistics.
///
/// It is recommended that `function` be a 'pure function', i.e.
/// - No side effects.
/// - Result depends only on arguments.
/// Otherwise, you may get interesting Results.
pub fn OldBenchmark(function: anytype) type {
    const Error = BenchmarkError;

    const info = @typeInfo(@TypeOf(function));
    if (info != .@"fn")
        @compileError("Benchmark expects a function type");

    const function_info = info.@"fn";
    if (function_info.attrs.varargs)
        @compileError("Cannot create ArgsTuple for variadic function");

    const Result = function_info.return_type.?;
    const Args = std.meta.ArgsTuple(@TypeOf(function));

    return struct {
        const Self = @This();

        const TypeErased = struct {
            result: Result,
            args: Args,
        };

        fn typeErasedCall(params: ?*anyopaque) callconv(.c) void {
            const p: *TypeErased = @ptrCast(@alignCast(params.?));
            p.result = @call(.never_inline, function, p.args);
        }

        pub fn run(
            pm_check_table: []const [2]u32,
            repeat: u32,
            args: Args,
        ) Error!Result {
            return run_internal(pm_check_table, repeat, args, true);
        }

        /// Use this if the function may return a different value on subsequent calls
        pub fn run_not_pure(
            pm_check_table: []const [2]u32,
            repeat: u32,
            args: Args,
        ) Error!void {
            _ = run_internal(pm_check_table, repeat, args, false);
        }

        inline fn run_internal(
            pm_check_table: []const [2]u32,
            repeat: u32,
            args: Args,
            compare_results: bool,
        ) Error!Result {
            var params: TypeErased = .{
                .result = undefined,
                .args = args,
            };
            // Pre-heat IRAM cache
            typeErasedCall(@ptrCast(&params));
            const expected_result: Result = params.result;

            const pm_config: sys.xtensa_perfmon_config_t = .{
                .counters_size = pm_check_table.len,
                .select_mask = @ptrCast(pm_check_table.ptr),
                .repeat_count = @intCast(repeat),
                .max_deviation = 1,
                .call_function = &typeErasedCall,
                .call_params = @ptrCast(&params),
                .callback = sys.xtensa_perfmon_view_cb,
                .callback_params = null, // stdout
                .tracelevel = PERFMON_TRACELEVEL,
            };
            const err: sys.esp_err_t = sys.xtensa_perfmon_exec(&pm_config);
            if (err != 0) return Error.Failed;

            if (compare_results) {
                if (expected_result != params.result) return Error.InconsistentResults;
            }

            return params.result;
        }
    };
}

pub fn NewBenchmark(function: anytype) type {
    const Error = BenchmarkError;

    const info = @typeInfo(@TypeOf(function));
    if (info != .@"fn")
        @compileError("Benchmark expects a function type");

    const function_info = info.@"fn";
    if (function_info.attrs.varargs)
        @compileError("Cannot create ArgsTuple for variadic function");

    const Result = function_info.return_type.?;
    const Args = std.meta.ArgsTuple(@TypeOf(function));

    return struct {
        const Self = @This();

        pub inline fn run(
            pm_check_table: []const [2]u32,
            repeat: u32,
            args: Args,
        ) linksection(IRAM_ATTR) Error!Result {
            return run_internal(pm_check_table, repeat, args, true);
        }

        /// Use this if the function may return a different value on subsequent calls
        pub inline fn run_not_pure(
            pm_check_table: []const [2]u32,
            repeat: u32,
            args: Args,
        ) linksection(IRAM_ATTR) Error!void {
            _ = run_internal(pm_check_table, repeat, args, false);
        }

        noinline fn run_internal(
            pm_check_table: []const [2]u32,
            repeat: u32,
            args: Args,
            compare_results: bool,
        ) linksection(IRAM_ATTR) Error!Result {
            // Warm-up the Instruction cache
            var expected_result: Result = undefined;
            if (true) {
                expected_result, const cycles, const iram_busy = try run_once_PORT(
                    pm_counter_cycles,
                    pm_counter_iram_busy,
                    args,
                    -1,
                );
                _ = cycles;

                if (iram_busy > 0) {
                    log.debug("WARMUP: Instruction RAM/ROM busy stall = {}", .{iram_busy});
                }
            }

            for (pm_check_table) |pm_check| {
                // var total_cycles: u64 = 0;
                // var max_cycles: u32 = 0;
                // var min_cycles: u32 = std.math.maxInt(u32);

                var total_stats: u64 = 0;
                var max_stats: u32 = 0;
                var min_stats: u32 = std.math.maxInt(u32);

                var invalid: u32 = 0;
                var done: u32 = 0;
                while (done < repeat) {
                    const result, const iram_busy, const stats = try run_once_PORT(
                        pm_counter_iram_busy,
                        pm_check,
                        args,
                        -1,
                    );
                    // log.info("p0 = {}, p1 = {}", .{ cycles, stats });

                    if (compare_results) {
                        if (expected_result != result) return Error.InconsistentResults;
                    }

                    if (iram_busy > 0) {
                        invalid += 1;

                        // log.warn("Instruction RAM/ROM busy stall = {}", .{iram_busy});
                        @call(.always_inline, log.warn, .{
                            "Done = {}/{}, Invalid = {}/{}, Instruction RAM/ROM busy stall = {}",
                            .{ done, repeat, invalid, repeat, iram_busy },
                        });

                        if (invalid > repeat) {
                            return Error.IramBusyStall;
                        }

                        continue;
                    }

                    // max_cycles = @max(max_cycles, cycles);
                    // min_cycles = @min(min_cycles, cycles);

                    max_stats = @max(max_stats, stats);
                    min_stats = @min(min_stats, stats);

                    // total_cycles += cycles;
                    total_stats += stats;

                    done += 1;
                }
                log.info("total_stats = {} (min = {}, max = {}))", .{ total_stats, min_stats, max_stats });

                sys.xtensa_perfmon_view_cb(null, pm_check[0], pm_check[1], @as(u32, @intCast(total_stats / repeat)));
            }
            return expected_result;
        }

        const pm_counter_cycles: [2]u32 = .{ sys.XTPERF_CNT_CYCLES, 0xffff };
        const pm_counter_iram_busy: [2]u32 = .{ sys.XTPERF_CNT_I_STALL, sys.XTPERF_MASK_I_STALL_BUSY };

        fn run_once_PORT(
            pm_check_0: [2]u32,
            pm_check_1: [2]u32,
            args: Args,
            tracelevel: c_int,
        ) linksection(IRAM_ATTR) Error!struct { Result, u32, u32 } {
            // Set up cycle counter
            sys.xtensa_perfmon_stop();
            // if tracelevel used, then kernelcnt will be enabled
            const kernelcnt: c_int = if (tracelevel >= 0) 1 else 0;

            assert(sys.ESP_OK == sys.xtensa_perfmon_init(0, @intCast(pm_check_0[0]), @intCast(pm_check_0[1]), kernelcnt, tracelevel));
            assert(sys.ESP_OK == sys.xtensa_perfmon_init(1, @intCast(pm_check_1[0]), @intCast(pm_check_1[1]), kernelcnt, tracelevel));

            sys.xtensa_perfmon_start();
            const result = @call(.never_inline, function, args);
            sys.xtensa_perfmon_stop();

            const p0 = sys.xtensa_perfmon_value(0);
            const p1 = sys.xtensa_perfmon_value(1);

            return .{ result, p0, p1 };
        }
    };
}

const access = struct {
    fn xtensa_perfmon_reset(id: c_int) sys.esp_err_t {
        if (id >= sys.XCHAL_NUM_PERF_COUNTERS) {
            return sys.ESP_ERR_INVALID_ARG;
        }
        sys.eri_write(sys.ERI_PERFMON_PM0 + id * @sizeOf(i32), 0);
        return sys.ESP_OK;
    }

    fn xtensa_perfmon_start() void {
        sys.eri_write(sys.ERI_PERFMON_PGM, sys.PGM_PMEN);
    }

    fn xtensa_perfmon_stop() void {
        sys.eri_write(sys.ERI_PERFMON_PGM, 0);
    }

    fn xtensa_perfmon_value(id: c_int) u32 {
        if (id >= sys.ERI_PERFMON_MAX) {
            return 0;
        }
        const result: u32 = sys.eri_read(sys.ERI_PERFMON_PM0 + id * @sizeOf(i32));
        return result;
    }
};
