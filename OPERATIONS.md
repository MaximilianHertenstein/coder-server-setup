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
| Repository | Quelltext: `setup-coder.sh`, `setup.conf.example`, `scripts/`, `RESTORE.md`, `templates/allowlist.md`, `tests/` |
| `/opt/coder/` auf dem Server | Alles Erzeugte: Stack-Konfiguration, `.env`, Wartungsskripte, Backups |
| `/etc/cron.d/`, `/etc/logrotate.d/`, `/etc/fail2ban/`, `/etc/apt/apt.conf.d/` | vom Setup erzeugte Systemdateien |

Ein `git pull` allein verändert **nichts** am laufenden System. Änderungen
an generierten Dateien kommen erst durch einen erneuten Lauf von
`setup-coder.sh` an. Verwaltete Dateien werden in ihrem Zielverzeichnis
atomar ersetzt; weicht eine Datei ab, setzt der Lauf sie ohne Vorwarnung
deterministisch neu (siehe Abschnitt 7).

## 2. Vom Setup erzeugte Dateien

| Pfad | Zweck | `write_managed` |
|---|---|---|
| `/opt/coder/.env` | Secrets: `POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` (600, root) | nein (bewusst) |
| `/opt/coder/docker-compose.yml` | Stack-Definition, Logs, Ports, Volumes | ja |
| `/opt/coder/caddy/Caddyfile` | TLS + Reverse Proxy, Apex + Wildcard (Verzeichnis `caddy/` wird vollständig gemountet) | ja |
| `/opt/coder/prometheus/prometheus.yml` | Scrape-Jobs `coder`, `node`, Einbindung `rule_files` (Verzeichnis `prometheus/` wird vollständig gemountet) | ja |
| `/opt/coder/prometheus/rules/coder-alerts.yml` | drei Alarmregeln (Target down, Platte <10 %, Backup >25 h; TLS-Regeln entfallen 2026-10-03) | ja |
| `/opt/coder/grafana/provisioning/datasources/prometheus.yml` | Datasource `Prometheus` wird automatisch angelegt | ja |
| `/opt/coder/node-textfile/coder_backup.prom` | Zeitstempel des letzten erfolgreichen Backups (vom Setup angelegt, vom Lauf beschrieben) | nein |
| `/opt/coder/versions.env` | wirksam gewesene Coder-Version (Downgrade-Schutz; seit Fehler-7 nur noch `CODER_VERSION`, Postgres manuell gewartet) | ja |
| `/opt/coder/backup.sh` | tägliche Datenbank-Sicherung | ja |
| `/opt/coder/.maintenance.lock` | gemeinsamer Laufzeit-Lock für Setup, Backup und Reset (600, root) | nein |
| `/opt/coder/reset-coder.sh` | Komplett-Reset des Coder-Stacks | ja |
| `/opt/coder/workspace-egress.sh` | Workspace-Egress-Sperre (DOCKER-USER: `10.0.0.0/8` + `192.168.0.0/16` DROP) | ja |
| `/opt/coder/RESTORE.md` | Runbook-Kopie (Quelle liegt im Repository) | nein |
| `/etc/cron.d/coder-backup` | Cron: täglich 01:00 | ja |
| `/etc/logrotate.d/coder-backup` | Rotation `/var/log/coder-backup.log` | ja |
| `/etc/fail2ban/jail.d/10-coder-sshd.local` | Drop-In: Jail `sshd` (backend systemd) | ja |
| `/etc/ssh/sshd_config.d/01-coder.conf` | SSH-Policy des Setups (Passwort ja, root nur Schlüssel), `sshd -T`-validiert; eigenes Alt-Drop-In `99-coder.conf` wird beim Lauf entfernt | ja |
| `/etc/apt/apt.conf.d/52-coder-reboot` | automatischer Reboot 03:00 | ja |
| `/etc/systemd/system/coder-egress-firewall.service` | führt die Egress-Sperre nach `docker.service` und nach jedem Reboot aus | ja |
| `/etc/docker/daemon.json` | Log-Limit json-file 10 MB × 3 (nur beim Fehlen geschrieben) | nein |
| `/etc/apt/apt.conf.d/20auto-upgrades` | via debconf von unattended-upgrades | nein |
| `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.gpg` | Docker-apt-Repo (Fingerprint geprüft) | nein |

