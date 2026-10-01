#!/usr/bin/env bash
# ============================================================================
# Coder-Server Setup – coder.ghse-unterricht.de
# Zielsystem: Debian 13 (trixie)
#
# Aufruf als root (ohne root bricht das Skript vor jeder Änderung ab):
#   chmod +x setup-coder.sh
#   sudo ./setup-coder.sh
# Umgebungsvariablen gehören hinter das sudo (siehe OPERATIONS.md):
#   sudo env DOMAIN_CODER=… ACME_EMAIL=… ./setup-coder.sh
#
# Mehrfach ausführbar (idempotent): bei Abbruch, fehlendem DNS oder fehlender
# Portweiterleitung einfach erneut laufen lassen; fehlendes DNS meldet der
# Abschlusscheck als WARNUNG, nicht als Fehler.
#
# Inhaltliche Details bewusst nur in den Dokumenten (Single Source):
#   README.md        Start, Voraussetzungen (DNS/Wildcard), Prüfstand
#   OPERATIONS.md    Betrieb, Wartungsskripte, Cron, Netz-Anforderung, Updates
#   SECURITY.md      Socket-Risiko, D-SSH, On-Demand-TLS-Budget, Monitoring
#   RESTORE.md       Wiederherstellung
# Image-Versionen und Pin-Regeln stehen an den Variablendefinitionen unten.
# ============================================================================

set -euo pipefail

# Eigenes Verzeichnis: die installierbaren Wartungsskripte liegen als echte
# Dateien unter scripts/ (direkt per bash -n/shellcheck prüfbar) und werden
# über write_managed von dort eingespielt. Voraussetzung: das Repo liegt
# vollständig auf dem Server (git clone, siehe README).
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Root ist Pflicht – zuerst, vor jeder Prüfung und jeder Änderung: Lock,
# Rechte und Dateien unter /opt/coder gehören root, und die Wartungsskripte
# sperren dieselbe Datei. Ohne root würde das Setup scheitern, nachdem es
# bereits Pakete installiert hätte.
# sudo leitet fremde Umgebungsvariablen nicht durch; Werte gehören hinter
# das sudo: sudo env DOMAIN_CODER=… ACME_EMAIL=… ./setup-coder.sh
if [ "$(id -u)" -ne 0 ]; then
  echo "Fehler: dieses Setup muss als root laufen – Aufruf: sudo ./setup-coder.sh" >&2
  echo "Umgebungsvariablen gehören nach das sudo, sonst greifen die Defaults:" >&2
  echo "  sudo env DOMAIN_CODER=coder.beispiel.de ACME_EMAIL=admin@beispiel.de ./setup-coder.sh" >&2
  exit 1
fi

# Zielplattform vor jeder Serveränderung prüfen. Die Docker-APT-Quelle unten
# übernimmt VERSION_CODENAME aus /etc/os-release; ohne Guard könnte ein Lauf
# auf Ubuntu oder Debian 12 eine unpassende Quelle eintragen und Pakete
# verändern, obwohl nur Debian 13 (trixie) unterstützt wird.
if [ ! -r /etc/os-release ]; then
  echo "Fehler: /etc/os-release fehlt oder ist nicht lesbar; Zielplattform nicht prüfbar. Abbruch ohne Serveränderungen." >&2
  exit 1
fi
. /etc/os-release
if [ "${ID:-}" != "debian" ] || [ "${VERSION_CODENAME:-}" != "trixie" ]; then
  printf 'Fehler: nicht unterstützte Zielplattform (ID=%s, VERSION_CODENAME=%s). Erwartet wird Debian 13 (trixie). Abbruch vor Serveränderungen.\n' \
    "${ID:-unbekannt}" "${VERSION_CODENAME:-unbekannt}" >&2
  exit 1
fi

# Das Setup schreibt Compose- und Wartungsskripte und startet den Stack.
# Ein paralleler Wartungslauf könnte Dateien während ihrer Ausführung
# überschreiben. Vor diesen Konfigurations- und Stack-Änderungen nimmt das
# Setup denselben flock wie die Wartungsskripte: er hängt am Deskriptor 8
# dieses Prozesses und bleibt gesperrt, bis alle Prozesse ihn geerbt haben,
# beendet sind. Alle Aufrufe hier sind kurzlebig, kein Dauerläufer erbt ihn.
ENV_TMP=""
MANAGED_TMP=""
setup_cleanup() {
  local rc=$?
  for _tmp in "${ENV_TMP}" "${MANAGED_TMP}"; do
    [ -n "${_tmp}" ] && rm -f -- "${_tmp}" 2>/dev/null || true
  done
  return "${rc}"
}

mkdir -p /opt/coder
sh -c 'umask 077; : >> /opt/coder/.maintenance.lock; chown root:root /opt/coder/.maintenance.lock; chmod 600 /opt/coder/.maintenance.lock'
exec 8>>/opt/coder/.maintenance.lock
if ! flock -w 300 8; then
  echo "Fehler: gemeinsamer Wartungs-Lock nach 300 s nicht erhalten; Setup abgebrochen (Exit 75)." >&2
  exit 75
fi
export CODER_MAINTENANCE_LOCK_HELD=1
trap setup_cleanup EXIT

# Wo das Skript selbst liegt – JETZT merken, vor jedem cd. Schritt 2 geht nach
# /opt/coder; würde der Runbook-Check in Schritt 6 seinen Pfad erst dort aus
# "dirname $0" (relativ, also ".") berechnen, suchte er RESTORE.md in
# /opt/coder und meldete ihn jedes Mal als fehlend, obwohl er daneben liegt.
SCRIPT_SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Alle Werte lassen sich beim Aufruf per Umgebungsvariable überschreiben,
# ohne diese Datei zu ändern, z.B.:
#   DOMAIN_CODER=andere-domain.de ./setup-coder.sh
# ":=" setzt den Default nur, wenn die Variable noch nicht (von außen) gesetzt
# wurde.
: "${DOMAIN_CODER:=coder.ghse-unterricht.de}"
: "${ACME_EMAIL:=hert@ghse.de}"
# Pin-Regeln: CODER/PROMETHEUS/GRAFANA/NODE_EXPORTER exakt, CADDY bewusst nur
# minor-gepinnt (z. B. "2.10") – TLS-taugliche Patch-Updates sollen über
# "docker compose pull" ankommen; postgres:18-alpine analog (Major-Tag).
# WICHTIG: Das ghcr.io-Tag TRÄGT das "v"-Präfix (v2.36.6). Am 2026-09-28 gegen
# die Registry geprüft: ghcr.io/coder/coder:2.36.6 -> HTTP 404,
# :v2.36.6 -> Pull ok; die Release-Notes nennen das Tag teils ohne "v" (falsch,
# das bricht Schritt 3 ab). Vor jeder Versionserhöhung IMMER per "docker pull"
# gegen die Registry belegen, nicht nach dem Wortlaut der Notes. Für einen
# bit-genauen, reproduzierbaren Pin bräuchte man ein Image-Digest (sha256:...).
: "${CODER_VERSION:=v2.36.6}"              # https://github.com/coder/coder/releases prüfen
: "${CADDY_VERSION:=2.10}"                # https://hub.docker.com/_/caddy/tags
: "${PROMETHEUS_VERSION:=v3.14.0}"        # https://github.com/prometheus/prometheus/releases
: "${GRAFANA_VERSION:=12.4.5}"            # https://github.com/grafana/grafana/releases
: "${NODE_EXPORTER_VERSION:=v1.12.1}"     # https://github.com/prometheus/node_exporter/releases
# Review 0.3: Admin-Adressen, die fail2ban nie sperren darf (geteilte
# Schul-NAT: 5 Fehlversuche sperrten sonst die gemeinsame Quell-IP).
# Nur Admin-Plaetze eintragen, nicht das ganze Schuelernetz.
: "${FAIL2BAN_IGNORE_IP:=127.0.0.1/8 ::1}"

# ---- Wirksam gewesene Versionen + Downgrade-Schutz (A5) --------------------
# Die fünf Versionen sind exakt gepinnt. Führt man das Skript mit einer
# NIEDRIGEREN Version aus (älterer Repo-Stand, Verwechslung, versehentlicher
# Rollback), würde "docker compose up -d" die Images still zurücksetzen – bei
# Coder mit DB-Schema-Migrationen u. U. irreversibel. Daher wird die zuletzt
# wirksam gewesene Version in /opt/coder/versions.env gemerkt (nur
# Versionen, keine Geheimnisse -> 644, ohne sudo lesbar) und jeder
# Downgrade-Versuch hart abgebrochen, sofern nicht ausdrücklich
# CODER_ALLOW_DOWNGRADE=yes gesetzt ist (bewusster Rollback, siehe
# RESTORE.md). Eine Änderung NACH oben (Upgrade) bleibt ohne Rückfrage.
VERSIONS_FILE="/opt/coder/versions.env"
VERSION_VARS="CODER_VERSION CADDY_VERSION PROMETHEUS_VERSION GRAFANA_VERSION NODE_EXPORTER_VERSION"
VERSIONS_PREV="$(cat "${VERSIONS_FILE}" 2>/dev/null || true)"
for _vv in ${VERSION_VARS}; do
  _vnew="${!_vv:-}"
  _vprev="$(printf '%s\n' "${VERSIONS_PREV}" | awk -F= -v k="${_vv}" '$1 == k {print substr($0, index($0, "=") + 1); exit}')"
  _vprev_sort="${_vprev#v}"
  _vnew_sort="${_vnew#v}"
  if [ -n "${_vprev_sort}" ] && [ -n "${_vnew_sort}" ] && [ "${_vprev_sort}" != "${_vnew_sort}" ] \
    && [ "$(printf '%s\n%s\n' "${_vprev_sort}" "${_vnew_sort}" | sort -V | head -n 1)" = "${_vnew_sort}" ]; then
    echo "Fehler: Downgrade erkannt – ${_vv} würde von ${_vprev} auf ${_vnew} zurückgesetzt." >&2
    echo "Ein Downgrade kann bei Coder eine bereits ausgeführte DB-Schema-Migration" >&2
    echo "nicht rückgängig machen und die Installation unbrauchbar machen." >&2
    if [ "${CODER_ALLOW_DOWNGRADE:-}" = "yes" ]; then
      echo "CODER_ALLOW_DOWNGRADE=yes gesetzt – bewusstes Downgrade wird durchgeführt." >&2
    else
      echo "Abbruch, nichts wurde verändert. Bewusstes Downgrade (mit verifiziertem" >&2
      echo "Dump, siehe RESTORE.md):" >&2
      echo "  sudo env CODER_ALLOW_DOWNGRADE=yes CODER_VERSION=... ./setup-coder.sh" >&2
      exit 1
    fi
  fi
done
# Persistierung steht NICHT hier (A1/A7): /opt/coder gibt es an dieser Stelle
# noch nicht (erst ab Schritt 2), und eine Version darf erst eingetragen
# werden, wenn sie wirklich läuft. Siehe direkt nach "docker compose up -d".

# ---- Hilfsfunktionen für die Zusammenfassung ab Schritt 4 -----------------
declare -a SUMMARY=()
ERROR_COUNT=0
ok()   { echo "  [OK]     $1"; SUMMARY+=("[OK]     $1"); }
warn() { echo "  [WARNUNG] $1"; SUMMARY+=("[WARNUNG] $1"); }
fail() { echo "  [FEHLER] $1"; SUMMARY+=("[FEHLER] $1"); ERROR_COUNT=$((ERROR_COUNT + 1)); }

check_container_running() {
  local name="$1"
  local label="$2"
  if [ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || echo false)" = "true" ]; then
    ok "${label} läuft"
  else
    fail "${label} läuft NICHT – prüfen mit: sudo docker logs ${name}"
  fi
}

