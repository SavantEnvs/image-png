#!/usr/bin/env bash
#
# mayhem/build.sh — build image-png's cargo-fuzz targets as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus compile the
# upstream cargo test suite (normal flags) so mayhem/test.sh only RUNS it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache; the runtime exports
#     CARGO_NET_OFFLINE=true — so do NOT hard-code `--offline` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# OSS-Fuzz Rust libFuzzer+ASan flags. --cfg fuzzing matches libfuzzer-sys;
# force-frame-pointers aids ASan backtraces.
# Debug-info contract (SPEC §6.2 item 10): DWARF <= 3 on the fuzz binaries.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3}"
# Sanitizer contract: $SANITIZER_FLAGS comes from the base ENV (clang syntax); rustc
# takes -Zsanitizer instead, so map non-empty -> ASan and an EXPLICIT empty -> none.
SANITIZER_FLAGS="${SANITIZER_FLAGS=-fsanitize=address}"
RUST_SANITIZER=""
[ -n "$SANITIZER_FLAGS" ] && RUST_SANITIZER="-Zsanitizer=address"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SANITIZER} ${RUST_DEBUG_FLAGS} -Cforce-frame-pointers"

# DWARF<4 first-CU anchor: rustc's prebuilt ASan runtime ships DWARF-5 and would land
# at .debug_info offset 0. Link a clang -gdwarf-3 anchor object FIRST via a cc-wrapper
# so the first compilation unit is DWARF-3.
ANCHOR_DIR=/tmp/mayhem-dwarf3
mkdir -p "$ANCHOR_DIR"
echo 'int mayhem_dwarf3_anchor(void) { return 0; }' > "$ANCHOR_DIR/anchor.c"
clang -c -gdwarf-3 -O2 -o "$ANCHOR_DIR/anchor.o" "$ANCHOR_DIR/anchor.c"
printf '#!/usr/bin/env bash\nexec cc %s "$@"\n' "$ANCHOR_DIR/anchor.o" > "$ANCHOR_DIR/cc-wrap.sh"
chmod +x "$ANCHOR_DIR/cc-wrap.sh"
export RUSTFLAGS="$RUSTFLAGS -Clinker=$ANCHOR_DIR/cc-wrap.sh"

# Additive cargo-fuzz crate (leaves upstream fuzz/ untouched).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the project's upstream TEST suite too — with NORMAL flags (a clean, non-sanitized build,
# no fuzzing RUSTFLAGS) — so mayhem/test.sh only RUNS it. At this old BASE the dev-dependencies
# include glium/glutin (for examples/show.rs), which do not build on the image's nightly, so the
# suite is built from a scratch copy of the crate (src/ + tests/, Cargo.toml without the example-only
# dev-dependencies); the checkout is left untouched.
TEST_DIR=/tmp/png-test
# Cargo.lock and target/ stay across re-runs: the lock (made by the first, online build) is what lets
# the offline re-run skip the registry index.
mkdir -p "$TEST_DIR"
rm -rf "$TEST_DIR/src" "$TEST_DIR/tests"
cp -r src tests "$TEST_DIR/"
python3 - "$SRC/Cargo.toml" "$TEST_DIR/Cargo.toml" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'\n\[dev-dependencies\.glium\].*?(?=\n\[|\Z)', '\n', s, flags=re.S)
s = re.sub(r'^(getopts|term)\s*=.*\n', '', s, flags=re.M)
open(sys.argv[2], 'w').write(s)
PY
echo "=== cargo test --no-run (normal flags, scratch copy) ==="
(cd "$TEST_DIR" && env -u RUSTFLAGS cargo test --no-run)

echo "build.sh complete"
