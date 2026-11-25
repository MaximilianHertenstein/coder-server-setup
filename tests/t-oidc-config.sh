#!/bin/bash
# IServ-OIDC: Parser, Aktivierungslogik, Secret-Handling und Compose-Übergabe.
# Läuft ohne Server/Produktion; die Compose-Prüfung wird übersprungen, wenn
# `docker compose` lokal fehlt.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
skip() { echo "SKIP: $1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"
LIB="${REPO_ROOT}/scripts/lib/oidc-config.sh"
# shellcheck source=scripts/lib/oidc-config.sh
. "${LIB}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

SECRET="TEST-ONLY-OIDC-SECRET"
CONFIG="${WORK}/oidc.env"

write_config() {
  local file=$1 mode=$2 client_id=$3 client_secret=$4
  cat > "$file" <<EOF
OIDC_ENABLED=${mode}
CODER_OIDC_ISSUER_URL=https://ghse.de
CODER_OIDC_CLIENT_ID=${client_id}
CODER_OIDC_CLIENT_SECRET=${client_secret}
CODER_OIDC_SCOPES=openid,profile,email
CODER_OIDC_SIGN_IN_TEXT='Mit IServ anmelden'
CODER_OIDC_USERNAME_FIELD=preferred_username
CODER_OIDC_NAME_FIELD=name
CODER_OIDC_EMAIL_FIELD=email
CODER_OIDC_IGNORE_EMAIL_VERIFIED=false
CODER_OIDC_ALLOW_SIGNUPS=true
EOF
}

# --- Vorlage, Rechte, Nicht-Überschreiben ---------------------------------
if oidc_ensure_file "$CONFIG"; then
  pass "oidc_ensure_file legt die Vorlage an"
else
  fail "oidc_ensure_file: ${OIDC_ERROR}"
fi
[ "$(stat -c '%a' "$CONFIG")" = "600" ] \
  && pass "Vorlage hat Modus 600" || fail "Vorlage hat Modus $(stat -c '%a' "$CONFIG") statt 600"
grep -q "^CODER_OIDC_CLIENT_ID=''$" "$CONFIG" \
  && grep -q "^CODER_OIDC_CLIENT_SECRET=''$" "$CONFIG" \
  && pass "Vorlage enthält leere Client-ID/Secret" || fail "Vorlage enthält keine leeren Client-ID/Secret"
grep -qx '# OIDC_INTERNAL_HOST=10.0.0.1' "$CONFIG" \
  && pass "Vorlage dokumentiert OIDC_INTERNAL_HOST" || fail "OIDC_INTERNAL_HOST fehlt in der Vorlage"
if oidc_load_config "$CONFIG" && [ "$OIDC_ACTIVE" -eq 0 ]; then
  pass "Vorlage ist gültig und lässt OIDC ohne Zugangsdaten aus"
else
  fail "Vorlage ist ungültig: ${OIDC_ERROR:-unerwartet aktiv}"
fi
printf '\n# operator-marker\n' >> "$CONFIG"
oidc_ensure_file "$CONFIG" > /dev/null 2>&1
grep -q '^# operator-marker$' "$CONFIG" \
  && pass "vorhandene OIDC-Datei wird nicht überschrieben" \
  || fail "vorhandene OIDC-Datei wurde überschrieben"
chmod 644 "$CONFIG"
oidc_ensure_file "$CONFIG" > /dev/null 2>&1
[ "$(stat -c '%a' "$CONFIG")" = "600" ] \
  && pass "vorhandene Datei wird auf 600 zurückgesetzt" || fail "Modus 600 wurde nicht erzwungen"
grep -q 'chown root:root' "${LIB}" \
  && pass "Eigentümer root:root ist im Helfer gesetzt" || fail "chown root:root fehlt"

# --- Aktivierungslogik -----------------------------------------------------
write_config "$CONFIG" auto "" ""
if oidc_load_config "$CONFIG" && [ "$OIDC_ACTIVE" -eq 0 ] && [ -z "$(oidc_compose_block "$CONFIG")" ]; then
  pass "auto ohne Zugangsdaten: OIDC aus, kein Compose-env_file"
else
  fail "auto ohne Zugangsdaten: ${OIDC_ERROR:-unerwartet aktiv}"
fi
oidc_ensure_file "$CONFIG" > /dev/null 2>&1
if oidc_load_config "$CONFIG" && [ "$OIDC_ACTIVE" -eq 0 ]; then
  pass "Re-Run ohne Zugangsdaten bleibt deaktiviert"
else
  fail "Re-Run ohne Zugangsdaten wurde aktiv"
fi

write_config "$CONFIG" auto "test-client" "$SECRET"
if oidc_load_config "$CONFIG" && [ "$OIDC_ACTIVE" -eq 1 ] \
  && [ "$OIDC_ISSUER_URL" = "https://ghse.de" ] \
  && [ "$OIDC_CLIENT_ID" = "test-client" ] \
  && [ "$OIDC_CLIENT_SECRET" = "$SECRET" ] \
  && [ "$OIDC_SCOPES" = "openid,profile,email" ] \
  && [ "$OIDC_SIGN_IN_TEXT" = "Mit IServ anmelden" ] \
  && [ "$OIDC_USERNAME_FIELD" = "preferred_username" ] \
  && [ "$OIDC_NAME_FIELD" = "name" ] \
  && [ "$OIDC_EMAIL_FIELD" = "email" ] \
  && [ "$OIDC_IGNORE_EMAIL_VERIFIED" = "false" ] \
  && [ "$OIDC_ALLOW_SIGNUPS" = "true" ]; then
  pass "auto mit vollständigen Zugangsdaten: OIDC an, Claims/Scopes korrekt"
else
  fail "auto mit vollständigen Zugangsdaten: ${OIDC_ERROR:-Werte falsch}"
fi
oidc_ensure_file "$CONFIG" > /dev/null 2>&1
if oidc_load_config "$CONFIG" && [ "$OIDC_ACTIVE" -eq 1 ] && [ "$OIDC_CLIENT_SECRET" = "$SECRET" ]; then
  pass "Setup-Re-Run erhält eine vorhandene OIDC-Konfiguration"
else
  fail "Setup-Re-Run hat die OIDC-Konfiguration verändert"
fi
printf 'OIDC_INTERNAL_HOST=10.0.0.1\n' >> "$CONFIG"
if oidc_load_config "$CONFIG" && [ "$OIDC_INTERNAL_HOST" = "10.0.0.1" ]; then
  pass "OIDC_INTERNAL_HOST akzeptiert eine IPv4-Adresse"
else
  fail "OIDC_INTERNAL_HOST: ${OIDC_ERROR:-Wert nicht übernommen}"
fi
sed -i 's/^OIDC_INTERNAL_HOST=.*/OIDC_INTERNAL_HOST=10.0.0.999/' "$CONFIG"
if oidc_load_config "$CONFIG"; then
  fail "ungültige OIDC_INTERNAL_HOST wurde akzeptiert"
else
  pass "ungültige OIDC_INTERNAL_HOST wird abgelehnt"
fi
sed -i '/^OIDC_INTERNAL_HOST=/d' "$CONFIG"
oidc_load_config "$CONFIG" > /dev/null 2>&1 || fail "Fixture nach OIDC_INTERNAL_HOST-Test laedt nicht"
BLOCK=$(oidc_compose_block "$CONFIG")
case "$BLOCK" in
  *"env_file:"*"- ${CONFIG}"*) pass "Compose-Block verweist auf die Quelldatei" ;;
  *) fail "Compose-Block falsch: ${BLOCK}" ;;
