#!/usr/bin/env bash
# fm-eggbot-ingest.sh - ingest Grok Bot "dr eggbot" context-debt events into
# captain-held backlog tasks.
#
# Usage:
#   fm-eggbot-ingest.sh [ingest]
#   fm-eggbot-ingest.sh check
#   fm-eggbot-ingest.sh arm
#   fm-eggbot-ingest.sh disarm
#   fm-eggbot-ingest.sh --help
#
# PRODUCER CONTRACT. Eggbot atomically writes one JSON object per event into
# gitignored state/eggbot/inbox/ (create those directories if needed). Write a
# complete regular file under a name that does not yet exist in inbox/, then
# rename it into place as *.json so ingest never reads a partial object. Ignore
# names that begin with `.`. Schema name is the literal
# `fm-eggbot-context-debt.v1`. `event_id` is the idempotency key: a processed
# receipt at state/eggbot/processed/<event_id> makes a later ingest of the same
# event a no-op. Do not hand-edit data/backlog.md; ingest always goes through
# bin/fm-tasks-axi.sh add and then bin/fm-captain-hold.sh hold.
#
# SCHEMA fm-eggbot-context-debt.v1 (this header is the owner). Required:
#   schema     literal "fm-eggbot-context-debt.v1"
#   event_id   path-safe slug [A-Za-z0-9._-], no leading dot, length 1..64
#   project    one-line repo/project identity for `tasks-axi add --repo`;
#              must not start with `-`
#   title      one-line task title for `tasks-axi add`; must not start with `-`
#   debt       non-empty array of items
# Optional:
#   task_id    path-safe slug for the backlog row; default event_id
#   kind       ship | scout | captain; default ship
#   week       one-line week label for the task body
#   source     one-line producer label for the task body
# Each debt item requires:
#   id         path-safe slug
#   summary    one-line description
#   reason     one-line hold reason; parentheses are refused (captain-hold
#              / tasks-axi hold contract)
#   dod        object with:
#     merge_is_not_done     boolean; true means merge is not done
#     require_green_ci      boolean; true means green CI is required evidence
#     closure               object:
#       kind                process_patch | context_or_map
#       path                required for context_or_map; CONTEXT/map path
#       commit              optional; with path forms path@commit evidence
#     changelog_without_code  optional "blocker" | "ok"
#     contract_freeze       optional bool, or {required: bool, name?: string}
#     thrash                optional {days: int>=0, repeats: int>=0};
#                           days>=3 or repeats>=3 is hold-worthy evidence in
#                           the body, not a separate ingest decision
# Extra object keys are ignored so producers can extend without a bump.
#
# INGEST. Validates each inbox *.json, skips an event whose processed receipt
# already exists, then creates or resumes a backlog row. Creation seeds the
# row with a one-line `Eggbot-event: <event_id>` body via `tasks-axi add --body`
# so a crash before the full-body update is recoverable. An existing row is
# resumed only when that provenance line is present; any other occupant of
# `task_id` is a collision and is refused. The full event body is written with
# `update --body-file` and verified before hold. The processed receipt is
# written only after that body still contains both the provenance line and
# `Definition of done:`. CLI-bound producer strings must not start with `-`.
# tasks-axi 0.2.5 rejects a bare `--` token as an unknown flag, so ingest
# uses `show <id> --full`, `add <id> "<title>" --kind … --repo … --body …`,
# and `update <id> --body-file …`. Inbox files stay in place; the receipt
# is the skip key.
#
# CHECK. A standing watcher check: silent when inbox has no *.json, otherwise
# runs ingest. One wake line when new events were held, or when ingest failed;
# a proven no-op (zero new holds, no failure) stays silent. Arm writes
# state/eggbot.check.sh and binds it with fm-check-register.sh. ingest and
# check prepend $HOME/.local/bin to PATH when it is missing so a bare SSH or
# watcher PATH still finds tasks-axi. The generated shim also exports
# PATH="$HOME/.local/bin:$PATH" beside FM_HOME.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
EGGBOT_DIR="$STATE/eggbot"
INBOX="$EGGBOT_DIR/inbox"
PROCESSED="$EGGBOT_DIR/processed"
INGEST_LOCK="$EGGBOT_DIR/.ingest.lock"
RECORD="$STATE/.eggbot-check"
CHECK_ID=eggbot
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
TASKS_AXI_BIN="$SCRIPT_DIR/fm-tasks-axi.sh"
HOLD_BIN="$SCRIPT_DIR/fm-captain-hold.sh"
EVENT_PROVENANCE_PREFIX='Eggbot-event:'
FULL_BODY_MARK='Definition of done:'
SCHEMA_NAME=fm-eggbot-context-debt.v1
RECORD_SCHEMA=fm-eggbot-check-v1
PROCESSED_SCHEMA=fm-eggbot-ingest-processed-v1
MAX_BYTES=65536
MAX_LINE=240

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-eggbot-ingest.sh [ingest]   ingest unprocessed context-debt events from state/eggbot/inbox/
  fm-eggbot-ingest.sh check      run ingest when inbox has JSON; wake line unless a proven no-op
  fm-eggbot-ingest.sh arm        write and register state/eggbot.check.sh
  fm-eggbot-ingest.sh disarm     remove the check shim, its trust binding, and the report record
  fm-eggbot-ingest.sh --help     print this help

