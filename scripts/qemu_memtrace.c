#define _POSIX_C_SOURCE 200809L

/*
 * Fail-closed QEMU system-emulation memory tracer for the L1D study.
 *
 * This plugin intentionally accepts only QEMU's API 6, riscv64 system
 * emulation, and a single vCPU.  A target process opens and closes its ROI by
 * executing the RISC-V HINT below with the marker ABI in a0..a5:
 *
 *   .word 0x12300013              // addi x0, x0, 0x123
 *   a0 = 0x4c3144524f490002       // "L1DROI", ABI version 2
 *   a1 = run nonce
 *   a2 = 1 (START) or 2 (STOP)
 *   a3 = command index
 *   a4 = PID
 *   a5 = TID
 *
 * START locks vCPU 0, U privilege, and the complete non-Bare SATP value.  The
 * raw schema-v2 rows are deliberately data-redacted and contain enough
 * context to audit attribution:
 *
 *   seq  vcpu  priv  satp  pc  op  size  vaddr  paddr  paddr_end
 *
 * seq is the zero-based demand-memory-event index within the ROI, op is R/W,
 * and size is bytes.  Kernel and foreign-SATP accesses are ignored.  A
 * cross-line event independently translates its final byte so the splitter
 * never assumes physical contiguity.  Missing physical address, IO,
 * unsupported width, failed end translation, malformed marker, or incomplete
 * ROI makes the entire capture INVALID.
 */

#include <qemu-plugin.h>

#include "qemu_memtrace_policy.h"
#include "qemu_memtrace_canonical.h"

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

#define L1D_ROI_MAGIC UINT64_C(0x4c3144524f490002)
#define L1D_ROI_MARKER_WORD UINT32_C(0x12300013)
#define RISCV_PRIV_U UINT64_C(0)
#define RISCV64_SATP_MODE_MASK UINT64_C(0xf000000000000000)
#define MAX_TRACE_WINDOWS 32
#define MAX_WINDOW_LABEL 24

enum roi_event {
    ROI_EVENT_START = 1,
    ROI_EVENT_STOP = 2,
};

enum trace_mode {
    TRACE_MODE_UNSET,
    TRACE_MODE_COUNT,
    TRACE_MODE_CAPTURE,
};

struct trace_window {
    uint64_t start;
    uint64_t count;
    uint64_t warmup;
    uint64_t measure;
    uint64_t captured;
    uint64_t misaligned;
    uint64_t cross_line;
    uint64_t canonical_accesses;
    bool announced;
    char label[MAX_WINDOW_LABEL];
};

struct register_set {
    struct qemu_plugin_register *a[6];
    struct qemu_plugin_register *priv;
    struct qemu_plugin_register *satp;
    const char *a_name[6];
    const char *priv_name;
    const char *satp_name;
    bool ready;
};

static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *trace_file;
static enum trace_mode mode;
static struct register_set regs;
static GByteArray *reg_buf;

static uint64_t expected_nonce;
static uint64_t expected_command;
static uint64_t expected_total;
static bool have_expected_nonce;
static bool have_expected_command;
static bool have_expected_total;

static struct trace_window windows[MAX_TRACE_WINDOWS];
static unsigned int num_windows;

static bool tracing;
static bool start_seen;
static bool stop_seen;
static bool invalid;
static bool summary_written;
static char first_violation[64] = "none";

static uint64_t locked_satp;
static uint64_t locked_pid;
static uint64_t locked_tid;
static uint64_t valid_seen;
static uint64_t captured_rows;
static uint64_t filtered_non_u;
static uint64_t filtered_foreign_satp;
static uint64_t misaligned_events;
static uint64_t cross_line_events;
static uint64_t expanded_replay_accesses;
static uint64_t canonical_replay_accesses;
static uint64_t captured_canonical_replay_accesses;
static uint64_t violations;
static uint64_t register_read_failures;

static const char *trace_mode_name(void)
{
    switch (mode) {
    case TRACE_MODE_COUNT:
        return "count";
    case TRACE_MODE_CAPTURE:
        return "capture";
    default:
        return "unset";
    }
}

static bool add_overflows_u64(uint64_t lhs, uint64_t rhs)
{
    return rhs > UINT64_MAX - lhs;
}

