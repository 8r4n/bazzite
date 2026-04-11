#!/usr/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <target> <image>" >&2
    exit 1
fi

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi

variants_file="${project_root}/just_scripts/metadata/variants.json"
features_file="${project_root}/just_scripts/metadata/features.json"

target_input=${1,,}
image_input=${2,,}

if ! command -v python3 >/dev/null 2>&1; then
    echo "Missing required command: python3" >&2
    exit 1
fi

if [[ ! -f ${variants_file} ]]; then
    echo "Variant metadata file not found: ${variants_file}" >&2
    exit 1
fi

if [[ ! -f ${features_file} ]]; then
    echo "Feature metadata file not found: ${features_file}" >&2
    exit 1
fi

normalize_target() {
    case "$1" in
        "")
            python3 - <<'PY' "${variants_file}"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["defaults"]["defaultTarget"])
PY
            ;;
        deck)
            echo "bazzite-deck"
            ;;
        nvidia)
            echo "bazzite-nvidia"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

normalize_image() {
    if [[ -n $1 ]]; then
        echo "$1"
    else
        python3 - <<'PY' "${variants_file}"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["defaults"]["defaultImage"])
PY
    fi
}

resolve_env_template() {
    local template=$1
    local resolved=${template}

    while [[ ${resolved} =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\:\-([^}]*)\} ]]; do
        local expression=${BASH_REMATCH[0]}
        local var_name=${BASH_REMATCH[1]}
        local fallback=${BASH_REMATCH[2]}
        local replacement=${!var_name:-${fallback}}

        resolved=${resolved//${expression}/${replacement}}
    done

    echo "${resolved}"
}

target=$(normalize_target "${target_input}")
selected_image=$(normalize_image "${image_input}")

variant_json=$(python3 - <<'PY' "${variants_file}" "${features_file}" "${selected_image}" "${target}"
import json
import sys

variants_path, features_path, selected_image, target = sys.argv[1:5]

with open(variants_path, encoding="utf-8") as handle:
    variants = json.load(handle)

with open(features_path, encoding="utf-8") as handle:
    features = json.load(handle)["features"]

if selected_image not in variants["imageInputs"]:
    raise SystemExit(f"Invalid image: {selected_image}")

if target not in variants["targets"]:
    raise SystemExit(f"Invalid target: {target}")

image_data = variants["imageInputs"][selected_image]
target_data = variants["targets"][target]

resolved_features = []
for feature in target_data.get("features", []) + image_data.get("features", []):
    if feature not in resolved_features:
        resolved_features.append(feature)

missing_features = [feature for feature in resolved_features if feature not in features]
if missing_features:
    raise SystemExit(
        "Variant metadata references undefined features: " + ", ".join(missing_features)
    )

payload = {
    "base_image_name": image_data["baseImageName"],
    "base_image_family": image_data["baseImageFamily"],
    "base_variant_name": image_data["baseVariantName"],
    "source_image_template": image_data["sourceImage"],
    "flatpak_dir_shortname": image_data["flatpakDirShortname"],
    "flatpak_bootstrap_image": image_data["flatpakBootstrapImage"],
    "desktop": image_data["desktopSuffix"],
    "build_version_template": image_data["buildVersion"],
    "content_version_template": image_data["contentVersion"],
    "image_variant_suffix": image_data["imageVariantSuffix"],
    "container_target": target_data["containerTarget"],
    "flatpak_bootstrap_version": variants["defaults"]["latest"],
    "variant_features": " ".join(resolved_features),
}

print(json.dumps(payload))
PY
)

base_image_name=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["base_image_name"])
PY
)
base_image_family=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["base_image_family"])
PY
)
base_variant_name=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["base_variant_name"])
PY
)
source_image_template=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["source_image_template"])
PY
)
flatpak_dir_shortname=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["flatpak_dir_shortname"])
PY
)
flatpak_bootstrap_image=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["flatpak_bootstrap_image"])
PY
)
desktop=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["desktop"])
PY
)
build_version_template=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["build_version_template"])
PY
)
content_version_template=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["content_version_template"])
PY
)
image_variant_suffix=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["image_variant_suffix"])
PY
)
container_target=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["container_target"])
PY
)
flatpak_bootstrap_version=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["flatpak_bootstrap_version"])
PY
)
variant_features=$(python3 - <<'PY' "${variant_json}"
import json
import sys

print(json.loads(sys.argv[1])["variant_features"])
PY
)

build_version=$(resolve_env_template "${build_version_template}")
content_version=$(resolve_env_template "${content_version_template}")
source_image=$(resolve_env_template "${source_image_template}")

if [[ ( ${base_image_name} == "centos-stream-10" || ${base_image_name} == "rhel-10" ) && ${target} != "bazzite" && ${target} != "bazzite-custom" && ${target} != "bazzite-kmoddev" ]]; then
    echo "${base_variant_name} builds only support desktop targets." >&2
    exit 1
fi

if [[ ${container_target} == "bazzite-nvidia" ]]; then
    image="bazzite${desktop}-nvidia"
else
    image="${target}${desktop}"
fi
image="${image}${image_variant_suffix}"

variant_id=${image}

cat <<EOF
target=$(printf '%q' "${target}")
image=$(printf '%q' "${image}")
container_target=$(printf '%q' "${container_target}")
desktop=$(printf '%q' "${desktop}")
build_version=$(printf '%q' "${build_version}")
content_version=$(printf '%q' "${content_version}")
base_image_name=$(printf '%q' "${base_image_name}")
base_image_family=$(printf '%q' "${base_image_family}")
base_variant_name=$(printf '%q' "${base_variant_name}")
source_image=$(printf '%q' "${source_image}")
flatpak_dir_shortname=$(printf '%q' "${flatpak_dir_shortname}")
flatpak_bootstrap_image=$(printf '%q' "${flatpak_bootstrap_image}")
flatpak_bootstrap_version=$(printf '%q' "${flatpak_bootstrap_version}")
image_variant_suffix=$(printf '%q' "${image_variant_suffix}")
variant_id=$(printf '%q' "${variant_id}")
variant_features=$(printf '%q' "${variant_features}")
EOF