esac
case "$BLOCK" in
  *"$SECRET"*) fail "Secret steht im Compose-Block" ;;
  *) pass "Compose-Block enthält kein Secret" ;;
esac

write_config "$CONFIG" false "test-client" "$SECRET"
if oidc_load_config "$CONFIG" && [ "$OIDC_ACTIVE" -eq 0 ] && [ -z "$(oidc_compose_block "$CONFIG")" ]; then
  pass "OIDC_ENABLED=false deaktiviert auch bei gesetzten Zugangsdaten"
else
  fail "OIDC_ENABLED=false: ${OIDC_ERROR:-unerwartet aktiv}"
fi

write_config "$CONFIG" true "test-client" ""
if oidc_load_config "$CONFIG"; then
  fail "OIDC_ENABLED=true ohne Secret wurde akzeptiert"
else
  case "$OIDC_ERROR" in
    *CLIENT_SECRET*) pass "true ohne Secret: klarer Fehler ohne Secret-Wert" ;;
    *) fail "true ohne Secret: unerwartete Meldung: ${OIDC_ERROR}" ;;
  esac
fi

write_config "$CONFIG" auto "test-client" ""
if oidc_load_config "$CONFIG"; then
  fail "auto mit nur Client-ID wurde akzeptiert"
else
  pass "auto mit nur einer Angabe: Fehler statt stiller Teilkonfiguration"
