#!/bin/bash
# Manuelles Update: Images ziehen, Stack neu erstellen. Kein Auto-Prune (B-003).
# B-009: Health-Gate nach "up -d" (Container Running + Postgres healthy +
# /healthz-200 via Caddy-TLS-Smoke, Timeout 60 s wegen On-Demand-Erstverzögerung
# 5-30 s) + ehrlicher Rollback-Kommentar (Garantie nur für exakt Gepinnte).
# Keine app/db-Aufspaltung (D-Update-Split, siehe Report).
# Aufrufkontext: dieses Skript und setup-coder.sh laufen beide als root
# (sudo-Aufruf bzw. Cron) und nutzen deshalb direkt "docker".
set -euo pipefail
cd /opt/coder

# Wartungs-Lock serialisiert Updates mit Backup, Passwortrotation und Reset.
# FD 8 wird an backup.sh vererbt; das Marker-Env verhindert dort Deadlock.
(umask 077; : >> /opt/coder/.maintenance.lock)
chown root:root /opt/coder/.maintenance.lock
chmod 600 /opt/coder/.maintenance.lock
exec 8>>/opt/coder/.maintenance.lock
if ! flock -w 300 8; then
  echo "update.sh: Wartungs-Lock nach 300 s nicht erhalten; Update abgebrochen." >&2
  exit 75
fi
export CODER_MAINTENANCE_LOCK_HELD=1

# Vor jedem Update sicherheitshalber ein Backup ziehen (seit F-005 verifiziert).
# A3: schlägt das fehl oder läuft in den Lock-Timeout (Exit 75), bricht
# "set -e" hier ab – KEIN Update ohne frisches Backup.
echo "Ziehe Pre-Update-Backup..."
/opt/coder/backup.sh

# B-013: Pull-Retry max. 3 (Registry-/Schulnetz-Schluckauf), danach hart mit
# Ursache statt set -e-Rohfehler. Kein Retry um LE (Budget, hier nicht betroffen).
_pull_ok=false
for _r in 1 2 3; do
  if docker compose pull; then _pull_ok=true; break; fi
  echo "pull-Versuch ${_r}/3 fehlgeschlagen, warte 10 s ..." >&2
  sleep 10
done
if [ "${_pull_ok}" != "true" ]; then
  echo "FEHLER: compose pull nach 3 Versuchen – Registry/Netz prüfen, dann erneut." >&2
  exit 1
fi
docker compose up -d --remove-orphans

# Health-Gate (F-012): Container müssen laufen, Postgres gesund sein –
# sonst Exit != 0 mit Hinweis statt stillem "Erfolg".
echo "Prüfe Stack-Gesundheit nach Update..."
GATE_OK=true
for c in coder-postgres coder coder-caddy coder-prometheus coder-node-exporter coder-grafana; do
  if [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)" != "true" ]; then
    echo "FEHLER: Container ${c} läuft nach Update NICHT – prüfen mit: docker logs ${c}" >&2
    GATE_OK=false
  fi
done
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null)" = "healthy" ] && break
  sleep 2
done
if [ "$(docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null)" != "healthy" ]; then
  echo "FEHLER: Postgres nach Update nicht healthy – prüfen mit: docker logs coder-postgres" >&2
  GATE_OK=false
fi
# B-009: /healthz-200 via Caddy (TLS-Smoke): prüft Caddy-TLS + Reverse-Proxy +
# Coder-App in einem Schritt. Apex aus der vom Setup abgelegten Datei
# /opt/coder/domain (A2: der awk-Ansatz aus der Caddyfile griff auf die
# @askOK-Matcherzeile und lieferte leer -> Smoke wurde still übersprungen),
# SNI-korrekte lokale Probe per --resolve (SNI + Host = Domain, Verbindung
# lokal). Timeout 60 s: deckt On-Demand-Erstverzögerung (5-30 s) ab, ohne
# legitime Updates rot zu melden.
GATE_DOMAIN=$(tr -d '[:space:]' < /opt/coder/domain 2>/dev/null || true)
if [ -n "${GATE_DOMAIN:-}" ]; then
  if HEALTH_CODE=$(curl -sS --max-time 60 -o /dev/null -w "%{http_code}" --resolve "${GATE_DOMAIN}:443:127.0.0.1" "https://${GATE_DOMAIN}/healthz" 2>/dev/null); then
    :
  else
    HEALTH_CODE="000"
  fi
  if [ "${HEALTH_CODE}" != "200" ]; then
    echo "FEHLER: Caddy-TLS-Smoke rot – https://${GATE_DOMAIN}/healthz via 127.0.0.1 antwortet ${HEALTH_CODE} statt 200 (prüfen mit: docker logs coder-caddy; docker logs coder)" >&2
    GATE_OK=false
  else
    echo "Caddy-TLS-Smoke grün: /healthz via Caddy antwortet 200."
  fi
else
  echo "Warnung: /opt/coder/domain fehlt oder ist leer – TLS-Smoke übersprungen (kein Fail)." >&2
fi
if [ "${GATE_OK}" != "true" ]; then
  echo "FEHLER: Update-Gate rot – Stack prüfen, ggf. Rollback (siehe Kommentar unten)." >&2
  exit 1
fi
echo "Update-Gate grün: alle Container laufen, Postgres healthy, /healthz via Caddy 200."

# Kein Auto-Prune nach Update (B-003): "docker image prune --filter until=24h"
# filtert nach Image-Erstellungsdatum, nicht nach Dangling-Zeitpunkt. Bewegliche
# Tags (caddy:2.10, postgres:18-alpine) wären nach "pull" sofort dangling, aber
# Wochen alt – und damit trotz "behält gestern" sofort gelöscht. Alte Images
# sind der billigste Offline-Rollback; manuell und bewusst aufräumen
# ("docker image prune"), nie automatisch nach Update.

# Rollback-Hinweis (F-012/B-003, korrigiert): schnelles Zurück ("alte Version in
# setup-coder.sh setzen + Setup erneut") funktioniert OHNE erneuten Pull nur
# für exakt gepinnte Images (Coder/Prometheus/Grafana – deren Tags ändern sich
# nie von selbst). Für Caddy (Minor-Pin 2.10) und Postgres (18-alpine) holt
# "pull" ggf. ein neueres Image. Alte Images bleiben seit B-003 bis zu manuellem
# "docker image prune" erhalten (kein Auto-Prune nach Update) – bei Platten-
# engpass bewusst aufräumen. Bei Coder-Major-Updates mit Schema-Migrationen
# kann ein Downgrade irreversibel sein – Major-Updates nur mit verifiziertem
# Dump (siehe RESTORE.md) und einzeln fahren, nie zusammen mit DB-Update.
#
# Hinweis: "docker compose pull" holt bei exakten Pins NUR das, was in der
# docker-compose.yml steht – CODER_VERSION, PROMETHEUS_VERSION,
# GRAFANA_VERSION, CADDY_VERSION und NODE_EXPORTER_VERSION stehen aber in
# setup-coder.sh. Wer also eine Version ändern will, ändert sie dort und
# führt das Setup-Skript erneut aus; "update.sh" allein ändert keine dieser
# Versionen (es aktualisiert nur, was schon in der Compose-Datei steht) und
# zieht bei Minor-Pins wie caddy:2.10 zusätzlich die neueste Patch-Version.
