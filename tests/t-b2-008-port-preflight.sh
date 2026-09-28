#!/bin/bash
# T-0xx / B2-008: Port-Preflight – keine Warn vor den eigenen Containern,
# echte Fremd-Konflikte weiterhin laut (inkl. UDP 443 und IP-Ungleichheit).
# Der ECHTE Block aus setup-coder.sh wird nach Zeilen extrahiert und mit
# Fake-docker/Fake-ss + sudo-Shim in /tmp ausgefuehrt (kein Root, keine
# Produktion).
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
mkdir -p "${BIN}"

L_START="$(grep -nF 'PORT_CHECK="80/tcp' "${SETUP}" | cut -d: -f1 || true)"
L_END="$(grep -nF 'if _avail=$(df --output=avail' "${SETUP}" | cut -d: -f1 || true)"
[ -n "${L_START}" ] && [ -n "${L_END}" ] && [ "${L_START}" -lt "${L_END}" ] \
  && pass "Blockgrenzen gefunden (Z.${L_START}..Z.$((L_END - 1)))" \
  || fail "Blockgrenzen fehlen (${L_START}/${L_END})"
BLOCK="${WORK}/block.sh"
awk -v s="${L_START}" -v e="${L_END}" 'NR>=s && NR<e {print}' "${SETUP}" > "${BLOCK}"
bash -n "${BLOCK}" && pass "extrahierter Block ist syntaktisch gueltig" || fail "Block-Syntax"

# --- Fakes ------------------------------------------------------------------
cat > "${BIN}/docker" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  compose)
    [ -f "${FAKE_DIR}/ps" ] && cat "${FAKE_DIR}/ps"
    exit 0
    ;;
  inspect)
    fmt="${3:-}"
    id="${4:-}"
    case "${fmt}" in
      '{{.Name}}')
        [ -f "${FAKE_DIR}/${id}.name" ] && sed -n '1p' "${FAKE_DIR}/${id}.name"
        ;;
      '{{.HostConfig.PortBindings}}')
        [ -f "${FAKE_DIR}/${id}.pb" ] && sed -n '1p' "${FAKE_DIR}/${id}.pb"
        ;;
      *)
        exit 1
        ;;
    esac
    exit 0
    ;;
esac
exit 1
FAKE
cat > "${BIN}/ss" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  -tlnp) printf 'tcp\n' >> "${FAKE_DIR}/ss.calls"; [ -f "${FAKE_DIR}/ss.tcp" ] && cat "${FAKE_DIR}/ss.tcp" ;;
  -ulnp) printf 'udp\n' >> "${FAKE_DIR}/ss.calls"; [ -f "${FAKE_DIR}/ss.udp" ] && cat "${FAKE_DIR}/ss.udp" ;;
  *) exit 1 ;;
esac
exit 0
FAKE
chmod +x "${BIN}/docker" "${BIN}/ss"

run_block() {  # $1=Warndatei
  local warns="$1"
  : > "${warns}"
  (
    set -euo pipefail
    export PATH="${BIN}:${PATH}"
    export FAKE_DIR="${WORK}"
    sudo() { "$@"; }
    warn() { printf 'WARN\t%s\n' "$1"; }
    # shellcheck source=/dev/null
    . "${BLOCK}"
  ) > "${warns}" 2>&1
}

