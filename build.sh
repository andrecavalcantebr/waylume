#!/bin/bash
# build.sh — shim de compatibilidade; a ferramenta real é build.py
exec "$(dirname "$0")/build.py" "$@"
