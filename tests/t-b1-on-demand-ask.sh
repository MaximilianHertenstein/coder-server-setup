#!/bin/bash
# shellcheck disable=SC2034  # Variablen hier gehen in render.sh/eval ein.
# T-B1: On-Demand-TLS + lokaler ask-Endpunkt (B1/C4).
#   1. Der ECHTE Caddyfile-Heredoc aus setup-coder.sh wird gerendert (Domain
#      "coder.test", RFC-6761-reserviert -> kein echter ACME-Treffer).
#   2. Struktur: Apex OHNE on_demand, Wildcard MIT on_demand, ask-URL korrekt,
#      kein Platzhalter-Domain-Rest, ask-Server auf :9123.
#   3. Verhalten des Musters (DomainCoderRegex) gegen die dokumentierten
#      Coder-Subdomain-Formen aus coderd/workspaceapps/appurl/appurl.go.
#   4. Wenn lokal ein caddy-Image liegt (kein Pull): caddy validate +
#      caddy adapt (Apex-Policy ohne on_demand) und ein echter Live-Check des
#      ask-Endpunkts. Alles ohne Netz, ohne Produktion.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

DOMAIN_CODER="coder.test"
ACME_EMAIL="admin@example.test"
ACME_CA=""

# --- 1. Heredoc extrahieren und rendern -------------------------------------
# A2: die Write-Zeile traegt optional den Validierer validate_caddyfile vor <<EOF.
L_START="$(grep -nF 'write_managed "/opt/coder/caddy/Caddyfile" 644 "Caddyfile"' "${SETUP}" | cut -d: -f1 || true)"
if [ -n "${L_START}" ]; then
  L_END="$(awk -v s="${L_START}" 'NR>s && $0=="EOF" {print NR; exit}' "${SETUP}" || true)"
else
  L_END=""
fi
if [ -n "${L_START}" ] && [ -n "${L_END}" ]; then
  pass "Caddyfile-Heredoc gefunden (Z.${L_START}..Z.${L_END})"
else
  fail "Caddyfile-Heredoc fehlt (${L_START}/${L_END})"
fi
awk -v s="${L_START}" -v e="${L_END}" 'NR>s && NR<e' "${SETUP}" > "${WORK}/caddybody"

{
  echo 'DOMAIN_CODER="coder.test"'
  echo 'ACME_EMAIL="admin@example.test"'
  echo 'ACME_CA="${ACME_CA:-}"'
  # Definitionszeilen exakt wie in setup-coder.sh (inkl. Reihenfolge);
  # CADDY_ACME_LINE liefert die acme_ca-/email-Zeilen des globalen Blocks
  # (caddy-fmt-Fix, Tabs + keine Leerzeile bei leerem ACME_CA).
  grep -E '^DOMAIN_CODER_(ESC|REGEX)=' "${SETUP}" || true
  grep -E '^CADDY_ACME_LINE=' "${SETUP}" || true
  echo 'cat <<EOF'
  cat "${WORK}/caddybody"
  echo 'EOF'
} > "${WORK}/render.sh"
bash -n "${WORK}/render.sh" && pass "Render-Skript syntaktisch gueltig" || fail "Render-Skript defekt"
bash "${WORK}/render.sh" > "${WORK}/Caddyfile" 2> "${WORK}/render.err" \
  && pass "Caddyfile gerendert" \
  || fail "Rendern fehlgeschlagen: $(cat "${WORK}/render.err")"

CF="${WORK}/Caddyfile"
grep -qF "DOMAIN_CODER_REGEX=" "${SETUP}" && pass "DOMAIN_CODER_REGEX definiert" || fail "DOMAIN_CODER_REGEX fehlt"
# Ausfuehrbare Fassung fuer die Muster-Pruefungen unten.
DOMAIN_CODER_ESC=""
DOMAIN_CODER_REGEX=""
eval "$(grep -E '^DOMAIN_CODER_(ESC|REGEX)=' "${SETUP}")"
[ -n "${DOMAIN_CODER_REGEX}" ] || fail "DOMAIN_CODER_REGEX leer nach eval"

# --- 2. Struktur -------------------------------------------------------------
grep -qF 'permission http http://127.0.0.1:9123/ask' "${CF}" \
  && pass "HTTP-Permission-Modul nutzt den lokalen :9123-Endpunkt" || fail "HTTP-Permission-URL fehlt/falsch"
