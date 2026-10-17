const std = @import("std");
const sys = @import("sys");
const xtensa = @import("xtensa");

const eri = xtensa.eri;

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
    UnknownCounter,
    UnknownCounterMask,
};

const BenchMarkStatResult = struct {
    repeat: u32,
    min: u32,
    max: u32,
    total: u64,

    const init: BenchMarkStatResult = .{
        .repeat = 0,
        .min = std.math.maxInt(u32),
        .max = 0,
        .total = 0,
    };

    fn add_result(self: *BenchMarkStatResult, val: u32) void {
        self.max = @max(self.max, val);
        self.min = @min(self.min, val);
        self.total += val;
        self.repeat += 1;
    }
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
            return run_internal(pm_check_table, repeat, args, .{
                .compare_results = true,
            });
        }

        /// Use this if the function may return a different value on subsequent calls
        pub inline fn run_not_pure(
            pm_check_table: []const [2]u32,
            repeat: u32,
            args: Args,
        ) linksection(IRAM_ATTR) Error!void {
            _ = run_internal(pm_check_table, repeat, args, .{});
        }

        const Option = struct {
            compare_results: bool = false,
            yield_between_runs: bool = false,
        };

        noinline fn run_internal(
            pm_check_table: []const [2]u32,
            repeat: u32,
            args: Args,
            option: Option,
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
                const retry = 3 + (repeat / 16); // Should be plenty

                var results_summary: BenchMarkStatResult = .init;

                var invalid: u32 = 0;
                var done: u32 = 0;
                while (done < repeat) {
                    const result, const stats = run_once_internal(
                        pm_check,
                        args,
                        if (option.compare_results) expected_result else null,
                    ) catch |err| {
                        invalid += 1;

                        // Inline the log code so it gets forced into IRAM
                        // Otherwise, it will clobber a large chunk of the IRAM cache
                        @call(.always_inline, log.warn, .{
                            "Done = {}/{}, Invalid = {}/{}: {t}",
                            .{ done, repeat, invalid, retry, err },
                        });

                        if (invalid > retry) {
                            return Error.IramBusyStall;
                        }
                        continue;
                    };

                    if (option.compare_results) {
                        if (expected_result != result) return Error.InconsistentResults;
                    }

                    results_summary.add_result(stats);

                    done += 1;
                }
                log.debug("Total = {}", .{results_summary.total});

                try apis.print_results(pm_check[0], pm_check[1], results_summary);
            }
            return expected_result;
        }

        noinline fn run_once_internal(
            pm_check: [2]u32,
            args: Args,
            consistent_result: ?Result,
        ) linksection(IRAM_ATTR) Error!struct { Result, u32 } {
            const result, const iram_busy, const stats = try run_once_PORT(
                pm_counter_iram_busy,
                pm_check,
                args,
                -1,
            );

            if (consistent_result) |expected_result| {
                if (expected_result != result) return Error.InconsistentResults;
            }

            if (iram_busy > 0) {
                // Inline the log code so it gets forced into IRAM
                // Otherwise, it will clobber a large chunk of the IRAM cache
                @call(.always_inline, log.warn, .{
                    "Instruction RAM/ROM busy stall = {} cycles",
                    .{iram_busy},
                });

                return Error.IramBusyStall;
            }

            return .{ result, stats };
        }

        const pm_counter_cycles: [2]u32 = .{ sys.XTPERF_CNT_CYCLES, 0xffff };
        const pm_counter_iram_busy: [2]u32 = .{ sys.XTPERF_CNT_I_STALL, sys.XTPERF_MASK_I_STALL_BUSY };

        noinline fn run_once_PORT(
            pm_check_0: [2]u32,
            pm_check_1: [2]u32,
            args: Args,
            tracelevel: c_int,
        ) linksection(IRAM_ATTR) Error!struct { Result, u32, u32 } {
            // Set up cycle counter
            access.xtensa_perfmon_stop();
            // if tracelevel used, then kernelcnt will be enabled
            const kernelcnt: bool = (tracelevel >= 0);

            access.xtensa_perfmon_init(0, @intCast(pm_check_0[0]), @intCast(pm_check_0[1]), kernelcnt, tracelevel);
            access.xtensa_perfmon_init(1, @intCast(pm_check_1[0]), @intCast(pm_check_1[1]), kernelcnt, tracelevel);

            access.xtensa_perfmon_start();
            // Do not inline the call, because that could change the instruction alignment
            const result = @call(.never_inline, function, args);
            access.xtensa_perfmon_stop();

            const p0 = sys.xtensa_perfmon_value(0);
            const p1 = sys.xtensa_perfmon_value(1);

            return .{ result, p0, p1 };
        }
    };
}

