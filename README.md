# Upgrade Runtime Image Helper

This repo provides `upgrade-runtime.sh`, a helper script that scans
InferenceServices in a namespace and switches them from namespaced
ServingRuntimes to the latest runtime defined by templates in
`redhat-ods-applications`.

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

Plan and prompt (default). The script shows the upgrade plan, asks to proceed,
and automatically creates a backup for rollback:

```bash
./upgrade-runtime.sh -n <namespace>
```

Apply changes without prompting (backup still created automatically):

```bash
./upgrade-runtime.sh -n <namespace> --apply
```

Roll back using a backup file:

```bash
./upgrade-runtime.sh -n <namespace> --rollback ./runtime-backup-<namespace>-<timestamp>.tsv
```

Save output to a log file:

```bash
./upgrade-runtime.sh -n <namespace> --apply --log-dir ./logs
```

Verbose output:

```bash
./upgrade-runtime.sh -n <namespace> -v
```

Example output (default interactive mode):

```text
$ ./upgrade-runtime.sh -n test-raghul
Serving Runtime Upgrade Helper v1.0

[INFO] Checking prerequisites...
[INFO] Prerequisites check passed

[INFO] Scanning InferenceServices in namespace: test-raghul

Planned Runtime Upgrades

Model: vllm-cuda-raw
  Current runtime: vllm-cuda-raw (v0.10.1.1)
  Target runtime: vllm-cuda-runtime (v0.13.0)
  Source: Template/vllm-cuda-runtime-template
  Result: planned (apply pending)

Proceed with upgrades and create backup? [y/N]:
```
