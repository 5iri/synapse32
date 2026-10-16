.DEFAULT_GOAL := help
.PHONY: help linux baremetal fastmem test
help:
	@echo 'Targets: linux (static RV32 Linux ELF), baremetal (M-mode ELF/bin/hex), fastmem (Verilator experiment), test (report validation)'
linux:
	bash build_linux.sh
baremetal:
	bash build_baremetal.sh
fastmem:
	bash fastmem.sh
test:
	python3 -m unittest discover -s . -p 'test_*.py' -v
