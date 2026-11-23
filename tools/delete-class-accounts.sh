#!/usr/bin/env bash
# delete-class-accounts.sh – löscht alle Coder-Konten einer Klasse und
# deren Workspaces. Die Löschung ist endgültig.
#
# Aufruf:
#   ./tools/delete-class-accounts.sh
#   ./tools/delete-class-accounts.sh --class 10a --dry-run
#
# Der Owner-Token wird beim Start unsichtbar abgefragt oder über
# CODER_SESSION_TOKEN übergeben.
set -euo pipefail
umask 077

DEFAULT_CODER_URL="https://coder.ghse-unterricht.de"

CLASS=""
DRY_RUN=0
ASSUME_YES=0
TIMEOUT=600

die() {
  printf 'Fehler: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warnung: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Löscht alle Coder-Konten einer Klasse samt ihrer Workspaces.

Aufruf:
  delete-class-accounts.sh [<klasse>] [Optionen]

Ohne --class oder Klassenname als Argument wird interaktiv nach dem
Klassennamen gefragt.
Gelöscht werden nur Konten mit exaktem Namen <klasse>-<nummer>.

Optionen:
  --class <name>     Klassenname, z. B. 10a (sonst Abfrage)
  --dry-run          Nur anzeigen, was gelöscht würde
  --yes              Bestätigung überspringen (für Automatisierung)
  --timeout <sek>    Zeitlimit für Workspace-Löschungen (Default: 600)
  -h, --help         Diese Hilfe

Umgebung:
  CODER_URL             Default: https://coder.ghse-unterricht.de
  CODER_SESSION_TOKEN   optional; wird sonst unsichtbar abgefragt

Ablauf:
  1. Konten der Klasse anzeigen
  2. Auf Bestätigung durch Eingabe des Klassennamens warten
  3. Konten sperren (verhindert neue Workspaces)
  4. Workspaces löschen und auf Abschluss warten
  5. Konten endgültig löschen

Diese Operation ist nicht umkehrbar. Ein Abbruch nach Schritt 3 lässt die
Konten gesperrt zurück; ein erneuter Lauf setzt die Löschung fort.
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
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --timeout)
      need_arg "$@"
      TIMEOUT="$2"
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
      [ -z "$CLASS" ] || die "Zu viele Argumente: $1 (--help)"
      CLASS="$1"
      shift
      ;;
  esac
done

command -v curl > /dev/null 2>&1 || die "curl fehlt"
command -v jq > /dev/null 2>&1 || die "jq fehlt"

: "${CODER_URL:=$DEFAULT_CODER_URL}"
CODER_URL=${CODER_URL%/}

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "Zeitlimit '$TIMEOUT' ist keine Zahl"
[ "$TIMEOUT" -ge 30 ] && [ "$TIMEOUT" -le 3600 ] \
  || die "Zeitlimit muss zwischen 30 und 3600 Sekunden liegen"

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

TMPDIR=$(mktemp -d)
chmod 700 "$TMPDIR"
CFG="$TMPDIR/curl.cfg"
BODY="$TMPDIR/body.json"
TARGETS="$TMPDIR/targets.tsv"
WS="$TMPDIR/workspaces.tsv"
PENDING="$TMPDIR/pending.tsv"
NEXT="$TMPDIR/next.tsv"
FAILED="$TMPDIR/failed.tsv"
REMAIN="$TMPDIR/remain.tsv"

