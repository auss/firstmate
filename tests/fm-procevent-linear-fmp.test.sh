#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-linear-fmp.sh against fake triage
# checkouts (current and legacy package layouts) that implement the
# poll/ready/receipt CLI contract. No network, no model calls, no Telegram.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/bin"
LAB=$(fm_test_tmproot fm-procevent-linear-fmp)
export FM_HOME="$LAB"
FM_LFP="$BIN/fm-procevent-linear-fmp.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$BIN/fm-timeout-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

# Fake triage package: poll honors FAKE_POLL_RC, ready cats FAKE_READY_FILE,
# receipt records into FAKE_RECEIPTS. This is the public CLI surface the real
# adapter runs, exercised without any live source.
make_fake_triage() {  # <dir> [package]
  local pkg=${2:-fmp_triage}
  mkdir -p "$1/$pkg"
  printf '"""fake triage package for adapter tests"""\n' > "$1/$pkg/__init__.py"
  cat > "$1/$pkg/cli.py" <<'PY'
import json
import os
import sys

def main():
    args = sys.argv[1:]
    command = args[0] if args else ""
    if command == "poll":
        rc = int(os.environ.get("FAKE_POLL_RC", "0"))
        if rc:
            print("scan failed, nothing inferred this pass: linear unreachable", file=sys.stderr)
        else:
            print("poll: scanned=3 evaluated=1 ready=1")
        return rc
    if command == "ready":
        rc = int(os.environ.get("FAKE_READY_RC", "0"))
        if rc:
            print("outbox read failed: permission denied", file=sys.stderr)
            return rc
        path = os.environ.get("FAKE_READY_FILE", "")
        receipts = os.environ.get("FAKE_RECEIPTS", "")
        closed = set()
        if receipts and os.path.exists(receipts):
            with open(receipts) as handle:
                closed = {line.strip() for line in handle if line.strip()}
        if path and os.path.exists(path):
            with open(path) as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        if json.loads(line).get("delivery_id") in closed:
                            continue
                    except ValueError:
                        pass
                    print(line.rstrip("\n"))
        return 0
    if command == "receipt":
        delivery = args[1]
        receipts = os.environ.get("FAKE_RECEIPTS", "")
        seen = []
        if receipts and os.path.exists(receipts):
            with open(receipts) as handle:
                seen = [line.strip() for line in handle if line.strip()]
        if delivery in seen:
            print(f"receipt already recorded for {delivery}")
        else:
            if receipts:
                with open(receipts, "a") as handle:
                    handle.write(delivery + "\n")
            print(f"receipt recorded for {delivery}")
        return 0
    print(f"unsupported command: {command}", file=sys.stderr)
    return 1

sys.exit(main())
PY
}

TRIAGE="$LAB/triage"
make_fake_triage "$TRIAGE"
READY_FILE="$LAB/ready.jsonl"
RECEIPTS="$LAB/receipts.txt"
: > "$READY_FILE"
export FAKE_READY_FILE="$READY_FILE"
export FAKE_RECEIPTS="$RECEIPTS"
unset FAKE_POLL_RC || true

EVENT_ONE='{"schema_version":1,"kind":"fmp_linear_agent_ready","delivery_id":"fmp:uuid-42:hash-one:readiness-v1","issue":{"id":"uuid-42","url":"https://linear.app/kucharski-ai/issue/FMP-42/aaaa","title":"Milk becomes unchecked after reload","what_wrong":"check milk, reload","intended":"stays checked","page_path":"/plan","evidence_omitted":["attachments"]},"evaluation":{"score":1,"probability":0.93,"policy_version":"readiness-v1","trace_id":"trace-1"}}'
EVENT_TWO='{"schema_version":1,"kind":"fmp_linear_agent_ready","delivery_id":"fmp:uuid-43:hash-two:readiness-v1","issue":{"id":"uuid-43","url":"https://linear.app/kucharski-ai/issue/FMP-43/bbbb","title":"Two-day split missing dinner","what_wrong":"dinner missing","intended":"both meals","page_path":"/week","evidence_omitted":[]},"evaluation":{"score":1,"probability":0.97,"policy_version":"readiness-v1","trace_id":"trace-2"}}'
JOURNAL_DIR="$LAB/state/linear-fmp"

