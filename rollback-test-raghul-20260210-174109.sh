#!/bin/bash
set -euo pipefail

NAMESPACE="test-raghul"
BACKUP_FILE="./runtime-backup-test-raghul-20260210-174109.tsv"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "[ERROR] Backup file not found: $BACKUP_FILE"
    exit 1
fi

while IFS=$'\t' read -r isvc_name runtime_path runtime_name; do
    [ -z "$isvc_name" ] && continue
    [[ "$isvc_name" =~ ^# ]] && continue
    patch=$(printf '[{\"op\":\"replace\",\"path\":\"%s\",\"value\":\"%s\"}]' "$runtime_path" "$runtime_name")
    oc patch inferenceservice "$isvc_name" -n "$NAMESPACE" \
        --type='json' \
        -p="$patch"
done < "$BACKUP_FILE"

echo "[INFO] Rollback complete"
