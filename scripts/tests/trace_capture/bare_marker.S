    .option norvc
    .section .text
    .globl _start
_start:
    li a0, 0x4c3144524f490002
    li a1, 0x55
    li a2, 1
    li a3, 7
    li a4, 42
    li a5, 42
    .word 0x12300013

    /* QEMU virt SiFive test device: 0x5555 requests a clean exit. */
    li t0, 0x100000
    li t1, 0x5555
    sw t1, 0(t0)
1:
    wfi
    j 1b
