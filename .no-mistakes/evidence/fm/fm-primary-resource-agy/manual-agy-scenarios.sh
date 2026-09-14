#!/usr/bin/env bash
# Manual end-to-end drive of bin/fm-primary-resource.sh agy support
# (branch fm/fm-primary-resource-agy). Each scenario runs the REAL script
# (check / commit) in an isolated temp home and records the observable result.
set -u
ROOT=/home/marcin/.no-mistakes/worktrees/c7b2df826ee7/01M2DQN77BZP5QTMQSTZ7SEPFB
PR="$ROOT/bin/fm-primary-resource.sh"
EV=/home/marcin/.no-mistakes/evidence/01M2DQN77BZP5QTMQSTZ7SEPFB
WORK=$(mktemp -d /tmp/fmpr-agy-manual.XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
cd "$WORK"

FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"

run_pr() {  # <home> <args...>
  local home=$1; shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 \
    FM_SUPERVISOR_TARGET="${FM_SUPERVISOR_TARGET:-fixture:agent}" \
    FM_SUPERVISOR_BACKEND="${FM_SUPERVISOR_BACKEND:-tmux}" \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$home/argv" \
    PATH="$FAKEBIN:$PATH" \
    "$PR" "$@"
}

make_home() {  # <name>
  local home="$WORK/$1"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/state/primary-resource"
  git -C "$home" init -q
  printf '# fixture AGENTS\n' > "$home/AGENTS.md"
  ln -sfn "$ROOT/bin" "$home/bin"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$home"
}

bind_home() {  # <home> <harness> <session> <transcript>
  jq -nc --arg h "$2" --argjson p "$$" --arg s "$3" --arg t "$4" \
    '{version:1, harness:$h, pid:$p, sessionId:$s, transcriptPath:$t, boundAt:1}' \
    > "$1/state/primary-resource/binding.json"
  printf '%s\0' "$2" > "$1/argv"
}

write_agy_tx() {  # <path> <bytes>
  mkdir -p "$(dirname -- "$1")"
  { printf '%s' '{"step_index":0,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-09-13T15:31:53Z","content":"'
    head -c "$2" /dev/zero | tr '\0' x
    printf '%s\n' '"}'; } > "$1"
}
write_claude_tx() {  # <path> <tokens>
  mkdir -p "$(dirname -- "$1")"
  jq -nc --argjson t "$2" '{type:"assistant", isSidechain:false, message:{usage:{input_tokens:$t, cache_creation_input_tokens:0, cache_read_input_tokens:0}}}' > "$1"
}

QBASE='{"schemaVersion":5,"providers":[]}'
addq() {  # <json> <provider> <pctRemaining> [stale] [semantics]
  printf '%s' "$1" | jq -c --arg p "$2" --argjson r "$3" --argjson st "${4:-false}" --arg qs "${5:-known}" '
    .providers += [{provider:$p, state:{status:"ok", stale:$st},
      quotaSemantics:{status:$qs, effectiveAvailability:(if $qs == "known"
        then [{scope:"account", status:"known", effectivePercentRemaining:50, runway:{status:"through_reset"}}]
        else [] end)},
      windows:[
        {id:"five_hour", kind:"session", resetsAt:"2026-09-11T20:00:00Z", percentRemaining:$r},
        {id:"weekly", kind:"weekly", resetsAt:"2026-09-18T00:00:00Z", percentRemaining:$r}
      ]}]'
}

stow_ok() {  # <path> <incident> <session>
  printf 'FM_PRIMARY_RESOURCE_STOW_V1\nverdict=reset-safe\nincidentId=%s\ngeneration=%s\n' "$2" "$3" > "$1"
}

install_fixture_tmux() {  # snapshot launch cmds, run helper in background
  cat > "$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = new-session ]; then
  cp -f "$FM_HOME"/state/primary-resource/launch/*.cmd "$FM_HOME/" 2>/dev/null || true
  bash -c "${!#}" >/dev/null 2>&1 &
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKEBIN/tmux"
}

hdr() { printf '\n=== SCENARIO %s ===\n' "$1"; }
get_incident() { printf '%s' "$1" | awk '{for(i=1;i<=NF;i++) if($i=="quota"||$i=="context"){print $(i+1); exit}}'; }

# ---------------------------------------------------------------- S1: agy context is alert-only
hdr "S1: agy primary, healthy quota, real transcript -> alert-only context (agy-no-usage)"
h=$(make_home s1-agy-ctx)
write_agy_tx "$h/tx.jsonl" 1000
bind_home "$h" agy sess-s1 "$h/tx.jsonl"
q=$(addq "$QBASE" agy 50)
out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check 2>&1 || true)
printf 'check output: %s\n' "$out"
printf 'proposals dir empty? '; [ -z "$(find "$h/state/primary-resource/proposals" -type f -print -quit 2>/dev/null)" ] && echo YES || echo NO
out2=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check 2>&1 || true)
printf 'second check output (alert-once): [%s]\n' "$(printf '%s' "$out2" | tr -d '\n')"

# missing transcript -> missing-binding reason
h=$(make_home s1b-agy-missing)
bind_home "$h" agy sess-s1b "$h/missing.jsonl"
out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check 2>&1 || true)
printf 'missing-transcript check output: %s\n' "$out"

# ---------------------------------------------------------------- S2: agy source exhausted -> claude destination, full commit
hdr "S2: agy primary quota exhausted (2%% left) -> quota handover to claude, committed"
h=$(make_home s2-agy-src)
write_agy_tx "$h/tx.jsonl" 1000
bind_home "$h" agy sess-s2 "$h/tx.jsonl"
q=$(addq "$(addq "$QBASE" agy 2)" claude 50)
out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check 2>/dev/null || true)
printf 'check output: %s\n' "$out"
inc=$(get_incident "$out"); printf 'incident: %s\n' "$inc"
printf 'stored proposal: '; jq -c '{action, replacement}' "$h/state/primary-resource/proposals/$inc.json"
stow_ok "$h/stow.md" "$inc" sess-s2
printf '#!/usr/bin/env bash\necho ok\n' > "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"
install_fixture_tmux
rc=0; FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" commit "$inc" --stow-receipt "$h/stow.md" >/dev/null 2>&1 || rc=$?
printf 'commit exit: %s\n' "$rc"
printf 'receipt: '; jq -c '{sourceHarness,sourceProvider,destinationHarness,destinationProvider}' "$h/state/primary-resource/receipts/$inc.json"

# ---------------------------------------------------------------- S3: claude exhausted, codex exhausted -> agy destination with --prompt-interactive
hdr "S3: claude exhausted, codex exhausted -> handover destination falls through to agy (--prompt-interactive)"
h=$(make_home s3-agy-dest)
write_claude_tx "$h/tx.jsonl" 1000
bind_home "$h" claude sess-s3 "$h/tx.jsonl"
q=$(addq "$(addq "$(addq "$QBASE" claude 2)" codex 1)" agy 60)
out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check 2>/dev/null || true)
printf 'check output: %s\n' "$out"
inc=$(get_incident "$out"); printf 'incident: %s\n' "$inc"
printf 'stored proposal: '; jq -c '{action, replacement}' "$h/state/primary-resource/proposals/$inc.json"
stow_ok "$h/stow.md" "$inc" sess-s3
printf '#!/usr/bin/env bash\necho ok\n' > "$FAKEBIN/agy"; chmod +x "$FAKEBIN/agy"
rc=0; FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" commit "$inc" --stow-receipt "$h/stow.md" >/dev/null 2>&1 || rc=$?
printf 'commit exit: %s\n' "$rc"
printf 'receipt: '; jq -c '{sourceHarness,destinationHarness,destinationProvider}' "$h/state/primary-resource/receipts/$inc.json"
printf 'successor launch cmd snapshot: %s\n' "$(cat "$h/$inc.cmd" 2>/dev/null)"
printf 'launch cmd contains --prompt-interactive? '; grep -q -- '--prompt-interactive' "$h/$inc.cmd" 2>/dev/null && echo YES || echo NO

# ---------------------------------------------------------------- S4: codex preferred over agy when both eligible
hdr "S4: claude exhausted, codex AND agy eligible -> codex stays preferred"
h=$(make_home s4-preference)
write_claude_tx "$h/tx.jsonl" 1000
bind_home "$h" claude sess-s4 "$h/tx.jsonl"
q=$(addq "$(addq "$(addq "$QBASE" claude 2)" codex 50)" agy 60)
FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check >/dev/null 2>&1 || true
printf 'chosen replacement: '; jq -c '.replacement | {harness, provider}' "$h"/state/primary-resource/proposals/*.json

# ---------------------------------------------------------------- S5: stale agy source row -> alert-only
hdr "S5 (adversarial): agy quota exhausted but row marked stale -> alert-only, no handover"
h=$(make_home s5-agy-stale-src)
write_agy_tx "$h/tx.jsonl" 1000
bind_home "$h" agy sess-s5 "$h/tx.jsonl"
q=$(addq "$(addq "$QBASE" agy 1 true)" claude 50)
out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check 2>&1 || true)
printf 'check output: %s\n' "$out"
printf 'proposals dir empty? '; [ -z "$(find "$h/state/primary-resource/proposals" -type f -print -quit 2>/dev/null)" ] && echo YES || echo NO

# ---------------------------------------------------------------- S6: unknown-semantics agy destination row -> not an eligible fallback
hdr "S6 (adversarial): claude+codex exhausted, agy row unknown semantics -> no agy fallback"
h=$(make_home s6-agy-unknown-dest)
write_claude_tx "$h/tx.jsonl" 1000
bind_home "$h" claude sess-s6 "$h/tx.jsonl"
q=$(addq "$(addq "$(addq "$QBASE" claude 2)" codex 1)" agy 60 false unknown)
out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check 2>&1 || true)
printf 'check output: %s\n' "$out"
printf 'proposals dir empty? '; [ -z "$(find "$h/state/primary-resource/proposals" -type f -print -quit 2>/dev/null)" ] && echo YES || echo NO

# ---------------------------------------------------------------- S7: commit refuses agy destination when agy binary is missing
hdr "S7 (adversarial): commit an agy-destination proposal with no agy binary on PATH -> refusal"
h=$(make_home s7-no-agy-bin)
write_claude_tx "$h/tx.jsonl" 1000
bind_home "$h" claude sess-s7 "$h/tx.jsonl"
q=$(addq "$(addq "$(addq "$QBASE" claude 2)" codex 1)" agy 60)
out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" run_pr "$h" check 2>/dev/null || true)
inc=$(get_incident "$out")
stow_ok "$h/stow.md" "$inc" sess-s7
rc=0
FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" PATH="/usr/bin:/bin" \
  FM_HOME="$h" FM_ROOT_OVERRIDE="$h" FM_STATE_OVERRIDE="$h/state" \
  FM_PRIMARY_RESOURCE_FORCE_OWNER=1 FM_SUPERVISOR_TARGET=fixture:agent \
  FM_SUPERVISOR_BACKEND=tmux FM_PRIMARY_RESOURCE_ARGV_FILE="$h/argv" \
  run_pr "$h" commit "$inc" --stow-receipt "$h/stow.md" 2>&1 || rc=$?
printf 'commit exit with agy absent from PATH: %s\n' "$rc"
printf 'receipt created despite refusal? '; [ -e "$h/state/primary-resource/receipts/$inc.json" ] && echo YES || echo NO

printf '\n=== ALL MANUAL SCENARIOS DRIVEN ===\n'
