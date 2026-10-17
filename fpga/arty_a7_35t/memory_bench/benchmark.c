// Reuse the existing board UART, trap ABI and coherent RV32 counter readers.
// Its unused CoreMark entry point is discarded by --gc-sections.
#define board_main unused_coremark_board_main
#define board_trap unused_coremark_board_trap
#include "base_port.c"
#undef board_main
#undef board_trap

#define OPERATIONS 65536u
#define UNROLL 16u
#define BLOCKS (OPERATIONS/UNROLL)
#define HOT_WORDS 128u
#define COLD_WORDS 16384u
#define PERF ((volatile uint32_t *)0x20001000u)

// Keep snapshot storage and both hot buffers at distinct D-cache offsets.
// Together they occupy <1.5 KiB; the stack uses the top of RAM.
static struct {
    uint64_t before[16], after[16];
    volatile uint32_t ring[HOT_WORDS], stores[HOT_WORDS];
    volatile uint32_t warm_sink;
} hot __attribute__((aligned(4096)));
static volatile uint32_t cold[COLD_WORDS] __attribute__((aligned(4096)));
static const char *const perf_names[16]={
    "clock","retired","fetch_wait","data_wait","muldiv_wait","fence_wait",
    "icache_hit","icache_miss","dcache_hit","dcache_miss","itlb_miss","dtlb_miss",
    "axi_read_wait","axi_write_wait","store_queue_stall","store_enqueued"
};
static void fence_stores(void) { __asm__ volatile("fence rw,rw" ::: "memory"); }
static void snapshot(uint64_t *dest) {
    for(unsigned i=0;i<16;i++) {
        uint32_t hi,lo,again;
        do { hi=PERF[5+2*i];lo=PERF[4+2*i];again=PERF[5+2*i]; } while(hi!=again);
        dest[i]=((uint64_t)hi<<32)|lo;
    }
}
static void print_u64(uint64_t value) {
    char digits[20];unsigned n=0;
    do { digits[n++]=(char)('0'+value%10);value/=10; } while(value);
    while(n) board_uart_putc(digits[--n]);
}
static uint32_t initial_word(unsigned i) { return 0x10203040u^i; }
static uint32_t cold_word(unsigned i) { return 0x12345678u+i*0x9e3779b9u; }
static void prepare_ring(void) {
    for(unsigned i=0;i<HOT_WORDS;i++)
        hot.ring[i]=(uint32_t)(uintptr_t)&hot.ring[(i+17)%HOT_WORDS];
    fence_stores();
    uintptr_t p=(uintptr_t)&hot.ring[0];
    for(unsigned i=0;i<HOT_WORDS;i++) p=*(volatile uint32_t *)p;
    hot.warm_sink=(uint32_t)p;
    fence_stores();
}
static void prepare_stores(void) {
    for(unsigned i=0;i<HOT_WORDS;i++) hot.stores[i]=initial_word(i);
    fence_stores();
    uint32_t sum=0;
    for(unsigned i=0;i<HOT_WORDS;i++) sum+=hot.stores[i];
    hot.warm_sink=sum;
    fence_stores();
}
static uint32_t prepare_cold(void) {
    for(unsigned i=0;i<COLD_WORDS;i++) cold[i]=cold_word(i);
    fence_stores();
    uint32_t expected=0;
    for(unsigned i=0;i<COLD_WORDS;i+=4) expected+=cold_word(i);
    return expected*(OPERATIONS/(COLD_WORDS/4));
}

