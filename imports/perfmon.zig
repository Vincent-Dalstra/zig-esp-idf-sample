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

comptime {
    if (std.mem.eql(u8, "xtensa", sys.CONFIG_IDF_TARGET_ARCH)) {
        assert(@hasDecl(sys, "CONFIG_IDF_TARGET_ARCH_XTENSA"));
    } else if (std.mem.eql(u8, "riscv", sys.CONFIG_IDF_TARGET_ARCH)) {
        assert(@hasDecl(sys, "CONFIG_IDF_TARGET_ARCH_RISCV"));
        @compileError("Perfmon is not supported on RISC-V Architecture");
    } else {
        @compileError("Unknown target architecture: " ++ sys.CONFIG_IDF_TARGET_ARCH);
    }
}

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

    pub const new_simple: [7]Statistic_Full.Mask = .{
        .{ .XTPERF_CNT_CYCLES = .all },
        .{ .XTPERF_CNT_INSN = .all },
        .{ .XTPERF_CNT_D_LOAD_U1 = .{ .LOCAL_MEM = true } },
        .{ .XTPERF_CNT_D_STORE_U1 = .{ .LOCAL_MEM = true } },
        .{ .XTPERF_CNT_BUBBLES = .except(.all, .{ .R_HOLD_REG_DEP = true }) },
        .{ .XTPERF_CNT_BUBBLES = .{ .R_HOLD_REG_DEP = true } },
        .{ .XTPERF_CNT_OVERFLOW = .all },
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
            pm_check_table: []const Statistic,
            repeat: u32,
            args: Args,
        ) linksection(IRAM_ATTR) Error!Result {
            return run_internal(pm_check_table, repeat, args, .{
                .compare_results = true,
            });
        }

        /// Use this if the function may return a different value on subsequent calls
        pub inline fn run_not_pure(
            pm_check_table: []const Statistic,
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
            stat_table: []const Statistic,
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

            for (stat_table) |stat| {
                const retry = 3 + (repeat / 16); // Should be plenty

                var results_summary: BenchMarkStatResult = .init;

                var invalid: u32 = 0;
                var done: u32 = 0;
                while (done < repeat) {
                    try reset_internal(args);

                    const result, const stats = run_once(
                        stat,
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

                try apis.print_results(stat, results_summary);
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
            stat: Statistic,
            args: Args,
        ) linksection(IRAM_ATTR) Error!struct { Result, u32 } {
            const result, const iram_busy, const stats = internal.run_once(
                pm_counter_iram_busy,
                stat,
                args,
                .all,
            );

            if (iram_busy > 0) {
                return Error.IramBusyStall;
            }

            return .{ result, stats };
        }

        const pm_counter_cycles: Statistic = .{ .XTPERF_CNT_CYCLES = .all };
        const pm_counter_iram_busy: Statistic = .{ .XTPERF_CNT_I_STALL = .{ .BUSY = true } };

        const internal = struct {
            noinline fn run_once(
                stat_0: Statistic,
                stat_1: Statistic,
                args: Args,
                tracelevel: access.TraceLevel,
            ) linksection(IRAM_ATTR) struct { Result, u32, u32 } {
                counter.start(stat_0, stat_1, tracelevel);
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
        stat_0: Statistic,
        stat_1: Statistic,
        tracelevel: access.TraceLevel,
    ) void {
        access.xtensa_perfmon_stop();
        access.xtensa_perfmon_init(0, stat_0, tracelevel);
        access.xtensa_perfmon_init(1, stat_1, tracelevel);

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
    fn print_results(stat: Statistic, result: BenchMarkStatResult) BenchmarkError!void {
        log.info(
            "min/max/avg = {d:9} /{d:9} /{d:9} , select = {d:2}, mask = 0x{x:04}",
            .{ result.min, result.max, (result.total / result.repeat), stat.infer().raw(), stat.raw() },
        );
        log.info(
            "    {s}.",
            .{try get_select_description(stat)},
        );

        const backing, const len = try get_mask_descriptions(stat);
        const mask_descriptions = backing[0..len];

        for (mask_descriptions) |desc| {
            log.info(
                "        {s}",
                .{desc},
            );
        }
    }

    fn get_select_description(select: Statistic_Full.Select) BenchmarkError![*:0]const u8 {
        var i: usize = 0;
        while (true) : (i += 1) {
            if (sys.xtensa_perfmon_select_table[i].select == -1) break;
            if (sys.xtensa_perfmon_select_table[i].select == @as(c_int, select.raw())) {
                return sys.xtensa_perfmon_select_table[i].description;
            }
        }
        return BenchmarkError.UnknownCounter;
    }

    fn get_mask_descriptions(stat: Statistic) BenchmarkError!struct { [16][*:0]const u8, usize } {
        const pop: u6 = @popCount(stat.raw());
        var ret: [16][*:0]const u8 = undefined;
        var ret_i: usize = 0;

        var i: usize = 0;
        while (ret_i < pop) : (i += 1) {
            if (sys.xtensa_perfmon_masks_table[i].select == -1) break;
            if (sys.xtensa_perfmon_masks_table[i].select == @as(c_int, stat.infer().raw())) {
                if ((sys.xtensa_perfmon_masks_table[i].mask & @as(c_int, stat.raw())) != 0) {
                    ret[ret_i] = sys.xtensa_perfmon_masks_table[i].description;
                    ret_i += 1;
                }
            }
        }
        if (ret_i < pop) {
            std.log.err(
                "Invalid Mask! {}/{} for select={d}, mask=0x{x:04}",
                .{ ret_i, pop, stat.infer().raw(), stat.raw() },
            );
            return BenchmarkError.UnknownCounterMask;
        }
        assert(ret_i == @popCount(stat.raw()));
        return .{ ret, ret_i };
    }
};

const access = struct {
    const PmCtrl_Register = Statistic_Full.PmCtrl_Register;
    const TraceLevel = PmCtrl_Register.TraceLevel;

    const Id = std.math.IntFittingRange(0, (sys.ERI_PERFMON_MAX - 1));
    const RegWidth = u32;

    /// Configure one of the performance monitors and reset its counter
    fn xtensa_perfmon_init(id: Id, stat: Statistic, traceLevel: TraceLevel) linksection(IRAM_ATTR) void {
        assert(id < sys.ERI_PERFMON_MAX);
        const pmc: PmCtrl_Register = .construct(stat.infer(), stat, traceLevel);
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

const Statistic = Statistic_Full.Mask;

const Statistic_Full = struct {
    const Full = struct {
        select: Select,
        mask: Mask,
    };

    pub const PmCtrl_Register = packed struct(u32) {
        intEn: bool = false,
        unused1: u2 = 0,
        krnlCnt: u1,
        traceLevel: u4,
        select: u5,
        unused2: u3 = 0,
        mask: u16,

        const TraceLevel = packed struct(u5) {
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

        pub fn construct(select: Select, mask: Mask, traceLevel: TraceLevel) PmCtrl_Register {
            return .{
                .krnlCnt = @backingInt(traceLevel.kernelCnt),
                .traceLevel = traceLevel.level,
                .select = @backingInt(select),
                .mask = mask.raw(),
            };
        }
    };

    pub const Select = enum(u5) {
        XTPERF_CNT_CYCLES = 0,
        XTPERF_CNT_OVERFLOW = 1,
        XTPERF_CNT_INSN = 2,
        XTPERF_CNT_D_STALL = 3,
        XTPERF_CNT_I_STALL = 4,
        XTPERF_CNT_EXR = 5,
        XTPERF_CNT_BUBBLES = 6,
        XTPERF_CNT_I_TLB = 7,
        XTPERF_CNT_I_MEM = 8,
        XTPERF_CNT_D_TLB = 9,
        XTPERF_CNT_D_LOAD_U1 = 10,
        XTPERF_CNT_D_LOAD_U2 = 11,
        XTPERF_CNT_D_LOAD_U3 = 12,
        XTPERF_CNT_D_STORE_U1 = 13,
        XTPERF_CNT_D_STORE_U2 = 14,
        XTPERF_CNT_D_STORE_U3 = 15,
        XTPERF_CNT_D_ACCESS_U1 = 16,
        XTPERF_CNT_D_ACCESS_U2 = 17,
        XTPERF_CNT_D_ACCESS_U3 = 18,
        XTPERF_CNT_MULTIPLE_LS = 22,
        XTPERF_CNT_OUTBOUND_PIF = 23,
        XTPERF_CNT_INBOUND_PIF = 24,
        XTPERF_CNT_PREFETCH = 26,
        // TODO: not available on the ESP32, only the ESP32-S2 and ESP32-S3
        // #if XCHAL_HW_VERSION >= 270004
        XTPERF_CNT_IDMA = 27,
        XTPERF_CNT_INSN_LENGTH = 28,
        // #endif XCHAL_HW_VERSION >= 270004

        fn raw(self: Select) u5 {
            return @backingInt(self);
        }
    };

    // TODO: Check this table against the esp-idf one, then remove this comment
    pub const Mask = union(Select) {
        XTPERF_CNT_CYCLES: packed struct(u16) {
            cycles: bool = false,
            unused: u15 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x0001));
        },
        XTPERF_CNT_OVERFLOW: packed struct(u16) {
            cycles: bool = false,
            unused: u15 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x0001));
        },
        XTPERF_CNT_INSN: packed struct(u16) {
            JX: bool = false,
            CALLX: bool = false,
            RET: bool = false,
            RF: bool = false,
            BRANCH_TAKEN: bool = false,
            J: bool = false,
            CALL: bool = false,
            BRANCH_NOT_TAKEN: bool = false,
            LOOP_TAKEN: bool = false,
            unused0: bool = false,
            LOOP_BEGIN: bool = false,
            LOOP_END: bool = false,
            NON_BRANCH: bool = false,
            unused: u3 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x8DFF));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_STALL: packed struct(u16) {
            unused0: u1 = 0,
            STORE_BUF_FULL: bool = false,
            STORE_BUF_CONFLICT: bool = false,
            CACHE_MISS: bool = false,
            BUSY: bool = false,
            IN_PIF: bool = false,
            MHT_LOOKUP: bool = false,
            UNCACHED_LOAD: bool = false,
            BANK_CONFLICT: bool = false,
            unused: u7 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x01FE));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_I_STALL: packed struct(u16) {
            CACHE_MISS: bool = false,
            BUSY: bool = false,
            IN_PIF: bool = false,
            TIE_PORT: bool = false,
            EXTERNAL_SIGNAL: bool = false,
            UNCACHED_FETCH: bool = false,
            FAST_L32R: bool = false,
            ITERATIVE_MUL: bool = false,
            ITERATIVE_DIV: bool = false,
            unused: u7 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x01FF));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_EXR: packed struct(u16) {
            REPLAYS: bool = false,
            LEVEL1_INT: bool = false,
            LEVELH_INT: bool = false,
            DEBUG: bool = false,
            NMI: bool = false,
            WINDOW: bool = false,
            ALLOCA: bool = false,
            OTHER: bool = false,
            MEM_ERR: bool = false,
            unused: u7 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x01FF));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_BUBBLES: packed struct(u16) {
            PSO: bool = false,
            unused0: bool = false,
            R_HOLD_D_CACHE_MISS: bool = false,
            R_HOLD_STORE_RELEASE: bool = false,
            R_HOLD_REG_DEP: bool = false,
            R_HOLD_WAIT: bool = false,
            R_HOLD_HALT: bool = false,
            CTI: bool = false,
            WAIT1: bool = false,
            unused: u7 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x01FD));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_I_TLB: packed struct(u16) {
            HITS: bool = false,
            REPLAYS: bool = false,
            REFILLS: bool = false,
            MISSES: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_I_MEM: packed struct(u16) {
            CACHE_HITS: bool = false,
            CACHE_MISSES: bool = false,
            IRAM: bool = false,
            BYPASS: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_TLB: packed struct(u16) {
            HITS: bool = false,
            REPLAYS: bool = false,
            REFILLS: bool = false,
            MISSES: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_LOAD_U1: packed struct(u16) {
            CACHE_HITS: bool = false,
            CACHE_MISSES: bool = false,
            LOCAL_MEM: bool = false,
            BYPASS: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_LOAD_U2: packed struct(u16) {
            CACHE_HITS: bool = false,
            CACHE_MISSES: bool = false,
            LOCAL_MEM: bool = false,
            BYPASS: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_LOAD_U3: packed struct(u16) {
            CACHE_HITS: bool = false,
            CACHE_MISSES: bool = false,
            LOCAL_MEM: bool = false,
            BYPASS: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_STORE_U1: packed struct(u16) {
            CACHE_HITS: bool = false,
            CACHE_MISSES: bool = false,
            LOCAL_MEM: bool = false,
            PIF: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_STORE_U2: packed struct(u16) {
            CACHE_HITS: bool = false,
            CACHE_MISSES: bool = false,
            LOCAL_MEM: bool = false,
            PIF: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_STORE_U3: packed struct(u16) {
            CACHE_HITS: bool = false,
            CACHE_MISSES: bool = false,
            LOCAL_MEM: bool = false,
            PIF: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_ACCESS_U1: packed struct(u16) {
            CACHE_MISSES: bool = false,
            HITS_SHARED: bool = false,
            HITS_EXCLUSIVE: bool = false,
            HITS_MODIFIED: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            const hits: @This() = @fromBackingInt(@intCast(0x000E));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_ACCESS_U2: packed struct(u16) {
            CACHE_MISSES: bool = false,
            HITS_SHARED: bool = false,
            HITS_EXCLUSIVE: bool = false,
            HITS_MODIFIED: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            const hits: @This() = @fromBackingInt(@intCast(0x000E));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_D_ACCESS_U3: packed struct(u16) {
            CACHE_MISSES: bool = false,
            HITS_SHARED: bool = false,
            HITS_EXCLUSIVE: bool = false,
            HITS_MODIFIED: bool = false,
            unused: u12 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x000F));
            const hits: @This() = @fromBackingInt(@intCast(0x000E));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_MULTIPLE_LS: packed struct(u16) {
            Store0_Load0: bool = false,
            Store0_Load1: bool = false,
            Store1_Load0: bool = false,
            Store1_Load1: bool = false,
            Store0_Load2: bool = false,
            Store2_Load0: bool = false,
            unused: u10 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x003F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_OUTBOUND_PIF: packed struct(u16) {
            CASTOUT: bool = false,
            PREFETCH: bool = false,
            unused: u14 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x0003));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_INBOUND_PIF: packed struct(u16) {
            I_DMA: bool = false,
            D_DMA: bool = false,
            unused: u14 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x0003));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_PREFETCH: packed struct(u16) {
            I_HIT: bool = false,
            D_HIT: bool = false,
            I_MISS: bool = false,
            D_MISS: bool = false,
            unused0: u1 = 0,
            D_L1_FILL: bool = false,
            unused: u10 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x002F));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },

        // TODO: not available on the ESP32, only the ESP32-S2 and ESP32-S3
        // #if XCHAL_HW_VERSION >= 270004

        XTPERF_CNT_IDMA: packed struct(u16) {
            ACTIVE_CYCLES: bool = false,
            unused: u15 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x0001));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },
        XTPERF_CNT_INSN_LENGTH: packed struct(u16) {
            _16: bool = false,
            _24: bool = false,
            _32: bool = false,
            _40: bool = false,
            _48: bool = false,
            _56: bool = false,
            _64: bool = false,
            _72: bool = false,
            _80: bool = false,
            _88: bool = false,
            _96: bool = false,
            _104: bool = false,
            _112: bool = false,
            _120: bool = false,
            _128: bool = false,
            unused: u1 = 0,
            const all: @This() = @fromBackingInt(@intCast(0x7FFF));
            pub fn except(this: @This(), unset: @This()) @This() {
                return @fromBackingInt(@intCast(@backingInt(this) & ~@backingInt(unset)));
            }
        },

        // #endif XCHAL_HW_VERSION >= 270004

        fn infer(mask: Mask) Select {
            switch (mask) {
                else => |_, tag| {
                    return tag;
                },
            }
        }

        fn raw(self: Mask) u16 {
            switch (self) {
                inline else => |val| {
                    return @backingInt(val);
                },
            }
        }
    };
};
