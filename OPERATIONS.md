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
| Repository | Quelltext: `setup-coder.sh`, `setup.conf.example`, `scripts/`, `RESTORE.md`, `templates/allowlist.md`, `tests/`, `ai-review/` |
| `/opt/coder/` auf dem Server | Alles Erzeugte: Stack-Konfiguration, `.env`, Wartungsskripte, Backups, Hashstore |
| `/etc/cron.d/`, `/etc/logrotate.d/`, `/etc/fail2ban/`, `/etc/apt/apt.conf.d/` | vom Setup erzeugte Systemdateien |

Ein `git pull` allein verändert **nichts** am laufenden System. Änderungen
an generierten Dateien kommen erst durch einen erneuten Lauf von
`setup-coder.sh` an. Verwaltete Dateien werden in ihrem Zielverzeichnis
atomar ersetzt; erkannte Hand-Änderungen erscheinen als WARN, bevor die
Setup-Version sie ersetzt (siehe Abschnitt 7).

## 2. Vom Setup erzeugte Dateien

| Pfad | Zweck | Hashstore |
|---|---|---|
| `/opt/coder/.env` | Secrets: `POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` (600, root) | nein (bewusst) |
| `/opt/coder/docker-compose.yml` | Stack-Definition, Logs, Ports, Volumes | ja |
| `/opt/coder/caddy/Caddyfile` | TLS + Reverse Proxy, Apex + Wildcard (Verzeichnis `caddy/` wird vollständig gemountet) | ja |
| `/opt/coder/prometheus/prometheus.yml` | Scrape-Jobs `coder`, `node`, Einbindung `rule_files` (Verzeichnis `prometheus/` wird vollständig gemountet) | ja |
| `/opt/coder/prometheus/rules/coder-alerts.yml` | fünf Alarmregeln (Target down, Platte <10 %, Backup >25 h, TLS-Ausstellungen/7 d >20, TLS-Check veraltet) | nein |
| `/opt/coder/grafana/provisioning/datasources/prometheus.yml` | Datasource `Prometheus` wird automatisch angelegt | nein |
| `/opt/coder/node-textfile/coder_backup.prom` | Zeitstempel des letzten erfolgreichen Backups (vom Setup angelegt, vom Lauf beschrieben) | nein |
| `/opt/coder/node-textfile/coder_tls.prom` | TLS-Ausstellungen der letzten 7 Tage (aus den Zertifikatsdateien im `caddy_data`-Volume) und Zeitstempel des letzten erfolgreichen Checks | nein |
| `/opt/coder/versions.env` | wirksam gewesene Versionen der fünf Images (644) | nein |
| `/opt/coder/backup.sh` | tägliche Datenbank-Sicherung | ja |
| `/opt/coder/.maintenance.lock` | gemeinsamer Laufzeit-Lock für Setup, Backup und Reset (600, root) | nein |
| `/opt/coder/reset-coder.sh` | Komplett-Reset des Coder-Stacks | ja |
| `/opt/coder/check-tls.sh` | zählt Let's-Encrypt-Ausstellungen (7 Tage) | ja |
| `/opt/coder/RESTORE.md` | Runbook-Kopie (Quelle liegt im Repository) | nein |
| `/opt/coder/.generated-hashes` | sha256 der 11 drift-überwachten Dateien (600, root) | – |
| `/etc/cron.d/coder-backup` | Cron: täglich 01:00 | ja |
| `/etc/cron.d/coder-tlscheck` | Cron: Montag 06:30 | ja |
| `/etc/logrotate.d/coder-backup` | Rotation `/var/log/coder-backup.log` | ja |
| `/etc/logrotate.d/coder-logs` | Rotation `/var/log/coder-tls.log` (wöchentlich, 8×) | ja |
| `/etc/fail2ban/jail.d/10-coder-sshd.local` | Drop-In: Jail `sshd` (backend systemd) | ja |
| `/etc/apt/apt.conf.d/52-coder-reboot` | automatischer Reboot 03:00 | ja |
| `/etc/docker/daemon.json` | Log-Limit json-file 10 MB × 3 (nur beim Fehlen geschrieben) | nein |
| `/etc/apt/apt.conf.d/20auto-upgrades` | via debconf von unattended-upgrades | nein |
| `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.gpg` | Docker-apt-Repo (Fingerprint geprüft) | nein |

