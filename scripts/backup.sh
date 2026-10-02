#!/bin/bash
# Tägliches Postgres-Backup (F-005/F-008/F-009, mit P-013/P-017-Korrekturen).
# Aufruf: /opt/coder/backup.sh (direkt, per Cron, aus dem Setup-Pre-Upgrade-
# bzw. Test-Lauf oder aus reset-coder.sh).
# Gleichzeitige Läufe werden per flock serialisiert: der zweite Lauf WARTET
# bis zu 300 s und fertigt danach ein eigenes Backup an, statt die Datei des
# ersten per ">" zu trunkieren (F-009). Läuft der Vorgänger länger, gibt es
# Exit 75 (EX_TEMPFAIL) statt des alten Exit 0.
# A3: Exit 0 war der Fehler – "übersprungen" wurde als Erfolg gewertet und
# ein Update/Reset lief trotz fehlendem Backup weiter. Heute liefern alle
# Ausstiege (Lock-Timeout, Wartungs-Lock, Postgres nicht bereit) ≠0; die
# Aufrufer (Setup, reset-coder.sh) brechen bei ≠0 mit set -e bzw. eigener
# Prüfung korrekt ab.
# Der gemeinsame Lock unten verhindert, dass ein eigenständiges Backup mit
# Update, Passwortwechsel oder Reset überlappt. pg_dump selbst liefert zudem
# einen konsistenten Snapshot.
set -euo pipefail
umask 077
# Cron-PATH ist minimal (/usr/bin:/bin): explizit setzen (P-017), damit
# docker/gzip/date/flock/logger/df/stat gefunden werden.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
BACKUP_DIR="/opt/coder/backups"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
mkdir -p "${BACKUP_DIR}"

# Gemeinsamer Wartungs-Lock: ein eigenständiges Backup wartet ebenfalls auf
# Update/Passwortwechsel/Reset. Von diesen Skripten geerbtes FD 8 hält den
# Lock bereits; das Marker-Env verhindert einen Selbst-Deadlock beim Backup-
# Aufruf aus einem Wartungsskript. Der separate Backup-Lock schützt weiterhin
# zwei Backup-Aufrufe.
if [ "${CODER_MAINTENANCE_LOCK_HELD:-}" != "1" ]; then
  (umask 077; : >> /opt/coder/.maintenance.lock)
  chown root:root /opt/coder/.maintenance.lock
  chmod 600 /opt/coder/.maintenance.lock
  exec 8>>/opt/coder/.maintenance.lock
  if ! flock -w 300 8; then
    echo "backup.sh: gemeinsamer Wartungs-Lock nach 300 s nicht erhalten; kein Backup angelegt." >&2
    logger -t coder-backup "Wartungs-Lock-Timeout nach 300 s, kein Backup angelegt" || true
    exit 75
  fi
  export CODER_MAINTENANCE_LOCK_HELD=1
fi

# Zusätzlicher Selbst-Lock (.backup.lock, B-001): schützt Cron-, Setup-
# Pre-Backup- und manuelle Läufe gemeinsam. Der Wartungs-Lock oben verhindert
# zusätzlich Kollisionen mit verändernden Abläufen. Die Cron-Zeile enthält bewusst
# KEIN äußeres flock auf derselben Datei (würde den inneren Lauf bis zum
# Timeout sperren -> Exit 75 ohne Backup).
exec 9>"${BACKUP_DIR}/.backup.lock"
if ! flock -w 300 9; then
  LATEST_SKIP=$(ls -t "${BACKUP_DIR}"/coder_*.sql.gz 2>/dev/null | head -n1 || true)
  if [ -n "${LATEST_SKIP:-}" ]; then
    echo "backup.sh: Lock nach 300 s nicht erhalten, kein Backup angelegt (Lock ${BACKUP_DIR}/.backup.lock). Letztes gültiges Backup: ${LATEST_SKIP} ($(stat -c %y "${LATEST_SKIP}" 2>/dev/null || echo unbekannt))." >&2
    logger -t coder-backup "Lock-Timeout nach 300 s, kein neues Backup; letztes gültiges Backup: ${LATEST_SKIP}" || true
  else
    echo "backup.sh: Lock nach 300 s nicht erhalten, kein Backup angelegt (Lock ${BACKUP_DIR}/.backup.lock). KEIN gültiges Backup vorhanden!" >&2
    logger -t coder-backup "Lock-Timeout nach 300 s, KEIN gültiges Backup vorhanden" || true
  fi
  # 75 = EX_TEMPFAIL: kein Erfolg, kein Datenverlust – aber die Aufrufer
  # (Setup, reset-coder.sh) sollen EXPLIZIT abbrechen.
  exit 75