cleanup() {
  local f
  for f in "$CFG" "$BODY" "$TARGETS" "$WS" "$PENDING" "$NEXT" "$FAILED" "$REMAIN"; do
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

printf 'header = "Coder-Session-Token: %s"\n' "$CODER_SESSION_TOKEN" > "$CFG"
: > "$PENDING"
: > "$FAILED"
: > "$REMAIN"

api() {
  local method=$1 path=$2 data=${3:-} code
  if [ -n "$data" ]; then
    code=$(printf '%s' "$data" | curl -sS --max-time 30 -K "$CFG" \
      -X "$method" -H 'Content-Type: application/json' \
      --data-binary @- -o "$BODY" -w '%{http_code}' \
      "$CODER_URL$path" || true)
  else
    code=$(curl -sS --max-time 30 -K "$CFG" -X "$method" \
      -o "$BODY" -w '%{http_code}' "$CODER_URL$path" || true)
  fi
  printf '%s' "${code:-000}"
}

code=$(api GET /api/v2/users/me)
if [ "$code" != "200" ]; then
  [ -s "$BODY" ] && cat "$BODY" >&2
  die "Login am Coder-Server fehlgeschlagen (HTTP $code). CODER_URL und Token prüfen."
fi
ME=$(jq -r '.username // empty' "$BODY")
jq -e '.roles // [] | map(.name) | index("owner")' "$BODY" > /dev/null \
  || die "Der Token gehört nicht zu einem Owner-Konto."

code=$(api GET /api/v2/users)
[ "$code" = "200" ] || {
  [ -s "$BODY" ] && cat "$BODY" >&2
  die "Konten konnten nicht geladen werden (HTTP $code)."
}

jq -r --arg cls "$CLASS" '
  .users[]
  | select(.username | test("^" + $cls + "-[0-9]+$"))
  | [.id, .username, ((.roles // []) | map(.name) | join(",")),
     (.is_service_account // false)]
  | @tsv
' "$BODY" | sort -t $'\t' -k2,2 > "$TARGETS"

if [ ! -s "$TARGETS" ]; then
  printf 'Keine Konten der Klasse %s gefunden – nichts zu löschen.\n' "$CLASS"
  exit 0
fi

while IFS=$'\t' read -r id user roles service; do
  [ "$user" != "$ME" ] || die "Das eigene Konto ($user) passt auf das Muster und wird nicht gelöscht."
  [ "$service" != "true" ] || die "Konto $user ist ein Service-Account und wird nicht gelöscht."
  case ",$roles," in
    *,owner,*) die "Konto $user hat Owner-Rechte und wird nicht automatisch gelöscht." ;;
  esac
done < "$TARGETS"

list_workspaces() {
  local user=$1
  local code
  code=$(api GET "/api/v2/workspaces?q=owner%3A$user")
  [ "$code" = "200" ] || {
    [ -s "$BODY" ] && cat "$BODY" >&2
    die "Workspaces von $user konnten nicht geladen werden (HTTP $code)."
  }
  jq -r '
    .workspaces[]
    | [.id, .name, .latest_build.id, .latest_build.transition,
       .latest_build.job.status]
    | @tsv
  ' "$BODY" > "$WS"
}

printf '\nKonten der Klasse %s auf %s:\n' "$CLASS" "$CODER_URL"
while IFS=$'\t' read -r id user roles service; do
  list_workspaces "$user"
  count=$(wc -l < "$WS" | tr -d ' ')
  printf '  %-24s %-8s %s Workspace(s)\n' "$user" "$roles" "$count"
  while IFS=$'\t' read -r wid wname bid transition status; do
    printf '      - %s (%s)\n' "$wname" "$transition"
  done < "$WS"
done < "$TARGETS"
printf '\nKonten: %s. Die Löschung ist endgültig.\n' \
  "$(wc -l < "$TARGETS" | tr -d ' ')"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry-Run: nichts geändert.\n'
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  [ -t 0 ] || die "Ohne Terminal bitte --yes angeben."
  printf 'Zum endgültigen Löschen "%s" eingeben: ' "$CLASS"
  IFS= read -r answer || die "Abgebrochen."
  [ "$answer" = "$CLASS" ] || die "Abgebrochen – nichts gelöscht."
else
  warn "--yes gesetzt: Löschung ohne Rückfrage."
fi

# Konten sperren, damit während des Aufräumens keine neuen Workspaces
# entstehen und sich niemand mehr anmeldet.
while IFS=$'\t' read -r id user roles service; do
  code=$(api PUT "/api/v2/users/$id/status/suspend")
  case "$code" in
    200|204)
      printf 'Gesperrt: %s\n' "$user"
      ;;
    *)
      [ -s "$BODY" ] && cat "$BODY" >&2
      die "Konto $user konnte nicht gesperrt werden (HTTP $code). Bereits gesperrte Konten bleiben gesperrt; erneuter Lauf setzt fort."
      ;;
  esac
done < "$TARGETS"

# Workspace-Löschungen anstoßen; bereits laufende Löschungen übernehmen.
ws_total=0
while IFS=$'\t' read -r id user roles service; do
  list_workspaces "$user"
  while IFS=$'\t' read -r wid wname bid transition status; do
    ws_total=$((ws_total + 1))
    if [ "$transition" = "delete" ]; then
      case "$status" in
        pending|running|canceling)
          printf 'Wartet bereits: %s/%s\n' "$user" "$wname"
          printf '%s\t%s\t%s\n' "$bid" "$user" "$wname" >> "$PENDING"
          continue
          ;;
        succeeded)
          printf 'Bereits gelöscht: %s/%s\n' "$user" "$wname"
          continue
          ;;
        *)
          die "Löschung von $user/$wname ist '$status'. Bitte im Coder prüfen und den Lauf wiederholen."
          ;;
      esac
    fi
    code=$(api POST "/api/v2/workspaces/$wid/builds" '{"transition":"delete"}')
    case "$code" in
      200|201)
        ;;
      *)
        [ -s "$BODY" ] && cat "$BODY" >&2
        die "Workspace $user/$wname konnte nicht gelöscht werden (HTTP $code)."
        ;;
    esac
    bid=$(jq -r '.id // empty' "$BODY")
    [ -n "$bid" ] || die "Coder hat für $user/$wname keine Build-ID geliefert."
    printf 'Lösche Workspace: %s/%s\n' "$user" "$wname"
    printf '%s\t%s\t%s\n' "$bid" "$user" "$wname" >> "$PENDING"
  done < "$WS"
