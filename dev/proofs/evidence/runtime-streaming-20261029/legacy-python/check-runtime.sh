#!/usr/bin/env bash
# Full native checks; each invocation retains its own independent logs.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .data
weaver_run_dir=$(mktemp -d "$PWD/.data/runtime-check-XXXXXXXX")
weaver_go=${WEAVER_GO:-go}
export GOCACHE="$PWD/.data/go-build-cache"
export GOMODCACHE="$PWD/.data/go-mod-cache"
export GOTMPDIR="$PWD/.data/go-tmp"
export GOTOOLCHAIN=local
mkdir -p "$GOCACHE" "$GOMODCACHE" "$GOTMPDIR"
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
run_check go-tests "$weaver_go" test -race ./go/...
run_check go-routing-pbt "$weaver_go" test ./go/internal/routing -run '^$' -fuzz FuzzCeilingNeverExpands -fuzztime=3s -parallel=1
run_check go-decoder-pbt "$weaver_go" test ./go/api/v1 -run '^$' -fuzz FuzzDecoderNeverPanics -fuzztime=3s -parallel=1
run_check go-stream-pbt "$weaver_go" test ./go/internal/streaming -run '^$' -fuzz FuzzMessageBounds -fuzztime=3s -parallel=1
run_check quint-stream-tests quint test dev/proofs/quint/StreamingExecution.qnt --main StreamingExecution --seed 293
run_check quint-stream-safety quint run dev/proofs/quint/StreamingExecution.qnt --main StreamingExecution --invariant safe --max-samples 1000 --max-steps 60 --seed 293
run_check quint-lifecycle-tests quint test dev/proofs/quint/RuntimeLifecycle.qnt --main RuntimeLifecycle --seed 293
run_check quint-lifecycle-safety quint run dev/proofs/quint/RuntimeLifecycle.qnt --main RuntimeLifecycle --invariant safe --max-samples 1000 --max-steps 60 --seed 293
run_check lean-stream elan run leanprover/lean4:v4.34.1 lean dev/proofs/lean/StreamingExecution.lean
run_check cedar-proof-bridge elan run leanprover/lean4:v4.34.1 lake -d dev/proofs/cedar build WeaverPolicyBridge
run_check quint-typecheck quint typecheck dev/proofs/quint/RuntimeAdmission.qnt
run_check quint-tests quint test dev/proofs/quint/RuntimeAdmission.qnt --main RuntimeAdmission --seed 293
run_check quint-safety quint run dev/proofs/quint/RuntimeAdmission.qnt --main RuntimeAdmission --invariant safety --max-samples 1000 --max-steps 50 --seed 293
run_check lean elan run leanprover/lean4:v4.34.1 lean dev/proofs/lean/RuntimeAdmission.lean
run_check go-native-integration "$weaver_go" test -race -tags=integration ./go/dev -run 'TestOriginalTaskProposalReplay|TestStreamProposalToNativeWire' -v
printf 'Evidence: %s\n' "$weaver_run_dir"
exit "$weaver_failed"
