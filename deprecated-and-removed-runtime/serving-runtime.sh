#!/bin/bash

# serving-runtime.sh - Check deployed models with runtime and image information
# Usage: ./serving-runtime.sh -n <namespace>

# Script version and metadata
SCRIPT_NAME="$(basename "$0")"
VERSION="1.1"

# Default values
NAMESPACE=""
ALL_NAMESPACES=false
SHOW_HELP=false
VERBOSE=false

# Removed templates list (template-name values)
REMOVED_TEMPLATES=(
    "caikit-tgis-serving-template"
    "caikit-standalone-serving-template"
    "ovms"
)
declare -A REMOVED_TEMPLATES_FOUND

record_removed_template() {
    local template_name="$1"
    REMOVED_TEMPLATES_FOUND["$template_name"]=1
}

# Color codes for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to display help
show_help() {
    cat << EOF
${BOLD}KServe InferenceService Runtime and Image Checker${NC}

${BOLD}DESCRIPTION:${NC}
    This script checks all deployed InferenceServices (models) in a specified namespace or across all namespaces
    and displays their associated ServingRuntime and container images. Useful for
    documenting current deployments and planning ODH upgrades.

${BOLD}USAGE:${NC}
    $SCRIPT_NAME -n <namespace> [OPTIONS]
    $SCRIPT_NAME --all-namespaces [OPTIONS]

${BOLD}REQUIRED (CHOOSE ONE):${NC}
    -n, --namespace NAMESPACE   Target namespace to check for deployed models
    --all-namespaces            Check for deployed models across all namespaces

${BOLD}OPTIONS:${NC}
    -v, --verbose              Show detailed information
    -h, --help                 Show this help message and exit

${BOLD}EXAMPLES:${NC}
    # Check models in specific namespace
    $SCRIPT_NAME -n my-models

    # Check models across all namespaces
    $SCRIPT_NAME --all-namespaces

    # Check with verbose output
    $SCRIPT_NAME -n my-models --verbose

    # Check models in current namespace context
    $SCRIPT_NAME -n \$(oc project -q)

${BOLD}PREREQUISITES:${NC}
    • OpenShift CLI (oc) - logged into target cluster
    • jq (JSON processor) - for JSON manipulation
    • Access to target namespace or all namespaces if --all-namespaces is used

${BOLD}OUTPUT:${NC}
    The script displays:
    • InferenceService name and status
    • ServingRuntime name and deployment mode
    • Container image used by the runtime

EOF
}

# Function for logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "${BOLD}${BLUE}$1${NC}"
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if oc is installed and user is logged in
    if ! command -v oc &> /dev/null; then
        log_error "OpenShift CLI (oc) is not installed or not in PATH"
        exit 1
    fi

    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Please login first: oc login"
        exit 1
    fi

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Please install jq for JSON processing"
        exit 1
    fi

    # Check if namespace exists and is accessible
    if [ "$ALL_NAMESPACES" = false ] && ! oc get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist or is not accessible"
        echo "Available namespaces:"
        oc get namespaces --no-headers -o custom-columns=NAME:.metadata.name | sed 's/^/  • /'
        exit 1
    fi

    if [ "$ALL_NAMESPACES" = true ]; then
        if ! oc auth can-i get inferenceservices --all-namespaces &> /dev/null; then
            log_error "Insufficient permissions to list InferenceServices across all namespaces"
            exit 1
        fi
        if ! oc auth can-i get servingruntimes --all-namespaces &> /dev/null; then
            log_error "Insufficient permissions to list ServingRuntimes across all namespaces"
            exit 1
        fi
    fi

    log_info "Prerequisites check passed"
}

