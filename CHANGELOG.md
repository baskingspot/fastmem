# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `copy`, `move`, and `set`, generic over the element type, with per-target
  kernels selected at compile time or, on x86_64 without AVX2, at run time.
- The opt-in `exportSymbols()` layer: strong, hidden `memcpy`, `memmove`, and
  `memset` definitions for ELF programs and shared libraries.
- The guard-page correctness suite and the per-target codegen gates.
- The benchmark fleet under `bench/` and `infra/`, and the measurement
  record.

### Fixed

- Two fastmem package copies in one link no longer collide on the hidden
  aarch64 kernel symbols. A consumer copy exports no kernel entry, and every
  kernel assembly label carries the package instance id.
