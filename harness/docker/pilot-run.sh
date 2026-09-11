#!/bin/bash
# agentENV pilot: a bounded-concurrency agent pool over sharded tasks.
#
# Usage: ./pilot-run.sh [TASKS] [CONCURRENCY]
#   TASKS  total task units (shards), default 10
#   CONC   max agents running at once, default = TASKS (full parallel)
#
# Example (the 10k form):
#   ./pilot-run.sh 10000 200      # 10,000 task units, 200-agent rolling pool
#
# Env:
#   TASK_TIMEOUT=300   per-agent seconds inside the container
#   RETRY_PASSES=2     re-run passes for failed/missing shards
#
# Architecture: shard fan-out -> xargs -P bounded pool of throwaway
# agentENV containers (dsh --profile headless, stateless, one per task) ->
# result files on disk -> retry passes for missing/invalid results ->
# local reduce. The pool is the queue: a slot frees, the next shard starts.
# LLM word-count accuracy is NOT the acceptance bar; the bar is: every
# shard returns parseable JSON through the gateway, within the timeouts.

set -uo pipefail

TASKS=${1:-10}
CONC=${2:-$TASKS}
IMAGE=omarchy-agentenv:latest
REPO=${REPO:-$HOME/omarchy-harness-linux}
work=/tmp/agentenv-pilot
TASK_TIMEOUT=${TASK_TIMEOUT:-300}
RETRY_PASSES=${RETRY_PASSES:-2}

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found" >&2; exit 1; }

rm -rf "$work"
mkdir -p "$work/task" "$work/results"

# --- Map: shard the corpus ------------------------------------------------
# Real English text from the repo's own design docs. The corpus is
# replicated enough that every shard stays non-empty at any TASKS size
# (demo-scale only; production tasks carry their own payloads).
corpus_src=$(mktemp)
cat "$REPO"/plans/harness.md "$REPO"/plans/server.md "$REPO"/README.md > "$corpus_src" 2>/dev/null
[ -s "$corpus_src" ] || { echo "corpus empty" >&2; exit 1; }

words=$(wc -w < "$corpus_src")
copies=$(( (TASKS * 25 + words - 1) / words ))
[ "$copies" -lt 1 ] && copies=1
corpus="$work/corpus.txt"
for _ in $(seq "$copies"); do cat "$corpus_src"; done > "$corpus"

# -a 5 keeps zero-padded ids unique up to 99,999 shards.
split -n l/"$TASKS" -d -a 5 --additional-suffix=.txt "$corpus" "$work/task/shard-"
shards=("$work/task"/shard-*.txt)

# Ground truth for the reduce-side sanity report.
tr -cs 'A-Za-z' '\n' < "$corpus" | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn | head -10 \
  | awk '{print $2, $1}' > "$work/baseline-top10.txt"

echo "== corpus: $(wc -w < "$corpus") words -> ${#shards[@]} shards, pool $CONC, retries $RETRY_PASSES"

# --- One task = one throwaway agent container -------------------------------
# Always returns 0 so GNU xargs never aborts (it treats exit 255 as fatal);
# failure is expressed by a missing/invalid result file and picked up by
# the retry passes below.
run_one() {
  local f=$1
  local id
  id=$(basename "$f" .txt)
  id=${id#shard-}
  docker run --rm --name "pilot-$id" \
    -v "$work/task":/task:ro -v "$work/results":/results \
    --add-host witmem-gw.local:10.0.2.2 \
    --entrypoint /bin/bash \
    "$IMAGE" -c "timeout $TASK_TIMEOUT /opt/harness/node_modules/.bin/dsh --profile headless 'You are one shard worker of a word-frequency MapReduce. Read /task/shard-$id.txt with your file tools. Count case-insensitive word frequencies (words = runs of letters A-Za-z only). Reply with ONLY minified JSON, no prose, no code fence: {\"shard\":\"$id\",\"words_total\":<int>,\"top\":[[\"word\",count],[\"word\",count],[\"word\",count],[\"word\",count],[\"word\",count]]} where top is your 5 most frequent words.' > /results/shard-$id.txt 2> /results/shard-$id.err" \
    >/dev/null 2>&1
  return 0
}
export -f run_one
export work IMAGE TASK_TIMEOUT

# --- Progress reporter -------------------------------------------------------
(
  while :; do
    sleep 30
    echo "  [progress] $(ls "$work/results"/shard-*.txt 2>/dev/null | wc -l)/$TASKS results, $(docker ps -q --filter 'name=pilot-' 2>/dev/null | wc -l) agents running"
  done
) &
PROGRESS_PID=$!

# --- Pool: xargs -P is the concurrency gate and the queue --------------------
start=$(date +%s)
printf '%s\n' "${shards[@]}" | xargs -P "$CONC" -I{} bash -c 'run_one "$@"' _ {}
kill "$PROGRESS_PID" 2>/dev/null

# --- Retry passes for missing/invalid results --------------------------------
pass=1
while [ "$pass" -le "$RETRY_PASSES" ]; do
  failed=()
  for f in "${shards[@]}"; do
    id=$(basename "$f" .txt); id=${id#shard-}
    r="$work/results/shard-$id.txt"
    if [ ! -s "$r" ] || ! grep -q '{' "$r"; then
      failed+=("$f")
    fi
  done
  [ "${#failed[@]}" -eq 0 ] && break
  echo "== retry pass $pass: ${#failed[@]} shards"
  printf '%s\n' "${failed[@]}" | xargs -P "$CONC" -I{} bash -c 'run_one "$@"' _ {}
  pass=$((pass + 1))
done
elapsed=$(( $(date +%s) - start ))

# --- Reduce: aggregate shard results -----------------------------------------
node -e '
const fs = require("fs");
const dir = process.argv[1];
const shards = fs.readdirSync(dir).filter(f => /^shard-\d+\.txt$/.test(f));
let ok = 0, fail = 0;
const merged = new Map();
for (const f of shards) {
  const raw = fs.readFileSync(`${dir}/${f}`, "utf8");
  const m = raw.match(/\{[\s\S]*\}/);
  if (!m) { fail++; continue; }
  try {
    const j = JSON.parse(m[0]);
    ok++;
    for (const [w, c] of j.top || []) merged.set(w, (merged.get(w) || 0) + c);
  } catch (e) { fail++; }
}
const top = [...merged.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10);
console.log("SHARDS_OK=" + ok + " SHARDS_FAIL=" + fail);
console.log("TOP10_MERGED=" + JSON.stringify(top));
' "$work/results"

echo "== baseline top10 (local tr/sort/uniq):"
paste -d' ' <(awk '{print $1}' "$work/baseline-top10.txt") <(awk '{print $2}' "$work/baseline-top10.txt") | head -10
echo "== pipeline: ${#shards[@]} shards, pool $CONC, ${elapsed}s wall (retry passes: $((pass - 1)))"
echo "== pilot artifacts kept in $work"
