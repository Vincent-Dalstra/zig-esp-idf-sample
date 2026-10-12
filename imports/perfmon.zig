const std = @import("std");
const sys = @import("sys");

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
pub const pm_check = struct {
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
};
/// Note: `function` will be executed multiple times!
/// This is necessary to collect each of the different statistics.
///
/// It is recommended that `function` be a 'pure function', i.e.
/// - No side effects.
/// - Result depends only on arguments.
/// Otherwise, you may get interesting Results.
pub fn Benchmark(function: anytype) type {
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

// const Benchmark_old = struct {
//     pm_config: sys.xtensa_perfmon_config_t,

//     pub fn init() sys.xtensa_perfmon_config_t {
//         const PERFMON_TRACELEVEL: c_int = -1;

//         return .{
//             .pm_config = .{
//                 .counters_size = pm_check_table.len / 2,
//                 .select_mask = &pm_check_table,
//                 .repeat_count = 1,
//                 .max_deviation = 1,
//                 .call_function = undefined,
//                 .call_params = @ptrCast(&params),
//                 .callback = sys.xtensa_perfmon_view_cb,
//                 .callback_params = null, // stdout
//                 .tracelevel = PERFMON_TRACELEVEL,
//             };
//         };
//     }

//     pub fn run(
//         bench: Benchmark,
//         function: anytype,
//         args: std.meta.ArgsTuple(@TypeOf(function)),
//     ) @typeInfo(@TypeOf(function)).@"fn".return_type {
//         const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
//         const Args = @TypeOf(args);
//         const TypeErased = struct {
//             fn start(context: *const anyopaque, result: *anyopaque) void {
//                 const args_casted: *const Args = @ptrCast(@alignCast(context));
//                 const result_casted: *Result = @ptrCast(@alignCast(result));
//                 result_casted.* = @call(.auto, function, args_casted.*);
//             }
//         };

//         var pm_config: sys.xtensa_perfmon_config_t = .{
//             .counters_size = pm_check_table.len / 2,
//             .select_mask = &pm_check_table,
//             .repeat_count = TOTAL_CALL_AMOUNT,
//             .max_deviation = 1,
//             .call_function = undefined,
//             .call_params = @ptrCast(&params),
//             .callback = sys.xtensa_perfmon_view_cb,
//             .callback_params = null, // stdout
//             .tracelevel = PERFMON_TRACELEVEL,
//         };

//         return future;
//     }
// }
