#!/bin/bash
# check-tls.sh: zaehlt Zertifikatsdateien, die in den letzten 7 Tagen
# (wieder)geschrieben wurden, und legt sie als textfile-Metrik ab.
# Zaehlung aus dem caddy_data-Volume statt aus docker logs: ein Container-
# Recreate (Image-Update, Compose-Aenderung) setzt den Logzaehler zurueck,
# die Zertifikatsdateien bleiben. "obtaining certificate" aus dem Log waere
# zudem nur ein Versuch (auch Fehlschlaege/Retries), keine Ausstellung.
# Lesend bis auf die Metrik-Datei. Fehler beim Lesen oder Schreiben liefern
# Exit 1 und aktualisieren den Erfolgszeitpunkt nicht.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Frische Installation ohne ausgestellte Zertifikate: caddy_data hat noch
# kein certificates-Verzeichnis – das ist kein Lesefehler, sondern Stand
# "0 Ausstellungen"; die Metrik und der Erfolgszeitpunkt muessen trotzdem
# gesetzt werden, sonst feuert TlsCheckStale bis zum ersten Zertifikat.
# Container nicht erreichbar oder find-Fehler im vorhandenen Verzeichnis =
# Exit 1, Metrik bleibt unveraendert. Frueher maskierte
# "find 2>/dev/null | wc -l" im Container jeden Fehler und zaehlte still 0.
if ! CERT_DIR_STATE="$(docker exec coder-caddy sh -c \
  'if [ -d /data/caddy/certificates ]; then echo yes; else echo no; fi')"; then
  echo "Fehler: caddy-Container nicht erreichbar; TLS-Metrik bleibt unveraendert." >&2
  logger -t coder-tls "FEHLER: caddy-Container nicht erreichbar" || true
  exit 1
fi
if [ "${CERT_DIR_STATE}" = "yes" ]; then
  if ! FILES="$(docker exec coder-caddy find /data/caddy/certificates -name "*.crt" -mtime -7)"; then
    echo "Fehler: Zertifikatsdateien konnten nicht gezaehlt werden (find meldete Fehler); TLS-Metrik bleibt unveraendert." >&2
    logger -t coder-tls "FEHLER: Zertifikatsdateien konnten nicht gezaehlt werden" || true
    exit 1
  fi
  COUNT="$(printf '%s\n' "${FILES}" | grep -c . || true)"
else
  COUNT=0
fi
echo "TLS-Ausstellungen letzte 7 Tage (im caddy_data geaenderte *.crt): ${COUNT}"
# Atomar schreiben: der textfile-Collector ignoriert Dateien, die mit "." an-
# fangen, ein abgebrochener Lauf erzeugt also keine Metrik, sondern Muell.
if [ -d /opt/coder/node-textfile ]; then
  if TMP=$(mktemp /opt/coder/node-textfile/.coder_tls.prom.XXXXXX 2>/dev/null); then
    {
      echo "# HELP coder_tls_issuances_7d Let's-Encrypt-Ausstellungen der letzten 7 Tage (geaenderte *.crt im caddy_data)."
      echo "# TYPE coder_tls_issuances_7d gauge"
      echo "coder_tls_issuances_7d ${COUNT}"
      echo "# HELP coder_tls_check_last_success_timestamp_seconds Unix-Zeitpunkt des letzten erfolgreichen TLS-Checks."
      echo "# TYPE coder_tls_check_last_success_timestamp_seconds gauge"
      echo "coder_tls_check_last_success_timestamp_seconds $(date +%s)"
    } > "${TMP}"
    chmod 644 "${TMP}"
    mv "${TMP}" /opt/coder/node-textfile/coder_tls.prom
    logger -t coder-tls "Ausstellungen/7d: ${COUNT}" || true
  else
    echo "Fehler: temporaere TLS-Metrikdatei konnte nicht erstellt werden." >&2
    exit 1
  fi
else
  echo "Fehler: /opt/coder/node-textfile fehlt; TLS-Check-Metrik kann nicht geschrieben werden." >&2
  exit 1
fi
