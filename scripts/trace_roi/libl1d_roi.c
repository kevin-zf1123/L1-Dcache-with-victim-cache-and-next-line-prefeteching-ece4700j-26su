#define _GNU_SOURCE

/* RISC-V/glibc LD_PRELOAD shim that brackets only the target process main(). */

#include "roi_abi.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#if !defined(__riscv) || __riscv_xlen != 64
#error "libl1d_roi must be built for RV64"
#endif

typedef int (*main_function_t)(int, char **, char **);
typedef int (*libc_start_main_t)(main_function_t, int, char **,
                                 void (*)(void), void (*)(void),
                                 void (*)(void), void *);

static main_function_t target_main;
static uint64_t run_nonce;
static uint64_t command_index;

static void fail_closed(void)
{
    /* 125 is deliberately distinct from exec failure (127). */
    _exit(125);
}

static uint64_t parse_env_u64(const char *name, int allow_zero)
{
    const char *text = getenv(name);
    char *end = NULL;

    if (text == NULL || text[0] == '\0' || text[0] == '-') {
        fail_closed();
    }
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0' ||
        (!allow_zero && parsed == 0)) {
        fail_closed();
    }
    return (uint64_t)parsed;
}

__attribute__((always_inline))
static inline void emit_marker(uint64_t event, uint64_t nonce_value,
                               uint64_t command_value, uint64_t pid_value,
                               uint64_t tid_value)
{
    register uint64_t abi_magic __asm__("a0") = L1D_ROI_MAGIC;
    register uint64_t nonce __asm__("a1") = nonce_value;
    register uint64_t roi_event __asm__("a2") = event;
    register uint64_t command __asm__("a3") = command_value;
    register uint64_t pid __asm__("a4") = pid_value;
    register uint64_t tid __asm__("a5") = tid_value;

    __asm__ volatile(
        ".word 0x12300013 # %0 %1 %2 %3 %4 %5"
        :
        : "r"(abi_magic), "r"(nonce), "r"(roi_event),
          "r"(command), "r"(pid), "r"(tid)
        : "memory");
}

static int traced_main(int argc, char **argv, char **envp)
{
    main_function_t main_function = target_main;
    uint64_t nonce = run_nonce;
    uint64_t command = command_index;
    uint64_t pid = (uint64_t)getpid();
    uint64_t tid = (uint64_t)syscall(SYS_gettid);

    emit_marker(L1D_ROI_START, nonce, command, pid, tid);
    int result = main_function(argc, argv, envp);
    emit_marker(L1D_ROI_STOP, nonce, command, pid, tid);
    return result;
}

__attribute__((visibility("default")))
int __libc_start_main(main_function_t main_function, int argc, char **argv,
                      void (*init)(void), void (*fini)(void),
                      void (*rtld_fini)(void), void *stack_end)
{
    libc_start_main_t real_start =
        (libc_start_main_t)dlsym(RTLD_NEXT, "__libc_start_main");
    if (real_start == NULL || main_function == NULL) {
        fail_closed();
    }

    run_nonce = parse_env_u64(L1D_ROI_NONCE_ENV, 0);
    command_index = parse_env_u64(L1D_ROI_COMMAND_ENV, 1);
    target_main = main_function;
    return real_start(traced_main, argc, argv, init, fini, rtld_fini,
                      stack_end);
}
