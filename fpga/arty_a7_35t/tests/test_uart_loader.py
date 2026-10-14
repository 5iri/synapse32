"""Exercise real UART waveforms, DDR backpressure, CRC rejection and reset."""
import struct
import zlib
import os
from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb_test.simulator import run

@cocotb.test()
async def serial_boot(d):
    bit_cycles = int(os.environ.get('TEST_UART_BIT_CYCLES', '16'))
    cocotb.start_soon(Clock(d.clk,10,units='ns').start())
    d.rst.value=1;d.enabled.value=1;d.rx.value=1;d.ready.value=0;d.done.value=0;d.bus_fault.value=0
    writes=[];finishes=[];bus_delay=13
    async def bus():
        while True:
            await FallingEdge(d.clk)
            d.ready.value=0;d.done.value=0
            if int(d.req.value):
                writes.append((int(d.addr.value),int(d.data.value)))
                d.ready.value=1
                await FallingEdge(d.clk);d.ready.value=0
                for _ in range(bus_delay): await FallingEdge(d.clk)
                d.done.value=1
                await FallingEdge(d.clk);d.done.value=0
    async def watch():
        while True:
            await FallingEdge(d.clk)
            if int(d.finish.value): finishes.append(len(writes))
    cocotb.start_soon(bus());cocotb.start_soon(watch())
    async def reset():
        d.rst.value=1;d.rx.value=1;d.bus_fault.value=0
        for _ in range(5): await FallingEdge(d.clk)
        d.rst.value=0
        for _ in range(5): await FallingEdge(d.clk)
        writes.clear();finishes.clear()
    async def send(values):
        for value in values:
            for bit in [0]+[(value>>i)&1 for i in range(8)]+[1]:
                d.rx.value=bit
                for _ in range(bit_cycles): await FallingEdge(d.clk)
        d.rx.value=1
    async def reply():
        await FallingEdge(d.tx)
        await Timer(bit_cycles*15,units='ns')
        value=0
        for bit in range(8):
            value|=int(d.tx.value)<<bit
            await Timer(bit_cycles*10,units='ns')
        assert int(d.tx.value)==1,'reply stop bit'
        for _ in range(40): await FallingEdge(d.clk)
        return value
    data=bytes(range(64))
    for bad_crc in [False,True]:
        await reset()
        packet=b'S32!'+struct.pack('<I',len(data))+data+struct.pack('<I',zlib.crc32(data)^bad_crc)
        response=cocotb.start_soon(reply())
        await send(packet)
        assert await response==(ord('E') if bad_crc else ord('K'))
        assert writes==[(0x80000000+i,int.from_bytes(data[i:i+4],'little')) for i in range(0,len(data),4)]
        assert bool(int(d.error.value))==bad_crc
        assert finishes==([] if bad_crc else [16])
    for length in [0,3,0x04000004]:
        await reset()
        response=cocotb.start_soon(reply())
        await send(b'S32!'+struct.pack('<I',length))
        assert await response==ord('E')
        assert not writes and not finishes and int(d.error.value)
    await reset();bus_delay=bit_cycles*20
    response=cocotb.start_soon(reply())
    data=bytes(range(16))
    await send(b'S32!'+struct.pack('<I',16)+data+struct.pack('<I',zlib.crc32(data)))
    assert await response==ord('E')
    assert int(d.error.value) and not finishes,'DDR overrun released CPU'
    await reset();bus_delay=13
    response=cocotb.start_soon(reply())
    await send(b'S32!'+struct.pack('<I',16)+data)
    d.bus_fault.value=1
    assert await response==ord('E')
    assert int(d.error.value) and not finishes,'DDR error was acknowledged as a valid image'

if __name__=='__main__':
    here=Path(__file__).resolve().parent
    for clock_hz, baud in [(1843200,115200),(50000000,1000000)]:
        run(verilog_sources=[str(here.parent/'uart_boot_loader.sv')],
            toplevel='uart_boot_loader',module='test_uart_loader',simulator='verilator',
            parameters={'CLOCK_HZ':clock_hz,'BAUD':baud},
            extra_env={'TEST_UART_BIT_CYCLES':str((clock_hz+baud//2)//baud)},
            sim_build=str(here.parent/f'build/test_uart_loader_{baud}'),extra_args=['-Wno-fatal'],python_search=[str(here)])
