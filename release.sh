#!/bin/bash
# Prepare a verified archive first, then upload a draft with scripts/publish-release.sh.
set -euo pipefail
exec "$(dirname "$0")/scripts/prepare-release.sh" "$@"
