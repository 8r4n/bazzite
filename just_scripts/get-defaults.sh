#!/usr/bin/bash
set -eo pipefail

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi

resolved_variant=$(
    "${project_root}/just_scripts/resolve-variant.sh" \
        "${target:-}" \
        "${image:-}"
)

eval "${resolved_variant}"