Die Konfigurationsdateien für Caddy und Prometheus stehen absichtlich in
eigenen Unterverzeichnissen (`caddy/`, `prometheus/`): Docker bindet eine
**Datei** beim Containerstart an deren Inode. Das Setup ersetzt sie atomar per
Temp-Datei und `mv` – über einen Einzeldatei-Mount sähe der laufende Container
bis zum nächsten Recreate die alte Fassung, während Hash- und Preflight-Prüfen
die neue bestätigen. Verzeichnis-Mounts zeigen auf den jeweils aktuellen Inode.

Nicht im Repository, nur auf dem Server: alle Backups und Logs.

## 3. Konfigurationsvariablen

Defaults stehen im Kopf von `setup-coder.sh`. Überschreibungen laufen in
dieser Reihenfolge (Vorrang von links):

1. Umgebungsvariable beim Aufruf – gehört hinter das sudo (`sudo` leitet
   fremde Variablen nicht durch):
   `sudo env DOMAIN_CODER=… ACME_EMAIL=… ./setup-coder.sh`
2. `setup.conf` neben `setup-coder.sh` (Vorlage: `setup.conf.example`,
   gitignored, nie ins Repository): Zeilen `SCHLÜSSEL=Wert` für
   `DOMAIN_CODER`, `ACME_EMAIL`, `ACME_CA` (eigener ACME-Endpunkt, z. B.
   Let's-Encrypt-Staging; leer = Caddys Standard) und `FAIL2BAN_IGNORE_IP`
3. der Default im Skript

Versions-Pins (`CODER_VERSION`, `CADDY_VERSION`, `PROMETHEUS_VERSION`,
`GRAFANA_VERSION`, `NODE_EXPORTER_VERSION`) und `CODER_ALLOW_DOWNGRADE`
(nur `yes`, erlaubt ein bewusstes Zurücksetzen einer Image-Version) laufen
weiterhin nur über Umgebungsvariablen. Sonstiges und Pin-Regeln:
[README.md](README.md), Abschnitt „Wichtigste Konfiguration".

**Secrets-Verfahren**

- Erstpasswörter werden beim ersten Lauf erzeugt und in
  `/opt/coder/.env` (600, root:root) gespeichert. Die Ausgabe zeigt nur den
  gezielten Abrufbefehl für das Grafana-Passwort, nicht den Secret-Wert.
- Eine unvollständige `.env` wird nie still neu gewürfelt – das Setup
  bricht ab und nennt die Reparatur.
- Passwörter müssen hex sein (`[0-9a-f]`); sonst bricht das Setup ab und
  nennt die Reparatur (TROUBLESHOOTING.md A4).
- Rotation (Grafana-Admin): kein Skript mehr, manuell nach Abschnitt 7
  „Passwörter rotieren". Passwort bei Bedarf gezielt abrufen:

  `sudo sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /opt/coder/.env`
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
startet Docker die Container selbst; den Wiederanlauf prüft man danach per
`docker ps` und `/healthz` (Abschnitt 5).

Das Setup validiert Compose, Caddyfile und Prometheus-Konfiguration samt
Regeln bereits beim Schreiben (Temp-Datei validieren, dann atomar ersetzen);
bei einem Fehler bricht der Lauf ab und die Live-Datei bleibt unangetastet.
Die Images zieht es in Schritt 2 (`docker compose pull`), der Stack startet
in Schritt 3. Diese Prüfung validiert die Dateien, aber stellt keine
TLS-Zertifikate aus.

Caddy-Hinweis: Docker-Compose erkennt Änderungen an der eingebundenen
`Caddyfile` nicht automatisch. Das Setup lädt die Konfiguration nur neu,
wenn sich die Datei geändert hat (validiert wurde bereits beim Schreiben)
– ohne `restart`, damit bestehende Verbindungen nicht abreißen. Bei eigener
Änderung also zuerst prüfen, dann neu laden:

```bash
sudo docker exec coder-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo docker exec coder-caddy caddy reload    --config /etc/caddy/Caddyfile --adapter caddyfile
```

Prometheus lädt `prometheus.yml` und Alarmregeln auf SIGHUP neu; das Setup
sendet das Signal bei jedem Lauf, solange Prometheus läuft (Reload ist
No-Op bei unveränderter Datei). Manuell:
`sudo docker kill -s HUP coder-prometheus`. Grafana liest seine Datasource-
Provisioning-Datei beim Start; das Setup startet Grafana bei einer Änderung
dieser Datei neu (`sudo docker restart coder-grafana`).

## 5. Checks (Gesundheit prüfen)

Schritt 8 des Setups meldet `[OK]`/`[WARNUNG]`/`[FEHLER]` für: die sechs
Container, den Docker-Socket-Zugriff (GroupAdd/docker-GID),
`https://<domain>/healthz` (HTTP 200) und den Wildcard-DNS. Einen
belegten Port meldet `docker compose up` mit klarer Portangabe (Diagnose:
[TROUBLESHOOTING.md](TROUBLESHOOTING.md)), `pg_isready` läuft als
Compose-Healthcheck.
Alles davon einzeln reproduzierbar – plus die Nachweise, die das Setup
nicht selbst abfragt:

Nach dem ersten Workspace zusätzlich im Terminal dieses Workspaces die
öffentliche Coder-URL prüfen. Ein Test vom Host belegt nicht, dass
Workspace-DNS, Egress und TLS-Zugriff funktionieren:

```bash
curl --fail --show-error --max-time 15 \
  https://coder.ghse-unterricht.de/healthz
```

Danach eine echte Workspace-App über ihre von Coder erzeugte
`*.coder.ghse-unterricht.de`-URL im Browser öffnen. Das prüft zusätzlich
Wildcard-DNS und On-Demand-TLS; ein erfolgreicher `/healthz`-Aufruf allein
belegt diese App-Route nicht.

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

# TLS-Ausstellungen der letzten 7 Tage (aus den Zertifikatsdateien im
# caddy_data-Volume, kein Container-Logfenster nötig)
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

Alles davon zusammen in einem Lauf: `sudo ./setup-coder.sh` – Schritt 8
meldet jeden Punkt einzeln als `[OK]`/`[WARNUNG]`/`[FEHLER]`. Zusätzlich
meldet Schritt 8 den Nutzerstand (B2): solange kein menschliches Konto
existiert, weist er darauf hin, dass der erste Anmeldende Owner wird.

### Empfohlene Routine

| Rhythmus | Was | Befehl/Ort |
|---|---|---|
| täglich | Backup vorhanden und aktuell | `ls -t /opt/coder/backups/coder_*.sql.gz \| head -n1` |
| täglich | Backup-Metrik aktuell (Prometheus `BackupStale`) | `cat /opt/coder/node-textfile/coder_backup.prom` |
| nach Reboot | Container wieder da und gesund | `sudo docker ps`, Postgres `healthy`, `/healthz` 200 |
| wöchentlich | TLS-Ausstellungen | `sudo /opt/coder/check-tls.sh` |
| wöchentlich | fail2ban-Bans, ufw-Status | `sudo fail2ban-client status sshd`, `sudo ufw status` |
| vor Coder-Update | Backup grün | `gzip -t $(ls -t /opt/coder/backups/coder_*.sql.gz \| head -n1)` |
| pro Semester | Restore-Probe auf Test-VM | [RESTORE.md](RESTORE.md) |

## 6. Logs

| Log | Inhalt | Rotation |
|---|---|---|
| `/var/log/coder-backup.log` | Ausgabe des Backup-Crons | weekly, 8, compress |
| `/var/log/coder-tls.log` | TLS-Ausstellungen je Woche | weekly, 8, compress |
| Container-Logs | `json-file`, 10 MB × 3 pro Container | intern begrenzt |
| `journalctl -u fail2ban`, `-u ssh`, `-u cron`, `-u unattended-upgrades` | Systemdienste | Debian-Defaults |

```bash
sudo docker logs coder --tail=100
sudo docker logs coder-caddy --tail=100
sudo journalctl -u fail2ban -n 50 --no-pager
logger -t coder-backup -p user.info "..."     # wie die Skripte selbst loggen
```

Die beiden Setup-Logs werden über `/etc/logrotate.d/coder-backup` und
`/etc/logrotate.d/coder-logs` wöchentlich rotiert; acht komprimierte
Generationen bleiben erhalten.

### Monitoring und Grafana

- Prometheus und node-exporter laufen nur auf `127.0.0.1` (9090/9100),
  Grafana nur auf `127.0.0.1:3001`. Von außen ist nichts davon erreichbar.
- Zugriff per SSH-Tunnel:

  ```bash
  ssh -L 3001:127.0.0.1:3001 <user>@<server>
  # danach im Browser: http://127.0.0.1:3001  (Benutzer: admin)
  ```

- Das Grafana-Admin-Passwort gilt nur beim allerersten Start; danach nur
  manuell drehen (Abschnitt 7 „Passwörter rotieren"). Bei Bedarf aus der
  geschützten `.env` abrufen:
  `sudo sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /opt/coder/.env`.
- Die Datasource `Prometheus` wird beim Setup automatisch provisioniert
  (`/opt/coder/grafana/provisioning/datasources/`) – kein Eintragen im UI.
- **Fünf Alarmregeln** liegen in Prometheus (`/opt/coder/prometheus/rules/`):
  Coder-Target down, Root-Partition <10 % frei, letztes Backup älter als
  25 Stunden, TLS-Ausstellungen >20/7 Tage (Let's-Encrypt-Limit 50/Woche)
  sowie ein fehlender oder mehr als 8 Tage alter TLS-Check. Sie sind
  einsehbar unter `http://127.0.0.1:9090/alerts` bzw. in Grafana.
- Es gibt **keinen Benachrichtigungskanal** (kein Alertmanager, keine
  Mail/Telegram/Webhook): die Regeln klingeln nirgends, sie zeigen nur
  etwas, wer hinsieht. Metriken sind sichtbar, wer sie ansieht.

## 7. Wartung

Ein erneuter Lauf von `setup-coder.sh` nimmt denselben Laufzeit-Lock wie
Backup und Reset. Die anderen Wartungsskripte warten bis zu 300 Sekunden;
danach brechen sie ohne Änderung mit Exit 75 ab.

### Update (bewusst manuell)

Update = gewünschte Pin-Änderung in `setup-coder.sh` (optional) und
erneuter Lauf aus dem aktuellen Repo-Stand:

```bash
cd <repo> && git log -1 --oneline    # Stand notieren
sudo ./setup-coder.sh
```

Ablauf: Pre-Upgrade-Backup, sobald sich Bilder ändern → `docker compose
pull` (max. 3 Versuche) → `docker compose up -d` → Abschlusscheck
(alle Container laufen, Postgres healthy, `/healthz` 200 über Caddy-TLS).
Bei rotem Abschlusscheck: Exit ≠ 0, Stack prüfen, ggf. zurückrollen.

- **Kein Auto-Prune**: alte Images bleiben als Rollback-Basis erhalten,
  Aufräumen nur manuell (`sudo docker image prune`) und bewusst.
- Exakt gepinnte Images (Coder, Prometheus, Grafana, node-exporter) kann man
  durch Setzen des Pins in `setup-coder.sh` + erneuten Setup-Lauf ändern oder
  zurückrollen. `CADDY_VERSION` (Minor) und `postgres:18-alpine` holen beim
  `pull` ggf. ein neueres Bild hinter demselben Tag.
- PostgreSQL läuft auf `postgres:18-alpine` (Major-Tag, holt 18.x-Patches
  über `pull`; aktuell 18.6, Stand 2026-09-30). Achtung, geprüft am
  Test-Host: ab Major 18 mountet das Image das Volume unter
  `/var/lib/postgresql` (Daten in `<major>/` darin), nicht mehr unter
  `/var/lib/postgresql/data` – das 18er-Image startet sonst absichtlich
  nicht. Compose und Image wandern deshalb immer zusammen (beides erzeugt
  `setup-coder.sh` neu). Der Wechsel von 15 geschah
  vor der Inbetriebnahme per Dump/Restore mit Datenprobe (siehe
  [RESTORE.md](RESTORE.md)). Ein weiterer Major-Wechsel ist bewusst kein
  `pull`: Volume bleibt, Dump/Restore in einem Wartungsfenster, danach
  Datenprobe. Upstream-Support für 18 endet im November 2030.
  [PostgreSQL-Versionierung](https://www.postgresql.org/support/versioning/)
- Docker Engine und Compose-Plugin werden weder durch `unattended-upgrades`
  noch durch das Setup aktualisiert. Dafür in einem abgestimmten
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

### Passwörter rotieren (Grafana-Admin)

Kein Rotationsskript mehr (B7); manuell in dieser Reihenfolge:

1. Backup ziehen: `sudo /opt/coder/backup.sh`
2. Neues Passwort erzeugen und per stdin in Grafana setzen (niemals als
   Argument – sonst steht es kurz in `ps aux`):

   ```bash
   read -rs -p 'Neues Grafana-Passwort: ' NEU; echo
   printf '%s\n' "$NEU" | sudo docker exec -i coder-grafana \
     grafana cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin
   ```

3. Dasselbe Einmal-Passwort in `/opt/coder/.env` unter
   `GRAFANA_ADMIN_PASSWORD=` eintragen (600 bleibt; atomar über Temp-Datei
   und `mv`, nicht `sed -i`) und im Passwort-Manager sichern.
   `GF_SECURITY_ADMIN_PASSWORD` wirkt nur beim allerersten Grafana-Start –
   die `.env` ist die abrufbare Kopie:
   `sudo sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /opt/coder/.env`
4. `POSTGRES_PASSWORD` bleibt unverändert (Nicht-Hex-Reparatur:
   TROUBLESHOOTING.md A4).

**C2 – Folge des geänderten `.env`:** Beim nächsten vollständigen
`docker compose up -d` wird **Grafana** neu erstellt (Env-Hash) – kurzer
Neustart, Volumes/Dashboards bleiben, kurzfristig kein Login möglich.
Postgres und Coder sind nicht betroffen; wer das Fenster steuern will,
plant den nächsten Stack-Lauf (Update) entsprechend.

### Reboot

- Automatisch bei Kernel-Updates um 03:00 Uhr
  (`/etc/apt/apt.conf.d/52-coder-reboot`) – **Fenster ist nicht mit dem
  Schulbetrieb abgestimmt**; laufende Workspaces/Sessions werden
  abgerissen. Die Zeitzone steht auf `Europe/Berlin` (Setup setzt sie
  idempotent, C1), damit 03:00 wirklich 03:00 MEZ/MESZ sind.
- Nach einem Reboot startet Docker die Container selbst; danach prüfen:
  `sudo docker ps`, Postgres `healthy`
  (`sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres`) und
  `curl -s -o /dev/null -w '%{http_code}\n' https://coder.ghse-unterricht.de/healthz`
  (muss 200 sein). Ein lesendes Boot-Gate (`boot-check.sh`) gibt es nicht
  mehr (B8).
- Manuell: `sudo reboot`, danach die drei Checks oben ausführen.

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

Zusätzlich zieht ein Setup-Lauf vor einem Upgrade (geänderte Bilder) ein
Backup; `reset-coder.sh` ebenfalls (Abbruch ohne Backup, außer `--force`).

Backup, Setup-Läufe und Reset teilen `/opt/coder/.maintenance.lock`.
Dadurch kann ein Backup nicht mitten in einem Setup-Lauf oder Reset
laufen. Ein paralleler Lauf wartet bis zu fünf Minuten auf den Lock und
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
| Log-Rotation Backup-Log | wöchentlich | `/etc/logrotate.d/coder-backup` |
| Debian-Paketupdates + Reboot 03:00 (ohne Docker Engine) | Debian-Default | unattended-upgrades, `52-coder-reboot` |
| Coder-/Stack-Update | **nie automatisch** | manueller Setup-Lauf (Abschnitt 7) |
| Docker-Engine-/Compose-Update | **nie automatisch** | manuelles APT-Upgrade in einem Wartungsfenster |

Prüfen: `systemctl is-active cron`, `ls -l /etc/cron.d/`,
`sudo systemctl status unattended-upgrades --no-pager`.

## 10. Tests

```bash
bash -n setup-coder.sh scripts/*.sh tests/*.sh
shellcheck -S warning setup-coder.sh scripts/*.sh tests/*.sh
for f in tests/*.sh; do bash "$f"; done
```

Stand 2026-10-01: alle 10 Dateien in `tests/` Exit 0, 266 `PASS`,
0 `FAIL` (in diesem Lauf ohne SKIP); ShellCheck `-S warning` und `bash -n`
ohne Befund. Vollständige Setup-/VM-Läufe sind auf dem Test-Host
dokumentiert (README „Prüfstand der Liste"), nicht lokal.

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

> **Vorab klären (offen, Stand 2026-09-30):** Laut Betreiber läuft der
> Schulserver künftig mit **IServ** auf dem zentralen Netzwerkserver.
> Solange unklar ist, wer DNS, Wildcard und 80/443 übernimmt, bleiben die
> Inbetriebnahme und die TLS-Frage (On-Demand vs. DNS-01) aufgeschoben.

### Pre-Flight vor dem ersten Lauf (Betreiber)

Zehn Minuten am Zielserver, bevor `sudo ./setup-coder.sh` läuft – geordnet
nach dem, was das Skript **nicht** selbst prüft:

1. **Webserver-Konflikt klären – besonders IServ.** Laut Betreiber läuft
   der Schulserver künftig mit IServ; wenn am Zielserver IServ, nginx oder
   Apache schon **80/443** halten, kann Caddy die Ports nicht binden:

   ```bash
   ss -ltnp | grep -E ':(80|443|5432) '
   systemctl list-units --type=service --state=running | grep -Ei 'iserv|nginx|apache|caddy'
   ```

   Bei fremdem Listener auf 80/443 **vor dem Lauf entscheiden**: Caddy
   bekommt die Ports (IServ-Web umziehen/Proxy-Regel, s. Netzwerkadmin
   Zeile 4) oder Coder läuft an anderer Stelle. Das Setup erwartet 80/443.
   Eigenes Docker-Postgres (5432) ist kein Konflikt – der Stack
   veröffentlicht diesen Port nicht.
2. **sshd muss auf Port 22 laufen** – sonst bricht das Skript eigens vor
   der ersten Firewall-Änderung ab (eigene Regel, `sshd -T | grep -i ^port`).
3. **Internetabbindung** (Images + Zertifikate):

   ```bash
   curl -sI 'https://auth.docker.io/token?service=registry.docker.io' | head -1   # Docker Hub
   curl -sI https://ghcr.io/v2/ | head -1                                          # Coder-Image
   ```

4. **Ressourcen:** `df -h /` (Images, laufende Dumps), `free -h` (Stack +
   Workspaces), `nproc`.
5. **DNS/Weiterleitung** stehen? Netzwerkadmin-Zeilen 1–4 unten. Fehlen
   sie, läuft der Stack trotzdem (Skript ist idempotent), bekommt aber kein
   Zertifikat – späterer zweiter Lauf genügt.
6. **Erstkonto vorbereiten:** ohne `CODER_FIRST_USER_*` ist der erste
   Anmeldende Owner. Variablen nur über `sudo env …` übergeben (sudo leitet
   eigene Variablen nicht durch), Beispiel in Schritt 4 unten.
7. **Danach:** zweiter Lauf, Checks aus OPERATIONS §5, Cron-Dateien unter
   `/etc/cron.d/` prüfen, erster `backup.sh`-Lauf per `gzip -t`.

### Netzwerkadmin

| # | Was | Warum |
|---|---|---|
| 1 | A-Record `coder.ghse-unterricht.de` → öffentliche IP des Ziel-**Servers** | sonst keine Weboberfläche |
| 2 | A-Record Wildcard `*.coder.ghse-unterricht.de` → gleiche IP | **Pflicht**: Coder vergibt Workspace-URLs im Format `<port>--<agent>--<workspace>--<user>.coder.ghse-unterricht.de`; ohne Wildcard laufen nur die Oberfläche und keine Workspace-App/Port-Forwarding |
| 3 | Firewall/Router: **80/tcp und 443/tcp 1:1 an den Server** weiterleiten (443/udp optional für HTTP/3) | ACME braucht 80 (http-01) und 443 (tls-alpn-01); ohne beides kein Zertifikat |
| 4 | Falls ein Proxy/Reverse-Proxy bestehen bleibt: `/.well-known/acme-challenge/` durchreichen **und** HTTPS als TLS-Passthrough (SNI) | ein Proxy, der selbst antwortet (z. B. mit 404), blockiert die Zertifikatsausstellung dauerhaft |
| 5 | SSH/22 bleibt ausschließlich aus dem Schulnetz erreichbar; keine öffentliche Weiterleitung | Passwortzugang ist für die erste Inbetriebnahme vorgesehen; ufw + fail2ban begrenzen Fehlversuche zusätzlich |
| 6 | Nur wenn Zeile 3 dauerhaft nicht geht: KAS-Zugang für DNS-01 (Modul `caddy-dns/all-inkl`) selbst beschaffen bzw. herausgeben | Der Betreiber hat **keinen** DNS-Zugang – Zugangsdaten und Umstellung sind Aufgabe des Domainverwalters; der Betreiber fordert nur an, was in den Zeilen 1–4 steht |

**Alternative, falls 80/443 nicht 1:1 erreichbar sind (DNS-01, B4b):**
Ein Zertifikat ohne eingehende 80/443 geht nur über den DNS-01-Challenge.
Zone `ghse-unterricht.de` liegt bei **All-Inkl**; dafür existiert das
Caddy-Modul `caddy-dns/all-inkl` (`dns.providers.allinkl`, KAS-Username/
-Passwort). Das Standard-`caddy`-Image enthält es **nicht** – nötig wären
ein eigenes Image (xcaddy-Build) und die KAS-Zugangsdaten in einer
`600`-Datei auf dem Server, nie im Repository – die KAS-Zugangsdaten
liegen beim **Domainverwalter**, nicht beim Betreiber (der hat keinen
Zugang und muss sie nur anfordern, wenn Zeile 3 dauerhaft nicht geht).
**Die Umstellung ist am 2026-09-30 aufgeschoben**, solange unklar ist, ob
die Zone bei All-Inkl bleibt und wer DNS/Ports künftig übernimmt (IServ,
siehe oben); bis
dahin ist http-01/tls-alpn-01 der eingeschlagene Weg. Beachten: DNS-01
löst nur die ACME-Frage – der Nutzerverkehr braucht weiterhin 80/443 bis
zum Server.

### Betreiber (Auftraggeber)

1. **Vorab:** `sudo ./setup-coder.sh` am Zielserver ausführen (erster Lauf legt
   Stack, Firewall, Backups an; Warnung zu TLS ist bis zu Punkt 3 normal).
2. **DNS/Weiterleitung abwarten** (Schritt 1–4 oben).
3. **Zweiter Lauf:** `sudo ./setup-coder.sh` erneut ausführen – idempotent,
   erzeugt dann das Zertifikat bzw. meldet weiterhin WARN, falls es fehlt.
4. **Erstkonto anlegen – SOFORT, bevor die URL irgendjemand weitergegeben
   wird:** Wer sich als Erster anmeldet, wird automatisch Owner. Entweder
   beim ersten Lauf über die drei Variablen (nur so sieht das Skript sie,
   `sudo` leitet fremde Variablen nicht durch):

   E-Mail ist laut Betreiber (2026-10-01) festgesetzt; Benutzername und
   Passwort entsprechend anpassen:

   ```bash
   sudo env CODER_FIRST_USER_EMAIL='maximilian.hertenstein@ghse.de' \
            CODER_FIRST_USER_USERNAME='maximilian' \
            CODER_FIRST_USER_FULL_NAME='Maximilian Hertenstein' \
            ./setup-coder.sh
   ```

   Das Passwort fragt das Skript dabei interaktiv ab (A4, `read -rs`);
   in nicht-interaktiven Läufen muss `CODER_FIRST_USER_PASSWORD='…'`
   gesetzt sein (hinter dem sudo, nie in Logs/Tickets).
   Alternativ: unmittelbar danach selbst im Browser anmelden. Danach ein **zweites**
   Owner-Konto anlegen, damit die Administration nicht an einem Zugang
   hängt (siehe [SECURITY.md](SECURITY.md)).
5. **Abnahme mit den Checks aus [Abschnitt 5](#5-checks-gesundheit-prüfen):**

   ```bash
   getent hosts coder.ghse-unterricht.de
   curl -s -o /dev/null -w '%{http_code}\n' https://coder.ghse-unterricht.de/healthz   # muss 200 sein
   docker logs coder-caddy --tail=50 | grep -i 'obtaining certificate\|error'          # muss leer bleiben
   sudo docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=8080--main--ws--user.coder.ghse-unterricht.de'   # ok
   ```

   Zusätzlich (A9) einen Test-Workspace anlegen und dessen App-URL
   **vom Schulnetz-Client** aus öffnen: der Workspace-Agent baut die
   Verbindung selbst auf (Hairpin-NAT), das prüft Port-Forwarding und
   Wildcard-DNS gemeinsam.

6. **Danach:** SSH-Nachhärtung nur auf gesonderten Wunsch per Drop-In-
   Snippet aus [SECURITY.md](SECURITY.md) §1 (D-SSH), mit getestetem
   Key-Login und Zweit-Zugang. `RESTORE.md`-Restore-Probe einmalig
   durchspielen.

Nicht Teil der Inbetriebnahme, aber betriebsrelevant: die Wildcard-Zertifikate
laufen über On-Demand-TLS mit dem gemeinsamen Let's-Encrypt-Budget der Domain
(Erkennung: wöchentliches `check-tls.sh`; Details
[TROUBLESHOOTING.md](TROUBLESHOOTING.md), Abschnitte B1–B3).
