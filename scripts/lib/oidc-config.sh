#!/usr/bin/env bash
# shellcheck disable=SC2034  # Globals (OIDC_*) werden vom Aufrufer gelesen.
# IServ-OIDC-Konfiguration für setup-coder.sh.
#
# Diese Datei wird gesourct und definiert nur Funktionen. Sie gibt niemals
# Secret-Werte aus und schreibt selbst keine Dateien außer der Vorlage in
# oidc_ensure_file().
#
# Quelle: /opt/coder/oidc.env (root:root, 0600) – wird nie überschrieben.
# Bei aktivem OIDC bindet Compose genau diese Datei als env_file ein.

OIDC_CONFIG_ALLOWED_KEYS=(
  OIDC_ENABLED
  OIDC_INTERNAL_HOST
  CODER_OIDC_ISSUER_URL
  CODER_OIDC_CLIENT_ID
  CODER_OIDC_CLIENT_SECRET
  CODER_OIDC_SCOPES
  CODER_OIDC_SIGN_IN_TEXT
  CODER_OIDC_USERNAME_FIELD
  CODER_OIDC_NAME_FIELD
  CODER_OIDC_EMAIL_FIELD
  CODER_OIDC_IGNORE_EMAIL_VERIFIED
  CODER_OIDC_ALLOW_SIGNUPS
)

oidc_key_allowed() {
  local key
  for key in "${OIDC_CONFIG_ALLOWED_KEYS[@]}"; do
    [ "$key" = "$1" ] && return 0
  done
  return 1
}

oidc_trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

oidc_is_ipv4() {
  local ip=$1 a b c d o
  case "$ip" in
    *[!0-9.]*|'') return 1 ;;
  esac
  IFS=. read -r a b c d <<< "$ip"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] || return 1
  for o in "$a" "$b" "$c" "$d"; do
    [ "$o" -ge 0 ] 2> /dev/null && [ "$o" -le 255 ] 2> /dev/null || return 1
  done
  return 0
}

oidc_read_value() {
  local file=$1 wanted=$2 line key value
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key=$(oidc_trim "${line%%=*}")
    [ "$key" = "$wanted" ] || continue
    value=$(oidc_trim "${line#*=}")
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    printf '%s' "$value"
    return 0
  done < "$file"
  return 0
}

