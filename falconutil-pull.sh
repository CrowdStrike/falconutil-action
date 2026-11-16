#!/usr/bin/env bash
set -x

# This script is used to pull the Falcon Container Sensor container image.
# Uses the falcon-container-sensor-pull.sh script to pull the image.

log() {
    local log_level=${2:-INFO}
    echo "[$(date +'%Y-%m-%dT%H:%M:%S')] $log_level: $1" >&2
}

# Retry a command up to a fixed number of attempts with a short backoff.
# Used to ride out transient network failures (e.g. TLS handshake timeouts)
# when contacting GitHub or the CrowdStrike registry.
retry() {
    local max_attempts=${INPUT_RETRY_MAX_ATTEMPTS:-3}
    local delay=${INPUT_RETRY_DELAY_SECONDS:-5}
    local attempt=1

    while true; do
        "$@" && return 0
        if (( attempt >= max_attempts )); then
            log "Command failed after ${attempt} attempt(s): $*" "ERROR"
            return 1
        fi
        log "Attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s: $*" "WARN"
        sleep "$delay"
        (( attempt++ ))
    done
}

validate_required_inputs() {
    local invalid=false
    local -a required_inputs=(
        "INPUT_FALCON_CLIENT_ID"
        "FALCON_CLIENT_SECRET"
        "INPUT_FALCON_REGION"
    )

    for input in "${required_inputs[@]}"; do
        if [[ -z "${!input:-}" ]]; then
            log "Missing required input/env variable '${input#INPUT_}'. Please see the actions's documentation for more details." "ERROR"
            invalid=true
        fi
    done

    [[ "$invalid" == "true" ]] && exit 1
}

# Prints one "<os>/<arch> <digest>" line per platform of a multi-platform image, or one
# "<os>/<arch>" line for a single-platform image. Prints nothing when the manifest can't be read.
image_platforms() {
    local manifest entry platform os arch digest
    manifest=$(docker manifest inspect -v "$1" 2>/dev/null | tr -d ' \t\n')
    [[ -n "$manifest" ]] || return 0

    # Each entry starts with its "Ref"; the first platform and digest in it belong to its descriptor
    while read -r entry; do
        platform=$(grep -o '"platform":{[^}]*}' <<<"$entry" | head -n 1)
        os=$(grep -o '"os":"[^"]*"' <<<"$platform" | cut -d '"' -f 4)
        arch=$(grep -o '"architecture":"[^"]*"' <<<"$platform" | cut -d '"' -f 4)
        # Attestation manifests use the unknown/unknown platform
        [[ -n "$os" && -n "$arch" && "$os" != "unknown" ]] || continue
        if [[ "$manifest" == \[* ]]; then
            digest=$(grep -o '"digest":"sha256:[0-9a-f]*"' <<<"$entry" | head -n 1 | cut -d '"' -f 4)
            echo "${os}/${arch} ${digest}"
        else
            echo "${os}/${arch}"
        fi
    done <<<"${manifest//'{"Ref":'/$'\n'}"
}

# Prints the platform falconutil patches for: the platform of a local source image with
# IfNotPresent, else the runner's platform when the source image has it, else the only
# platform of the source image. Prints nothing when it can't be determined.
detect_target_platform() {
    local source="$1" platform platforms daemon_platform

    if [[ "${INPUT_IMAGE_PULL_POLICY:-}" == "IfNotPresent" ]]; then
        platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$source" 2>/dev/null)
        if [[ -n "$platform" && "$platform" != "/" ]]; then
            echo "$platform"
            return 0
        fi
    fi

    platforms=$(image_platforms "$source" | cut -d ' ' -f 1 | sort -u)
    [[ -n "$platforms" ]] || return 0
    daemon_platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')
    if grep -qx "$daemon_platform" <<<"$platforms"; then
        echo "$daemon_platform"
    elif [[ $(wc -l <<<"$platforms") -eq 1 ]]; then
        echo "$platforms"
    fi
    return 0
}

# Prints the image pinned to the digest of the target platform when it is a multi-platform
# image, else the image as is. With the containerd image store a multi-platform tag resolves
# locally to the runner's platform, so falconutil would read the wrong image.
pin_to_target_platform() {
    local image="$1" digest repository
    digest=$(image_platforms "$image" | awk -v platform="$TARGET_PLATFORM" 'NF == 2 && $1 == platform { print $2; exit }')
    if [[ -z "$digest" ]]; then
        echo "$image"
        return 0
    fi
    repository="${image%@*}"
    [[ "${repository##*/}" == *:* ]] && repository="${repository%:*}"
    echo "${repository}@${digest}"
}

validate_required_inputs

# Download the falcon-container-sensor-pull.sh script
retry curl -fsSL -O https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh || exit 1

# Check if the version is provided
VERSION=${INPUT_VERSION:+"--version ${INPUT_VERSION}"}
# falconutil runs on the runner, so pull the sensor for the runner's architecture
case "$(uname -m)" in
    x86_64 | amd64) RUNNER_PLATFORM="x86_64" RUNNER_ARCH="amd64" ;;
    aarch64 | arm64) RUNNER_PLATFORM="aarch64" RUNNER_ARCH="arm64" ;;
    *) RUNNER_PLATFORM="${INPUT_FALCON_IMAGE_PLATFORM:-x86_64}" RUNNER_ARCH="" ;;
