#include "Vfastmem.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t ram_base = 0x80000000u, ram_size = 64u << 20;
constexpr uint32_t scratch_base = 0x10000000u, scratch_size = 1u << 20;
constexpr uint32_t uart_base = 0x20000000u;

struct Host {
    std::vector<uint8_t> ram = std::vector<uint8_t>(ram_size, 0);
    std::vector<uint8_t> scratch = std::vector<uint8_t>(scratch_size, 0);
    std::deque<uint8_t> rx;
    uint64_t cycles = 0;
    unsigned iterations = 50, ready_count = 0, done_count = 0;
    uint8_t uart_lcr = 0;
    bool failed = false;
    std::string line;

    uint8_t read_byte(uint32_t addr) const {
        if (addr >= ram_base && addr - ram_base < ram_size)
            return ram[addr - ram_base];
        if (addr >= scratch_base && addr - scratch_base < scratch_size)
            return scratch[addr - scratch_base];
        throw std::runtime_error("unmapped RAM read at " + std::to_string(addr));
    }
    uint32_t ram_word(uint32_t addr, unsigned width = 4) const {
        uint32_t value = 0;
        for (unsigned i = 0; i < width; ++i) value |= uint32_t(read_byte(addr+i)) << (8*i);
        return value;
    }
    uint32_t read_data(uint32_t addr, unsigned type) const {
        uint32_t value;
        if (addr == 0x0200bff8u) value = uint32_t(cycles);
        else if (addr == 0x0200bffcu) value = uint32_t(cycles >> 32);
        else if (addr >= uart_base && addr < uart_base + 32) {
            switch ((addr-uart_base)/4) {
            case 0: value = (uart_lcr & 0x80) ? 0 : (rx.empty() ? 0 : rx.front()); break;
            case 2: value = 1; break; // no interrupt pending
            case 3: value = uart_lcr; break;
            case 5: value = 0x60 | (!rx.empty() ? 1 : 0); break;
            default: value = 0;
            }
        } else {
            unsigned width = type == 0 || type == 4 ? 1 : type == 1 || type == 5 ? 2 : 4;
            value = ram_word(addr, width);
        }
        switch (type) {
        case 0: return uint32_t(int32_t(int8_t(value)));
        case 1: return uint32_t(int32_t(int16_t(value)));
        case 4: return value & 0xff;
        case 5: return value & 0xffff;
        default: return value;
        }
    }
    void receive_line() {
        if (line == "S32_BAREMETAL_READY") {
            if (ready_count < 2) {
                std::string cmd = std::string(ready_count++ == 0 ? "p " : "v ")
                    + std::to_string(iterations) + "\n";
                rx.insert(rx.end(), cmd.begin(), cmd.end());
            }
        } else if (line.rfind("S32_BAREMETAL_DONE:", 0) == 0) {
            if (line != "S32_BAREMETAL_DONE:0") failed = true;
            ++done_count;
        } else if (line.find("ERROR") != std::string::npos ||
                   line.find("S32_BAREMETAL_TRAP") != std::string::npos) {
            failed = true;
        }
        line.clear();
    }
    void write(uint32_t addr, uint32_t value, unsigned be) {
        if (addr >= uart_base && addr < uart_base + 32) {
            unsigned reg = (addr-uart_base)/4;
            if (!(be & 1)) return;
            if (reg == 3) uart_lcr = uint8_t(value);
            else if (reg == 0 && !(uart_lcr & 0x80)) {
                char c = char(value);
                std::cout.put(c);
                if (c == '\n') { receive_line(); std::cout.flush(); }
                else if (c != '\r') line += c;
            }
            return;
        }
        for (unsigned i = 0; i < 4; ++i) {
            if (!(be & (1u << i))) continue;
            uint32_t target = addr+i;
            if (target >= ram_base && target-ram_base < ram_size)
                ram[target-ram_base] = uint8_t(value >> (8*i));
            else if (target >= scratch_base && target-scratch_base < scratch_size)
                scratch[target-scratch_base] = uint8_t(value >> (8*i));
            else throw std::runtime_error("unmapped RAM write at " + std::to_string(target));
        }
    }
    void commit_read(uint32_t addr) {
        if (addr == uart_base && !(uart_lcr & 0x80) && !rx.empty()) rx.pop_front();
    }
    void settle(Vfastmem &top) const {
        // Resolve host-backed combinational reads without changing storage. The
        // CPU may change data requests when an AMO consumes a read response.
        for (unsigned pass = 0; pass < 16; ++pass) {
            top.eval();
            uint32_t instr = ram_word(top.instr_store_addr);
            uint32_t data = top.data_store_req && !top.data_store_we
                ? read_data(top.data_store_addr, top.data_load_type) : 0;
            if (top.instr_store_rdata == instr && top.data_store_rdata == data) return;
            top.instr_store_rdata = instr;
            top.data_store_rdata = data;
        }
        throw std::runtime_error("host memory inputs did not settle");
    }
};
}

