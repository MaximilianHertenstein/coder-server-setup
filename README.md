# Coder-Server-Setup

Installation und Wartung eines Coder-Servers auf einer Debian-13-VM: ein
Skript (`setup-coder.sh`) baut den kompletten Stack auf – Caddy (Reverse
Proxy + TLS), Coder, PostgreSQL, Prometheus/Grafana/node-exporter, Firewall
(ufw + fail2ban), automatische Sicherheitsupdates, tägliche Datenbank-Backups
und die Wartungsskripte für Update, Passwort-Rotation und Reset.

Das Repository ist die **Quelle**. Alles Laufzeit-Relevante wird beim ersten
Lauf auf dem Server unter `/opt/coder/` erzeugt (`docker-compose.yml`,
`Caddyfile`, `.env`, Skripte, Cron-Dateien) – diese Dateien liegen bewusst
nicht im Repository.

## Doku-Landkarte

| Frage | Wo steht sie |
|---|---|
| Was ist das, wie installiere ich es? | diese Datei |
| Betrieb: Start/Stop, Checks, Logs, Wartung, Backup | [OPERATIONS.md](OPERATIONS.md) |
| Datenbank wiederherstellen | [RESTORE.md](RESTORE.md) |
| Härtung, SSH, Secrets, TLS, Firewall, Grenzen | [SECURITY.md](SECURITY.md) |
| Einen Fehler diagnostizieren und sicher beheben | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Was wurde wann geändert? | [CHANGELOG.md](CHANGELOG.md) |
| Welches Workspace-Template darf was? | [templates/allowlist.md](templates/allowlist.md) |
| Befunde, Pläne, Prüfprotokolle (Referenz) | `ai-review/` – keine Lese-Pflicht für den Betrieb; Auswertung der letzten Runde: [ai-review/REVIEW-2026-09-29-AUSWERTUNG.md](ai-review/REVIEW-2026-09-29-AUSWERTUNG.md) |

## Status (Stand 2026-09-29)

| Punkt | Stand |
|---|---|
| Quellstand | Branch `main`, letzter Commit `252ebc8` (Review-Runde 1, Phasen 1–7); die Änderungen der **Review-Runde 2** (zweite Fundliste) sind im Arbeitsstand **nicht committet** (siehe [CHANGELOG.md](CHANGELOG.md)) |
| Lokale Tests | 10 Skripte in `tests/`, alle 2026-09-29 ausgeführt: 10× Exit 0, 316 `PASS`, 0 `FAIL` (Drift-Test jetzt auf 17 Dateien) |
| Syntax/ShellCheck | `bash -n` für `setup-coder.sh` und `ssh-harden.sh` OK; `shellcheck -S warning` meldet genau einen Befund (SC2034, ungenutzter Zähler), `ssh-harden.sh` ohne Befund |
| Vollständiger Setup-Lauf auf echtem System | 2026-09-29 auf dem Test-Host `2.29.11.30` (Debian 13): Läufe 8 und 9 (Review-Runde 1) sowie **Läufe 10 und 11** (Review-Runde 2) je Exit 0, 0 `[FEHLER]`, 0 Drift; Lauf 11 ohne Container-Neustart (Idempotenz), Lauf 10 startete nur Prometheus neu (4. Alarmregel). **TLS bleibt offen** – `…/healthz` lief in den Läufen 3 bis 11 nie HTTP 200, weil ein externer nginx am öffentlichen IP 80/443 beantwortet (Details [CHANGELOG.md](CHANGELOG.md)) |
| Restore-Test | **nicht geprobt**, RTO unbekannt ([RESTORE.md](RESTORE.md)) |
| Offsite-Backup | **nicht eingerichtet** – Platten-/Hostverlust = Datenbank + Backups weg |
| SSH-Härtung | **Minimalvariante** (Entscheidung 2026-09-29): Schutz gegen fehlgeschlagene Logins läuft (ufw `limit 22/tcp` + fail2ban, Root-Passwort-Login gesperrt); Zielserver ist **derzeit nur per Passwort** erreichbar → erst Key setzen und testen, dann ggf. `ssh-harden.sh` ([SECURITY.md](SECURITY.md) §1) |
| Offene Befunde | u. a. B5 (Client-IPs im Audit: Env-Namen belegt, aus Datenschutzgründen bewusst nicht gesetzt), DNS-01 als Alternative nur dokumentiert – Details [CHANGELOG.md](CHANGELOG.md) |