const apis = struct {
    // Rewrite & improvement of `sys.xtensa_perfmon_view_cb`
    fn print_results(select: u32, mask: u32, result: BenchMarkStatResult) BenchmarkError!void {
        log.info(
            "min/max/avg = {d:9} /{d:9} /{d:9} , select = {d:2}, mask = 0x{x:04}",
            .{ result.min, result.max, (result.total / result.repeat), select, mask },
        );

        log.info(
            "    {s}.",
            .{try get_select_description(select)},
        );

        const backing, const len = try get_mask_descriptions(select, mask);
        const mask_descriptions = backing[0..len];

        for (mask_descriptions) |desc| {
            log.info(
                "        {s}",
                .{desc},
            );
        }

        // log.info(
        //     "{s}",
        //     .{},
        // );
    }

    fn get_select_description(select: u32) BenchmarkError![*:0]const u8 {
        var i: usize = 0;
        while (true) : (i += 1) {
            if (sys.xtensa_perfmon_select_table[i].select == -1) break;
            if (sys.xtensa_perfmon_select_table[i].select == select) {
                return sys.xtensa_perfmon_select_table[i].description;
            }
        }
        return BenchmarkError.UnknownCounter;
    }

    fn get_mask_descriptions(select: u32, mask: u32) BenchmarkError!struct { [32][*:0]const u8, usize } {
        const pop: u6 = @popCount(mask);
        var ret: [32][*:0]const u8 = undefined;
        var ret_i: usize = 0;

        var i: usize = 0;
        while (ret_i < pop) : (i += 1) {
            if (sys.xtensa_perfmon_masks_table[i].select == -1) break;
            if (sys.xtensa_perfmon_masks_table[i].select == select) {
                if ((sys.xtensa_perfmon_masks_table[i].mask & @as(c_int, @intCast(mask))) != 0) {
                    ret[ret_i] = sys.xtensa_perfmon_masks_table[i].description;
                    ret_i += 1;
                }
            }
        }
        if (ret_i < pop) {
            return BenchmarkError.UnknownCounterMask;
        }
        assert(ret_i == @popCount(mask));
        return .{ ret, ret_i };
    }
};

const access = struct {
    const PmCtrl_Register = packed struct(u32) {
        intEn: bool = false,
        unused1: u2 = 0,
        krnlCnt: bool,
        traceLevel: u4,
        select: u5,
        unused2: u3 = 0,
        mask: u16,
    };

    /// Configure a performance monitor and reset the counter.
    fn xtensa_perfmon_init(id: usize, select: u16, mask: u16, kernelcnt: bool, tracelevel: c_int) void {
        assert(id < sys.ERI_PERFMON_MAX);
        const pmc: PmCtrl_Register = .{
            .krnlCnt = kernelcnt,
            .traceLevel = @intCast(0xf & tracelevel),
            .select = @intCast(select),
            .mask = mask,
        };

        eri.write((@as(u32, @intCast(sys.ERI_PERFMON_PM0)) + (id * @sizeOf(u32))), 0);
        eri.write((@as(u32, @intCast(sys.ERI_PERFMON_PMCTRL0)) + (id * @sizeOf(u32))), @bitCast(pmc));
        return;
    }

    fn xtensa_perfmon_reset(id: c_int) sys.esp_err_t {
        if (id >= sys.XCHAL_NUM_PERF_COUNTERS) {
            return sys.ESP_ERR_INVALID_ARG;
        }
        eri.write(sys.ERI_PERFMON_PM0 + id * @sizeOf(i32), 0);
        return sys.ESP_OK;
    }

    fn xtensa_perfmon_start() void {
        eri.write(sys.ERI_PERFMON_PGM, sys.PGM_PMEN);
    }

    fn xtensa_perfmon_stop() void {
        eri.write(sys.ERI_PERFMON_PGM, 0);
    }

    fn xtensa_perfmon_value(id: c_int) u32 {
        if (id >= sys.ERI_PERFMON_MAX) {
            return 0;
        }
        const result: u32 = eri.read(sys.ERI_PERFMON_PM0 + id * @sizeOf(i32));
        return result;
    }
};
