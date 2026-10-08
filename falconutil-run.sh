#!/usr/bin/env bash
# This script executes the Falconutil patch-image command to patch container images
# with Falcon Container Sensor.

readonly FALCONUTIL_BIN="${OUTPUT_FALCONUTIL_BIN:-}"

log() {
    local log_level=${2:-INFO}
    echo "[$(date +'%Y-%m-%dT%H:%M:%S')] $log_level: $1" >&2
}

validate_required_inputs() {
    local invalid=false
    local -a required_inputs=(
        "INPUT_CID"
        "INPUT_SOURCE_IMAGE_URI"
        "INPUT_TARGET_IMAGE_URI"
        "INPUT_FALCON_IMAGE_URI"
    )

    for input in "${required_inputs[@]}"; do
        if [[ -z "${!input:-}" ]]; then
            log "Missing required input/env variable '${input#INPUT_}'. Please see the action's documentation for more details." "ERROR"
            invalid=true
        fi
    done

    if [[ -z "${FALCONUTIL_BIN}" ]]; then
        log "FALCONUTIL_BIN path is not set. The previous step might have failed." "ERROR"
        invalid=true
    fi

    [[ "$invalid" == "true" ]] && exit 1
}

execute_falconutil_patch() {
    log "Executing Falconutil patch-image command"

    # Build command arguments
    local -a cmd_args=(
        "patch-image"
        "--source-image-uri=${INPUT_SOURCE_IMAGE_URI}"
        "--target-image-uri=${INPUT_TARGET_IMAGE_URI}"
        "--cid=${INPUT_CID}"
        "--falcon-image-uri=${INPUT_FALCON_IMAGE_URI}"
    )

    # Add optional arguments if they are provided
    [[ -n "${INPUT_CLOUD_SERVICE:-}" ]] && cmd_args+=("--cloud-service=${INPUT_CLOUD_SERVICE}")
    [[ -n "${INPUT_CONTAINER:-}" ]] && cmd_args+=("--container=${INPUT_CONTAINER}")
    [[ -n "${INPUT_CONTAINER_GROUP:-}" ]] && cmd_args+=("--container-group=${INPUT_CONTAINER_GROUP}")
    [[ -n "${INPUT_FALCONCTL_OPTS:-}" ]] && cmd_args+=("--falconctl-opts=${INPUT_FALCONCTL_OPTS}")
    [[ -n "${INPUT_IMAGE_PULL_POLICY:-}" ]] && cmd_args+=("--image-pull-policy=${INPUT_IMAGE_PULL_POLICY}")
    [[ -n "${INPUT_PLATFORM:-}" ]] && cmd_args+=("--platform=${INPUT_PLATFORM}")
    [[ -n "${INPUT_RESOURCE_GROUP:-}" ]] && cmd_args+=("--resource-group=${INPUT_RESOURCE_GROUP}")
    [[ -n "${INPUT_SUBSCRIPTION:-}" ]] && cmd_args+=("--subscription=${INPUT_SUBSCRIPTION}")

    # Log the full command for debugging
    log "Running: ${FALCONUTIL_BIN} ${cmd_args[*]}"

    # Execute the command
    if "${FALCONUTIL_BIN}" "${cmd_args[@]}"; then
        log "Patching completed successfully"
    else
        local exit_code=$?
        log "Patching failed with exit code ${exit_code}" "ERROR"
        # Let the built-in GitHub Actions error handling take care of the failure
        return $exit_code
    fi
}

main() {
    validate_required_inputs
    execute_falconutil_patch
}

# Execute main function
main
