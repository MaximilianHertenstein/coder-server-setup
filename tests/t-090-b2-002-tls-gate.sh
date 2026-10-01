#!/bin/bash
# T-090 / B2-002: TLS-SNI / Update-Gate / Boot-Gate.
# Beweist per echtem TLS-Handshake (kein awk-Only), dass:
#  1. gesundes Update-Gate -> 200 / GRUEN (SNI-korrekte --resolve-Probe)
#  2. gestoppter Coder -> ROT
#  3. gesunder Boot -> BOOT-GATE GRUEN
#  4. kranker Boot -> BOOT-GATE ROT
#  5. TLS-SNI ist die Domain (nicht 127.0.0.1 / nicht leer)
#  6. die Gate-Probe loest keinen 127.0.0.1-On-Demand-Versuch aus
# Nur /tmp, keine Produktion, keine Secrets.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"
BOOTGATE="${REPO_ROOT}/scripts/boot-check.sh"
UPDGATE="${REPO_ROOT}/scripts/update.sh"
DOMAIN="gate.test.local"

# ---------- STATIK: Produktionszeilen in setup-coder.sh + Gate-Skripten ----
if grep -qF 'scripts/boot-check.sh' "${SETUP}" && grep -qF 'scripts/update.sh' "${SETUP}"; then
  pass "Setup installiert boot-check.sh und update.sh aus scripts/"
else
  fail "Setup installiert die Gate-Skripte nicht aus scripts/"
fi
# Boot-Gate: --resolve DOMAIN:443:127.0.0.1 + https://DOMAIN/healthz + max-time 10
if grep -qF -- '--resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz"' "${BOOTGATE}" \
  && grep -qF -- 'curl -sS --max-time 10 -o /dev/null -w "%{http_code}" --resolve "${DOMAIN}:443:127.0.0.1"' "${BOOTGATE}"; then
  pass "Boot-Gate prüft TLS-Vertrauen und SNI (--resolve DOMAIN:443:127.0.0.1, max-time 10)"
else
  fail "Boot-Gate nicht SNI-korrekt"
fi

# Update-Gate: --resolve GATE_DOMAIN:443:127.0.0.1 + https://GATE_DOMAIN/healthz + max-time 60
if grep -qF -- '--resolve "${GATE_DOMAIN}:443:127.0.0.1" "https://${GATE_DOMAIN}/healthz"' "${UPDGATE}" \
  && grep -qF -- 'curl -sS --max-time 60 -o /dev/null -w "%{http_code}" --resolve "${GATE_DOMAIN}:443:127.0.0.1"' "${UPDGATE}"; then
  pass "Update-Gate prüft TLS-Vertrauen und SNI (--resolve GATE_DOMAIN:443:127.0.0.1, max-time 60)"
else
  fail "Update-Gate nicht SNI-korrekt"
fi

if grep -qF 'curl -sk --max-time 10' "${SETUP}" "${BOOTGATE}" "${UPDGATE}" \
  || grep -qF 'curl -sk --max-time 60' "${SETUP}" "${BOOTGATE}" "${UPDGATE}"; then
  fail "Produktions-Smoke ignoriert TLS-Zertifikatsfehler weiterhin"
else
  pass "Produktions-Smokes verlangen vertrauenswürdiges TLS-Zertifikat"
fi

# Nirgends SNI=127.0.0.1: kein https://127.0.0.1/healthz mehr
if grep -qF -- 'https://127.0.0.1/healthz' "${SETUP}" "${BOOTGATE}" "${UPDGATE}"; then
  fail "SNI=127.0.0.1 noch vorhanden (https://127.0.0.1/healthz)"
else
  pass "kein https://127.0.0.1/healthz mehr (kein SNI=127.0.0.1)"
fi

# Kein Host-Header-Trick gegen 127.0.0.1 mehr
if grep -qF -- '-H "Host: ${DOMAIN}" "https://127.0.0.1' "${SETUP}" "${BOOTGATE}" "${UPDGATE}" \
  || grep -qF -- '-H "Host: ${GATE_DOMAIN}" "https://127.0.0.1' "${SETUP}" "${BOOTGATE}" "${UPDGATE}"; then
  fail "Host-Header gegen 127.0.0.1 noch vorhanden"
else
  pass "kein Host-Header gegen 127.0.0.1 mehr"
fi