static bool parse_u64(const char *text, uint64_t *value)
{
    char *end = NULL;

    if (text == NULL || text[0] == '\0' || text[0] == '-') {
        return false;
    }
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0') {
        return false;
    }
    *value = (uint64_t)parsed;
    return true;
}

static bool valid_label(const char *label)
{
    if (label == NULL || label[0] == '\0' ||
        strlen(label) >= MAX_WINDOW_LABEL) {
        return false;
    }
    for (const unsigned char *p = (const unsigned char *)label; *p != '\0'; p++) {
        if (!isalnum(*p) && *p != '_' && *p != '-') {
            return false;
        }
    }
    return true;
}

/* windows=start:count:warmup:measure:label;... */
static bool parse_windows(const char *text)
{
    char *copy = strdup(text);
    char *outer_save = NULL;

    if (copy == NULL) {
        return false;
    }

    for (char *entry = strtok_r(copy, ";,", &outer_save);
         entry != NULL;
         entry = strtok_r(NULL, ";,", &outer_save)) {
        char *fields[5] = {0};
        unsigned int n_fields = 0;
        char *inner_save = NULL;

        for (char *field = strtok_r(entry, ":", &inner_save);
             field != NULL;
             field = strtok_r(NULL, ":", &inner_save)) {
            if (n_fields >= 5) {
                free(copy);
                return false;
            }
            fields[n_fields++] = field;
        }

        if (n_fields != 5 || num_windows >= MAX_TRACE_WINDOWS) {
            free(copy);
            return false;
        }

        struct trace_window *window = &windows[num_windows];
        if (!parse_u64(fields[0], &window->start) ||
            !parse_u64(fields[1], &window->count) ||
            !parse_u64(fields[2], &window->warmup) ||
            !parse_u64(fields[3], &window->measure) ||
            !valid_label(fields[4]) || window->count == 0 ||
            add_overflows_u64(window->start, window->count) ||
            add_overflows_u64(window->warmup, window->measure) ||
            window->warmup + window->measure != window->count) {
            free(copy);
            return false;
        }

        if (num_windows > 0) {
            const struct trace_window *previous = &windows[num_windows - 1];
            if (window->start < previous->start + previous->count) {
                free(copy);
                return false;
            }
        }

        snprintf(window->label, sizeof(window->label), "%s", fields[4]);
        num_windows++;
    }

    free(copy);
    return num_windows != 0;
}

static bool register_name_is(const char *name, const char *first,
                             const char *second, const char *third)
{
    return name != NULL &&
           (strcmp(name, first) == 0 ||
            (second != NULL && strcmp(name, second) == 0) ||
            (third != NULL && strcmp(name, third) == 0));
}

static bool read_register_u64(struct qemu_plugin_register *handle,
                              uint64_t *value)
{
    if (handle == NULL || reg_buf == NULL) {
        return false;
    }

    g_byte_array_set_size(reg_buf, 0);
    if (!qemu_plugin_read_register(handle, reg_buf) ||
        reg_buf->len == 0 || reg_buf->len > sizeof(uint64_t)) {
        return false;
    }

    uint64_t decoded = 0;
    for (guint i = 0; i < reg_buf->len; i++) {
        decoded |= (uint64_t)reg_buf->data[i] << (i * 8);
    }
    *value = decoded;
    return true;
}

static void record_violation_locked(const char *code)
{
    invalid = true;
    tracing = false;
    violations++;
    if (strcmp(first_violation, "none") == 0) {
        snprintf(first_violation, sizeof(first_violation), "%s", code);
    }
    if (trace_file != NULL && !summary_written) {
        fprintf(trace_file,
                "# violation code=%s total_events=%" PRIu64 "\n",
                code, valid_seen);
        fflush(trace_file);
    }
}

static bool read_context_registers_locked(uint64_t *priv, uint64_t *satp)
{
    if (!regs.ready || !read_register_u64(regs.priv, priv) ||
        !read_register_u64(regs.satp, satp)) {
        register_read_failures++;
        record_violation_locked("register_read_failed");
        return false;
    }
    return true;
}

