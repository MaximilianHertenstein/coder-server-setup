#!/bin/bash
# boot-check.sh (B-011): lesendes Boot-Gate, kein Eingriff.
# Aufruf: per @reboot-Cron oder manuell. Exit 1 bei rot (sichtbar im Cron-Log),
# ändert aber nichts am Stack – nur Diagnose für den Morgen nach dem Reboot.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOG="/var/log/coder-boot.log"
OUT=$(mktemp)
{
echo "=== boot-check $(date -Is) ==="
OK=true
PG_HEALTH="none"
# Postgres meldet "healthy" erst nach dem ersten Health-Probe (interval 5 s);
# @reboot startet boot-check.sh Sekunden zuvor und läse ohne Wartezeit
# "starting" – jedes Boot wäre ROT, obwohl der Stack gesund ist (Messung
# 2026-09-28 auf dem Test-Host: T+0 s "starting", T+4 s "healthy"). Maximal
# 120 s warten, danach ist das ROT echt (laufende DB wäre längst healthy).
for _ in $(seq 1 24); do
  PG_HEALTH="$(docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null || echo none)"
  if [ "${PG_HEALTH}" = "healthy" ]; then break; fi
  sleep 5
done
if [ "${PG_HEALTH}" != "healthy" ]; then
  echo "ROT: Postgres nach Boot '${PG_HEALTH}' (120 s gewartet)"
  OK=false
else
  echo "OK: Postgres healthy nach Boot"
fi
# A4: Container-Status erst JETZT prüfen. @reboot läuft parallel zu dockerd,
# die Container starten erst kurz danach – der frühe "läuft/läuft nicht"-Lauf
# oben (vor der Wartezeit) hätte jedes Boot fälschlich ROT gemeldet. Auch hier
# max. 120 s warten, bis alle sechs laufen, danach ist das ROT echt.
for _ in $(seq 1 24); do
  _all_running=true
  for c in coder-postgres coder coder-caddy coder-prometheus coder-node-exporter coder-grafana; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)" != "true" ]; then
      _all_running=false
    fi
  done
  if [ "${_all_running}" = "true" ]; then break; fi
  sleep 5
done
for c in coder-postgres coder coder-caddy coder-prometheus coder-node-exporter coder-grafana; do
  if [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)" != "true" ]; then
    echo "ROT: Container ${c} läuft nicht nach Boot"
    OK=false
  else
    echo "OK: ${c} läuft"
  fi
done
# A2: Domain aus der vom Setup abgelegten Datei. Der frühere awk-Ansatz griff
# in der Caddyfile auf die @askOK-Matcherzeile und lieferte leer – der
# TLS-Smoke wurde still übersprungen.
DOMAIN=$(tr -d '[:space:]' < /opt/coder/domain 2>/dev/null || true)
if [ -n "${DOMAIN:-}" ]; then
  CODE="000"
  for _ in $(seq 1 30); do
    if CODE=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz" 2>/dev/null) && [ "${CODE}" = "200" ]; then
      break
    fi
    sleep 10
  done
  if [ "${CODE}" != "200" ]; then
    echo "ROT: /healthz via Caddy antwortet ${CODE} statt 200 (TLS-Smoke bis zu 10 Minuten)"
    OK=false
  else
    echo "OK: /healthz via Caddy 200"
  fi
else
  echo "WARN: /opt/coder/domain fehlt oder ist leer – TLS-Smoke übersprungen"
fi
if [ "${OK}" = "true" ]; then echo "BOOT-GATE GRÜN"; else echo "BOOT-GATE ROT – prüfen mit: docker logs coder / docker logs coder-postgres"; fi
} > "${OUT}" 2>&1
cat "${OUT}" >> "${LOG}" 2>/dev/null || true
logger -t coder-boot < "${OUT}" || true
# Auswertung des LAUFS (nicht des kumulativen Logs – alte GRÜN-Zeilen sähen
# sonst einen aktuellen ROT-Lauf grün).
if grep -q "BOOT-GATE GRÜN" "${OUT}"; then
  rm -f "${OUT}"
  exit 0
else
  rm -f "${OUT}"
  exit 1
fi
