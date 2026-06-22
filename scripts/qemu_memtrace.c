/*
 * QEMU TCG plugin that emits committed data-memory accesses in this repo's
 * trace replay format:
 *
 *   opcode size unsigned address [data]
 *
 * opcode: 0=load, 1=store
 * size:   0=byte, 1=half, 2=word, 3=double
 *
 * Optional RISC-V HINT markers toggle tracing without trapping:
 *   start: .word 0x12300013   // addi x0, x0, 0x123
 *   stop:  .word 0x12400013   // addi x0, x0, 0x124
 */

#include <qemu-plugin.h>

#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

enum {
    MAGIC_TRACE_START = 0x12300013u,
    MAGIC_TRACE_STOP = 0x12400013u,
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *trace_file;
static qemu_plugin_id_t plugin_id;
static bool tracing_enabled;
static bool use_phys_addr;
static bool skip_io = true;
static bool skip_misaligned = true;
static bool reset_on_start = true;
static bool summary_written;
static bool callbacks_reset_requested;
static uint64_t limit = 10000000;
static uint64_t captured;
static uint64_t skipped_size;
static uint64_t skipped_io;
static uint64_t skipped_misaligned;
static uint64_t dropped_after_limit;

static bool parse_bool_arg(const char *value)
{
    return strcmp(value, "1") == 0 ||
           strcmp(value, "on") == 0 ||
           strcmp(value, "yes") == 0 ||
           strcmp(value, "true") == 0;
}

static uint64_t parse_u64(const char *value)
{
    char *end = NULL;
    uint64_t result = strtoull(value, &end, 0);

    if (end == value || (end != NULL && *end != '\0')) {
        fprintf(stderr, "qemu_memtrace: invalid integer argument '%s'\n",
                value);
        exit(2);
    }

    return result;
}

static uint64_t mem_value_as_u64(qemu_plugin_mem_value value)
{
    switch (value.type) {
    case QEMU_PLUGIN_MEM_VALUE_U8:
        return value.data.u8;
    case QEMU_PLUGIN_MEM_VALUE_U16:
        return value.data.u16;
    case QEMU_PLUGIN_MEM_VALUE_U32:
        return value.data.u32;
    case QEMU_PLUGIN_MEM_VALUE_U64:
        return value.data.u64;
    case QEMU_PLUGIN_MEM_VALUE_U128:
        return value.data.u128.low;
    default:
        return 0;
    }
}

static void write_store_data(unsigned int size_shift, uint64_t data)
{
    switch (size_shift) {
    case 0:
        fprintf(trace_file, " %02" PRIx64, data & 0xffu);
        break;
    case 1:
        fprintf(trace_file, " %04" PRIx64, data & 0xffffu);
        break;
    case 2:
        fprintf(trace_file, " %08" PRIx64, data & 0xffffffffu);
        break;
    default:
        fprintf(trace_file, " %016" PRIx64, data);
        break;
    }
}

static void write_summary_locked(const char *reason)
{
    if (trace_file == NULL || summary_written) {
        return;
    }

    fprintf(trace_file,
            "# summary reason=%s captured=%" PRIu64
            " skipped_size=%" PRIu64
            " skipped_io=%" PRIu64
            " skipped_misaligned=%" PRIu64
            " dropped_after_limit=%" PRIu64 "\n",
            reason, captured, skipped_size, skipped_io, skipped_misaligned,
            dropped_after_limit);
    fflush(trace_file);
    fclose(trace_file);
    trace_file = NULL;
    summary_written = true;
}

static void reset_done_cb(qemu_plugin_id_t id)
{
    (void)id;
}

static bool request_callback_reset_locked(void)
{
    if (callbacks_reset_requested) {
        return false;
    }

    callbacks_reset_requested = true;
    return true;
}

static void trace_mem_cb(unsigned int vcpu_index, qemu_plugin_meminfo_t info,
                         uint64_t vaddr, void *userdata)
{
    (void)vcpu_index;
    (void)userdata;

    pthread_mutex_lock(&lock);

    if (callbacks_reset_requested) {
        pthread_mutex_unlock(&lock);
        return;
    }

    if (!tracing_enabled) {
        pthread_mutex_unlock(&lock);
        return;
    }

    if (captured >= limit) {
        tracing_enabled = false;
        dropped_after_limit++;
        write_summary_locked("limit");
        bool do_reset = request_callback_reset_locked();
        pthread_mutex_unlock(&lock);
        if (do_reset) {
            qemu_plugin_reset(plugin_id, reset_done_cb);
        }
        return;
    }

    unsigned int size_shift = qemu_plugin_mem_size_shift(info);
    if (size_shift > 3) {
        skipped_size++;
        pthread_mutex_unlock(&lock);
        return;
    }

    uint64_t addr = vaddr;
    struct qemu_plugin_hwaddr *haddr = qemu_plugin_get_hwaddr(info, vaddr);
    if (haddr != NULL) {
        bool is_io = qemu_plugin_hwaddr_is_io(haddr);
        if (skip_io && is_io) {
            skipped_io++;
            pthread_mutex_unlock(&lock);
            return;
        }
        if (use_phys_addr && !is_io) {
            addr = qemu_plugin_hwaddr_phys_addr(haddr);
        }
    }

    if (skip_misaligned && (addr & ((UINT64_C(1) << size_shift) - 1)) != 0) {
        skipped_misaligned++;
        pthread_mutex_unlock(&lock);
        return;
    }

    bool is_store = qemu_plugin_mem_is_store(info);
    if (is_store) {
        uint64_t data = mem_value_as_u64(qemu_plugin_mem_get_value(info));
        fprintf(trace_file, "1 %u 0 %016" PRIx64, size_shift, addr);
        write_store_data(size_shift, data);
        fputc('\n', trace_file);
    } else {
        int unsigned_load = qemu_plugin_mem_is_sign_extended(info) ? 0 : 1;
        fprintf(trace_file, "0 %u %d %016" PRIx64 "\n",
                size_shift, unsigned_load, addr);
    }

    captured++;
    if (captured >= limit) {
        tracing_enabled = false;
        write_summary_locked("limit");
        bool do_reset = request_callback_reset_locked();
        pthread_mutex_unlock(&lock);
        if (do_reset) {
            qemu_plugin_reset(plugin_id, reset_done_cb);
        }
        return;
    }

    pthread_mutex_unlock(&lock);
}

static void marker_start_cb(unsigned int vcpu_index, void *userdata)
{
    (void)vcpu_index;
    (void)userdata;

    pthread_mutex_lock(&lock);
    tracing_enabled = true;
    if (reset_on_start) {
        captured = 0;
        skipped_size = 0;
        skipped_io = 0;
        skipped_misaligned = 0;
        dropped_after_limit = 0;
    }
    pthread_mutex_unlock(&lock);
}

static void marker_stop_cb(unsigned int vcpu_index, void *userdata)
{
    (void)vcpu_index;
    (void)userdata;

    pthread_mutex_lock(&lock);
    tracing_enabled = false;
    write_summary_locked("marker_stop");
    bool do_reset = request_callback_reset_locked();
    pthread_mutex_unlock(&lock);
    if (do_reset) {
        qemu_plugin_reset(plugin_id, reset_done_cb);
    }
}

static uint32_t read_le32(const uint8_t bytes[4])
{
    return ((uint32_t)bytes[0]) |
           ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

static void translate_tb_cb(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    (void)id;

    size_t n_insns = qemu_plugin_tb_n_insns(tb);
    for (size_t i = 0; i < n_insns; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);

        if (qemu_plugin_insn_size(insn) == 4) {
            uint8_t bytes[4] = {0};
            if (qemu_plugin_insn_data(insn, bytes, sizeof(bytes)) == 4) {
                uint32_t word = read_le32(bytes);
                if (word == MAGIC_TRACE_START) {
                    qemu_plugin_register_vcpu_insn_exec_cb(
                        insn, marker_start_cb, QEMU_PLUGIN_CB_NO_REGS, NULL);
                } else if (word == MAGIC_TRACE_STOP) {
                    qemu_plugin_register_vcpu_insn_exec_cb(
                        insn, marker_stop_cb, QEMU_PLUGIN_CB_NO_REGS, NULL);
                }
            }
        }

        qemu_plugin_register_vcpu_mem_cb(
            insn, trace_mem_cb, QEMU_PLUGIN_CB_NO_REGS,
            QEMU_PLUGIN_MEM_RW, NULL);
    }
}

static void exit_cb(qemu_plugin_id_t id, void *userdata)
{
    (void)id;
    (void)userdata;

    pthread_mutex_lock(&lock);
    write_summary_locked("qemu_exit");
    pthread_mutex_unlock(&lock);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const qemu_info_t *info,
                                           int argc, char **argv)
{
    (void)info;
    plugin_id = id;

    const char *out_path = "qemu-memtrace.trace";

    for (int i = 0; i < argc; i++) {
        char *equals = strchr(argv[i], '=');
        if (equals == NULL) {
            continue;
        }
        *equals = '\0';
        const char *key = argv[i];
        const char *value = equals + 1;

        if (strcmp(key, "out") == 0) {
            out_path = value;
        } else if (strcmp(key, "limit") == 0) {
            limit = parse_u64(value);
        } else if (strcmp(key, "start") == 0) {
            tracing_enabled = parse_bool_arg(value);
        } else if (strcmp(key, "phys") == 0) {
            use_phys_addr = parse_bool_arg(value);
        } else if (strcmp(key, "noio") == 0) {
            skip_io = parse_bool_arg(value);
        } else if (strcmp(key, "aligned") == 0) {
            skip_misaligned = parse_bool_arg(value);
        } else if (strcmp(key, "reset") == 0) {
            reset_on_start = parse_bool_arg(value);
        } else {
            fprintf(stderr, "qemu_memtrace: unknown argument '%s'\n", key);
            return 1;
        }
    }

    trace_file = fopen(out_path, "w");
    if (trace_file == NULL) {
        perror("qemu_memtrace: fopen");
        return 1;
    }
    setvbuf(trace_file, NULL, _IOFBF, 1 << 20);

    fprintf(trace_file, "# opcode size unsigned address [data]\n");
    fprintf(trace_file, "# opcode 0 = load, opcode 1 = store.\n");
    fprintf(trace_file, "# size: 0=byte, 1=half, 2=word, 3=double.\n");
    fprintf(trace_file,
            "# unsigned is used only by loads; stores write 0 there.\n");
    fprintf(trace_file,
            "# addr=%s limit=%" PRIu64 " start=%s noio=%s aligned=%s\n",
            use_phys_addr ? "phys" : "virt", limit,
            tracing_enabled ? "on" : "off",
            skip_io ? "on" : "off",
            skip_misaligned ? "on" : "off");

    qemu_plugin_register_vcpu_tb_trans_cb(id, translate_tb_cb);
    qemu_plugin_register_atexit_cb(id, exit_cb, NULL);

    return 0;
}
