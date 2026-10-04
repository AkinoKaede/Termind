#!/bin/sh
set -eu

# Regenerates Termind's compact model-capability snapshot from one pinned Pi
# package version. The version is required so updates never silently follow a
# moving npm tag.

if [ "$#" -ne 1 ]; then
    echo "usage: $0 PI_VERSION" >&2
    exit 64
fi

version=$1
package="@earendil-works/pi-ai@$version"
output="Frameworks/Resources/PiModelCatalog.json"
temporary_dir=$(mktemp -d /tmp/termind-pi-model-catalog.XXXXXX)
trap 'rm -rf "$temporary_dir"' EXIT

npm pack "$package" --pack-destination "$temporary_dir" >/dev/null
tar -xzf "$temporary_dir"/*.tgz -C "$temporary_dir"
data_dir="$temporary_dir/package/dist/providers/data"

commit=$(npm view "$package" gitHead)
integrity=$(npm view "$package" dist.integrity)
temporary="$temporary_dir/PiModelCatalog.json"

# Pi exposes some IDs through multiple APIs. Prefer their chat records because
# the assistant selects models by provider and ID, without an API-type suffix.
jq -cs \
    --arg commit "$commit" \
    --arg version "$version" \
    --arg integrity "$integrity" \
    '{
        source: ("https://github.com/badlogic/pi-mono/tree/" + $commit + "/packages/ai"),
        package: "@earendil-works/pi-ai",
        version: $version,
        commit: $commit,
        integrity: $integrity,
        models: ([
            .[]
            | to_entries[]
            | .value
            | to_entries[]
            | .value
            | {
                provider,
                type,
                id,
                name,
                reasoning,
                input,
                output: (.output // (if .type == "image" then ["image"] else ["text"] end)),
                contextWindow,
                maxOutputTokens: .maxTokens,
                unsupportedEfforts: (
                    (.thinkingLevelMap // {})
                    | to_entries
                    | map(select(.value == null) | .key)
                ),
                effortWireValues: (
                    (.thinkingLevelMap // {})
                    | with_entries(select(.value != null))
                )
            }
        ] | group_by([.provider, .id])
          | map(min_by(if .type == "chat" then 0 elif .type == "image" then 1 else 2 end)))
    }' "$data_dir"/*.json > "$temporary"

mv "$temporary" "$output"
echo "Wrote $output from Pi $version ($commit)"
