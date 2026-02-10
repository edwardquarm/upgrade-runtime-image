#!/bin/bash

# upgrade-runtime.sh - Switch InferenceServices to latest cluster serving runtime
# Usage: ./upgrade-runtime.sh -n <namespace> [--apply] [--cleanup]

SCRIPT_NAME="$(basename "$0")"
VERSION="1.0"

NAMESPACE=""
SHOW_HELP=false
VERBOSE=false
APPLY=false
CLEANUP=false

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
    namespaced ServingRuntimes to the latest ClusterServingRuntime when a
    matching template name is available.

${BOLD}USAGE:${NC}
    $SCRIPT_NAME -n <namespace> [OPTIONS]

${BOLD}REQUIRED PARAMETERS:${NC}
    -n, --namespace NAMESPACE   Target namespace

${BOLD}OPTIONS:${NC}
    --apply                    Apply changes (default is dry-run)
    --cleanup                  Delete old namespaced runtimes if unused after apply
    -v, --verbose              Show detailed info
    -h, --help                 Show this help message and exit

${BOLD}EXAMPLES:${NC}
    # Dry-run
    $SCRIPT_NAME -n my-models

    # Apply changes
    $SCRIPT_NAME -n my-models --apply

    # Apply and cleanup old runtimes
    $SCRIPT_NAME -n my-models --apply --cleanup

EOF
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "${BOLD}${BLUE}$1${NC}"; }

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

get_cluster_runtime_annotation() {
    local runtime_name="$1"
    local annotation="$2"
    oc get clusterservingruntime "$runtime_name" -o jsonpath="{.metadata.annotations.${annotation}}" 2>/dev/null
}

count_isvc_using_runtime() {
    local runtime_name="$1"
    oc get inferenceservice -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.predictor.model.runtime}{"\t"}{.spec.predictor.runtime}{"\n"}{end}' \
        | awk -v r="$runtime_name" '($2==r || $3==r){c++} END{print c+0}'
}

main() {
    log_header "Serving Runtime Upgrade Helper v$VERSION"
    echo ""

    check_prerequisites
    echo ""

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

        if ! oc get clusterservingruntime "$template_name" &>/dev/null; then
            [ "$VERBOSE" = "true" ] && echo -e "${YELLOW}[SKIP]${NC} $isvc_name: no ClusterServingRuntime '$template_name' found"
            continue
        fi

        latest_version=$(get_cluster_runtime_annotation "$template_name" 'opendatahub\.io/runtime-version')

        if [ -n "$current_version" ] && [ -n "$latest_version" ] && [ "$current_version" = "$latest_version" ]; then
            [ "$VERBOSE" = "true" ] && echo -e "${GREEN}[OK]${NC} $isvc_name: runtime already at latest ($current_version)"
            continue
        fi

        echo -e "${BOLD}Model:${NC} $isvc_name"
        echo -e "  ${CYAN}Current runtime:${NC} $runtime_name (${current_version:-unknown})"
        echo -e "  ${CYAN}Target runtime:${NC} $template_name (${latest_version:-unknown})"

        if [ "$APPLY" = "true" ]; then
            runtime_path=$(get_isvc_runtime_path "$isvc_name")
            if [ -z "$runtime_path" ]; then
                echo -e "  ${RED}Result:${NC} unable to determine runtime path"
            else
                oc patch inferenceservice "$isvc_name" -n "$NAMESPACE" \
                    --type='json' \
                    -p="[{\"op\":\"replace\",\"path\":\"$runtime_path\",\"value\":\"$template_name\"}]" \
                    >/dev/null
                echo -e "  ${GREEN}Result:${NC} updated"
                plan_count=$((plan_count+1))
            fi
        else
            echo -e "  ${YELLOW}Result:${NC} dry-run (use --apply to update)"
            plan_count=$((plan_count+1))
        fi

        echo ""
    done <<< "$isvc_list"

    if [ "$APPLY" = "true" ] && [ "$CLEANUP" = "true" ]; then
        log_header "Cleanup Old Namespaced Runtimes"
        echo ""
        runtimes=$(oc get servingruntime -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        while IFS= read -r rt_name; do
            [ -z "$rt_name" ] && continue
            count=$(count_isvc_using_runtime "$rt_name")
            if [ "$count" -eq 0 ]; then
                echo -e "${CYAN}Deleting:${NC} $rt_name"
                oc delete servingruntime "$rt_name" -n "$NAMESPACE" >/dev/null
            else
                [ "$VERBOSE" = "true" ] && echo -e "${YELLOW}Keeping:${NC} $rt_name (still used by $count InferenceService(s))"
            fi
        done <<< "$runtimes"
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
        --cleanup)
            CLEANUP=true
            shift
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

main "$@"
