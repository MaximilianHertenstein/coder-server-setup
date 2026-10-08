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
| Befunde, Pläne, Prüfprotokolle (Referenz) | [CHANGELOG.md](CHANGELOG.md) – Prüfstände und Dispositionen, Einträge 2026-09-29 (Setup-Fundliste A1–A13/B1–B10/C1–C5), 2026-10-03 (Review-Runde A1–A12/B1–B21) und 2026-10-08 (Review-Runde 5, Proxmox-Backup-/Risiko-Runde); Prozess-Archiv `ai-review/` am 2026-10-03 entfernt (in Git-Historie) |

## Status (Stand 2026-10-01)

| Punkt | Stand |
|---|---|
| Quellstand | Branch `main`, alles committet; Stände pro Runde in [CHANGELOG.md](CHANGELOG.md) |
| Lokale Tests | Stand 2026-10-08: alle 10 Dateien in `tests/` grün (329 PASS, 0 FAIL), `bash -n setup-coder.sh scripts/*.sh tests/*.sh` und `shellcheck -S warning` ohne Befund |
| Vollständiger Setup-Lauf auf echtem System | **zwei volle Läufe RC 0 am 2026-10-03** und **zwei weitere volle Läufe RC 0 am 2026-10-08** auf dem Test-Host `2.29.11.30` (jeweils 0 `[FEHLER]`, 64 `[OK]`; 2026-10-08 live geprüft: ACME-Pflicht-Gate bricht vor jeder Änderung ab, ufw-`DENY 172.16.0.0/12` genau einmal über dem `allow` in beiden Läufen, `DOCKER-USER` je Netz genau ein `DROP`, Egress-Unit `enabled`+`active`, `qemu-guest-agent` installiert/aktiv, node-exporter ohne `run/credentials`-Serie; Warnung `/healthz` bekannt – externer DNS-Blocker; Details [CHANGELOG.md](CHANGELOG.md)) |
| Restore-Test | **Pfad A komplett geprobt** 2026-10-01 auf dem Test-Host: Alt weg, Volumes frisch, Setup 58 s, Import 2,3 s, Datenprobe 1, `owner` zurück – 1 min 50 s ohne VM-Boot. Offen: RTO inkl. VM-Boot/Paketinstallation (braucht frische VM) und `/healthz` unter echtem DNS ([RESTORE.md](RESTORE.md)) |
| Monitoring | **abgenommen, Stand 2026-10-03 (Test-Host):** Prometheus `ready` 200, 3 Alarmregeln geladen (`BackupStale`, `CoderTargetDown`, `RootPartitionFillingUp`), Targets `coder`/`node` up, Grafana `api/health` 200 auf 127.0.0.1:3001, textfile-Metrik (Backup) vorhanden |
| Offsite-Backup | **weggezählt, Weg entschieden 2026-10-08** (D-Offsite bleibt: kein zweiter Schul-Standort): (a) vzdump/PBS-Ziel = anderer Storage/Host als die VM-Disk, (b) monatlicher `rsync`-Pull `/opt/coder/backups` vom Betreiber-Rechner auf externe Platte, **verschlüsselt** (Dumps enthalten Tokens/Nutzerdaten); kein Automatismus im Repo. Offen ist nur noch die Umsetzung (Proxmox-Zugang, Kalendereintrag) |
| SSH-Härtung | **Entschieden (D-SSH, 2026-09-30; Regelwerk revidiert 2026-10-03):** Passwort-Login bleibt Standard; SSH laut Netzvorgabe nur aus dem Schulnetz, ufw `allow` für die erkannten sshd-Ports (kein `limit` – würde die geteilte Schul-NAT drosseln), fail2ban zusätzlich und ein eigenes SSH-Drop-In (`/etc/ssh/sshd_config.d/01-coder.conf`: Passwort-Login explizit an, `PermitRootLogin prohibit-password`; Details und Key-only-Umstellung in [SECURITY.md](SECURITY.md) §1) |
| Offene Entscheidungen | **aufgeschoben:** DNS-01-Teil von D-TLS (Anbieter All-Inkl bekannt, Modul `caddy-dns/all-inkl`; Umstellung wartet auf Klärung Zone/Hosting und Zuständigkeit für DNS/Ports). Von den D-Entscheidungen sonst nichts offen. **Entschieden 2026-09-30:** D-Socket, D-Firewall, D-Reboot-Fenster, D-Offsite, D-SSH, D-Monitoring – alle mit Optionen in [SECURITY.md](SECURITY.md) §9; entschieden: B5 (Client-IPs im Audit bleiben aus); PostgreSQL-Migration erledigt (15 → 18 am 2026-09-30, Beleg in [CHANGELOG.md](CHANGELOG.md)). **Entschieden 2026-10-08:** Update-Fenster (monatlich, 1. Samstag 09:00), Alarmweg (`hert@ghse.de`, Grafana-Mail über IServ-SMTP), Unterrichtsdaten (via Proxmox-VM-Backup, Restverlust ≤ 1 Schultag), Offsite-Transport (PBS-/anderes Storage-Target + monatlicher verschlüsselter `rsync`-Pull) – Details OPERATIONS §7/§5, [RESTORE.md](RESTORE.md), [CHANGELOG.md](CHANGELOG.md) Einträge 2026-10-08 (6)+(7) |

