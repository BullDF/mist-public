#!/bin/bash
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
container_name="mist-mail-tests-$$"
cleanup() { docker rm -f "${container_name:?}" >/dev/null 2>&1 || true; }
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    docker run --rm -d --name "$container_name" \
        -p 127.0.0.1::3143 -p 127.0.0.1::3025 \
        -e 'GREENMAIL_OPTS=-Dgreenmail.setup.test.smtp -Dgreenmail.setup.test.imap -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=mail:secret@example.test' \
        greenmail/standalone:2.1.3 >/dev/null
    MIST_MAIL_IMAP_PORT=$(docker port "$container_name" 3143/tcp | awk -F: '{print $NF}')
    MIST_MAIL_SMTP_PORT=$(docker port "$container_name" 3025/tcp | awk -F: '{print $NF}')
    export MIST_MAIL_IMAP_PORT MIST_MAIL_SMTP_PORT
    ready=0
    for ((attempt=0; attempt<60; attempt++)); do
        if nc -z 127.0.0.1 "$MIST_MAIL_IMAP_PORT" >/dev/null 2>&1 && nc -z 127.0.0.1 "$MIST_MAIL_SMTP_PORT" >/dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    if [ "$ready" != 1 ]; then echo 'GreenMail did not start within 60 seconds' >&2; exit 1; fi
    echo "Running mail integration tests against GreenMail 2.1.3 on loopback."
else
    echo 'Docker daemon unavailable: GreenMail integration tests will skip.'
    unset MIST_MAIL_IMAP_PORT MIST_MAIL_SMTP_PORT
fi
swift test --package-path PackageCollection "$@"
