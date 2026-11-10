#!/usr/bin/env bash
# =============================================================================
# Test suite for termux-auth-wrapper (runs on any Linux with bash + jq)
#
# Simulates a Termux prefix in a temporary directory and replaces
# termux-fingerprint, su (KernelSU), ssh, sshpass, bw and dpkg with mocks.
#
#   tests/run_tests.sh            all tests
#   tests/run_tests.sh -v         also print the output of failed commands
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE=false
[[ ${1:-} == -v ]] && VERBOSE=true

PASS=0
FAIL=0
FAILED_NAMES=()

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '      %s\n' "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# assert_eq <name> <expected> <actual>
assert_eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected: $(printf '%q' "$2")  actual: $(printf '%q' "$3")"; fi; }
assert_contains() { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "expected substring: $2 | output: ${3:0:400}"; fi; }
assert_not_contains() { if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected substring: $2"; fi; }
assert_file() { if [[ -e $2 ]]; then ok "$1"; else bad "$1" "file missing: $2"; fi; }
assert_no_file() { if [[ ! -e $2 ]]; then ok "$1"; else bad "$1" "file should not exist: $2"; fi; }

# --- Test environment --------------------------------------------------------
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/taw-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

new_env() {
    # $1 = name; creates a fresh fake Termux and exports variables
    local base="$ROOT/$1"
    export PREFIX="$base/usr"
    export HOME="$base/home"
    export TMPDIR="$PREFIX/tmp"
    export MOCK_LOG="$base/mock.log"
    export FP_CALLS="$base/fp_calls"
    mkdir -p "$PREFIX/bin" "$PREFIX/tmp" "$PREFIX/etc/apt/apt.conf.d" "$HOME" "$base/system"
    : >"$MOCK_LOG"; : >"$FP_CALLS"
    export PATH="$PREFIX/bin:/usr/bin:/bin"
    unset BW_SESSION SSH_AUTH_SOCK
    for v in $(compgen -v TAW_); do unset "$v"; done
    export TAW_COLOR=never
    export TAW_ALLOW_ROOT=1   # test containers often run as root

    # tools needed by the root side (PATH=$PREFIX/bin:/system/bin)
    local t
    for t in bash sh cat id mkdir env sleep printf echo true false touch; do
        p=$(type -P "$t" 2>/dev/null) && ln -sf "$p" "$PREFIX/bin/$t"
    done
    write_mocks "$base"
}

write_mocks() {
    local base=$1

    # termux-fingerprint: behavior via MOCK_FP
    cat >"$PREFIX/bin/termux-fingerprint" <<'EOF'
#!/usr/bin/env bash
echo "call $*" >>"$FP_CALLS"
[[ -n ${MOCK_FP_DELAY:-} ]] && sleep "$MOCK_FP_DELAY"
case ${MOCK_FP:-success} in
  success) echo '{"errors":[],"failed_attempts":0,"auth_result":"AUTH_RESULT_SUCCESS"}' ;;
  fail)    echo '{"errors":[],"failed_attempts":3,"auth_result":"AUTH_RESULT_FAILURE"}' ;;
  nohw)    echo '{"errors":["ERROR_NO_HARDWARE"],"failed_attempts":0,"auth_result":"AUTH_RESULT_UNKNOWN"}' ;;
  noenroll) echo '{"errors":["ERROR_NO_ENROLLED_FINGERPRINTS"],"failed_attempts":0,"auth_result":"AUTH_RESULT_UNKNOWN"}' ;;
  lockout) echo '{"errors":["ERROR_LOCKOUT"],"failed_attempts":5,"auth_result":"AUTH_RESULT_FAILURE"}' ;;
  garbage) echo 'Termux:API is not yet available' ;;
  empty)   ;;
  hang)    sleep 30 ;;
esac
EOF

    # su (KernelSU): su [-p] [-M] [user] -c CMD  -> runs CMD with sh
    cat >"$base/system/su" <<'EOF'
#!/usr/bin/env bash
args=()
while (($#)); do
  case $1 in
    -c) cmd=$2; shift 2; continue ;;
    *) args+=("$1") ;;
  esac
  shift
done
echo "su ${args[*]:-} -c $cmd" >>"$MOCK_LOG"
exec /bin/sh -c "$cmd"
EOF

    # "real" ssh (without marker): -G resolves aliases, otherwise prints the arguments
    cat >"$PREFIX/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# fake openssh binary
