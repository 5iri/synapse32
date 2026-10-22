VIVADO ?= vivado
PYTHON ?= python3
PYTHON_RUN := $(if $(findstring /,$(PYTHON)),$(abspath $(PYTHON)),$(PYTHON))
PORT ?= /dev/ttyUSB1
BOOT_BAUD ?= 1000000
IMAGE ?= build/linux-image/fw_payload.bin
UART_LOG ?= build/hardware-uart.log

.PHONY: bitstream performance-bitstream linux llvm-toolchain program upload test-board test test-fetch test-memory-path memory-bench test-phy test-linux test-core test-l1 test-store-buffer test-posted-stores test-perf-counters test-bram-coremark test-coremark-axi triangulator deploy-triangulator visualizer test-triangulator coremark coremark-baremetal coremark-profile coremark-linux-profiler workloads test-workloads deploy-workloads
workloads:
	$(PYTHON_RUN) workloads/build.py
test-workloads:
	$(PYTHON_RUN) -m unittest discover -s workloads -p 'test_*.py'
deploy-workloads: workloads
	$(PYTHON_RUN) workloads/deploy.py $(PORT) --log $(UART_LOG)
triangulator:
	bash triangulator/build.sh
deploy-triangulator: triangulator
	$(PYTHON_RUN) triangulator/deploy.py $(PORT) --log $(UART_LOG)
visualizer:
	$(PYTHON_RUN) triangulator/viewer.py --port $(PORT) --log $(UART_LOG) --start
test-triangulator:
	$(PYTHON_RUN) triangulator/test_geometry.py
	$(PYTHON_RUN) triangulator/test_viewer.py
	$(PYTHON_RUN) triangulator/test_protocol.py
	$(PYTHON_RUN) triangulator/test_uart_link.py
coremark:
	bash coremark/build.sh
coremark-baremetal:
	bash coremark/build_baremetal.sh
coremark-profile:
	bash coremark/build_profile.sh
coremark-linux-profiler:
	bash coremark/build_linux_profiler.sh
memory-bench:
	bash memory_bench/build.sh
bitstream:
	$(VIVADO) -mode batch -source build_bitstream.tcl
performance-bitstream:
	$(VIVADO) -mode batch -source build_performance.tcl
linux:
	bash build_linux.sh
llvm-toolchain:
	bash prepare_llvm.sh
program:
	$(VIVADO) -mode batch -source program.tcl
upload:
	$(PYTHON_RUN) upload.py $(PORT) $(IMAGE) --baud $(BOOT_BAUD) --console
test-board:
	$(PYTHON_RUN) test_board.py $(PORT) $(IMAGE) --baud $(BOOT_BAUD)
test:
	bash test_dcache.sh
	bash test_fast_l1.sh
	bash test_write_buffer.sh
	bash test_posted_stores.sh
	bash test_perf_counters.sh
	$(MAKE) test-fetch
	$(MAKE) test-memory-path
	bash test_axi.sh
	for fast in 0 1; do verilator --binary --timing -Wno-fatal -j 4 -I../../rtl/include --top-module tb_muldiv -GFAST_MULTIPLY=$$fast --Mdir build/obj_muldiv_fast$$fast tests/tb_muldiv.sv ../../rtl/core_modules/iterative_muldiv.v > build/muldiv-fast$$fast-compile.log 2>&1 && build/obj_muldiv_fast$$fast/Vtb_muldiv || exit $$?; done
	bash test_muldiv_cancel.sh
	$(PYTHON_RUN) tests/test_sv32_bus.py
	$(PYTHON_RUN) tests/test_tlb_bus.py
	$(PYTHON_RUN) tests/test_uart_loader.py
test-l1:
	bash test_fast_l1.sh
test-fetch:
	bash test_pipelined_fetch_port.sh
	bash test_frontend_cache_transactions.sh
	bash test_fetch_port_restart.sh
	bash test_instruction_fetch_queue.sh
	bash test_instr_access_fault.sh
	bash test_fetch_access_fault.sh
	FETCH_QUEUE=0 EXPECT_INTERVAL=2 bash test_fetch_throughput.sh
	FETCH_QUEUE=1 EXPECT_INTERVAL=1 bash test_fetch_throughput.sh
	FETCH_QUEUE=1 POSTED_TEST_DEPTHS=4 POSTED_TEST_FAST_MUL=1 bash test_posted_stores.sh
test-store-buffer:
	bash test_write_buffer.sh
test-memory-path:
	$(PYTHON_RUN) -m unittest discover -s memory_bench -p 'test_*.py'
	LOAD_FORWARDING_INTERFACE=1 LOAD_FORWARDING=0 EXPECT_INTERVAL=3 bash test_load_forwarding.sh
	LOAD_FORWARDING_INTERFACE=1 LOAD_FORWARDING=1 EXPECT_INTERVAL=2 bash test_load_forwarding.sh
	bash test_early_store_response.sh
	bash test_load_fault_priority.sh
	bash test_load_response_contract.sh
	bash test_trigger_base_compare.sh
	bash test_atomic_trigger_forwarding.sh
	FETCH_QUEUE=1 LOAD_FORWARDING=1 FAST_STORE_ACK=1 POSTED_TEST_DEPTHS=4 POSTED_TEST_FAST_MUL=1 bash test_posted_stores.sh
test-posted-stores:
	bash test_posted_stores.sh
test-perf-counters:
	bash test_perf_counters.sh
test-bram-coremark:
	bash test_bram_coremark.sh
test-coremark-axi:
	bash test_coremark_axi.sh
test-phy:
	bash simulate.sh
test-linux:
	bash test_linux.sh $(IMAGE)
test-core:
	cd ../.. && $(PYTHON_RUN) -m pytest \
		tests/system_tests/test_memory_wait.py \
		tests/system_tests/test_uart_rx_fifo.py \
		tests/system_tests/test_uart_plic_rearm.py \
		tests/system_tests/test_csr_pending_rmw.py -q
