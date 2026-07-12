#include "../../qemu_memtrace_policy.h"
#include "../../qemu_memtrace_canonical.h"

#include <assert.h>
#include <stdint.h>

struct translate_fixture {
    bool succeed;
    uint64_t expected_vaddr;
    uint64_t paddr;
    unsigned int calls;
};

static bool translate_fixture_cb(uint64_t vaddr, uint64_t *paddr,
                                 void *userdata)
{
    struct translate_fixture *fixture = userdata;
    fixture->calls++;
    assert(vaddr == fixture->expected_vaddr);
    if (!fixture->succeed) {
        return false;
    }
    *paddr = fixture->paddr;
    return true;
}

int main(void)
{
    const uint64_t bound_satp = UINT64_C(0x8000000000001234);
    const uint64_t foreign_satp = UINT64_C(0x8000000000005678);

    assert(l1d_classify_trace_context(0, 0, bound_satp, bound_satp) ==
           L1D_TRACE_CONTEXT_TARGET);
    assert(l1d_classify_trace_context(0, 1, bound_satp, bound_satp) ==
           L1D_TRACE_CONTEXT_IGNORE_NON_U);
    assert(l1d_classify_trace_context(0, 0, foreign_satp, bound_satp) ==
           L1D_TRACE_CONTEXT_IGNORE_FOREIGN_SATP);

    /* A target resuming after a foreign address space remains attributable. */
    assert(l1d_classify_trace_context(0, 0, bound_satp, bound_satp) ==
           L1D_TRACE_CONTEXT_TARGET);
    assert(l1d_classify_trace_context(1, 0, bound_satp, bound_satp) ==
           L1D_TRACE_CONTEXT_INVALID_VCPU);

    struct l1d_touch_plan plan = {0};
    struct translate_fixture translation = {0};
    assert(l1d_plan_line_touches(UINT64_C(0x1003), UINT64_C(0x8003), 2,
                                 translate_fixture_cb, &translation,
                                 &plan) == L1D_TOUCH_PLAN_OK);
    assert(plan.misaligned && !plan.cross_line &&
           plan.canonical_accesses == 1 && plan.paddr_end == UINT64_C(0x8006));
    assert(translation.calls == 0);

    translation = (struct translate_fixture){
        .succeed = true,
        .expected_vaddr = UINT64_C(0x1010),
        .paddr = UINT64_C(0xa000),
    };
    assert(l1d_plan_line_touches(UINT64_C(0x100f), UINT64_C(0x900f), 1,
                                 translate_fixture_cb, &translation,
                                 &plan) == L1D_TOUCH_PLAN_OK);
    assert(plan.misaligned && plan.cross_line &&
           plan.canonical_accesses == 2 && plan.paddr_end == UINT64_C(0xa000));
    assert(translation.calls == 1);

    translation = (struct translate_fixture){
        .succeed = false,
        .expected_vaddr = UINT64_C(0x1002),
    };
    assert(l1d_plan_line_touches(UINT64_C(0x0fff), UINT64_C(0xbfff), 2,
                                 translate_fixture_cb, &translation,
                                 &plan) == L1D_TOUCH_PLAN_TRANSLATION_FAILED);
    assert(translation.calls == 1);
    return 0;
}
