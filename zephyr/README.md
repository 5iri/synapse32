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

## Bundled Demo Binary

The repository keeps a known-good Zephyr hello-world image at:

```text
sim/zephyr_hello.bin
```

Run it from the repository root with:

```sh
uv pip install -r requirements.txt
python sim/run_zephyr_sim.py
```

To run a different image manually:

```sh
python sim/run_zephyr_sim.py path/to/zephyr.bin
```

## Regenerate `sim/zephyr_hello.bin`

The committed demo binary was produced from the sample application in
`samples/zephyr_hello/` using the out-of-tree Synapse32 Zephyr module in this
repository.

### Required Configuration

Board defaults:

- `zephyr/boards/synapse32/synapse32_sim/synapse32_sim_synapse32_defconfig`
- UART console enabled
- `CONFIG_XIP=y`
- `CONFIG_INCLUDE_RESET_VECTOR=y`

Sample config:

- `samples/zephyr_hello/prj.conf`
- `CONFIG_PRINTK=y`
- `CONFIG_STDOUT_CONSOLE=y`
- `CONFIG_MINIMAL_LIBC=y`

Sample source:

- `samples/zephyr_hello/src/main.c`

### One-Time Build Command

This repository does not automate Zephyr workspace setup. From an existing
Zephyr workspace, point `REPO_ROOT` at this repository and run:

```sh
REPO_ROOT=/path/to/synapse32
env \
  ZEPHYR_TOOLCHAIN_VARIANT=cross-compile \
  CROSS_COMPILE=/opt/homebrew/bin/riscv64-unknown-elf- \
  CROSS_COMPILE_TOOLCHAIN_PATH=/opt/homebrew/bin \
  TOOLCHAIN_HOME=/opt/homebrew/bin \
  "$REPO_ROOT/.venv/bin/python" -m west build -p always \
  -b synapse32_sim/synapse32 \
  "$REPO_ROOT/samples/zephyr_hello" \
  -d /tmp/zephyr_synapse32_build \
  -- \
  -DZEPHYR_EXTRA_MODULES="$REPO_ROOT" \
  -DCROSS_COMPILE=/opt/homebrew/bin/riscv64-unknown-elf- \
  -DCROSS_COMPILE_TOOLCHAIN_PATH=/opt/homebrew/bin \
  -DTOOLCHAIN_HOME=/opt/homebrew/bin
```

Then copy the built image into the repository:

```sh
cp /tmp/zephyr_synapse32_build/zephyr/zephyr.bin sim/zephyr_hello.bin
```