for a in "$@"; do [[ $a == -G ]] && G=1; done
if [[ -n ${G:-} ]]; then
  dest=""; user=${USER:-me}; skip=0
  for a in "$@"; do
    if ((skip)); then skip=0; continue; fi
    case $a in -G) ;; -l|-p|-o|-i|-J) skip=1 ;; -*) ;; *) dest=$a; break ;; esac
  done
  [[ $dest == *@* ]] && { user=${dest%%@*}; dest=${dest#*@}; }
  [[ $dest == myalias ]] && dest=10.0.0.5
  printf 'user %s\nhostname %s\nport 22\n' "$user" "$dest"
  exit 0
fi
echo "REAL_SSH $*" | tee -a "$MOCK_LOG"
prev=""
for a in "$@"; do
  if [[ $prev == -i ]]; then echo "KEYFILE=$a"; echo "KEYLINE=$(head -n1 "$a")"; fi
  prev=$a
done
exit "${MOCK_SSH_RC:-0}"
EOF

    cat >"$PREFIX/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -d ]] || { echo "sshpass mock: expected -d" >&2; exit 99; }
fd=$2; shift 2
IFS= read -r pw <&"$fd"
echo "SSHPASS_PW=$pw"
exec "$@"
EOF

    cat >"$PREFIX/bin/bw" <<'EOF'
#!/usr/bin/env bash
echo "bw $*" >>"$MOCK_LOG"
case $1 in
  status)
    if [[ ${BW_SESSION:-} == goodsession ]]; then s=unlocked; else s=${MOCK_BW_STATUS:-locked}; fi
    printf '{"status":"%s"}\n' "$s" ;;
  unlock)
    var=""; prev=""
    for a in "$@"; do [[ $prev == --passwordenv ]] && var=$a; prev=$a; done
    [[ -n $var && ${!var:-} == master ]] && { echo goodsession; exit 0; }
    echo "Invalid master password." >&2; exit 1 ;;
  list)
    [[ ${BW_SESSION:-} == goodsession || ${MOCK_BW_STATUS:-} == unlocked ]] || { echo "Vault is locked." >&2; exit 1; }
    search=""; prev=""
    for a in "$@"; do [[ $prev == --search ]] && search=$a; prev=$a; done
    case $search in
      srv)    echo '[{"id":"ID-A","name":"Server A","login":{"username":"root","password":"pa"}},{"id":"ID-B","name":"Server B #2","login":{"username":"admin","password":"pb"}}]' ;;
      single) echo '[{"id":"ID-S","name":"Single","sshKey":{"privateKey":"k"}}]' ;;
      *)      echo '[]' ;;
    esac ;;
  get)
    [[ ${BW_SESSION:-} == goodsession || ${MOCK_BW_STATUS:-} == unlocked ]] || { echo "Vault is locked." >&2; exit 1; }
    case $3 in
      ITEMPW)  echo '{"login":{"username":"u","password":"s3cr3t pw"}}' ;;
      ITEMKEY) printf '%s\n' '{"type":5,"sshKey":{"privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"}}' ;;
      *) echo "Not found." >&2; exit 1 ;;
    esac ;;
esac
EOF
    chmod +x "$PREFIX/bin/termux-fingerprint" "$base/system/su" "$PREFIX/bin/ssh" \
             "$PREFIX/bin/sshpass" "$PREFIX/bin/bw"
    export MOCK_SU="$base/system/su"
}

