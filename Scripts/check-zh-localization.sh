#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
catalog=${1:-"$script_dir/../Frameworks/Resources/Localizable.xcstrings"}

if ! jq empty "$catalog"; then
  echo "Invalid string catalog: $catalog" >&2
  exit 1
fi

for language in zh-Hans zh-Hant; do
  missing=$(jq -r --arg language "$language" '
    .strings | to_entries[]
    | select(.value.localizations[$language] == null)
    | .key
  ' "$catalog")
  if [[ -n "$missing" ]]; then
    echo "Missing $language localizations:" >&2
    echo "$missing" >&2
    exit 1
  fi

  unfinished=$(jq -r --arg language "$language" '
    .strings | to_entries[] as $entry
    | [
        $entry.value.localizations[$language]
        | .. | objects | .stringUnit?
        | select(. != null and (.state != "translated" or (.value == "" and $entry.key != "")))
      ]
    | select(length > 0)
    | $entry.key
  ' "$catalog")
  if [[ -n "$unfinished" ]]; then
    echo "Unfinished $language localizations:" >&2
    echo "$unfinished" >&2
    exit 1
  fi

  violations=$(jq -r --arg language "$language" '
    .strings | to_entries[] as $entry
    | [
        ($entry.value.localizations[$language] // {})
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
    echo "Invalid $language spacing:" >&2
    echo "$violations" >&2
    exit 1
  fi
done

echo "zh-Hans and zh-Hant localization checks passed."
