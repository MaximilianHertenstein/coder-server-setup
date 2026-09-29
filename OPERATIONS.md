# OPERATIONS.md – Betrieb und Wartung

Stand: 2026-09-29. Grundlage: das tatsächlich im Repository stehende
`setup-coder.sh` (erzeugt alles auf dem Server). Alle Befehle hier sind
Standard-Docker-/systemd-Befehle; wo das Setup selbst etwas prüft oder
erzeugt, steht der Pfad dabei.

Verweise: Wiederherstellung → [RESTORE.md](RESTORE.md), Sicherheit →
[SECURITY.md](SECURITY.md), Fehlerbilder → [TROUBLESHOOTING.md](TROUBLESHOOTING.md),
Änderungsstand → [CHANGELOG.md](CHANGELOG.md), Einstieg → [README.md](README.md).

## 1. Ablageprinzip

| Wo | Was |
|---|---|
| Repository | Quelltext: `setup-coder.sh`, `ssh-harden.sh`, `RESTORE.md`, `templates/allowlist.md`, `tests/`, `ai-review/` |
| `/opt/coder/` auf dem Server | Alles Erzeugte: Stack-Konfiguration, `.env`, Wartungsskripte, Backups, Hashstore |
| `/etc/cron.d/`, `/etc/logrotate.d/`, `/etc/fail2ban/`, `/etc/apt/apt.conf.d/` | vom Setup erzeugte Systemdateien |

Ein `git pull` allein verändert **nichts** am laufenden System. Änderungen
an generierten Dateien kommen erst durch einen erneuten Lauf von
`setup-coder.sh` an – dieser schreibt die Dateien dabei aber neu (siehe
Abschnitt 7, Drift-Warnung).

## 2. Vom Setup erzeugte Dateien

