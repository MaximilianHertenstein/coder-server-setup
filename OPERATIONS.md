# OPERATIONS.md – Betrieb und Wartung

Grundlage: das tatsächlich im Repository stehende `setup-coder.sh` (erzeugt
alles auf dem Server). Alle Befehle hier sind Standard-Docker-/systemd-
Befehle; wo das Setup selbst etwas prüft oder erzeugt, steht der Pfad dabei.

Verweise: Wiederherstellung → [RESTORE.md](RESTORE.md), Sicherheit →
[SECURITY.md](SECURITY.md), Fehlerbilder → [TROUBLESHOOTING.md](TROUBLESHOOTING.md),
Einstieg → [README.md](README.md).

## 1. Ablageprinzip

| Wo | Was |
|---|---|
| Repository | Quelltext: `setup-coder.sh`, `setup.conf.example`, `scripts/`, `RESTORE.md`, `templates/allowlist.md`, `tests/` |
| `/opt/coder/` auf dem Server | Alles Erzeugte: Stack-Konfiguration, `.env`, Wartungsskripte, Backups |
| `/etc/cron.d/`, `/etc/logrotate.d/`, `/etc/fail2ban/`, `/etc/apt/apt.conf.d/` | vom Setup erzeugte Systemdateien |

Ein `git pull` allein verändert **nichts** am laufenden System. Änderungen
an generierten Dateien kommen erst durch einen erneuten Lauf von
`setup-coder.sh` an. Verwaltete Dateien werden atomar ersetzt; weicht eine
Datei ab, setzt der Lauf sie ohne Vorwarnung deterministisch neu
(siehe Abschnitt 7).

## 2. Vom Setup erzeugte Dateien

| Pfad | Zweck | `write_managed` |
|---|---|---|
| `/opt/coder/.env` | Secrets: `POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` (600, root) | nein (bewusst) |
| `/opt/coder/docker-compose.yml` | Stack-Definition, Logs, Ports, Volumes | ja |
| `/opt/coder/caddy/Caddyfile` | TLS + Reverse Proxy, Apex + Wildcard (Verzeichnis `caddy/` wird vollständig gemountet) | ja |
| `/opt/coder/prometheus/prometheus.yml` | Scrape-Jobs `coder`, `node`, `rule_files` (Verzeichnis `prometheus/` wird vollständig gemountet) | ja |
| `/opt/coder/prometheus/rules/coder-alerts.yml` | drei Alarmregeln (Target down, Platte <10 %, Backup >25 h) | ja |
| `/opt/coder/grafana/provisioning/datasources/prometheus.yml` | Datasource `Prometheus` wird automatisch angelegt | ja |
| `/opt/coder/node-textfile/coder_backup.prom` | Zeitstempel des letzten erfolgreichen Backups | nein |
| `/opt/coder/versions.env` | wirksam gewesene Coder-Version (Downgrade-Schutz) | ja |
| `/opt/coder/backup.sh` | tägliche Datenbank-Sicherung | ja |
| `/opt/coder/.maintenance.lock` | gemeinsamer Laufzeit-Lock für Setup, Backup und Reset (600, root) | nein |
| `/opt/coder/reset-coder.sh` | Komplett-Reset des Coder-Stacks | ja |
| `/opt/coder/workspace-egress.sh` | Workspace-Egress-Sperre (DOCKER-USER: `10.0.0.0/8` + `192.168.0.0/16` DROP) | ja |
| `/opt/coder/RESTORE.md` | Runbook-Kopie (Quelle liegt im Repository) | nein |
| `/etc/cron.d/coder-backup` | Cron: täglich 01:00 | ja |
| `/etc/logrotate.d/coder-backup` | Rotation `/var/log/coder-backup.log` | ja |
| `/etc/fail2ban/jail.d/10-coder-sshd.local` | Drop-In: Jail `sshd` (backend systemd) | ja |
| `/etc/ssh/sshd_config.d/01-coder.conf` | SSH-Policy des Setups (Passwort ja, root nur Schlüssel), `sshd -T`-validiert | ja |
| `/etc/apt/apt.conf.d/52-coder-reboot` | automatischer Reboot 03:00 | ja |
| `/etc/systemd/system/coder-egress-firewall.service` | führt die Egress-Sperre nach `docker.service` und nach jedem Reboot aus | ja |
| `/etc/docker/daemon.json` | Log-Limit json-file 10 MB × 3 (nur beim Fehlen geschrieben) | nein |
| `/etc/apt/apt.conf.d/20auto-upgrades` | via debconf von unattended-upgrades | nein |
| `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.gpg` | Docker-apt-Repo (Fingerprint geprüft) | nein |

