#!/usr/bin/bash
set -euo pipefail

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi

variants_file="${project_root}/just_scripts/metadata/variants.json"
features_file="${project_root}/just_scripts/metadata/features.json"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Missing required command: python3" >&2
    exit 1
fi

python3 - <<'PY' "${variants_file}" "${features_file}"
import json
import sys

variants_path, features_path = sys.argv[1:3]

with open(variants_path, encoding="utf-8") as handle:
    variants = json.load(handle)

with open(features_path, encoding="utf-8") as handle:
    features = json.load(handle)

if not isinstance(variants.get("imageInputs"), dict) or not variants["imageInputs"]:
    raise SystemExit("variants.json must define a non-empty imageInputs object")

if not isinstance(variants.get("targets"), dict) or not variants["targets"]:
    raise SystemExit("variants.json must define a non-empty targets object")

if not isinstance(features.get("features"), dict) or not features["features"]:
    raise SystemExit("features.json must define a non-empty features object")

required_image_fields = [
    "baseImageName",
    "baseImageFamily",
    "baseVariantName",
    "sourceImage",
    "flatpakDirShortname",
    "flatpakBootstrapImage",
    "desktopSuffix",
    "buildVersion",
    "contentVersion",
    "imageVariantSuffix",
    "features",
]

for image_name, image_data in variants["imageInputs"].items():
    missing = [field for field in required_image_fields if field not in image_data]
    if missing:
        raise SystemExit(f"Image '{image_name}' is missing required fields: {', '.join(missing)}")
    if not isinstance(image_data["features"], list):
        raise SystemExit(f"Image '{image_name}' must define 'features' as an array")

for target_name, target_data in variants["targets"].items():
    if not target_data.get("containerTarget"):
        raise SystemExit(f"Target '{target_name}' must define containerTarget")
    if not isinstance(target_data.get("features"), list):
        raise SystemExit(f"Target '{target_name}' must define 'features' as an array")

known_features = set(features["features"].keys())
referenced_features = set()
for image_data in variants["imageInputs"].values():
    referenced_features.update(image_data["features"])
for target_data in variants["targets"].values():
    referenced_features.update(target_data["features"])

undefined = sorted(referenced_features - known_features)
if undefined:
    raise SystemExit(
        "Undefined features referenced by variants or targets: " + ", ".join(undefined)
    )
PY

echo "Variant metadata is valid."