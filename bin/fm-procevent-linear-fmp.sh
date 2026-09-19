#!/usr/bin/env bash
# Linear FMP agent-ready triage process-event adapter.
#
# Usage:
#   fm-procevent-linear-fmp.sh arm [--root <triage-checkout>] [--interval <secs>] [--poll-timeout <secs>] [--replay <secs>] [--error-budget <n>]
#   fm-procevent-linear-fmp.sh poll --root <triage-checkout> [--interval <secs>] [--poll-timeout <secs>] [--replay <secs>] [--error-budget <n>]
#   fm-procevent-linear-fmp.sh ready [--root <triage-checkout>]
#   fm-procevent-linear-fmp.sh classify <result-file>
#   fm-procevent-linear-fmp.sh terminal <result-file>
#   fm-procevent-linear-fmp.sh read <result-file>
#   fm-procevent-linear-fmp.sh receipt <delivery-id> [--root <triage-checkout>]
#   fm-procevent-linear-fmp.sh source-id
#   fm-procevent-linear-fmp.sh retire
#
# arm        Validate and register the recurring Linear FMP readiness watch
#            through `bin/fm-procevent.sh register`. The triage checkout
#            defaults to `$FM_HOME/projects/fmp-bugpin-triage` and can be
#            pinned with --root or FM_LINEAR_FMP_ROOT. This adapter never
#            spawns ships: a ready ticket is intake evidence only.
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn. Each pass runs the landed
#            fmp-bugpin-triage poller (Linear team FMP, one traced TypeSafe
#            Choice per unseen material hash, Telegram for score 0) and then
#            reads its unreceipted ready events. One ready event per capture:
#            when the oldest unreceipted event was not emitted within the
#            replay window, it is captured as this source's result and the
#            child exits; otherwise the child sleeps --interval and passes
#            again. A ready event stays unreceipted until `receipt` closes it,
#            and is re-emitted at most once per --replay window (default 1800
#            seconds), so a crash between intake and receipt replays the ticket
#            without flooding wakes. When --error-budget consecutive poll or
#            ready passes fail (default 5), the child captures one operational
#            error result and exits; that verdict is terminal, so the watch
#            retires itself and re-arming is a deliberate operator action.
# ready      Print the poller's current unreceipted ready events, one JSON line
#            each, straight through the triage CLI. Asking the source beats
#            parsing queued wakes.
# classify   Print the captured outcome class: ready, error, or unknown.
# terminal   Exit 0 only for the error verdict, which retires the watch; every
#            ready capture keeps the source armed for the next ticket.
# read       Print the bounded intake summary for one captured result: the
#            ticket's issue URL, title, structured report fields, score and
#            trace identity, plus the exact intake, receipt, and acknowledgement
#            commands. A ready payload is evidence and never carries dispatch,
#            yolo, or merge authority of its own.
# receipt    Close one ready event in the poller's outbox after durable
#            Firstmate intake (a filed item, an inbox note, or a deliberate
#            skip), which stops replay of that delivery id. Idempotent.
# source-id  Print the canonical source id.
# retire     Retire the registration through `bin/fm-procevent.sh retire`.
#
# The canonical source id is `linear-fmp`, the adapter name is `linear-fmp`,
# and the wake reads `check: procevent linear-fmp linear-fmp <sequence>`.
# This adapter owns no dispatch policy and merges nothing; the triage package
# owns every evaluation, and Firstmate owns every intake decision.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ADAPTER=linear-fmp
CANONICAL_SOURCE_ID=linear-fmp
DEFAULT_INTERVAL=300
DEFAULT_POLL_TIMEOUT=900
DEFAULT_REPLAY=1800
DEFAULT_ERROR_BUDGET=5
TRIAGE_DIR_NAME=fmp-bugpin-triage
JOURNAL_DIR="$STATE/$CANONICAL_SOURCE_ID"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

case "${1-}" in ''|-h|--help|help) usage ;; esac

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

