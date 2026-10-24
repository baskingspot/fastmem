# ec2bench

The generic harness moved to `baskingspot/infra/harness/` and installs from a
tag. Its contract is `baskingspot/infra/harness/README.md`; the operator
runbook is `baskingspot/infra/docs/runbook.md`. This repository keeps only
`bench/fastmem_bench/` (the adapter) and pins the tag in `bench/pyproject.toml`.
