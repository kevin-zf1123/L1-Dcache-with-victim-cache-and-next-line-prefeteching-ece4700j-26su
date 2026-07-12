#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

/* Execute exactly one dynamic ELF with the ROI shim injected. */

#include "roi_abi.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/personality.h>
#include <unistd.h>

static void usage(const char *program)
{
    fprintf(stderr,
            "usage: %s --shim PATH --nonce UINT64 --command-index UINT64 "
            "-- PROGRAM [ARG ...]\n",
            program);
}

static int set_preload(const char *shim)
{
    const char *existing = getenv("LD_PRELOAD");
    if (existing == NULL || existing[0] == '\0') {
        return setenv("LD_PRELOAD", shim, 1);
    }

    size_t size = strlen(shim) + 1 + strlen(existing) + 1;
    char *combined = malloc(size);
    if (combined == NULL) {
        return -1;
    }
    snprintf(combined, size, "%s:%s", shim, existing);
    int result = setenv("LD_PRELOAD", combined, 1);
    free(combined);
    return result;
}

static int disable_address_space_randomization(void)
{
    int current = personality(0xffffffffUL);
    if (current == -1) {
        return -1;
    }
    if (personality((unsigned long)current | ADDR_NO_RANDOMIZE) == -1) {
        return -1;
    }
    int verified = personality(0xffffffffUL);
    if (verified == -1 || ((unsigned long)verified & ADDR_NO_RANDOMIZE) == 0) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *shim = NULL;
    const char *nonce = NULL;
    const char *command = NULL;
    int index = 1;

    while (index < argc && strcmp(argv[index], "--") != 0) {
        if (index + 1 >= argc) {
            usage(argv[0]);
            return 2;
        }
        if (strcmp(argv[index], "--shim") == 0) {
            shim = argv[index + 1];
        } else if (strcmp(argv[index], "--nonce") == 0) {
            nonce = argv[index + 1];
        } else if (strcmp(argv[index], "--command-index") == 0) {
            command = argv[index + 1];
        } else {
            usage(argv[0]);
            return 2;
        }
        index += 2;
    }

    if (index >= argc || strcmp(argv[index], "--") != 0 ||
        index + 1 >= argc || shim == NULL || nonce == NULL ||
        command == NULL) {
        usage(argv[0]);
        return 2;
    }
    if (access(shim, R_OK) != 0) {
        fprintf(stderr, "trace_exec: cannot read shim %s: %s\n",
                shim, strerror(errno));
        return 126;
    }
    if (setenv(L1D_ROI_NONCE_ENV, nonce, 1) != 0 ||
        setenv(L1D_ROI_COMMAND_ENV, command, 1) != 0 ||
        set_preload(shim) != 0) {
        fprintf(stderr, "trace_exec: failed to prepare environment: %s\n",
                strerror(errno));
        return 126;
    }
    if (disable_address_space_randomization() != 0) {
        fprintf(stderr, "trace_exec: cannot disable address-space randomization: %s\n",
                strerror(errno));
        return 126;
    }

    execvp(argv[index + 1], &argv[index + 1]);
    fprintf(stderr, "trace_exec: exec %s failed: %s\n",
            argv[index + 1], strerror(errno));
    return 127;
}