| Pfad | Zweck | Hashstore |
|---|---|---|
| `/opt/coder/.env` | Secrets: `POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `DOCKER_GID` (600, root) | nein (bewusst) |
| `/opt/coder/docker-compose.yml` | Stack-Definition, Logs, Ports, Volumes | ja |
| `/opt/coder/Caddyfile` | TLS + Reverse Proxy, Apex + Wildcard | ja |
| `/opt/coder/prometheus.yml` | Scrape-Jobs `coder`, `node`, Einbindung `rule_files` | ja |
| `/opt/coder/rules/coder-alerts.yml` | fünf Alarmregeln (Target down, Platte <10 %, Backup >25 h, TLS-Ausstellungen/7 d >20, TLS-Check veraltet) | nein |
| `/opt/coder/grafana/provisioning/datasources/prometheus.yml` | Datasource `Prometheus` wird automatisch angelegt | nein |
| `/opt/coder/node-textfile/coder_backup.prom` | Zeitstempel des letzten erfolgreichen Backups (vom Setup angelegt, vom Lauf beschrieben) | nein |
| `/opt/coder/node-textfile/coder_tls.prom` | Untergrenze der TLS-Ausstellungen der letzten 7 Tage und Zeitstempel des letzten erfolgreichen Checks | nein |
| `/opt/coder/domain` | Apex-Domain, Quelle für TLS-Smoke und Update-Gate (644) – wird bei jedem Lauf aus `DOMAIN_CODER` überschrieben, daher bewusst ohne Hashstore | nein |
| `/opt/coder/versions.env` | wirksam gewesene Versionen der fünf Images (644) | nein |
| `/opt/coder/backup.sh` | tägliche Datenbank-Sicherung | ja |
| `/opt/coder/.maintenance.lock` | gemeinsamer Laufzeit-Lock für Backup, Update, Passwortwechsel und Reset (600, root) | nein |
| `/opt/coder/update.sh` | manuelles Update mit Pre-Backup und Health-Gate | ja |
| `/opt/coder/reset-passwords.sh` | Passwort-Rotation Postgres + Grafana | ja |
| `/opt/coder/reset-coder.sh` | Komplett-Reset des Coder-Stacks | ja |
| `/opt/coder/boot-check.sh` | lesendes Boot-Gate nach Reboot | ja |
| `/opt/coder/check-tls.sh` | zählt Let's-Encrypt-Ausstellungen (7 Tage) | ja |
| `/opt/coder/RESTORE.md` | Runbook-Kopie (Quelle liegt im Repository) | nein |
| `/opt/coder/.generated-hashes` | sha256 der 16 generierten Dateien (600, root) | – |
| `/etc/cron.d/coder-backup` | Cron: täglich 01:00 | ja |
| `/etc/cron.d/coder-tlscheck` | Cron: Montag 06:30 | ja |
| `/etc/cron.d/coder-bootcheck` | Cron: `@reboot` | ja |
| `/etc/logrotate.d/coder-backup` | Rotation `/var/log/coder-backup.log` | ja |
| `/etc/logrotate.d/coder-logs` | Rotation `/var/log/coder-boot.log` und `/var/log/coder-tls.log` (wöchentlich, 8×) | ja |
| `/etc/fail2ban/jail.d/10-coder-sshd.local` | Drop-In: Jail `sshd` (backend systemd) | ja |
| `/etc/apt/apt.conf.d/52-coder-reboot` | automatischer Reboot 03:00 | ja |
| `/etc/docker/daemon.json` | Log-Limit json-file 10 MB × 3 (nur beim Fehlen geschrieben) | nein |
| `/etc/apt/apt.conf.d/20auto-upgrades` | via debconf von unattended-upgrades | nein |
| `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.gpg` | Docker-apt-Repo (Fingerprint geprüft) | nein |

Nicht im Repository, nur auf dem Server: alle Backups, `.env`-Sicherungen
(`.env.bak.*`, genau eine Generation), Logs.

## 3. Konfigurationsvariablen

Überschreibbar per Umgebungsvariable beim Aufruf, ohne Datei zu ändern:
`DOMAIN_CODER`, `ACME_EMAIL`, `CODER_VERSION`, `CADDY_VERSION`,
`PROMETHEUS_VERSION`, `GRAFANA_VERSION`, `NODE_EXPORTER_VERSION`, dazu
`CODER_ALLOW_SSH_DOWNGRADE` (nur `yes`, siehe [SECURITY.md](SECURITY.md)),
`CODER_ALLOW_DOWNGRADE` (nur `yes`, erlaubt ein bewusstes Zurücksetzen einer
Image-Version) und `ACME_CA` (eigener ACME-Endpunkt, z. B.
Let's-Encrypt-Staging; leer = Caddys Standard).
Defaults und Pin-Regeln: [README.md](README.md), Abschnitt „Wichtigste
Konfiguration".

**Secrets-Verfahren**

- Erstpasswörter werden beim ersten Lauf erzeugt. Nur das Grafana-Admin-
  Passwort erscheint in der Ausgabe; das interne Postgres-Passwort steht
  ausschließlich in `/opt/coder/.env` (600, root:root).
- Eine unvollständige `.env` wird nie still neu gewürfelt – das Setup
  bricht ab und nennt die Reparatur.
- Passwörter müssen hex sein (`[0-9a-f]`); sonst bricht das Setup ab und
  verweist auf `reset-passwords.sh`.
- Rotation: `sudo /opt/coder/reset-passwords.sh` (zieht zuerst ein
  Backup, legt `.env.bak.<Zeitstempel>` an, gibt das neue Grafana-Admin-
  Passwort aus).
- Nie in Tickets, Chats, Logs oder das Repository kopieren.

## 4. Start, Stop, Status

Stack-Arbeitsverzeichnis ist immer `/opt/coder`:

```bash
cd /opt/coder
sudo docker compose ps                        # Status
sudo docker compose up -d                     # starten/angleichen
sudo docker compose stop                      # stoppen (Volumes bleiben)
sudo docker compose restart <dienst>          # einen Dienst neu starten
sudo docker compose up -d --no-deps coder    # nur Coder neu erstellen
sudo docker compose logs -f --tail=100 coder  # Logs eines Dienstes
sudo docker compose down --remove-orphans     # Container + Netz entfernen, Volumes bleiben
```

Reihenfolge beim Stack: `postgres` muss `healthy` sein, bevor `coder`
startet (`depends_on: condition: service_healthy`). Nach einem Reboot
startet Docker die Container direkt – das gilt als Grund, warum
`boot-check.sh` existiert.

Caddy-Hinweis: Docker-Compose erkennt Änderungen an der eingebundenen
`Caddyfile` nicht automatisch. Das Setup lädt die Konfiguration nur neu,
wenn sich die Datei geändert hat **und** `caddy validate` grün ist –
ohne `restart`, damit bestehende Verbindungen nicht abreißen. Bei eigener
Änderung also zuerst prüfen, dann neu laden:

```bash
sudo docker exec coder-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo docker exec coder-caddy caddy reload    --config /etc/caddy/Caddyfile --adapter caddyfile
```

Prometheus lädt `prometheus.yml` und Alarmregeln auf SIGHUP neu; das Setup
sendet das Signal nur bei einer Dateiänderung. Manuell:
`sudo docker kill -s HUP coder-prometheus`. Grafana liest seine Datasource-
Provisioning-Datei beim Start; das Setup startet Grafana bei einer Änderung
dieser Datei neu (`sudo docker restart coder-grafana`).

## 5. Checks (Gesundheit prüfen)

Schritt 10 des Setups meldet `[OK]`/`[WARNUNG]`/`[FEHLER]` für: die sechs
Container, den Docker-Socket-Zugriff (GroupAdd/docker-GID),
`https://<domain>/healthz` (HTTP 200) und den Wildcard-DNS. Port-Konflikte
prüft Schritt 3 (Preflight), `pg_isready` läuft als Compose-Healthcheck.
Alles davon einzeln reproduzierbar – plus die Nachweise, die das Setup
nicht selbst abfragt:

