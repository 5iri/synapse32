// Run the real board fabric and UART wires with a byte-accurate AXI RAM.
// Preloading the payload replaces the host loader, not any CPU memory path.
#include "Vsynapse_ddr3_system.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

#ifndef UART_BIT_CYCLES
#define UART_BIT_CYCLES 16
#endif

int main(int argc, char **argv) {
    try {
        VerilatedContext context;
        context.commandArgs(argc,argv);
        if(argc<2 || argc>5)
            throw std::runtime_error("usage: Vsynapse_ddr3_system memory-bench.bin [cycles [repeats [AXI-response-cycles]]]");
        const uint64_t limit=argc>2 ? std::stoull(argv[2]) : 2000000000ULL;
        const unsigned repeats=argc>3 ? unsigned(std::stoul(argv[3])) : 1;
        const uint64_t response_cycles=argc>4 ? std::stoull(argv[4]) : 20;
        if(!repeats || !response_cycles) throw std::runtime_error("repeats and response delay must be positive");
        std::ifstream image(argv[1],std::ios::binary);
        if(!image) throw std::runtime_error("cannot open payload");
        std::vector<uint8_t> memory(65*1024*1024);
        std::vector<uint8_t> payload((std::istreambuf_iterator<char>(image)),{});
        if(payload.empty() || payload.size()>64*1024*1024)
            throw std::runtime_error("invalid payload size");
        std::copy(payload.begin(),payload.end(),memory.begin());
        Vsynapse_ddr3_system d{&context};
        d.clk=0; d.rst=1; d.calibrated=1; d.uart_rx=1; d.load_req=0; d.load_finish=0;
        d.load_addr=0; d.load_data=0; d.rlast=1; d.rresp=0; d.bresp=0;
        d.rvalid=0; d.bvalid=0; d.arready=0; d.awready=0; d.wready=0;

        bool have_aw=false,have_w=false,write_scheduled=false,read_scheduled=false;
        bool read_valid=false,write_valid=false;
        uint32_t aw=0,ar=0;
        std::array<uint32_t,4> write_data{},read_data{};
        uint16_t strobe=0;
        uint64_t read_due=0,write_due=0,reads=0,writes=0;
        int tx_wait=0,tx_bit=-1;
        unsigned tx_byte=0;
        bool previous_tx=true,failed=false;
        std::string line;
        unsigned ready_count=0,done_count=0;
        std::deque<uint8_t> rx;
        unsigned rx_bit=0,rx_ticks=0;

        for(uint64_t cycle=0;cycle<limit && !context.gotFinish();++cycle) {
            d.rst=cycle<10; d.load_finish=cycle==12;
            // Two stop bits leave a full UART receiver recovery interval.
            d.uart_rx=rx.empty() || rx_bit>=9 ? 1 : rx_bit==0 ? 0 :
                (rx.front()>>(rx_bit-1))&1;
            const bool rx_active=!rx.empty();

            if(read_scheduled && !read_valid && cycle>=read_due) {
                for(unsigned word=0;word<4;++word) {
                    read_data[word]=0;
                    for(unsigned byte=0;byte<4;++byte)
                        read_data[word]|=uint32_t(memory[ar+4*word+byte])<<(8*byte);
                }
                read_valid=true;
            }
            if(write_scheduled && !write_valid && cycle>=write_due) {
                for(unsigned byte=0;byte<16;++byte)
                    if(strobe&(1u<<byte))
                        memory[aw+byte]=uint8_t(write_data[byte/4]>>(8*(byte%4)));
                write_valid=true;
            }
            d.clk=0;
            d.arready=!read_scheduled && !read_valid && cycle%3==1;
            d.awready=!have_aw && !write_valid && cycle%5==1;
            d.wready=!have_w && !write_valid && cycle%7==3;
            d.rvalid=read_valid; d.bvalid=write_valid;
            for(unsigned word=0;word<4;++word) d.rdata[word]=read_data[word];
            d.eval();
            const bool ar_fire=d.arvalid&&d.arready,r_fire=d.rvalid&&d.rready;
            const bool aw_fire=d.awvalid&&d.awready,w_fire=d.wvalid&&d.wready;
            const bool b_fire=d.bvalid&&d.bready;
            const uint32_t address=d.axi_addr;
            std::array<uint32_t,4> incoming_write{};
            for(unsigned word=0;word<4;++word) incoming_write[word]=d.wdata[word];
            const uint16_t incoming_strobe=d.wstrb;
            d.clk=1; d.eval();

            if(rx_active && ++rx_ticks==UART_BIT_CYCLES) {
                rx_ticks=0;
                if(++rx_bit==11) {rx_bit=0; rx.pop_front();}
            }
            if(r_fire) {read_valid=false; read_scheduled=false;}
            if(b_fire) {write_valid=false; write_scheduled=false; have_aw=false; have_w=false;}
            if(ar_fire) {
                if(read_scheduled || uint64_t(address)+16>memory.size())
                    throw std::runtime_error("invalid or duplicate AXI read");
                ar=address; read_scheduled=true; read_due=cycle+response_cycles; ++reads;
            }
            if(aw_fire) {
                if(have_aw || uint64_t(address)+16>memory.size())
                    throw std::runtime_error("invalid or duplicate AXI write address");
                aw=address; have_aw=true;
            }
            if(w_fire) {
                if(have_w) throw std::runtime_error("duplicate AXI write data");
                write_data=incoming_write; strobe=incoming_strobe; have_w=true;
            }
            if(have_aw && have_w && !write_scheduled) {
                write_scheduled=true; write_due=cycle+response_cycles; ++writes;
            }
            if(d.fault)
                throw std::runtime_error("fabric fault at PC "+std::to_string(d.pc_debug));

            const bool tx=d.uart_tx;
            if(tx_bit<0) {
                if(previous_tx && !tx) {tx_wait=UART_BIT_CYCLES+UART_BIT_CYCLES/2; tx_bit=0; tx_byte=0;}
            } else if(--tx_wait==0) {
                if(tx_bit<8) {tx_byte|=unsigned(tx)<<tx_bit++; tx_wait=UART_BIT_CYCLES;}
                else {
                    if(!tx) throw std::runtime_error("UART framing error; build firmware with 1 MHz and UART scale 16");
                    const char ch=char(tx_byte);
                    std::cout.put(ch); tx_bit=-1;
                    if(ch=='\n') {
                        std::cout.flush();
                        if(line=="S32_MEMORY_BENCH_READY" && ready_count<repeats) {
                            ++ready_count;
                            const std::string command="r\n";
                            rx.insert(rx.end(),command.begin(),command.end());
                        } else if(line.rfind("S32_MEMORY_BENCH_DONE:",0)==0) {
                            failed|=line!="S32_MEMORY_BENCH_DONE:0"; ++done_count;
                        } else if(line.find("ERROR!")!=std::string::npos ||
                                  line.find("S32_MEMORY_BENCH_TRAP")!=std::string::npos) failed=true;
                        line.clear();
                    } else if(ch!='\r') line+=ch;
                }
            }
            previous_tx=tx;
            if(failed) throw std::runtime_error("firmware reported error or trap");
            if(done_count==repeats) {
                std::cout<<"\nMEMORY_BENCH_AXI_SUMMARY cycles="<<cycle+1<<" reads="<<reads
                    <<" writes="<<writes<<" response_cycles="<<response_cycles<<" completed="<<done_count<<'\n';
                d.final(); return 0;
            }
            if(cycle && cycle%50000000==0)
                std::cerr<<"cycles="<<cycle<<" PC=0x"<<std::hex<<d.pc_debug<<std::dec
                    <<" reads="<<reads<<" writes="<<writes<<'\n';
        }
        throw std::runtime_error("cycle limit reached before all reports completed");
    } catch(const std::exception& error) {
        std::cerr<<"memory_bench_axi: "<<error.what()<<'\n'; return 1;
    }
}
