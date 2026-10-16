"""Sequential Sv32 walks under independent physical-bus stalls."""
import random
import os
from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb_test.simulator import run

@cocotb.test()
async def walks_and_faults(d):
    if os.environ.get('FETCH')=='1': return
    cocotb.start_soon(Clock(d.clk, 10, units="ns").start())
    for name in ['req','we','write_intent','translate','sum','mxr','bus_gnt','bus_done','bus_error','flush_tlb']:
        getattr(d,name).value=0
    d.rst.value=1;d.va.value=0;d.satp.value=0;d.wdata.value=0;d.privilege.value=3
    d.be.value=15;d.load_type.value=2;d.bus_rdata.value=0
    for _ in range(3): await RisingEdge(d.clk)
    await FallingEdge(d.clk);d.rst.value=0
    memory={};trace=[];rng=random.Random(321)
    async def bus():
        while True:
            await FallingEdge(d.clk)
            d.bus_gnt.value=0;d.bus_done.value=0
            if int(d.bus_req.value) and rng.randrange(3)==0:
                a=int(d.bus_addr.value);we=int(d.bus_we.value);value=int(d.bus_wdata.value)
                trace.append((a,we));d.bus_gnt.value=1
                await FallingEdge(d.clk);d.bus_gnt.value=0
                for _ in range(rng.randrange(1,8)): await FallingEdge(d.clk)
                if we: memory[a]=value
                d.bus_rdata.value=memory.get(a,0);d.bus_done.value=1
                await FallingEdge(d.clk);d.bus_done.value=0
    cocotb.start_soon(bus())
    root=0x80010000;table=0x80011000;va=0x40002000;pa=0x80002000
    root_entry=root+4*(va>>22);leaf_entry=table+4*((va>>12)&1023)
    memory[pa]=0x87654380
    async def access(*,paged=True,write=False,priv=1,sum_=0,mxr=0,kind=2,fault=False,value=None,satp=None):
        # These cases exercise the walker after editing PTEs. Cached hits and
        # permission changes without a fence are covered by test_tlb_bus.py.
        await FallingEdge(d.clk);d.flush_tlb.value=1
        await FallingEdge(d.clk);d.flush_tlb.value=0
        await FallingEdge(d.clk)
        d.va.value=va;d.satp.value=satp if satp is not None else 0x80000000|(root>>12);d.translate.value=paged
        d.privilege.value=priv;d.sum.value=sum_;d.mxr.value=mxr;d.we.value=write
        d.write_intent.value=write;d.load_type.value=kind;d.wdata.value=0x12345678;d.req.value=1
        for _ in range(150):
            await Timer(1,units='ns')
            if int(d.gnt.value):
                await RisingEdge(d.clk);await FallingEdge(d.clk);d.req.value=0;break
            await FallingEdge(d.clk)
        else: assert False,'no grant'
        for _ in range(150):
            await Timer(1,units='ns')
            if int(d.rvalid.value):
                assert bool(int(d.page_fault.value))==fault
                if value is not None: assert int(d.rdata.value)==value
                await RisingEdge(d.clk);await FallingEdge(d.clk);return
            await FallingEdge(d.clk)
        assert False,'no response'
    # Bare physical access, then 4 MiB and 4 KiB translations.
    d.va.value=va;memory[va]=7
    await access(paged=False,priv=3,value=7)
    memory[root_entry]=(0x80000000>>12)<<10|0xcf
    await access(value=0x87654380)
    memory[root_entry]=(table>>12)<<10|1
    memory[leaf_entry]=(pa>>12)<<10|0xcf
    await access(kind=0,value=0xffffff80)
    await access(kind=4,value=0x80)
    await access(write=True)
    assert memory[pa]==0x12345678
    before=len(trace)
    for flags,write,priv,sum_,mxr in [(0x0f,False,1,0,0),(0x4f,True,1,0,0),
        (0xcf,False,0,0,0),(0xdf,False,1,0,0),(0xc5,False,1,0,0),(0,False,1,0,0)]:
        memory[leaf_entry]=(pa>>12)<<10|flags
        await access(write=write,priv=priv,sum_=sum_,mxr=mxr,fault=True)
    assert len(trace)-before==12,'faulting access reached physical memory'
    memory[leaf_entry]=(pa>>12)<<10|0xdf
    await access(priv=0,value=0x12345678)
    await access(sum_=1,value=0x12345678)
    memory[leaf_entry]=(pa>>12)<<10|0xc9 # X-only
    await access(mxr=1,value=0x12345678)
    memory[root_entry]=((0x80001000>>12)<<10)|0xcf # misaligned superpage
    await access(fault=True)
    before=len(trace)
    await access(satp=0x80100000,fault=True)
    assert len(trace)==before,'out-of-range root PPN was truncated'
    assert not int(d.fatal_error.value)

