#!/bin/sh
set -eu

# Reuse the isolated runtime provisioned for this workstation.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
abba_runtime=${BRAINBUILDER_ABBA_RUNTIME:-"$HOME/.cache/brainbuilder-abba"}
export JAVA_HOME=${JAVA_HOME:-$(/usr/libexec/java_home -v 11)}
export PATH="$abba_runtime/runtime/apache-maven-3.9.11/bin:$PATH"

exec "$abba_runtime/venv/bin/python" "$script_dir/../abba_bridge.py" run \
    --elastix "$abba_runtime/runtime/elastix-5.2.0/bin/elastix" \
    --transformix "$abba_runtime/runtime/elastix-5.2.0/bin/transformix" "$@"