grep -qF 'ask http ' "${CF}" \
  && fail "deprecated Caddy ask-Option steht noch in der Caddyfile" || pass "deprecated Caddy ask-Option entfernt"
grep -qF 'example.com' "${CF}" && fail "Platzhaler example.com steht noch in der Caddyfile" \
  || pass "kein example.com-Rest (alter ask-Platzhaler weg)"
grep -qF ':9123 {' "${CF}" && pass "ask-Server existiert (:9123)" || fail "ask-Server :9123 fehlt"
grep -qF 'on_demand_tls {' "${CF}" && pass "globale on_demand_tls-Direktive vorhanden" || fail "on_demand_tls fehlt"

# Apex-Block: Zeilen von "<domain> {" bis zur naechsten "}" auf Spalte 1.
apex_block() { awk -v d="${DOMAIN_CODER}" '$0 == d" {" {f=1; next} f && $0=="}" {exit} f {print}' "${CF}"; }
wild_block()  { awk -v d="${DOMAIN_CODER}" '$0 == "*."d" {" {f=1; next} f && $0=="}" {exit} f {print}' "${CF}"; }
APEX="$(apex_block)"
WILD="$(wild_block)"
[ -n "${APEX}" ] && pass "Apex-Block gefunden" || fail "Apex-Block fehlt"
[ -n "${WILD}" ] && pass "Wildcard-Block gefunden" || fail "Wildcard-Block fehlt"
printf '%s\n' "${APEX}" | grep -qF 'on_demand' \
  && fail "Apex hat on_demand (muss ohne, Budget-Schutz)" || pass "Apex OHNE on_demand"
printf '%s\n' "${WILD}" | grep -qF 'on_demand' \
  && pass "Wildcard MIT on_demand" || fail "Wildcard ohne on_demand"
# ACME-E-Mail liegt als globale Option im Header-Block statt pro Site in
# "issuer acme { }".
grep -qF 'email admin@example.test' "${CF}" \
  && pass "ACME-E-Mail als globale Option" || fail "globale email-Option fehlt"
grep -qF 'issuer acme' "${CF}" \
  && fail "issuer acme steht noch in der Caddyfile (Email gehört global)" \
  || pass "kein issuer acme mehr in der Caddyfile"

# --- 3. Muster-Verhalten (grep -E als POSIX-ERE-Proxy fuer CEL/RE2) ---------
re_match() { printf '%s\n' "$1" | grep -Eq "${DOMAIN_CODER_REGEX}"; }
POSITIVE='8080--main--myworkspace--john.coder.test
33295s--agent--workspace--user--apps.coder.test
8000--dev--user.coder.test
node-react-app--myworkspace--john.coder.test'
while IFS= read -r h; do
  [ -n "${h}" ] || continue
  if re_match "${h}"; then pass "Muster erlaubt: ${h}"; else fail "Muster lehnt ab: ${h}"; fi
done <<< "${POSITIVE}"
NEGATIVE='evil.coder.test
coder.test
a.b.coder.test
8080--main--ws--user.evil.test
8080--main--ws--user
--x--y.coder.test
8080----main--ws--u.coder.test
8080--main--myws--john.coder.test.evil.com'
while IFS= read -r h; do
  [ -n "${h}" ] || continue
  if re_match "${h}"; then fail "Muster erlaubt zuviel: ${h}"; else pass "Muster verweigert: ${h}"; fi
done <<< "${NEGATIVE}"

# --- 4. Optional: echtes caddy (nur wenn lokal vorhanden, kein Pull) --------
IMG=""
if command -v docker > /dev/null 2>&1; then
  IMG="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^caddy:' | head -n 1 || true)"
fi
if [ -z "${IMG}" ]; then
  echo "SKIP: kein lokales caddy-Image – validate/adapt/Live-Check entfaellt"
elif ! docker info > /dev/null 2>&1; then
  echo "SKIP: Docker-Daemon nicht erreichbar – validate/adapt/Live-Check entfaellt"
