#ifndef L1D_QEMU_MEMTRACE_POLICY_H
#define L1D_QEMU_MEMTRACE_POLICY_H

#include <stdint.h>

enum l1d_trace_context_class {
    L1D_TRACE_CONTEXT_TARGET,
    L1D_TRACE_CONTEXT_IGNORE_NON_U,
    L1D_TRACE_CONTEXT_IGNORE_FOREIGN_SATP,
    L1D_TRACE_CONTEXT_INVALID_VCPU,
};

static inline enum l1d_trace_context_class
l1d_classify_trace_context(unsigned int vcpu_index, uint64_t privilege,
                           uint64_t satp, uint64_t bound_satp)
{
    if (vcpu_index != 0) {
        return L1D_TRACE_CONTEXT_INVALID_VCPU;
    }
    if (privilege != UINT64_C(0)) {
        return L1D_TRACE_CONTEXT_IGNORE_NON_U;
    }
    if (satp != bound_satp) {
        return L1D_TRACE_CONTEXT_IGNORE_FOREIGN_SATP;
    }
    return L1D_TRACE_CONTEXT_TARGET;
}

#endif
