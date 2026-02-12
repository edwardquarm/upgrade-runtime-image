# Deprecated and Removed Runtime Scanner

This folder provides `serving-runtime.sh`, a helper script that scans
InferenceServices and reports their ServingRuntime, runtime template, container
images, and whether a removed template is still in use.

## Download

```bash
curl -fsSL https://raw.githubusercontent.com/edwardquarm/upgrade-runtime-image/main/deprecated-and-removed-runtime/serving-runtime.sh -o serving-runtime.sh
chmod +x serving-runtime.sh
```

## Prerequisites

- `oc` CLI installed and in `PATH`
- Logged into the target OpenShift cluster (`oc login`)
- `jq` installed
- Access to the target namespace (or all namespaces if using `--all-namespaces`)

## Run

Scan a single namespace:

```bash
./serving-runtime.sh -n <namespace>
```

Scan across all namespaces:

```bash
./serving-runtime.sh --all-namespaces
```

Verbose output:

```bash
./serving-runtime.sh -n <namespace> -v
```

## Removed Templates List

Removed templates are tracked inside `serving-runtime.sh` in the
`REMOVED_TEMPLATES` array. If a ServingRuntime reports one of these templates,
the script prints a red `X` and a migration warning.

Example:

```text
Template Used: caikit-tgis-serving-template
X Template Removed: This template has been removed. Please migrate the workload to another template.
```

## vLLM API Detection

If the ServingRuntime container command or args include
`vllm.entrypoints.openai.api_server`, the script prints:

```text
vLLM API Used: OpenAI API
```

## Output Fields

The script includes:
- InferenceService name and status
- Namespace (when using `--all-namespaces`)
- ServingRuntime and deployment mode
- Template used (if available)
- Removed template warning (if applicable)
- vLLM API detection (if applicable)
- Container image(s)
