#!/usr/bin/env bash
# Build Apache Superset tarball for ODP — FROM LOCAL SOURCE CODE
#
# This script builds a fully self-contained venv tarball of Superset
# including compiled frontend assets, backend Python packages, and
# translations — all from the local source tree so local patches are
# included.
#
# Usage:
#   cd odp/
#   ./buildtarball-from-source.sh                     # uses VERSION file
#   ./buildtarball-from-source.sh --skip-prereqs      # skip install_prereqs.sh
#   ./buildtarball-from-source.sh --extras "postgres,mysql,trino"  # custom DB extras
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERSET_SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PY=python3.11
PY_VERSION=3.11
NODE_MAJOR=20

SKIP_PREREQS="false"
SUPERSET_DB_EXTRAS="postgres"   # comma-separated pyproject.toml extras

# Parse CLI flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-prereqs)  SKIP_PREREQS="true"; shift ;;
        --extras)        SUPERSET_DB_EXTRAS="$2"; shift 2 ;;
        *)               echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Read versions
# ---------------------------------------------------------------------------
VERSION_FILE="${SCRIPT_DIR}/VERSION"
if [ ! -f "${VERSION_FILE}" ]; then
    echo "ERROR: VERSION file not found at ${VERSION_FILE}"
    exit 1
fi
ODP_VERSION=$(cat "${VERSION_FILE}" | tr -d '[:space:]')

# Superset upstream version from package.json (single source of truth for setup.py)
SUPERSET_VERSION=$(python3 -c "import json; print(json.load(open('${SUPERSET_SOURCE_ROOT}/superset-frontend/package.json'))['version'])" 2>/dev/null \
    || grep '"version"' "${SUPERSET_SOURCE_ROOT}/superset-frontend/package.json" | head -1 | sed 's/.*"version".*"\(.*\)".*/\1/')

ODP_SUPERSET_VERSION="${SUPERSET_VERSION}.${ODP_VERSION}"
ODP_SUPERSET_VERSION_UNDERSCORE="${ODP_SUPERSET_VERSION//./_}"
ODP_SUPERSET_VERSION_UNDERSCORE="${ODP_SUPERSET_VERSION_UNDERSCORE//-/_}"

TARBALL_NAME="superset_environment_${ODP_SUPERSET_VERSION_UNDERSCORE}.tar.gz"
VENV_DIR="${SCRIPT_DIR}/superset_venv"

echo "============================================"
echo "Superset Tarball Builder (FROM SOURCE)"
echo "============================================"
echo "Source Directory  : ${SUPERSET_SOURCE_ROOT}"
echo "Superset Version  : ${SUPERSET_VERSION}"
echo "ODP Version       : ${ODP_VERSION}"
echo "Combined Version  : ${ODP_SUPERSET_VERSION}"
echo "DB Extras         : ${SUPERSET_DB_EXTRAS}"
echo "Tarball           : ${TARBALL_NAME}"
echo "============================================"

# Verify source directory
if [ ! -f "${SUPERSET_SOURCE_ROOT}/pyproject.toml" ]; then
    echo "ERROR: pyproject.toml not found at ${SUPERSET_SOURCE_ROOT}"
    exit 1
fi
if [ ! -f "${SUPERSET_SOURCE_ROOT}/setup.py" ]; then
    echo "ERROR: setup.py not found at ${SUPERSET_SOURCE_ROOT}"
    exit 1
fi
if [ ! -d "${SUPERSET_SOURCE_ROOT}/superset-frontend" ]; then
    echo "ERROR: superset-frontend/ not found at ${SUPERSET_SOURCE_ROOT}"
    exit 1
fi

# ===================================================================
# Step 1: Install Prerequisites
# ===================================================================
echo ""
echo "[Step 1/7] Installing Prerequisites"

if [ "${SKIP_PREREQS}" = "true" ]; then
    echo "Skipping (--skip-prereqs)"
else
    PREREQS_SCRIPT="${SCRIPT_DIR}/install_prereqs.sh"
    if [ -f "${PREREQS_SCRIPT}" ]; then
        chmod +x "${PREREQS_SCRIPT}"
        bash "${PREREQS_SCRIPT}"
    else
        echo "WARNING: install_prereqs.sh not found — skipping"
    fi
fi

# Verify critical tools
for cmd in ${PY} node npm git; do
    if ! command -v ${cmd} &>/dev/null; then
        echo "ERROR: '${cmd}' not found. Run install_prereqs.sh first or install manually."
        exit 1
    fi
done
echo "Python : $(${PY} --version 2>&1)"
echo "Node   : $(node --version)"
echo "npm    : $(npm --version)"