```bash
# Alle sechs Container laufen
for c in coder-postgres coder coder-caddy coder-prometheus coder-node-exporter coder-grafana; do
  sudo docker inspect -f '{{.Name}} {{.State.Running}}' "$c"
done

# PostgreSQL gesund + erreichbar
sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres   # erwartet: healthy
sudo docker exec coder-postgres pg_isready -U coder -d coder

# Öffentlicher Pfad (DNS + Portweiterleitung + TLS in einem)
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 \
  https://coder.ghse-unterricht.de/healthz                          # erwartet: 200

# Lokal gebundene Dienste
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9090/-/healthy   # Prometheus
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3001/login        # Grafana
curl -s http://127.0.0.1:9100/metrics | head -n1                            # node-exporter

# Coder hat Docker-Socket-Zugriff (Gruppe muss die aktuelle docker-GID enthalten)
sudo docker inspect --format '{{json .HostConfig.GroupAdd}}' coder

# DNS inkl. Wildcard (Wildcard = Voraussetzung für Workspace-Apps)
getent hosts coder.ghse-unterricht.de
getent hosts setup-probe-$RANDOM.coder.ghse-unterricht.de

# On-Demand-TLS-ask (nur IM Container erreichbar – Port 9123 ist nicht
# in "ports:" und hat keine ufw-Regel): 200 = erlaubt, 404 = verboten
docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=coder.ghse-unterricht.de'
docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=evil.ghse-unterricht.de'   # erwartet: 404, rc=1 (busybox wget)

# Backup-Metrik sichtbar? (fehlend = noch kein erfolgreicher Lauf)
cat /opt/coder/node-textfile/coder_backup.prom
curl -s http://127.0.0.1:9100/metrics | grep '^coder_backup'

# TLS-Ausstellungen (Untergrenze wegen Container-Logrotation)
curl -s http://127.0.0.1:9100/metrics | grep '^coder_tls_issuances'

# Zeitpunkt des letzten erfolgreichen TLS-Checks; fehlt/älter als 8 Tage = Alarm
curl -s http://127.0.0.1:9100/metrics | grep '^coder_tls_check_last_success_timestamp_seconds'

# Alarmregeln geladen (5 Stück)?
curl -s http://127.0.0.1:9090/api/v1/rules | grep -o '"name":"[A-Za-z]*"' | sort -u

# Prüfen, ob irgendwo eine Docker-Origin für unattended-upgrades konfiguriert ist
apt-config dump | grep -E 'Unattended-Upgrade::Origins-Pattern'
```

Firewall/SSH-Checks:

```bash
sudo ufw status verbose
sudo ufw show added      # gespeicherte Regeln, auch wenn Status inactive ist
grep IPV6 /etc/default/ufw
sudo fail2ban-client status sshd
sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'
```