Die Konfigurationsdateien für Caddy und Prometheus stehen absichtlich in
eigenen Unterverzeichnissen: Docker bindet eine **Datei** beim Containerstart
an deren Inode. Das Setup ersetzt sie atomar per Temp-Datei und `mv` – über
einen Einzeldatei-Mount sähe der laufende Container bis zum nächsten Recreate
die alte Fassung. Verzeichnis-Mounts zeigen auf den jeweils aktuellen Inode.

Nicht im Repository, nur auf dem Server: alle Backups und Logs.

## 3. Konfigurationsvariablen

Überschreibungen laufen in dieser Reihenfolge (Vorrang von links):

1. Umgebungsvariable beim Aufruf – gehört hinter das sudo (`sudo` leitet
   fremde Variablen nicht durch):
   `sudo env DOMAIN_CODER=… ACME_EMAIL=… ./setup-coder.sh`
2. `setup.conf` neben `setup-coder.sh` (Vorlage: `setup.conf.example`,
   gitignored, nie ins Repository): Zeilen `SCHLÜSSEL=Wert` für
   `DOMAIN_CODER`, `ACME_EMAIL`, `ACME_CA` und `FAIL2BAN_IGNORE_IP`
3. der Default im Skript – nur `DOMAIN_CODER` hat einen; `ACME_EMAIL` hat
   bewusst keinen (Pflicht, sonst Abbruch vor jeder Serveränderung)

Versions-Pins und `CODER_ALLOW_DOWNGRADE` laufen nur über
Umgebungsvariablen; Tabelle in [README.md](README.md), Abschnitt
„Wichtigste Konfiguration".

**Secrets-Verfahren**

- Erstpasswörter werden beim ersten Lauf erzeugt und in `/opt/coder/.env`
  (600, root:root) gespeichert. Die Ausgabe zeigt nie den Secret-Wert.
- Eine unvollständige `.env` wird nie still neu gewürfelt – das Setup
  bricht ab und nennt die Reparatur (TROUBLESHOOTING.md A3/A4).
- `POSTGRES_PASSWORD` muss hex sein, `GRAFANA_ADMIN_PASSWORD` ist frei
  wählbar; Rotation nach Abschnitt 7 „Passwörter rotieren".
- Passwort bei Bedarf gezielt abrufen:
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
`Caddyfile` nicht automatisch. Bei eigener Änderung also zuerst prüfen,
dann neu laden:

```bash
sudo docker exec coder-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo docker exec coder-caddy caddy reload    --config /etc/caddy/Caddyfile --adapter caddyfile
```

Prometheus lädt `prometheus.yml` und Alarmregeln auf SIGHUP neu
(manuell: `sudo docker kill -s HUP coder-prometheus`). Grafana liest sein
Provisioning beim Start; das Setup startet Grafana bei einer Änderung
dieser Dateien neu (`sudo docker restart coder-grafana`).

## 5. Checks (Gesundheit prüfen)

Schritt 7 des Setups meldet `[OK]`/`[WARNUNG]`/`[FEHLER]` für: die sechs
Container, den Docker-Socket-Zugriff, `https://<domain>/healthz` (HTTP 200)
und den Wildcard-DNS. Einen belegten Port meldet `docker compose up` mit
klarer Portangabe (Diagnose: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)).
Alles einzeln reproduzierbar:

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

# On-Demand-TLS-ask (nur IM Container erreichbar – Port 9123 hat keine
# ufw-Regel): 200 = erlaubt, 404 = verboten
docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=coder.ghse-unterricht.de'
docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=evil.ghse-unterricht.de'   # erwartet: 404

