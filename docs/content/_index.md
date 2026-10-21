+++
title = "fastmem"
+++

Fast `memcpy`, `memmove`, and `memset` for Zig. The kernels are tuned per CPU
model and measured against glibc and compiler-rt on seven EC2 targets.

The guide is still being written. Until it lands:

- The [README](https://github.com/baskingspot/fastmem#readme) covers the API,
  the export layer, and the kernels.
- The [design notes](https://github.com/baskingspot/fastmem/tree/main/docs)
  hold the benchmark contract, the runtime dispatch, and one file per fleet
  measurement.
