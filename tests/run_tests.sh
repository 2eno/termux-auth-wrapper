#!/usr/bin/env bash
# =============================================================================
# Testsuite für termux-auth-wrapper (läuft auf jedem Linux mit bash + jq)
#
# Simuliert ein Termux-Präfix in einem temporären Verzeichnis und ersetzt
# termux-fingerprint, su (KernelSU), ssh, sshpass, bw und dpkg durch Mocks.
#
#   tests/run_tests.sh            alle Tests
#   tests/run_tests.sh -v         mit Ausgabe der fehlgeschlagenen Befehle
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

# assert_eq <name> <erwartet> <ist>
assert_eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "erwartet: $(printf '%q' "$2")  ist: $(printf '%q' "$3")"; fi; }
assert_contains() { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "erwartet Teiltext: $2 | Ausgabe: ${3:0:400}"; fi; }
assert_not_contains() { if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1" "unerwarteter Teiltext: $2"; fi; }
assert_file() { if [[ -e $2 ]]; then ok "$1"; else bad "$1" "Datei fehlt: $2"; fi; }
assert_no_file() { if [[ ! -e $2 ]]; then ok "$1"; else bad "$1" "Datei sollte fehlen: $2"; fi; }

# --- Testumgebung ------------------------------------------------------------
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/taw-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

new_env() {
    # $1 = Name; legt ein frisches Fake-Termux an und exportiert Variablen
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
    export TAW_ALLOW_ROOT=1   # Testcontainer laufen oft als root

    # Werkzeuge, die die Root-Seite (PATH=$PREFIX/bin:/system/bin) braucht
    local t
    for t in bash sh cat id mkdir env sleep printf echo true false touch; do
        p=$(type -P "$t" 2>/dev/null) && ln -sf "$p" "$PREFIX/bin/$t"
    done
    write_mocks "$base"
}

write_mocks() {
    local base=$1

    # termux-fingerprint: Verhalten über MOCK_FP
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

    # su (KernelSU): su [-p] [-M] [user] -c CMD  -> führt CMD mit sh aus
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

    # "echtes" ssh (ohne Marker): -G löst Aliasse auf, sonst Argumente ausgeben
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
[[ $1 == -d ]] || { echo "sshpass mock: erwartet -d" >&2; exit 99; }
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
    # run <befehl...>  -> setzt OUT (stdout+stderr) und RC
    OUT=$("$@" 2>&1)
    RC=$?
    if [[ $VERBOSE == true && $RC != 0 ]]; then printf '      [rc=%s] %s\n' "$RC" "${OUT//$'\n'/$'\n      '}"; fi
}

# =============================================================================
section "Statische Prüfung"
if command -v shellcheck >/dev/null 2>&1; then
    if out=$(cd "$REPO" && shellcheck -x -P SCRIPTDIR -P . install.sh uninstall.sh lib/*.sh wrappers/* bin/termux-auth 2>&1); then
        ok "shellcheck ohne Befunde"
    else
        bad "shellcheck" "$out"
    fi
else
    printf '  (shellcheck nicht installiert – übersprungen)\n'
fi
for f in "$REPO"/install.sh "$REPO"/uninstall.sh "$REPO"/lib/*.sh "$REPO"/wrappers/* "$REPO"/bin/termux-auth; do
    bash -n "$f" || bad "Syntax $f"
done
ok "bash -n für alle Skripte"

# =============================================================================
section "Installation (prefix-Modus, ohne dpkg)"
new_env prefix
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes
assert_eq "install.sh Exit-Code 0" 0 "$RC"
assert_file "sudo-Wrapper installiert" "$PREFIX/bin/sudo"
assert_file "ssh-Wrapper installiert" "$PREFIX/bin/ssh"
assert_contains "ssh in PREFIX/bin ist Wrapper" "TERMUX_AUTH_WRAPPER_MARKER" "$(head -c 300 "$PREFIX/bin/ssh")"
assert_contains "Original-ssh gesichert" "fake openssh binary" "$(cat "$PREFIX/libexec/termux-auth-wrapper/ssh" 2>/dev/null)"
assert_eq "Shebang auf \$PREFIX/bin/bash umgeschrieben" "#!$PREFIX/bin/bash" "$(head -n1 "$PREFIX/bin/sudo")"
assert_not_contains "Platzhalter ersetzt" "@TAW_LIB_DIR@" "$(cat "$PREFIX/bin/sudo")"
assert_file "termux-auth verlinkt" "$PREFIX/bin/termux-auth"
assert_file "check_biometric verlinkt" "$PREFIX/bin/check_biometric"
assert_file "Konfiguration angelegt" "$HOME/.config/termux-auth-wrapper/config.conf"
assert_file "apt-Hook angelegt" "$PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper"
assert_eq "Konfiguration ist 0600" 600 "$(stat -c %a "$HOME/.config/termux-auth-wrapper/config.conf")"

echo "# eigene Änderung" >>"$HOME/.config/termux-auth-wrapper/config.conf"
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes
assert_eq "Neuinstallation idempotent" 0 "$RC"
assert_contains "Konfiguration bei Neuinstallation erhalten" "# eigene Änderung" "$(cat "$HOME/.config/termux-auth-wrapper/config.conf")"
assert_contains "Original-ssh nach Neuinstallation weiterhin vorhanden" "fake openssh binary" "$(cat "$PREFIX/libexec/termux-auth-wrapper/ssh")"

write_config

# =============================================================================
section "check_biometric.sh"
MOCK_FP=success run check_biometric -d "Test"
assert_eq "Erfolg -> Exit 0" 0 "$RC"
MOCK_FP=fail run check_biometric
assert_eq "Abgelehnt -> Exit 1" 1 "$RC"
assert_contains "Abgelehnt -> Meldung" "nicht erkannt" "$OUT"
MOCK_FP=nohw run check_biometric
assert_contains "Kein Sensor -> Meldung" "keinen Fingerabdrucksensor" "$OUT"
MOCK_FP=noenroll run check_biometric
assert_contains "Kein Fingerabdruck eingerichtet -> Meldung" "Kein Fingerabdruck eingerichtet" "$OUT"
MOCK_FP=lockout run check_biometric
assert_contains "Lockout -> Meldung" "gesperrt" "$OUT"
MOCK_FP=garbage run check_biometric
assert_eq "Kein JSON -> Exit 1" 1 "$RC"
assert_contains "Kein JSON -> Meldung" "kein JSON" "$OUT"
MOCK_FP=empty run check_biometric
assert_contains "Leere Ausgabe -> Hinweis auf Termux:API" "Termux:API" "$OUT"
MOCK_FP=success run check_biometric -q
assert_eq "-q ohne Ausgabe" "" "$OUT"
start=$SECONDS
MOCK_FP=hang run check_biometric
assert_eq "Hängender Dialog -> Exit 1" 1 "$RC"
assert_contains "Hängender Dialog -> Timeout-Meldung" "Keine Antwort von Termux:API" "$OUT"
(( SECONDS - start <= 10 )) && ok "Timeout greift (≤10s)" || bad "Timeout greift" "$((SECONDS - start))s"
: >"$FP_CALLS"
MOCK_FP=fail TAW_BIO_MAX_ATTEMPTS=3 run check_biometric
assert_eq "BIO_MAX_ATTEMPTS=3 -> 3 Dialoge" 3 "$(fp_count)"
: >"$FP_CALLS"
MOCK_FP=nohw TAW_BIO_MAX_ATTEMPTS=3 run check_biometric
assert_eq "Kein Sensor -> keine Wiederholung" 1 "$(fp_count)"
: >"$FP_CALLS"
MOCK_FP=success run check_biometric -t "Mein Titel" -d "Meine Beschreibung"
assert_contains "Titel/Beschreibung an termux-fingerprint" "-t Mein Titel -d Meine Beschreibung" "$(cat "$FP_CALLS")"

: >"$FP_CALLS"
MOCK_FP=success TAW_BIO_DIALOG_TEXT=false run check_biometric -d "X"
assert_eq "BIO_DIALOG_TEXT=false -> keine Optionen" "call " "$(cat "$FP_CALLS")"

# =============================================================================
section "termux-auth diag"
printf '#!/bin/sh\necho "1.2.3"\n' >"$PREFIX/bin/dpkg-query"
printf '#!/bin/sh\n[ -n "$MOCK_IPC_HANG" ] && sleep 30\necho "{\\"percentage\\": 80}"\n' >"$PREFIX/bin/termux-battery-status"
chmod +x "$PREFIX/bin/dpkg-query" "$PREFIX/bin/termux-battery-status"
MOCK_FP=hang run termux-auth diag
assert_contains "diag: Paketversion" "termux-api 1.2.3" "$OUT"
assert_contains "diag: IPC ok, nur Dialog hängt" "Nur der Dialog hängt" "$OUT"
MOCK_FP=hang MOCK_IPC_HANG=1 run termux-auth diag
assert_contains "diag: IPC hängt -> Hinweis Signatur/Quelle" "empfängt gar keine Anfragen" "$OUT"
MOCK_FP=success run termux-auth diag
assert_contains "diag: Erfolg" "Alles funktioniert" "$OUT"
assert_contains "diag: kein Absturz" "Kein Absturz von com.termux.api" "$OUT"
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
assert_contains "diag: Absturz von Termux:API erkannt" "Termux:API ist abgestürzt" "$OUT"
assert_contains "diag: Stacktrace ausgegeben" "SecurityException: Permission Denial" "$OUT"
assert_not_contains "diag: fremde App ignoriert" "com.other.app" "$OUT"
assert_contains "diag: Hinweis zur Ursache" "Berechtigungsproblem" "$OUT"
rm -f "$PREFIX/bin/logcat"
rm -f "$PREFIX/bin/dpkg-query" "$PREFIX/bin/termux-battery-status"

# =============================================================================
section "sudo-Wrapper"
MOCK_FP=success run sudo id -u
assert_eq "sudo id -u -> eigene UID (Mock-su)" "$(id -u)" "$OUT"
MOCK_FP=success run sudo printf '%s|' "a b" "c'd" '$HOME' '`x`' ';' '"q"'
assert_eq "Quoting von Sonderzeichen" "a b|c'd|\$HOME|\`x\`|;|\"q\"|" "$OUT"
MOCK_FP=success run sh -c 'echo hallo | sudo cat'
assert_eq "stdin wird durchgereicht" "hallo" "$OUT"
MOCK_FP=success run sudo sh -c 'exit 7'
assert_eq "Exit-Code wird durchgereicht" 7 "$RC"
MOCK_FP=success run sudo FOO=bar sh -c 'echo $FOO'
assert_eq "VAR=wert-Zuweisungen" "bar" "$OUT"
MOCK_FP=success run sudo sh -c 'echo $PREFIX:$HOME'
assert_eq "Termux-Umgebung auf Root-Seite" "$PREFIX:$HOME/.suroot" "$OUT"
: >"$MOCK_LOG"
MOCK_FP=fail run sudo touch "$ROOT/should-not-exist"
assert_eq "Fingerabdruck abgelehnt -> Exit 1" 1 "$RC"
assert_no_file "Befehl wurde NICHT ausgeführt" "$ROOT/should-not-exist"
assert_eq "su wurde nicht aufgerufen" "" "$(cat "$MOCK_LOG")"
assert_contains "Klare Fehlermeldung" "Authentifizierung fehlgeschlagen" "$OUT"
MOCK_FP=success run sudo -u shell id -u
assert_contains "-u BENUTZER an su übergeben" "su shell -c" "$(cat "$MOCK_LOG")"
: >"$MOCK_LOG"
MOCK_FP=success run sudo -E true
assert_contains "-E -> su -p" "su -p -c" "$(cat "$MOCK_LOG")"
MOCK_FP=success run sudo --bogus
assert_eq "Unbekannte Option -> Exit 1" 1 "$RC"
run sudo -h
assert_contains "--help" "Fingerabdruck" "$OUT"
MOCK_FP=success TAW_SUDO_ENABLED=false run sudo true
assert_contains "SUDO_ENABLED=false" "deaktiviert" "$OUT"
MOCK_FP=success TAW_SU_BINARY=/nonexistent run sudo true
assert_contains "Fehlendes su -> Meldung" "nicht ausführbar" "$OUT"

# Aufruf aus einem Shell-Skript heraus (PATH-Auflösung)
cat >"$ROOT/script.sh" <<'EOF'
#!/bin/sh
sudo id -u
EOF
chmod +x "$ROOT/script.sh"
MOCK_FP=success run "$ROOT/script.sh"
assert_eq "sudo aus Skript greift über PATH" "$(id -u)" "$OUT"

# =============================================================================
section "Auth-Cache & Locking"
write_config "AUTH_CACHE_TIMEOUT=300"
: >"$FP_CALLS"
MOCK_FP=success run sudo true
MOCK_FP=fail run sudo true
assert_eq "Cache: zweiter Aufruf ohne Dialog erfolgreich" 0 "$RC"
assert_eq "Cache: nur ein Dialog" 1 "$(fp_count)"
MOCK_FP=fail run sudo -k true
assert_eq "sudo -k BEFEHL ignoriert Cache" 1 "$RC"
run sudo -k
MOCK_FP=fail run sudo true
assert_eq "sudo -k löscht Cache" 1 "$RC"
MOCK_FP=success run sudo -v
assert_eq "sudo -v authentifiziert" 0 "$RC"
run sudo -K
: >"$FP_CALLS"
run sudo -n true
assert_eq "sudo -n ohne Cache -> Fehler" 1 "$RC"
assert_eq "sudo -n zeigt keinen Dialog" 0 "$(fp_count)"
MOCK_FP=success run sudo -v
run sudo -n true
assert_eq "sudo -n mit Cache -> OK" 0 "$RC"
MOCK_FP=fail run ssh myalias
assert_eq "getrennte Caches für sudo/ssh" 255 "$RC"
MOCK_FP=fail TAW_AUTH_CACHE_SHARED=true run ssh myalias
assert_eq "AUTH_CACHE_SHARED=true teilt den Cache" 255 "$RC"
MOCK_FP=success TAW_AUTH_CACHE_SHARED=true run sudo -v
MOCK_FP=fail TAW_AUTH_CACHE_SHARED=true run ssh myalias
assert_eq "AUTH_CACHE_SHARED=true: ssh nutzt sudo-Cache" 0 "$RC"
run sudo -K
# Parallele Aufrufe (z. B. Skript mit "cmd & cmd &") -> nur EIN Dialog
: >"$FP_CALLS"
export MOCK_FP=success MOCK_FP_DELAY=1
for i in 1 2 3; do sudo true >/dev/null 2>&1 & done
wait
unset MOCK_FP MOCK_FP_DELAY
assert_eq "Parallele Aufrufe teilen sich einen Dialog" 1 "$(fp_count)"
run sudo -K

# =============================================================================
section "Fallbacks"
write_config "FALLBACK_MODE=none"
MOCK_FP=nohw run sudo true
assert_eq "FALLBACK_MODE=none + kein Sensor -> verweigert" 1 "$RC"
write_config "FALLBACK_MODE=allow"
MOCK_FP=nohw run sudo true
assert_eq "FALLBACK_MODE=allow + kein Sensor -> erlaubt" 0 "$RC"
assert_contains "allow warnt deutlich" "UNSICHER" "$OUT"
MOCK_FP=fail run sudo true
assert_eq "allow greift NICHT bei abgelehntem Fingerabdruck" 1 "$RC"
write_config "FALLBACK_MODE=allow" "FALLBACK_ON_REJECT=true"
MOCK_FP=fail run sudo true
assert_eq "FALLBACK_ON_REJECT=true" 0 "$RC"
write_config "FALLBACK_MODE=pin"
MOCK_FP=nohw run sudo true </dev/null
assert_eq "PIN-Fallback ohne gesetzte PIN -> verweigert" 1 "$RC"
assert_contains "PIN-Hinweis" "termux-auth set-pin" "$OUT"

# =============================================================================
section "Konfigurations-Parser"
write_config 'BIO_TITLE="Mit # Raute"' "AUTH_CACHE_TIMEOUT=abc" "UNBEKANNT=1" "das ist keine zuweisung" 'SSH_SKIP_HOSTS="a b" # Kommentar'
run bash -c "source '$PREFIX/lib/termux-auth-wrapper/common.sh'; taw_load_config; echo \"T=\$TAW_BIO_TITLE|C=\$TAW_AUTH_CACHE_TIMEOUT|S=\$TAW_SSH_SKIP_HOSTS\""
assert_contains "Anführungszeichen + Raute im Wert" "T=Mit # Raute|" "$OUT"
assert_contains "Ungültige Zahl -> Standardwert" "C=300|" "$OUT"
assert_contains "Kommentar nach Wert entfernt" "S=a b" "$OUT"
assert_contains "Unbekannter Schlüssel -> Warnung" "Unbekannter Konfigurationsschlüssel 'UNBEKANNT'" "$OUT"
assert_contains "Ungültige Zeile -> Warnung" "Ungültige Zeile" "$OUT"
run bash -c "export TAW_BIO_TITLE=env; source '$PREFIX/lib/termux-auth-wrapper/common.sh'; taw_load_config; echo \$TAW_BIO_TITLE"
assert_contains "Umgebungsvariable hat Vorrang" "env" "$OUT"
write_config 'BIO_TITLE="$(touch '"$ROOT"'/pwned)"'
run bash -c "source '$PREFIX/lib/termux-auth-wrapper/common.sh'; taw_load_config"
assert_no_file "Konfiguration wird nicht ausgeführt" "$ROOT/pwned"

# =============================================================================
section "ssh-Wrapper"
write_config
: >"$FP_CALLS"; : >"$MOCK_LOG"
MOCK_FP=success run ssh -p 2222 user@host.example ls -la
assert_eq "ssh -> echtes ssh mit unveränderten Argumenten" "REAL_SSH -p 2222 user@host.example ls -la" "$OUT"
assert_eq "ssh -> ein Dialog" 1 "$(fp_count)"
assert_contains "Zielangabe im Dialog" "SSH-Verbindung zu user@host.example" "$(cat "$FP_CALLS")"
: >"$MOCK_LOG"
MOCK_FP=fail run ssh host.example
assert_eq "ssh abgelehnt -> Exit 255" 255 "$RC"
assert_eq "ssh abgelehnt -> keine Verbindung" "" "$(cat "$MOCK_LOG")"
: >"$FP_CALLS"
MOCK_FP=fail run ssh -V
assert_eq "ssh -V ohne Dialog" 0 "$(fp_count)"
MOCK_FP=fail run ssh -G host
assert_eq "ssh -G ohne Dialog" 0 "$(fp_count)"
MOCK_FP=success MOCK_SSH_RC=42 run ssh host
assert_eq "ssh Exit-Code wird durchgereicht" 42 "$RC"
write_config 'SSH_SKIP_HOSTS="github.com *.lan"'
: >"$FP_CALLS"
MOCK_FP=fail run ssh git@github.com
assert_eq "SSH_SKIP_HOSTS: github.com ohne Dialog" 0 "$RC"
MOCK_FP=fail run ssh nas.lan
assert_eq "SSH_SKIP_HOSTS: Glob *.lan" 0 "$RC"
assert_eq "SSH_SKIP_HOSTS: kein Dialog" 0 "$(fp_count)"
write_config "SSH_AUTH_SCOPE=mapped"
MOCK_FP=fail run ssh unmapped.host
assert_eq "SSH_AUTH_SCOPE=mapped: nicht zugeordneter Host ohne Dialog" 0 "$RC"
write_config "SSH_ENABLED=false"
MOCK_FP=fail run ssh any.host
assert_eq "SSH_ENABLED=false -> Durchreichen" 0 "$RC"

section "ssh + Bitwarden"
cat >"$HOME/.config/termux-auth-wrapper/ssh-hosts.conf" <<'EOF'
# Kommentar
10.0.0.5          ITEMPW    password
keyhost           ITEMKEY   key
*.missing         NOPE
named             "Mein Server"  auto
EOF
write_config "BW_ENABLED=true" "BW_UNLOCK_MODE=never"
MOCK_FP=success MOCK_BW_STATUS=unlocked run ssh myalias
assert_contains "Passwort über sshpass (FD) übergeben" "SSHPASS_PW=s3cr3t pw" "$OUT"
assert_contains "Alias via ssh -G auf Hostname aufgelöst" "REAL_SSH -o NumberOfPasswordPrompts=1 myalias" "$OUT"
MOCK_FP=success MOCK_BW_STATUS=unlocked TAW_SSH_KEY_METHOD=tempfile run ssh keyhost
assert_contains "Schlüssel per -i übergeben" "KEYLINE=-----BEGIN OPENSSH PRIVATE KEY-----" "$OUT"
assert_contains "IdentitiesOnly gesetzt" "-o IdentitiesOnly=yes keyhost" "$OUT"
keyfile=$(grep -o 'KEYFILE=.*' <<<"$OUT" | cut -d= -f2)
assert_no_file "Temporärer Schlüssel wieder gelöscht" "${keyfile:-/nonexistent-but-unset}"
[[ -n $keyfile ]] || bad "Schlüsseldatei-Pfad ermittelt"
MOCK_FP=success MOCK_BW_STATUS=locked run ssh myalias
assert_contains "Gesperrter Tresor -> klare Meldung" "Bitwarden-Tresor ist gesperrt" "$OUT"
assert_contains "BW_FALLBACK=prompt -> normales ssh" "REAL_SSH myalias" "$OUT"
write_config "BW_ENABLED=true" "BW_UNLOCK_MODE=never" "BW_FALLBACK=fail"
MOCK_FP=success MOCK_BW_STATUS=locked run ssh myalias
assert_eq "BW_FALLBACK=fail -> Exit 255" 255 "$RC"
MOCK_FP=success MOCK_BW_STATUS=unauthenticated run ssh myalias
assert_contains "Nicht angemeldet -> Hinweis bw login" "bw login" "$OUT"
MOCK_FP=success MOCK_BW_STATUS=unlocked run ssh x.missing
assert_contains "Unbekanntes Item -> Fehlermeldung von bw" "Not found" "$OUT"
MOCK_FP=fail MOCK_BW_STATUS=unlocked run ssh myalias
assert_eq "Ohne Fingerabdruck kein Bitwarden-Zugriff" 255 "$RC"
assert_not_contains "Kein Passwort ohne Fingerabdruck" "s3cr3t" "$OUT"
MOCK_FP=success BW_SESSION=goodsession TAW_BW_ITEM=ITEMPW run ssh irgendwo
assert_contains "TAW_BW_ITEM überschreibt Zuordnung" "SSHPASS_PW=s3cr3t pw" "$OUT"
mv "$PREFIX/bin/bw" "$PREFIX/bin/bw.off"
MOCK_FP=success run ssh myalias
assert_contains "bw fehlt -> Installationshinweis" "npm install -g @bitwarden/cli" "$OUT"
mv "$PREFIX/bin/bw.off" "$PREFIX/bin/bw"

# =============================================================================
section "Interaktive Pfade (PTY)"
if command -v python3 >/dev/null 2>&1; then
    TTY="python3 -I $REPO/tests/tty_helper.py"
    write_config "FALLBACK_MODE=pin"
    # shellcheck disable=SC2086
    run $TTY "Neue Fallback-PIN=4711" "wiederholen=4711" -- termux-auth set-pin
    assert_eq "set-pin Exit-Code 0" 0 "$RC"
    assert_contains "set-pin speichert Hash" 'FALLBACK_PIN_HASH="sha256:' "$(cat "$HOME/.config/termux-auth-wrapper/config.conf")"
    assert_not_contains "PIN nicht im Klartext gespeichert" "4711" "$(cat "$HOME/.config/termux-auth-wrapper/config.conf")"
    # shellcheck disable=SC2086
    MOCK_FP=nohw run $TTY "Fallback-PIN=4711" -- sudo id -u
    assert_eq "PIN-Fallback mit richtiger PIN" 0 "$RC"
    assert_contains "PIN-Fallback führt Befehl aus" "$(id -u)" "$OUT"
    # shellcheck disable=SC2086
    MOCK_FP=nohw run $TTY "(1/3)=0000" "(2/3)=1111" "(3/3)=2222" -- sudo id -u
    assert_eq "PIN-Fallback mit falscher PIN -> verweigert" 1 "$RC"
    # shellcheck disable=SC2086
    MOCK_FP=fail run $TTY "Fallback-PIN=4711" -- sudo true
    assert_eq "PIN nicht angeboten bei abgelehntem Fingerabdruck" 1 "$RC"
    assert_not_contains "kein PIN-Prompt bei Ablehnung" "Fallback-PIN" "$OUT"

    write_config "BW_ENABLED=true" "BW_UNLOCK_MODE=prompt" "BW_SESSION_CACHE=true"
    : >"$MOCK_LOG"
    # shellcheck disable=SC2086
    MOCK_FP=success MOCK_BW_STATUS=locked run $TTY "Master-Passwort=master" -- ssh myalias
    assert_contains "Bitwarden interaktiv entsperrt + Passwort übergeben" "SSHPASS_PW=s3cr3t pw" "$OUT"
    assert_not_contains "Master-Passwort nicht in argv von bw" "master" "$(cat "$MOCK_LOG")"
    assert_eq "BW-Session-Cache ist 0600" 600 "$(stat -c %a "$HOME/.local/state/termux-auth-wrapper/bw-session" 2>/dev/null)"
    MOCK_FP=success MOCK_BW_STATUS=locked run ssh myalias </dev/null
    assert_contains "Gecachte BW-Session wird wiederverwendet" "SSHPASS_PW=s3cr3t pw" "$OUT"
    # shellcheck disable=SC2086
    MOCK_FP=success MOCK_BW_STATUS=locked run $TTY "Master-Passwort=falsch" -- env TAW_BW_SESSION_CACHE=false TAW_BW_FALLBACK=fail ssh myalias
    assert_contains "Falsches Master-Passwort -> Meldung" "falsches Master-Passwort" "$OUT"
    rm -f "$HOME/.local/state/termux-auth-wrapper/bw-session"
else
    printf '  (python3 nicht verfügbar – übersprungen)\n'
fi

# =============================================================================
section "Update-Sicherheit: repair"
run termux-auth repair
assert_contains "repair: alles in Ordnung" "in Ordnung" "$OUT"
# Simuliertes "pkg upgrade openssh" ohne dpkg-divert: überschreibt den Wrapper
printf '#!/usr/bin/env bash\n# fake openssh binary v2\necho "REAL_SSH_V2 $*"\n' >"$PREFIX/bin/ssh"
chmod +x "$PREFIX/bin/ssh"
run termux-auth repair --quiet
assert_contains "repair erkennt ersetzten Wrapper" "replaced" "$OUT"
assert_contains "Wrapper wiederhergestellt" "TERMUX_AUTH_WRAPPER_MARKER" "$(head -c 300 "$PREFIX/bin/ssh")"
assert_contains "Neues Original gesichert" "v2" "$(cat "$PREFIX/libexec/termux-auth-wrapper/ssh")"
write_config
MOCK_FP=success run ssh host
assert_contains "Wrapper nutzt aktualisiertes Original" "REAL_SSH_V2 host" "$OUT"
run termux-auth status
assert_contains "termux-auth status" "Abhängigkeiten" "$OUT"

# =============================================================================
section "Deinstallation"
run "$PREFIX/lib/termux-auth-wrapper/uninstall.sh" --prefix "$PREFIX" --yes
assert_eq "uninstall.sh Exit-Code 0" 0 "$RC"
assert_no_file "sudo-Wrapper entfernt" "$PREFIX/bin/sudo"
assert_contains "Original-ssh zurückgelegt" "v2" "$(cat "$PREFIX/bin/ssh" 2>/dev/null)"
assert_no_file "Bibliothek entfernt" "$PREFIX/lib/termux-auth-wrapper"
assert_no_file "apt-Hook entfernt" "$PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper"
assert_file "Konfiguration bleibt (ohne --purge)" "$HOME/.config/termux-auth-wrapper/config.conf"

# =============================================================================
section "Installation mit dpkg-divert (wie in echtem Termux)"
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
# Minimaler dpkg-divert-Mock: Datenbank "pfad|ziel"
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
assert_eq "install.sh mit dpkg" 0 "$RC"
assert_contains "ssh per dpkg-divert umgeleitet" "dpkg-divert" "$OUT"
assert_contains "Diversion eingetragen" "$PREFIX/bin/ssh|$PREFIX/libexec/termux-auth-wrapper/ssh" "$(cat "$DIVERT_DB")"
write_config
MOCK_FP=success run ssh host
assert_contains "ssh über Diversion erreichbar" "REAL_SSH host" "$OUT"
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes
assert_eq "Neuinstallation mit bestehender Diversion" 1 "$(grep -c 'bin/ssh|' "$DIVERT_DB")"
run "$REPO/uninstall.sh" --prefix "$PREFIX" --yes --purge
assert_eq "Diversion entfernt" "" "$(cat "$DIVERT_DB")"
assert_contains "Original-ssh wiederhergestellt" "fake openssh binary" "$(cat "$PREFIX/bin/ssh")"
assert_no_file "--purge entfernt Konfiguration" "$HOME/.config/termux-auth-wrapper"

# =============================================================================
section "Installation im home-Modus"
new_env home
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes --mode home
assert_eq "install.sh --mode home" 0 "$RC"
assert_file "Wrapper in ~/.bin" "$HOME/.bin/ssh"
assert_contains "Original-ssh bleibt unverändert in PREFIX/bin" "fake openssh binary" "$(cat "$PREFIX/bin/ssh")"
assert_contains "PATH-Block in ~/.bashrc" "termux-auth-wrapper" "$(cat "$HOME/.bashrc")"
assert_no_file "kein apt-Hook im home-Modus" "$PREFIX/etc/apt/apt.conf.d/99-termux-auth-wrapper"
write_config
export PATH="$HOME/.bin:$PATH"
MOCK_FP=success run ssh host
assert_contains "Wrapper findet echtes ssh über PATH" "REAL_SSH host" "$OUT"
MOCK_FP=success run sudo id -u
assert_eq "sudo im home-Modus" "$(id -u)" "$OUT"
run "$REPO/install.sh" --prefix "$PREFIX" --force --yes --mode prefix
assert_no_file "Moduswechsel entfernt ~/.bin-Wrapper" "$HOME/.bin/ssh"
assert_not_contains "Moduswechsel entfernt PATH-Block" "termux-auth-wrapper" "$(cat "$HOME/.bashrc")"
assert_file "Moduswechsel: Wrapper in PREFIX/bin" "$PREFIX/bin/sudo"

# =============================================================================
printf '\n\033[1mErgebnis: %d bestanden, %d fehlgeschlagen\033[0m\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
