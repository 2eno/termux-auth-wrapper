# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # TAW_* values come from taw_load_config
# =============================================================================
# termux-auth-wrapper – Bitwarden CLI integration (optional)
#
#   taw_bw_ensure_unlocked            -> 0 if BW_SESSION is valid
#   taw_bw_get_secret <item> <type>   -> sets TAW_BW_SECRET / TAW_BW_SECRET_TYPE
#                                        (type: password | key | auto)
#
# Secrets are only ever kept in variables and are never logged.
# =============================================================================

[[ -n "${_TAW_BW_LOADED:-}" ]] && return 0
_TAW_BW_LOADED=1

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

TAW_BW_SECRET=""
TAW_BW_SECRET_TYPE=""
_TAW_BW_SESSION_FILE="$TAW_STATE_DIR/bw-session"

# Run bw with a time limit and without interactive prompts
_taw_bw() {
    local -a cmd=(bw)
    if command -v timeout >/dev/null 2>&1; then
        cmd=(timeout "$TAW_BW_TIMEOUT" bw)
    fi
    "${cmd[@]}" "$@" --nointeraction </dev/null
}

taw_bw_require() {
    if ! command -v bw >/dev/null 2>&1; then
        taw_err "Bitwarden CLI 'bw' not found."
        taw_hint "Install: pkg install nodejs && npm install -g @bitwarden/cli"
        taw_hint "Then sign in once: bw login"
        return 1
    fi
    command -v jq >/dev/null 2>&1 || { taw_err "jq is missing: pkg install jq"; return 1; }
}

# Prints locked | unlocked | unauthenticated | error
taw_bw_status() {
    local out
    out=$(_taw_bw status 2>/dev/null) || { printf 'error'; return 0; }
    jq -r '.status // "error"' <<<"$out" 2>/dev/null || printf 'error'
}

_taw_bw_load_cached_session() {
    [[ -n ${BW_SESSION:-} ]] && return 0
    taw_is_true "$TAW_BW_SESSION_CACHE" || return 1
    [[ -f $_TAW_BW_SESSION_FILE && ! -L $_TAW_BW_SESSION_FILE ]] || return 1
    local s
    s=$(<"$_TAW_BW_SESSION_FILE")
    [[ -n $s ]] || return 1
    export BW_SESSION=$s
    taw_debug "BW_SESSION loaded from cache"
}

_taw_bw_store_session() {
    taw_is_true "$TAW_BW_SESSION_CACHE" || return 0
    taw_ensure_dir "$TAW_STATE_DIR" 700
    (umask 077; printf '%s' "$BW_SESSION" >"$_TAW_BW_SESSION_FILE") || \
        taw_warn "Could not cache the BW session."
}

taw_bw_forget_session() {
    rm -f "$_TAW_BW_SESSION_FILE" 2>/dev/null || true
}

_taw_bw_unlock_interactive() {
    local pw session rc=0
    if ! taw_have_tty; then
        taw_err "The Bitwarden vault is locked and no terminal is available to enter the password."
        return 1
    fi
    printf '[%s] Bitwarden master password: ' "$TAW_COMPONENT" >/dev/tty
    IFS= read -r -s pw </dev/tty || pw=""
    printf '\n' >/dev/tty
    [[ -n $pw ]] || { taw_err "No master password entered."; return 1; }
    # Pass it via an environment variable (--passwordenv) instead of an
    # argument so the password doesn't show up in the process list.
    session=$(TAW_BW_MASTER_PW=$pw _taw_bw unlock --raw --passwordenv TAW_BW_MASTER_PW 2>/dev/null) || rc=$?
    pw=""
    if (( rc != 0 )) || [[ -z $session ]]; then
        if (( rc == 124 )); then
            taw_err "Timed out unlocking Bitwarden (${TAW_BW_TIMEOUT}s)."
        else
            taw_err "Unlocking Bitwarden failed (wrong master password?)."
        fi
        return 1
    fi
    export BW_SESSION=$session
    _taw_bw_store_session
    taw_ok "Bitwarden unlocked."
}