static bool read_marker_registers_locked(uint64_t values[6], uint64_t *priv,
                                         uint64_t *satp)
{
    if (!regs.ready) {
        register_read_failures++;
        record_violation_locked("registers_not_ready");
        return false;
    }
    for (unsigned int i = 0; i < 6; i++) {
        if (!read_register_u64(regs.a[i], &values[i])) {
            register_read_failures++;
            record_violation_locked("marker_register_read_failed");
            return false;
        }
    }
    return read_context_registers_locked(priv, satp);
}

static void vcpu_init_cb(qemu_plugin_id_t id, unsigned int vcpu_index)
{
    (void)id;

    pthread_mutex_lock(&state_lock);
    if (vcpu_index != 0) {
        record_violation_locked("unexpected_vcpu_init");
        pthread_mutex_unlock(&state_lock);
        return;
    }

    GArray *descriptors = qemu_plugin_get_registers();
    if (descriptors == NULL) {
        record_violation_locked("register_list_failed");
        pthread_mutex_unlock(&state_lock);
        return;
    }

    for (guint i = 0; i < descriptors->len; i++) {
        qemu_plugin_reg_descriptor *descriptor =
            &g_array_index(descriptors, qemu_plugin_reg_descriptor, i);
        const char *name = descriptor->name;

        for (unsigned int a = 0; a < 6; a++) {
            char x_name[4];
            char a_name[3];
            snprintf(x_name, sizeof(x_name), "x%u", a + 10);
            snprintf(a_name, sizeof(a_name), "a%u", a);
            if (register_name_is(name, a_name, x_name, NULL)) {
                regs.a[a] = descriptor->handle;
                regs.a_name[a] = name;
            }
        }

        if (register_name_is(name, "priv", "privilege", NULL)) {
            regs.priv = descriptor->handle;
            regs.priv_name = name;
        } else if (register_name_is(name, "satp", NULL, NULL)) {
            regs.satp = descriptor->handle;
            regs.satp_name = name;
        }
    }

    regs.ready = regs.priv != NULL && regs.satp != NULL;
    for (unsigned int i = 0; i < 6; i++) {
        regs.ready = regs.ready && regs.a[i] != NULL;
    }

    if (!regs.ready) {
        record_violation_locked("required_register_missing");
        fprintf(stderr,
                "qemu_memtrace: QEMU did not expose a0..a5, priv, and satp\n");
    } else {
        fprintf(trace_file,
                "# registers status=PASS a0=%s a1=%s a2=%s a3=%s a4=%s "
                "a5=%s priv=%s satp=%s\n",
                regs.a_name[0], regs.a_name[1], regs.a_name[2],
                regs.a_name[3], regs.a_name[4], regs.a_name[5],
                regs.priv_name, regs.satp_name);
        fflush(trace_file);
    }

    g_array_free(descriptors, TRUE);
    pthread_mutex_unlock(&state_lock);
}

static void announce_window_locked(unsigned int index)
{
    struct trace_window *window = &windows[index];
    if (window->announced) {
        return;
    }
    window->announced = true;
    fprintf(trace_file,
            "# window index=%u start=%" PRIu64 " count=%" PRIu64
            " warmup=%" PRIu64 " measure=%" PRIu64 " label=%s\n",
            index, window->start, window->count, window->warmup,
            window->measure, window->label);
}

static void write_raw_row_locked(unsigned int vcpu_index,
                                 qemu_plugin_meminfo_t info, uint64_t pc,
                                 uint64_t priv, uint64_t satp, uint64_t vaddr,
                                 uint64_t paddr, uint64_t paddr_end)
{
    unsigned int size_shift = qemu_plugin_mem_size_shift(info);
    char op = qemu_plugin_mem_is_store(info) ? 'W' : 'R';

    fprintf(trace_file,
            "%" PRIu64 "\t%u\t%" PRIu64 "\t0x%016" PRIx64
            "\t0x%016" PRIx64 "\t%c\t%u\t0x%016" PRIx64
            "\t0x%016" PRIx64 "\t0x%016" PRIx64 "\n",
            valid_seen, vcpu_index, priv, satp, pc,
            op, 1u << size_shift, vaddr, paddr, paddr_end);
    captured_rows++;
}

