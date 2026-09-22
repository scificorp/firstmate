#!/usr/bin/env bash
# Live launch-command-delivery validation against the REAL product through an
# isolated Herdr lab session (bin/fm-herdr-lab.sh contract).
#
# The change under test is the spawn launch-command-delivery contract: a full
# launch command (the incident was a guarded Nungu API CI retry truncated
# before Claude started) must reach a real pane unchanged, through the staged
# /tmp/fm-<id>+<home-token>/launch.<gen>.sh source file, without truncation or
# destination-shell quoting drift, and the worker must start and reach
# processing.
#
# Scenarios:
#   A. A long, quoted raw launch command containing literal command-substitution
#      text is delivered to a real Herdr pane unchanged and executes in the
#      destination shell without truncation or substitution.
#   B. A claude-harness worker is launched fresh through the staged source-file
#      transport: the pane receives the short source line, the staged launch
#      carries the complete claude command with the brief path intact, and the
#      worker process starts and reaches processing in the lab pane.
#
# Everything runs in throwaway temp dirs and an fm-lab-* Herdr session; the
# default Herdr session is never touched and a fleet-state tripwire guards it.
set -u

ROOT=/Users/unarams/.no-mistakes/worktrees/558623ebb989/01M33ZXEVXY45A98PE3BWY7NPJ
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
OUT_DIR=/Users/unarams/.no-mistakes/evidence/01M33ZXEVXY45A98PE3BWY7NPJ

fail() { echo "FAIL: $*" >&2; cleanup; exit 1; }
note() { echo "== $*"; }

# --- isolated lab session ----------------------------------------------------
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

# Firstmate's documented test-harness escape hatch: this validation drives the
# real fm-spawn from a no-mistakes gate worktree (bin/fm-gate-refuse-lib.sh).
export FM_GATE_REFUSE_BYPASS=1
SESSION=$("$LAB_HELPER" name launch-delivery) || fail "could not name lab session"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-launch-live.XXXXXX") || fail "mktemp"

WORKTREES=()
CLEANED=0
cleanup() {
  local wt
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  rm -rf -- /tmp/fm-launch-live-* 2>/dev/null
  "$LAB_HELPER" teardown "$SESSION" || echo "WARN: lab teardown reported failure" >&2
  rm -rf "$TMP_ROOT"
  return 0
}
trap cleanup EXIT INT TERM

note "provision lab session $SESSION (provision owns prepare + fleet tripwire)"
"$LAB_HELPER" provision "$SESSION" || fail "provision failed"
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

# --- throwaway scratch world -------------------------------------------------
FMHOME=$TMP_ROOT/home
PROJ=$TMP_ROOT/project
mkdir -p "$FMHOME/state" "$FMHOME/config" "$FMHOME/data" "$FMHOME/projects"
touch "$FMHOME/state/.last-watcher-beat"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Live Validation' -c user.email='live@example.invalid' commit -qm initial
TASK_A=launch-live-raw-a1
TASK_B=launch-live-claude-b1
for id in "$TASK_A" "$TASK_B"; do
  mkdir -p "$FMHOME/data/$id"
  cat > "$FMHOME/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Disposable live validation of launch-command delivery for $id. Do nothing and remain idle.

## Firstmate spec
This brief exists only so the launch transport has a real file to stage.
EOF
done

spawn() { # <id> <launch...>
  local id=$1
  shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$FMHOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$@" 2>&1
}

meta_field() { grep "^$2=" "$FMHOME/state/$1.meta" 2>/dev/null | head -1 | cut -d= -f2-; }

pane_read() { # <pane-id>
  lab pane read "$1" --source recent --lines 200 2>/dev/null
}

# --- Scenario A: long quoted raw launch through a real Herdr pane -------------
note "Scenario A: long quoted raw launch with literal command-substitution text"
MARKER_A=$TMP_ROOT/marker-a.txt
PAD=$(python3 -c "print('A'*1800)")
PAYLOAD="prefix 'single quoted' \"double quoted\" literal command substitution \$(printf should-not-run) $PAD suffix-after-long-padding"
PAYLOAD_Q=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$PAYLOAD")
MARKER_Q=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$MARKER_A")
RAW="/bin/sh -c $(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "printf '%s\\n' $PAYLOAD_Q > $MARKER_Q")"

