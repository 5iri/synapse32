# Synapse32 triangulation visualizer

The RV32 Linux executable moves points and calculates a Delaunay triangulation
on the FPGA. A laptop browser draws the received mesh and charts its computation
time. The browser does not generate points or triangulate them.

The program uses integer coordinates and exact 64-bit predicates in a 640×400
viewport. It builds a triangulation of the actual convex hull, inserts interior
vertices, and flips edges until they satisfy the Delaunay criterion. No FPU,
libc, dynamic allocation, display adapter, or bitstream change is needed.

## Use the Linux session already running

Keep `test_board.py --keep-open` running. Use its actual log path below; the
examples assume the default `build/hardware-uart.log`. Close other typing
clients while deploying or controlling the demo.

From the repository root:

```sh
make -C fpga/arty_a7_35t triangulator
.venv/bin/python fpga/arty_a7_35t/triangulator/deploy.py /dev/ttyUSB1 \
  --log fpga/arty_a7_35t/build/hardware-uart.log
.venv/bin/python fpga/arty_a7_35t/triangulator/viewer.py \
  --log fpga/arty_a7_35t/build/hardware-uart.log --start
```

Open **http://127.0.0.1:8765**. Start with 16 points; choose 32 or 64 and click
**Restart on FPGA** to increase the workload. **Stop computation** interrupts
the program and returns Linux to its shell while retaining the UART reader.

The deployer transfers acknowledged base64 chunks, checks the executable's
SHA256 on the FPGA, and sets its executable permission. It writes only
`/tmp/triangulator`. Both tools use companion write handles and tail the retained
reader's log without configuring UART or changing DTR.

If a serial application has left an exclusive TTY lock behind, new handles can
report `Device or resource busy` even after that application exits. Clear the
lock while the reader remains open:

```sh
sudo python3 -c 'import os,fcntl,termios; fd=os.open("/dev/ttyUSB1",os.O_WRONLY|os.O_NOCTTY); fcntl.ioctl(fd,termios.TIOCNXCL); os.close(fd)'
```

## Include the program in future Linux images

The Arty Linux build now includes `/bin/triangulator` automatically:

```sh
LLVM=1 make -C fpga/arty_a7_35t linux
```

After booting that image, use `viewer.py --binary /bin/triangulator`.
For the tested faster profile, also pass `--cpu-mhz 62.5 --kernel-hz 25` so
the hardware labels reflect the programmed clock and kernel image. These
options only label the viewer; they do not configure the FPGA or Linux.
`BUILD_TRIANGULATOR=0` omits the demo. `triangulator/build.sh` accepts
`TRIANGULATOR_CC` and `TRIANGULATOR_OUT`; the default compiler is the local
LLVM/musl wrapper produced by `prepare_llvm.sh`.

For a finite console benchmark:

```sh
/bin/triangulator --points 16 --frames 10
```

The C executable emits one `S32MESH` JSON line per frame and `S32DONE` when a
finite run completes. `--frames 0`, the default, runs until interrupted.

## Interpret and verify the measurements

**Triangulation time** is elapsed monotonic time around the mesh calculation,
including interrupts and clock-read overhead. Point movement, JSON formatting, and UART
transmission are outside that interval. **Received frame rate** measures meshes
arriving at the laptop and therefore includes those additional costs. Neither
number is a CPU-utilization percentage or a browser rendering benchmark.

```sh
make -C fpga/arty_a7_35t test-triangulator PYTHON=../../.venv/bin/python
.venv/bin/python fpga/arty_a7_35t/triangulator/test_geometry.py \
  --log fpga/arty_a7_35t/build/hardware-uart.log
```

Native tests use independent, arbitrary-precision Python predicates to check
empty circumcircles, orientation, manifold edges, vertex coverage, Euler's
formula and total convex-hull area. The same checks can validate every complete
mesh captured from the FPGA. Fixtures cover thin boundary triangles,
collinearity, duplicate points and seeded random clouds up to 64 points.
