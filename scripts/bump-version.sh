#!/bin/sh

set -eu

repo_root=$(git rev-parse --show-toplevel)
version_file="$repo_root/domyos/Version.xcconfig"

if [ ! -f "$version_file" ]; then
    echo "error: version config not found: $version_file" >&2
    exit 1
fi

current_version=$(sed -n 's/^APP_MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' "$version_file")

case "$current_version" in
    *.*) ;;
    *)
        echo "error: invalid APP_MARKETING_VERSION: $current_version" >&2
        exit 1
        ;;
esac

major=${current_version%%.*}
minor=${current_version#*.}

case "$major:$minor" in
    *[!0-9:]*|:|*:)
        echo "error: APP_MARKETING_VERSION must use numeric major.minor format" >&2
        exit 1
        ;;
esac

next_version="$major.$((minor + 1))"
build_number=$(date +%Y%m%d)
temporary_file="$version_file.tmp"

sed \
    -e "s/^APP_MARKETING_VERSION[[:space:]]*=.*/APP_MARKETING_VERSION = $next_version/" \
    -e "s/^APP_BUILD_NUMBER[[:space:]]*=.*/APP_BUILD_NUMBER = $build_number/" \
    "$version_file" > "$temporary_file"
mv "$temporary_file" "$version_file"

echo "Version updated: $current_version -> $next_version ($build_number)"