int main(int argc, char **argv) {
    try {
        std::string binary;
        uint64_t max_cycles = 1000000000ull;
        Host host;
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];
            if (arg == "--binary" && i+1 < argc) binary = argv[++i];
            else if (arg == "--iterations" && i+1 < argc)
                host.iterations = unsigned(std::stoul(argv[++i]));
            else if (arg == "--max-cycles" && i+1 < argc)
                max_cycles = std::stoull(argv[++i]);
            else throw std::runtime_error("expected --binary PATH [--iterations N] [--max-cycles N]");
        }
        if (binary.empty() || !host.iterations) throw std::runtime_error("binary and positive iterations required");
        std::ifstream file(binary, std::ios::binary);
        if (!file) throw std::runtime_error("cannot open binary: " + binary);
        std::vector<uint8_t> program((std::istreambuf_iterator<char>(file)), {});
        if (program.empty() || program.size() > ram_size) throw std::runtime_error("invalid binary size");
        std::copy(program.begin(), program.end(), host.ram.begin());
        VerilatedContext context;
        context.commandArgs(argc, argv);
        Vfastmem top{&context};
        top.clk = 0; top.rst = 1;
        top.instr_store_rdata = top.data_store_rdata = 0;
        for (unsigned reset = 0; reset < 8; ++reset) {
            host.settle(top); top.clk = 1; top.eval(); top.clk = 0; top.eval();
        }
        top.rst = 0;
        uint64_t fetch_wait = 0, mem_wait = 0, hazard = 0;
        while (host.cycles < max_cycles && host.done_count < 2 && !host.failed && !context.gotFinish()) {
            host.settle(top);
            const uint32_t addr = top.data_store_addr, value = top.data_store_wdata;
            const unsigned be = top.data_store_be;
            const bool write = top.data_write_fire, read = top.data_read_fire;
            fetch_wait += top.debug_fetch_wait;
            mem_wait += top.debug_mem_wait;
            hazard += top.debug_hazard_stall;
            top.clk = 1; top.eval();
            if (write) host.write(addr, value, be);
            if (read) host.commit_read(addr);
            ++host.cycles;
            top.clk = 0;
        }
        top.eval();
        std::cout << "\nFASTMEM_SUMMARY cycles=" << host.cycles
            << " csr_cycles=" << top.debug_cycles << " instret=" << top.debug_instret
            << " fetch_wait=" << fetch_wait << " mem_wait=" << mem_wait
            << " hazard_stall=" << hazard << " completed=" << host.done_count << '\n';
        top.final();
        if (host.failed) throw std::runtime_error("firmware reported an error or trap");
        if (host.done_count != 2) throw std::runtime_error("cycle limit reached before both runs completed");
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "fastmem: " << error.what() << '\n';
        return 1;
    }
}
