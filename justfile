# fastmem: fast memcpy, memmove, and memset for Zig. README.md is the user
# overview; AGENTS.md holds the working notes; docs/bench-design.md describes
# the benchmark system.

[private]
default:
    @just --list

[doc("Unit tests, the export-layer checks, and the shipped-binary builds")]
[group("test")]
test:
    zig build test

[doc("The export-layer binary checks alone (docs/export-layer.md)")]
[group("test")]
test-export:
    zig build test-export

[doc("The full guard-page correctness matrix on this host (G1)")]
[group("test")]
test-guard:
    zig build test-guard -Doptimize=ReleaseFast

[doc("x86 codegen gates for all fleet CPU models (runs on any host)")]
[group("test")]
codegen-x86:
    zig build codegen-x86

[doc("Fuzz with an iteration budget, for example `just fuzz 50M`. ReleaseSafe forces the LLVM backend, dodging the 0.16.0 self-hosted-backend bug in Debug fuzz mode (ziglang/zig#30655)")]
[group("test")]
fuzz LIMIT="10M":
    zig build test -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src build.zig
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md docs/content docs/static .github wrangler.jsonc docs/config.toml .oxfmtrc.jsonc
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md docs/content docs/static .github wrangler.jsonc docs/config.toml .oxfmtrc.jsonc
    just --fmt

[doc("Everything the main CI job runs: tests, lint, codegen, the bench harness checks, the OpenTofu modules, and the site")]
[group("ci")]
ci: test lint codegen-x86 bench-check doc

[doc("Build the site into zig-out/site/fastmem/ from docs/")]
[group("docs")]
doc: api
    baskingspot-docs build fastmem

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve fastmem

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title fastmem --repo-url https://github.com/baskingspot/fastmem --rev main --format json --out docs/data

[doc("Deploy the rendered site to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Regenerate the light and dark benchmark charts in docs/static/ from the scorecard (uses the bench dev environment)")]
[group("bench")]
plot:
    uv run --project bench python bench/plot_scorecard.py

[doc("Run the measurement binary on this host (e.g. just bench --suite quick --filter copy/aligned)")]
[group("bench")]
bench *ARGS:
    zig build bench -- {{ ARGS }}

[doc("Emit assembly and LLVM IR for the native (or -Dtarget) target into zig-out/asm/")]
[group("bench")]
asm *ARGS:
    zig build asm {{ ARGS }}
    @ls zig-out/asm/

[doc("Emit assembly for the linux-gnu/musl and macOS triples")]
[group("bench")]
asm-all:
    zig build asm-all
    @ls zig-out/asm/

[doc("Show one function from the native assembly (e.g. just show-fn fastmem_copy)")]
[group("bench")]
show-fn FN:
    @grep -A 80 '{{ FN }}:' zig-out/asm/*.s

[doc("Compare assembly between two triples (run asm-all first)")]
[group("bench")]
diff-asm A B:
    diff --color zig-out/asm/{{ A }}.s zig-out/asm/{{ B }}.s || true

[doc("Remove build artifacts")]
[group("build")]
clean:
    rm -rf zig-out .zig-cache

# Benchmark fleet: the bench/ adapter (docs/bench-design.md). The fleet and the
# generic harness live in baskingspot/infra.
# Every fleet command runs as the fastmem-bench IAM user.
export AWS_PROFILE := env("AWS_PROFILE", "fastmem-bench")

[doc("Run any harness command (e.g. just b ls, just b up c8g c7i --ttl 2h, just b analyze <run-dir>)")]
[group("fleet")]
b *ARGS:
    uv run --project bench bench {{ ARGS }}

[doc("Launch boxes (e.g. just bench-up c8g c7i, or just bench-up for every target)")]
[group("fleet")]
bench-up *TARGETS:
    uv run --project bench bench up {{ if TARGETS == "" { "c7i c8i c7a c8a c7g c8g c9g" } else { TARGETS } }}

[doc("Terminate every box of this project")]
[group("fleet")]
bench-down:
    uv run --project bench bench down --all

[doc("Show the fleet")]
[group("fleet")]
bench-ls:
    uv run --project bench bench ls

[doc("Correctness on every running box (e.g. just bench-test --optimize ReleaseFast --optimize Debug)")]
[group("fleet")]
bench-test *ARGS:
    uv run --project bench bench test {{ ARGS }}

[doc("Measure on every running box (e.g. just bench-run --rev main --rev WORKTREE --suite standard)")]
[group("fleet")]
bench-run *ARGS:
    uv run --project bench bench run {{ ARGS }}

[doc("Harness checks: tests, lint, format, types")]
[group("fleet")]
bench-check:
    cd bench && uv run pytest -q && uv run ruff check . && uv run ruff format --check . && uv run ty check

