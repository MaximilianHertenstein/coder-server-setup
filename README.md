# Coder-Server-Setup

Installation und Wartung eines Coder-Servers auf einer Debian-13-VM. Ein
Skript (`setup-coder.sh`) baut den kompletten Stack auf: Caddy (Reverse
Proxy + TLS), Coder, PostgreSQL, Prometheus/Grafana/node-exporter, Firewall
(ufw + fail2ban), automatische Sicherheitsupdates, tägliche Datenbank-Backups
und die Wartungsskripte für Backup, Reset und Workspace-Egress-Sperre.

Das Repository ist die Quelle. Alles Laufzeit-Relevante erzeugt das Skript
beim ersten Lauf unter `/opt/coder/` (`docker-compose.yml`, `Caddyfile`,
`.env`, Skripte, Cron-Dateien) – diese Dateien liegen bewusst nicht im
Repository.

## Doku-Landkarte

| Frage | Wo steht sie |
|---|---|
| Was ist das, wie installiere ich es? | diese Datei |
| Betrieb: Start/Stop, Checks, Logs, Wartung, Backup | [OPERATIONS.md](OPERATIONS.md) |
| Datenbank wiederherstellen | [RESTORE.md](RESTORE.md) |
| Härtung, SSH, Secrets, TLS, Firewall, Grenzen | [SECURITY.md](SECURITY.md) |
| Einen Fehler diagnostizieren und sicher beheben | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Was darf ein Workspace-Template? | [templates/allowlist.md](templates/allowlist.md) |

## Wo stehen wir