static bool translate_vaddr_for_plan(uint64_t vaddr, uint64_t *paddr,
                                     void *userdata)
{
    (void)userdata;
    return qemu_plugin_translate_vaddr(vaddr, paddr);
}

static void trace_mem_cb(unsigned int vcpu_index, qemu_plugin_meminfo_t info,
                         uint64_t vaddr, void *userdata)
{
    uint64_t pc = (uint64_t)(uintptr_t)userdata;
    uint64_t priv = 0;
    uint64_t satp = 0;

    pthread_mutex_lock(&state_lock);
    if (!tracing) {
        pthread_mutex_unlock(&state_lock);
        return;
    }

    if (!read_context_registers_locked(&priv, &satp)) {
        pthread_mutex_unlock(&state_lock);
        return;
    }
    enum l1d_trace_context_class context =
        l1d_classify_trace_context(vcpu_index, priv, satp, locked_satp);
    if (context == L1D_TRACE_CONTEXT_INVALID_VCPU) {
        record_violation_locked("memory_vcpu_changed");
        pthread_mutex_unlock(&state_lock);
        return;
    }
    if (context == L1D_TRACE_CONTEXT_IGNORE_NON_U) {
        filtered_non_u++;
        pthread_mutex_unlock(&state_lock);
        return;
    }
    if (context == L1D_TRACE_CONTEXT_IGNORE_FOREIGN_SATP) {
        filtered_foreign_satp++;
        pthread_mutex_unlock(&state_lock);
        return;
    }

    unsigned int size_shift = qemu_plugin_mem_size_shift(info);
    if (size_shift > 3) {
        record_violation_locked("unsupported_access_size");
        pthread_mutex_unlock(&state_lock);
        return;
    }

    struct qemu_plugin_hwaddr *haddr = qemu_plugin_get_hwaddr(info, vaddr);
    if (haddr == NULL) {
        record_violation_locked("physical_address_unavailable");
        pthread_mutex_unlock(&state_lock);
        return;
    }
    if (qemu_plugin_hwaddr_is_io(haddr)) {
        record_violation_locked("user_io_access");
        pthread_mutex_unlock(&state_lock);
        return;
    }

    uint64_t paddr = qemu_plugin_hwaddr_phys_addr(haddr);
    struct l1d_touch_plan touch_plan = {0};
    enum l1d_touch_plan_result plan_result = l1d_plan_line_touches(
        vaddr, paddr, size_shift, translate_vaddr_for_plan, NULL, &touch_plan);
    if (plan_result == L1D_TOUCH_PLAN_ADDRESS_OVERFLOW) {
        record_violation_locked("access_address_overflow");
        pthread_mutex_unlock(&state_lock);
        return;
    }
    if (plan_result == L1D_TOUCH_PLAN_TRANSLATION_FAILED) {
        record_violation_locked("cross_line_translation_failed");
        pthread_mutex_unlock(&state_lock);
        return;
    }

    misaligned_events += touch_plan.misaligned ? 1u : 0u;
    cross_line_events += touch_plan.cross_line ? 1u : 0u;
    expanded_replay_accesses += touch_plan.canonical_accesses - 1u;
    canonical_replay_accesses += touch_plan.canonical_accesses;

    if (mode == TRACE_MODE_CAPTURE) {
        for (unsigned int i = 0; i < num_windows; i++) {
            struct trace_window *window = &windows[i];
            if (valid_seen < window->start) {
                break;
            }
            if (valid_seen < window->start + window->count) {
                announce_window_locked(i);
                write_raw_row_locked(vcpu_index, info, pc, priv, satp,
                                     vaddr, paddr, touch_plan.paddr_end);
                window->captured++;
                window->misaligned += touch_plan.misaligned ? 1u : 0u;
                window->cross_line += touch_plan.cross_line ? 1u : 0u;
                window->canonical_accesses += touch_plan.canonical_accesses;
                captured_canonical_replay_accesses +=
                    touch_plan.canonical_accesses;
                break;
            }
        }
    }

    valid_seen++;
    pthread_mutex_unlock(&state_lock);
}

