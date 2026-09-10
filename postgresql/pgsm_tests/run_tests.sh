#!/usr/bin/bash

set -o errexit
set -o nounset
set -o pipefail

###############################################################################
# PGSM Test Framework
#
# Main test runner
#
# Usage:
#   ./run_tests.sh
#   ./run_tests.sh --list
#   ./run_tests.sh --suite sanity
#   ./run_tests.sh --test PGSM-SANITY-001
#   ./run_tests.sh --release
#   ./run_tests.sh --all
#
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Framework paths
###############################################################################

CONFIG_FILE="${SCRIPT_DIR}/config/test_config.sh"

LIB_DIR="${SCRIPT_DIR}/lib"
TEST_DIR="${SCRIPT_DIR}/tests"
RESULT_DIR="${SCRIPT_DIR}/results"
LOG_DIR="${SCRIPT_DIR}/logs"

###############################################################################
# Default options
###############################################################################

RUN_MODE="default"
SUITE=""
TEST_ID=""
VERBOSE=0

###############################################################################
# Runtime state
###############################################################################

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

declare -a FAILED_TEST_NAMES=()
declare -a SKIPPED_TEST_NAMES=()

START_TIME=0
END_TIME=0

###############################################################################
# Colors
###############################################################################

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    RESET=''
fi

###############################################################################
# Usage
###############################################################################

usage()
{
    cat <<EOF

PGSM Test Framework

Usage:
    $(basename "$0") [OPTIONS]

Options:

    --list
        List all available tests.

    --suite <suite>
        Run all tests belonging to a suite.

        Example:
            ./run_tests.sh --suite sanity
            ./run_tests.sh --suite basic

    --test <test-id>
        Run a single test by test ID.

        Example:
            ./run_tests.sh --test PGSM-SANITY-001

    --release
        Run the release validation test suite.

    --all
        Run all available tests.

    --verbose
        Enable verbose output.

    -h, --help
        Show this help message.

Examples:

    # Run default test set
    ./run_tests.sh

    # List tests
    ./run_tests.sh --list

    # Run sanity tests
    ./run_tests.sh --suite sanity

    # Run one test
    ./run_tests.sh --test PGSM-SANITY-001

    # Run release validation
    ./run_tests.sh --release

    # Run everything
    ./run_tests.sh --all

EOF
}

###############################################################################
# Logging helpers
###############################################################################

log_info()
{
    echo -e "${BLUE}[INFO]${RESET} $*"
}

log_debug()
{
    if [[ "${VERBOSE}" -eq 1 ]]; then
        echo -e "${CYAN}[DEBUG]${RESET} $*"
    fi
}

log_success()
{
    echo -e "${GREEN}[PASS]${RESET} $*"
}

log_failure()
{
    echo -e "${RED}[FAIL]${RESET} $*"
}

log_skip()
{
    echo -e "${YELLOW}[SKIP]${RESET} $*"
}

