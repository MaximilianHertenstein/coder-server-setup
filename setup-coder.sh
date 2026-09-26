#!/usr/bin/env bash
# ============================================================================
# Coder-Server Setup – coder.ghse-unterricht.de
# Zielsystem: Debian 13 (trixie)
# ============================================================================
#
# Voraussetzung für vollständig funktionierendes HTTPS:
#   - DNS: coder.ghse-unterricht.de UND *.coder.ghse-unterricht.de (Wildcard,
#     für Workspace-Apps/Port-Forwarding) müssen per A-Record (ggf. AAAA) auf
#     die öffentliche IP des Servers zeigen.
#   - Die Schulnetz-Infrastruktur muss Port 80 und 443 zum Server
#     (intern 10.16.103.13) durchreichen (Portweiterleitung/Reverse Proxy).
#
# Wildcard-Subdomains bekommen ihr Zertifikat erst bei Bedarf (Caddy
# On-Demand-TLS, offiziell von Coder empfohlen ohne eigenen DNS-Provider-API-
# Zugang) - beim allerersten Aufruf einer neuen Workspace-App-URL dauert das
# 5-30 Sekunden länger. Let's Encrypt begrenzt neue Zertifikate auf 50 pro
# Woche pro registrierter Domain - für eine kleine Schulklasse unkritisch,
# aber bei sehr vielen unterschiedlichen Workspace-URLs pro Woche im Hinterkopf
# behalten.
#
# Falls das beim Ausführen noch nicht steht: Der Stack startet trotzdem.
# Caddy versucht im Hintergrund weiter, ein Zertifikat zu bekommen, und der
# Abschlusscheck (Schritt 10) meldet das als WARNUNG statt als Fehler. Das
# Skript ist mehrfach ausführbar (idempotent) – einfach erneut laufen lassen,
# sobald DNS/Portweiterleitung stehen.
#
# SSH (Port 22) ist absichtlich für Zugriff von überall offen (Rate-Limiting
# per ufw + fail2ban als Schutz), damit du auch von zuhause ran kannst. Die
# Schulnetz-Infrastruktur muss dafür Port 22 zusätzlich zu 80/443 weiterleiten.
# WICHTIG: Passwort-Login ist aktuell noch aktiv, weil noch kein SSH-Key
# eingerichtet ist. Sobald ein Key funktioniert, unbedingt Bescheid geben,
# damit Passwort-Login deaktiviert wird (sonst bleibt SSH per Brute-Force
# angreifbar, auch mit fail2ban).
#
# Grafana bleibt bewusst nur über 127.0.0.1 (SSH-Tunnel) erreichbar, nicht
# über die Domain – kein öffentlicher Zugriff auf das Monitoring nötig.
#
# Coder-Updates laufen NICHT automatisch. update.sh liegt bereit, wird aber
# manuell mit "sudo /opt/coder/update.sh" ausgeführt.
#
# CODER_VERSION: Das Image-Tag auf ghcr.io braucht das "v"-Präfix (v2.36.6,
# nicht 2.36.6). Für eine neuere Version:
# https://github.com/coder/coder/releases
#
# Versionierung: CODER_VERSION, PROMETHEUS_VERSION und GRAFANA_VERSION sind
# exakte Versionen (ändern sich nie von selbst). CADDY_VERSION ist bewusst nur
# auf die Minor-Version gepinnt (z.B. "2.10"), nicht exakt - Caddy terminiert
# TLS, Patch-Updates (Sicherheitsfixes) sollen dort über "docker compose pull"
# automatisch ankommen. postgres:15-alpine folgt demselben Prinzip. Für einen
# wirklich bit-genauen, reproduzierbaren Pin müsste man ein Image-Digest
# (sha256:...) statt eines Tags verwenden. Ab und zu manuell auf neue Major-
# Versionen prüfen.
#
# Ausführen als Benutzer mit sudo-Rechten:
#   chmod +x setup-coder.sh
#   ./setup-coder.sh
#
# Vom Skript unter /opt/coder bereitgestellte Wartungsskripte (alle mit
# "sudo /opt/coder/<name>.sh" manuell aufzurufen, keines läuft automatisch
# außer backup.sh per Cronjob):
#   backup.sh           Postgres-Backup (täglich per Cron, 01:00 Uhr)
#   update.sh           Coder/Caddy/Postgres/Grafana/Prometheus aktualisieren
#   reset-passwords.sh  Neue Postgres-/Grafana-Passwörter setzen
#   reset-coder.sh      Coder-Reset (Datenbank, .env - Zertifikate bleiben)
# ============================================================================

set -euo pipefail

# Alle Werte lassen sich beim Aufruf per Umgebungsvariable überschreiben,
# ohne diese Datei zu ändern, z.B.:
#   DOMAIN_CODER=andere-domain.de ./setup-coder.sh
# ":=" setzt den Default nur, wenn die Variable noch nicht (von außen) gesetzt
# wurde.
: "${DOMAIN_CODER:=coder.ghse-unterricht.de}"
: "${ACME_EMAIL:=hert@ghse.de}"
: "${CODER_VERSION:=v2.36.6}"             # https://github.com/coder/coder/releases prüfen
: "${CADDY_VERSION:=2.10}"                # https://hub.docker.com/_/caddy/tags
: "${PROMETHEUS_VERSION:=v3.14.0}"        # https://github.com/prometheus/prometheus/releases
: "${GRAFANA_VERSION:=12.4.5}"            # https://github.com/grafana/grafana/releases
: "${NODE_EXPORTER_VERSION:=v1.12.1}"     # https://github.com/prometheus/node_exporter/releases

# ---- Hilfsfunktionen für die Zusammenfassung ab Schritt 4 -----------------
declare -a SUMMARY=()
ERROR_COUNT=0
ok()   { echo "  [OK]     $1"; SUMMARY+=("[OK]     $1"); }
warn() { echo "  [WARNUNG] $1"; SUMMARY+=("[WARNUNG] $1"); }
fail() { echo "  [FEHLER] $1"; SUMMARY+=("[FEHLER] $1"); ERROR_COUNT=$((ERROR_COUNT + 1)); }

check_container_running() {
  local name="$1"
  local label="$2"
  if [ "$(sudo docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || echo false)" = "true" ]; then
    ok "${label} läuft"
  else
    fail "${label} läuft NICHT – prüfen mit: sudo docker logs ${name}"
  fi
}

