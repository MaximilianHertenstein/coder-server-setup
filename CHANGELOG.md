# CHANGELOG.md

Append-only Dokumentation des tatsächlichen Repository-Stands.
**Es gibt keine Releases.** Dieses Verzeichnis kennt keine Versionsnummern
und keine Freigaben – nur Daten, Commits und was sich tatsächlich geändert
hat. Kein Eintrag behauptet eine Prüfung, die nicht stattgefunden hat.

Format je Eintrag: Datum, Umfang, geänderte Dateien, nachweisbarer Teststand,
offene Punkte. Ältere Einträge werden nicht umgeschrieben; Korrekturen kommen
als neuer Eintrag.

Stand: 2026-09-29 · aktueller Quellstand: `git log -1 --oneline`
(Branch `main`; Umsetzung lief auf `ai/implementation-v3`; die Änderungen
dieses Eintrags sind **nicht committet** – Arbeitsstand im Repo).

---

## 2026-09-29 – Review-Runde 2 (zweite Fundliste A1–C7)

**Umfang:** zweite Fundliste bewertet und umgesetzt (ohne Deployment –
der Test-Host läuft weiterhin auf dem Stand von Lauf 9 / Commit `252ebc8`).
Bewertung je Punkt in
[ai-review/REVIEW-2026-09-29-AUSWERTUNG.md](ai-review/REVIEW-2026-09-29-AUSWERTUNG.md)
Abschnitt 6.

- **Bewertung:** zugestimmt und umgesetzt A1, A2, A4, A5, A6, A7, B1, B4,
  B4b (nur Doku), B6, C1, C2, C3, C4, C6, C7. **Abgelehnt:** A3 (Pipe-/SIGPIPE-Risiko
  ist bei gemessenen 4 700 B / 10 903 B / 633 B / 0 B nicht erreichbar),
  C5 (Datei-Split bricht die zeilenmarkerbasierten Tests; stattdessen
  ID-Legende). **Offen als Entscheidung:** B5 (Client-IPs im Audit –
  Datenschutzfrage, Env-Namen `CODER_PROXY_TRUSTED_HEADERS`/
  `CODER_PROXY_TRUSTED_ORIGINS` belegt, bewusst nicht gesetzt). B2/B3
  waren bereits in der Doku erledigt.
- **Code (`setup-coder.sh`):** A1/A7 `versions.env` erst nach
  erfolgreichem `up -d` (+`install -d /opt/coder`), A2 explizite Datei
  `/opt/coder/domain` und `tr`-Leser in `boot-check.sh`/`update.sh`,
  A4 Boot-Gate: PG-Health-Warten → Warten auf alle Container → Meldung,
  A5 Volume-Guard bei vorhandenem `coder_postgres_data`, A6
  `fail2ban-client status sshd` statt `get … logpath`, B1 optionale
  Erstanlage des Owner-Kontos über `CODER_FIRST_USER_*` (Passwort per
  stdin in den Container, Flags in `coder login --help` von v2.36.6
  geprüft), B4 `check-tls.sh` schreibt `node-textfile/coder_tls.prom` +
  vierte Prometheus-Regel `TlsIssuanceBudgetHigh`, B6 SSH-Port-Vorabprüfung
  (`sshd -T`) vor der ersten `ufw`-Änderung, C1 Zeitzone `Europe/Berlin`,
  C2 Hinweis zur Container-Neuerstellung nach Passwort-Rotation,
  C3 doppelter Container-Check in `reset-passwords.sh` entfernt, C4
  `/etc/logrotate.d/coder-logs` für `coder-boot.log`/`coder-tls.log`,
  C6 fünf Tippfehler, C7 Hinweis zum Leeren des Scrollbacks bei
  Klartext-Zugangsdaten.
- **Dokumentation:** README (vier Alarmregeln, Prüfpunkt 11 für die
  Erstanlage), SECURITY (Log-Rotation für alle drei Logs, vier Regeln ohne
  Kanal, Grenzen-Tabelle 4/9 aktualisiert + neue Zeilen 11 (B5) und 12
  (DNS-01), Port-Vorabprüfung in §4), OPERATIONS (Dateitabelle: `coder-logs`,
  `coder_tls.prom`, `/opt/coder/domain`; §5 TLS-Metrik-Check + 4 Regeln;
  §7 C2-Folge und Zeitzone; §11 Schritt 4 Erstkonto + DNS-01-Alternative),
  TROUBLESHOOTING (Budget-Zählung über Metrik/Regel), Auswertungsdok
  Abschnitt 6 mit Bewertung und ID-Legende.
- **Tatsächlich ausgeführt am 2026-09-29 (lokal):**
  - `bash -n setup-coder.sh` 0 Befunde; `shellcheck -S warning
    setup-coder.sh` genau 1 Befund (SC2034, Retry-Zähler, unverändert).
  - **10 Testskripte Exit 0, 316 PASS, 0 FAIL**
    (`tests/t-b2-007-drift-hash.sh` von 16 auf **17** Drift-Dateien
    hochgezählt, `coder-logs` in der EXPECTED-Liste).
  - `yaml.safe_load` für `coder-alerts.yml` (4 Regeln inkl.
    `TlsIssuanceBudgetHigh`) und `prometheus.yml` ok.
  - Linkprüfung über 37 Markdown-Dateien: 192 lokale Links, 0 tot.