done < "$TARGETS"

# Auf alle Lösch-Builds warten.
if [ -s "$PENDING" ]; then
  deadline=$((SECONDS + TIMEOUT))
  last_note=$SECONDS
  while [ -s "$PENDING" ]; do
    : > "$NEXT"
    while IFS=$'\t' read -r bid user wname; do
      code=$(api GET "/api/v2/workspacebuilds/$bid")
      if [ "$code" = "404" ]; then
        printf 'Gelöscht: %s/%s\n' "$user" "$wname"
        continue
      fi
      if [ "$code" != "200" ]; then
        warn "Status von $user/$wname nicht abrufbar (HTTP $code) – versuche weiter."
        printf '%s\t%s\t%s\n' "$bid" "$user" "$wname" >> "$NEXT"
        continue
      fi
      status=$(jq -r '.job.status // empty' "$BODY")
      case "$status" in
        succeeded)
          printf 'Gelöscht: %s/%s\n' "$user" "$wname"
          ;;
        pending|running|canceling)
          printf '%s\t%s\t%s\n' "$bid" "$user" "$wname" >> "$NEXT"
          ;;
        *)
          printf '%s\t%s\t%s\t%s\n' "$bid" "$user" "$wname" "$status" >> "$FAILED"
          ;;
      esac
    done < "$PENDING"
    mv "$NEXT" "$PENDING"
    [ -s "$PENDING" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      die "Zeitlimit von ${TIMEOUT}s erreicht; offene Workspace-Löschungen: $(cut -f2,3 "$PENDING" | tr '\t' '/' | paste -sd ', ' -). Konten wurden nicht gelöscht; erneuter Lauf setzt fort."
    fi
    if [ $((SECONDS - last_note)) -ge 15 ]; then
      printf 'Noch %s Workspace-Löschung(en) aktiv ...\n' \
        "$(wc -l < "$PENDING" | tr -d ' ')"
      last_note=$SECONDS
    fi
    sleep 5
  done
fi

if [ -s "$FAILED" ]; then
  die "Workspace-Löschung fehlgeschlagen: $(cut -f2,3 "$FAILED" | tr '\t' '/' | paste -sd ', ' -). Konten wurden nicht gelöscht."
fi

# Sicherheitsnetz: Coder verweigert das Löschen von Konten mit Workspaces.
while IFS=$'\t' read -r id user roles service; do
  list_workspaces "$user"
  if [ -s "$WS" ]; then
    printf '%s\n' "$user" >> "$REMAIN"
  fi
done < "$TARGETS"
if [ -s "$REMAIN" ]; then
  die "Es sind noch Workspaces vorhanden bei: $(paste -sd ', ' - < "$REMAIN"). Konten wurden nicht gelöscht."
fi

deleted=0
failed=0
while IFS=$'\t' read -r id user roles service; do
  code=$(api DELETE "/api/v2/users/$id")
  case "$code" in
    200|204|404)
      printf 'Konto gelöscht: %s\n' "$user"
      deleted=$((deleted + 1))
      ;;
    *)
      warn "Konto $user konnte nicht gelöscht werden (HTTP $code)."
      [ -s "$BODY" ] && cat "$BODY" >&2
      failed=$((failed + 1))
      ;;
  esac
done < "$TARGETS"

printf '\nKlasse %s: %d Konten gelöscht, %d Workspaces geprüft, %d Fehler.\n' \
  "$CLASS" "$deleted" "$ws_total" "$failed"
[ "$failed" -eq 0 ] || exit 1