Konfiguration validieren (ohne Eingriff):

```bash
sudo docker compose -f /opt/coder/docker-compose.yml config --quiet
```

Wöchentlicher TLS-Stand (liefert Zahl + `logger`-Eintrag):

```bash
sudo /opt/coder/check-tls.sh      # Log: /var/log/coder-tls.log
```

Alles davon zusammen in einem Lauf: `sudo ./setup-coder.sh` – Schritt 10
meldet jeden Punkt einzeln als `[OK]`/`[WARNUNG]`/`[FEHLER]`. Zusätzlich
meldet Schritt 10 den Nutzerstand (B2): solange kein menschliches Konto
existiert, weist er darauf hin, dass der erste Anmeldende Owner wird.

### Empfohlene Routine

| Rhythmus | Was | Befehl/Ort |
|---|---|---|
| täglich | Backup vorhanden und aktuell | `ls -t /opt/coder/backups/coder_*.sql.gz \| head -n1` |
| täglich | Backup-Metrik aktuell (Prometheus `BackupStale`) | `cat /opt/coder/node-textfile/coder_backup.prom` |
| täglich | Boot-Gate nach Reboot gelesen | `grep 'BOOT-GATE' /var/log/coder-boot.log \| tail` |
| wöchentlich | TLS-Ausstellungen | `sudo /opt/coder/check-tls.sh` |
| wöchentlich | fail2ban-Bans, ufw-Status | `sudo fail2ban-client status sshd`, `sudo ufw status` |
| vor Coder-Update | Backup grün | `gzip -t $(ls -t /opt/coder/backups/coder_*.sql.gz \| head -n1)` |
| pro Semester | Restore-Probe auf Test-VM | [RESTORE.md](RESTORE.md) |

## 6. Logs

| Log | Inhalt | Rotation |
|---|---|---|
| `/var/log/coder-backup.log` | Ausgabe des Backup-Crons | weekly, 8, compress |
| `/var/log/coder-boot.log` | Boot-Gate je Reboot (`BOOT-GATE GRÜN/ROT`) | **keine** |
| `/var/log/coder-tls.log` | TLS-Ausstellungen je Woche | **keine** |
| `/var/log/coder-ssh-downgrade-*.before.log` / `.after.log` | ufw-Before/After bei Re-Run mit restriktiver SSH-Regel | keine |
| Container-Logs | `json-file`, 10 MB × 3 pro Container | intern begrenzt |
| `journalctl -u fail2ban`, `-u ssh`, `-u cron`, `-u unattended-upgrades` | Systemdienste | Debian-Defaults |

```bash
sudo docker logs coder --tail=100
sudo docker logs coder-caddy --tail=100
sudo journalctl -u fail2ban -n 50 --no-pager
logger -t coder-backup -p user.info "..."     # wie die Skripte selbst loggen
```

Hinweis: Die Boot- und TLS-Logs haben keine Rotation (nur
`coder-backup.log` ist eingerichtet). Bei langer Laufzeit wachsen sie –
Aufwachsen begrenzen, bevor es die Platte trifft, ist eine offene
Maßnahme (siehe [CHANGELOG.md](CHANGELOG.md), offene Punkte).

### Monitoring und Grafana

- Prometheus und node-exporter laufen nur auf `127.0.0.1` (9090/9100),
  Grafana nur auf `127.0.0.1:3001`. Von außen ist nichts davon erreichbar.
- Zugriff per SSH-Tunnel:

  ```bash
  ssh -L 3001:127.0.0.1:3001 <user>@<server>
  # danach im Browser: http://127.0.0.1:3001  (Benutzer: admin)
  ```

- Das Grafana-Admin-Passwort gilt nur beim allerersten Start; danach
  `sudo /opt/coder/reset-passwords.sh`.
- Die Datasource `Prometheus` wird beim Setup automatisch provisioniert
  (`/opt/coder/grafana/provisioning/datasources/`) – kein Eintragen im UI.
- **Fünf Alarmregeln** liegen in Prometheus (`/opt/coder/rules/`):
  Coder-Target down, Root-Partition <10 % frei, letztes Backup älter als
  25 Stunden, TLS-Ausstellungen >20/7 Tage und ein fehlender oder mehr als
  8 Tage alter TLS-Check. Sie sind einsehbar unter
  `http://127.0.0.1:9090/alerts` bzw. in Grafana.
