#!/usr/bin/env bash
# Behavior tests for bin/fm-eggbot-ingest.sh.
#
# Inbox JSON is ingested through fm-tasks-axi.sh add and fm-captain-hold.sh
# hold against a fakebin tasks-axi, never by editing data/backlog.md. Cases
# cover create+hold, idempotent re-ingest, already-processed skip, schema
# rejection, the arm/check standing-check surface, tasks-axi 0.2.5 CLI order
# without a bare `--` token, and HOME/.local/bin PATH bootstrap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INGEST="$ROOT/bin/fm-eggbot-ingest.sh"
TMP_ROOT=$(fm_test_tmproot fm-eggbot-ingest)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

write_fake_tasks_axi() {  # <home>
  local home=$1 fakebin store
  fakebin=$(fm_fakebin "$home")
  store="$home/fake-tasks"
  mkdir -p "$store"
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
STORE='$store'
LOG='$store/log'
mkdir -p "\$STORE"
printf '%s\n' "\$*" >> "\$LOG"

BODY_FILE=
BODY=
REASON=
KIND=
REPO=
skip_flags() {
  local -a out=()
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --)
        printf 'Unknown flag: --\\n' >&2
        exit 1
        ;;
      --file|--body-file|--body|--reason|--kind|--repo|--until)
        [ "\$#" -ge 2 ] || exit 1
        case "\$1" in
          --body-file) BODY_FILE=\$2 ;;
          --body) BODY=\$2 ;;
          --reason) REASON=\$2 ;;
          --kind) KIND=\$2 ;;
          --repo) REPO=\$2 ;;
        esac
        shift 2
        ;;
      --full) shift ;;
      --file=*|--body-file=*|--body=*|--reason=*|--kind=*|--repo=*|--until=*)
        case "\$1" in
          --body-file=*) BODY_FILE=\${1#--body-file=} ;;
          --body=*) BODY=\${1#--body=} ;;
          --reason=*) REASON=\${1#--reason=} ;;
          --kind=*) KIND=\${1#--kind=} ;;
          --repo=*) REPO=\${1#--repo=} ;;
        esac
        shift
        ;;
      *) out+=("\$1"); shift ;;
    esac
  done
  ARGS=("\${out[@]+"\${out[@]}"}")
}

show_row() {
  local id=\$1
  local dir="\$STORE/\$id" body held hold_kind
  [ -d "\$dir" ] || { printf 'code: NOT_FOUND\n' >&2; return 1; }
  body=\$(cat "\$dir/body" 2>/dev/null || true)
  held=\$(cat "\$dir/held" 2>/dev/null || printf 'no')
  hold_kind=\$(cat "\$dir/hold_kind" 2>/dev/null || printf '%s\n' '-')
  printf '%s\n' "task:"
  printf '  id: %s\n' "\$id"
  printf '  title: %s\n' "\$(cat "\$dir/title")"
  printf '  state: %s\n' "\$(cat "\$dir/state")"
  printf '  held: %s\n' "\$held"
  printf '  blocked: no\n'
  printf '  hold_kind: %s\n' "\$hold_kind"
  if [ -n "\$body" ]; then
    python3 -c 'import json,sys; print("  body: " + json.dumps(sys.stdin.read()))' < "\$dir/body"
  else
    printf '  body: -\n'
  fi
}

BODY_FILE=
BODY=
REASON=
KIND=
REPO=
skip_flags "\$@"
set -- "\${ARGS[@]+"\${ARGS[@]}"}"

