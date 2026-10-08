# CrowdStrike Falcon Utility GitHub Action

This GitHub Action allows you to use CrowdStrike's Falcon Utility to patch container images with the Falcon Container Sensor directly in your CI/CD pipeline.

## Features

- Patch application container images with Falcon Container Sensor
- Deploy container workloads with runtime security protection
- Customize patching parameters for various cloud platforms (ACA, ACI, ECS_FARGATE, CLOUDRUN)
- Support for various container deployment scenarios

## Prerequisites

### Create a CrowdStrike API Client

> [!NOTE]
> API clients are granted one or more API scopes. Scopes allow access to specific CrowdStrike APIs and describe the actions that an API client can perform. To create an API client, see [API Clients and Keys](https://falcon.crowdstrike.com/login/?unilogin=true&next=/api-clients-and-keys).

Ensure the following API scopes are assigned to the client:

- **Sensor Download**[read]
- **Falcon Images Download**[read]

### Create a GitHub Secret

This action relies on the environment variable `FALCON_CLIENT_SECRET` to authenticate with the CrowdStrike API.

Create a GitHub secret in your repository to store the CrowdStrike API Client secret created from the step above. For more information, see [Creating secrets for a repository](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-a-repository).

### Docker Authentication Limitations

The Falcon Utility requires direct authentication credentials in `~/.docker/config.json` and does not support credential helpers (such as the `gcloud` helper used by Google Artifact Registry). When authenticating with registries that use credential helpers instead of storing encoded credentials directly in the config file, patching operations may fail with authentication errors.

**Workaround:**

1. Add an explicit step to pull the source image before patching: `docker pull SOURCE_IMAGE_URI`
2. Set `image_pull_policy: IfNotPresent` in your action configuration to use the locally cached image

This limitation applies to any registry that uses credential helpers rather than storing base64-encoded credentials directly in the auth section of the Docker configuration.

## Multi-Architecture Support

Recent versions of the Falcon Container Sensor are published as multi-architecture images supporting both x86_64 and ARM64 platforms. The action works on x86_64 and ARM64 runners and can patch images for either platform, including cross-architecture (for example, `linux/amd64` images on an ARM64 runner or an Apple Silicon machine).

By default, the action detects the platform to patch from the source image:

- A single-platform source image is patched for its platform.
- A multi-platform source image is patched for the runner's platform, the same way `docker pull` picks one.

To choose the platform explicitly, set `falcon_image_platform` to the platform of the image you are patching (not the platform of the runner):

```yaml
falcon_image_platform: 'aarch64'
```

The action then:

- Runs falconutil for the runner's architecture, so no emulation is needed on the runner.
- Pins multi-architecture Falcon Container Sensor images, including one set with `falcon_image_uri`, to the digest of the target platform.
- Passes `--platform` to falconutil, so the source and Falcon images are pulled for the target platform.

To read image manifests, the action uses `docker buildx imagetools` when available and falls back to `docker manifest inspect`. Detecting the platform of a source image that is not present on the runner requires access to its registry, so log in to that registry before running the action.

falconutil builds the patched image for the target platform, so patching for a platform other than the runner's requires emulation on the runner. GitHub-hosted runners don't have it by default; set it up before this action:

```yaml
- uses: docker/setup-qemu-action@v3
```

Without emulation, the action fails before patching with an error that explains this.

## Usage

To use this action in your workflow, add the following step:
<!-- x-release-please-start-version -->
```yaml
- name: Patch Container Image with Falcon Sensor
  uses: crowdstrike/falconutil-action@v1.1.0
  with:
    falcon_client_id: 'abcdefghijk123456789'
    falcon_region: 'us-2'
    source_image_uri: 'myregistry/myapp:latest'
    target_image_uri: 'myregistry/myapp:patched'
    cid: '1234567890ABCDEFG'
  env:
    FALCON_CLIENT_SECRET: ${{ secrets.FALCON_CLIENT_SECRET }}
```
<!-- x-release-please-end -->
## Environment Variables

| Variable | Description | Required | Default | Example/Allowed Values |
|----------|-------------|----------|---------|---------|
| `FALCON_CLIENT_SECRET` | CrowdStrike API Client Secret for authentication | **Yes** | - | `${{ secrets.FALCON_CLIENT_SECRET }}` |

## Inputs

| Input | Description | Required | Default | Example/Allowed Values |
|-------|-------------|----------|---------|---------|
| `falcon_client_id` | CrowdStrike API Client ID for authentication | **Yes** | - | `abcdefghijk123456789` |
| `falcon_region` | CrowdStrike API region | **Yes** | `us-1` | Allowed values: `us-1, us-2, eu-1, us-gov-1, us-gov-2` |
| `version` | Falcon Container Sensor version to pull (*defaults to the latest*) | No | - | `7.20.0-5908` |
| `source_image_uri` | Source Image URI to be patched | **Yes** | - | `myregistry/myapp:latest` |
| `target_image_uri` | Expected URI for patched Target Image | **Yes** | - | `myregistry/myapp:patched` |
| `cid` | Customer ID w/checksum to use | **Yes** | - | `1234567890ABCDEFG-XY` |
| `falcon_image_uri` | Falcon Container Sensor Image URI (*defaults to using the image pulled by the action*) | No | - | `my-falcon-sensor-image:latest` |
| `cloud_service` | Cloud Service platform the container will be deployed on | No | - | Allowed values: `ACA, ACI, ECS_FARGATE, CLOUDRUN` |
| `container` | Container name that can be used to identify the container on the Falcon console | No | - | `my-container` |
| `container_group` | Azure container group name | No | - | `my-container-group` |
| `falconctl_opts` | All falconctl options in a single string | No | - | `--tags=test --filter=include` |
| `image_pull_policy` | PullPolicy for Source and Falcon Container Sensor Image | No | `Always` | Allowed values: `IfNotPresent, Always` |
| `resource_group` | Azure resource group name | No | - | `my-resource-group` |
| `subscription` | Azure subscription id | No | - | `subscription-id` |
| `falcon_image_platform` | Platform of the image to patch (*defaults to the platform detected from the source image*) | No | - | `x86_64`, `aarch64` |

## Examples

### Basic container image patching
<!-- x-release-please-start-version -->
```yaml
- name: Patch Container Image
  uses: crowdstrike/falconutil-action@v1.1.0
  with:
    falcon_client_id: ${{ vars.FALCON_CLIENT_ID }}
    falcon_region: 'eu-1'
    source_image_uri: 'myregistry/myapp:latest'
    target_image_uri: 'myregistry/myapp:patched'
    cid: ${{ secrets.FALCON_CID }}
  env:
    FALCON_CLIENT_SECRET: ${{ secrets.FALCON_CLIENT_SECRET }}
```
<!-- x-release-please-end -->
### Azure Container Instance deployment
<!-- x-release-please-start-version -->
```yaml
- name: Patch Container Image for ACI
  uses: crowdstrike/falconutil-action@v1.1.0
  with:
    falcon_client_id: ${{ vars.FALCON_CLIENT_ID }}
    falcon_region: 'us-1'
    source_image_uri: 'myregistry/myapp:latest'
    target_image_uri: 'myregistry/myapp:patched'
    cid: ${{ secrets.FALCON_CID }}
    cloud_service: 'ACI'
    container_group: 'my-container-group'
    resource_group: 'my-resource-group'
    subscription: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  env:
    FALCON_CLIENT_SECRET: ${{ secrets.FALCON_CLIENT_SECRET }}
```
<!-- x-release-please-end -->
### AWS ECS Fargate deployment
<!-- x-release-please-start-version -->
```yaml
- name: Patch Container Image for ECS Fargate
  uses: crowdstrike/falconutil-action@v1.1.0
  with:
    falcon_client_id: ${{ vars.FALCON_CLIENT_ID }}
    falcon_region: 'us-2'
    source_image_uri: '123456789012.dkr.ecr.us-west-2.amazonaws.com/myapp:latest'
    target_image_uri: '123456789012.dkr.ecr.us-west-2.amazonaws.com/myapp:patched'
    cid: ${{ secrets.FALCON_CID }}
    cloud_service: 'ECS_FARGATE'
    image_pull_policy: 'IfNotPresent'
  env:
    FALCON_CLIENT_SECRET: ${{ secrets.FALCON_CLIENT_SECRET }}
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```
<!-- x-release-please-end -->
## Full Workflow Examples

For complete workflow examples including registry authentication and image pushing, see the examples directory:

- [Docker Hub Registry Example](./examples/docker-hub-workflow.yml)
- [GitHub Container Registry Example](./examples/ghcr-workflow.yml)
- [AWS ECR Registry Example](./examples/aws-ecr-workflow.yml)
- [Azure Container Registry Example](./examples/azure-acr-workflow.yml)
- [Google Artifact Registry Example](./examples/google-artifact-registry-workflow.yml)

## Support

This project is a community-driven, open source project designed to provide a simple way to run CrowdStrike's Falcon Utility in a GitHub Action.
While not a formal CrowdStrike product, this project is maintained by CrowdStrike and supported in partnership with the open source developer community.

For additional support, please see the [SUPPORT](SUPPORT.md) file.

## License

See [LICENSE](LICENSE)