SPAWN_A_OUT=$TMP_ROOT/spawn-a.out
spawn "$TASK_A" "$PROJ" --mode no-mistakes --yolo off --harness "$RAW" --backend herdr >"$SPAWN_A_OUT" 2>&1 \
  || fail "scenario A spawn failed: $(cat "$SPAWN_A_OUT")"
WORKTREES+=("$(meta_field "$TASK_A" worktree)")
echo "-- spawn A transcript:"; cat "$SPAWN_A_OUT"

PANE_A=$(meta_field "$TASK_A" herdr_pane_id)
[ -n "$PANE_A" ] || fail "no herdr_pane_id recorded for $TASK_A: $(cat "$FMHOME/state/$TASK_A.meta" 2>/dev/null)"
note "task A pane: $PANE_A"

DEADLINE=$(( $(date +%s) + 90 ))
while [ ! -s "$MARKER_A" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do sleep 2; done
[ -s "$MARKER_A" ] || { pane_read "$PANE_A" > "$OUT_DIR/live-lab-scenario-a-pane-timeout.txt" || true; fail "marker never written; launch command did not execute in the pane"; }
DELIVERED=$(cat "$MARKER_A")
[ "$DELIVERED" = "$PAYLOAD" ] || fail "delivered payload differs from the intended launch payload"
case "$DELIVERED" in
  *'$(printf should-not-run)'*) : ;;
  *) fail "literal command-substitution text did not survive as literal text" ;;
esac
note "marker content matches payload byte-for-byte; substitution stayed literal"

pane_read "$PANE_A" > "$TMP_ROOT/pane-a.txt" || fail "pane read failed"
STAGED_A=$(ls -d /tmp/fm-"$TASK_A"+* 2>/dev/null | head -1)
[ -n "$STAGED_A" ] || fail "no staged launch namespace /tmp/fm-$TASK_A+*"
STAGED_A_FILE=$(find "$STAGED_A" -name 'launch*' -type f 2>/dev/null | head -1)
[ -n "$STAGED_A_FILE" ] || fail "no staged launch file under $STAGED_A"
cat "$STAGED_A_FILE" > "$OUT_DIR/live-lab-scenario-a-staged-launch.txt"
case "$(cat "$STAGED_A_FILE")" in
  *'suffix-after-long-padding'*) : ;;
  *) fail "staged launch lost the long-command suffix; transport truncated it" ;;
esac
LIT_SUB='$(printf should-not-run)'
case "$(cat "$STAGED_A_FILE")" in
  *"$LIT_SUB"*) : ;;
  *) fail "staged launch lost the literal command-substitution text" ;;
esac
if grep -q "^\. '.*launch" "$TMP_ROOT/pane-a.txt"; then
  note "pane received the staged short source line (not a typed long literal)"
  grep "^\. '.*launch" "$TMP_ROOT/pane-a.txt" | head -1 > "$TMP_ROOT/pane-a-source-line.txt" || true
else
  note "NOTE: staged source line not visible in recent capture (may have scrolled)"
fi
cp "$TMP_ROOT/pane-a.txt" "$OUT_DIR/live-lab-scenario-a-pane.txt"
note "Scenario A PASS"

# --- Scenario B: claude launch delivered via staged source file ---------------
note "Scenario B: claude worker starts fresh through the staged source and reaches processing"
CLAUDE_CONFIG_DIR_B=$TMP_ROOT/claude-config
mkdir -p "$CLAUDE_CONFIG_DIR_B"
SPAWN_B_OUT=$TMP_ROOT/spawn-b.out
CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_B" \
  spawn "$TASK_B" "$PROJ" --mode no-mistakes --yolo off claude --backend herdr >"$SPAWN_B_OUT" 2>&1 \
  || fail "scenario B spawn failed: $(cat "$SPAWN_B_OUT")"