case "\${1:-}" in
  --version) printf '%s\n' 'tasks-axi 0.2.5' ;;
  --help) printf '%s\n' 'usage: tasks-axi <command>' ;;
  update)
    if [ "\${2:-}" = --help ]; then
      printf '%s\n' '--archive-body'
      exit 0
    fi
    id=\${2:-}
    [ -n "\$id" ] && [ -d "\$STORE/\$id" ] || exit 1
    if [ -f "\$STORE/fail-update-once" ]; then
      rm -f "\$STORE/fail-update-once"
      exit 1
    fi
    [ -n "\$BODY_FILE" ] || exit 1
    cat "\$BODY_FILE" > "\$STORE/\$id/body"
    ;;
  mv)
    [ "\${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    if [ "\${2:-}" = --help ]; then
      printf '%s\n' '  --kind captain'
      exit 0
    fi
    id=\${2:-}
    [ -n "\$id" ] && [ -d "\$STORE/\$id" ] || exit 1
    [ "\$KIND" = captain ] || exit 1
    [ -n "\$REASON" ] || exit 1
    case "\$REASON" in *'('*|*')'*) exit 1 ;; esac
    printf 'yes\n' > "\$STORE/\$id/held"
    printf 'captain\n' > "\$STORE/\$id/hold_kind"
    printf '%s\n' "\$REASON" > "\$STORE/\$id/reason"
    ;;
  add)
    id=\${2:-}
    title=\${3:-}
    [ -n "\$id" ] && [ -n "\$title" ] || exit 1
    [ ! -d "\$STORE/\$id" ] || exit 1
    mkdir -p "\$STORE/\$id"
    printf '%s\n' "\$title" > "\$STORE/\$id/title"
    printf '%s\n' "\${KIND:-ship}" > "\$STORE/\$id/kind"
    printf '%s\n' "\${REPO:-}" > "\$STORE/\$id/repo"
    printf 'queued\n' > "\$STORE/\$id/state"
    printf 'no\n' > "\$STORE/\$id/held"
    printf '%s\n' '-' > "\$STORE/\$id/hold_kind"
    : > "\$STORE/\$id/body"
    if [ -n "\$BODY" ]; then
      printf '%s\n' "\$BODY" > "\$STORE/\$id/body"
    fi
    if [ -n "\$BODY_FILE" ]; then
      cat "\$BODY_FILE" > "\$STORE/\$id/body"
    fi
    printf '%s\n' "\$id"
    ;;
  show)
    show_row "\${2:-}"
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
}

make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  write_fake_tasks_axi "$home"
  printf '%s\n' "$home"
}

run_ingest() {  # <home> <action...>
  local home=$1
  shift
  PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$INGEST" "$@"
}

write_event() {  # <home> <filename> <json>
  local home=$1 name=$2 json=$3 dest tmp
  mkdir -p "$home/state/eggbot/inbox"
  dest="$home/state/eggbot/inbox/$name"
  tmp="$dest.tmp"
  printf '%s\n' "$json" > "$tmp"
  mv -f -- "$tmp" "$dest"
}

sample_event() {  # <event_id> [task_id]
  local event_id=$1 task_id=${2:-$1}
  cat <<EOF
{
  "schema": "fm-eggbot-context-debt.v1",
  "event_id": "$event_id",
  "task_id": "$task_id",
  "project": "family-meal-planner",
  "title": "Close FMP week context and map DoD debt",
  "kind": "ship",
  "week": "2026-09-08/14",
  "source": "dr eggbot",
  "debt": [
    {
      "id": "shopping-correctness",
      "summary": "shopping-correctness vs code without split",
      "reason": "merge is not done; need green CI plus CONTEXT/map update path@commit",
      "dod": {
        "merge_is_not_done": true,
        "require_green_ci": true,
        "closure": {
          "kind": "context_or_map",
          "path": "CONTEXT.md",
          "commit": "deadbeef"
        },
        "changelog_without_code": "blocker",
        "contract_freeze": {"required": true, "name": "Listonic"},
        "thrash": {"days": 3, "repeats": 3}
      }
    },
    {
      "id": "stale-codemap",
      "summary": "stale .slim/codemap.json",
      "reason": "map update missing; evidence is path@commit after green CI",
      "dod": {
        "merge_is_not_done": true,
        "require_green_ci": true,
        "closure": {
          "kind": "process_patch"
        }
      }
    }
  ]
}
EOF
}