echo "############################################################"
echo "# [1/10] Docker Engine installieren"
echo "############################################################"
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg openssl
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# K1/F-018 (billige Hälfte, kein Digest-Pin): Fingerprint des Docker-GPG-Keys
# gegen den öffentlich dokumentierten Wert prüfen
# (https://docs.docker.com/engine/install/debian/).
# Bei Fehlschlag: Fingerprint dort neu abgleichen (Rotation), nicht einfach
# übernehmen.
DOCKER_FPR=$(sudo gpg --show-keys --with-colons /etc/apt/keyrings/docker.gpg 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
if [ "${DOCKER_FPR}" != "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" ]; then
  echo "Fehler: Docker-GPG-Fingerprint unerwartet ('${DOCKER_FPR:-leer}'). Mögliche Rotation – Fingerprint unter https://docs.docker.com/engine/install/debian/ abgleichen, dann Setup erneut laufen lassen." >&2
  exit 1
fi

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# GID der docker-Gruppe merken – wird gleich für den Docker-Socket-Zugriff
# des Coder-Containers gebraucht (offizielles Coder-Docker-Setup verlangt das).
DOCKER_GID=$(getent group docker | cut -d: -f3)

# Optional: eigenen Benutzer der docker-Gruppe hinzufügen, damit du Docker
# ohne sudo bedienen kannst (danach einmal neu einloggen).
# sudo usermod -aG docker "$USER"

echo "############################################################"
echo "# [2/10] Verzeichnis und Konfigurationsdateien anlegen"
echo "############################################################"
sudo mkdir -p /opt/coder/backups
sudo chmod 700 /opt/coder/backups
cd /opt/coder

# Geheimnisse nur beim ersten Lauf erzeugen, damit ein erneutes Ausführen
# des Skripts nicht die bestehende Datenbank-Anmeldung zerstört.
# F-006 (mit P-010/P-011): atomar schreiben ohne 644-Fenster, vorhandene
# .env auf Vollständigkeit prüfen. Eine unvollständige .env wird NIEMALS
# still neu gewürfelt (das würde die DB-Anmeldung zerstören) – stattdessen
# Abbruch mit Reparaturanleitung. P-010: "umask 077" in dieser Shell wirkt
# nicht durch "sudo tee" hindurch (tee läuft als root mit root-umask),
# daher "sudo install -m 600" vor dem Schreiben.
if ! [[ "${DOCKER_GID:-}" =~ ^[0-9]+$ ]]; then
  echo "Fehler: docker-GID konnte nicht ermittelt werden (getent group docker lieferte '${DOCKER_GID:-leer}'). .env wird nicht angefasst." >&2
  exit 1
fi
if [ ! -f /opt/coder/.env ]; then
  # hex statt base64: garantiert nur 0-9a-f, kann also nie ein "/", "+" oder
  # "=" enthalten, das in der Postgres-Connection-URL (postgres://user:PASS@host)
  # die URL zerlegen bzw. falsch interpretiert werden würde.
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)

  ENV_TMP=$(sudo mktemp /opt/coder/.env.tmp.XXXXXX)
  # Wird bei Abbruch (inkl. Reboot/SSH-Abbruch) weggeräumt, damit kein
  # halb geschriebenes Temp-File liegen bleibt.
  trap 'sudo rm -f "$ENV_TMP"' EXIT
  # 600 VOR dem Schreiben festlegen: tee kürzt nur, erzeugt nicht neu,
  # der Modus bleibt also 600 – kein 644-Fenster (P-010).
  sudo install -m 600 /dev/null "$ENV_TMP"
  sudo chown root:root "$ENV_TMP"
  sudo tee "$ENV_TMP" > /dev/null <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
DOCKER_GID=${DOCKER_GID}
EOF
  sudo chown root:root "$ENV_TMP"
  sudo chmod 600 "$ENV_TMP"
  sudo mv "$ENV_TMP" /opt/coder/.env
  # mv hat das Temp-File übernommen, trap muss nichts mehr räumen.
  trap - EXIT

  echo "------------------------------------------------------------"
  echo "Neu generierte Zugangsdaten (jetzt sicher notieren!):"
  echo "  Postgres-Passwort:      ${POSTGRES_PASSWORD}"
  echo "  Grafana-Admin-Passwort: ${GRAFANA_ADMIN_PASSWORD}"
  echo "  (stehen auch in /opt/coder/.env, nur für root lesbar)"
  echo "------------------------------------------------------------"
elif sudo grep -qE '^POSTGRES_PASSWORD=[^[:space:]]+' /opt/coder/.env \
  && sudo grep -qE '^GRAFANA_ADMIN_PASSWORD=[^[:space:]]+' /opt/coder/.env \
  && sudo grep -qE '^DOCKER_GID=[0-9]+$' /opt/coder/.env; then
  echo "/opt/coder/.env existiert bereits und ist vollständig – wird nicht überschrieben."
else
  echo "Fehler: /opt/coder/.env existiert, ist aber unvollständig (mindestens ein Schlüssel fehlt/leer)." >&2
  echo "Abbruch ohne Änderung – Passwörter werden NICHT neu gewürfelt (P-011: neu würfeln würde die Datenbank-Anmeldung zerstören)." >&2
  echo "Reparatur: fehlende Schlüssel in /opt/coder/.env ergänzen (vorhandene Werte behalten) oder bei Totalverlust Restore nach Runbook; danach Setup erneut laufen lassen." >&2
  exit 1
fi

# F-007 (mit P-012): DOCKER_GID bei jedem Lauf auffrischen. Nur die GID wird
# getauscht, Passwörter bleiben unangetastet. P-012: kein "sed -i" (nicht
# atomar), Guard gegen leere/nicht-numerische GID (oben bereits geprüft),
# Recreate nur bei tatsächlichem Diff und nur wenn der Coder-Container schon
# existiert – sonst erledigt Schritt 3 das Erstellen mit der neuen GID.
OLD_DOCKER_GID=$(sudo grep '^DOCKER_GID=' /opt/coder/.env | cut -d= -f2-)
if [ "${OLD_DOCKER_GID}" != "${DOCKER_GID}" ]; then
  echo "docker-GID hat sich geändert (${OLD_DOCKER_GID} -> ${DOCKER_GID}), aktualisiere /opt/coder/.env ..."
  ENV_TMP_GID=$(sudo mktemp /opt/coder/.env.tmp.XXXXXX)
  trap 'sudo rm -f "$ENV_TMP_GID"' EXIT
  sudo install -m 600 /dev/null "$ENV_TMP_GID"
  sudo chown root:root "$ENV_TMP_GID"
  sudo grep -v '^DOCKER_GID=' /opt/coder/.env | sudo tee "$ENV_TMP_GID" > /dev/null
  echo "DOCKER_GID=${DOCKER_GID}" | sudo tee -a "$ENV_TMP_GID" > /dev/null
  sudo chown root:root "$ENV_TMP_GID"
  sudo chmod 600 "$ENV_TMP_GID"
  sudo mv "$ENV_TMP_GID" /opt/coder/.env
  trap - EXIT
  if [ "$(sudo docker inspect -f '{{.State.Running}}' coder 2>/dev/null || echo false)" = "true" ]; then
    echo "Erstelle Coder-Container mit neuer GID neu ..."
    sudo docker compose up -d --no-deps coder
  else
    echo "Coder-Container läuft noch nicht – Schritt 3 erstellt ihn mit der neuen GID."
  fi
fi

