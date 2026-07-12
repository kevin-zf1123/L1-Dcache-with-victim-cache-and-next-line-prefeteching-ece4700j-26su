#include <stdint.h>

#if !defined(__riscv) || __riscv_xlen != 64
#error "dynamic_misaligned_fixture must be built for RV64"
#endif

volatile uint32_t misaligned_fixture_sink;

int main(void)
{
    _Alignas(16) volatile uint8_t bytes[32];
    uint32_t same_line;
    uint32_t cross_line;

    for (uint32_t index = 0; index < 32; index++) {
        bytes[index] = (uint8_t)(index + 1);
    }
    __asm__ volatile("lw %0, 3(%1)" : "=r"(same_line) : "r"(bytes) : "memory");
    __asm__ volatile("lw %0, 15(%1)" : "=r"(cross_line) : "r"(bytes) : "memory");
    misaligned_fixture_sink = same_line ^ cross_line;
    return 0;
}
