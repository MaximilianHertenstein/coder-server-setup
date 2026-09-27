# 08 – Documentation / Handover-Review

Stand: 2026-09-27. Geprüft am HEAD (Branch `ai/implementation-v2`-Stand,
`setup-coder.sh` 1615 Zeilen, `ssh-harden.sh` 80 Zeilen, `RESTORE.md` 68
Zeilen, `templates/allowlist.md` 34 Zeilen, `tests/` leer).

Rolle: Senior System Administrator + Technical Writer für Infrastructure
Handover. Keine Implementierung, keine andere Datei verändert. Ausschließlich
diese Datei (`ai-review/08-documentation.md`) erstellt.

## Methodik

- Vollständige Lesung: `setup-coder.sh` (alle 1615 Zeilen), `ssh-harden.sh`,
  `RESTORE.md`, `templates/allowlist.md`, `AGENTS.md`,
  `copilot-instructions.md`, `.gitignore`, `ai-review/01-bash.md`,
  `02-security.md`, `03-debian-docker.md`, `04-coder-caddy.md`,
  `05-backup-recovery.md`, `06-architecture.md`, `07-complexity.md`,
  `PLAN.md`, `PLAN-REVIEW.md` (Stichprobe), `TEST_PLAN.md` (`ai-review/`,
  2735 Zeilen), `POST-IMPLEMENTATION-PLAN.md` (Stichprobe),
  `IMPLEMENTATION-REPORT-v2.md`, `FINAL-BREAKER-v2.md`.
- Read-only-Verifikation lokal: `ls`, `wc -l`, Existenzchecks
  (`README.md` fehlt, `docker-compose.yml`/`Caddyfile`/`prometheus.yml`/
  `backup.sh`/`update.sh`/`reset-passwords.sh`/`reset-coder.sh` existieren
  **nicht** als Dateien – sie werden per Heredoc nach `/opt/coder/`
  generiert; `TEST_PLAN.md` existiert nur unter `ai-review/`, nicht im Root;
  `tests/` ist leer).
- Klassifizierung: FACT (im Code/Doku belegt) vs. GAP (für Handover fehlend).
  Severity bezieht sich auf **Übernehmbarkeit durch einen neuen
  Administrator**, nicht auf Code-Schwere.

## Vorab-Befund: Aufgabenstellung vs. Repository-Ist

Die Aufgabenstellung nennt als Analysebasis u. a. `README.md`,
`docker-compose.yml`, `Caddyfile`, `prometheus.yml`, `backup.sh`,
`update.sh`, `reset-passwords.sh`, `reset-coder.sh`, `TEST_PLAN.md` (Root).
Fakt:

- `README.md` existiert nicht (`README_MISSING`, per `ls` verifiziert).
- `docker-compose.yml`, `Caddyfile`, `prometheus.yml`, `backup.sh`,
  `update.sh`, `reset-passwords.sh`, `reset-coder.sh` existieren nicht als
  Repo-Dateien (`COMPOSE_MISSING` etc., verifiziert). Sie sind eingebettete
  Heredocs in `setup-coder.sh` (Schritt 2/6/7/8/9) und entstehen erst auf dem
  Zielhost unter `/opt/coder/`.
- `TEST_PLAN.md` existiert nur als `ai-review/TEST_PLAN.md` (2735 Zeilen),
  kein Root-`TEST_PLAN.md`.
- `tests/` ist leer (0 Dateien).

Das ist kein redaktionelles Detail, sondern der größte Handover-Befund:
Der Einstiegspunkt, den ein neuer Administrator erwartet (`README` →
Architektur → Installation → Betrieb), existiert nicht. Das gesamte
Betriebswissen steckt im Skriptkopf (`setup-coder.sh` Z. 1–75), in
verstreuten Kommentaren (~30 % Kommentaranteil), in `RESTORE.md` (68 Zeilen)
und in ~17.000 Zeilen Review-Doku, die nie zur Operator-Doku verdichtet
wurde.

## Übergabe-Urteil vorweg

**Nein. Ein neuer Administrator kann dieses System derzeit nicht innerhalb
eines Arbeitstages sicher übernehmen.**

Begründung:

1. Kein Einstiegsdokument (`README.md` fehlt).
2. Kein Betriebs-Runbook (`OPERATIONS.md` fehlt): Start/Stop/Status/Logs/
   Healthchecks sind über 1615 Zeilen Skript verstreut.
3. Kein Security-Dokument (`SECURITY.md` fehlt): SSH-Provisorium (weltweit +
   Passwort aktiv), Docker-Socket-Risiko, UFW-vs-Docker-Grenze und
   On-Demand-TLS-Budget sind nur in Kommentaren/Reviews belegt, nicht als
  Betriebsanweisung mit Eigentümer/Frist.
4. Kein belegter Restore: `RESTORE.md` ist Verfahrenstiefe 1, nie geprobt,
   RTO-Tabelle `_offen_`, kein Offsite (Plattenverlust = Totalverlust).