Keine Freigabe für Produktion ist in diesem Repository dokumentiert.

**Zielbetrieb:** ein Schulserver, per SSH nur aus dem Schulnetz bzw. per VPN
erreichbar; die Weiterleitung der Weboberfläche (80/443) muss noch durch einen
Netzwerkadmin umgesetzt werden – bis dahin kann das Setup dort keine
Zertifikate ausstellen. Der aktuelle Test-Host `2.29.11.30` ist eine
Hetzner-VM, die irgendwann abgeschaltet wird. **Wer was macht** (DNS +
Wildcard, Portweiterleitung, Abnahme): [OPERATIONS.md](OPERATIONS.md)
Abschnitt 11.

## Was im Repo liegt

| Datei | Zweck |
|---|---|
| `setup-coder.sh` | Das Setup-Skript (10 Schritte, `set -euo pipefail`, mehrfach ausführbar) |
| `ssh-harden.sh` | Vorbereiteter SSH-Härtungspfad, **wird nicht vom Setup aufgerufen** |
| `RESTORE.md` | Wiederherstellungs-Runbook (wird auf den Server nach `/opt/coder/RESTORE.md` kopiert) |
| `templates/allowlist.md` | Regelwerk für Workspace-Templates (Docker-Socket ist host-root-äquivalent) |
| `tests/` | 10 lokale Prüfskripte (STATIC/UNIT-LIKE, ohne Docker und ohne Produktion) |
| `ai-review/` | Reviews, Pläne, Implementierungsberichte (B-/B2-/P-/F-Nummern) |

## Was das Setup-Skript macht

Aufruf als Benutzer mit sudo-Rechten: `./setup-coder.sh`

| # | Schritt | Ergebnis |
|---|---|---|
| 1 | Docker Engine installieren | apt-Repo + Fingerprint-Prüfung des Docker-GPG-Keys, `docker-ce` + Compose-Plugin, `daemon.json` (Log-Limit 10 MB × 3) |
| 2 | Verzeichnis und Konfiguration anlegen | `/opt/coder/`, `.env` (nur beim ersten Lauf), `docker-compose.yml`, `Caddyfile` (On-Demand-TLS mit lokalem `ask`), `prometheus.yml` + `rules/coder-alerts.yml`, Grafana-Datasource-Provisioning, `node-textfile/` |
| 3 | Docker-Stack starten | Preflights (Daemon, fremde Listener, Platte), `docker compose config --quiet`, Pull + `up -d`, Caddy bei Änderung `validate` + `reload`, Prometheus/Grafana nur bei Konfigurationsänderung neu |
| 4 | Firewall + SSH-Schutz | ufw (Default deny incoming), `ufw limit 22/tcp`, 80/443 frei, fail2ban-Jail `sshd`, Abschluss-Checks |
| 5 | Automatische Sicherheitsupdates | unattended-upgrades inkl. Docker-Origin (C6), Reboot 03:00, lesendes Boot-Gate (`boot-check.sh`), TLS-Zählung (`check-tls.sh`) |
| 6 | Tägliches Datenbank-Backup | `backup.sh`, Cron 01:00 (`/etc/cron.d/coder-backup`), logrotate, Testlauf, Kopie der `RESTORE.md`, Erfolgs-Metrik nach `node-textfile/` |
| 7 | Update-Skript | `update.sh` (manuell, kein Cronjob) mit Pre-Backup und Health-Gate |
| 8 | Passwort-Reset-Skript | `reset-passwords.sh` (Postgres + Grafana, atomare `.env`-Aktualisierung) |
| 9 | Komplett-Reset-Skript | `reset-coder.sh` (Inventar → Backup → Bestätigung → Volumes + `.env`) |
| 10 | Abschlusscheck & Zusammenfassung | Container, Socket-GID, `https://…/healthz`, Wildcard-DNS, Nutzer-/Owner-Hinweis (B2), `[FEHLER]`-Zähler → Exit 1 bei Fehlern |

