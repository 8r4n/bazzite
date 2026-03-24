#!/usr/bin/bash
function sudoif(){
    if [[ $(command -v sudo) ]] && /usr/bin/sudo -n true >/dev/null 2>&1; then
        /usr/bin/sudo "$@" \
        || exit 1
    elif [[ "${TERM_PROGRAM}" == "vscode" && \
          ! -f /run/.containerenv && \
          ! -f /.dockerenv ]]; then
        [[ $(command -v systemd-run) ]] && \
        /usr/bin/systemd-run --uid=0 --gid=0 -d -E TERM="$TERM" -t -q -P -G "$@" \
        || exit 1
    else
        [[ $(command -v sudo) ]] && \
        /usr/bin/sudo "$@" \
        || exit 1
    fi
}