static void marker_cb(unsigned int vcpu_index, void *userdata)
{
    (void)userdata;
    uint64_t marker[6] = {0};
    uint64_t priv = 0;
    uint64_t satp = 0;

    pthread_mutex_lock(&state_lock);
    if (!read_marker_registers_locked(marker, &priv, &satp)) {
        pthread_mutex_unlock(&state_lock);
        return;
    }

    if (vcpu_index != 0) {
        record_violation_locked("marker_wrong_vcpu");
    } else if (marker[0] != L1D_ROI_MAGIC) {
        record_violation_locked("marker_magic_or_version_mismatch");
    } else if (marker[1] != expected_nonce) {
        record_violation_locked("marker_nonce_mismatch");
    } else if (marker[3] != expected_command) {
        record_violation_locked("marker_command_mismatch");
    } else if (marker[4] == 0 || marker[5] == 0) {
        record_violation_locked("marker_pid_tid_invalid");
    } else if (marker[2] == ROI_EVENT_START) {
        if (start_seen || stop_seen) {
            record_violation_locked("duplicate_start");
        } else if (priv != RISCV_PRIV_U) {
            record_violation_locked("start_not_user_mode");
        } else if ((satp & RISCV64_SATP_MODE_MASK) == 0) {
            record_violation_locked("start_bare_satp");
        } else {
            start_seen = true;
            tracing = true;
            locked_satp = satp;
            locked_pid = marker[4];
            locked_tid = marker[5];
            valid_seen = 0;
            captured_rows = 0;
            fprintf(trace_file,
                    "# roi_start nonce=0x%016" PRIx64
                    " command=%" PRIu64 " vcpu=%u priv=%" PRIu64
                    " satp=0x%016" PRIx64 " pid=%" PRIu64
                    " tid=%" PRIu64 "\n",
                    marker[1], marker[3], vcpu_index, priv, satp,
                    marker[4], marker[5]);
            fflush(trace_file);
        }
    } else if (marker[2] == ROI_EVENT_STOP) {
        if (!start_seen) {
            record_violation_locked("stop_before_start");
        } else if (stop_seen) {
            record_violation_locked("duplicate_stop");
        } else if (priv != RISCV_PRIV_U) {
            record_violation_locked("stop_not_user_mode");
        } else if (satp != locked_satp) {
            record_violation_locked("stop_satp_mismatch");
        } else if (marker[4] != locked_pid || marker[5] != locked_tid) {
            record_violation_locked("stop_pid_tid_mismatch");
        } else {
            stop_seen = true;
            tracing = false;
            fprintf(trace_file,
                    "# roi_stop nonce=0x%016" PRIx64
                    " command=%" PRIu64 " vcpu=%u priv=%" PRIu64
                    " satp=0x%016" PRIx64 " pid=%" PRIu64
                    " tid=%" PRIu64 " total_events=%" PRIu64 "\n",
                    marker[1], marker[3], vcpu_index, priv, satp,
                    marker[4], marker[5], valid_seen);
            fflush(trace_file);
        }
    } else {
        record_violation_locked("marker_event_invalid");
    }

    pthread_mutex_unlock(&state_lock);
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
        uint64_t pc = qemu_plugin_insn_vaddr(insn);
        void *userdata = (void *)(uintptr_t)pc;

        if (qemu_plugin_insn_size(insn) == 4) {
            uint8_t bytes[4] = {0};
            if (qemu_plugin_insn_data(insn, bytes, sizeof(bytes)) == 4 &&
                read_le32(bytes) == L1D_ROI_MARKER_WORD) {
                qemu_plugin_register_vcpu_insn_exec_cb(
                    insn, marker_cb, QEMU_PLUGIN_CB_R_REGS, userdata);
            }
        }

        qemu_plugin_register_vcpu_mem_cb(
            insn, trace_mem_cb, QEMU_PLUGIN_CB_R_REGS,
            QEMU_PLUGIN_MEM_RW, userdata);
    }
}

