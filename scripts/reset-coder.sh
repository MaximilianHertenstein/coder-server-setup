#!/bin/bash
# Setzt die Coder-Installation zurück, als wäre sie neu installiert:
# Datenbank, Grafana-Dashboards und generierte Passwörter (.env) werden
# gelöscht. Backups unter /opt/coder/backups bleiben erhalten.
# Caddys Zertifikate (caddy_data/caddy_config) bleiben ABSICHTLICH erhalten:
# ein Reset während der Testphase soll nicht bei jedem Mal ein neues Let's-
# Encrypt-Zertifikat anfordern und so das Wochen-Rate-Limit pro Domain
# riskieren. Betrifft NUR den Coder-Stack, nicht den Server selbst
# (SSH/Firewall/OS bleiben unverändert).
#
# Ablauf (F-011/P-019): Inventar (hart: Nicht-Compose-Container = Abbruch)
# -> Backup -> Bestätigung erst nach
# Backup-Ergebnis -> Löschung. Mit --force bei Backup-Fehlschlag zusätzlich
# Zweitbestätigung mit Anzeige des neuesten Backups.
# Nutzung: sudo /opt/coder/reset-coder.sh [--force]
#   --force: Reset auch durchführen, wenn das Sicherheits-Backup fehlschlägt
#            (ohne --force bricht das Skript in diesem Fall ab, statt
#            möglicherweise die einzige Datenrettung zu verlieren).
#            B-020/Break-Glass: --force ist KEIN Komfort-Flag, sondern die
#            bewusste Freigabe zur Zerstörung ohne Netz (Backup defekt oder
#            kein Backup vorhanden). Wer: nur der dokumentierte Betreiber nach
#            Kenntnisnahme des neuesten verfügbaren Backups (wird angezeigt).
#            Nachweis: zweite Eingabe 'RESET-OHNE-BACKUP' (immer interaktiv,
#            P-019 verweigert Pipe auch mit --force).
#            Andere Argumente werden abgelehnt (kein stilles Ignorieren von
#            Tippfehlern). --force ersetzt NICHT das Fremd-Container-Gate.
# Danach: sudo ./setup-coder.sh erneut ausführen, um alles neu aufzubauen.
set -euo pipefail
cd /opt/coder

# Wartungs-Lock vor Inventar/Backup/Bestätigung halten, damit kein Update,
# Passwortwechsel oder Backup zwischen Sicherung und destruktivem Reset läuft.
(umask 077; : >> /opt/coder/.maintenance.lock)
chown root:root /opt/coder/.maintenance.lock
chmod 600 /opt/coder/.maintenance.lock
exec 8>>/opt/coder/.maintenance.lock
if ! flock -w 300 8; then
  echo "reset-coder.sh: Wartungs-Lock nach 300 s nicht erhalten; Reset abgebrochen." >&2
  exit 75
fi
export CODER_MAINTENANCE_LOCK_HELD=1

FORCE=false
# Kleine CLI: erlaubt sind genau keine
# Argumente oder --force. Ein Tippfehler darf nicht still als "ohne --force"
# weiterlaufen, und Extra-Argumente werden nicht geschluckt.
if [ "$#" -gt 1 ] || { [ "$#" -ge 1 ] && [ "$1" != "--force" ]; }; then
  echo "Fehler: unbekanntes Argument '$*' – erlaubt: sudo /opt/coder/reset-coder.sh [--force]" >&2
  exit 1
fi
if [ "${1:-}" = "--force" ]; then
  FORCE=true
fi

# P-019: Destruktiver Reset braucht IMMER ein Terminal, auch mit --force –
# --force ersetzt nur das Backup-Gate, nicht die bewusste Bestätigung.
# Ein per Pipe eingespeistes "RESET" oder "RESET-OHNE-BACKUP" ist keine
# bewusste Bestätigung.
if [ ! -t 0 ]; then
  echo "Fehler: stdin ist kein Terminal (Pipe/CI erkannt). Destruktiver Reset wird verweigert." >&2
  echo "Interaktiv aufrufen: sudo /opt/coder/reset-coder.sh [--force]" >&2
  exit 1
fi

# Compose-Projektname determinieren (F-004/P-016): Default = Verzeichnisname
# (/opt/coder -> "coder"), aber per -p/Env überstimmbar – daher aus
# "docker compose config" lesen, nie raten. Leer/Fehler = Abbruch.
PROJECT=$(docker compose config | awk '/^name:/ {print $2; exit}' || true)
if [ -z "${PROJECT:-}" ]; then
  echo "Fehler: Compose-Projektname unklar (docker compose config liefert kein 'name:'). Abbruch, nichts wurde verändert." >&2
  exit 1
