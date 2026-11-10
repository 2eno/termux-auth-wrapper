#!/usr/bin/env bash
# TERMUX_AUTH_WRAPPER_MARKER
# shellcheck disable=SC2153  # TAW_* values come from taw_load_config
# =============================================================================
# check_biometric.sh – central fingerprint check via Termux:API
#
# Usage as a program:
#     check_biometric [-d DESCRIPTION] [-t TITLE] [-q]
#     exit code 0 = fingerprint confirmed, 1 = failure/not available
#
# Usage as a library (source):
#     taw_biometric_check "description"   -> return 0/1
#     sets afterwards: TAW_BIO_STATUS  (success | rejected | locked | unavailable)
#                      TAW_BIO_REASON  (human-readable reason)
#
# Evaluates the JSON printed by termux-fingerprint, e.g.:
#     {"errors":[],"failed_attempts":0,"auth_result":"AUTH_RESULT_SUCCESS"}
# =============================================================================

# readlink -f: also works when the script is called through a symlink
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"

TAW_BIO_STATUS=""
TAW_BIO_REASON=""

_taw_bio_set() {
    TAW_BIO_STATUS=$1
    TAW_BIO_REASON=$2
}

# A single dialog call. Sets TAW_BIO_STATUS/REASON.
_taw_bio_attempt() {
    local fp=$1 desc=$2 out errfile rc=0
    local -a cmd=()

    if command -v timeout >/dev/null 2>&1; then
        cmd=(timeout "$TAW_BIO_TIMEOUT")
    else
        taw_debug "'timeout' not available – the dialog runs without a time limit"
    fi
    cmd+=("$fp")
    # Title/description can be turned off in case a termux-api version
    # doesn't know these options
    if taw_is_true "${TAW_BIO_DIALOG_TEXT:-true}"; then
        cmd+=(-t "${TAW_BIO_TITLE:-Termux authentication}" -d "$desc")
    fi

    taw_ensure_dir "$TAW_RUNTIME_DIR" 700
    errfile=$(mktemp "$TAW_RUNTIME_DIR/fp-err.XXXXXX")
    # stdin from /dev/null: the check must never "steal" data from a pipe
    # (e.g. with: echo foo | sudo tee /file)
    out=$("${cmd[@]}" </dev/null 2>"$errfile") || rc=$?
    local errtext
    errtext=$(head -c 300 "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    taw_debug "termux-fingerprint rc=$rc out=${out//$'\n'/ } err=${errtext//$'\n'/ }"

    if (( rc == 124 )); then
        _taw_bio_set unavailable "No answer from Termux:API within ${TAW_BIO_TIMEOUT}s. Either the dialog was not confirmed, or the 'Termux:API' app is not responding or has crashed (source/signature, battery restriction, never opened). Narrow down the cause with: termux-auth diag"
        return 1
    fi
    if (( rc == 126 || rc == 127 )); then
        _taw_bio_set unavailable "termux-fingerprint could not be executed (rc=$rc)."
        return 1
    fi
    if [[ -z ${out//[[:space:]]/} ]]; then
        _taw_bio_set unavailable "termux-fingerprint printed nothing (rc=$rc)${errtext:+: $errtext}. Is the 'Termux:API' app installed and from the same source as Termux (F-Droid/GitHub)?"
        return 1
    fi
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
        _taw_bio_set unavailable "Unexpected output from termux-fingerprint (not JSON): ${out:0:120}"
        return 1
    fi

    local result errors failed
    result=$(jq -r '.auth_result // "AUTH_RESULT_UNKNOWN"' <<<"$out")
    errors=$(jq -r '(.errors // []) | map(tostring) | join(",")' <<<"$out")
    failed=$(jq -r '.failed_attempts // 0' <<<"$out")

    case ",$errors," in
        *,ERROR_NO_HARDWARE,*)
            _taw_bio_set unavailable "This device has no fingerprint sensor (ERROR_NO_HARDWARE)."
            return 1 ;;
        *,ERROR_NO_ENROLLED_FINGERPRINTS,*)
            _taw_bio_set unavailable "No fingerprint enrolled – add one in the Android settings under 'Security' (ERROR_NO_ENROLLED_FINGERPRINTS)."
            return 1 ;;
        *,ERROR_UNSUPPORTED_OS_VERSION,*)
            _taw_bio_set unavailable "This Android version is not supported by termux-fingerprint (ERROR_UNSUPPORTED_OS_VERSION)."
            return 1 ;;
        *,ERROR_LOCKOUT,*|*,ERROR_TOO_MANY_FAILED_ATTEMPTS,*)
            _taw_bio_set locked "Sensor locked after too many failed attempts – try again later or unlock the device with your PIN."
            return 1 ;;
    esac

    if [[ $result == AUTH_RESULT_SUCCESS ]]; then
        _taw_bio_set success "Fingerprint confirmed."
        return 0
    fi

    local why="Fingerprint not recognized or dialog cancelled"
    [[ $failed != 0 ]] && why+=" ($failed failed attempt(s))"
    [[ -n $errors ]] && why+=" [$errors]"
    _taw_bio_set rejected "$why."
    return 1
}

# taw_biometric_check [description]
taw_biometric_check() {
    local desc=${1:-"Please confirm your identity"} fp attempt

    if ! fp=$(command -v termux-fingerprint 2>/dev/null); then
        _taw_bio_set unavailable "termux-fingerprint not found. Install it with 'pkg install termux-api' plus the 'Termux:API' app (F-Droid/GitHub)."
        taw_err "$TAW_BIO_REASON"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _taw_bio_set unavailable "jq not found. Install it with 'pkg install jq'."
        taw_err "$TAW_BIO_REASON"
        return 1
    fi

    for (( attempt = 1; attempt <= TAW_BIO_MAX_ATTEMPTS; attempt++ )); do
        if _taw_bio_attempt "$fp" "$desc"; then
            taw_debug "$TAW_BIO_REASON"
            return 0
        fi
        # Only ask again on "rejected" – lockout/unavailability is final
        if [[ $TAW_BIO_STATUS == rejected ]] && (( attempt < TAW_BIO_MAX_ATTEMPTS )); then
            taw_warn "$TAW_BIO_REASON Trying again ($((attempt + 1))/$TAW_BIO_MAX_ATTEMPTS) …"
            continue
        fi
        break
    done
    taw_err "$TAW_BIO_REASON"
    return 1
}

# --- Direct invocation -------------------------------------------------------
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    TAW_COMPONENT="check_biometric"

    _usage() {
        cat <<EOF
Usage: check_biometric [-d DESCRIPTION] [-t TITLE] [-q] [-h]

Shows the Android fingerprint dialog (termux-fingerprint).
Exit code 0 on success, 1 on failure or if no biometrics are available.

  -d TEXT   description in the dialog
  -t TEXT   title of the dialog
  -q        no output (exit code only)
  -h        this help

Example in your own scripts:
  if check_biometric -d "Delete the backup?"; then rm -rf ~/backup; fi
EOF
    }

    _desc="Please confirm your identity"
    _title=""
    while getopts ":d:t:qh" _opt; do
        case $_opt in
            d) _desc=$OPTARG ;;
            t) _title=$OPTARG ;;
            q) TAW_QUIET=true ;;
            h) _usage; exit 0 ;;
            :) taw_err "Option -$OPTARG requires an argument"; _usage >&2; exit 1 ;;
            *) taw_err "Unknown option: -$OPTARG"; _usage >&2; exit 1 ;;
        esac
    done

    taw_load_config
    [[ -n $_title ]] && TAW_BIO_TITLE=$_title

    if [[ ${TAW_QUIET:-false} == true ]]; then
        taw_biometric_check "$_desc" 2>/dev/null && exit 0
        exit 1
    fi
    if taw_biometric_check "$_desc"; then
        taw_ok "$TAW_BIO_REASON"
        exit 0
    fi
    exit 1
fi
