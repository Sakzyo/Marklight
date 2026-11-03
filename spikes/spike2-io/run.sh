#!/bin/bash
# Spike 2: open, no-op, save every fixture and compare SHA-256 before and after.
# Works on copies in a temp dir; also checks the executable bit and a symlink.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product spike2-io >/dev/null
BIN="$(swift build -c release --show-bin-path)/spike2-io"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/files"
cp -p fixtures/* "$WORK/files/"
for f in ../../Tests/Fixtures/*; do cp -p "$f" "$WORK/files/core-$(basename "$f")"; done
# File-system cases: executable bit, and a symlink opened by its link path.
chmod 755 "$WORK/files/utf8.md"
ln -s files/crlf.md "$WORK/link-to-crlf.md"

fail=0
printf '%-28s %-10s %s\n' FILE RESULT SHA256
for f in "$WORK"/files/* "$WORK/link-to-crlf.md"; do
  before=$(shasum -a 256 "$f" | cut -d' ' -f1)
  mode_before=$(stat -f %Lp "$f")
  "$BIN" save "$f"
  after=$(shasum -a 256 "$f" | cut -d' ' -f1)
  mode_after=$(stat -f %Lp "$f")
  result=identical
  [[ "$before" == "$after" ]] || { result=CHANGED; fail=1; }
  [[ "$mode_before" == "$mode_after" ]] || { result="MODE $mode_before->$mode_after"; fail=1; }
  printf '%-28s %-10s %s\n' "$(basename "$f")" "$result" "${after:0:16}"
done

if [[ -L "$WORK/link-to-crlf.md" && "$(readlink "$WORK/link-to-crlf.md")" == "files/crlf.md" ]]; then
  echo "symlink link-to-crlf.md: preserved -> files/crlf.md"
else
  echo "symlink link-to-crlf.md: BROKEN"; fail=1
fi
echo "utf8.md mode after save: $(stat -f %Lp "$WORK/files/utf8.md") (expected 755)"
[[ $fail == 0 ]] && echo "PASS" || { echo "FAIL"; exit 1; }