- Es gibt **keinen Benachrichtigungskanal** (kein Alertmanager, keine
  Mail/Telegram/Webhook): die Regeln klingeln nirgends, sie zeigen nur
  etwas, wer hinsieht. Metriken sind sichtbar, wer sie ansieht.

## 7. Wartung

Ein erneuter Lauf von `setup-coder.sh` ist nicht Teil des gemeinsamen
Laufzeit-Locks. Er darf nicht gleichzeitig mit Backup, Update, Passwortwechsel
oder Reset laufen.

### Update (bewusst manuell)

```bash
sudo /opt/coder/update.sh
```

Ablauf im Skript: Pre-Backup (`backup.sh`) → `docker compose pull`
(max. 3 Versuche) → `docker compose up -d --remove-orphans` → Health-Gate
(alle Container laufen, Postgres healthy, `/healthz` 200 über Caddy-TLS).
Bei rotem Gate: Exit ≠ 0, Stack prüfen, ggf. zurückrollen.

- **Kein Auto-Prune**: alte Images bleiben als Rollback-Basis erhalten,
  Aufräumen nur manuell (`sudo docker image prune`) und bewusst.
- Exakt gepinnte Images (Coder, Prometheus, Grafana, node-exporter) kann man
  durch Setzen des Pins in `setup-coder.sh` + erneuten Setup-Lauf ändern oder
  zurückrollen. `CADDY_VERSION` (Minor) und `postgres:15-alpine` holen beim
  `pull` ggf. ein neueres Bild hinter demselben Tag.
- `update.sh` zieht die aktuellen Image-Inhalte der generierten Compose-Tags.
  Neue Releases kommen dabei nur für die beweglichen Tags `caddy:2.10` und
  `postgres:15-alpine` automatisch an. Für die exakt gepinnten Images muss
  der Pin in `setup-coder.sh` geändert und Setup erneut ausgeführt werden.
- Docker Engine und Compose-Plugin werden weder durch `unattended-upgrades`
  noch durch `update.sh` aktualisiert. Dafür in einem abgestimmten
  Wartungsfenster manuell ausführen:

  ```bash
  sudo apt-get update
  sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ```

  Ein Upgrade kann `dockerd` neu starten und alle Workspace-Container
  unterbrechen. Vorher Unterrichtsende abstimmen und anschließend prüfen,
  dass alle Container wieder gesund sind.
- Coder-Major-Updates: Schema-Migrationen können Downgrades irreversibel
  machen. Nur mit verifiziertem Dump, einzeln fahren – nie zusammen mit
  einem DB-Update.

### Passwörter rotieren

```bash
sudo /opt/coder/reset-passwords.sh
```

Reihenfolge im Skript: Vorab-Backup → `.env`-Sicherung (eine Generation)
→ `ALTER USER` in Postgres → Grafana-Reset → atomarer `.env`-Tausch →
`up -d --no-deps coder`. Bei Abbruch nennt das Skript die Phase und den
Weg zurück; erneutes Ausführen heilt in der Regel.

**C2 – Folge des geänderten `.env`:** Coder läuft sofort mit dem neuen
Passwort weiter, **Postgres und Grafana aber erst, wenn sie neu erstellt
werden**, denn der Env-Hash von `docker compose up -d` ändert sich. Beim
nächsten vollständigen `docker compose up -d` werden diese beiden Container
**neu erstellt** – kurzfristige Unterbrechung von DB und Grafana einplanen
(kein Datenverlust, Volumes bleiben). Wer das nicht will, führt die Rotation
bewusst kurz vor einem Wartungsfenster aus.

### Reboot

- Automatisch bei Kernel-Updates um 03:00 Uhr
  (`/etc/apt/apt.conf.d/52-coder-reboot`) – **Fenster ist nicht mit dem
  Schulbetrieb abgestimmt**; laufende Workspaces/Sessions werden
  abgerissen. Die Zeitzone steht auf `Europe/Berlin` (Setup setzt sie
  idempotent, C1), damit 03:00 wirklich 03:00 MEZ/MESZ sind.