taw_bw_ensure_unlocked() {
    taw_bw_require || return 1
    _taw_bw_load_cached_session || true

    local status
    status=$(taw_bw_status)
    taw_debug "Bitwarden status: $status"
    case $status in
        unlocked)
            return 0 ;;
        unauthenticated)
            taw_err "Not signed in to Bitwarden."
            taw_hint "Run once: bw login"
            return 1 ;;
        locked)
            # Discard a cached session that may have expired
            taw_bw_forget_session
            unset BW_SESSION
            if [[ $TAW_BW_UNLOCK_MODE == prompt ]]; then
                _taw_bw_unlock_interactive
                return
            fi
            taw_err "The Bitwarden vault is locked."
            taw_hint "Unlock with: export BW_SESSION=\"\$(bw unlock --raw)\""
            taw_hint "or set BW_UNLOCK_MODE=prompt in the config."
            return 1 ;;
        *)
            taw_err "Could not determine the Bitwarden status (timeout/network/installation?)."
            taw_hint "Check manually with: bw status"
            return 1 ;;
    esac
}

# taw_bw_get_secret <item-id-or-name> <password|key|auto>
taw_bw_get_secret() {
    local ref=$1 want=${2:-auto} item err rc=0
    TAW_BW_SECRET=""
    TAW_BW_SECRET_TYPE=""

    taw_bw_ensure_unlocked || return 1

    if taw_is_true "$TAW_BW_SYNC"; then
        _taw_bw sync >/dev/null 2>&1 || taw_warn "bw sync failed – using the local state."
    fi

    taw_ensure_dir "$TAW_RUNTIME_DIR" 700
    local errfile
    errfile=$(mktemp "$TAW_RUNTIME_DIR/bw-err.XXXXXX")
    item=$(_taw_bw get item "$ref" 2>"$errfile") || rc=$?
    err=$(head -c 300 "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    if (( rc != 0 )) || [[ -z $item ]]; then
        taw_err "Could not read Bitwarden item '$ref'${err:+: ${err//$'\n'/ }}"
        [[ $err == *"More than one"* ]] && taw_hint "Use the unique item ID instead of the name (bw list items --search \"$ref\")."
        return 1
    fi

    local pw key
    pw=$(jq -r '.login.password // empty' <<<"$item")
    # SSH key: native Bitwarden SSH key type, custom field or note
    key=$(jq -r '
        .sshKey.privateKey
        // ((.fields // []) | map(select(.name == "ssh_private_key" or .name == "private_key")) | .[0].value)
        // (if ((.notes // "") | test("-----BEGIN [A-Z ]*PRIVATE KEY-----")) then .notes else empty end)
        // empty' <<<"$item")
    item=""

    case $want in
        password)
            [[ -n $pw ]] || { taw_err "Item '$ref' contains no password."; return 1; }
            TAW_BW_SECRET=$pw; TAW_BW_SECRET_TYPE=password ;;
        key)
            [[ -n $key ]] || { taw_err "Item '$ref' contains no private SSH key."; return 1; }
            TAW_BW_SECRET=$key; TAW_BW_SECRET_TYPE=key ;;
        auto)
            if [[ -n $key ]]; then
                TAW_BW_SECRET=$key; TAW_BW_SECRET_TYPE=key
            elif [[ -n $pw ]]; then
                TAW_BW_SECRET=$pw; TAW_BW_SECRET_TYPE=password
            else
                taw_err "Item '$ref' contains neither a password nor an SSH key."
                return 1
            fi ;;
        *)
            taw_err "Unknown secret type '$want' (allowed: password, key, auto)."
            return 1 ;;
    esac
    pw=""; key=""
    taw_debug "Loaded Bitwarden secret of type '$TAW_BW_SECRET_TYPE'"
    return 0
}