- **Tatsächlich ausgeführt auf dem Test-Host `2.29.11.30`:**
  - `logrotate -d` für den neuen `coder-logs`-Inhalt (nach `/tmp` kopiert,
    eigener State): Syntax akzeptiert, beide Pfade erkannt.
  - `docker exec coder coder login --help`: Flags `--first-user-email`
    `-username` `-password` `-full-name` `-trial` vorhanden (v2.36.6).
  - **Lauf 10** (neues Skript auf den Host gespielt) → **Exit 0,
    0 `[FEHLER]`, 0 Drift**, 17 Hashes, `/opt/coder/domain` und
    `/etc/logrotate.d/coder-logs` angelegt, Prometheus startete neu
    (Regel-Datei geändert) und kennt jetzt **4 Regeln** inkl.
    `TlsIssuanceBudgetHigh`; alle übrigen Container unverändert
    (`StartedAt` identisch).
  - **Lauf 11** (Idempotenz) → **Exit 0, 0 `[FEHLER]`, 0 Drift, keine
    Container-Neustarts**; beide Läufe zeigen nur die beiden bekannten
    Warnungen (externer nginx blockiert `healthz`, SSH-Passwort-Login).
  - `timedatectl`: `Etc/UTC → Europe/Berlin (CEST)` gesetzt; A6-Meldung
    `[OK] fail2ban zählt SSH-Fehlversuche (Total failed: 1011)`; B6-Prüfung
    still (bricht nur ab, wenn sshd ≠ 22); B2-Hinweis „Noch kein
    Nutzerkonto vorhanden" (B1-Variablen waren nicht gesetzt, Zweig blieb aus).
  - `sudo /opt/coder/check-tls.sh` manuell: schreibt
    `coder_tls.prom` mit `coder_tls_issuances_7d 32`; daraufhin meldet
    Prometheus `TlsIssuanceBudgetHigh` **firing** – auf dem Test-Host
    korrekt (32 Zertifikats-Ausstellungen in 7 Tagen durch die früheren
    Läufe), ohne Benachrichtigungskanal.
  - `sudo /opt/coder/boot-check.sh` manuell: PG zuerst healthy, dann alle
    sechs Container, dann `/healthz` → **BOOT-GATE ROT** mit 000 (bekannter
    externer nginx), A4-Reihenfolge laut `/var/log/coder-boot.log` korrekt.
  - `logrotate -d /etc/logrotate.d/coder-logs` (echte Datei): Syntax ok.
---

## 2026-09-29 – Review-Runde: Umsetzung (Phasen 1–7) + Live-Läufe 8 und 9

**Umfang:** Umsetzung der Befunde aus der Review-Runde im vereinbarten
Umfang „alle Fixes außer D1" plus Doku; danach zwei vollständige
Setup-Läufe auf dem Test-Host `2.29.11.30` (Debian 13). Doku-Ziel:
README, SECURITY, OPERATIONS, TROUBLESHOOTING, RESTORE, neue
`ai-review/REVIEW-2026-09-29-AUSWERTUNG.md`.

- **Code (`setup-coder.sh`):** A1 ufw-Failsafe-Ordnung (restriktive Regel
  wiederherstellen → prüfen → erst dann `limit` löschen; Worldwide-`limit`
  nur im else-Zweig; Pfad-Check), A2 Postgres-Loopback-Verifikation mit
  Negativkontrolle, A3 `flock -w 300`/`exit 75`, A4 Versions-Kommentar,
  A5 Versionswächter + `versions.env`, A6 `retry3 docker compose pull`,
  A7 TLS-Gate mit zwei Probes, A9 `ssh-harden.sh`-Kopie, A10
  `daemon.json`-Anlage mit Merge-Anweisung statt stillschweigendem
  Überschreiben,
  B1 lokaler On-Demand-`ask`-Endpunkt, B2 Owner-/Nutzerhinweis in Schritt 10,
  B6 `CODER_TELEMETRY_ENABLE=false`, B7 fail2ban-Read-Order (Drop-in
  `/etc/fail2ban/jail.d/10-coder-sshd.local` statt `jail.local`), C1
  node-exporter-Textdatei + atomarer Metrik-Schreibvorgang, C2
  `daemon.json` (Log-Limit, nur bei Container-frei neu starten), C3
  Prometheus-Regel-Dateien + Grafana-Datasource-Provisioning + bedingte
  Restarts (`restart_on_cfg_change`), C4 `caddy validate` + `reload`,
  C6 Docker-Origin für unattended-upgrades (Append, `a=<Suite>` ohne
  Codename-Token), C7 `apt_install()`, C9 `name: coder` + `CADDY_ACME_CA`,
  D2 Docker-Range-Template-Inspektor.
