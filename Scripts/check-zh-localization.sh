#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
catalog=${1:-"$script_dir/../Termind/Resources/Localizable.xcstrings"}

if ! jq empty "$catalog"; then
  echo "Invalid string catalog: $catalog" >&2
  exit 1
fi

missing=$(jq -r '
  .strings | to_entries[]
  | select(.value.localizations."zh-Hans" == null)
  | .key
' "$catalog")
if [[ -n "$missing" ]]; then
  echo "Missing zh-Hans localizations:" >&2
  echo "$missing" >&2
  exit 1
fi

unfinished=$(jq -r '
  .strings | to_entries[] as $entry
  | [
      $entry.value.localizations."zh-Hans"
      | .. | objects | .stringUnit?
      | select(. != null and .state != "translated")
    ]
  | select(length > 0)
  | $entry.key
' "$catalog")
if [[ -n "$unfinished" ]]; then
  echo "Unfinished zh-Hans localizations:" >&2
  echo "$unfinished" >&2
  exit 1
fi

violations=$(jq -r '
  .strings | to_entries[] as $entry
  | [
      ($entry.value.localizations."zh-Hans" // {})
      | .. | objects | .stringUnit?.value? // empty
    ]
  | .[]
  | select(
      test("\\p{Han}")
      and (
        test("\\p{Han}[ \\t]+[A-Za-z0-9%@`]|[A-Za-z0-9%@`][ \\t]+\\p{Han}")
        or test("[ \\t]+[—·→：，。！？；、/:]|[—·→：，。！？；、/:][ \\t]+")
        or test("\\p{Han}[,.!?;]|[,.!?;]\\p{Han}")
      )
    )
  | "\($entry.key): \(.)"
' "$catalog")
if [[ -n "$violations" ]]; then
  echo "Invalid zh-Hans spacing:" >&2
  echo "$violations" >&2
  exit 1
fi

echo "zh-Hans localization checks passed."