test_help_and_usage() {
  local out rc=0
  out=$("$INGEST" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "ingest" "--help lists ingest"
  assert_contains "$out" "check" "--help lists check"
  assert_contains "$out" "arm" "--help lists arm"
  assert_contains "$out" "state/eggbot/inbox" "--help names the drop path"
  assert_contains "$out" "fm-eggbot-context-debt.v1" "--help names the schema"
  rc=0
  out=$("$INGEST" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  pass "fm-eggbot-ingest: help and usage plumbing"
}

test_happy_path_creates_and_holds() {
  local home out task=fmp-ctx-debt-2026-09-14
  home=$(make_home happy)
  write_event "$home" "week.json" "$(sample_event fmp-2026-09-14-context-debt "$task")"
  out=$(run_ingest "$home" ingest 2>&1) || fail "ingest must succeed: $out"
  assert_contains "$out" "created=1" "happy path creates one event"
  assert_contains "$out" "failed=0" "happy path has no failures"
  assert_present "$home/state/eggbot/processed/fmp-2026-09-14-context-debt" \
    "processed receipt is written"
  assert_present "$home/fake-tasks/$task/reason" "hold recorded a reason"
  assert_equals "yes" "$(cat "$home/fake-tasks/$task/held")" "row is held"
  assert_equals "captain" "$(cat "$home/fake-tasks/$task/hold_kind")" "hold kind is captain"
  assert_contains "$(cat "$home/fake-tasks/$task/reason")" "merge is not done" \
    "hold reason carries DoD evidence"
  assert_not_contains "$(cat "$home/fake-tasks/$task/reason")" "(" \
    "hold reason has no parentheses"
  assert_equals "family-meal-planner" "$(cat "$home/fake-tasks/$task/repo")" \
    "add used the event project as repo"
  assert_contains "$(cat "$home/fake-tasks/$task/body")" "Eggbot-event: fmp-2026-09-14-context-debt" \
    "task body records event provenance"
  assert_contains "$(cat "$home/fake-tasks/$task/body")" "Definition of done:" \
    "task body includes definition of done"
  assert_grep "show $task --full" "$home/fake-tasks/log" \
    "show uses id then --full"
  assert_grep "add $task " "$home/fake-tasks/log" \
    "add places the task id before flags"
  assert_grep "update $task " "$home/fake-tasks/log" \
    "update places the task id before --body-file"
  if grep -E '(^|[[:space:]])--([[:space:]]|$)' "$home/fake-tasks/log" >/dev/null; then
    fail "tasks-axi 0.2.5 rejects a bare -- token, but ingest passed one: $(cat "$home/fake-tasks/log")"
  fi
  assert_equals "$(printf '## In flight\n\n## Queued\n\n## Done\n')" \
    "$(cat "$home/data/backlog.md")" \
    "ingest must not hand-edit data/backlog.md"
  pass "fm-eggbot-ingest: happy path creates a captain-held task"
}

test_reingest_is_idempotent() {
  local home out first second task=fmp-ctx-debt-replay
  home=$(make_home replay)
  write_event "$home" "week.json" "$(sample_event fmp-2026-09-14-replay "$task")"
  first=$(run_ingest "$home" ingest 2>&1) || fail "first ingest must succeed: $first"
  assert_contains "$first" "created=1" "first ingest creates the event"
  second=$(run_ingest "$home" ingest 2>&1) || fail "second ingest must succeed: $second"
  assert_contains "$second" "created=0" "re-ingest creates nothing"
  assert_contains "$second" "skipped=1" "re-ingest skips the processed event"
  assert_contains "$second" "failed=0" "re-ingest has no failures"
  add_count=$(grep -c '^add ' "$home/fake-tasks/log" || true)
  [ "$add_count" = 1 ] || fail "re-ingest must not add the task again (add count=$add_count)"
  pass "fm-eggbot-ingest: re-ingest is idempotent"
}

test_skip_already_processed_without_inbox_reread_side_effects() {
  local home out task=already-held
  home=$(make_home already)
  write_event "$home" "week.json" "$(sample_event already-processed-event "$task")"
  mkdir -p "$home/state/eggbot/processed"
  printf '%s\n' \
    'fm-eggbot-ingest-processed-v1' \
    'event_id=already-processed-event' \
    "task_id=$task" \
    'source=week.json' > "$home/state/eggbot/processed/already-processed-event"
  out=$(run_ingest "$home" ingest 2>&1) || fail "ingest of a processed event must succeed: $out"
  assert_contains "$out" "skipped=1" "already processed event is skipped"
  assert_contains "$out" "created=0" "already processed event is not created"
  assert_absent "$home/fake-tasks/$task" "skip must not add a task"
  pass "fm-eggbot-ingest: already processed events are skipped"
}

test_reject_bad_schema() {
  local home out rc=0
  home=$(make_home bad)
  write_event "$home" "bad.json" '{"schema":"nope","event_id":"x"}'
  out=$(run_ingest "$home" ingest 2>&1) || rc=$?
  expect_code 1 "$rc" "bad schema must fail ingest"
  assert_contains "$out" "schema must be the literal fm-eggbot-context-debt.v1" \
    "bad schema names the expected literal"
  assert_contains "$out" "failed=1" "bad schema is counted as failed"
  [ ! -e "$home/state/eggbot/processed/x" ] || fail "bad schema must not write a receipt"
  pass "fm-eggbot-ingest: bad schema is rejected"
}

test_reject_parentheses_in_reason() {
  local home out rc=0
  home=$(make_home parens)
  write_event "$home" "parens.json" '{
    "schema": "fm-eggbot-context-debt.v1",
    "event_id": "paren-event",
    "project": "family-meal-planner",
    "title": "debt",
    "debt": [{
      "id": "item",
      "summary": "x",
      "reason": "need evidence (path@commit)",
      "dod": {
        "merge_is_not_done": true,
        "require_green_ci": true,
        "closure": {"kind": "process_patch"}
      }
    }]
  }'
  out=$(run_ingest "$home" ingest 2>&1) || rc=$?
  expect_code 1 "$rc" "parentheses in reason must fail"
  assert_contains "$out" "must not contain parentheses" "parentheses are refused"
  pass "fm-eggbot-ingest: hold reasons with parentheses are refused"
}

test_check_invokes_ingest_when_inbox_has_work() {
  local home out task=check-held
  home=$(make_home check-work)
  write_event "$home" "week.json" "$(sample_event check-event "$task")"
  out=$(run_ingest "$home" check 2>&1) || fail "check must succeed: $out"
  assert_contains "$out" "eggbot: held 1 context-debt task(s)" \
    "check wakes when ingest holds a task"
  [ "$(wc -l <<<"$out" | tr -d '[:space:]')" = 1 ] || fail "check prints one wake line: $out"
  assert_present "$home/fake-tasks/$task/reason" "check-run ingest held the task"
  out=$(run_ingest "$home" check 2>&1) || fail "second check must succeed: $out"
  [ -z "$out" ] || fail "a proven no-op check must stay silent: $out"
  pass "fm-eggbot-ingest: check ingests inbox work and stays silent on a no-op"
}

test_check_silent_when_inbox_empty() {
  local home out
  home=$(make_home check-empty)
  out=$(run_ingest "$home" check 2>&1) || fail "empty check must succeed: $out"
  [ -z "$out" ] || fail "empty inbox must stay silent: $out"
  pass "fm-eggbot-ingest: empty inbox check is silent"
}

test_arm_writes_and_binds_and_disarm_removes() {
  local home out
  home=$(make_home arm)
  out=$(run_ingest "$home" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/eggbot.check.sh" "arm names the shim"
  assert_present "$home/state/eggbot.check.sh" "arm writes the check shim"
  assert_present "$home/state/eggbot.check-trust" "arm binds the shim"
  assert_present "$home/state/eggbot/inbox" "arm creates the producer drop path"
  assert_contains "$(cat "$home/state/eggbot.check.sh")" "fm-eggbot-ingest.sh check" \
    "shim dispatches check"
  # Match the literal shim assignment; HOME is expanded when the check runs.
  # shellcheck disable=SC2016
  assert_contains "$(cat "$home/state/eggbot.check.sh")" 'export PATH="$HOME/.local/bin:$PATH"' \
    "shim prepends the user install prefix for a bare watcher PATH"
  out=$(run_ingest "$home" arm 2>&1) || fail "re-arm must succeed: $out"
  out=$(run_ingest "$home" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/eggbot.check.sh" "disarm removes the shim"
  assert_absent "$home/state/eggbot.check-trust" "disarm removes the trust binding"
  assert_present "$home/state/eggbot/inbox" "disarm leaves the drop path"
  pass "fm-eggbot-ingest: arm binds the standing check and disarm removes it"
}

test_partial_create_repairs_body_before_receipt() {
  local home out rc=0 task=partial-body-task event=partial-body-event
  home=$(make_home partial)
  write_event "$home" "week.json" "$(sample_event "$event" "$task")"
  : > "$home/fake-tasks/fail-update-once"
  out=$(run_ingest "$home" ingest 2>&1) || rc=$?
  expect_code 1 "$rc" "a failed body update must fail ingest"
  assert_absent "$home/state/eggbot/processed/$event" \
    "failed body update must not write a receipt"
  assert_present "$home/fake-tasks/$task/body" "seed row exists after add"
  assert_contains "$(cat "$home/fake-tasks/$task/body")" "Eggbot-event: $event" \
    "add seeds event provenance"
  assert_not_contains "$(cat "$home/fake-tasks/$task/body")" "Definition of done:" \
    "failed update leaves the full body unwritten"
  out=$(run_ingest "$home" ingest 2>&1) || fail "retry after a failed body update must succeed: $out"
  assert_contains "$out" "created=1" "retry creates after repairing the body"
  assert_present "$home/state/eggbot/processed/$event" "receipt waits until the full body exists"
  assert_contains "$(cat "$home/fake-tasks/$task/body")" "Definition of done:" \
    "retry writes the full event body"
  pass "fm-eggbot-ingest: partial create repairs body before the receipt"
}

test_task_id_collision_is_refused() {
  local home out rc=0 task=release-check
  home=$(make_home collision)
  mkdir -p "$home/fake-tasks/$task"
  printf '%s\n' 'release audit' > "$home/fake-tasks/$task/title"
  printf '%s\n' 'ship' > "$home/fake-tasks/$task/kind"
  printf '%s\n' 'family-meal-planner' > "$home/fake-tasks/$task/repo"
  printf 'queued\n' > "$home/fake-tasks/$task/state"
  printf 'no\n' > "$home/fake-tasks/$task/held"
  printf '%s\n' '-' > "$home/fake-tasks/$task/hold_kind"
  printf '%s\n' 'unrelated release work' > "$home/fake-tasks/$task/body"
  write_event "$home" "week.json" "$(sample_event collide-event "$task")"
  out=$(run_ingest "$home" ingest 2>&1) || rc=$?
  expect_code 1 "$rc" "an unrelated task_id must fail ingest"
  assert_contains "$out" "already exists and is not eggbot event collide-event" \
    "collision names the existing task and event"
  assert_absent "$home/state/eggbot/processed/collide-event" \
    "collision must not write a receipt"
  assert_equals "no" "$(cat "$home/fake-tasks/$task/held")" "collision must not hold the foreign row"
  assert_equals "release audit" "$(cat "$home/fake-tasks/$task/title")" \
    "collision must not rewrite the foreign title"
  assert_equals "unrelated release work" "$(cat "$home/fake-tasks/$task/body")" \
    "collision must not rewrite the foreign body"
  pass "fm-eggbot-ingest: unrelated task_id collisions are refused"
}

test_leading_dash_title_is_rejected() {
  local home out rc=0
  home=$(make_home dash-title)
  write_event "$home" "dash.json" '{
    "schema": "fm-eggbot-context-debt.v1",
    "event_id": "dash-event",
    "project": "family-meal-planner",
    "title": "-n injected",
    "debt": [{
      "id": "item",
      "summary": "x",
      "reason": "merge is not done",
      "dod": {
        "merge_is_not_done": true,
        "require_green_ci": true,
        "closure": {"kind": "process_patch"}
      }
    }]
  }'
  out=$(run_ingest "$home" ingest 2>&1) || rc=$?
  expect_code 1 "$rc" "a leading-dash title must fail ingest"
  assert_contains "$out" "title must not start with a dash" "leading-dash titles are refused"
  assert_absent "$home/fake-tasks/log" "leading-dash title must not invoke tasks-axi"
  assert_absent "$home/fake-tasks/dash-event" "leading-dash title must not add a row"
  [ ! -e "$home/state/eggbot/processed/dash-event" ] || fail "leading-dash title must not write a receipt"
  pass "fm-eggbot-ingest: leading-dash titles cannot inject CLI options"
}

test_disarm_fails_closed_when_record_cannot_be_removed() {
  local home out rc=0
  home=$(make_home disarm-fail)
  run_ingest "$home" arm >/dev/null || fail "arm must succeed before a failing disarm"
  mkdir -p "$home/state/.eggbot-check/nested"
  out=$(run_ingest "$home" disarm 2>&1) || rc=$?
  expect_code 1 "$rc" "disarm must fail when the report record cannot be removed"
  assert_not_contains "$out" "disarmed:" "failed disarm must not report success"
  assert_contains "$out" "could not remove" "failed disarm names the stuck record"
  pass "fm-eggbot-ingest: disarm fails closed when removal fails"
}

test_ingest_bootstraps_home_local_bin() {
  local home out task=local-bin-task
  home=$(make_home local-bin)
  mkdir -p "$home/.local/bin"
  mv "$home/fakebin/tasks-axi" "$home/.local/bin/tasks-axi"
  write_event "$home" "week.json" "$(sample_event local-bin-event "$task")"
  out=$(PATH="$BASE_PATH" HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$INGEST" ingest 2>&1) || fail "ingest must find tasks-axi via HOME/.local/bin: $out"
  assert_contains "$out" "created=1" "PATH bootstrap still creates the event"
  assert_present "$home/state/eggbot/processed/local-bin-event" "PATH bootstrap writes a receipt"
  assert_equals "yes" "$(cat "$home/fake-tasks/$task/held")" "PATH bootstrap still holds the row"
  pass "fm-eggbot-ingest: ingest finds tasks-axi under HOME/.local/bin"
}

test_check_shim_bootstraps_home_local_bin() {
  local home out task=shim-path-task
  home=$(make_home shim-path)
  write_event "$home" "week.json" "$(sample_event shim-path-event "$task")"
  run_ingest "$home" arm >/dev/null || fail "arm must succeed before a shim PATH check"
  mkdir -p "$home/.local/bin"
  mv "$home/fakebin/tasks-axi" "$home/.local/bin/tasks-axi"
  out=$(PATH="$BASE_PATH" HOME="$home" "$home/state/eggbot.check.sh" 2>&1) \
    || fail "standing check shim must find tasks-axi via HOME/.local/bin: $out"
  assert_contains "$out" "eggbot: held 1 context-debt task(s)" \
    "shim PATH bootstrap still holds a task"
  assert_present "$home/state/eggbot/processed/shim-path-event" \
    "shim PATH bootstrap writes a receipt"
  pass "fm-eggbot-ingest: standing check shim finds tasks-axi under HOME/.local/bin"
}

test_help_and_usage
test_happy_path_creates_and_holds
test_reingest_is_idempotent
test_skip_already_processed_without_inbox_reread_side_effects
test_reject_bad_schema
test_reject_parentheses_in_reason
test_check_invokes_ingest_when_inbox_has_work
test_check_silent_when_inbox_empty
test_arm_writes_and_binds_and_disarm_removes
test_partial_create_repairs_body_before_receipt
test_task_id_collision_is_refused
test_leading_dash_title_is_rejected
test_disarm_fails_closed_when_record_cannot_be_removed
test_ingest_bootstraps_home_local_bin
test_check_shim_bootstraps_home_local_bin
