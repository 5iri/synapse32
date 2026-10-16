#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *const names[16]={
    "clock","retired","fetch_wait","data_wait","muldiv_wait","fence_wait",
    "icache_hit","icache_miss","dcache_hit","dcache_miss","itlb_miss","dtlb_miss",
    "axi_read_wait","axi_write_wait","store_queue_stall","store_enqueued"
};
static void snapshot(volatile uint32_t *p,uint64_t *dest) {
    for(unsigned i=0;i<16;i++) {
        uint32_t hi,lo,again;
        do {hi=p[5+2*i];lo=p[4+2*i];again=p[5+2*i];} while(hi!=again);
        dest[i]=((uint64_t)hi<<32)|lo;
    }
}
int main(int argc,char **argv) {
    if(argc<2) {fprintf(stderr,"usage: %s COMMAND [ARGS...]\n",argv[0]);return 2;}
    int fd=open("/dev/mem",O_RDONLY|O_SYNC);
    if(fd<0) {perror("open /dev/mem (run as root)");return 1;}
    volatile uint32_t *p=mmap(NULL,4096,PROT_READ,MAP_SHARED,fd,0x20001000);
    close(fd);
    if(p==MAP_FAILED) {perror("mmap profiling registers");return 1;}
    if(p[0]!=0x53333250u || p[1]!=1) {fprintf(stderr,"profiling registers unavailable\n");return 1;}
    uint64_t before[16],after[16];
    snapshot(p,before);
    pid_t child=fork();
    if(child<0) {perror("fork");return 1;}
    if(!child) {execvp(argv[1],argv+1);perror("execvp");_exit(127);}
    int status;
    while(waitpid(child,&status,0)<0) if(errno!=EINTR) {perror("waitpid");return 1;}
    snapshot(p,after);
    puts("S32_PERF_SCOPE: whole CPU during command, including kernel/background activity");
    for(unsigned i=0;i<16;i++) {
        uint64_t value=after[i]-before[i];
        printf("S32_PERF %s: 0x%08x%08x\n",names[i],(unsigned)(value>>32),(unsigned)value);
    }
    munmap((void *)p,4096);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128+WTERMSIG(status);
}