fi

echo "############################################################"
echo "Inventar VOR dem Reset – Harte Regel:"
echo "es darf KEINE Nicht-Compose-Container geben. Workspace-Container"
echo "entstehen über den Docker-Socket, nicht über docker-compose.yml –"
echo "'down' erfasst sie nicht; mit gelöschter DB liefen sie verwaist"
echo "weiter (Namens-/Port-Konflikte beim Neuaufbau). Labels sind dabei"
echo "egal: ALLE Nicht-Compose-Container sind ZUERST von Hand entfernen."
FOREIGN_LIST="$(docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}' \
  | awk -v p="${PROJECT}" -F'\t' '$3 != p {print "  fremd: " $1 " (" $2 ")"}' || true)"
if [ -n "${FOREIGN_LIST}" ]; then
  printf '%s\n' "${FOREIGN_LIST}"
fi
echo "(Compose-eigene Container mit project=${PROJECT} sind oben nicht gelistet.)"
echo "############################################################"
if [ -n "${FOREIGN_LIST}" ]; then
  echo "Fehler: Nicht-Compose-Container vorhanden (Inventar oben) – Reset abgebrochen, nichts wurde verändert." >&2
  echo "Zuerst aufräumen, dann Reset erneut starten:" >&2
  printf '%s\n' "${FOREIGN_LIST}" >&2
  echo "  Inhalt vorher ansehen (docker inspect <name>), dann: docker rm -f <name>" >&2
  echo "  --force hebt diese Klemme NICHT auf – sie schützt vor verwaisten Containern." >&2
  exit 1
fi
echo "############################################################"
echo "WARNUNG: Das löscht unwiderruflich:"
echo "  - Datenbank (alle Nutzer, Workspaces, Templates)"
echo "  - Grafana-Dashboards/-Einstellungen"
echo "  - Prometheus-Metrikverlauf"
echo "  - generierte Passwörter (.env)"
echo "Backups unter /opt/coder/backups bleiben erhalten."
echo "Caddys Let's-Encrypt-Zertifikate bleiben erhalten (kein Rate-Limit-Risiko)."
echo "Server-Einstellungen (SSH, Firewall, Docker) bleiben unverändert."
echo "############################################################"

echo "Versuche ein letztes Backup vor dem Reset..."
BACKUP_OK=false
if /opt/coder/backup.sh; then
  BACKUP_OK=true
fi

if [ "${BACKUP_OK}" != "true" ]; then
  if [ "${FORCE}" = "true" ]; then
    echo "------------------------------------------------------------"
    echo "Backup fehlgeschlagen, --force gesetzt. Neuestes VERFÜGBARES Backup:"
    LATEST=$(ls -t /opt/coder/backups/coder_*.sql.gz 2>/dev/null | head -n1 || true)
    if [ -n "${LATEST:-}" ]; then
      stat -c '  Datei: %n, Größe: %s Bytes, geändert: %y' "${LATEST}"
      if gzip -t "${LATEST}" 2>/dev/null; then
        echo "  Integrität: gzip -t OK (kein Ersatz für Restore-Test, siehe RESTORE.md)"
      else
        echo "  Integrität: gzip -t FEHLGESCHLAGEN – dieses Backup ist defekt!"
      fi
    else
      echo "  KEIN Backup vorhanden – nach dem Reset gibt es keinen Rückweg!"
    fi
    echo "------------------------------------------------------------"
    read -r -p "Trotzdem löschen? Zum Fortfahren 'RESET-OHNE-BACKUP' eingeben: " CONFIRM2
    if [ "${CONFIRM2}" != "RESET-OHNE-BACKUP" ]; then
      echo "Abgebrochen, nichts wurde verändert."
      exit 1
    fi
  else
    echo "Fehler: Backup vor dem Reset fehlgeschlagen. Abbruch, ohne etwas zu löschen." >&2
    echo "Zum Reset trotzdem erzwingen: sudo /opt/coder/reset-coder.sh --force" >&2
    exit 1
  fi
else
  read -r -p "Backup erfolgreich. Zum Fortfahren 'RESET' eingeben: " CONFIRM
  if [ "${CONFIRM}" != "RESET" ]; then
    echo "Abgebrochen, nichts wurde verändert."
    exit 1
  fi
fi

