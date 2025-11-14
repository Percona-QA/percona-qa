#!/bin/bash

# Directory containing the .sh files (default: current directory)
DIR="."

# List of files to exclude (space-separated)
EXCLUDE_LIST=("vault_test_setup.sh" "get_download_link.sh" "run_tests.sh")

# Loop through all .sh files
for file in "$DIR"/*.sh; do
    filename=$(basename "$file")

    # Skip excluded files
    if [[ " ${EXCLUDE_LIST[@]} " =~ " ${filename} " ]]; then
        echo "Skipping $filename"
        continue
    fi
    echo "###########################################################"
    echo "Executing $filename..."
    echo "###########################################################"
    bash "$file"
    ret=$?

    if [[ $ret -ne 0 ]]; then
        echo "❌ $filename failed with exit code $ret"
    else
        echo "✅ $filename completed successfully"
    fi

    echo "--------------------------------------"
done