# Prüft nur Struktur und Schlüsselnamen, nicht die Werte. Fehlermeldungen
# nennen niemals Werte, nur Zeilennummer und Schlüssel.
oidc_validate_config() {
  local file=$1 line key lineno=0 seen=" "
  OIDC_ERROR=""
  if [ ! -f "$file" ]; then
    OIDC_ERROR="OIDC-Konfigurationsdatei fehlt: $file"
    return 1
  fi
  if [ ! -r "$file" ]; then
    OIDC_ERROR="OIDC-Konfigurationsdatei ist nicht lesbar: $file"
    return 1
  fi
  if [ "$(LC_ALL=C tr -d -c '\000' < "$file" | wc -c)" -ne 0 ]; then
    OIDC_ERROR="OIDC-Konfigurationsdatei enthält NUL-Bytes."
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if [[ ! "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]]; then
      OIDC_ERROR="Zeile $lineno: erwartet KEY=VALUE."
      return 1
    fi
    key=$(oidc_trim "${line%%=*}")
    if ! oidc_key_allowed "$key"; then
      OIDC_ERROR="Zeile $lineno: nicht unterstützte Option: $key"
      return 1
    fi
    case "$seen" in
      *" $key "*)
        OIDC_ERROR="Zeile $lineno: doppelte Option: $key"
        return 1
        ;;
    esac
    seen="$seen$key "
  done < "$file"
  return 0
}

# Liest und prüft die Werte. Setzt bei Erfolg OIDC_ACTIVE=0/1 und die
# OIDC_*-Variablen; bei Fehlern OIDC_ERROR (ohne Werte) und Rückgabe 1.
oidc_load_config() {
  local file=$1 mode issuer client_id client_secret scopes sign_in
  local username_field name_field email_field ignore_verified allow_signups
  local internal_host

  OIDC_ACTIVE=0
  OIDC_MODE=auto
  OIDC_INTERNAL_HOST=""
  OIDC_ISSUER_URL=""
  OIDC_CLIENT_ID=""
  OIDC_CLIENT_SECRET=""
  OIDC_SCOPES="openid,profile,email"
  OIDC_SIGN_IN_TEXT="Mit IServ anmelden"
  OIDC_USERNAME_FIELD="preferred_username"
  OIDC_NAME_FIELD="name"
  OIDC_EMAIL_FIELD="email"
  OIDC_IGNORE_EMAIL_VERIFIED="false"
  OIDC_ALLOW_SIGNUPS="true"
  OIDC_ERROR=""

  oidc_validate_config "$file" || return 1

  mode=$(oidc_read_value "$file" OIDC_ENABLED)
  mode=${mode,,}
  [ -n "$mode" ] || mode=auto
  issuer=$(oidc_read_value "$file" CODER_OIDC_ISSUER_URL)
  client_id=$(oidc_read_value "$file" CODER_OIDC_CLIENT_ID)
  client_secret=$(oidc_read_value "$file" CODER_OIDC_CLIENT_SECRET)
  internal_host=$(oidc_read_value "$file" OIDC_INTERNAL_HOST)
  if [ -n "$internal_host" ] && ! oidc_is_ipv4 "$internal_host"; then
    OIDC_ERROR="OIDC_INTERNAL_HOST muss eine IPv4-Adresse sein (z. B. 10.0.0.1)."
    return 1
  fi
  OIDC_INTERNAL_HOST=$internal_host

  case "$mode" in
    auto)
      OIDC_MODE=auto
      if [ -n "$client_id" ] && [ -n "$client_secret" ]; then
        OIDC_ACTIVE=1
      elif [ -z "$client_id" ] && [ -z "$client_secret" ]; then
        OIDC_ACTIVE=0
      else
        OIDC_ERROR="OIDC_ENABLED=auto: Client-ID und Secret müssen gemeinsam gesetzt oder leer sein."
        return 1
      fi
      ;;
    true|yes|on|1)
      OIDC_MODE=true
      OIDC_ACTIVE=1
      ;;
    false|no|off|0)
      OIDC_MODE=false
      OIDC_ACTIVE=0
      ;;
    *)
      OIDC_ERROR="OIDC_ENABLED muss auto, true oder false sein."
      return 1
      ;;
  esac

  if [ "$OIDC_ACTIVE" -eq 0 ]; then
    return 0
  fi

  [ -n "$issuer" ] || { OIDC_ERROR="CODER_OIDC_ISSUER_URL fehlt."; return 1; }
  [ -n "$client_id" ] || { OIDC_ERROR="CODER_OIDC_CLIENT_ID fehlt."; return 1; }
  [ -n "$client_secret" ] || { OIDC_ERROR="CODER_OIDC_CLIENT_SECRET fehlt."; return 1; }
  case "$issuer" in
    https://*) ;;
    *) OIDC_ERROR="CODER_OIDC_ISSUER_URL muss mit https:// beginnen."; return 1 ;;
  esac
  case "$issuer" in
    */) OIDC_ERROR="CODER_OIDC_ISSUER_URL ohne abschließenden Schrägstrich eintragen."; return 1 ;;
  esac
  case "$issuer" in
    *[[:space:]]*) OIDC_ERROR="CODER_OIDC_ISSUER_URL darf keine Leerzeichen enthalten."; return 1 ;;
  esac

  scopes=$(oidc_read_value "$file" CODER_OIDC_SCOPES)
  [ -n "$scopes" ] || scopes="openid,profile,email"
  if [ "$scopes" != "openid,profile,email" ]; then
    OIDC_ERROR="CODER_OIDC_SCOPES muss exakt 'openid,profile,email' sein."
    return 1
  fi

  sign_in=$(oidc_read_value "$file" CODER_OIDC_SIGN_IN_TEXT)
  [ -n "$sign_in" ] || sign_in="Mit IServ anmelden"

  username_field=$(oidc_read_value "$file" CODER_OIDC_USERNAME_FIELD)
  [ -n "$username_field" ] || username_field="preferred_username"
  name_field=$(oidc_read_value "$file" CODER_OIDC_NAME_FIELD)
  [ -n "$name_field" ] || name_field="name"
  email_field=$(oidc_read_value "$file" CODER_OIDC_EMAIL_FIELD)
  [ -n "$email_field" ] || email_field="email"

  if [[ ! "$username_field" =~ ^[A-Za-z0-9_.:-]+$ ]] \
    || [[ ! "$name_field" =~ ^[A-Za-z0-9_.:-]+$ ]] \
    || [[ ! "$email_field" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    OIDC_ERROR="CODER_OIDC_USERNAME_FIELD, CODER_OIDC_NAME_FIELD und CODER_OIDC_EMAIL_FIELD müssen gültige Claim-Namen sein."
    return 1
  fi

  ignore_verified=$(oidc_read_value "$file" CODER_OIDC_IGNORE_EMAIL_VERIFIED)
  ignore_verified=${ignore_verified,,}
  [ -n "$ignore_verified" ] || ignore_verified=false
  if [ "$ignore_verified" != "false" ]; then
    OIDC_ERROR="CODER_OIDC_IGNORE_EMAIL_VERIFIED muss false bleiben (E-Mail-Verifizierung erzwingen)."
    return 1
  fi

  allow_signups=$(oidc_read_value "$file" CODER_OIDC_ALLOW_SIGNUPS)
  allow_signups=${allow_signups,,}
  [ -n "$allow_signups" ] || allow_signups=true
  case "$allow_signups" in
    true|false) ;;
    *) OIDC_ERROR="CODER_OIDC_ALLOW_SIGNUPS muss true oder false sein."; return 1 ;;
  esac

  # Die Laufzeitdatei schreibt Werte in einfachen Anführungszeichen; ein
  # einfaches Anführungszeichen im Wert würde sie zerlegen.
  case "$issuer$client_id$client_secret$scopes$sign_in$username_field$name_field$email_field" in
    *"'"*)
      OIDC_ERROR="OIDC-Werte dürfen kein einfaches Anführungszeichen enthalten."
      return 1
      ;;
  esac

  OIDC_ISSUER_URL=$issuer
  OIDC_CLIENT_ID=$client_id
  OIDC_CLIENT_SECRET=$client_secret
  OIDC_SCOPES=$scopes
  OIDC_SIGN_IN_TEXT=$sign_in
  OIDC_USERNAME_FIELD=$username_field
  OIDC_NAME_FIELD=$name_field
  OIDC_EMAIL_FIELD=$email_field
  OIDC_IGNORE_EMAIL_VERIFIED=$ignore_verified
  OIDC_ALLOW_SIGNUPS=$allow_signups
  return 0
}

