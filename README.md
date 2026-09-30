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
| Befunde, Pläne, Prüfprotokolle (Referenz) | `ai-review/` – keine Lese-Pflicht für den Betrieb; neueste Setup-Prüfung: [ai-review/REVIEW-2026-09-29-SETUP-PUNKTE.md](ai-review/REVIEW-2026-09-29-SETUP-PUNKTE.md) |

## Status (Stand 2026-09-30)

| Punkt | Stand |
|---|---|
| Quellstand | Branch `main`, alles committet; Stände pro Runde in [CHANGELOG.md](CHANGELOG.md) |
| Lokale Tests | Stand 2026-09-30: alle 12 Dateien in `tests/` grün (346 PASS, 0 FAIL), `bash -n setup-coder.sh` und `shellcheck -S warning` ohne Befund |
| Vollständiger Setup-Lauf auf echtem System | Letzter Lauf auf dem Test-Host `2.29.11.30` am 2026-09-30 (nach B2-005 und Restore-Probe), Exit 0, 0 Fehler, Firewall unverändert (Details [CHANGELOG.md](CHANGELOG.md)) |
| Restore-Test | **teilweise geprobt** 2026-09-30: Dump-Import in isolierten Probencontainer grün (Datenprobe 1, 3,0 s); Stack-Restore auf frischer VM und volle RTO weiter offen ([RESTORE.md](RESTORE.md)) |
| Offsite-Backup | **bewusst akzeptiert** (D-Offsite, 2026-09-30): kein zweiter Standort – Platten-/Hostverlust = Datenbank + Backups weg |
| SSH-Härtung | **Entschieden (D-SSH, 2026-09-30):** Passwort-Login bleibt Standard, `ssh-harden.sh` ist nicht Standard und bleibt unaufgerufen; SSH laut Netzvorgabe nur aus dem Schulnetz, ufw `limit 22/tcp` und fail2ban zusätzlich ([SECURITY.md](SECURITY.md) §1) |
| Offene Entscheidungen | **aufgeschoben:** DNS-01-Teil von D-TLS (Anbieter All-Inkl bekannt, Modul `caddy-dns/all-inkl`; Umstellung wartet auf Klärung Zone/Hosting/IServ). Von den D-Entscheidungen sonst nichts mehr offen. **Entschieden 2026-09-30:** D-Socket, D-Firewall, D-Reboot-Fenster, D-Offsite, D-SSH, D-Monitoring – alle mit Optionen in [SECURITY.md](SECURITY.md) §9; entschieden: B5 (Client-IPs im Audit bleiben aus); fällig: PostgreSQL-15-Migration vor Supportende 2027 – Details [CHANGELOG.md](CHANGELOG.md) |

Keine Freigabe für Produktion ist in diesem Repository dokumentiert.

**Zielbetrieb:** ein Schulserver, per SSH nur aus dem Schulnetz
erreichbar; die Weiterleitung der Weboberfläche (80/443) muss noch durch einen
Netzwerkadmin umgesetzt werden – bis dahin kann das Setup dort keine
Zertifikate ausstellen. Laut Betreiber (2026-09-30) soll der Schulserver
künftig mit **IServ** auf dem zentralen Netzwerkserver laufen; bis
feststeht, wer DNS, Wildcard und 80/443 übernimmt, bleiben die TLS-
Umstellung auf DNS-01 (D-TLS) und der Inbetriebnahme-Termin aufgeschoben.
Der aktuelle Test-Host `2.29.11.30` ist eine
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
| `ai-review/` | Reviews, Pläne, Implementierungsberichte (B-/B2-/P-/F-Nummern); [Prüfung der Setup-Fundliste A1–A13, B1–B10 und C1–C5](ai-review/REVIEW-2026-09-29-SETUP-PUNKTE.md) |

## Was das Setup-Skript macht

Aufruf als root: `sudo ./setup-coder.sh` (das Skript bricht ohne root ab);
Umgebungsvariablen gehören hinter das sudo, siehe unten.

