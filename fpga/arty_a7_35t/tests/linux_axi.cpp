// Boot the real FPGA SoC with a byte-accurate AXI RAM and physical UART output.
// Preloading RAM and pulsing load_finish replaces only the host upload step.
#include "Vsynapse_ddr3_system.h"
#include "Vsynapse_ddr3_system___024root.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc,argv);
    if(argc<2) {std::cerr<<"usage: Vsynapse_ddr3_system fw_payload.bin [cycles]\n";return 2;}
    std::ifstream image(argv[1],std::ios::binary);
    if(!image) {std::cerr<<"Cannot open payload\n";return 2;}
    std::vector<uint8_t> memory(65*1024*1024);
    std::vector<uint8_t> payload((std::istreambuf_iterator<char>(image)),{});
    if(payload.empty()||payload.size()>64*1024*1024) return 2;
    std::copy(payload.begin(),payload.end(),memory.begin());
    Vsynapse_ddr3_system d;
    d.rst=1;d.calibrated=1;d.uart_rx=1;d.load_req=0;d.load_finish=0;
    d.load_addr=0;d.load_data=0;d.rlast=1;d.rresp=0;d.bresp=0;d.rvalid=0;d.bvalid=0;
    bool have_aw=false,have_w=false;
    uint32_t aw=0;std::array<uint32_t,4> w{};uint16_t strobe=0;
    int uart_wait=0,uart_bit=-1;unsigned uart_byte=0;bool previous_tx=true;
    std::string transcript;
    bool shell_seen=false;
    const std::string input="echo FPGA_BOOT_OK\n";
    size_t input_char=0;int input_bit=0,input_ticks=0;
    const uint64_t limit=argc>2 ? std::stoull(argv[2]) : 2000000000ULL;
    for(uint64_t cycle=0;cycle<limit&&!Verilated::gotFinish();++cycle) {
        d.rst=cycle<10;d.load_finish=cycle==12;
        if(shell_seen&&input_char<input.size()) {
            d.uart_rx=input_bit==0 ? 0 : input_bit==9 ? 1 :
                (uint8_t(input[input_char])>>(input_bit-1))&1;
            if(++input_ticks==432) {
                input_ticks=0;
                if(++input_bit==10){input_bit=0;++input_char;}
            }
        } else d.uart_rx=1;
        d.clk=0;d.arready=!d.rvalid;d.awready=!have_aw&&!d.bvalid;d.wready=!have_w&&!d.bvalid;
        d.eval();
        bool ar=d.arvalid&&d.arready,rc=d.rvalid&&d.rready;
        bool wa=d.awvalid&&d.awready,wd=d.wvalid&&d.wready,bc=d.bvalid&&d.bready;
        uint32_t address=d.axi_addr;
        std::array<uint32_t,4> new_w{};for(int i=0;i<4;i++)new_w[i]=d.wdata[i];
        uint16_t new_strobe=d.wstrb;
        d.clk=1;d.eval();
        if(rc)d.rvalid=0;
        if(bc){d.bvalid=0;have_aw=false;have_w=false;}
        if(ar){
            if(address+16>memory.size()) {std::cerr<<"AXI read out of range\n";return 1;}
            for(int i=0;i<4;i++)std::memcpy(&d.rdata[i],&memory[address+4*i],4);
            d.rvalid=1;
        }
        if(wa){aw=address;have_aw=true;}
        if(wd){w=new_w;strobe=new_strobe;have_w=true;}
        if(have_aw&&have_w&&!d.bvalid){
            if(aw+16>memory.size()) {std::cerr<<"AXI write out of range\n";return 1;}
            for(int i=0;i<16;i++)if(strobe&(1<<i))memory[aw+i]=(w[i/4]>>(8*(i%4)))&255;
            d.bvalid=1;
        }
        if(d.fault){std::cerr<<"Fabric fault at PC "<<std::hex<<d.pc_debug
            <<" physical address "<<d.rootp->synapse_ddr3_system__DOT__select_addr<<"\n";return 1;}
        bool tx=d.uart_tx;
        if(uart_bit<0){
            if(previous_tx&&!tx){uart_wait=432+216;uart_bit=0;uart_byte=0;}
        }else if(--uart_wait==0){
            if(uart_bit<8){uart_byte|=unsigned(tx)<<uart_bit++;uart_wait=432;}
            else {
                if(!tx){std::cerr<<"UART framing error\n";return 1;}
                char ch=char(uart_byte);std::cout<<ch<<std::flush;transcript+=ch;uart_bit=-1;
                if(!shell_seen&&transcript.size()>=3&&transcript.compare(transcript.size()-3,3," # ")==0) shell_seen=true;
                if(shell_seen&&transcript.find("\nFPGA_BOOT_OK\r\n")!=std::string::npos) {
                    std::cerr<<"\nPASS: Linux BusyBox shell executed a UART command through FPGA AXI/Sv32/PLIC fabric in "<<cycle<<" cycles\n";return 0;
                }
            }
        }
        previous_tx=tx;
        if(cycle&&cycle%50000000==0) std::cerr<<"\ncycles="<<cycle<<" PC="<<std::hex<<d.pc_debug<<std::dec<<"\n";
    }
    std::cerr<<"\nLinux boot timeout PC="<<std::hex<<d.pc_debug<<"\n";return 1;
}
