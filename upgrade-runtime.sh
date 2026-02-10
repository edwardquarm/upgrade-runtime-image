#!/bin/bash

# upgrade-runtime.sh - Switch InferenceServices to latest template runtime
# Usage: ./upgrade-runtime.sh -n <namespace> [--apply]

SCRIPT_NAME="$(basename "$0")"
VERSION="1.0"

NAMESPACE=""
SHOW_HELP=false
VERBOSE=false
APPLY=false
BACKUP=false
BACKUP_DIR="."
ROLLBACK_FILE=""
BACKUP_FILE=""
ROLLBACK_SCRIPT=""
LOG_FILE=""
LOG_DIR=""
TEMPLATE_NAMESPACE="redhat-ods-applications"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

show_help() {
    cat << EOF
${BOLD}Serving Runtime Upgrade Helper${NC}

${BOLD}DESCRIPTION:${NC}
    Scans InferenceServices in a namespace and switches them from outdated
    namespaced ServingRuntimes to the latest runtime defined by templates in
    the template namespace.

${BOLD}USAGE:${NC}
    $SCRIPT_NAME -n <namespace> [OPTIONS]

${BOLD}REQUIRED PARAMETERS:${NC}
    -n, --namespace NAMESPACE   Target namespace

${BOLD}OPTIONS:${NC}
    --apply                    Apply changes without confirmation (default is dry-run)
    --backup                   Save original runtimes for rollback (requires --apply)
    --backup-dir DIR           Directory for backup and rollback files (default: .)
    --rollback FILE            Roll back using a backup file created with --backup
    --log-file FILE            Write all output to a log file
    --log-dir DIR              Write all output to a timestamped log file in DIR
    -v, --verbose              Show detailed info
    -h, --help                 Show this help message and exit

${BOLD}EXAMPLES:${NC}
    # Dry-run
    $SCRIPT_NAME -n my-models

    # Apply changes
    $SCRIPT_NAME -n my-models --apply

    # Apply with rollback backup
    $SCRIPT_NAME -n my-models --apply --backup

    # Roll back using a backup file
    $SCRIPT_NAME -n my-models --rollback ./runtime-backup-my-models-20240210-120000.tsv

    # Save output to a log file
    $SCRIPT_NAME -n my-models --apply --backup --log-dir ./logs

EOF
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "${BOLD}${BLUE}$1${NC}"; }