| # | Schritt | Ergebnis |
|---|---|---|
| 1 | Grundpakete und Docker Engine installieren | `cron` und weitere Grundpakete, apt-Repo + Fingerprint-Prüfung des Docker-GPG-Keys, `docker-ce` + Compose-Plugin, `daemon.json` (Log-Limit 10 MB × 3) |
| 2 | Verzeichnis und Konfiguration anlegen | `/opt/coder/`, `.env` (nur beim ersten Lauf), `docker-compose.yml`, `caddy/Caddyfile` (On-Demand-TLS mit lokalem HTTP-Permission-Endpunkt), `prometheus/prometheus.yml` + `prometheus/rules/coder-alerts.yml`, Grafana-Datasource-Provisioning, `node-textfile/` |
| 3 | Docker-Stack starten | Preflights (Daemon, fremde Listener, Platte), Compose-Konfiguration, Pull, Caddy- und Prometheus-Konfiguration samt Regeln validieren, dann `up -d`; Caddy bei Änderung `validate` + `reload`, Prometheus lädt geänderte Regeln per SIGHUP; Grafana startet bei geänderter Provisioning-Datei neu |
| 4 | Firewall + SSH-Schutz | ufw (Default deny incoming), `ufw limit 22/tcp`, 80/443 frei, fail2ban-Jail `sshd`, Abschluss-Checks |
| 5 | Automatische Sicherheitsupdates | Debian-Paketupdates per unattended-upgrades, Reboot 03:00, lesendes Boot-Gate (`boot-check.sh`), TLS-Zählung (`check-tls.sh`); Docker Engine bleibt manuell |
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
Bind-Mounts aus `/opt/coder/`: `caddy/` (Caddyfile), `prometheus/`
(Konfiguration + sechs Alarmregeln, darunter TLS-Ausstellungen >20 pro 7 Tage,
ein veralteter TLS-Check und ein gekürztes Caddy-Logfenster), `grafana/provisioning/datasources/`
und `node-textfile/` (Backup- und TLS-Metrik für den textfile-collector von
node-exporter). Caddy- und Prometheus-Konfiguration werden als **Verzeichnisse**
gebunden statt als Einzeldatei: ein Datei-Mount hält am Inode fest und würde
nach dem atomaren Schreiben des Setups bis zum nächsten Recreate die alte
Fassung zeigen.

## Voraussetzungen

- [ ] Debian 13 (trixie), root-Zugang (`sudo`), Netzzugang zu `download.docker.com`,
      `ghcr.io` und den Debian-Servern. Das Setup prüft `ID` und
      `VERSION_CODENAME` aus `/etc/os-release` und bricht vor Änderungen ab,
      wenn es nicht Debian „trixie“ ist.
      Prüfung: `cat /etc/os-release`
- [ ] DNS: `coder.ghse-unterricht.de` **und** `*.coder.ghse-unterricht.de`
      (Wildcard, für Workspace-Apps) zeigen per A-Record auf die öffentliche
      IP des Servers.
      Prüfung: `getent hosts coder.ghse-unterricht.de` und
      `getent hosts setup-probe-1.coder.ghse-unterricht.de`
- [ ] Die Schulnetz-Infrastruktur leitet 80/tcp und 443/tcp (443/udp für
      HTTP/3 optional) an den Server weiter (Standard intern: 10.16.103.13).
      SSH/22 bleibt ausschließlich aus dem Schulnetz erreichbar; keine
      öffentliche SSH-Weiterleitung einrichten.
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
sudo ./setup-coder.sh          # nur als root, sonst Abbruch vor Änderungen
```

Optional vor dem Lauf (Überschreiben der Defaults, ohne Datei zu ändern):

```bash
sudo env DOMAIN_CODER=coder.beispiel.de ACME_EMAIL=admin@beispiel.de ./setup-coder.sh
```

**Erfolgsdefinition**

1. Exit-Code `0` (die Zusammenfassung meldet 0 Einträge `[FEHLER]`),
2. `curl -s -o /dev/null -w '%{http_code}\n' https://coder.ghse-unterricht.de/healthz`
   liefert `200`,
3. der SSH-Passwort-Login bleibt bei der ersten Inbetriebnahme bewusst aktiv;
   SSH/22 darf nur aus dem Schulnetz erreichbar sein (siehe
   [SECURITY.md](SECURITY.md)),
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
| `CODER_ALLOW_DOWNGRADE` | (leer) | nur `yes` erlaubt ein bewusstes Zurücksetzen einer Version (A5-Downgrade-Schutz) |
| `ACME_CA` | (leer) | optionaler eigener ACME-Endpunkt, z. B. Let's-Encrypt-Staging statt Produktions-CA |

