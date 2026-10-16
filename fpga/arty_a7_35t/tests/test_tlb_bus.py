"""Exercise the upstream TLB through the board's stalled DDR-facing port."""
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer
from cocotb_test.simulator import run


class Port:
    def __init__(self, dut):
        self.d = dut
        self.memory = {}
        self.trace = []
        self.delay = 4
        self.fetch = os.environ['FETCH'] == '1'
        self.root = 0x80010000
        self.table = 0x80011000
        self.va = 0x40002000
        self.pa = 0x80002000

    async def init(self):
        d = self.d
        cocotb.start_soon(Clock(d.clk, 10, units='ns').start())
        for name in ['req', 'we', 'write_intent', 'sum', 'mxr', 'bus_gnt',
                     'bus_done', 'bus_error', 'flush_tlb']:
            getattr(d, name).value = 0
        d.rst.value = 1
        d.va.value = self.va
        d.satp.value = 0x80000000 | (self.root >> 12)
        d.translate.value = 1
        d.privilege.value = 1
        d.wdata.value = 0xabcdef01
        d.be.value = 15
        d.load_type.value = 2
        d.bus_rdata.value = 0
        for _ in range(3):
            await FallingEdge(d.clk)
        d.rst.value = 0
        self.map(self.pa)
        self.memory[self.pa] = 0x11223344
        cocotb.start_soon(self.bus())

    def map(self, pa, flags=0xcf):
        self.memory[self.root + 4 * (self.va >> 22)] = (self.table >> 12) << 10 | 1
        self.memory[self.table + 4 * ((self.va >> 12) & 1023)] = (pa >> 12) << 10 | flags

    async def bus(self):
        d = self.d
        while True:
            await FallingEdge(d.clk)
            d.bus_gnt.value = 0
            d.bus_done.value = 0
            if int(d.bus_req.value):
                address = int(d.bus_addr.value)
                write = int(d.bus_we.value)
                data = int(d.bus_wdata.value)
                self.trace.append((address, write))
                d.bus_gnt.value = 1
                await FallingEdge(d.clk)
                d.bus_gnt.value = 0
                # Snapshot the response before the simulated memory is changed.
                value = self.memory.get(address, 0)
                for _ in range(self.delay):
                    await FallingEdge(d.clk)
                if write:
                    self.memory[address] = data
                d.bus_rdata.value = value
                d.bus_done.value = 1
                await FallingEdge(d.clk)
                d.bus_done.value = 0

    async def fence(self):
        await FallingEdge(self.d.clk)
        self.d.flush_tlb.value = 1
        await FallingEdge(self.d.clk)
        self.d.flush_tlb.value = 0

    async def begin(self, **signals):
        d = self.d
        await FallingEdge(d.clk)
        for name, value in signals.items():
            getattr(d, name).value = value
        d.req.value = 1
        for _ in range(200):
            await Timer(1, units='ns')
            if int(d.gnt.value):
                await FallingEdge(d.clk)
                d.req.value = 0
                return
            await FallingEdge(d.clk)
        raise AssertionError('request was not granted')

    async def finish(self, value=None, fault=False):
        d = self.d
        for _ in range(300):
            await Timer(1, units='ns')
            if int(d.rvalid.value):
                assert bool(int(d.page_fault.value)) == fault
                if value is not None:
                    assert int(d.rdata.value) == value
                await FallingEdge(d.clk)
                return
            await FallingEdge(d.clk)
        raise AssertionError('request did not complete')

    async def access(self, value=None, fault=False, **signals):
        start = len(self.trace)
        await self.begin(**signals)
        await self.finish(value, fault)
        return self.trace[start:]


@cocotb.test()
async def hits_permissions_and_context(d):
    p = Port(d)
    await p.init()
    assert len(await p.access(0x11223344)) == 3, 'cold 4 KiB walk'
    assert await p.access(0x11223344) == [(p.pa, 0)], 'TLB hit still walks DDR'
    # Permission changes in the CPU must be checked even on a cached PTE.
    assert await p.access(fault=True, privilege=0) == [], 'S leaf accessible to U'
    assert await p.access(0x11223344, privilege=1) == [(p.pa, 0)]

    # A changed PTE remains cached until SFENCE, then the new page must be read.
    new_pa = p.pa + 0x1000
    p.memory[new_pa] = 0x55667788
    p.map(new_pa)
    assert await p.access(0x11223344) == [(p.pa, 0)]
    await p.fence()
    assert len(await p.access(0x55667788)) == 3
    assert await p.access(0x55667788) == [(new_pa, 0)]

    # Changing only the ASID also invalidates: upstream entries have no ASID tag.
    p.map(p.pa)
    assert len(await p.access(0x11223344, satp=0x80400000 | (p.root >> 12))) == 3
    # An unrepresentable root PPN must fault rather than use a cached hit.
    assert await p.access(fault=True, satp=0x80100000) == []
    assert len(await p.access(0x11223344, satp=0x80000000 | (p.root >> 12))) == 3

    # Megapages share one translation across distinct 4 KiB VPNs.
    p.memory[p.root + 4 * (p.va >> 22)] = (0x80000000 >> 12) << 10 | 0xcf
    await p.fence()
    assert len(await p.access(0x11223344)) == 2
    assert await p.access(0x55667788, va=p.va + 0x1000) == [(new_pa, 0)]
    assert not int(d.fatal_error.value)


