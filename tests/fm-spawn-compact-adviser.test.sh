#!/usr/bin/env bash
# tests/fm-spawn-compact-adviser.test.sh - Firstmate launches agents without
# pinning COMPACT_ADVISER_DISABLE, so the compact adviser follows the
# launching session, while an operator's own kill switch still reaches the
# agent.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane actually received, under a synthetic pane environment, with
# the harness binary replaced by a probe that prints the environment it was
# started with. What the probe prints is what a real agent would have received.
#
# The remote second-mate route never reaches this path; its coverage lives in
# tests/fm-spawn-compact-adviser-remote.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-compact-adviser)

# A synthetic pane value the launch must leave alone rather than override: the
# default is pass-through, so a pane that already carries a value - an
# operator's kill switch in either direction - must have that value reach the
# agent unchanged.
CONTRARY=0
OVERRIDE=1

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Replace the harness binary with a probe that reports the two environment
# facts under test, so executing the emitted launch answers "what would the
# agent have seen" rather than "what does the command text look like".
install_env_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf 'disable=%s\n' "${COMPACT_ADVISER_DISABLE-unset}"
printf 'hooks=%s\n' "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS-unset}"
SH
  chmod +x "$1/$2"
}

probe_fact() {  # <field> <probe-output>
  printf '%s\n' "$2" | sed -n "s/^$1=//p"
}

# Run the emitted launch command in a synthetic pane shell, first replaying the
# pane exports the real pane shell received, in send order. Extra NAME=VALUE
# arguments model what the destination pane environment carries; none models a
# host that never set the names.
#   replay_emitted_launch <fakebin> <launch-log> <pane-log> [NAME=VALUE]...
replay_emitted_launch() {
  local fakebin=$1 launchlog=$2 panelog=$3
  shift 3
  local launch preamble
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog" || true)
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane "$@" \
    /bin/sh -c "$preamble
$launch"
}

# Firstmate must not deliver any compact-adviser value of its own: neither a
# pre-launch pane export nor a launch-command assignment may exist.
assert_no_spawned_disable() {  # <pane-log> <label>
  local panelog=$1 label=$2
  ! grep -q '^export COMPACT_ADVISER_DISABLE=' "$panelog" \
    || fail "$label: the pane shell received a compact-adviser export Firstmate never sends"
  grep -q '^export GOTMPDIR=' "$panelog" \
    || fail "$label: the pane log is missing the pre-launch exports it should still carry"
}

