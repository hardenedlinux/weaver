#!/usr/bin/env bash
# Full native checks; each invocation retains its own independent logs.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .data
weaver_run_dir=$(mktemp -d "$PWD/.data/runtime-check-XXXXXXXX")
weaver_go=${WEAVER_GO:-go}
export GOCACHE="$PWD/.data/go-build-cache"
export GOTMPDIR="$PWD/.data/go-tmp"
mkdir -p "$GOCACHE" "$GOTMPDIR"
weaver_failed=0
run_check() {
  local label=$1
  shift
  if "$@" > "$weaver_run_dir/$label.log" 2>&1; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s: %s/%s.log\n' "$label" "$weaver_run_dir" "$label"
    weaver_failed=1
  fi
}
run_check rust-format cargo fmt --all -- --check
run_check rust-tests cargo test --workspace --locked --offline
run_check rust-clippy cargo clippy --workspace --all-targets --locked --offline -- -D warnings
run_check go-tests "$weaver_go" test -race ./...
run_check go-routing-pbt "$weaver_go" test ./control/routing -run '^$' -fuzz FuzzCeilingNeverExpands -fuzztime=3s -parallel=1
run_check go-decoder-pbt "$weaver_go" test ./control/contract -run '^$' -fuzz FuzzDecoderNeverPanics -fuzztime=3s -parallel=1
run_check sysml sysml -strict -validate models/sysml/WeaverExecution.sysml
run_check quint-typecheck quint typecheck proofs/qunit/RuntimeAdmission.qnt
run_check quint-tests quint test proofs/qunit/RuntimeAdmission.qnt --main RuntimeAdmission --seed 293
run_check quint-safety quint run proofs/qunit/RuntimeAdmission.qnt --main RuntimeAdmission --invariant safety --max-samples 1000 --max-steps 50 --seed 293
run_check lean elan run leanprover/lean4:v4.34.1 lean proofs/lean/RuntimeAdmission.lean
run_check trace python3 scripts/check-runtime-trace.py
run_check cross-language env WEAVER_GO="$weaver_go" python3 scripts/replay-local-owner.py
printf 'Evidence: %s\n' "$weaver_run_dir"
exit "$weaver_failed"
