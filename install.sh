#!/usr/bin/env bash
# One-line installer for ats-mini-controller (RTL-SDR station browser).
#
#   curl -fsSL https://raw.githubusercontent.com/jsawyerdev/ats-mini-controller/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --port 8731 --no-reboot
#
# Supported native path: Debian/Ubuntu/RPi OS (.deb asset). Anywhere else
# (or with --manual) it builds from a pinned git tag into /opt with systemd.
# In both cases udev rules + DVB modprobe blacklist are installed so
# librtlsdr can claim the dongle (needs one reboot on first install).
#
# Release assets are checksum-verified before privileged installation and
# every dependency/setup step is fatal: a failed install exits non-zero
# instead of reporting a misleading partial success.
set -euo pipefail

REPO="${REPO:-jsawyerdev/ats-mini-controller}"
PORT="${PORT:-8731}"
VERSION="${VERSION:-latest}"
NEED_REBOOT=1
MANUAL=0
# Escape hatch for pre-release testing only: install without published
# checksums. Never set this in normal use.
ALLOW_UNVERIFIED="${ATS_ALLOW_UNVERIFIED:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:-8731}"; shift 2 ;;
        --version) VERSION="${2:-latest}"; shift 2 ;;
        --no-reboot) NEED_REBOOT=0; shift ;;
        --manual) MANUAL=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  DEB_ARCH="amd64" ;;
    aarch64) DEB_ARCH="arm64" ;;
    armv7l|armv6l) DEB_ARCH="armhf" ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

release_tag() {
    if [ "$VERSION" != "latest" ]; then echo "$VERSION"; return; fi
    curl -fsSL -o /dev/null -w "%{url_effective}" \
        "https://github.com/${REPO}/releases/latest" | sed 's#.*/tag/##'
}

# Verify a downloaded release asset against published checksums before it is
# installed with privileges. Fails closed: no checksum material, no install.
verify_asset() { # $1 = file path, $2 = asset file name, $3 = release base URL
    local file="$1" name="$2" base="$3"
    if [ "$ALLOW_UNVERIFIED" = "1" ]; then
        echo "WARNING: installing $name WITHOUT checksum verification (ATS_ALLOW_UNVERIFIED=1)." >&2
        return 0
    fi
    local sumfile
    sumfile="$(mktemp)"
    if curl -fsSL -o "$sumfile" "$base/$name.sha256"; then
        (cd "$(dirname "$file")" && sha256sum -c "$sumfile")
    elif curl -fsSL -o "$sumfile" "$base/SHA256SUMS.txt"; then
        (cd "$(dirname "$file")" && grep -F " $name" "$sumfile" | sha256sum -c -)
    else
        echo "ERROR: no published checksum for $name under $base." >&2
        echo "Refusing to install an unverified privileged artifact." >&2
        echo "Wait for the release checksums, or re-run with --manual to build from the pinned git tag." >&2
        rm -f "$sumfile"
        return 1
    fi
    rm -f "$sumfile"
}

install_deb() { # $1 = TAG
    local tag="$1" base="https://github.com/${REPO}/releases/download/${tag}"
    local url="$base/ats-mini-controller_${tag#v}_${DEB_ARCH}.deb"
    echo "Installing ats-mini-controller ${tag} for ${ARCH} ..."
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    curl -fsSL -o "$TMP/pkg.deb" "$url"
    verify_asset "$TMP/pkg.deb" "ats-mini-controller_${tag#v}_${DEB_ARCH}.deb" "$base"
    # Fatal: any failure below aborts the install (set -e, no '|| true').
    $SUDO apt-get update
    $SUDO apt-get install -y "$TMP/pkg.deb" rtl-sdr libusb-1.0-0
    rm -rf "$TMP"; trap - EXIT
}