Jeder erzeugten Datei wird beim Schreiben ein Hash in
`/opt/coder/.generated-hashes` zugeordnet. Weicht eine Datei ab (Operator-
Tuning), meldet der nächste Lauf eine **WARNUNG** und schreibt die Datei
deterministisch neu – Hand-Anpassungen gehen dabei verloren, Details in
[OPERATIONS.md](OPERATIONS.md).

## Architektur in Kurzform

| Dienst | Image (Pin) | Port | Zugang |
|---|---|---|---|
| Caddy | `caddy:2.10` (Minor-Pin) | 80/tcp, 443/tcp, 443/udp | öffentlich |
| Coder | `ghcr.io/coder/coder:v2.36.6` (exakt) | intern 3000 | nur über Caddy |
| PostgreSQL | `postgres:15-alpine` | keiner | nur im Compose-Netz |
| Prometheus | `prom/prometheus:v3.14.0` (exakt) | 127.0.0.1:9090 | lokal |
| node-exporter | `prom/node-exporter:v1.12.1` (exakt) | 127.0.0.1:9100 | lokal |
| Grafana | `grafana/grafana:12.4.5` (exakt) | 127.0.0.1:3001 | lokal, per SSH-Tunnel |
| sshd, ufw, fail2ban, Cron | Debian-Pakete | 22/tcp | ufw `limit` + fail2ban |

Volumes: `postgres_data`, `caddy_data`, `caddy_config`, `prometheus_data`,
`grafana_data`. Container-Logs: `json-file`, 10 MB × 3 Dateien je Container
(daemon-weit in `daemon.json` festgelegt, nicht nur compose-seitig).
Bind-Mounts aus `/opt/coder/`: `prometheus.yml`, `rules/` (vier Alarmregeln,
dazu TLS-Ausstellungen >20 pro 7 Tage), `grafana/provisioning/datasources/`
und `node-textfile/` (Backup- und TLS-Metrik für den textfile-collector von
node-exporter).

## Voraussetzungen

- [ ] Debian 13 (trixie), sudo-Rechte, Netzzugang zu `download.docker.com`,
      `ghcr.io` und den Debian-Servern.
      Prüfung: `lsb_release -a`
- [ ] DNS: `coder.ghse-unterricht.de` **und** `*.coder.ghse-unterricht.de`
      (Wildcard, für Workspace-Apps) zeigen per A-Record auf die öffentliche
      IP des Servers.
      Prüfung: `getent hosts coder.ghse-unterricht.de` und
      `getent hosts setup-probe-1.coder.ghse-unterricht.de`
- [ ] Die Schulnetz-Infrastruktur leitet 80/tcp, 443/tcp (und 443/udp für
      HTTP/3) sowie 22/tcp an den Server weiter (Standard intern:
      10.16.103.13).
- [ ] Ausreichend Platte: Warnung unter 1 GB frei unter `/opt/coder`,
      Backup bricht unter 500 MB frei hart ab.
      Prüfung: `df -h /opt/coder`
- [ ] Ein zweiter Zugang (Konsole/Proxmox/iDRAC) existiert, falls du dich
      per SSH aussperrst.
- [ ] Der aktuelle Stand des Repos ist bekannt:
      `git log -1 --oneline` und `git status`

Fehlt DNS oder Portweiterleitung, startet der Stack **trotzdem**: der
Abschlusscheck meldet es als WARNUNG. Danach das Skript einfach erneut
ausführen.

## Schneller Einstieg

```bash
git clone https://github.com/MaximilianHertenstein/coder-server-setup.git
cd coder-server-setup
git log -1 --oneline          # Stand notieren
chmod +x setup-coder.sh
./setup-coder.sh              # sudo wird intern benötigt
```