fi

# --- Wertprüfungen und Secret-Handling ------------------------------------
write_config "$CONFIG" auto "test-client" "$SECRET"
sed -i 's/^CODER_OIDC_SCOPES=.*/CODER_OIDC_SCOPES=openid,profile,email,groups/' "$CONFIG"
if oidc_load_config "$CONFIG"; then fail "zusätzlicher Scope wurde akzeptiert"; else pass "zusätzliche Scopes werden abgelehnt"; fi

write_config "$CONFIG" auto "test-client" "$SECRET"
sed -i 's/^CODER_OIDC_IGNORE_EMAIL_VERIFIED=.*/CODER_OIDC_IGNORE_EMAIL_VERIFIED=true/' "$CONFIG"
if oidc_load_config "$CONFIG"; then fail "ignore_email_verified=true wurde akzeptiert"; else pass "E-Mail-Verifizierung lässt sich nicht abschalten"; fi

write_config "$CONFIG" auto "test-client" "$SECRET"
printf 'CODER_OIDC_UNBEKANNT=x\n' >> "$CONFIG"
if oidc_load_config "$CONFIG"; then fail "unbekannte Option wurde akzeptiert"; else pass "unbekannte OIDC-Option wird abgelehnt"; fi

write_config "$CONFIG" auto "test-client" "$SECRET"
printf 'CODER_OIDC_CLIENT_ID=doppelt\n' >> "$CONFIG"
if oidc_load_config "$CONFIG"; then fail "doppelte Option wurde akzeptiert"; else pass "doppelte Option wird abgelehnt"; fi

write_config "$CONFIG" auto "test-client" "secret'quote"
OUT=$(oidc_load_config "$CONFIG" 2>&1 || true)
case "$OUT" in
  *"secret'quote"*) fail "Fehlermeldung enthält Secret" ;;
  *) pass "Fehlermeldung enthält kein Secret" ;;
esac

write_config "$CONFIG" auto "test-client" "$SECRET"
OUT=$(oidc_load_config "$CONFIG" 2>&1 || true)
case "$OUT" in
  *"$SECRET"*) fail "Laden gibt Secret aus" ;;
  *) pass "Laden von OIDC gibt kein Secret aus" ;;
esac

# --- Quelldatei ------------------------------------------------------------
write_config "$CONFIG" auto "test-client" "$SECRET"
grep -q "^CODER_OIDC_CLIENT_SECRET=${SECRET}$" "$CONFIG" \
  && pass "Quelldatei enthält das Secret an der erwarteten Stelle" \
  || fail "Quelldatei enthält das Secret nicht"
