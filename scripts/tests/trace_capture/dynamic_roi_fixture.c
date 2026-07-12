#include <stdint.h>

volatile uint64_t fixture_sink;

int main(void)
{
    _Alignas(16) volatile uint64_t values[16];
    uint64_t sum = 0;

    for (uint64_t index = 0; index < 16; index++) {
        values[index] = index * 3;
    }
    for (uint64_t index = 0; index < 16; index++) {
        sum += values[index];
    }
    fixture_sink = sum;
    return sum == 360 ? 0 : 1;
}