- **Nicht umgesetzt (bewusst):** D1 Datei-Split (Testmarker brechen),
  A8, B3 (nur Doku), erzwungener Admin-Account.
- **Dokumentation:** README-Status/`TLS`-Absatz, SECURITY-§3–§5/§8,
  OPERATIONS-Dateitabelle/Checks/Drift 16, TROUBLESHOOTING A10/B5/C5/D5/E8,
  RESTORE-`versions.env`-Hinweis.
- **Tatsächlich ausgeführt am 2026-09-29 (lokal):**
  - `bash -n setup-coder.sh` 0 Befunde; `shellcheck -S warning
    setup-coder.sh` genau 1 Befund (SC2034, ungenutzter Zähler in der
    Retry-Schleife); `shellcheck` für `tests/t-b1-on-demand-ask.sh` sauber.
  - **10 Testskripte Exit 0, 314 PASS, 0 FAIL** (neu:
    `tests/t-b1-on-demand-ask.sh`; `tests/t-b2-007-drift-hash.sh` auf 16
    `note_drift`/`remember_hash` hochgezählt).
  - Gerenderte Compose-/Prometheus-/Rules-/Daemon-Dateien: YAML-Parser,
    `docker compose config --quiet` Exit 0, `promtool check config`
    „3 rules found", „is valid prometheus config file syntax".
  - Linkprüfung über `*.md`, `ai-review/*.md`, `templates/*.md`:
    0 tote Links.
- **Tatsächlich ausgeführt am 2026-09-29 (Test-Host `2.29.11.30`):**
  - Lauf 8 → **Exit 0, 0 `[FEHLER]`**; Lauf 9 (Idempotenz) → **Exit 0,
    0 `[FEHLER]`, 0 Drift-Warnungen, keine Container-Neustarts**,
    C2-Warnung entfallen (`daemon.json` vorhanden). Verbleibend in beiden
    Läufen nur die dokumentierten Warnungen (SSH-Passwort-Login aktiv,
    `healthz` ohne 200).
  - Verifiziert nach Lauf 8: B1 `ask` → `ok` für
    `8080--main--ws--user.…`, 404 für `evil.…` und für die Apex-Domain,
    `caddy validate` „Valid configuration"; B7 `jail.local` entfernt,
    Drop-in angelegt, Jail `sshd` aktiv; C6 `apt-config dump` enthält
    `o=Docker,a=trixie,l=Docker CE,c=stable`; C1
    `/opt/coder/node-textfile/coder_backup.prom` vorhanden, Metrik über
    `:9100/metrics` sichtbar; C3 Prometheus kennt genau 3 Regeln
    (`CoderTargetDown`, `RootPartitionFillingUp`, `BackupStale`), Grafana-
    Datasource-Datei liegt in `grafana/provisioning/datasources/`; C2
    `/etc/docker/daemon.json` geschrieben, danach **`systemctl restart
    docker` nach Rücksprache ausgeführt** (Stack vorher gestoppt, `up -d`,
    alle 6 Container wieder `Up`, Postgres `healthy`, Metriken 200):
    `docker inspect` meldet jetzt bei allen Containern `json-file` mit
    `max-size=10m`/`max-file=3`; `versions.env` angelegt; ufw unverändert
    (nur worldwide `22/tcp LIMIT`); `logrotate -d` meldet rotiert.