write_config() {
    mkdir -p "$HOME/.config/termux-auth-wrapper"
    {
        printf 'SU_BINARY="%s"\n' "$MOCK_SU"
        printf '%s\n' "BIO_TIMEOUT=5" "BIO_MAX_ATTEMPTS=1" "AUTH_CACHE_TIMEOUT=0"
        if (($#)); then printf '%s\n' "$@"; fi
    } >"$HOME/.config/termux-auth-wrapper/config.conf"
}

fp_count() { wc -l <"$FP_CALLS" | tr -d ' '; }

run() {
    # run <command...>  -> sets OUT (stdout+stderr) and RC
    OUT=$("$@" 2>&1)
    RC=$?
    if [[ $VERBOSE == true && $RC != 0 ]]; then printf '      [rc=%s] %s\n' "$RC" "${OUT//$'\n'/$'\n      '}"; fi
}

# =============================================================================
section "Static checks"
if command -v shellcheck >/dev/null 2>&1; then
    if out=$(cd "$REPO" && shellcheck -x -P SCRIPTDIR -P . install.sh uninstall.sh lib/*.sh wrappers/* bin/termux-auth 2>&1); then
        ok "shellcheck without findings"
    else
        bad "shellcheck" "$out"
    fi
else
    printf '  (shellcheck not installed – skipped)\n'
fi
for f in "$REPO"/install.sh "$REPO"/uninstall.sh "$REPO"/lib/*.sh "$REPO"/wrappers/* "$REPO"/bin/termux-auth; do
    bash -n "$f" || bad "Syntax $f"
done
ok "bash -n for all scripts"

# =============================================================================
section "Installation (prefix mode, without dpkg)"
new_env prefix
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes
assert_eq "install.sh exit code 0" 0 "$RC"
assert_file "sudo wrapper installed" "$PREFIX/bin/sudo"
assert_file "ssh wrapper installed" "$PREFIX/bin/ssh"
assert_contains "ssh in PREFIX/bin is the wrapper" "TERMUX_AUTH_WRAPPER_MARKER" "$(head -c 300 "$PREFIX/bin/ssh")"
assert_contains "original ssh saved" "fake openssh binary" "$(cat "$PREFIX/libexec/termux-auth-wrapper/ssh" 2>/dev/null)"
assert_eq "shebang rewritten to \$PREFIX/bin/bash" "#!$PREFIX/bin/bash" "$(head -n1 "$PREFIX/bin/sudo")"
assert_not_contains "placeholder replaced" "@TAW_LIB_DIR@" "$(cat "$PREFIX/bin/sudo")"
assert_file "termux-auth linked" "$PREFIX/bin/termux-auth"
assert_file "check_biometric linked" "$PREFIX/bin/check_biometric"
assert_file "configuration created" "$HOME/.config/termux-auth-wrapper/config.conf"
assert_file "apt hook created" "$PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper"
assert_eq "configuration is 0600" 600 "$(stat -c %a "$HOME/.config/termux-auth-wrapper/config.conf")"

echo "# my own change" >>"$HOME/.config/termux-auth-wrapper/config.conf"
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes
assert_eq "reinstall is idempotent" 0 "$RC"
assert_contains "configuration kept on reinstall" "# my own change" "$(cat "$HOME/.config/termux-auth-wrapper/config.conf")"
assert_contains "original ssh still present after reinstall" "fake openssh binary" "$(cat "$PREFIX/libexec/termux-auth-wrapper/ssh")"

write_config

# =============================================================================
section "check_biometric.sh"
MOCK_FP=success run check_biometric -d "Test"
assert_eq "success -> exit 0" 0 "$RC"
MOCK_FP=fail run check_biometric
assert_eq "rejected -> exit 1" 1 "$RC"
assert_contains "rejected -> message" "not recognized" "$OUT"
MOCK_FP=nohw run check_biometric
assert_contains "no sensor -> message" "no fingerprint sensor" "$OUT"
MOCK_FP=noenroll run check_biometric
assert_contains "no fingerprint enrolled -> message" "No fingerprint enrolled" "$OUT"
MOCK_FP=lockout run check_biometric
assert_contains "lockout -> message" "locked" "$OUT"
MOCK_FP=garbage run check_biometric
assert_eq "not JSON -> exit 1" 1 "$RC"
assert_contains "not JSON -> message" "not JSON" "$OUT"
MOCK_FP=empty run check_biometric
assert_contains "empty output -> hint about Termux:API" "Termux:API" "$OUT"
MOCK_FP=success run check_biometric -q
assert_eq "-q prints nothing" "" "$OUT"
start=$SECONDS
MOCK_FP=hang run check_biometric
assert_eq "hanging dialog -> exit 1" 1 "$RC"
assert_contains "hanging dialog -> timeout message" "No answer from Termux:API" "$OUT"
(( SECONDS - start <= 10 )) && ok "timeout applies (≤10s)" || bad "timeout applies" "$((SECONDS - start))s"
: >"$FP_CALLS"
MOCK_FP=fail TAW_BIO_MAX_ATTEMPTS=3 run check_biometric
assert_eq "BIO_MAX_ATTEMPTS=3 -> 3 dialogs" 3 "$(fp_count)"
: >"$FP_CALLS"
MOCK_FP=nohw TAW_BIO_MAX_ATTEMPTS=3 run check_biometric
assert_eq "no sensor -> no retry" 1 "$(fp_count)"
: >"$FP_CALLS"
MOCK_FP=success run check_biometric -t "My title" -d "My description"
assert_contains "title/description passed to termux-fingerprint" "-t My title -d My description" "$(cat "$FP_CALLS")"

: >"$FP_CALLS"
MOCK_FP=success TAW_BIO_DIALOG_TEXT=false run check_biometric -d "X"
assert_eq "BIO_DIALOG_TEXT=false -> no options" "call " "$(cat "$FP_CALLS")"

# =============================================================================
section "termux-auth diag"
printf '#!/bin/sh\necho "1.2.3"\n' >"$PREFIX/bin/dpkg-query"
printf '#!/bin/sh\n[ -n "$MOCK_IPC_HANG" ] && sleep 30\necho "{\\"percentage\\": 80}"\n' >"$PREFIX/bin/termux-battery-status"
chmod +x "$PREFIX/bin/dpkg-query" "$PREFIX/bin/termux-battery-status"
MOCK_FP=hang run termux-auth diag
assert_contains "diag: package version" "termux-api 1.2.3" "$OUT"
assert_contains "diag: IPC ok, only the dialog hangs" "Only the dialog hangs" "$OUT"
MOCK_FP=hang MOCK_IPC_HANG=1 run termux-auth diag
assert_contains "diag: IPC hangs -> hint about signature/source" "receives no requests at all" "$OUT"
MOCK_FP=success run termux-auth diag
assert_contains "diag: success" "Everything works" "$OUT"
assert_contains "diag: no crash" "No crash of com.termux.api" "$OUT"
cat >"$PREFIX/bin/logcat" <<'EOF'
#!/bin/sh
[ "$3" = crash ] || exit 0
cat <<'LOG'
11-02 14:50:01.000  1111  1111 E AndroidRuntime: FATAL EXCEPTION: main
11-02 14:50:01.000  1111  1111 E AndroidRuntime: Process: com.other.app, PID: 1111
11-02 14:50:01.000  1111  1111 E AndroidRuntime: java.lang.NullPointerException
11-02 14:54:01.000  2222  2222 E AndroidRuntime: FATAL EXCEPTION: main
11-02 14:54:01.000  2222  2222 E AndroidRuntime: Process: com.termux.api, PID: 2222
11-02 14:54:01.000  2222  2222 E AndroidRuntime: java.lang.SecurityException: Permission Denial: test
11-02 14:54:01.000  2222  2222 E AndroidRuntime: 	at com.termux.api.TermuxApiReceiver.onReceive(TermuxApiReceiver.java:42)
11-02 14:54:02.000  3333  3333 I ActivityManager: something else
LOG
EOF
chmod +x "$PREFIX/bin/logcat"
MOCK_FP=hang run termux-auth diag
assert_contains "diag: Termux:API crash detected" "Termux:API has crashed" "$OUT"
assert_contains "diag: stack trace printed" "SecurityException: Permission Denial" "$OUT"
assert_not_contains "diag: other app ignored" "com.other.app" "$OUT"
assert_contains "diag: hint about the cause" "permission problem" "$OUT"
# Real case (Pixel/Android 17): package "not installed for user 0"
cat >"$PREFIX/bin/logcat" <<'EOF'
#!/bin/sh
[ "$3" = crash ] || exit 0
cat <<'LOG'
11-02 15:10:00.000 16245 16245 E AndroidRuntime: FATAL EXCEPTION: main
11-02 15:10:00.000 16245 16245 E AndroidRuntime: Process: com.termux.api, PID: 16245
11-02 15:10:00.000 16245 16245 E AndroidRuntime: java.lang.RuntimeException: Unable to instantiate application com.termux.api.TermuxAPIApplication package com.termux.api
11-02 15:10:00.000 16245 16245 E AndroidRuntime: Caused by: java.lang.IllegalStateException: Unable to get package info for com.termux.api; is package not installed on user 0?
LOG
EOF
printf '#!/bin/sh\n[ "$1" = list ] && [ "$2" = packages ] && echo package:com.termux\nexit 1\n' >"$PREFIX/bin/pm"
chmod +x "$PREFIX/bin/logcat" "$PREFIX/bin/pm"
MOCK_FP=hang run termux-auth diag
assert_contains "diag: 'not installed on user 0' detected" '"not installed" for user 0' "$OUT"
assert_contains "diag: package info shown despite rc!=0" "== pm list packages --user 0" "$OUT"
assert_contains "diag: missing package for user 0 detected" "pm install-existing --user 0 com.termux.api" "$OUT"
rm -f "$PREFIX/bin/logcat" "$PREFIX/bin/pm"
rm -f "$PREFIX/bin/dpkg-query" "$PREFIX/bin/termux-battery-status"

# =============================================================================
section "sudo wrapper"
MOCK_FP=success run sudo id -u
assert_eq "sudo id -u -> own UID (mock su)" "$(id -u)" "$OUT"
MOCK_FP=success run sudo printf '%s|' "a b" "c'd" '$HOME' '`x`' ';' '"q"'
assert_eq "quoting of special characters" "a b|c'd|\$HOME|\`x\`|;|\"q\"|" "$OUT"
MOCK_FP=success run sh -c 'echo hello | sudo cat'
assert_eq "stdin is passed through" "hello" "$OUT"
MOCK_FP=success run sudo sh -c 'exit 7'
assert_eq "exit code is passed through" 7 "$RC"
MOCK_FP=success run sudo FOO=bar sh -c 'echo $FOO'
assert_eq "VAR=value assignments" "bar" "$OUT"
MOCK_FP=success run sudo sh -c 'echo $PREFIX:$HOME'
assert_eq "Termux environment on the root side" "$PREFIX:$HOME/.suroot" "$OUT"
: >"$MOCK_LOG"
MOCK_FP=fail run sudo touch "$ROOT/should-not-exist"
assert_eq "fingerprint rejected -> exit 1" 1 "$RC"
assert_no_file "command was NOT run" "$ROOT/should-not-exist"
assert_eq "su was not called" "" "$(cat "$MOCK_LOG")"
assert_contains "clear error message" "Authentication failed" "$OUT"
MOCK_FP=success run sudo -u shell id -u
assert_contains "-u USER passed to su" "su shell -c" "$(cat "$MOCK_LOG")"
: >"$MOCK_LOG"
MOCK_FP=success run sudo -E true
assert_contains "-E -> su -p" "su -p -c" "$(cat "$MOCK_LOG")"
MOCK_FP=success run sudo --bogus
assert_eq "unknown option -> exit 1" 1 "$RC"
run sudo -h
assert_contains "--help" "fingerprint" "$OUT"
MOCK_FP=success TAW_SUDO_ENABLED=false run sudo true
assert_contains "SUDO_ENABLED=false" "disabled" "$OUT"
MOCK_FP=success TAW_SU_BINARY=/nonexistent run sudo true
assert_contains "missing su -> message" "not executable" "$OUT"

# Call from within a shell script (PATH resolution)
cat >"$ROOT/script.sh" <<'EOF'
#!/bin/sh
sudo id -u
EOF
chmod +x "$ROOT/script.sh"
MOCK_FP=success run "$ROOT/script.sh"
assert_eq "sudo from a script is found via PATH" "$(id -u)" "$OUT"

# =============================================================================
section "Auth cache & locking"
write_config "AUTH_CACHE_TIMEOUT=300"
: >"$FP_CALLS"
MOCK_FP=success run sudo true
MOCK_FP=fail run sudo true
assert_eq "cache: second call succeeds without dialog" 0 "$RC"
assert_eq "cache: only one dialog" 1 "$(fp_count)"
MOCK_FP=fail run sudo -k true
assert_eq "sudo -k COMMAND ignores the cache" 1 "$RC"
run sudo -k
MOCK_FP=fail run sudo true
assert_eq "sudo -k clears the cache" 1 "$RC"
MOCK_FP=success run sudo -v
assert_eq "sudo -v authenticates" 0 "$RC"
run sudo -K
: >"$FP_CALLS"
run sudo -n true
assert_eq "sudo -n without cache -> error" 1 "$RC"
assert_eq "sudo -n shows no dialog" 0 "$(fp_count)"
MOCK_FP=success run sudo -v
run sudo -n true
assert_eq "sudo -n with cache -> OK" 0 "$RC"
MOCK_FP=fail run ssh myalias
assert_eq "separate caches for sudo/ssh" 255 "$RC"
MOCK_FP=fail TAW_AUTH_CACHE_SHARED=true run ssh myalias
assert_eq "AUTH_CACHE_SHARED=true shares the cache" 255 "$RC"
MOCK_FP=success TAW_AUTH_CACHE_SHARED=true run sudo -v
MOCK_FP=fail TAW_AUTH_CACHE_SHARED=true run ssh myalias
assert_eq "AUTH_CACHE_SHARED=true: ssh uses the sudo cache" 0 "$RC"
run sudo -K
# Parallel calls (e.g. a script with "cmd & cmd &") -> only ONE dialog
: >"$FP_CALLS"
export MOCK_FP=success MOCK_FP_DELAY=1
for i in 1 2 3; do sudo true >/dev/null 2>&1 & done
wait
unset MOCK_FP MOCK_FP_DELAY
assert_eq "parallel calls share one dialog" 1 "$(fp_count)"
run sudo -K

# =============================================================================
section "Fallbacks"
write_config "FALLBACK_MODE=none"
MOCK_FP=nohw run sudo true
assert_eq "FALLBACK_MODE=none + no sensor -> denied" 1 "$RC"
write_config "FALLBACK_MODE=allow"
MOCK_FP=nohw run sudo true
assert_eq "FALLBACK_MODE=allow + no sensor -> allowed" 0 "$RC"
assert_contains "allow warns clearly" "INSECURE" "$OUT"
MOCK_FP=fail run sudo true
assert_eq "allow does NOT apply to a rejected fingerprint" 1 "$RC"
write_config "FALLBACK_MODE=allow" "FALLBACK_ON_REJECT=true"
MOCK_FP=fail run sudo true
assert_eq "FALLBACK_ON_REJECT=true" 0 "$RC"
write_config "FALLBACK_MODE=pin"
MOCK_FP=nohw run sudo true </dev/null
assert_eq "PIN fallback without a PIN set -> denied" 1 "$RC"
assert_contains "PIN hint" "termux-auth set-pin" "$OUT"

# =============================================================================
section "Config parser"
write_config 'BIO_TITLE="With # hash"' "AUTH_CACHE_TIMEOUT=abc" "UNKNOWN=1" "this is not an assignment" 'SSH_SKIP_HOSTS="a b" # comment'
run bash -c "source '$PREFIX/lib/termux-auth-wrapper/common.sh'; taw_load_config; echo \"T=\$TAW_BIO_TITLE|C=\$TAW_AUTH_CACHE_TIMEOUT|S=\$TAW_SSH_SKIP_HOSTS\""
assert_contains "quotes + hash in the value" "T=With # hash|" "$OUT"
assert_contains "invalid number -> default" "C=300|" "$OUT"
assert_contains "comment after the value removed" "S=a b" "$OUT"
assert_contains "unknown key -> warning" "Unknown config key 'UNKNOWN'" "$OUT"
assert_contains "invalid line -> warning" "Invalid line" "$OUT"
run bash -c "export TAW_BIO_TITLE=env; source '$PREFIX/lib/termux-auth-wrapper/common.sh'; taw_load_config; echo \$TAW_BIO_TITLE"
assert_contains "environment variable takes precedence" "env" "$OUT"
write_config 'BIO_TITLE="$(touch '"$ROOT"'/pwned)"'
run bash -c "source '$PREFIX/lib/termux-auth-wrapper/common.sh'; taw_load_config"
assert_no_file "configuration is not executed" "$ROOT/pwned"

# =============================================================================
section "ssh wrapper"
write_config
: >"$FP_CALLS"; : >"$MOCK_LOG"
MOCK_FP=success run ssh -p 2222 user@host.example ls -la
assert_eq "ssh -> real ssh with unchanged arguments" "REAL_SSH -p 2222 user@host.example ls -la" "$OUT"
assert_eq "ssh -> one dialog" 1 "$(fp_count)"
assert_contains "target shown in the dialog" "SSH connection to user@host.example" "$(cat "$FP_CALLS")"
: >"$MOCK_LOG"
MOCK_FP=fail run ssh host.example
assert_eq "ssh rejected -> exit 255" 255 "$RC"
assert_eq "ssh rejected -> no connection" "" "$(cat "$MOCK_LOG")"
: >"$FP_CALLS"
MOCK_FP=fail run ssh -V
assert_eq "ssh -V without dialog" 0 "$(fp_count)"
MOCK_FP=fail run ssh -G host
assert_eq "ssh -G without dialog" 0 "$(fp_count)"
MOCK_FP=success MOCK_SSH_RC=42 run ssh host
assert_eq "ssh exit code is passed through" 42 "$RC"
write_config 'SSH_SKIP_HOSTS="github.com *.lan"'
: >"$FP_CALLS"
MOCK_FP=fail run ssh git@github.com
assert_eq "SSH_SKIP_HOSTS: github.com without dialog" 0 "$RC"
MOCK_FP=fail run ssh nas.lan
assert_eq "SSH_SKIP_HOSTS: Glob *.lan" 0 "$RC"
assert_eq "SSH_SKIP_HOSTS: no dialog" 0 "$(fp_count)"
write_config "SSH_AUTH_SCOPE=mapped"
MOCK_FP=fail run ssh unmapped.host
assert_eq "SSH_AUTH_SCOPE=mapped: unmapped host without dialog" 0 "$RC"
write_config "SSH_ENABLED=false"
MOCK_FP=fail run ssh any.host
assert_eq "SSH_ENABLED=false -> pass-through" 0 "$RC"

section "ssh + Bitwarden"
cat >"$HOME/.config/termux-auth-wrapper/ssh-hosts.conf" <<'EOF'
# comment
10.0.0.5          ITEMPW    password
keyhost           ITEMKEY   key
*.missing         NOPE
named             "My server"  auto
EOF
write_config "BW_ENABLED=true" "BW_UNLOCK_MODE=never"
MOCK_FP=success MOCK_BW_STATUS=unlocked run ssh myalias
assert_contains "password passed via sshpass (FD)" "SSHPASS_PW=s3cr3t pw" "$OUT"
assert_contains "alias resolved to host name via ssh -G" "REAL_SSH -o NumberOfPasswordPrompts=1 myalias" "$OUT"
MOCK_FP=success MOCK_BW_STATUS=unlocked TAW_SSH_KEY_METHOD=tempfile run ssh keyhost
assert_contains "key passed with -i" "KEYLINE=-----BEGIN OPENSSH PRIVATE KEY-----" "$OUT"
assert_contains "IdentitiesOnly set" "-o IdentitiesOnly=yes keyhost" "$OUT"
keyfile=$(grep -o 'KEYFILE=.*' <<<"$OUT" | cut -d= -f2)
assert_no_file "temporary key deleted again" "${keyfile:-/nonexistent-but-unset}"
[[ -n $keyfile ]] || bad "key file path determined"
MOCK_FP=success MOCK_BW_STATUS=locked run ssh myalias
assert_contains "locked vault -> clear message" "The Bitwarden vault is locked" "$OUT"
assert_contains "BW_FALLBACK=prompt -> normal ssh" "REAL_SSH myalias" "$OUT"
write_config "BW_ENABLED=true" "BW_UNLOCK_MODE=never" "BW_FALLBACK=fail"
MOCK_FP=success MOCK_BW_STATUS=locked run ssh myalias
assert_eq "BW_FALLBACK=fail -> Exit 255" 255 "$RC"
MOCK_FP=success MOCK_BW_STATUS=unauthenticated run ssh myalias
assert_contains "not signed in -> hint bw login" "bw login" "$OUT"
MOCK_FP=success MOCK_BW_STATUS=unlocked run ssh x.missing
assert_contains "unknown item -> error message from bw" "Not found" "$OUT"
MOCK_FP=fail MOCK_BW_STATUS=unlocked run ssh myalias
assert_eq "no Bitwarden access without fingerprint" 255 "$RC"
assert_not_contains "no password without fingerprint" "s3cr3t" "$OUT"
MOCK_FP=success BW_SESSION=goodsession TAW_BW_ITEM=ITEMPW run ssh somewhere
assert_contains "TAW_BW_ITEM overrides the mapping" "SSHPASS_PW=s3cr3t pw" "$OUT"
mv "$PREFIX/bin/bw" "$PREFIX/bin/bw.off"
MOCK_FP=success run ssh myalias
assert_contains "bw missing -> install hint" "npm install -g @bitwarden/cli" "$OUT"
mv "$PREFIX/bin/bw.off" "$PREFIX/bin/bw"

# =============================================================================
section "Interactive paths (PTY)"
if command -v python3 >/dev/null 2>&1; then
    TTY="python3 -I $REPO/tests/tty_helper.py"
    write_config "FALLBACK_MODE=pin"
    # shellcheck disable=SC2086
    run $TTY "New fallback PIN=4711" "Repeat PIN=4711" -- termux-auth set-pin
    assert_eq "set-pin exit code 0" 0 "$RC"
    assert_contains "set-pin stores a hash" 'FALLBACK_PIN_HASH="sha256:' "$(cat "$HOME/.config/termux-auth-wrapper/config.conf")"
    assert_not_contains "PIN not stored in plain text" "4711" "$(cat "$HOME/.config/termux-auth-wrapper/config.conf")"
    # shellcheck disable=SC2086
    MOCK_FP=nohw run $TTY "Fallback PIN=4711" -- sudo id -u
    assert_eq "PIN fallback with the right PIN" 0 "$RC"
    assert_contains "PIN fallback runs the command" "$(id -u)" "$OUT"
    # shellcheck disable=SC2086
    MOCK_FP=nohw run $TTY "(1/3)=0000" "(2/3)=1111" "(3/3)=2222" -- sudo id -u
    assert_eq "PIN fallback with a wrong PIN -> denied" 1 "$RC"
    # shellcheck disable=SC2086
    MOCK_FP=fail run $TTY "Fallback PIN=4711" -- sudo true
    assert_eq "PIN not offered after a rejected fingerprint" 1 "$RC"
    assert_not_contains "no PIN prompt after rejection" "Fallback PIN" "$OUT"

    write_config "BW_ENABLED=true" "BW_UNLOCK_MODE=prompt" "BW_SESSION_CACHE=true"
    : >"$MOCK_LOG"
    # shellcheck disable=SC2086
    MOCK_FP=success MOCK_BW_STATUS=locked run $TTY "master password=master" -- ssh myalias
    assert_contains "Bitwarden unlocked interactively + password passed" "SSHPASS_PW=s3cr3t pw" "$OUT"
    assert_not_contains "master password not in the argv of bw" "master" "$(cat "$MOCK_LOG")"
    assert_eq "BW session cache is 0600" 600 "$(stat -c %a "$HOME/.local/state/termux-auth-wrapper/bw-session" 2>/dev/null)"
    MOCK_FP=success MOCK_BW_STATUS=locked run ssh myalias </dev/null
    assert_contains "cached BW session is reused" "SSHPASS_PW=s3cr3t pw" "$OUT"
    # shellcheck disable=SC2086
    MOCK_FP=success MOCK_BW_STATUS=locked run $TTY "master password=wrong" -- env TAW_BW_SESSION_CACHE=false TAW_BW_FALLBACK=fail ssh myalias
    assert_contains "wrong master password -> message" "wrong master password" "$OUT"
    rm -f "$HOME/.local/state/termux-auth-wrapper/bw-session"

    # Setup: master password once, then only the fingerprint
    write_config "BW_UNLOCK_MODE=prompt"
    rm -f "$HOME/.config/termux-auth-wrapper/ssh-hosts.conf"
    # shellcheck disable=SC2086
    MOCK_FP=success MOCK_BW_STATUS=locked run $TTY "[Y/n]=y" "master password=master" -- termux-auth bw-unlock
    assert_eq "bw-unlock exit code 0" 0 "$RC"
    cfg=$(cat "$HOME/.config/termux-auth-wrapper/config.conf")
    assert_contains "bw-unlock enables the session cache" 'BW_SESSION_CACHE="true"' "$cfg"
    assert_contains "bw-unlock enables Bitwarden" 'BW_ENABLED="true"' "$cfg"
    assert_file "bw-unlock stores the session" "$HOME/.local/state/termux-auth-wrapper/bw-session"
    # shellcheck disable=SC2086
    MOCK_FP=success MOCK_BW_STATUS=locked run $TTY "Choose an item=2" -- termux-auth map nas srv password
    assert_eq "map exit code 0" 0 "$RC"
    assert_contains "map lists the matches" "Server B #2  [admin]  password" "$OUT"
    hosts=$(cat "$HOME/.config/termux-auth-wrapper/ssh-hosts.conf")
    assert_contains "map writes the mapping" "ID-B  password  # Server B 2" "$hosts"
    MOCK_FP=success MOCK_BW_STATUS=locked run termux-auth map nas single key </dev/null
    hosts=$(cat "$HOME/.config/termux-auth-wrapper/ssh-hosts.conf")
    assert_contains "map: single match without asking" "ID-S  key" "$hosts"
    assert_eq "map replaces an existing mapping" 1 "$(grep -c '^nas ' <<<"$hosts")"
    MOCK_FP=success MOCK_BW_STATUS=locked run termux-auth map nas nothing
    assert_contains "map: no matches -> message" "No Bitwarden items" "$OUT"
    MOCK_FP=fail run termux-auth map nas srv
    assert_eq "map denied without fingerprint" 1 "$RC"
    # Result: ssh uses the stored session, no more master password
    MOCK_FP=success MOCK_BW_STATUS=locked run termux-auth map srvhost srv password </dev/null
    MOCK_FP=success MOCK_BW_STATUS=locked TAW_AUTH_CACHE_TIMEOUT=0 run ssh srvhost </dev/null
    assert_not_contains "ssh after bw-unlock without master password" "master password" "$OUT"
    rm -f "$HOME/.local/state/termux-auth-wrapper/bw-session" "$HOME/.config/termux-auth-wrapper/ssh-hosts.conf"
else
    printf '  (python3 not available – skipped)\n'
fi

# =============================================================================
section "Update safety: repair"
run termux-auth repair
assert_contains "repair: all OK" ": OK" "$OUT"
# Simulated "pkg upgrade openssh" without dpkg-divert: overwrites the wrapper
printf '#!/usr/bin/env bash\n# fake openssh binary v2\necho "REAL_SSH_V2 $*"\n' >"$PREFIX/bin/ssh"
chmod +x "$PREFIX/bin/ssh"
run termux-auth repair --quiet
assert_contains "repair detects the replaced wrapper" "replaced" "$OUT"
assert_contains "wrapper restored" "TERMUX_AUTH_WRAPPER_MARKER" "$(head -c 300 "$PREFIX/bin/ssh")"
assert_contains "new original saved" "v2" "$(cat "$PREFIX/libexec/termux-auth-wrapper/ssh")"
write_config
MOCK_FP=success run ssh host
assert_contains "wrapper uses the updated original" "REAL_SSH_V2 host" "$OUT"
run termux-auth status
assert_contains "termux-auth status" "Dependencies" "$OUT"

# =============================================================================
section "Uninstall"
run "$PREFIX/lib/termux-auth-wrapper/uninstall.sh" --prefix "$PREFIX" --yes
assert_eq "uninstall.sh exit code 0" 0 "$RC"
assert_no_file "sudo wrapper removed" "$PREFIX/bin/sudo"
assert_contains "original ssh put back" "v2" "$(cat "$PREFIX/bin/ssh" 2>/dev/null)"
assert_no_file "library removed" "$PREFIX/lib/termux-auth-wrapper"
assert_no_file "apt hook removed" "$PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper"
assert_file "configuration kept (without --purge)" "$HOME/.config/termux-auth-wrapper/config.conf"

# =============================================================================
section "Installation with dpkg-divert (like in real Termux)"
new_env dpkg
mkdir -p "$PREFIX/var/lib/dpkg"
export DIVERT_DB="$ROOT/dpkg/diversions"
: >"$DIVERT_DB"
cat >"$PREFIX/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -S ]] || exit 2
case $2 in */bin/ssh) echo "openssh: $2" ;; *) echo "dpkg-query: no path found matching pattern $2" >&2; exit 1 ;; esac
EOF
cat >"$PREFIX/bin/dpkg-divert" <<'EOF'
#!/usr/bin/env bash
# Minimal dpkg-divert mock: database "path|target"
action="" divert="" file=""
while (($#)); do
  case $1 in
    --local|--rename|--quiet) ;;
    --divert) divert=$2; shift ;;
    --add|--remove|--listpackage|--truename) action=$1 ;;
    *) file=$1 ;;
  esac
  shift
