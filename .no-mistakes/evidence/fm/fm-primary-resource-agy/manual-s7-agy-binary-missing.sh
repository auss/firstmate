#!/usr/bin/env bash
# S7 redo: commit an agy-destination proposal with NO agy binary reachable.
# (First attempt was invalid: run_pr re-prepended a fakebin that still held a
# fake agy from S3.) Clean fakebin, real script, observable refusal.
set -u
ROOT=/home/marcin/.no-mistakes/worktrees/c7b2df826ee7/01M2DQN77BZP5QTMQSTZ7SEPFB
PR="$ROOT/bin/fm-primary-resource.sh"
WORK=$(mktemp -d /tmp/fmpr-s7.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"   # deliberately empty: no agy, no claude

h="$WORK/home"
mkdir -p "$h/state" "$h/config" "$h/data" "$h/state/primary-resource"
git -C "$h" init -q
printf '# fixture AGENTS\n' > "$h/AGENTS.md"
ln -sfn "$ROOT/bin" "$h/bin"
printf '%s\n' "$$" > "$h/state/.lock"

jq -nc --arg h claude --argjson p "$$" --arg s sess-s7 --arg t "$h/tx.jsonl" \
  '{version:1, harness:$h, pid:$p, sessionId:$s, transcriptPath:$t, boundAt:1}' \
  > "$h/state/primary-resource/binding.json"
printf '%s\0' claude > "$h/argv"
jq -nc --argjson t 1000 '{type:"assistant", isSidechain:false, message:{usage:{input_tokens:$t, cache_creation_input_tokens:0, cache_read_input_tokens:0}}}' > "$h/tx.jsonl"

QBASE='{"schemaVersion":5,"providers":[]}'
addq() { printf '%s' "$1" | jq -c --arg p "$2" --argjson r "$3" '
  .providers += [{provider:$p, state:{status:"ok", stale:false},
    quotaSemantics:{status:"known", effectiveAvailability:[{scope:"account", status:"known", effectivePercentRemaining:50, runway:{status:"through_reset"}}]},
    windows:[{id:"five_hour", kind:"session", resetsAt:"2026-09-11T20:00:00Z", percentRemaining:$r},
             {id:"weekly", kind:"weekly", resetsAt:"2026-09-18T00:00:00Z", percentRemaining:$r}]}]'; }
q=$(addq "$(addq "$(addq "$QBASE" claude 2)" codex 1)" agy 60)

runenv() {  # <args...>
  env FM_HOME="$h" FM_ROOT_OVERRIDE="$h" FM_STATE_OVERRIDE="$h/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 FM_SUPERVISOR_TARGET=fixture:agent \
    FM_SUPERVISOR_BACKEND=tmux FM_PRIMARY_RESOURCE_ARGV_FILE="$h/argv" \
    FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" \
    PATH="$FAKEBIN:/usr/bin:/bin" "$PR" "$@"
}

printf 'command -v agy inside this PATH: %s\n' "$(env PATH="$FAKEBIN:/usr/bin:/bin" command -v agy || echo NONE)"
out=$(runenv check 2>/dev/null || true)
printf 'check output: %s\n' "$out"
inc=$(printf '%s' "$out" | awk '{for(i=1;i<=NF;i++) if($i=="quota"){print $(i+1); exit}}')
printf 'incident: %s\n' "$inc"
printf 'proposal destination: '; jq -c '.replacement | {harness, provider}' "$h/state/primary-resource/proposals/$inc.json"
printf 'FM_PRIMARY_RESOURCE_STOW_V1\nverdict=reset-safe\nincidentId=%s\ngeneration=sess-s7\n' "$inc" > "$h/stow.md"

rc=0
out=$(runenv commit "$inc" --stow-receipt "$h/stow.md" 2>&1) || rc=$?
printf 'commit exit: %s\n' "$rc"
printf 'commit stderr/stdout: %s\n' "$out"
printf 'receipt created? '; [ -e "$h/state/primary-resource/receipts/$inc.json" ] && echo YES || echo NO
printf 'launch cmd written? '; [ -e "$h/state/primary-resource/launch/$inc.cmd" ] && echo YES || echo NO