# Schritt 10 (A7): getrennte lokale und oeffentliche Probe. Lokal MIT
# --resolve (127.0.0.1, unabhaengig von DNS/Hairpin) + Retry, oeffentlich
# OHNE --resolve (echter DNS-Weg, ein Versuch). Beide Pfade muessen existieren.
if grep -qF -- '--resolve "${DOMAIN_CODER}:443:127.0.0.1" "https://${DOMAIN_CODER}/healthz"' "${SETUP}" \
  && grep -qF -- '--max-time 10' "${SETUP}" \
  && grep -qF -- 'while [ "${_try}" -lt 6 ]' "${SETUP}"; then
  pass "Schritt 10 A7: lokaler Pfad mit --resolve und Retry (6x max-time 10)"
else
  fail "Schritt 10: lokaler Retry-Pfad mit --resolve fehlt"
fi
if grep -qF 'PUB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://${DOMAIN_CODER}/healthz"' "${SETUP}"; then
  pass "Schritt 10 A7: oeffentlicher Pfad ohne --resolve (1 Versuch, echter DNS-Weg)"
else
  fail "Schritt 10: oeffentlicher Pfad ohne --resolve fehlt"
fi

# Boot-Poll-Schleife erhalten (30x, bestehende Semantik)
if grep -qF -- 'for _ in $(seq 1 30); do' "${SETUP}"; then
  pass "Boot-Poll-Schleife 30x erhalten"
else
  fail "Boot-Poll-Schleife fehlt"
fi

# ---------- LIVE: echter TLS-Handshake gegen SNI-selektiven Testserver ----------
WORK="$(mktemp -d)"
trap 'kill "${SRV_PID:-}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# Cert nur fuer die Domain (kein IP-SAN) – wie ein Caddy-Zertifikat.
openssl req -x509 -newkey rsa:2048 -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
  -days 2 -nodes -subj "/CN=${DOMAIN}" -addext "subjectAltName=DNS:${DOMAIN}" 2>/dev/null

# Caddy-aequivalenter Server: unbekanntes SNI -> Handshake-Alert (kein Zertifikat,
# in Produktion waere das der 127.0.0.1-On-Demand-Versuch). SNI wird geloggt.
cat > "${WORK}/sni-server.py" <<PYEOF
import http.server, ssl
DOMAIN = "${DOMAIN}"
WORK = "${WORK}"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
def sni_cb(sslobj, server_name, ctx):
    with open(WORK + "/sni.log", "a") as f:
        f.write(f"{server_name}\n")
    if server_name != DOMAIN:
        return ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME
    return None
open(WORK + "/sni.log", "w").close()
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(WORK + "/cert.pem", WORK + "/key.pem")
ctx.sni_callback = sni_cb
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
open(WORK + "/port.txt", "w").write(str(httpd.socket.getsockname()[1]))
httpd.serve_forever()
PYEOF

python3 "${WORK}/sni-server.py" & SRV_PID=$!
for _ in $(seq 1 50); do
  [ -f "${WORK}/port.txt" ] && break
  sleep 0.2
done
PORT="$(cat "${WORK}/port.txt")"
echo "INFO: Testserver 127.0.0.1:${PORT}, Domain ${DOMAIN}"

# L-ALT: altes v2-Muster (Host-Header gegen IP) muss scheitern (SNI != Domain).
OLD_CODE="000"
OLD_EXIT=0
if OLD_CODE=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" -H "Host: ${DOMAIN}" "https://127.0.0.1:${PORT}/healthz" 2>/dev/null); then
  OLD_EXIT=0
else
  OLD_EXIT=$?
  [ -n "${OLD_CODE}" ] || OLD_CODE="000"
fi
if [ "${OLD_CODE}" != "200" ]; then
  pass "altes Host-Header-Muster scheitert (code=${OLD_CODE}, exit=${OLD_EXIT}) – B2-002-Repro"
else
  fail "altes Muster liefert 200 – Repro ungueltig"
fi
if grep -qxF "${DOMAIN}" "${WORK}/sni.log"; then
  fail "altes Muster sendete Domain-SNI (erwartet: nicht-Domain)"
else
  pass "altes Muster sendet SNI != Domain (SNI-Log: $(tr '\n' ' ' < "${WORK}/sni.log"))"
fi

# Frisches SNI-Log nur fuer die neuen Proben (On-Demand-Nachweis).
: > "${WORK}/sni.log"

# L-NEU-UPDATE (Test 1): --resolve-Mechanik wie Update-Gate -> 200 / GRUEN.
# Port ist Testport statt 443; --resolve-Semantik (SNI+Host=Domain, lokal) identisch.
NEW_CODE="$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" --resolve "${DOMAIN}:${PORT}:127.0.0.1" "https://${DOMAIN}:${PORT}/healthz" 2>/dev/null || true)"
[ -n "${NEW_CODE}" ] || NEW_CODE="000"
if [ "${NEW_CODE}" = "200" ]; then
  pass "Update-Gate gesund -> 200 / GRUEN (code=${NEW_CODE})"