if out=$("$FM_LFP" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
[ "$(printf '%s\n' "$out" | grep -cF 'fm-procevent-linear-fmp.sh arm')" = 1 ] \
  || fail "help omitted the arm usage"
if printf '%s\n' "$out" | grep -q '^set -u$'; then
  fail "help leaked executable source"
fi
ok "help renders only the complete header"

[ "$("$FM_LFP" source-id)" = linear-fmp ] || fail "source-id mismatch"
ok "source-id prints the canonical id"

# arm: default root resolution, real registration, then retire.
mkdir -p "$LAB/projects"
make_fake_triage "$LAB/projects/fmp-bugpin-triage" fmp_bugpin_triage
arm_out=$(FM_LINEAR_FMP_ROOT='' "$FM_LFP" arm --interval 60) || fail "arm failed: $arm_out"
printf '%s\n' "$arm_out" | grep -qx 'armed: linear-fmp' || fail "arm did not report armed"
printf '%s\n' "$arm_out" | grep -q 'never spawns ships' \
  || fail "arm omitted the no-dispatch reminder"
if ! FM_HOME="$LAB" "$BIN/fm-procevent.sh" list 2>/dev/null | grep -q 'linear-fmp'; then
  fail "registration missing from fm-procevent list"
fi
"$FM_LFP" retire >/dev/null 2>&1 || fail "retire failed"
if FM_HOME="$LAB" "$BIN/fm-procevent.sh" list 2>/dev/null | grep -q 'linear-fmp'; then
  fail "retire left the registration armed"
fi
ok "arm registers through the generic runner and retire disarms"

# arm refuses a checkout without the package.
mkdir -p "$LAB/empty-root"
if "$FM_LFP" arm --root "$LAB/empty-root" 2>/dev/null; then
  fail "arm accepted a checkout with no triage package"
fi
ok "arm refuses a checkout without the triage package"

# Root resolution regression: the renamed checkout wins while both exist,
# the legacy checkout still resolves alone, and an explicit --root carrying
# neither layout is refused instead of silently falling back.
make_fake_triage "$LAB/projects/fmp-triage" fmp_triage
arm_out=$(FM_LINEAR_FMP_ROOT='' "$FM_LFP" arm --interval 60) \
  || fail "arm failed with the renamed checkout present: $arm_out"
printf '%s\n' "$arm_out" | grep -qx "root: $LAB/projects/fmp-triage" \
  || fail "arm did not prefer the renamed checkout"
"$FM_LFP" retire >/dev/null 2>&1 || fail "retire failed"
rm -rf "$LAB/projects/fmp-triage"
arm_out=$(FM_LINEAR_FMP_ROOT='' "$FM_LFP" arm --interval 60) \
  || fail "arm failed with only the legacy checkout present: $arm_out"
printf '%s\n' "$arm_out" | grep -qx "root: $LAB/projects/fmp-bugpin-triage" \
  || fail "arm no longer resolves the legacy checkout"
"$FM_LFP" retire >/dev/null 2>&1 || fail "retire failed"
mkdir -p "$LAB/neither-root"
if arm_err=$("$FM_LFP" arm --root "$LAB/neither-root" 2>&1); then
  fail "arm silently fell back from a neither-layout --root"
fi
printf '%s\n' "$arm_err" | grep -q "triage checkout is unavailable: $LAB/neither-root" \
  || fail "arm error did not name the refused checkout"
ok "root resolution prefers the renamed checkout, keeps the legacy one, and refuses neither-layout"

# The command only arms when every runtime dependency for delivery exists.
make_tool_path() {  # <dir> [extra command...]
  local dir=$1 tool
  shift
  mkdir -p "$dir"
  for tool in bash dirname python3 mktemp sleep cat rm "$@"; do
    ln -s "/usr/bin/$tool" "$dir/$tool"
  done
}

NO_JQ_PATH="$LAB/no-jq-path"
make_tool_path "$NO_JQ_PATH"
if env PATH="$NO_JQ_PATH" FM_TIMEOUT_MECHANISM_OVERRIDE=bash "$FM_LFP" arm --root "$TRIAGE" 2>&1 \
  | grep -q 'jq is not available'; then
  :
else
  fail "arm did not reject a missing jq"
fi

NO_SHA_PATH="$LAB/no-sha-path"
make_tool_path "$NO_SHA_PATH" jq
if env PATH="$NO_SHA_PATH" FM_TIMEOUT_MECHANISM_OVERRIDE=bash "$FM_LFP" arm --root "$TRIAGE" 2>&1 \
  | grep -q 'shasum or sha256sum is not available'; then
  :
else
  fail "arm did not reject a missing SHA provider"
fi
ok "arm verifies ready delivery dependencies"

# poll: one ready event per capture, with journal suppression and replay.
printf '%s\n%s\n' "$EVENT_ONE" "$EVENT_TWO" > "$READY_FILE"
poll_out=$(fm_run_timed 60 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --replay 3600) \
  || fail "poll exited nonzero on an available ready event"
printf '%s\n' "$poll_out" | grep -qx 'status: ready' || fail "poll did not report ready"
printf '%s\n' "$poll_out" | grep -qx 'delivery_id: fmp:uuid-42:hash-one:readiness-v1' \
  || fail "poll did not surface the oldest unreceipted event"
[ "$(printf '%s\n' "$poll_out" | grep -c '^ready: ')" = 1 ] \
  || fail "poll emitted more than one ready payload"
printf '%s\n' "$poll_out" | grep -q '^poll_summary: poll: scanned=' \
  || fail "poll omitted the bounded poll summary"
journal_count=$(find "$JOURNAL_DIR" -maxdepth 1 -type f -name '*.emitted' -print | wc -l)
[ "$journal_count" = 1 ] \
  || fail "poll did not journal its emission"
ok "poll captures exactly one ready event per result"

# The same delivery is suppressed inside the replay window and replays after it.
printf '%s\n' "$EVENT_ONE" > "$READY_FILE"
suppressed=$(fm_run_timed 5 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --replay 3600)
suppressed_rc=$?
[ "$suppressed_rc" = 124 ] || fail "suppressed poll exited $suppressed_rc instead of timing out"
[ -z "$suppressed" ] || fail "suppressed poll emitted output inside the replay window"
ok "poll stays silent inside the replay window"

journal=$(find "$JOURNAL_DIR" -maxdepth 1 -type f -name '*.emitted' -print -quit)
[ -n "$journal" ] || fail "no journal file to age"
printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$journal"
replay_out=$(fm_run_timed 60 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --replay 3600) \
  || fail "replay poll exited nonzero"
printf '%s\n' "$replay_out" | grep -qx 'delivery_id: fmp:uuid-42:hash-one:readiness-v1' \
  || fail "aged journal did not replay the same delivery"
ok "poll replays the same delivery after the replay window"

# After receipting the first event, the next capture surfaces the second one.
FM_HOME="$LAB" "$FM_LFP" receipt 'fmp:uuid-42:hash-one:readiness-v1' --root "$TRIAGE" >/dev/null \
  || fail "receipt failed on the first delivery"
[ -s "$RECEIPTS" ] || fail "receipt did not reach the fake outbox"
[ -z "$(ls -1 "$JOURNAL_DIR" 2>/dev/null)" ] || fail "receipt left the journal behind"
printf '%s\n%s\n' "$EVENT_ONE" "$EVENT_TWO" > "$READY_FILE"
next_out=$(fm_run_timed 60 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --replay 3600) \
  || fail "poll after receipt exited nonzero"
printf '%s\n' "$next_out" | grep -qx 'delivery_id: fmp:uuid-43:hash-two:readiness-v1' \
  || fail "poll did not advance to the next unreceipted event"
ok "receipt closes a delivery and poll advances to the next"

# receipt is idempotent through the fake outbox.
FM_HOME="$LAB" "$FM_LFP" receipt 'fmp:uuid-42:hash-one:readiness-v1' --root "$TRIAGE" \
  | grep -q 'receipt already recorded' || fail "repeat receipt was not idempotent"
ok "receipt is idempotent"

# Operational failure past the budget captures one terminal error result.
: > "$READY_FILE"
error_out=$(FAKE_POLL_RC=2 fm_run_timed 60 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --replay 3600 --error-budget 2) \
  || fail "error-budget poll exited nonzero"
printf '%s\n' "$error_out" | grep -qx 'status: error' || fail "budget exhaustion did not report error"
printf '%s\n' "$error_out" | grep -q '^error: .*linear unreachable' \
  || fail "error result omitted the bounded cause"
printf '%s\n' "$error_out" | grep -qx 'poll_failures: 2' || fail "error result miscounted failures"
printf '%s\n' "$error_out" | grep -qx 'last_exit: 2' || fail "error result misreported the exit"
unset FAKE_POLL_RC
ok "repeated poller failure captures one typed operational error"

# A ready/outbox failure must retain its own diagnostic, not poll's success.
ready_error_out=$(FAKE_READY_RC=3 fm_run_timed 60 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --replay 3600 --error-budget 2) \
  || fail "ready error-budget poll exited nonzero"
printf '%s\n' "$ready_error_out" | grep -q '^error: .*outbox read failed' \
  || fail "ready error result omitted the outbox cause"
printf '%s\n' "$ready_error_out" | grep -qx 'last_exit: 3' \
  || fail "ready error result misreported the exit"
ok "repeated ready failure captures its operational cause"

rm -rf "$JOURNAL_DIR"
: > "$RECEIPTS"
printf '%s\n' "$EVENT_ONE" > "$READY_FILE"
for attempt in 1 2 3 4 5; do
  replay_failure_out=$(FAKE_POLL_RC=2 fm_run_timed 30 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 3600 --replay 1800 --error-budget 5) \
    || fail "replayed failure attempt $attempt exited nonzero"
  if [ "$attempt" -lt 5 ]; then
    printf '%s\n' "$replay_failure_out" | grep -qx 'status: ready' \
      || fail "replayed failure attempt $attempt did not preserve ready delivery"
    journal=$(find "$JOURNAL_DIR" -maxdepth 1 -type f -name '*.emitted' -print -quit)
    [ -n "$journal" ] || fail "replayed failure attempt $attempt did not journal delivery"
    printf '%s\n' "$(( $(date +%s) - 1801 ))" > "$journal"
  fi
done
printf '%s\n' "$replay_failure_out" | grep -qx 'status: error' \
  || fail "replayed ready delivery reset the poll failure budget"
printf '%s\n' "$replay_failure_out" | grep -qx 'poll_failures: 5' \
  || fail "replayed ready delivery miscounted poll failures"
unset FAKE_POLL_RC
ok "replayed ready delivery preserves the poll failure budget"

"$FM_LFP" arm --root "$TRIAGE" --interval 1 --error-budget 2 >/dev/null \
  || fail "re-arm after terminal failure failed"
rearmed_failure_out=$(FAKE_POLL_RC=2 fm_run_timed 60 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --replay 3600 --error-budget 2) \
  || fail "re-armed error-budget poll exited nonzero"
printf '%s\n' "$rearmed_failure_out" | grep -qx 'poll_failures: 2' \
  || fail "re-arm inherited the prior terminal failure count"
unset FAKE_POLL_RC
ok "re-arm starts with a fresh poll failure budget"

# Re-arming an active source preserves the current failure episode.
printf '1\n' > "$JOURNAL_DIR/.failures"
rm -f "$JOURNAL_DIR"/*.emitted
printf '%s\n' "$EVENT_ONE" > "$READY_FILE"
"$FM_LFP" arm --root "$TRIAGE" --interval 3600 --replay 1800 --error-budget 2 >/dev/null \
  || fail "active re-arm failed"
active_rearm_out=$(FAKE_POLL_RC=2 fm_run_timed 30 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 3600 --replay 1800 --error-budget 2) \
  || fail "active re-arm poll exited nonzero"
printf '%s\n' "$active_rearm_out" | grep -qx 'status: error' \
  || fail "active re-arm reset the failure budget"
unset FAKE_POLL_RC
ok "active re-arm preserves the poll failure budget"

# classify, terminal, and read over captured result documents.
INBOX="$LAB/state/procevent-inbox"
mkdir -p "$INBOX"
printf '%s\n' "$poll_out" > "$INBOX/linear-fmp.7.result"
printf '%s\n' "$error_out" > "$INBOX/linear-fmp.8.result"
[ "$("$FM_LFP" classify "$INBOX/linear-fmp.7.result")" = ready ] || fail "classify misread ready"
[ "$("$FM_LFP" classify "$INBOX/linear-fmp.8.result")" = error ] || fail "classify misread error"
printf 'garbage\n' > "$LAB/garbage.result"
[ "$("$FM_LFP" classify "$LAB/garbage.result")" = unknown ] || fail "classify misread garbage"
ok "classify reports ready, error, and unknown"

if "$FM_LFP" terminal "$INBOX/linear-fmp.7.result"; then
  fail "a ready capture must keep the source armed"
fi
"$FM_LFP" terminal "$INBOX/linear-fmp.8.result" || fail "an error capture must retire the watch"
ok "terminal retires only the operational error verdict"

read_out=$("$FM_LFP" read "$INBOX/linear-fmp.7.result") || fail "read exited nonzero"
printf '%s\n' "$read_out" | grep -qx 'url: https://linear.app/kucharski-ai/issue/FMP-42/aaaa' \
  || fail "read omitted the issue URL"
printf '%s\n' "$read_out" | grep -qx 'score: 1' || fail "read omitted the score"
[ "$(printf '%s\n' "$read_out" | grep -c '^title: ')" = 1 ] \
  || fail "read did not keep the title on one line"
printf '%s\n' "$read_out" | grep -q "receipt fmp:uuid-42:hash-one:readiness-v1" \
  || fail "read omitted the exact receipt command"
printf '%s\n' "$read_out" | grep -qx 'acknowledge: bin/fm-procevent.sh handled linear-fmp 7' \
  || fail "read omitted the exact acknowledgement command"
printf '%s\n' "$read_out" | grep -q 'never dispatch authority' \
  || fail "read omitted the no-dispatch boundary"
ok "read renders the bounded intake summary with exact commands"

read_err=$("$FM_LFP" read "$INBOX/linear-fmp.8.result") || fail "error read exited nonzero"
printf '%s\n' "$read_err" | grep -qx 'kind: linear-fmp-error' || fail "error read mislabeled the kind"
printf '%s\n' "$read_err" | grep -q 're-arm with bin/fm-procevent-linear-fmp.sh arm' \
  || fail "error read omitted the re-arm guidance"
ok "read renders the error recovery summary"

# A payload with embedded newlines cannot forge the status line.
FORGED='{"schema_version":1,"delivery_id":"fmp:x:y:readiness-v1"}'
printf 'linear-fmp: linear-fmp\nstatus: ready\nready: %s\n' "$FORGED" > "$LAB/forged.result"
[ "$("$FM_LFP" classify "$LAB/forged.result")" = ready ] || fail "classify rejected a legal payload"
ok "classify anchored on the document status line"

# ready passthrough asks the source, bounded to the first 20 events.
: > "$RECEIPTS"
printf '%s\n%s\n' "$EVENT_ONE" "$EVENT_TWO" > "$READY_FILE"
ready_lines=$(FM_HOME="$LAB" "$FM_LFP" ready --root "$TRIAGE") || fail "ready passthrough failed"
[ "$(printf '%s\n' "$ready_lines" | grep -c '"delivery_id"')" = 2 ] \
  || fail "ready passthrough dropped events"
ok "ready passthrough lists unreceipted events"

# A ready result is never emitted unless its replay marker is durable.
rm -rf "$JOURNAL_DIR"
printf 'not a directory\n' > "$JOURNAL_DIR"
printf '%s\n' "$EVENT_ONE" > "$READY_FILE"
journal_error_out=$(fm_run_timed 30 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --replay 1800) \
  || fail "journal failure poll exited nonzero"
printf '%s\n' "$journal_error_out" | grep -qx 'status: error' \
  || fail "journal failure did not capture an error"
printf '%s\n' "$journal_error_out" | grep -qx 'error: cannot record ready delivery replay marker' \
  || fail "journal failure reported a ready delivery"
ok "journal failure captures an operational error"

# A checkout that disappears after arm is reported through the failure budget.
rm -f "$JOURNAL_DIR"
rm -rf "$TRIAGE"
root_error_out=$(fm_run_timed 30 env FM_HOME="$LAB" "$FM_LFP" poll --root "$TRIAGE" --interval 1 --error-budget 2) \
  || fail "missing checkout poll exited nonzero"
printf '%s\n' "$root_error_out" | grep -qx 'status: error' \
  || fail "missing checkout did not capture an error"
printf '%s\n' "$root_error_out" | grep -q '^error: triage checkout is unavailable:' \
  || fail "missing checkout error omitted its cause"
ok "runtime checkout loss captures an operational error"

printf '# all fm-procevent-linear-fmp tests passed\n'