fi

# B-016: stale Orphan-Sweep (nur eigenes Muster, älter als 24 h). SIGKILL/Reboot
# umgehen trap EXIT – ohne Sweep blieben .tmp.*-Orphans (600/root) ewig liegen.
find "${BACKUP_DIR}" -maxdepth 1 -name 'coder_*.sql.gz.tmp.*' -mmin +1440 -delete 2>/dev/null || true

# Mindestplatz vor dem Dump (P-007/B-015): klar abbrechen statt partieller Datei.
# 500-MB-Bodenwert ist konservativ, aber UNVERMESSEN (kein Ersatz für
# Platten-Monitoring; retention.size/check.sh erst nach Messung, D-Monitoring).
MIN_FREE_BYTES=524288000
if FREE_BYTES=$(df --output=avail -B1 "${BACKUP_DIR}" 2>/dev/null | tail -n1 | tr -d ' '); then
  if [ "${FREE_BYTES}" -lt "${MIN_FREE_BYTES}" ]; then
    echo "backup.sh: zu wenig freier Platz in ${BACKUP_DIR} (${FREE_BYTES} < ${MIN_FREE_BYTES} Bytes), Abbruch ohne Datei." >&2
    logger -t coder-backup "FEHLGESCHLAGEN: zu wenig Platz (${FREE_BYTES} Bytes frei)" || true
    exit 1
  fi
fi

FINAL="${BACKUP_DIR}/coder_${TIMESTAMP}.sql.gz"
TMP="${FINAL}.tmp.$$"
# Räumt bei Abbruch (inkl. ENOSPC mitten im Stream) auf: nie partielle
# Finaldatei (F-005). Gleiche Partition, daher atomares mv unten.
cleanup() { rm -f "${TMP}"; }
trap cleanup EXIT

if docker exec coder-postgres pg_dump -U coder coder | gzip > "${TMP}"; then
  :
else
  echo "backup.sh: pg_dump-Pipeline fehlgeschlagen, keine Finaldatei angelegt." >&2
  logger -t coder-backup "FEHLGESCHLAGEN: pg_dump-Pipeline" || true
  exit 1
fi
chmod 600 "${TMP}"

# Verifikation (F-005, mit P-013/B-010): gzip-Integrität ist hart (Fail).
# B-010: leeres stdin oder pg_dump-Fehlertext nach stdout ergibt valides gzip
# ohne SQL-Semantik – daher SQL-Header als Fail-Kriterium (kein hartes
# Größenlimit: frische/verkleinerte DB darf nicht scheitern).
if ! gzip -t "${TMP}"; then
  echo "backup.sh: gzip-Integritätstest fehlgeschlagen, keine Finaldatei angelegt." >&2
  logger -t coder-backup "FEHLGESCHLAGEN: gzip -t" || true
  exit 1
fi
# B2-001: Kopf in Variable lesen – direkte Pipe (zcat|head|grep) gäbe unter
# pipefail Exit 141 (SIGPIPE) bei Dumps > ~64 KB und damit falschen Fail.
HEADER="$(zcat "${TMP}" 2>/dev/null | head -c 4000 || true)"
if ! grep -q "PostgreSQL database dump" <<< "${HEADER}"; then
  echo "backup.sh: FEHLGESCHLAGEN: kein SQL-Dump-Header (leer oder Fehlertext), keine Finaldatei angelegt." >&2
  logger -t coder-backup "FEHLGESCHLAGEN: kein SQL-Dump-Header" || true
  exit 1
fi
DUMP_SIZE=$(stat -c %s "${TMP}")
if [ "${DUMP_SIZE}" -lt 512 ]; then
  echo "backup.sh: Warnung: Backup ungewöhnlich klein (${DUMP_SIZE} Bytes) – ggf. leere DB, bitte prüfen." >&2
