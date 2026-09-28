#!/bin/bash
# Source this file from build scripts; project.yml is the version source of truth.
release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_version="$(awk '$1 == "MARKETING_VERSION:" {gsub(/"/, "", $2); print $2; exit}' "$release_root/project.yml")"
project_build="$(awk '$1 == "CURRENT_PROJECT_VERSION:" {print $2; exit}' "$release_root/project.yml")"
version="${LMW_VERSION:-$project_version}"
build_number="${LMW_BUILD:-$project_build}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid release version '$version'; use MAJOR.MINOR.PATCH." >&2
    return 1 2>/dev/null || exit 1
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid build number '$build_number'; use a positive integer." >&2
    return 1 2>/dev/null || exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '%s\n' "$version"
fi