# docker-compose.yml
# WICHTIG: \${...} bleibt hier absichtlich für Docker Compose stehen (wird aus
# /opt/coder/.env aufgelöst); ${DOMAIN_CODER} etc. werden dagegen jetzt von
# der Shell eingesetzt.
# P-007: JSON-File-Logging ohne Limit wächst auf der Root-Partition unbegrenzt
# (Plattenkiller Nr. 1). 10m x 3 pro Container als konservativer Standard.
sudo tee /opt/coder/docker-compose.yml > /dev/null <<EOF
x-logging: &coder-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  postgres:
    image: postgres:15-alpine
    container_name: coder-postgres
    restart: unless-stopped
    logging: *coder-logging
    environment:
      POSTGRES_DB: coder
      POSTGRES_USER: coder
      POSTGRES_PASSWORD: "\${POSTGRES_PASSWORD}"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coder -d coder"]
      interval: 5s
      timeout: 5s
      retries: 5

  coder:
    image: ghcr.io/coder/coder:${CODER_VERSION}
    container_name: coder
    restart: unless-stopped
    logging: *coder-logging
    depends_on:
      postgres:
        condition: service_healthy
    # Gibt dem Coder-Container Schreibrechte auf den gemounteten Docker-Socket
    # des Hosts (offizielles Setup, siehe coder.com/docs/install/docker).
    group_add:
      - "\${DOCKER_GID}"
    environment:
      - CODER_PG_CONNECTION_URL=postgres://coder:\${POSTGRES_PASSWORD}@postgres:5432/coder?sslmode=disable
      - CODER_HTTP_ADDRESS=0.0.0.0:3000
      - CODER_ACCESS_URL=https://${DOMAIN_CODER}
      - CODER_WILDCARD_ACCESS_URL=*.${DOMAIN_CODER}
      - CODER_PROMETHEUS_ENABLE=true
      - CODER_PROMETHEUS_COLLECT_AGENT_STATS=true
      - CODER_PROMETHEUS_ADDRESS=0.0.0.0:2112
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

  caddy:
    image: caddy:${CADDY_VERSION}
    container_name: coder-caddy
    restart: unless-stopped
    logging: *coder-logging
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"  # HTTP/3 (QUIC) - Caddy nutzt das automatisch, wenn der Port da ist
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - coder

  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: coder-prometheus
    restart: unless-stopped
    logging: *coder-logging
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      # Explizit statt sich auf den (aktuell gleichen) Standardwert zu
      # verlassen: begrenzt, wie weit die Prometheus-Datenbank auf der
      # kleinen Schul-VM anwachsen kann.
      - --storage.tsdb.retention.time=15d
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    # Nur lokal erreichbar (kein öffentlicher Port, kein Login vorhanden)
    ports:
      - "127.0.0.1:9090:9090"

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: coder-node-exporter
    restart: unless-stopped
    logging: *coder-logging
    pid: host
    # Nur lesend eingebunden, damit Host-Metriken (u.a. freier Speicherplatz)
    # in Prometheus/Grafana sichtbar werden - bisher hing der fertige
    # Monitoring-Stack nur an Coders eigenen App-Metriken, ohne jede Sicht auf
    # den Host selbst.
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
      - --path.rootfs=/rootfs
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\$\$|/)
    ports:
      - "127.0.0.1:9100:9100"

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: coder-grafana
    restart: unless-stopped
    logging: *coder-logging
    environment:
      # Wirkt nur beim allerersten Start (leere grafana_data). Passwort danach
      # ändern: sudo /opt/coder/reset-passwords.sh
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_ADMIN_PASSWORD}
      # Kein GF_SERVER_ROOT_URL nötig – Zugriff läuft per SSH-Tunnel auf
      # 127.0.0.1:3001, nicht über eine eigene Domain.
    # Zusätzlich lokal erreichbar für Direktzugriff/Debugging
    ports:
      - "127.0.0.1:3001:3000"
    volumes:
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
# inkl. Wildcard-Subdomain für Coder-Workspace-Apps (Port-Forwarding,
# code-server-Vorschau etc. laufen über eigene Subdomains).
#
# Wildcard-Zertifikate lassen sich nicht per normaler HTTP-01-Challenge
# ausstellen (die validiert immer nur EINEN konkreten Hostnamen). Die von
# Coder offiziell empfohlene Lösung ohne eigenen DNS-Provider-API-Zugang ist
# Caddys On-Demand-TLS: bei jedem neuen Subdomain-Aufruf wird das Zertifikat
# erst bei Bedarf angefordert (dauert beim allerersten Aufruf 5-30 Sekunden
# länger). Für "echte" Wildcard-Zertifikate ohne diese Verzögerung bräuchte
# es einen eigenen Caddy-Build mit DNS-Provider-Plugin (z.B. Cloudflare/
# Route53) - dafür fehlt aktuell ein API-Token, siehe frühere Notiz.
#
# WICHTIG: "ask http://example.com" ist keine zu ersetzende Platzhalter-URL,
# sondern exakt so von Coder empfohlen - NICHT ändern. example.com
# beantwortet jede Anfrage mit HTTP 200 und erfüllt damit nur Caddys
# technische Voraussetzung, dass On-Demand-TLS einen "ask"-Endpunkt braucht.
# Der eigentliche Schutz gegen Missbrauch kommt vom Site-Block-Muster selbst:
# Caddy fragt ohnehin nur für Hostnamen nach, die schon auf
# "*.${DOMAIN_CODER}" passen - andere Domains erreichen diesen Site-Block gar
# nicht erst.
#
# P-005 (ehrliche Grenzen, kein Fix): "ask http://example.com" antwortet IMMER
# 200 – JEDER Internet-Teilnehmer kann per SNI mit beliebigem
# "*.${DOMAIN_CODER}"-Namen ein echtes Let's-Encrypt-Zertifikat auslösen (ohne
# Coder-Account). Wochenbudget: 50 pro registrierter Domain
# ("ghse-unterricht.de", geteilt mit allen anderen Schuldiensten derselben
# Domain). Folge: legitime neue Workspace-Apps bekommen in derselben Woche ggf.
# kein Zertifikat (TLS-Fehler im Unterricht). Zusätzlich gilt On-Demand hier
# auch für die Root-Domain selbst (nicht nur Wildcard), und jeder
# Erst-Handshake hängt an der Erreichbarkeit von example.com. Echter Fix
# (echter ask-Endpunkt vs. DNS-01-Wildcard) nur per Entscheidung D-TLS mit
# Frist – siehe BLOCKER B-05 im Report. Erkennung: Caddy-Log auf
# "obtaining certificate" beobachten.
# P-025: Hash VOR dem Schreiben merken – Schritt 3 startet Caddy nur bei
# tatsächlicher Änderung neu (blinder Restart = TLS-Unterbrechung bei jedem
# Re-Run).
CADDY_BEFORE=$(sudo sha256sum /opt/coder/Caddyfile 2>/dev/null | cut -d' ' -f1 || true)
CADDY_WAS_RUNNING=$(sudo docker inspect -f '{{.State.Running}}' coder-caddy 2>/dev/null || echo false)
sudo tee /opt/coder/Caddyfile > /dev/null <<EOF
{
    on_demand_tls {
        ask http://example.com
    }
}

${DOMAIN_CODER}, *.${DOMAIN_CODER} {
    reverse_proxy coder:3000
    tls {
        on_demand
        issuer acme {
            email ${ACME_EMAIL}
        }
    }
}
EOF

# prometheus.yml
sudo tee /opt/coder/prometheus.yml > /dev/null <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'coder'
    static_configs:
      - targets: ['coder:2112']
  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']
EOF

echo "############################################################"
echo "# [3/10] Docker-Stack starten"
echo "############################################################"
cd /opt/coder

# Validiert YAML-Syntax und Variablen-Interpolation, bevor überhaupt etwas
# gestartet wird - ein Fehler hier ist deutlich klarer als ein kryptischer
# Fehler mitten in "docker compose up".
sudo docker compose config --quiet

sudo docker compose up -d

# Docker Compose erkennt Änderungen am Inhalt einer eingebundenen Datei
# (Caddyfile) nicht automatisch, nur Änderungen an der docker-compose.yml
# selbst. P-025: trotzdem NICHT blind neu starten (TLS-Unterbrechung + Ban-/
# Verbindungs-Verlust bei jedem Re-Run), sondern nur bei tatsächlicher
# Caddyfile-Änderung – und nur, wenn Caddy vorher schon lief (Erstlauf braucht
# keinen Restart, "up -d" hat ihn gerade erstellt).
CADDY_AFTER=$(sudo sha256sum /opt/coder/Caddyfile | cut -d' ' -f1)
if [ "${CADDY_WAS_RUNNING}" = "true" ] && [ "${CADDY_BEFORE}" != "${CADDY_AFTER}" ]; then
  echo "Caddyfile geändert – starte Caddy neu ..."
  sudo docker compose restart caddy
