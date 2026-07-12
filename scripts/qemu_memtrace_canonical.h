#ifndef L1D_QEMU_MEMTRACE_CANONICAL_H
#define L1D_QEMU_MEMTRACE_CANONICAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define L1D_TRACE_LINE_BYTES UINT64_C(16)

typedef bool (*l1d_translate_vaddr_fn)(uint64_t vaddr, uint64_t *paddr,
                                       void *userdata);

enum l1d_touch_plan_result {
    L1D_TOUCH_PLAN_OK,
    L1D_TOUCH_PLAN_ADDRESS_OVERFLOW,
    L1D_TOUCH_PLAN_TRANSLATION_FAILED,
};

struct l1d_touch_plan {
    uint64_t vaddr_end;
    uint64_t paddr_end;
    bool misaligned;
    bool cross_line;
    unsigned int canonical_accesses;
};

static inline enum l1d_touch_plan_result
l1d_plan_line_touches(uint64_t vaddr, uint64_t paddr,
                      unsigned int size_shift, l1d_translate_vaddr_fn translate,
                      void *translate_userdata, struct l1d_touch_plan *plan)
{
    const uint64_t size_bytes = UINT64_C(1) << size_shift;
    const uint64_t last_offset = size_bytes - 1;

    if (vaddr > UINT64_MAX - last_offset) {
        return L1D_TOUCH_PLAN_ADDRESS_OVERFLOW;
    }
    plan->vaddr_end = vaddr + last_offset;
    plan->misaligned = (vaddr & last_offset) != 0;
    plan->cross_line =
        (vaddr / L1D_TRACE_LINE_BYTES) !=
        (plan->vaddr_end / L1D_TRACE_LINE_BYTES);
    plan->canonical_accesses = plan->cross_line ? 2u : 1u;

    if (plan->cross_line) {
        if (translate == NULL ||
            !translate(plan->vaddr_end, &plan->paddr_end,
                       translate_userdata)) {
            return L1D_TOUCH_PLAN_TRANSLATION_FAILED;
        }
    } else {
        if (paddr > UINT64_MAX - last_offset) {
            return L1D_TOUCH_PLAN_ADDRESS_OVERFLOW;
        }
        plan->paddr_end = paddr + last_offset;
    }
    return L1D_TOUCH_PLAN_OK;
}

#endif