# Function to get InferenceService information
get_inferenceservice_info() {
    local isvc_name="$1"
    local target_namespace="$2"
    local runtime_name
    local deployment_mode
    local status
    local ready_status

    # Get basic InferenceService information
    runtime_name=$(oc get inferenceservice "$isvc_name" -n "$target_namespace" -o jsonpath='{.spec.predictor.model.runtime}' 2>/dev/null)
    deployment_mode=$(oc get inferenceservice "$isvc_name" -n "$target_namespace" -o jsonpath='{.metadata.annotations.serving\.kserve\.io/deploymentMode}' 2>/dev/null || echo "Serverless (default)")
    status=$(oc get inferenceservice "$isvc_name" -n "$target_namespace" -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null || echo "Unknown")
    ready_status=$(oc get inferenceservice "$isvc_name" -n "$target_namespace" -o jsonpath='{.status.conditions[-1].status}' 2>/dev/null || echo "Unknown")

    # Display InferenceService information
    echo -e "${BOLD}Model:${NC} $isvc_name"
    if [ "$ALL_NAMESPACES" = true ]; then
        echo -e "  ${CYAN}Namespace:${NC} $target_namespace"
    fi
    echo -e "  ${CYAN}Runtime:${NC} ${runtime_name:-N/A}"
    echo -e "  ${CYAN}Deployment Mode:${NC} $deployment_mode"
    echo -e "  ${CYAN}Status:${NC} $status ($ready_status)"

    # Get ServingRuntime images if runtime exists
    if [ -n "$runtime_name" ] && [ "$runtime_name" != "null" ]; then
        get_servingruntime_images "$runtime_name" "$target_namespace"
    else
        echo -e "  ${YELLOW}Image Used:${NC} No runtime specified"
    fi

    echo ""
}

# Function to get ServingRuntime container images
get_servingruntime_images() {
    local runtime_name="$1"
    local target_namespace="$2"
    local images
    local template_name
    local template_display_name
    local removed=false
    local runtime_command
    local runtime_args

    # Check if ServingRuntime exists
    if ! oc get servingruntimes "$runtime_name" -n "$target_namespace" &>/dev/null; then
        echo -e "  ${RED}Image Used:${NC} ServingRuntime '$runtime_name' not found"
        return
    fi

    # Get template info from annotations if present
    template_name=$(oc get servingruntimes "$runtime_name" -n "$target_namespace" -o jsonpath='{.metadata.annotations.opendatahub\.io/template-name}' 2>/dev/null)
    template_display_name=$(oc get servingruntimes "$runtime_name" -n "$target_namespace" -o jsonpath='{.metadata.annotations.opendatahub\.io/template-display-name}' 2>/dev/null)
    if [ -n "$template_name" ] && [ "$template_name" != "null" ]; then
        for removed_template in "${REMOVED_TEMPLATES[@]}"; do
            if [ "$template_name" = "$removed_template" ]; then
                removed=true
                break
            fi
        done

        if [ -n "$template_display_name" ] && [ "$template_display_name" != "null" ]; then
            echo -e "  ${CYAN}Template Used:${NC} $template_name ($template_display_name)"
        else
            echo -e "  ${CYAN}Template Used:${NC} $template_name"
        fi

        if [ "$removed" = true ]; then
            record_removed_template "$template_name"
            echo -e "  ${RED}X Template Removed:${NC} This template has been removed. Please migrate the workload to another template."
        fi
    else
        echo -e "  ${YELLOW}Template Used:${NC} Not found in annotations"
    fi

    # Detect vLLM API server usage
    runtime_command=$(oc get servingruntimes "$runtime_name" -n "$target_namespace" -o jsonpath='{.spec.containers[*].command}' 2>/dev/null)
    runtime_args=$(oc get servingruntimes "$runtime_name" -n "$target_namespace" -o jsonpath='{.spec.containers[*].args}' 2>/dev/null)
    if echo "$runtime_command $runtime_args" | grep -q "vllm.entrypoints.openai.api_server"; then
        echo -e "  ${CYAN}vLLM API Used:${NC} OpenAI API"
    fi
    if echo "$runtime_command $runtime_args" | grep -q "vllm_tgis_adapter"; then
        echo -e "  ${CYAN}vLLM API Used:${NC} TGIS Adapter API"
    fi

    # Get container images
    images=$(oc get servingruntimes "$runtime_name" -n "$target_namespace" -o jsonpath='{.spec.containers[*].image}' 2>/dev/null)

    if [ -n "$images" ]; then
        echo -e "  ${CYAN}Image Used:${NC}"
        echo "$images" | tr ' ' '\n' | while read -r image; do
            echo -e "    • $image"
        done
    else
        echo -e "  ${YELLOW}Image Used:${NC} No container images found"
    fi
}