### Offene Punkte – wer macht was (Stand 2026-10-08)

Alles, was noch jemanden braucht, an einem Ort (Details jeweils in der
verlinkten Stelle):

| Was | Wer | Wo |
|---|---|---|
| Pre-Flight-Checkliste durchlaufen, dann erster `setup-coder.sh`-Lauf am Schulserver | Betreiber | [OPERATIONS.md](OPERATIONS.md) §11 |
| Portlage 80/443 klären: Der Zielserver ist ein **frisches Debian ohne Webserver** – IServ läuft auf einem anderen (zentralen) Server, mit dem das Schulnetz verwaltet wird, vermutlich samt Reverse-Proxy. Entscheidung: DNS zeigt direkt auf den Zielserver, oder der zentrale Proxy leitet 80/443 durch (ACME-Pfade + TLS-Passthrough/SNI). **Status 2026-10-03 (E-Mail):** Zugriff von außen auf Zielserver `10.16.103.13`, Apex `coder.ghse-unterricht.de` + optional Wildcard und WebSocket-Pflicht beim Netzwerkadmin (Sascha) angefragt – Antwort: Einrichtung erst, sobald **IServ in Produktion** geht, aktuell technisch nicht möglich. WebSocket braucht auf unserer Seite nichts (Caddy `reverse_proxy` reicht `Upgrade` standardmäßig durch); beim zentralen Proxy muss die Durchreichung später mit abgedeckt sein | Betreiber + Netzwerkadmin | §11 Pre-Flight Punkt 1, §11 „Netzwerkadmin" Zeile 4 |
| DNS: A-Record, Wildcard, 80/443-Weiterleitung, Proxy-Durchreichung beantragen. **Befund 2026-10-03:** Zone bei Kasserver/All-Inkl (`ns5/ns6.kasserver.com`), `A` für die Apex zeigt aktuell `85.13.130.100` (alte Schulseite, MX ebenfalls Kasserver), `93.240.138.106` = Kreis-Proxy `pmg.em-ghse.logoip.de` (HTTP 451) – der Weg für 80/443 und wer Kasserver-Zugang/API-Token hat, ist mit dem Schulträger zu klären. **Status 2026-10-03:** in derselben Anfrage mit angeantwortet, s. Portlage-Zeile | Netzwerkadmin; der Betreiber fordert nur Zeilen 1–4 an | §11 „Netzwerkadmin" |
| VM-Backup der Proxmox-VM selbst (vzdump/PBS) um 02:00 einrichten – Lücke zwischen DB-Backup 01:00 und Reboot 03:00; `qemu-guest-agent` braucht den virtio-Channel in der VM; **Ziel = anderer Storage/Host als die VM-Disk (entschieden 2026-10-08, trägt auch die Workspace-Homes und den Offsite-Teil)**; dabei einmal prüfen, dass die Workspace-Homes wirklich in Docker-Volumes liegen; einmal Restore-aus-VM-Backup testen | Betreiber (Proxmox/PBS-Zugang) | OPERATIONS §7 „Backup"/„Reboot", [SECURITY.md](SECURITY.md) §9, [RESTORE.md](RESTORE.md) |
| Ersten Test-Workspace und Port-Forwarding vom Schulnetz aus prüfen (Hairpin-NAT des Workspace-Agenten, A9); danach die Workspace-Container-Labels prüfen, die `reset-coder.sh` für den Verzeichnis-Cleanup braucht (B-11: Bei Nicht-Compose-Containern bricht `reset-coder.sh` hart ab, es wird nichts gelöscht) | Betreiber | OPERATIONS §11 Abnahme Schritt 5, [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Template-Schritt 4 (Spielraum der Limits im Workspace) je Template abhaken – **entschieden 2026-10-08: erst nach dem Vorführen der konkreten Templates** | Betreiber | [templates/allowlist.md](templates/allowlist.md) |
| Zone/Hosting klären **und beim Netzwerkadmin das DNS-API-Token für die Zone erfragen** – erst danach DNS-01-Modul einbauen; bis dahin läuft On-Demand-TLS (Let's-Encrypt-Limit 50 Zertifikate/Woche pro Domain, Warnung ab 20) | Domainverwalter/Hosting, **nicht** der Betreiber (Token-Anfrage: Betreiber) | OPERATIONS §11 Zeile 6, [SECURITY.md](SECURITY.md) §9 D-TLS |
| Produktionsfreigabe aussprechen – bewusst hier nicht dokumentiert | Betreiber | diese README |
| Unterrichtsdaten | **entschieden 2026-10-08:** Workspace-Homes werden über das Proxmox-VM-Backup (vzdump 02:00) mitgesichert, separate Volume-Sicherung entfällt; Restverlust ≤ 1 Schultag (Snapshot-Stand) | Betreiber | [RESTORE.md](RESTORE.md) „Was gesichert wird", OPERATIONS §7 |
| Alarmweg/Empfänger | **entschieden 2026-10-08:** Empfänger `hert@ghse.de`, Weg Grafana-Mail über IServ-SMTP; **offen bleibt nur noch die Umsetzung** (warten auf IServ-Produktivschaltung + SMTP-Zugang); bis dahin fängt der tägliche BackupStale-Routine-Check in OPERATIONS §5 den kritischen Fall ab | Betreiber | [SECURITY.md](SECURITY.md) §9 D-Monitoring, OPERATIONS §5 |
| Offene Verifikation: RTO inkl. VM-Boot, `/healthz` + Wildcard, volle Platte, 03:00-Fire | wartet auf frische VM / DNS / Kernel-Update | Prüfstand-Tabelle unten |

Keine Freigabe für Produktion ist in diesem Repository dokumentiert.

**Zielbetrieb:** ein Schulserver (frisches Debian 13), per SSH nur aus dem
Schulnetz erreichbar. IServ läuft **nicht** auf diesem Server, sondern auf
einem anderen zentralen Netzwerkserver, mit dem das Schulnetz verwaltet
wird – vermutlich ist dort auch der Reverse-Proxy. Offen ist, wie 80/443
zum Zielserver kommen: DNS direkt auf den Zielserver, oder Durchreichung
bzw. Proxy-Regel am zentralen Server. Bis das steht, kann das Setup dort
keine Zertifikate ausstellen; die TLS-Umstellung auf DNS-01 (D-TLS)
wartet zusätzlich auf Klärung von Zone/Hosting. Der Betreiber hat
**keinen** DNS-Zugang – Anforderungen laufen über den
Netzwerkadmin ([OPERATIONS.md](OPERATIONS.md) §11).
Der aktuelle Test-Host `2.29.11.30` ist eine
Hetzner-VM, die irgendwann abgeschaltet wird. **Wer was macht** (DNS +
Wildcard, Portweiterleitung, Abnahme): [OPERATIONS.md](OPERATIONS.md)
Abschnitt 11.

## Was im Repo liegt

| Datei | Zweck |
|---|---|
| `setup-coder.sh` | Das Setup-Skript (8 Schritte, `set -euo pipefail`, mehrfach ausführbar) |
| `scripts/` | Wartungsskripte als echte Dateien (`backup.sh`, `reset-coder.sh`, `workspace-egress.sh`); das Setup schreibt sie nach `/opt/coder/` (`write_managed`: `bash -n` + atomar) |
| `show-sources.sh` | Gibt Setup, Härtung und Wartungsskripte mit Dateimarker und Zeilennummern aus – z. B. um die Quellen einem Chatbot zu geben (Teilmengen als Argumente) |
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

- **SSH**: Auf dem Schulserver ist Port 22 laut Netzvorgabe nur aus dem
  Schulnetz erreichbar. Passwort-Login bleibt bewusst aktiv (D-SSH,
  2026-09-30); ufw stellt `allow` für die erkannten sshd-Ports (Revision
  2026-10-03: kein `limit`, weil es die geteilte Schul-NAT aller Nutzer
  drosseln würde) und fail2ban begrenzt Fehlversuche (5 Fehlversuche in
  10 min → 1 h Sperre, `ignoreip` enthält nur Admin-Plätze – die geteilte
  Schul-NAT wird bewusst NICHT eingetragen, Rateversuche aus dem Schulnetz
  sollen sperren). Das Setup schreibt das Drop-In
  `/etc/ssh/sshd_config.d/01-coder.conf` (Passwort-Login explizit an,
  `sshd -T`-Validierung, Reload nur bei Änderung); Key-only/Umbau in
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

Stand 2026-10-08: alle 10 Testskripte Exit 0 (329 `PASS`, 0 `FAIL`);
`bash -n` ohne Befund; `shellcheck -S warning`
ohne Befund. Vollständige Läufe (Erstlauf, Re-Run, Reboot, Reset, Restore,
Passwortrotation) liefen separat auf dem Test-Host `2.29.11.30` – siehe
Prüfstand-Liste unten.

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

## Nur auf einer Test-VM bzw. in Produktion zu verifizieren

Folgende Punkte sind im Repository **nicht** belegt und müssen vor
Freigabe auf einer isolierten Test-VM (Restore, Reset, Reboot) bzw. am
Produktivsystem geprüft werden:

1. Vollständiger Lauf von `setup-coder.sh` auf frischem Debian 13
   (inkl. Paketinstallation, Image-Pull, Let's-Encrypt-Erstausstellung).
2. Re-Run auf laufendem Stack (Idempotenz); Hand-Änderungen an
   generierten Dateien werden ohne Warnung deterministisch überschrieben
   (`write_managed`-Test belegt das
   Schreibverhalten).
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
10. Offsite-Backup-Transport: einmal proben, wie der monatliche
    `rsync`-Pull (entschieden 2026-10-08) mit Verschlüsselung und ohne
    Zugriff von der VM auf die Zielkopie funktioniert.
11. Erstanlage des Owner-Kontos über `CODER_FIRST_USER_*` beim ersten Lauf
    (B1): muss das Konto entstehen, ohne dass jemand die Anmeldeseite
    erreicht – und der Re-Run (Konto existiert) darf scheitern, ohne
    abzubrechen.

### Prüfstand der Liste (Test-Host `2.29.11.30`, Stand 2026-10-08)

| # | Status |
|---|---|
| 1 | erledigt: Original-Lauf auf frischer Debian-13-VM 2026-09-28/29; zusätzlich Neuaufbau nach `reset-coder.sh` heute (RC 0) |
| 2 | erledigt 2026-09-30 19:05: Re-Run RC 0 in 48 s; Hand-Patch an der Compose-Datei wurde als Drift erkannt und deterministisch regeneriert, Stack nicht neu erstellt; erneut bestätigt 2026-10-01 nach der Skript-Extraktion: zwei Re-Runs RC 0 (56 s / 47 s), mtimes der sechs Wartungsskripte unverändert, 0 Drift |
| 3 | erledigt: Cron-Läufe um 01:00 nachweisbar (Dumps 29. + 30.09., `gzip -t` grün), 14 Dumps in der Rotation, logrotate aktiv; Verhalten bei vollem Speicher bleibt offen – ein echter Plattenausfall ist nur mit Rettungskonsole sicher zurückspielbar |
| 4 | fast erledigt: Dump-Import isoliert 3,0 s, Major-Wechsel 15 → 18 live (2,3 s), **Pfad A am 2026-10-01 komplett** (Setup 58 s, Import 2,3 s, Datenprobe 1, `owner` zurück; 1 min 50 s ohne VM-Boot); offen bleibt nur RTO inkl. VM-Boot/Paketinstallation und `/healthz` unter echtem DNS |
| 5 | erledigt 2026-09-30 19:07: Reboot, alle 6 Container + Postgres healthy in 51 s, API grün; die `/healthz`-Zeile bleibt hier rot, weil die Domain nicht auf den Host zeigt (kein Zertifikat, externer Blocker); Reboot-Fenster konfiguriert geprüft (`52-coder-reboot`: `Automatic-Reboot true`, `03:00`) – tatsächlicher Fire noch nicht beobachtet; Wiederanlauf nach Reboot per `docker ps` und `/healthz` prüfen |
| 6 | erledigt: Verfahren `allow` – weltweite `allow 22/tcp`, eigene `limit`-Regel (v4/v6) wird entfernt, Quellregeln bleiben unangetastet, fail2ban aktiv; Altbestand der Grafana-3001-Quellregeln wird innerhalb einer harten Allowlist entfernt |
| 7 | erledigt, inklusive Rest: `reset-coder.sh --force` mit echten Volumes – DB/Grafana/Prometheus-Volumes und `.env` gelöscht, Zertifikate und Dumps erhalten; der Pfad „fremder Container“ wurde mit einem bewusst fremden Container geprüft (als `fremd: fremd-inventartest` gemeldet, danach selbst entfernt), Neuaufbau mit Owner-Konto grün. Nicht-Compose-Container führen zum harten Abbruch vor jeder Löschung (`--force` hebt das Gate nicht auf) |
| 8 | als Skript entfällt (D-SSH); optional manuell: SSH-Härtungs-Drop-In aus [SECURITY.md](SECURITY.md) §1, nur mit getestetem Key-Login und Zweit-Zugang |
| 9 | teilweise: von außen 22/80/443 offen, 9090/9100/3001/3000/8080 geschlossen; Wildcard-DNS und Workspace-Subdomain nicht prüfbar, solange die Domain nicht auf den Server zeigt |
| 10 | entfällt (D-Offsite) |
| 11 | erledigt: Erstanlage über `CODER_FIRST_USER_EMAIL`/`USERNAME` + Passwort-Prompt beim Lauf (RC 0, `[OK] Erstkonto (Owner) angelegt: owner`); Re-Run mit existierendem Konto RC 0 ohne Abbruch (Block läuft nur bei `HUMAN_USERS=0`) |
| 12 | erledigt 2026-10-08 (Läufe 5 + 6, RC 0, je 0 `[FEHLER]`/64 `[OK]`): ACME-Pflicht-Gate ohne `setup.conf` bricht vor jeder Änderung mit Klartext ab (RC 1); ufw `22/tcp DENY 172.16.0.0/12` genau einmal und über dem `allow` – nach Lauf 6 unverändert (kein Duplikat); `DOCKER-USER` je Netz genau ein `DROP` (`10.0.0.0/8`, `192.168.0.0/16`), nach Lauf 6 unverändert; Egress-Unit `enabled` + `active`; `qemu-guest-agent` installiert und aktiv (Channel `org.qemu.guest_agent.0` vorhanden); node-exporter: 0 Serien `run/credentials` (vorher 27), `node_filesystem_avail_bytes` nur noch Host-Mounts (`/`, `/boot/efi`, `/run`, `/run/lock`, `/run/user/0`, `/tmp` – Wurzelpartition für `RootPartitionFillingUp` bleibt); `sshd -T`: `passwordauthentication yes`, `permitrootlogin without-password`; 3001 an 127.0.0.1, 3 Alarmregeln, Prometheus `ready` 200 |

## Detaildokumentation

- [OPERATIONS.md](OPERATIONS.md) – Betrieb, Checks, Wartung, Logs, Backup
- [RESTORE.md](RESTORE.md) – Wiederherstellung mit Datenprobe und RTO-Tabelle
- [SECURITY.md](SECURITY.md) – Härtung, SSH, Secrets, TLS/SNI, Firewall, Grenzen
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) – Fehlerbilder, Diagnose, Behebung
- [CHANGELOG.md](CHANGELOG.md) – tatsächliche Änderungsstände, keine Releases
- [templates/allowlist.md](templates/allowlist.md) – was Workspace-Templates
  dürfen