done
entry=$(grep "^$file|" "$DIVERT_DB" || true)
case $action in
  --add) [[ -n $entry ]] && exit 0; mv "$file" "$divert"; echo "$file|$divert" >>"$DIVERT_DB" ;;
  --remove) [[ -n $entry ]] || exit 0; mv "${entry#*|}" "$file"; grep -v "^$file|" "$DIVERT_DB" >"$DIVERT_DB.n" || true; mv "$DIVERT_DB.n" "$DIVERT_DB" ;;
  --listpackage) [[ -n $entry ]] && echo LOCAL ;;
  --truename) if [[ -n $entry ]]; then echo "${entry#*|}"; else echo "$file"; fi ;;
esac
exit 0
EOF
chmod +x "$PREFIX/bin/dpkg" "$PREFIX/bin/dpkg-divert"
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes
assert_eq "install.sh with dpkg" 0 "$RC"
assert_contains "ssh diverted with dpkg-divert" "dpkg-divert" "$OUT"
assert_contains "diversion registered" "$PREFIX/bin/ssh|$PREFIX/libexec/termux-auth-wrapper/ssh" "$(cat "$DIVERT_DB")"
write_config
MOCK_FP=success run ssh host
assert_contains "ssh reachable through the diversion" "REAL_SSH host" "$OUT"
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes
assert_eq "reinstall with an existing diversion" 1 "$(grep -c 'bin/ssh|' "$DIVERT_DB")"
run "$REPO/uninstall.sh" --prefix "$PREFIX" --yes --purge
assert_eq "diversion removed" "" "$(cat "$DIVERT_DB")"
assert_contains "original ssh restored" "fake openssh binary" "$(cat "$PREFIX/bin/ssh")"
assert_no_file "--purge removes the configuration" "$HOME/.config/termux-auth-wrapper"

# =============================================================================
section "Installation in home mode"
new_env home
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes --mode home
assert_eq "install.sh --mode home" 0 "$RC"
assert_file "wrapper in ~/.bin" "$HOME/.bin/ssh"
assert_contains "original ssh stays unchanged in PREFIX/bin" "fake openssh binary" "$(cat "$PREFIX/bin/ssh")"
assert_contains "PATH block in ~/.bashrc" "termux-auth-wrapper" "$(cat "$HOME/.bashrc")"
assert_no_file "no apt hook in home mode" "$PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper"
write_config
export PATH="$HOME/.bin:$PATH"
MOCK_FP=success run ssh host
assert_contains "wrapper finds the real ssh via PATH" "REAL_SSH host" "$OUT"
MOCK_FP=success run sudo id -u
assert_eq "sudo in home mode" "$(id -u)" "$OUT"
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes --mode prefix
assert_no_file "mode change removes the ~/.bin wrappers" "$HOME/.bin/ssh"
assert_not_contains "mode change removes the PATH block" "termux-auth-wrapper" "$(cat "$HOME/.bashrc")"
assert_file "mode change: wrappers in PREFIX/bin" "$PREFIX/bin/sudo"

# =============================================================================
printf '\n\033[1mResult: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