grep -q 'CODER_OIDC_EMAIL_DOMAIN\|CODER_OIDC_GROUP_FIELD' "$CONFIG" \
  && fail "Quelldatei setzt Domain-/Gruppenbeschränkung" \
  || pass "keine Domain- oder Gruppenbeschränkung in der Quelldatei"

# --- Statische Prüfungen am Setup -----------------------------------------
grep -qF '. "${SETUP_DIR}/scripts/lib/oidc-config.sh"' "$SETUP" \
  && pass "Setup lädt den OIDC-Helfer" || fail "Setup lädt den OIDC-Helfer nicht"
grep -qF 'oidc_ensure_file "$OIDC_ENV_FILE"' "$SETUP" \
  && pass "Setup legt die OIDC-Quelldatei an" || fail "oidc_ensure_file fehlt im Setup"
grep -qF 'oidc_load_config "$OIDC_ENV_FILE"' "$SETUP" \
  && pass "Setup prüft die OIDC-Konfiguration" || fail "oidc_load_config fehlt im Setup"
grep -qF 'oidc_compose_block "$OIDC_ENV_FILE"' "$SETUP" \
  && pass "Compose nutzt die geschützte Quelldatei direkt" || fail "Compose-block nutzt die Quelldatei nicht"
grep -qF '${OIDC_COMPOSE_BLOCK}' "$SETUP" \
  && pass "Compose-Template enthält den bedingten OIDC-Block" || fail "Compose-Block fehlt im Template"
if grep -q 'CODER_DISABLE_PASSWORD_AUTH' "$SETUP"; then
  fail "Setup deaktiviert die lokale Passwort-Anmeldung"
else
  pass "lokale Passwort-Anmeldung bleibt unangetastet"
fi
grep -qx 'oidc.env' "${REPO_ROOT}/.gitignore" \
  && pass "OIDC-Quelldatei ist in .gitignore" || fail "OIDC-Quelldatei fehlt in .gitignore"

# --- Compose-Rendering und -Validierung -----------------------------------
# Extrahiert den echten Compose-Heredoc aus setup-coder.sh, setzt Testwerte
# und prüft den coder-Service. So wird die Übergabe an Docker Compose real
# validiert, ohne das Setup oder den Server auszuführen.
render_compose() {
  local active=$1 out=$2 dir=$3
  {
    cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "${LIB}"
CODER_VERSION=v2.38.10
CADDY_VERSION=2.11
PROMETHEUS_VERSION=v3.16.0
GRAFANA_VERSION=13.3.1
NODE_EXPORTER_VERSION=v1.13.1
DOMAIN_CODER=coder.example.test
DOCKER_GID=999
OIDC_ACTIVE=${active}
OIDC_ENV_FILE="${dir}/oidc.env"
OIDC_COMPOSE_BLOCK=\$(oidc_compose_block "\$OIDC_ENV_FILE")
EOF
    awk '
      /^write_managed "\/opt\/coder\/docker-compose.yml"/ { print "cat <<EOF"; found=1; next }
      found && /^EOF$/ { print; exit }
      found { print }
    ' "$SETUP"
  } > "$dir/render.sh"
  bash "$dir/render.sh" > "$out"
}

OFF_DIR="${WORK}/compose-off"
ON_DIR="${WORK}/compose-on"
mkdir -p "$OFF_DIR" "$ON_DIR"

if render_compose 0 "$OFF_DIR/compose.yml" "$OFF_DIR"; then
  pass "Compose ohne OIDC rendert"
  if grep -q 'env_file:' "$OFF_DIR/compose.yml"; then
    fail "Compose ohne OIDC enthält env_file"
  else
    pass "Compose ohne OIDC enthält kein env_file"
  fi
else
  fail "Compose ohne OIDC rendert nicht"
fi