# Backup-Metrik sichtbar? (fehlend = noch kein erfolgreicher Lauf)
cat /opt/coder/node-textfile/coder_backup.prom
curl -s http://127.0.0.1:9100/metrics | grep '^coder_backup'

# Alarmregeln geladen (3 Stück)?
curl -s http://127.0.0.1:9090/api/v1/rules | grep -o '"name":"[A-Za-z]*"' | sort -u

# Updates wirklich geplant? (unattended-upgrades ist oneshot, der Timer läuft)
systemctl is-active apt-daily-upgrade.timer && systemctl is-enabled apt-daily-upgrade.timer
```

Firewall/SSH-Checks:

```bash
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'
```

Konfiguration validieren (ohne Eingriff):
`sudo docker compose -f /opt/coder/docker-compose.yml config --quiet`

TLS-Budget sichten (kein automatischer Check, [SECURITY.md](SECURITY.md) §3):

```bash
sudo docker exec caddy sh -c "find /data/caddy/certificates -name '*.crt' -mtime -7" | wc -l
```

Nach dem ersten Workspace zusätzlich im Terminal **dieses** Workspaces die
öffentliche Coder-URL prüfen und eine echte Workspace-App über ihre
`*.coder…`-URL im Browser öffnen – ein Host-Test belegt nicht, dass
Workspace-DNS, Egress und App-Routen funktionieren.

Alles davon zusammen in einem Lauf: `sudo ./setup-coder.sh` – Schritt 7
meldet jeden Punkt einzeln.

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
| Container-Logs | `json-file`, 10 MB × 3 pro Container | intern begrenzt |
| `journalctl -u fail2ban`, `-u ssh`, `-u cron`, `-u unattended-upgrades` | Systemdienste | Debian-Defaults |

```bash
sudo docker logs coder --tail=100
sudo docker logs coder-caddy --tail=100
sudo journalctl -u fail2ban -n 50 --no-pager
```

### Monitoring und Grafana

- Prometheus, node-exporter und Grafana laufen nur auf `127.0.0.1`
  (9090/9100/3001) und sind von außen nirgends erreichbar. Grafana darf
  **nicht** am Router weitergeleitet werden (nur 80/443/22).
- Grafana-Zugang per SSH-Tunnel (von überall):

  ```bash
  ssh -L 3001:127.0.0.1:3001 <user>@<server>
  # danach im Browser: http://127.0.0.1:3001  (Benutzer: admin)
  ```

- Datasource `Prometheus` und das Dashboard „Server-Last" werden
  automatisch provisioniert (`/opt/coder/grafana/provisioning/`); weitere
  Dashboards als JSON in dasselbe Verzeichnis, bei Änderung startet das
  Setup Grafana neu.
- Drei Alarmregeln in Prometheus (`/opt/coder/prometheus/rules/`):
  Coder-Target down, Root-Partition <10 % frei, letztes Backup älter als
  25 Stunden. Sichtbar unter `http://127.0.0.1:9090/alerts` bzw. in Grafana.
