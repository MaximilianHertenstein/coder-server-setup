#!/usr/bin/env bash
# ============================================================================
# Coder-Server Setup – coder.ghse-unterricht.de
# Zielsystem: Debian 13 (trixie)
#
# Aufruf als root (ohne root bricht das Skript vor jeder Änderung ab):
#   chmod +x setup-coder.sh
#   sudo ./setup-coder.sh
# Persistente Werte (Domain, ACME-Mail, fail2ban-Admin-IP) in setup.conf
# ablegen (Vorlage: setup.conf.example, gitignored) – die überlebt Re-Runs.
# Für einen Lauf gilt weiterhin: sudo env DOMAIN_CODER=… ./setup-coder.sh
# (Umgebung schlägt setup.conf, setup.conf schlägt den Default).
# Einzige interaktive Eingabe: Erstlauf ohne vorhandenes Konto, wenn
# CODER_FIRST_USER_EMAIL und CODER_FIRST_USER_USERNAME gesetzt und stdin ein
# TTY sind, fragt das Skript einmal unsichtbar das Erstkonto-Passwort ab
# (read -rs; leer lassen = Konto später im Browser anlegen). Sonst kein
# Prompt. Nicht-interaktiv: CODER_FIRST_USER_PASSWORD_FILE (root-only Datei)
# setzen – siehe OPERATIONS §11.
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
  echo "Betreiberwerte dauerhaft in setup.conf eintragen (Vorlage: setup.conf.example);" >&2
  echo " für einen Lauf gehören Variablen hinter das sudo, sonst greifen die Defaults:" >&2
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

ENV_TMP=""
MANAGED_TMP=""
setup_cleanup() {
  local rc=$?
  for _tmp in "${ENV_TMP}" "${MANAGED_TMP}"; do
    [ -n "${_tmp}" ] && rm -f -- "${_tmp}" 2>/dev/null || true
  done
  return "${rc}"
}
trap setup_cleanup EXIT

# Alle Werte lassen sich beim Aufruf per Umgebungsvariable überschreiben,
# ohne diese Datei zu ändern, z.B.:
#   DOMAIN_CODER=andere-domain.de ./setup-coder.sh
# A5: Persistente Betreiberwerte aus setup.conf (neben dem Skript, gitignored).
# Ohne sie würde ein späterer Re-Run ohne "sudo env ..." die Defaults zurück-
# setzen – z.B. die Admin-IP aus fail2ban ignorip. Vorrang:
#   Umgebungsvariable (aktueller Lauf) > setup.conf > eingebauter Default.
# Nur die vier freigegebenen Schlüssel werden gelesen, alles andere (auch
# Syntaxfehler) überschreibt nichts und bricht den Lauf nicht ab; danach
# bricht die Domain-Prüfung bei ungültigem DOMAIN_CODER hart ab.
if [ -f "${SETUP_DIR}/setup.conf" ]; then
  while IFS='=' read -r _sk _sv || [ -n "${_sk}" ]; do
    case "${_sk}" in ''|\#*) continue ;; esac
    # Werte wörtlich übernehmen wäre schädlich: CRLF (Windows-Editor) landet
    # als \r in Domain/Jail/Compose, umschließende Anführungszeichen in der
    # fail2ban- oder Caddyfile-Konfiguration. Beides hier strippen.
    _sv="${_sv%$'\r'}"
    case "${_sv}" in
      \"*\") _sv="${_sv#\"}"; _sv="${_sv%\"}" ;;
      \'*\') _sv="${_sv#\'}"; _sv="${_sv%\'}" ;;
    esac
    case "${_sk}" in
      DOMAIN_CODER)       [ -n "${DOMAIN_CODER+x}" ] || DOMAIN_CODER="${_sv}" ;;
      ACME_EMAIL)         [ -n "${ACME_EMAIL+x}" ] || ACME_EMAIL="${_sv}" ;;
      ACME_CA)            [ -n "${ACME_CA+x}" ] || ACME_CA="${_sv}" ;;
      FAIL2BAN_IGNORE_IP) [ -n "${FAIL2BAN_IGNORE_IP+x}" ] || FAIL2BAN_IGNORE_IP="${_sv}" ;;
    esac
  done < "${SETUP_DIR}/setup.conf"