# B-012: Drift-Warnung (Caddy-P-025-Muster verallgemeinert). Alle generierten
# Dateien werden deterministisch regeneriert (Heilung bleibt), aber nie still:
# weicht eine Datei von der letzten Setup-Generation ab (Operator-Tuning wie
# retention.size, Caddy-Snippets, recidive-Jails, Cron-Zeiten), steht das als
# WARN in der SUMMARY. Erwartungswerte liegen in /opt/coder/.generated-hashes
# (nur root, 600). Kein interaktiver Stopp (Idempotenz bleibt).
# Commit-Ort (B2-007): write_managed schreibt atomar und aktualisiert den Hash
# unmittelbar nach dem erfolgreichen Austausch. So kann ein abgebrochener
# Lauf keinen Hash der alten Datei als Hash der neuen Generation eintragen.
HASHSTORE="/opt/coder/.generated-hashes"
note_drift() {
  local file="$1" label="$2" cur="" exp=""
  cur=$(sha256sum "${file}" 2>/dev/null | cut -d' ' -f1 || true)
  exp=$(awk -v f="${file}" '$2 == f {print $1}' "${HASHSTORE}" 2>/dev/null || true)
  if [ -n "${cur}" ] && [ -n "${exp}" ] && [ "${cur}" != "${exp}" ]; then
    warn "Drift in ${label} (${file}): weicht von letzter Setup-Generation ab – wird deterministisch regeneriert, Hand-Anpassung geht verloren"
  fi
}
remember_hash() {
  local file="$1" h=""
  h=$(sha256sum "${file}" 2>/dev/null | cut -d' ' -f1 || true)
  [ -n "${h}" ] || return 0
  touch "${HASHSTORE}" 2>/dev/null || true
  awk -v f="${file}" '$2 != f' "${HASHSTORE}" 2>/dev/null | tee "${HASHSTORE}.tmp" > /dev/null || true
  echo "${h}  ${file}" | tee -a "${HASHSTORE}.tmp" > /dev/null
  mv "${HASHSTORE}.tmp" "${HASHSTORE}"
  chmod 600 "${HASHSTORE}"
}
# B7: Gegenstück, wenn das Skript eine Datei selbst wieder entfernt (alte
# jail.local). Ohne diesen Aufruf bliebe der Hash der gelöschten Datei im
# Store und der Folgelauf meldete Operator-Drift für eine eigene Residuen.
forget_hash() {
  local file="$1"
  [ -f "${HASHSTORE}" ] || return 0
  awk -v f="${file}" '$2 != f' "${HASHSTORE}" 2>/dev/null | tee "${HASHSTORE}.tmp" > /dev/null || true
  mv "${HASHSTORE}.tmp" "${HASHSTORE}"
  chmod 600 "${HASHSTORE}"
}

# Atomar eine vom Setup verwaltete Datei schreiben. Die temporäre Datei liegt
# im Zielverzeichnis, damit mv dieselbe Dateisystem-Grenze nicht überschreitet.
# Bei identischem Inhalt bleibt der Ziel-Inode unangetastet; das vermeidet
# unnötige Reloads und schützt laufende Leser. Modus und Hash werden trotzdem
# nachgezogen. MANAGED_TMP wird vom EXIT-Cleanup entfernt, falls der Lauf vor
# dem mv abbricht.
write_managed() { # $1=Pfad $2=Modus $3=Drift-Label; Inhalt via stdin
  local file="$1" mode="$2" label="$3" dir base
  dir="${file%/*}"
  base="${file##*/}"
  MANAGED_TMP=$(mktemp "${dir}/.${base}.tmp.XXXXXX")
  if ! tee "${MANAGED_TMP}" > /dev/null; then
    rm -f -- "${MANAGED_TMP}" 2>/dev/null || true
    MANAGED_TMP=""
    return 1
  fi
  case "${file}" in
    *.sh)
      if ! bash -n "${MANAGED_TMP}"; then
        echo "Fehler: generiertes Skript ist syntaktisch ungültig: ${file}; vorhandene Datei bleibt erhalten." >&2
        rm -f -- "${MANAGED_TMP}"
        MANAGED_TMP=""
        return 1
      fi
      ;;
  esac
  chmod "${mode}" "${MANAGED_TMP}"
  if [ "${label}" != "-" ]; then
    note_drift "${file}" "${label}"
  fi
  if cmp -s -- "${MANAGED_TMP}" "${file}"; then
    chmod "${mode}" "${file}"
    rm -f -- "${MANAGED_TMP}"
  else
    mv -f -- "${MANAGED_TMP}" "${file}"
  fi
  MANAGED_TMP=""
  if [ "${label}" != "-" ]; then
    remember_hash "${file}"
  fi
}

# B-013: Retry max. 3 mit Schlaf + Ursachen-Log (Schulnetz!). Keine endlosen
# Retries, keine Retry-Logik um LE-Ausstellung (Budget) – nur apt/curl/pull.
# Gibt den finalen Exit-Code zurück (set -e bricht danach wie bisher ab).
retry3() {
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    elif [ "${attempt}" -ge 3 ]; then
      echo "FEHLER nach 3 Versuchen: $* – Ursache prüfen (Netz/DNS/Registry), dann Setup erneut." >&2
      return 1
    else
      echo "Versuch ${attempt} fehlgeschlagen ($*), warte 10 s vor Wiederholung ..." >&2
      sleep 10
      attempt=$((attempt + 1))
    fi
  done
}

echo "############################################################"
echo "# [1/10] Docker Engine installieren"
echo "############################################################"
# C1: Alle Cron-Zeiten dieses Skripts (Backup 01:00, Reboot 03:00, TLS-Check
# Mo 06:30) gelten in LOCALTIME. Neue VMs laufen oft auf UTC, dann schlägt das
# Backup um 03:00 Berlin an (Sommerzeit 04:00) und der Reboot mitten in der
# Nacht. Explizit setzen statt raten; idempotenter No-Op, wenn schon Berlin.
if command -v timedatectl >/dev/null 2>&1; then
  _tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [ "${_tz}" != "Europe/Berlin" ]; then
    if timedatectl set-timezone Europe/Berlin; then
      echo "Zeitzone '${_tz:-unbekannt}' -> Europe/Berlin gesetzt (C1): Backup 01:00 und Reboot 03:00 laufen in lokaler Zeit."
    else
      echo "Hinweis: Zeitzone konnte nicht gesetzt werden – Cron-Zeiten gelten in '${_tz:-unbekannt}' (C1)." >&2
    fi
  fi
fi
# C7: Paketinstallationen nicht-interaktiv und konform. Ohne
# DEBIAN_FRONTEND=noninteractive können Pakete bei vorhandener
# modifizierter Konfigurationsdatei (z.B. nach operatorseitiger Anpassung)
# auf Nachfragen warten und das Skript hängen; "--force-confold" behält in
# dem Fall die vorhandene Datei, statt eine neue Version zu überschreiben.
# Die Variable gilt nur für diesen einen Aufruf (env, kein export).
apt_install() {
  retry3 env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confold "$@"
}
retry3 apt-get update
apt_install ca-certificates curl gnupg openssl cron logrotate iproute2
install -m 0755 -d /etc/apt/keyrings
# --batch --yes: existiert die Datei bereits (jeder zweite Lauf), fragt gpg
# beim Überschreiben per /dev/tty nach – ohne TTY (ssh ohne -t, nohup) kommt
# "cannot open '/dev/tty'" mit exit 2 und set -e beendet den Lauf in Schritt 1.
curl -fsSL --retry 3 --retry-delay 5 https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# K1/F-018 (billige Hälfte, kein Digest-Pin): Fingerprint des Docker-GPG-Keys
# gegen den öffentlich dokumentierten Wert prüfen
# (https://docs.docker.com/engine/install/debian/).
# Bei Fehlschlag: Fingerprint dort neu abgleichen (Rotation), nicht einfach
# übernehmen.
DOCKER_FPR=$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.gpg 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}' || true)
if [ "${DOCKER_FPR}" != "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" ]; then
  echo "Fehler: Docker-GPG-Fingerprint unerwartet ('${DOCKER_FPR:-leer}'). Mögliche Rotation – Fingerprint unter https://docs.docker.com/engine/install/debian/ abgleichen, dann Setup erneut laufen lassen." >&2
  exit 1
fi

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

retry3 apt-get update
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# C2: Loggrößen begrenzen. Ohne Limit wächst das json-file-Logging der
# Standard-Installation bis die Root-Partition voll ist (Plattenkiller Nr. 1);
# eine projektweite compose-"logging:"-Anker-Datei deckte nur die eigenen
# Container ab, nicht z.B. "docker run"-Experimente oder spätere Projekte
# (Review 2.10: Anker entfernt, daemon.json ist die einzige Quelle).
# Deshalb hier die daemon-weite Vorgabe – und KEINE Fremdkonfiguration anfassen: eine
# vorhandene daemon.json ohne unsere Log-Schlüssel wird weder überschrieben
# (insecure-registries, live-restore, mirrors gingen verloren) noch still
# gemergt (kein jq/python3 als Abhängigkeit), sondern der Lauf bricht mit
# Reparaturanleitung ab. Fremddatei MIT den Schlüsseln: in Ruhe lassen.
DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_DAEMON_CHANGED=0
if [ -f "${DAEMON_JSON}" ]; then
  if grep -q '"max-size"' "${DAEMON_JSON}" && grep -q '"max-file"' "${DAEMON_JSON}"; then
    echo "daemon.json vorhanden und enthält bereits max-size/max-file – wird nicht überschrieben."
  else
    echo "Fehler: ${DAEMON_JSON} existiert, enthält aber kein Log-Limit (max-size/max-file)." >&2
    echo "Das Setup schreibt fremde Docker-Konfigurationen nicht um und kann sie ohne jq nicht mergen." >&2
    echo "Von Hand ergänzen (bestehende Schlüssel behalten):" >&2
    echo '  {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' >&2
    echo "danach: sudo systemctl restart docker ; Setup erneut ausführen." >&2
    exit 1
  fi
else
  install -d -m 0755 /etc/docker
  tee "${DAEMON_JSON}" > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
  chmod 644 "${DAEMON_JSON}"
  DOCKER_DAEMON_CHANGED=1
fi
# Die Optionen liest der Daemon nur beim Start. Neu starten nur, wenn WIR die
# Datei gerade geschrieben haben – und nur, wenn keine eigenen Container laufen
# (sonst wäre das ein ungefragter Ausfall). Läuft der Stack schon, sind seine
# Container ohnehin mit dem alten Log-Treiber gestartet; wirkt die Änderung
# dann erst beim nächsten geplanten Neustart, wird das hier ausdrücklich
# gewarnt, statt es still hinzunehmen.
if [ "${DOCKER_DAEMON_CHANGED}" -eq 1 ]; then
  if [ -n "$(docker compose -f /opt/coder/docker-compose.yml ps -q 2>/dev/null || true)" ]; then
    warn "daemon.json geschrieben, aber eigene Container laufen – Docker wird NICHT neu gestartet. Log-Limit greift erst nach 'sudo systemctl restart docker' (C2)"
  else
    systemctl restart docker
    echo "Docker-Daemon neu gestartet – Log-Limit (10m x 3) gilt ab jetzt."
  fi
fi

# GID der docker-Gruppe merken – wird gleich für den Docker-Socket-Zugriff
# des Coder-Containers gebraucht (offizielles Coder-Docker-Setup verlangt das).
# pipefail würde einen fehlenden Group-Eintrag sonst als stillen Abbruch ohne
# Meldung beenden (cut läuft trotzdem, Pipeline-Status != 0) – hier laut.
DOCKER_GID=$(getent group docker | cut -d: -f3 || true)
if [ -z "${DOCKER_GID}" ]; then
  echo "Fehler: Gruppe 'docker' nicht gefunden – Docker-Installation prüfen (groupadd docker)." >&2
  exit 1
fi

# Optional: eigenen Benutzer der docker-Gruppe hinzufügen, damit du Docker
# ohne sudo bedienen kannst (danach einmal neu einloggen).
# sudo usermod -aG docker "$USER"

echo "############################################################"
echo "# [2/10] Verzeichnis und Konfigurationsdateien anlegen"
echo "############################################################"
mkdir -p /opt/coder/backups
chmod 700 /opt/coder/backups
cd /opt/coder

# Geheimnisse nur beim ersten Lauf erzeugen, damit ein erneutes Ausführen
# des Skripts nicht die bestehende Datenbank-Anmeldung zerstört.
# F-006 (mit P-010/P-011): atomar schreiben ohne 644-Fenster, vorhandene
# .env auf Vollständigkeit prüfen. Eine unvollständige .env wird NIEMALS
# still neu gewürfelt (das würde die DB-Anmeldung zerstören) – stattdessen
# Abbruch mit Reparaturanleitung. P-010: "umask 077" in dieser Shell wirkt
# nicht durch "tee" hindurch (tee läuft mit root-umask),
# daher "install -m 600" vor dem Schreiben.
if ! [[ "${DOCKER_GID:-}" =~ ^[0-9]+$ ]]; then
  echo "Fehler: docker-GID konnte nicht ermittelt werden (getent group docker lieferte '${DOCKER_GID:-leer}'). .env wird nicht angefasst." >&2
  exit 1