- **Das Setup läuft am Zielserver (Schulserver) durch** – Erstlauf und
  Re-Run ohne Fehler, Erstkonto `maximilian` angelegt. Es fehlt nur noch,
  was andere liefern müssen: DNS-Portweiterleitung 80/443 und das
  Proxmox-VM-Backup (siehe „Offene Punkte").
- **Getestet:** alle lokalen Tests (10 Dateien, 329 `PASS`, 0 `FAIL`),
  mehrfache Voll-Läufe auf einer Test-VM (je 0 `[FEHLER]`), Restore-Pfad A
  komplett geprobt (Datenprobe = 1, RTO rund 2 Minuten ohne VM-Boot).
- **Noch offen vor Freigabe:** RTO inkl. VM-Boot, `/healthz` unter echtem
  DNS (Portweiterleitung steht noch nicht), Restore-/Reset-Probe unter
  Last, Offsite-Zugriff proben, Produktionsfreigabe.
- **Offene Entscheidung nur noch eine:** DNS-01-Zugang beim Domainverwalter
  (bis dahin On-Demand-TLS). Alle übrigen Entscheidungen sind getroffen:
  [SECURITY.md](SECURITY.md) §9.

## Offene Punkte – wer macht was

Alles, was noch jemanden braucht, an einem Ort (Details in der verlinkten
Stelle):

| Was | Wer | Wo |
|---|---|---|
| DNS/Portlage: A-Record + Wildcard auf die Server-IP, 80/443 dorthin durchreichen (Netzwerkadmin-Zeilen 1–4). **Status 2026-10-14:** DNS (Apex+Wildcard) löst auf, Portweiterleitung fehlt noch – `/healthz` antwortet mit Code 000. Zone/Hosting + DNS-API-Token separat für DNS-01 | Netzwerkadmin/Domainverwalter; Betreiber fordert nur Zeilen 1–4 an | [OPERATIONS.md](OPERATIONS.md) §11 |
| Proxmox-VM-Backup (vzdump/PBS) um 02:00 einrichten, Ziel = anderer Storage/Host; dabei einmal prüfen, dass die Workspace-Homes wirklich in Docker-Volumes liegen; einmal Restore aus dem VM-Backup testen | Betreiber (Proxmox/PBS-Zugang) | [OPERATIONS.md](OPERATIONS.md) §7, [RESTORE.md](RESTORE.md) |
| Ersten Test-Workspace anlegen und dessen App-URL vom Schulnetz-Client öffnen (prüft Port-Forwarding + Wildcard-DNS, [TROUBLESHOOTING.md](TROUBLESHOOTING.md) B6); danach die Workspace-Container-Labels prüfen, die `reset-coder.sh` für den Verzeichnis-Cleanup braucht (ohne sie bricht der Reset hart ab) | Betreiber | [OPERATIONS.md](OPERATIONS.md) §11 |
| Template-Schritt 4 (Spielraum der Limits im Workspace) je Template abhaken – erst nach dem Vorführen der konkreten Templates | Betreiber | [templates/allowlist.md](templates/allowlist.md) |
| Alarmweg umsetzen: Grafana-Contact-Point an `hert@ghse.de` über IServ-SMTP, sobald IServ produktiv ist; bis dahin fängt der tägliche BackupStale-Routine-Check den kritischen Fall ab | Betreiber | [OPERATIONS.md](OPERATIONS.md) §6 |
| Offsite-Transport umsetzen: monatlicher verschlüsselter `rsync`-Pull der Backups auf externe Platte | Betreiber | [OPERATIONS.md](OPERATIONS.md) §8 |
| Produktionsfreigabe aussprechen – bewusst hier nicht dokumentiert | Betreiber | – |

Keine Freigabe für Produktion ist in diesem Repository dokumentiert.

**Zielbetrieb:** ein Schulserver (fresches Debian 13), per SSH nur aus dem
Schulnetz erreichbar. IServ und der zentrale Reverse-Proxy laufen auf einem
anderen Server – wie 80/443 zum Zielserver kommen und wer was anfordert,
steht komplett in [OPERATIONS.md](OPERATIONS.md) §11. Der Betreiber hat
keinen DNS-Zugang.

## Voraussetzungen

- [ ] Debian 13 (trixie), root-Zugang (`sudo`), Netzzugang zu
      `download.docker.com`, `ghcr.io` und den Debian-Servern. Das Setup
      prüft `ID` und `VERSION_CODENAME` und bricht vor Änderungen ab, wenn
      es nicht Debian „trixie" ist. Prüfung: `cat /etc/os-release`
- [ ] DNS: `coder.ghse-unterricht.de` **und** `*.coder.ghse-unterricht.de`
      (Wildcard, für Workspace-Apps) zeigen per A-Record auf die öffentliche
      IP des Servers. Prüfung: `getent hosts coder.ghse-unterricht.de` und
      `getent hosts setup-probe-1.coder.ghse-unterricht.de`
- [ ] Die Schulnetz-Infrastruktur leitet 80/tcp und 443/tcp (443/udp für
      HTTP/3 optional) an den Server weiter (Standard intern: 10.16.103.13).
      SSH/22 bleibt ausschließlich aus dem Schulnetz erreichbar; keine
      öffentliche SSH-Weiterleitung einrichten.
- [ ] Ausreichend Platte: Warnung unter 1 GB frei unter `/opt/coder`,
      Backup bricht unter 500 MB frei hart ab. Prüfung: `df -h /opt/coder`
- [ ] Ein zweiter Zugang (Konsole/Proxmox/iDRAC) existiert, falls du dich
      per SSH aussperrst.

Fehlt DNS oder Portweiterleitung, startet der Stack **trotzdem**: der
Abschlusscheck meldet es als WARNUNG. Danach das Skript einfach erneut
ausführen.

## Schneller Einstieg

```bash
git clone https://github.com/MaximilianHertenstein/coder-server-setup.git
cd coder-server-setup
chmod +x setup-coder.sh
sudo ./setup-coder.sh          # nur als root, sonst Abbruch vor Änderungen
```

`ACME_EMAIL` ist **Pflicht** (Kontakt-Adresse für Let's Encrypt, kein
Default; ohne Wert bricht das Setup vor jeder Serveränderung ab). Am
besten einmalig in `setup.conf` eintragen:

```bash
cp setup.conf.example setup.conf    # dann ACME_EMAIL=… eintragen
```

Umgebungsvariablen (hinter dem sudo, `sudo` leitet eigene Variablen nicht
durch) überschreiben `setup.conf`:

```bash
sudo env DOMAIN_CODER=coder.beispiel.de ACME_EMAIL=admin@beispiel.de ./setup-coder.sh
```

**Einziges Passwort-Prompt (Erstinstallation):** Existiert noch kein
Coder-Konto und sind `CODER_FIRST_USER_EMAIL`/`CODER_FIRST_USER_USERNAME`
gesetzt, fragt das Skript einmal **unsichtbar** das Passwort des Erstkontos
ab (nur mit TTY; Enter ohne Eingabe = Konto später selbst im Browser
anlegen). Sonst läuft der Lauf ohne jede Eingabe; nicht-interaktive
Variante in [OPERATIONS.md](OPERATIONS.md) §11.

**Erfolg bedeutet:** Exit-Code 0 (0 Einträge `[FEHLER]` in der
Zusammenfassung), `curl -s -o /dev/null -w '%{http_code}\n'
https://coder.ghse-unterricht.de/healthz` liefert `200`, ein Backup existiert
(`ls -t /opt/coder/backups/coder_*.sql.gz | head -n1`).

Danach: Zugangsdaten aus `/opt/coder/.env` (nur root lesbar) sichern,
[OPERATIONS.md](OPERATIONS.md) lesen, ersten Restore-Test auf einer
isolierten Test-VM nach [RESTORE.md](RESTORE.md) fahren. Das Skript ist auf
erneutes Ausführen ausgelegt (Re-Run).

## Was im Repo liegt

| Datei | Zweck |
|---|---|
| `setup-coder.sh` | Das Setup-Skript (8 Schritte, `set -euo pipefail`, mehrfach ausführbar) |
| `scripts/` | Wartungsskripte (`backup.sh`, `reset-coder.sh`, `workspace-egress.sh`); das Setup schreibt sie nach `/opt/coder/` |
| `setup.conf.example` | Vorlage für `setup.conf` (Domain, ACME-Adresse **Pflicht**, ACME-CA, fail2ban-Ignore-IP); `setup.conf` selbst ist gitignored |
| `RESTORE.md` | Wiederherstellungs-Runbook (wird auf den Server nach `/opt/coder/RESTORE.md` kopiert) |
| `templates/allowlist.md` | Regelwerk für Workspace-Templates (Docker-Socket ist host-root-äquivalent) |
| `tests/` | 10 lokale Prüfskripte (ohne Docker und ohne Produktion) |

## Was das Setup-Skript macht

| # | Schritt | Ergebnis |
|---|---|---|
| 1 | Grundpakete und Docker Engine | apt-Repo mit Fingerprint-Prüfung, `docker-ce` + Compose-Plugin, Log-Limit 10 MB × 3, `qemu-guest-agent` (nur wenn die VM den virtio-Serial-Channel hat) |
| 2 | Verzeichnis und Konfiguration | `/opt/coder/` mit `.env` (nur beim ersten Lauf), Compose, Caddyfile (On-Demand-TLS mit lokalem `ask`-Endpunkt), Prometheus + drei Alarmregeln, Grafana-Provisioning, Wartungsskripte – jedes Schreiben atomar mit Validierung, danach `docker compose pull` |
| 3 | Docker-Stack starten | `up -d`; laufende Caddy/Prometheus werden per reload/SIGHUP neu geladen, Grafana nur bei geänderter Provisioning-Datei neu gestartet |
| 4 | Firewall + SSH-Schutz | ufw (deny incoming; `deny` für Docker-Netze am sshd-Port **vor** dem `allow`; 80/443 frei), fail2ban-Jail `sshd`, SSH-Drop-In, Workspace-Egress-Sperre, Abschluss-Checks |
| 5 | Automatische Sicherheitsupdates | unattended-upgrades, Reboot 03:00; Docker Engine bleibt manuell |
| 6 | Tägliches Datenbank-Backup | `backup.sh`, Cron 01:00, logrotate, Testlauf, Kopie der `RESTORE.md`, Erfolgs-Metrik |
| 7 | Abschlusscheck & Zusammenfassung | Container, Socket-GID, `/healthz`, Wildcard-DNS, Nutzer-/Owner-Hinweis; `[FEHLER]` → Exit 1 |

Verwaltete Dateien werden atomar geschrieben und bei Abweichung
deterministisch neu gesetzt – Hand-Anpassungen an generierten Dateien
gehen beim nächsten Lauf verloren; gewollte Anpassungen gehören ins
Repository oder in ein eigenes vorrangiges Drop-In, Details in
[OPERATIONS.md](OPERATIONS.md) §7.

## Architektur in Kurzform

| Dienst | Image (Pin) | Port | Zugang |
|---|---|---|---|
| Caddy | `caddy:2.11` (Minor-Pin) | 80/tcp, 443/tcp, 443/udp | öffentlich |
| Coder | `ghcr.io/coder/coder:v2.37.3` (exakt) | intern 3000 | nur über Caddy |
| PostgreSQL | `postgres:18-alpine` | keiner | nur im Compose-Netz |
| Prometheus | `prom/prometheus:v3.15.0` (exakt) | 127.0.0.1:9090 | lokal |
| node-exporter | `prom/node-exporter:v1.12.1` (exakt) | 127.0.0.1:9100 | lokal |
| Grafana | `grafana/grafana:12.4.12` (exakt) | 127.0.0.1:3001 (keine ufw-Regel) | ausschließlich per SSH-Tunnel |
| sshd, ufw, fail2ban, Cron | Debian-Pakete | 22/tcp | ufw `allow` + fail2ban |

Volumes: `postgres_data`, `caddy_data`, `caddy_config`, `prometheus_data`,
`grafana_data`. Container-Logs: `json-file`, 10 MB × 3 je Container.
Caddy- und Prometheus-Konfiguration werden als **Verzeichnisse** gebunden
statt als Einzeldatei (ein Datei-Mount hält am Inode fest und würde nach
dem atomaren Schreiben des Setups die alte Fassung zeigen).

## Wichtigste Konfiguration

Defaults stehen im Kopf von `setup-coder.sh`, überschreibbar per
`setup.conf` oder Umgebungsvariable – Vorrang: Env > `setup.conf` > Default:

| Variable | Default | Bedeutung |
|---|---|---|
| `DOMAIN_CODER` | `coder.ghse-unterricht.de` | Access-URL und Wildcard `*.…` |
| `ACME_EMAIL` | **Pflicht** (kein Default) | Let's-Encrypt-Kontaktadresse; ohne Wert bricht das Setup vor jeder Änderung ab |
| `CODER_VERSION` | `v2.37.3` | exakter Coder-Image-Tag (mit `v`) |
| `CADDY_VERSION` | `2.11` | Minor-Pin, Patch-Updates per `compose pull` |
| `PROMETHEUS_VERSION` | `v3.15.0` | exakter Pin |
| `GRAFANA_VERSION` | `12.4.12` | exakter Pin |
| `NODE_EXPORTER_VERSION` | `v1.12.1` | exakter Pin |
| `CODER_ALLOW_DOWNGRADE` | (leer) | nur `yes` erlaubt ein bewusstes Zurücksetzen einer Version |
| `ACME_CA` | (leer) | optionaler eigener ACME-Endpunkt, z. B. Let's-Encrypt-Staging |
| `FAIL2BAN_IGNORE_IP` | `127.0.0.1/8 ::1` | komma-getrennte Admin-Adressen, die fail2ban nicht bannen darf |

Updates laufen über einen erneuten Lauf von `setup-coder.sh` (Ablauf:
[OPERATIONS.md](OPERATIONS.md) §7). Neu hinter beweglichen Tags (`caddy:2.11`,
`postgres:18-alpine`) kommen automatisch mit; Coder, Prometheus, Grafana und
node-exporter sind exakt gepinnt – für deren Versionswechsel den Pin in
`setup-coder.sh` ändern und das Setup erneut ausführen. Docker-Engine-Updates
sind davon getrennt und manuell. PostgreSQL 18 (Major-Tag `postgres:18-alpine`)
holt 18.x-Patches per `pull`; ein Major-Wechsel ist kein Tag-Wechsel, sondern
Dump/Restore in einem Wartungsfenster ([RESTORE.md](RESTORE.md)).

## Sicherheit und Hardening (Kurzfassung)

- **Docker-Socket**: Der Coder-Container hält `/var/run/docker.sock`
  schreibbar – bei Kompromittierung eines Workspaces ist der Host
  kompromittierbar. Abfengerung: [templates/allowlist.md](templates/allowlist.md)
  (Dauerregel, keine zweite VM – entschieden).
- **SSH**: Port 22 laut Netzvorgabe nur aus dem Schulnetz; Passwort-Login
  bleibt bewusst an, Root nur per Schlüssel. ufw `allow` ohne `limit`
  (würde die geteilte Schul-NAT drosseln), fail2ban sperrt nach 5
  Fehlversuchen/10 min für 1 h. Key-only-Nachhärtung als vorrangiges
  Drop-In: [SECURITY.md](SECURITY.md) §1.
- **Firewall**: ufw `default deny incoming`; 80/443 frei; alle übrigen
  Dienste ausschließlich an `127.0.0.1` gebunden. Workspace-Container
  erreichen RFC1918 außerhalb der Docker-Netze nicht (Egress-Sperre).
- **Secrets**: `.env` mit 600/root, generierte Passwörter hex, kein Secret
  im Repository, Rotation manuell ([OPERATIONS.md](OPERATIONS.md) §7).
- **TLS**: Caddy On-Demand-TLS mit Wildcard; ein lokaler `ask`-Endpunkt
  erlaubt nur Coder-App-Subdomänen. Das Let's-Encrypt-Wochenbudget (50/
  Domain) ist mit allen Schuldiensten geteilt und wird **nicht**
  automatisch überwacht – Grenzen: [SECURITY.md](SECURITY.md) §3.
