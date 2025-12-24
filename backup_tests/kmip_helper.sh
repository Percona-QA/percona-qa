#!/bin/bash

# KMIP Helper Library
# Usage: source kmip_helper.sh
# 
# This library provides functions for managing KMIP servers (PyKMIP, HashiCorp, etc.)
# Required: Docker must be installed and running

# set -euo pipefail

# Global variables
declare -ga KMIP_CONTAINER_NAMES
declare -gA KMIP_CONFIGS_DEFAULTS=(
    #[pykmip]="addr=127.0.0.1,image=satyapercona/kmip:latest,port=5696,name=kmip_pykmip"
    [hashicorp]="addr=127.0.0.1,port=5696,name=kmip_hashicorp,setup_script=hashicorp-kmip-setup.sh"
    [fortanix]="addr=216.180.120.88,port=5696,name=kmip_fortanix,setup_script=fortanix_kmip_setup.py"
    #[ciphertrust]="addr=127.0.0.1,port=5696,name=kmip_ciphertrust,setup_script=setup_kmip_api.py"
)

# Initialize default configurations if not already set
init_kmip_configs() {
    # If KMIP_CONFIGS not set in main script, initialize with defaults
    if [[ -z "${KMIP_CONFIGS[*]-}" ]]; then
        declare -gA KMIP_CONFIGS=()
    fi

    # Apply defaults for all keys defined in main script if not set
    for key in "${!KMIP_CONFIGS[@]}"; do
        if [[ -z "${KMIP_CONFIGS[$key]}" ]]; then
            KMIP_CONFIGS[$key]="${KMIP_CONFIGS_DEFAULTS[$key]}"
        fi
    done

    echo "KMIP configurations initialized from Defaults" >&2
}

# Cleanup existing Docker container
cleanup_existing_container() {
    local container_name="$1"
    local container_id=$(docker ps -aq --filter "name=$container_name")

    [ -z "$container_id" ] && return 0

    if ! docker rm -f "$container_id" >/dev/null 2>&1; then
        return 1
    fi
    sleep 5  # Allow port to be released
    return 0
}

# Validate if a port is available
validate_port_available() {
    local port="$1"
    local max_attempts=10

    if [[ -z "$port" ]]; then
        echo "Error: No port specified"
        return 1
    fi

    for i in $(seq 1 $max_attempts); do
        local port_in_use=false

        # Method 1: Fast bash TCP check (works without external tools)
        if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
          port_in_use=true
        fi

        # Fallback methods only if bash TCP check failed
        if [[ "$port_in_use" == false ]]; then
        # Prefer ss over netstat (faster and more modern)
          if command -v ss >/dev/null 2>&1; then
            ss -tuln | grep -qE ":(${port})\s+" && port_in_use=true
          elif command -v netstat >/dev/null 2>&1; then
            netstat -tuln 2>/dev/null | grep -qE ":(${port})\s+" && port_in_use=true
          fi
        fi

        if [[ "$port_in_use" == false ]]; then
            return 0
        fi

        echo -n "."
        echo
        if [[ $i -lt $max_attempts ]]; then
            sleep 2
        fi
    done

    return 1
}
validate_environment() {
    local type="${1:-}"  # Use :- to handle empty input safely

    [[ -z "$type" ]] && {
        echo "ERROR: No KMIP type specified" >&2
        return 1
    }

    # Safely check if key exists
    [[ -n "${KMIP_CONFIGS[$type]+x}" ]] || {
        echo "ERROR: Invalid type '$type'. Available types:" >&2
        printf "  - %s\n" "${!KMIP_CONFIGS[@]}" >&2
        return 1
    }

    return 0
}

# Get all KMIP container names
get_kmip_container_names() {
    KMIP_CONTAINER_NAMES=()
    for type in "${!KMIP_CONFIGS[@]}"; do
        IFS=',' read -ra pairs <<< "${KMIP_CONFIGS[$type]-}"  # Use - for safety
        for pair in "${pairs[@]}"; do
            IFS='=' read -r key value <<< "${pair-}"
            [[ "${key-}" == "name" ]] && KMIP_CONTAINER_NAMES+=("${value-}") && break
        done
    done
}

# Parse configuration for a specific type
parse_config() {
    local type=$1
    # Clear the existing config array
    unset kmip_config
    declare -gA kmip_config  # Global associative array

    IFS=',' read -ra pairs <<< "${KMIP_CONFIGS[$type]}"
    for pair in "${pairs[@]}"; do
        IFS='=' read -r key value <<< "$pair"
        kmip_config["$key"]="$value"
    done

    # Set defaults if not specified
    kmip_config["type"]="$type"
    [[ -z "${kmip_config[name]}" ]] && kmip_config["name"]="kmip_${type}"
    [[ -z "${kmip_config[addr]}" ]] && kmip_config["addr"]="127.0.0.1"
    [[ -z "${kmip_config[port]}" ]] && kmip_config["port"]="5696"
    [[ -z "${kmip_config[cert_dir]}" ]] && kmip_config["cert_dir"]="kmip_certs_${kmip_config[type]}"
}