test_ship_allowlist_absent() {
  local rec out status seen
  rec=$(make_case ship-open codex ship-open-a1)
  read_case "$rec"
  out=$(run_case_spawn ship-open-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn without an allowlist should succeed: $out"
  assert_no_spawned_disable "$PANE_LOG" "ship, allowlist absent"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(replay_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "ship, allowlist absent: the emitted launch failed to run"
  assert_equals unset "$(probe_fact disable "$seen")" \
    "a ship worker launched on a host that never set the kill switch must not receive one"
  assert_equals unset "$(probe_fact hooks "$seen")" \
    "a ship worker launched on a host that never enabled function hooks must not receive the flag"
  seen=$(replay_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "COMPACT_ADVISER_DISABLE=$OVERRIDE") \
    || fail "ship, allowlist absent: the emitted launch failed to run under the override"
  assert_equals 1 "$(probe_fact disable "$seen")" \
    "an operator's kill switch in the pane environment must reach a ship worker by inheritance"
  seen=$(replay_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1") \
    || fail "ship, allowlist absent: the emitted launch failed to run with function hooks on"
  assert_equals 1 "$(probe_fact hooks "$seen")" \
    "a function-hooks opt-in in the pane environment must reach a ship worker by inheritance"
  pass "ship launch with no allowlist leaves the compact adviser to the ambient environment"
}

test_ship_allowlist_enabled() {
  local rec out status seen launch
  rec=$(make_case ship-filtered codex ship-filtered-a1)
  read_case "$rec"
  # An empty file is the strictest opt-in: the launch keeps Firstmate's own
  # operational floor and nothing else, so it is where a floor either holds or
  # is lost.
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn ship-filtered-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn under an allowlist should succeed: $out"
  assert_no_spawned_disable "$PANE_LOG" "ship, allowlist enabled"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '/usr/bin/env -i' \
    "an enabled allowlist should launch under a cleared environment"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(replay_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "ship, allowlist enabled: the emitted launch failed to run"
  assert_equals unset "$(probe_fact disable "$seen")" \
    "the cleared environment must not invent a compact-adviser kill switch"
  assert_equals unset "$(probe_fact hooks "$seen")" \
    "the cleared environment must not invent a function-hooks opt-in"
  seen=$(replay_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "COMPACT_ADVISER_DISABLE=$OVERRIDE") \
    || fail "ship, allowlist enabled: the emitted launch failed to run under the override"
  assert_equals 1 "$(probe_fact disable "$seen")" \
    "the operational floor must forward an operator's kill switch through the cleared environment"
  seen=$(replay_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1") \
    || fail "ship, allowlist enabled: the emitted launch failed to run with function hooks on"
  assert_equals 1 "$(probe_fact hooks "$seen")" \
    "the operational floor must forward the function-hooks opt-in through the cleared environment"
  pass "ship launch under an enabled allowlist forwards both compact-adviser names without setting either"
}

# The pass-through must not depend on the pane exports having landed, and no
# launch-command assignment may reintroduce a value. Replaying the launch
# alone, with a contrary ambient value, is that case.
test_launch_command_never_pins_the_switch() {
  local setting rec out status seen launch
  for setting in absent enabled; do
    rec=$(make_case "ship-nopane-$setting" codex "ship-nopane-$setting-a1")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_case_spawn "ship-nopane-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    install_env_probe "$FAKEBIN_DIR" codex
    launch=$(cat "$LAUNCH_LOG")
    seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
      TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
      /bin/sh -c "$launch") \
      || fail "allowlist=$setting: the emitted launch failed to run without the pane exports"
    assert_equals 0 "$(probe_fact disable "$seen")" \
      "allowlist=$setting: the launch command alone must not override a contrary pane value"
  done
  pass "the launch command pins no compact-adviser value, whichever allowlist posture is in force"
}

test_secondmate_launch() {
  local setting rec sm out status seen
  for setting in absent enabled; do
    rec=$(make_case "secondmate-$setting" codex "sm-$setting")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    sm="$CASE_DIR/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "sm-$setting" > "$sm/.fm-secondmate-home"
    printf 'charter for sm-%s\n' "$setting" > "$sm/data/charter.md"
    out=$(run_case_spawn "sm-$setting" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "secondmate spawn with allowlist=$setting should succeed: $out"
    assert_no_spawned_disable "$PANE_LOG" "secondmate, allowlist $setting"
    install_env_probe "$FAKEBIN_DIR" codex
    seen=$(replay_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
      || fail "secondmate, allowlist $setting: the emitted launch failed to run"
    assert_equals unset "$(probe_fact disable "$seen")" \
      "a secondmate launched with allowlist=$setting must not receive a kill switch nobody set"
    seen=$(replay_emitted_launch "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "COMPACT_ADVISER_DISABLE=$OVERRIDE") \
      || fail "secondmate, allowlist $setting: the emitted launch failed to run under the override"
    assert_equals 1 "$(probe_fact disable "$seen")" \
      "an operator's kill switch must reach a secondmate with allowlist=$setting"
  done
  pass "a secondmate launch leaves the compact adviser to the pane environment in both allowlist postures"
}

# --- relaunch ---------------------------------------------------------------
#
# bin/fm-control.sh relaunch stops the agent and rebuilds the launch through
# bin/fm-spawn.sh --relaunch, so this drives the operator-facing verb rather
# than the rebuild alone. The stub below models just enough pane lifecycle for
# that transaction: the harness exit command leaves a bare shell behind, and the
# launch literal starts the harness again.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_keeps_the_pass_through() {
  local setting dir home proj wt id out status seen launch preamble
  for setting in absent enabled; do
    id="relaunch-$setting-a1"
    dir="$TMP_ROOT/relaunch-$setting"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
    touch "$home/state/.last-watcher-beat"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    make_relaunch_stub "$dir"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$setting"
    fm_test_spawn_brief "$home" "$id"
    : > "$dir/fake/literal"
    : > "$dir/fake/keys"
    printf 'codex' > "$dir/fake/command"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$wt" > "$dir/fake/cwd"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "project=$proj"
      echo "harness=codex"
      echo "kind=ship"
      echo "mode=no-mistakes"
      echo "yolo=off"
      echo "tasktmp=$dir/tasktmp"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"

    mkdir -p "$dir/user-home"
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch with allowlist=$setting should succeed: $out"

    ! grep -q '^export COMPACT_ADVISER_DISABLE=' "$dir/fake/keys" \
      || fail "relaunch with allowlist=$setting re-exported a compact-adviser value into the pane"
    launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
    [ -n "$launch" ] || fail "relaunch with allowlist=$setting sent no replacement launch command"
    install_env_probe "$dir/fakebin" codex
    preamble=$(grep '^export ' "$dir/fake/keys" || true)
    seen=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" TERM=xterm \
      TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$OVERRIDE" \
      /bin/sh -c "$preamble
$launch") \
      || fail "relaunch with allowlist=$setting: the replacement launch failed to run"
    assert_equals 1 "$(probe_fact disable "$seen")" \
      "an operator's kill switch must reach a relaunched agent with allowlist=$setting, exactly as a fresh spawn"
    seen=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" TERM=xterm \
      TMUX=synthetic-pane \
      /bin/sh -c "$preamble
$launch") \
      || fail "relaunch with allowlist=$setting: the replacement launch failed to run unset"
    assert_equals unset "$(probe_fact disable "$seen")" \
      "a relaunched agent with allowlist=$setting must not receive a kill switch nobody set"
  done
  pass "relaunch keeps the compact adviser following the pane environment in both allowlist postures"
}

# A command-prefix assignment only covers the first simple command. A raw
# compound launch such as `cd <dir> && <probe>` must carry no forced value
# either, so this drives that escape hatch and executes the pane's launch under
# a contrary ambient value.
test_raw_compound_launch_command_pins_nothing() {
  local rec out status seen launch probe_dir
  rec=$(make_case raw-compound claude raw-compound-a1)
  read_case "$rec"
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$HOME_DIR/config/crew-dispatch.json"

  probe_dir="$CASE_DIR/agent-cwd"
  mkdir -p "$probe_dir"
  cat > "$probe_dir/probe" <<'SH'
#!/bin/sh
printf 'disable=%s\n' "${COMPACT_ADVISER_DISABLE-unset}"
SH
  chmod +x "$probe_dir/probe"

  out=$(run_case_spawn raw-compound-a1 "$PROJ_DIR" --mode no-mistakes --yolo off \
    "cd $probe_dir && ./probe")
  status=$?
  expect_code 0 "$status" "raw compound launch spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  [ -n "$launch" ] || fail "raw compound launch spawn sent no launch command"
  seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
    /bin/sh -c "$launch") \
    || fail "raw compound launch: the emitted launch failed to run"
  assert_equals 0 "$(probe_fact disable "$seen")" \
    "a raw compound launch must not force a compact-adviser value onto the agent, even after cd"
  seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$OVERRIDE" \
    /bin/sh -c "$launch") \
    || fail "raw compound launch: the emitted launch failed to run under the override"
  assert_equals 1 "$(probe_fact disable "$seen")" \
    "an operator's kill switch must reach a raw compound launch, even after cd"
  pass "a compound raw launch-command leaves the compact adviser to the ambient environment"
}

test_ship_allowlist_absent
test_ship_allowlist_enabled
test_launch_command_never_pins_the_switch
test_secondmate_launch
test_relaunch_keeps_the_pass_through
test_raw_compound_launch_command_pins_nothing
