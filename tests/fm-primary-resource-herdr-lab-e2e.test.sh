#!/usr/bin/env bash
# Live lab-scoped Herdr end-to-end regression for bin/fm-primary-resource.sh:
# check proposes the context handover, commit creates the helper's own
# non-focused workspace pane through the real Herdr CLI scoped to an fm-lab-*
# session, the helper really runs inside that pane (busy read, occupant proof
# via pane process-info, /exit delivery, successor launch, started outcome,
# helper pane cleanup), and the lab leaves the default session untouched.
#
# The occupant is a bash binary and the successor an editor binary, each copied
# to a harness name so the real process classifiers (Herdr registration and
# fm_agent_process_classify) see a live claude: the occupant exits on the real
# /exit line, and the successor opens the successor prompt as a buffer the way
# an interactive agent would wait at its prompt.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate opt-in FM_PRIMARY_RESOURCE_HERDR_LAB_E2E herdr jq python3 vim

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-primary-resource-herdr-lab-e2e)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-pr-resource)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

LAB_TORNDOWN=0
OCCUPANT_PID=
SUCCESSOR_PID=
cleanup() {
  local status=$?
  if [ "$LAB_TORNDOWN" -eq 0 ]; then
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fi
  [ -z "$SUCCESSOR_PID" ] || kill -TERM "$SUCCESSOR_PID" 2>/dev/null || true
  [ -z "$OCCUPANT_PID" ] || kill -TERM "$OCCUPANT_PID" 2>/dev/null || true
  fm_test_cleanup
  exit "$status"
}
# Before provisioning: an early failure must never leak the lab.
trap cleanup EXIT

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

session_names() { lab session list --json | jq -r '.sessions[]?.name' | LC_ALL=C sort; }
default_snapshot() { lab session list --json | jq -c '[.sessions[]? | select(.default == true)]'; }

NAMES_BEFORE=$(session_names)
DEFAULT_BEFORE=$(default_snapshot)

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# --- fixture home ---------------------------------------------------------------

git -C "$HOME_DIR" init -q
printf '# live lab fixture\n' > "$HOME_DIR/AGENTS.md"
ln -sfn "$ROOT/bin" "$HOME_DIR/bin"
jq -nc --argjson t 175000 \
  '{type:"assistant", isSidechain:false, message:{usage:{input_tokens:$t, cache_creation_input_tokens:0, cache_read_input_tokens:0}}}' \
  > "$HOME_DIR/tx.jsonl"

# A bash binary named claude: real process classifiers see a live claude whose
# argv never needs to be guessed, and it exits on the real /exit line.
cp "$(command -v bash)" "$HOME_DIR/claude"
chmod +x "$HOME_DIR/claude"
# The successor relaunch runs the captured argv0 with the successor prompt as
# a positional argument; an editor binary named claude opens it as a buffer and
# stays alive, exactly like an interactive agent would.
mkdir -p "$HOME_DIR/successor"
cp "$(command -v vim)" "$HOME_DIR/successor/claude"
chmod +x "$HOME_DIR/successor/claude"
# shellcheck disable=SC2016 # occupant body is a literal -c string
occupant_body='trap "exit 0" TERM; while IFS= read -r line; do case "$line" in /quit|/exit) exit 0 ;; esac; done; while true; do sleep 1; done'

CREATE=$(lab workspace create --cwd "$HOME_DIR" --label primary --no-focus) \
  || fail 'live lab: could not create the primary workspace'
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail 'live lab: could not read the primary pane id'

lab pane run "$PANE" "$(printf '%q --noprofile --norc -c %q' "$HOME_DIR/claude" "$occupant_body")" \
  || fail 'live lab: could not start the claude occupant'

# Wait until Herdr positively registers a live claude at idle: the helper's
# first busy read fails closed on anything less legible.
i=0
while [ "$i" -lt 60 ]; do
  OCCUPANT_PID=$(lab pane process-info --pane "$PANE" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]? | select(.name == "claude") | .pid' 2>/dev/null | head -n1)
  if [ -n "$OCCUPANT_PID" ] \
    && [ "$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" = idle ]; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
[ -n "$OCCUPANT_PID" ] || fail "live lab: claude occupant never became visible (pane=$PANE)"
[ "$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" = idle ] \
  || fail 'live lab: claude occupant never reached a legible idle status'

mkdir -p "$HOME_DIR/state/primary-resource"
jq -nc --arg h claude --argjson p "$OCCUPANT_PID" --arg s sess-herdr-live --arg t "$HOME_DIR/tx.jsonl" \
  '{version:1, harness:$h, pid:$p, sessionId:$s, transcriptPath:$t, boundAt:1}' \
  > "$HOME_DIR/state/primary-resource/binding.json"
printf '%s\n' "$OCCUPANT_PID" > "$HOME_DIR/state/.lock"
printf '%s\0' "$HOME_DIR/successor/claude" > "$HOME_DIR/argv"

