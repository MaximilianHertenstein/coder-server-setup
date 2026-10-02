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
if ! COUNT=$(docker exec coder-caddy sh -c 'find /data/caddy/certificates -name "*.crt" -mtime -7 | wc -l'); then
  echo "Fehler: Zertifikatsdateien konnten nicht gezaehlt werden; TLS-Metrik bleibt unveraendert." >&2
  logger -t coder-tls "FEHLER: Zertifikatsdateien konnten nicht gezaehlt werden" || true
  exit 1
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