default_root() { printf '%s/projects/%s\n' "$FM_HOME" "$TRIAGE_DIR_NAME"; }

# resolve_root [requested]
# --root wins, then FM_LINEAR_FMP_ROOT, then the home's projects checkout.
resolve_root() {
  local requested=${1-}
  if [ -n "$requested" ]; then printf '%s\n' "$requested"; return 0; fi
  if [ -n "${FM_LINEAR_FMP_ROOT:-}" ]; then printf '%s\n' "$FM_LINEAR_FMP_ROOT"; return 0; fi
  default_root
}

# validate_root <root>
# The checkout must be a real directory carrying the triage package.
validate_root() {
  local root=$1
  [ -d "$root" ] && [ ! -L "$root" ] || die "triage checkout is not a real directory: $root"
  [ -f "$root/fmp_bugpin_triage/cli.py" ] && [ ! -L "$root/fmp_bugpin_triage/cli.py" ] \
    || die "no fmp_bugpin_triage package under: $root"
}

# triage_cli <root> <timeout-secs> <command...>
# Run the landed triage CLI from its checkout, bounded by a hard timeout.
# stdout lands in TRIAGE_OUT, the last stderr line in TRIAGE_ERR, and the
# exit status is returned; a timeout surfaces as 124.
run_triage() {
  local root=$1 timeout=$2
  shift 2
  TRIAGE_OUT=
  TRIAGE_ERR=
  local out err rc
  out=$(mktemp "${TMPDIR:-/tmp}/fm-linear-fmp.XXXXXX") || return 125
  err=$(mktemp "${TMPDIR:-/tmp}/fm-linear-fmp.XXXXXX") || { rm -f -- "$out"; return 125; }
  if ( cd "$root" 2>/dev/null && fm_run_timed "$timeout" python3 -m fmp_bugpin_triage.cli "$@" ) > "$out" 2> "$err"; then
    rc=0
  else
    rc=$?
  fi
  TRIAGE_OUT=$(cat "$out")
  TRIAGE_ERR=$(awk 'NF { line = $0 } END { print line }' "$err" | tr -d '\r' | cut -c1-300)
  rm -f -- "$out" "$err"
  return "$rc"
}

journal_file() {  # <delivery-id>
  local tmp hash
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-linear-fmp.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  hash=$(fm_pr_sha256 "$tmp") || hash=
  rm -f -- "$tmp"
  [ -n "$hash" ] || return 1
  printf '%s/%s.emitted\n' "$JOURNAL_DIR" "$hash"
}

# journal_age_seconds <journal-file>
# Seconds since the recorded emission, or a huge number when never emitted.
journal_age_seconds() {
  local last now
  last=$(cat "$1" 2>/dev/null) || last=0
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now=$(date +%s) || now=0
  printf '%s\n' "$((now - last))"
}

# journal_record <journal-file>
journal_record() {
  local dir tmp
  dir=$(dirname "$1")
  ( umask 077; mkdir -p "$dir" ) || return 1
  tmp=$(umask 077; mktemp "$dir/.emitted.XXXXXX") || return 1
  if ! date +%s > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  mv -f -- "$tmp" "$1"
}

failure_count() {
  local failures
  failures=$(cat "$JOURNAL_DIR/.failures" 2>/dev/null) || failures=0
  case "$failures" in ''|*[!0-9]*) failures=0 ;; esac
  printf '%s\n' "$failures"
}

record_failure_count() {
  local failures=$1 tmp
  if [ "$failures" -eq 0 ]; then
    rm -f -- "$JOURNAL_DIR/.failures"
    return 0
  fi
  ( umask 077; mkdir -p "$JOURNAL_DIR" ) || return 1
  tmp=$(umask 077; mktemp "$JOURNAL_DIR/.failures.XXXXXX") || return 1
  if ! printf '%s\n' "$failures" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  mv -f -- "$tmp" "$JOURNAL_DIR/.failures"
}