QUOTA_JSON=$(jq -nc --argjson ea '[{"scope":"account","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]' '
  {schemaVersion:5, providers:[
    {provider:"claude", state:{status:"ok", stale:false},
     quotaSemantics:{status:"known", effectiveAvailability:$ea},
     windows:[
       {id:"five_hour", kind:"session", resetsAt:"2026-09-11T20:00:00Z", percentRemaining:50},
       {id:"seven_day", kind:"weekly", resetsAt:"2026-09-18T00:00:00Z", percentRemaining:50}
     ]}
  ]}')

run_pr() {
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 \
    FM_PRIMARY_RESOURCE_QUOTA_JSON="$QUOTA_JSON" \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$HOME_DIR/argv" \
    FM_SUPERVISOR_BACKEND=herdr \
    FM_SUPERVISOR_TARGET="$HERDR_LAB_SESSION:$PANE" \
    PATH="$HERDR_ORIGINAL_PATH" \
    "$ROOT/bin/fm-primary-resource.sh" "$@"
}

# --- check proposes the handover ------------------------------------------------

out=$(run_pr check 2>&1) || fail "live lab: check failed: $out"
case "$out" in
  *'primary-resource context '*) ;;
  *) fail "live lab: Herdr check must propose a context handover, got: $out" ;;
esac
incident=${out##* }; incident=${incident%%$'\n'*}
[ -n "$incident" ] || fail "live lab: no incident id in check output: $out"

# --- commit launches the real helper pane ---------------------------------------

printf 'FM_PRIMARY_RESOURCE_STOW_V1\nverdict=reset-safe\nincidentId=%s\ngeneration=sess-herdr-live\n' "$incident" \
  > "$HOME_DIR/stow.md"

rc=0
out=$(run_pr commit "$incident" --stow-receipt "$HOME_DIR/stow.md" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "live lab: commit must launch the Herdr helper, got rc=$rc: $out"
assert_present "$HOME_DIR/state/primary-resource/receipts/$incident.json" \
  'live lab: commit must persist the incident receipt'

# The successor command is <argv0> '<prompt>' (the argv file carries only the
# captured argv0). Assert the cmd commit wrote really relaunches that argv0.
launch_cmd_file="$HOME_DIR/state/primary-resource/launch/$incident.cmd"
i=0
while [ "$i" -lt 20 ] && [ ! -f "$launch_cmd_file" ]; do sleep 0.25; i=$((i + 1)); done
[ -f "$launch_cmd_file" ] || fail 'live lab: launch cmd file never appeared'
case "$(cat "$launch_cmd_file")" in
  "$HOME_DIR/successor/claude "*) ;;
  *) fail "live lab: unexpected launch cmd shape: $(cat "$launch_cmd_file")" ;;
esac

# --- the real helper completes inside the lab -----------------------------------

outcome="$HOME_DIR/state/primary-resource/outcomes/$incident.json"
stage=''
reason=''
i=0
while [ "$i" -lt 120 ]; do
  stage=$(jq -r '.stage // empty' "$outcome" 2>/dev/null || true)
  if [ -n "$stage" ] && [ "$stage" != waiting-idle ] && [ "$stage" != exiting ] && [ "$stage" != launching ]; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
reason=$(jq -r '.reason // empty' "$outcome" 2>/dev/null || true)
assert_equals started "$stage" "live lab: helper must complete the handover (reason=$reason)"
assert_equals successor-alive "$reason" 'live lab: helper must record a live successor'

if kill -0 "$OCCUPANT_PID" 2>/dev/null; then
  fail 'live lab: the old occupant must be gone after the handover'
fi
# The pane's foreground must now be a DIFFERENT claude-named process: the
# successor really launched inside the lab pane.
SUCCESSOR_PID=$(lab pane process-info --pane "$PANE" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[]? | select(.name == "claude") | .pid' 2>/dev/null | head -n1)
[ -n "$SUCCESSOR_PID" ] || fail 'live lab: no claude-named successor in the primary pane'
[ "$SUCCESSOR_PID" != "$OCCUPANT_PID" ] \
  || fail 'live lab: the foreground claude must be the successor, not the occupant'
kill -0 "$SUCCESSOR_PID" 2>/dev/null || fail 'live lab: the successor process must be alive'
assert_absent "$HOME_DIR/state/primary-resource/launch/$incident.cmd" \
  'live lab: terminal outcome must remove the launch cmd file'
assert_absent "$HOME_DIR/state/primary-resource/launch/$incident.argv" \
  'live lab: terminal outcome must remove the launch argv file'

# The helper pane close must have disposed the helper workspace: only the
# primary workspace may remain in the lab.
leaked=$(lab workspace list | jq -r '.result.workspaces[]?.label | select(startswith("fm-pr-helper-"))')
[ -z "$leaked" ] || fail "live lab: helper workspace leaked: $leaked"

# --- isolation: default session untouched, no lab leak ---------------------------

assert_equals "$DEFAULT_BEFORE" "$(default_snapshot)" \
  'live lab: the default session must be byte-identical after the handover'

env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail 'live lab: teardown refused (fleet-state tripwire or lab removal failed)'
LAB_TORNDOWN=1

assert_equals "$NAMES_BEFORE" "$(session_names)" \
  'live lab: session list must be identical after teardown (no lab leaked)'

pass 'live Herdr lab handover: check->commit->helper->successor, default untouched'
