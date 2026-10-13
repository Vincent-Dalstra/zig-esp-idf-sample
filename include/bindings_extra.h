// esp-idf component missing from bindings.h

#include "perfmon.h"

#ifdef CONFIG_IDF_TARGET_ARCH_XTENSA
#include "eri.h"
#include "xtensa-debug-module.h"
#include "xtensa/xt_perf_consts.h"
#endif