static void validate_final_locked(void)
{
    if (!regs.ready) {
        record_violation_locked("required_register_missing_at_exit");
    }
    if (!start_seen) {
        record_violation_locked("missing_start");
    }
    if (!stop_seen) {
        record_violation_locked("missing_stop");
    }
    if (expanded_replay_accesses != cross_line_events ||
        canonical_replay_accesses != valid_seen + expanded_replay_accesses ||
        cross_line_events > misaligned_events) {
        record_violation_locked("canonicalization_conservation_failed");
    }
    if (mode == TRACE_MODE_CAPTURE) {
        if (!have_expected_total || valid_seen != expected_total) {
            record_violation_locked("count_capture_total_mismatch");
        }
        for (unsigned int i = 0; i < num_windows; i++) {
            if (windows[i].captured != windows[i].count) {
                record_violation_locked("capture_window_incomplete");
            }
            if (windows[i].canonical_accesses !=
                    windows[i].captured + windows[i].cross_line ||
                windows[i].cross_line > windows[i].misaligned) {
                record_violation_locked("window_canonicalization_failed");
            }
        }
    }
}

static void write_summary_locked(const char *reason)
{
    if (trace_file == NULL || summary_written) {
        return;
    }

    validate_final_locked();
    fprintf(trace_file,
            "# summary status=%s reason=%s mode=%s total_events=%" PRIu64
            " captured_rows=%" PRIu64 " expected_total=%" PRIu64
            " count_matches_capture=%u start_seen=%u stop_seen=%u"
            " vcpu=0 priv=0 satp=0x%016" PRIx64
            " pid=%" PRIu64 " tid=%" PRIu64
            " command=%" PRIu64 " nonce=0x%016" PRIx64
            " filtered_non_u=%" PRIu64
            " filtered_foreign_satp=%" PRIu64
            " misaligned_events=%" PRIu64
            " cross_line_events=%" PRIu64
            " expanded_replay_accesses=%" PRIu64
            " canonical_replay_accesses=%" PRIu64
            " captured_canonical_replay_accesses=%" PRIu64
            " register_read_failures=%" PRIu64
            " violations=%" PRIu64 " first_violation=%s\n",
            invalid ? "INVALID" : "PASS", reason, trace_mode_name(),
            valid_seen, captured_rows,
            have_expected_total ? expected_total : valid_seen,
            (!have_expected_total || expected_total == valid_seen) ? 1u : 0u,
            start_seen ? 1u : 0u, stop_seen ? 1u : 0u,
            locked_satp, locked_pid, locked_tid, expected_command,
            expected_nonce, filtered_non_u, filtered_foreign_satp,
            misaligned_events, cross_line_events,
            expanded_replay_accesses, canonical_replay_accesses,
            captured_canonical_replay_accesses,
            register_read_failures,
            violations, first_violation);

    for (unsigned int i = 0; i < num_windows; i++) {
        fprintf(trace_file,
                "# window_summary index=%u start=%" PRIu64
                " count=%" PRIu64 " warmup=%" PRIu64
                " measure=%" PRIu64 " label=%s captured=%" PRIu64
                " misaligned=%" PRIu64 " cross_line=%" PRIu64
                " canonical_accesses=%" PRIu64
                " status=%s\n",
                i, windows[i].start, windows[i].count,
                windows[i].warmup, windows[i].measure, windows[i].label,
                windows[i].captured, windows[i].misaligned,
                windows[i].cross_line, windows[i].canonical_accesses,
                windows[i].captured == windows[i].count ? "PASS" : "INVALID");
    }

    fflush(trace_file);
    summary_written = true;
    fclose(trace_file);
    trace_file = NULL;
}

static void exit_cb(qemu_plugin_id_t id, void *userdata)
{
    (void)id;
    (void)userdata;

    pthread_mutex_lock(&state_lock);
    write_summary_locked("qemu_exit");
    pthread_mutex_unlock(&state_lock);

    if (reg_buf != NULL) {
        g_byte_array_free(reg_buf, TRUE);
        reg_buf = NULL;
    }
}