Optional vor dem Lauf (Überschreiben der Defaults, ohne Datei zu ändern):

```bash
DOMAIN_CODER=coder.beispiel.de ACME_EMAIL=admin@beispiel.de ./setup-coder.sh
```

**Erfolgsdefinition**

1. Exit-Code `0` (die Zusammenfassung meldet 0 Einträge `[FEHLER]`),
2. `curl -s -o /dev/null -w '%{http_code}\n' https://coder.ghse-unterricht.de/healthz`
   liefert `200`,
3. die Warnung zum SSH-Passwort-Login bleibt bis zur Härtung erwartbar
   (siehe [SECURITY.md](SECURITY.md)),
4. ein Backup existiert: `ls -t /opt/coder/backups/coder_*.sql.gz | head -n1`.

Das Skript ist auf erneutes Ausführen ausgelegt (Re-Run). Ob ein zweiter
Lauf auf einem bereits laufenden Stack in jeder Hinsicht sauber durchläuft,
ist eine **VM-Prüfung**.

Danach: Zugangsdaten aus `/opt/coder/.env` (nur root lesbar) sichern,
[OPERATIONS.md](OPERATIONS.md) lesen, ersten Restore-Test auf einer
isolierten Test-VM nach [RESTORE.md](RESTORE.md) fahren.

## Wichtigste Konfiguration

Alle Defaults stehen im Kopf von `setup-coder.sh` und sind als
Umgebungsvariable überschreibbar:

| Variable | Default | Bedeutung |
|---|---|---|
| `DOMAIN_CODER` | `coder.ghse-unterricht.de` | Access-URL und Wildcard `*.…` |
| `ACME_EMAIL` | `hert@ghse.de` | Let's-Encrypt-Benachrichtigungsadresse |
| `CODER_VERSION` | `v2.36.6` | exakter Coder-Image-Tag (mit `v`) |
| `CADDY_VERSION` | `2.10` | Minor-Pin, Patch-Updates per `compose pull` |
| `PROMETHEUS_VERSION` | `v3.14.0` | exakter Pin |
| `GRAFANA_VERSION` | `12.4.5` | exakter Pin |
| `NODE_EXPORTER_VERSION` | `v1.12.1` | exakter Pin |
| `CODER_ALLOW_SSH_DOWNGRADE` | (leer) | nur `yes` erlaubt einen Re-Run, der eine vorgefundene restriktive SSH-Regel ersetzt |
| `CODER_ALLOW_DOWNGRADE` | (leer) | nur `yes` erlaubt ein bewusstes Zurücksetzen einer Version (A5-Downgrade-Schutz) |
| `ACME_CA` | (leer) | optionaler eigener ACME-Endpunkt, z. B. Let's-Encrypt-Staging statt Produktions-CA |

Versionen ändern sich nie von selbst. Prometheus-/Grafana-Updates brauchen
einen erneuten Lauf von `setup-coder.sh`, `update.sh` allein reicht nicht
(exakte Pins). Die vollständige Dateiliste, Cron-Zeiten und
Wartungsverfahren stehen in [OPERATIONS.md](OPERATIONS.md).

## Sicherheit und Hardening (Kurzfassung)

- **SSH**: Port 22 ist von überall erreichbar, aber rate-limitiert
  (`ufw limit 22/tcp`) und über fail2ban abgesichert. Passwort-Login bleibt
  aktiv, bis `ssh-harden.sh` bewusst ausgeführt wird – dieses verlangt zwei
  Bestätigungsflags (`--i-have-key-access --i-have-second-access`), einen
  vorhandenen SSH-Key und bestätigt den Zweit-Zugang.
- **Firewall**: ufw mit `default deny incoming`; 80/443 (tcp+udp) frei.
  Prometheus, node-exporter und Grafana sind ausschließlich an
  `127.0.0.1` gebunden.
- **Docker-Socket**: Der Coder-Container hält `/var/run/docker.sock`
  schreibbar – bei Kompromittierung eines Workspaces ist der Host
  kompromittierbar. Abfederung: [templates/allowlist.md](templates/allowlist.md).
