#!/usr/bin/env bash
# Linux CI (A3): the same steps on GitHub Actions (.github/workflows/) and in a Linux or WSL checkout.
#   bash tools/build/ci_linux.sh [step...]   steps: build fork-tests client-tests live-test perf perf-live (default: all)
# TSAN=1: ThreadSanitizer build of the fork's tests (preset fp3d-linux-tsan) and a run with
# tools/build/tsan.supp. No bridge then: Godot isn't instrumented, so the .so couldn't load under TSan.
# Needs: the Linux packages of docs/BUILD.md step 5 (ccache is used when installed), bridge/godot-cpp for the
# bridge, and GODOT=<Godot 4.7.2 Linux editor> for the client steps. JOBS=<n> overrides the job count.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
die() { echo "ci_linux.sh: $*" >&2; exit 1; }

preset=fp3d-linux
[ -z "${TSAN:-}" ] || preset=fp3d-linux-tsan
bin="out/build/$preset"   # relative to cdda/
tests=(fp3d-sim-test fp3d-snapshot-test fp3d-events-test fp3d-ids-test fp3d-chargen-test)
# CDDA's big files take ~2 GB each to compile (more under TSan): more jobs than memory allows get killed.
mem_gb=$(awk '/MemTotal/ { print int($2 / 1048576) }' /proc/meminfo)
per_job=2; [ -z "${TSAN:-}" ] || per_job=3
jobs=$(( mem_gb / per_job )); [ "$jobs" -ge 1 ] || jobs=1; [ "$jobs" -le "$(nproc)" ] || jobs=$(nproc)
jobs="${JOBS:-$jobs}"
failed=()

step_build() {
    [ -f cdda/CMakeLists.txt ] || die "cdda/ is empty (git submodule update --init)"
    cp tools/build/CMakeUserPresets.json cdda/
    local targets=("${tests[@]}")
    if [ -z "${TSAN:-}" ]; then
        [ -f bridge/godot-cpp/CMakeLists.txt ] || die "no bridge/godot-cpp (docs/BUILD.md step 5)"
        targets+=(fp3d-cdda)
    fi
    (cd cdda && cmake --preset "$preset" >/dev/null && cmake --build "$bin" --parallel "$jobs" --target "${targets[@]}")
}

step_fork_tests() {
    local run=()
    if [ -n "${TSAN:-}" ]; then
        # halt_on_error=0: report every race of a run; exitcode makes any report fail the test.
        export TSAN_OPTIONS="suppressions=$root/tools/build/tsan.supp halt_on_error=0 exitcode=66 second_deadlock_stack=1"
        # TSan's shadow memory needs the old mmap layout; newer kernels randomise too much (no root needed).
        run=(setarch "$(uname -m)" -R)
    fi
    for t in "${tests[@]}"; do
        echo "== $t"
        local s=0
        (cd cdda && timeout "${TEST_TIMEOUT:-1800}" "${run[@]}" "$bin/src/fp3d/$t") || s=$?
        [ "$s" -eq 0 ] || { echo "== $t FAILED (exit $s)"; failed+=("$t"); }
    done
}

godot_ok() {
    [ -n "${GODOT:-}" ] && [ -x "$GODOT" ] || die "set GODOT to Godot 4.7.2's Linux editor"
    # Import once per checkout (Godot's .godot/ cache); run_tests needs the imported resources.
    if [ ! -d client/.godot/imported ]; then
        "$GODOT" --headless --path client --import >/dev/null 2>&1 || true
    fi
}

step_client_tests() {
    godot_ok
    local s=0
    "$GODOT" --headless --path client --script res://tests/run_tests.gd || s=$?
    [ "$s" -eq 0 ] || failed+=(run_tests)
}

step_live_test() {
    godot_ok
    [ -f client/bin/fp3d_cdda.linux.x86_64.so ] || die "no bridge in client/bin (step build)"
    local s=0
    timeout "${TEST_TIMEOUT:-1800}" "$GODOT" --headless --path client --script res://tests/live_test.gd || s=$?
    [ "$s" -eq 0 ] || failed+=(live_test)
}

# Performance budget (client/tests/snapshot_bench.gd). PERF_SCALE multiplies the budgets: shared CI runners
# are slower and noisier than the dev PC the budgets were set on.
step_perf() {
    godot_ok
    local s=0 live=()
    [ "${1:-}" != live ] || { [ -f client/bin/fp3d_cdda.linux.x86_64.so ] || die "no bridge in client/bin"; live=(--live); }
    timeout "${TEST_TIMEOUT:-1800}" "$GODOT" --headless --path client --script res://tests/snapshot_bench.gd -- \
        "${live[@]}" --budget-scale="${PERF_SCALE:-1}" || s=$?
    [ "$s" -eq 0 ] || failed+=("perf${live:+-live}")
}

[ $# -gt 0 ] || { set -- build fork-tests; [ -n "${TSAN:-}" ] || set -- build fork-tests client-tests live-test perf perf-live; }
for step in "$@"; do
    case "$step" in
        build) step_build ;;
        fork-tests) step_fork_tests ;;
        client-tests) step_client_tests ;;
        live-test) [ -z "${TSAN:-}" ] || die "live-test can't run under TSAN"; step_live_test ;;
        perf) step_perf ;;
        perf-live) [ -z "${TSAN:-}" ] || die "perf-live can't run under TSAN"; step_perf live ;;
        *) die "unknown step $step" ;;
    esac
done
if [ ${#failed[@]} -gt 0 ]; then
    echo "ci_linux.sh: FAILED: ${failed[*]}" >&2
    exit 1
fi
echo "ci_linux.sh: all passed ($*)"
