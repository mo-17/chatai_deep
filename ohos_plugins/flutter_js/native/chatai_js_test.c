#include "chatai_js.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void check(const char *code, int timeout, size_t memory, int error, const char *contains) {
    fprintf(stderr, "Checking JS budget (timeout=%d)\n", timeout);
    int32_t status = -1;
    char *result = chatai_js_eval(code, strlen(code), timeout, memory, &status);
    assert(result != NULL);
    if (status != error || !strstr(result, contains)) {
        fprintf(stderr, "Unexpected JS result: status=%d, output=%s\n", status, result);
        assert(0);
    }
    chatai_js_free(result);
}
int main(void) {
    const size_t heap = 32 * 1024 * 1024;
    check("'中文😀:' + JSON.stringify([1,2,3].map(x=>x*2))", 2000, heap, 0, "中文😀:[2,4,6]");
    check("[typeof fetch,typeof require,typeof std,typeof os,typeof process,typeof sendMessage].join(',')", 2000, heap, 0,
          "undefined,undefined,undefined,undefined,undefined,undefined");
    check("/(a+)+$/.test('a'.repeat(200)+'!')", 30, heap, 1, "timed out");
    check("while(true){}", 30, heap, 1, "timed out");
    check("({toString(){while(true){}}})", 30, heap, 1, "timed out");
    check("const a=[];while(true)a.push(new Array(10000).fill('memory'))", 2000, 2*1024*1024, 1, "memory");
    check("function f(){return f()}f()", 2000, heap, 1, "stack");
    check("'a'.repeat(4*1024*1024+1)", 2000, heap, 1, "output exceeds");
    check("throw new Error('expected')", 2000, heap, 1, "expected");
    check("Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0)", 100, heap, 1, "cannot block");
    check("globalThis.leak=3", 2000, heap, 0, "3");
    check("typeof leak", 2000, heap, 0, "undefined");
    check("1", 0, heap, 1, "Invalid");
    check("1", 2000, 128*1024*1024, 1, "Invalid");
    puts("14 real QuickJS runtime checks passed");
    return 0;
}