fi
if [ ! -f /opt/coder/.env ]; then
  # A5/P-011: fehlt die .env NUR teilweise, bricht das Skript unten ab. Fehlt
  # sie ganz, würde dieser Zweig frische Passwörter würfeln, während
  # coder_postgres_data die alten behält – Coder käme nicht mehr an die DB
  # (Crashloop) und nichts würde warnen. Also vor dem Würfeln prüfen, ob die
  # Datenbank-Volume schon existiert; im Zweifel abbrechen statt zerstören.
  DOCKER_VOLUMES="$(docker volume ls -q 2>/dev/null || true)"
  if grep -qx 'coder_postgres_data' <<< "${DOCKER_VOLUMES}"; then
    echo "Fehler: /opt/coder/.env fehlt, aber das Volume coder_postgres_data existiert." >&2
    echo "Abbruch ohne Änderung – neu gewürfelte Passwörter würden die bestehende" >&2
    echo "Datenbank-Anmeldung zerstören." >&2
    echo "Reparatur: Ein SQL-Backup enthält die .env und ihre Passwörter NICHT." >&2
    echo "Eine separat gesicherte .env wiederherstellen oder nach RESTORE.md mit" >&2
    echo "neuen Zugangsdaten neu aufsetzen; Volume NICHT löschen." >&2
    exit 1
  fi
  # hex statt base64: garantiert nur 0-9a-f, kann also nie ein "/", "+" oder
  # "=" enthalten, das in der Postgres-Connection-URL (postgres://user:PASS@host)
  # die URL zerlegen bzw. falsch interpretiert werden würde.
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)

  ENV_TMP=$(mktemp /opt/coder/.env.tmp.XXXXXX)
  # 600 VOR dem Schreiben festlegen: tee kürzt nur, erzeugt nicht neu,
  # der Modus bleibt also 600 – kein 644-Fenster (P-010).
  install -m 600 /dev/null "$ENV_TMP"
  chown root:root "$ENV_TMP"
  tee "$ENV_TMP" > /dev/null <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
EOF
  chown root:root "$ENV_TMP"
  chmod 600 "$ENV_TMP"
  mv "$ENV_TMP" /opt/coder/.env
  ENV_TMP=""

  echo "------------------------------------------------------------"
  echo "Grafana-Admin-Passwort wurde in /opt/coder/.env (Modus 600) gespeichert."
  echo "Bei Bedarf gezielt abrufen: sudo sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /opt/coder/.env"
  echo "Das interne Postgres-Passwort bleibt ebenfalls in /opt/coder/.env."
  echo "------------------------------------------------------------"
elif grep -qE '^POSTGRES_PASSWORD=[^[:space:]]+' /opt/coder/.env \
  && grep -qE '^GRAFANA_ADMIN_PASSWORD=[^[:space:]]+' /opt/coder/.env; then
  echo "/opt/coder/.env existiert bereits und ist vollständig – wird nicht überschrieben."
  # B2-003: Newline/NUL im .env-Wert hart abweisen, bevor der Werteparitäts-
  # Check grün meldet. Ein Hand-Edit kann den Wert über eine zweite Zeile
  # fortsetzen; grep/cut und docker compose lesen dann nur die erste Zeile.
  if [ "$(sh -c 'LC_ALL=C tr -d -c "\000" < /opt/coder/.env | wc -c')" -ne 0 ] \
    || grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=|^#|^$' /opt/coder/.env; then
    echo "Fehler: .env-Wert enthält Newline/NUL – wird nicht still getrimmt." >&2
    echo "Reparatur: fehlerhafte .env-Zeile manuell korrigieren (einzeiliger Wert je Schlüssel), danach Setup erneut." >&2
    exit 1
  fi
  # B-014/B2-003: Hex-Validierung bleibt fail-closed (auch im Setup-Re-Run),
  # Nicht-Hex-Werte brechen die Postgres-Connection-URL. reset-passwords.sh
  # würfelt nur noch GRAFANA_ADMIN_PASSWORD neu; POSTGRES_PASSWORD muss
  # manuell in DB und .env abgeglichen werden (TROUBLESHOOTING.md A4).
  if ! grep -qE '^POSTGRES_PASSWORD=[0-9a-f]+$' /opt/coder/.env \
    || ! grep -qE '^GRAFANA_ADMIN_PASSWORD=[0-9a-f]+$' /opt/coder/.env; then
    echo "Fehler: /opt/coder/.env enthält Nicht-Hex-Passwörter." >&2
    echo "Reparatur: siehe TROUBLESHOOTING.md (A4), danach Setup erneut." >&2
    exit 1
  fi
else
  echo "Fehler: /opt/coder/.env existiert, ist aber unvollständig (mindestens ein Schlüssel fehlt/leer)." >&2
  echo "Abbruch ohne Änderung – Passwörter werden NICHT neu gewürfelt (neu würfeln würde die Datenbank-Anmeldung zerstören)." >&2
  echo "Reparatur: fehlende Schlüssel in /opt/coder/.env ergänzen (vorhandene Werte behalten) oder bei Totalverlust Restore nach Runbook; danach Setup erneut laufen lassen." >&2
  exit 1
fi

# docker-compose.yml
# WICHTIG: \${...} bleibt hier absichtlich für Docker Compose stehen (wird aus
# /opt/coder/.env aufgelöst); ${DOMAIN_CODER} etc. werden dagegen jetzt von
# der Shell eingesetzt.
# P-007: Log-Limit kommt daemon-weit aus /etc/docker/daemon.json (C2, 10m x 3)
# und deckt damit auch fremde Container; ein eigenes compose-logging wäre nur
# eine zweite Quelle fuer denselben Wert.
# C9: Fester Projektname. Sonst leitet compose den Projektnamen aus dem
# Verzeichnis ab (/opt/coder -> "coder") – ein Umbenennen/Umziehen des
# Verzeichnisses würde die laufenden Container als fremd behandeln und einen
# zweiten Stack nebenan aufbauen. Gleichzeitig ist der Name damit unabhängig
# davon, von wo aus compose aufgerufen wird.
write_managed "/opt/coder/docker-compose.yml" 644 "docker-compose.yml" <<EOF
name: coder

services:
  postgres:
    image: postgres:18-alpine
    container_name: coder-postgres
    restart: unless-stopped
    # B-011: längere Shutdown-Gnade nur für Postgres (längere Checkpoint-/
    # WAL-Phase bei Reboot 03:00). Keine pauschale Grace für alle Services.
    stop_grace_period: 30s
    environment:
      POSTGRES_DB: coder
      POSTGRES_USER: coder
      POSTGRES_PASSWORD: "\${POSTGRES_PASSWORD}"
    volumes:
      # PostgreSQL 18 Layout (docker-library/postgres #1259): ab Major 18
      # liegen die Daten unter /var/lib/postgresql/<major>/; das alte Mount
      # /var/lib/postgresql/data laesst das 18er-Image absichtlich nicht
      # starten (Fehler "data in unused mount"). Weiterhin gleicher Volume-
      # Name, also gleicher Rollback-/Reset-Pfad.
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coder -d coder"]
      interval: 5s
      timeout: 5s
      retries: 5

  coder:
    image: ghcr.io/coder/coder:${CODER_VERSION}
    container_name: coder
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    # Gibt dem Coder-Container Schreibrechte auf den gemounteten Docker-Socket
    # des Hosts (offizielles Setup, siehe coder.com/docs/install/docker).
    # Die aktuelle GID wird hier direkt eingetragen (kein .env-Umweg): der
    # Wert muss beim Schreiben stimmen, ein Hand-Edit der .env würde sonst
    # still wirkungslos bleiben. Ein erneuter Setup-Lauf gleicht ihn an.
    group_add:
      - "${DOCKER_GID}"
    environment:
      - CODER_PG_CONNECTION_URL=postgres://coder:\${POSTGRES_PASSWORD}@postgres:5432/coder?sslmode=disable
      - CODER_HTTP_ADDRESS=0.0.0.0:3000
      - CODER_ACCESS_URL=https://${DOMAIN_CODER}
      - CODER_WILDCARD_ACCESS_URL=*.${DOMAIN_CODER}
      - CODER_PROMETHEUS_ENABLE=true
      - CODER_PROMETHEUS_COLLECT_AGENT_STATS=true
      - CODER_PROMETHEUS_ADDRESS=0.0.0.0:2112
      # B6: Telemetrie an Coder, Inc. bewusst aus – unabhängig davon, was der
      # Build aktuell standardmäßig tut (Review 1.8: keine unbelegten
      # Editions-Behauptungen im Kommentar).
      - CODER_TELEMETRY_ENABLE=false
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

  caddy:
    image: caddy:${CADDY_VERSION}
    container_name: coder-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"  # HTTP/3 (QUIC) - Caddy nutzt das automatisch, wenn der Port da ist
    volumes:
      # Verzeichnis statt Einzeldatei: docker bindet eine Datei beim Container-
      # start an deren Inode. write_managed ersetzt sie per mv – der Container
      # sähe sonst bis zum Recreate die ALTE Datei, während validate/reload im
      # Container die neue bestätigen würden. Ein Verzeichnis-Mount zeigt auf
      # den jeweils aktuellen Inode.
      - ./caddy:/etc/caddy:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - coder

  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: coder-prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      # Explizit statt sich auf den (aktuell gleichen) Standardwert zu
      # verlassen: begrenzt, wie weit die Prometheus-Datenbank auf der
      # kleinen Schul-VM anwachsen kann.
      - --storage.tsdb.retention.time=15d
    volumes:
      # Dasselbe Prinzip wie oben bei caddy: Verzeichnis-Mount, damit eine per
      # mv ersetzte prometheus.yml den laufenden Container wirklich erreicht.
      # Die Alarmregeln liegen darunter (./prometheus/rules) und brauchen keinen
      # eigenen Mount mehr; Schritt 3 sendet SIGHUP nur bei tatsächlicher
      # Änderung (Konfiguration + Regeln werden erst neu geladen).
      - ./prometheus:/etc/prometheus:ro
      - prometheus_data:/prometheus
    # Nur lokal erreichbar (kein öffentlicher Port, kein Login vorhanden)
    ports:
      - "127.0.0.1:9090:9090"

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: coder-node-exporter
    restart: unless-stopped
    pid: host
    # Nur lesend eingebunden, damit Host-Metriken (u.a. freier Speicherplatz)
    # in Prometheus/Grafana sichtbar werden - bisher hing der fertige
    # Monitoring-Stack nur an Coders eigenen App-Metriken, ohne jede Sicht auf
    # den Host selbst.
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro,rslave
      # C1: textfile-collector. backup.sh schreibt nach jedem erfolgreichen Lauf
      # /opt/coder/node-textfile/coder_backup.prom (mode 644, atomar). Read-only
      # ist hier richtig: geschrieben wird vom Host, der Container liest nur.
      - ./node-textfile:/var/lib/node-exporter/textfile:ro
    command:
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
      - --path.rootfs=/rootfs
      - --collector.textfile.directory=/var/lib/node-exporter/textfile
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\$\$|/)
    ports:
      - "127.0.0.1:9100:9100"

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: coder-grafana
    restart: unless-stopped
    environment:
      # Wirkt nur beim allerersten Start (leere grafana_data). Passwort danach
      # ändern: sudo /opt/coder/reset-passwords.sh
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_ADMIN_PASSWORD}
      # Kein GF_SERVER_ROOT_URL nötig – Zugriff läuft per SSH-Tunnel auf
      # 127.0.0.1:3001, nicht über eine eigene Domain.
      # Telemetrie/Update-Checks an Grafana Inc. aus (Review 1.8): passt zur
      # bewusst telemetriefreien Haltung des Stacks (siehe CODER_TELEMETRY).
      - GF_ANALYTICS_REPORTING_ENABLED=false
      - GF_ANALYTICS_CHECK_FOR_UPDATES=false
    # Zusätzlich lokal erreichbar für Direktzugriff/Debugging
    ports:
      - "127.0.0.1:3001:3000"
    volumes:
      # C3: Datasource-Quittung (provisioniert, statt manuell im UI einzutragen).
      # Nur das Unterverzeichnis gemountet, damit der Rest von
      # /etc/grafana/provisioning des Images erhalten bleibt.
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
      - grafana_data:/var/lib/grafana
    depends_on:
      - prometheus

volumes:
  postgres_data:
  caddy_data:
  caddy_config:
  prometheus_data:
  grafana_data:
EOF

