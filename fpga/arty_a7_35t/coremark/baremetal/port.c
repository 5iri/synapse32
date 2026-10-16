#include "coremark.h"

#ifndef CPU_CLOCK_HZ
#error Define the actual FPGA CPU clock
#endif
#define UART ((volatile uint32_t *)0x20000000u)
#define MTIME ((volatile uint32_t *)0x0200bff8u)
ee_u32 default_num_contexts = 1;
static uint64_t timer_start, timer_stop, cycles_start, cycles_stop, retired_start, retired_stop;

static uint64_t mtime(void) {
    uint32_t hi, lo, check;
    do { hi=MTIME[1]; lo=MTIME[0]; check=MTIME[1]; } while(hi!=check);
    return ((uint64_t)hi<<32)|lo;
}
static uint64_t cycles(void) {
    uint32_t hi,lo,check;
    do {
        __asm__ volatile("rdcycleh %0; rdcycle %1; rdcycleh %2" : "=r"(hi),"=r"(lo),"=r"(check));
    } while(hi!=check);
    return ((uint64_t)hi<<32)|lo;
}
static uint64_t retired(void) {
    uint32_t hi,lo,check;
    do {
        __asm__ volatile("rdinstreth %0; rdinstret %1; rdinstreth %2" : "=r"(hi),"=r"(lo),"=r"(check));
    } while(hi!=check);
    return ((uint64_t)hi<<32)|lo;
}
void board_uart_putc(char c) {
    if(c=='\n') board_uart_putc('\r');
    while(!(UART[5]&0x20)) {}
    UART[0]=(uint8_t)c;
}
static char uart_getc(void) {
    while(!(UART[5]&1)) {}
    return (char)UART[0];
}
void start_time(void) {
    timer_start=mtime(); cycles_start=cycles(); retired_start=retired();
}
void stop_time(void) {
    retired_stop=retired(); cycles_stop=cycles(); timer_stop=mtime();
}
CORE_TICKS get_time(void) {
    return (CORE_TICKS)((timer_stop-timer_start)/(CPU_CLOCK_HZ/1000));
}
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)ticks/1000.0; }
void portable_init(core_portable *p,int *argc,char *argv[]) {
    (void)argc;(void)argv;
    if(sizeof(ee_ptr_int)!=sizeof(void *) || sizeof(ee_u32)!=4)
        ee_printf("ERROR! Invalid CoreMark platform types\n");
    p->portable_id=1;
}
void portable_fini(core_portable *p) { p->portable_id=0; }
static void print_counter(const char *name,uint64_t value) {
    ee_printf("%s: 0x%08x%08x\n",name,(uint32_t)(value>>32),(uint32_t)value);
}
void board_trap(uint32_t cause,uint32_t pc,uint32_t value) {
    ee_printf("S32_BAREMETAL_TRAP cause=%08x pc=%08x value=%08x\n",cause,pc,value);
    for(;;) __asm__ volatile("wfi");
}
extern int coremark_main(int,char **);
void board_main(void) {
    unsigned divisor=(CPU_CLOCK_HZ+115200*8)/(115200*16);
    UART[3]=0x83;UART[0]=divisor&255;UART[1]=divisor>>8;
    UART[3]=3;UART[1]=0;UART[2]=7;
    uint64_t begin=mtime();
    // Give the host time to switch from loader baud to console baud.
    while(mtime()-begin<CPU_CLOCK_HZ/2) {}
    ee_printf("S32_BAREMETAL_CPU_HZ: %u\n",(unsigned)CPU_CLOCK_HZ);
    ee_printf("M-mode; satp=0; mie=0; mstatus.MIE=0; no OpenSBI or OS\n");
    ee_printf("S32_TIMER_START\n");
    begin=mtime();uint64_t first_cycle=cycles();
    while(mtime()-begin<(uint64_t)CPU_CLOCK_HZ*2) {}
    uint64_t delta=cycles()-first_cycle;
    ee_printf("S32_TIMER_END\n");print_counter("Timer selftest cycles",delta);
    for(;;) {
        char line[24];unsigned n=0;
        ee_printf("S32_BAREMETAL_READY\n");
        for(;;) {
            char c=uart_getc();
            if(c=='\r') continue;
            if(c=='\n') break;
            if(n+1<sizeof(line)) line[n++]=c;
        }
        line[n]=0;
        if(n<3 || (line[0]!='p'&&line[0]!='v') || line[1]!=' ') continue;
        unsigned i=2;
        while(i<n && line[i]>='0' && line[i]<='9') ++i;
        if(i!=n) continue;
        char *seed=line[0]=='v' ? "0x3415" : "0";
        char *argv[]={"coremark",seed,seed,"0x66",line+2,"7","1",0};
        ee_printf("S32_BAREMETAL_RUN: %s\n",line);
        int rc=coremark_main(7,argv);
        print_counter("Timed CPU cycles",cycles_stop-cycles_start);
        print_counter("Timed retired instructions",retired_stop-retired_start);
        ee_printf("S32_BAREMETAL_DONE:%d\n",rc);
    }
}