# Function to generate summary report
generate_summary() {
    local total_models="$1"
    local total_runtimes

    log_header "Summary Report"
    if [ "$ALL_NAMESPACES" = true ]; then
        echo -e "${BOLD}Namespace:${NC} All"
    else
        echo -e "${BOLD}Namespace:${NC} $NAMESPACE"
    fi
    echo -e "${BOLD}Total Models:${NC} $total_models"

    if [ "$total_models" -gt 0 ]; then
        # Count unique runtimes
        if [ "$ALL_NAMESPACES" = true ]; then
            total_runtimes=$(oc get inferenceservice -A -o jsonpath='{.items[*].spec.predictor.model.runtime}' 2>/dev/null | tr ' ' '\n' | sort | uniq | wc -l)
        else
            total_runtimes=$(oc get inferenceservice -n "$NAMESPACE" -o jsonpath='{.items[*].spec.predictor.model.runtime}' 2>/dev/null | tr ' ' '\n' | sort | uniq | wc -l)
        fi
        echo -e "${BOLD}Unique Runtimes:${NC} $total_runtimes"
    fi

    echo -e "${BOLD}Removed / deprecated templates:${NC}"
    if [ "${#REMOVED_TEMPLATES_FOUND[@]}" -gt 0 ]; then
        removed_list=$(printf '%s\n' "${!REMOVED_TEMPLATES_FOUND[@]}" | sort)
        while read -r removed_template; do
            if [ -n "$removed_template" ]; then
                echo -e "  ${YELLOW}!${NC} $removed_template"
            fi
        done <<< "$removed_list"
    else
        echo -e "  ${GREEN}✓ None${NC}"
    fi

    if [ "$total_models" -gt 0 ]; then
        echo ""
        if [ "$ALL_NAMESPACES" = true ]; then
            echo -e "${BOLD}Available ServingRuntimes across all namespaces:${NC}"
            if oc get servingruntimes -A --no-headers 2>/dev/null | grep -q .; then
                oc get servingruntimes -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | sed 's/^/  • /'
            else
                echo "  • No ServingRuntimes found"
            fi
        else
            echo -e "${BOLD}Available ServingRuntimes in namespace:${NC}"
            if oc get servingruntimes -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
                oc get servingruntimes -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | sed 's/^/  • /'
            else
                echo "  • No ServingRuntimes found"
            fi
        fi
    fi

    echo ""
    echo -e "${BOLD}Generated:${NC} $(date)"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --all-namespaces)
            ALL_NAMESPACES=true
            NAMESPACE=""
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

# Show help if requested
if [ "$SHOW_HELP" == "true" ]; then
    show_help
    exit 0
fi

# Validate required parameters
if [ "$ALL_NAMESPACES" = true ] && [ -n "$NAMESPACE" ]; then
    log_error "Use either -n <namespace> or --all-namespaces, not both"
    echo "Use -h or --help for usage information"
    exit 1
fi

if [ "$ALL_NAMESPACES" = false ] && [ -z "$NAMESPACE" ]; then
    log_error "Namespace is required. Use -n <namespace> to specify the target namespace"
    echo "Use -h or --help for usage information"
    exit 1
fi

# Main script execution
main() {
    log_header "KServe InferenceService Runtime Checker v$VERSION"
    echo ""

    # Check prerequisites
    check_prerequisites
    echo ""

    # Get list of InferenceServices
    if [ "$ALL_NAMESPACES" = true ]; then
        log_info "Checking InferenceServices across all namespaces"
    else
        log_info "Checking InferenceServices in namespace: $NAMESPACE"
    fi
    echo ""

    # Get all InferenceServices
    if [ "$ALL_NAMESPACES" = true ]; then
        isvc_list=$(oc get inferenceservice -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null)
    else
        isvc_list=$(oc get inferenceservice -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
    fi

    if [ -z "$isvc_list" ]; then
        if [ "$ALL_NAMESPACES" = true ]; then
            log_warn "No InferenceServices found across all namespaces"
        else
            log_warn "No InferenceServices found in namespace '$NAMESPACE'"
        fi
        echo ""
        generate_summary 0
        exit 0
    fi

    # Process each InferenceService
    model_count=0
    log_header "Deployed Models and Runtimes"
    echo ""

    if [ "$ALL_NAMESPACES" = true ]; then
        while read -r isvc_namespace isvc_name; do
            if [ -n "$isvc_name" ] && [ -n "$isvc_namespace" ]; then
                get_inferenceservice_info "$isvc_name" "$isvc_namespace"
                ((model_count++))
            fi
        done <<< "$isvc_list"
    else
        while IFS= read -r isvc_name; do
            if [ -n "$isvc_name" ]; then
                get_inferenceservice_info "$isvc_name" "$NAMESPACE"
                ((model_count++))
            fi
        done <<< "$isvc_list"
    fi

    # Generate summary
    generate_summary "$model_count"
}

# Run main function
main "$@"
