#ifndef CHATAI_JS_H
#define CHATAI_JS_H
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__)
#define CHATAI_EXPORT __attribute__((visibility("default")))
#else
#define CHATAI_EXPORT
#endif
#ifdef __cplusplus
extern "C" {
#endif
// 每次调用拥有独立 runtime；返回的字符串必须交给 chatai_js_free。
CHATAI_EXPORT char *chatai_js_eval(const char *code, size_t length, int32_t timeout_ms,
                                  size_t memory_limit, int32_t *status);
CHATAI_EXPORT size_t chatai_js_length(const char *value);
CHATAI_EXPORT void chatai_js_free(void *value);
#ifdef __cplusplus
}
#endif
#endif