prompt_yes_no() {
    local prompt="$1"
    local reply

    read -r -p "$prompt [y/N]: " reply
    case "$reply" in
        y|Y|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

setup_logging() {
    local ts

    if [ -n "$LOG_DIR" ] && [ -z "$LOG_FILE" ]; then
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            log_error "Unable to create log directory: $LOG_DIR"
            exit 1
        fi
        ts=$(date +%Y%m%d-%H%M%S)
        LOG_FILE="${LOG_DIR}/upgrade-runtime-${NAMESPACE}-${ts}.log"
    fi

    if [ -n "$LOG_FILE" ]; then
        exec > >(tee -a "$LOG_FILE") 2>&1
        log_info "Logging to: $LOG_FILE"
    fi
}

init_backup_files() {
    local ts

    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        log_error "Unable to create backup directory: $BACKUP_DIR"
        exit 1
    fi

    ts=$(date +%Y%m%d-%H%M%S)
    BACKUP_FILE="${BACKUP_DIR}/runtime-backup-${NAMESPACE}-${ts}.tsv"
    ROLLBACK_SCRIPT="${BACKUP_DIR}/rollback-${NAMESPACE}-${ts}.sh"

    printf "# isvc_name\truntime_path\truntime_name\n" > "$BACKUP_FILE"

    cat << EOF > "$ROLLBACK_SCRIPT"
#!/bin/bash
set -euo pipefail

NAMESPACE="$NAMESPACE"
BACKUP_FILE="$BACKUP_FILE"

if [ ! -f "\$BACKUP_FILE" ]; then
    echo "[ERROR] Backup file not found: \$BACKUP_FILE"
    exit 1
fi

while IFS=\$'\t' read -r isvc_name runtime_path runtime_name; do
    [ -z "\$isvc_name" ] && continue
    [[ "\$isvc_name" =~ ^# ]] && continue
    patch=\$(printf '[{\"op\":\"replace\",\"path\":\"%s\",\"value\":\"%s\"}]' "\$runtime_path" "\$runtime_name")
    oc patch inferenceservice "\$isvc_name" -n "\$NAMESPACE" \\
        --type='json' \\
        -p="\$patch"
done < "\$BACKUP_FILE"

echo "[INFO] Rollback complete"
EOF

    chmod +x "$ROLLBACK_SCRIPT" 2>/dev/null || true

    log_info "Backup file: $BACKUP_FILE"
    log_info "Rollback script: $ROLLBACK_SCRIPT"
}

append_backup_entry() {
    local isvc_name="$1"
    local runtime_path="$2"
    local runtime_name="$3"

    printf "%s\t%s\t%s\n" "$isvc_name" "$runtime_path" "$runtime_name" >> "$BACKUP_FILE"
}

run_rollback() {
    if [ ! -f "$ROLLBACK_FILE" ]; then
        log_error "Rollback file not found: $ROLLBACK_FILE"
        exit 1
    fi

    log_header "Rollback InferenceService Runtimes"
    echo ""

    while IFS=$'\t' read -r isvc_name runtime_path runtime_name; do
        [ -z "$isvc_name" ] && continue
        [[ "$isvc_name" =~ ^# ]] && continue
        oc patch inferenceservice "$isvc_name" -n "$NAMESPACE" \
            --type='json' \
            -p="[{\"op\":\"replace\",\"path\":\"$runtime_path\",\"value\":\"$runtime_name\"}]" \
            >/dev/null \
            && echo -e "${GREEN}Rolled back:${NC} $isvc_name" \
            || echo -e "${RED}Rollback failed:${NC} $isvc_name"
    done < "$ROLLBACK_FILE"

    echo ""
    log_info "Rollback complete"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v oc &> /dev/null; then
        log_error "OpenShift CLI (oc) is not installed or not in PATH"
        exit 1
    fi

    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Please login first: oc login"
        exit 1
    fi

    if ! oc get inferenceservice -n "$NAMESPACE" &> /dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist or is not accessible"
        exit 1
    fi

    if [ -z "$ROLLBACK_FILE" ]; then
        if ! oc get template -n "$TEMPLATE_NAMESPACE" &>/dev/null; then
            log_error "Template namespace '$TEMPLATE_NAMESPACE' is not accessible"
            exit 1
        fi
    fi

    log_info "Prerequisites check passed"
}

get_isvc_runtime_path() {
    local isvc_name="$1"
    local model_runtime
    local predictor_runtime

    model_runtime=$(oc get inferenceservice "$isvc_name" -n "$NAMESPACE" -o jsonpath='{.spec.predictor.model.runtime}' 2>/dev/null)
    if [ -n "$model_runtime" ] && [ "$model_runtime" != "null" ]; then
        echo "/spec/predictor/model/runtime"
        return
    fi

    predictor_runtime=$(oc get inferenceservice "$isvc_name" -n "$NAMESPACE" -o jsonpath='{.spec.predictor.runtime}' 2>/dev/null)
    if [ -n "$predictor_runtime" ] && [ "$predictor_runtime" != "null" ]; then
        echo "/spec/predictor/runtime"
        return
    fi

    echo ""
}

get_isvc_runtime_name() {
    local isvc_name="$1"
    local runtime

    runtime=$(oc get inferenceservice "$isvc_name" -n "$NAMESPACE" -o jsonpath='{.spec.predictor.model.runtime}' 2>/dev/null)
    if [ -z "$runtime" ] || [ "$runtime" = "null" ]; then
        runtime=$(oc get inferenceservice "$isvc_name" -n "$NAMESPACE" -o jsonpath='{.spec.predictor.runtime}' 2>/dev/null)
    fi

    echo "$runtime"
}

get_runtime_annotation() {
    local runtime_name="$1"
    local annotation="$2"
    oc get servingruntime "$runtime_name" -n "$NAMESPACE" -o jsonpath="{.metadata.annotations.${annotation}}" 2>/dev/null
}

resolve_template_resource() {
    local template_name="$1"

    if oc get template "$template_name" -n "$TEMPLATE_NAMESPACE" &>/dev/null; then
        echo "$template_name"
        return
    fi

    if [[ "$template_name" != *-template ]]; then
        if oc get template "${template_name}-template" -n "$TEMPLATE_NAMESPACE" &>/dev/null; then
            echo "${template_name}-template"
            return
        fi
    fi

    echo ""
}

get_template_runtime_version() {
    local template_resource="$1"
    oc get template "$template_resource" -n "$TEMPLATE_NAMESPACE" \
        -o jsonpath='{.objects[?(@.kind=="ServingRuntime")].metadata.annotations.opendatahub\.io/runtime-version}' 2>/dev/null
}

get_template_runtime_name() {
    local template_resource="$1"
    oc get template "$template_resource" -n "$TEMPLATE_NAMESPACE" \
        -o jsonpath='{.objects[?(@.kind=="ServingRuntime")].metadata.name}' 2>/dev/null
}

apply_template_runtime() {
    local template_resource="$1"
    oc process -n "$TEMPLATE_NAMESPACE" "$template_resource" \
        | oc apply -n "$NAMESPACE" -f - >/dev/null
}

apply_plan() {
    local plan_file="$1"
    local applied_count=0

    while IFS=$'\t' read -r isvc_name runtime_path runtime_name template_resource target_runtime_name latest_version; do
        [ -z "$isvc_name" ] && continue

        if ! apply_template_runtime "$template_resource"; then
            echo -e "${RED}Result:${NC} failed to apply template runtime for $isvc_name"
            continue
        fi

        if oc patch inferenceservice "$isvc_name" -n "$NAMESPACE" \
            --type='json' \
            -p="[{\"op\":\"replace\",\"path\":\"$runtime_path\",\"value\":\"$target_runtime_name\"}]" \
            >/dev/null; then
            echo -e "${GREEN}Result:${NC} updated $isvc_name"
            applied_count=$((applied_count+1))
            if [ "$BACKUP" = "true" ] && [ -n "$BACKUP_FILE" ]; then
                append_backup_entry "$isvc_name" "$runtime_path" "$runtime_name"
            fi
        else
            echo -e "${RED}Result:${NC} update failed $isvc_name"
        fi
    done < "$plan_file"

    if [ "$applied_count" -gt 0 ]; then
        log_info "Applied updates to $applied_count InferenceService(s)"
    else
        log_warn "No updates applied"
    fi
}

count_isvc_using_runtime() {
    local runtime_name="$1"
    oc get inferenceservice -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.predictor.model.runtime}{"\t"}{.spec.predictor.runtime}{"\n"}{end}' \
        | awk -v r="$runtime_name" '($2==r || $3==r){c++} END{print c+0}'
}

main() {
    log_header "Serving Runtime Upgrade Helper v$VERSION"
    echo ""

    setup_logging

    check_prerequisites
    echo ""

    if [ -n "$ROLLBACK_FILE" ]; then
        run_rollback
        return
    fi

    log_info "Scanning InferenceServices in namespace: $NAMESPACE"
    echo ""

    isvc_list=$(oc get inferenceservice -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
    if [ -z "$isvc_list" ]; then
        log_warn "No InferenceServices found in namespace '$NAMESPACE'"
        exit 0
    fi

    log_header "Planned Runtime Upgrades"
    echo ""

    plan_count=0
    plan_file=$(mktemp)
    did_apply=false

    while IFS= read -r isvc_name; do
        [ -z "$isvc_name" ] && continue

        runtime_name=$(get_isvc_runtime_name "$isvc_name")
        if [ -z "$runtime_name" ] || [ "$runtime_name" = "null" ]; then
            [ "$VERBOSE" = "true" ] && echo -e "${YELLOW}[SKIP]${NC} $isvc_name: no runtime set"
            continue
        fi

        if ! oc get servingruntime "$runtime_name" -n "$NAMESPACE" &>/dev/null; then
            [ "$VERBOSE" = "true" ] && echo -e "${YELLOW}[SKIP]${NC} $isvc_name: runtime '$runtime_name' is not namespaced"
            continue
        fi

        template_name=$(get_runtime_annotation "$runtime_name" 'opendatahub\.io/template-name')
        current_version=$(get_runtime_annotation "$runtime_name" 'opendatahub\.io/runtime-version')

        if [ -z "$template_name" ]; then
            [ "$VERBOSE" = "true" ] && echo -e "${YELLOW}[SKIP]${NC} $isvc_name: runtime '$runtime_name' has no template annotation"
            continue
        fi

        target_runtime_name=""
        latest_version=""
        source_label=""
        template_resource=""

        template_resource=$(resolve_template_resource "$template_name")
        if [ -z "$template_resource" ]; then
            [ "$VERBOSE" = "true" ] && echo -e "${YELLOW}[SKIP]${NC} $isvc_name: no template found for '$template_name'"
            continue
        fi
        latest_version=$(get_template_runtime_version "$template_resource")
        target_runtime_name=$(get_template_runtime_name "$template_resource")
        source_label="Template/$template_resource"

        if [ -z "$target_runtime_name" ]; then
            [ "$VERBOSE" = "true" ] && echo -e "${YELLOW}[SKIP]${NC} $isvc_name: unable to determine target runtime name"
            continue
        fi

        if [ -n "$current_version" ] && [ -n "$latest_version" ] && [ "$current_version" = "$latest_version" ]; then
            [ "$VERBOSE" = "true" ] && echo -e "${GREEN}[OK]${NC} $isvc_name: runtime already at latest ($current_version)"
            continue
        fi

        runtime_path=$(get_isvc_runtime_path "$isvc_name")
        if [ -z "$runtime_path" ]; then
            echo -e "${BOLD}Model:${NC} $isvc_name"
            echo -e "  ${CYAN}Current runtime:${NC} $runtime_name (${current_version:-unknown})"
            echo -e "  ${CYAN}Target runtime:${NC} $target_runtime_name (${latest_version:-unknown})"
            echo -e "  ${CYAN}Source:${NC} $source_label"
            echo -e "  ${RED}Result:${NC} unable to determine runtime path"
            echo ""
            continue
        fi

        echo -e "${BOLD}Model:${NC} $isvc_name"
        echo -e "  ${CYAN}Current runtime:${NC} $runtime_name (${current_version:-unknown})"
        echo -e "  ${CYAN}Target runtime:${NC} $target_runtime_name (${latest_version:-unknown})"
        echo -e "  ${CYAN}Source:${NC} $source_label"
        echo -e "  ${YELLOW}Result:${NC} planned (apply pending)"
        plan_count=$((plan_count+1))
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$isvc_name" "$runtime_path" "$runtime_name" "$template_resource" "$target_runtime_name" "${latest_version:-}" \
            >> "$plan_file"

        echo ""
    done <<< "$isvc_list"

    if [ "$plan_count" -eq 0 ]; then
        rm -f "$plan_file"
        echo ""
        log_info "No upgrades required"
        echo ""
        log_info "Done"
        return
    fi

    echo ""
    if [ "$APPLY" = "true" ]; then
        if [ "$BACKUP" = "false" ]; then
            BACKUP=true
            log_info "Enabling backup for apply"
        fi
        if [ "$BACKUP" = "true" ] && [ -z "$BACKUP_FILE" ]; then
            init_backup_files
            echo ""
        fi
        apply_plan "$plan_file"
        did_apply=true
    else
        if [ -t 0 ]; then
            if prompt_yes_no "Proceed with upgrades and create backup?"; then
                APPLY=true
                BACKUP=true
                init_backup_files
                echo ""
                apply_plan "$plan_file"
                did_apply=true
            else
                log_info "No changes applied"
            fi
        else
            log_info "Dry-run only (no TTY). Re-run with --apply to proceed."
        fi
    fi

    rm -f "$plan_file"

    if [ "$did_apply" = "true" ] && [ -n "$ROLLBACK_SCRIPT" ] && [ -t 0 ]; then
        echo ""
        if prompt_yes_no "Rollback now and restore original runtimes?"; then
            "$ROLLBACK_SCRIPT"
        else
            log_info "Rollback script available at: $ROLLBACK_SCRIPT"
        fi
    fi

    echo ""
    log_info "Done"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --backup)
            BACKUP=true
            shift
            ;;
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --rollback)
            ROLLBACK_FILE="$2"
            shift 2
            ;;
        --log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            SHOW_HELP=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

if [ "$SHOW_HELP" = "true" ]; then
    show_help
    exit 0
fi

if [ -z "$NAMESPACE" ]; then
    log_error "Namespace is required. Use -n <namespace> to specify the target namespace"
    echo "Use -h or --help for usage information"
    exit 1
fi

if [ -n "$ROLLBACK_FILE" ] && [ "$APPLY" = "true" ]; then
    log_error "Cannot use --apply with --rollback"
    exit 1
fi

main "$@"