else
  echo "Caddyfile unverändert (oder Erstlauf) – kein Caddy-Restart (P-025)."
fi

sudo docker compose ps

echo "############################################################"
echo "# [4/10] Firewall (ufw) + SSH-Schutz einrichten"
echo "############################################################"
sudo apt-get install -y ufw fail2ban

# Falls ein früherer Lauf schon eine engere oder App-Profil-Regel angelegt
# hat: entfernen, bevor die neue Regel gesetzt wird. --force unterdrückt die
# interaktive "Proceed? (y|n)"-Rückfrage von ufw, die das Skript sonst hier
# hängen lassen würde.
sudo ufw --force delete allow OpenSSH > /dev/null 2>&1 || true
sudo ufw --force delete allow 22/tcp > /dev/null 2>&1 || true
sudo ufw --force delete allow from 10.16.0.0/12 to any port 22 proto tcp > /dev/null 2>&1 || true

# SSH ist jetzt von überall erreichbar (Zugriff von zuhause gewünscht) – eine
# Herkunfts-Beschränkung ist bei einer dynamischen Heim-IP nicht praktikabel.
# "limit" statt "allow": ufw blockt automatisch IPs mit auffällig vielen
# Verbindungsversuchen in kurzer Zeit (eingebautes Rate-Limiting).
# fail2ban ist die zweite, schärfere Verteidigungslinie: es sperrt IPs nach
# mehreren fehlgeschlagenen Login-Versuchen für längere Zeit komplett.
sudo ufw limit 22/tcp

# backend=systemd explizit setzen: Debians fail2ban-Paket hat python3-systemd
# als harte Abhängigkeit (steht so auf der offiziellen Debian-Paketseite),
# journald ist also immer verfügbar - "auto" wählt das aber nicht zuverlässig
# automatisch (bekanntes, in fail2bans eigenem Bugtracker dokumentiertes
# Verhalten auf systemd-basierten Distributionen). Eine zusätzliche
# rsyslog/auth.log-Installation ist damit unnötig und wäre auf Debian 13
# überflüssiger Overhead.
# P-025: Hash VOR dem Schreiben merken (Vergleich weiter unten entscheidet
# zwischen reload/restart/start – blinder restart verwirft aktive Bans).
JAIL_BEFORE=$(sudo sha256sum /etc/fail2ban/jail.local 2>/dev/null | cut -d' ' -f1 || true)
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[sshd]
enabled  = true
backend  = systemd
port     = ssh
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
# P-025: "restart" bei jedem Lauf verwirft aktive Bans (Angreifer per Re-Run
# entbannt). Daher: nur bei geänderter jail.local neu laden (reload statt
# restart, mit restart als Fallback), sonst nur sicherstellen, dass der Dienst
# läuft (start ist No-Op, wenn aktiv – kein Ban-Verlust).
sudo systemctl enable fail2ban
JAIL_AFTER=$(sudo sha256sum /etc/fail2ban/jail.local | cut -d' ' -f1)
if systemctl is-active --quiet fail2ban && [ "${JAIL_BEFORE}" = "${JAIL_AFTER}" ]; then
  echo "fail2ban läuft bereits mit unveränderter jail.local – kein Reload (Bans bleiben erhalten, P-025)."
elif systemctl is-active --quiet fail2ban; then
  sudo systemctl reload fail2ban || sudo systemctl restart fail2ban
else
  sudo systemctl start fail2ban
fi

# Hinweis: Docker trägt für per "ports:" veröffentlichte Container-Ports
# (hier 80/443 von Caddy) eigene iptables-Regeln ein, die ufw dabei
# üblicherweise umgehen – diese beiden Regeln sind also vor allem
# Dokumentation, kein zusätzlicher Schutz. Der eigentliche Schutz für 80/443
# ist, dass dort ohnehin der öffentliche Coder-Zugang laufen soll. Bei
# Prometheus/Grafana kommt der Schutz stattdessen daher, dass deren Ports nur
# an 127.0.0.1 gebunden sind (siehe docker-compose.yml) – das wirkt unabhängig
# von ufw/Docker-iptables. Für SSH gilt das NICHT: sshd ist ein normaler
# Host-Dienst, kein Docker-Container, ufw/fail2ban greifen hier also wirklich.
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw --force enable
sudo ufw status verbose

if sudo ufw status | grep -q "Status: active"; then
  ok "ufw ist aktiv"
else
  fail "ufw ist NICHT aktiv"
fi
if sudo ufw status | grep -q "22/tcp.*LIMIT"; then
  ok "SSH ist offen, aber per ufw rate-limitiert (22/tcp LIMIT)"
else
  fail "SSH-Rate-Limit-Regel fehlt in ufw – prüfen mit: sudo ufw status"
fi
if systemctl is-active --quiet fail2ban; then
  ok "fail2ban läuft"
else
  fail "fail2ban läuft NICHT"
fi
if sudo fail2ban-client status sshd > /dev/null 2>&1; then
  ok "fail2ban-Jail 'sshd' ist aktiv"
else
  fail "fail2ban-Jail 'sshd' ist nicht aktiv – prüfen mit: sudo fail2ban-client status"
fi
if sudo fail2ban-client get sshd logpath > /dev/null 2>&1 || sudo journalctl -u ssh -n1 > /dev/null 2>&1; then
  ok "journald liefert SSH-Logs – fail2ban (backend=systemd) kann Login-Versuche sehen"
else
  warn "Konnte SSH-Logs über journald nicht bestätigen – prüfen mit: sudo fail2ban-client status sshd"
fi
if sudo sshd -T 2>/dev/null | grep -qi '^passwordauthentication no' && \
   sudo sshd -T 2>/dev/null | grep -qi '^kbdinteractiveauthentication no'; then
  ok "SSH-Passwort-Login ist deaktiviert (nur noch Keys erlaubt)"
else
  warn "SSH-Passwort-Login ist noch AKTIV – SSH-Key einrichten und danach deaktivieren lassen"
fi
if sudo ufw status | grep -q "80/tcp"; then
  ok "Port 80/tcp ist in ufw freigegeben"
else
  fail "Port 80/tcp fehlt in ufw"
fi
if sudo ufw status | grep -q "443/tcp"; then
  ok "Port 443/tcp ist in ufw freigegeben"
else
  fail "Port 443/tcp fehlt in ufw"
fi
if sudo ufw status | grep -q "443/udp"; then
  ok "Port 443/udp ist in ufw freigegeben (HTTP/3)"
else
  fail "Port 443/udp fehlt in ufw"
fi

echo "############################################################"
echo "# [5/10] Automatische Sicherheitsupdates einrichten"
echo "############################################################"
sudo apt-get update
sudo apt-get install -y unattended-upgrades

# Nicht-interaktive Aktivierung statt "dpkg-reconfigure -plow" (Dialog).
# Schreibt /etc/apt/apt.conf.d/20auto-upgrades.
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | sudo debconf-set-selections
sudo dpkg-reconfigure -f noninteractive unattended-upgrades

# Eigene Datei statt Änderung an der von dpkg verwalteten 50unattended-upgrades
# (die würde beim nächsten Paket-Update sonst zu einem Konflikt-Dialog führen).
sudo tee /etc/apt/apt.conf.d/52-coder-reboot > /dev/null <<'EOF'
// Automatischer Neustart bei Kernel-Updates, nachts um 03:00 Uhr
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