else
  chmod 644 "${CF}"
  if docker run --rm -v "${WORK}:/t:ro,z" "${IMG}" caddy validate --config /t/Caddyfile > "${WORK}/validate.log" 2>&1; then
    pass "caddy validate gruen (${IMG})"
  else
    fail "caddy validate rot: $(tail -n 3 "${WORK}/validate.log")"
  fi
  if docker run --rm -v "${WORK}:/t:ro,z" "${IMG}" caddy adapt --config /t/Caddyfile --pretty \
      > "${WORK}/adapted.json" 2> "${WORK}/adapt.err"; then
    if command -v python3 > /dev/null 2>&1; then
      if python3 - "${WORK}/adapted.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pols = d.get("apps", {}).get("tls", {}).get("automation", {}).get("policies", [])
wild = [p for p in pols if p.get("subjects") == ["*.coder.test"]]
assert wild, "Wildcard-Policy fehlt"
assert wild[0].get("on_demand") is True, "Wildcard-Policy ohne on_demand"
# Apex braucht keine eigene Subject-Policy (globale email-
# Option); zählt hat nur, dass ausserhalb der Wildcard keine Policy
# on_demand trägt (Budget-Schutz).
for p in pols:
    if p is not wild[0]:
        assert not p.get("on_demand"), f"undogene on_demand-Policy: {p}"
assert "admin@example.test" in json.dumps(d), "globale ACME-E-Mail fehlt im adapt-JSON"
od = d.get("apps", {}).get("tls", {}).get("automation", {}).get("on_demand", {})
assert od.get("permission", {}).get("endpoint") == "http://127.0.0.1:9123/ask", od
PY
      then
        pass "caddy adapt: Wildcard mit on_demand, Rest ohne, globale email, ask-URL gesetzt"
      else
        fail "caddy adapt: Policy-Struktur weicht ab ($(python3 -c 'import json,sys' 2>/dev/null; echo details siehe adapted.json))"
      fi
    else
      echo "SKIP: python3 fehlt – Policy-Struktur nicht geprueft"
    fi
  else
    fail "caddy adapt fehlgeschlagen: $(tail -n 2 "${WORK}/adapt.err")"
  fi

  # Live: ask-Endpunkt antwortet 200/404 korrekt. Der Container bekommt einen
  # zufaelligen Host-Port, damit ein belegter 9123 den Test nicht bricht.
  CNAME="cb1ask$$"
  docker rm -f "${CNAME}" > /dev/null 2>&1 || true
  if docker run -d --name "${CNAME}" -p 127.0.0.1::9123 -v "${CF}:/etc/caddy/Caddyfile:ro,z" "${IMG}" > /dev/null 2>&1; then
    HOSTPORT=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      HOSTPORT="$(docker port "${CNAME}" 9123/tcp 2>/dev/null | head -n 1 | sed 's/.*://')"
      [ -n "${HOSTPORT}" ] && break
      sleep 1
    done
    if [ -n "${HOSTPORT}" ]; then
      # Auf den Ask-Endpunkt warten: der Docker-Port-Mapping steht sofort,
      # Caddy hoert danach – ohne Wartezeit sind die ersten Aufrufe 000.
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${HOSTPORT}/ask?domain=x--y--z.coder.test" || true)"
        [ "${_c}" = "404" ] && break
        sleep 1
      done
      ask() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HOSTPORT}/ask?domain=$1" || true; }
      [ "$(ask '8080--main--myworkspace--john.coder.test')" = "200" ] \
        && pass "Live ask: dokumentierte App-Form -> 200" || fail "Live ask: App-Form nicht 200"
      [ "$(ask 'evil.coder.test')" = "404" ] \
        && pass "Live ask: evil -> 404" || fail "Live ask: evil nicht 404"
      [ "$(ask 'coder.test')" = "404" ] \
        && pass "Live ask: Apex -> 404" || fail "Live ask: Apex nicht 404"
      [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HOSTPORT}/x?domain=8080--main--ws--u.coder.test" || true)" = "404" ] \
        && pass "Live ask: falscher Pfad -> 404" || fail "Live ask: falscher Pfad nicht 404"
    else
      fail "Live ask: kein Host-Port ermittelbar"
    fi
    docker rm -f "${CNAME}" > /dev/null 2>&1 || true
  else
    fail "Live ask: Container ließ sich nicht starten"
  fi
fi

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B1: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B1: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
