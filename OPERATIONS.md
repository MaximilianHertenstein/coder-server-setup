# OPERATIONS.md – Betrieb und Wartung

Stand: 2026-09-28. Grundlage: das tatsächlich im Repository stehende
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
| `/opt/coder/prometheus.yml` | Scrape-Jobs `coder`, `node` | ja |
| `/opt/coder/backup.sh` | tägliche Datenbank-Sicherung | ja |
| `/opt/coder/update.sh` | manuelles Update mit Pre-Backup und Health-Gate | ja |
| `/opt/coder/reset-passwords.sh` | Passwort-Rotation Postgres + Grafana | ja |
| `/opt/coder/reset-coder.sh` | Komplett-Reset des Coder-Stacks | ja |
| `/opt/coder/boot-check.sh` | lesendes Boot-Gate nach Reboot | ja |
| `/opt/coder/check-tls.sh` | zählt Let's-Encrypt-Ausstellungen (7 Tage) | ja |
| `/opt/coder/RESTORE.md` | Runbook-Kopie (Quelle liegt im Repository) | nein |
| `/opt/coder/.generated-hashes` | sha256 der 15 generierten Dateien (600, root) | – |
| `/etc/cron.d/coder-backup` | Cron: täglich 01:00 | ja |
| `/etc/cron.d/coder-tlscheck` | Cron: Montag 06:30 | ja |
| `/etc/cron.d/coder-bootcheck` | Cron: `@reboot` | ja |
| `/etc/logrotate.d/coder-backup` | Rotation `/var/log/coder-backup.log` | ja |
| `/etc/fail2ban/jail.local` | Jail `sshd` (backend systemd) | ja |
| `/etc/apt/apt.conf.d/52-coder-reboot` | automatischer Reboot 03:00 | ja |
| `/etc/apt/apt.conf.d/20auto-upgrades` | via debconf von unattended-upgrades | nein |
| `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.gpg` | Docker-apt-Repo (Fingerprint geprüft) | nein |

Nicht im Repository, nur auf dem Server: alle Backups, `.env`-Sicherungen
(`.env.bak.*`, genau eine Generation), Logs.

## 3. Konfigurationsvariablen

Überschreibbar per Umgebungsvariable beim Aufruf, ohne Datei zu ändern:
`DOMAIN_CODER`, `ACME_EMAIL`, `CODER_VERSION`, `CADDY_VERSION`,
`PROMETHEUS_VERSION`, `GRAFANA_VERSION`, `NODE_EXPORTER_VERSION`, dazu
`CODER_ALLOW_SSH_DOWNGRADE` (nur `yes`, siehe [SECURITY.md](SECURITY.md)).
Defaults und Pin-Regeln: [README.md](README.md), Abschnitt „Wichtigste
Konfiguration".

**Secrets-Verfahren**

- Erstpasswörter werden beim ersten Lauf erzeugt und stehen in der
  Ausgabe des Skripts und in `/opt/coder/.env` (600, root:root).
- Eine unvollständige `.env` wird nie still neu gewürfelt – das Setup
  bricht ab und nennt die Reparatur.
- Passwörter müssen hex sein (`[0-9a-f]`); sonst bricht das Setup ab und
  verweist auf `reset-passwords.sh`.
- Rotation: `sudo /opt/coder/reset-passwords.sh` (zieht zuerst ein
  Backup, legt `.env.bak.<Zeitstempel>` an, gibt die neuen Werte aus).
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
`Caddyfile` nicht automatisch. Das Setup startet Caddy nur neu, wenn der
Hash der Datei sich geändert hat und Caddy vorher lief (blinder Restart
hieße TLS-Unterbrechung). Bei eigener Änderung der Caddyfile also explizit:

```bash
sudo docker compose restart caddy
```

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
```

Firewall/SSH-Checks:

```bash
sudo ufw status verbose
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

### Empfohlene Routine

| Rhythmus | Was | Befehl/Ort |
|---|---|---|
| täglich | Backup vorhanden und aktuell | `ls -t /opt/coder/backups/coder_*.sql.gz \| head -n1` |
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
- Es ist **kein Alerting** eingerichtet (kein Alertmanager, keine
  Benachrichtigungsregeln). Metriken sind nur sichtbar, wer sie ansieht.

## 7. Wartung

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
- Exakt gepinnte Images (Coder, Prometheus, Grafana) kann man durch
  Setzen der Version in `setup-coder.sh` + erneuten Setup-Lauf
  zurückrollen. `CADDY_VERSION` (Minor) und `postgres:15-alpine` holen
  beim `pull` ggf. ein neueres Bild.
- Prometheus-/Grafana-Änderungen brauchen einen erneuten Lauf von
  `setup-coder.sh`; `update.sh` allein zieht nur, was in der
  `docker-compose.yml` steht.
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

### Reboot

- Automatisch bei Kernel-Updates um 03:00 Uhr
  (`/etc/apt/apt.conf.d/52-coder-reboot`) – **Fenster ist nicht mit dem
  Schulbetrieb abgestimmt**; laufende Workspaces/Sessions werden
  abgerissen.
- Nach jedem Reboot schreibt `boot-check.sh` (per `@reboot`) nach
  `/var/log/coder-boot.log` und ins Journal: Container-Status, Postgres
  `healthy`, `/healthz` 200 innert 5 Minuten. Das Gate ist **lesend**
  – es ändert nichts am Stack, es meldet nur.
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

Das Setup hält sha256 der 15 generierten Dateien in
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
| Parallelität | Self-`flock`; zweiter Lauf wird übersprungen und meldet Alter des letzten Backups |
| Mindestplatz | 500 MB frei, sonst Abbruch ohne Datei |
| Offsite | **nicht eingerichtet** |

Zusätzlich ziehen `update.sh` und `reset-passwords.sh` vor dem Eingriff
ein Backup; `reset-coder.sh` ebenfalls (Abbruch ohne Backup, außer
`--force`).

Ein grünes Backup ist **kein** Restore-Nachweis. Verifikation und
Ablauf: [RESTORE.md](RESTORE.md).

```bash
# Zustand prüfen
ls -lt /opt/coder/backups/ | head
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
| Sicherheitsupdates + Reboot 03:00 | Debian-Default | unattended-upgrades, `52-coder-reboot` |
| Coder-Update | **nie automatisch** | `update.sh` wird manuell aufgerufen |

Prüfen: `systemctl is-active cron`, `ls -l /etc/cron.d/`,
`sudo systemctl status unattended-upgrades --no-pager`.

## 10. Tests

```bash
bash -n setup-coder.sh ssh-harden.sh
shellcheck -S warning setup-coder.sh ssh-harden.sh
for f in tests/*.sh; do bash "$f"; done
```

Stand 2026-09-28 (tatsächlich ausgeführt): 8/8 Skripte Exit 0, 251 `PASS`,
0 `FAIL`; ShellCheck `-S warning` genau ein Befund (SC2034).

Die Skripte arbeiten mit Fakes/Fixtures in `/tmp` – sie brauchen weder
Root noch Docker und berühren keine Produktion. Sie belegen das Verhalten
einzelner Codestellen, **nicht** den Gesamtlauf. VM-Pflichtige Prüfungen
stehen in [README.md](README.md), Abschnitt „Nur auf einer Test-VM bzw. in
Produktion zu verifizieren".