sudo systemctl status unattended-upgrades --no-pager || true

if systemctl is-active --quiet unattended-upgrades; then
  ok "unattended-upgrades-Dienst läuft"
else
  fail "unattended-upgrades-Dienst läuft nicht"
fi
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q '"1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  ok "Automatische Update-Prüfung ist aktiviert"
else
  fail "Automatische Update-Prüfung (20auto-upgrades) fehlt oder ist deaktiviert"
fi
if [ -f /etc/apt/apt.conf.d/52-coder-reboot ]; then
  ok "Automatischer Neustart um 03:00 Uhr ist konfiguriert"
else
  fail "Reboot-Konfiguration (52-coder-reboot) fehlt"
fi

echo "############################################################"
echo "# [6/10] Tägliches Datenbank-Backup einrichten"
echo "############################################################"
sudo tee /opt/coder/backup.sh > /dev/null <<'EOF'
#!/bin/bash
# Tägliches Postgres-Backup (F-005/F-008/F-009, mit P-013/P-017-Korrekturen).
# Aufruf: /opt/coder/backup.sh (direkt, per Cron oder aus update.sh).
# Gleichzeitige Läufe werden per flock serialisiert: ein zweiter Lauf wird
# übersprungen (Meldung + logger, Exit 0), statt die Datei des ersten per ">"
# zu trunkieren (F-009). Update-Shutdown-Race ist unkritisch: pg_dump läuft in
# einer Transaktion (konsistent), und ein laufendes Cron-Backup ist für
# update.sh genauso frisch wie ein eigenes.
set -euo pipefail
umask 077
# Cron-PATH ist minimal (/usr/bin:/bin): explizit setzen (P-017), damit
# docker/gzip/date/flock/logger/df/stat gefunden werden.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
BACKUP_DIR="/opt/coder/backups"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
mkdir -p "${BACKUP_DIR}"

# Selbst-Lock auf derselben Datei wie in der Cron-Zeile: schützt auch
# update.sh-Pre-Backup und manuelle Läufe, nicht nur Cron (F-009).
exec 9>"${BACKUP_DIR}/.backup.lock"
if ! flock -n 9; then
  echo "backup.sh: übersprungen, Vorgänger läuft noch (Lock ${BACKUP_DIR}/.backup.lock)." >&2
  logger -t coder-backup "übersprungen, Vorgänger läuft noch" || true
  exit 0
fi

# Mindestplatz vor dem Dump (P-007): klar abbrechen statt partieller Datei.
# Konservativer Bodenwert (Dumps sind wenige MB); kein Ersatz für
# Platten-Monitoring (siehe BLOCKER B-07/retention.size im Report).
MIN_FREE_BYTES=524288000
if FREE_BYTES=$(df --output=avail -B1 "${BACKUP_DIR}" 2>/dev/null | tail -n1 | tr -d ' '); then
  if [ "${FREE_BYTES}" -lt "${MIN_FREE_BYTES}" ]; then
    echo "backup.sh: zu wenig freier Platz in ${BACKUP_DIR} (${FREE_BYTES} < ${MIN_FREE_BYTES} Bytes), Abbruch ohne Datei." >&2
    logger -t coder-backup "FEHLGESCHLAGEN: zu wenig Platz (${FREE_BYTES} Bytes frei)"
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
  logger -t coder-backup "FEHLGESCHLAGEN: pg_dump-Pipeline"
  exit 1
fi
chmod 600 "${TMP}"

# Verifikation (F-005, mit P-013): gzip-Integrität ist hart (Fail), Größe nur
# Plausibilität (Warnung, kein Fail – frische DB ~1-2 KiB darf nicht scheitern,
# legitime Verkleinerung ebenso; leeres stdin wird als Warnung sichtbar).
if ! gzip -t "${TMP}"; then
  echo "backup.sh: gzip-Integritätstest fehlgeschlagen, keine Finaldatei angelegt." >&2
  logger -t coder-backup "FEHLGESCHLAGEN: gzip -t"
  exit 1
fi
DUMP_SIZE=$(stat -c %s "${TMP}")
if [ "${DUMP_SIZE}" -lt 512 ]; then
  echo "backup.sh: Warnung: Backup ungewöhnlich klein (${DUMP_SIZE} Bytes) – ggf. leere DB, bitte prüfen." >&2
fi

mv "${TMP}" "${FINAL}"
# mv hat übernommen, trap muss nichts mehr räumen.
trap - EXIT
chmod 600 "${FINAL}"
logger -t coder-backup "Backup OK: ${FINAL} (${DUMP_SIZE} Bytes)" || true

# Stückzahlbasierte Rotation (F-008): neueste 14 "coder_*.sql.gz" behalten
# (Kommentar-vs-Code-Mismatch behoben), Rest löschen. Mindestbestand ist
# eingebaut (bei <= 14 keine Löschung) – kein Totalverlust nach Cron-Lücken.
# Gezählt wird alles unter finalem Namen; dort landet seit F-005 nur
# Verifiziertes.
KEEP=14
mapfile -t NEWEST < <(ls -t "${BACKUP_DIR}"/coder_*.sql.gz 2>/dev/null || true)
if [ "${#NEWEST[@]}" -gt "${KEEP}" ]; then
  for OLD in "${NEWEST[@]:${KEEP}}"; do
    rm -f "${OLD}"
  done
fi
EOF
sudo chmod +x /opt/coder/backup.sh

# Falls von einer früheren Skript-Version noch ein Eintrag in der
# Root-Crontab existiert (dieses Skript nutzte anfangs "crontab -e"): erst
# entfernen, sonst würde das Backup doppelt laufen (einmal von dort, einmal
# von der neuen /etc/cron.d/-Datei unten).
if sudo crontab -l 2>/dev/null | grep -qF "/opt/coder/backup.sh"; then
  # "|| true": grep -v liefert Exit 1, wenn nach dem Filtern keine Zeile
  # übrig ist (F-001: einzige Alt-Zeile). Ohne das bricht das Setup unter
  # "set -euo pipefail" hier lautlos ab.
  (sudo crontab -l 2>/dev/null | grep -vF "/opt/coder/backup.sh" || true) | sudo crontab -
fi

# F-009(a): ohne Cron-Daemon läuft nie ein Backup, das Setup meldete trotzdem
# [OK]. Paketname/Service ("cron"/"cron") für trixie – auf Minimal-Images
# verifizieren (T-076, Test-VM).
sudo apt-get install -y cron
# "enable --now": enable ist idempotent, start ist No-Op wenn aktiv (kein
# Ban-Verlust wie bei fail2ban-restart, P-025 betrifft nur fail2ban).
sudo systemctl enable --now cron

# /etc/cron.d/ statt "crontab -l | ... | crontab -": eine einzelne,
# nachvollziehbare Datei statt fragilem Parsen/Überschreiben der gesamten
# Root-Crontab (Risiko, versehentlich andere Einträge zu verlieren). Das
# Format braucht hier zusätzlich das Benutzerfeld ("root") vor dem Befehl.
# flock -n (F-009): parallele Läufe (Cron 01:00 vs. update.sh-Pre-Backup vs.
# manuell) trunkieren einander sonst per ">" dieselbe Minutendatei. Zweiter
# Lauf wird in backup.sh sauber übersprungen. Absolute Pfade (P-017).
sudo tee /etc/cron.d/coder-backup > /dev/null <<'EOF'
0 1 * * * root /usr/bin/flock -n /opt/coder/backups/.backup.lock /opt/coder/backup.sh >> /var/log/coder-backup.log 2>&1
EOF
sudo chmod 644 /etc/cron.d/coder-backup

