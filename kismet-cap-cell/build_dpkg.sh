#!/usr/bin/env bash
# Build a Debian package containing the full kismet-cap-cell project snapshot.
#
# Output:
#   ./dist/cellulardatasource_<version>_<arch>.deb
#
# Install:
#   sudo dpkg -i ./dist/cellulardatasource_<version>_<arch>.deb
#
# Notes:
# - Installs project files to /opt/cellulardatasource/kismet-cap-cell
# - Adds wrappers:
#   - /usr/bin/cellular-datasource-one
#   - /usr/bin/cellular-datasource-pi-setup
# - Does not auto-run installers or auto-enable services

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_NAME="cellulardatasource"
PKG_MAINTAINER="${PKG_MAINTAINER:-Alsatian Consulting}"
PKG_EMAIL="${PKG_EMAIL:-support@alsatianconsulting.com}"
PKG_VERSION="${PKG_VERSION:-0.1.0}"
PKG_ARCH="${PKG_ARCH:-$(dpkg --print-architecture)}"
PKG_SECTION="${PKG_SECTION:-utils}"
PKG_PRIORITY="${PKG_PRIORITY:-optional}"
PKG_DESC="${PKG_DESC:-Cellular datasource project bundle for Kismet (scripts, plugin sources, Android app sources).}"

DIST_DIR="${ROOT_DIR}/dist"
STAGE_DIR="$(mktemp -d)"
PKG_ROOT="${STAGE_DIR}/root"
DEBIAN_DIR="${PKG_ROOT}/DEBIAN"
INSTALL_BASE="/opt/cellulardatasource/kismet-cap-cell"
TARGET_TREE="${PKG_ROOT}${INSTALL_BASE}"

cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

mkdir -p "${DIST_DIR}" "${DEBIAN_DIR}" "${TARGET_TREE}" "${PKG_ROOT}/usr/bin"

# Copy full project tree, excluding local build/cache/git artifacts.
rsync -a --delete \
  --exclude '.git/' \
  --exclude '.idea/' \
  --exclude '.gradle/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '**/build/' \
  --exclude '**/.gradle/' \
  --exclude 'dist/' \
  --exclude 'pkgroot/' \
  --exclude 'tmp/' \
  --exclude '*.deb' \
  "${ROOT_DIR}/" "${TARGET_TREE}/"

cat > "${DEBIAN_DIR}/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: ${PKG_SECTION}
Priority: ${PKG_PRIORITY}
Architecture: ${PKG_ARCH}
Maintainer: ${PKG_MAINTAINER} <${PKG_EMAIL}>
Depends: bash, coreutils, rsync
Description: ${PKG_DESC}
 This package installs the kismet-cap-cell project files under:
  ${INSTALL_BASE}
 .
 It does not auto-run install.sh/one_shot_install.sh; run them manually
 after package installation.
EOF

cat > "${DEBIAN_DIR}/postinst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/cellulardatasource/kismet-cap-cell"
if [[ -d "${BASE}" ]]; then
  chmod +x \
    "${BASE}/one" \
    "${BASE}/one_shot_install.sh" \
    "${BASE}/install.sh" \
    "${BASE}/pi_one_command_setup.sh" \
    "${BASE}/undo_install.sh" \
    "${BASE}/uninstall.sh" \
    "${BASE}/multi_phone.sh" \
    "${BASE}/cell_autoconfig.sh" \
    "${BASE}/build_dpkg.sh" || true
fi

echo "[cellulardatasource] Installed at ${BASE}"
echo "[cellulardatasource] Next steps:"
echo "  cd ${BASE}"
echo "  sudo ./one               # interactive primary installer"
echo "  sudo ./pi_one_command_setup.sh   # opinionated Pi setup profile"
EOF
chmod 0755 "${DEBIAN_DIR}/postinst"

cat > "${DEBIAN_DIR}/prerm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod 0755 "${DEBIAN_DIR}/prerm"

cat > "${PKG_ROOT}/usr/bin/cellular-datasource-one" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /opt/cellulardatasource/kismet-cap-cell/one "$@"
EOF
chmod 0755 "${PKG_ROOT}/usr/bin/cellular-datasource-one"

cat > "${PKG_ROOT}/usr/bin/cellular-datasource-pi-setup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /opt/cellulardatasource/kismet-cap-cell/pi_one_command_setup.sh "$@"
EOF
chmod 0755 "${PKG_ROOT}/usr/bin/cellular-datasource-pi-setup"

OUT_DEB="${DIST_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"
dpkg-deb --build "${PKG_ROOT}" "${OUT_DEB}" >/dev/null

echo "Built: ${OUT_DEB}"
dpkg-deb --info "${OUT_DEB}" | sed -n '1,40p'