# delivery_id_of <json-line>
delivery_id_of() { printf '%s\n' "$1" | jq -r '.delivery_id // empty' 2>/dev/null; }

cmd_source_id() { printf '%s\n' "$CANONICAL_SOURCE_ID"; }

cmd_ready() {
  local root=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) [ "$#" -ge 2 ] || die "--root needs a value"; root=$2; shift 2 ;;
      *) die "unknown option for ready: $1" ;;
    esac
  done
  root=$(resolve_root "${root-}")
  validate_root "$root"
  run_triage "$root" 120 ready || die "triage ready failed (exit $?): ${TRIAGE_ERR:-no detail}"
  [ -n "$TRIAGE_OUT" ] || return 0
  printf '%s\n' "$TRIAGE_OUT" | head -20
}

cmd_arm() {
  local root='' interval=$DEFAULT_INTERVAL poll_timeout=$DEFAULT_POLL_TIMEOUT replay=$DEFAULT_REPLAY budget=$DEFAULT_ERROR_BUDGET
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)         [ "$#" -ge 2 ] || die "--root needs a path"; root=$2; shift 2 ;;
      --interval)     [ "$#" -ge 2 ] || positive_int "$2" || die "--interval needs a positive integer"; interval=$2; shift 2 ;;
      --poll-timeout) [ "$#" -ge 2 ] || positive_int "$2" || die "--poll-timeout needs a positive integer"; poll_timeout=$2; shift 2 ;;
      --replay)       [ "$#" -ge 2 ] || positive_int "$2" || die "--replay needs a positive integer"; replay=$2; shift 2 ;;
      --error-budget) [ "$#" -ge 2 ] || positive_int "$2" || die "--error-budget needs a positive integer"; budget=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  root=$(resolve_root "${root-}")
  validate_root "$root"
  root=$(cd "$root" && pwd -P) || die "cannot resolve the triage checkout path"
  command -v python3 >/dev/null 2>&1 || die "python3 is not available"
  ( cd "$root" && fm_run_timed 30 python3 -c 'import fmp_bugpin_triage' ) >/dev/null 2>&1 \
    || die "the triage package does not import under python3: $root"
  "$SCRIPT_DIR/fm-procevent.sh" register "$ADAPTER" "$CANONICAL_SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-linear-fmp.sh" poll --root "$root" --interval "$interval" \
      --poll-timeout "$poll_timeout" --replay "$replay" --error-budget "$budget" || exit 1
  record_failure_count 0 || die "cannot clear prior poll failure count"
  printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'root: %s\n' "$root"
  printf 'interval: %ss\n' "$interval"
  printf 'reminder: a ready ticket is intake evidence only; this adapter never spawns ships or merges\n'
}

