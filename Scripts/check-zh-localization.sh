#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [catalog]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  catalogs=("$1")
else
  catalogs=(
    "$script_dir/../Frameworks/Resources/Localizable.xcstrings"
    "$script_dir/../Frameworks/Resources/InfoPlist.xcstrings"
  )
fi

python3 "$script_dir/normalize-string-catalogs.py" --check "${catalogs[@]}"

for catalog in "${catalogs[@]}"; do

if ! jq empty "$catalog"; then
  echo "Invalid string catalog: $catalog" >&2
  exit 1
fi

for language in zh-Hans zh-Hant; do
  missing=$(jq -r --arg language "$language" '
    .strings | to_entries[]
    | select(.value.shouldTranslate != false and .value.localizations[$language] == null)
    | .key
  ' "$catalog")
  if [[ -n "$missing" ]]; then
    echo "Missing $language localizations:" >&2
    echo "$missing" >&2
    exit 1
  fi

  unfinished=$(jq -r --arg language "$language" '
    .strings | to_entries[] as $entry
    | select($entry.value.shouldTranslate != false)
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
    | select($entry.value.shouldTranslate != false)
    | [
        ($entry.value.localizations[$language] // {})
        | .. | objects | .stringUnit?.value? // empty
      ]
    | .[]
    | select(
        # Key-card type subtitles intentionally separate the label and value.
        (if $entry.key == "Type %@" then sub("^(?<label>类型|類型) (?=%@)"; "\(.label)") else . end)
        |
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

done

echo "zh-Hans and zh-Hant localization checks passed."