reset_fixtures() {
  rm -f "${WORK}"/ps "${WORK}"/ss.tcp "${WORK}"/ss.udp "${WORK}"/ss.calls \
        "${WORK}"/*.name "${WORK}"/*.pb 2>/dev/null || true
}

WARNFILE="${WORK}/warns"

# --- (1) gesunder Re-Run: eigene Container + eigene Listener -> 0 WARN ------
reset_fixtures
printf '%s\n' c1 c2 c3 c4 c5 > "${WORK}/ps"
printf '%s\n' '/coder-caddy' > "${WORK}/c1.name"
# Reale Ausgabe von Docker 29.8.1/Go: leere HostIp wird als "invalid IP"
# gerendert, nicht als "{ 80}" (am 2026-09-28 auf dem Test-Host gemessen).
printf 'map[80/tcp:[{invalid IP 80}] 443/tcp:[{invalid IP 443}] 443/udp:[{invalid IP 443}]]' > "${WORK}/c1.pb"
printf '%s\n' '/coder-prometheus' > "${WORK}/c2.name"
printf 'map[9090/tcp:[{127.0.0.1 9090}]]' > "${WORK}/c2.pb"
printf '%s\n' '/coder-node-exporter' > "${WORK}/c3.name"
printf 'map[9100/tcp:[{127.0.0.1 9100}]]' > "${WORK}/c3.pb"
printf '%s\n' '/coder-grafana' > "${WORK}/c4.name"
printf 'map[3001/tcp:[{127.0.0.1 3001}]]' > "${WORK}/c4.pb"
printf '%s\n' '/coder' > "${WORK}/c5.name"
printf 'map[]' > "${WORK}/c5.pb"
cat > "${WORK}/ss.tcp" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      511        0.0.0.0:80        0.0.0.0:*    users:(("docker-proxy",pid=100,fd=4))
LISTEN 0      511              *:80              *:*    users:(("docker-proxy",pid=100,fd=5))
LISTEN 0      511        0.0.0.0:443       0.0.0.0:*    users:(("docker-proxy",pid=100,fd=6))
LISTEN 0      511              *:443             *:*    users:(("docker-proxy",pid=100,fd=7))
LISTEN 0      4096   127.0.0.1:9090        0.0.0.0:*    users:(("prometheus",pid=200,fd=3))
LISTEN 0      4096   127.0.0.1:9100        0.0.0.0:*    users:(("node_exporter",pid=201,fd=3))
LISTEN 0      4096   127.0.0.1:3001        0.0.0.0:*    users:(("grafana",pid=202,fd=3))
LISTEN 0      128        0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=300,fd=3))
LISTEN 0      128   127.0.0.1:631          0.0.0.0:*    users:(("cupsd",pid=301,fd=3))
EOF
cat > "${WORK}/ss.udp" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
UNCONN 0      0        0.0.0.0:443        0.0.0.0:*    users:(("docker-proxy",pid=100,fd=8))
UNCONN 0      0              *:443             *:*    users:(("docker-proxy",pid=100,fd=9))
EOF
RC=0; run_block "${WARNFILE}" || RC=$?
[ "${RC}" -eq 0 ] && pass "(1) gesunder Re-Run: Block endet mit rc 0" || fail "(1) rc=${RC}: $(cat "${WARNFILE}")"
N="$(grep -c '^WARN' "${WARNFILE}" || true)"
[ "${N}" -eq 0 ] && pass "(1) gesunder Re-Run: keine Port-WARN (0 statt frueher 5)" \
  || fail "(1) unerwartete WARN: $(cat "${WARNFILE}")"
grep -qE '^(tcp|udp)$' "${WORK}/ss.calls" && pass "(1) ss wurde aufgerufen" || fail "(1) ss nicht aufgerufen"
grep -qx 'udp' "${WORK}/ss.calls" && pass "(1) ss -ulnp wird aufgerufen (UDP-Teil existiert)" \
  || fail "(1) ss -ulnp fehlt"
grep -qx 'tcp' "${WORK}/ss.calls" && pass "(1) ss -tlnp wird aufgerufen" || fail "(1) ss -tlnp fehlt"

# --- (1b) Legacy-Render "{ 80}" (andere Docker-/Go-Versionen) -> ebenfalls 0 WARN
printf 'map[80/tcp:[{ 80}] 443/tcp:[{ 443}] 443/udp:[{ 443}]]' > "${WORK}/c1.pb"
RC=0; run_block "${WARNFILE}" || RC=$?
[ "${RC}" -eq 0 ] && pass "(1b) Legacy-Format '{ 80}': rc 0" || fail "(1b) rc=${RC}: $(cat "${WARNFILE}")"
N="$(grep -c '^WARN' "${WARNFILE}" || true)"
[ "${N}" -eq 0 ] && pass "(1b) Legacy-Format '{ 80}': keine Port-WARN" \
  || fail "(1b) unerwartete WARN: $(cat "${WARNFILE}")"
printf 'map[80/tcp:[{invalid IP 80}] 443/tcp:[{invalid IP 443}] 443/udp:[{invalid IP 443}]]' > "${WORK}/c1.pb"

# --- (2) Fremd-Listener auf 80/tcp, keine eigenen Container -> WARN mit Name
reset_fixtures
cat > "${WORK}/ss.tcp" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      511        0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=400,fd=6))
EOF
RC=0; run_block "${WARNFILE}" || RC=$?
[ "${RC}" -eq 0 ] && pass "(2) Fremd-80: rc 0" || fail "(2) rc=${RC}"
N="$(grep -c '^WARN' "${WARNFILE}" || true)"
[ "${N}" -eq 1 ] && pass "(2) Fremd-80: genau eine WARN" || fail "(2) WARN-Anzahl=${N}: $(cat "${WARNFILE}")"
grep -q 'nginx' "${WARNFILE}" && pass "(2) Fremd-80: Prozessname genannt" || fail "(2) Prozessname fehlt"
grep -q '80/tcp' "${WARNFILE}" && pass "(2) Fremd-80: Port/Proto genannt" || fail "(2) Port/Proto fehlt"

# --- (3) Port gleich, IP ungleich auf 9090 -> WARN --------------------------
reset_fixtures
printf '%s\n' c1 > "${WORK}/ps"
printf '%s\n' '/coder-prometheus' > "${WORK}/c1.name"
printf 'map[9090/tcp:[{127.0.0.1 9090}]]' > "${WORK}/c1.pb"
cat > "${WORK}/ss.tcp" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:9090       0.0.0.0:*    users:(("prometheus",pid=200,fd=3))
LISTEN 0      4096   0.0.0.0:9090         0.0.0.0:*    users:(("rogue",pid=401,fd=3))
EOF
RC=0; run_block "${WARNFILE}" || RC=$?
N="$(grep -c '^WARN' "${WARNFILE}" || true)"
[ "${N}" -eq 1 ] && pass "(3) 9090 Port gleich/IP ungleich: genau eine WARN" || fail "(3) WARN=${N}: $(cat "${WARNFILE}")"
grep -q 'rogue' "${WARNFILE}" && pass "(3) fremder Prozess genannt" || fail "(3) Prozessname fehlt"
grep -q 'prometheus' "${WARNFILE}" && fail "(3) eigener Listener darf nicht warnen" \
  || pass "(3) eigener Loopback-Listener unterdrueckt"

# --- (4) fremder UDP-Listener auf 443 -> WARN (nur ueber ss -ulnp sichtbar)
reset_fixtures
cat > "${WORK}/ss.udp" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
UNCONN 0      0        0.0.0.0:443        0.0.0.0:*    users:(("quicd",pid=402,fd=7))
EOF
RC=0; run_block "${WARNFILE}" || RC=$?
N="$(grep -c '^WARN' "${WARNFILE}" || true)"
[ "${N}" -eq 1 ] && pass "(4) Fremd-UDP-443: eine WARN" || fail "(4) WARN=${N}: $(cat "${WARNFILE}")"
grep -q '443/udp' "${WARNFILE}" && pass "(4) als 443/udp gemeldet" || fail "(4) Proto fehlt"
grep -q 'quicd' "${WARNFILE}" && pass "(4) Prozessname genannt" || fail "(4) Prozessname fehlt"

# --- (5) Container ohne coder- Praefix wird NICHT als eigen gewertet --------
reset_fixtures
printf '%s\n' c5 > "${WORK}/ps"
printf '%s\n' '/coder' > "${WORK}/c5.name"
printf 'map[80/tcp:[{ 80}]]' > "${WORK}/c5.pb"
cat > "${WORK}/ss.tcp" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      511        0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=400,fd=6))
EOF
RC=0; run_block "${WARNFILE}" || RC=$?
N="$(grep -c '^WARN' "${WARNFILE}" || true)"
[ "${N}" -eq 1 ] && pass "(5) Container 'coder' ohne Praefix wird ignoriert (WARN bleibt)" \
  || fail "(5) WARN=${N}: $(cat "${WARNFILE}")"

# --- (6) nicht gepruefter Port -> keine WARN --------------------------------
reset_fixtures
cat > "${WORK}/ss.tcp" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      128        0.0.0.0:9999      0.0.0.0:*    users:(("weird",pid=403,fd=3))
EOF
RC=0; run_block "${WARNFILE}" || RC=$?
N="$(grep -c '^WARN' "${WARNFILE}" || true)"
[ "${N}" -eq 0 ] && pass "(6) Port 9999 nicht geprueft: keine WARN" || fail "(6) WARN=${N}: $(cat "${WARNFILE}")"

# --- (7) Struktur -----------------------------------------------------------
grep -qF 'PORT_CHECK="80/tcp 443/tcp 443/udp 9090/tcp 9100/tcp 3001/tcp"' "${SETUP}" \
  && pass "PORT_CHECK vollstaendig (alle 6 Paare)" || fail "PORT_CHECK unvollstaendig"
grep -qF 'sudo ss -tlnp' "${SETUP}" && pass "TCP-Vorpruefung per ss -tlnp" || fail "ss -tlnp fehlt"
grep -qF 'sudo ss -ulnp' "${SETUP}" && pass "UDP-Vorpruefung per ss -ulnp" || fail "ss -ulnp fehlt"
grep -qF "docker inspect --format '{{.HostConfig.PortBindings}}'" "${SETUP}" \
  && pass "eigene Bindings aus HostConfig.PortBindings" || fail "PortBindings-Inspect fehlt"
grep -qF 'docker compose ps -q' "${SETUP}" && pass "Projekt-Container via docker compose ps -q" \
  || fail "compose ps -q fehlt"
if grep -qF 'grep -Eq ":${_p}([^0-9]|$)"' "${SETUP}"; then
  fail "alter roher ss-Match ist noch im Code"
else
  pass "alter roher ss-Match ist entfernt"
fi
grep -qF 'grep -qxF -- "${_pr}|${_ip}|${_port}"' "${SETUP}" \
  && pass "Vergleich ist exakte IP:Port:Proto-Zeile" || fail "exakter Vergleich fehlt"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-008: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-008: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