# P-007: Backup-Log ohne Rotation wächst als Root-Log unbegrenzt.
sudo tee /etc/logrotate.d/coder-backup > /dev/null <<'EOF'
/var/log/coder-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF
sudo chmod 644 /etc/logrotate.d/coder-backup

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
if [ -f /etc/logrotate.d/coder-backup ]; then
  ok "Log-Rotation für coder-backup.log ist konfiguriert"
else
  fail "Logrotate-Konfiguration für coder-backup.log fehlt"
fi

echo "Teste Backup einmal direkt..."
# Zusätzliche Absicherung: "condition: service_healthy" in der
# docker-compose.yml sorgt zwar schon dafür, dass "docker compose up -d" in
# Schritt 3 auf einen gesunden Postgres wartet, bevor es zurückkehrt - falls
# das auf einer sehr langsamen Platte trotzdem einmal nicht reicht, wartet
# diese Schleife hier zusätzlich bis zu 60 Sekunden, statt einen falschen
# Alarm zu melden.
for i in $(seq 1 30); do
  [ "$(sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null)" = "healthy" ] && break
  sleep 2
done
if sudo /opt/coder/backup.sh; then
  LATEST_BACKUP=$(ls -t /opt/coder/backups/coder_*.sql.gz 2>/dev/null | head -n1 || true)
  if [ -n "${LATEST_BACKUP:-}" ]; then
    ok "Testlauf erfolgreich, Backup-Datei angelegt: ${LATEST_BACKUP}"
  else
    fail "backup.sh lief ohne Fehler, aber es wurde keine Backup-Datei gefunden"
  fi
else
  fail "Testlauf von backup.sh ist fehlgeschlagen (z. B. weil Postgres noch nicht bereit war)"
fi

echo "############################################################"
echo "# [7/10] Update-Skript bereitstellen (manuell, KEIN Cronjob)"
echo "############################################################"
sudo tee /opt/coder/update.sh > /dev/null <<'EOF'
#!/bin/bash
# Manuelles Update: Images ziehen, Stack neu erstellen, alte Images pflegen.
# F-012/P-020 (Minimal-Fix, K5): Health-Gate nach "up -d" (Fehl-Update fällt
# selbst auf, nicht erst durch Nutzerbeschwerde) + Prune-Guard (altes Image
# bleibt 24 h für Rollback) + ehrlicher Rollback-Kommentar (Garantie nur für
# exakt Gepinnte). Keine app/db-Aufspaltung (Non-Goal bis D7, siehe Report).
set -euo pipefail
cd /opt/coder

# Vor jedem Update sicherheitshalber ein Backup ziehen (seit F-005 verifiziert)
echo "Ziehe Pre-Update-Backup..."
/opt/coder/backup.sh

docker compose pull
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
for i in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null)" = "healthy" ] && break
  sleep 2
done
if [ "$(docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null)" != "healthy" ]; then
  echo "FEHLER: Postgres nach Update nicht healthy – prüfen mit: docker logs coder-postgres" >&2
  GATE_OK=false
fi
if [ "${GATE_OK}" != "true" ]; then
  echo "FEHLER: Update-Gate rot – Stack prüfen, ggf. Rollback (siehe Kommentar unten)." >&2
  exit 1
fi
echo "Update-Gate grün: alle Container laufen, Postgres healthy."

# Prune-Guard (P-020): "-f" allein löschte SOFORT das alte Caddy-/Postgres-
# Image (bewegliche Tags caddy:2.10/postgres:15-alpine werden nach pull
# dangling). "until=24h" behält die Images von gestern für einen schnellen
# Rollback; älteres wird weiter aufgeräumt. Plattenbudget beachten (P-007).
docker image prune -f --filter "until=24h"

# Rollback-Hinweis (F-012, korrigiert): schnelles Zurück ("alte Version in
# setup-coder.sh setzen + Setup erneut") funktioniert OHNE erneuten Pull nur
# für exakt gepinnte Images (Coder/Prometheus/Grafana – deren Tags ändern sich
# nie von selbst). Für Caddy (Minor-Pin 2.10) und Postgres (15-alpine) holt
# "pull" ggf. ein neueres Image; das alte ist nach 24-h-Fenster weg und muss
# dann erneut gezogen werden. Bei Coder-Major-Updates mit Schema-Migrationen
# kann ein Downgrade irreversibel sein – Major-Updates nur mit verifiziertem
# Dump (siehe RESTORE.md) und einzeln fahren, nie zusammen mit DB-Update.
#
# Hinweis: "docker compose pull" holt bei exakten Pins NUR das, was in der
# docker-compose.yml steht – für ein Prometheus-/Grafana-Update
# PROMETHEUS_VERSION/GRAFANA_VERSION in setup-coder.sh anpassen und das
# Setup-Skript erneut ausführen, ein einfaches "update.sh" reicht dafür nicht.
EOF
sudo chmod +x /opt/coder/update.sh

# Falls ein früherer Lauf einen automatischen Update-Cronjob angelegt hat:
# entfernen, weil Updates jetzt bewusst manuell laufen sollen.
if sudo crontab -l 2>/dev/null | grep -qF "/opt/coder/update.sh"; then
  # Siehe F-001 oben: "|| true" verhindert stillen Abbruch, wenn die
  # Update-Zeile die einzige Crontab-Zeile war.
  (sudo crontab -l 2>/dev/null | grep -vF "/opt/coder/update.sh" || true) | sudo crontab -
  warn "Vorhandenen automatischen Update-Cronjob entfernt – Updates laufen jetzt nur noch manuell"
else
  ok "Kein automatischer Update-Cronjob vorhanden (wie gewünscht)"
fi

if [ -x /opt/coder/update.sh ]; then
  ok "update.sh ist vorhanden und ausführbar – manuell starten mit: sudo /opt/coder/update.sh"
else
  fail "update.sh fehlt oder ist nicht ausführbar"
fi

echo "Aktuelle Crontab:"
sudo crontab -l 2>/dev/null || echo "(keine Einträge - Backup läuft über /etc/cron.d/coder-backup, nicht über die Crontab)"

echo "############################################################"
echo "# [8/10] Passwort-Reset-Skript bereitstellen"
echo "############################################################"
sudo tee /opt/coder/reset-passwords.sh > /dev/null <<'EOF'
#!/bin/bash
# Setzt neue, zufällige Passwörter für den Postgres-Benutzer "coder" und den
# Grafana-Admin. Das ist nötig, weil POSTGRES_PASSWORD/GF_SECURITY_ADMIN_PASSWORD
# nur beim allerersten Start wirken – ein einfaches Ändern der .env reicht bei
# einer bereits laufenden Installation NICHT aus.
#
# Reihenfolge DB->.env ist Status-quo (F-010 sichert nur ab, P-018 diskutiert
# .env-zuerst – siehe BLOCKER B-10 im Report, keine stille Umstellung).
# Nutzung: sudo /opt/coder/reset-passwords.sh
set -euo pipefail
cd /opt/coder

if [ ! -f .env ]; then
  echo "Fehler: /opt/coder/.env nicht gefunden. Erst setup-coder.sh ausführen." >&2
  exit 1
fi
if ! grep -qE '^POSTGRES_PASSWORD=[^[:space:]]+' .env || ! grep -qE '^DOCKER_GID=[0-9]+$' .env; then
  echo "Fehler: /opt/coder/.env ist unvollständig. Erst reparieren (setup-coder.sh meldet wie), dann erneut." >&2
  exit 1