- **Secrets**: `.env` mit 600/root, Passwörter ausschließlich hex,
  Rotation über `reset-passwords.sh`. Kein Secret im Repository
  (`.gitignore`).
- **TLS**: Caddy On-Demand-TLS mit Wildcard. Der `ask`-Endpunkt
  (`127.0.0.1:9123`, nur im Container erreichbar) prüft den beantragten
  Namen gegen das Coder-App-Subdomänen-Muster und antwortet mit 200 oder
  404 – Namen außerhalb des Musters bekommen kein Zertifikat. Das Muster
  ist bewusst ein **Filter, kein Budgetschutz**: für Namen darin kann ein
  Angreifer das Zertifikat weiterhin auslösen, das Let's-Encrypt-
  Wochenbudget (50/Domain) bleibt mit allen Schuldiensten geteilt
  (Grenzen und Folgen: [SECURITY.md](SECURITY.md)).
- **Updates**: unattended-upgrades inkl. automatischem Reboot um 03:00 Uhr
  (Betriebsfenster ist **nicht** mit dem Schulbetrieb abgestimmt).

Grenzen, Nachweisbefehle und offene Entscheidungen: [SECURITY.md](SECURITY.md).

## Backup und Restore (Kurzfassung)

- Täglich 01:00 Uhr: `pg_dump` nach `/opt/coder/backups/coder_<Zeitstempel>.sql.gz`,
  verifiziert (`gzip -t` + SQL-Header), 600/root, 700 für das Verzeichnis,
  Rotation: neueste 14 Dumps.
- **Gesichert ist nur die Datenbank.** Nicht gesichert: `.env` (alle
  Passwörter), Compose-/Caddy-/Prometheus-Config, Zertifikate,
  Grafana-Dashboards, Prometheus-Historie, Workspace-Dateien.
- **Offsite fehlt** – es gibt aktuell nur diese eine Kopie auf derselben Platte.
- Restore-Ablauf, Voraussetzungen (Restore-Sonde!), Verifikation und
  Fehlerfälle: [RESTORE.md](RESTORE.md). Der Restore-Test ist noch offen und
  gehört auf eine isolierte Test-VM, nie auf Produktion.

## Testen

Lokal ausführbar (kein Docker, kein Root, keine Produktion):

```bash
bash -n setup-coder.sh ssh-harden.sh
shellcheck -S warning setup-coder.sh ssh-harden.sh
for f in tests/*.sh; do bash "$f" || echo "ROT: $f"; done
```

Stand 2026-09-29, tatsächlich ausgeführt (Stand nach Review-Runde 2): alle 10
Skripte Exit 0 (316 `PASS`, 0 `FAIL`); `bash -n` ohne Befund; ShellCheck mit genau einem
Befund (SC2034, ungenutzter Zähler in der Retry-Schleife), `ssh-harden.sh`
ohne Befund.

Was die Tests **belegen**: das Verhalten der extrahierten Codestellen
(Backup-Headercheck, TLS-/Boot-Gates, Hex-Migration, ufw-Downgrade-Gate
inkl. Abbruchfall „restriktiv + worldwide-Limit", Reset-Precheck, Drift-Hashes
über 17 Dateien, Port-Preflight, `ON_ERROR_STOP` im Restore-Runbook) anhand
von Fakes und Fixture-Dateien sowie den gerenderten On-Demand-`ask`-Endpunkt
(`t-b1-on-demand-ask.sh`: Muster-Falluntersuchung, optional `caddy validate`
+ `caddy adapt`).

Was die Tests **nicht belegen**: einen vollständigen Setup-Lauf, echtes
Verhalten von ufw/fail2ban/Docker/Caddy/Let's-Encrypt, Backups mit echtem
`pg_dump`, Reboots, Reset und Restore. Dafür braucht es eine isolierte
Test-VM (siehe nächste Abschnitt).

Auf dem Server zusätzlich sinnvoll:

```bash
sudo docker compose -f /opt/coder/docker-compose.yml config --quiet
sudo /opt/coder/backup.sh
```

