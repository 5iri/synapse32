/* Driver-level RV32 test: real OpenSBI FDT/regmap/reset/SRST code, RAM MMIO. */
#include <sbi/sbi_domain.h>
#include <sbi/sbi_ecall.h>
#include <sbi/sbi_ecall_interface.h>
#include <sbi/sbi_error.h>
#include <sbi/sbi_heap.h>
#include <sbi/sbi_system.h>
#include <sbi/sbi_trap.h>
#include <sbi_utils/fdt/fdt_helper.h>
#include <sbi_utils/regmap/fdt_regmap.h>
#include <sbi_utils/reset/fdt_reset.h>
#include <libfdt.h>

/* Keep firmware types and libc headers separate; RV32 call widths agree. */
extern int printf(const char *, ...);
extern int vprintf(const char *, __builtin_va_list);
extern void exit(int) __attribute__((noreturn));
extern void *calloc(size_t, size_t);
extern void free(void *);
extern void *fopen(const char *, const char *);
extern size_t fread(void *, size_t, size_t, void *);
extern int fclose(void *);
extern void *mmap(void *, size_t, int, int, int, long long);

#define CHECK(condition) do { if (!(condition)) { \
    printf("FAIL reset firmware line %d: %s\n", __LINE__, #condition); exit(1); \
} } while (0)
#define RESET_BASE 0x20002000UL
#define RESET_KEY 0x53333252U

struct sbi_domain root;
static unsigned long shared_base, shared_size, shared_flags;
static unsigned long jump_buffer[5];
static unsigned int extension_registrations, reset_calls;
static volatile unsigned int *reset_register;
extern struct fdt_reset fdt_syscon_reboot;
extern struct fdt_regmap fdt_regmap_syscon;
extern struct sbi_ecall_extension ecall_srst;
struct fdt_reset *fdt_reset_drivers[] = { &fdt_syscon_reboot };
unsigned long fdt_reset_drivers_size = 1;
struct fdt_regmap *fdt_regmap_drivers[] = { &fdt_regmap_syscon };
unsigned long fdt_regmap_drivers_size = 1;

void *sbi_zalloc(size_t size) { return calloc(1, size); }
void sbi_free(void *pointer) { free(pointer); }
int sbi_printf(const char *format, ...)
{
    int result;
    __builtin_va_list arguments;
    __builtin_va_start(arguments, format);
    result = vprintf(format, arguments);
    __builtin_va_end(arguments);
    return result;
}
int sbi_domain_root_add_memrange(unsigned long address, unsigned long size,
                               unsigned long alignment, unsigned long flags)
{
    CHECK(alignment == 4096);
    shared_base = address; shared_size = size; shared_flags = flags;
    return 0;
}
int sbi_ecall_register_extension(struct sbi_ecall_extension *extension)
{
    CHECK(extension == &ecall_srst);
    CHECK(extension->extid_start == SBI_EXT_SRST);
    ++extension_registrations;
    return 0;
}
void __attribute__((noreturn)) sbi_hart_hang(void)
{
    __builtin_longjmp(jump_buffer, 1);
}
/* Reuse the actual registry/support selection; park/IPI reset glue is unused. */
#define sbi_system_reset unused_privileged_system_reset
#include "lib/sbi/sbi_system.c"
#undef sbi_system_reset
void __attribute__((noreturn)) sbi_system_reset(u32 type, u32 reason)
{
    const struct sbi_system_reset_device *device =
        sbi_system_reset_get_device(type, reason);
    CHECK(device != NULL);
    ++reset_calls;
    device->system_reset(type, reason);
    CHECK(0);
    exit(1);
}

int main(int argc, char **argv)
{
    void *file, *fdt;
    struct sbi_trap_regs registers = {0};
    struct sbi_ecall_return result = {0};
    unsigned int expected, type;
    CHECK(argc == 3);
    expected = argv[2][0] == '1';
    fdt = calloc(1, 65536);
    CHECK(fdt != NULL);
    file = fopen(argv[1], "rb"); CHECK(file != NULL);
    CHECK(fread(fdt, 1, 65536, file) > 0); fclose(file);
    CHECK(fdt_check_header(fdt) == 0);
    root.next_arg1 = (unsigned long)fdt;
    root.system_reset_allowed = true; /* Permission alone must not advertise SRST. */
    CHECK(ecall_srst.register_extensions() == 0);
    CHECK(extension_registrations == 0);
    fdt_reset_init();
    CHECK(sbi_system_reset_supported(SBI_SRST_RESET_TYPE_COLD_REBOOT, 0) == expected);
    CHECK(sbi_system_reset_supported(SBI_SRST_RESET_TYPE_WARM_REBOOT, 0) == expected);
    CHECK(!sbi_system_reset_supported(SBI_SRST_RESET_TYPE_SHUTDOWN, 0));
    CHECK(ecall_srst.register_extensions() == 0);
    CHECK(extension_registrations == expected);
    if (!expected) {
        printf("PASS: DT without reset device does not advertise SRST\n");
        return 0;
    }
    CHECK(shared_base == RESET_BASE && shared_size == 4);
    CHECK(shared_flags & SBI_DOMAIN_MEMREGION_MMIO);
    CHECK((shared_flags & SBI_DOMAIN_MEMREGION_SHARED_SURW_MRW) ==
          SBI_DOMAIN_MEMREGION_SHARED_SURW_MRW);
    /* Anonymous fixed RAM stands in for the real full-word MMIO register. */
    CHECK(mmap((void *)RESET_BASE, 4096, 3, 0x32, -1, 0LL) == (void *)RESET_BASE);
    reset_register = (volatile unsigned int *)RESET_BASE;
    for (type = SBI_SRST_RESET_TYPE_COLD_REBOOT;
         type <= SBI_SRST_RESET_TYPE_WARM_REBOOT; ++type) {
        *reset_register = type == SBI_SRST_RESET_TYPE_COLD_REBOOT ? 0 : 0xa5a5a5a5;
        registers.a0 = type; registers.a1 = SBI_SRST_RESET_REASON_NONE;
        if (__builtin_setjmp(jump_buffer) == 0) {
            ecall_srst.handle(SBI_EXT_SRST, SBI_EXT_SRST_RESET, &registers, &result);
            CHECK(0);
        }
        CHECK(*reset_register == RESET_KEY);
    }
    CHECK(reset_calls == 2);
    registers.a0 = SBI_SRST_RESET_TYPE_SHUTDOWN;
    CHECK(ecall_srst.handle(SBI_EXT_SRST, SBI_EXT_SRST_RESET,
                           &registers, &result) == SBI_ENOTSUPP);
    CHECK(reset_calls == 2);
    printf("PASS: actual OpenSBI driver registers cold/warm SRST; offset0 full32 key0x53333252; shutdown unsupported\n");
    return 0;
}
