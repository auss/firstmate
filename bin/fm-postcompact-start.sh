#!/usr/bin/env bash
# PostCompact starter - the post-compaction half of the captain's compact
# hooks: the hook itself performs start. Neither harness delivers a
# PostCompact hook's stdout to the model, so it runs the compact-source
# session-start work with the wake drain's presentation marked undelivered
# (FM_WAKE_PRESENTATION_UNDELIVERED=1): the digest commits no one-shot
# unread-status, annotation, or outcome-backstop receipt against output
# nobody sees, and the tracked SessionStart hook - which Claude fires as
# source `compact` with model-visible stdout - remains the delivery channel
# for the digest and its full presentation.
# bin/fm-precompact-stow.sh's header owns the full compact-hook contract; see
# docs/sessionstart-nudge.md "Compaction hooks".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env FM_WAKE_PRESENTATION_UNDELIVERED=1 \
  "$SCRIPT_DIR/fm-sessionstart-run.sh" --source compact