if render_compose 1 "$ON_DIR/compose.yml" "$ON_DIR"; then
  pass "Compose mit OIDC rendert"
  # Echte Vorlage (Kommentare, Anführungszeichen, OIDC_ENABLED) für die
  # Compose-Auflösung verwenden – so wird das ausgelieferte Format geprüft.
  oidc_ensure_file "$ON_DIR/oidc.env" > /dev/null 2>&1 || fail "OIDC-Vorlage für Compose fehlt"
  sed -i "s|^CODER_OIDC_CLIENT_ID=.*|CODER_OIDC_CLIENT_ID='test-client'|" "$ON_DIR/oidc.env"
  sed -i "s|^CODER_OIDC_CLIENT_SECRET=.*|CODER_OIDC_CLIENT_SECRET='${SECRET}'|" "$ON_DIR/oidc.env"
  if oidc_load_config "$ON_DIR/oidc.env" > /dev/null 2>&1 && [ "$OIDC_ACTIVE" -eq 1 ]; then
    pass "ausgelieferte Vorlage wird mit ausgefüllten Werten aktiv"
  else
    fail "ausgelieferte Vorlage wird mit Werten nicht aktiv: ${OIDC_ERROR:-?}"
  fi
  if grep -qF "$SECRET" "$ON_DIR/compose.yml"; then
    fail "Secret steht in der Compose-Datei"
  else
    pass "kein Secret in der Compose-Datei"
  fi
  grep -q 'env_file:' "$ON_DIR/compose.yml" \
    && pass "Compose mit OIDC hat env_file" || fail "Compose mit OIDC hat kein env_file"
else
  fail "Compose mit OIDC rendert nicht"
fi

if command -v docker > /dev/null 2>&1 && docker compose version > /dev/null 2>&1; then
  for mode in off on; do
    dir="${WORK}/compose-${mode}"
    if ( cd "$dir" && POSTGRES_PASSWORD=test GRAFANA_ADMIN_PASSWORD=test \
        docker compose -f compose.yml config --quiet > /dev/null 2>&1 ); then
      pass "docker compose config: ${mode} gültig"
    else
      fail "docker compose config: ${mode} ungültig"
    fi
  done

  OFF_JSON=$( cd "$OFF_DIR" && POSTGRES_PASSWORD=test GRAFANA_ADMIN_PASSWORD=test \
    docker compose -f compose.yml config --format json 2>/dev/null )
  ON_JSON=$( cd "$ON_DIR" && POSTGRES_PASSWORD=test GRAFANA_ADMIN_PASSWORD=test \
    docker compose -f compose.yml config --format json 2>/dev/null )

  if echo "$OFF_JSON" | jq -e '.services.coder.environment.CODER_OIDC_CLIENT_ID == null' > /dev/null; then
    pass "deaktiviert: keine OIDC-Variable im coder-Service"
  else
    fail "deaktiviert: OIDC-Variable im coder-Service"
  fi
  if echo "$ON_JSON" | jq -e --arg s "$SECRET" \
      '.services.coder.environment.CODER_OIDC_CLIENT_SECRET == $s
       and .services.coder.environment.CODER_OIDC_CLIENT_ID == "test-client"
       and .services.coder.environment.CODER_OIDC_ISSUER_URL == "https://ghse.de"
       and .services.coder.environment.CODER_OIDC_SIGN_IN_TEXT == "Mit IServ anmelden"
       and .services.coder.environment.CODER_OIDC_SCOPES == "openid,profile,email"' > /dev/null; then
    pass "aktiviert: OIDC-Werte kommen im coder-Service an"
  else
    fail "aktiviert: OIDC-Werte fehlen/falsch im coder-Service"
  fi
  if echo "$ON_JSON" | jq -e '.services.coder.environment.CODER_DISABLE_PASSWORD_AUTH == null' > /dev/null; then
    pass "aktiviert: lokale Passwort-Anmeldung nicht deaktiviert"
  else
    fail "aktiviert: CODER_DISABLE_PASSWORD_AUTH ist gesetzt"
  fi
else
  skip "docker compose fehlt – Compose-Validierung nicht ausgeführt"
fi

exit "$FAIL"