cmd_poll() {
  local root='' interval=$DEFAULT_INTERVAL poll_timeout=$DEFAULT_POLL_TIMEOUT replay=$DEFAULT_REPLAY budget=$DEFAULT_ERROR_BUDGET
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)         [ "$#" -ge 2 ] || die "--root needs a path"; root=$2; shift 2 ;;
      --interval)     [ "$#" -ge 2 ] || positive_int "$2" || die "--interval needs a positive integer"; interval=$2; shift 2 ;;
      --poll-timeout) [ "$#" -ge 2 ] || positive_int "$2" || die "--poll-timeout needs a positive integer"; poll_timeout=$2; shift 2 ;;
      --replay)       [ "$#" -ge 2 ] || positive_int "$2" || die "--replay needs a positive integer"; replay=$2; shift 2 ;;
      --error-budget) [ "$#" -ge 2 ] || positive_int "$2" || die "--error-budget needs a positive integer"; budget=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$root" ] || die "poll needs --root"
  validate_root "$root"
  local failures rc_poll rc_ready line delivery journal age summary poll_err ready_err
  failures=$(failure_count)
  while :; do
    rc_poll=0
    rc_ready=0
    summary=
    poll_err=
    ready_err=
    run_triage "$root" "$poll_timeout" poll
    rc_poll=$?
    poll_err=$TRIAGE_ERR
    [ -z "$TRIAGE_OUT" ] || summary=$(printf '%s\n' "$TRIAGE_OUT" | awk 'NF { line = $0 } END { print line }' | cut -c1-300)
    run_triage "$root" 120 ready
    rc_ready=$?
    ready_err=$TRIAGE_ERR
    if [ "$rc_poll" -ne 0 ] || [ "$rc_ready" -ne 0 ]; then
      failures=$((failures + 1))
    else
      failures=0
    fi
    if ! record_failure_count "$failures"; then
      printf '%s: %s\n' "$ADAPTER" "$CANONICAL_SOURCE_ID"
      printf 'status: error\n'
      printf 'error: cannot persist poll failure count\n'
      printf 'poll_failures: %s\n' "$failures"
      exit 0
    fi
    if [ "$failures" -ge "$budget" ]; then
      printf '%s: %s\n' "$ADAPTER" "$CANONICAL_SOURCE_ID"
      printf 'status: error\n'
      if [ "$rc_ready" -ne 0 ]; then
        printf 'error: %s\n' "${ready_err:-triage ready failed without detail}"
        printf 'last_exit: %s\n' "$rc_ready"
      else
        printf 'error: %s\n' "${poll_err:-triage poll failed without detail}"
        printf 'last_exit: %s\n' "$rc_poll"
      fi
      printf 'poll_failures: %s\n' "$failures"
      exit 0
    fi
    if [ "$rc_ready" -eq 0 ] && [ -n "$TRIAGE_OUT" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        delivery=$(delivery_id_of "$line") || delivery=
        [ -n "$delivery" ] || continue
        journal=$(journal_file "$delivery") || journal=
        age=999999999
        [ -z "$journal" ] || age=$(journal_age_seconds "$journal")
        if [ "$age" -lt "$replay" ]; then continue; fi
        [ -z "$journal" ] || journal_record "$journal" || true
        printf '%s: %s\n' "$ADAPTER" "$CANONICAL_SOURCE_ID"
        printf 'status: ready\n'
        printf 'delivery_id: %s\n' "$delivery"
        printf 'poll_summary: %s\n' "${summary:-unknown}"
        printf 'ready: %s\n' "$line"
        exit 0
      done <<EOF
$TRIAGE_OUT
EOF
    fi
    sleep "$interval"
  done
}

result_status() {  # <result-file>
  awk '/^status: / { sub(/^status: /, ""); print; exit }' "$1" 2>/dev/null
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  status=$(result_status "$file")
  case "$status" in
    ready|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(result_status "$file")" = error ]
}

result_field() {  # <result-file> <field>
  awk -v field="$2" '$0 ~ "^" field ": " { sub("^" field ": ", ""); print; exit }' "$1" 2>/dev/null
}