log_error()
{
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

###############################################################################
# Argument parsing
###############################################################################

parse_arguments()
{
    while [[ $# -gt 0 ]]; do

        case "$1" in

            --list)
                RUN_MODE="list"
                shift
                ;;

            --suite)
                if [[ $# -lt 2 ]]; then
                    log_error "--suite requires an argument"
                    usage
                    exit 2
                fi

                RUN_MODE="suite"
                SUITE="$2"
                shift 2
                ;;

            --test)
                if [[ $# -lt 2 ]]; then
                    log_error "--test requires an argument"
                    usage
                    exit 2
                fi

                RUN_MODE="test"
                TEST_ID="$2"
                shift 2
                ;;

            --release)
                RUN_MODE="release"
                shift
                ;;

            --all)
                RUN_MODE="all"
                shift
                ;;

            --verbose)
                VERBOSE=1
                shift
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;

        esac
    done
}

###############################################################################
# Load framework libraries
###############################################################################

load_framework()
{
    log_debug "Loading framework libraries"

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        exit 1
    fi

    source "${CONFIG_FILE}"

    local libraries=(
        "${LIB_DIR}/common.sh"
        "${LIB_DIR}/postgres.sh"
        "${LIB_DIR}/pgsm.sh"
        "${LIB_DIR}/assertions.sh"
        "${LIB_DIR}/logging.sh"
    )

    local lib

    for lib in "${libraries[@]}"; do
        if [[ ! -f "${lib}" ]]; then
            log_error "Required library not found: ${lib}"
            exit 1
        fi

        source "${lib}"
    done
}

###############################################################################
# Prerequisite checks
###############################################################################

check_prerequisites()
{
    log_info "Checking prerequisites..."

    local required_commands=(
        bash
        psql
    )

    local command

    for command in "${required_commands[@]}"; do
        if ! command -v "${command}" >/dev/null 2>&1; then
            log_error "Required command not found: ${command}"
            return 1
        fi
    done

    log_debug "bash: $(bash --version | head -n 1)"
    log_debug "psql: $(psql --version)"

    return 0
}

###############################################################################
# Result directory
###############################################################################

initialize_results()
{
    local timestamp

    timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"

    RUN_RESULT_DIR="${RESULT_DIR}/${timestamp}"
    RUN_LOG_DIR="${LOG_DIR}/${timestamp}"

    mkdir -p "${RUN_RESULT_DIR}"
    mkdir -p "${RUN_LOG_DIR}"

    FRAMEWORK_LOG="${RUN_LOG_DIR}/framework.log"

    touch "${FRAMEWORK_LOG}"

    SUMMARY_FILE="${RUN_RESULT_DIR}/summary.txt"
    RESULTS_FILE="${RUN_RESULT_DIR}/results.csv"
    FAILURES_FILE="${RUN_RESULT_DIR}/failures.txt"
    ENVIRONMENT_FILE="${RUN_RESULT_DIR}/environment.txt"

    touch "${SUMMARY_FILE}"
    touch "${FAILURES_FILE}"

    echo "test_id,test_name,suite,status,duration_seconds" \
        > "${RESULTS_FILE}"

    log_info "Results directory: ${RUN_RESULT_DIR}"
}

###############################################################################
# Environment information
###############################################################################

collect_environment()
{
    {
        echo "PGSM Test Framework"
        echo "==================="
        echo
        echo "Date:        $(date)"
        echo "Hostname:    $(hostname)"
        echo "OS:          $(uname -a)"
        echo
        echo "PostgreSQL:"
        psql --version 2>/dev/null || true
        echo
        echo "Configuration:"
        echo "Config file: ${CONFIG_FILE}"
    } > "${ENVIRONMENT_FILE}"
}

###############################################################################
# Test discovery
###############################################################################

discover_tests()
{
    find "${TEST_DIR}" \
        -type f \
        -name "*.sh" \
        -print \
        | sort
}

###############################################################################
# Test metadata
###############################################################################

get_test_id()
{
    local test_file="$1"

    # shellcheck disable=SC1090
    source "${test_file}"

    if [[ -z "${TEST_ID:-}" ]]; then
        log_error "TEST_ID is not defined in ${test_file}"
        return 1
    fi

    echo "${TEST_ID}"
}

get_test_name()
{
    local test_file="$1"

    # shellcheck disable=SC1090
    source "${test_file}"

    echo "${TEST_NAME:-${TEST_ID:-Unknown}}"
}

get_test_suite()
{
    local test_file="$1"

    # shellcheck disable=SC1090
    source "${test_file}"

    if [[ -n "${TEST_SUITE:-}" ]]; then
        echo "${TEST_SUITE}"
        return
    fi

    # Derive suite from directory if TEST_SUITE isn't explicitly defined.
    local relative_path
    relative_path="${test_file#"${TEST_DIR}"/}"

    echo "${relative_path%%/*}"
}

###############################################################################
# Test selection
###############################################################################

should_run_test()
{
    local test_file="$1"

    local test_id
    local test_suite

    test_id="$(get_test_id "${test_file}")"
    test_suite="$(get_test_suite "${test_file}")"

    case "${RUN_MODE}" in

        default)
            # Iteration 1: default mode runs sanity tests.
            [[ "${test_suite}" == "sanity" ]]
            ;;

        all)
            return 0
            ;;

        suite)
            [[ "${test_suite}" == "${SUITE}" ]]
            ;;

        test)
            [[ "${test_id}" == "${TEST_ID}" ]]
            ;;

        release)
            # Release mode can initially be mapped to the release suite.
            [[ "${test_suite}" == "release" ]]
            ;;

        *)
            return 1
            ;;

    esac
}

###############################################################################
# List tests
###############################################################################

list_tests()
{
    printf "\n%-25s %-45s %-20s\n" \
        "TEST ID" "TEST NAME" "SUITE"

    printf "%-25s %-45s %-20s\n" \
        "-------------------------" \
        "---------------------------------------------" \
        "--------------------"

    local test_file
    local test_id
    local test_name
    local test_suite

    while IFS= read -r test_file; do

        test_id="$(get_test_id "${test_file}")"
        test_name="$(get_test_name "${test_file}")"
        test_suite="$(get_test_suite "${test_file}")"

        printf "%-25s %-45s %-20s\n" \
            "${test_id}" \
            "${test_name}" \
            "${test_suite}"

    done < <(discover_tests)

    echo
}

###############################################################################
# Run one test
###############################################################################

