# nia-eth

The Ethernet MAC subsystem for the DCMAC hard block of AMD Versal devices. Segmented MAC
clients are adapted to AXI-Stream ports, a link control module to maintain the link state,
and CSR register blocks.
Example designs are 100G/200G/400G segmented traffic generators and receivers, and similar example design for 100G/200G/400G AXI-Stream traffic.

Target device: AMD Versal with DCMAC, tested on VP1552 FPGA.

Supported line rate:

 - 100GAUI-1 (for 100GBase-R,  106Gbps per lane)
 - 200GAUI-2 (for 200GBase-R2, 106Gbps per lane)
 - 400GAUI-4 (for 400GBase-R4, 106Gbps per lane)

## Requirements

* `make check`: GNU make, bash, Python 3.
* Simulation: cocotb with Verilator 5. `cocotb-config` must be on `PATH`.
* To build image: Vivado 2025.2 and DCMAC licence;
* Programming image: Vivado or Vivado Lab with the JTAG drivers
* The traffic test over JTAG: `xsdb`.


## User's Guide

### 1. Simulation

    make help
    make check                             # self-checking scripts
    make list                              # list the simulation entries
    make sim                               # run all the simulation cases
    NIA_SIM_ARGS="SIM=verilator" make sim  # choose the simulator

    cd sim/seam && python3 run_mutations.py # run mutation of simulation

### 2. Build the image

    source <path to Vivado>/settings64.sh
    make image                             # default: dual 100GAUI-1 with AXIS adaptor and pktgen

    NIA_RATE=200 make image                # dual 200GAUI-2 with AXIS adaptor and pktgen
    NIA_RATE=400 make image                # single 400GAUI-4 with AXIS adaptor and pktgen

    NIA_USR_MHZ=391 make image             # datapath at 390.625 MHz, line rate at every length
    NIA_USR_MHZ=250 make image             # datapath at 250 MHz

    NIA_PKTGEN=seg make image              # dual 100GAUI-1 with segmented pktgen
    NIA_PKTGEN=seg NIA_RATE=200 make image # dual 200GAUI-2 with segmented pktgen
    NIA_PKTGEN=seg NIA_RATE=400 make image # single 400GAUI-4 with segmented pktgen

    make clean

### 3. Program the board

    source <path to Vivado or Vivado Lab>/settings64.sh
    cd example/TU03/hw

    ./program.sh check
    PDI=../../../build/image/tu03_pktgen_dual_top.pdi ./program.sh program

If there are more than one board attached: set `NIA_TARGET` with a substring of its JTAG
cable serial. The scripts will look for the specific board and program the image.

    NIA_TARGET=<cable serial> PDI=<image> ./program.sh program

### 4. Run the traffic source on one port

    source <path to Vivado or Vivado Lab>/settings64.sh
    cd example/TU03/hw
    xsdb pktgen_probe.tcl

    NIA_LEN_MIN=64 NIA_LEN_MAX=64 NIA_FRAMES=100000 \
      xsdb pktgen_probe.tcl                         # fixed pkt size, send 100K pkt

    NIA_LEN_MODE=1 NIA_LEN_MIN=60 NIA_LEN_MAX=9018 \
      xsdb pktgen_probe.tcl                         # send pkt with random size between MIN and MAX

    NIA_WINDOW=<address> NIA_POLLS=<count> \
      xsdb pktgen_probe.tcl                         # poll test status

### 5. Dual-port external loopback test

Connect the two ports with a 112G PAM4 capable DAC. Pktgen client 0 transmits from port 0 and client 1 receives on port 1,
and the reverse at the same time, so both directions are measured at once and each is checked against
the other client's counters.

    source <path to Vivado or Vivado Lab>/settings64.sh
    cd example/TU03/hw
    ./pktgen_dual_run.sh test                            # run test steps 1 to 6
    NIA_STEPS="1 2 3" ./pktgen_dual_run.sh test          # a subset of test steps

Every step prints its readings and `STEP <n> RESULT PASS|FAIL <reason>` line, and the test stops at
the first failure. What each step establishes:

| step | what it does |
|---|---|
| 1 | reads both generator windows and establishes that they are two instances rather than one aliased twice |
| 2 | issues the bring-up restart and times the link falling and both links returning |
| 3 | one clean burst per size in both directions at once, and asserts the transmit counts of one client against the receive counts of the other, with no error frames and no mismatched beats |
| 4 | the rate table at 64, 65, 128, 256, 512, 1024, 1518, 4096 and 9018 bytes |
| 5 | whether the MAC ever back pressured the generator |
| 6 | one repair command to one group while both directions carry traffic, and what the other group's counters did across it |
| 7 | that stopping a burst mid-frame dirties the data path, which is why steps 3 and 4 stop on a frame limit |

Test options:

    NIA_STEPS="1 2 3 4 5 6"                select test steps to run, in this order
    NIA_RATE_SIZES="64 65 128 ... 9018"    the sizes of the rate table, nine by default
    NIA_BURST_SIZES="64 1518 9018"         the sizes of step 3
    NIA_BURST_BYTES=3000000000             bytes per burst per direction, keep under 4 GB
    NIA_RATE_S=3.0                         burst test duration in seconds per each rate
    NIA_BURST_MS=20000                     the timeout of one burst
    NIA_BRINGUP_MS=10000                   how long step 2 waits for both links
    NIA_RESET_GROUP=0                      which group step 6 repairs
    NIA_REPAIR=rxdp                        rxdp, resync or txdp: the repair command step 6 issues
    NIA_WINDOW=0xA4000000                  the base address of the register aperture

`NIA_WINDOW` must be the address the image was built with, which `make image` sets.

### 6. Interconnection test between two FPGA boards

