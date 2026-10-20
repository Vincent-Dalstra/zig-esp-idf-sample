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

    const new_table_simple: [7]Statistic.Mask = .{
        .XTPERF_CNT_CYCLES.all,
        .XTPERF_CNT_INSN.all,
        .XTPERF_CNT_D_LOAD_U1.all,
        .XTPERF_CNT_D_STORE_U1.all,
        .XTPERF_CNT_BUBBLES.all.except(.R_HOLD_REG_DEP),
        .XTPERF_CNT_BUBBLES.R_HOLD_REG_DEP,
        .XTPERF_CNT_OVERFLOW.all,
    };
};

const Statistic = struct {
    const PmCtrl_Register = packed struct(u32) {
        intEn: bool = false,
        unused1: u2 = 0,
        krnlCnt: u1,
        traceLevel: u4,
        select: u5,
        unused2: u3 = 0,
        mask: u16,

        fn construct(select: Select, mask: Mask, traceLevel: access.TraceLevel) PmCtrl_Register {
            return .{
                .krnlCnt = @backingInt(traceLevel.kernelCnt),
                .traceLevel = @intCast(0xf & traceLevel.level),
                .select = @backingInt(select),
                .mask = @backingInt(mask),
            };
        }
    };

    const Select = enum(u5) {
        XTPERF_CNT_CYCLES,
        XTPERF_CNT_OVERFLOW,
        XTPERF_CNT_INSN,
        XTPERF_CNT_D_STALL,
        XTPERF_CNT_I_STALL,
        XTPERF_CNT_EXR,
        XTPERF_CNT_BUBBLES,
        XTPERF_CNT_I_TLB,
        XTPERF_CNT_I_MEM,
        XTPERF_CNT_D_TLB,
        XTPERF_CNT_D_LOAD_U1,
        XTPERF_CNT_D_LOAD_U2,
        XTPERF_CNT_D_LOAD_U3,
        XTPERF_CNT_D_STORE_U1,
        XTPERF_CNT_D_STORE_U2,
        XTPERF_CNT_D_STORE_U3,
        XTPERF_CNT_D_ACCESS_U1,
        XTPERF_CNT_D_ACCESS_U2,
        XTPERF_CNT_D_ACCESS_U3,
        XTPERF_CNT_MULTIPLE_LS,
        XTPERF_CNT_OUTBOUND_PIF,
        XTPERF_CNT_INBOUND_PIF,
        XTPERF_CNT_PREFETCH,
        // TODO: not available on the ESP32, only the ESP32-S2 and ESP32-S3
        // #if XCHAL_HW_VERSION >= 270004
        //     XTPERF_CNT_IDMA, "iDMA"},
        //     XTPERF_CNT_INSN_LENGTH, "Length of Instructions"},
        // #endif
    };
    const Mask = union(Select) {
        XTPERF_CNT_CYCLES: packed struct(u16) {
            cycles: bool,
            const all: @This() = @fromBackingInt(@intCast(0x0001));
        },
        XTPERF_CNT_OVERFLOW: packed struct(u16) {
            cycles: bool,
            const all: @This() = @fromBackingInt(@intCast(0x0001));
        },
        XTPERF_CNT_INSN: packed struct(u16) {
            JX: bool,
            CALLX: bool,
            RET: bool,
            RF: bool,
            BRANCH_TAKEN: bool,
            J: bool,
            CALL: bool,
            BRANCH_NOT_TAKEN: bool,
            LOOP_TAKEN: bool,
            unused0: bool,
            LOOP_BEGIN: bool,
            LOOP_END: bool,
            NON_BRANCH: bool,
            unused: u3,
            const all: @This() = @fromBackingInt(@intCast(0x8DFF));
            fn except(this: @This(), unset: @This()) @This() {
                return (@backingInt(this) & ~@backingInt(unset));
            }
        },
        XTPERF_CNT_BUBBLES: packed struct(u16) {
            PSO: bool,
            unused0: bool,
            R_HOLD_D_CACHE_MISS: bool,
            R_HOLD_STORE_RELEASE: bool,
            R_HOLD_REG_DEP: bool,
            R_HOLD_WAIT: bool,
            R_HOLD_HALT: bool,
            CTI: bool,
            WAIT1: bool,
            unused: u7,
            const all: @This() = @fromBackingInt(@intCast(0x01FD));
            fn except(this: @This(), unset: @This()) @This() {
                return (@backingInt(this) & ~@backingInt(unset));
            }
        },
        XTPERF_CNT_D_LOAD_U1: packed struct(u16) {
            CACHE_HITS: bool,
            CACHE_MISSES: bool,
            LOCAL_MEM: bool,
            LOCAL_BYPASS: bool,
            unused: u12,
            const all: @This() = @fromBackingInt(@intCast(0x0008));
            fn except(this: @This(), unset: @This()) @This() {
                return (@backingInt(this) & ~@backingInt(unset));
            }
        },
        XTPERF_CNT_D_STORE_U1: packed struct(u16) {
            CACHE_HITS: bool,
            CACHE_MISSES: bool,
            LOCAL_MEM: bool,
            LOCAL_BYPASS: bool,
            unused: u12,
            const all: @This() = @fromBackingInt(@intCast(0x0008));
            fn except(this: @This(), unset: @This()) @This() {
                return (@backingInt(this) & ~@backingInt(unset));
            }
        },
    };
};