WORKTREES+=("$(meta_field "$TASK_B" worktree)")
echo "-- spawn B transcript:"; cat "$SPAWN_B_OUT"

PANE_B=$(meta_field "$TASK_B" herdr_pane_id)
[ -n "$PANE_B" ] || fail "no herdr_pane_id recorded for $TASK_B"
note "task B pane: $PANE_B"

# The staged launch namespace is the on-disk source the pane sources; assert the
# complete claude command there (the exact bytes the destination shell reads).
STAGED=$(ls -d /tmp/fm-"$TASK_B"+* 2>/dev/null | head -1)
[ -n "$STAGED" ] || fail "no staged launch namespace /tmp/fm-$TASK_B+*"
STAGED_LAUNCH=$(find "$STAGED" -name 'launch*' -type f 2>/dev/null | head -1)
[ -n "$STAGED_LAUNCH" ] || fail "no staged launch file under $STAGED"
STAGED_CONTENT=$(cat "$STAGED_LAUNCH")
echo "$STAGED_CONTENT" > "$OUT_DIR/live-lab-scenario-b-staged-launch.txt"
case "$STAGED_CONTENT" in
  *'claude --dangerously-skip-permissions'*) : ;;
  *) fail "staged launch is missing the claude command" ;;
esac
case "$STAGED_CONTENT" in
  *"$FMHOME/data/$TASK_B/launch-brief.md"*) : ;;
  *) fail "staged launch lost the brief path" ;;
esac
LIT_CMDSUB='$('
case "$STAGED_CONTENT" in
  *"$LIT_CMDSUB"*) : ;;  # claude brief is read through command substitution
  *) fail "staged launch lost the command-substitution brief read" ;;
esac
note "staged launch carries the complete claude command, brief path, and brief command-substitution"

# Reached processing: poll the real pane's OS-level foreground process until a
# verified harness (claude) is running in it, then record the pane's own view.
proc_json=''
DEADLINE=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  proc_json=$(lab pane process-info --pane "$PANE_B" 2>/dev/null || true)
  if printf '%s' "$proc_json" | jq -e '
    .result.type == "pane_process_info"
    and ([.result.process_info.foreground_processes[]?
          | ((.argv // [])[0] // .argv0 // "" )] | map(test("claude")) | any)
  ' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
printf '%s' "$proc_json" | jq . > "$OUT_DIR/live-lab-scenario-b-process-info.json" 2>/dev/null \
  || printf '%s' "$proc_json" > "$OUT_DIR/live-lab-scenario-b-process-info.json"
printf '%s' "$proc_json" | jq -e '
  .result.type == "pane_process_info"
  and ([.result.process_info.foreground_processes[]?
        | ((.argv // [])[0] // .argv0 // "" )] | map(test("claude")) | any)
' >/dev/null 2>&1 \
  || fail "claude worker never showed as the pane's foreground harness (process-info: $(printf '%s' "$proc_json" | head -c 400))"
note "claude verified as the lab pane's foreground harness (reached processing)"

lab agent get "$PANE_B" 2>/dev/null | jq . > "$OUT_DIR/live-lab-scenario-b-agent-state.json" 2>/dev/null || true
sleep 3   # let the claude TUI paint before the pane capture
pane_read "$PANE_B" > "$TMP_ROOT/pane-b.txt" || fail "pane B read failed"
cp "$TMP_ROOT/pane-b.txt" "$OUT_DIR/live-lab-scenario-b-pane.txt"
if grep -q "^\. '.*launch" "$TMP_ROOT/pane-b.txt"; then
  note "pane B shows the staged source line"
fi
note "pane B capture (first 25 lines):"
head -25 "$TMP_ROOT/pane-b.txt"
note "Scenario B PASS (delivery contract proven against the real pane; worker reached processing)"

note "ALL LIVE SCENARIOS PASSED"
cleanup
exit 0
