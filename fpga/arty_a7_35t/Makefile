VIVADO ?= vivado
PYTHON ?= python3
PYTHON_RUN := $(if $(findstring /,$(PYTHON)),$(abspath $(PYTHON)),$(PYTHON))
PORT ?= /dev/ttyUSB1
IMAGE ?= build/linux-image/fw_payload.bin

.PHONY: bitstream linux llvm-toolchain program upload test test-phy test-linux test-core
bitstream:
	$(VIVADO) -mode batch -source build_bitstream.tcl
linux:
	bash build_linux.sh
llvm-toolchain:
	bash prepare_llvm.sh
program:
	$(VIVADO) -mode batch -source program.tcl
upload:
	$(PYTHON_RUN) upload.py $(PORT) $(IMAGE) --console
test:
	bash test_axi.sh
	verilator --binary --timing -Wno-fatal -j 4 -I../../rtl/include --top-module tb_muldiv --Mdir build/obj_muldiv tests/tb_muldiv.sv ../../rtl/core_modules/iterative_muldiv.v > build/muldiv-compile.log 2>&1
	build/obj_muldiv/Vtb_muldiv
	$(PYTHON_RUN) tests/test_sv32_bus.py
	$(PYTHON_RUN) tests/test_uart_loader.py
test-phy:
	bash simulate.sh
test-linux:
	bash test_linux.sh $(IMAGE)
test-core:
	cd ../.. && $(PYTHON_RUN) -m pytest tests/system_tests/test_memory_wait.py tests/system_tests/test_uart_rx_fifo.py tests/system_tests/test_uart_plic_rearm.py -q