`update.sh` sichert die Datenbank, zieht die in Compose eingetragenen Tags und
prüft danach den Stack. Neue Images kommen dabei nur automatisch hinter den
beweglichen Tags `caddy:2.10` und `postgres:15-alpine` an. Coder, Prometheus,
Grafana und node-exporter sind exakt gepinnt: für deren Versionswechsel den
Pin in `setup-coder.sh` ändern und Setup erneut ausführen. Docker-Engine- und
Compose-Paketupdates sind davon getrennt und manuell; ein Engine-Update kann
alle Workspaces unterbrechen. Die vollständige Dateiliste, Cron-Zeiten und
Wartungsverfahren stehen in [OPERATIONS.md](OPERATIONS.md).

PostgreSQL ist derzeit auf Major-Version 15 festgelegt. Deren Upstream-Support
endet am 11. November 2027; die Major-Migration braucht ein eigenes,
geprobtes Verfahren und wird nicht durch einen Tag-Wechsel im Setup erledigt.
Siehe [PostgreSQL-Versionierung](https://www.postgresql.org/support/versioning/).

## Sicherheit und Hardening (Kurzfassung)

- **SSH**: Auf dem Schulserver ist Port 22 laut Netzvorgabe nur aus dem
  Schulnetz erreichbar. Passwort-Login bleibt bewusst aktiv (D-SSH,
  2026-09-30); ufw rate-limitiert (`ufw limit 22/tcp`) und fail2ban
  begrenzen Fehlversuche. `ssh-harden.sh` wird nicht automatisch ausgeführt;
  es verlangt zwei Bestätigungsflags (`--i-have-key-access --i-have-second-access`), einen
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
- **TLS**: Caddy On-Demand-TLS mit Wildcard. Das `permission http`-Modul nutzt
  den lokalen `ask`-Endpunkt (`127.0.0.1:9123`, nur im Container erreichbar).
  Dieser prüft den beantragten
  Namen gegen das Coder-App-Subdomänen-Muster und antwortet mit 200 oder
  404 – Namen außerhalb des Musters bekommen kein Zertifikat. Das Muster
  ist bewusst ein **Filter, kein Budgetschutz**: für Namen darin kann ein
  Angreifer das Zertifikat weiterhin auslösen, das Let's-Encrypt-
  Wochenbudget (50/Domain) bleibt mit allen Schuldiensten geteilt
  (Grenzen und Folgen: [SECURITY.md](SECURITY.md)).
- **Updates**: Debian-Paketupdates per unattended-upgrades inkl. automatischem
  Reboot um 03:00 Uhr (Betriebsfenster ist **nicht** mit dem Schulbetrieb
  abgestimmt). Docker Engine wird manuell aktualisiert, um ungeplante
  Workspace-Unterbrechungen zu vermeiden.

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

Stand nach Prüfung der angehängten Punkte am 2026-09-29: alle 10 Testskripte
Exit 0 (311 `PASS`, 0 `FAIL`); `bash -n` ohne Befund; ShellCheck mit einem
vorhandenen Befund (SC2034, ungenutzter Retry-Schleifenzähler) ist inzwischen
behoben; `shellcheck -S warning setup-coder.sh` meldet derzeit nichts. Der
lokale Caddy-Parsertest wurde übersprungen, weil kein Caddy-Image lokal
vorhanden war; ein vollständiger Setup-/VM-Lauf wurde nicht ausgeführt.

Was die Tests **belegen**: das Verhalten der extrahierten Codestellen
(Backup-Headercheck, TLS-/Boot-Gates, Hex-Migration, ufw-SSH-Regel-Gate
inkl. „Beschränkung bleibt unangetastet, kein Delete von Bestandsregeln",
Reset-Precheck, Drift-Hashes über 16 Dateien, Port-Preflight,
`ON_ERROR_STOP` im Restore-Runbook) anhand
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
   restriktiver SSH-Regel (B2-004-Pfad B): Regel bleibt unangetastet, es
   wird keine weltweite `limit`-Regel daneben gesetzt.
7. `reset-coder.sh` mit echten Containern/Volumes und fremden
   Workspace-Containern im Inventar.
8. `ssh-harden.sh` – optional, nicht Teil der Standard-Abnahme (D-SSH);
   nur mit getestetem Key-Login und Zweit-Zugang.
9. Externe Sicht: Ports 22/80/443 offen, 9090/9100/3001 von außen
   geschlossen; Wildcard-DNS und Workspace-App-Subdomain im Test.
10. Offsite-Backup-Transport – entfällt (D-Offsite: kein zweiter Standort).
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
