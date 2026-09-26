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
if [ ! -f /opt/coder/.env ]; then
  # hex statt base64: garantiert nur 0-9a-f, kann also nie ein "/", "+" oder
  # "=" enthalten, das in der Postgres-Connection-URL (postgres://user:PASS@host)
  # die URL zerlegen bzw. falsch interpretiert werden würde.
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)

  sudo tee /opt/coder/.env > /dev/null <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
DOCKER_GID=${DOCKER_GID}
EOF
  sudo chmod 600 /opt/coder/.env
  sudo chown root:root /opt/coder/.env

  echo "------------------------------------------------------------"
  echo "Neu generierte Zugangsdaten (jetzt sicher notieren!):"
  echo "  Postgres-Passwort:      ${POSTGRES_PASSWORD}"
  echo "  Grafana-Admin-Passwort: ${GRAFANA_ADMIN_PASSWORD}"
  echo "  (stehen auch in /opt/coder/.env, nur für root lesbar)"
  echo "------------------------------------------------------------"
else
  echo "/opt/coder/.env existiert bereits – wird nicht überschrieben."
fi

# docker-compose.yml
# WICHTIG: \${...} bleibt hier absichtlich für Docker Compose stehen (wird aus
# /opt/coder/.env aufgelöst); ${DOMAIN_CODER} etc. werden dagegen jetzt von
# der Shell eingesetzt.
sudo tee /opt/coder/docker-compose.yml > /dev/null <<EOF
services:
  postgres:
    image: postgres:15-alpine
    container_name: coder-postgres
    restart: unless-stopped
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
# selbst. Deshalb Caddy hier gezielt neu starten, damit eine neue Caddyfile
# (z.B. nach Domain-Wechsel) garantiert übernommen wird.
sudo docker compose restart caddy

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
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[sshd]
enabled  = true
backend  = systemd
port     = ssh
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
# "enable" (Systemstart) + "restart" statt "enable --now": bei einem
# erneuten Lauf des Skripts läuft fail2ban meist schon, und "enable --now"
# lädt eine geänderte jail.local dann NICHT automatisch neu – "restart" tut
# das immer, egal ob der Dienst vorher lief oder nicht.
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

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
set -euo pipefail
umask 077
BACKUP_DIR="/opt/coder/backups"
TIMESTAMP=$(date +%Y-%m-%d_%H%M)
mkdir -p "${BACKUP_DIR}"

docker exec coder-postgres pg_dump -U coder coder | gzip > "${BACKUP_DIR}/coder_${TIMESTAMP}.sql.gz"
chmod 600 "${BACKUP_DIR}/coder_${TIMESTAMP}.sql.gz"

# Nur die letzten 14 Backups behalten
find "${BACKUP_DIR}" -name 'coder_*.sql.gz' -type f -mtime +14 -delete
EOF
sudo chmod +x /opt/coder/backup.sh

# Falls von einer früheren Skript-Version noch ein Eintrag in der
# Root-Crontab existiert (dieses Skript nutzte anfangs "crontab -e"): erst
# entfernen, sonst würde das Backup doppelt laufen (einmal von dort, einmal
# von der neuen /etc/cron.d/-Datei unten).
if sudo crontab -l 2>/dev/null | grep -qF "/opt/coder/backup.sh"; then
  (sudo crontab -l 2>/dev/null | grep -vF "/opt/coder/backup.sh") | sudo crontab -
fi

# /etc/cron.d/ statt "crontab -l | ... | crontab -": eine einzelne,
# nachvollziehbare Datei statt fragilem Parsen/Überschreiben der gesamten
# Root-Crontab (Risiko, versehentlich andere Einträge zu verlieren). Das
# Format braucht hier zusätzlich das Benutzerfeld ("root") vor dem Befehl.
sudo tee /etc/cron.d/coder-backup > /dev/null <<'EOF'
0 1 * * * root /opt/coder/backup.sh >> /var/log/coder-backup.log 2>&1
EOF
sudo chmod 644 /etc/cron.d/coder-backup
ok "Täglicher Backup-Cronjob ist eingetragen (01:00 Uhr, /etc/cron.d/coder-backup)"

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
set -euo pipefail
cd /opt/coder

# Vor jedem Update sicherheitshalber ein Backup ziehen
/opt/coder/backup.sh

docker compose pull
docker compose up -d --remove-orphans

# Bewusst "-f" statt "-a": "-a" würde auch das VORHERIGE, noch getaggte
# Image entfernen (z.B. die alte Coder-Version). Das spart zwar Plattenplatz,
# macht aber einen schnellen Rollback ("CODER_VERSION zurücksetzen und
# setup-coder.sh erneut laufen lassen") unmöglich, ohne das alte Image aus
# dem Internet neu zu ziehen. Für ein kleines Schul-Setup ist die Möglichkeit,
# bei einer fehlerhaften Version schnell zurückzuwechseln, wichtiger als der
# gesparte Plattenplatz. Bei Bedarf manuell aufräumen: sudo docker image
# prune -a
docker image prune -f