esac
PLATFORM="--platform ${RUNNER_PLATFORM}"

pull_sensor() {
    bash falcon-container-sensor-pull.sh -u "${INPUT_FALCON_CLIENT_ID}" -r "${INPUT_FALCON_REGION}" -t falcon-container ${VERSION} ${PLATFORM}
}

output=$(retry pull_sensor)

# Extract the image name from the output
image_name=$(echo "$output" | grep "^registry.*.com/falcon-container" | tail -n 1)

# Check if the image name is empty
if [ -z "$image_name" ]; then
    echo "Failed to get the image name."
    exit 1
fi

FALCONUTIL_BIN_PATH=/opt/crowdstrike/bin
# Make sure the directory exists
mkdir -p $FALCONUTIL_BIN_PATH
id=$(docker create ${RUNNER_ARCH:+--platform "linux/${RUNNER_ARCH}"} "$image_name")
docker cp "$id:/usr/bin/falconutil" $FALCONUTIL_BIN_PATH

# Ensure the binary exists
if [ ! -f $FALCONUTIL_BIN_PATH/falconutil ]; then
    echo "Failed to copy the FCS binary."
    exit 1
fi

log "Successfully pulled Falcon Container Sensor image: $image_name"

falcon_image_uri="${INPUT_FALCON_IMAGE_URI:-$image_name}"
# Without --platform falconutil pulls the source image for the runner's platform, which fails
# for an image of another platform. Detect the platform so it can be passed explicitly.
TARGET_PLATFORM=$(detect_target_platform "$INPUT_SOURCE_IMAGE_URI")
if [[ -n "$TARGET_PLATFORM" ]]; then
    falcon_image_uri=$(pin_to_target_platform "$falcon_image_uri")
    log "Target platform: $TARGET_PLATFORM, Falcon Container Sensor image: $falcon_image_uri"
else
    log "Unable to detect the platform of source image $INPUT_SOURCE_IMAGE_URI; falconutil will detect it" "WARNING"
fi

# Set the bin path as an output
echo "FALCONUTIL_BIN=$FALCONUTIL_BIN_PATH/falconutil" >> "$GITHUB_OUTPUT"
# Set the image name as an output
echo "FALCON_IMAGE_URI=$falcon_image_uri" >> "$GITHUB_OUTPUT"
# Set the target platform as an output
echo "FALCON_IMAGE_PLATFORM=$TARGET_PLATFORM" >> "$GITHUB_OUTPUT"
