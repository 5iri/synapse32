// Optional board-local profiling overlay; timed EEMBC algorithms are unchanged.
// build_profile.sh supplies the generic bare-metal port as base_port.c.
#define start_time base_start_time
#define stop_time base_stop_time
#define coremark_main profile_coremark_main
#include "base_port.c"
#undef start_time
#undef stop_time
#undef coremark_main

#define PERF ((volatile uint32_t *)0x20001000u)
static uint64_t perf_start[16], perf_stop[16];
static const char *const perf_names[16] = {
    "clock", "retired", "fetch_wait", "data_wait", "muldiv_wait", "fence_wait",
    "icache_hit", "icache_miss", "dcache_hit", "dcache_miss",
    "itlb_miss", "dtlb_miss", "axi_read_wait", "axi_write_wait",
    "store_queue_stall", "store_enqueued"
};
static void snapshot(uint64_t *dest) {
    for(unsigned i=0;i<16;i++) {
        uint32_t hi,lo,again;
        do {
            hi=PERF[5+2*i];lo=PERF[4+2*i];again=PERF[5+2*i];
        } while(hi!=again);
        dest[i]=((uint64_t)hi<<32)|lo;
    }
}
void start_time(void) { snapshot(perf_start);base_start_time(); }
void stop_time(void) { base_stop_time();snapshot(perf_stop); }
extern int coremark_main(int,char **);
int profile_coremark_main(int argc,char **argv) {
    if(PERF[0]!=0x53333250u || PERF[1]!=1) {
        ee_printf("ERROR! FPGA profiling registers unavailable\n");
        return 1;
    }
    int rc=coremark_main(argc,argv);
    for(unsigned i=0;i<16;i++) {
        uint64_t delta=perf_stop[i]-perf_start[i];
        ee_printf("S32_PERF %s: 0x%08x%08x\n",perf_names[i],
                  (uint32_t)(delta>>32),(uint32_t)delta);
    }
    return rc;
}
