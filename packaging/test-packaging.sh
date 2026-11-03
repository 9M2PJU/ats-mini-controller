#!/usr/bin/env bash
# Isolated packaging smoke test for the single supported native path (.deb).
# No root, no network, no systemd required. Fails on any of the blocking
# review issues: ineffective --port, masked dependency failures, missing
# shebang, unverified privileged downloads, or out-of-scope packaging paths.
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 1. Effective configuration: service must honour PORT from EnvironmentFile.
if grep -q '^EnvironmentFile=-/etc/ats-mini-controller/env' packaging/ats-mini-controller.service \
    && grep -q '^ExecStart=/usr/bin/ats-mini-controller$' packaging/ats-mini-controller.service; then
    ok "service delegates to PORT-aware wrapper"
else
    bad "service must use 'ExecStart=/usr/bin/ats-mini-controller' with EnvironmentFile (else --port is ineffective)"
fi
if grep -q -- '--port 8731' packaging/ats-mini-controller.service; then
    bad "service hard-codes --port 8731"
else
    ok "service does not hard-code port"
fi

# 2. Fatal dependency/setup failures: installer must not mask them with || true.
if grep -n 'apt-get.*|| true' install.sh | grep -qv 'systemctl\|udevadm'; then
    bad "install.sh masks apt failures with '|| true'"
else
    ok "install.sh dependency installs are fatal"
fi
if grep -n 'dnf.*|| true\|pacman.*|| true\|zypper.*|| true' install.sh | grep -qv 'systemctl\|udevadm'; then
    bad "install.sh masks non-apt package-manager failures"
else
    ok "install.sh has no masked package-manager fallback chain"
fi

# 3. Deterministic direct execution: Bash scripts need a shebang (SC2148).
for f in packaging/build-packages.sh install.sh packaging/test-packaging.sh; do
    if head -n1 "$f" | grep -q '^#!/usr/bin/env bash'; then
        ok "$f has bash shebang"
    else
        bad "$f missing '#!/usr/bin/env bash' shebang"
    fi
    if bash -n "$f"; then
        ok "$f passes bash -n"
    else
        bad "$f fails bash -n"
    fi
done
if bash -n packaging/postinst && bash -n packaging/prerm; then
    ok "postinst/prerm pass sh syntax check"
else
    bad "postinst/prerm fail syntax check"
fi

# 4. Verified privileged downloads: installer must checksum release assets.
if grep -q 'sha256sum' install.sh; then
    ok "install.sh verifies checksums"
else
    bad "install.sh downloads privileged artifacts without checksum verification"
fi
if grep -q "SKIP" packaging/aur/ats-mini-controller/PKGBUILD 2>/dev/null; then
    bad "AUR stable template ships with sha256sums SKIP (no immutable checksums)"
else
    ok "no SKIP-checksum stable template ships"
fi

# 5a. Single supported path: out-of-scope builders/templates must be gone.
for gone in packaging/ats-mini-controller.spec packaging/build-appimage.sh \
            packaging/AppRun packaging/ats-mini-controller.desktop packaging/aur; do
    if [ -e "$gone" ]; then
        bad "out-of-scope path still ships: $gone (reduce to .deb first)"
    else
        ok "absent (single-path scope): $gone"
    fi
done
if grep -q 'build-packages.sh.*\.rpm\|t rpm\|zypper\|pacman\|yay\|paru\|AppImage\|aur' install.sh 2>/dev/null \
    || grep -v -i 'defer' README.md | grep -q 'dnf install\|yay -S\|paru -S\|makepkg\|AppImage\|;AppImage'; then
    bad "install.sh/README still advertise non-.deb paths"
else
    ok "install.sh/README advertise only the .deb path"
fi
if grep -q '\-t rpm\|rpmbuild\|\.spec' packaging/build-packages.sh; then
    bad "build-packages.sh still builds .rpm"
else
    ok "build-packages.sh builds .deb only"
fi

# 5b. Lifecycle behaviour: build staging tree and exercise wrapper PORT expansion.
STAGE="$(./packaging/build-packages.sh --stage-only 2>/dev/null | tail -n1)" || STAGE=""
if [ -n "$STAGE" ] && [ -f "$STAGE/usr/bin/ats-mini-controller" ]; then
    ok "build stages payload without fpm"
    # Stub the venv python to capture args, then run wrapper with custom PORT.
    FAKE_BIN="$(mktemp -d)"
    echo 'echo "$@"' > "$FAKE_BIN/python"
    chmod +x "$FAKE_BIN/python"
    WRAP_TMP="$(mktemp -d)"
    sed "s#/opt/ats-mini-controller/venv/bin/python#$FAKE_BIN/python#" \
        "$STAGE/usr/bin/ats-mini-controller" > "$WRAP_TMP/ats-mini-controller"
    chmod +x "$WRAP_TMP/ats-mini-controller"
    ARGS="$(PORT=9999 HOST=127.0.0.1 "$WRAP_TMP/ats-mini-controller")"
    case "$ARGS" in
        *"--port 9999"*|*"--port=9999"*) ok "wrapper honours PORT=9999 (-> $ARGS)" ;;
        *) bad "wrapper ignores PORT (got: $ARGS)" ;;
    esac
    rm -rf "$FAKE_BIN" "$WRAP_TMP"
else
    bad "build-packages.sh --stage-only did not stage a payload"
fi

# 5c. Unconditional env persistence: custom --port must survive default installs.
if grep -q '!= "8731"' install.sh; then
    bad "install.sh only persists PORT when non-default"
else
    ok "install.sh persists PORT unconditionally"
fi

echo "---"
echo "packaging smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
