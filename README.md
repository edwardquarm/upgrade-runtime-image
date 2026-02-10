# Upgrade Runtime Image Helper

This repo provides `upgrade-runtime.sh`, a helper script that scans
InferenceServices in a namespace and switches them from namespaced
ServingRuntimes to the latest matching ClusterServingRuntime.

## Download

```bash
curl -fsSL https://raw.githubusercontent.com/edwardquarm/upgrade-runtime-image/main/upgrade-runtime.sh -o upgrade-runtime.sh
chmod +x upgrade-runtime.sh
```

## Prerequisites

- `oc` CLI installed and in `PATH`
- Logged into the target OpenShift cluster (`oc login`)
- Access to the target namespace

## Run

Dry-run (default):

```bash
./upgrade-runtime.sh -n <namespace>
```

Apply changes:

```bash
./upgrade-runtime.sh -n <namespace> --apply
```

Apply and cleanup unused namespaced runtimes:

```bash
./upgrade-runtime.sh -n <namespace> --apply --cleanup
```

Verbose output:

```bash
./upgrade-runtime.sh -n <namespace> -v
```