The similar test as external loopback but between two FPGA boards over two DACs. The scripts are located in `example/TU03/hw_twoboard/`.

`NIA_DPC_A` and `NIA_DPC_B` are the serial numbers of JTAG programmer (e.g. Digilent JTAG 210308A1CB76).

    source <path to Vivado or Vivado Lab>/settings64.sh
    cd example/TU03/hw_twoboard

    ./program_twoboard.sh list                      # read the two JTAG cable serials
    SERIAL_A=<serial> SERIAL_B=<serial> \
      ./program_twoboard.sh program ../../../build/image/tu03_pktgen_dual_top.pdi

    NIA_DPC_A=<id> NIA_DPC_B=<id> xsdb pktgen_twoboard_link.tcl   # bring the link up, steps 1 to 3
    NIA_DPC_A=<id> NIA_DPC_B=<id> xsdb pktgen_twoboard_wire.tcl   # run test, steps 1 to 4

More test options:

    NIA_STEPS="1 2 3 4"          which steps to run, in this order
    NIA_CLIENTS=1                a one client image. Client 1 is never read
    NIA_SIZES="64 65 128 ..."    the sizes of the rate table
    NIA_EQ_SIZES="64 1518 9018"  the sizes of step 3
    NIA_EQ_BYTES=3000000000      bytes per burst per direction in step 3, keep under 4 GB
    NIA_WARMUP_BYTES=100000000   bytes per direction in the discarded warm-up burst
    NIA_RATE_S=3.0               seconds per rate burst
    NIA_BURST_MS=30000           the timeout of one burst
    NIA_BRINGUP_MS=8000          how long step 2 of the link check waits for every link
    NIA_SETTLE_MS=1500           how long every link must hold before the link is called up
    NIA_OBSERVE_MS=5000          the quiet observation of step 3 of the link check
    NIA_ALLOW_MIXED=1            measure one instrument against the other on purpose

At 400GAUI-4 there is only one pktgen client for port 0, so `NIA_CLIENTS=1` is required.

#### Packet size sweeping test

`sweep_twoboard.sh` sweeps the frame length (pkt size) from `NIA_IMIN` to `NIA_IMAX` inclusive, one burst per pkt size, and writes a per pkt size result table beside the log. It reads `<top>.image_props.txt`, which `make image` writes beside the device image, so the cage count and the frame length range match the image being programmed. `sweep_all.sh` runs it over every image in the directory.

    source <path to Vivado or Vivado Lab>/settings64.sh
    cd example/TU03/hw_twoboard

    ./program_twoboard.sh list                      # read the two JTAG cable serials

    SERIAL_A=<serial> SERIAL_B=<serial> \
      ./sweep_twoboard.sh ../../../build/image/tu03_axispg_dual_top.pdi

    SERIAL_A=<serial> SERIAL_B=<serial> \
      ./test_axis.sh rate                           # the rate table, byte exact
    SERIAL_A=<serial> SERIAL_B=<serial> \
      ./test_axis.sh sweep                          # every length 64 to 9018
    SERIAL_A=<serial> SERIAL_B=<serial> NIA_ISTEP=97 NIA_RATES=400 \
      ./test_axis.sh sweep                          # a short sweep of one rate
    SERIAL_A=<serial> SERIAL_B=<serial> \
      ./sweep_all.sh                                # sweep every image in build/image

The default `NIA_IMAX` is 9018 and `NIA_EQ_BYTES` is 15000000. The test prints `SWEEP RESULT PASS`
only when every pkt size has exact same RX bytes comparing to TX bytes.

`SERIAL_A` and `SERIAL_B` are required and must differ.

### 7. Link state and a cable event

Link state monitor will watch the state of link and cable events of plug-out and plug-in.

    source <path to Vivado or Vivado Lab>/settings64.sh
    cd example/TU03/hw
    NIA_DURATION_S=1800 ./pktgen_dual_run.sh monitor-detached

    ./pktgen_dual_run.sh stop

    NIA_AUTO_RESTART=1 NIA_RESTART_AFTER_MS=5000 \
      ./pktgen_dual_run.sh monitor              # issue a bring-up restart if the link is down

Monitor options:

    NIA_WAIT_MS=500              the link polling interval in ms
    NIA_DURATION_S=600           how long to watch, 0 - watches until stopped
    NIA_LEN=512                  frame length of the load the monitor runs
    NIA_BURST_BYTES=3000000000   bytes in one burst
    NIA_BURST_MS=10000           burst timeout in ms
    NIA_AUTO_RESTART=0           1 - issues a bring-up restart when the link is down
    NIA_RESTART_AFTER_MS=3000    how long the link must be down before a restart

### 8. Link quality and the forward error correction counters

The link quality monitor samples the command window, the per port PHY status behind the statistics
snapshot and both generator windows, prints one line per sample, reports every link and alignment
transition as it happens, and prints a summary when it stops.

    source <path to Vivado or Vivado Lab>/settings64.sh
    cd example/TU03/hw
    ./pktgen_dual_run.sh linkmon                          # 60 s at the default interval

    NIA_MON_DUR_S=1800 NIA_MON_S=5 \
      ./pktgen_dual_run.sh linkmon-detached               # a 30 minute soak, detached

    ./pktgen_dual_run.sh stop

    NIA_MON_CSV=/tmp/linkmon.csv ./pktgen_dual_run.sh linkmon   # one row a sample as well

Link quality monitor options:

    NIA_MON_S=2                  seconds between samples
    NIA_MON_DUR_S=60             seconds to run, 0 runs until stopped
    NIA_MON_LEN=1518             frame length of the load the monitor runs
    NIA_MON_LOAD=1               0 observes only and starts no traffic
    NIA_MON_CSV=<path>           also write one comma separated row a sample
