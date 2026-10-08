#!/usr/bin/env bash
set -x

# This script is used to pull the Falcon Container Sensor container image.
# Uses the falcon-container-sensor-pull.sh script to pull the image.
#
# It also resolves the target platform to patch and the Falcon Container Sensor image
# that matches it, so falconutil works the same way on any runner architecture:
#   - falconutil is extracted for the runner's CPU architecture
#   - the target platform is falcon_image_platform, or detected from the source image
#   - multi-arch Falcon images are pinned to the digest of the target platform

log() {
    local log_level=${2:-INFO}
    echo "[$(date +'%Y-%m-%dT%H:%M:%S')] $log_level: $1" >&2
}

die() {
    log "$1" "ERROR"
    exit 1
}

validate_required_inputs() {
    local invalid=false
    local -a required_inputs=(
        "INPUT_FALCON_CLIENT_ID"
        "FALCON_CLIENT_SECRET"
        "INPUT_FALCON_REGION"
        "INPUT_SOURCE_IMAGE_URI"
    )

    for input in "${required_inputs[@]}"; do
        if [[ -z "${!input:-}" ]]; then
            log "Missing required input/env variable '${input#INPUT_}'. Please see the actions's documentation for more details." "ERROR"
            invalid=true
        fi
    done

    [[ "$invalid" == "true" ]] && exit 1
}

# Maps a sensor platform or CPU architecture to an image architecture (amd64, arm64)
to_image_arch() {
    case "$1" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

# Maps an image architecture to the sensor platform used by falcon-container-sensor-pull.sh
to_sensor_platform() {
    case "$1" in
        amd64) echo "x86_64" ;;
        arm64) echo "aarch64" ;;
        *) return 1 ;;
    esac
}

# Strips the tag or digest from an image reference
image_repository() {
    local ref="${1%@*}"
    [[ "${ref##*/}" == *:* ]] && ref="${ref%:*}"
    echo "$ref"
}

