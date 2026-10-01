#!/bin/bash
# check-tls.sh (B-005/B4): zählt LE-Ausstellungen der letzten 7 Tage im
# Caddy-Log, legt sie als textfile-Metrik ab und meldet sie an syslog.
# Lesend bis auf die Metrik-Datei. Fehler beim Lesen oder Schreiben liefern
# Exit 1 und aktualisieren den Erfolgszeitpunkt nicht.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if ! COUNT=$(docker logs --since 168h coder-caddy 2>&1 | awk '/obtaining certificate/ {n++} END {print n+0}'); then
  echo "Fehler: Caddy-Logs konnten nicht gelesen werden; TLS-Metrik bleibt unveraendert." >&2
  logger -t coder-tls "FEHLER: Caddy-Logs konnten nicht gelesen werden" || true
  exit 1
fi
# Der 7-Tage-Scan sieht nur, was noch im Logpuffer ist (10 MB x 3
# json-file-Dateien pro Container). Fenstergroesse und Rotation-Verlust werden
# deshalb gemessen und als Metrik abgelegt: ohne das waere die Zahl im
# Ernstfall (Budget-DoS erzeugt Traffic und Ausstellungen gleichzeitig)
# eine stille Untergrenze.
NOW=$(date +%s)
OLDEST=$(docker logs --timestamps coder-caddy 2>/dev/null | head -n1 | cut -d' ' -f1 || true)
OLDEST_TS=""
if [ -n "${OLDEST}" ]; then
  OLDEST_TS=$(date -d "${OLDEST}" +%s 2>/dev/null || true)
fi
WINDOW=0
if [ -n "${OLDEST_TS}" ]; then
  WINDOW=$((NOW - OLDEST_TS))
fi
if [ "${WINDOW}" -gt 604800 ]; then
  WINDOW=604800
fi
START_TS=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' coder-caddy 2>/dev/null || true)" +%s 2>/dev/null || true)
TRUNCATED=0
if [ "${WINDOW}" -lt 604800 ]; then
  if [ -n "${START_TS}" ] && [ $((NOW - START_TS)) -ge 604800 ]; then
    TRUNCATED=1
    echo "WARNUNG: Caddy-Log reicht nur $((WINDOW / 3600)) Std. zurueck, obwohl der Container $(( (NOW - START_TS) / 86400 )) Tage laeuft – Logrotation (10 MB x 3) hat Eintraege der letzten 7 Tage verworfen; die Zahl ist eine Untergrenze."
  else
    echo "HINWEIS: Caddy-Logfenster nur $((WINDOW / 3600)) Std. – die Zaehlung gilt erst ab Logbeginn (frischer Container)."
  fi
fi
echo "TLS-Ausstellungen letzte 7 Tage (Caddy-Log, 'obtaining certificate'): ${COUNT} (Logfenster: $((WINDOW / 3600)) Std.)"
# Atomar schreiben: der textfile-Collector ignoriert Dateien, die mit "."/an-
# fangen, ein abgebrochener Lauf erzeugt also keine Metrik, sondern Müll.
if [ -d /opt/coder/node-textfile ]; then
  if TMP=$(mktemp /opt/coder/node-textfile/.coder_tls.prom.XXXXXX 2>/dev/null); then
    {
      echo "# HELP coder_tls_issuances_7d Let's-Encrypt-Ausstellungen der letzten 7 Tage (Caddy-Log)."
      echo "# TYPE coder_tls_issuances_7d gauge"
      echo "coder_tls_issuances_7d ${COUNT}"
      echo "# HELP coder_tls_log_window_seconds Sekunden Caddy-Loghistorie im Puffer (604800 = volle 7 Tage)."
      echo "# TYPE coder_tls_log_window_seconds gauge"
      echo "coder_tls_log_window_seconds ${WINDOW}"
      echo "# HELP coder_tls_log_truncated 1, wenn Logrotation Eintraege der letzten 7 Tage verworfen hat (Ausstellungszaehler ist dann nur eine Untergrenze)."
      echo "# TYPE coder_tls_log_truncated gauge"
      echo "coder_tls_log_truncated ${TRUNCATED}"
      echo "# HELP coder_tls_check_last_success_timestamp_seconds Unix-Zeitpunkt des letzten erfolgreichen TLS-Checks."
      echo "# TYPE coder_tls_check_last_success_timestamp_seconds gauge"
      echo "coder_tls_check_last_success_timestamp_seconds $(date +%s)"
    } > "${TMP}"
    chmod 644 "${TMP}"
    mv "${TMP}" /opt/coder/node-textfile/coder_tls.prom
    logger -t coder-tls "Ausstellungen/7d: ${COUNT} (Logfenster ${WINDOW}s, trunc=${TRUNCATED})" || true
  else
    echo "Fehler: temporaere TLS-Metrikdatei konnte nicht erstellt werden." >&2
    exit 1
  fi
else
  echo "Fehler: /opt/coder/node-textfile fehlt; TLS-Check-Metrik kann nicht geschrieben werden." >&2
  exit 1
fi