@cocotb.test()
async def root_switch_bare_mode_and_fault_retry(d):
    p = Port(d)
    await p.init()
    await p.access(0x11223344)
    new_root, new_table, new_pa = 0x80012000, 0x80013000, p.pa + 0x1000
    p.memory[new_root + 4 * (p.va >> 22)] = (new_table >> 12) << 10 | 1
    leaf = new_table + 4 * ((p.va >> 12) & 1023)
    p.memory[leaf] = (new_pa >> 12) << 10 | 0xcf
    p.memory[new_pa] = 0x55667788
    assert len(await p.access(0x55667788, satp=0x80000000 | (new_root >> 12))) == 3
    assert await p.access(0x55667788) == [(new_pa, 0)]
    # M-mode/bare bypass must use the VA even while a translation is cached.
    p.memory[p.va] = 0x12345013
    assert await p.access(0x12345013, translate=0, privilege=3) == [(p.va, 0)]
    assert await p.access(0x55667788, translate=1, privilege=1) == [(new_pa, 0)]
    p.memory[leaf] = 0
    await p.fence()
    assert len(await p.access(fault=True)) == 2
    # Faults are not cached: making the previously invalid leaf valid succeeds.
    p.memory[leaf] = (new_pa >> 12) << 10 | 0xcf
    assert len(await p.access(0x55667788)) == 3
    if not p.fetch:
        assert await p.access(we=1, write_intent=1) == [(new_pa, 1)]
        assert p.memory[new_pa] == 0xabcdef01


@cocotb.test()
async def cached_permission_controls(d):
    p = Port(d)
    await p.init()
    if p.fetch:
        p.map(p.pa, 0xdf)  # U, RWX, A/D.
        await p.access(0x11223344, privilege=0)
        assert await p.access(fault=True, privilege=1, sum=1) == []
    else:
        p.map(p.pa, 0xdf)
        await p.access(0x11223344, privilege=0)
        assert await p.access(fault=True, privilege=1) == []
        assert await p.access(0x11223344, sum=1) == [(p.pa, 0)]
        p.map(p.pa, 0x49)  # Execute-only S leaf, accessed but not dirty.
        await p.fence()
        await p.access(0x11223344, mxr=1, sum=0)
        assert await p.access(fault=True, mxr=0) == []
        assert await p.access(fault=True, we=1, write_intent=1) == []
        p.map(p.pa, 0x4f)  # Writable but D clear; a cached read must not permit a store.
        await p.fence()
        await p.access(0x11223344, we=0, write_intent=0)
        assert await p.access(fault=True, we=1, write_intent=1) == []


@cocotb.test()
async def fence_during_walk(d):
    p = Port(d)
    await p.init()
    p.delay = 12
    await p.begin()
    for _ in range(100):
        await FallingEdge(d.clk)
        if len(p.trace) == 2:
            break
    else:
        raise AssertionError('leaf request was not issued')
    # Let the bus snapshot the old leaf before changing memory and fencing.
    await FallingEdge(d.clk)
    new_pa = p.pa + 0x1000
    p.memory[new_pa] = 0x55667788
    p.map(new_pa)
    await p.fence()
    if p.fetch:
        # Even at the same PC a pre-fence instruction response must be discarded.
        for _ in range(90):
            await FallingEdge(d.clk)
            assert not int(d.rvalid.value), 'pre-fence instruction escaped'
    else:
        await p.finish(0x11223344)  # Older accepted data access may finish.
    assert len(await p.access(0x55667788)) == 3, 'aborted walk refilled the TLB'
    assert await p.access(0x55667788) == [(new_pa, 0)]


if __name__ == '__main__':
    here = Path(__file__).resolve().parent
    repo = here.parents[2]
    for fetch in [0, 1]:
        run(verilog_sources=[str(here.parent / 'sv32_bus_port.sv'),
                             str(repo / 'rtl/mmu/sv32_tlb.v')],
            includes=[str(repo / 'rtl/include')], toplevel='sv32_bus_port',
            module='test_tlb_bus', simulator='verilator', parameters={'FETCH': fetch},
            extra_env={'FETCH': str(fetch)},
            sim_build=str(here.parent / f'build/test_tlb_bus_{fetch}'),
            extra_args=['-Wno-fatal'], python_search=[str(here)])