# Reads an image manifest from its registry. Sets IMAGE_KIND to "index" or "manifest" and
# IMAGE_PLATFORMS to one "<os>/<arch> <digest>" line per platform (no digest for a single
# manifest). Uses docker buildx when available, else docker manifest inspect.
inspect_remote_image() {
    local image="$1"
    IMAGE_KIND=""
    IMAGE_PLATFORMS=""

    if docker buildx version >/dev/null 2>&1; then
        local raw
        raw=$(docker buildx imagetools inspect --raw "$image" 2>/dev/null) || return 1
        if grep -q '"manifests"' <<<"$raw"; then
            IMAGE_KIND="index"
            IMAGE_PLATFORMS=$(docker buildx imagetools inspect "$image" \
                --format '{{range .Manifest.Manifests}}{{if .Platform}}{{.Platform.OS}}/{{.Platform.Architecture}} {{.Digest}}{{"\n"}}{{end}}{{end}}') || return 1
        else
            IMAGE_KIND="manifest"
            IMAGE_PLATFORMS=$(docker buildx imagetools inspect "$image" --format '{{.Image.OS}}/{{.Image.Architecture}}') || return 1
        fi
    else
        local flat entry platform os arch digest
        flat=$(docker manifest inspect -v "$image" 2>/dev/null | tr -d ' \t\n') || return 1
        [[ -n "$flat" ]] || return 1
        if [[ "$flat" == \[* ]]; then
            IMAGE_KIND="index"
        else
            IMAGE_KIND="manifest"
        fi
        # Each entry starts with its "Ref"; the first digest and platform in it belong to its descriptor
        while read -r entry; do
            [[ -n "$entry" ]] || continue
            platform=$(grep -o '"platform":{[^}]*}' <<<"$entry" | head -n 1)
            os=$(grep -o '"os":"[^"]*"' <<<"$platform" | cut -d '"' -f 4)
            arch=$(grep -o '"architecture":"[^"]*"' <<<"$platform" | cut -d '"' -f 4)
            digest=$(grep -o '"digest":"sha256:[0-9a-f]*"' <<<"$entry" | head -n 1 | cut -d '"' -f 4)
            [[ -n "$os" && -n "$arch" ]] || continue
            if [[ "$IMAGE_KIND" == "index" ]]; then
                IMAGE_PLATFORMS+="${os}/${arch} ${digest}"$'\n'
            else
                IMAGE_PLATFORMS+="${os}/${arch}"$'\n'
            fi
        done <<<"${flat//'{"Ref":'/$'\n'}"
    fi

    # Attestation manifests use the unknown/unknown platform
    IMAGE_PLATFORMS=$(grep -v -e '^unknown/' -e '^$' <<<"$IMAGE_PLATFORMS")
    [[ -n "$IMAGE_PLATFORMS" ]]
}

# Prints the platform falconutil should patch for, as "<os>/<arch>"
detect_source_platform() {
    local source="$1"
    local local_platform="" platforms daemon_platform

    # With IfNotPresent falconutil uses a local image when there is one, so detect from it first.
    # A local multi-platform image reports the daemon's default platform, or nothing if
    # that platform isn't present.
    if [[ "${INPUT_IMAGE_PULL_POLICY:-}" == "IfNotPresent" ]]; then
        local_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$source" 2>/dev/null)
        if [[ -n "$local_platform" && "$local_platform" != "/" ]]; then
            log "Detected platform ${local_platform} from local source image $source"
            echo "$local_platform"
            return
        fi
    fi

    if ! inspect_remote_image "$source"; then
        die "Unable to read the platform of source image $source. Make sure the runner is logged in to its registry, or set falcon_image_platform."
    fi

    platforms=$(cut -d ' ' -f 1 <<<"$IMAGE_PLATFORMS" | sort -u)
    if [[ $(wc -l <<<"$platforms") -eq 1 ]]; then
        log "Detected platform ${platforms} from source image $source"
        echo "$platforms"
        return
    fi

    # Same default as docker pull: the daemon's platform
    daemon_platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')
    if grep -qx "$daemon_platform" <<<"$platforms"; then
        log "Source image $source is multi-platform; using the runner's platform ${daemon_platform}"
        echo "$daemon_platform"
        return
    fi

    die "Source image $source supports $(tr '\n' ' ' <<<"$platforms")but not the runner's platform ${daemon_platform}. Set falcon_image_platform to choose one."
}

# Prints a reference to image that resolves to the target platform: a multi-arch image is
# pinned to the digest of the target platform, because with the containerd image store a
# multi-arch tag resolves locally to the runner's platform. Returns 2 when the manifest
# can't be read.
pin_to_target_platform() {
    local image="$1" label="$2" digest

    inspect_remote_image "$image" || return 2

    if [[ "$IMAGE_KIND" == "manifest" ]]; then
        [[ "$IMAGE_PLATFORMS" == "$TARGET_PLATFORM" ]] ||
            die "$label $image is ${IMAGE_PLATFORMS}, but the target platform is ${TARGET_PLATFORM}"
        echo "$image"
        return
    fi

    digest=$(awk -v platform="$TARGET_PLATFORM" '$1 == platform { print $2; exit }' <<<"$IMAGE_PLATFORMS")
    [[ -n "$digest" ]] || die "$label $image does not provide the target platform ${TARGET_PLATFORM}"
    echo "$(image_repository "$image")@${digest}"
}

# Prints the source image reference to patch
resolve_source_image() {
    local image="$1" resolved rc local_platform

    # With IfNotPresent falconutil patches the local image, which can differ from the registry
    if [[ "${INPUT_IMAGE_PULL_POLICY:-}" == "IfNotPresent" ]]; then
        local_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image" 2>/dev/null)
        if [[ "$local_platform" == "$TARGET_PLATFORM" ]]; then
            echo "$image"
            return
        fi
    fi

    resolved=$(pin_to_target_platform "$image" "Source image")
    rc=$?
    case "$rc" in
        0) echo "$resolved" ;;
        2)
            # Not readable from a registry: falconutil can only use a local image as is
            local_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image" 2>/dev/null)
            if [[ -n "$local_platform" && "$local_platform" != "/" && "$local_platform" != "$TARGET_PLATFORM" ]]; then
                if docker image inspect --platform "$TARGET_PLATFORM" "$image" >/dev/null 2>&1; then
                    die "Source image $image is a local multi-platform image that is not in a registry, and falconutil can only patch its ${local_platform} variant on this runner. Push the image to a registry, or build it for ${TARGET_PLATFORM} only."
                fi
                die "Local source image $image is ${local_platform}, but the target platform is ${TARGET_PLATFORM}"
            fi
            echo "$image"
            ;;
        *) exit 1 ;;
    esac
}

# Prints the Falcon image reference to patch with
resolve_falcon_image() {
    local image="$1" resolved rc

    resolved=$(pin_to_target_platform "$image" "Falcon image")
    rc=$?
    case "$rc" in
        0) echo "$resolved" ;;
        2)
            log "Unable to read the manifest of Falcon image $image; using it as is" "WARNING"
            echo "$image"
            ;;
        *) exit 1 ;;
    esac
}