fi
# B-010: Vorwert-Vergleich als Warnung (kein Fail): halbierte Größe gegenüber
# letztem gültigem Dump deutet auf Teilverlust, legitime Verkleinerung bleibt grün.
PREV_DUMP=$(ls -t "${BACKUP_DIR}"/coder_*.sql.gz 2>/dev/null | head -n1 || true)
if [ -n "${PREV_DUMP:-}" ]; then
  PREV_SIZE=$(stat -c %s "${PREV_DUMP}" 2>/dev/null || echo 0)
  if [ "${PREV_SIZE}" -gt 0 ] && [ "${DUMP_SIZE}" -lt "$((PREV_SIZE / 2))" ]; then
    echo "backup.sh: Warnung: Backup deutlich kleiner als Vorgänger (${DUMP_SIZE} < ${PREV_SIZE}/2 Bytes) – bitte prüfen, kein Fail." >&2
    logger -t coder-backup "Warnung: Dump stark verkleinert (${DUMP_SIZE} vs. ${PREV_SIZE} Bytes)" || true
  fi
fi

mv "${TMP}" "${FINAL}"
# mv hat übernommen, trap muss nichts mehr räumen.
trap - EXIT
chmod 600 "${FINAL}"
logger -t coder-backup "Backup OK: ${FINAL} (${DUMP_SIZE} Bytes)" || true

# C1: Zeitstempel des letzten ERFOLGREICHEN Laufs als Prometheus-Metrik
# (textfile-collector von node-exporter). Erst hier, nach der Finaldatei –
# ein abgebrochener Lauf darf keinen frischen Zeitstempel hinterlassen,
# sonst täuscht die Metrik (und die BackupStale-Alarmregel) Gesundheit vor.
# Atomar: erst eine temporäre Datei mit 644 (umask 077 des Skripts umgehen,
# sonst kann der Container-Einzug der Metrik nicht lesen) per mv umbenennen.
# Fehlschlag darf das Backup nicht zum Fehler machen – Warnung reicht, das
# Verzeichnis legt das Setup mit 0755 an.
TF_DIR="/opt/coder/node-textfile"
if TF_TMP=$(mktemp "${TF_DIR}/.coder_backup.prom.XXXXXX" 2>/dev/null); then
  {
    echo "# HELP coder_backup_last_success_timestamp_seconds Unix-Zeitpunkt (Sekunden) des letzten erfolgreichen coder-Backups."
    echo "# TYPE coder_backup_last_success_timestamp_seconds gauge"
    echo "coder_backup_last_success_timestamp_seconds $(date +%s)"
  } > "${TF_TMP}"
  chmod 644 "${TF_TMP}"
  mv "${TF_TMP}" "${TF_DIR}/coder_backup.prom"
else
  echo "Warnung: Backup erfolgreich, aber Metrik ${TF_DIR}/coder_backup.prom nicht schreibbar (Verzeichnis fehlt/ist nicht 0755)." >&2
  logger -t coder-backup "Warnung: Backup OK, Metrik-Datei konnte nicht angelegt werden" || true
fi

# Rotation nach ALTER mit Mindestbestand (Review 1.7): reine Stückzahl-
# rotation verdrängt bei mehreren Wartungsläufen am selben Tag die täglichen
# Backups – die Historie wird kürzer als 14 Tage. Gelöscht wird nur, was
# älter als 14 Tage ist; dazu nie die 7 neuesten Dateien, damit auch nach
# langen Cron-Lücken (alle Dumps > 14 Tage) nie der Bestand auf Null fällt.
KEEP_MIN=7
RETENTION_SECONDS=1209600
mapfile -t NEWEST < <(ls -t "${BACKUP_DIR}"/coder_*.sql.gz 2>/dev/null || true)
NOWS=$(date +%s)
for IDX in "${!NEWEST[@]}"; do
  if [ "${IDX}" -lt "${KEEP_MIN}" ]; then
    continue
  fi
  # || continue muss AUSSERhalb der $( ) stehen: dort beendet es nur die
  # Subshell, die Schleife liefe mit leerem MT weiter und rm -fete trotzdem.
  MT=$(stat -c %Y "${NEWEST[$IDX]}" 2>/dev/null) || continue
  if [ $((NOWS - MT)) -gt "${RETENTION_SECONDS}" ]; then
    rm -f "${NEWEST[$IDX]}"
  fi
done