- **Updates**: Debian-Paketupdates inkl. Reboot um 03:00 (Dauerregel);
  Stack-/Engine-Updates manuell im monatlichen Update-Fenster
  ([OPERATIONS.md](OPERATIONS.md) §7).

## Backup und Restore (Kurzfassung)

- Täglich 01:00 Uhr: `pg_dump` nach `/opt/coder/backups/`, verifiziert,
  Rotation: neueste 14 Dumps; dazu eine `.env`-Kopie.
- **Gesichert ist nur die Datenbank** (bis das Proxmox-VM-Backup läuft):
  nicht gesichert sind `.env`, Stack-Konfiguration, Zertifikate,
  Grafana-Dashboards und Workspace-Dateien (die über das VM-Backup
  mitgesichert werden).
- **Offsite:** entschieden (vzdump/PBS auf anderem Storage/Host +
  monatlicher verschlüsselter `rsync`-Pull), Umsetzung offen.
- Ein grünes Backup ist **kein** Restore-Nachweis: Restore-Probe auf
  Test-VM, Ablauf in [RESTORE.md](RESTORE.md). **Nie zum ersten Mal auf
  Produktion restoren.**

## Testen

Lokal ausführbar (kein Docker, kein Root, keine Produktion):

```bash
bash -n setup-coder.sh scripts/*.sh tests/*.sh
shellcheck -S warning setup-coder.sh scripts/*.sh tests/*.sh
for f in tests/*.sh; do bash "$f" || echo "ROT: $f"; done
```