fi
# ":=" setzt den Default nur, wenn die Variable noch nicht (von außen oder
# über setup.conf) gesetzt wurde.
: "${DOMAIN_CODER:=coder.ghse-unterricht.de}"
: "${ACME_EMAIL:=hert@ghse.de}"
# Domain hart prüfen, bevor sie in Caddyfile/Compose wandert: Leerzeichen,
# Anführungszeichen, \r oder Grossbuchstaben würden die Konfiguration oder
# die TLS-Ausstellung brechen.
if ! [[ "${DOMAIN_CODER}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  echo "Fehler: DOMAIN_CODER='${DOMAIN_CODER}' ist keine gültige Domain (erlaubt: klein, a-z, 0-9, '.', '-'; kein Leerzeichen/Anführung/\\r)." >&2
  echo "In setup.conf oder als Umgebungsvariable korrigieren, dann Setup erneut." >&2
  exit 1
fi
# Pin-Regeln: CODER/PROMETHEUS/GRAFANA/NODE_EXPORTER exakt, CADDY bewusst nur
# minor-gepinnt (z. B. "2.11") – TLS-taugliche Patch-Updates sollen über
# "docker compose pull" ankommen; postgres:18-alpine analog (Major-Tag).
# WICHTIG: Das ghcr.io-Tag TRÄGT das "v"-Präfix (v2.37.3). Am 2026-09-28 und
# erneut am 2026-10-03 gegen die Registry geprüft: ghcr.io/coder/coder:2.36.6
# und :2.37.3 -> HTTP 404, mit "v" (v2.36.6/v2.37.3) -> 200; die Release-
# Notes nennen das Tag teils ohne "v" (falsch, das bricht Schritt 3 ab).
# Vor jeder Versionserhöhung IMMER per "docker pull"
# gegen die Registry belegen, nicht nach dem Wortlaut der Notes. Für einen
# bit-genauen, reproduzierbaren Pin bräuchte man ein Image-Digest (sha256:...).
# Stand 2026-10-03 (Upstream-Stable geprüft: releases/latest bzw.
# prerelease-Flags): Coder v2.37.3 (v2.36.6 war die Vorgängerlinie),
# Caddy 2.11 (2.11.7 released), Prometheus v3.15.0, Grafana 12.4.12
# (12.x-Security-Backports; Major 13 bewusst nicht), node-exporter
# v1.12.1 = aktuell, Postgres 19 nur Beta -> 18-alpine bleibt.
: "${CODER_VERSION:=v2.37.3}"              # https://github.com/coder/coder/releases prüfen
: "${CADDY_VERSION:=2.11}"                # https://hub.docker.com/_/caddy/tags
: "${PROMETHEUS_VERSION:=v3.15.0}"        # https://github.com/prometheus/prometheus/releases
: "${GRAFANA_VERSION:=12.4.12}"           # https://github.com/grafana/grafana/releases
: "${NODE_EXPORTER_VERSION:=v1.12.1}"     # https://github.com/prometheus/node_exporter/releases
# Admin-Adressen, die fail2ban nie sperren darf – NUR echte Admin-Plätze hier
# eintragen, ausdrücklich NICHT die geteilte Schul-NAT: Rateversuche aus
# dem Schulnetz sollen nach 5 Fehlversuchen sperren. Bewusst akzeptiert:
# die gemeinsame NAT-IP kann dann gesperrt sein (Recovery: anderes Netz
# oder Proxmox-Konsole). Default bleibt loopback.
: "${FAIL2BAN_IGNORE_IP:=127.0.0.1/8 ::1}"

# ---- Wirksam gewesene Version + Downgrade-Schutz (A5) ---------------------
# Gepinnt und geschützt wird nur CODER_VERSION: allein Coder führt
# DB-Schema-Migrationen aus, ein stilles Zurücksetzen wäre dort irreversibel.
# Caddy/Prometheus/node-exporter sind beim Restarten zustandslos, ihr
# Versionswechsel ist ein bewusster Compose-Tag-Eintrag; Grafana-Downgrades
# sind wegen der lokalen SQLite-Daten bewusste Manuellearbeit (Release-Notes
# lesen). POSTGRES_VERSION wird gar nicht verwaltet: Postgres-Major nur
# manuell ändern, immer mit frischem Backup.
# Versions.env: nur Version, keine Geheimnisse -> 644, ohne sudo lesbar.
# Downgrade-Versuch hart abgebrochen, sofern nicht ausdrücklich
# CODER_ALLOW_DOWNGRADE=yes gesetzt ist (bewusster Rollback, siehe
# RESTORE.md). Eine Änderung NACH oben (Upgrade) bleibt ohne Rückfrage.
VERSIONS_FILE="/opt/coder/versions.env"
VERSION_VARS="CODER_VERSION"
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
# noch nicht (Ordner kommt erst nach allen Preflights), und eine Version darf
# erst eingetragen werden, wenn sie wirklich läuft. Siehe direkt nach
# "docker compose up -d".

# ---- Hilfsfunktionen für die Zusammenfassung ab Schritt 4 -----------------
declare -a SUMMARY=()
ERROR_COUNT=0
ok()   { echo "  [OK]     $1"; SUMMARY+=("[OK]     $1"); }
warn() { echo "  [WARNUNG] $1"; SUMMARY+=("[WARNUNG] $1"); }
fail() { echo "  [FEHLER] $1"; SUMMARY+=("[FEHLER] $1"); ERROR_COUNT=$((ERROR_COUNT + 1)); }

check_container_running() {
  local name="$1"
  local label="$2"
  # State.Status, nicht State.Running: im Restart-Loop meldet Docker
  # Running=true (gemessen 2026-10-03), Status="restarting" – mit Running
  # bekäme ein abstürzender Container ein fälschliches [OK]. --type
  # schließt Namenskollision mit Image/Volume aus.
  if [ "$(docker inspect --type container -f '{{.State.Status}}' "${name}" 2>/dev/null || echo missing)" = "running" ]; then
    ok "${label} läuft"
  else
    fail "${label} läuft NICHT – prüfen mit: sudo docker logs ${name}"
  fi
}

# Das Setup ist deklarativer Besitzer der generierten Dateien, das
# Überschreiben von Handänderungen ist in README/OPERATIONS dokumentiert.
# Was zählt: Temp schreiben, validieren, atomar ersetzen.

# Atomar eine vom Setup verwaltete Datei schreiben. Die temporäre Datei liegt
# im Zielverzeichnis, damit mv dieselbe Dateisystem-Grenze nicht überschreitet.
# Bei identischem Inhalt bleibt der Ziel-Inode unangetastet; das vermeidet
# unnötige Reloads und schützt laufende Leser. Modus wird nachgezogen.
# MANAGED_TMP wird vom EXIT-Cleanup entfernt, falls der Lauf vor
# dem mv abbricht.
# A2: Optionaler Validierer ($4, Funktionsname) läuft auf der TEMP-Datei, VOR
# dem Austausch der Live-Datei. Bei Fehlschlag bleibt die vorhandene Datei
# unangetastet und der Lauf bricht ab – eine ungültige Konfiguration landet
# damit nie auf der Platte und könnte den nächsten Reboot nicht überleben.
write_managed() { # $1=Pfad $2=Modus $3=Referenz-Label (Reserve, ungenutzt) [$4=Validierer]; Inhalt via stdin
  local file="$1" mode="$2" validator="${4:-}" dir base
  dir="${file%/*}"
  base="${file##*/}"
  MANAGED_TMP=$(mktemp "${dir}/.${base}.tmp.XXXXXX")
  if ! cat > "${MANAGED_TMP}"; then
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
  if [ -n "${validator}" ]; then
    # mktemp legt 600 an; promtool laeuft im Container als nobody und darf die
    # Temp-Datei dann nicht lesen (live gefunden 2026-10-01). Vor dem
    # Validieren auf den spaeteren Endmodus heben, danach chmod "${mode}".
    chmod 644 -- "${MANAGED_TMP}"
    if ! "${validator}" "${MANAGED_TMP}"; then
      echo "Fehler: Validierung fehlgeschlagen (${validator}): ${file} – Live-Datei bleibt unverändert, Lauf abgebrochen." >&2
      rm -f -- "${MANAGED_TMP}" 2>/dev/null || true
      MANAGED_TMP=""
      return 1
    fi
  fi
  chmod "${mode}" "${MANAGED_TMP}"
  if cmp -s -- "${MANAGED_TMP}" "${file}"; then
    chmod "${mode}" "${file}"
    rm -f -- "${MANAGED_TMP}"
  else
    mv -f -- "${MANAGED_TMP}" "${file}"
  fi
  MANAGED_TMP=""
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

# A2: Validierer für write_managed – prüfen die TEMP-Datei (Pfad $1), bevor die
# Live-Datei ausgetauscht wird. Die caddy-/promtool-Präfixe brauchen die
# Images, deshalb wird vor dem Schreiben dieser Dateien gepullt (siehe unten).
# caddy:2.11 hat KEINEN ENTRYPOINT (nur CMD ["caddy","run",...]) – ohne
# --entrypoint würde "validate" selbst als Binary ausgeführt und scheitern
# mit 'executable file not found in $PATH'.
validate_compose() {
  docker compose -f "$1" config --quiet
}
validate_caddyfile() {
  docker run --rm --entrypoint caddy -v /opt/coder/caddy:/etc/caddy:ro "caddy:${CADDY_VERSION}" \
    validate --config "/etc/caddy/$(basename "$1")" --adapter caddyfile
}
validate_prom_rules() {
  docker run --rm --entrypoint /bin/promtool -v /opt/coder/prometheus:/etc/prometheus:ro "prom/prometheus:${PROMETHEUS_VERSION}" \
    check rules "/etc/prometheus/rules/$(basename "$1")"
}
validate_prom_config() {
  docker run --rm --entrypoint /bin/promtool -v /opt/coder/prometheus:/etc/prometheus:ro "prom/prometheus:${PROMETHEUS_VERSION}" \
    check config "/etc/prometheus/$(basename "$1")"
}

# A10: Alle SSH-Vorbedingungen HIER, vor Docker-Installation und Stack-Start.
# Die Firewall-Regel unten setzt die hier erkannten sshd-Ports; ohne lesbare
# sshd-Konfiguration wäre unklar, welchen Port "ufw enable" noch offen lässt –
# deshalb hart abbrechen, bevor irgendetwas installiert oder verändert wird
# (Zugriff dann nur noch über Konsolenzugang des Hosts).
if ! command -v sshd > /dev/null 2>&1; then
  echo "Fehler: sshd nicht gefunden – openssh-server fehlt; ohne SSH-Zugang würde die Firewall-Änderung den Host absperren." >&2
  echo "openssh-server installieren (apt install openssh-server), dann Setup erneut." >&2
  exit 1
fi
if ! SSHD_EFFECTIVE_CONFIG="$(sshd -T 2>/dev/null)"; then
  echo "Fehler: sshd-Konfiguration konnte nicht gelesen werden – Abbruch vor jeder Serveränderung." >&2
  exit 1
fi
SSHD_PORTS="$(printf '%s\n' "${SSHD_EFFECTIVE_CONFIG}" | awk '/^port /{print $2}' | sort -u | xargs echo 2>/dev/null || true)"
if [ -z "${SSHD_PORTS}" ]; then
  echo "Fehler: sshd -T lieferte keinen Port – Abbruch vor jeder Serveränderung." >&2
  exit 1
fi

# Wartungs-Lock: erst nach allen read-only Preflights (OS, Domain, Downgrade,
# sshd) und vor dem ersten Eingriff – deshalb sind die Abbruchmeldungen oben
# ("vor jeder Serveränderung") wörtlich zu nehmen. Das Setup schreibt Compose-
# und Wartungsskripte und startet den Stack. Ein paralleler Wartungslauf
# könnte Dateien während ihrer Ausführung überschreiben. Vor diesen
# Konfigurations- und Stack-Änderungen nimmt das Setup denselben flock wie
# die Wartungsskripte: er hängt am Deskriptor 8 dieses Prozesses und bleibt
# gesperrt, bis alle Prozesse ihn geerbt haben, beendet sind. Alle Aufrufe
# hier sind kurzlebig, kein Dauerläufer erbt ihn.
mkdir -p /opt/coder
sh -c 'umask 077; : >> /opt/coder/.maintenance.lock; chown root:root /opt/coder/.maintenance.lock; chmod 600 /opt/coder/.maintenance.lock'
exec 8>>/opt/coder/.maintenance.lock
if ! flock -w 300 8; then
  echo "Fehler: gemeinsamer Wartungs-Lock nach 300 s nicht erhalten; Setup abgebrochen (Exit 75)." >&2
  exit 75
fi
export CODER_MAINTENANCE_LOCK_HELD=1

echo "############################################################"
echo "# [1/7] Docker Engine installieren"
echo "############################################################"
# C1: Alle Cron-Zeiten dieses Skripts (Backup 01:00, Reboot 03:00)
# gelten in LOCALTIME. Neue VMs laufen oft auf UTC, dann läuft das
# Backup um 03:00 statt 01:00 Berlin und der Reboot mitten in der Nacht.
# Explizit setzen statt raten; idempotenter No-Op, wenn schon Berlin.
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
apt_install ca-certificates curl gnupg openssl cron logrotate
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
  ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

retry3 apt-get update
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# C2: Loggrößen begrenzen. Ohne Limit wächst das json-file-Logging der
# Standard-Installation bis die Root-Partition voll ist (Plattenkiller Nr. 1);
# eine projektweite compose-"logging:"-Anker-Datei deckte nur die eigenen
# Container ab, nicht z.B. "docker run"-Experimente oder spätere Projekte
# (Anker entfernt; daemon.json ist die einzige Quelle).
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
  cat > "${DAEMON_JSON}" <<'EOF'
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
# Datei gerade geschrieben haben – und nur, wenn GAR KEINE Container laufen
# (auch fremde Dienste hängen am Daemon). Läuft schon etwas, ist das
# ein ungefragter Ausfall; dann greift die Änderung erst beim nächsten
# geplanten Neustart und das wird hier ausdrücklich gewarnt, statt es still
# hinzunehmen.
if [ "${DOCKER_DAEMON_CHANGED}" -eq 1 ]; then
  if [ -n "$(docker ps -q 2>/dev/null || true)" ]; then
    warn "daemon.json geschrieben, aber es laufen Container – Docker wird NICHT neu gestartet. Log-Limit greift erst nach 'sudo systemctl restart docker' (C2)"
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
if ! [[ "${DOCKER_GID:-}" =~ ^[0-9]+$ ]]; then
  echo "Fehler: docker-GID nicht ermittelt oder keine Zahl (getent group docker lieferte '${DOCKER_GID:-leer}'). .env wird nicht angefasst." >&2
  exit 1
fi

# Optional: eigenen Benutzer der docker-Gruppe hinzufügen, damit du Docker
# ohne sudo bedienen kannst (danach einmal neu einloggen).
# sudo usermod -aG docker "$USER"

echo "############################################################"
echo "# [2/7] Verzeichnis und Konfigurationsdateien anlegen"
echo "############################################################"
mkdir -p /opt/coder/backups
chmod 700 /opt/coder/backups
cd /opt/coder

# Geheimnisse nur beim ersten Lauf erzeugen, damit ein erneutes Ausführen
# des Skripts nicht die bestehende Datenbank-Anmeldung zerstört.
# F-006 (mit P-011): atomar über Temp-Datei schreiben, vorhandene
# .env auf Vollständigkeit prüfen. Eine unvollständige .env wird NIEMALS
# still neu gewürfelt (das würde die DB-Anmeldung zerstören) – stattdessen
# Abbruch mit Reparaturanleitung. mktemp legt die Temp-Datei als 0600 an
# (root-owned) – kein zusätzliches install/chown/chmod nötig.
if [ ! -f /opt/coder/.env ]; then
  # A5/P-011: fehlt die .env NUR teilweise, bricht das Skript unten ab. Fehlt
  # sie ganz, würde dieser Zweig frische Passwörter würfeln, während
  # coder_postgres_data die alten behält – sonst käme Coder nicht an die DB
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
  cat > "$ENV_TMP" <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
EOF
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
  # aber nur für POSTGRES_PASSWORD – Nicht-Hex bricht die Postgres-Connection-
  # URL. GRAFANA_ADMIN_PASSWORD ist frei wählbar; gedreht wird per grafana cli
  # (OPERATIONS.md „Passwörter rotieren"), der .env-Eintrag ist nur die
  # abrufbare Kopie (POSTGRES manuell in DB und .env abgleichen: TROUBLESHOOTING.md A4).
  if ! grep -qE '^POSTGRES_PASSWORD=[0-9a-f]+$' /opt/coder/.env; then
    echo "Fehler: /opt/coder/.env: POSTGRES_PASSWORD ist nicht-hex." >&2
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
write_managed "/opt/coder/docker-compose.yml" 644 "docker-compose.yml" validate_compose <<EOF
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
      # Build aktuell standardmäßig tut.
      - CODER_TELEMETRY_ENABLE=false
      # A8: Coder sitzt hinter Caddy und sieht ohne diese Werte nur die
      # Container-IP des Proxys – Audit-Log und IP-Rate-Limits würden überall
      # dieselbe Adresse zeigen. Vertrauen nur Docker-Netz (172.16.0.0/12,
      # Compose-Default-Subnetze) und Loopback; Header nur X-Forwarded-For.
      - CODER_PROXY_TRUSTED_HEADERS=X-Forwarded-For
      - CODER_PROXY_TRUSTED_ORIGINS=172.16.0.0/12,127.0.0.1/8
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
      # Wirkt nur beim allerersten Start (leere grafana_data); danach ist der
      # .env-Eintrag nur noch die abrufbare Kopie. Drehen per grafana cli
      # (OPERATIONS.md „Passwörter rotieren") – ein Neustart mit geänderter
      # .env ändert das Passwort NICHT, Grafana hält es in seiner DB.
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_ADMIN_PASSWORD}
      # Kein GF_SERVER_ROOT_URL nötig – Zugriff per IP (Schulnetz oder
      # SSH-Tunnel), nicht über eine eigene Domain.
      # Telemetrie/Update-Checks an Grafana Inc. aus: passt zur
      # bewusst telemetriefreien Haltung des Stacks (siehe CODER_TELEMETRY).
      - GF_ANALYTICS_REPORTING_ENABLED=false
      - GF_ANALYTICS_CHECK_FOR_UPDATES=false
    # NICHT auf allen Interfaces und
    # NICHT per ufw-Quellregeln schützen. Docker-published Ports umgehen den
    # ufw-INPUT-Pfad (IPv4-DNAT, Docker-Doku), und RFC1918-Quellen
    # (10/8, 172.16/12, 192.168/16) sind keine Präzisionsgrenze für "unser
    # Schulnetz" – 172.16/12 enthält sogar die Docker-Netze selbst.
    # Bindung auf Loopback wie Prometheus/node-exporter: Zugriff per
    # SSH-Tunnel (ssh -L 3001:127.0.0.1:3001 …), LAN und WAN sehen 3001 nicht.
    ports:
      - "127.0.0.1:3001:3000"
    volumes:
      # C3: Datasource-Quittung (provisioniert, statt manuell im UI einzutragen).
      # Nur das Unterverzeichnis gemountet, damit der Rest von
      # /etc/grafana/provisioning des Images erhalten bleibt.
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
      # Dashboards als eigenes Unterverzeichnis – gleiche Begründung.
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
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

# A2/B-013: Bilder JETZT ziehen, bevor die Container-Dateien geschrieben
# werden – die Validierer für Caddyfile/Prometheus brauchen die Images, und
# ein fehlender/falscher Tag (z.B. coder/coder:2.36.6 ohne "v") soll vor
# jedem weiteren Schritt klar scheitern. Daemon-Check gehört hierher, weil
# "pull" der erste Docker-Aufruf nach der Installation ist.
if ! docker info > /dev/null 2>&1; then
  echo "Fehler: Docker-Daemon antwortet nicht (docker info). Erst Daemon heilen, dann Setup erneut." >&2
  exit 1
fi
retry3 docker compose pull

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
#     D-TLS (DNS-01-Wildcard ohne On-Demand) das Thema.
#     Eine automatische Budget-Überwachung gibt es nicht (manuelle
#     Sichtprüfung) – Erschöpfung fällt als HTTPS-Fehler auf;
#     Gegenmittel ist DNS-01, sobald Zone/Token geklärt sind (D-TLS).
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
# Property (mit caddy:2.11 nachgeprüft: "unrecognized ACME issuer property"),
# während die globale Option in beide Issuer (Apex + On-Demand) durchschlägt.
CADDY_ACME_CA=""
if [ -n "${ACME_CA:-}" ]; then
  CADDY_ACME_CA="    acme_ca ${ACME_CA}"
fi
# Lauf-Status VOR Schritt 3 (Reload/Neustart-Entscheidung unten). Pfad der
# Caddyfile unter /opt/coder/caddy, weil die compose-Datei das Verzeichnis
# statt der Einzeldatei bindet.
CADDY_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' coder-caddy 2>/dev/null || echo false)
# write_managed legt Verzeichnisse nicht an (Vorbild: rules/grafana unten).
install -d -m 0755 /opt/coder/caddy
write_managed "/opt/coder/caddy/Caddyfile" 644 "Caddyfile" validate_caddyfile <<EOF
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

# Prometheus bekommt SIGHUP bei jedem Lauf, solange es läuft –
# Reload statt Neustart (P-025), ohne Hash-Vergleich: ein SIGHUP auf
# unveränderte Regeln ist ein No-Op (braucht kein --web.enable-lifecycle).
# Nur Grafana hat keine Reload-API und braucht weiterhin den Hash – dessen
# Neustart ist invasiv und bleibt an die tatsächliche Änderung gebunden.
# Grafana liest Provisioning-Dateien nur beim Start.
# Ganzer Provisioning-Baum (Datasource + Dashboards): find+sort+sha256,
# damit auch ein neu hinzugekommener Dashboards-Ordner den Hash ändert.
# Verzeichnisse vorab anlegen: auf dem Erstlauf existieren sie noch nicht
# (die install -d unten kommen erst nach dieser Stelle), "find" gäbe dann
# Exit 1 und pipefail+set -e brächen hier ohne Meldung ab. "|| true" fängt
# jeden weiteren Pipeline-Fehler ab: falscher Hash bedeutet nur einen
# zusätzlichen Grafana-Neustart, kein Setup-Abbruch.
install -d -m 0755 /opt/coder/grafana/provisioning/datasources \
                  /opt/coder/grafana/provisioning/dashboards
GRAFANA_PROV_BEFORE=$(find /opt/coder/grafana/provisioning -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1 || true)
# Lauf-Status VOR dem Schreiben (gleiche Idee wie CADDY_WAS_RUNNING): nur ein
# Container, der schon mit der alten Datei lief, braucht danach einen Neustart.
PROM_CFG_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' coder-prometheus 2>/dev/null || echo false)
GRAFANA_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' coder-grafana 2>/dev/null || echo false)

# A2: Erst die Alarmregeln schreiben (eigener Validierer), dann
# prometheus.yml – der Config-Validierer lädt die rule_files mit und sieht
# so die frisch geschriebenen Regeln.
# C3: Alarmregeln (einzige Alarmkanäle ohne Alertmanager: Prometheus-eigenen
# /alerts + Grafana). Drei Regeln, alle mit messbarer Grundlage:
#   1. Coder-Target down  2. Root-Partition <10% frei  3. letztes Backup >25h
# Kein "absent()"-Zweig für Regel 3: fehlende Metrik = seit Aufsetzen noch
# kein Backup gelaufen, das meldet ohnehin das erste erfolgreiche Laufdatum;
# ehrlicher als ein Alarm direkt nach der Installation.
install -d -m 0755 /opt/coder/prometheus/rules
write_managed "/opt/coder/prometheus/rules/coder-alerts.yml" 644 - validate_prom_rules <<'EOF'
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
EOF

# prometheus.yml (komplettes Verzeichnis gemountet, siehe compose)
install -d -m 0755 /opt/coder/prometheus
write_managed "/opt/coder/prometheus/prometheus.yml" 644 "prometheus.yml" validate_prom_config <<'EOF'
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

# C3/Dashboards: Dashboard „Server-Last" (Gesamtlast des Servers über die Zeit:
# CPU, Arbeitsspeicher, Load-Average, Wurzelpartition) als Anbieter + JSON
# provisionieren. Weitere Dashboards: JSON in dasselbe Verzeichnis legen.
install -d -m 0755 /opt/coder/grafana/provisioning/dashboards
write_managed "/opt/coder/grafana/provisioning/dashboards/dashboards.yml" 644 - <<'EOF'
apiVersion: 1

providers:
  - name: coder
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

write_managed "/opt/coder/grafana/provisioning/dashboards/server-load.json" 644 - <<'EOF'
{
  "id": null,
  "uid": "server-load",
  "title": "Server-Last",
  "tags": ["coder"],
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 0,
  "editable": true,
  "graphTooltip": 1,
  "refresh": "1m",
  "time": { "from": "now-6h", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "CPU-Auslastung",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "coder-prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "percent", "min": 0, "max": 100,
          "custom": { "drawStyle": "line", "lineWidth": 1, "fillOpacity": 10 } },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "single", "sort": "none" }
      },
      "targets": [
        { "refId": "A", "expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)", "legendFormat": "Gesamt" }
      ]
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Arbeitsspeicher belegt",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "coder-prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "percent", "min": 0, "max": 100,
          "custom": { "drawStyle": "line", "lineWidth": 1, "fillOpacity": 10 } },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "single", "sort": "none" }
      },
      "targets": [
        { "refId": "A", "expr": "100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))", "legendFormat": "belegt" }
      ]
    },
    {
      "id": 3,
      "type": "timeseries",
      "title": "Load-Average",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "coder-prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "short", "min": 0,
          "custom": { "drawStyle": "line", "lineWidth": 1, "fillOpacity": 0 } },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "none" }
      },
      "targets": [
        { "refId": "A", "expr": "node_load1", "legendFormat": "1 Min" },
        { "refId": "B", "expr": "node_load5", "legendFormat": "5 Min" },
        { "refId": "C", "expr": "node_load15", "legendFormat": "15 Min" }
      ]
    },
    {
      "id": 4,
      "type": "timeseries",
      "title": "Wurzelpartition belegt",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "coder-prometheus" },
      "fieldConfig": {
        "defaults": { "unit": "percent", "min": 0, "max": 100,
          "custom": { "drawStyle": "line", "lineWidth": 1, "fillOpacity": 10 } },
        "overrides": []
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "single", "sort": "none" }
      },
      "targets": [
        { "refId": "A", "expr": "100 * (1 - (node_filesystem_avail_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"}))", "legendFormat": "/" }
      ]
    }
  ]
}
EOF