- Nach jedem Reboot schreibt `boot-check.sh` (per `@reboot`) nach
  `/var/log/coder-boot.log` und ins Journal: Container-Status, Postgres
  `healthy` (bis 120 s), alle Container (weitere bis 120 s) und `/healthz` 200
  (TLS-Smoke bis zu 10 Minuten). Gesamtlaufzeit im Fehlerfall knapp 14 Minuten.
  Das Gate ist **lesend** – es ändert nichts am Stack, es meldet nur.
- Manuell: `sudo reboot`, danach den Log prüfen.

### Komplett-Reset

```bash
sudo /opt/coder/reset-coder.sh            # mit Backup + Bestätigung "RESET"
sudo /opt/coder/reset-coder.sh --force    # nur, wenn das Backup fehlschlägt
```

Was passiert: Inventar fremder Container (lesend) → letztes Backup →
Bestätigung → Prüfung, ob fremde Container ein zu löschendes Volume halten
(Abbruch vor `down`, nichts angefasst) → `docker compose down
--remove-orphans` → Löschen der Volumes `postgres_data`, `grafana_data`,
`prometheus_data` → `.env` entfernen.

Bleiben erhalten: Backups, Caddy-Zertifikate (`caddy_data`/`caddy_config`),
alle Einstellungen außerhalb des Coder-Stacks. Danach:
`sudo ./setup-coder.sh`.

`--force` ist kein Komfort-Flag: er setzt den Reset auch ohne
funktionierendes Backup durch und verlangt eine zweite Eingabe
`RESET-OHNE-BACKUP`. Ohne Terminal (Pipe/CI) wird der Reset ohne
`--force` verweigert. **Nie auf Produktion üben.**

### Drift-Warnung (generierte Dateien)

Das Setup hält sha256 der 16 generierten Dateien in
`/opt/coder/.generated-hashes`. Ändert sich eine Datei durch Handarbeit,
kommt beim nächsten Setup-Lauf:

```
[WARNUNG] Drift in <label> (<pfad>): weicht von letzter Setup-Generation ab –
wird deterministisch regeneriert, Hand-Anpassung geht verloren
```

Verhalten: der Lauf läuft weiter (kein interaktiver Stopp), die Datei
wird neu geschrieben und der Hash aktualisiert. Gewollte Anpassungen
(Caddy-Snippets, Logrotate-Zeiten, fail2ban-Jails, Cron-Zeiten) daher
im Repository bzw. in `setup-coder.sh` ändern und das Setup erneut
ausführen – nicht dauerhaft auf dem Server korrigieren.

Prüfen, ob der Hashstore stimmt: `sudo cat /opt/coder/.generated-hashes`.

## 8. Backup

| Eigenschaft | Wert |
|---|---|
| Was | `pg_dump` der Datenbank `coder`, gzip-komprimiert |
| Wann | täglich 01:00 Uhr (`/etc/cron.d/coder-backup`), manuell `sudo /opt/coder/backup.sh` |
| Wo | `/opt/coder/backups/coder_<YYYY-MM-DD_HHMMSS>.sql.gz` (700/Verzeichnis, 600/Datei) |
| Verifikation | `gzip -t` (hart), SQL-Header (hart), Größe < 512 B (Warnung), halbiert gegenüber Vorgänger (Warnung) |
| Rotation | neueste 14 Dateien, Mindestbestand eingebaut |
| Parallelität | gemeinsamer Wartungs-`flock` plus Backup-`flock`; parallele Läufe warten bis zu 300 s. Bei weiter belegtem Lock Exit 75, ohne neues Backup |
| Mindestplatz | 500 MB frei, sonst Abbruch ohne Datei |
| Offsite | **nicht eingerichtet** |
| Metrik | nach jedem Erfolg `node-textfile/coder_backup.prom` (644, atomar) → `coder_backup_last_success_timestamp_seconds`; Fehlschlag des Metrik-Schreibens verwandelt ein gutes Backup nicht in einen Cron-Fehler |

Zusätzlich ziehen `update.sh` und `reset-passwords.sh` vor dem Eingriff
ein Backup; `reset-coder.sh` ebenfalls (Abbruch ohne Backup, außer
`--force`).