__attribute__((noinline)) static uint32_t register_baseline(void) {
    uint32_t sum=0x2468ace0u;
    for(unsigned block=0;block<BLOCKS;block++)
        __asm__ volatile(".rept 16\n\taddi %[sum],%[sum],1\n\t.endr"
                         : [sum] "+r"(sum));
    return sum;
}
__attribute__((noinline)) static uint32_t dependent_loads(void) {
    uintptr_t p=(uintptr_t)&hot.ring[0];
    for(unsigned block=0;block<BLOCKS;block++)
        __asm__ volatile(".rept 16\n\tlw %[p],0(%[p])\n\t.endr"
                         : [p] "+r"(p) :: "memory");
    return p==(uintptr_t)&hot.ring[0] ? 0 : UINT32_MAX;
}
__attribute__((noinline)) static uint32_t independent_loads(void) {
    uintptr_t a=(uintptr_t)&hot.ring[0],b=(uintptr_t)&hot.ring[32];
    uintptr_t c=(uintptr_t)&hot.ring[64],d=(uintptr_t)&hot.ring[96];
    for(unsigned block=0;block<BLOCKS;block++)
        __asm__ volatile(".rept 4\n\tlw %[a],0(%[a])\n\tlw %[b],0(%[b])\n\t"
                         "lw %[c],0(%[c])\n\tlw %[d],0(%[d])\n\t.endr"
                         : [a] "+r"(a),[b] "+r"(b),[c] "+r"(c),[d] "+r"(d) :: "memory");
    return a==(uintptr_t)&hot.ring[0] && b==(uintptr_t)&hot.ring[32] &&
           c==(uintptr_t)&hot.ring[64] && d==(uintptr_t)&hot.ring[96] ? 192 : UINT32_MAX;
}
__attribute__((noinline)) static uint32_t stores_same_word(void) {
    for(unsigned block=0;block<BLOCKS;block++)
        __asm__ volatile(".rept 16\n\tsw %[v],0(%[p])\n\t.endr"
                         :: [v] "r"(0x13579bdfu),[p] "r"(&hot.stores[0]) : "memory");
    return 0;
}
__attribute__((noinline)) static uint32_t stores_adjacent_words(void) {
    for(unsigned block=0;block<BLOCKS;block++)
        __asm__ volatile(".rept 4\n\tsw %[a],0(%[p])\n\tsw %[b],4(%[p])\n\t"
                         "sw %[c],8(%[p])\n\tsw %[d],12(%[p])\n\t.endr"
                         :: [a] "r"(0x11111111u),[b] "r"(0x22222222u),
                            [c] "r"(0x33333333u),[d] "r"(0x44444444u),
                            [p] "r"(&hot.stores[0]) : "memory");
    return 0;
}
#define STORE_WORD(offset) "sw %[v]," #offset "(%[p])\n\t"
__attribute__((noinline)) static uint32_t stores_streaming_hot(void) {
    volatile uint32_t *p=hot.stores;
    for(unsigned block=0;block<BLOCKS;block++) {
        __asm__ volatile(STORE_WORD(0) STORE_WORD(4) STORE_WORD(8) STORE_WORD(12)
                         STORE_WORD(16) STORE_WORD(20) STORE_WORD(24) STORE_WORD(28)
                         STORE_WORD(32) STORE_WORD(36) STORE_WORD(40) STORE_WORD(44)
                         STORE_WORD(48) STORE_WORD(52) STORE_WORD(56) STORE_WORD(60)
                         :: [v] "r"(0x55aa33ccu),[p] "r"(p) : "memory");
        p+=UNROLL;
        if(p==hot.stores+HOT_WORDS) p=hot.stores;
    }
    return 0;
}
__attribute__((noinline)) static uint32_t stores_sparse(void) {
    uint32_t gap=0;
    for(unsigned block=0;block<OPERATIONS/4;block++)
        __asm__ volatile(".rept 4\n\tsw %[v],0(%[p])\n\t"
                         ".rept 32\n\taddi %[gap],%[gap],1\n\t.endr\n\t.endr"
                         : [gap] "+&r"(gap)
                         : [v] "r"(0x87654321u),[p] "r"(&hot.stores[0]) : "memory");
    return gap;
}
#define COLD_LOAD(offset) "lw %[tmp]," #offset "(%[p])\n\tadd %[sum],%[sum],%[tmp]\n\t"
__attribute__((noinline)) static uint32_t loads_streaming_cold(void) {
    volatile uint32_t *p=cold;uint32_t sum=0,tmp;
    for(unsigned block=0;block<BLOCKS;block++) {
        __asm__ volatile(COLD_LOAD(0) COLD_LOAD(16) COLD_LOAD(32) COLD_LOAD(48)
                         COLD_LOAD(64) COLD_LOAD(80) COLD_LOAD(96) COLD_LOAD(112)
                         COLD_LOAD(128) COLD_LOAD(144) COLD_LOAD(160) COLD_LOAD(176)
                         COLD_LOAD(192) COLD_LOAD(208) COLD_LOAD(224) COLD_LOAD(240)
                         : [sum] "+&r"(sum),[tmp] "=&r"(tmp) : [p] "r"(p) : "memory");
        p+=4*UNROLL;
        if(p==cold+COLD_WORDS) p=cold;
    }
    return sum;
}
static uint32_t verify_stores(unsigned which,int *valid) {
    uint32_t checksum=0;
    for(unsigned i=0;i<HOT_WORDS;i++) {
        uint32_t expected=initial_word(i),actual=hot.stores[i];
        if(which==3 && i==0) expected=0x13579bdfu;
        if(which==4 && i<4) expected=0x11111111u*(i+1);
        if(which==5) expected=0x55aa33ccu;
        if(which==6 && i==0) expected=0x87654321u;
        if(actual!=expected) *valid=0;
        checksum+=actual;
    }
    return checksum;
}
struct test_case {
    const char *name;
    uint32_t (*run)(void);
    unsigned working_set_bytes;
    int final_fence;
    unsigned unroll;
};
static const struct test_case cases[]={
    {"register_baseline",register_baseline,0,0,16},
    {"dependent_loads",dependent_loads,sizeof(hot.ring),0,16},
    {"independent_loads",independent_loads,sizeof(hot.ring),0,16},
    {"stores_same_word",stores_same_word,4,1,16},
    {"stores_adjacent_words",stores_adjacent_words,16,1,16},
    {"stores_streaming_hot",stores_streaming_hot,sizeof(hot.stores),1,16},
    {"stores_sparse",stores_sparse,4,1,4},
    {"loads_streaming_cold",loads_streaming_cold,sizeof(cold),0,16}
};
static int run_all(void) {
    int all_valid=1;
    for(unsigned which=0;which<sizeof(cases)/sizeof(cases[0]);which++) {
        const struct test_case *test=&cases[which];
        uint32_t expected=0;
        if(which==0) expected=0x2468ace0u+OPERATIONS;
        if(which==1||which==2) { prepare_ring();expected=which==1?0:192; }
        if(which>=3&&which<=6) prepare_stores();
        if(which==7) expected=prepare_cold();
        snapshot(hot.before);
        __asm__ volatile("" ::: "memory");
        uint64_t first_cycle=cycles(),first_retired=retired();
        uint32_t checksum=test->run();
        if(test->final_fence) fence_stores();
        __asm__ volatile("" ::: "memory");
        uint64_t last_retired=retired(),last_cycle=cycles();
        snapshot(hot.after);
        int valid=which>=3&&which<=6 ? 1 : checksum==expected;
        if(which==6 && checksum!=OPERATIONS*32) valid=0;
        if(which>=3&&which<=6) checksum=verify_stores(which,&valid);
        all_valid&=valid;
        ee_printf("S32_MEMORY_BENCH {\"case\":\"%s\",\"cycles\":",test->name);
        print_u64(last_cycle-first_cycle);
        ee_printf(",\"instructions\":");print_u64(last_retired-first_retired);
        ee_printf(",\"operations\":%u,\"checksum\":%u,\"working_set_bytes\":%u,"
                  "\"unroll\":%u,\"final_fence\":%s,\"validated\":%s,\"profiling\":{",
                  OPERATIONS,checksum,test->working_set_bytes,test->unroll,
                  test->final_fence?"true":"false",valid?"true":"false");
        for(unsigned i=0;i<16;i++) {
            ee_printf("%s\"%s\":",i?",":"",perf_names[i]);
            print_u64(hot.after[i]-hot.before[i]);
        }
        ee_printf("}}\n");
    }
    return all_valid;
}
void board_trap(uint32_t cause,uint32_t pc,uint32_t value) {
    ee_printf("S32_MEMORY_BENCH_TRAP cause=%08x pc=%08x value=%08x\n",cause,pc,value);
    for(;;) __asm__ volatile("wfi");
}
void board_main(void) {
    unsigned divisor=(CPU_CLOCK_HZ+UART_BAUD*UART_DIVISOR_SCALE/2)/(UART_BAUD*UART_DIVISOR_SCALE);
    UART[3]=0x83;UART[0]=divisor&255;UART[1]=divisor>>8;
    UART[3]=3;UART[1]=0;UART[2]=7;
    uint64_t begin=mtime();
    while(mtime()-begin<CPU_CLOCK_HZ/10) {}
    ee_printf("S32_MEMORY_BENCH_CPU_HZ:%u\n",(unsigned)CPU_CLOCK_HZ);
    if(PERF[0]!=0x53333250u||PERF[1]!=1) {
        ee_printf("ERROR profiling registers unavailable\n");
        for(;;) __asm__ volatile("wfi");
    }
    for(;;) {
        ee_printf("S32_MEMORY_BENCH_READY\n");
        char first=uart_getc(),next;
        do { next=uart_getc(); } while(next!='\n');
        if(first=='r') ee_printf("S32_MEMORY_BENCH_DONE:%d\n",run_all()?0:1);
    }
}