- **Alarmweg:** Empfänger ist `hert@ghse.de`, Weg ist Grafana-Mail über den
  IServ-SMTP – Umsetzung (Contact Point in Grafana), sobald IServ in
  Produktion ist und SMTP-Zugang besteht. Bis dahin gibt es **ohne
  automatischen Kanal**: die Regeln klingeln nirgends, wer hinsieht, sieht
  sie unter `http://127.0.0.1:9090/alerts`. Manuelle Absicherung bis
  dahin: der tägliche Routine-Check der Backup-Metrik fängt den
  kritischsten Fall (BackupStale) als Mensch-Linie ab.

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
pull` (max. 3 Versuche) → `docker compose up -d` → Abschlusscheck. Bei
rotem Abschlusscheck: Exit ≠ 0, Stack prüfen, ggf. zurückrollen.

- **Update-Fenster:** manuelle Stack-Updates laufen **monatlich am ersten
  Samstag um 09:00** – Setup-Rerun (Pins, `compose pull` für Caddy-/
  Postgres-Patches, Stack-Neustart) und im selben Fenster das
  Docker-Engine-Upgrade. Das betrifft NICHT die automatischen
  Debian-Paketupdates (unattended-upgrades, Reboot 03:00). Ablauf: Backup
  grün → `sudo ./setup-coder.sh` (RC 0) → Checks aus §5. Kritische CVEs
  ad hoc nach Unterrichtsende.
- **Kein Auto-Prune**: alte Images bleiben als Rollback-Basis, Aufräumen
  nur manuell (`sudo docker image prune`) und bewusst.
- PostgreSQL läuft auf `postgres:18-alpine` (Major-Tag, holt 18.x-Patches
  über `pull`). Achtung: ab Major 18 mountet das Image das Volume unter
  `/var/lib/postgresql` (Daten in `<major>/` darin, **nicht** unter
  `/var/lib/postgresql/data`) – das 18er-Image startet sonst absichtlich
  nicht. Compose und Image wandern deshalb immer zusammen (beides erzeugt
  `setup-coder.sh` neu). Ein weiterer Major-Wechsel ist bewusst kein
  `pull`: Volume bleibt, Dump/Restore in einem Wartungsfenster
  ([RESTORE.md](RESTORE.md)), danach Datenprobe.
- Docker Engine und Compose-Plugin werden weder durch `unattended-upgrades`
  noch durch das Setup aktualisiert. Dafür in einem abgestimmten
  Wartungsfenster manuell:

  ```bash
  sudo apt-get update
  sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ```

  Ein Upgrade kann `dockerd` neu starten und alle Workspace-Container
  unterbrechen. Vorher Unterrichtsende abstimmen, danach Container prüfen.
- Coder-Major-Updates: Schema-Migrationen können Downgrades irreversibel
  machen. Nur mit verifiziertem Dump, einzeln fahren – nie zusammen mit
  einem DB-Update.

### Passwörter rotieren (Grafana-Admin)

Manuell in dieser Reihenfolge:

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
   die `.env` ist die abrufbare Kopie.
4. `POSTGRES_PASSWORD` bleibt unverändert (Reparatur bei Nicht-Hex:
   TROUBLESHOOTING.md A4).

**Folge des geänderten `.env`:** Beim nächsten vollständigen
`docker compose up -d` wird **Grafana** neu erstellt (Env-Hash) – kurzer
Neustart, Volumes/Dashboards bleiben. Postgres und Coder sind nicht
betroffen.

### Reboot

- Automatisch bei Kernel-Updates um 03:00 Uhr
  (`/etc/apt/apt.conf.d/52-coder-reboot`) – abgestimmte Dauerregel; in
  Ferien- und Prüfungsphasen vorher manuell abstimmen (Reboot dann nur
  nach Plan); laufende Workspaces/Sessions werden abgerissen. Die
  Timezone steht auf `Europe/Berlin`, damit 03:00 wirklich 03:00 MEZ/MESZ
  sind.
- **Nachtachse:** 01:00 Datenbank-Backup → 02:00 VM-Backup der
  Proxmox-VM (vzdump/PBS, **noch einzurichten**; braucht
  `qemu-guest-agent` und den virtio-Serial-Channel, das Setup installiert
  den Agenten nur bei vorhandenem Channel) → 03:00 Reboot. Sicherungen
  liegen damit vor dem Reboot.
- Nach einem Reboot: Docker startet die Container selbst; danach prüfen:
  `sudo docker ps`, Postgres `healthy` und `/healthz` muss 200 liefern.
- Manuell: `sudo reboot`, danach die drei Checks oben.

### Komplett-Reset

```bash
sudo /opt/coder/reset-coder.sh            # mit Backup + Bestätigung "RESET"
sudo /opt/coder/reset-coder.sh --force    # nur, wenn das Backup fehlschlägt
```

Was passiert: Inventar (hart – **Nicht-Compose-Container = Abbruch vor
allem, nichts verändert**; `--force` hebt diese Klemme nicht auf) →
letztes Backup → Bestätigung → Prüfung, ob Container ein zu löschendes
Volume halten → `docker compose down --remove-orphans` → Löschen der
Volumes `postgres_data`, `grafana_data`, `prometheus_data` → `.env` und
`versions.env` entfernen. Unbekannte Argumente werden abgelehnt.

Bleiben erhalten: Backups, Caddy-Zertifikate, alle Einstellungen
außerhalb des Coder-Stacks. Danach im Repo-Verzeichnis
`sudo ./setup-coder.sh`.

`--force` ist kein Komfort-Flag: er setzt den Reset auch ohne
funktionierendes Backup durch und verlangt eine zweite Eingabe
`RESET-OHNE-BACKUP`; das Fremd-Container-Gate bleibt aktiv. Ohne Terminal
(Pipe/CI) wird der Reset **immer** verweigert. **Nie auf Produktion üben.**

### Hand-Änderungen an generierten Dateien

Das Setup schreibt verwaltete Dateien atomar; weicht eine vorgefundene Datei
inhaltlich ab, ersetzt der nächste Lauf sie **ohne Vorwarnung** durch die
Setup-Fassung (gleicher Inhalt: Inode bleibt unangetastet).

Gewollte Anpassungen (Caddy-Snippets, Logrotate-Zeiten, fail2ban-Jails,
Cron-Zeiten, SSH-Policy) daher im Repository bzw. in `setup-coder.sh`
bzw. als eigenes, vorrangiges Drop-In (`00-*.conf`) ändern und das Setup
erneut ausführen – nicht dauerhaft auf dem Server korrigieren.

## 8. Backup

| Eigenschaft | Wert |
|---|---|
| Was | `pg_dump` der Datenbank `coder`, gzip-komprimiert |
| Wann | täglich 01:00 Uhr (`/etc/cron.d/coder-backup`), manuell `sudo /opt/coder/backup.sh` |
| Wo | `/opt/coder/backups/coder_<YYYY-MM-DD_HHMMSS>.sql.gz` (700/Verzeichnis, 600/Datei); dazu `backups/coder.env` (600, `.env`-Kopie, bei jedem Lauf erneuert) |
| Verifikation | `gzip -t` (hart), SQL-Header (hart), Größe < 512 B (Warnung), halbiert gegenüber Vorgänger (Warnung) |
| Rotation | neueste 14 Dateien |
| Parallelität | gemeinsamer Wartungs-`flock` plus Backup-`flock`; parallele Läufe warten bis zu 300 s, dann Exit 75 ohne neues Backup |
| Mindestplatz | 500 MB frei, sonst Abbruch ohne Datei |
| Offsite | **nicht eingerichtet** – entschieden: vzdump/PBS auf anderem Storage/Host + monatlicher verschlüsselter `rsync`-Pull `/opt/coder/backups` vom Betreiber-Rechner (Dumps enthalten Tokens/Nutzerdaten). Bis zur Umsetzung: Platten-/Hostverlust = DB + alle lokalen Backups weg |
| Metrik | nach jedem Erfolg `node-textfile/coder_backup.prom` → `coder_backup_last_success_timestamp_seconds`; ein fehlgeschlagener Metrik-Schreibversuch macht ein gutes Backup nicht zu einem Cron-Fehler |

Zusätzlich zieht ein Setup-Lauf vor einem Upgrade ein Backup (volumen-
basiert erkannt). `reset-coder.sh` sichert ebenfalls (Abbruch ohne Backup,
außer `--force`). Backup, Setup-Läufe und Reset teilen
`/opt/coder/.maintenance.lock`.

**Was `BackupStale` misst:** nur, dass der lokale `pg_dump`-Lauf erfolgreich
war und jünger als 25 h ist. Die Metrik weiß nichts von der VM-Ebene
(Proxmox/vzdump) und nichts von Offsite – VM-Backup 02:00 ist separat
einzurichten (Abschnitt 7 „Reboot").

```bash
# Zustand prüfen
ls -lt /opt/coder/backups/ | head
cat /opt/coder/node-textfile/coder_backup.prom
gzip -t "$(ls -t /opt/coder/backups/coder_*.sql.gz | head -n1)" && echo "gzip OK"
tail -20 /var/log/coder-backup.log
```

Ein grünes Backup ist **kein** Restore-Nachweis. Verifikation und Ablauf:
[RESTORE.md](RESTORE.md).

## 9. Automatische Aufgaben

| Aufgabe | Wann | Datei/Quelle |
|---|---|---|
| Datenbank-Backup | täglich 01:00 | `/etc/cron.d/coder-backup` |
| Workspace-Egress-Sperre anwenden | bei jedem Boot und bei jedem Setup-Lauf | `coder-egress-firewall.service` → `/opt/coder/workspace-egress.sh` |
| Log-Rotation Backup-Log | wöchentlich | `/etc/logrotate.d/coder-backup` |
| Debian-Paketupdates + Reboot 03:00 (ohne Docker Engine) | Debian-Default | unattended-upgrades, `52-coder-reboot` |
| Coder-/Stack-Update | **nie automatisch** | manueller Setup-Lauf (Abschnitt 7) |
| Docker-Engine-/Compose-Update | **nie automatisch**, mind. monatlich + bei kritischen CVEs im Wartungsfenster | manuelles APT-Upgrade, siehe Abschnitt 7 |

Prüfen: `systemctl is-active cron`, `ls -l /etc/cron.d/`,
`systemctl status apt-daily-upgrade.timer --no-pager`.

## 10. Tests

```bash
bash -n setup-coder.sh scripts/*.sh tests/*.sh
shellcheck -S warning setup-coder.sh scripts/*.sh tests/*.sh
for f in tests/*.sh; do bash "$f"; done
```

Aktueller Stand: alle 10 Dateien in `tests/` Exit 0, 329 `PASS`, 0 `FAIL`.
Die Skripte arbeiten mit Fakes/Fixtures in `/tmp` – sie brauchen weder Root
noch Docker und berühren keine Produktion. Sie belegen das Verhalten
einzelner Codestellen, **nicht** den Gesamtlauf; was noch VM oder echtes
Netz braucht, steht in [README.md](README.md), Abschnitt „Wo stehen wir".

## 11. Inbetriebnahme am Zielserver: wer macht was

Domain bleibt **`ghse-unterricht.de`** (gesamt mit anderen Schuldiensten
geteilt). Der Zielserver ist ein Schulserver, per SSH nur aus dem Schulnetz
erreichbar. Bis DNS und Web-Portweiterleitung stehen, startet der Stack
trotzdem – Caddy holt das Zertifikat dann nach (Skript ist idempotent,
einfach erneut ausführen).

> **Vorab klären (offen):** Der Zielserver ist ein **frisches Debian ohne
> eigenen Webserver**. **IServ** läuft auf einem anderen zentralen
> Netzwerkserver, vermutlich samt Reverse-Proxy. Solange unklar ist, wie
> 80/443 zum Zielserver kommen (DNS direkt oder Durchreichung am zentralen
> Server) und wer DNS/Wildcard übernimmt, bleibt die TLS-Frage (On-Demand
> vs. DNS-01) aufgeschoben.

### Pre-Flight vor dem ersten Lauf (Betreiber)

Zehn Minuten am Zielserver, bevor `sudo ./setup-coder.sh` läuft – geordnet
nach dem, was das Skript **nicht** selbst prüft:

1. **Portlage 80/443 klören.** Kurz nachprüfen, ob am Zielserver schon
   etwas **80/443** hält (sonst kann Caddy die Ports nicht binden):

   ```bash
   ss -ltnp | grep -E ':(80|443|5432) '
   systemctl list-units --type=service --state=running | grep -Ei 'nginx|apache|caddy|iserv'
   ```

   Der entscheidende Teil ist extern: DNS zeigt direkt auf den Zielserver,
   oder der zentrale Proxy leitet 80/443 dorthin durch (ACME-Pfade +
   TLS-Passthrough/SNI, s. Netzwerkadmin Zeile 4). Eigenes Docker-Postgres
   (5432) ist kein Konflikt – der Stack veröffentlicht diesen Port nicht.
2. **sshd muss auf Port 22 laufen** – sonst bricht das Skript vor der
   ersten Firewall-Änderung ab. Prüfen mit
   `sudo sshd -T | grep -i ^port` (ohne sudo ist `/usr/sbin` meist nicht
   im PATH).
3. **Internetabbindung** (Images + Zertifikate) – Statuscode per GET
   prüfen (`curl -sI` (HEAD) liefert an beiden Endpunkten 405 und sieht
   nach Fehler aus):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' 'https://auth.docker.io/token?service=registry.docker.io'  # muss 200 sein
   curl -s -o /dev/null -w '%{http_code}\n' https://ghcr.io/v2/                                         # muss 401 sein (unauthorized = erreichbar)
   ```

4. **Ressourcen:** `df -h /` (Images, laufende Dumps), `free -h` (Stack +
   Workspaces), `nproc`.
5. **DNS/Weiterleitung** stehen? Netzwerkadmin-Zeilen 1–4 unten. Fehlen
   sie, läuft der Stack trotzdem, bekommt aber kein Zertifikat – späterer
   zweiter Lauf genügt.
6. **Erstkonto vorbereiten:** ohne `CODER_FIRST_USER_*` ist der erste
   Anmeldende Owner. Variablen nur über `sudo env …` übergeben, Beispiel
   in Betreiber Schritt 4.
7. **`setup.conf` anlegen:** `cp setup.conf.example setup.conf` und
   `ACME_EMAIL=…` eintragen – diese Adresse ist **Pflicht**. Domain
   optional, sonst greift der Default.
8. **Danach:** zweiter Lauf, Checks aus Abschnitt 5, Cron-Dateien unter
   `/etc/cron.d/` prüfen, erster `backup.sh`-Lauf per `gzip -t`.

### Netzwerkadmin

| # | Was | Warum |
|---|---|---|
| 1 | A-Record `coder.ghse-unterricht.de` → öffentliche IP des Ziel-**Servers** | sonst keine Weboberfläche |
| 2 | A-Record Wildcard `*.coder.ghse-unterricht.de` → gleiche IP | **Pflicht**: Coder vergibt Workspace-URLs im Format `<port>--<agent>--<workspace>--<user>.coder.ghse-unterricht.de`; ohne Wildcard laufen nur die Oberfläche und keine Workspace-App/Port-Forwarding |
| 3 | Firewall/Router: **80/tcp und 443/tcp 1:1 an den Server** weiterleiten (443/udp optional für HTTP/3) | ACME braucht 80 (http-01) und 443 (tls-alpn-01); ohne beides kein Zertifikat |
| 4 | Falls der zentrale Proxy (vermutlich am IServ-Server) vor dem Zielserver bleibt: `/.well-known/acme-challenge/` durchreichen, HTTPS als TLS-Passthrough (SNI) **und WebSocket-Upgrade** durchreichen (Workspace-Verbindungen laufen über WSS) | ein Proxy, der selbst antwortet (z. B. mit 404), blockiert die Zertifikatsausstellung dauerhaft |
| 5 | SSH/22 bleibt ausschließlich aus dem Schulnetz erreichbar; keine öffentliche Weiterleitung | Passwortzugang ist für die erste Inbetriebnahme vorgesehen; ufw + fail2ban begrenzen Fehlversuche zusätzlich |
| 6 | Nur wenn Zeile 3 dauerhaft nicht geht: KAS-Zugang für DNS-01 (Modul `caddy-dns/all-inkl`) beim Domainverwalter anfordern | Der Betreiber hat **keinen** DNS-Zugang; der Betreiber fordert nur an, was in den Zeilen 1–4 steht |

**Alternative DNS-01 (nur falls 80/443 dauerhaft nicht 1:1 gehen):**
Wildcard-Zertifikat ohne eingehende 80/443 geht nur über den DNS-01-
Challenge; Zone `ghse-unterricht.de` liegt bei **All-Inkl**, dafür existiert
das Caddy-Modul `caddy-dns/all-inkl`. Das Standard-`caddy`-Image enthält es
**nicht** – nötig wären ein eigener xcaddy-Build und die KAS-Zugangsdaten in
einer `600`-Datei auf dem Server, nie im Repository. **Die Umstellung ist
aufgeschoben**, solange unklar ist, ob die Zone bei All-Inkl bleibt und wer
DNS/Ports übernimmt. DNS-01 löst nur die ACME-Frage – der Nutzerverkehr
braucht weiterhin 80/443 bis zum Server.

### Betreiber (Auftraggeber)

1. **Vorab:** `sudo ./setup-coder.sh` am Zielserver ausführen (Warnung zu
   TLS ist bis zu Punkt 3 normal).
2. **DNS/Weiterleitung abwarten** (Netzwerkadmin-Zeilen 1–4).
3. **Zweiter Lauf:** `sudo ./setup-coder.sh` erneut ausführen –
   idempotent, erzeugt dann das Zertifikat bzw. meldet weiterhin WARN,
   falls es fehlt.
4. **Erstkonto anlegen – SOFORT, bevor die URL irgendjemand weitergegeben
   wird:** Wer sich als Erster anmeldet, wird automatisch Owner. Entweder
   beim ersten Lauf über die drei Variablen (nur so sieht das Skript sie):

   ```bash
   sudo env CODER_FIRST_USER_EMAIL='maximilian.hertenstein@ghse.de' \
            CODER_FIRST_USER_USERNAME='maximilian' \
            CODER_FIRST_USER_FULL_NAME='Maximilian Hertenstein' \
            ./setup-coder.sh
   ```

   Das Passwort fragt das Skript dabei interaktiv ab – gewollt und die
   einzige Eingabe des Laufs (nur solange kein Konto existiert, die
   Variablen gesetzt sind und stdin ein TTY ist; Enter ohne Eingabe
   überspringt die Anlage). In nicht-interaktiven Läufen das Passwort
   bevorzugt aus einer root-only Datei geben:

   ```bash
   read -rs -p 'Erstkonto-Passwort: ' _p; echo
   sudo sh -c 'umask 077; cat > /root/.erstkonto-passwort' <<< "$_p"
   unset _p
   sudo env CODER_FIRST_USER_PASSWORD_FILE=/root/.erstkonto-passwort ./setup-coder.sh
   sudo rm -f /root/.erstkonto-passwort
   ```

   Fallback: `CODER_FIRST_USER_PASSWORD='…'` direkt hinter dem sudo – steht
   kurz in `ps` und dauerhaft in der Shell-History; nie in Logs oder
   Tickets. Passwort: **lange Passphrase**, kein bekanntes Schulpasswort.
   Danach ein **zweites** Owner-Konto anlegen, damit die Administration
   nicht an einem Zugang hängt ([SECURITY.md](SECURITY.md) §1).
5. **Abnahme mit den Checks aus [Abschnitt 5](#5-checks-gesundheit-prüfen):**

   ```bash
   getent hosts coder.ghse-unterricht.de
   curl -s -o /dev/null -w '%{http_code}\n' https://coder.ghse-unterricht.de/healthz   # muss 200 sein
   docker logs coder-caddy --tail=50 | grep -i 'obtaining certificate\|error'          # muss leer bleiben
   sudo docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=8080--main--ws--user.coder.ghse-unterricht.de'   # ok
   ```

   Zusätzlich einen Test-Workspace anlegen und dessen App-URL **vom
   Schulnetz-Client** aus öffnen: der Workspace-Agent baut die Verbindung
   selbst auf (Hairpin-NAT), das prüft Port-Forwarding und Wildcard-DNS
   gemeinsam (TROUBLESHOOTING.md B6).

6. **Danach:** SSH-Nachhärtung nur auf gesonderten Wunsch per Drop-In-
   Snippet aus [SECURITY.md](SECURITY.md) §1, mit getestetem Key-Login und
   Zweit-Zugang. `RESTORE.md`-Restore-Probe einmalig durchspielen.

Die Wildcard-Zertifikate laufen über On-Demand-TLS mit dem gemeinsamen
Let's-Encrypt-Budget der Domain; eine automatische Budget-Überwachung gibt
es nicht, Erschöpfung fällt als HTTPS-Fehler auf (manuelle Sichtprüfung in
Abschnitt 5, Details TROUBLESHOOTING.md B3).
