# Coder-Server-Setup

Installation und Wartung eines Coder-Servers auf einer Debian-13-VM: ein
Skript (`setup-coder.sh`) baut den kompletten Stack auf – Caddy (Reverse
Proxy + TLS), Coder, PostgreSQL, Prometheus/Grafana/node-exporter, Firewall
(ufw + fail2ban), automatische Sicherheitsupdates, tägliche Datenbank-Backups
und die Wartungsskripte für Backup und Reset sowie die
Workspace-Egress-Sperre.

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
| Befunde, Prüfstände, Dispositionen (Archiv) | [CHANGELOG.md](CHANGELOG.md) |

## Status (Stand 2026-10-08)

| Punkt | Stand |
|---|---|
| Quellstand | Branch `main`, alles committet; Stände pro Runde in [CHANGELOG.md](CHANGELOG.md) |
| Lokale Tests | Stand 2026-10-08: alle 10 Dateien in `tests/` grün (329 PASS, 0 FAIL), `bash -n setup-coder.sh scripts/*.sh tests/*.sh` und `shellcheck -S warning` ohne Befund |
| Vollständiger Setup-Lauf | **vier volle Läufe RC 0** auf Test-Host `2.29.11.30` (2026-10-03 und 2026-10-08, jeweils 0 `[FEHLER]`, 64 `[OK]`; Live-Greps unten, Verifikation #12). **Zielserver (Schule) 2026-10-14: erster Lauf + Re-Run liefen bis zur Zusammenfassung durch** (je 0 `[FEHLER]`, nur die WARNUNG `/healthz` = Portlage offen), Erstkonto `maximilian` angelegt. Details [CHANGELOG.md](CHANGELOG.md) |
| Restore-Test | **Pfad A komplett geprobt** 2026-10-01: Setup 58 s, Import 2,3 s, Datenprobe, `owner` zurück – 1 min 50 s ohne VM-Boot. Offen: RTO inkl. VM-Boot und `/healthz` unter echtem DNS ([RESTORE.md](RESTORE.md), Verifikation #4) |
| Monitoring | **abgenommen, Stand 2026-10-03 (Test-Host):** Prometheus `ready` 200, 3 Alarmregeln geladen (`BackupStale`, `CoderTargetDown`, `RootPartitionFillingUp`), Targets `coder`/`node` up, Grafana `api/health` 200 auf 127.0.0.1:3001, textfile-Metrik (Backup) vorhanden |
| Offsite-Backup | **entschieden 2026-10-08** (D-Offsite bleibt: kein zweiter Schul-Standort): (a) vzdump/PBS-Ziel = anderer Storage/Host als die VM-Disk, (b) monatlicher verschlüsselter `rsync`-Pull `/opt/coder/backups` vom Betreiber-Rechner. Offen: nur noch die Umsetzung (Verifikation #10) |
| SSH-Härtung | **entschieden (D-SSH, 2026-09-30):** Passwort-Login bleibt Standard, Root nur per Schlüssel; ufw `allow` ohne `limit` (Schul-NAT), fail2ban zusätzlich, Drop-In `/etc/ssh/sshd_config.d/01-coder.conf` – Details [SECURITY.md](SECURITY.md) §1 |
| Offene Entscheidungen | **nur DNS-01 aufgeschoben** (wartet Zone/Hosting, D-TLS). Übrige Entscheidungen erledigt: Übersicht [SECURITY.md](SECURITY.md) §9, Verlauf [CHANGELOG.md](CHANGELOG.md) |

### Offene Punkte – wer macht was (Stand 2026-10-08)

Alles, was noch jemanden braucht, an einem Ort (Details jeweils in der
verlinkten Stelle):

| Was | Wer | Wo |
|---|---|---|
| DNS/Portlage klären: lokal Pre-Flight 1 (`ss -ltnp`), extern Netzwerkadmin-Zeilen 1–4 (A, Wildcard, 80/443, ggf. Proxy-Durchreichung + TLS-Passthrough). **Status der Anfrage 2026-10-03:** Einrichtung erst, sobald **IServ in Produktion** ist. **Status Schulserver 2026-10-14:** DNS (Apex+Wildcard) löst auf, `/healthz` antwortet weiter mit Code 000 → Portweiterleitung 80/443 fehlt noch. Zone/Hosting + DNS-API-Token separat für DNS-01 (bis dahin On-Demand-TLS, Budget 50 Zertifikate/Woche) | Netzwerkadmin/Domainverwalter; Betreiber fordert nur Zeilen 1–4 an | [OPERATIONS.md](OPERATIONS.md) §11, [SECURITY.md](SECURITY.md) §9 D-TLS |
| VM-Backup der Proxmox-VM selbst (vzdump/PBS) um 02:00 einrichten – Lücke zwischen DB-Backup 01:00 und Reboot 03:00; `qemu-guest-agent` braucht den virtio-Channel in der VM; Ziel = anderer Storage/Host (entschieden 2026-10-08, trägt auch die Workspace-Homes und den Offsite-Teil); dabei einmal prüfen, dass die Workspace-Homes wirklich in Docker-Volumes liegen; einmal Restore-aus-VM-Backup testen | Betreiber (Proxmox/PBS-Zugang) | OPERATIONS §7 „Backup"/„Reboot", [SECURITY.md](SECURITY.md) §9, [RESTORE.md](RESTORE.md) |
| Ersten Test-Workspace und Port-Forwarding vom Schulnetz aus prüfen (Hairpin-NAT, A9); danach die Workspace-Container-Labels prüfen, die `reset-coder.sh` für den Verzeichnis-Cleanup braucht (B-11: Bei Nicht-Compose-Containern bricht `reset-coder.sh` hart ab, es wird nichts gelöscht) | Betreiber | OPERATIONS §11 Abnahme Schritt 5, [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Template-Schritt 4 (Spielraum der Limits im Workspace) je Template abhaken – entschieden 2026-10-08: erst nach dem Vorführen der konkreten Templates | Betreiber | [templates/allowlist.md](templates/allowlist.md) |
| Produktionsfreigabe aussprechen – bewusst hier nicht dokumentiert | Betreiber | diese README |
| Alarmweg umsetzen: Grafana-Contact-Point an `hert@ghse.de` über IServ-SMTP, sobald IServ produktiv ist; bis dahin fängt der tägliche BackupStale-Routine-Check (OPERATIONS §5) den kritischen Fall ab | Betreiber | [SECURITY.md](SECURITY.md) §9 D-Monitoring, OPERATIONS §5 |
| Offene Verifikation: RTO inkl. VM-Boot, `/healthz` + Wildcard, volle Platte, 03:00-Fire, rsync-Pull proben | wartet auf frische VM / DNS / Kernel-Update | Verifikationstabelle unten |

Keine Freigabe für Produktion ist in diesem Repository dokumentiert.

**Zielbetrieb:** ein Schulserver (frisches Debian 13), per SSH nur aus dem
Schulnetz erreichbar. IServ und der zentrale Reverse-Proxy laufen auf einem
anderen Server – wie 80/443 zum Zielserver kommen und wer was anfordert,
steht komplett in [OPERATIONS.md](OPERATIONS.md) §11. Der Betreiber hat
keinen DNS-Zugang. Der aktuelle Test-Host `2.29.11.30` ist eine
Hetzner-VM, die irgendwann abgeschaltet wird.

## Was im Repo liegt

| Datei | Zweck |
|---|---|
| `setup-coder.sh` | Das Setup-Skript (8 Schritte, `set -euo pipefail`, mehrfach ausführbar) |
| `scripts/` | Wartungsskripte als echte Dateien (`backup.sh`, `reset-coder.sh`, `workspace-egress.sh`); das Setup schreibt sie nach `/opt/coder/` (`write_managed`: `bash -n` + atomar) |
| `setup.conf.example` | Vorlage für `setup.conf` (Domain, ACME-Adresse **Pflicht**, ACME-CA, fail2ban-Ignore-IP); `setup.conf` selbst ist gitignored |
| `RESTORE.md` | Wiederherstellungs-Runbook (wird auf den Server nach `/opt/coder/RESTORE.md` kopiert) |
| `templates/allowlist.md` | Regelwerk für Workspace-Templates (Docker-Socket ist host-root-äquivalent) |
| `tests/` | 10 lokale Prüfskripte (STATIC/UNIT-LIKE, ohne Docker und ohne Produktion) |

## Was das Setup-Skript macht

Aufruf als root: `sudo ./setup-coder.sh` (das Skript bricht ohne root ab);
Werte über `setup.conf` neben dem Skript (gitignored, Vorlage
`setup.conf.example`) oder als Umgebungsvariable hinter dem sudo.

| # | Schritt | Ergebnis |
|---|---|---|
| 1 | Grundpakete und Docker Engine installieren | `cron` und weitere Grundpakete, apt-Repo + Fingerprint-Prüfung des Docker-GPG-Keys, `docker-ce` + Compose-Plugin, `daemon.json` (Log-Limit 10 MB × 3); `qemu-guest-agent` nur, wenn die VM den virtio-Serial-Channel hat (Proxmox-VM-Backup mit Freeze) |
| 2 | Verzeichnis und Konfiguration anlegen | `/opt/coder/`, `.env` (nur beim ersten Lauf), `docker-compose.yml`, `caddy/Caddyfile` (On-Demand-TLS mit lokalem HTTP-Permission-Endpunkt), `prometheus/prometheus.yml` + `prometheus/rules/coder-alerts.yml`, Grafana-Provisioning (Datasource + Dashboard „Server-Last"), `node-textfile/`, Wartungsskripte (`scripts/*.sh` → `/opt/coder/`, 755, per `write_managed`: `bash -n` + atomar) – jedes Schreiben atomar mit Validierung (Compose/Caddyfile/Prometheus-Config+Regeln), danach `docker compose pull` |
| 3 | Docker-Stack starten | Preflights (Daemon, Platte), dann `up -d`; Caddy und Prometheus bei laufendem Container per `reload`/SIGHUP neu, Grafana nur bei geänderter Provisioning-Datei neu |
| 4 | Firewall + SSH-Schutz | ufw (Default deny incoming), zuerst `deny` für Docker-Container-Netze (172.16.0.0/12) am sshd-Port, dann `ufw allow` für die erkannten sshd-Ports (eigene alte `limit`-Regel wird entfernt), 80/443 frei, Altbestandsregeln für Grafana 3001 werden entfernt (Grafana nur noch 127.0.0.1, keine ufw-Regel), fail2ban-Jail `sshd`, SSH-Drop-In, Workspace-Egress-Sperre (`coder-egress-firewall.service` sperrt Workspace-Container den Zugriff auf RFC1918 außerhalb der Docker-Netze), Abschluss-Checks (inkl. Gegenprobe auf die `deny`-Regel) |
| 5 | Automatische Sicherheitsupdates | Debian-Paketupdates per unattended-upgrades (geprüft über `apt-daily-upgrade.timer`), Reboot 03:00; Docker Engine bleibt manuell |
| 6 | Tägliches Datenbank-Backup | `backup.sh`, Cron 01:00 (`/etc/cron.d/coder-backup`), logrotate, Testlauf, Kopie der `RESTORE.md`, Erfolgs-Metrik nach `node-textfile/` |
| 7 | Abschlusscheck & Zusammenfassung | Container, Socket-GID, `https://…/healthz`, Wildcard-DNS, Nutzer-/Owner-Hinweis (B2), `[FEHLER]`-Zähler → Exit 1 bei Fehlern |

Verwaltete Dateien werden atomar geschrieben und bei Abweichung
deterministisch neu gesetzt – Hand-Anpassungen an generierten Dateien
gehen beim nächsten Lauf ohne Warnung verloren; gewollte Anpassungen
gehören nach `/opt/coder/setup.conf` oder in den Repo-Quellen, Details in
[OPERATIONS.md](OPERATIONS.md)).

## Architektur in Kurzform

| Dienst | Image (Pin) | Port | Zugang |
|---|---|---|---|
| Caddy | `caddy:2.11` (Minor-Pin) | 80/tcp, 443/tcp, 443/udp | öffentlich |
| Coder | `ghcr.io/coder/coder:v2.37.3` (exakt) | intern 3000 | nur über Caddy |
| PostgreSQL | `postgres:18-alpine` | keiner | nur im Compose-Netz |
| Prometheus | `prom/prometheus:v3.15.0` (exakt) | 127.0.0.1:9090 | lokal |
| node-exporter | `prom/node-exporter:v1.12.1` (exakt) | 127.0.0.1:9100 | lokal |
| Grafana | `grafana/grafana:12.4.12` (exakt) | `127.0.0.1:3001` (nur lokal, keine ufw-Regel) | ausschließlich per SSH-Tunnel (HTTP, Login Pflicht) |
| sshd, ufw, fail2ban, Cron | Debian-Pakete | 22/tcp | ufw `allow` + fail2ban |

Volumes: `postgres_data`, `caddy_data`, `caddy_config`, `prometheus_data`,
`grafana_data`. Container-Logs: `json-file`, 10 MB × 3 Dateien je Container
(daemon-weit in `daemon.json` festgelegt, nicht nur compose-seitig).
Bind-Mounts aus `/opt/coder/`: `caddy/` (Caddyfile), `prometheus/`
(Konfiguration + drei Alarmregeln), `grafana/provisioning/datasources/`
und `node-textfile/` (Backup-Metrik für den textfile-collector von
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
(Vorlage: `cp setup.conf.example setup.conf`; Domain, ACME-Adresse –
**Pflicht, kein Default**, sonst bricht das Setup vor jeder Änderung ab –,
ACME-CA, fail2ban-Ignore-IP). Umgebungsvariablen (hinter dem sudo)
überschreiben `setup.conf`, `setup.conf` überschreibt die Defaults:

```bash
sudo env DOMAIN_CODER=coder.beispiel.de ACME_EMAIL=admin@beispiel.de ./setup-coder.sh
```

**Einzige Passwort-Eingabe (Erstinstallation):** Existiert noch kein
Coder-Konto und sind `CODER_FIRST_USER_EMAIL`/`CODER_FIRST_USER_USERNAME`
gesetzt, fragt das Skript einmal **unsichtbar** das Passwort des Erstkontos
ab (nur mit TTY; Enter ohne Eingabe = Konto später selbst im Browser
anlegen). Ohne diese Variablen läuft der Lauf ohne jede Eingabe;
Nicht-interaktiv-Variante in [OPERATIONS.md](OPERATIONS.md) §11.

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
| `ACME_EMAIL` | **Pflicht** (kein Default) | Let's-Encrypt-Benachrichtigungsadresse; ohne Wert (Conf oder Env) bricht das Setup vor jeder Änderung ab |
| `CODER_VERSION` | `v2.37.3` | exakter Coder-Image-Tag (mit `v`) |
| `CADDY_VERSION` | `2.11` | Minor-Pin, Patch-Updates per `compose pull` |
| `PROMETHEUS_VERSION` | `v3.15.0` | exakter Pin |
| `GRAFANA_VERSION` | `12.4.12` | exakter Pin |
| `NODE_EXPORTER_VERSION` | `v1.12.1` | exakter Pin |
| `CODER_ALLOW_DOWNGRADE` | (leer) | nur `yes` erlaubt ein bewusstes Zurücksetzen einer Version (A5-Downgrade-Schutz) |
| `ACME_CA` | (leer) | optionaler eigener ACME-Endpunkt, z. B. Let's-Encrypt-Staging statt Produktions-CA |
| `FAIL2BAN_IGNORE_IP` | `127.0.0.1/8 ::1` | komma-getrennte Admin-Adressen, die fail2ban nicht bannen darf |

Updates laufen über einen erneuten Lauf von `setup-coder.sh`: er zieht bei
Bild-Wechsel das Datenbank-Pre-Upgrade-Backup, holt die in Compose
eingetragenen Tags (`compose pull`) und startet den Stack bei Änderung neu.
Neue Images kommen automatisch nur hinter den beweglichen Tags `caddy:2.11`
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

- **SSH**: Port 22 laut Netzvorgabe nur aus dem Schulnetz; Passwort-Login
  bleibt bewusst an, Root nur per Schlüssel (D-SSH). ufw `allow` ohne
  `limit` (würde die geteilte Schul-NAT drosseln), fail2ban sperrt nach
  5 Fehlversuchen/10 min für 1 h (`ignoreip` ohne Schul-NAT). Drop-In
  `/etc/ssh/sshd_config.d/01-coder.conf`; Key-only-Umbau in
  [SECURITY.md](SECURITY.md) §1.
- **Firewall**: ufw mit `default deny incoming`; 80/443 (tcp+udp) frei,
  keine 3001-Regel mehr (Grafana nur an `127.0.0.1`, Zugang per
  SSH-Tunnel; alte Quellregeln werden beim Setup-Lauf entfernt).
  Prometheus, node-exporter und Grafana sind ausschließlich an
  `127.0.0.1` gebunden.
- **Docker-Socket**: Der Coder-Container hält `/var/run/docker.sock`
  schreibbar – bei Kompromittierung eines Workspaces ist der Host
  kompromittierbar. Abfederung: [templates/allowlist.md](templates/allowlist.md).
- **Secrets**: `.env` mit 600/root, generierte Passwörter hex (das Setup-Gate
  verlangt Hex nur noch für `POSTGRES_PASSWORD`), Rotation (Grafana) manuell,
  Ablauf in [OPERATIONS.md](OPERATIONS.md).
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
- **Updates**: Debian-Paketupdates per unattended-upgrades inkl.
  automatischem Reboot um 03:00 (Dauerregel, abgestimmt 2026-10-08; in
  Ferien-/Prüfungsphasen vorher abstimmen). Docker-Engine- und
  Stack-Updates manuell im monatlichen Update-Fenster (OPERATIONS §7).

Grenzen, Nachweisbefehle und offene Entscheidungen: [SECURITY.md](SECURITY.md).

## Backup und Restore (Kurzfassung)

- Täglich 01:00 Uhr: `pg_dump` nach `/opt/coder/backups/coder_<Zeitstempel>.sql.gz`,
  verifiziert (`gzip -t` + SQL-Header), 600/root, 700 für das Verzeichnis,
  Rotation: neueste 14 Dumps.
- **Gesichert ist nur die Datenbank** (bis das Proxmox-VM-Backup läuft):
  nicht gesichert sind `.env`, Compose-/Caddy-/Prometheus-Config,
  Zertifikate, Grafana-Dashboards, Prometheus-Historie, Workspace-Dateien.
- **Offsite-Transport entschieden 2026-10-08:** vzdump/PBS auf anderem
  Storage/Host + monatlicher verschlüsselter `rsync`-Pull; Umsetzung offen.
- Restore-Pfad A ist am 2026-10-01 auf einer Test-VM geprobt; offen bleibt
  RTO inkl. VM-Boot. Ablauf und Verifikation: [RESTORE.md](RESTORE.md) –
  Restore niemals zum ersten Mal auf Produktion.

## Testen

Lokal ausführbar (kein Docker, kein Root, keine Produktion):

```bash
bash -n setup-coder.sh scripts/*.sh tests/*.sh
shellcheck -S warning setup-coder.sh scripts/*.sh tests/*.sh
for f in tests/*.sh; do bash "$f" || echo "ROT: $f"; done
```

Stand 2026-10-08: alle 10 Testskripte Exit 0 (329 `PASS`, 0 `FAIL`);
`bash -n` ohne Befund; `shellcheck -S warning`
ohne Befund. Vollständige Läufe (Erstlauf, Re-Run, Reboot, Reset, Restore,
Passwortrotation) liefen separat auf dem Test-Host `2.29.11.30` – siehe
Verifikationstabelle unten.

Was die Tests **belegen**: das Verhalten der Wartungsskripte (echte Dateien
unter `scripts/`: Backup-Headercheck, Reset-Precheck inkl. Argument-Ablehnung
und Fremd-Container-Gate, Workspace-Egress-Sperre mit Fake-iptables) und
weiterer Setup-Codestellen
(ufw-Regelpfad
inkl. „Quellregeln bleiben unangetastet, `allow` für die erkannten
sshd-Ports, eigene alte `limit`-Regel wird entfernt, Altbestand 3001
innerhalb einer harten Allowlist", dazu die Docker-Netz-`deny` vor dem
`allow` (B3a),
ACME-Pflicht ohne Personen-Default (A4), Hex-Migration,
`write_managed` (atomar, Inode-stabil bei gleichen Inhalt,
`bash -n`-Guard, Validierer vor dem Austausch; 12 direkte Zieldateien, die
`scripts/*.sh` per Schleife, dazu `versions.env` und der sshd-Drop-In),
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
Aufgaben, Update und Rollback, Reboot, Reset, Backup-Steckbrief:
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

## Verifikation (Test-VM bzw. Produktion)

Was das Repo nicht belegt und vor Freigabe zu prüfen ist – Nachweise und
Details stehen im [CHANGELOG.md](CHANGELOG.md):

| # | Prüfpunkt | Status (Test-Host `2.29.11.30`, Stand 2026-10-08) |
|---|---|---|
| 1 | Voll-Lauf auf frischem Debian 13 (Pakete, Images, Erstausstellung) | erledigt 2026-09-29 (RC 0) + Neuaufbau nach `reset-coder.sh` 2026-10-08 + **Zielserver-Erstlauf 2026-10-14**; Let's-Encrypt-Erstausstellung wartet auf Portlage (#9) |
| 2 | Re-Run/Idempotenz, Drift-Erkennung | erledigt mehrfach 2026-09-30/10-01 (RC 0, Hand-Patch deterministisch regeneriert, 0 Drift) und **am Zielserver 2026-10-14** (zweiter Lauf ohne Abweichung) |
| 3 | Echtes Backup (Cron 01:00, logrotate) | erledigt (Dumps, `gzip -t`, 14er-Rotation); **offen:** volle Platte |
| 4 | Restore nach [RESTORE.md](RESTORE.md) inkl. Datenprobe/RTO | Pfad A komplett 2026-10-01 (1 min 50 s ohne VM-Boot); **offen:** RTO inkl. VM-Boot + `/healthz` unter echtem DNS |
| 5 | Reboot/Wiederanlauf, 03:00-Fenster | erledigt 2026-09-30 (6 Container in 51 s, Fenster konfiguriert); **offen:** tatsächlicher Fire um 03:00 |
| 6 | ufw/fail2ban im Echtbetrieb, Re-Run bei vorhandener SSH-Restriktion | erledigt (allow-Pfad, Quellregeln unangetastet, alte `limit`-Regel entfernt, fail2ban aktiv) |
| 7 | `reset-coder.sh` mit echten/fremden Containern | erledigt (`--force` löscht nur eigene; Nicht-Compose-Container = harter Abbruch) |
| 8 | Optionale SSH-Nachhärtung (D-SSH) | entfällt als Skript; manuell nur mit Key-Login + Zweit-Zugang ([SECURITY.md](SECURITY.md) §1) |
| 9 | Externe Sicht: Ports offen/geschlossen, Wildcard-DNS | teilweise (Ports geprüft; Wildcard/Workspace-Subdomain wartet auf DNS) |
| 10 | Offsite-Transport: monatlicher verschlüsselter `rsync`-Pull | **offen** (entschieden 2026-10-08) |
| 11 | Erstkonto `CODER_FIRST_USER_*` + Re-Run | erledigt – am Zielserver 2026-10-14 (`maximilian`), Re-Run ohne Abbruch (1 Konto; zweites Owner-Konto steht noch aus) |
| 12 | Review-Runde-5-Live-Greps (ACME-Gate, ufw-DENY-Reihenfolge, `DOCKER-USER`, Egress-Unit, qemu-Guest-Agent, node-exporter-Mounts, `sshd -T`) | erledigt 2026-10-08 (Läufe 5+6 RC 0, je 0 `[FEHLER]`/64 `[OK]`; Details CHANGELOG, Eintrag 2026-10-08) |