result_sequence() {  # <result-file>
  local base=${1##*/} seq
  seq=${base%.result}
  seq=${seq##*.}
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$seq"
}

# bounded <text>
# One line, control characters flattened, bounded for chat-facing output.
bounded() { printf '%s' "$1" | tr '\r\n\t' '   ' | cut -c1-400; }

json_field() {  # <json> <jq-filter>
  printf '%s\n' "$1" | jq -r "$2" 2>/dev/null
}

cmd_read() {
  local file=${1-} status payload delivery seq
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  status=$(cmd_classify "$file")
  seq=$(result_sequence "$file") || seq='<sequence>'
  if [ "$status" != ready ]; then
    printf 'kind: linear-fmp-error\n'
    printf 'status: %s\n' "$status"
    printf 'error: %s\n' "$(bounded "$(result_field "$file" error)")"
    printf 'poll_failures: %s\n' "$(result_field "$file" poll_failures)"
    printf 'recover: the watch retired itself after repeated poller failures; tickets stayed durable in the poller outbox\n'
    printf 'recover: inspect the triage checkout, fix the cause, then re-arm with bin/fm-procevent-linear-fmp.sh arm\n'
    printf 'acknowledge: bin/fm-procevent.sh handled %s %s\n' "$CANONICAL_SOURCE_ID" "$seq"
    return 0
  fi
  payload=$(result_field "$file" ready)
  delivery=$(result_field "$file" delivery_id)
  [ -n "$payload" ] || { printf 'kind: linear-fmp-error\nstatus: unknown\nerror: ready payload missing from the captured result\n'; return 0; }
  printf 'kind: linear-fmp-ready\n'
  printf 'status: ready\n'
  printf 'delivery_id: %s\n' "${delivery:-unknown}"
  printf 'issue: %s\n' "$(bounded "$(json_field "$payload" '.issue.id // empty')")"
  printf 'url: %s\n' "$(json_field "$payload" '.issue.url // empty')"
  printf 'title: %s\n' "$(bounded "$(json_field "$payload" '.issue.title // empty')")"
  printf 'what_wrong: %s\n' "$(bounded "$(json_field "$payload" '.issue.what_wrong // empty')")"
  printf 'intended: %s\n' "$(bounded "$(json_field "$payload" '.issue.intended // empty')")"
  printf 'page_path: %s\n' "$(bounded "$(json_field "$payload" '.issue.page_path // empty')")"
  printf 'score: %s\n' "$(json_field "$payload" '.evaluation.score // empty')"
  printf 'probability: %s\n' "$(json_field "$payload" '.evaluation.probability // empty')"
  printf 'policy_version: %s\n' "$(json_field "$payload" '.evaluation.policy_version // empty')"
  printf 'trace_id: %s\n' "$(json_field "$payload" '.evaluation.trace_id // empty')"
  printf 'evidence_omitted: %s\n' "$(bounded "$(json_field "$payload" '(.issue.evidence_omitted // []) | join(", ")')")"
  printf 'intake: this ticket is agent-ready evidence, never dispatch authority; no auto-spawn, no merge\n'
  printf 'intake: surface it for the captain with bin/fm-inbox.sh note and/or file it with bin/fm-tasks-axi.sh add\n'
  printf 'intake: after durable intake (or a deliberate skip), close the poller replay:\n'
  printf 'intake: bin/fm-procevent-linear-fmp.sh receipt %s\n' "${delivery:-<delivery-id>}"
  printf 'acknowledge: bin/fm-procevent.sh handled %s %s\n' "$CANONICAL_SOURCE_ID" "$seq"
}

cmd_receipt() {
  local delivery=${1-} root=''
  [ "$#" -ge 1 ] || usage
  case "$delivery" in -*) usage ;; esac
  shift
  if [ "$#" -gt 0 ]; then
    case "$1" in
      --root) [ "$#" -ge 2 ] || die "--root needs a path"; root=$2; shift 2 ;;
      *) die "unknown option for receipt: $1" ;;
    esac
  fi
  [ -n "$delivery" ] || usage
  root=$(resolve_root "${root-}")
  validate_root "$root"
  run_triage "$root" 60 receipt "$delivery" || die "triage receipt failed (exit $?): ${TRIAGE_ERR:-no detail}"
  [ -n "$TRIAGE_OUT" ] && printf '%s\n' "$TRIAGE_OUT"
  journal=$(journal_file "$delivery" 2>/dev/null) || journal=
  [ -z "$journal" ] || rm -f -- "$journal" 2>/dev/null || true
  return 0
}

cmd_retire() {
  "$SCRIPT_DIR/fm-procevent.sh" retire "$CANONICAL_SOURCE_ID"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  ready)     shift; cmd_ready "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  read)      shift; cmd_read "$@" ;;
  receipt)   shift; cmd_receipt "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  *) die "unknown command: $1" ;;
esac