Backup, Update, Passwortwechsel und Reset teilen `/opt/coder/.maintenance.lock`.
Dadurch kann ein Backup nicht mitten in einer Passwortrotation oder einem
Reset laufen. Ein paralleler Lauf wartet bis zu fünf Minuten auf den Lock und
bricht danach mit Exit 75 ab. `reset-coder.sh` hält ihn auch während der
Bestätigungsabfrage; bei langem Warten auf den Betreiber können andere
Wartungsbefehle deshalb nach fünf Minuten abbrechen und später erneut gestartet
werden.

Ein grünes Backup ist **kein** Restore-Nachweis. Verifikation und
Ablauf: [RESTORE.md](RESTORE.md).

```bash
# Zustand prüfen (Metrik ist der Prometheus-Wert für BackupStale)
ls -lt /opt/coder/backups/ | head
cat /opt/coder/node-textfile/coder_backup.prom
curl -s http://127.0.0.1:9100/metrics | grep coder_backup
gzip -t "$(ls -t /opt/coder/backups/coder_*.sql.gz | head -n1)" && echo "gzip OK"
cat /etc/cron.d/coder-backup
systemctl is-active cron
tail -20 /var/log/coder-backup.log
```

## 9. Automatische Aufgaben

| Aufgabe | Wann | Datei/Quelle |
|---|---|---|
| Datenbank-Backup | täglich 01:00 | `/etc/cron.d/coder-backup` |
| TLS-Ausstellungen zählen | Montag 06:30 | `/etc/cron.d/coder-tlscheck` |
| Boot-Gate | `@reboot` | `/etc/cron.d/coder-bootcheck` |
| Log-Rotation Backup-Log | wöchentlich | `/etc/logrotate.d/coder-backup` |
| Debian-Paketupdates + Reboot 03:00 (ohne Docker Engine) | Debian-Default | unattended-upgrades, `52-coder-reboot` |
| Coder-Update | **nie automatisch** | `update.sh` wird manuell aufgerufen |
| Docker-Engine-/Compose-Update | **nie automatisch** | manuelles APT-Upgrade in einem Wartungsfenster |

Prüfen: `systemctl is-active cron`, `ls -l /etc/cron.d/`,
`sudo systemctl status unattended-upgrades --no-pager`.

## 10. Tests

```bash
bash -n setup-coder.sh ssh-harden.sh
shellcheck -S warning setup-coder.sh ssh-harden.sh
for f in tests/*.sh; do bash "$f"; done
```

Stand nach Prüfung der angehängten Punkte am 2026-09-29: 10/10 Skripte
Exit 0, 311 `PASS`, 0 `FAIL`; ShellCheck `-S warning` meldet einen
vorhandenen Befund (SC2034). `t-090` wurde wegen Loopback-Listener außerhalb
der Sandbox ausgeführt. Der Caddy-Parsertest war mangels lokalem Image
übersprungen; kein vollständiger Setup-/VM-Lauf.

Die Skripte arbeiten mit Fakes/Fixtures in `/tmp` – sie brauchen weder
Root noch Docker und berühren keine Produktion. Sie belegen das Verhalten
einzelner Codestellen, **nicht** den Gesamtlauf. VM-Pflichtige Prüfungen
stehen in [README.md](README.md), Abschnitt „Nur auf einer Test-VM bzw. in
Produktion zu verifizieren".

## 11. Inbetriebnahme am Zielserver: wer macht was

Domain bleibt **`ghse-unterricht.de`** (gesamt mit anderen Schuldiensten
geteilt). Der Zielserver ist ein Schulserver, per SSH nur aus dem Schulnetz
erreichbar. Passwort-Login bleibt bei der ersten Inbetriebnahme bewusst aktiv.
Bis DNS und Web-Portweiterleitung stehen, startet der
Stack trotzdem – Caddy holt das Zertifikat dann nach (Skript ist idempotent,
einfach erneut ausführen).

### Netzwerkadmin

