#define _POSIX_C_SOURCE 200809L
#include "chatai_js.h"
#include "quickjs/quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_SOURCE (4 * 1024 * 1024)
#define MAX_OUTPUT (4 * 1024 * 1024)
#define MAX_ERROR 4096
#define MAX_MEMORY (64 * 1024 * 1024)

typedef struct { int64_t deadline; int timed_out; } Budget;
static int64_t monotonic_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int interrupted(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    Budget *budget = opaque;
    int64_t now = monotonic_ms();
    if (now < 0 || now >= budget->deadline) budget->timed_out = 1;
    return budget->timed_out;
}
static char *copy_string(const char *text, size_t length) {
    size_t *storage = malloc(sizeof(size_t) + length + 1);
    char *result = storage ? (char *)(storage + 1) : NULL;
    if (result) { *storage = length; memcpy(result, text, length); result[length] = 0; }
    return result;
}
static char *message(int32_t *status, int32_t code, const char *text) {
    *status = code;
    return copy_string(text, strlen(text));
}

char *chatai_js_eval(const char *code, size_t length, int32_t timeout_ms,
                     size_t memory_limit, int32_t *status) {
    if (!status) return NULL;
    if (!code || length > MAX_SOURCE || timeout_ms < 1 || timeout_ms > 10000 ||
        memory_limit < 1024 * 1024 || memory_limit > MAX_MEMORY) {
        return message(status, 1, "Invalid JavaScript resource budget");
    }
    Budget budget = { monotonic_ms(), 0 };
    if (budget.deadline < 0) return message(status, 1, "Monotonic clock unavailable");
    budget.deadline += timeout_ms;
    char *source = copy_string(code, length);
    if (!source) return message(status, 1, "Source allocation failed");
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) { chatai_js_free(source); return message(status, 1, "Runtime allocation failed"); }
    JS_SetMemoryLimit(runtime, memory_limit);
    JS_SetMaxStackSize(runtime, 256 * 1024);
    JS_SetCanBlock(runtime, 0); // Atomics.wait 不能阻塞原生线程以绕过中断。
    JS_SetInterruptHandler(runtime, interrupted, &budget);
    JSContext *context = JS_NewContext(runtime);
    if (!context) {
        JS_FreeRuntime(runtime); chatai_js_free(source);
        return message(status, 1, "JavaScript memory limit exceeded");
    }
    // 不安装 quickjs-libc、模块加载器或宿主绑定：没有文件、网络和进程能力。
    JSValue value = JS_Eval(context, source, length, "skill.js", JS_EVAL_TYPE_GLOBAL);
    chatai_js_free(source);
    int failed = JS_IsException(value);
    if (failed) { JS_FreeValue(context, value); value = JS_GetException(context); }
    size_t output_length = 0;
    const char *text = JS_ToCStringLen(context, &output_length, value);
    char *output;
    if (budget.timed_out || interrupted(runtime, &budget)) {
        output = message(status, 1, "JavaScript execution timed out");
    } else if (!text) {
        output = message(status, 1, "JavaScript result conversion failed or memory limit exceeded");
    } else if (output_length > (failed ? MAX_ERROR : MAX_OUTPUT)) {
        output = message(status, 1, failed ? "JavaScript error exceeds limit" : "JavaScript output exceeds limit");
    } else {
        *status = failed ? 1 : 0;
        output = copy_string(text, output_length);
    }
    if (text) JS_FreeCString(context, text);
    JS_FreeValue(context, value);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    return output;
}
size_t chatai_js_length(const char *value) { return value ? ((const size_t *)value)[-1] : 0; }
void chatai_js_free(void *value) { if (value) free((size_t *)value - 1); }