# Caddyfile – echtes, öffentlich vertrauenswürdiges Let's-Encrypt-Zertifikat,
# inklusive Wildcard-Subdomain für Coder-Workspace-Apps (Port-Forwarding,
# code-server-Vorschau etc. laufen über eigene Subdomains).
#
# Wildcard-Zertifikate lassen sich nicht per normaler HTTP-01-Challenge
# ausstellen (die validiert immer nur EINEN konkreten Hostnamen). Caddys
# On-Demand-TLS holt das Zertifikat beim ersten Aufruf einer neuen Subdomain
# (5-30 s länger beim allerersten Aufruf). "Echte" Wildcard-Zertifikate ohne
# diese Verzögerung bräuchten einen eigenen Caddy-Build mit DNS-Provider-
# Plugin (z.B. Cloudflare/Route53) – dafür fehlt ein API-Token (D-TLS).
#
# Aufbau (B1):
#   - Global: On-Demand-TLS mit ask-Endpunkt auf 127.0.0.1:9123.
#   - :9123: der ask-Endpunkt selbst. REIN innerhalb des Containers (der Port
#     steht nicht in "ports:" der compose-Datei), also ohne ufw-Regel und von
#     außen nicht erreichbar. Antwort 200 = Zertifikat erlaubt, 404 = verboten.
#   - Apex (${DOMAIN_CODER}): OHNE on_demand – Zertifikat beim Start über
#     HTTP-01, Erneuerung durch Caddy. Berührt das On-Demand-Budget nicht.
#   - Wildcard (*.${DOMAIN_CODER}): MIT on_demand, der ask-Endpunkt prüft das
#     Muster. Ein Angreifer bekommt damit kein Zertifikat für beliebige
#     Namen; für Namen IM Muster kann er es weiterhin auslösen – das Muster
#     ist ein grober Filter, kein Budget-Schutz (P-005, Dokumentation in
#     SECURITY.md). Wochenbudget 50/Woche pro registrierter Domain bleibt bis
#     D-TLS (DNS-01-Wildcard ohne On-Demand) das Thema. Erkennung: Caddy-Log
#     auf "obtaining certificate" / check-tls.sh beobachten.
#
# Muster (Quelle: Coder-Quellcode coderd/workspaceapps/appurl/appurl.go,
# Format "{PORT/APP_SLUG}[--{AGENT_NAME}]--{WORKSPACE_NAME}--{USERNAME}":
#     8080--main--myworkspace--john.${DOMAIN_CODER}         (App/Port-Forward)
#     33295s--agent--workspace--user--apps.${DOMAIN_CODER}  (HTTPS-Port)
# Erste Label muss also mindestens zwei "--"-Trenner tragen und nur aus
# Buchstaben/Ziffern/Einfach-Bindestrich bestehen. Punkte in der ersten Label
# sind ausgeschlossen – damit bleiben "evil.${DOMAIN_CODER}",
# "a.b.${DOMAIN_CODER}" und der Apex selbst draußen. Richtige Warnung bei
# unbekannter Coder-Version: Muster gegen die Coder-Doku prüfen, nicht den
# Code raten lassen.
# DOMAIN_CODER_REGEX enthaelt KEINE Backslashes in den Punktgruppen ([.]
# statt "\.") und KEIN "$"-Escaping-Probleme, weil CEL-Strings in Caddy dort
# keine Escape-Sequenzen kennen – deshalb die Klammern-Variante.
DOMAIN_CODER_ESC="$(printf '%s' "${DOMAIN_CODER}" | sed 's/\./[.]/g')"
DOMAIN_CODER_REGEX="^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*(--[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*){2,}[.]${DOMAIN_CODER_ESC}\$"
# C9: Optionaler eigener ACME-Endpunkt (ACME_CA), z.B. um gegen das
# Let's-Encrypt-Staging zu testen, ohne das Wochenbudget der Produktions-CA zu
# verbrauchen. Leer = Caddys Standard. Die Zeile entsteht nur, wenn gesetzt –
# ein leeres "acme_ca" ohne Argument wäre ungültig. Gehört in den GLOBALen
# Block, nicht in "issuer acme { }": dort ist "acme_ca" kein gültiges
# Property (mit caddy:2.10 nachgeprüft: "unrecognized ACME issuer property"),
# während die globale Option in beide Issuer (Apex + On-Demand) durchschlägt.
CADDY_ACME_CA=""
if [ -n "${ACME_CA:-}" ]; then
  CADDY_ACME_CA="    acme_ca ${ACME_CA}"
fi
# Lauf-Status VOR Schritt 3 (Reload/Neustart-Entscheidung unten). Pfad der
# Caddyfile unter /opt/coder/caddy, weil die compose-Datei das Verzeichnis
# statt der Einzeldatei bindet.
CADDY_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' coder-caddy 2>/dev/null || echo false)
# A2: Domain einmalig ablegen. boot-check.sh und update.sh haben sie vorher
# per awk aus der Caddyfile gezogen und dabei auf die @askOK-Matcherzeile
# gegriffen (enthält "*" und "{2,}", Zeile beginnt mit Leerzeichen -> $1 leer):
# Ergebnis "Apex nicht parsbar" und übersprungener TLS-Smoke. Datei ist ein
# reines Artefakt dieses Skripts, wird bei jedem Lauf neu geschrieben – kein
# Drift-Check nötig.
write_managed "/opt/coder/domain" 644 - <<EOF
${DOMAIN_CODER}
EOF
# write_managed legt Verzeichnisse nicht an (Vorbild: rules/grafana unten).
install -d -m 0755 /opt/coder/caddy
write_managed "/opt/coder/caddy/Caddyfile" 644 "Caddyfile" <<EOF
{
${CADDY_ACME_CA}
    email ${ACME_EMAIL}
    on_demand_tls {
        # Caddy 2.9+ empfiehlt permission; ask ist deprecated.
        permission http http://127.0.0.1:9123/ask
    }
}