- **Neu dokumentiertes Risiko (extern, nicht im Repo behebbar):** Der
  öffentliche IP `85.13.130.100` beantwortet 80/443 mit einem **nginx**
  (404), nicht mit Caddy – daher scheitert die ACME-Ausstellung
  (http-01 404, tls-alpn-01 „no application protocol") und `…/healthz`
  lief in den Läufen 3 bis 9 nie HTTP 200 (Läufe 1/2 ohne diesen Check).
  Caddy hat daher derzeit **kein Zertifikat**. Der Test-Host ist eine
  Hetzner-VM (kein Schul-Standort); die Portweiterleitung/der Proxy vor
  80/443 wird später konfiguriert (D-TLS/D-Netz). Kein Regression dieser
  Runde – belegt durch `curl -I http://…/` → `Server: nginx` von außen
  und `http://127.0.0.1/` → 308 vom Host.
- **Offen nach dieser Runde:** TLS/ACME (extern, später: Weiterleitung 80/443
  am Zielnetz durch den Netzwerkadmin), Restore-Probe/RTO, Offsite-Backup,
  Entscheidungen D-* (siehe unten); SSH-Härtung: Entscheidung „nur
  Minimalvariante gegen fehlgeschlagene Logins" (läuft bereits), volles
  `ssh-harden.sh` vorerst ohne Einsatz.

---

## 2026-09-28 – VM-Testlauf auf dem Test-Host (Teil der Testmatrix) + Boot-Gate-Fix

**Umfang:** erster Teil der bisher „nicht ausgeführten" VM-Matrix auf
`2.29.11.30` (Debian 13, frischer Stand nach den vier Fixes oben); ein
weiterer Defekt gefunden und behoben.

- **Defekt 5 – Boot-Gate meldete jedes Mal fälschlich ROT.** Nach echtem
  Reboot schrieb `/var/log/coder-boot.log`
  „ROT: Postgres nicht healthy nach Boot", obwohl der Stack gesund war:
  boot-check.sh liest den Health-Status ohne Wartezeit, direkt nach
  @reboot ist er `starting` (gemessen: T+0 s `starting`, T+4 s `healthy`,
  erster Probe nach `interval: 5s`). Fix: gebundene Warteschleife (24 ×
  5 s = max 120 s), danach erst echtes ROT; bei healthy zusätzlich eine
  OK-Zeile. Zweiter Reboot danach: **„OK: Postgres healthy nach Boot"**
  (Abschnitt 17:48:03).
- **Geändert:** `setup-coder.sh` (Herodoc von `boot-check.sh`);
  **neu:** `tests/t-b2-010-boot-gate-health.sh` (13 Checks: Extraktion,
  Statik, Fall „starting → healthy" → GRÜN/Exit 0, Fall „dauerhaft
  starting" → ROT/Exit 1, Fake-`docker` mit Health-Sequenz).
- **Tatsächlich ausgeführt am 2026-09-28 (Host + lokal):**
  - Lokal: `bash -n` 0 Befunde, `shellcheck -S warning` unverändert (1×
    SC2034), **9 Testskripte Exit 0, 266 PASS, 0 FAIL** (6/16/64/61/16/37/
    28/25/13).
  - Server: Lauf 7 → Exit 0, 0 FEHLER, Boot-Gate neu erzeugt, keine Drift.
  - Geprüfte Matrix-Teile (jeweils ausgeführt): T-065 Rechte
    (`.env` 600, `backups` 700, Dumps 600, Cron 644, Skripte 755,
    `nobody` darf `.env` nicht lesen); T-066 kein Klartext-Passwort in
    Backup-Log/Journal (Coder-Container-Env enthält die URL wie dokumentiert);
    T-067 Log-Limits bei allen 6 Containern `10m × 3`; T-068 node-exporter
    `pid: host` **ohne** `--collector.processes` (K3 bleibt offen); T-069
    kein NOPASSWD für Wartungsskripte, kein Auto-Reset/-Update-Cron;
    T-062/T-060 ufw active, 22/tcp LIMIT + 80/443/443-udp v4+v6,
    Default deny; öffentlich nur 80/443/SSH, Prometheus/Grafana/
    node-exporter loopback; T-070 Backups `gzip -t` OK (4 Dateien, je
    ~73,9 kB, 600); T-075 Retention stückzahlbasiert `KEEP=14`; T-076
    Cron aktiv, 01:00; T-077 logrotate weekly/8; T-090 `update.sh`:
    Pre-Backup + Pull + `up -d` grün, **Gate rot mit Exit 1**
    (Caddy-TLS-Smoke 000, weil hier kein Zertifikat möglich) – fail-closed
    statt stilles Grün; T-106 Pipe ohne `--force` → Exit 1, nichts
    gelöscht (5 Volumes, `.env`, 6 Container da); T-100 Backup-Fehlschlag
    (Postgres gestoppt) → „Abbruch, ohne etwas zu löschen", Exit 1,
    danach Postgres wieder healthy; T-110 Reboot → alle 6 Container,
    ufw/cron/fail2ban/docker aktiv, `/healthz` intern OK, Boot-Log als
    Zeuge geschrieben (jetzt mit OK-Zeile für Postgres).
- **Offen/nicht ausgeführt:** T-063 Workspace-Selbsttest und
  Template-Inventar (braucht User/Template in Coder), Restore-Probe mit
  echter VM (T-080–T-083), vollständiger Reset-Pfad T-105,
  DNS/ACME/Wildcard von außen (T-120–T-126) – auf diesem Host mangels
  eigener Domain grundsätzlich nicht möglich; `healthz`-ROTs in den
  Gates bleiben daher hier erwartbar. K3 (`pid: host`) unverändert offen.

---


## 2026-09-28 – Erstlauf auf frischer Debian-13-VM: vier Defekte, behoben

**Umfang:** erster echter Skriptlauf auf einem frisch neu aufgesetzten
Debian 13 (trixie), Host `2.29.11.30` (vorher Ubuntu 26.04 mit fremder
Coder-Installation, auf Wunsch komplett neu aufgesetzt). Vier Funde, jeder
behoben und nachgetestet. Kein Feature, keine Architektur-, keine
Planänderung.

1. **`CODER_VERSION` ohne `v` – Stack startet gar nicht (Starter-Blocker).**
   Lauf 1 brach in Schritt 3 ab: `ghcr.io/coder/coder:2.36.6` →
   `not found`. Gegen die Registry geprüft: Manifest `2.36.6` → HTTP 404,
   `v2.36.6` → HTTP 200, `docker pull ghcr.io/coder/coder:v2.36.6` ok
   (Digest `sha256:a7daad452864428ce1e93d37706b780f248b06ccb2f8e2fcb2ffd9a11f10ebd4`),
   Docker Hub `coder/coder` kennt keinen der beiden Tags. Die Release-Notes
   zu v2.36.6 nennen selbst `… coder:2.36.6` ohne `v` – dieser dortige Satz
   ist falsch und stand wörtlich als Kommentar im Skript. Kein Test deckt das
   ab: `tests/` prüft Quelltext, kein Registry-Zugriff.
2. **Zweiter Lauf scheitert in Schritt 1 (Idempotenz).** Existiert
   `/etc/apt/keyrings/docker.gpg` bereits, fragt `gpg --dearmor -o` nach dem
   Überschreiben per `/dev/tty`; ohne TTY (`ssh` ohne `-t`, `nohup`) →
   `cannot open '/dev/tty'`, exit 2 → `set -euo pipefail` beendet den Lauf.
   Kontrolliert nachgestellt: ohne Flag exit 2, mit `--batch --yes` exit 0.
   Mit TTY bliebe der sonst promptfreie Normalpfad an genau dieser einen
   Frage hängen.
3. **B2-008 warnt bei jedem Re-Run über den eigenen Caddy (False Positive).**
   `docker inspect --format '{{.HostConfig.PortBindings}}'` rendert auf
   Docker 29.8.1/Go die leere HostIp als `{invalid IP 80}`, nicht als
   `{ 80}` wie der Kommentar annimmt; die awk-Auswertung las daraus
   `ip=invalid`, `port=IP`, fand nie einen Treffer und meldete 80/tcp,
   443/tcp, 443/udp (je v4+v6) als „fremden Listener … vor 'up -d'
   aufräumen" – genau die Warnung, die B2-008 abstellen sollte. 9090/9100/
   3001 matchten weiter (dort ist HostIp `127.0.0.1` gesetzt).
4. **Runbook wurde nie abgelegt (B-008).** `SCRIPT_SRC_DIR` wurde in Schritt 6
   relativ aus `dirname $0` berechnet, nachdem Schritt 2 `cd /opt/coder`
   gemacht hat → gesucht wurde `/opt/coder/RESTORE.md`, die Datei lag aber
   neben dem Skript. Der Warn trat bei jedem Lauf auf, die Kopie nie.

**Geändert:** `setup-coder.sh` – `CODER_VERSION` `2.36.6` → `v2.36.6`
(Kommentarblock Z.48–57 auf Registry-Ergebnis korrigiert), `gpg` mit
`--batch --yes`, awk-Zweig für `{invalid IP <port>}`, `SCRIPT_SRC_DIR` vor
dem ersten `cd` ermittelt; `README.md` – zwei Tabellenzeilen
(`ghcr.io/coder/coder:v2.36.6`, Tag „mit `v`"); `tests/t-b2-008-
port-preflight.sh` – Fixture (1) auf das reale Docker-29.8.1-Format
umgestellt, Szenario (1b) für das Legacy-Format `{ 80}` ergänzt.

**Tatsächlich ausgeführt am 2026-09-28:**
- Lokal: `bash -n setup-coder.sh` und alle 8 Testskripte → 0 Befunde;
  `shellcheck -S warning setup-coder.sh` → 1 Befund (SC2034, ungenutzter
  Zähler `i`,   Z.1264, unverändert); alle 8 `tests/*.sh` → 8× Exit 0,
  **253 PASS, 0 FAIL** (6/16/64/61/16/37/28/25).
- Server `2.29.11.30`: sechs Läufe. Lauf 1 Abbruch Schritt 3 (Blocker 1),
  Lauf 2 Abbruch Schritt 1 (Blocker 2), Läufe 3–6 Exit 0. Lauf 6 nach allen
  vier Fixes: Exit 0, 0 `[FEHLER]`, 0 Port-WARN, Runbook
  `[OK] Runbook nach /opt/coder/RESTORE.md abgelegt`, keine Drift-Warnung;
  verbleibend nur zwei erwartete WARNungen (ACME/healthz, SSH-Passwort).
- Nachweisen: 6 Container laufen (`ghcr.io/coder/coder:v2.36.6`,
  postgres `healthy`), `docker exec coder-caddy wget http://coder:3000/healthz`
  → `OK`, `gzip -t` des Test-Backups grün (73 931 Byte, Recht 600),
  `ufw status` → active mit `22/tcp LIMIT`, fail2ban-Jail `sshd` aktiv,
  Cron-Dateien `coder-backup`/`coder-bootcheck`/`coder-tlscheck` vorhanden.

**Offen:** ACME/Lets-Encrypt läuft auf diesem Test-Host ins Leere
(`coder.ghse-unterricht.de` zeigt auf einen anderen Server) → erwartete
WARNUNG in Schritt 10, kein Defekt; TLS-/DNS-Weg weiter nur auf echter
Zielumgebung prüfbar (siehe README „Nur auf einer Test-VM bzw. in
Produktion zu verifizieren"). SSH-Passwort-Login bleibt bis D-SSH aktiv.

---

## 2026-09-28 – Release-QA (Doku-Fix, kein Code)

**Umfang:** vollständige QA-Runde über den Branch-Stand; **keine** Änderung
an `setup-coder.sh`, `ssh-harden.sh`, `tests/`, `ai-review/PLAN-v3*.md`.

- **Geändert:** `ai-review/TEST_PLAN.md` – datierte Ergänzung, die die vom
  Plan (Phase B, PV-015) zugesagte Delta-Verlinkung liefert: TEST_PLAN
  bleibt die VM-Matrix, `tests/` ist der lokal ausführbare
  B2-Delta-Harness, PLAN-v3 Phase B ist die B2-Spezifikation; dazu die
  beiden gegenüber 2026-09-26 abweichenden, bereits dokumentierten
  T-002-Befunde (SC2034 in `setup-coder.sh` Z.1247; SC2034/SC2154 in den
  extrahierten Heredocs).
  Ursache: das in PLAN-v3 angekündigte „Delta nachziehen" wurde nie
  geschrieben, `TEST_PLAN` enthielt keinen Verweis auf `tests/`.
- **Tatsächlich ausgeführt am 2026-09-28:** `git status`/`git diff` sauber
  (Arbeitsverzeichnis unverändert, keine unverfolgten Dateien);
  `bash -n` über `setup-coder.sh`, `ssh-harden.sh` und alle 8 Testskripte →
  0 Befunde; `shellcheck -S warning -s bash` Hauptdatei → genau 1 Befund
  (SC2034 Z.1247), `ssh-harden.sh` und `tests/*.sh` → 0 Befunde,
  extrahierte Shell-Heredocs (4) → SC2034 `update.sh` + SC2154
  `reset-passwords.sh` (beide dokumentiert); alle 8 Testskripte → 8× Exit 0,
  251 `PASS`, 0 `FAIL` (je Datei: 6/16/64/61/16/37/26/25); Link-Check über
  36 Markdown-Dateien → 0 tote Verweise; aus dem `docker-compose.yml`-
  Heredoc extrahierte Datei (Platzhalter substituiert) →
  `docker compose config --quiet` Exit 0; Token-/Key-/Private-Key-Muster-
  Scan über alle verfolgten Dateien → kein Treffer; Dateirechte
  (`tests/*` und `ssh-harden.sh` 755, `setup-coder.sh` 644 mit `chmod +x`
  im README-Schnellstart) und kein Testrückstand im Arbeitsverzeichnis
  geprüft.
- **Nicht geprüft (keine Umgebung dafür):** alles unter VM-/Produktions-
  Pflicht – siehe `README.md`, Abschnitt „Nur auf einer Test-VM bzw. in
  Produktion zu verifizieren"; das Phase-C-VM-Gate und der RTO-Wert
  bleiben offen.

---

## 2026-09-28 – Dokumentationsabschluss

**Umfang:** Dokumentation auf den tatsächlich implementierten Stand gebracht.
Keine Implementierungsänderung.

- **Neu:** `README.md` (Einstieg + Doku-Landkarte, Voraussetzungen,
  Schneller Einstieg, Konfiguration, Sicherheits-/Backup-/Test-Überblick,
  Liste der nur auf VM/Produktion zu prüfenden Schritte),
  `OPERATIONS.md` (generierte Dateien, Start/Stop, Checks, Logs, Wartung,
  Backup-Steckbrief, automatische Aufgaben, Teststand),
  `SECURITY.md` (SSH, Secrets, TLS/SNI, Firewall, Docker-Netz/Listener,
  bekannte Grenzen mit offenem Entscheidungsstand),
  `TROUBLESHOOTING.md` (Fehlerbilder mit Diagnosebefehlen, erwarteter
  Ursache und sicherer Behebung, inkl. „niemals so beheben"-Tabelle).
- **Geändert:** `RESTORE.md` – Abschnitt zu negativen/fehlerhaften
  Restore-Fällen und Verweise auf die neuen Doku-Dateien ergänzt;
  der geprüfte Wortlaut von Pfad A/Schritt 4–5 (Import mit
  `-v ON_ERROR_STOP=1`, Datenprobe = 1) blieb unverändert.
- **Unverändert (Pflicht):** `ai-review/PLAN-v3.md`,
  `ai-review/PLAN-v3-REVIEW.md`, `ai-review/PLAN-v3-FINAL-CHECK.md`,
  `setup-coder.sh`, `ssh-harden.sh`, `templates/allowlist.md`, `tests/`.
- **Tatsächlich ausgeführt am 2026-09-28:**
  `bash -n setup-coder.sh ssh-harden.sh` → 0 Befunde;
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` → genau 1 Befund
  (SC2034, ungenutzter Zähler `i`, setup-coder.sh Zeile 1247),
  `ssh-harden.sh` ohne Befund;
  alle 8 Skripte in `tests/` mit Exit 0 (251 `PASS`, 0 `FAIL`);
  Verlinkungsroutine über alle Markdown-Dateien geprüft.

---

## 2026-09-27/28 – Umsetzungsrunde v3 (B2-Fixes)

**Basis:** `ai-review/PLAN-v3.md` (+ `PLAN-v3-REVIEW.md`,
`PLAN-v3-FINAL-CHECK.md`), Funde aus `ai-review/FINAL-BREAKER-v2.md`.
Jede Umsetzung hat einen Implementierungsbericht unter
`ai-review/IMPLEMENTATION-REPORT-v3-B2-*.md` und, soweit lokal prüfbar,
einen Test in `tests/`.

| Datum | Commit | Umfang | Test (tatsächlich ausgeführt) |
|---|---|---|---|
| 2026-09-27 | `44c6610` | B2-001: Backup-Headercheck ohne SIGPIPE-Fehlurteil (`set -o pipefail` + große Dumps) | `tests/t-071b-headercheck.sh`, 6 PASS |
| 2026-09-27 | `1b040e7` | B2-002: TLS-SNI-korrekte Gate-Probe (`--resolve`), Update-Gate und Boot-Gate | `tests/t-090-b2-002-tls-gate.sh`, 16 PASS |
| 2026-09-28 | `2eaf95a` | B2-003: `.env`-Gates – Newline/NUL hart abweisen, Hex-only, Legacy-Migration ohne Verweis-Pingpong | `tests/t-b2-003-hex-migration.sh`, 64 PASS |
| 2026-09-28 | `13f8a99` | B2-004: Re-Run-Downgrade nur explizit (`CODER_ALLOW_SSH_DOWNGRADE=yes`), Before/After-Protokoll + Wiederherstellungs-Verifikation | `tests/t-b2-004-ufw-downgrade.sh`, 61 PASS |
| 2026-09-28 | `7373bd2` | B2-006: Volume-Belegungs-Check in `reset-coder.sh` **vor** `docker compose down` | `tests/t-b2-006-reset-precheck.sh`, 16 PASS |
| 2026-09-28 | `25e7ee9` | B2-007: `remember_hash` an jeder Schreibstelle (15 Dateien) statt in Schritt 10 | `tests/t-b2-007-drift-hash.sh`, 37 PASS |
| 2026-09-28 | `b29c2a4` | B2-008: Port-Preflight unterscheidet eigene und fremde Listener (TCP + UDP) | `tests/t-b2-008-port-preflight.sh`, 26 PASS |
| 2026-09-28 | `d6e5bc6` | B2-009: `RESTORE.md` Pfad A mit `-v ON_ERROR_STOP=1`, Datenprobe statt Liveness-only | `tests/t-b2-009-restore-on-error-stop.sh`, 25 PASS |
| 2026-09-28 | `f7ba55d` | nur Berichtskorrektur: Testzahl B2-007 von 45 auf 37 PASS richtiggestellt (Testdatei unverändert) | – |

**In dieser Runde nicht umgesetzt (offen, im Repository so dokumentiert):**

- **B2-005** – `check-tls.sh` zählt `docker logs --since 168h`, die
  Container-Logs sind aber auf 10 MB × 3 Dateien gedeckelt: bei hohem
  Logvolumen geht die Zählung unter. Kein Fix, kein eigener Bericht,
  Quellstand unverändert.
- VM-/Integrationstests aus der Testmatrix (u. a. Restore-Probe T-080,
  Reboot-Gates auf echtem Host, echte ufw-/fail2ban-Läufe) – siehe
  [README.md](README.md), Abschnitt „Nur auf einer Test-VM bzw. in
  Produktion zu verifizieren".

---

## 2026-09-27 – Planungs- und Reviewdokumente v3

Nur Dokumente in `ai-review/` (kein Code): `FINAL-BREAKER-v2.md`,
`POST-IMPLEMENTATION-PLAN.md`, `PLAN-v3.md`, `PLAN-v3-REVIEW.md`,
`PLAN-v3-FINAL-CHECK.md`, `07-complexity.md`, `08-documentation.md`.

Markierung im Verlauf: Tag **`v2-pre-implementation-v3`** (= `9f97a09`)
steht für den Stand direkt vor der v3-Umsetzung.

---

## 2026-09-27 – Korrekturrunde v2

**Basis:** `ai-review/POST-IMPLEMENTATION-PLAN.md` (nur MUST_FIX und
SHOULD_FIX), Bericht `ai-review/IMPLEMENTATION-REPORT-v2.md`.
Geändert: `setup-coder.sh`, `ssh-harden.sh`.

Umgesetzt: B-001 (Cron-`flock`-Deadlock), B-002 (Coder-Image-Tag ohne
`v`-Präfix), B-003 (kein Auto-Prune nach Update), B-005-Erkennung
(`check-tls.sh` + wöchentlicher Cron), B-006 (`ssh-harden.sh` Post-Check
und Key-Regex), B-007 (ufw-Default-Policy + Re-Run-Warnung statt stillen
Löschens), B-008-Code (eine Restore-Variante, `RESTORE.md` wird auf den
Server kopiert), B-009-Gate (`/healthz`-TLS-Smoke im Update-Gate), B-010
(SQL-Header-Check, Vorwert-Warnung, Skip-Alter), B-011 (Boot-Gate,
`stop_grace_period` für Postgres), B-015-Kommentar (500-MB-Bodenwert als
unvermessen markiert), B-012 (Drift-Hashes), B-013 (`retry3` +
Preflights), B-014 (Hex-Validierung), B-016 (Orphan-Sweep, Reset-Pre-Check),
B-019 (Wildcard-Probe getrennt), B-020 (Break-Glass-Doku für `--force`).

Bewusst **nicht** umgesetzt (laut Bericht, Blocker/Entscheidung):
Offsite-Backup, Socket-Trennung, App-/DB-Split, Mini-Restore-Automatisierung,
In-Container-Healthcheck, fail2ban-`jail.d`-Include, `retention.size`,
`CODER_DISABLE_PATH_APPS`, Workspace-RPO, Handshake-Nachweis – plus alle
OPTIONAL-Funde (u. a. SC2034/SC2012-Kosmetik).

---

## 2026-09-26 – Erste Umsetzungsrunde v1

**Basis:** `ai-review/PLAN.md` + `ai-review/PLAN-REVIEW.md` (F-001–F-012,
P-001–P-025), Bericht `ai-review/IMPLEMENTATION-REPORT.md`.

- `setup-coder.sh`: +463/−60 – u. a. Crontab-Migration (`|| true`),
  atomare `.env`-Erzeugung (600 ohne 644-Fenster), GID-Guard,
  Backup-Pfad (Temp-Datei, `gzip -t`, Mindestplatz, Rotation),
  projektgebundene Volume-Filter, Bestätigungen vor dem Reset,
  Health-Gate, Drift-/Retry-Grundlagen.
- **Neu im Repository:** `RESTORE.md`, `ssh-harden.sh`,
  `templates/allowlist.md`, `ai-review/IMPLEMENTATION-REPORT.md`.
- Bewusst offen gelassen u. a.: Offsite-Hook (F-002),
  `CODER_DISABLE_PATH_APPS`, echter TLS-`ask`/DNS-01, DOCKER-USER-Kette,
  `retention.size`, `mem_limit`, App-/DB-Split.

---

## 2026-09-26 – Ausgangsstand

- Erster Commit `944ee14`: `setup-coder.sh`, `.gitignore`, `AGENTS.md`,
  `copilot-instructions.md` und die leeren Review-Skelette in `ai-review/`
  (`01-bash.md` … `06-architecture.md`, `PLAN.md`, `PLAN-REVIEW.md`,
  `TEST_PLAN.md`).
- `main` und Tag **`baseline`** stehen auf `d505b1f` und enthalten das
  Ausgangs-`setup-coder.sh` sowie die ersten Review-Dokumente
  (`01-bash.md` … `06-architecture.md`, `PLAN.md`, `PLAN-REVIEW.md`,
  `TEST_PLAN.md`), aber **kein** `ssh-harden.sh`, **kein** `RESTORE.md`,
  **keine** `tests/`, **kein** `templates/`.
- Ab hier liefen die Umsetzungsrunden ausschließlich auf den Branches
  `ai/implementation-v1`, `ai/implementation-v2`, `ai/implementation-v3`.

---

## Offene Punkte (Stand 2026-09-29, ohne Frist/Eigentümer)

| Punkt | Status |
|---|---|
| TLS/ACME auf dem Test-Host | **blockiert extern**: nginx am öffentlichen IP beantwortet 80/443, Caddy erhält kein Zertifikat, `healthz` seit Lauf 3 ohne 200. Zielbetrieb = Schulserver (SSH nur aus Schulnetz/VPN), Weiterleitung 80/443 offen beim Netzwerkadmin; Test-Host `2.29.11.30` wird irgendwann abgeschaltet |
| C2 Log-Limit wirksam | erledigt 2026-09-29: `daemon.json` geschrieben, Docker nach Rücksprache neu gestartet – `docker inspect` zeigt bei allen Containern `json-file` + `max-size=10m`/`max-file=3` |
| B2-005 (TLS-Zählung blind gegenüber Log-Rotation) | offen, nicht umgesetzt |
| Restore-Probe + RTO-Zahl | offen, `RESTORE.md`-Tabelle `_offen_` |
| Offsite-Backup | nicht eingerichtet |
| SSH-Härtung (`ssh-harden.sh`) | Entscheidung 2026-09-29: nur **Minimalvariante** gegen fehlgeschlagene Logins (ufw `limit` + fail2ban, Root-Passwort-Login gesperrt) – beides läuft. Zielserver aktuell **nur per Passwort** zugänglich (kein Key), Test-Host nur per Key: erst Key setzen und aus zweitem Fenster testen, dann erst Härtung |
| Template-Erstinventar + Workspace-Selbsttest (T-063) | `_offen_` in [templates/allowlist.md](templates/allowlist.md) |
| VM-/Integrationstests der Testmatrix | nicht ausgeführt |
| Entscheidungen D-TLS, D-Socket, D-SSH, D-Firewall, D-Reboot-Fenster, D-Monitoring, D-Offsite | offen |