# Generate KMIP configuration file
generate_kmip_config() {
    local type="$1"
    local addr="$2"
    local port="$3"
    local cert_dir="$4"
    local config_file="${cert_dir}/component_keyring_kmip.cnf"
    echo "Generating KMIP config for: ${type}"

    sudo tee "$config_file" > /dev/null <<EOF
{
  "server_addr": "$addr",
  "server_port": "$port",
  "client_ca": "${cert_dir}/client_certificate.pem",
  "client_key": "${cert_dir}/client_key.pem",
  "server_ca": "${cert_dir}/root_certificate.pem"
}
EOF
    echo "Configuration file created: $config_file"
}

# Setup PyKMIP server
setup_pykmip() {
    local type="pykmip"
    local container_name="${kmip_config[name]}"
    local addr="${kmip_config[addr]}"
    local port="${kmip_config[port]}"
    local image="${kmip_config[image]}"
    local cert_dir="${HOME}/${kmip_config[cert_dir]}"


    if [ -d "$cert_dir" ]; then
      echo "Cleaning existing certificate directory: $cert_dir"
      rm -rf "$cert_dir"/* 2>/dev/null
    fi

    mkdir -p "$cert_dir" || {
      echo "ERROR: Failed to create certificate directory: $cert_dir" >&2
      return 1
    }
    chmod 700 "$cert_dir"  # Restrict access to owner only

    # 1. Cleanup existing resources
    echo "Cleaning up existing container... "
    if cleanup_existing_container "$container_name"; then
        echo "Done"
    else
        echo "Failed"
        return 1
    fi

    # 2. Verify port availability
    echo "Checking port $port availability... "
    if validate_port_available "$port"; then
        echo "Available"
    else
        echo "Unavailable"
        echo "Port $port is in use by:"
        lsof -i :"$port"
        # Do container at global level, from what we know.
        get_kmip_container_names
        for kmip_name in "${KMIP_CONTAINER_NAMES[@]}"; do
          cleanup_existing_container "$kmip_name"
        done
        if ! validate_port_available "$port"; then
          echo "Still unavailable $port, please check and clean up port $port and retry"
          exit 1;
        fi
    fi

    # 3. Start container
    echo "Starting container... "
    if ! docker run -d \
        --name "$container_name" \
        --security-opt seccomp=unconfined \
        --cap-add=NET_ADMIN \
        -p "$port:5696" \
        "$image" >/dev/null 2>&1; then
        echo "Failed"
        return 1
    fi
    echo "Started (ID: $(docker inspect --format '{{.Id}}' "$container_name"))"

    sleep 10

    docker cp "$container_name":/opt/certs/root_certificate.pem $cert_dir/root_certificate.pem >/dev/null 2>&1
    docker cp "$container_name":/opt/certs/client_key_jane_doe.pem $cert_dir/client_key.pem >/dev/null 2>&1
    docker cp "$container_name":/opt/certs/client_certificate_jane_doe.pem $cert_dir/client_certificate.pem >/dev/null 2>&1

    sleep 5

    # Post-startup configuration
    echo "Generating KMIP configuration..."
    generate_kmip_config "$type" "$addr" "$port" "$cert_dir" || {
        echo "Failed to generate KMIP config"
        return 1
    }

    echo "PyKMIP server started successfully on address $addr and port $port"
    return 0
}

# Setup HashiCorp Vault KMIP server
setup_hashicorp() {
    local type="hashicorp"
    local container_name="${kmip_config[name]}"
    local addr="${kmip_config[addr]}"
    local port="${kmip_config[port]}"
    local image="${kmip_config[image]}"
    local setup_script="${kmip_config[setup_script]}"
    local cert_dir="${HOME}/${kmip_config[cert_dir]}"


    echo "Cleaning up existing container... "
    if cleanup_existing_container "$container_name"; then
        echo "Done"
    else
        echo "Failed"
        return 1
    fi

    echo "Checking port $port availability... "
    if validate_port_available "$port"; then
        echo "Available"
    else
        echo "Unavailable"
        echo "Port $port is in use by:"
        lsof -i :"$port"
        # Do container at global level, from what we know.
        get_kmip_container_names
        for name in "${KMIP_CONTAINER_NAMES[@]}"; do
          cleanup_existing_container "$name"
        done
        if ! validate_port_available "$port"; then
          echo "Still unavailable $port, please check and clean up port $port and retry"
          exit 1;
        fi
    fi

    # Download first, then execute the hashicorp setup
    # ToDo Remove before Merge
   script=$(curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused \
      --connect-timeout 5 --max-time 30 \
      https://raw.githubusercontent.com/Percona-QA/percona-qa/cad02909729f1347fa01079247c0ca03f2e3acab/"$setup_script")
    curl_exit_code=$?

    # ToDo Remove before Merge
    # script=$(curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused \
    #   --connect-timeout 5 --max-time 30 \
    #   https://raw.githubusercontent.com/Percona-QA/percona-qa/refs/heads/master/"$setup_script")



    if [ "${curl_exit_code:-1}" -ne 0 ] || [ -z "$script" ]; then
      echo "Failed to download script after retries (curl exit code: $curl_exit_code)"
      exit 1
    fi


    if [ -d "$cert_dir" ]; then
      echo "Cleaning existing certificate directory: $cert_dir"
      rm -rf "$cert_dir"/* 2>/dev/null
    fi

    mkdir -p "$cert_dir" || {
      echo "ERROR: Failed to create certificate directory: $cert_dir" >&2
      return 1
    }

    # Check if license file exists
    if [[ ! -f "$DEFAULT_LICENSE" ]]; then
      echo "ERROR: License file not found at: $DEFAULT_LICENSE" >&2
      exit 1
    fi

    echo "Executing script: $script"
    # Execute the script
    echo "$script" | sudo bash -s -- --cert-dir="$cert_dir" --license="$DEFAULT_LICENSE"
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Failed to execute script $setup_script, (exit code: $exit_code)" >&2
        return 1
    fi

    generate_kmip_config "$type" "$addr" "$port" "$cert_dir" || {
        echo "Failed to generate KMIP config" >&2; return 1; }

    echo "Hashicorp server started successfully on address $addr and port $port"
    return 0
}

setup_fortanix() {
    local type="fortanix"
    local container_name="${kmip_config[name]}"
    local addr="${kmip_config[addr]}"
    local port="${kmip_config[port]}"
    local email="${kmip_config[email]}"
    local password="${kmip_config[password]}"
    local setup_script="${kmip_config[setup_script]}"
    local cert_dir="${HOME}/${kmip_config[cert_dir]}"

    # Check if both variables are set and not empty
    if [[ -z "$email" || -z "$password" ]]; then
      echo "Error: Both email and password must be set in Config or Script for Fortanix KMIP Provider!!" >&2
      exit 1
    fi

    echo "Checking port availability... "
    if validate_port_available "$port"; then
        echo "Available"
    else
        echo "Unavailable"
        echo "Port $port is in use by:"
        lsof -i :"$port"
        return 1
    fi

    echo "Starting Fortanix KMIP server in (script method): $setup_script"
    # Download first, then execute the fortanix setup script
    script=$(wget -qO- https://raw.githubusercontent.com/Percona-QA/percona-qa/8ab34a4da257070518825fcdf8ae547f99705597/"$setup_script")

    # To-Do Remove B4 Merge
    # script=$(wget -qO- https://raw.githubusercontent.com/Percona-QA/percona-qa/refs/heads/master/"$setup_script")
    wget_exit_code=$?

    if [ $wget_exit_code -ne 0 ]; then
      echo "Failed to download script (wget exit code: $wget_exit_code)"
      exit 1
    fi

    if [ -z "$script" ]; then
      echo "Downloaded script is empty"
      exit 1
    fi

    mkdir -p "$cert_dir" || true

    # Execute the Python script from a variable
    echo "$script" | python3 - --cert-dir="$cert_dir" --email="$email" --password="$password"
    exit_code=$?

    generate_kmip_config "$type" "$addr" "$port" "$cert_dir" || {
        echo "Failed to generate KMIP config"; exit 1; }

    echo "Fortanix server started successfully on address $addr and port $port"
    return 0
}

# Placeholder for CipherTrust setup
setup_cipher_api() {
    echo "CipherTrust setup not implemented yet"
    return 1
}

# Main function to start KMIP server
start_kmip_server() {
    local type="$1"
    validate_environment "$type" || return 1
    parse_config "$type"
    echo "Starting ${type^^} KMIP Server on port ${kmip_config[port]}"

    case "$type" in
        pykmip)     setup_pykmip ;;
        hashicorp)  setup_hashicorp ;;
        fortanix)  setup_fortanix ;;
        ciphertrust) setup_cipher_api ;;
        *)          echo "Unsupported KMIP Type: $type"; return 1 ;;
    esac
}
