#!/bin/bash
# split_and_push_final_with_splitonly.sh
# Splits large files into 10MB chunks, optionally commits/pushes them,
# can rewrap untracked chunks, and recombine chunks back to the original.
#
# Usage:
#   ./split_and_push.sh [--split-only|--rewrap|--recombine] file1.tar.gz file2.tgz ...

set -euo pipefail

CHUNK_SIZE=10M
CHUNK_BYTES=$((10 * 1024 * 1024)) # 10 MB in bytes
BRANCH="main"
STATE_FILE=".pushed_chunks.log"
MODE="push"   # default mode is push
REWRAP=false
RECOMBINE=false

# Parse first flag
case "${1:-}" in
  --split-only)
    MODE="split"
    shift
    ;;
  --rewrap)
    REWRAP=true
    shift
    ;;
  --recombine)
    RECOMBINE=true
    shift
    ;;
esac

touch "$STATE_FILE"

# Ensure log + original tars are ignored in Git
if [ "$MODE" = "push" ] && [ "$RECOMBINE" = false ]; then
  if ! grep -q ".pushed_chunks.log" .gitignore 2>/dev/null; then
    echo ".pushed_chunks.log" >> .gitignore
    echo "*.tar.gz" >> .gitignore
    echo "*.tgz" >> .gitignore
  fi
fi

# ============================================================
# Recombine mode
# ============================================================
if [ "$RECOMBINE" = true ]; then
  for basefile in "$@"; do
    echo "🔗 Recombining parts for $basefile ..."
    # Expect chunks like basefile.part.000, basefile.part.001, etc.
    if ls "${basefile}.part."* >/dev/null 2>&1; then
      cat "${basefile}.part."* > "$basefile"
      echo "✅ Recombined into $basefile"
    else
      echo "❌ No chunks found for $basefile"
    fi
  done
  exit 0
fi

# ============================================================
# Normal split/push workflow
# ============================================================
for file in "$@"; do
  echo "📦 Processing $file ..."

  # Check if chunks exist or if any are missing
  expected_size=$(stat -c%s "$file")
  expected_parts=$(( (expected_size + CHUNK_BYTES - 1) / CHUNK_BYTES ))
  actual_parts=$(ls -1 "${file}.part."* 2>/dev/null | wc -l || echo 0)

  if [ "$actual_parts" -ne "$expected_parts" ]; then
    echo "⚠️ Missing or incorrect chunks for $file. Re-splitting..."
    rm -f "${file}.part."* 2>/dev/null || true
    split -b $CHUNK_SIZE -d -a 3 "$file" "${file}.part."
    [ "$MODE" = "push" ] && git rm --cached -f "$file" 2>/dev/null || true
  fi

  if [ "$MODE" = "split" ]; then
    echo "✅ Split complete for $file (no push mode)."
    continue
  fi

  # Commit + push mode
  for chunk in ${file}.part.*; do
    if grep -qx "$chunk" "$STATE_FILE"; then
      echo "✅ Already pushed: $chunk — skipping."
      continue
    fi

    echo "➕ Adding $chunk ..."
    git rm --cached -f "$chunk" 2>/dev/null || true
    git add -f "$chunk"

    echo "📝 Committing $chunk ..."
    if ! git commit -m "Add chunk $chunk from $file"; then
      echo "⚠️ Nothing to commit for $chunk. Skipping."
      continue
    fi

    # Infinite retry loop for pushing
    wait_time=10
    while true; do
      echo "📤 Pushing $chunk (wait=$wait_time s if fail)..."
      if git push origin "$BRANCH"; then
        echo "✅ Successfully pushed $chunk"
        echo "$chunk" >> "$STATE_FILE"
        break
      else
        echo "❌ Push failed for $chunk. Rolling back last commit..."
        git reset --mixed HEAD~1
        git reset "$chunk"

        echo "⏳ Retrying in $wait_time seconds..."
        sleep $wait_time

        wait_time=$((wait_time + 5))
        if [ $wait_time -gt 300 ]; then
          wait_time=300
        fi
      fi
    done
  done

  echo "🎉 Finished $file"

  # Extra step: retry untracked *.part.* files if --rewrap is set
  if [ "$REWRAP" = true ]; then
    echo "🔍 Checking for untracked part files (rewrap mode)..."
    untracked=$(git status --porcelain | awk '/^\?\?/ && $2 ~ /\.part\./ {print $2}')
    for chunk in $untracked; do
      echo "♻️ Retrying untracked chunk $chunk ..."
      git add -f "$chunk"
      if git commit -m "Rewrap commit for $chunk"; then
        wait_time=10
        while true; do
          echo "📤 Pushing $chunk (wait=$wait_time s if fail)..."
          if git push origin "$BRANCH"; then
            echo "✅ Successfully re-pushed $chunk"
            echo "$chunk" >> "$STATE_FILE"
            break
          else
            echo "❌ Push failed for $chunk. Rolling back last commit..."
            git reset --mixed HEAD~1
            git reset "$chunk"
            echo "⏳ Retrying in $wait_time seconds..."
            sleep $wait_time
            wait_time=$((wait_time + 5))
            if [ $wait_time -gt 300 ]; then
              wait_time=300
            fi
          fi
        done
      fi
    done
  fi
done

