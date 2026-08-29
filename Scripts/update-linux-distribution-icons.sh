#!/bin/sh
set -eu

# Regenerates the Linux distribution icon assets and runtime catalog from one
# pinned Simple Icons release. A version is required so builds never follow a
# moving npm tag or download assets at runtime.

if [ "$#" -ne 1 ]; then
    echo "usage: $0 SIMPLE_ICONS_VERSION" >&2
    exit 64
fi

version=$1
case "$version" in
    ""|*[!0-9A-Za-z._-]*)
        echo "invalid Simple Icons version: $version" >&2
        exit 64
        ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
source_catalog="$script_dir/linux-distribution-icons.json"
assets_dir="$repository_dir/Termind/Resources/Assets.xcassets/LinuxDistributions"
runtime_catalog="$repository_dir/Termind/Resources/LinuxDistributionIcons.json"
license_dir="$repository_dir/Termind/Resources/LinuxDistributionIcons"
temporary_dir=$(mktemp -d /tmp/termind-linux-icons.XXXXXX)
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

command -v npm >/dev/null 2>&1 || { echo "npm is required" >&2; exit 69; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 69; }
test -r "$source_catalog" || { echo "missing $source_catalog" >&2; exit 66; }

pack_json=$(npm pack "simple-icons@$version" --pack-destination "$temporary_dir" --json)
tarball=$(printf '%s' "$pack_json" | jq -er '.[0].filename')
integrity=$(printf '%s' "$pack_json" | jq -er '.[0].integrity')
tar -xzf "$temporary_dir/$tarball" -C "$temporary_dir"
package_dir="$temporary_dir/package"
package_version=$(jq -er '.version' "$package_dir/package.json")
test "$package_version" = "$version" || {
    echo "package version mismatch: expected $version, found $package_version" >&2
    exit 65
}

generated_assets="$temporary_dir/LinuxDistributions"
generated_catalog="$temporary_dir/LinuxDistributionIcons.json"
generated_license="$temporary_dir/LinuxDistributionIcons"
mkdir -p "$generated_assets" "$generated_license"

cat > "$generated_assets/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

entries="$temporary_dir/entries.jsonl"
: > "$entries"
jq -c '.[]' "$source_catalog" | while IFS= read -r requested; do
    title=$(printf '%s' "$requested" | jq -er '.title')
    slug=$(printf '%s' "$requested" | jq -er '.slug')
    ids=$(printf '%s' "$requested" | jq -ec '.ids | select(length > 0)')
    metadata=$(jq -ec --arg title "$title" '.[] | select(.title == $title)' \
        "$package_dir/data/simple-icons.json")
    matches=$(jq -n --argjson metadata "[$metadata]" '$metadata | length')
    test "$matches" -eq 1 || {
        echo "expected exactly one metadata entry for $title" >&2
        exit 65
    }
    hex=$(printf '%s' "$metadata" | jq -er '.hex | select(test("^[0-9A-F]{6}$"))')
    source_url=$(printf '%s' "$metadata" | jq -er '.source')
    license=$(printf '%s' "$metadata" | jq -r '.license.type // empty')
    source_svg="$package_dir/icons/$slug.svg"
    test -s "$source_svg" || { echo "missing icon: $slug.svg" >&2; exit 66; }
    grep -q '<svg' "$source_svg" || { echo "invalid SVG: $slug.svg" >&2; exit 65; }
    if grep -Eiq '<script|<foreignObject|<image|javascript:|xlink:href|[[:space:]]href=' "$source_svg"; then
        echo "unsafe external content in $slug.svg" >&2
        exit 65
    fi

    asset="LinuxDistro-$slug"
    imageset="$generated_assets/$asset.imageset"
    mkdir -p "$imageset"
    cp "$source_svg" "$imageset/$asset.svg"
    jq -n --arg filename "$asset.svg" '{
        images: [{ filename: $filename, idiom: "universal" }],
        info: { author: "xcode", version: 1 },
        properties: {
          "preserves-vector-representation": true,
          "template-rendering-intent": "template"
        }
      }' > "$imageset/Contents.json"

    jq -nc \
        --arg title "$title" --arg slug "$slug" --arg asset "$asset" \
        --arg hex "$hex" --arg sourceURL "$source_url" --arg license "$license" \
        --argjson ids "$ids" \
        '{ title: $title, slug: $slug, asset: $asset, ids: $ids, hex: $hex,
           sourceURL: $sourceURL, license: (if $license == "" then null else $license end) }' \
        >> "$entries"
done

jq -sS \
    --arg version "$version" --arg integrity "$integrity" \
    '{ source: "https://github.com/simple-icons/simple-icons",
       package: "simple-icons", version: $version, integrity: $integrity,
       entries: . }' "$entries" > "$generated_catalog"
cp "$package_dir/LICENSE.md" "$generated_license/SimpleIcons.LICENSE.md"
cp "$package_dir/DISCLAIMER.md" "$generated_license/SimpleIcons.DISCLAIMER.md"

# Replace generated outputs only after every requested icon and metadata entry
# has been validated, preventing an interrupted update from leaving a partial set.
rm -rf "$assets_dir" "$license_dir"
mv "$generated_assets" "$assets_dir"
mv "$generated_license" "$license_dir"
mv "$generated_catalog" "$runtime_catalog"

echo "Wrote Linux distribution icons from simple-icons@$version"