install_from_source() { # $1 = TAG; pinned-tag build, no unverified tarballs
    local tag="$1"
    echo "Building ats-mini-controller ${tag} from source (pinned tag) ..."
    if ! have apt-get; then
        echo "ERROR: source fallback needs apt-get for build dependencies." >&2
        echo "Install manually: python3-venv, git, rtl-sdr, libusb-1.0-0, then re-run." >&2
        exit 1
    fi
    # Fatal dependency install: abort on failure, never limp on.
    $SUDO apt-get update
    $SUDO apt-get install -y python3-venv git rtl-sdr libusb-1.0-0
    $SUDO mkdir -p /opt/ats-mini-controller /etc/ats-mini-controller
    $SUDO chown -R "$(id -u):$(id -g)" /opt/ats-mini-controller
    SRC="$(mktemp -d)"; trap 'rm -rf "$SRC"' EXIT
    # git transports the tag object hashes, pinning the checkout to the
    # immutable release tag instead of an anonymous tarball.
    git clone --depth 1 --branch "$tag" "https://github.com/${REPO}.git" "$SRC"
    local want="${tag#v}"
    local got
    got="$(grep -m1 -oP '^APP_VERSION = "\K[^"]+' "$SRC/app.py")"
    if [ "$got" != "$want" ]; then
        echo "ERROR: tag $tag checkout has app.py version $got, expected $want. Aborting." >&2
        exit 1
    fi
    python3 -m venv /opt/ats-mini-controller/venv
    /opt/ats-mini-controller/venv/bin/pip install --no-cache-dir -r "$SRC/requirements.txt"
    cp "$SRC"/app.py "$SRC"/radio_bridge.py "$SRC"/cw_decoder.py "$SRC"/cw_monitor.py \
       "$SRC"/audio_passthrough.py "$SRC"/stations_db.py /opt/ats-mini-controller/
    mkdir -p /opt/ats-mini-controller/static /opt/ats-mini-controller/data/recordings
    cp "$SRC/static/index.html" /opt/ats-mini-controller/static/
    cp "$SRC/data/stations.db" /opt/ats-mini-controller/data/ 2>/dev/null || {
        echo "ERROR: stations.db missing from $tag checkout." >&2; exit 1;
    }
    # Ship the PORT-aware launcher the systemd unit calls.
    $SUDO install -m755 /dev/stdin /usr/bin/ats-mini-controller <<'EOF'
#!/bin/sh
exec /opt/ats-mini-controller/venv/bin/python -m uvicorn app:app --app-dir /opt/ats-mini-controller --host "${HOST:-0.0.0.0}" --port "${PORT:-8731}"
EOF
    $SUDO cp "$SRC/packaging/ats-mini-controller.service" /lib/systemd/system/
    $SUDO cp "$SRC/packaging/66-rtl-sdr.rules" /lib/udev/rules.d/
    $SUDO cp "$SRC/packaging/blacklist-rtlsdr.conf" /etc/modprobe.d/blacklist-rtlsdr.conf
    $SUDO sh "$SRC/packaging/postinst"
    rm -rf "$SRC"; trap - EXIT
}

TAG="$(release_tag)"
if have apt-get && [ "$MANUAL" -eq 0 ]; then
    install_deb "$TAG"
else
    install_from_source "$TAG"
fi

# Persist the configured port on every install so the systemd unit
# (EnvironmentFile + /usr/bin/ats-mini-controller wrapper) always picks it up.
echo "PORT=$PORT" | $SUDO tee /etc/ats-mini-controller/env >/dev/null
if [ -d /run/systemd/system ]; then
    $SUDO systemctl daemon-reload
    $SUDO systemctl restart ats-mini-controller.service || {
        echo "WARNING: service restart failed (first install often needs a reboot for the DVB blacklist)." >&2
    }
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "Done. Open http://${IP:-<host>:}:${PORT} on your LAN."
if [ "$NEED_REBOOT" -eq 1 ]; then
    echo "First install usually needs one reboot to release the DVB kernel modules."
fi