echo "Ermittle Datenbank-, Grafana- und Prometheus-Volumes (Projekt: ${PROJECT})..."
# F-004/P-016: Filter um project-Label eingeschränkt (generische volume-Namen
# kollidieren sonst mit jedem zweiten Stack), Treffer anzeigen, zeilenweise
# löschen, Allowlist als Guard. Leer-Fall = harter Abbruch VOR rm .env.
VOLUMES_TO_DELETE=""
for VOL_LABEL in postgres_data grafana_data prometheus_data; do
  case "${VOL_LABEL}" in
    postgres_data|grafana_data|prometheus_data) ;;
    *) echo "Fehler: unerwartetes Volume-Label '${VOL_LABEL}' (Allowlist). Abbruch." >&2; exit 1 ;;
  esac
  while IFS= read -r VOL_NAME; do
    [ -n "${VOL_NAME}" ] || continue
    echo "  gefunden: ${VOL_NAME} (${VOL_LABEL})"
    VOLUMES_TO_DELETE="${VOLUMES_TO_DELETE}${VOL_NAME}"$'\n'
  done < <(docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}" --filter "label=com.docker.compose.volume=${VOL_LABEL}")
done

if [ -z "${VOLUMES_TO_DELETE//[$'\n ']/}" ]; then
  echo "Fehler: kein einziges Compose-Volume für project=${PROJECT} gefunden (Label-Mismatch?)." >&2
  echo "Abbruch – nichts angefasst: Stack läuft weiter, Volumes und .env sind unverändert." >&2
  exit 1
fi

# B-016/B-020-Pre-Check + B2-006 (lesend, VOR dem 'down'): hängt an einem zu
# löschenden Volume noch ein Container (fremder Workspace, paralleler Lauf),
# bricht "volume rm" unter set -e mitten in der Teillöschung ab – weder alt
# noch neu lauffähig. Vor v2 stand "down" VOR diesem Check: bei Treffer war der
# Stack bereits halb zerlegt (Container weg, Netz weg, Cron-Backup im Fenster
# rot), obwohl Daten und .env intakt waren. Jetzt bricht das Skript ab, solange
# ALLES noch läuft – Erwartung: belegtes Volume -> Abbruch vor 'down', alle
# Container laufen weiter.
# Projekt-eigene Container zählen NICHT als Beleg: 'down' stoppt sie selbst,
# sie sind kein Hindernis für die spätere volume rm. Geprüft werden nur
# Nicht-Projekt-Container (fremde Workspaces), die das Volume auch nach 'down'
# weiterhin halten würden. Ohne diese Einschränkung würde jeder Re-Run auf
# laufendem Stack abbrechen, weil coder-postgres postgres_data hält (gemessen:
# "docker ps -a --filter volume=<name>" findet laufende Container). "-q"
# fehlt absichtlich neben "--format": docker ignoriert --format bei -q
# ("Ignoring custom format, because both --format and --quiet are set"), das
# Label käme nie an und auch Projekt-Container würden als Beleg zählen.
while IFS= read -r VOL_NAME; do
  [ -n "${VOL_NAME}" ] || continue
  if USERS=$(docker ps -a --filter "volume=${VOL_NAME}" \
      --format '{{.ID}} {{.Label "com.docker.compose.project"}}' 2>/dev/null \
      | awk -v p="${PROJECT}" '$2 != p {print $1}') && [ -n "${USERS:-}" ]; then
    echo "Fehler: Volume ${VOL_NAME} wird noch von Container(n) benutzt: $(echo "${USERS}" | tr '\n' ' ')" >&2
    echo "Abbruch VOR 'docker compose down' – nichts angefasst: alle Container laufen weiter, Volumes und .env sind unverändert (fremde Container erst aufräumen, dann Reset erneut)." >&2
    exit 1
  fi
done <<< "${VOLUMES_TO_DELETE}"

echo "Stoppe Container (caddy_data/caddy_config bleiben unangetastet)..."
echo "(Das Inventar oben war leer – Nicht-Compose-/Workspace-Container sind"
echo "per harter Regel vorher entfernt worden.)"
docker compose down --remove-orphans

while IFS= read -r VOL_NAME; do
  [ -n "${VOL_NAME}" ] || continue
  docker volume rm "${VOL_NAME}"
done <<< "${VOLUMES_TO_DELETE}"

echo "Entferne generierte Passwörter (.env)..."
rm -f .env

echo "------------------------------------------------------------"
echo "Reset abgeschlossen. Zum Neuaufbau:"
echo "  sudo ./setup-coder.sh"
echo "(erzeugt neue Passwörter und startet den Stack komplett neu)"
echo "(Workspace-/fremde Container gab es vorher nicht – harte Regel oben.)"
echo "------------------------------------------------------------"