const PERFMON_TRACELEVEL: c_int = -1;

const BenchmarkError = error{
    Failed,
    InconsistentResults, // see `run_not_pure()`
    IramBusyStall,
    UnknownCounter,
    UnknownCounterMask,
    ResetFunctionReturnedNull,
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

    // pub fn format(
    //     self: @This(),
    //     writer: *std.Io.Writer,
    // ) std.Io.Writer.Error!void {
    //     try writer.print(
    //         "{d:9} /{d:9} /{d:9}",
    //         .{ self.min, self.max, (self.total / self.repeat) },
    //     );
    // }
};

/// Note: `function` will be executed multiple times!
/// This is necessary to collect each of the different statistics.
///
/// It is recommended that `function` be a 'pure function', i.e.
/// - No side effects.
/// - Result depends only on arguments.
///
/// Otherwise, you should call `NewBenchMark` directly, which lets you provide
/// a function to `reset` things between each call.
pub fn BenchmarkPure(function: anytype) type {
    return Benchmark(function, null);
}
pub const Benchmark = NewBenchmark;

pub fn NewBenchmark(workFn: anytype, resetFn: anytype) type {
    const Error = BenchmarkError;

    const info = @typeInfo(@TypeOf(workFn));
    if (info != .@"fn")
        @compileError("Benchmark expects a function!");

    const workFn_info = info.@"fn";
    if (workFn_info.attrs.varargs)
        @compileError("Cannot create ArgsTuple for variadic function");

    const Result = workFn_info.return_type.?;
    const Args = std.meta.ArgsTuple(@TypeOf(workFn));

    const resetFn_info = @typeInfo(@TypeOf(resetFn));
    const ResetResult = if (resetFn_info == .null) void else blk: {
        if (info != .@"fn")
            @compileError("Reset must be `null` or a function!");
        const resetFn_info_function = resetFn_info.@"fn";
        if (resetFn_info_function.attrs.varargs)
            @compileError("Reset fn must not be variadic");
        const ResetArgs = std.meta.ArgsTuple(@TypeOf(workFn));
        if (Args != ResetArgs) {
            @compileError("Reset function must take the same arguments as the benchmarked function");
        }

        if (resetFn_info_function.return_type.? != void and resetFn_info_function.return_type.? != ?void) {
            @compileError("Reset function must have type `void` or `?void`");
        }
        break :blk resetFn_info_function.return_type.?;
    };

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
                try reset_internal(args);
                expected_result, const cycles, const iram_busy = internal.run_once(
                    pm_counter_cycles,
                    pm_counter_iram_busy,
                    args,
                    .all,
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
                    try reset_internal(args);
                    const result, const stats = run_once(
                        pm_check,
                        args,
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

        inline fn reset_internal(args: Args) Error!void {
            if (resetFn_info == .null) {
                return; // no reset required
            } else {
                switch (ResetResult) {
                    void => @call(.auto, resetFn, args),
                    ?void => @call(.auto, resetFn, args) orelse return Error.ResetFunctionReturnedNull,
                    else => unreachable,
                }
            }
        }

        pub noinline fn run_once(
            pm_check: [2]u32,
            args: Args,
        ) linksection(IRAM_ATTR) Error!struct { Result, u32 } {
            const result, const iram_busy, const stats = internal.run_once(
                pm_counter_iram_busy,
                pm_check,
                args,
                .all,
            );

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

        const internal = struct {
            noinline fn run_once(
                pm_check_0: [2]u32,
                pm_check_1: [2]u32,
                args: Args,
                tracelevel: access.TraceLevel,
            ) linksection(IRAM_ATTR) struct { Result, u32, u32 } {
                counter.start(pm_check_0, pm_check_1, tracelevel);
                // Do not inline the call, because that could change the instruction alignment
                const result = @call(.never_inline, workFn, args);
                const p0, const p1 = counter.stop();
                return .{ result, p0, p1 };
            }
        };
    };
}

pub const counter = struct {
    /// Reset, configure and start both counters.
    pub inline fn start(
        pm_check_0: [2]u32,
        pm_check_1: [2]u32,
        tracelevel: access.TraceLevel,
    ) void {
        access.xtensa_perfmon_stop();
        access.xtensa_perfmon_init(0, @intCast(pm_check_0[0]), @intCast(pm_check_0[1]), tracelevel);
        access.xtensa_perfmon_init(1, @intCast(pm_check_1[0]), @intCast(pm_check_1[1]), tracelevel);

        access.xtensa_perfmon_start();
    }
    // Collect the results of both counters
    pub inline fn stop() struct { u32, u32 } {
        access.xtensa_perfmon_stop();

        const p0 = sys.xtensa_perfmon_value(0);
        const p1 = sys.xtensa_perfmon_value(1);

        return .{ p0, p1 };
    }
};

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
        krnlCnt: u1,
        traceLevel: u4,
        select: u5,
        unused2: u3 = 0,
        mask: u16,
    };

    const TraceLevel = struct {
        kernelCnt: enum(u1) {
            equalOrLess = 0, // counts only when CINTLEVEL <= val
            greaterThan = 1, // counts only when CINTLEVEL > val
        },
        level: u4,

        const all: TraceLevel = .{
            .kernelCnt = .equalOrLess,
            .level = std.math.maxInt(u4),
        };
    };

    const Id = std.math.IntFittingRange(0, (sys.ERI_PERFMON_MAX - 1));
    const RegWidth = u32;

    /// Configure one of the performance monitors and reset its counter
    fn xtensa_perfmon_init(id: Id, select: u16, mask: u16, traceLevel: TraceLevel) linksection(IRAM_ATTR) void {
        assert(id < sys.ERI_PERFMON_MAX);
        const pmc: PmCtrl_Register = .{
            .krnlCnt = @backingInt(traceLevel.kernelCnt),
            .traceLevel = @intCast(0xf & traceLevel.level),
            .select = @intCast(select),
            .mask = mask,
        };
        xtensa_perfmon_reset(id);
        eri.write(regAddr(sys.ERI_PERFMON_PMCTRL0, id), @bitCast(pmc));
        return;
    }
    /// Reset a counter to 0
    fn xtensa_perfmon_reset(id: Id) void {
        assert(id < sys.XCHAL_NUM_PERF_COUNTERS);
        eri.write(regAddr(sys.ERI_PERFMON_PM0, id), 0);
        return;
    }
    fn xtensa_perfmon_value(id: Id) u32 {
        assert(id < sys.XCHAL_NUM_PERF_COUNTERS);
        return eri.read(regAddr(sys.ERI_PERFMON_PM0, id));
    }
    fn regAddr(regBase: c_int, id: Id) u32 {
        return (@as(u32, @intCast(regBase)) + (@as(u32, id) * @sizeOf(RegWidth)));
    }

    /// Always inline (a function return would affect the results)
    inline fn xtensa_perfmon_start() void {
        eri.write(sys.ERI_PERFMON_PGM, sys.PGM_PMEN);
    }
    /// Always inline (a function call would affect the results)
    inline fn xtensa_perfmon_stop() void {
        eri.write(sys.ERI_PERFMON_PGM, 0);
    }
};
