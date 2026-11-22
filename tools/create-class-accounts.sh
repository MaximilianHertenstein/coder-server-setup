#!/usr/bin/env bash
# create-class-accounts.sh – legt Coder-Konten für eine Klasse an und
# erzeugt ein druckbares PDF mit Benutzername, E-Mail und Passwort.
#
# Aufruf:
#   CODER_URL=https://coder.ghse-unterricht.de \
#   CODER_SESSION_TOKEN=... \
#   ./tools/create-class-accounts.sh --class 10a --count 25
#
# Der Token braucht Owner-Rechte (Konten anlegen, Passwörter setzen).
# Er wird nur für den Lauf benötigt und sollte kurzlebig sein.
set -euo pipefail
umask 077

DEFAULT_EMAIL_DOMAIN="schueler.ghse-unterricht.de"
PASSWORD_LENGTH=14
PASSWORD_CHARSET="A-HJ-NP-Za-km-z2-9"

CLASS=""
COUNT=""
EMAIL_DOMAIN="$DEFAULT_EMAIL_DOMAIN"
RESET=0
DRY_RUN=0
OUT_DIR="$PWD"

die() {
  printf 'Fehler: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warnung: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Legt Coder-Konten für eine Klasse an und erzeugt ein PDF mit Zugangsdaten.

Aufruf:
  create-class-accounts.sh [Optionen]
  create-class-accounts.sh --class <name> --count <n> [Optionen]

Ohne --class/--count fragt das Skript interaktiv nach Klassenname und Anzahl.

Optionen:
  --class <name>        Klassenname, z. B. 10a (sonst Abfrage)
  --count <n>           Anzahl der Schülerinnen und Schüler (sonst Abfrage)
  --email-domain <d>    Domain der E-Mail-Adressen
                        (Default: schueler.ghse-unterricht.de)
  --reset               Bei vorhandenen Konten ein neues Passwort setzen
                        (ohne --reset werden vorhandene Konten übersprungen)
  --dry-run             Nichts anlegen, nur ein Vorschau-PDF erzeugen
  --out <dir>           Zielverzeichnis für das PDF (Default: aktuell)
  -h, --help            Diese Hilfe

Umgebung:
  CODER_URL             Default: https://coder.ghse-unterricht.de
  CODER_SESSION_TOKEN   optional; wird sonst beim Start abgefragt

Erzeugte Namen: <klasse>-01, <klasse>-02, ...
E-Mails:        <name>@<email-domain>
Passwörter:     14 Zeichen, ohne 0/O, 1/l/I
EOF
}

need_arg() {
  [ "$#" -ge 2 ] || die "Option $1 braucht einen Wert"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --class)
      need_arg "$@"
      CLASS="$2"
      shift 2
      ;;
    --count)
      need_arg "$@"
      COUNT="$2"
      shift 2
      ;;
    --email-domain)
      need_arg "$@"
      EMAIL_DOMAIN="$2"
      shift 2
      ;;
    --reset)
      RESET=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --out)
      need_arg "$@"
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unbekannte Option: $1 (--help)"
      ;;
    *)
      if [ -z "$CLASS" ]; then
        CLASS="$1"
      elif [ -z "$COUNT" ]; then
        COUNT="$1"
      else
        die "Zu viele Argumente: $1 (--help)"
      fi
      shift
      ;;
  esac
done

command -v typst > /dev/null 2>&1 \
  || die "typst fehlt (für das PDF). Installation: https://typst.app/"
if [ "$DRY_RUN" -eq 0 ]; then
  command -v curl > /dev/null 2>&1 || die "curl fehlt"
  command -v jq > /dev/null 2>&1 || die "jq fehlt"
  : "${CODER_URL:=https://coder.ghse-unterricht.de}"
fi

normalize_class() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