Die Konfigurationsdateien für Caddy und Prometheus stehen absichtlich in
eigenen Unterverzeichnissen (`caddy/`, `prometheus/`): Docker bindet eine
**Datei** beim Containerstart an deren Inode. Das Setup ersetzt sie atomar per
Temp-Datei und `mv` – über einen Einzeldatei-Mount sähe der laufende Container
bis zum nächsten Recreate die alte Fassung, während die Validierer
(Compose/Caddyfile/Prometheus) die neue Fassung prüfen. Verzeichnis-Mounts
zeigen auf den jeweils aktuellen Inode.

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
3. der Default im Skript – nur `DOMAIN_CODER` hat einen; `ACME_EMAIL` hat
   bewusst keinen (Pflicht, sonst Abbruch vor jeder Serveränderung)

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
- `POSTGRES_PASSWORD` muss hex sein (`[0-9a-f]`) – sonst bricht das Setup
  ab und nennt die Reparatur (TROUBLESHOOTING.md A4). `GRAFANA_ADMIN_PASSWORD`
  ist frei wählbar; gedreht wird nach Abschnitt 7.
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
`sudo docker kill -s HUP coder-prometheus`. Grafana liest sein Provisioning
(Datasource + Dashboards) beim Start; das Setup startet Grafana bei einer
Änderung dieser Dateien neu (`sudo docker restart coder-grafana`).

## 5. Checks (Gesundheit prüfen)

Schritt 7 des Setups meldet `[OK]`/`[WARNUNG]`/`[FEHLER]` für: die sechs
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

# Alarmregeln geladen (3 Stück)?
curl -s http://127.0.0.1:9090/api/v1/rules | grep -o '"name":"[A-Za-z]*"' | sort -u

# Updates wirklich geplant? (unattended-upgrades ist oneshot, der Timer läuft)
systemctl is-active apt-daily-upgrade.timer && systemctl is-enabled apt-daily-upgrade.timer

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

TLS-Budget manuell sichten (kein automatischer Check):

```bash
sudo docker exec caddy sh -c "find /data/caddy/certificates -name '*.crt' -mtime -7" | wc -l
```

Alles davon zusammen in einem Lauf: `sudo ./setup-coder.sh` – Schritt 7
meldet jeden Punkt einzeln als `[OK]`/`[WARNUNG]`/`[FEHLER]`. Zusätzlich
meldet Schritt 7 den Nutzerstand (B2): solange kein menschliches Konto
existiert, weist er darauf hin, dass der erste Anmeldende Owner wird.

### Empfohlene Routine

| Rhythmus | Was | Befehl/Ort |
|---|---|---|
| täglich | Backup vorhanden und aktuell | `ls -t /opt/coder/backups/coder_*.sql.gz \| head -n1` |
| täglich | Backup-Metrik aktuell (Prometheus `BackupStale`) | `cat /opt/coder/node-textfile/coder_backup.prom` |
| nach Reboot | Container wieder da und gesund | `sudo docker ps`, Postgres `healthy`, `/healthz` 200 |
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

- Prometheus und node-exporter laufen nur auf `127.0.0.1` (9090/9100) und
  sind von außen nirgends erreichbar.
- Grafana ist **nur an `127.0.0.1:3001`** gebunden (vorhandene
  ufw-Quellregeln auf Port 3001 räumt das Setup beim Lauf auf). Der Port ist von
  außen nirgends erreichbar und darf **nicht** am Router weitergeleitet
  werden (nur 80/443/22).