# Hinweis: CODER_VERSION/CADDY_VERSION sind hier oben exakt bzw. auf eine
# Minor-Version gepinnt, PROMETHEUS_VERSION/GRAFANA_VERSION exakt. "docker
# compose pull" holt bei exakten Pins NUR das, was in der docker-compose.yml
# steht - für ein Prometheus-/Grafana-Update muss man PROMETHEUS_VERSION/
# GRAFANA_VERSION in setup-coder.sh anpassen und das Setup-Skript erneut
# ausführen, ein einfaches "update.sh" reicht dafür nicht.
EOF
sudo chmod +x /opt/coder/update.sh

# Falls ein früherer Lauf einen automatischen Update-Cronjob angelegt hat:
# entfernen, weil Updates jetzt bewusst manuell laufen sollen.
if sudo crontab -l 2>/dev/null | grep -qF "/opt/coder/update.sh"; then
  (sudo crontab -l 2>/dev/null | grep -vF "/opt/coder/update.sh") | sudo crontab -
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
# Nutzung: sudo /opt/coder/reset-passwords.sh
set -euo pipefail
cd /opt/coder

if [ ! -f .env ]; then
  echo "Fehler: /opt/coder/.env nicht gefunden. Erst setup-coder.sh ausführen." >&2
  exit 1
fi

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
# Übergabe über STDIN statt "docker exec -e PGPASSWORD=...": Alles, was auf
# der docker-exec-Kommandozeile steht, ist auf dem Host für jeden lokalen
# Benutzer über "ps aux" sichtbar (Kommandozeilen-Argumente sind grundsätzlich
# kein sicherer Weg für Geheimnisse). Per STDIN taucht weder das alte noch
# das neue Passwort dort auf.
docker exec -i coder-postgres sh <<INNER_EOF
export PGPASSWORD="${OLD_PG_PW}"
psql -U coder -d coder -c "ALTER USER coder WITH PASSWORD '${NEW_PG_PW}';"
INNER_EOF

echo "Setze neues Grafana-Admin-Passwort..."
# Gleiches Prinzip wie oben bei Postgres: über STDIN statt als
# docker-exec-Argument, sonst wäre das neue Passwort kurzzeitig über
# "ps aux" auf dem Host sichtbar.
docker exec -i coder-grafana sh <<INNER_EOF
grafana-cli --homepath /usr/share/grafana admin reset-admin-password "${NEW_GF_PW}"
INNER_EOF

# .env aktualisieren, damit Coder mit dem neuen Postgres-Passwort verbindet
# und die Werte für später dokumentiert sind
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${NEW_PG_PW}|" .env
sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${NEW_GF_PW}|" .env

# Coder neu erstellen, damit es die neue Datenbank-Verbindungs-URL verwendet.
# --no-deps: nur den Coder-Container anfassen, Postgres nicht mit neu starten
# (dessen Environment referenziert POSTGRES_PASSWORD zwar auch, ein Neustart
# wäre harmlos, aber unnötig, solange die Datenbank schon initialisiert ist).
docker compose up -d --no-deps coder

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
read -r -p "Zum Fortfahren 'RESET' eingeben: " CONFIRM
if [ "${CONFIRM}" != "RESET" ]; then
  echo "Abgebrochen, nichts wurde verändert."
  exit 1
fi

echo "Versuche ein letztes Backup vor dem Reset..."
if ! /opt/coder/backup.sh; then
  if [ "${FORCE}" = "true" ]; then
    echo "Warnung: Backup fehlgeschlagen, mache wegen --force trotzdem weiter."
  else
    echo "Fehler: Backup vor dem Reset fehlgeschlagen. Abbruch, ohne etwas zu löschen." >&2
    echo "Zum Reset trotzdem erzwingen: sudo /opt/coder/reset-coder.sh --force" >&2
    exit 1
  fi
fi

echo "Stoppe Container (caddy_data/caddy_config bleiben unangetastet)..."
docker compose down --remove-orphans

echo "Entferne Datenbank-, Grafana- und Prometheus-Volumes..."
# Über das Compose-Label statt über einen geratenen "coder_<name>"-Präfix
# gesucht, da der tatsächliche Volume-Name vom Projektnamen (=Verzeichnis-
# name) abhängt und sich so nicht fest annehmen lässt.
for VOL_LABEL in postgres_data grafana_data prometheus_data; do
  VOL_NAME=$(docker volume ls -q --filter "label=com.docker.compose.volume=${VOL_LABEL}")
  if [ -n "${VOL_NAME}" ]; then
    docker volume rm "${VOL_NAME}"
  fi
done

echo "Entferne generierte Passwörter (.env)..."
rm -f .env

echo "------------------------------------------------------------"
echo "Reset abgeschlossen. Zum Neuaufbau:"
echo "  sudo ./setup-coder.sh"
echo "(erzeugt neue Passwörter und startet den Stack komplett neu)"
echo ""
echo "Hinweis: Coder erstellt Workspace-Container direkt über den"
echo "Docker-Socket, nicht über diese docker-compose.yml. Falls vor dem"
echo "Reset Workspaces liefen, kennt 'docker compose down' sie nicht und"
echo "lässt sie stehen. Prüfen und bei Bedarf von Hand aufräumen:"
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