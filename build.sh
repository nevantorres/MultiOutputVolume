#!/bin/bash
# Builds MultiOutputVolume.app from the Swift sources in ./Sources.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MultiOutputVolume"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

# --- Stable self-signed code-signing identity -------------------------------
# Signing every build with the *same* certificate gives the app a stable
# Designated Requirement, so the Accessibility grant that the volume keys need
# survives rebuilds — unlike ad-hoc signing, whose signature (and thus the
# permission) changes on every build. The identity lives in a dedicated
# keychain with a known password so codesign can use it without any GUI prompt
# or your login password.
SIGN_CN="MultiOutputVolume Local Signing"
CERT_DIR="${HOME}/.local/share/multioutputvolume-signing"
SIGN_KEYCHAIN="${HOME}/Library/Keychains/multioutputvolume-signing.keychain-db"
KC_PASS="multioutputvolume"   # protects only this local signing keychain
P12_PASS="multioutputvolume"

ensure_signing_identity() {
    # Already usable? (search-list lookup accepts the untrusted self-signed cert)
    if security find-identity -p codesigning 2>/dev/null | grep -q "${SIGN_CN}"; then
        return 0
    fi

    echo "› Creating a stable self-signed signing identity (first build only)…"
    mkdir -p "${CERT_DIR}"
    chmod 700 "${CERT_DIR}"
    local cert="${CERT_DIR}/cert.pem"
    local key="${CERT_DIR}/key.pem"
    local p12="${CERT_DIR}/identity.p12"
    local cnf="${CERT_DIR}/cert.cnf"

    # Generate the cert once and keep it forever — reusing it is what keeps the
    # Designated Requirement (and the permission grant) stable across rebuilds.
    if [ ! -f "${cert}" ] || [ ! -f "${key}" ]; then
        cat > "${cnf}" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${SIGN_CN}
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
        openssl req -x509 -newkey rsa:2048 -keyout "${key}" -out "${cert}" \
            -days 3650 -nodes -config "${cnf}" >/dev/null 2>&1
    fi

    # macOS's importer can't verify OpenSSL 3's default PKCS#12 MAC, so export
    # with the legacy SHA1/3DES algorithms and a non-empty password.
    openssl pkcs12 -export -legacy \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -inkey "${key}" -in "${cert}" -name "${SIGN_CN}" \
        -out "${p12}" -passout "pass:${P12_PASS}" >/dev/null 2>&1

    # Create the dedicated keychain if it doesn't exist yet.
    if ! security list-keychains -d user | grep -q "multioutputvolume-signing"; then
        security create-keychain -p "${KC_PASS}" "${SIGN_KEYCHAIN}" 2>/dev/null || true
    fi
    security set-keychain-settings "${SIGN_KEYCHAIN}"          # no auto-lock timeout
    security unlock-keychain -p "${KC_PASS}" "${SIGN_KEYCHAIN}"

    # -T grants codesign access; set-key-partition-list makes that access silent.
    security import "${p12}" -k "${SIGN_KEYCHAIN}" -P "${P12_PASS}" \
        -T /usr/bin/codesign >/dev/null 2>&1 || true
    security set-key-partition-list -S apple-tool:,apple: -s \
        -k "${KC_PASS}" "${SIGN_KEYCHAIN}" >/dev/null 2>&1 || true

    # Add the keychain to the user search list so codesign finds the identity
    # (append; preserve the existing keychains).
    if ! security list-keychains -d user | grep -q "multioutputvolume-signing"; then
        local existing
        existing=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
        security list-keychains -d user -s "${SIGN_KEYCHAIN}" ${existing}
    fi

    echo "  Created identity “${SIGN_CN}”. Grant Accessibility once more for this"
    echo "  signature; it then persists across future rebuilds."
}

echo "› Cleaning…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

echo "› Compiling…"
swiftc -O \
    -framework Cocoa \
    -framework CoreAudio \
    -framework AudioToolbox \
    -o "${MACOS_DIR}/${APP_NAME}" \
    Sources/*.swift

echo "› Assembling bundle…"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

echo "› Code signing…"
ensure_signing_identity
if security find-identity -p codesigning 2>/dev/null | grep -q "${SIGN_CN}"; then
    # Make sure the signing keychain is unlocked (it locks across reboots).
    security unlock-keychain -p "${KC_PASS}" "${SIGN_KEYCHAIN}" 2>/dev/null || true
    codesign --force --sign "${SIGN_CN}" "${APP_DIR}"
else
    # Couldn't create/find the stable identity — ad-hoc sign so the app still
    # runs (the Accessibility grant just won't survive the next rebuild).
    echo "  (stable identity unavailable — falling back to ad-hoc signing)"
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo "✓ Built ${APP_DIR}"
echo "  Run with:  open \"${APP_DIR}\""
