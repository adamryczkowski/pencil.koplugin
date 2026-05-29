default:
    @just --list

setup:
    luarocks --local install busted
    luarocks --local install luacov
    luarocks --local install luacov-reporter-lcov

validate:
    eval "$(luarocks --local path)" && busted

KOBO_MOUNT := env_var_or_default("KOBO_MOUNT", "/media/" + env_var("USER") + "/KOBOeReader")
KOBO_SSH_PORT := env_var_or_default("KOBO_SSH_PORT", "2222")

deploy-usb:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{KOBO_MOUNT}}/.adds/koreader" ]; then
        echo "Kobo not found at {{KOBO_MOUNT}}/.adds/koreader" >&2
        echo "Override the mount with: KOBO_MOUNT=/path/to/mount just deploy-usb" >&2
        exit 1
    fi
    rsync -rltD --no-perms --no-owner --no-group --delete pencil.koplugin/ "{{KOBO_MOUNT}}/.adds/koreader/plugins/pencil.koplugin/"
    cp input.lua "{{KOBO_MOUNT}}/.adds/koreader/frontend/device/input.lua"
    sync
    echo "Deployed. Unmount the device and restart KOReader."

deploy-ssh ADDRESS:
    #!/usr/bin/env bash
    set -euo pipefail
    REMOTE_ROOT="/mnt/onboard/.adds/koreader"
    SSH_CMD="ssh -p {{KOBO_SSH_PORT}} -o ConnectTimeout=10"
    TARGET="{{ADDRESS}}"
    [[ "$TARGET" == *@* ]] || TARGET="root@$TARGET"
    RSYNC_OPTS="-rltD --no-perms --no-owner --no-group --progress"
    rsync $RSYNC_OPTS --delete -e "$SSH_CMD" pencil.koplugin/ "${TARGET}:${REMOTE_ROOT}/plugins/pencil.koplugin/"
    rsync $RSYNC_OPTS -e "$SSH_CMD" input.lua "${TARGET}:${REMOTE_ROOT}/frontend/device/input.lua"
    echo "Deployed. Restart KOReader on the device."