:9123 {
    @askOK expression \`{http.request.uri.path} == "/ask" && matches({http.request.uri.query.domain}, '${DOMAIN_CODER_REGEX}')\`
    handle @askOK {
        respond "ok" 200
    }
    handle {
        respond "not found" 404
    }
}

${DOMAIN_CODER} {
    reverse_proxy coder:3000
}

*.${DOMAIN_CODER} {
    reverse_proxy coder:3000
    tls {
        on_demand
    }
}
EOF

# Review 2.6: Prometheus bekommt SIGHUP bei jedem Lauf, solange es lief –
# Reload statt Neustart (P-025), ohne Hash-Vergleich: ein SIGHUP auf
# unveränderte Regeln ist ein No-Op (braucht kein --web.enable-lifecycle).
# Nur Grafana hat keine Reload-API und braucht weiterhin den Hash – dessen
# Neustart ist invasiv und bleibt an die tatsächliche Änderung gebunden.
# Grafana liest Provisioning-Dateien nur beim Start.
GRAFANA_PROV_BEFORE=$(sha256sum /opt/coder/grafana/provisioning/datasources/prometheus.yml 2>/dev/null | cut -d' ' -f1 || true)
# Lauf-Status VOR dem Schreiben (gleiche Idee wie CADDY_WAS_RUNNING): nur ein
# Container, der schon mit der alten Datei lief, braucht danach einen Neustart.
PROM_CFG_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' coder-prometheus 2>/dev/null || echo false)
GRAFANA_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' coder-grafana 2>/dev/null || echo false)

# prometheus.yml (komplettes Verzeichnis gemountet, siehe compose)
install -d -m 0755 /opt/coder/prometheus
write_managed "/opt/coder/prometheus/prometheus.yml" 644 "prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: 'coder'
    static_configs:
      - targets: ['coder:2112']
  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']
EOF

# C3: Alarmregeln (einzige Alarmkanäle ohne Alertmanager: Prometheus-eigenen
# /alerts + Grafana). Drei Regeln, alle mit messbarer Grundlage:
#   1. Coder-Target down  2. Root-Partition <10% frei  3. letztes Backup >25h.
# Kein "absent()"-Zweig für Regel 3: fehlende Metrik = seit Aufsetzen noch
# kein Backup gelaufen, das meldet ohnehin das erste erfolgreiche Laufdatum;
# ehrlicher als ein Alarm direkt nach der Installation.
install -d -m 0755 /opt/coder/prometheus/rules
write_managed "/opt/coder/prometheus/rules/coder-alerts.yml" 644 - <<'EOF'
groups:
  - name: coder
    rules:
      - alert: CoderTargetDown
        expr: up{job="coder"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Coder-Metriken werden seit 2 min nicht mehr abgefragt"
          description: "Prometheus erreicht coder:2112 nicht – Coder-Container prüfen: docker ps / docker logs coder"
      - alert: RootPartitionFillingUp
        expr: node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Root-Partition unter 10% frei"
          description: "Backups, Images und Container-Logs liegen auf derselben Platte: df -h /"
      - alert: BackupStale
        expr: time() - coder_backup_last_success_timestamp_seconds > 90000
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Kein erfolgreiches Backup seit über 25 Stunden"
          description: "Letzter Erfolg siehe /opt/coder/node-textfile/coder_backup.prom, Log: /var/log/coder-backup.log"
      - alert: TlsIssuanceBudgetHigh
        expr: coder_tls_issuances_7d > 20
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Über 20 Zertifikats-Ausstellungen in 7 Tagen"
          description: "Untergrenze aus den noch vorhandenen Caddy-Logs; Rotation kann Eintraege der letzten 7 Tage bereits verworfen haben. Wert: /opt/coder/node-textfile/coder_tls.prom"
      - alert: TlsCheckStale
        expr: absent(coder_tls_check_last_success_timestamp_seconds) or time() - coder_tls_check_last_success_timestamp_seconds > 691200
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "TLS-Ausstellungscheck fehlt oder ist älter als 8 Tage"
          description: "Cron, Caddy-Logs oder Textfile-Metrik pruefen; bei veralteter Metrik ist der 7-Tage-Zaehler nicht aussagekraeftig."
      - alert: TlsLogTruncated
        expr: coder_tls_log_truncated == 1
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Caddy-Logpuffer reicht nicht bis 7 Tage zurueck"
          description: "Logrotation (10 MB x 3) hat Eintraege der letzten 7 Tage verworfen; coder_tls_issuances_7d ist deshalb nur eine Untergrenze. Wert: /opt/coder/node-textfile/coder_tls.prom"
EOF

# C3: Datasource für Grafana provisioning statt manuelle UI-Konfigurations-
# Eintragung. Betrifft nur den Beginn der Container-Welt; ob provisioniert
# wurde, sieht der erste Start in den Grafana-Logs.
install -d -m 0755 /opt/coder/grafana/provisioning/datasources
write_managed "/opt/coder/grafana/provisioning/datasources/prometheus.yml" 644 - <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    uid: coder-prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOF

# C1: Zielverzeichnis der Backup-Metrik. MUSS 0755 sein: backup.sh läuft mit
# "umask 077" und würde das Verzeichnis sonst anlegen, wenn es fehlt – dann
# könnte node-exporter die Datei nicht lesen und die Metrik bliebe tot.
install -d -m 0755 /opt/coder/node-textfile

GRAFANA_PROV_AFTER=$(sha256sum /opt/coder/grafana/provisioning/datasources/prometheus.yml | cut -d' ' -f1)

echo "############################################################"
echo "# [3/10] Docker-Stack starten"
echo "############################################################"
cd /opt/coder

# B-013-Preflights (lesend bis auf Daemon-Fail): toter Daemon und volle
# Platte endeten bisher in set -e-Tod mit Roh-Fehlermeldung. Daemon-Fail ist
# hart (früh + klar statt spät in Schritt 3); Platte WARN ab 1 GB (grober
# Hinweis, kein Ersatz für D-Monitoring).
if ! docker info > /dev/null 2>&1; then
  echo "Fehler: Docker-Daemon antwortet nicht (docker info). Erst Daemon heilen, dann Setup erneut." >&2
  exit 1
fi

if _avail=$(df --output=avail -B1 /opt/coder 2>/dev/null | tail -n1 | tr -d ' '); then
  if [ "${_avail}" -lt 1073741824 ]; then
    warn "Wenig Platte unter /opt/coder (${_avail} < 1 GB, grober Hinweis) – Images/Backups brauchen Luft"
  fi
fi

# Validiert YAML-Syntax und Variablen-Interpolation, bevor überhaupt etwas
# gestartet wird - ein Fehler hier ist deutlich klarer als ein kryptischer
# Fehler mitten in "docker compose up".
docker compose config --quiet

# A6: erst alle Images ziehen, dann starten. Vor B-013 gab es hier kein Pull –
# bei fehlendem/falschem Tag (z.B. coder/coder:2.36.6 ohne "v") scheiterte erst
# "up -d" mitten im Lauf. Ein eigener Manifest-Preflight ist überflüssig:
# "docker compose pull" nennt den fehlenden Tag im Fehlerfall ohnehin und
# bricht vor jedem Container-Start ab.
retry3 docker compose pull

# 1.1/Review: KEIN Upgrade ohne frisches Backup. Schritt 3 zieht Bilder und
# "up -d" kann eine Coder-DB-Schema-Migration ausführen – ohne Dump wäre danach
# kein Rollback möglich. Nur wenn die DB schon läuft und backup.sh existiert
# (Erstlauf: beides nicht -> kein Backup nötig). Der Wartungs-Lock hängt schon
# an diesem Prozess (CODER_MAINTENANCE_LOCK_HELD=1), backup.sh erwirbt keinen
# zweiten. Fehlschlag bricht vor "up -d" ab, nichts ist verändert.
if [ "$(docker inspect -f '{{.State.Running}}' coder-postgres 2>/dev/null || echo false)" = "true" ] \
  && [ -x /opt/coder/backup.sh ]; then
  echo "Ziehe Pre-Upgrade-Backup vor möglicher DB-Migration ..."
  if ! env CODER_MAINTENANCE_LOCK_HELD=1 /opt/coder/backup.sh; then
    echo "FEHLER: Pre-Upgrade-Backup fehlgeschlagen – Abbruch vor 'docker compose up -d'." >&2
    echo "Ursache prüfen (Platte/Postgres), Backup laufen lassen, dann Setup erneut." >&2
    exit 1
  fi
fi

# Erstlauf-Validierung mit genau den Images, die anschließend gestartet werden.
# Caddy lädt Zertifikate erst zur Laufzeit; validate prüft die Caddyfile, ohne
# den bestehenden Stack zu ändern. promtool prüft Konfiguration und Regeln.
echo "Validiere Caddyfile, Prometheus-Konfiguration und Alarmregeln vor dem Start ..."
# caddy:2.10 hat KEINEN ENTRYPOINT (nur CMD ["caddy","run",...]) – ohne
# --entrypoint würde "validate" selbst als Binary ausgeführt und scheitert
# mit 'executable file not found in $PATH'.
docker run --rm --entrypoint caddy -v /opt/coder/caddy:/etc/caddy:ro "caddy:${CADDY_VERSION}" validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker run --rm --entrypoint /bin/promtool -v /opt/coder/prometheus:/etc/prometheus:ro "prom/prometheus:${PROMETHEUS_VERSION}" check config /etc/prometheus/prometheus.yml
docker run --rm --entrypoint /bin/promtool -v /opt/coder/prometheus:/etc/prometheus:ro "prom/prometheus:${PROMETHEUS_VERSION}" check rules /etc/prometheus/rules/coder-alerts.yml

docker compose up -d

# A7/A1: wirksam gewesene Versionen erst JETZT persistieren – genau ab dem
# Moment, in dem die neuen Images laufen (ein Abbruch vor "up -d" darf keine
# nie gelaufene Version als wirksam eintragen, ein Abbruch DANACH darf keine
# bereits migrierte DB ungeschützt lassen). "install -d" sichert den Pfad,
# falls dieser Block je früher stünde (A1: tee legt keine Verzeichnisse an).
install -d -m 0755 /opt/coder
write_managed "${VERSIONS_FILE}" 644 - <<VERSIONSEOF
# Von setup-coder.sh erzeugt – wirksam gewesene Versionen des letzten Laufs.
# Kein Geheimnis, daher 644 (unten ohne sudo lesbar).
CODER_VERSION=${CODER_VERSION}
CADDY_VERSION=${CADDY_VERSION}
PROMETHEUS_VERSION=${PROMETHEUS_VERSION}
GRAFANA_VERSION=${GRAFANA_VERSION}
NODE_EXPORTER_VERSION=${NODE_EXPORTER_VERSION}
VERSIONSEOF

# Review 2.6: validate + reload bei JEDEM Lauf, solange Caddy lief. Reload
# geht über die Admin-API (verbindungserhaltend – P-025 verbietet nur
# Restarts), ist bei unveränderter Datei ein No-Op und fängt damit auch
# Abweichungen ab, die nicht über write_managed entstanden sind. Ohne
# Hash-Vergleich: eine ungültige Datei meldet "caddy validate" vor dem
# Neuladen, Caddy behält dann die laufende Konfiguration (kein Ausfall).
# "restart" ist bewusst KEIN Fallback (C4). Erstlauf ohne laufendes Caddy
# braucht kein Reload – "up -d" hat den Container gerade mit der Datei
# gestartet.
if [ "${CADDY_WAS_RUNNING}" = "true" ]; then
  if docker exec coder-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1; then
    if docker exec coder-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1; then
      ok "Caddy validate + reload OK (ohne Verbindungsabbruch) (C4)"
    else
      warn "caddy reload fehlgeschlagen – Caddy läuft weiter mit der ALTEN Konfiguration. Manuell prüfen: sudo docker exec coder-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile (C4)"
    fi
  else
    fail "Caddyfile ungültig (caddy validate rot) – Caddy behält die laufende Konfiguration, kein Ausfall. Fehler anzeigen mit: sudo docker exec coder-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile (C4)"
  fi
else
  echo "Caddy lief vorher nicht (Erstlauf) – kein Reload nötig, up -d startet ihn mit der Datei."
fi

# C3: Prometheus-Dateien und Grafana-Provisioning liegen als Bind-Mounts im
# Container – "docker compose up -d" erkennt deren Inhalt NICHT.
if [ "${PROM_CFG_WAS_RUNNING}" = "true" ]; then
  if docker kill -s HUP coder-prometheus > /dev/null 2>&1; then
    ok "Prometheus per SIGHUP neu geladen (Konfiguration und Alarmregeln) (C3)"
  else
    warn "Prometheus konnte SIGHUP nicht laden – Konfiguration manuell prüfen: sudo docker logs coder-prometheus"
  fi
else
  echo "Prometheus lief vorher nicht – kein SIGHUP (läuft mit der neuen Datei)."
fi
if [ "${GRAFANA_PROV_BEFORE}" = "${GRAFANA_PROV_AFTER}" ]; then
  echo "Grafana-Datasource unverändert – kein Neustart."
elif [ "${GRAFANA_WAS_RUNNING}" != "true" ]; then
  echo "Grafana-Datasource neu/geändert, Container lief vorher nicht – läuft bereits mit der neuen Konfiguration, kein Neustart."
elif docker restart coder-grafana > /dev/null 2>&1; then
  ok "Grafana neu gestartet, damit Provisioning greift (C3)"
else
  warn "Neustart von coder-grafana fehlgeschlagen – Konfiguration manuell nachziehen: sudo docker restart coder-grafana (C3)"
fi

docker compose ps

echo "############################################################"
echo "# [4/10] Firewall (ufw) + SSH-Schutz einrichten"
echo "############################################################"
apt_install ufw fail2ban

# B6: Die SSH-Regel unten ist fest auf "22/tcp". Lauscht sshd auf einem
# anderen Port, würde "ufw enable" den eigenen Zugang abschneiden – deshalb
# VOR der ersten Firewall-Änderung prüfen und hart abbrechen, statt sich
# auszusperren (Zugriff dann nur noch über Konsolenzugang des Hosts).
if ! SSHD_EFFECTIVE_CONFIG="$(sshd -T 2>/dev/null)"; then
  fail "sshd-Konfiguration konnte nicht gelesen werden – Abbruch vor jeder Firewall-Änderung."
  exit 1
fi
SSHD_PORTS="$(printf '%s\n' "${SSHD_EFFECTIVE_CONFIG}" | awk '/^port /{print $2}' | sort -u | xargs echo 2>/dev/null || true)"
if [ -z "${SSHD_PORTS}" ]; then
  fail "sshd -T lieferte keinen Port – Abbruch vor jeder Firewall-Änderung."
  exit 1
fi
if [ "${SSHD_PORTS}" != "22" ]; then
  echo "Fehler: sshd lauscht auf Port '${SSHD_PORTS}', dieses Skript erlaubt aber nur 22/tcp." >&2
  echo "Abbruch vor jeder Firewall-Änderung – sonst würde 'ufw enable' den SSH-Zugang schneiden." >&2
  echo "Port in setup-coder.sh anpassen (Suchbegriff: 'ufw limit 22/tcp') und erneut ausführen." >&2
  exit 1
fi

# Review 0.1/2.4 (D-SSH): schmaler fester Regelpfad statt Pfad-A/B/C-Analyse.
# Geblieben sind die Sicherheitsinvarianten:
#   - Ohne lesbaren ufw-Status wird NICHTS geaendert (Abbruch).
#   - Gespeicherte SSH-Quellregeln bei inaktiver ufw -> Abbruch vor enable.
#   - Eine vorgefundene quellbeschraenkte SSH-Regel wird nicht aufgeweicht:
#     keine weltweite limit-Regel daneben, keine Quellregel wird geloescht.
#   - Weltweite allow-Regeln (die limit wirkungslos machen wuerden) werden
#     entfernt und der Erfolg VERIFIZIERT, bevor mit limit weitergemacht wird.
if ! UFW_OUT="$(ufw status numbered 2>/dev/null)"; then
  fail "ufw-Status nicht lesbar – Abbruch vor jeder Regel-/Policy-Änderung (SSH-Schutz)."
  exit 1
fi
if ! UFW_ADDED_OUT="$(ufw show added 2>/dev/null)"; then
  fail "gespeicherte ufw-Regeln nicht lesbar – Abbruch vor jeder Regel-/Policy-Änderung (SSH-Schutz)."
  exit 1
fi
# Detektor (POSIX grep -E):22-Regeln aller Schreibweisen, danach minus
# "Anywhere" = Quellbeschraenkung. "show added" deckt zusaetzlich den
# inaktiven Fall ab (dort zeigt "ufw status" keine Regeln).
UFW_SSH_ALL="$(printf '%s\n' "${UFW_OUT}" \
  | grep -Ei '(^|[[:space:]])(22(/tcp)?|OpenSSH)([[:space:]]|\(v6\)|$)|from[[:space:]]+[^[:space:]]+[[:space:]]+to[[:space:]]+any[[:space:]]+port[[:space:]]+22([^0-9]|$)' || true)"
UFW_RESTRICTED="$(printf '%s\n' "${UFW_SSH_ALL}" \
  | grep -Ev '[[:space:]]Anywhere([[:space:]\(]|$)' || true)"
UFW_ADDED_RESTRICTED="$(printf '%s\n' "${UFW_ADDED_OUT}" \
  | grep -Ei '(^|[[:space:]])(22(/tcp)?|OpenSSH)([[:space:]]|\(v6\)|$)|from[[:space:]]+[^[:space:]]+[[:space:]]+to[[:space:]]+any[[:space:]]+port[[:space:]]+22([^0-9]|$)' \
  | grep -Ei '[[:space:]]from[[:space:]]+' \
  | grep -Eiv '[[:space:]]from[[:space:]]+(any|0\.0\.0\.0/0|::/0)([[:space:]]|$)|Anywhere' || true)"
UFW_RESTRICTED_LINE=""
if grep -qi 'Status:[[:space:]]*inactive' <<< "${UFW_OUT}"; then
  if [ -n "${UFW_ADDED_RESTRICTED}" ]; then
    fail "ufw ist inaktiv, enthält aber gespeicherte SSH-Quellregeln; Abbruch vor jeder ufw-Regel-/Policy-Änderung."
    printf 'Gespeicherte Regel(n):\n%s\n' "${UFW_ADDED_RESTRICTED}" >&2
    echo "Die Firewall bleibt unverändert. Beschränkung bewusst prüfen, UFW danach selbst aktivieren; Setup erneut ausführen." >&2
    exit 1
  fi
  warn "ufw ist inaktiv (Status: inactive) – Firewall wird jetzt eingerichtet"
elif [ -n "${UFW_RESTRICTED}" ]; then
  UFW_RESTRICTED_LINE="$(printf '%s\n' "${UFW_RESTRICTED}" | head -n 1)"
fi

# Regelanwendung (Review 0.1/2.4): einfache feste Folge. Reihenfolge erst
# Policy, dann SSH-Regeln; "limit" ist idempotent ("Skipping adding existing
# rule"), deletes auf nicht vorhandene Regeln scheitern still (|| true).
ufw default deny incoming
ufw default allow outgoing
if [ -n "${UFW_RESTRICTED}" ]; then
  warn "quellbeschränkte SSH-Regel bleibt unangetastet: ${UFW_RESTRICTED_LINE} – keine weltweite 'limit 22/tcp'-Regel gesetzt"
  if grep -Ei 'Anywhere' <<< "${UFW_SSH_ALL}" > /dev/null 2>&1; then
    warn "weltweite SSH-Regel steht NEBEN der Beschränkung, ufw wertet beide (die Quelle greift deshalb nicht) – manuell auflösen: sudo ufw status numbered"
  fi
else
  # Nur die drei weltweiten Schreibweisen einer allow-Regel; Quellregeln
  # ("allow from …") sind davon strukturell nicht betroffen.
  ufw --force delete allow 22/tcp  > /dev/null 2>&1 || true
  ufw --force delete allow 22      > /dev/null 2>&1 || true
  ufw --force delete allow OpenSSH > /dev/null 2>&1 || true
  UFW_LEFTOVER="$(ufw status numbered 2>/dev/null || true)"
  UFW_LEFTOVER="$(printf '%s\n' "${UFW_LEFTOVER}" \
    | grep -Ei '(^|[[:space:]])(22(/tcp)?|OpenSSH)([[:space:]]|\(v6\)|$)' \
    | grep -Ei '[[:space:]]Anywhere([[:space:]\(]|$)' \
    | grep -Ei '[[:space:]]ALLOW([[:space:]]|$)' || true)"
  if [ -n "${UFW_LEFTOVER}" ]; then
    fail "weltweite 'allow'-SSH-Regel steht nach dem Löschen noch (${UFW_LEFTOVER}) – manuell prüfen: sudo ufw status numbered"
    exit 1
  fi
  ufw limit 22/tcp
fi

# backend=systemd explizit setzen: Debians fail2ban-Paket hat python3-systemd
# als harte Abhängigkeit (steht so auf der offiziellen Debian-Paketseite),
# journald ist also immer verfügbar - "auto" wählt das aber nicht zuverlässig
# automatisch (bekanntes, in fail2bans eigenem Bugtracker dokumentiertes
# Verhalten auf systemd-basierten Distributionen). Eine zusätzliche
# rsyslog/auth.log-Installation ist damit unnötig und wäre auf Debian 13
# überflüssiger Overhead.
# B7/Review 1.4+2.3: Eigene Jails in einen Drop-In unter jail.d/ legen.
# Lese-Reihenfolge von fail2ban (man jail.conf):
#   jail.conf -> jail.d/*.conf -> jail.local -> jail.d/*.local
# Unser Dateiname faellt unter "jail.d/*.local" und hat damit VORRANG vor
# einer Hand-angelegten jail.local – dort geschriebene Jails greifen also
# NICHT. Deshalb WARN, solange jail.local existiert, statt sie still
# anzutasten (die alte hash-guardierte Entfernung entfiel mit Review 2.3:
# ohne Produktion gibt es keine setup-eigene Alt-Datei mehr).
# P-025: Hash VOR dem Schreiben merken (Vergleich weiter unten entscheidet
# zwischen reload/restart/start – blinder restart verwirft aktive Bans).
JAIL_DROPIN="/etc/fail2ban/jail.d/10-coder-sshd.local"
JAIL_BEFORE=$(sha256sum "${JAIL_DROPIN}" 2>/dev/null | cut -d' ' -f1 || true)
if [ -f /etc/fail2ban/jail.local ]; then
  warn "Vorgefunden: /etc/fail2ban/jail.local – unser Drop-In ${JAIL_DROPIN} hat laut Lese-Reihenfolge Vorrang, dort geschriebene Jails greifen nicht. Eigene Werte in den Drop-In übernehmen und jail.local entfernen."
fi
mkdir -p /etc/fail2ban/jail.d
# Review 0.3: bantime.increment verlängert Wiederholungssperren, ignoreip
# schützt Admin-Adressen vor der geteilten Schul-NAT (sonst sperrt ein
# Tippfehler die gemeinsame Quell-IP). Werte per FAIL2BAN_IGNORE_IP setzen:
#   sudo env FAIL2BAN_IGNORE_IP='127.0.0.1/8 ::1 <Admin-IP>' ./setup-coder.sh
write_managed "/etc/fail2ban/jail.d/10-coder-sshd.local" 644 "fail2ban-jail.d/10-coder-sshd.local" <<EOF
[sshd]
enabled  = true
backend  = systemd
port     = ssh
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
ignoreip = ${FAIL2BAN_IGNORE_IP}
EOF
# P-025: "restart" bei jedem Lauf verwirft aktive Bans (Angreifer per Re-Run
# entbannt). Daher: nur bei geänderter Datei neu laden (reload statt restart,
# mit restart als Fallback), sonst nur sicherstellen, dass der Dienst läuft
# (start ist No-Op, wenn aktiv – kein Ban-Verlust).
systemctl enable fail2ban
JAIL_AFTER=$(sha256sum "${JAIL_DROPIN}" 2>/dev/null | cut -d' ' -f1 || true)
if systemctl is-active --quiet fail2ban && [ "${JAIL_BEFORE}" = "${JAIL_AFTER}" ]; then
  echo "fail2ban läuft bereits mit unveränderter ${JAIL_DROPIN} – kein Reload (Bans bleiben erhalten, P-025)."
elif systemctl is-active --quiet fail2ban; then
  systemctl reload fail2ban || systemctl restart fail2ban
else
  systemctl start fail2ban
fi

# Hinweis: Docker trägt für per "ports:" veröffentlichte Container-Ports
# (hier 80/443 von Caddy) eigene iptables-Regeln ein, die ufw dabei
# üblicherweise umgehen – diese beiden Regeln sind also vor allem
# Dokumentation, kein zusätzlicher Schutz (B-007: "ufw status grün" heißt für
# künftige Container-Ports NICHT "geschützt"). Bindungsregel (Review-Check bei
# jedem Compose-Change): neue "ports:"-Einträge NUR als "127.0.0.1:<port>:<port>"
# binden; öffentliche Ports sind die Ausnahme und bleiben Caddy (80/443)
# vorbehalten. DOCKER-USER ja/nein erst per D-Firewall-Entscheidung nach
# Dual-Stack-Test (T-060) – kein Einbau ohne Nachweis.
# Der eigentliche Schutz für 80/443
# ist, dass dort ohnehin der öffentliche Coder-Zugang laufen soll. Bei
# Prometheus/Grafana kommt der Schutz stattdessen daher, dass deren Ports nur
# an 127.0.0.1 gebunden sind (siehe docker-compose.yml) – das wirkt unabhängig
# von ufw/Docker-iptables. Für SSH gilt das NICHT: sshd ist ein normaler
# Host-Dienst, kein Docker-Container, ufw/fail2ban greifen hier also wirklich.
# B-007/IPv6: ufw wendet dieselbe Policy auf v4+v6 an, solange IPV6=yes in
# /etc/default/ufw (Debian-Default). Pfad deklariert: Dual-Stack mit gleicher
# Policy; bei "IPV6=no" gilt nur v4 (dann WARN unten). Kein stilles Umschalten.
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable
ufw status verbose
if grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
  ok "ufw-IPv6-Pfad deklariert: IPV6=yes (gleiche Policy für v4+v6)"
else
  warn "ufw-IPv6-Pfad unklar (kein IPV6=yes in /etc/default/ufw) – Dual-Stack-Annahme gilt nicht, prüfen mit: grep IPV6 /etc/default/ufw"
fi

UFW_STATUS="$(ufw status)"
if grep -q "Status: active" <<< "${UFW_STATUS}"; then
  ok "ufw ist aktiv"
else
  fail "ufw ist NICHT aktiv"
fi
# A1: Pfad-abhängig prüfen. Ohne vorgefundene Beschränkung muss die weltweite
# Rate-Limit-Regel existieren. Mit Beschränkung (Pfad B) darf KEINE weltweite
# 22-Regel daneben stehen – ufw wertet beide parallel, die Quell-Beschränkung
# wäre dann wirkungslos (bei "ALLOW" sogar ohne Rate-Limit).
UFW_SSH_LINES="$(grep -E '(22/tcp|OpenSSH)[[:space:]]+(LIMIT|ALLOW)' <<< "${UFW_STATUS}" || true)"
if [ -n "${UFW_RESTRICTED}" ]; then
  if grep -q 'ALLOW' <<< "${UFW_SSH_LINES}" && grep -q 'Anywhere' <<< "${UFW_SSH_LINES}"; then
    fail "weltweite 'allow'-SSH-Regel steht neben der Quell-Beschränkung – jede IP könnte ohne Beschränkung auf SSH zugreifen; prüfen mit: sudo ufw status"
  elif grep -q 'LIMIT' <<< "${UFW_SSH_LINES}" && grep -q 'Anywhere' <<< "${UFW_SSH_LINES}"; then
    fail "weltweite 'limit'-SSH-Regel steht neben der Quell-Beschränkung – die Beschränkung greift dann nicht; prüfen mit: sudo ufw status"
  else
    ok "SSH quellbeschränkt: keine weltweite 22-Regel daneben, Beschränkung greift"
  fi
elif grep -q "22/tcp.*LIMIT" <<< "${UFW_SSH_LINES}"; then
  ok "SSH ist offen, aber per ufw rate-limitiert (22/tcp LIMIT)"
else
  fail "SSH-Rate-Limit-Regel fehlt in ufw – prüfen mit: sudo ufw status"
fi
if systemctl is-active --quiet fail2ban; then
  ok "fail2ban läuft"
else
  fail "fail2ban läuft NICHT"
fi
# A4: Beim ersten Start kann systemd bereits "active" melden, bevor der
# fail2ban-Socket antwortet. Bis zu 15 s auf den Client warten, ehe das Jail
# als Fehler gemeldet wird.
F2B_READY=false
for _ in $(seq 1 15); do
  if fail2ban-client ping > /dev/null 2>&1; then
    F2B_READY=true
    break
  fi
  sleep 1
done
if [ "${F2B_READY}" = "true" ] && fail2ban-client status sshd > /dev/null 2>&1; then
  ok "fail2ban-Jail 'sshd' ist aktiv"
else
  fail "fail2ban-Client oder Jail 'sshd' antwortet nach 15 s nicht – prüfen mit: sudo fail2ban-client status"
fi
# A6: Der alte Check ("fail2ban-client get sshd logpath" || "journalctl -n1")
# war immer grün – beides liefert ohne Bezug zum Jail Exit 0, der Zustand des
# Filters wurde nie geprüft. Jetzt: das Jail muss "Total failed" als Zahl
# führen, d. h. der Filter zählt wirklich Fehlversuche. Dass der Debian-13-
# Filter auch die Session-Prozesse sieht, ist ausgeliefert und 2026-09-29
# gemessen: journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd +
# _COMM=sshd-session, 63/63 Fehlversuche hatten _COMM=sshd-session.
F2B_STATUS="$(fail2ban-client status sshd 2>/dev/null || true)"
F2B_FAILED="$(printf '%s\n' "${F2B_STATUS}" | awk -F: '/Total failed/ {gsub(/[ \t]/,"",$2); print $2; exit}')"
if [ -n "${F2B_FAILED}" ] && [ "${F2B_FAILED}" -eq "${F2B_FAILED}" ] 2>/dev/null; then
  ok "fail2ban zählt SSH-Fehlversuche (Total failed: ${F2B_FAILED})"
else
  fail "fail2ban-Jail 'sshd' zählt keine Fehlversuche – prüfen mit: sudo fail2ban-client status sshd"
fi
if grep -qi '^passwordauthentication no' <<< "${SSHD_EFFECTIVE_CONFIG}" && \
   grep -qi '^kbdinteractiveauthentication no' <<< "${SSHD_EFFECTIVE_CONFIG}"; then
  ok "SSH-Passwort-Login ist deaktiviert (nur noch Keys erlaubt)"
else
  ok "SSH-Passwort-Login ist aktiv – bewusste Entscheidung (D-SSH); ufw-Rate-Limit und fail2ban sperren Wiederholer"
fi
# Review 0.3a: root per Passwort von ueberall waere ein Upgrade-Pfad jeden
# Brute-Forces – der Debian-Default prohibit-password bleibt gefordert.
if grep -qi '^permitrootlogin yes' <<< "${SSHD_EFFECTIVE_CONFIG}"; then
  warn "PermitRootLogin yes ist gesetzt – bei Passwort-SSH von überall nicht tragbar. Abschalten: PermitRootLogin prohibit-password in /etc/ssh/sshd_config, sshd neu laden (Validation-Check vor Reload)."
else
  ok "PermitRootLogin erlaubt kein root-Passwort-Login (prohibit-password/without-password)"
fi
# Anker ^ am Zeilenanfang: "443/tcp" soll nicht "8443/tcp" treffen, und die
# Spaltenabfolge verhindert, dass "22/tcp" von einer ganz anderen Regel kommt.
if grep -qE '^80/tcp[[:space:]]' <<< "${UFW_STATUS}"; then
  ok "Port 80/tcp ist in ufw freigegeben"
else
  fail "Port 80/tcp fehlt in ufw"
fi
if grep -qE '^443/tcp[[:space:]]' <<< "${UFW_STATUS}"; then
  ok "Port 443/tcp ist in ufw freigegeben"
else
  fail "Port 443/tcp fehlt in ufw"
fi
if grep -qE '^443/udp[[:space:]]' <<< "${UFW_STATUS}"; then
  ok "Port 443/udp ist in ufw freigegeben (HTTP/3)"
else
  fail "Port 443/udp fehlt in ufw"
fi

echo "############################################################"
echo "# [5/10] Automatische Sicherheitsupdates einrichten"
echo "############################################################"
retry3 apt-get update
apt_install unattended-upgrades

# Nicht-interaktive Aktivierung statt "dpkg-reconfigure -plow" (Dialog).
# Schreibt /etc/apt/apt.conf.d/20auto-upgrades.
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

# Eigene Datei statt Änderung an der von dpkg verwalteten 50unattended-upgrades
# (die würde beim nächsten Paket-Update sonst zu einem Konflikt-Dialog führen).
write_managed "/etc/apt/apt.conf.d/52-coder-reboot" 644 "52-coder-reboot" <<'EOF'
// Automatischer Neustart bei Kernel-Updates, nachts um 03:00 Uhr.
// B-011/D-Reboot-Fenster: 03:00 ist Default, kein abgestimmtes Betriebsfenster.
// Vor Produktionsfreigabe mit Schulbetrieb abstimmen + im Wartungsplan
// hinterlegen (laufende Workspaces/Sessions werden abgerissen). Boot-Gesundheit
// prüft /opt/coder/boot-check.sh (lesend, @reboot, kein Eingriff).
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

APT_UU_CONFIG="$(apt-config dump 2>/dev/null || true)"
if grep -Fq 'o=Docker' <<< "${APT_UU_CONFIG}"; then
  warn "Die wirksame APT-Konfiguration enthält weiterhin eine Docker-Origin für unattended-upgrades; prüfen mit: grep -rn 'o=Docker' /etc/apt/apt.conf.d/"
else
  ok "Docker-Origin ist nicht für unattended-upgrades freigegeben"
fi

if systemctl is-active --quiet unattended-upgrades; then
  ok "unattended-upgrades-Dienst läuft"
else
  fail "unattended-upgrades-Dienst läuft nicht"
fi
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && \
   grep -qF 'APT::Periodic::Unattended-Upgrade "1";' <<< "${APT_UU_CONFIG}"; then
  ok "Automatische Update-Prüfung ist aktiviert"
else
  fail "Automatische Update-Prüfung (20auto-upgrades) fehlt oder ist deaktiviert"
fi
if grep -qF 'Unattended-Upgrade::Automatic-Reboot "true";' <<< "${APT_UU_CONFIG}" && grep -qF 'Unattended-Upgrade::Automatic-Reboot-Time "03:00";' <<< "${APT_UU_CONFIG}"; then
  ok "Automatischer Neustart um 03:00 Uhr ist konfiguriert"
else
  fail "Reboot-Konfiguration (52-coder-reboot) fehlt"
fi

# B-011: lesendes Boot-Gate (kein Eingriff, nur Logging). Docker startet nach
# Reboot alle Container gleichzeitig per Daemon-Restart (depends_on gilt nur für
# Compose-CLI) – Coder kann gegen unbereites Postgres crash-loopen. Dieses
# Gate wartet gestaffelt bis zu 120 s auf Postgres, weitere 120 s auf alle
# Container und bis zu 10 Minuten auf /healthz via TLS (je curl max. 10 s plus
# 10 s Abstand). Gesamtlaufzeit im Fehlerfall: knapp 14 Minuten. Ergebnis nach
# /var/log/coder-boot.log (+ logger). Auslösung per @reboot-Cron.
write_managed "/opt/coder/boot-check.sh" 755 "boot-check.sh" < "${SETUP_DIR}/scripts/boot-check.sh"
write_managed "/etc/cron.d/coder-bootcheck" 644 "coder-bootcheck-Cron" <<'EOF'
@reboot root /opt/coder/boot-check.sh
EOF
if [ -x /opt/coder/boot-check.sh ] && bash -n /opt/coder/boot-check.sh \
  && grep -qxF '@reboot root /opt/coder/boot-check.sh' /etc/cron.d/coder-bootcheck; then
  ok "Lesendes Boot-Gate installiert (/opt/coder/boot-check.sh, @reboot)"
else
  fail "Boot-Gate fehlt (/opt/coder/boot-check.sh oder /etc/cron.d/coder-bootcheck)"
fi

# B-005-Erkennung: On-Demand-TLS-Ausstellungen zählen (lesend, kein Alertmanager).
# "obtaining certificate" im noch verfuegbaren Caddy-Log ist eine Untergrenze:
# Docker-Logrotation kann Eintraege aus den letzten 7 Tagen bereits verworfen
# haben. Die Erfolgszeit wird separat exportiert, damit ein ausgefallener oder
# verpasster Cronlauf als TlsCheckStale sichtbar wird.
write_managed "/opt/coder/check-tls.sh" 755 "check-tls.sh" < "${SETUP_DIR}/scripts/check-tls.sh"
write_managed "/etc/cron.d/coder-tlscheck" 644 "coder-tlscheck-Cron" <<'EOF'
30 6 * * 1 root /opt/coder/check-tls.sh >> /var/log/coder-tls.log 2>&1
EOF
if [ -x /opt/coder/check-tls.sh ] && bash -n /opt/coder/check-tls.sh \
  && grep -qxF '30 6 * * 1 root /opt/coder/check-tls.sh >> /var/log/coder-tls.log 2>&1' /etc/cron.d/coder-tlscheck; then
  ok "TLS-Erkennung installiert (/opt/coder/check-tls.sh, wöchentlich Mo 06:30)"
else
  fail "TLS-Erkennung fehlt (/opt/coder/check-tls.sh oder /etc/cron.d/coder-tlscheck)"
fi
# TlsCheckStale würde sonst ab dem ersten Scrape feuern: die Metrik
# coder_tls_check_last_success_timestamp_seconds existiert erst nach dem
# ersten Cron-Lauf (Mo 06:30), und absent() meldet den Check als veraltet.
if /opt/coder/check-tls.sh; then
  ok "TLS-Check einmalig ausgeführt (Erfolgs-Timestamp gesetzt, kein TlsCheckStale bis Montag 06:30)"
else
  warn "einmaliger TLS-Check fehlgeschlagen – TlsCheckStale kann bis zum ersten Montag-Lauf feuern (/var/log/coder-tls.log)"
fi

echo "############################################################"
echo "# [6/10] Tägliches Datenbank-Backup einrichten"
echo "############################################################"
write_managed "/opt/coder/backup.sh" 755 "backup.sh" < "${SETUP_DIR}/scripts/backup.sh"

# F-009(a): ohne Cron-Daemon läuft nie ein Backup, das Setup meldete trotzdem
# [OK]. Das Paket wurde bereits in Schritt 1 installiert; hier werden die
# geordneten Eintraege aktiviert.
# "enable --now": enable ist idempotent, start ist No-Op wenn aktiv (kein
# Ban-Verlust wie bei fail2ban-restart, P-025 betrifft nur fail2ban).
systemctl enable --now cron

# /etc/cron.d/ statt "crontab -l | ... | crontab -": eine einzelne,
# nachvollziehbare Datei statt fragilem Parsen/Überschreiben der gesamten
# Root-Crontab (Risiko, versehentlich andere Einträge zu verlieren). Das
# Format braucht hier zusätzlich das Benutzerfeld ("root") vor dem Befehl.
# B-001: KEIN äußeres flock in der Cron-Zeile – backup.sh hält seine beiden
# Locks selbst und wartet darauf bis zu 300 s. Ein äußeres
# "flock" auf derselben Datei würde den inneren Lauf bis zum Timeout sperren
# (Exit 75, kein Backup). Absolute Pfade (P-017).
write_managed "/etc/cron.d/coder-backup" 644 "coder-backup-Cron" <<'EOF'
0 1 * * * root /opt/coder/backup.sh >> /var/log/coder-backup.log 2>&1
EOF

# P-007: Backup-Log ohne Rotation wächst als Root-Log unbegrenzt.
write_managed "/etc/logrotate.d/coder-backup" 644 "coder-backup-logrotate" <<'EOF'
/var/log/coder-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF

# C4: die beiden anderen Logdateien des Stacks liefen bisher ohne Rotation und
# wuchsen unbegrenzt (coder-boot.log wächst bei jedem Reboot, coder-tls.log
# pro Woche). Eigene Datei statt Anhängen an coder-backup, weil deren Inhalt
# nach Server-Konvention Backup-spezifisch bleibt.
write_managed "/etc/logrotate.d/coder-logs" 644 "coder-logs-logrotate" <<'EOF'
/var/log/coder-boot.log
/var/log/coder-tls.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF

if [ -f /etc/cron.d/coder-backup ] && grep -qF "/opt/coder/backup.sh" /etc/cron.d/coder-backup; then
  ok "Täglicher Backup-Cronjob ist eingetragen (01:00 Uhr, /etc/cron.d/coder-backup)"
else
  fail "Backup-Cronjob (/etc/cron.d/coder-backup) fehlt oder unvollständig"
fi
if systemctl is-active --quiet cron; then
  ok "Cron-Daemon läuft (sonst liefe nie ein Backup)"
else
  fail "Cron-Daemon läuft NICHT – Backups würden still nie laufen"
fi
if logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then
  ok "Logrotate-Konfiguration ist syntaktisch gültig"
else
  fail "Logrotate-Konfiguration ist ungültig – prüfen mit: sudo logrotate -d /etc/logrotate.conf"
fi

echo "Teste Backup einmal direkt..."
# Zusätzliche Absicherung: "condition: service_healthy" in der
# docker-compose.yml sorgt zwar schon dafür, dass "docker compose up -d" in
# Schritt 3 auf einen gesunden Postgres wartet, bevor es zurückkehrt - falls
# das auf einer sehr langsamen Platte trotzdem einmal nicht reicht, wartet
# diese Schleife hier zusätzlich bis zu 60 Sekunden, statt einen falschen
# Alarm zu melden.
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null)" = "healthy" ] && break
  sleep 2
done
if env CODER_MAINTENANCE_LOCK_HELD=1 /opt/coder/backup.sh; then
  LATEST_BACKUP=$(ls -t /opt/coder/backups/coder_*.sql.gz 2>/dev/null | head -n1 || true)
  if [ -n "${LATEST_BACKUP:-}" ]; then
    ok "Testlauf erfolgreich, Backup-Datei angelegt: ${LATEST_BACKUP}"
  else
    fail "backup.sh lief ohne Fehler, aber es wurde keine Backup-Datei gefunden"
  fi
else
  fail "Testlauf von backup.sh ist fehlgeschlagen (z. B. weil Postgres noch nicht bereit war)"
fi

# B-008: Runbook auf dem Server ablegen, damit Verweise aus update.sh und
# reset-coder.sh ("/opt/coder" auf dem Server) dort auflösen. Kein Dangling:
# liegt RESTORE.md neben dem Setup, wird es kopiert; sonst WARN (kein Fail).
# SCRIPT_SRC_DIR wurde oben vor dem cd nach /opt/coder berechnet, hier nicht
# neu berechnen – relativ zu /opt/coder fände sie RESTORE.md nie.
if [ -f "${SCRIPT_SRC_DIR}/RESTORE.md" ]; then
  cp -a "${SCRIPT_SRC_DIR}/RESTORE.md" /opt/coder/RESTORE.md
  chmod 644 /opt/coder/RESTORE.md
  ok "Runbook nach /opt/coder/RESTORE.md abgelegt"
else
  warn "RESTORE.md liegt nicht neben setup-coder.sh – kein Runbook auf Server abgelegt"
fi

echo "############################################################"
echo "# [7/10] Update-Skript bereitstellen (manuell, KEIN Cronjob)"
echo "############################################################"
write_managed "/opt/coder/update.sh" 755 "update.sh" < "${SETUP_DIR}/scripts/update.sh"

if [ -x /opt/coder/update.sh ] && bash -n /opt/coder/update.sh; then
  ok "update.sh ist vorhanden und ausführbar – manuell starten mit: sudo /opt/coder/update.sh"
else
  fail "update.sh fehlt oder ist nicht ausführbar"
fi

echo "Aktuelle Crontab:"
crontab -l 2>/dev/null || echo "(keine Einträge - Backup läuft über /etc/cron.d/coder-backup, nicht über die Crontab)"

echo "############################################################"
echo "# [8/10] Passwort-Reset-Skript bereitstellen"
echo "############################################################"
write_managed "/opt/coder/reset-passwords.sh" 755 "reset-passwords.sh" < "${SETUP_DIR}/scripts/reset-passwords.sh"

if [ -x /opt/coder/reset-passwords.sh ] && bash -n /opt/coder/reset-passwords.sh; then
  ok "reset-passwords.sh ist vorhanden und ausführbar – Aufruf: sudo /opt/coder/reset-passwords.sh"
else
  fail "reset-passwords.sh fehlt oder ist nicht ausführbar"
fi

echo "############################################################"
echo "# [9/10] Komplett-Reset-Skript bereitstellen"
echo "############################################################"
write_managed "/opt/coder/reset-coder.sh" 755 "reset-coder.sh" < "${SETUP_DIR}/scripts/reset-coder.sh"

if [ -x /opt/coder/reset-coder.sh ] && bash -n /opt/coder/reset-coder.sh; then
  ok "reset-coder.sh ist vorhanden und ausführbar – Aufruf: sudo /opt/coder/reset-coder.sh"
else
  fail "reset-coder.sh fehlt oder ist nicht ausführbar"
fi

echo "############################################################"
echo "# [10/10] Abschlusscheck & Zusammenfassung"
echo "############################################################"

# B-012/B2-007: Der Schritt-10-Block, der hier alle 15 Hashes auf einmal
# nachgezogen hat, ist entfernt. remember_hash steht jetzt an jeder Schreib-
# stelle direkt nach erfolgreichem tee/chmod – ein Abbruch vor Schritt 10
# hinterlässt damit keine veralteten Hashes mehr, die im nächsten Lauf eine
# Fehl-Warnung ("Operator-Drift") für setup-eigene Residuen auslösen.
# Residueller, dokumentierter Restpfad: Kill genau zwischen Schreiben und
# remember_hash -> einmalige Fehl-WARN im Folgelauf, kein Datenverlust,
# der nächste grüne Lauf heilt den Hashstore.

check_container_running "coder-postgres" "Postgres-Container"
check_container_running "coder" "Coder-Container"
check_container_running "coder-caddy" "Caddy-Container"
check_container_running "coder-prometheus" "Prometheus-Container"
check_container_running "coder-node-exporter" "Node-Exporter-Container"
check_container_running "coder-grafana" "Grafana-Container"

# F-007/P-012: "Container läuft" beweist keinen Socket-Zugriff. Host-seitige
# Probe (kein Tool im Coder-Image vorausgesetzt): GroupAdd des Containers muss
# die aktuelle docker-GID enthalten, sonst "Permission denied" auf
# /var/run/docker.sock und keine Workspace-Provisionierung.
if CODER_GROUPS=$(docker inspect --format '{{json .HostConfig.GroupAdd}}' coder 2>/dev/null); then
  if [ -n "${DOCKER_GID:-}" ] && grep -q "${DOCKER_GID}" <<< "${CODER_GROUPS}"; then
    ok "Coder-Container hat docker-GID ${DOCKER_GID} (Socket-Zugriff konfiguriert)"
  else
    fail "Coder-Container GroupAdd (${CODER_GROUPS}) enthält docker-GID ${DOCKER_GID:-?} NICHT – Socket-Zugriff prüfen (F-007)"
  fi
else
  warn "Socket-Probe nicht möglich (coder-Container nicht inspizierbar)"
fi

# A7: Zwei getrennte Proben, damit ein Misserfolg eindeutig zugeordnet werden
# kann. Beide laufen immer (Zuweisung jeweils DIREKT in der if-Bedingung –
# nur dort greift set -e nicht; eine eigene "VAR=$(curl ...)"-Zeile davor
# hätte das Skript beim ersten Fehlschlag beendet).
#
# (a) LOKALER Pfad: --resolve zwingt die Verbindung auf 127.0.0.1 und macht
#     die Probe damit unabhängig von öffentlichem DNS und Hairpin-NAT – sie
#     prüft präzise das, was auf diesem Host läuft (Caddy-TLS, Reverse-Proxy,
#     Coder). 6 Versuche à max. 10 s mit 5 s Pause (curl-Budget 60 s,
#     schlimmstenfalls 85 s), weil Caddy beim Erstlauf noch ein Zertifikat
#     beantragen muss und das nicht in der ersten Sekunde fertig ist.
#     Die Wiederholung bricht ab, sobald 200 kam oder lokal kein DNS-Eintrag
#     existiert (dann ist nichts zu wiederholen – die Diagnose unten greift).
#     /healthz statt der Startseite: dedizierter, dokumentierter Endpunkt.
# (b) ÖFFENTLICHER Pfad: nur EIN Versuch, ohne --resolve, also über den
#     echten DNS-Eintrag und den echten, von außen beschrittenen Weg.
#     Lief (a) grün und (b) nicht, ist die Ursache Netz, nicht Code:
#     Portweiterleitung/Reverse-Proxy im Schulnetz oder Hairpin-NAT – deshalb
#     WARN statt Fail (Kopfprinzip: das Setup startet trotzdem).
_try=0
HTTP_CODE="000"
while [ "${_try}" -lt 6 ] && [ "${HTTP_CODE}" != "200" ]; do
  _try=$((_try + 1))
  if HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      --resolve "${DOMAIN_CODER}:443:127.0.0.1" "https://${DOMAIN_CODER}/healthz" 2>/dev/null); then
    : # Antwort kam an, der HTTP-Code steht in HTTP_CODE
  else
    HTTP_CODE="000"
  fi
  if [ "${HTTP_CODE}" = "200" ] || [ "${_try}" -ge 6 ]; then
    break
  fi
  if ! getent hosts "${DOMAIN_CODER}" > /dev/null 2>&1; then
    break
  fi
  sleep 5
done
LOCAL_CODE="${HTTP_CODE}"

if [ "${LOCAL_CODE}" = "200" ]; then
  if PUB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://${DOMAIN_CODER}/healthz" 2>/dev/null); then
    : # Antwort kam an
  else
    PUB_CODE="000"
  fi
  if [ "${PUB_CODE}" = "200" ]; then
    ok "https://${DOMAIN_CODER}/healthz antwortet lokal UND öffentlich mit HTTP 200 – Let's-Encrypt-Zertifikat ausgestellt, Coder erreichbar"
  else
    warn "https://${DOMAIN_CODER}/healthz antwortet auf dem Server (127.0.0.1) mit 200, über den öffentlichen Weg aber nicht (Code: ${PUB_CODE}). Das ist kein Skriptfehler: Portweiterleitung 80/443 oder Reverse-Proxy im Schulnetz fehlt, oder der eingehende Weg wird von einem Hairpin-NAT geblockt. Prüfen mit: getent hosts ${DOMAIN_CODER}; von außen: curl -sI https://${DOMAIN_CODER}/healthz"
  fi
elif getent hosts "${DOMAIN_CODER}" > /dev/null 2>&1; then
  warn "${DOMAIN_CODER} löst lokal auf, aber https://${DOMAIN_CODER}/healthz antwortet nicht mit HTTP 200 (lokaler Pfad, Code: ${LOCAL_CODE} nach ${_try} Versuchen). Mögliche Ursachen: Portweiterleitung 80/443 fehlt noch, oder Zertifikat noch nicht ausgestellt. Prüfen mit: sudo docker compose -f /opt/coder/docker-compose.yml logs caddy"
else
  warn "DNS: ${DOMAIN_CODER} löst noch nicht auf. Normal, solange DNS-Eintrag und Portweiterleitung/Reverse Proxy im Schulnetz noch nicht stehen – Skript nach der Einrichtung einfach erneut laufen lassen."
fi

# B-019: Wildcard-Probe getrennt von Apex, immer WARN (nie Fail – Setup soll bei
# fehlender Weiterleitung starten, Kopfprinzip). Nur DNS-Resolve einer zufälligen
# Subdomain (kein TLS-Handshake, kein LE-Budget). Limit: lokaler Resolver statt
# autoritativem Server (kein dig garantiert); Negativprobe: fehlt Wildcard, kommt
# WARN statt grünem Gesamt-OK. App-Smoke (T-124) erst nach erstem Workspace.
WILDCARD_PROBE="setup-probe-${RANDOM}.${DOMAIN_CODER}"
if getent hosts "${WILDCARD_PROBE}" > /dev/null 2>&1; then
  ok "Wildcard-DNS löst auf (*.${DOMAIN_CODER} via ${WILDCARD_PROBE})"
else
  warn "Wildcard-DNS fehlt (*.${DOMAIN_CODER} löst nicht auf, Probe ${WILDCARD_PROBE}) – Workspace-Apps/Port-Forwarding scheitern, Apex-OK gilt NICHT für Apps. DNS-Wildcard-Eintrag setzen, dann Setup erneut."
fi

# B2: rein lesend, KEINE Nutzer-Erzwinge-Erstellung. Coder vergibt dem ersten
# menschlichen Konto automatisch Owner-Rechte, das ist so vorgesehen – ein
# "create-admin-user" erzwungen durch das Setup wäre versionseitig fragil und
# würde bei Re-Runs auf einem schon benutzten Server nichts ändern (können).
# Geprüft wird nur, ob ein menschliches Konto existiert; "prebuilds" und
# künftige Systemkonten sind per COALESCE-Ausschluss keine Treffer.
HUMAN_USERS="$(docker exec coder-postgres psql -U coder -d coder -tAc \
  "SELECT count(*) FROM users AS u WHERE NOT COALESCE((to_jsonb(u)->>'is_system')::boolean,false) AND NOT COALESCE((to_jsonb(u)->>'is_service_account')::boolean,false) AND NOT COALESCE((to_jsonb(u)->>'deleted')::boolean,false)" 2>/dev/null || true)"
# B1: optional die Erstanlage DURCH DAS SETUP, solange kein Konto existiert –
# sonst würde der erste zufällige Aufrufer der Anmeldeseite Owner. Nur aktiv,
# wenn der Betreiber alle drei Variablen setzt (sonst unverändertes Verhalten).
# Passwort läuft per stdin in den Container, nie als docker-exec-Argument
# (dasselbe Prinzip wie der ALTER-USER unten: nichts in "ps" sichtbar).
if [ "${HUMAN_USERS}" = "0" ] \
  && [ -n "${CODER_FIRST_USER_EMAIL:-}" ] \
  && [ -n "${CODER_FIRST_USER_USERNAME:-}" ] \
  && [ -n "${CODER_FIRST_USER_PASSWORD:-}" ]; then
  if FIRST_OUT=$(printf '%s\n' "${CODER_FIRST_USER_PASSWORD}" | \
      docker exec -i \
        -e CODER_CONFIG_DIR=/tmp/coder-firstuser \
        -e CODER_FIRST_USER_EMAIL="${CODER_FIRST_USER_EMAIL}" \
        -e CODER_FIRST_USER_USERNAME="${CODER_FIRST_USER_USERNAME}" \
        -e CODER_FIRST_USER_FULL_NAME="${CODER_FIRST_USER_FULL_NAME:-}" \
        coder sh -c 'IFS= read -r P
          export CODER_FIRST_USER_PASSWORD="$P"
          exec coder login http://127.0.0.1:3000 --first-user-trial=false ${CODER_FIRST_USER_FULL_NAME:+--first-user-full-name "$CODER_FIRST_USER_FULL_NAME"}' 2>&1); then
    ok "Erstkonto (Owner) angelegt: ${CODER_FIRST_USER_USERNAME}"
  else
    warn "Erstkonto NICHT angelegt: $(printf '%s' "${FIRST_OUT}" | tr '\n' ' ' | tail -c 300) – Konto manuell auf der Anmeldeseite anlegen, bevor die URL weitergegeben wird"
  fi
  # Das CLI-Session-Token liegt in diesem isolierten Config-Verzeichnis.
  # Nach Erfolg wie Fehler entfernen; der bestehende Coder-Config-Ordner bleibt
  # unberuehrt.
  docker exec coder rm -rf -- /tmp/coder-firstuser >/dev/null 2>&1 || \
    warn "Temporäres Coder-Login-Verzeichnis konnte nicht entfernt werden; manuell löschen: docker exec coder rm -rf /tmp/coder-firstuser"
fi
case "${HUMAN_USERS}" in
  '')
    warn "Nutzeranzahl nicht lesbar (coder-postgres/psql nicht erreichbar) – B2-Check übersprungen" ;;
  0)
    echo ""
    echo "HINWEIS: Noch kein Nutzerkonto vorhanden. Der erste Anmeldende"
    echo "wird automatisch Owner (Administrator) dieses Coder-Servers – die"
    echo "Anmeldeseite daher nicht unkontrolliert weitergeben, bevor das erste"
    echo "Konto angelegt ist. Danach ein zweites Owner-Konto anlegen, damit die"
    echo "Administration nicht an einem Zugang hängt (siehe OPERATIONS.md)."
    echo "" ;;
  *)
    ok "${HUMAN_USERS} Nutzerkonto/-konten vorhanden" ;;
esac

echo ""
echo "============================================================"
echo " Zusammenfassung"
echo "============================================================"
for line in "${SUMMARY[@]}"; do
  echo "  ${line}"
done
echo "============================================================"
echo ""
echo "Coder-URL (sobald DNS + Portweiterleitung stehen): https://${DOMAIN_CODER}"
echo "Workspace-Apps/Port-Forwarding brauchen zusätzlich den Wildcard-DNS-Eintrag"
echo "*.${DOMAIN_CODER} -> öffentliche Server-IP (siehe Kopf des Skripts)."
echo "update.sh zieht die konfigurierten Image-Tags und prüft den Stack:"
echo "sudo /opt/coder/update.sh"
echo "Neue Releases kommen dabei nur hinter beweglichen Tags (Caddy/Postgres)."
echo "Exakt gepinnte Images aktualisieren: Pin in setup-coder.sh ändern und"
echo "das Setup erneut ausführen. Docker-Engine-Updates sind separat und manuell."
echo "Grafana weiterhin nur per SSH-Tunnel: 127.0.0.1:3001"

if [ "${ERROR_COUNT}" -gt 0 ]; then
  echo ""
  echo "${ERROR_COUNT} [FEHLER]-Eintrag/-Einträge in der Zusammenfassung oben – bitte prüfen."
  exit 1
fi