## Betrieb und Wartung

Kurz: Stack steuern über `cd /opt/coder && sudo docker compose …`, Updates
bewusst manuell über `sudo /opt/coder/update.sh`, Passwörter über
`sudo /opt/coder/reset-passwords.sh`, kompletter Reset über
`sudo /opt/coder/reset-coder.sh` (nach Backup und Bestätigung).

Vollständig – Start/Stop, Status- und Health-Checks, Logs, automatische
Aufgaben, Update und Rollback, Reboot, Reset, Drift-Warnungen, Backup-Steckbrief:
**[OPERATIONS.md](OPERATIONS.md)**.

## Troubleshooting-Einstieg

Die drei ersten Befehle bei jedem Verdacht:

```bash
cd /opt/coder && sudo docker compose ps
sudo docker logs coder --tail=50
sudo docker logs coder-postgres --tail=50
```

Danach Fehlerbild suchen – Diagnosebefehle, Ursachen und sichere Behebung
stehen in **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**. Grundregel: bei rot
nicht weiter auf dem Produktionssystem herumprobieren, erst diagnostizieren.
Kein Fehlerbild wird durch Abschalten von Prüfungen, Zurücksetzen von
Firewall-Regeln oder übersprungener Verifikation „gelöst".

## Nur auf einer Test-VM bzw. in Produktion zu verifizieren

Folgende Punkte sind im Repository **nicht** belegt und müssen vor
Freigabe auf einer isolierten Test-VM (Restore, Reset, Reboot) bzw. am
Produktivsystem geprüft werden:

1. Vollständiger Lauf von `setup-coder.sh` auf frischem Debian 13
   (inkl. Paketinstallation, Image-Pull, Let's-Encrypt-Erstausstellung).
2. Re-Run auf laufendem Stack (Idempotenz) und erneuter Lauf nach
   Hand-Änderungen an generierten Dateien.
3. Echtes Backup inkl. `pg_dump`, Cron-Lauf um 01:00, logrotate,
   Verhalten bei vollem Speicher.
4. Restore nach [RESTORE.md](RESTORE.md) inkl. Datenprobe und RTO-Messung
   (Tabelle dort ist `_offen_`).
5. Reboot inkl. Boot-Gate (`/var/log/coder-boot.log`) und
   unattended-upgrades-Fenster 03:00.
6. ufw-/fail2ban-Verhalten im Echtbetrieb, Re-Run mit vorhandener
   restriktiver SSH-Regel (B2-004-Pfad B) und der Bypass-Lauf.
7. `reset-coder.sh` mit echten Containern/Volumes und fremden
   Workspace-Containern im Inventar.
8. `ssh-harden.sh` – nur mit getestetem Key-Login und Zweit-Zugang.
9. Externe Sicht: Ports 22/80/443 offen, 9090/9100/3001 von außen
   geschlossen; Wildcard-DNS und Workspace-App-Subdomain im Test.
10. Offsite-Backup-Transport und Wiederanlauf danach (Entscheidung steht aus).
11. Erstanlage des Owner-Kontos über `CODER_FIRST_USER_*` beim ersten Lauf
    (B1): muss das Konto entstehen, ohne dass jemand die Anmeldeseite
    erreicht – und der Re-Run (Konto existiert) darf scheitern, ohne
    abzubrechen.

## Detaildokumentation

- [OPERATIONS.md](OPERATIONS.md) – Betrieb, Checks, Wartung, Logs, Backup
- [RESTORE.md](RESTORE.md) – Wiederherstellung mit Datenprobe und RTO-Tabelle
- [SECURITY.md](SECURITY.md) – Härtung, SSH, Secrets, TLS/SNI, Firewall, Grenzen
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) – Fehlerbilder, Diagnose, Behebung
- [CHANGELOG.md](CHANGELOG.md) – tatsächliche Änderungsstände, keine Releases
- [templates/allowlist.md](templates/allowlist.md) – was Workspace-Templates
  dürfen
- `ai-review/` – Reviews, Pläne, Implementierungsberichte (Referenz)