- Zugang per SSH-Tunnel (von überall, auch außerhalb des Schulnetzes):

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
- Ebenso das Dashboard **„Server-Last"**
  (`/opt/coder/grafana/provisioning/dashboards/server-load.json`): CPU,
  Arbeitsspeicher, Load-Average und Wurzelpartition über die Zeit – die
  Gesamtlast des Servers als Zeitverlauf. Weitere Dashboards kommen als JSON
  in dasselbe Verzeichnis; bei Änderung startet das Setup Grafana neu.
- **Drei Alarmregeln** liegen in Prometheus (`/opt/coder/prometheus/rules/`):
  Coder-Target down, Root-Partition <10 % frei, letztes Backup älter als
  25 Stunden. Sie sind einsehbar unter `http://127.0.0.1:9090/alerts`
  bzw. in Grafana.
- **Alarmweg (entschieden 2026-10-08): Empfänger ist `hert@ghse.de`,
  Weg ist Grafana-Mail über den IServ-SMTP** – Umsetzung (Contact Point
  in Grafana), sobald IServ in Produktion ist und SMTP-Zugang besteht;
  kein Telegram/Webhook-Zeugs dazwischen. Zustellung IServ →
  `hert@ghse.de` ist laut Betreiber bestätigt (2026-10-08). Bis dahin
  weiterhin **ohne automatischen Kanal**: die Regeln klingeln nirgends,
  wer hinsieht, sieht sie unter `http://127.0.0.1:9090/alerts`.
  Manuelle Absicherung bis dahin: der tägliche Routine-Check der
  Backup-Metrik oben fängt den kritischsten Fall (BackupStale) als
  Mensch-Linie ab.

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

- **Update-Fenster (entschieden 2026-10-08):** manuelle Stack-Updates
  laufen **monatlich am ersten Samstag um 09:00** – also Setup-Rerun
  (Coder-/Prometheus-/Grafana-/node-exporter-Pins, `compose pull` für
  Caddy-/Postgres-Patches, Stack-Neustart) und im selben Fenster das
  Docker-Engine-Upgrade. Das betrifft NICHT die automatischen
  Debian-Paketupdates (`unattended-upgrades`, Reboot 03:00), die bleiben
  wie sie sind. Vorher `git log`, Versions-Pins und CHANGELOG prüfen;
  Ablauf: Backup grün → `sudo ./setup-coder.sh` (RC 0) → Checks aus §5.
  Kritische CVEs außerplanmäßig, nach Unterrichtsende.

- **Kein Auto-Prune**: alte Images bleiben als Rollback-Basis erhalten,
  Aufräumen nur manuell (`sudo docker image prune`) und bewusst.
- Exakt gepinnte Images (Coder, Prometheus, Grafana, node-exporter) kann man
  durch Setzen des Pins in `setup-coder.sh` + erneuten Setup-Lauf ändern oder
  zurückrollen. `CADDY_VERSION` (Minor) und `postgres:18-alpine` holen beim
  `pull` ggf. ein neueres Bild hinter demselben Tag.
- PostgreSQL läuft auf `postgres:18-alpine` (Major-Tag, holt 18.x-Patches
  über `pull`; aktuell 18.6, Stand 2026-09-30). Achtung, geprüft am
  Test-Host: ab Major 18 mountet das Image das Volume unter
  `/var/lib/postgresql` (Daten in `<major>/` darin, **nicht** unter
  `/var/lib/postgresql/data`) – das 18er-Image startet sonst absichtlich
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
  (`/etc/apt/apt.conf.d/52-coder-reboot`) – **abgestimmt 2026-10-08:
  03:00 bleibt**, in Ferien- und Prüfungsphasen wird vorher manuell
  abgestimmt (Reboot dann nur nach Plan); laufende Workspaces/Sessions werden
  abgerissen. Die Zeitzone steht auf `Europe/Berlin` (Setup setzt sie
  idempotent, C1), damit 03:00 wirklich 03:00 MEZ/MESZ sind.