# ===================================================================
# Step 2: Install Frontend Dependencies
# ===================================================================
echo ""
echo "[Step 2/7] Installing Frontend Dependencies"

cd "${SUPERSET_SOURCE_ROOT}/superset-frontend"

# Clean previous build artifacts
rm -rf "${SUPERSET_SOURCE_ROOT}/superset/static/assets"
mkdir -p "${SUPERSET_SOURCE_ROOT}/superset/static/assets"

echo "Running npm ci (clean install) ..."
npm ci

# ===================================================================
# Step 3: Build Frontend Assets (Webpack Production Build)
# ===================================================================
echo ""
echo "[Step 3/7] Building Frontend Assets (webpack production build)"
echo "This may take 5–10 minutes and requires ~8 GB RAM ..."

npm run build

# ===================================================================
# Step 4: Build Frontend Translations (.po -> .json)
# ===================================================================
echo ""
echo "[Step 4/7] Building Frontend Translations"

npm run build-translation || echo "WARNING: Frontend translation build failed (non-fatal)"

# Verify assets
ASSETS_DIR="${SUPERSET_SOURCE_ROOT}/superset/static/assets"
if [ ! -d "${ASSETS_DIR}" ]; then
    echo "ERROR: Frontend build failed — ${ASSETS_DIR} was not created!"
    exit 1
fi

ASSET_FILE_COUNT=$(find "${ASSETS_DIR}" -type f | wc -l | tr -d ' ')
if [ "${ASSET_FILE_COUNT}" -lt 10 ]; then
    echo "ERROR: Frontend build appears incomplete — only ${ASSET_FILE_COUNT} files in ${ASSETS_DIR}"
    exit 1
fi

echo "Frontend build successful: ${ASSET_FILE_COUNT} files in ${ASSETS_DIR}"

# Return to script directory
cd "${SCRIPT_DIR}"

# ===================================================================
# Step 5: Create Python Virtual Environment & Install Backend
# ===================================================================
echo ""
echo "[Step 5/7] Creating Python venv and installing Superset backend"

rm -rf "${VENV_DIR}"
${PY} -m venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"

pip install --upgrade pip setuptools wheel

# Install pinned base dependencies (reproducible builds)
echo "Installing pinned base requirements ..."
pip install -r "${SUPERSET_SOURCE_ROOT}/requirements/base.txt"

# Install Superset from local source (non-editable so static assets are copied into the venv)
echo "Installing Superset from local source ..."
pip install "${SUPERSET_SOURCE_ROOT}"

# Install optional database driver extras
if [ -n "${SUPERSET_DB_EXTRAS}" ]; then
    echo "Installing optional DB extras: [${SUPERSET_DB_EXTRAS}] ..."
    pip install "${SUPERSET_SOURCE_ROOT}[${SUPERSET_DB_EXTRAS}]"
fi

# Install additional ODP-specific requirements if present {for future use}
ODP_REQUIREMENTS="${SCRIPT_DIR}/requirements.txt"
if [ -f "${ODP_REQUIREMENTS}" ]; then
    echo "Installing additional ODP requirements from ${ODP_REQUIREMENTS} ..."
    pip install -r "${ODP_REQUIREMENTS}"
fi

# ===================================================================
# Step 6: Build Backend Translations (.po -> .mo)
# ===================================================================
echo ""
echo "[Step 6/7] Compiling Backend Translations (.po -> .mo)"

pip install babel
if command -v flask &>/dev/null; then
    FLASK_APP="superset.app:create_app()" flask fab babel-compile --target "${SUPERSET_SOURCE_ROOT}/superset/translations" \
        || pybabel compile -d "${SUPERSET_SOURCE_ROOT}/superset/translations" \
        || echo "WARNING: Backend translation compile failed (non-fatal)"
else
    pybabel compile -d "${SUPERSET_SOURCE_ROOT}/superset/translations" \
        || echo "WARNING: Backend translation compile failed (non-fatal)"
fi

# ===================================================================
# Step 7: Generate BUILD_INFO & Pack Tarball
# ===================================================================
echo ""
echo "[Step 7/7] Generating BUILD_INFO & packing tarball"

# Generate version_info.json (same as setup.py does)
GIT_SHA=$(cd "${SUPERSET_SOURCE_ROOT}" && git rev-parse HEAD 2>/dev/null || echo "unknown")
cat > "${SUPERSET_SOURCE_ROOT}/superset/static/version_info.json" <<VEOF
{"GIT_SHA": "${GIT_SHA}", "version": "${SUPERSET_VERSION}"}
VEOF