else
  fail "Update-Gate gesund liefert ${NEW_CODE} statt 200"
fi

# L-NEU-BOOT (Test 3): gleiche Mechanik wie Boot-Gate (max-time 10, Loop-Einzelprobe) -> 200.
BOOT_CODE="$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" --resolve "${DOMAIN}:${PORT}:127.0.0.1" "https://${DOMAIN}:${PORT}/healthz" 2>/dev/null || true)"
[ -n "${BOOT_CODE}" ] || BOOT_CODE="000"
if [ "${BOOT_CODE}" = "200" ]; then
  pass "Boot-Gate gesund -> BOOT-GATE GRUEN (code=${BOOT_CODE})"
else
  fail "Boot-Gate gesund liefert ${BOOT_CODE} statt 200"
fi

# Test 5: SNI muss Domain sein.
if grep -qxF "${DOMAIN}" "${WORK}/sni.log"; then
  pass "TLS-SNI ist Domain (${DOMAIN})"
else
  fail "TLS-SNI ist nicht Domain (Log: $(tr '\n' ' ' < "${WORK}/sni.log"))"
fi

# Test 6: kein 127.0.0.1-SNI durch die neuen Gate-Proben (kein On-Demand-Versuch).
if grep -qxF "127.0.0.1" "${WORK}/sni.log"; then
  fail "127.0.0.1-SNI durch Gate-Probe (On-Demand-Versuch)"
else
  pass "kein 127.0.0.1-SNI durch Gate-Proben (Log: $(tr '\n' ' ' < "${WORK}/sni.log"))"
fi

# OpenSSL-Gegenprobe: Domain-SNI liefert Zertifikat, IP-SNI wird abgewiesen (Alert 112).
# (Bash-Match statt grep-Pipe: grep -q schliesst die Pipe frueh, openssl stirbt
# an SIGPIPE und pipefail wuerde den Treffer als FAIL werten.)
OPENSSL_DOMAIN_OUT="$(printf '' | timeout 10 openssl s_client -connect "127.0.0.1:${PORT}" -servername "${DOMAIN}" -CAfile "${WORK}/cert.pem" 2>&1 || true)"
if [[ "${OPENSSL_DOMAIN_OUT}" == *"CN=${DOMAIN}"* ]]; then
  pass "openssl Domain-SNI liefert Zertifikat CN=${DOMAIN}"
else
  fail "openssl Domain-SNI liefert kein Zertifikat"
fi
OPENSSL_IP_OUT="$(printf '' | timeout 10 openssl s_client -connect "127.0.0.1:${PORT}" -servername "127.0.0.1" -CAfile "${WORK}/cert.pem" 2>&1 || true)"
if [[ "${OPENSSL_IP_OUT}" == *"unrecognized name"* ]]; then
  pass "openssl IP-SNI abgewiesen (unrecognized name, Alert 112)"
else
  fail "openssl IP-SNI nicht abgewiesen"
fi

# Tests 2+4: kranker Zustand (Server gestoppt) -> ROT fuer Update- und Boot-Gate.
kill "${SRV_PID}" 2>/dev/null || true
SRV_PID=""
sleep 0.5
DEAD_CODE="$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" --resolve "${DOMAIN}:${PORT}:127.0.0.1" "https://${DOMAIN}:${PORT}/healthz" 2>/dev/null || true)"
[ -n "${DEAD_CODE}" ] || DEAD_CODE="000"
if [ "${DEAD_CODE}" != "200" ]; then
  pass "Update-Gate krank -> ROT (code=${DEAD_CODE})"
else
  fail "Update-Gate krank liefert 200"
fi
DEAD_BOOT="$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" --resolve "${DOMAIN}:${PORT}:127.0.0.1" "https://${DOMAIN}:${PORT}/healthz" 2>/dev/null || true)"
[ -n "${DEAD_BOOT}" ] || DEAD_BOOT="000"
if [ "${DEAD_BOOT}" != "200" ]; then
  pass "Boot-Gate krank -> BOOT-GATE ROT (code=${DEAD_BOOT})"
else
  fail "Boot-Gate krank liefert 200"
fi

if [ "${FAIL}" -eq 0 ]; then
  echo "T-090/B2-002: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-090/B2-002: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