fi

for c in coder-postgres coder-grafana; do
  if [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)" != "true" ]; then
    echo "Fehler: Container ${c} läuft nicht. Erst 'docker compose up -d' ausführen." >&2
    exit 1
  fi
done

# Verifiziertes Vorab-Backup als Rollback-Basis (P-018): schlägt das fehl,
# wird gar nichts geändert.
echo "Ziehe Vorab-Backup (Rollback-Basis)..."
/opt/coder/backup.sh

ENV_BAK=".env.bak.$(date +%Y-%m-%d_%H%M%S)"
cp -a .env "${ENV_BAK}"
chmod 600 "${ENV_BAK}"
# Genau eine .bak-Generation behalten (P-018: keine Secret-Halde).
(ls -t .env.bak.* 2>/dev/null || true) | tail -n +2 | xargs -r rm -f
echo "Sicherung der alten .env: ${ENV_BAK}"

# Abbruch-Falle (F-010): weist bei Ctrl-C/SSH-Abbruch/Fehler den Weg, statt
# still DB=neu/.env=alt zu hinterlassen. Re-Run heilt (würfelt erneut und
# synchronisiert DB+Grafana+.env); .bak stellt den Vorzustand wieder her.
PHASE="Vorbereitung"
trap 'rc=$?; rm -f .env.tmp.??????; if [ "${rc}" -ne 0 ]; then echo "ABBRUCH in Phase [${PHASE}]. Möglicher Zustand: DB- und/oder Grafana-Passwort bereits neu, .env ggf. noch alt." >&2; echo "Reparatur: 1) Skript erneut laufen lassen (heilt in der Regel). 2) Falls DB-Login danach scheitert: altes Passwort aus ${ENV_BAK} per psql setzen (ALTER USER coder WITH PASSWORD ...). 3) Grafana ggf. erneut per grafana-cli angleichen." >&2; fi' EXIT

for c in coder-postgres coder-grafana; do
  if [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)" != "true" ]; then
    echo "Fehler: Container ${c} läuft nicht. Erst 'docker compose up -d' ausführen." >&2
    exit 1
  fi
done

OLD_PG_PW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
# hex statt base64: garantiert nur 0-9a-f, kann also nie ein "/", "+" oder "="
# enthalten, das in der Postgres-Connection-URL Probleme machen würde.
NEW_PG_PW=$(openssl rand -hex 24)
NEW_GF_PW=$(openssl rand -hex 16)

echo "Setze neues Postgres-Passwort..."
PHASE="Postgres-ALTER-USER"
# Übergabe über STDIN statt "docker exec -e PGPASSWORD=...": Alles, was auf
# der docker-exec-Kommandozeile steht, ist auf dem Host für jeden lokalen
# Benutzer über "ps aux" sichtbar (Kommandozeilen-Argumente sind grundsätzlich
# kein sicherer Weg für Geheimnisse). Per STDIN taucht weder das alte noch
# das neue Passwort dort auf.
docker exec -i coder-postgres sh <<INNER_EOF
export PGPASSWORD="${OLD_PG_PW}"
psql -U coder -d coder -c "ALTER USER coder WITH PASSWORD '${NEW_PG_PW}';"
INNER_EOF

# Verifikation mit dem NEUEN Passwort (gleiches STDIN-Muster, kein ps-Leak):
# schlägt das fehl, bricht das Skript ab, BEVOR .env angefasst wird.
PHASE="Postgres-Verifikation"
docker exec -i coder-postgres sh <<INNER_EOF
export PGPASSWORD="${NEW_PG_PW}"
psql -U coder -d coder -c "SELECT 1;" > /dev/null
INNER_EOF

echo "Setze neues Grafana-Admin-Passwort..."
PHASE="Grafana-Reset"
# Gleiches Prinzip wie oben bei Postgres: über STDIN statt als
# docker-exec-Argument, sonst wäre das neue Passwort kurzzeitig über
# "ps aux" auf dem Host sichtbar.
docker exec -i coder-grafana sh <<INNER_EOF
grafana-cli --homepath /usr/share/grafana admin reset-admin-password "${NEW_GF_PW}"
INNER_EOF

# .env aktualisieren, damit Coder mit dem neuen Postgres-Passwort verbindet
# und die Werte für später dokumentiert sind. F-010: atomar per Temp+mv statt
# "sed -i" (Abbruch während sed korrumpierte .env); beide Schlüssel in EINEM
# Tausch, DOCKER_GID bleibt erhalten.
PHASE=".env-Tausch"
ENV_TMP_PW=$(mktemp .env.tmp.XXXXXX)
chmod 600 "${ENV_TMP_PW}"
# Kein "|| true": Exit 1 hieße "alle Zeilen gefiltert" (= DOCKER_GID fehlt),
# dann ist Abbrechen (Fail-closed, .env unangetastet) richtig.
grep -v -e '^POSTGRES_PASSWORD=' -e '^GRAFANA_ADMIN_PASSWORD=' .env > "${ENV_TMP_PW}"
printf 'POSTGRES_PASSWORD=%s\n' "${NEW_PG_PW}" >> "${ENV_TMP_PW}"
printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "${NEW_GF_PW}" >> "${ENV_TMP_PW}"
chmod 600 "${ENV_TMP_PW}"
mv "${ENV_TMP_PW}" .env

# Coder neu erstellen, damit es die neue Datenbank-Verbindungs-URL verwendet.
# --no-deps: nur den Coder-Container anfassen, Postgres nicht mit neu starten
# (dessen Environment referenziert POSTGRES_PASSWORD zwar auch, ein Neustart
# wäre harmlos, aber unnötig, solange die Datenbank schon initialisiert ist).
PHASE="Coder-Recreate"
docker compose up -d --no-deps coder

PHASE="fertig"
trap - EXIT

echo "------------------------------------------------------------"
echo "Neue Zugangsdaten (jetzt sicher notieren!):"
echo "  Postgres-Passwort:      ${NEW_PG_PW}"
echo "  Grafana-Admin-Passwort: ${NEW_GF_PW}"
echo "  (stehen auch in /opt/coder/.env, nur für root lesbar)"
echo "------------------------------------------------------------"
EOF
sudo chmod +x /opt/coder/reset-passwords.sh

if [ -x /opt/coder/reset-passwords.sh ]; then
  ok "reset-passwords.sh ist vorhanden und ausführbar – Aufruf: sudo /opt/coder/reset-passwords.sh"
else
  fail "reset-passwords.sh fehlt oder ist nicht ausführbar"
fi

echo "############################################################"
echo "# [9/10] Komplett-Reset-Skript bereitstellen"
echo "############################################################"
sudo tee /opt/coder/reset-coder.sh > /dev/null <<'EOF'
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
# Ablauf (F-011/P-019): Inventar (lesend) -> Backup -> Bestätigung erst nach
# Backup-Ergebnis -> Löschung. Mit --force bei Backup-Fehlschlag zusätzlich
# Zweitbestätigung mit Anzeige des neuesten Backups.
# Nutzung: sudo /opt/coder/reset-coder.sh [--force]
#   --force: Reset auch durchführen, wenn das Sicherheits-Backup fehlschlägt
#            (ohne --force bricht das Skript in diesem Fall ab, statt
#            möglicherweise die einzige Datenrettung zu verlieren).
# Danach: sudo ./setup-coder.sh erneut ausführen, um alles neu aufzubauen.
set -euo pipefail
cd /opt/coder