static int install_error(const char *message)
{
    fprintf(stderr, "qemu_memtrace: %s\n", message);
    return 1;
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const qemu_info_t *info,
                                           int argc, char **argv)
{
    const char *out_path = NULL;

    if (QEMU_PLUGIN_VERSION != 6 || info->version.cur != 6) {
        return install_error("requires QEMU Plugin API 6 exactly");
    }
    if (!info->system_emulation) {
        return install_error("requires system emulation");
    }
    if (strcmp(info->target_name, "riscv64") != 0) {
        return install_error("requires the riscv64 target");
    }
    if (info->system.smp_vcpus != 1 || info->system.max_vcpus != 1) {
        return install_error("requires -smp 1,maxcpus=1");
    }

    for (int i = 0; i < argc; i++) {
        char *equals = strchr(argv[i], '=');
        if (equals == NULL) {
            return install_error("every plugin argument must be key=value");
        }
        *equals = '\0';
        const char *key = argv[i];
        const char *value = equals + 1;

        if (strcmp(key, "out") == 0) {
            out_path = value;
        } else if (strcmp(key, "mode") == 0) {
            if (strcmp(value, "count") == 0) {
                mode = TRACE_MODE_COUNT;
            } else if (strcmp(value, "capture") == 0) {
                mode = TRACE_MODE_CAPTURE;
            } else {
                return install_error("mode must be count or capture");
            }
        } else if (strcmp(key, "nonce") == 0) {
            if (!parse_u64(value, &expected_nonce)) {
                return install_error("invalid nonce");
            }
            have_expected_nonce = true;
        } else if (strcmp(key, "command") == 0) {
            if (!parse_u64(value, &expected_command)) {
                return install_error("invalid command index");
            }
            have_expected_command = true;
        } else if (strcmp(key, "expected_total") == 0) {
            if (!parse_u64(value, &expected_total)) {
                return install_error("invalid expected_total");
            }
            have_expected_total = true;
        } else if (strcmp(key, "windows") == 0) {
            if (!parse_windows(value)) {
                return install_error(
                    "windows must be sorted start:count:warmup:measure:label entries");
            }
        } else {
            return install_error("unknown plugin argument");
        }
    }

    if (out_path == NULL || out_path[0] == '\0') {
        return install_error("out is required");
    }
    if (mode == TRACE_MODE_UNSET) {
        return install_error("mode is required");
    }
    if (!have_expected_nonce || expected_nonce == 0) {
        return install_error("a non-zero nonce is required");
    }
    if (!have_expected_command) {
        return install_error("command is required");
    }
    if (mode == TRACE_MODE_COUNT && num_windows != 0) {
        return install_error("count mode must not have windows");
    }
    if (mode == TRACE_MODE_CAPTURE &&
        (!have_expected_total || num_windows == 0)) {
        return install_error("capture mode requires expected_total and windows");
    }

    trace_file = fopen(out_path, "w");
    if (trace_file == NULL) {
        perror("qemu_memtrace: fopen");
        return 1;
    }
    setvbuf(trace_file, NULL, _IOFBF, 1 << 20);
    reg_buf = g_byte_array_sized_new(sizeof(uint64_t));
    if (reg_buf == NULL) {
        fclose(trace_file);
        trace_file = NULL;
        return install_error("failed to allocate register buffer");
    }

    fprintf(trace_file, "# L1D_QEMU_MEMTRACE schema=3\n");
    fprintf(trace_file,
            "# columns seq vcpu priv satp pc op size vaddr paddr paddr_end\n");
    fprintf(trace_file,
            "# data_policy addresses=licensed-private store_data=redacted\n");
    fprintf(trace_file,
            "# context target=%s plugin_api=%d system_emulation=1 smp_vcpus=%d"
            " max_vcpus=%d mode=%s expected_nonce=0x%016" PRIx64
            " command=%" PRIu64 " expected_total=%" PRIu64 "\n",
            info->target_name, info->version.cur, info->system.smp_vcpus,
            info->system.max_vcpus, trace_mode_name(), expected_nonce,
            expected_command, have_expected_total ? expected_total : 0);
    for (unsigned int i = 0; i < num_windows; i++) {
        fprintf(trace_file,
                "# window_config index=%u start=%" PRIu64
                " count=%" PRIu64 " warmup=%" PRIu64
                " measure=%" PRIu64 " label=%s\n",
                i, windows[i].start, windows[i].count,
                windows[i].warmup, windows[i].measure, windows[i].label);
    }
    fflush(trace_file);

    qemu_plugin_register_vcpu_init_cb(id, vcpu_init_cb);
    qemu_plugin_register_vcpu_tb_trans_cb(id, translate_tb_cb);
    qemu_plugin_register_atexit_cb(id, exit_cb, NULL);
    return 0;
}