# C1: Zielverzeichnis der Backup-Metrik. MUSS 0755 sein: backup.sh läuft mit
# "umask 077" und würde das Verzeichnis sonst anlegen, wenn es fehlt – dann
# könnte node-exporter die Datei nicht lesen und die Metrik bliebe tot.
install -d -m 0755 /opt/coder/node-textfile

GRAFANA_PROV_AFTER=$(find /opt/coder/grafana/provisioning -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1 || true)

# Wartungsskripte am Ende von Schritt 2 schreiben, VOR dem Stack-Start:
# Schritt 3 verlangt bei vorhandenem DB-Volume /opt/coder/backup.sh und bricht
# sonst als "inkonsistente Installation" ab – läge die Schleife noch in
# Schritt 5, würde eine Unterbrechung zwischen "up -d" und Schritt 5 den
# Re-Run genau dort aufbrechen. write_managed prueft *.sh per bash -n und
# schreibt atomar.
for _src in "${SETUP_DIR}"/scripts/*.sh; do
  _src_base="$(basename "${_src}")"
  write_managed "/opt/coder/${_src_base}" 755 "${_src_base}" < "${_src}"
done
# Alten TLS-Check-Bestand (check-tls.sh, Cron, Metrik, Log) still entfernen –
# Caddy betreibt ACME selbst, eine eigene Zählung gibt es nicht (D-TLS);
# jeweils idempotenter No-Op.
rm -f /etc/cron.d/coder-tlscheck /opt/coder/check-tls.sh \
      /var/log/coder-tls.log /opt/coder/node-textfile/coder_tls.prom

echo "############################################################"
echo "# [3/7] Docker-Stack starten"
echo "############################################################"
cd /opt/coder

# B-013: volle Platte endete sonst in set -e-Tod mit Roh-Fehlermeldung.
# Platte WARN ab 1 GB (grober Hinweis, kein Ersatz für D-Monitoring); der
# Daemon-Fail liegt vor dem Pull in Schritt 2.
if _avail=$(df --output=avail -B1 /opt/coder 2>/dev/null | tail -n1 | tr -d ' '); then
  if [ "${_avail}" -lt 1073741824 ]; then
    warn "Wenig Platte unter /opt/coder (${_avail} < 1 GB, grober Hinweis) – Images/Backups brauchen Luft"
  fi
fi

# KEIN Upgrade ohne frisches
# Backup. Schritt 3 zieht Bilder und "up -d" kann eine Coder-DB-Schema-
# Migration ausführen – ohne Dump wäre danach kein Rollback möglich.
# Entscheidend ist der BESTAND (DB-Volume), nicht ob der postgres-Container
# zufällig gerade läuft: gestoppter Container + vorhandenes Volume + erneuter
# Setup-Lauf würde sonst ohne Dump in eine mögliche Migration starten.
# Erstlauf ohne Volume braucht kein Backup; Volume ohne backup.sh ist eine
# inkonsistente Installation und bricht hart ab (die Schleife steht seit
# Schritt 2). Gesichert wird nur bei VersionsWECHSEL gegen versions.env –
# nur dann läuft beim "up -d" eine DB-Migration; bei unveränderter Version
# deckt der tägliche Cron-Lauf die Sicherung ab. Der Wartungs-Lock hängt
# schon an diesem Prozess (CODER_MAINTENANCE_LOCK_HELD=1), backup.sh
# erwirbt keinen zweiten. Fehlschlag bricht vor "up -d" ab, nichts ist
# verändert. Gestopptes Postgres wird vor dem Dump gestartet (gepinntes
# Major-Image, vorhandenes Volume – keine Coder-Migration, der läuft erst
# mit dem Coder-Container in Schritt 3).
# Projekt-Label (name: coder, steht in der Compose-Datei): ohne das würde
# auch das postgres_data eines FREMDEN Compose-Projekts diesen Pfad auslösen.
if [ -n "$(docker volume ls -q --filter "label=com.docker.compose.project=coder" --filter "label=com.docker.compose.volume=postgres_data" 2>/dev/null | head -n1)" ]; then
  if [ ! -x /opt/coder/backup.sh ]; then
    echo "FEHLER: DB-Volume vorhanden, aber /opt/coder/backup.sh fehlt – inkonsistente Installation, kein Upgrade ohne Backup-Möglichkeit." >&2
    echo "scripts/backup.sh aus dem Repo nach /opt/coder/ kopieren (755), dann Setup erneut." >&2
    exit 1
  fi
  # versions.env fehlt oder nennt eine andere Version (Erst-Upgrade,
  # manueller Eingriff) => Backup laufen lassen. -Fqx: wörtlich, ganze Zeile.
  if grep -Fqx "CODER_VERSION=${CODER_VERSION}" "${VERSIONS_FILE}" 2>/dev/null; then
    echo "Coder-Version unverändert (${CODER_VERSION}) – Pre-Upgrade-Backup entfällt, keine DB-Migration erwartet (Cron sichert täglich)."
  else
    if [ "$(docker inspect -f '{{.State.Running}}' coder-postgres 2>/dev/null || echo false)" != "true" ]; then
      echo "Postgres-Container läuft nicht, DB-Volume ist aber da – starte Postgres für das Pre-Upgrade-Backup ..."
      docker compose up -d postgres
      _pg_ready=false
      for _ in $(seq 1 30); do
        if docker exec coder-postgres pg_isready -U coder > /dev/null 2>&1; then
          _pg_ready=true
          break
        fi
        sleep 2
      done
      if [ "${_pg_ready}" != "true" ]; then
        echo "FEHLER: Postgres wird nach 60 s nicht bereit – kein Dump möglich, Abbruch vor 'docker compose up -d'." >&2
        exit 1
      fi
    fi
    echo "Ziehe Pre-Upgrade-Backup vor möglicher DB-Migration (Version ${CODER_VERSION} neu gegenüber ${VERSIONS_FILE}) ..."
    if ! env CODER_MAINTENANCE_LOCK_HELD=1 /opt/coder/backup.sh; then
      echo "FEHLER: Pre-Upgrade-Backup fehlgeschlagen – Abbruch vor 'docker compose up -d'." >&2
      echo "Ursache prüfen (Platte/Postgres), Backup laufen lassen, dann Setup erneut." >&2
      exit 1
    fi
  fi
fi

# A2: Compose/Caddyfile/Prometheus wurden in Schritt 2 bereits validiert, BEVOR
# sie die Live-Platte erreicht haben – hier wird nur noch gestartet.
docker compose up -d

# Die wirksam
# gewesene Version wird bewusst SOFORT nach "up -d" persistiert, nicht erst
# nach den Health-Checks. Grund: die DB-Migration läuft beim Start der neuen
# Coder-Version, nicht erst bei "gesund" – würde erst nach Healthcheck
# geschrieben, bliebe nach einem Crash die ALTE Version eingetragen, obwohl
# die DB schon migriert ist, und der Downgrade-Schutz ließe genau den
# gefährlichen Rollback zu. "wirksam" heißt hier "kann migriert haben",
# nicht "ist gesund" – Gesundheit meldet Schritt 7. "install -d" sichert
# den Pfad, falls dieser Block je früher stünde (A1: cat legt keine
# Verzeichnisse an).
install -d -m 0755 /opt/coder
write_managed "${VERSIONS_FILE}" 644 - <<VERSIONSEOF
# Von setup-coder.sh erzeugt – wirksam gewesene Version des letzten Laufs.
# Kein Geheimnis, daher 644 (unten ohne sudo lesbar).
CODER_VERSION=${CODER_VERSION}
VERSIONSEOF

# A2/C4: Reload bei JEDEM Lauf, solange Caddy lief – die Datei ist beim
# Schreiben bereits validiert (write_managed + validate_caddyfile), ein
# erneutes validate vor dem Reload wäre derselbe Prüfpfad mit demselben
# Ergebnis. Reload geht über die Admin-API (verbindungserhaltend – P-025
# verbietet nur Restarts), ist bei unveränderter Datei ein No-Op. Schlägt
# er fehl (z.B. Admin-API weg), behält Caddy automatisch die laufende
# Konfiguration – "restart" ist bewusst KEIN Fallback (C4). Erstlauf ohne
# laufendes Caddy braucht kein Reload – "up -d" hat den Container gerade
# mit der Datei gestartet.
if [ "${CADDY_WAS_RUNNING}" = "true" ]; then
  if docker exec coder-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1; then
    ok "Caddy reload OK (ohne Verbindungsabbruch, gevaliderte Datei) (C4)"
  else
    warn "caddy reload fehlgeschlagen – Caddy läuft weiter mit der ALTEN Konfiguration. Manuell prüfen: sudo docker exec coder-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile (C4)"
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
  echo "Grafana-Provisioning unverändert – kein Neustart."
elif [ "${GRAFANA_WAS_RUNNING}" != "true" ]; then
  echo "Grafana-Provisioning neu/geändert, Container lief vorher nicht – läuft bereits mit der neuen Konfiguration, kein Neustart."
elif docker restart coder-grafana > /dev/null 2>&1; then
  ok "Grafana neu gestartet, damit Provisioning (Datasource/Dashboards) greift (C3)"
else
  warn "Neustart von coder-grafana fehlgeschlagen – Provisioning manuell nachziehen: sudo docker restart coder-grafana (C3)"
fi

docker compose ps

echo "############################################################"
echo "# [4/7] Firewall (ufw) + SSH-Schutz einrichten"
echo "############################################################"
apt_install ufw fail2ban

# Der sshd-Port-Check steht im Preflight (vor Schritt 1) – A10: Vorbedingungen
# gehören vor die Installation, nicht erst vor der ersten Firewall-Änderung.
#
# B11/D-SSH: kein Quellbeschränkungs-Pfad und kein Rate-Limit in der Firewall.
# Die Netzgrenze (SSH nur aus dem Schulnetz) liegt am Router; fail2ban ist der
# Brute-Force-Schutz. ufw limit (6 Verbindungen/30 s je Quell-IP) würde die
# geteilte Schul-NAT-IP drosseln – alle dahinter zahlen mit. Invarianten:
#   - Ohne lesbaren ufw-Status wird NICHTS geaendert (Abbruch).
#   - Nichts wird geloescht, außer der eigenen alten limit-Regel frueherer
#     Laeufe (erst allow setzen, dann loeschen – niemals ein Fenster ohne
#     SSH-Regel). Quellregeln und fremde Regeln bleiben unangetastet.
if ! UFW_OUT="$(ufw status numbered 2>/dev/null)"; then
  fail "ufw-Status nicht lesbar – Abbruch vor jeder Regel-/Policy-Änderung (SSH-Schutz)."
  exit 1
fi
if grep -qi 'Status:[[:space:]]*inactive' <<< "${UFW_OUT}"; then
  warn "ufw ist inaktiv (Status: inactive) – Firewall wird jetzt eingerichtet"
fi

# Regelanwendung: einfache feste Folge. Reihenfolge erst Policy, dann
# SSH-Regeln; "allow" ist idempotent ("Skipping adding existing rule").
ufw default deny incoming
ufw default allow outgoing
# SSH: allow für die im Preflight erkannten sshd-Ports (funktioniert auch
# bei einem Nicht-22-Port).
for _ssh_p in ${SSHD_PORTS}; do
  ufw allow "${_ssh_p}/tcp"
done
# Eigene Altregel aus der limit-Ära entfernen – allow steht bereits, also
# kein Augenblick ohne SSH-Regel. Nicht vorhanden = stiller No-Op.
ufw --force delete limit 22/tcp > /dev/null 2>&1 || true

# Nur die Nicht-Defaults setzen. Debian liefert selbst [sshd] enabled=true,
# backend=systemd und journalmatch in jail.d/defaults-debian.conf sowie
# maxretry=5/findtime=10m in jail.conf (am Test-Host geprueft 2026-10-03);
# die Schluessel bleiben in unserer .local also aus, weil fail2ban sektionen-
# uebergreifend pro Schluessel fusioniert. Fehlt die Debian-Datei, merkt der
# Abschlusscheck "fail2ban-client status sshd" das (Jail antwortet nicht).
# port traegt die im Preflight erkannten sshd-Ports (anders als Debian-Default
# "ssh" = nur 22 wuerde ein Nicht-22-Port nie beobachtet).
# B7: Eigene Jails in einen Drop-In unter jail.d/ legen.
# Lese-Reihenfolge von fail2ban (man jail.conf):
#   jail.conf -> jail.d/*.conf -> jail.local -> jail.d/*.local
# Unser Dateiname faellt unter "jail.d/*.local" und hat damit VORRANG vor
# einer Hand-angelegten jail.local – dort geschriebene Jails greifen also
# NICHT. Deshalb WARN, solange jail.local existiert, statt sie still
# anzutasten (ohne Produktion gibt es keine setup-eigene Alt-Datei).
JAIL_DROPIN="/etc/fail2ban/jail.d/10-coder-sshd.local"
if [ -f /etc/fail2ban/jail.local ]; then
  warn "Vorgefunden: /etc/fail2ban/jail.local – unser Drop-In ${JAIL_DROPIN} hat laut Lese-Reihenfolge Vorrang, dort geschriebene Jails greifen nicht. Eigene Werte in den Drop-In übernehmen und jail.local entfernen."
fi
mkdir -p /etc/fail2ban/jail.d
# bantime.increment verlängert Wiederholungssperren. ignoreip enthält NUR
# Admin-Plätze (Default loopback); die Schul-NAT wird bewusst NICHT
# eingetragen: Rateversuche aus dem
# Schulnetz sollen sperren. Werte dauerhaft in setup.conf eintragen
# (Schlüssel FAIL2BAN_IGNORE_IP, siehe setup.conf.example).
write_managed "/etc/fail2ban/jail.d/10-coder-sshd.local" 644 "fail2ban-jail.d/10-coder-sshd.local" <<EOF
[sshd]
port     = ${SSHD_PORTS// /,}
bantime  = 1h
bantime.increment = true
ignoreip = ${FAIL2BAN_IGNORE_IP}
EOF
# B13/A7e: hart starten, dann reloaden – die alte Annahme "restart verwirft
# aktive Bans" war falsch: fail2ban stellt Bans beim (Neu-)Start aus seiner
# SQLite-DB (Debian-Default dbfile aktiv) wieder her. Nach "enable --now"
# braucht der Client einen Moment, deshalb wird der Reload bis 15 s wiederholt.
systemctl enable --now fail2ban
F2B_RELOADED=false
for _ in $(seq 1 15); do
  if fail2ban-client reload > /dev/null 2>&1; then
    F2B_RELOADED=true
    break
  fi
  sleep 1
done
if [ "${F2B_RELOADED}" = "false" ]; then
  fail "fail2ban-Client antwortet nach 15 s nicht – prüfen mit: sudo fail2ban-client ping"
  exit 1
fi

# B-007/A7b: Docker trägt für "ports:"-veröffentlichte Container-Ports
# (80/443 von Caddy) eigene iptables-Regeln ein, die ufw für Zugriffe von
# AUSSEN umgehen – dort bringen diese Regeln nichts. Für Zugriffe vom
# Docker-Netz auf die Host-IP (z.B. Workspace-Agent -> CODER_ACCESS_URL) und
# für IPv6 laufen sie aber über INPUT/docker-proxy und werden gebraucht,
# deshalb bleiben sie stehen. Bindungsregel: neue "ports:"-Einträge NUR als
# "127.0.0.1:<port>:<port>" – öffentliche Ports bleiben Caddy (80/443)
# vorbehalten, Prometheus/node-exporter UND Grafana sind nur an 127.0.0.1
# gebunden. SSH gilt nicht als Docker-Port: sshd ist ein Host-Dienst,
# ufw/fail2ban greifen hier.
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
# Grafana 3001: alte Quellregeln aus der "Schulnetz via ufw"-Ära entfernen
# (Grafana ist loopback-gebunden,
# eine ufw-Regel wäre nur noch eine Lug-Regel). Idempotent: nicht vorhanden =
# stiller No-Op. Reihenfolge: Regeln löschen, dann unten "enable".
for _spec in \
  "from 10.0.0.0/8 to any port 3001 proto tcp" \
  "from 172.16.0.0/12 to any port 3001 proto tcp" \
  "from 192.168.0.0/16 to any port 3001 proto tcp" \
  "3001/tcp"; do
  # shellcheck disable=SC2086 # Wortaufteilung der ufw-Spezifikation ist Absicht
  ufw --force delete allow ${_spec} > /dev/null 2>&1 || true
done
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
# SSH: die im Preflight erkannten Ports müssen als ALLOW (Anywhere) stehen;
# eine LIMIT-Regel erfüllt diesen Check nicht (D-SSH: ufw limit würde die geteilte
# Schul-NAT drosseln, fail2ban ist der Brute-Force-Schutz) und Quellregeln
# allein zahlen auch nicht – diese Firewall soll den Zugang nur nicht
# versehentlich verschließen, die Netzgrenze liegt am Router.
UFW_SSH_MISSING=""
for _p in ${SSHD_PORTS}; do
  if grep -qE "^${_p}/tcp[[:space:]]+ALLOW[[:space:]]+Anywhere" <<< "${UFW_STATUS}"; then
    ok "SSH-Port ${_p}/tcp steht als ALLOW in ufw"
  else
    UFW_SSH_MISSING="${UFW_SSH_MISSING} ${_p}"
  fi
done
if [ -n "${UFW_SSH_MISSING}" ]; then
  fail "SSH-ALLOW-Regel fehlt in ufw für Port(s):${UFW_SSH_MISSING} – prüfen mit: sudo ufw status"
fi
# B13: ein einziger Check statt is-active/ping/Total-failed – "status sshd"
# liefert nur Exit 0, wenn Dienst UND Jail antworten (der Reload-Retry oben
# hat dem Client schon Zeit zum Hochfahren gegeben).
if fail2ban-client status sshd > /dev/null 2>&1; then
  ok "fail2ban-Jail 'sshd' antwortet (fail2ban-client status sshd Exit 0)"
else
  fail "fail2ban-Client oder Jail 'sshd' antwortet nicht – prüfen mit: sudo fail2ban-client status"
fi
# D-SSH/Policy: Passwort-Login für
# normale Benutzer ausdrücklich erlaubt, root bleibt bei Schlüssel. Das
# "von überall" hält die ufw-ALLOW-Regel oben; hier wird die sshd-Seite
# aktiv gesetzt statt nur beobachtet. Validierung: sshd -T über die GESAMTE
# Konfiguration (ein einzelner Drop-In ist kein vollständiger Config-Check).
# Bei Fehlschlag: alten Inhalt wiederherstellen und abbrechen – nie mit
# ungetesteter Datei neu laden.
# Reihenfolge: sshd nimmt pro Keyword den ERSTEN Wert, Drop-ins werden
# alphabetisch gelesen. 01-coder.conf schlägt jede 50-* -Datei (z.B.
# cloud-init), das Härtungs-Snippet 00-coder-hardening.conf schlägt 01-coder
# (Ziffernvergleich, keine Sonderzeichen-Abhängigkeit).
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-coder.conf"
_SSHD_DROPIN_OLD="$(cat "${SSHD_DROPIN}" 2>/dev/null || true)"
install -d -m 755 /etc/ssh/sshd_config.d
write_managed "${SSHD_DROPIN}" 644 - <<'EOF'
# Von setup-coder.sh erzeugt (D-SSH): SSH-Policy dieses Coder-Servers.
# Passwort-Login für normale Benutzer ist bewusst erlaubt; Schutz gegen
# Brute-Force: fail2ban (Jail sshd) plus ufw-allow (kein limit, Netzgrenze
# am Router). Root nur per Schlüssel.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin prohibit-password
EOF
# Alt-Format 99-coder.conf: 99 sortierte hinter allem (50-cloud-init.conf
# gewann), die Effekt-Checks unten hätten jeden Lauf rot. Nur unser eigenes
# Alt-Drop-In entfernen (Markierung im Header), fremde 99-coder.conf nicht.
if [ -f /etc/ssh/sshd_config.d/99-coder.conf ] \
  && grep -qF 'Von setup-coder.sh erzeugt (D-SSH)' /etc/ssh/sshd_config.d/99-coder.conf; then
  rm -f /etc/ssh/sshd_config.d/99-coder.conf
  echo "Eigenes Alt-Drop-In 99-coder.conf entfernt (Neformat: 01-coder.conf)."
fi
if ! _SSHD_T_OUT="$(sshd -T 2>&1)"; then
  echo "Fehler: sshd-Konfiguration nach dem Schreiben von ${SSHD_DROPIN} ist ungültig:" >&2
  printf '%s\n' "${_SSHD_T_OUT}" >&2
  if [ -n "${_SSHD_DROPIN_OLD}" ]; then
    printf '%s\n' "${_SSHD_DROPIN_OLD}" > "${SSHD_DROPIN}"
    echo "Alter Inhalt von ${SSHD_DROPIN} wiederhergestellt." >&2
  else
    rm -f "${SSHD_DROPIN}"
    echo "${SSHD_DROPIN} entfernt (vorher nicht vorhanden)." >&2
  fi
  echo "Abbruch vor dem Reload – die laufende SSH-Sitzung bleibt unberührt." >&2
  exit 1
fi
if systemctl is-active --quiet ssh; then
  systemctl reload ssh
else
  warn "ssh-Dienst nicht aktiv – Drop-In geschrieben, Reload entfällt (lädt beim nächsten ssh-Start)"
fi
# Effekt-Check gegen die NEU geladene Konfiguration, nicht den Preflight-
# Snapshot – sonst würde der Check die alte Welt bewerten.
SSHD_EFFECTIVE_CONFIG="$(sshd -T 2>/dev/null || true)"
ok "sshd-Policy gesetzt (${SSHD_DROPIN}: Passwort ja, KbdInteractive ja, root nur Schlüssel) und neu geladen"
if grep -qi '^passwordauthentication yes' <<< "${SSHD_EFFECTIVE_CONFIG}" \
  && grep -qi '^kbdinteractiveauthentication yes' <<< "${SSHD_EFFECTIVE_CONFIG}"; then
  ok "SSH-Passwort-Login erlaubt (PasswordAuthentication/KbdInteractiveAuthentication yes)"
else
  fail "SSH-Passwort-Login NICHT aktiv (erwartet yes in ${SSHD_DROPIN}) – prüfen mit: sudo sshd -T | grep -iE 'passwordauthentication|kbdinteractive' (Vorrang anderer Drop-Ins?)"
fi
# root per Passwort von ueberall waere ein Upgrade-Pfad jeden
# Brute-Forces – unser Drop-In schreibt prohibit-password; Warnung fängt
# Vorrang fremder Drop-Ins/Altkonfiguration ab.
if grep -qi '^permitrootlogin yes' <<< "${SSHD_EFFECTIVE_CONFIG}"; then
  warn "PermitRootLogin yes wirkt (Vorrang vor ${SSHD_DROPIN}) – bei Passwort-SSH von überall nicht tragbar. Andere Drop-Ins unter /etc/ssh/sshd_config.d prüfen, prohibit-password durchsetzen, sshd -t, reload."
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
# Grafana 3001: bewusst KEINE
# ufw-Regel – Loopback-Bindung ist der Schutz; eine stehengebliebene Altregel
# wäre eine Lug-Regel (behauptet "Schulnetz-Schutz", den Docker ohnehin
# umgeht) und wird oben bereits idempotent gelöscht.
if grep -qE '^3001/tcp[[:space:]]' <<< "${UFW_STATUS}"; then
  warn "Altregel 3001/tcp steht noch in ufw (Löschen oben fehlgeschlagen?) – überflüssig, Grafana ist nur an 127.0.0.1 gebunden. Prüfen: sudo ufw status"
else
  ok "keine ufw-Regel für 3001 (Grafana nur 127.0.0.1, per SSH-Tunnel erreichbar)"
fi

echo "############################################################"
echo "# [5/7] Automatische Sicherheitsupdates einrichten"
echo "############################################################"
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
// hinterlegen (laufende Workspaces/Sessions werden abgerissen).
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

APT_UU_CONFIG="$(apt-config dump 2>/dev/null || true)"
# unattended-upgrades ist auf Debian ein oneshot-Service, den
# apt-daily-upgrade.timer anstößt – geprüft wird der Timer (aktiv +
# enabled), dazu die APT::Periodic-Zeile oben.
if systemctl is-active --quiet apt-daily-upgrade.timer \
  && systemctl is-enabled --quiet apt-daily-upgrade.timer; then
  ok "apt-daily-upgrade.timer aktiv und enabled (stößt unattended-upgrades an)"
else
  fail "apt-daily-upgrade.timer läuft nicht/enabled fehlt – automatische Updates greifen nicht (systemctl status apt-daily-upgrade.timer)"
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

echo "############################################################"
echo "# [6/7] Tägliches Datenbank-Backup einrichten"
echo "############################################################"

# F-009(a): ohne Cron-Daemon läuft nie ein Backup, das Setup meldete trotzdem
# [OK]. Das Paket wurde bereits in Schritt 1 installiert; hier werden die
# geordneten Eintraege aktiviert.
# "enable --now": enable ist idempotent, start ist No-Op wenn aktiv.
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

# C4/Update: überflüssige Logrotate-Datei entfernen (coder-backup.log hat
# eine eigene Datei).
rm -f /etc/logrotate.d/coder-logs

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

# B21: Testlauf nur, solange noch KEIN Backup existiert – bei Re-Run lief das
# Pre-Upgrade-Backup (Schritt 3) bereits, ein zweiter Voll-Dump pro Lauf ist
# überflüssig. Erstmaliger Aufbau testet also, jeder spätere Lauf nicht.
if ls /opt/coder/backups/coder_*.sql.gz > /dev/null 2>&1; then
  echo "Vorhandene Backups unter /opt/coder/backups – Backup-Testlauf übersprungen."
else
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
fi

# B-008: Runbook auf dem Server ablegen, damit Verweise ("/opt/coder" auf dem
# Server) dort auflösen. SETUP_DIR ist vor dem cd nach /opt/coder berechnet.
if [ -f "${SETUP_DIR}/RESTORE.md" ]; then
  cp -a "${SETUP_DIR}/RESTORE.md" /opt/coder/RESTORE.md
  chmod 644 /opt/coder/RESTORE.md
  ok "Runbook nach /opt/coder/RESTORE.md abgelegt"
else
  warn "RESTORE.md liegt nicht neben setup-coder.sh – kein Runbook auf Server abgelegt"
fi

echo "############################################################"
echo "# [7/7] Abschlusscheck & Zusammenfassung"
echo "############################################################"

# Alte Hashstore-Datei aus der Drift-Ära (B-012, entfernt 2026-10-03)
# still entfernen – kein Verfahren hängt mehr daran.
rm -f /opt/coder/.generated-hashes

check_container_running "coder-postgres" "Postgres-Container"
check_container_running "coder" "Coder-Container"
check_container_running "coder-caddy" "Caddy-Container"
check_container_running "coder-prometheus" "Prometheus-Container"
check_container_running "coder-node-exporter" "Node-Exporter-Container"
check_container_running "coder-grafana" "Grafana-Container"

# F-007/P-012: "Container läuft" beweist keinen Socket-Zugriff. Host-seitige
# Probe (kein Tool im Coder-Image vorausgesetzt): GroupAdd des Containers muss
# die aktuelle docker-GID enthalten, sonst "Permission denied" auf
# /var/run/docker.sock und keine Workspace-Provisionierung. Volltreffer in
# JSON-Schreiben ("999"), kein Teilsting-Match: 99 dürfte nicht auf "999"
# passen und fälschlich [OK] melden.
if CODER_GROUPS=$(docker inspect --format '{{json .HostConfig.GroupAdd}}' coder 2>/dev/null); then
  if [ -n "${DOCKER_GID:-}" ] && grep -q "\"${DOCKER_GID}\"" <<< "${CODER_GROUPS}"; then
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
# wenn der Betreiber E-Mail und Benutzername setzt (sonst unverändertes
# Verhalten). A4: interaktiv kommt das Passwort NIEMALS auf eine Kommandozeile
# (read -rs). Nicht-interaktiv bevorzugt CODER_FIRST_USER_PASSWORD_FILE – der
# Pfad zeigt auf eine root-only Datei, ihr Inhalt bleibt in ps und History
# weg; die nackte Variable CODER_FIRST_USER_PASSWORD ist bewusster Fallback
# (steht bei "sudo env …" in ps und Shell-History – vorher abwägen).
# Übergabe in den Container läuft per stdin (derselbe Weg wie der ALTER-USER
# unten).
if [ "${HUMAN_USERS}" = "0" ] \
  && [ -n "${CODER_FIRST_USER_EMAIL:-}" ] \
  && [ -n "${CODER_FIRST_USER_USERNAME:-}" ] \
  && [ -z "${CODER_FIRST_USER_PASSWORD:-}" ]; then
  if [ -n "${CODER_FIRST_USER_PASSWORD_FILE:-}" ]; then
    if [ ! -r "${CODER_FIRST_USER_PASSWORD_FILE}" ]; then
      echo "Fehler: CODER_FIRST_USER_PASSWORD_FILE='${CODER_FIRST_USER_PASSWORD_FILE}' ist nicht lesbar." >&2
      exit 1
    fi
    CODER_FIRST_USER_PASSWORD="$(cat -- "${CODER_FIRST_USER_PASSWORD_FILE}")"
    case "${CODER_FIRST_USER_PASSWORD}" in
      '')
        echo "Fehler: CODER_FIRST_USER_PASSWORD_FILE enthält kein Passwort (leere Datei)." >&2
        exit 1 ;;
      *$'\n'*)
        echo "Fehler: CODER_FIRST_USER_PASSWORD_FILE enthält mehr als eine Zeile – nur einzeilige Passwörter." >&2
        exit 1 ;;
    esac
  elif [ -t 0 ]; then
    read -rs -p "Erstkonto: Passwort für '${CODER_FIRST_USER_USERNAME}' eingeben (leer lassen = im Browser anlegen): " \
      CODER_FIRST_USER_PASSWORD || CODER_FIRST_USER_PASSWORD=""
    echo ""
  fi
fi
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
    # Frisch angelegt – der case danach soll nicht "Noch kein Nutzerkonto"
    # melden, nur weil HUMAN_USERS vor der Anlage gelesen wurde.
    HUMAN_USERS=1
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
echo "*.${DOMAIN_CODER} -> öffentliche Server-IP (siehe README.md)."
echo "Neue Releases: Pin in setup-coder.sh (Versions-Variablen) ändern und"
echo "das Setup erneut ausführen. Docker-Engine-Updates sind separat und manuell."
echo "Grafana: nur 127.0.0.1:3001 (Login admin), Zugang per SSH-Tunnel: ssh -L 3001:127.0.0.1:3001 <user>@<server>, dann http://127.0.0.1:3001"

if [ "${ERROR_COUNT}" -gt 0 ]; then
  echo ""
  echo "${ERROR_COUNT} [FEHLER]-Eintrag/-Einträge in der Zusammenfassung oben – bitte prüfen."
  exit 1
fi