| # | Was | Warum |
|---|---|---|
| 1 | A-Record `coder.ghse-unterricht.de` → öffentliche IP des Ziel-**Servers** | sonst keine Weboberfläche |
| 2 | A-Record Wildcard `*.coder.ghse-unterricht.de` → gleiche IP | **Pflicht**: Coder vergibt Workspace-URLs im Format `<port>--<agent>--<workspace>--<user>.coder.ghse-unterricht.de`; ohne Wildcard laufen nur die Oberfläche und keine Workspace-App/Port-Forwarding |
| 3 | Firewall/Router: **80/tcp und 443/tcp 1:1 an den Server** weiterleiten (443/udp optional für HTTP/3) | ACME braucht 80 (http-01) und 443 (tls-alpn-01); ohne beides kein Zertifikat |
| 4 | Falls ein Proxy/Reverse-Proxy bestehen bleibt: `/.well-known/acme-challenge/` durchreichen **und** HTTPS als TLS-Passthrough (SNI) | ein Proxy, der selbst antwortet (z. B. mit 404), blockiert die Zertifikatsausstellung dauerhaft |
| 5 | SSH/22 bleibt ausschließlich aus dem Schulnetz erreichbar; keine öffentliche Weiterleitung | Passwortzugang ist für die erste Inbetriebnahme vorgesehen; ufw + fail2ban begrenzen Fehlversuche zusätzlich |

**Alternative, falls 80/443 nicht 1:1 erreichbar sind (DNS-01, B4b):**
Ein Zertifikat ohne eingehende 80/443 geht nur über den DNS-01-Challenge
(`/opt/coder/Caddyfile` müsste den `_acme-challenge.`-CNAME tragen und der
`caddy`-Image bräuchte ein DNS-Plugin, das das Standardimage **nicht**
enthält). Das braucht Zonen-Zugang beim DNS-Provider – erst anfragen, wenn
Zeile 3 hakt; bis dahin ist http-01/tls-alpn-01 der eingeschlagene Weg.

### Betreiber (Auftraggeber)

1. **Vorab:** `./setup-coder.sh` am Zielserver ausführen (erster Lauf legt
   Stack, Firewall, Backups an; Warnung zu TLS ist bis zu Punkt 3 normal).
2. **DNS/Weiterleitung abwarten** (Schritt 1–4 oben).
3. **Zweiter Lauf:** `./setup-coder.sh` erneut ausführen – idempotent,
   erzeugt dann das Zertifikat bzw. meldet weiterhin WARN, falls es fehlt.
4. **Erstkonto anlegen – SOFORT, bevor die URL irgendjemand weitergegeben
   wird:** Wer sich als Erster anmeldet, wird automatisch Owner. Entweder
   beim ersten Lauf über die drei Variablen (nur so sieht das Skript sie,
   `sudo` leitet fremde Variablen nicht durch):

   ```bash
   sudo env CODER_FIRST_USER_EMAIL='admin@ghse-unterricht.de' \
            CODER_FIRST_USER_USERNAME='admin' \
            CODER_FIRST_USER_PASSWORD='<starkes, eigenes Passwort>' \
            CODER_FIRST_USER_FULL_NAME='Schulverwaltung' \
            ./setup-coder.sh
   ```

   oder unmittelbar danach selbst anmelden. Danach ein **zweites**
   Owner-Konto anlegen, damit die Administration nicht an einem Zugang
   hängt (siehe [SECURITY.md](SECURITY.md)).
5. **Abnahme mit den Checks aus [Abschnitt 5](#5-checks-gesundheit-prüfen):**

   ```bash
   getent hosts coder.ghse-unterricht.de
   curl -s -o /dev/null -w '%{http_code}\n' https://coder.ghse-unterricht.de/healthz   # muss 200 sein
   docker logs coder-caddy --tail=50 | grep -i 'obtaining certificate\|error'          # muss leer bleiben
   sudo docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=8080--main--ws--user.coder.ghse-unterricht.de'   # ok
   ```

6. **Danach:** `ssh-harden.sh` nur mit getestetem Key-Login und Zweit-Zugang
   ausführen (siehe [SECURITY.md](SECURITY.md)), `RESTORE.md`-Restore-Probe
   einmalig durchspielen.

Nicht Teil der Inbetriebnahme, aber betriebsrelevant: die Wildcard-Zertifikate
laufen über On-Demand-TLS mit dem gemeinsamen Let's-Encrypt-Budget der Domain
(Erkennung: wöchentliches `check-tls.sh`; Details
[TROUBLESHOOTING.md](TROUBLESHOOTING.md), Abschnitte B1–B3).