- **Wartungsplan/Nachtachse:** 01:00 Datenbank-Backup → 02:00 VM-Backup
  der Proxmox-VM (vzdump/PBS, **noch einzurichten**, offener Punkt;
  braucht `qemu-guest-agent` und den virtio-Serial-Channel in der VM,
  das Setup installiert den Agenten nur bei vorhandenem Channel) → 03:00
  Reboot. Reihenfolge bewusst so: Sicherungen liegen vor dem Reboot,
  der Reboot startet den frischen Stand.
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

Was passiert: Inventar (hart – **Nicht-Compose-Container = Abbruch vor
allem, nichts verändert**; `--force` hebt diese Klemme nicht auf) →
letztes Backup → Bestätigung → Prüfung, ob Container ein zu löschendes
Volume halten (Abbruch vor `down`, nichts angefasst) → `docker compose
down --remove-orphans` → Löschen der Volumes `postgres_data`,
`grafana_data`, `prometheus_data` → `.env` und `versions.env` entfernen.
Unbekannte Argumente werden abgelehnt (erlaubt: keine oder `--force`).

Bleiben erhalten: Backups, Caddy-Zertifikate (`caddy_data`/`caddy_config`),
alle Einstellungen außerhalb des Coder-Stacks. Danach im Repo-Verzeichnis
`sudo ./setup-coder.sh`.

`--force` ist kein Komfort-Flag: er setzt den Reset auch ohne
funktionierendes Backup durch und verlangt eine zweite Eingabe
`RESET-OHNE-BACKUP`; das Fremd-Container-Gate bleibt auch mit `--force`
aktiv. Ohne Terminal (Pipe/CI) wird der Reset **immer**
verweigert, auch mit `--force` (Schutz vor `echo RESET | …`). **Nie auf
Produktion üben.**

### Hand-Änderungen an generierten Dateien

Das Setup schreibt verwaltete Dateien atomar (`write_managed`); weicht eine
vorgefundene Datei inhaltlich ab, ersetzt der nächste Lauf sie **ohne
Vorwarnung** durch die Setup-Fassung (gleicher Inhalt: Ziel-Inode bleibt
unangetastet). Eine Restdatei `/opt/coder/.generated-hashes` aus älteren
Installationen wird beim Lauf still entfernt.

Gewollte Anpassungen (Caddy-Snippets, Logrotate-Zeiten, fail2ban-Jails,
Cron-Zeiten, SSH-Policy) daher im Repository bzw. in `setup-coder.sh`
bzw. als eigenes, vorrangiges Drop-In ändern und das Setup erneut
ausführen – nicht dauerhaft auf dem Server korrigieren.

## 8. Backup

| Eigenschaft | Wert |
|---|---|
| Was | `pg_dump` der Datenbank `coder`, gzip-komprimiert |
| Wann | täglich 01:00 Uhr (`/etc/cron.d/coder-backup`), manuell `sudo /opt/coder/backup.sh` |
| Wo | `/opt/coder/backups/coder_<YYYY-MM-DD_HHMMSS>.sql.gz` (700/Verzeichnis, 600/Datei); dazu `backups/coder.env` (600, `.env`-Kopie, bei jedem Backup-Lauf erneuert, lokal kein Offsite) |
| Verifikation | `gzip -t` (hart), SQL-Header (hart), Größe < 512 B (Warnung), halbiert gegenüber Vorgänger (Warnung) |
| Rotation | neueste 14 Dateien, Mindestbestand eingebaut |
| Parallelität | gemeinsamer Wartungs-`flock` plus Backup-`flock`; parallele Läufe warten bis zu 300 s. Bei weiter belegtem Lock Exit 75, ohne neues Backup |
| Mindestplatz | 500 MB frei, sonst Abbruch ohne Datei; gilt auch, wenn `df` selbst fehlschlägt (Abbruch statt stumm weiter) |
| Offsite | **nicht eingerichtet** |
| Metrik | nach jedem Erfolg `node-textfile/coder_backup.prom` (644, atomar) → `coder_backup_last_success_timestamp_seconds`; Fehlschlag des Metrik-Schreibens verwandelt ein gutes Backup nicht in einen Cron-Fehler |