# Generate BUILD_INFO manifest inside venv root
if [ -f /etc/os-release ]; then
    . /etc/os-release
    BUILD_OS="${ID}-${VERSION_ID}"
else
    BUILD_OS="unknown"
fi
PYTHON_FULL_VERSION=$(${PY} --version 2>&1 | awk '{print $2}')

BUILD_INFO_FILE="${VENV_DIR}/BUILD_INFO"
cat > "${BUILD_INFO_FILE}" <<BEOF
SUPERSET_VERSION=${SUPERSET_VERSION}
ODP_VERSION=${ODP_VERSION}
ODP_SUPERSET_VERSION=${ODP_SUPERSET_VERSION}
BUILD_TYPE=source
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
BUILD_OS=${BUILD_OS}
PYTHON_VERSION=${PYTHON_FULL_VERSION}
NODE_VERSION=$(node --version)
GIT_SHA=${GIT_SHA}
DB_EXTRAS=${SUPERSET_DB_EXTRAS}
BEOF

echo "BUILD_INFO:"
cat "${BUILD_INFO_FILE}"

# Verify Superset is importable
echo ""
echo "Verifying Superset installation ..."
INSTALLED_VERSION=$(pip show apache-superset 2>/dev/null | grep "^Version:" | cut -d' ' -f2 || echo "NOT_FOUND")
echo "Installed Superset version: ${INSTALLED_VERSION}"

if [ "${INSTALLED_VERSION}" = "NOT_FOUND" ]; then
    # Fallback: try the package name without underscore
    INSTALLED_VERSION=$(pip show apache_superset 2>/dev/null | grep "^Version:" | cut -d' ' -f2 || echo "NOT_FOUND")
    echo "Installed apache_superset version: ${INSTALLED_VERSION}"
fi

${PY} -c "import superset; print(f'Superset module loaded from: {superset.__file__}')"

# Verify frontend assets are accessible to the installed package
STATIC_ASSETS=$(${PY} -c "
import os, superset
base = os.path.dirname(superset.__file__)
assets = os.path.join(base, 'static', 'assets')
count = sum(len(f) for _, _, f in os.walk(assets)) if os.path.isdir(assets) else 0
print(f'{count} files in {assets}')
")
echo "Frontend assets: ${STATIC_ASSETS}"

# Pack the virtual environment using venv-pack
echo ""
echo "Packing virtual environment into tarball ..."
pip install venv-pack

venv-pack -o "${SCRIPT_DIR}/${TARBALL_NAME}"

deactivate

# ===================================================================
# Verify Tarball
# ===================================================================
echo ""
echo "Verifying tarball contents ..."

TARBALL_PATH="${SCRIPT_DIR}/${TARBALL_NAME}"
TARBALL_SIZE=$(du -h "${TARBALL_PATH}" | cut -f1)

# Save full file listing for diffing
FILELIST="${SCRIPT_DIR}/${TARBALL_NAME%.tar.gz}_filelist.txt"
tar tzf "${TARBALL_PATH}" | sort > "${FILELIST}"

# Count key file types
JS_COUNT=$(tar tzf "${TARBALL_PATH}" | grep -c 'static/assets/.*\.js$' || true)
CSS_COUNT=$(tar tzf "${TARBALL_PATH}" | grep -c 'static/assets/.*\.css$' || true)
PY_COUNT=$(tar tzf "${TARBALL_PATH}" | grep -c '\.py$' || true)
TOTAL_COUNT=$(wc -l < "${FILELIST}" | tr -d ' ')

echo ""
echo "============================================"
echo "BUILD SUCCESSFUL"
echo "============================================"
echo "Tarball         : ${TARBALL_PATH}"
echo "Size            : ${TARBALL_SIZE}"
echo "Total files     : ${TOTAL_COUNT}"
echo "  JS assets     : ${JS_COUNT}"
echo "  CSS assets    : ${CSS_COUNT}"
echo "  Python files  : ${PY_COUNT}"
echo ""
echo "Superset Version: ${SUPERSET_VERSION}"
echo "ODP Version     : ${ODP_VERSION}"
echo "Combined        : ${ODP_SUPERSET_VERSION}"
echo "Git SHA         : ${GIT_SHA}"
echo "DB Extras       : ${SUPERSET_DB_EXTRAS}"
echo ""
echo "File listing    : ${FILELIST}"
echo ""
echo "To deploy:"
echo "  mkdir -p /opt/superset && cd /opt/superset"
echo "  tar xzf ${TARBALL_NAME}"
echo "  source bin/activate"
echo "  superset db upgrade"
echo "  superset init"
echo "  gunicorn -w 4 -b 0.0.0.0:8088 'superset.app:create_app()'"
echo "============================================"
