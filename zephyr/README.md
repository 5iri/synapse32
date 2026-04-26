# Synapse32 Zephyr Port

This directory contains the out-of-tree Zephyr support needed to build Zephyr
images for the Synapse32 cocotb simulator. It is intentionally not a copy of the
upstream Zephyr tree.

## Contents

- `boards/synapse32/synapse32_sim/` - simulator board definition
- `soc/synapse32/synapse32/` - Synapse32 SoC definition and reset/IRQ glue
- `dts/` - Synapse32 device tree files and bindings
- `drivers/serial/` - polling UART driver used by Zephyr console output
- `module.yml` - Zephyr module metadata that exposes this port

## Prerequisites

Install Zephyr normally outside this repository, for example under
`~/zephyrproject`. The full Zephyr checkout and its Python environment should
not be committed here.

## Build A Zephyr Image

From an activated Zephyr environment:

```sh
west build -p always \
  -b synapse32_sim/synapse32 \
  samples/zephyr_hello \
  -d /tmp/zephyr_synapse32_build \
  -- -DZEPHYR_EXTRA_MODULES=$PWD
```

The build produces:

```text
/tmp/zephyr_synapse32_build/zephyr/zephyr.bin
```

## Run In Cocotb

After building the image, run it on the Synapse32 simulator:

```sh
python3 sim/run_zephyr.py /tmp/zephyr_synapse32_build/zephyr/zephyr.bin
```

The runner converts the binary to the `$readmemh` format expected by
`rtl/unified_mem.v`, launches Verilator through `cocotb_test`, and waits for the
UART console to print `Hello World`.