valid_class() {
  [ -n "$1" ] && [ "${#1}" -le 24 ] \
    && [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

if [ -z "$CLASS" ]; then
  if [ -t 0 ]; then
    while :; do
      IFS= read -r -p "Klassenname (z. B. 10a): " CLASS || die "Abgebrochen."
      CLASS=$(normalize_class "$CLASS")
      valid_class "$CLASS" && break
      warn "Bitte a-z, 0-9 und Bindestriche verwenden (max. 24 Zeichen)."
    done
  else
    die "Klasse fehlt (--class) und stdin ist kein Terminal"
  fi
else
  CLASS=$(normalize_class "$CLASS")
  valid_class "$CLASS" \
    || die "Klassenname '$CLASS' ist ungültig (a-z, 0-9, Bindestriche; max. 24 Zeichen)"
fi

if [ -z "$COUNT" ]; then
  if [ -t 0 ]; then
    while :; do
      IFS= read -r -p "Anzahl der Schülerinnen und Schüler: " COUNT || die "Abgebrochen."
      [[ "$COUNT" =~ ^[0-9]+$ ]] || { warn "Bitte eine Zahl eingeben."; continue; }
      COUNT=$((10#$COUNT))
      [ "$COUNT" -ge 1 ] && [ "$COUNT" -le 200 ] && break
      warn "Bitte eine Zahl zwischen 1 und 200 eingeben."
    done
  else
    die "Anzahl fehlt (--count) und stdin ist kein Terminal"
  fi
else
  [[ "$COUNT" =~ ^[0-9]+$ ]] || die "Anzahl '$COUNT' ist keine Zahl"
  COUNT=$((10#$COUNT))
  [ "$COUNT" -ge 1 ] && [ "$COUNT" -le 200 ] \
    || die "Anzahl muss zwischen 1 und 200 liegen"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "${CODER_SESSION_TOKEN:-}" ]; then
    if [ -t 0 ]; then
      printf 'Owner-Token (Eingabe bleibt unsichtbar): ' >&2
      IFS= read -rs CODER_SESSION_TOKEN || die "Kein Token eingegeben"
      printf '\n' >&2
    else
      die "CODER_SESSION_TOKEN ist nicht gesetzt und stdin ist kein Terminal"
    fi
  fi
  [ -n "$CODER_SESSION_TOKEN" ] || die "Kein Token eingegeben"
fi

EMAIL_DOMAIN=${EMAIL_DOMAIN,,}
[[ "$EMAIL_DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] \
  || die "E-Mail-Domain '$EMAIL_DOMAIN' ist ungültig"

mkdir -p "$OUT_DIR" || die "Zielverzeichnis '$OUT_DIR' lässt sich nicht anlegen"

TMPDIR=$(mktemp -d)
chmod 700 "$TMPDIR"
ROWS_ALL="$TMPDIR/rows-all.tsv"
ROWS_OK="$TMPDIR/rows-ok.tsv"
TYP="$TMPDIR/accounts.typ"
CHECK_PDF="$TMPDIR/check.pdf"
BODY="$TMPDIR/body.json"
CFG="$TMPDIR/curl.cfg"
: > "$ROWS_ALL"
: > "$ROWS_OK"
: > "$BODY"

cleanup() {
  local f
  for f in "$ROWS_ALL" "$ROWS_OK" "$TYP" "$CHECK_PDF" "$BODY" "$CFG"; do
    [ -e "$f" ] || continue
    if command -v shred > /dev/null 2>&1; then
      shred -u "$f" 2> /dev/null || rm -f "$f"
    else
      rm -f "$f"
    fi
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

gen_password() {
  local pw
  pw=$(LC_ALL=C tr -dc "$PASSWORD_CHARSET" < /dev/urandom 2> /dev/null \
    | head -c "$PASSWORD_LENGTH" || true)
  [ "${#pw}" -eq "$PASSWORD_LENGTH" ] \
    || die "Passwort konnte nicht erzeugt werden"
  printf '%s' "$pw"
}

write_typst() {
  local rows=$1 out=$2 banner=$3 n
  n=$(wc -l < "$rows" | tr -d ' ')
  {
    cat <<'TYP'
#set page(
  paper: "a4",
  margin: (x: 1.7cm, y: 1.6cm),
  footer: context align(right)[#text(size: 8pt, fill: luma(130))[Seite #counter(page).display()]],
)
#set text(font: "DejaVu Sans", size: 9.5pt, hyphenate: false)
#set par(justify: false)
#show raw: set text(font: "DejaVu Sans Mono", size: 9pt)

#let accent = rgb("#22456b")
#let band = rgb("#eef3f8")

#align(center)[
  #text(size: 19pt, weight: "bold", fill: accent)[Coder-Zugänge]
  #v(2pt)
TYP
    printf '  #text(size: 11pt)[Klasse %s]\n' "$CLASS"
    printf ']\n'
    printf '#v(4pt)\n'
    printf '#align(center)[#text(size: 8.5pt, fill: luma(95))[%s Konten · %s]]\n' \
      "$n" "$(date '+%d.%m.%Y')"
    if [ -n "${CODER_URL:-}" ]; then
      printf '#v(2pt)\n#align(center)[#text(size: 8.5pt, fill: luma(95))[#raw("%s")]]\n' \
        "${CODER_URL%/}"
    fi
    if [ "$banner" -eq 1 ]; then
      printf '#v(4pt)\n#align(center)[#text(fill: rgb("#b00020"), weight: "bold")[VORSCHAU – keine Konten angelegt]]\n'
    fi
    printf '#v(12pt)\n'
    printf '#table(\n  columns: (1fr, 1.9fr, 1fr),\n  inset: (x: 8pt, y: 6.5pt),\n'
    printf '  stroke: (_, y) => (bottom: 0.4pt + luma(205)),\n'
    printf '  fill: (_, y) => if calc.odd(y) { band } else { white },\n'
    printf '  table.header(\n'
    printf '    table.cell(fill: accent)[#text(fill: white, weight: "bold")[Benutzername]],\n'
    printf '    table.cell(fill: accent)[#text(fill: white, weight: "bold")[E-Mail]],\n'
    printf '    table.cell(fill: accent)[#text(fill: white, weight: "bold")[Passwort]],\n'
    printf '  ),\n'
    while IFS=$'\t' read -r u e p; do
      printf '  [#raw("%s")], [#raw("%s")], [#raw("%s")],\n' "$u" "$e" "$p"
    done < "$rows"
    printf ')\n'
    printf '#v(10pt)\n#line(length: 100%%, stroke: 0.5pt + luma(200))\n#v(4pt)\n'
    printf '#text(size: 8pt, fill: luma(95))[Passwort beim ersten Login ändern. Dieses Blatt enthält Klartext-Passwörter – nach dem Verteilen löschen.]\n'
  } > "$out"
}

api() {
  local method=$1 path=$2 data=${3:-} code
  if [ -n "$data" ]; then
    code=$(printf '%s' "$data" | curl -sS --max-time 30 -K "$CFG" \
      -X "$method" -H 'Content-Type: application/json' \
      --data-binary @- -o "$BODY" -w '%{http_code}' \
      "${CODER_URL%/}$path" || true)
  else
    code=$(curl -sS --max-time 30 -K "$CFG" -X "$method" \
      -o "$BODY" -w '%{http_code}' "${CODER_URL%/}$path" || true)
  fi
  printf '%s' "${code:-000}"
}

width=2
[ "${#COUNT}" -gt "$width" ] && width=${#COUNT}

# Alle geplanten Zeilen zuerst erzeugen; so lässt sich das PDF vor dem
# ersten API-Aufruf einmal probehalber bauen.
i=1
while [ "$i" -le "$COUNT" ]; do
  num=$(printf "%0${width}d" "$i")
  user="${CLASS}-${num}"
  email="${user}@${EMAIL_DOMAIN}"
  printf '%s\t%s\t%s\n' "$user" "$email" "$(gen_password)" >> "$ROWS_ALL"
  i=$((i + 1))
done

# Typst vor jedem Serverzugriff testen: ein kaputtes PDF darf nicht erst
# nach dem Anlegen der Konten auffallen.
write_typst "$ROWS_ALL" "$TYP" 0
typst compile "$TYP" "$CHECK_PDF" > /dev/null 2>&1 \
  || die "PDF-Vorschau konnte nicht erzeugt werden (typst)"

ORG=""
if [ "$DRY_RUN" -eq 0 ]; then
  printf 'header = "Coder-Session-Token: %s"\n' "$CODER_SESSION_TOKEN" > "$CFG"
  code=$(api GET /api/v2/users/me)
  if [ "$code" != "200" ]; then
    [ -s "$BODY" ] && cat "$BODY" >&2
    die "Login am Coder-Server fehlgeschlagen (HTTP $code). CODER_URL und Token prüfen."
  fi
  ORG=$(jq -r '.organization_ids[0] // empty' "$BODY" 2> /dev/null || true)
  [ -n "$ORG" ] || die "Keine Organisation im Benutzerkonto gefunden"
fi

created=0
skipped=0
failed=0

if [ "$DRY_RUN" -eq 0 ]; then
  while IFS=$'\t' read -r user email pw; do
    code=$(api GET "/api/v2/users/$user")
    case "$code" in
      200)
        if [ "$RESET" -eq 1 ]; then
          payload=$(jq -n --arg password "$pw" '{password:$password}')
          code=$(api PUT "/api/v2/users/$user/password" "$payload")
          if [ "$code" = "204" ] || [ "$code" = "200" ]; then
            printf '%s\t%s\t%s\n' "$user" "$email" "$pw" >> "$ROWS_OK"
            created=$((created + 1))
          else
            warn "Passwort für $user nicht gesetzt (HTTP $code)"
            [ -s "$BODY" ] && cat "$BODY" >&2
            failed=$((failed + 1))
          fi
        else
          warn "Existiert bereits, übersprungen: $user (--reset setzt ein neues Passwort)"
          skipped=$((skipped + 1))
        fi
        ;;
      404)
        num=${user##*-}
        payload=$(jq -n \
          --arg email "$email" \
          --arg username "$user" \
          --arg name "$CLASS $num" \
          --arg password "$pw" \
          --arg org "$ORG" \
          '{email:$email, username:$username, name:$name, password:$password,
            login_type:"password", user_status:"active",
            roles:["member"], organization_ids:[$org]}')
        code=$(api POST /api/v2/users "$payload")
        if [ "$code" = "201" ] || [ "$code" = "200" ]; then
          printf '%s\t%s\t%s\n' "$user" "$email" "$pw" >> "$ROWS_OK"
          created=$((created + 1))
        else
          warn "Konto $user nicht angelegt (HTTP $code)"
          [ -s "$BODY" ] && cat "$BODY" >&2
          failed=$((failed + 1))
        fi
        ;;
      000)
        warn "Coder-Server für $user nicht erreichbar"
        failed=$((failed + 1))
        ;;
      *)
        warn "Abfrage für $user fehlgeschlagen (HTTP $code)"
        [ -s "$BODY" ] && cat "$BODY" >&2
        failed=$((failed + 1))
        ;;
    esac
  done < "$ROWS_ALL"
else
  cp "$ROWS_ALL" "$ROWS_OK"
  created=$COUNT
fi

if [ ! -s "$ROWS_OK" ]; then
  if [ "$failed" -eq 0 ]; then
    printf 'Klasse %s: %d vorhandene Konten, keine neuen. Kein PDF erzeugt.\n' \
      "$CLASS" "$skipped"
    printf 'Mit --reset neue Passwörter setzen und ein PDF erzeugen.\n'
    exit 0
  fi
  warn "Keine Konten in der PDF – es wurde kein PDF erzeugt."
  exit 1
fi

banner=0
[ "$DRY_RUN" -eq 1 ] && banner=1
write_typst "$ROWS_OK" "$TYP" "$banner"
PDF="$OUT_DIR/coder-zugaenge-${CLASS}-$(date '+%Y-%m-%d_%H%M%S').pdf"
typst compile "$TYP" "$PDF" > /dev/null 2>&1 \
  || die "PDF konnte nicht erzeugt werden (typst)"
chmod 600 "$PDF"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Vorschau: %d Konten geplant, keine angelegt.\n' "$created"
else
  printf 'Klasse %s: %d angelegt/neu gesetzt, %d übersprungen, %d fehlgeschlagen.\n' \
    "$CLASS" "$created" "$skipped" "$failed"
fi
printf 'PDF: %s\n' "$PDF"
printf 'Hinweis: Das PDF enthält Klartext-Passwörter (Dateirechte 600). Nach dem Verteilen löschen.\n'

[ "$failed" -eq 0 ] || exit 1