Zusätzlich zieht ein Setup-Lauf vor einem Upgrade ein Backup –
volumen-basiert erkannt (läuft ein Postgres-Container mit
`postgres_data`, wird er gestartet und per `pg_isready` abgeklopft, bevor
gesichert wird; ohne `backup.sh` bricht der Lauf hart ab).
`reset-coder.sh` sichert ebenfalls (Abbruch ohne Backup, außer `--force`).

Backup, Setup-Läufe und Reset teilen `/opt/coder/.maintenance.lock`.
Dadurch kann ein Backup nicht mitten in einem Setup-Lauf oder Reset
laufen. Ein paralleler Lauf wartet bis zu fünf Minuten auf den Lock und
bricht danach mit Exit 75 ab. `reset-coder.sh` hält ihn auch während der
Bestätigungsabfrage; bei langem Warten auf den Betreiber können andere
Wartungsbefehle deshalb nach fünf Minuten abbrechen und später erneut gestartet
werden.

Ein grünes Backup ist **kein** Restore-Nachweis. Verifikation und
Ablauf: [RESTORE.md](RESTORE.md).

**Was `BackupStale` misst (C-7):** nur, dass der lokale `pg_dump`-Lauf
erfolgreich war und jünger als 25 h ist. Die Metrik weiß nichts von der
VM-Ebene (Proxmox/vzdump) und nichts von Offsite – ein grüner Wert deckt
nur die eine Kopie auf derselben Platte. VM-Backup 02:00 ist
separat einzurichten (Abschnitt 7 „Reboot").

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
| Workspace-Egress-Sperre anwenden | bei jedem Boot und bei jedem Setup-Lauf | `coder-egress-firewall.service` → `/opt/coder/workspace-egress.sh` |
| Log-Rotation Backup-Log | wöchentlich | `/etc/logrotate.d/coder-backup` |
| Debian-Paketupdates + Reboot 03:00 (ohne Docker Engine) | Debian-Default | unattended-upgrades, `52-coder-reboot` |
| Coder-/Stack-Update | **nie automatisch** | manueller Setup-Lauf (Abschnitt 7) |
| Docker-Engine-/Compose-Update | **nie automatisch**, empfohlen mind. monatlich + bei kritischen CVEs im Wartungsfenster | manuelles APT-Upgrade, siehe Abschnitt 7 „Update (bewusst manuell)" |

Prüfen: `systemctl is-active cron`, `ls -l /etc/cron.d/`,
`systemctl status apt-daily-upgrade.timer --no-pager` (der Timer stößt
den oneshot-Dienst `unattended-upgrades` an).

## 10. Tests

```bash
bash -n setup-coder.sh scripts/*.sh tests/*.sh
shellcheck -S warning setup-coder.sh scripts/*.sh tests/*.sh
for f in tests/*.sh; do bash "$f"; done
```

Stand 2026-10-08: alle 10 Dateien in `tests/` Exit 0, 329 `PASS`,
0 `FAIL`; ShellCheck `-S warning` und `bash -n`
ohne Befund. Vollständige Setup-/VM-Läufe sind auf dem Test-Host
dokumentiert (README „Verifikation"), nicht lokal.

Die Skripte arbeiten mit Fakes/Fixtures in `/tmp` – sie brauchen weder
Root noch Docker und berühren keine Produktion. Sie belegen das Verhalten
einzelner Codestellen, **nicht** den Gesamtlauf. VM-Pflichtige Prüfungen
stehen in [README.md](README.md), Abschnitt „Verifikation (Test-VM bzw.
Produktion)".

## 11. Inbetriebnahme am Zielserver: wer macht was

Domain bleibt **`ghse-unterricht.de`** (gesamt mit anderen Schuldiensten
geteilt). Der Zielserver ist ein Schulserver, per SSH nur aus dem Schulnetz
erreichbar. Passwort-Login bleibt bei der ersten Inbetriebnahme bewusst aktiv.
Bis DNS und Web-Portweiterleitung stehen, startet der
Stack trotzdem – Caddy holt das Zertifikat dann nach (Skript ist idempotent,
einfach erneut ausführen).

> **Vorab klären (offen):** Der Zielserver ist ein **frisches Debian ohne
> eigenen Webserver**. **IServ** läuft auf einem anderen zentralen
> Netzwerkserver, mit dem das Schulnetz verwaltet wird – vermutlich ist
> dort auch der Reverse-Proxy. Solange unklar ist, wie 80/443 zum
> Zielserver kommen (DNS direkt auf den Zielserver oder Durchreichung am
> zentralen Server) und wer DNS/Wildcard übernimmt, bleibt die TLS-Frage
> (On-Demand vs. DNS-01) aufgeschoben.

### Pre-Flight vor dem ersten Lauf (Betreiber)

Zehn Minuten am Zielserver, bevor `sudo ./setup-coder.sh` läuft – geordnet
nach dem, was das Skript **nicht** selbst prüft:

1. **Portlage 80/443 klären.** Der Zielserver ist ein frisches Debian
   ohne eigenen Webserver; IServ (und vermutlich der Reverse-Proxy) läuft
   auf einem anderen zentralen Netzwerkserver. Kurz nachprüfen, ob am
   Zielserver schon etwas **80/443** hält (sonst kann Caddy die Ports
   nicht binden):

   ```bash
   ss -ltnp | grep -E ':(80|443|5432) '
   systemctl list-units --type=service --state=running | grep -Ei 'nginx|apache|caddy|iserv'
   ```

   Der entscheidende Teil ist extern: DNS zeigt direkt auf den Zielserver,
   oder der zentrale Proxy leitet 80/443 dorthin durch (ACME-Pfade +
   TLS-Passthrough/SNI, s. Netzwerkadmin Zeile 4). Das Setup erwartet
   80/443 am Zielserver. Eigenes Docker-Postgres (5432) ist kein Konflikt –
   der Stack veröffentlicht diesen Port nicht.
2. **sshd muss auf Port 22 laufen** – sonst bricht das Skript eigens vor
   der ersten Firewall-Änderung ab (eigene Regel). Prüfen mit
   `sudo sshd -T | grep -i ^port` – ohne sudo ist `/usr/sbin` meist nicht
   im PATH (Schulserver-Log 2026-10-14: „sshd: Kommando nicht gefunden").
3. **Internetabbindung** (Images + Zertifikate) – Statuscode per GET
   prüfen, `curl -sI` (HEAD) liefert an beiden Endpunkten 405 und sieht
   nach Fehler aus (Schulserver-Log 2026-10-14, am Testhost 2026-10-14
   nachgestellt):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' 'https://auth.docker.io/token?service=registry.docker.io'  # muss 200 sein
   curl -s -o /dev/null -w '%{http_code}\n' https://ghcr.io/v2/                                         # muss 401 sein (unauthorized = erreichbar)
   ```

4. **Ressourcen:** `df -h /` (Images, laufende Dumps), `free -h` (Stack +
   Workspaces), `nproc`.
5. **DNS/Weiterleitung** stehen? Netzwerkadmin-Zeilen 1–4 unten. Fehlen
   sie, läuft der Stack trotzdem (Skript ist idempotent), bekommt aber kein
   Zertifikat – späterer zweiter Lauf genügt.
6. **Erstkonto vorbereiten:** ohne `CODER_FIRST_USER_*` ist der erste
   Anmeldende Owner. Variablen nur über `sudo env …` übergeben (sudo leitet
   eigene Variablen nicht durch), Beispiel in Schritt 4 unten.
7. **`setup.conf` anlegen:** `cp setup.conf.example setup.conf` und
   `ACME_EMAIL=…` eintragen – diese Adresse ist **Pflicht** (kein Default;
   ohne Wert bricht das Setup vor jeder Serveränderung ab und nennt die
   Datei). Domain optional, sonst greift der Default.
8. **Danach:** zweiter Lauf, Checks aus OPERATIONS §5, Cron-Dateien unter
   `/etc/cron.d/` prüfen, erster `backup.sh`-Lauf per `gzip -t`.

### Netzwerkadmin

| # | Was | Warum |
|---|---|---|
| 1 | A-Record `coder.ghse-unterricht.de` → öffentliche IP des Ziel-**Servers** | sonst keine Weboberfläche |
| 2 | A-Record Wildcard `*.coder.ghse-unterricht.de` → gleiche IP | **Pflicht**: Coder vergibt Workspace-URLs im Format `<port>--<agent>--<workspace>--<user>.coder.ghse-unterricht.de`; ohne Wildcard laufen nur die Oberfläche und keine Workspace-App/Port-Forwarding |
| 3 | Firewall/Router: **80/tcp und 443/tcp 1:1 an den Server** weiterleiten (443/udp optional für HTTP/3) | ACME braucht 80 (http-01) und 443 (tls-alpn-01); ohne beides kein Zertifikat |
| 4 | Falls der zentrale Proxy (vermutlich am IServ-Server) vor dem Zielserver bleibt: `/.well-known/acme-challenge/` durchreichen, HTTPS als TLS-Passthrough (SNI) **und WebSocket-Upgrade** durchreichen (Workspace-Verbindungen laufen über WSS; Caddy selbst leitet `Upgrade` standardmäßig durch) | ein Proxy, der selbst antwortet (z. B. mit 404), blockiert die Zertifikatsausstellung dauerhaft |
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
**Die Umstellung ist aufgeschoben**, solange unklar ist, ob
die Zone bei All-Inkl bleibt und wer DNS/Ports übernimmt (zentraler
IServ-Server, siehe oben); bis
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

   Das Passwort fragt das Skript dabei interaktiv ab (A4, `read -rs`) –
   **gewollt und die einzige Eingabe des Laufs**: nur solange kein
   menschliches Konto existiert, `CODER_FIRST_USER_EMAIL`/`_USERNAME`
   gesetzt sind und stdin ein TTY ist; Enter ohne Eingabe überspringt die
   Anlage (Browser-Registrierung).
   In nicht-interaktiven Läufen (ohne TTY) das Passwort bevorzugt aus einer
   root-only Datei geben – ihr Inhalt steht dann weder in `ps` noch in der
   Shell-History:

   ```bash
   read -rs -p 'Erstkonto-Passwort: ' _p; echo
   sudo sh -c 'umask 077; cat > /root/.erstkonto-passwort' <<< "$_p"
   unset _p
   sudo env CODER_FIRST_USER_PASSWORD_FILE=/root/.erstkonto-passwort ./setup-coder.sh
   sudo rm -f /root/.erstkonto-passwort
   ```

   Fallback: `CODER_FIRST_USER_PASSWORD='…'` direkt hinter dem sudo – das
   steht kurz in `ps` und dauerhaft in der Shell-History; nie in Logs oder
   Tickets. Selbst wählen:
   **lange Passphrase**, kein bekanntes Standard- oder Schulpasswort
   (SSH und Coder teilen sich das Netz; fail2ban begrenzt Versuche,
   ersetzt aber keine Passwortstärke).
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
laufen über On-Demand-TLS mit dem gemeinsamen Let's-Encrypt-Budget der
Domain; eine automatische Budget-Überwachung gibt es nicht,
Erschöpfung fällt als HTTPS-Fehler auf (manuelle
Sichtprüfung in Abschnitt 5, Details
[TROUBLESHOOTING.md](TROUBLESHOOTING.md), Abschnitte B1–B3).