@cocotb.test()
async def execute_permissions_and_redirects(d):
    if os.environ.get('FETCH')!='1': return
    cocotb.start_soon(Clock(d.clk,10,units='ns').start())
    for name in ['req','we','write_intent','sum','mxr','bus_gnt','bus_done','bus_error','flush_tlb']:
        getattr(d,name).value=0
    d.rst.value=1;d.va.value=0x40001000;d.satp.value=0x80080010
    d.wdata.value=0;d.be.value=0;d.load_type.value=2;d.translate.value=1
    d.privilege.value=1;d.bus_rdata.value=0
    for _ in range(3): await FallingEdge(d.clk)
    d.rst.value=0
    flags=0x49;instruction=0x12345013
    async def bus():
        while True:
            await FallingEdge(d.clk)
            d.bus_gnt.value=0;d.bus_done.value=0
            if int(d.bus_req.value):
                address=int(d.bus_addr.value);d.bus_gnt.value=1
                await FallingEdge(d.clk);d.bus_gnt.value=0
                for _ in range(7): await FallingEdge(d.clk)
                d.bus_rdata.value=((0x80000000>>12)<<10|flags) if address==0x80010400 else instruction
                d.bus_done.value=1
                await FallingEdge(d.clk);d.bus_done.value=0
    cocotb.start_soon(bus())
    async def access(priv,expected_fault):
        await FallingEdge(d.clk);d.flush_tlb.value=1
        await FallingEdge(d.clk);d.flush_tlb.value=0
        await FallingEdge(d.clk);d.req.value=1;d.privilege.value=priv
        for _ in range(100):
            await Timer(1,units='ns')
            if int(d.gnt.value):
                await FallingEdge(d.clk);d.req.value=0;break
            await FallingEdge(d.clk)
        else: assert False,'no fetch grant'
        for _ in range(100):
            await Timer(1,units='ns')
            if int(d.rvalid.value):
                assert bool(int(d.page_fault.value))==expected_fault
                if not expected_fault: assert int(d.rdata.value)==instruction
                await FallingEdge(d.clk);return
            await FallingEdge(d.clk)
        assert False,'no fetch response'
    await access(1,False)
    flags=0x43 # readable, not executable
    await access(1,True)
    flags=0x59 # user execute
    d.sum.value=1;await access(1,True) # SUM never permits S-mode execute on U pages
    await access(0,False)
    await FallingEdge(d.clk);d.flush_tlb.value=1
    await FallingEdge(d.clk);d.flush_tlb.value=0
    flags=0x49;d.privilege.value=1;d.req.value=1
    for _ in range(100):
        await Timer(1,units='ns')
        if int(d.gnt.value):
            await FallingEdge(d.clk);d.req.value=0;break
        await FallingEdge(d.clk)
    d.va.value=0x40002000 # redirect after acceptance, before PTE response
    for _ in range(50):
        await FallingEdge(d.clk)
        assert not int(d.rvalid.value) and not int(d.page_fault.value),'stale fetch escaped'
    await access(1,False)

if __name__=='__main__':
    here=Path(__file__).resolve().parent;repo=here.parents[2]
    for fetch in [0,1]:
        run(verilog_sources=[str(here.parent/'sv32_bus_port.sv'),str(repo/'rtl/mmu/sv32_tlb.v')],includes=[str(repo/'rtl/include')],
            toplevel='sv32_bus_port',module='test_sv32_bus',simulator='verilator',parameters={'FETCH':fetch},
            extra_env={'FETCH':str(fetch)},sim_build=str(here.parent/f'build/test_sv32_bus_{fetch}'),
            extra_args=['-Wno-fatal'],python_search=[str(here)])