Aktueller Stand: alle 10 Testskripte Exit 0 (329 `PASS`, 0 `FAIL`);
`bash -n` und `shellcheck -S warning` ohne Befund. Die Tests belegen das
Verhalten einzelner Codestellen anhand von Fakes und Fixtures – **nicht**
einen vollständigen Setup-Lauf, echtes ufw/fail2ban/Docker/Caddy-Verhalten
oder Reboots. Dafür braucht es eine isolierte Test-VM.

Auf dem Server zusätzlich sinnvoll:

```bash
sudo docker compose -f /opt/coder/docker-compose.yml config --quiet
sudo /opt/coder/backup.sh
```

## Betrieb und Wartung

Kurz: Stack steuern über `cd /opt/coder && sudo docker compose …`,
Updates über einen erneuten Lauf von `setup-coder.sh`, kompletter Reset
über `sudo /opt/coder/reset-coder.sh` (nach Backup und Bestätigung).

Vollständig – Start/Stop, Checks, Logs, automatische Aufgaben, Update,
Reboot, Reset, Backup-Steckbrief: **[OPERATIONS.md](OPERATIONS.md)**.

## Troubleshooting-Einstieg

Die drei ersten Befehle bei jedem Verdacht:

```bash
cd /opt/coder && sudo docker compose ps
sudo docker logs coder --tail=50
sudo docker logs coder-postgres --tail=50
```

Danach Fehlerbild suchen – Diagnose, Ursachen und sichere Behebung stehen
in **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**. Grundregel: bei rot nicht
weiter auf dem Produktionssystem herumprobieren, erst diagnostizieren. Kein
Fehlerbild wird durch Abschalten von Prüfungen, Zurücksetzen von
Firewall-Regeln oder übersprungener Verifikation „gelöst".