run_test()
{
    local test_file="$1"

    local test_id
    local test_name
    local test_suite

    test_id="$(get_test_id "${test_file}")"
    test_name="$(get_test_name "${test_file}")"
    test_suite="$(get_test_suite "${test_file}")"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    echo
    echo "======================================================================"
    log_info "Running: ${test_id}"
    log_info "Test:    ${test_name}"
    log_info "Suite:   ${test_suite}"
    echo "======================================================================"

    local test_start
    local test_end
    local duration
    local status
    local test_rc

    test_start="$(date +%s)"

    test_rc=0

    (
        source "${test_file}" || exit 1

        if declare -F test_setup >/dev/null 2>&1; then
            test_setup || exit 1
        fi

        if ! declare -F test_body >/dev/null 2>&1; then
            log_error "test_body() is not defined in ${test_file}"
            exit 1
        fi

        test_body
        test_rc=$?

        if declare -F test_cleanup >/dev/null 2>&1; then
            test_cleanup || true
        fi

        exit "${test_rc}"

    )

    test_rc=$?

    test_end="$(date +%s)"
    duration=$((test_end - test_start))

    if [[ "${test_rc}" -eq 0 ]]; then
        status="PASS"

        PASSED_TESTS=$((PASSED_TESTS + 1))

        log_success "${test_id} - ${test_name}"
    else
        status="FAIL"

        FAILED_TESTS=$((FAILED_TESTS + 1))

        FAILED_TEST_NAMES+=("${test_id} - ${test_name}")

        log_failure "${test_id} - ${test_name}"

        echo "${test_id} - ${test_name}" >> "${FAILURES_FILE}"
    fi

    echo "${test_id},\"${test_name}\",${test_suite},${status},${duration}" \
        >> "${RESULTS_FILE}"

    log_debug "Duration: ${duration}s"

    return "${test_rc}"
}

###############################################################################
# Run test suite
###############################################################################

run_tests()
{
    local test_file
    local found=0
    local overall_rc=0

    while IFS= read -r test_file; do

        if should_run_test "${test_file}"; then
            found=1

            if ! run_test "${test_file}"; then
                overall_rc=1
            fi
        fi

    done < <(discover_tests)

    if [[ "${found}" -eq 0 ]]; then

        case "${RUN_MODE}" in
            suite)
                log_error "No tests found for suite: ${SUITE}"
                ;;

            test)
                log_error "Test not found: ${TEST_ID}"
                ;;

            release)
                log_error "No release tests found."
                ;;

            *)
                log_error "No tests found."
                ;;
        esac

        return 1
    fi

    return "${overall_rc}"
}


setup_test_environment()
{
    log_info "Setting up PostgreSQL test environment..."

    postgres_init
    postgres_start

    if ! postgres_is_running; then
        log_error "PostgreSQL failed to start"
        return 1
    fi

    log_info "PostgreSQL started successfully"

    pgsm_is_available || {
        log_error "pg_stat_monitor is not available"
        return 1
    }

    pgsm_create_extension

    log_info "pg_stat_monitor extension created"

    local version
    version="$(pgsm_version)"

    log_info "PGSM version: ${version}"
}

cleanup_test_environment()
{
    log_info "Cleaning up test environment..."

    postgres_stop
}

###############################################################################
# Summary
###############################################################################

print_summary()
{
    END_TIME="$(date +%s)"

    local total_duration
    total_duration=$((END_TIME - START_TIME))

    echo
    echo
    echo "======================================================================"
    echo "                         TEST SUMMARY"
    echo "======================================================================"

    echo
    echo "Total tests : ${TOTAL_TESTS}"
    echo "Passed      : ${PASSED_TESTS}"
    echo "Failed      : ${FAILED_TESTS}"
    echo "Skipped     : ${SKIPPED_TESTS}"
    echo "Duration    : ${total_duration}s"

    echo
    echo "Results     : ${RESULTS_FILE}"
    echo "Environment : ${ENVIRONMENT_FILE}"
    echo "Failures    : ${FAILURES_FILE}"

    if [[ "${FAILED_TESTS}" -gt 0 ]]; then

        echo
        log_failure "Failed tests:"

        local failure

        for failure in "${FAILED_TEST_NAMES[@]}"; do
            echo "    ${failure}"
        done

        echo
        log_failure "TEST RUN FAILED"

    else

        echo
        log_success "ALL TESTS PASSED"

    fi

    echo "======================================================================"

    {
        echo "PGSM Test Summary"
        echo "================="
        echo
        echo "Total tests : ${TOTAL_TESTS}"
        echo "Passed      : ${PASSED_TESTS}"
        echo "Failed      : ${FAILED_TESTS}"
        echo "Skipped     : ${SKIPPED_TESTS}"
        echo "Duration    : ${total_duration}s"
        echo
    } > "${SUMMARY_FILE}"

    if [[ "${FAILED_TESTS}" -gt 0 ]]; then
        for failure in "${FAILED_TEST_NAMES[@]}"; do
            echo "${failure}" >> "${SUMMARY_FILE}"
        done
    fi
}

###############################################################################
# Main
###############################################################################

main()
{
    START_TIME="$(date +%s)"

    parse_arguments "$@"
    load_framework
    check_prerequisites || exit 1

    if [[ "${RUN_MODE}" == "list" ]]; then
        list_tests
        exit 0
    fi

    initialize_results
    collect_environment

    setup_test_environment

    log_info "Starting PGSM test framework"
    log_info "Run mode: ${RUN_MODE}"

    if [[ "${RUN_MODE}" == "suite" ]]; then
        log_info "Suite: ${SUITE}"
    elif [[ "${RUN_MODE}" == "test" ]]; then
        log_info "Test: ${TEST_ID}"
    fi

    local test_run_rc=0

    if ! run_tests; then
        test_run_rc=1
    fi

    cleanup_test_environment
    print_summary

    if [[ "${FAILED_TESTS}" -gt 0 ]]; then
        exit 1
    fi

    exit "${test_run_rc}"
}

main "$@"