# falconutil builds the patched image with RUN steps for the target platform, so the Docker
# host must be able to run its binaries. Without emulation that fails deep in the build.
check_target_emulation() {
    local falcon_image="$1" daemon_arch output

    daemon_arch=$(docker version --format '{{.Server.Arch}}')
    [[ "$daemon_arch" == "$TARGET_ARCH" ]] && return

    if ! output=$(docker run --rm --platform "$TARGET_PLATFORM" --entrypoint /bin/sh "$falcon_image" -c true 2>&1); then
        if grep -q "exec format error" <<<"$output"; then
            die "The Docker host is linux/${daemon_arch} and can't run ${TARGET_PLATFORM} binaries, which falconutil needs to build the patched image. Set up emulation before this action, for example with docker/setup-qemu-action."
        fi
        log "Unable to check ${TARGET_PLATFORM} emulation on the Docker host: $output" "WARNING"
    fi
}

# Pulls the Falcon Container Sensor image for a sensor platform and prints its name
pull_falcon_image() {
    local sensor_platform="$1"
    local output
    # shellcheck disable=SC2086
    output=$(bash falcon-container-sensor-pull.sh -u "${INPUT_FALCON_CLIENT_ID}" -r "${INPUT_FALCON_REGION}" -t falcon-container ${VERSION} --platform "$sensor_platform") || return 1
    echo "$output" | grep "^registry.*.com/falcon-container" | tail -n 1
}

validate_required_inputs

# Target platform: falcon_image_platform when set, else detected from the source image
if [[ -n "${INPUT_FALCON_IMAGE_PLATFORM:-}" ]]; then
    TARGET_ARCH=$(to_image_arch "$INPUT_FALCON_IMAGE_PLATFORM") ||
        die "Unsupported falcon_image_platform '${INPUT_FALCON_IMAGE_PLATFORM}'. Allowed values are x86_64, aarch64"
    TARGET_PLATFORM="linux/${TARGET_ARCH}"
else
    TARGET_PLATFORM=$(detect_source_platform "$INPUT_SOURCE_IMAGE_URI") || exit 1
    [[ "${TARGET_PLATFORM%%/*}" == "linux" ]] || die "Source image platform ${TARGET_PLATFORM} is not supported. Only Linux images can be patched."
    TARGET_ARCH=$(to_image_arch "${TARGET_PLATFORM#*/}") ||
        die "Source image platform ${TARGET_PLATFORM} is not supported. Supported platforms are linux/amd64, linux/arm64"
fi
log "Target platform: ${TARGET_PLATFORM}"

# falconutil runs on the runner, so it must match the runner's CPU architecture
RUNNER_ARCH=$(to_image_arch "$(uname -m)") || die "Unsupported runner architecture $(uname -m)"

# Download the falcon-container-sensor-pull.sh script
curl -O https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh

# Check if the version is provided
VERSION=${INPUT_VERSION:+"--version ${INPUT_VERSION}"}

image_name=$(pull_falcon_image "$(to_sensor_platform "$RUNNER_ARCH")")
binary_arch="$RUNNER_ARCH"
if [[ -z "$image_name" && "$TARGET_ARCH" != "$RUNNER_ARCH" ]]; then
    log "No ${RUNNER_ARCH} Falcon Container Sensor image found; using the ${TARGET_ARCH} image, which needs emulation on this runner" "WARNING"
    image_name=$(pull_falcon_image "$(to_sensor_platform "$TARGET_ARCH")")
    binary_arch="$TARGET_ARCH"
fi

# Check if the image name is empty
if [ -z "$image_name" ]; then
    echo "Failed to get the image name."
    exit 1
fi

FALCONUTIL_BIN_PATH=/opt/crowdstrike/bin
# Make sure the directory exists
mkdir -p $FALCONUTIL_BIN_PATH
id=$(docker create --platform "linux/${binary_arch}" "$image_name")
docker cp "$id:/usr/bin/falconutil" $FALCONUTIL_BIN_PATH
docker rm "$id" >/dev/null

# Ensure the binary exists
if [ ! -f $FALCONUTIL_BIN_PATH/falconutil ]; then
    echo "Failed to copy the FCS binary."
    exit 1
fi

log "Successfully pulled Falcon Container Sensor image: $image_name"

falcon_image_uri=$(resolve_falcon_image "${INPUT_FALCON_IMAGE_URI:-$image_name}") || exit 1
log "Falcon Container Sensor image for ${TARGET_PLATFORM}: $falcon_image_uri"

source_image_uri=$(resolve_source_image "$INPUT_SOURCE_IMAGE_URI") || exit 1
log "Source image for ${TARGET_PLATFORM}: $source_image_uri"

check_target_emulation "$falcon_image_uri"

{
    # Set the bin path as an output
    echo "FALCONUTIL_BIN=$FALCONUTIL_BIN_PATH/falconutil"
    # Set the image name as an output
    echo "FALCON_IMAGE_URI=$falcon_image_uri"
    # Set the source image as an output
    echo "SOURCE_IMAGE_URI=$source_image_uri"
    # Set the target platform as an output
    echo "FALCON_IMAGE_PLATFORM=$TARGET_PLATFORM"
} >> "$GITHUB_OUTPUT"