Producers atomically rename complete JSON into state/eggbot/inbox/*.json.
Schema name: fm-eggbot-context-debt.v1. See this script's header for the
field contract. Ingest creates backlog rows through fm-tasks-axi.sh add and
holds them with fm-captain-hold.sh hold; it never hand-edits data/backlog.md.
EOF
}

die_usage() {
  printf 'fm-eggbot-ingest: %s\n' "$1" >&2
  usage >&2
  exit 2
}

fail() {
  printf 'fm-eggbot-ingest: %s\n' "$*" >&2
  exit 1
}

# A non-interactive SSH or watcher PATH often lacks the user install prefix
# where tasks-axi lives. Prepend it when missing so fm-tasks-axi.sh can see it.
bootstrap_local_bin_path() {
  local extra="${HOME}/.local/bin"
  case ":$PATH:" in
    *":$extra:"*) ;;
    *)
      PATH="$extra:$PATH"
      export PATH
      ;;
  esac
}

record_epoch_now() {
  date +%s
}

record_read() {
  local line first=1
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

ensure_eggbot_dirs() {
  mkdir -p "$INBOX" "$PROCESSED" || return 1
  [ -d "$INBOX" ] && [ ! -L "$INBOX" ] || return 1
  [ -d "$PROCESSED" ] && [ ! -L "$PROCESSED" ] || return 1
}

inbox_json_files() {
  local f
  [ -d "$INBOX" ] || return 0
  for f in "$INBOX"/*.json; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "$(basename "$f")" in
      .*) continue ;;
    esac
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

validate_event() {  # <json-file> <out-dir>
  local json=$1 out=$2
  command -v python3 >/dev/null 2>&1 || {
    printf 'python3 is required to validate %s\n' "$SCHEMA_NAME" >&2
    return 1
  }
  python3 - "$json" "$out" "$SCHEMA_NAME" "$MAX_BYTES" <<'PY'
import json, os, re, sys

json_path, out_dir, schema_name, max_bytes_s = sys.argv[1:5]
max_bytes = int(max_bytes_s)
slug_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

def die(msg):
    sys.stderr.write("fm-eggbot-ingest: %s\n" % msg)
    sys.exit(2)

def one_line(name, value):
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        die("%s must be a non-empty one-line string" % name)
    if any(ord(ch) < 32 for ch in value):
        die("%s must not contain control characters" % name)
    return value

def cli_token(name, value):
    value = one_line(name, value)
    if value.startswith("-"):
        die("%s must not start with a dash" % name)
    return value

def slug(name, value):
    value = one_line(name, value)
    if not slug_re.match(value):
        die("%s must be a path-safe slug of 1..64 characters: %s" % (name, value))
    return value

def as_bool(name, value):
    if not isinstance(value, bool):
        die("%s must be a boolean" % name)
    return value

def as_nonneg_int(name, value):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        die("%s must be a non-negative integer" % name)
    return value

try:
    size = os.path.getsize(json_path)
except OSError as exc:
    die("cannot read %s: %s" % (json_path, exc))
if size > max_bytes:
    die("event file exceeds %s bytes" % max_bytes)
try:
    with open(json_path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    data = json.loads(raw)
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    die("invalid JSON: %s" % exc)

if not isinstance(data, dict):
    die("event must be a JSON object")
if data.get("schema") != schema_name:
    die("schema must be the literal %s" % schema_name)

event_id = slug("event_id", data.get("event_id"))
task_id = slug("task_id", data["task_id"]) if "task_id" in data else event_id
if task_id.startswith("-") or event_id.startswith("-"):
    die("task_id and event_id must not start with a dash")
project = cli_token("project", data.get("project"))
title = cli_token("title", data.get("title"))
kind = data.get("kind", "ship")
if kind not in ("ship", "scout", "captain"):
    die("kind must be ship, scout, or captain")
week = one_line("week", data["week"]) if "week" in data else ""
source = one_line("source", data["source"]) if "source" in data else ""

debt = data.get("debt")
if not isinstance(debt, list) or not debt:
    die("debt must be a non-empty array")

reasons = []
body_items = []
for i, item in enumerate(debt):
    prefix = "debt[%s]" % i
    if not isinstance(item, dict):
        die("%s must be an object" % prefix)
    item_id = slug("%s.id" % prefix, item.get("id"))
    summary = one_line("%s.summary" % prefix, item.get("summary"))
    reason = one_line("%s.reason" % prefix, item.get("reason"))
    if "(" in reason or ")" in reason:
        die("%s.reason must not contain parentheses" % prefix)
    dod = item.get("dod")
    if not isinstance(dod, dict):
        die("%s.dod must be an object" % prefix)
    merge_not_done = as_bool("%s.dod.merge_is_not_done" % prefix, dod.get("merge_is_not_done"))
    require_ci = as_bool("%s.dod.require_green_ci" % prefix, dod.get("require_green_ci"))
    closure = dod.get("closure")
    if not isinstance(closure, dict):
        die("%s.dod.closure must be an object" % prefix)
    closure_kind = closure.get("kind")
    if closure_kind not in ("process_patch", "context_or_map"):
        die("%s.dod.closure.kind must be process_patch or context_or_map" % prefix)
    path = closure.get("path")
    commit = closure.get("commit")
    if closure_kind == "context_or_map":
        path = one_line("%s.dod.closure.path" % prefix, path)
    elif path is not None:
        path = one_line("%s.dod.closure.path" % prefix, path)
    else:
        path = ""
    if commit is not None:
        commit = one_line("%s.dod.closure.commit" % prefix, commit)
    else:
        commit = ""
    if path and commit:
        evidence = "%s@%s" % (path, commit)
    elif path:
        evidence = path
    else:
        evidence = closure_kind

    changelog = dod.get("changelog_without_code")
    if changelog is not None and changelog not in ("blocker", "ok"):
        die("%s.dod.changelog_without_code must be blocker or ok" % prefix)

    freeze = dod.get("contract_freeze")
    freeze_line = ""
    if isinstance(freeze, bool):
        freeze_line = "required" if freeze else "not required"
    elif isinstance(freeze, dict):
        required = as_bool("%s.dod.contract_freeze.required" % prefix, freeze.get("required"))
        name = one_line("%s.dod.contract_freeze.name" % prefix, freeze["name"]) if "name" in freeze else ""
        freeze_line = "required" if required else "not required"
        if name:
            freeze_line = "%s %s" % (name, freeze_line)
    elif freeze is not None:
        die("%s.dod.contract_freeze must be a boolean or object" % prefix)

    thrash = dod.get("thrash")
    thrash_line = ""
    thrash_hold = False
    if isinstance(thrash, dict):
        days = as_nonneg_int("%s.dod.thrash.days" % prefix, thrash.get("days"))
        repeats = as_nonneg_int("%s.dod.thrash.repeats" % prefix, thrash.get("repeats"))
        thrash_line = "%sd/%sx" % (days, repeats)
        thrash_hold = days >= 3 or repeats >= 3
    elif thrash is not None:
        die("%s.dod.thrash must be an object" % prefix)

    reasons.append(reason)
    lines = [
        "### %s" % item_id,
        summary,
        reason,
        "- merge is not done: %s" % ("yes" if merge_not_done else "no"),
        "- require green CI: %s" % ("yes" if require_ci else "no"),
        "- closure: %s %s" % (closure_kind, evidence),
    ]
    if changelog:
        lines.append("- changelog without code: %s" % changelog)
    if freeze_line:
        lines.append("- contract freeze: %s" % freeze_line)
    if thrash_line:
        extra = " hold-worthy" if thrash_hold else ""
        lines.append("- thrash: %s%s" % (thrash_line, extra))
    body_items.append("\n".join(lines))

if len(reasons) == 1:
    hold_reason = reasons[0]
else:
    hold_reason = "eggbot context debt: " + "; ".join(reasons)
if "(" in hold_reason or ")" in hold_reason:
    die("composed hold reason must not contain parentheses")
if len(hold_reason) > 500:
    die("composed hold reason exceeds 500 characters")

body_lines = [
    "Eggbot-event: %s" % event_id,
    "Eggbot context-debt event %s." % event_id,
    "Project: %s" % project,
]
if week:
    body_lines.append("Week: %s" % week)
if source:
    body_lines.append("Source: %s" % source)
body_lines.extend([
    "",
    "Definition of done:",
    "- Merge is not done. Need green CI plus a process patch or a CONTEXT/map update named as path@commit.",
    "- CHANGELOG without a matching code change is a blocker when an item marks it so.",
    "- Contract-freeze items stay frozen until an explicit unfreeze.",
    "- Thrash of 3 days or 3 repeats is hold-worthy evidence.",
    "",
    "Items:",
    "",
])
body_lines.append("\n\n".join(body_items))
body = "\n".join(body_lines) + "\n"

os.makedirs(out_dir, exist_ok=True)
for name, value in (
    ("event_id", event_id),
    ("task_id", task_id),
    ("project", project),
    ("title", title),
    ("kind", kind),
    ("reason", hold_reason),
    ("body", body),
):
    with open(os.path.join(out_dir, name), "w", encoding="utf-8") as fh:
        fh.write(value)
PY
}

processed_path() {  # <event_id>
  printf '%s/%s\n' "$PROCESSED" "$1"
}

event_already_processed() {  # <event_id>
  local path
  path=$(processed_path "$1")
  [ -f "$path" ] && [ ! -L "$path" ]
}

write_processed() {  # <event_id> <task_id> <source-basename>
  local event_id=$1 task_id=$2 source=$3 dest tmp
  dest=$(processed_path "$event_id")
  tmp=$(umask 077; mktemp "$PROCESSED/.fm-eggbot-processed.XXXXXX") || return 1
  {
    printf '%s\n' "$PROCESSED_SCHEMA"
    printf 'event_id=%s\n' "$event_id"
    printf 'task_id=%s\n' "$task_id"
    printf 'source=%s\n' "$source"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

task_show_full() {  # <task_id>
  "$TASKS_AXI_BIN" show "$1" --full 2>/dev/null
}

task_exists() {  # <task_id>
  local out
  out=$(task_show_full "$1") || return 1
  printf '%s\n' "$out" | grep -q '^  state: '
}

event_provenance_needle() {  # <event_id>
  printf '%s %s' "$EVENT_PROVENANCE_PREFIX" "$1"
}

task_has_event_provenance() {  # <task_id> <event_id>
  local out
  out=$(task_show_full "$1") || return 1
  printf '%s\n' "$out" | grep -F -- "$(event_provenance_needle "$2")" >/dev/null
}

task_has_full_event_body() {  # <task_id> <event_id>
  local out
  out=$(task_show_full "$1") || return 1
  printf '%s\n' "$out" | grep -F -- "$(event_provenance_needle "$2")" >/dev/null || return 1
  printf '%s\n' "$out" | grep -F -- "$FULL_BODY_MARK" >/dev/null
}

add_task() {  # <task_id> <title> <kind> <project> <event_id>
  local seed
  seed=$(event_provenance_needle "$5")
  "$TASKS_AXI_BIN" add "$1" "$2" --kind "$3" --repo "$4" --body "$seed" >/dev/null
}

repair_body() {  # <task_id> <body-file>
  "$TASKS_AXI_BIN" update "$1" --body-file "$2" >/dev/null
}

hold_task() {  # <task_id> <reason>
  "$HOLD_BIN" hold "$1" --reason "$2" >/dev/null
}

INGEST_LOCK_HELD=0
ingest_cleanup() {
  if [ "$INGEST_LOCK_HELD" = 1 ]; then
    fm_lock_release "$INGEST_LOCK" || true
    INGEST_LOCK_HELD=0
  fi
}

process_event_file() {  # <json-file>; sets PROCESS_RESULT=created|skipped|failed
  local json=$1 parsed event_id task_id project title kind reason rc=0
  PROCESS_RESULT=failed
  parsed=$(mktemp -d "${TMPDIR:-/tmp}/fm-eggbot-parsed.XXXXXX") || return 1
  if ! validate_event "$json" "$parsed" 2>"$parsed.err"; then
    cat "$parsed.err" >&2
    rm -rf -- "$parsed" "$parsed.err"
    return 1
  fi
  rm -f -- "$parsed.err"
  event_id=$(cat "$parsed/event_id")
  task_id=$(cat "$parsed/task_id")
  project=$(cat "$parsed/project")
  title=$(cat "$parsed/title")
  kind=$(cat "$parsed/kind")
  reason=$(cat "$parsed/reason")
  if event_already_processed "$event_id"; then
    rm -rf -- "$parsed"
    PROCESS_RESULT=skipped
    return 0
  fi
  if task_exists "$task_id"; then
    if ! task_has_event_provenance "$task_id" "$event_id"; then
      rm -rf -- "$parsed"
      printf 'fm-eggbot-ingest: task %s already exists and is not eggbot event %s\n' \
        "$task_id" "$event_id" >&2
      return 1
    fi
  else
    add_task "$task_id" "$title" "$kind" "$project" "$event_id" || rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -rf -- "$parsed"
      printf 'fm-eggbot-ingest: could not add task %s for event %s\n' "$task_id" "$event_id" >&2
      return 1
    fi
  fi
  if ! task_has_full_event_body "$task_id" "$event_id"; then
    repair_body "$task_id" "$parsed/body" || rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -rf -- "$parsed"
      printf 'fm-eggbot-ingest: could not write the event body on task %s for event %s\n' \
        "$task_id" "$event_id" >&2
      return 1
    fi
  fi
  if ! task_has_full_event_body "$task_id" "$event_id"; then
    rm -rf -- "$parsed"
    printf 'fm-eggbot-ingest: task %s body is missing event %s provenance\n' \
      "$task_id" "$event_id" >&2
    return 1
  fi
  if ! hold_task "$task_id" "$reason"; then
    rm -rf -- "$parsed"
    printf 'fm-eggbot-ingest: could not hold task %s for event %s\n' "$task_id" "$event_id" >&2
    return 1
  fi
  if ! task_has_full_event_body "$task_id" "$event_id"; then
    rm -rf -- "$parsed"
    printf 'fm-eggbot-ingest: task %s lost event %s body before the processed receipt\n' \
      "$task_id" "$event_id" >&2
    return 1
  fi
  if ! write_processed "$event_id" "$task_id" "$(basename "$json")"; then
    rm -rf -- "$parsed"
    printf 'fm-eggbot-ingest: could not record processed receipt for %s\n' "$event_id" >&2
    return 1
  fi
  rm -rf -- "$parsed"
  PROCESS_RESULT=created
  printf 'held: %s event=%s\n' "$task_id" "$event_id"
  return 0
}

action_ingest() {
  local file created=0 skipped=0 failed=0
  bootstrap_local_bin_path
  ensure_eggbot_dirs || fail "cannot create $EGGBOT_DIR"
  mkdir -p "$DATA" || fail "cannot create data directory $DATA"
  [ -x "$TASKS_AXI_BIN" ] || fail "fm-tasks-axi.sh is missing at $TASKS_AXI_BIN"
  [ -x "$HOLD_BIN" ] || fail "fm-captain-hold.sh is missing at $HOLD_BIN"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to validate $SCHEMA_NAME"
  fm_lock_acquire_wait "$INGEST_LOCK" || fail "cannot lock eggbot ingest"
  INGEST_LOCK_HELD=1
  trap ingest_cleanup EXIT
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    PROCESS_RESULT=failed
    if process_event_file "$file"; then
      case "$PROCESS_RESULT" in
        created) created=$((created + 1)) ;;
        skipped) skipped=$((skipped + 1)) ;;
      esac
    else
      failed=$((failed + 1))
    fi
  done < <(inbox_json_files)
  printf 'ingested created=%s skipped=%s failed=%s\n' "$created" "$skipped" "$failed"
  ingest_cleanup
  trap - EXIT
  [ "$failed" -eq 0 ]
}

action_check() {
  local out rc=0 line files created=0
  bootstrap_local_bin_path
  mkdir -p "$STATE" || return 1
  ensure_eggbot_dirs 2>/dev/null || {
    line="cannot create eggbot drop path under $STATE"
    record_read
    if [ "$line" != "$RECORD_REPORTED" ]; then
      fm_cap_line_var "eggbot: $line" "$MAX_LINE"
      printf '%s\n' "$FM_LINE_CAP_LINE"
    fi
    record_write "$line" || true
    return 0
  }
  files=$(inbox_json_files)
  if [ -z "$files" ]; then
    record_write "" || true
    return 0
  fi
  out=$(action_ingest 2>&1) || rc=$?
  created=$(printf '%s\n' "$out" | sed -n 's/^ingested created=\([0-9][0-9]*\) skipped=.*/\1/p' | tail -n 1)
  case "$created" in
    ''|*[!0-9]*) created=0 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    line=$(printf '%s\n' "$out" | sed -n '/^fm-eggbot-ingest: /s/^fm-eggbot-ingest: //p' | head -n 1)
    [ -n "$line" ] || line="ingest failed"
    line="ingest failed: $line"
  elif [ "$created" -gt 0 ]; then
    line="held $created context-debt task(s)"
  else
    line=
  fi
  record_read
  if [ -n "$line" ] && [ "$line" != "$RECORD_REPORTED" ]; then
    fm_cap_line_var "eggbot: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  record_write "$line" || true
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-eggbot-ingest.sh - eggbot context-debt poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    'export PATH="$HOME/.local/bin:$PATH"' \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-eggbot-ingest.sh") check"
}

SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-eggbot-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-eggbot-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-eggbot-ingest: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  ensure_eggbot_dirs || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-eggbot-ingest: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-eggbot-ingest: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-eggbot-ingest: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-eggbot-ingest: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'fm-eggbot-ingest: state directory is unavailable\n' >&2
    return 1
  }
  if ! "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null; then
    printf 'fm-eggbot-ingest: could not unregister %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    if ! rm -f -- "$RECORD" || [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
      printf 'fm-eggbot-ingest: could not remove %s\n' "$RECORD" >&2
      return 1
    fi
  fi
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-ingest}" in
  ingest) action_ingest ;;
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