5. Kein einziger VM-Test je ausgeführt (`FINAL-BREAKER-v2.md`: v2 führt zwei
   CRITICAL-Regressionen ein – B2-001 Backup-Headercheck, B2-002 TLS-Smoke –
   und „darf so nicht in Produktion"). Ein Nachfolger weiß nicht, welcher
   Code-Stand freigegeben ist.
6. ~17.000 Zeilen Review-Doku vs. 0 Zeilen Operator-Doku: Der Nachfolger
   müsste erst Reviews lesen, um zu erfahren, was gilt – das ist kein
   Tagespensum.

---

## D-001 – Kein Einstiegsdokument (README fehlt)

Severity:
CRITICAL

Missing information:
Alles, was ein README beantworten müsste: Was ist das System, wofür wird es
verwendet, Architekturbild (Host vs. Container), Voraussetzungen, 5-Minuten-
Installationspfad, Links auf Betrieb/Restore/Security. Derzeit existiert
kein `README.md`.

Why needed:
Ohne README beginnt jede Übernahme mit Reverse-Engineering von
`setup-coder.sh` (1615 Zeilen). Die Aufgabenfragen zu Projektverständnis
(System, Zweck, Komponenten, Zusammenhänge, Host-vs-Container) sind nirgends
an einer Stelle beantwortet. Faktisch beantwortet nur der Skriptkopf
(Z. 1–75) Teile davon – auf dem Server, nicht im Repo-Klon.

Where it should be documented:
README.md (neu, schlank – Details nach OPERATIONS.md / SECURITY.md /
RESTORE.md auslagern, siehe „Documentation Structure").

Proposed content:
Kurzbeschreibung (Coder auf Debian 13 für Schulbetrieb, Single-Host);
Komponententabelle (Host: Docker Engine, UFW, fail2ban,
unattended-upgrades, Cron; Container: coder `ghcr.io/coder/coder:2.36.6`,
coder-postgres `postgres:15-alpine`, coder-caddy `caddy:2.10`,
coder-prometheus `prom/prometheus:v3.14.0`, coder-grafana
`grafana/grafana:12.4.5`, coder-node-exporter `prom/node-exporter:v1.12.1`);
Datenfluss (Browser → 80/443 → Caddy → `coder:3000` → Postgres;
Monitoring nur 127.0.0.1); Ablageorte (`/opt/coder/`, Volumes,
`/etc/cron.d/`, `/etc/fail2ban/jail.local`,
`/etc/apt/apt.conf.d/52-coder-reboot`); Zeiger auf OPERATIONS/SECURITY/
RESTORE/CHANGELOG.

Verification:
`test -f README.md && grep -qE 'Architektur|Voraussetzung|Installation|Betrieb|Restore' README.md && echo README_OK`.

---

## D-002 – Generierte Dateien sind im Repo unsichtbar

Severity:
HIGH

Missing information:
`docker-compose.yml`, `Caddyfile`, `prometheus.yml`, `backup.sh`,
`update.sh`, `reset-passwords.sh`, `reset-coder.sh` werden in der Aufgabe als
Analysebasis genannt, existieren aber nicht als Dateien. Ein Nachfolger sucht
sie, findet nur Heredocs in `setup-coder.sh` (Compose Z. 294–427, Caddyfile
Z. 469–485, prometheus.yml Z. 489–500, backup.sh Z. 842–956, update.sh
Z. 1060–1158, reset-passwords.sh Z. 1185–1316, reset-coder.sh Z. 1329–1499)
und kann sie ohne Zielhost weder lesen noch per `compose config` /
`caddy validate` / ShellCheck prüfen.

Why needed:
Handover-Fragen („Wie hängt was zusammen?", „Wo liegen Logs?",
„Wie funktioniert Restore?") lassen sich ohne lesbare Artefakte nur über
Skript-Lesung beantworten. Jede Config-Änderung muss im Heredoc-Kontext
(Escaping `\$` vs. `$`) statt als Config-Diff gelesen werden (vgl.
`ai-review/06-architecture.md` F-003).

Where it should be documented:
README.md (Ablageprinzip erklären: Single-File-Deployment, Generierung nach
`/opt/coder/`) + OPERATIONS.md (Liste aller generierten Dateien mit Pfad,
Zweck, Regenerationsregel). Kein neues Tooling nötig; ersatzweise
generierte Beispiele als Kommentarauszug versionieren.

Proposed content:
Tabelle: Repo-Quelle (`setup-coder.sh`-Zeilenbereich) → Zielpfad auf Server
(`/opt/coder/docker-compose.yml`, `/opt/coder/Caddyfile`,
`/opt/coder/prometheus.yml`, `/opt/coder/*.sh`, `/etc/cron.d/*`,
`/etc/logrotate.d/coder-backup`, `/etc/fail2ban/jail.local`,
`/etc/apt/apt.conf.d/52-coder-reboot`) → „deterministisch regeneriert,
Hand-Anpassung wird überschrieben (Drift-WARN via
`/opt/coder/.generated-hashes`)" → Prüfbefehl
(`docker compose config --quiet`, `caddy validate`, `bash -n`).

Verification:
`grep -q 'generated-hashes' README.md OPERATIONS.md && sudo docker compose -f /opt/coder/docker-compose.yml config --quiet && echo GEN_OK`.

---

## D-003 – Voraussetzungen nicht consolidated (Hardware, DNS, Netz, SSH)

Severity:
HIGH

Missing information:
Verstreut vorhanden (Skriptkopf Z. 7–46), aber nirgends als prüfbare Liste:

- Debian 13 (trixie) – belegt (Z. 4, Docker-Repo-Codename-Dynamik).
- Domain `coder.ghse-unterricht.de` + Wildcard `*.coder.ghse-unterricht.de`
  als A-/AAAA-Records auf öffentliche Server-IP – belegt (Z. 8–10).
- Schulnetz: Portweiterleitung 80+443 auf intern `10.16.103.13` (Z. 11–12),
  zusätzlich Port 22 für Heimzugriff (Z. 34–36).
- Benötigte Ports: 22/tcp (limit), 80/tcp, 443/tcp, 443/udp – belegt
  (Schritt 4, `ufw`-Checks Z. 635–691).
- SSH-Zugriff + sudo + Internetzugang – implizit („als Benutzer mit
  sudo-Rechten ausführen", Z. 64–66), aber nie als Checkliste.
- **Fehlend ganz:** Hardware-/Ressourcenbedarf (vCPU/RAM/Platte – TEST_PLAN
  nennt 2 vCPU/4 GB/30 GB nur als Test-VM, kein Produktionsmaß);
  Plattenkapazität für 15-Tage-Prometheus + 14 Backups + Images;
  Sudo-Voraussetzung explizit; Outbound-Anforderungen (Registry, LE,
  `example.com`-ask-Abhängigkeit).

Why needed:
Erstinstallation scheitert ohne diese Liste an DNS/Portweiterleitung – das
Skript meldet dann nur WARN (Schritt 10) und empfiehlt Re-Run. Ein Nachfolger
braucht vorab eine Gate-Liste, sonst installiert er blind und debuggt hinterher.

Where it should be documented:
README.md (Voraussetzungs-Checkliste mit Soll/Ist-Spalte).

Proposed content:
Checkliste mit Befehl je Zeile: `lsb_release -cs` (= trixie),
`getent hosts coder.ghse-unterricht.de`, `getent hosts setup-probe-<rand>.coder.ghse-unterricht.de`
(Wildcard), `ss -tlnp | grep -E ':(80|443)'`, `sudo -v`, `df -h /opt/coder`,
`free -h`, externer `nmap -p 22,80,443` + `nmap -sU -p 443` vom Scanner-Host,
Schulnetz-Ticket (Weiterleitung 22/80/443 an 10.16.103.13).

Verification:
Jede Zeile der Checkliste ist ein kopierbarer Befehl mit erwartetem Output;
`bash -n setup-coder.sh` grün + alle DNS/Port-Zeilen grün vor Freigabe.

---

## D-004 – Erstinstallation: Variablen, Secrets, Erfolgskriterien

Severity:
HIGH

Missing information:
Teilweise im Code, nicht als Anleitung:

- Aufruf (`chmod +x setup-coder.sh; ./setup-coder.sh`, Z. 64–66) – belegt.
- Überschreibbare Variablen (`DOMAIN_CODER`, `ACME_EMAIL`, `CODER_VERSION`,
  `CADDY_VERSION`, `PROMETHEUS_VERSION`, `GRAFANA_VERSION`,
  `NODE_EXPORTER_VERSION`, Z. 84–90) – belegt, aber ohne Doku, welche
  Kombination getestet/freigegeben ist und dass Prometheus-/Grafana-Updates
  nur per Setup-Re-Run (nicht `update.sh`) wirken (Kommentar Z. 1154–1157).
- Erzeugte Dateien: nur aus Code ableitbar (siehe D-002).
- Secrets: `/opt/coder/.env` (600, root:root), nur Erstlauf würfelt
  (`openssl rand -hex`), Re-Run fasst Passwörter nicht an, unvollständige
  `.env` = harter Abbruch (Z. 197–259); Ausgabe der Klartext-Passwörter am
  Terminal (Z. 235–240) – nirgends als Geheimnis-Verfahren (Notieren,
  Weitergabe, Rotation) dokumentiert.
- Erfolgskriterien: nur SUMMARY (`[OK]/[WARNUNG]/[FEHLER]`, Z. 1585–1616);
  WARN-Fälle (DNS fehlt, Wildcard fehlt, Passwort-Login aktiv) sind
  „erwartbar", aber es steht nirgends, welche WARNs bei Erstinstallation
  akzeptabel sind und welche einen Stopp bedeuten.

Why needed:
Falsche Variable (z. B. `CODER_VERSION=v2.36.6` statt `2.36.6`) oder
verlorene Erstausgabe = Passwortverlust. Ohne Erfolgsdefinition wird WARN mit
„fertig" verwechselt.

Where it should be documented:
README.md (Installationspfad, 10 Schritte in 5 Zeilen) + OPERATIONS.md
(Variablen-Tabelle, Secrets-Verfahren).

Proposed content:
Variablen-Tabelle (Name, Default, Wirkung, Änderungspfad); Secrets-Verfahren
(Erstausgabe notieren, `.env.bak.*`-Regel, Rotation nur via
`reset-passwords.sh`); Erfolgsdefinition (Exit 0 + 0× `[FEHLER]`,
zulässige WARNs bei fehlendem DNS/Weiterleitung mit Wiedervorlage „Re-Run
nach DNS"); Negativbeispiel (`CODER_VERSION` ohne `v`, beidseitiger
`docker pull`-Beleg vor Merge – vgl. IMPLEMENTATION-REPORT-v2 Blocker 2).

Verification:
Neuinstallation auf Test-VM nach Doku ohne Rückfrage an Autor; danach
`sudo docker compose -f /opt/coder/docker-compose.yml ps` (6× Running),
`coder-postgres` healthy, `https://<domain>/healthz` = 200, Backup-Datei
vorhanden, RTO-Zeile protokolliert.

---

## D-005 – Betrieb: Start/Stop/Status/Logs/Healthchecks fehlt als Runbook

Severity:
HIGH

Missing information:
Kein OPERATIONS.md. Wissen ist verstreut:

- Start/Stop: `sudo docker compose -f /opt/coder/docker-compose.yml up -d`
  / `stop`/`ps` (nur aus Code/Skripten ableitbar, Schritt 3 Z. 505–548).
- Status: `check_container_running` (Schritt 10 Z. 1523–1528), Socket-Probe
  (GroupAdd enthält DOCKER_GID, Z. 1534–1542), Apex-curl (Z. 1559–1571),
  Wildcard-`getent`-Probe (Z. 1578–1583).
- Logs: `sudo docker logs <name>` (in Fail-Meldungen genannt), Caddy
  `obtaining certificate`, `/var/log/coder-backup.log` (mit logrotate),
  `/var/log/coder-boot.log` (ohne Rotation), `/var/log/coder-tls.log`
  (ohne Rotation), `logger -t coder-backup/coder-tls/coder-boot`.
- Komponenten-Checks: Postgres `pg_isready -U coder -d coder` /
  Health-Status; Coder `/healthz`; Caddy `caddy validate`; Prometheus
  `http://127.0.0.1:9090/-/healthy`; Grafana `http://127.0.0.1:3001/login`
  nur per SSH-Tunnel; node-exporter `http://127.0.0.1:9100/metrics`.
- Grafana-Zugang: nur Kommentar „127.0.0.1:3001 per SSH-Tunnel" (Z. 42–43,
  Z. 1598) – kein Tunnel-Befehl dokumentiert.

Why needed:
Tägliche Fragen („Ist Coder gesund?", „Wo steht warum was?") erfordern heute
Skript-Lesung. Insbesondere Tunnel-Zugang und Log-Orte müssen ohne
Code-Suche funktionieren.

Where it should be documented:
OPERATIONS.md (neu).

Proposed content:
Je Komponente eine 4-Zeilen-Karte: Statusbefehl, Logbefehl, Gesund-Kriterium,
Erste-Maßnahme. Plus: SSH-Tunnel-Beispiel
(`ssh -L 3001:127.0.0.1:3001 -L 9090:127.0.0.1:9090 user@host`),
`ss -tlnp`-Soll (`*:80/*:443` Caddy, `127.0.0.1:9090/9100/3001`),
`df -h /opt/coder` + `docker inspect … LogConfig`.

Verification:
Nachfolger führt jede Karte auf gesundem Stack aus und erhält das
dokumentierte Gesund-Kriterium; `grep -c 'docker logs\|journalctl\|/var/log' OPERATIONS.md` > 0.

---

## D-006 – Wartung: Update / Rollback / Rotation / Reset / Reboot

Severity:
HIGH

Missing information:
Mechanik existiert (generierte Skripte), Verfahren nicht:

- Update: `sudo /opt/coder/update.sh` manuell, kein Cron (Z. 1161–1170);
  Pre-Backup, `compose pull`-Retry (3×), `up -d --remove-orphans`,
  Health-Gate (Container Running + Postgres healthy + `/healthz`-Smoke),
  kein Auto-Prune (bewusst, Kommentar Z. 1137–1157). Aber:
  Gate-Semantik ist per `FINAL-BREAKER-v2.md` B2-002 **derzeit defekt**
  (Host-Header gegen 127.0.0.1 statt `--resolve`), Prometheus-/Grafana-
  Versionen wirken nur per Setup-Re-Run – das steht nur im Codekommentar.
- Rollback: nur Kommentar (exakte Pins rollbackfähig ohne Re-Pull, Caddy
  Minor-Pin/Postgres floating brauchen Re-Pull; Major-Downgrades mit
  Schema-Migration irreversibel möglich) – kein Stufenplan.
- Passwortrotation: `sudo /opt/coder/reset-passwords.sh` (Vorab-Backup,
  `.env.bak.*` genau eine Generation, Phasen-Fenster PG/Grafana/.env) –
  Verfahren, aber Hex-Gate-Pingpong per B2-003 ungelöst (Legacy-`.env`
  blockiert Setup UND Reset).
- Reset: `sudo /opt/coder/reset-coder.sh [--force]` (`RESET` /
  `RESET-OHNE-BACKUP`, Backups + Caddy-Zerts bleiben, `.env` + 3 Volumes
  werden gelöscht, SSH/Firewall bleiben) – Inventar-vs-`down`-Reihenfolge
  per B2-006 bemängelt.
- Reboot: automatisch 03:00 nach Kernel-Updates (`52-coder-reboot`),
  Boot-Gate `/opt/coder/boot-check.sh` + `@reboot`-Cron (lesend, 5-Min-
  Fenster) – aber 03:00 nie mit Schulbetrieb abgestimmt (D-Reboot-Fenster
  offen), Boot-Log unrotiert.

Why needed:
Wartung ist der Moment, in dem Daten verloren gehen (falsches Update,
`--force`-Reset, Reboot in Dump). Ohne Stufenplan improvisiert der
Nachfolger – exakt das, was `reset-coder.sh`/`update.sh` verhindern sollen.

Where it should be documented:
OPERATIONS.md (Wartungskapitel je Verfahren: Zweck, Befehl, Vorbedingung,
  Erfolgsbild, Rückweg) + CHANGELOG.md (Versionen, Update-Datum, Ergebnis).

Proposed content:
Pro Verfahren: Einzeiler-Befehl, Pre-Check (z. B. `gzip -t` letztes Backup,
  `df`), Gate-Erwartung (Exit 0 + Gate-Zeile), Rollback-Zweig (exakt Pin vs.
  Re-Pull vs. Restore nach RESTORE.md), Verweis auf Sperren (B2-Fixes vor
  Freigabe: B2-001/B2-002/B2-003).

Verification:
Trockenlauf auf Test-VM je Verfahren mit Protokoll (Datum, Versionen,
Dump-Alter, RTO/Login ok); `ls /opt/coder/*.sh` + `systemctl is-active cron
fail2ban` + `cat /etc/cron.d/coder-backup` im Protokoll.

---

## D-007 – Security-Modell nicht übergabefähig

Severity:
CRITICAL

Missing information:
Alle Fakten vorhanden, kein SECURITY.md, keine Eigentümer/Fristen:

- SSH: weltweit offen (`limit 22/tcp` + fail2ban `sshd` maxretry 5/10m/1h
  als Dämpfung), **Passwort-Login noch aktiv** (Skript warnt nur, Z. 671–676,
  Z. 1600–1610); Härtungspfad `ssh-harden.sh` vorbereitet (2 Flags + Key-Check
  + Drop-In + Post-Check), aber Termin/Zweit-Zugang/Eigentümer offen
  (D-SSH). UFW-Defaults `deny incoming/allow outgoing` + IPv6-Pfad
  (`IPV6=yes`?) nur im Setup-Log.
- Docker-Socket: `coder`-Container hält `/var/run/docker.sock` schreibbar +
  `group_add DOCKER_GID` (offizielles Setup, Z. 330–343) = Host-root-
  äquivalent bei Kompromittierung (`02-security.md` F-001 CRITICAL);
  Template-Schutz nur `templates/allowlist.md` (Stufe 1, Erstinventar
  `_offen_`, D-Socket-Entscheidung offen).
- Firewall: UFW-Regeln für 80/443 sind für Docker-Ports Doku, kein Schutz
  (Kommentar Z. 617–644, `03-debian-docker.md` F-012 bestätigt); Bindungsregel
  „neue `ports:` nur 127.0.0.1, Ausnahme nur Caddy" nur Kommentar;
  `DOCKER-USER` bewusst fehlend (D-Firewall-Entscheidung nach Dual-Stack-Test
  T-060 offen).
- TLS: On-Demand mit `ask http://example.com` (immer 200) = jeder
  Internet-Teilnehmer kann per SNI Zertifikate für `*.domain` auslösen;
  Budget 50/Woche auf `ghse-unterricht.de` geteilt mit allen Schuldiensten;
  Erkennung `check-tls.sh` (Mo 06:30, zählt `obtaining certificate`),
  aber rotationsblind (B2-005) und Mechanik-Entscheidung D-TLS offen.
- Secrets: `.env` 600/root, Backups 600/700-Verzeichnis, aber Klartext-Ausgabe
  am Terminal, Container-Env (`CODER_PG_CONNECTION_URL`,
  `GF_SECURITY_ADMIN_PASSWORD`) via `docker inspect` lesbar für Docker-Admins;
  keine Rotation-ohne-Fenster-Garantie (B2-003).
- Öffentliche Dienste: 22/80/443/tcp + 443/udp (bei Weiterleitung), Rest
  loopback – kein externer Scan je protokolliert.

Why needed:
Security-Fragen der Aufgabe (SSH-Modell, Key/Passwort, Firewall, fail2ban,
Socket, Isolation, öffentliche Dienste, Secrets) sind die
Übernahme-Risiken Nr. 1. Ohne SECURITY.md mit Ist/Entscheidung/Frist trägt
der Nachfolger ein weltweit offenes Passwort-SSH + Socket-Host, ohne zu
wissen, was Provisorium und was Beschluss ist.

Where it should be documented:
SECURITY.md (neu) + README.md (Risiko-Kurzlage mit Verweis).

Proposed content:
Ist-Tabelle je Grenze (SSH, UFW/Docker, Socket/Templates, TLS, Images,
Secrets, Backups) mit: aktueller Zustand, Risiko (1 Satz), Entscheidung
(Eigentümer + Datum/Frist), Nachweisbefehl (`sshd -T | grep -iE
'passwordauth|kbdinteractive|permitroot'`, `ufw status verbose`,
`docker inspect coder --format '{{json .Mounts}}'`,
`nmap -sS -Pn -p 22,80,443,9090,9100,3001 <IP>`, `docker logs coder-caddy |
grep -c 'obtaining certificate'`, Template-`grep` aus `allowlist.md`).

Verification:
Jede SECURITY.md-Zeile verweist auf Befehl + erwartetes Ergebnis;
`sudo sshd -T`, `sudo ufw status`, externer `nmap`-Scan und Template-
Selbsttest (T-063) protokolliert und datiert.

---

## D-008 – Disaster Recovery: was persistent ist, was fehlt, was zu tun ist

Severity:
CRITICAL

Missing information:
`RESTORE.md` beantwortet Teile ehrlich (gesichert: nur Postgres-Dump,
neueste 14, lokal; nicht gesichert: `.env`, Compose/Caddy/Prometheus-Config,
Zertifikate, Dashboards, Prometheus-Historie 15d, Workspace-Dateien;
Offsite NICHT eingerichtet; nie geprobt; RTO-Tabelle `_offen_`), aber für
Handover unzureichend:

- Welche Daten persistent sind (6 Volumes + `.env` + Host-Config) steht nicht
  an einer Stelle (vgl. `06-architecture.md` F-002: kein State-Inventar).
- Was bei Totalverlust verloren ist (DB ohne Offsite + alle Workspace-
  Unterrichtsdaten + Dashboards + Zertifikats-Neuausstellung mit
  LE-Budget-Risiko) ist auf Reviews verteilt, nicht im Runbook als
  Verlusttabelle.
- Restore-Pfad A/B existiert, aber Pfad A ohne `ON_ERROR_STOP` (B2-009:
  stiller Teil-Restore möglich), Verifikation nur `/healthz` + Login (keine
  Datensicht), `.env`-Ersatz nur als „entweder original oder neu würfeln"
  angerissen.
- Wo Backups liegen (`/opt/coder/backups/coder_*.sql.gz`, 01:00-Cron,
  Rotation neueste 14) + was NICHT gesichert ist – vorhanden, aber ohne
  Frische-Alarm (`check.sh`-Leser fehlt, D-Monitoring offen).
- Manuelles Zutun (DNS/Weiterleitung, `.env`-Rückspielung `cp -a` + 600,
  `dropdb/createdb/psql`, Version-Gleichheit wegen Migrationen, RTO stoppen)
  steht drin, aber ohne Zeitstempel/Nachweis je gelaufen.

Why needed:
DR-Fragen der Aufgabe sind die einzigen, die im Ernstfall zählen. Ein
„erfolgreiches Backup-File" ist per AGENTS.md keine Evidenz – Restore-Test
ist Pflicht, fehlt aber. Der Nachfolger erbt ein Backup, das Totalverlust
nicht überlebt.

Where it should be documented:
RESTORE.md (erweitern, schlank halten) + OPERATIONS.md (Backup-Kapitel:
Lage, Retention, Verifikation, Freshness-Check).

Proposed content:
State-Inventar-Tabelle (Volumen/Datei → gesichert ja/nein → Rekonstruktionsweg);
Verlusttabelle Totalverlust; Pfad A/B mit `psql -v ON_ERROR_STOP=1` +
Datensicht-Verifikation (Tabellenzahl/Probe-Login mit echter Datensicht);
RTO-Tabelle mit erster echter Messung (Datum, Coder-Version, Dump-Alter, RTO,
Login ok); Offsite-Entscheidung (Ziel, Verschlüsselung, Schlüssel getrennt
vom Host, Retention – D6 mit Frist).

Verification:
Restore auf isolierter Test-VM (nie Produktion, T-080–T-083) aus
Offsite-Dump + Runbook, Zeit gestoppt (= RTO), in Tabelle eingetragen;
defekter Dump muss rot abbrechen (T-080-Negativprobe).

---

## D-009 – Troubleshooting: 11 Fehler ohne Diagnose-Pfad

Severity:
HIGH

Missing information:
Kein Troubleshooting-Kapitel. Zu jedem der geforderten Fehler existiert die
Diagnose nur als verstreuter Hinweis:

- Coder startet nicht → `sudo docker logs coder`, Socket-Probe (GroupAdd vs.
  DOCKER_GID), `compose ps`.
- PostgreSQL unhealthy → `docker inspect … Health.Status`,
  `docker exec coder-postgres pg_isready -U coder -d coder`,
  `docker logs coder-postgres`.
- Caddy kein TLS → `docker logs coder-caddy` (`obtaining certificate`),
  Apex-curl Schritt 10, `check-tls.sh`, DNS/Weiterleitung (Z. 28–32).
- DNS fehlt → `getent hosts <domain>` + Wildcard-Probe
  `setup-probe-<rand>.<domain>` (Z. 1578–1583).
- Portweiterleitung fehlt → Apex WARN-Texte (Z. 1567–1571), `ss -tlnp`,
  externer `nmap`, Schulnetz-Ticket an 10.16.103.13.
- SSH funktioniert nicht → `sshd -T`, `ufw status | grep 22/tcp.*LIMIT`,
  `fail2ban-client status sshd`, `journalctl -u ssh`.
- Backup schlägt fehl → `/opt/coder/backup.sh`-Exit, `gzip -t`,
  Header-Check (B2-001-defekt!), `df`, `/var/log/coder-backup.log`,
  `.backup.lock`-Skip mit letztem Backup.
- Update schlägt fehl → Update-Gate (B2-002-defekt!), `docker logs`,
  Rollback-Kommentar (exakt Pin vs. Re-Pull).
- Restore schlägt fehl → `gzip -t`, `ON_ERROR_STOP` fehlt (B2-009),
  Versionsdrift/Migrationen.
- Disk voll → `df`, `docker inspect … LogConfig` (10m×3), Prometheus
  `retention.time=15d` ohne `retention.size`, unrotierte Boot-/TLS-Logs.
- Container startet nach Reboot nicht → `/var/log/coder-boot.log`
  (`BOOT-GATE GRÜN/ROT`), `docker logs coder` (Postgres-Race, F-002),
  `stop_grace_period: 30s` nur Postgres.

Why needed:
Ohne Fehler→Befehl-Tabelle diagnostiziert der Nachfolger unter Druck per
`grep` im Skript. Jeder der 11 Fälle braucht: Symptom, Befehl, Gesund-
vs-Krank-Output, nächster Schritt.

Where it should be documented:
OPERATIONS.md (Troubleshooting-Tabelle, eine Zeile je Fehler + 3 Befehle).

Proposed content:
Tabelle: Fehler → 1. Befehl (kopierbar) → Gesund-Output → Krank-Output →
Verweis (Schritt/Runbook). Hinweis auf bekannte Defekte (B2-001/B2-002/B2-009)
als WARN-Box, bis gefixt.

Verification:
Jede Tabellenzeile auf Test-VM je einmal krank gestellt (Container stoppen,
PG stoppen, DNS kappen, Platte per tmpfs füllen, Reboot) und Soll-Output
protokolliert (T-051/T-052/T-073/T-110-Muster).

---

## D-010 – Monitoring, Logs, Grafana-Zugang

Severity:
MEDIUM

Missing information:
Monitoring existiert (Prometheus 2 Jobs `coder:2112` + `node-exporter:9100`,
`prometheus.yml` 15s; Grafana loopback `127.0.0.1:3001`; node-exporter
`127.0.0.1:9100`), aber:

- Kein Konsum: keine Alert-Regeln, kein Alertmanager, kein `check.sh`
  (Platte/Backup-Frische/Coder-down) – `06-architecture.md` F-007:
  „Metriken ohne Konsument".
- Grafana: nur Tunnel-Hinweis, kein Befehl, keine Dashboards (leben nur in
  `grafana_data`, weder versioniert noch gesichert – `05-backup-recovery.md`
  F-014), kein Admin-Verfahren nach Rotation.
- Logs: Orte bekannt (siehe D-005), aber Rotation nur für
  `coder-backup.log` (logrotate weekly/8/compress); `coder-boot.log`
  und `coder-tls.log` unrotiert; Container-Logs 10m×3 (P-007 umgesetzt),
  aber nirgends als „Log-Konzept" beschrieben.

Why needed:
Betriebsfrage „Wie prüft man Monitoring?" ist unbeantwortet. Schleichende
Defekte (Platte voll, Backup fehlt seit Wochen, Cron tot) bleiben still
(`05-backup-recovery.md` F-007) – der Nachfolger schaut nie rein, weil kein
Pfad dorthin führt.

Where it should be documented:
OPERATIONS.md (Monitoring-Kapitel: Zugänge, Maps, Log-Konzept, Freshness-Check).

Proposed content:
Tunnel-Befehle, Prometheus-`/-/healthy`-Check, Grafana-Login-Check,
Export-Pflicht für Dashboards („als Code oder Verlust akzeptieren"),
Log-Tabelle (Pfad → Rotation → Leser), Minimal-Frische-Prüfung (Alter des
neuesten `coder_*.sql.gz` + `df` + `/healthz`, per `logger` – bis
D-Monitoring nach Messung entscheidet).

Verification:
`curl --max-time 5 http://127.0.0.1:9090/-/healthy`,
`curl --max-time 5 http://127.0.0.1:3001/login`,
`curl --max-time 5 http://127.0.0.1:9100/metrics` je dokumentiert grün;
`logrotate --debug /etc/logrotate.d/coder-backup` grün.

---

## D-011 – Backup-Aussagekraft und Restore-Nachweis

Severity:
HIGH

Missing information:
Backup-Mechanik ist im Code gut (flock-Selbst-Lock, Temp+`mv`, `gzip -t`,
Header-Fail, 512-Byte-/Halbierungs-Warnung, Mindestbestand Retention 14,
`cron`-Paket + Cron-Datei, Testlauf im Setup), aber:

- Header-Check per B2-001 defekt (SIGPIPE + pipefail verwirft jeden Dump
  > ~64 KB) – im Operator-Dok ungenannt.
- Skip=Exit 0 meldet Backup-Alter, aber `update.sh` nutzt es nicht als
  Frische-Gate (B-010c).
- Cron 01:00 vs. Reboot 03:00 vs. manuelles Update unkoordiniert (kein
  Overlap außer Lock), 500-MB-`df`-Bodenwert „UNVERMESSEN" (B-015).
- Restore-Nachweis: keiner (RTO `_offen_`, T-080–T-083 nie gelaufen).
  AGENTS.md fordert Restore-Tests – es gibt null Belege.

Why needed:
Handover muss ehrlich sagen: „Backup läuft (Datei da, `gzip -t` grün), aber
Restore ist unbewiesen + ein Gate ist defekt." Sonst vertraut der Nachfolger
einer grünen Datei.

Where it should be documented:
OPERATIONS.md (Backup-Kapitel) + RESTORE.md (Nachweis-Tabelle).

Proposed content:
Backup-Steckbrief (Zeit 01:00, Ort, Retention 14, Verifikation `gzip -t` +
Header + Warnungen, Lock-Datei `.backup.lock`, Orphan-Sweep, Log + logrotate);
ehrliche Box (B2-001-Status, B2-009-Status, Offsite-Status, letzter
Mini-Restore mit Datum); Frische-Befehl
(`ls -t /opt/coder/backups/coder_*.sql.gz | head -n1 | xargs -I{} sh -c
'gzip -t {} && stat -c \"%y %s\" {}'`).

Verification:
`sudo /opt/coder/backup.sh; echo backup-exit=$?`,
`gzip -t <latest> && echo GZIP_OK`, Groß-Dump-Fixture > 1 MB (T-071b),
Mini-Restore in Wegwerf-Postgres mit Protokoll.

---

## D-012 – Versionen und Änderungen nicht nachvollziehbar (CHANGELOG fehlt)

Severity:
MEDIUM

Missing information:
Pins im Code (`CODER_VERSION:=2.36.6` ohne `v`, `CADDY_VERSION:=2.10` Minor,
`PROMETHEUS_VERSION:=v3.14.0`, `GRAFANA_VERSION:=12.4.5`,
`NODE_EXPORTER_VERSION:=v1.12.1`, `postgres:15-alpine` floating) + Kommentar
zu Update-Pfaden – aber kein CHANGELOG.md, keine Update-Historie (wer hat
wann was auf welche Version gehoben, mit welchem Ergebnis), keine
Freigabe-Kennzeichnung (v2 ist per Breaker gesperrt, steht aber nur in
`ai-review/`).

Why needed:
Wartungsfrage „Darf ich updaten? Was war die letzte Version?" ist ohne
CHANGELOG Ratespiel. Coder-Major mit Migration ist irreversibel möglich –
das braucht Historie + Dump-Verweis.

Where it should be documented:
CHANGELOG.md (neu, append-only) + OPERATIONS.md (Update-Verfahren verweist
darauf).

Proposed content:
Je Eintrag: Datum, alte→neue Version je Komponente, Pre-Backup-Datei,
Gate-Ergebnis, RTO/Login, Operator. Plus Sperrvermerk (B2-001/B2-002/B2-003
offen → kein Update/Rollout bis Fix + VM-Beleg).

Verification:
`test -f CHANGELOG.md && tail -5 CHANGELOG.md` zeigt letzten Update-Eintrag;
`git log --oneline -10` + `git status` vor jedem Update im Protokoll.

---

## D-013 – Review-Wahrheit vs. Operator-Wahrheit (Freigabe unklar)

Severity:
HIGH

Missing information:
~17.000 Zeilen Reviews (`ai-review/`, inkl. 2735-Zeilen-TEST_PLAN, 0
ausgeführte VM-Tests) sind kein Handover-Wissen. Kritisch:
`FINAL-BREAKER-v2.md` belegt zwei CRITICAL-Regressionen (B2-001, B2-002),
eine HIGH-Regression (B2-003) und sperrt v2 („darf weder gemergt noch
ausgerollt werden"). Ein Nachfolger, der nur Code + RESTORE.md liest,
sieht die Sperre nicht; einer, der alle Reviews liest, braucht Tage und
findet keine Freigabe (PLAN.md trunkiert, T-006 rot, RTO offen).

Why needed:
Übergabe braucht genau einen Satz: „Freigegebener Stand ist X, bekannte
Sperren sind Y, nächste Schritte sind Z." Heute gibt es drei Wahrheiten
(Code sagt grün, Breaker sagt rot, Tabelle sagt offen).

Where it should be documented:
README.md (Status-Box, 5 Zeilen) + CHANGELOG.md (Freigabe-Einträge).
Reviews bleiben Referenz, werden aber nicht zur Lese-Pflicht.

Proposed content:
Status-Box: freigegebener Commit, bekannte Blocker (B2-001/B2-002/B2-003,
B-002-Pull-Probe, Offsite, RTO), Link auf Breaker-Urteil + Test-VM-
Auftrag (`coder-test-<datum>`, Testdomain, Snapshot-Pflicht, nie
Produktion). PLAN.md-Trunkierung als Entwurf kennzeichnen oder reparieren.

Verification:
`git rev-parse --short HEAD` in Status-Box = ausgecheckter Stand;
`ls tests/` nicht-leer + datierter VM-Protokoll-Eintrag vor nächstem Review
(C-015-Meta-Test).

---

## D-014 – Offene Entscheidungen ohne Eigentümer und Frist

Severity:
HIGH

Missing information:
In Reports sauber benannt (D-TLS, D-Socket, D-SSH, D-Firewall, D-Reboot-
Fenster, D-Monitoring/Ressourcen, D-Passwort-Reihenfolge, D-Workspace-RPO,
D-Update-Split, D-Caddy-Pin, D-Offsite/D6, B-004-Erstinventar, T-063/T-124/
T-125/T-126-Protokolle), aber für den Betrieb nirgends mit Eigentümer + Datum:

- D-TLS (echter `ask` vs. DNS-01-Wildcard + CAA + Provider-Token).
- D-Socket (Allowlist dauerhaft vs. Proxy vs. separater Host).
- D-SSH (Key-Termin + Zweit-Zugang + Härtungsdatum).
- D-Firewall (DOCKER-USER ja/nein nach Dual-Stack-Test).
- D-Reboot-Fenster (03:00 mit Schulbetrieb abstimmen).
- D-Monitoring (Messung Platte/`docker stats`-Woche, dann `retention.size` +
  `check.sh`-Leser + Schwellen).
- D-Workspace-RPO (Git-Push-Pflicht vs. Server-Backup + Kommunikation).
- D-Update-Split (`app`/`db`-Trennung + DB-Major-Prozess).

Why needed:
Ohne Eigentümer/Frist bleibt jedes Provisorium Dauerzustand (SSH-Passwort,
Offsite-Leere, Wildcard-WARN). Der Nachfolger braucht eine Entscheidungsliste,
keine 17.000-Zeilen-Suche.

Where it should be documented:
README.md (Entscheidungs-Tabelle, 1 Zeile je D-Punkt) + SECURITY.md /
OPERATIONS.md (Details). Umsetzung in CHANGELOG.md vermerken.

Proposed content:
Tabelle: Entscheidung | Option A/B | Eigentümer | Frist | Status |
Blockiert (z. B. B-017-Flag gated auf B-004-Inventar). Leere Frist = als
`_offen_` sichtbar, nicht verschwiegen.

Verification:
Jede Tabellenzeile hat Eigentümer + Datum oder `_offen_`; `grep -c '_offen_' README.md`
ist die offene Risiko-Zahl.

---

## D-015 – Testplan existiert, aber nie ausgeführt

Severity:
MEDIUM

Missing information:
`ai-review/TEST_PLAN.md` (T-001–T-126+, Fresh Install, Idempotenz, Abbruch-,
Netz-, Docker-, Security-, Backup-, Restore-, Reboot-Matrix) ist ausführbar
geschrieben, aber per Selbstauskunft nie gelaufen („keine Test-VM
verfügbar"). `tests/` leer. Für Handover heißt das: Es gibt ein Prüfprogramm,
aber keinen einzigen Beleg (kein Datum, kein Commit, keine Tool-Versionen,
kein Exit-Code, kein Log). Zusätzlich fehlen die B2-neuen Tests (T-071b
Groß-Dump, Gate-Handshake, Hex-Migration, Drift-Abbruch, Reset-Ordnung,
Downgrade-Probe, Defekt-Dump-Restore, `caddy validate`).

Why needed:
AGENTS.md: „Never claim a test passed unless it was actually executed."
Ein Nachfolger darf TEST_PLAN-Erfüllung nicht annehmen – er muss bei Null
anfangen. Das muss dokumentiert sein, sonst entsteht falsche Sicherheit.

Where it should be documented:
README.md (Test-Status-Box) + OPERATIONS.md (Pflicht-Tests vor Freigabe).

Proposed content:
Test-Status (0/X ausgeführt, Test-VM-Auftrag `coder-test-<datum>` +
Testdomain + Snapshot-Regel), Prioritäts-Reihenfolge (T-071b, Handshake,
Hex-Migration zuerst – sie fangen B2-001–003), Protokollpflicht (Datum,
VM-Name, `git rev-parse --short HEAD`, Tool-Versionen, Exit-Codes, Logs).

Verification:
`ls tests/` + VM-Protokoll mit RTO-Zahl vorhanden; `bash -n setup-coder.sh`
+ ShellCheck + `compose config --quiet` als Gate vor jedem Merge.

---

## Handover Checklist

Abzuarbeiten in Reihenfolge. Jeder Punkt mit Datum + Ergebnis protokollieren.
Stop-Regeln beachten (bei rot nicht weiter auf Produktion).

### 1. Zugang und Bestandsaufnahme (lesend, 1–2 h)

- [ ] SSH-Zugang + sudo bestätigt (`sudo -v`), Zweit-Zugang (Konsole/Proxmox/
  iDRAC) bekannt und getestet.
- [ ] Repo-Klon auf Admin-Rechner, `git rev-parse --short HEAD` notiert,
  `git status`/`git log --oneline -10` geprüft.
- [ ] Freigabe-Status gelesen: `ai-review/FINAL-BREAKER-v2.md`
  (B2-001/B2-002/B2-003-Sperre verstanden – kein Update/Rollout bis Fix +
  VM-Beleg).
- [ ] Server-Ist: `lsb_release -a`, `free -h`, `df -h /opt/coder`,
  `docker --version`, `sudo docker compose version`.
- [ ] Datei-Ist: `ls -l /opt/coder/` (`.env` 600/root? `backups/` 700?),
  `stat -c '%a %U:%G %n' /opt/coder/.env /opt/coder/backups`,
  `cat /opt/coder/RESTORE.md` vorhanden?
- [ ] Container-Ist: `sudo docker compose -f /opt/coder/docker-compose.yml ps`;
  je Container `sudo docker inspect -f '{{.State.Running}}' <name>`;
  Postgres `sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres`.
- [ ] Netz-Ist: `ss -tlnp`, `ss -ulnp | grep 443`, `sudo ufw status verbose`,
  `grep IPV6 /etc/default/ufw`, `sudo fail2ban-client status sshd`,
  `sudo sshd -T | grep -iE 'passwordauth|kbdinteractive|permitroot'`.

### 2. Voraussetzungen schließen (Gate vor jeder Änderung)

- [ ] DNS: `getent hosts coder.ghse-unterricht.de` + Wildcard-Probe
  `getent hosts setup-probe-<rand>.coder.ghse-unterricht.de` grün.
- [ ] Schulnetz-Ticket: Weiterleitung 80/443 (+22 für Heimzugriff) an
  10.16.103.13 bestätigt.
- [ ] Externer Scan protokolliert: `nmap -sS -Pn -p
  22,80,443,9090,9100,3001 <IP>` + `nmap -sU -Pn -p 443 <IP>`
  (erwartet: 22/80/443 offen, 9090/9100/3001 geschlossen).
- [ ] Secrets-Verfahren geklärt: Erstpasswörter aus `/opt/coder/.env`
  (600/root) übernommen, Aufbewahrung + Rotationsweg
  (`reset-passwords.sh`) bekannt; keine Kopie in Tickets/Logs.

### 3. Gesundheit belegen (lesend, kein Eingriff)

- [ ] `https://coder.ghse-unterricht.de/healthz` = 200 (Apex + SNI echt,
  kein Host-Header-Trick).
- [ ] `sudo docker exec coder-postgres pg_isready -U coder -d coder`.
- [ ] `curl --max-time 5 http://127.0.0.1:9090/-/healthy`,
  `…/3001/login`, `…/9100/metrics` dokumentiert.
- [ ] `sudo docker logs coder-caddy --tail=50 | grep -iE
  'obtaining|error|acme'` ohne Auffälligkeit; wöchentlicher
  `check-tls.sh`-Wert notiert.
- [ ] Template-Selbsttest aus normalem Workspace (T-063): kein
  `docker.sock`, kein `postgres:5432`, keine fremden Container; gegen
  `templates/allowlist.md` abgehakt, Erstinventar-Zeile ausgefüllt.

### 4. Backup und Restore (Kern der Übernahme)

- [ ] Letztes Backup: `ls -t /opt/coder/backups/coder_*.sql.gz | head -n1`,
  `gzip -t` grün, Größe/Datum plausibel, Alter < 24 h.
- [ ] Cron: `cat /etc/cron.d/coder-backup` (01:00), `systemctl is-active cron`,
  `cat /etc/logrotate.d/coder-backup`, `logrotate --debug` grün.
- [ ] Offsite-Status ehrlich notiert (derzeit: NICHT eingerichtet → Risiko
  akzeptiert oder D6-Entscheidung mit Frist eröffnet).
- [ ] Restore auf **isolierter Test-VM** (nie Produktion, T-080–T-083) nach
  `RESTORE.md` gefahren, RTO gestoppt und in Tabelle eingetragen
  (Datum, Coder-Version, Dump-Alter, RTO, Login ok).
- [ ] Verlusttabelle verstanden und unterschrieben: `.env`, Configs, Zertifikate,
  Dashboards, Prometheus-Historie, Workspace-Dateien (Unterrichtsdaten!).

### 5. Wartung übernehmen (erst nach 1–4)

- [ ] Update-Verfahren gelesen (`update.sh` manuell, Pre-Backup, Gate,
  kein Auto-Prune, Prometheus/Grafana nur per Setup-Re-Run);
  Sperre B2-001/B2-002/B2-003 geprüft; letzter CHANGELOG-Eintrag gelesen.
- [ ] Reset-Verfahren gelesen (`reset-coder.sh` RESET vs.
  RESET-OHNE-BACKUP, `--force` nur Break-Glass, Workspace-Inventar vorher);
  nie auf Produktion geübt.
- [ ] Reboot-Fenster 03:00 mit Schulbetrieb abgeglichen (D-Reboot-Fenster),
  `/var/log/coder-boot.log` (`BOOT-GATE GRÜN/ROT`) bekannt.
- [ ] SSH-Härtungspfad bekannt (`ssh-harden.sh` nur mit getestetem Key +
  Zweit-Zugang + D-SSH-Termin); bis dahin Passwort-Stärke + fail2ban-
  Beobachtung als Provisorium dokumentiert.

### 6. Entscheidungen und Doku schließen

- [ ] Entscheidungs-Tabelle (D-TLS, D-Socket, D-SSH, D-Firewall, D-Reboot,
  D-Monitoring, D-Workspace-RPO, D-Update-Split, D-Offsite) mit Eigentümer +
  Frist befüllt oder `_offen_` markiert.
- [ ] Test-VM bestellt (`coder-test-<datum>`, Debian 13, Snapshot-fähig,
  Testdomain) – nächste Review-Runde erst nach T-071b + Handshake +
  Hex-Migration (C-015-Regel).
- [ ] Eigene Notizen ins Betriebslog/CHANGELOG geschrieben; offene WARNs
  (Wildcard, SSH-Passwort, Offsite) mit Wiedervorlage versehen.

---

## Documentation Structure

Ziel: „Alles Wesentliche schnell finden, Details an der richtigen Stelle."
`README.md` umfassend, aber kein 2000-Zeilen-Handbuch. Richtwert: README
~150–250 Zeilen, OPERATIONS ~300–500, SECURITY ~150–250, RESTORE ~80–150,
CHANGELOG append-only.

### README.md (neu, Einstieg, ~200 Zeilen)

- Was/Wofür (3 Sätze) + Status-Box (freigegebener Commit, bekannte Sperren
  B2-001/B2-002/B2-003, Test-Status 0/X, RTO `_offen_`).
- Architektur-Kurzbild (Tabelle Host vs. Container + Ports + Volumes +
  Ablageorte).
- Voraussetzungen-Checkliste (D-003, kopierbare Befehle).
- Installation in 5 Zeilen (Aufruf, Variablen-Hinweis, Erfolgsdefinition
  Exit 0 + 0× `[FEHLER]`, Re-Run-Regel).
- Betrieb/ Wartung/ Restore/ Security als je 3-Zeilen-Verweis
  („Details: OPERATIONS.md#…").
- Entscheidungs-Tabelle (D-Punkte, Eigentümer, Frist, `_offen_`-Zahl).
- Doku-Landkarte (welche Frage steht wo).

### RESTORE.md (erweitern, Runbook, ~120 Zeilen)

Behalten: Verfahrenstiefe, Was-gesichert/was-nicht (P-024-Ehrlichkeit),
Pfad A/B, Migrations-/Workspace-Hinweise, RTO-Tabelle.
Hinzufügen: State-Inventar-Tabelle, Verlusttabelle Totalverlust,
`psql -v ON_ERROR_STOP=1` + Datensicht-Verifikation (B2-009-Fix),
`.env`-Rückspielung (`cp -a`, 600, root:root), Versions-Gleichheits-Regel,
erste echte RTO-Messung. Nicht hinein: allgemeine Betriebs-/Security-Themen.

### OPERATIONS.md (neu, Betrieb + Wartung + Troubleshooting)

- Generierte-Dateien-Tabelle (D-002) + Variablen-Tabelle + Secrets-Verfahren.
- Start/Stop/Status/Logs/Healthchecks je Komponente (D-005).
- Wartung je Verfahren (Update/Rollback/Rotation/Reset/Reboot, D-006).
- Monitoring/Logs/Grafana (D-010) + Backup-Steckbrief (D-011).
- Troubleshooting-Tabelle für die 11 Fehler (D-009).
- Test-Status + Pflicht-Tests vor Freigabe (D-015).

### SECURITY.md (neu, Grenzen + Entscheidungen)

- Ist-Tabelle je Grenze (SSH, UFW/Docker, Socket/Templates, TLS, Images,
  Secrets, Backups, öffentliche Dienste) mit Risiko (1 Satz) + Nachweisbefehl.
- Provisorien als solche markiert (SSH-Passwort aktiv + weltweit, Offsite
  leer, On-Demand-`ask` immer-200) mit Eigentümer + Frist.
- Template-Allowlist-Verweis (`templates/allowlist.md` + Erstinventar +
  T-063-Protokoll), Scan-Nachweise (`nmap`, `ss`, `iptables-save` inkl.
  `DOCKER-USER`-Status), Rotations-Regel.
- Nicht hinein: Installations-Klickpfad, Restore-Schrittfolge (nur Verweise).

### CHANGELOG.md (neu, append-only)

- Je Eintrag: Datum, Commit, Komponenten-Versionen (Coder/Caddy/Prometheus/
  Grafana/Exporter/Postgres-Tag), Pre-Backup-Datei, Gate-Ergebnis, RTO/Login,
  Operator, Entscheidungen (D-Punkt geschlossen?).
- Sperrvermerke (B2-001/B2-002/B2-003) + Freigaben. Keine Prosa-Essays, keine
  Duplikate aus Reviews.

### Was ausdrücklich nicht wohin gehört

- `ai-review/` bleibt Referenz (Befund-Substanz, Evidenz-Standard,
  B-/B2-/P-Nummern), wird aber keine Lese-Pflicht für den Betrieb.
- Keine 2000-Zeilen-README: Historien-Kommentare (B-/P-/F-Nummern ohne
  Entscheidungsgehalt), Heredoc-Quelltexte und Review-Duplikate gehören
  nicht in Operator-Doku (vgl. `07-complexity.md` C-010).
- Neue WARN/Check-Zeilen nur mit benanntem Leser + Reparaturanleitung
  (C-013/C-014-Regeln), sonst Warnmüdigkeit.

## Verifikation dieser Review (Nachweis, kein Behaupten)

- `test -f README.md && echo FAIL-sollte-fehlen || echo README_MISSING-bestätigt`;
  `test -f docker-compose.yml || echo COMPOSE_MISSING-bestätigt`;
  `ls tests/ | wc -l` = 0; `wc -l ai-review/TEST_PLAN.md` = 2735,
  `grep -ci 'test-vm.*verfügbar\|nie.*ausgeführt\|nicht.*ausgeführt' ai-review/IMPLEMENTATION-REPORT-v2.md ai-review/FINAL-BREAKER-v2.md RESTORE.md` > 0.
- Stichproben: `grep -n 'DOMAIN_CODER:=coder.ghse-unterricht.de\|10.16.103.13\|52-coder-reboot\|coder-backup\|check-tls\|boot-check' setup-coder.sh`;
  `grep -n '_offen_' RESTORE.md templates/allowlist.md`;
  `grep -n 'B2-001\|B2-002\|darf.*nicht in Produktion' ai-review/FINAL-BREAKER-v2.md`.
- Diese Datei ändert keine andere Datei (`git status --short` zeigt nur
  `ai-review/08-documentation.md` als neu).
