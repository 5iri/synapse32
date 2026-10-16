.DEFAULT_GOAL := help
.PHONY: help linux baremetal test
help:
	@echo 'Targets: linux (static RV32 Linux ELF), baremetal (M-mode ELF/bin/hex), test (report validation)'
linux:
	bash build_linux.sh
baremetal:
	bash build_baremetal.sh
test:
	python3 -m unittest discover -s . -p 'test_*.py' -v
