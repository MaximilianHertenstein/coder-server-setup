# Coder-Server-Setup

Installation und Wartung eines Coder-Servers auf einer Debian-13-VM: ein
Skript (`setup-coder.sh`) baut den kompletten Stack auf – Caddy (Reverse
Proxy + TLS), Coder, PostgreSQL, Prometheus/Grafana/node-exporter, Firewall
(ufw + fail2ban), automatische Sicherheitsupdates, tägliche Datenbank-Backups
und die Wartungsskripte für Backup, TLS-Zählung und Reset.

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
| Befunde, Pläne, Prüfprotokolle (Referenz) | `ai-review/` – keine Lese-Pflicht für den Betrieb, Stand 26.–29.09.2026; neueste Setup-Prüfung vom 01.10.2026 mit Umsetzung/Ablehnungen: [CHANGELOG.md](CHANGELOG.md) (Eintrag „Review-Runde A1–A12/B1–B21"); in `ai-review/` selbst zuletzt [REVIEW-2026-09-29-SETUP-PUNKTE.md](ai-review/REVIEW-2026-09-29-SETUP-PUNKTE.md) |

## Status (Stand 2026-10-01)

| Punkt | Stand |
|---|---|
| Quellstand | Branch `main`, alles committet; Stände pro Runde in [CHANGELOG.md](CHANGELOG.md) |
| Lokale Tests | Stand 2026-10-01: alle 10 Dateien in `tests/` grün (267 PASS, 0 FAIL), `bash -n setup-coder.sh scripts/*.sh tests/*.sh` und `shellcheck -S warning` ohne Befund |
| Vollständiger Setup-Lauf auf echtem System | Letzter Lauf 2026-10-01 nach der Review-Runde auf dem Test-Host `2.29.11.30`: drei Re-Runs RC 0 (je 46 s, 0 Fehler, Skripte byte-identisch; der erste Lauf fand den A2-Rechte-Bug, RC 1, fail-closed); davor frischer Pfad-A-Aufbau (Exit 0 in 58 s) und Re-Run am 2026-09-30 (Exit 0, Drift erkannt, Firewall unverändert) – Details [CHANGELOG.md](CHANGELOG.md) |
| Restore-Test | **Pfad A komplett geprobt** 2026-10-01 auf dem Test-Host: Alt weg, Volumes frisch, Setup 58 s, Import 2,3 s, Datenprobe 1, `owner` zurück – 1 min 50 s ohne VM-Boot. Offen: RTO inkl. VM-Boot/Paketinstallation (braucht frische VM) und `/healthz` unter echtem DNS ([RESTORE.md](RESTORE.md)) |
| Monitoring | **abgenommen 2026-10-01** (Test-Host): Prometheus `ready` 200, Alarmregeln geladen (damals 6, aktuell 5: `BackupStale`, `CoderTargetDown`, `RootPartitionFillingUp`, `TlsCheckStale`, `TlsIssuanceBudgetHigh`; `TlsLogTruncated` entfallen mit A6), Targets `coder`/`node` up, Grafana `api/health` 200 auf 127.0.0.1:3001, textfile-Metriken (Backup/TLS) vorhanden |
| Offsite-Backup | **bewusst akzeptiert** (D-Offsite, 2026-09-30): kein zweiter Standort – Platten-/Hostverlust = Datenbank + Backups weg |
| SSH-Härtung | **Entschieden (D-SSH, 2026-09-30):** Passwort-Login bleibt Standard; SSH laut Netzvorgabe nur aus dem Schulnetz, ufw `limit 22/tcp` und fail2ban zusätzlich, optionale Nachhärtung als dokumentiertes Drop-In-Snippet ([SECURITY.md](SECURITY.md) §1) |
| Offene Entscheidungen | **aufgeschoben:** DNS-01-Teil von D-TLS (Anbieter All-Inkl bekannt, Modul `caddy-dns/all-inkl`; Umstellung wartet auf Klärung Zone/Hosting/IServ). Von den D-Entscheidungen sonst nichts mehr offen. **Entschieden 2026-09-30:** D-Socket, D-Firewall, D-Reboot-Fenster, D-Offsite, D-SSH, D-Monitoring – alle mit Optionen in [SECURITY.md](SECURITY.md) §9; entschieden: B5 (Client-IPs im Audit bleiben aus); PostgreSQL-Migration erledigt (15 → 18 am 2026-09-30, Beleg in [CHANGELOG.md](CHANGELOG.md)) |

### Offene Punkte – wer macht was (Stand 2026-10-01)

Alles, was noch jemanden braucht, an einem Ort (Details jeweils in der
verlinkten Stelle):

| Was | Wer | Wo |
|---|---|---|
| Pre-Flight-Checkliste durchlaufen, dann erster `setup-coder.sh`-Lauf am Schulserver | Betreiber | [OPERATIONS.md](OPERATIONS.md) §11 |
| IServ/nginx-Konflikt auf 80/443 **vor** dem Lauf klären (Entscheidung: Ports an Caddy vs. anderer Ort) | Betreiber + Hosting/IServ | §11 Pre-Flight Punkt 1 |
| DNS: A-Record, Wildcard, 80/443-Weiterleitung, Proxy-Durchreichung beantragen | Netzwerkadmin; der Betreiber fordert nur Zeilen 1–4 an | §11 „Netzwerkadmin" |
| 03:00-Rebootfenster mit Schulbetrieb abstimmen und im Wartungsplan hinterlegen | Betreiber | OPERATIONS §7 „Reboot", [SECURITY.md](SECURITY.md) §9 D-Reboot-Fenster |
| Ersten Test-Workspace und Port-Forwarding vom Schulnetz aus prüfen (Hairpin-NAT des Workspace-Agenten, A9) | Betreiber | OPERATIONS §11 Abnahme Schritt 5, [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Template-Schritt 4 (Spielraum der Limits im Workspace) je Template abhaken | Betreiber | [templates/allowlist.md](templates/allowlist.md) |
| Zone/Hosting/IServ klären **und beim Netzwerkadmin das DNS-API-Token für die Zone erfragen** – erst danach DNS-01-Modul einbauen; bis dahin läuft On-Demand-TLS weiter (Let's-Encrypt-Limit 50 Zertifikate/Woche pro Domain, Warnung ab 20) | Domainverwalter/Hosting, **nicht** der Betreiber (Token-Anfrage: Betreiber) | OPERATIONS §11 Zeile 6, [SECURITY.md](SECURITY.md) §9 D-TLS |
| Produktionsfreigabe aussprechen – bewusst hier nicht dokumentiert | Betreiber | diese README |
| Unterrichtsdaten: Workspace-Homes als akzeptierter Verlust deklarieren oder eigene Volume-Sicherung mit einrichten (vor Produktivbetrieb) | Betreiber | [RESTORE.md](RESTORE.md) „Was gesichert wird" |
| Offene Verifikation: RTO inkl. VM-Boot, `/healthz` + Wildcard, volle Platte, 03:00-Fire | wartet auf frische VM / DNS / Kernel-Update | Prüfstand-Tabelle unten |

Keine Freigabe für Produktion ist in diesem Repository dokumentiert.

**Zielbetrieb:** ein Schulserver, per SSH nur aus dem Schulnetz
erreichbar; die Weiterleitung der Weboberfläche (80/443) muss noch durch einen
Netzwerkadmin umgesetzt werden – bis dahin kann das Setup dort keine
Zertifikate ausstellen. Laut Betreiber (2026-09-30) soll der Schulserver
künftig mit **IServ** auf dem zentralen Netzwerkserver laufen; bis
feststeht, wer DNS, Wildcard und 80/443 übernimmt, bleiben die TLS-
Umstellung auf DNS-01 (D-TLS) und der Inbetriebnahme-Termin aufgeschoben.
Der Betreiber hat **keinen** DNS-Zugang – Anforderungen laufen über den
Netzwerkadmin ([OPERATIONS.md](OPERATIONS.md) §11).
Der aktuelle Test-Host `2.29.11.30` ist eine
Hetzner-VM, die irgendwann abgeschaltet wird. **Wer was macht** (DNS +
Wildcard, Portweiterleitung, Abnahme): [OPERATIONS.md](OPERATIONS.md)
Abschnitt 11.

## Was im Repo liegt

| Datei | Zweck |
|---|---|
| `setup-coder.sh` | Das Setup-Skript (8 Schritte, `set -euo pipefail`, mehrfach ausführbar) |
| `scripts/` | Wartungsskripte als echte Dateien (`backup.sh`, `check-tls.sh`, `reset-coder.sh`); das Setup schreibt bzw. installiert sie nach `/opt/coder/` |
| `show-sources.sh` | Gibt Setup, Härtung und Wartungsskripte mit Dateimarker und Zeilennummern aus – z. B. um die Quellen einem Chatbot zu geben (Teilmengen als Argumente) |
| `setup.conf.example` | Vorlage für `setup.conf` (Domain, ACME-Adresse/CA, fail2ban-Ignore-IP); `setup.conf` selbst ist gitignored |
| `RESTORE.md` | Wiederherstellungs-Runbook (wird auf den Server nach `/opt/coder/RESTORE.md` kopiert) |
| `templates/allowlist.md` | Regelwerk für Workspace-Templates (Docker-Socket ist host-root-äquivalent) |
| `tests/` | 10 lokale Prüfskripte (STATIC/UNIT-LIKE, ohne Docker und ohne Produktion) |
| `ai-review/` | Reviews, Pläne, Implementierungsberichte (B-/B2-/P-/F-Nummern); [Prüfung der Setup-Fundliste A1–A13, B1–B10 und C1–C5](ai-review/REVIEW-2026-09-29-SETUP-PUNKTE.md) |

## Was das Setup-Skript macht

Aufruf als root: `sudo ./setup-coder.sh` (das Skript bricht ohne root ab);
Werte über `setup.conf` neben dem Skript (gitignored, Vorlage
`setup.conf.example`) oder als Umgebungsvariable hinter dem sudo.

| # | Schritt | Ergebnis |
|---|---|---|
| 1 | Grundpakete und Docker Engine installieren | `cron` und weitere Grundpakete, apt-Repo + Fingerprint-Prüfung des Docker-GPG-Keys, `docker-ce` + Compose-Plugin, `daemon.json` (Log-Limit 10 MB × 3) |
| 2 | Verzeichnis und Konfiguration anlegen | `/opt/coder/`, `.env` (nur beim ersten Lauf), `docker-compose.yml`, `caddy/Caddyfile` (On-Demand-TLS mit lokalem HTTP-Permission-Endpunkt), `prometheus/prometheus.yml` + `prometheus/rules/coder-alerts.yml`, Grafana-Datasource-Provisioning, `node-textfile/` – jedes Schreiben atomar mit Hash und Validierung (Compose/Caddyfile/Prometheus-Config+Regeln), danach `docker compose pull` |
| 3 | Docker-Stack starten | Preflights (Daemon, Platte), dann `up -d`; Caddy und Prometheus bei laufendem Container per `reload`/SIGHUP neu, Grafana nur bei geänderter Provisioning-Datei neu |
| 4 | Firewall + SSH-Schutz | ufw (Default deny incoming), `ufw limit 22/tcp`, 80/443 frei, fail2ban-Jail `sshd`, Abschluss-Checks |
| 5 | Automatische Sicherheitsupdates | Debian-Paketupdates per unattended-upgrades, Reboot 03:00, TLS-Zählung (`check-tls.sh` + Cron); Docker Engine bleibt manuell |
| 6 | Tägliches Datenbank-Backup | `backup.sh`, Cron 01:00 (`/etc/cron.d/coder-backup`), logrotate, Testlauf, Kopie der `RESTORE.md`, Erfolgs-Metrik nach `node-textfile/` |
| 7 | Wartungsskripte installieren | `backup.sh`, `check-tls.sh`, `reset-coder.sh` nach `/opt/coder/` (755, byte-identisch zu `scripts/`) |
| 8 | Abschlusscheck & Zusammenfassung | Container, Socket-GID, `https://…/healthz`, Wildcard-DNS, Nutzer-/Owner-Hinweis (B2), `[FEHLER]`-Zähler → Exit 1 bei Fehlern |

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
| PostgreSQL | `postgres:18-alpine` | keiner | nur im Compose-Netz |
| Prometheus | `prom/prometheus:v3.14.0` (exakt) | 127.0.0.1:9090 | lokal |
| node-exporter | `prom/node-exporter:v1.12.1` (exakt) | 127.0.0.1:9100 | lokal |
| Grafana | `grafana/grafana:12.4.5` (exakt) | 127.0.0.1:3001 | lokal, per SSH-Tunnel |
| sshd, ufw, fail2ban, Cron | Debian-Pakete | 22/tcp | ufw `limit` + fail2ban |

Volumes: `postgres_data`, `caddy_data`, `caddy_config`, `prometheus_data`,
`grafana_data`. Container-Logs: `json-file`, 10 MB × 3 Dateien je Container
(daemon-weit in `daemon.json` festgelegt, nicht nur compose-seitig).
Bind-Mounts aus `/opt/coder/`: `caddy/` (Caddyfile), `prometheus/`
(Konfiguration + fünf Alarmregeln, darunter TLS-Ausstellungen >20 pro 7 Tage
und ein veralteter TLS-Check), `grafana/provisioning/datasources/`
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

Optional vor dem Lauf: Werte in `setup.conf` neben dem Skript eintragen
(Vorlage: `cp setup.conf.example setup.conf`; Domain, ACME-Adresse, ACME-CA,
fail2ban-Ignore-IP). Umgebungsvariablen (hinter dem sudo) überschreiben
`setup.conf`, `setup.conf` überschreibt die Defaults:

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

Defaults stehen im Kopf von `setup-coder.sh`, überschreibbar per
`setup.conf` (neben dem Skript, gitignored) oder Umgebungsvariable –
Vorrang: Env > `setup.conf` > Default:

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
| `FAIL2BAN_IGNORE_IP` | `127.0.0.1/8 ::1` | komma-getrennte Admin-Adressen, die fail2ban nicht bannen darf |

Updates laufen über einen erneuten Lauf von `setup-coder.sh`: er zieht bei
Bild-Wechsel das Datenbank-Pre-Upgrade-Backup, holt die in Compose
eingetragenen Tags (`compose pull`) und startet den Stack bei Änderung neu.
Neue Images kommen automatisch nur hinter den beweglichen Tags `caddy:2.10`
und `postgres:18-alpine` an; Coder, Prometheus, Grafana und node-exporter sind
exakt gepinnt: für deren Versionswechsel den Pin in `setup-coder.sh` ändern
und das Setup erneut ausführen. Docker-Engine- und Compose-Paketupdates sind
davon getrennt und manuell; ein Engine-Update kann alle Workspaces
unterbrechen. Die vollständige Dateiliste, Cron-Zeiten und
Wartungsverfahren stehen in [OPERATIONS.md](OPERATIONS.md).

PostgreSQL läuft seit dem Wechsel am 2026-09-30 auf Major-Version 18
(`postgres:18-alpine`, aktuell 18.6 – der Major-Tag holt 18.x-Patches
automatisch). Gewechselt wurde bewusst vor der Inbetriebnahme, solange nur
Testdaten im Volume lagen, per Dump/Restore (Verfahren: [RESTORE.md](RESTORE.md));
ein reiner Tag-Wechsel migriert kein Volume. Upstream-Support für 18 endet im
November 2030, siehe [PostgreSQL-Versionierung](https://www.postgresql.org/support/versioning/).

## Sicherheit und Hardening (Kurzfassung)

- **SSH**: Auf dem Schulserver ist Port 22 laut Netzvorgabe nur aus dem
  Schulnetz erreichbar. Passwort-Login bleibt bewusst aktiv (D-SSH,
  2026-09-30); ufw rate-limitiert (`ufw limit 22/tcp`) und fail2ban
  begrenzen Fehlversuche (`ignoreip` schützt Admin-Adressen vor der
  geteilten Schul-NAT). Das Setup ändert die SSH-Konfiguration nicht; für
  eine optionale Nachhärtung (Key-only, Zweit-Zugang) steht ein kurzes
  Drop-In-Snippet in [SECURITY.md](SECURITY.md) §1.
- **Firewall**: ufw mit `default deny incoming`; 80/443 (tcp+udp) frei.
  Prometheus, node-exporter und Grafana sind ausschließlich an
  `127.0.0.1` gebunden.
- **Docker-Socket**: Der Coder-Container hält `/var/run/docker.sock`
  schreibbar – bei Kompromittierung eines Workspaces ist der Host
  kompromittierbar. Abfederung: [templates/allowlist.md](templates/allowlist.md).
- **Secrets**: `.env` mit 600/root, Passwörter ausschließlich hex,
  Rotation (Grafana) manuell, Ablauf in [OPERATIONS.md](OPERATIONS.md).
  Kein Secret im Repository (`.env` und `setup.conf` sind gitignored).
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
bash -n setup-coder.sh scripts/*.sh tests/*.sh
shellcheck -S warning setup-coder.sh scripts/*.sh tests/*.sh
for f in tests/*.sh; do bash "$f" || echo "ROT: $f"; done
```

Stand 2026-10-01: alle 10 Testskripte Exit 0 (267 `PASS`, 0 `FAIL`, in
diesem Lauf ohne SKIP); `bash -n` ohne Befund; `shellcheck -S warning`
ohne Befund. Vollständige Läufe (Erstlauf, Re-Run, Reboot, Reset, Restore,
Passwortrotation) liefen separat auf dem Test-Host `2.29.11.30` – siehe
Prüfstand-Liste unten.

Was die Tests **belegen**: das Verhalten der Wartungsskripte (echte Dateien
unter `scripts/`: Backup-Headercheck, TLS-Zählfenster, Reset-Precheck) und
weiterer Setup-Codestellen
(ufw-Regelpfad
inkl. „Quellregeln bleiben unangetastet, globale 22/tcp-Allow wird entfernt,
Abschluss per `limit`",
Hex-Migration, 13 `write_managed`-Zieldateien samt Drift-Warnung und
Hash-Heilung,
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
über einen erneuten Lauf von `setup-coder.sh`, Grafana-Passwort manuell
drehen (Ablauf in OPERATIONS), kompletter Reset über
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
5. Reboot inkl. Wiederanlauf der Container (`docker ps`, `/healthz`) und
   unattended-upgrades-Fenster 03:00.
6. ufw-/fail2ban-Verhalten im Echtbetrieb, Re-Run mit vorhandener
   restriktiver SSH-Regel (B2-004-Pfad B): Regel bleibt unangetastet, es
   wird keine weltweite `limit`-Regel daneben gesetzt.
7. `reset-coder.sh` mit echten Containern/Volumes und fremden
   Workspace-Containern im Inventar.
8. Optionale SSH-Nachhärtung (Drop-In-Snippet aus [SECURITY.md](SECURITY.md) §1)
   – nicht Teil der Standard-Abnahme (D-SSH); nur mit getestetem Key-Login
   und Zweit-Zugang.
9. Externe Sicht: Ports 22/80/443 offen, 9090/9100/3001 von außen
   geschlossen; Wildcard-DNS und Workspace-App-Subdomain im Test.
10. Offsite-Backup-Transport – entfällt (D-Offsite: kein zweiter Standort).
11. Erstanlage des Owner-Kontos über `CODER_FIRST_USER_*` beim ersten Lauf
    (B1): muss das Konto entstehen, ohne dass jemand die Anmeldeseite
    erreicht – und der Re-Run (Konto existiert) darf scheitern, ohne
    abzubrechen.

### Prüfstand der Liste (Test-Host `2.29.11.30`, Stand 2026-10-01)

| # | Status |
|---|---|
| 1 | erledigt: Original-Lauf auf frischer Debian-13-VM 2026-09-28/29; zusätzlich Neuaufbau nach `reset-coder.sh` heute (RC 0) |
| 2 | erledigt 2026-09-30 19:05: Re-Run RC 0 in 48 s; Hand-Patch an der Compose-Datei wurde als Drift erkannt und deterministisch regeneriert, Stack nicht neu erstellt; erneut bestätigt 2026-10-01 nach der Skript-Extraktion: zwei Re-Runs RC 0 (56 s / 47 s), mtimes der sechs Wartungsskripte unverändert, 0 Drift |
| 3 | erledigt: Cron-Läufe um 01:00 nachweisbar (Dumps 29. + 30.09., `gzip -t` grün), 14 Dumps in der Rotation, logrotate aktiv; Verhalten bei vollem Speicher bleibt offen – ein echter Plattenausfall ist nur mit Rettungskonsole sicher zurückspielbar |
| 4 | fast erledigt: Dump-Import isoliert 3,0 s, Major-Wechsel 15 → 18 live (2,3 s), **Pfad A am 2026-10-01 komplett** (Setup 58 s, Import 2,3 s, Datenprobe 1, `owner` zurück; 1 min 50 s ohne VM-Boot); offen bleibt nur RTO inkl. VM-Boot/Paketinstallation und `/healthz` unter echtem DNS |
| 5 | erledigt 2026-09-30 19:07: Reboot, alle 6 Container + Postgres healthy in 51 s, API grün; die `/healthz`-Zeile bleibt hier rot, weil die Domain nicht auf den Host zeigt (kein Zertifikat, externer Blocker); Reboot-Fenster konfiguriert geprüft (`52-coder-reboot`: `Automatic-Reboot true`, `03:00`) – tatsächlicher Fire noch nicht beobachtet; Boot-Gate `boot-check.sh` entfällt seit B8 – Wiederanlauf nach Reboot per `docker ps` und `/healthz` prüfen |
| 6 | erledigt: Re-Run ließ genau eine `22/tcp LIMIT`-Regel (v4/v6) stehen; weltweite `allow 22/tcp` wird entfernt, Quellregeln bleiben unangetastet, fail2ban aktiv |
| 7 | erledigt, inklusive Rest: `reset-coder.sh --force` mit echten Volumes – DB/Grafana/Prometheus-Volumes und `.env` gelöscht, Zertifikate und Dumps erhalten; der Pfad „fremder Container“ wurde mit einem bewusst fremden Container geprüft (als `fremd: fremd-inventartest` gemeldet, danach selbst entfernt), Neuaufbau mit Owner-Konto grün |
| 8 | als Skript entfällt (D-SSH); optional manuell: SSH-Härtungs-Drop-In aus [SECURITY.md](SECURITY.md) §1, nur mit getestetem Key-Login und Zweit-Zugang |
| 9 | teilweise: von außen 22/80/443 offen, 9090/9100/3001/3000/8080 geschlossen; Wildcard-DNS und Workspace-Subdomain nicht prüfbar, solange die Domain nicht auf den Server zeigt |
| 10 | entfällt (D-Offsite) |
| 11 | erledigt: Erstanlage über `CODER_FIRST_USER_EMAIL`/`USERNAME` + Passwort-Prompt beim Lauf (RC 0, `[OK] Erstkonto (Owner) angelegt: owner`); Re-Run mit existierendem Konto RC 0 ohne Abbruch (Block läuft nur bei `HUMAN_USERS=0`) |

## Detaildokumentation

- [OPERATIONS.md](OPERATIONS.md) – Betrieb, Checks, Wartung, Logs, Backup
- [RESTORE.md](RESTORE.md) – Wiederherstellung mit Datenprobe und RTO-Tabelle
- [SECURITY.md](SECURITY.md) – Härtung, SSH, Secrets, TLS/SNI, Firewall, Grenzen
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) – Fehlerbilder, Diagnose, Behebung
- [CHANGELOG.md](CHANGELOG.md) – tatsächliche Änderungsstände, keine Releases
- [templates/allowlist.md](templates/allowlist.md) – was Workspace-Templates
  dürfen
- `ai-review/` – Reviews, Pläne, Implementierungsberichte (Referenz)