FORCE=false
if [ "${1:-}" = "--force" ]; then
  FORCE=true
fi

# P-019: nicht-interaktiv (Pipe/CI) ohne --force verweigern – ein per Pipe
# eingespeistes "RESET" ist keine bewusste Bestätigung.
if [ ! -t 0 ] && [ "${FORCE}" != "true" ]; then
  echo "Fehler: stdin ist kein Terminal (Pipe/CI erkannt). Destruktiver Reset wird ohne --force verweigert." >&2
  echo "Interaktiv aufrufen oder bewusst: sudo /opt/coder/reset-coder.sh --force" >&2
  exit 1
fi

# Compose-Projektname determinieren (F-004/P-016): Default = Verzeichnisname
# (/opt/coder -> "coder"), aber per -p/Env überstimmbar – daher aus
# "docker compose config" lesen, nie raten. Leer/Fehler = Abbruch.
PROJECT=$(docker compose config 2>/dev/null | awk '/^name:/ {print $2; exit}')
if [ -z "${PROJECT:-}" ]; then
  echo "Fehler: Compose-Projektname unklar (docker compose config liefert kein 'name:'). Abbruch, nichts wurde verändert." >&2
  exit 1
fi

echo "############################################################"
echo "Inventar VOR dem Reset (F-011: Workspace-Hinweis vor Löschung):"
echo "Coder erstellt Workspace-Container direkt über den Docker-Socket,"
echo "nicht über diese docker-compose.yml. 'docker compose down' erfasst sie"
echo "NICHT – sie liefen nach dem Reset verwaist weiter (DB-Metadaten weg,"
echo "Container da, Namens-/Port-Konflikte beim Neuaufbau möglich)."
echo "Coder-Workspace-Labels sind in diesem Repo nicht verifiziert (BLOCKER"
echo "B-11); daher werden ehrlich ALLE Nicht-Compose-Container angezeigt:"
docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}' | awk -v p="${PROJECT}" -F'\t' '$3 != p {print "  fremd: " $1 " (" $2 ")"}' || true
echo "(Compose-eigene Container mit project=${PROJECT} sind oben nicht gelistet.)"
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

echo "Stoppe Container (caddy_data/caddy_config bleiben unangetastet)..."
docker compose down --remove-orphans

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
  echo "Abbruch VOR '.env'-Löschung – Stack ist gestoppt, aber Daten und .env sind intakt ('docker compose up -d' stellt wieder her)." >&2
  exit 1
fi

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
echo ""
echo "Falls vor dem Reset Workspace-Container liefen (siehe Inventar oben):"
echo "sie stehen ggf. noch (verwaist). Prüfen und von Hand aufräumen:"
echo "  docker ps -a"
echo "------------------------------------------------------------"
EOF
sudo chmod +x /opt/coder/reset-coder.sh

if [ -x /opt/coder/reset-coder.sh ]; then
  ok "reset-coder.sh ist vorhanden und ausführbar – Aufruf: sudo /opt/coder/reset-coder.sh"
else
  fail "reset-coder.sh fehlt oder ist nicht ausführbar"
fi

echo "############################################################"
echo "# [10/10] Abschlusscheck & Zusammenfassung"
echo "############################################################"

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
if CODER_GROUPS=$(sudo docker inspect --format '{{json .HostConfig.GroupAdd}}' coder 2>/dev/null); then
  if [ -n "${DOCKER_GID:-}" ] && printf '%s' "${CODER_GROUPS}" | grep -q "${DOCKER_GID}"; then
    ok "Coder-Container hat docker-GID ${DOCKER_GID} (Socket-Zugriff konfiguriert)"
  else
    fail "Coder-Container GroupAdd (${CODER_GROUPS}) enthält docker-GID ${DOCKER_GID:-?} NICHT – Socket-Zugriff prüfen (F-007)"
  fi
else
  warn "Socket-Probe nicht möglich (coder-Container nicht inspizierbar)"
fi

# curl ist der eigentlich aussagekräftige Test: er prüft DNS-Auflösung, TCP-
# Erreichbarkeit UND TLS-Zertifikat in einem Schritt, über den echten Pfad,
# den ein Browser auch nehmen würde. "getent hosts" allein hatte zwei
# Schwächen: es prüft nur die lokale Namensauflösung des Servers (die von der
# öffentlichen Auflösung abweichen kann, z.B. bei internem DNS), und es wurde
# bisher als Vorbedingung genutzt, wodurch der curl-Test bei fehlendem
# lokalem DNS-Eintrag gar nicht erst lief. Jetzt läuft curl immer; getent
# dient nur noch als Zusatz-Diagnose für eine genauere Fehlermeldung.
# /healthz statt der Startseite: dedizierter, dokumentierter Health-Endpoint.
# WICHTIG: Die Zuweisung steht direkt in der if-Bedingung (nicht davor) - nur
# dort greift set -e nicht. Eine separate "HTTP_CODE=$(curl ...)"-Zeile davor
# hätte das ganze Skript beim ersten Fehlschlag (z.B. DNS/Portweiterleitung
# noch nicht bereit) sofort und ohne jede Meldung beendet, weil ein
# fehlschlagender einfacher Befehl unter set -e das Skript abbricht - außer
# er steht direkt in einer if/while/until-Bedingung.
if HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${DOMAIN_CODER}/healthz" 2>/dev/null); then
  : # Antwort kam an, der HTTP-Code steht in HTTP_CODE
else
  HTTP_CODE="000"
fi

if [ "${HTTP_CODE}" = "200" ]; then
  ok "https://${DOMAIN_CODER}/healthz antwortet mit HTTP 200 – Let's-Encrypt-Zertifikat ausgestellt, Coder erreichbar"
elif getent hosts "${DOMAIN_CODER}" > /dev/null 2>&1; then
  warn "${DOMAIN_CODER} löst lokal auf, aber https://${DOMAIN_CODER}/healthz antwortet nicht mit HTTP 200 (Code: ${HTTP_CODE}). Mögliche Ursachen: öffentliche DNS-Auflösung weicht ab, Portweiterleitung 80/443 fehlt noch, oder Zertifikat noch nicht ausgestellt. Prüfen mit: sudo docker compose -f /opt/coder/docker-compose.yml logs caddy"
else
  warn "DNS: ${DOMAIN_CODER} löst noch nicht auf. Normal, solange DNS-Eintrag und Portweiterleitung/Reverse Proxy im Schulnetz noch nicht stehen – Skript nach der Einrichtung einfach erneut laufen lassen."
fi

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
echo "Coder manuell aktualisieren: sudo /opt/coder/update.sh"
echo "Grafana weiterhin nur per SSH-Tunnel: 127.0.0.1:3001"

if ! (sudo sshd -T 2>/dev/null | grep -qi '^passwordauthentication no' && \
      sudo sshd -T 2>/dev/null | grep -qi '^kbdinteractiveauthentication no'); then
  echo ""
  echo "!! WICHTIG: SSH-Passwort-Login ist noch aktiv, und SSH ist vom Internet aus"
  echo "!! erreichbar. Stelle sicher, dass das Login-Passwort stark ist, und richte"
  echo "!! einen SSH-Key ein, sobald möglich – dann Bescheid geben, damit"
  echo "!! PasswordAuthentication deaktiviert wird."
fi

if [ "${ERROR_COUNT}" -gt 0 ]; then
  echo ""
  echo "${ERROR_COUNT} [FEHLER]-Eintrag/-Einträge in der Zusammenfassung oben – bitte prüfen."
  exit 1
fi