# Compose-YAML für den coder-Service; leer, solange OIDC aus ist.
oidc_compose_block() {
  local env_file=$1
  [ "${OIDC_ACTIVE:-0}" -eq 1 ] || return 0
  printf '    env_file:\n      - %s' "$env_file"
}

oidc_ensure_file() {
  local file=$1 tmp
  OIDC_ERROR=""

  if [ -L "$file" ]; then
    OIDC_ERROR="$file ist ein symbolischer Link; erwartet wird eine reguläre Datei."
    return 1
  fi
  if [ -e "$file" ] && [ ! -f "$file" ]; then
    OIDC_ERROR="$file ist keine reguläre Datei."
    return 1
  fi

  if [ ! -e "$file" ]; then
    tmp=$(mktemp "${file}.tmp.XXXXXX") || {
      OIDC_ERROR="Temporäre Datei für $file konnte nicht angelegt werden."
      return 1
    }
    if ! cat > "$tmp" <<'OIDC_TEMPLATE'
# IServ-OIDC für Coder – diese Datei wird von setup-coder.sh gelesen,
# aber niemals überschrieben. Rechte: root:root, 0600.
#
# OIDC_ENABLED=auto: aktiv, sobald CODER_OIDC_CLIENT_ID und
# CODER_OIDC_CLIENT_SECRET gesetzt sind.
# OIDC_ENABLED=false: aus, auch wenn Zugangsdaten gesetzt sind.
# OIDC_ENABLED=true:  an; Client-ID und Secret sind dann Pflicht.
OIDC_ENABLED=auto
CODER_OIDC_ISSUER_URL='https://ghse.de'
CODER_OIDC_CLIENT_ID=''
CODER_OIDC_CLIENT_SECRET=''

# Optional: interner Endpunkt des Issuers, falls die Schul-DNS ghse.de
# nach RFC1918 auflöst (im Schulnetz: 10.0.0.1). Die Egress-Sperre lässt
# dann nur das Compose-Netz zu diesem Host auf 443 durch.
# OIDC_INTERNAL_HOST=10.0.0.1

# Auf die IServ-Discovery abgestimmt. Keine zusätzlichen Scopes:
CODER_OIDC_SCOPES='openid,profile,email'
CODER_OIDC_SIGN_IN_TEXT='Mit IServ anmelden'
CODER_OIDC_USERNAME_FIELD='preferred_username'
CODER_OIDC_NAME_FIELD='name'
CODER_OIDC_EMAIL_FIELD='email'
CODER_OIDC_IGNORE_EMAIL_VERIFIED='false'
CODER_OIDC_ALLOW_SIGNUPS='true'

# Keine Domain-Einschränkung: CODER_OIDC_EMAIL_DOMAIN bleibt ungesetzt.
# Keine Gruppen-/Rollensynchronisierung: CODER_OIDC_GROUP_FIELD bleibt ungesetzt.
OIDC_TEMPLATE
    then
      rm -f "$tmp" 2> /dev/null || true
      OIDC_ERROR="Vorlage für $file konnte nicht geschrieben werden."
      return 1
    fi
    if ! chmod 600 "$tmp"; then
      rm -f "$tmp" 2> /dev/null || true
      OIDC_ERROR="Rechte von $file konnten nicht gesetzt werden."
      return 1
    fi
    if [ "$(id -u)" -eq 0 ] && ! chown root:root "$tmp"; then
      rm -f "$tmp" 2> /dev/null || true
      OIDC_ERROR="Eigentümer von $file konnte nicht gesetzt werden."
      return 1
    fi
    if ! mv -f "$tmp" "$file"; then
      rm -f "$tmp" 2> /dev/null || true
      OIDC_ERROR="$file konnte nicht angelegt werden."
      return 1
    fi
  fi

  if ! chmod 600 "$file"; then
    OIDC_ERROR="Rechte von $file konnten nicht auf 600 gesetzt werden."
    return 1
  fi
  if [ "$(id -u)" -eq 0 ] && ! chown root:root "$file"; then
    OIDC_ERROR="Eigentümer von $file konnte nicht auf root:root gesetzt werden."
    return 1
  fi
  return 0
}
