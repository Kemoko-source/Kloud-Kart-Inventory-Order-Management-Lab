#!/usr/bin/env bash
# Shared by the scripts in this folder: source it after `cd` to the repo root.

# Load .env into the environment, or stop with a message saying how to create it.
load_env() {
    if [ ! -f .env ]; then
        echo "No .env file in $(pwd)." >&2
        echo "Create one from the template, then set your own POSTGRES_PASSWORD:" >&2
        echo "    cp .env.example .env" >&2
        exit 1
    fi
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
}
