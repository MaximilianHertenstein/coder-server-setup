# IMPLEMENTATION-REPORT-v2 – Correction Pass (MUST_FIX / SHOULD_FIX)

Stand: 2026-09-27. Branch: `ai/implementation-v2` (Basis-Head `570db50` + Vorgänger-Commits).
Geltungsbereich: ausschließlich Findings aus `ai-review/POST-IMPLEMENTATION-PLAN.md`
mit Priority MUST_FIX oder SHOULD_FIX. OPTIONAL wurde nicht implementiert,
DECISION_REQUIRED wurde nicht eigenständig entschieden.
Kein Produktivserver-Befehl, keine Secrets, `main` unverändert.

Arbeitsweise pro Finding: Befund gelesen → Korrekturvorschlag gelesen →
aktuellen Code geprüft → kleinstmögliche sichere Änderung → `bash -n` →
ShellCheck (0.11.0) → relevante Konfiguration geprüft → Git-Diff geprüft.

## Implemented

### MUST_FIX

- **B-001 (Cron-Deadlock):** Äußeres `flock -n` aus `/etc/cron.d/coder-backup`
  entfernt. Einzige Sperre ist der innere Selbst-Lock in `backup.sh`
  (schützt Cron-, `update.sh`-Pre-Backup- und manuelle Läufe gemeinsam).
  Kommentare an beiden Stellen korrigiert (keine „Doppelabsicherung" mehr).
  Innerer Lock, Exit-0-Skip-Semantik, Sekunden-Timestamp, Cron-Zeit 01:00
  und Logrotate unverändert.
- **B-002 (Coder-Tag):** Default `v2.36.6` → `2.36.6`, Kopfkommentar korrigiert
  (Git-Tag ≠ Image-Tag, offizieller Pull-Befehl `ghcr.io/coder/coder:2.36.6`
  maßgeblich). Pin-Prinzip und alle anderen Versionen unverändert.
  Beidseitige `docker pull`-Probe auf Test-VM steht aus (Blocker, kein Netz
  gegen Registry von hier belegt) – Code-Seite implementiert.
- **B-003 (Prune):** `docker image prune -f --filter "until=24h"` aus
  `update.sh` entfernt, Kommentar ersetzt (kein Auto-Prune nach Update;
  manuelles Aufräumen bewusst). Kein Image-ID-Mechanismus (per Plan verworfen).
  `pull`→`up -d`-Reihenfolge unverändert.
- **B-005-Erkennung (On-Demand-TLS):** Kopfkommentar ehrlich korrigiert
  (Apex ebenfalls on-demand; Budget gehört `ghse-unterricht.de`, geteilt;
  `ask` antwortet immer 200). Erkennung neu: `/opt/coder/check-tls.sh`
  (zählt `obtaining certificate` im Caddy-Log der letzten 7 Tage, lesend,
  Exit 0, `logger`) + wöchentlicher Cron (Mo 06:30). Mechanik unverändert,
  kein `ask`-Schnellschuss, kein DNS-01-Umbau (D-TLS-Entscheidung offen).
- **B-006 (ssh-harden.sh):** Post-Check nach `reload` (alle drei Werte müssen
  effektiv `no` sein, sonst Exit 1 + Rollback-Hinweis); Key-Regex um
  `sk-ssh-ed25519@`, `sk-ecdsa-sha2-…`, `-cert-v01@` ergänzt (6/6 Key-Typen
  lokal verifiziert); Provisoriums-Alter mit Datum in Setup-Schlusswarnung.
  Kein Key-only-Enforcement im Setup, kein automatischer Härtungsaufruf,
  `limit 22/tcp` + fail2ban unverändert.
- **B-007 (UFW):** `ufw default deny incoming` / `allow outgoing` idempotent
  gesetzt; Re-Run warnt bei restriktiverer vorgefundener SSH-Regel in SUMMARY
  statt sie still zu löschen (Regeneration bleibt deterministisch, Idempotenz
  erhalten); Bindungsregel dokumentiert (`ports:` nur `127.0.0.1`, Ausnahme
  nur Caddy) + Review-Check; IPv6-Pfad deklariert (`IPV6=yes` → gleiche Policy
  v4+v6, sonst WARN). `limit 22/tcp` und 80/443-Regeln unverändert, kein
  DOCKER-USER-Einbau (D-Firewall-Entscheidung offen).
- **B-008-Code (Restore):** Pfad A in `RESTORE.md` auf
  `dropdb --if-exists` / `createdb` (+ `psql`-Import) festgelegt, eine
  Variante statt „Fehlerprotokoll lesen"; Setup legt `RESTORE.md` nach
  `/opt/coder/RESTORE.md` ab (Verweise aus `update.sh`/`reset-coder.sh`
  lösen auf dem Server auf; fehlt die Datei neben dem Setup → WARN, kein Fail).
  Offsite-Entscheidung (D6) offen – siehe Blocker.
- **B-009-Gate (Update):** Gate um `/healthz`-200-via-Caddy (TLS-Smoke,
  Host-Header gegen 127.0.0.1, kein DNS nötig, `--max-time 60` deckt
  On-Demand-Erstverzögerung 5–30 s ab; nicht parsbares Caddyfile → Warnung,
  kein Fail); Prune-Entfernung siehe B-003; Pre-Backup-Skip meldet Backup-Alter
  (B-010-Kopplung); sudo-Konvention dokumentiert (Skripte laufen als root mit
  plainem `docker`, Setup als Nicht-root mit `sudo docker` – kein
  funktionaler Unterschied). Manueller Update-Betrieb unverändert.
- **B-010 (Backup-Aussagekraft):** SQL-Header-Check als Fail-Kriterium
  (leeres stdin / pg_dump-Fehlertext → keine Finaldatei, ohne hartes
  Größenlimit – frische/verkleinerte DB bleibt grün); Vorwert-Vergleich als
  Warnung (aktuell < Hälfte des Vorgängers, kein Fail); Skip meldet Alter des
  letzten gültigen Backups (für `update.sh` unterscheidbar); `gzip -t` bleibt.
- **B-011 (Boot):** Lesendes Boot-Gate `/opt/coder/boot-check.sh` (Container
  Running + Postgres healthy + `/healthz` innert 5 Min, Ergebnis nach
  `/var/log/coder-boot.log` + `logger`, kein Eingriff; Auswertung laufbezogen,
  nicht kumulativ) + `@reboot`-Cron; `stop_grace_period: 30s` nur für
  Postgres; Reboot-Kommentar mit Betriebsfenster-Vorbehalt (D-Reboot-Fenster).
  Reboot-Automatik selbst unverändert.
- **B-015-Kommentar (Platte):** 500-MB-Bodenwert als „konservativ, aber
  UNVERMESSEN" markiert. Kein geratener `retention.size`-Wert (per Plan
  verboten ohne Messung); Compose bleibt bei `retention.time=15d`.

### SHOULD_FIX

- **B-012 (Drift):** `note_drift`/`remember_hash` mit Store
  `/opt/coder/.generated-hashes` (root, 600); Warnung vor dem Schreiben für
  alle 15 generierten Dateien (Compose, Caddyfile, prometheus.yml, jail.local,
  52-coder-reboot, alle Skripte, alle Cron-Dateien, logrotate); Regeneration
  bleibt deterministisch, kein interaktiver Stopp.
- **B-013 (Robustheit):** `retry3`-Helper (max. 3, 10 s Schlaf, Ursachen-Log);
  alle `apt-get update/install` und GPG-`curl --retry 3` darüber;
  Preflight-Block vor Schritt 3 (Docker-Daemon hart, Ports 80/443/9090/9100/
  3001 als WARN mit Prozess-Hinweis, Platte WARN ab 1 GB grob);
  `compose pull`-Retry (max. 3) in `update.sh`. Keine Retries um LE.
- **B-014 (Passwörter):** Hex-Validierung fail-closed für beide
  Passwort-Schlüssel im Setup-Re-Run und in `reset-passwords.sh` (Abweisung
  mit Reparaturweg `reset-passwords.sh` statt stiller Korruption durch
  Sonderzeichen/Quotes); Trap-Texte pro Fenster getrennt (PG vs. Grafana vs.
  `.env` vs. Vorbereitung). DB-zuerst-Reihenfolge unverändert (P-018-Beweis
  offen).
- **B-016 (Robustheit klein):** `|| true` an allen reinen Signal-`logger`s in
  `backup.sh` vereinheitlicht; Orphan-Sweep (eigenes Muster
  `coder_*.sql.gz.tmp.*`, älter als 24 h) beim Backup-Start; Reset-Pre-Check:
  `docker ps --filter volume=` pro zu löschendem Volume, Abbruch VOR dem
  ersten `rm` (fail-closed wie Leer-Guard). `trap EXIT`-Struktur unverändert.
- **B-019 (Wildcard-Check):** Apex- und Wildcard-Probe getrennt; zufällige
  Subdomain per `getent` (nur Resolve, kein TLS, kein LE-Budget), immer WARN
  nie Fail. Limit dokumentiert: lokaler Resolver statt autoritativem Server
  (kein `dig` garantiert); App-Smoke (T-124) braucht Test-VM.
- **B-020 (Reset):** Break-Glass-Doku für `--force` (wer/womit/Nachweis);
  Aufräum-Hinweis vor `down` gezogen (Namen notieren), Schlussblock auf
  Neuaufbau + Einzeiler verdichtet; Zwei-Stufen-Bestätigung, Leer-Guard und
  Zertifikats-/Backup-Schutz unverändert.

## Not Implemented

- **B-004-Code (Socket):** Kein Code-Eingriff (per Plan verboten ohne
  Architektur-Beschluss). Allowlist + Abnahme-Tabelle existieren; Erstinventar,
  T-063-Selbsttest-Protokoll und D-Socket-Entscheidung (Eigentümer + Frist)
  brauchen echten Stack + Test-VM → Blocker.
- **B-008-Offsite (D6):** Transport-Entscheidung (Ziel, Verschlüsselung,
  Schlüsselverwahrung getrennt vom Host, Retention, Secrets, Frist) nicht vom
  Implementierer zu setzen → Blocker. RTO-Zahl und T-080/T-082-Proben brauchen
  Test-VM.
- **B-009-Split (`app` vs. `db`):** Bewusst zurückgestellt – ändert den
  Bedienvertrag (K5/D-Update-Split-Entscheidung nötig). Gate (MUST) ist drin;
  Split als dokumentierte Folgeänderung.
- **B-010-Mini-Restore-Automatisierung:** Wöchentlicher Wegwerf-Postgres braucht
  Test-VM-Entwurf + Verifikation (nicht blind in Produktionsskript raten).
  Kern (Leer=Fail, Vorwert-Warnung, Skip-Alter) ist implementiert.
- **B-011-Coder-Healthcheck in-container + Caddy `service_healthy`:**
  Zurückgestellt – Healthcheck-Befehl braucht verifiziertes Tool im
  Coder-Image (weder `curl` noch `wget` belegbar); ungeprüfter Healthcheck
  würde Caddy bei `depends_on: service_healthy` dauerhaft blockieren
  (Totalausfall-Risiko). Boot-Gate (hostseitig, lesend) + Grace sind drin;
  In-Container-Check nur nach Test-VM-Verifikation.
- **B-012-jail.local-Include:** Zurückgestellt – Migration von Vollüberschreibung
  auf `jail.d`-Include ändert fail2ban-Merge-Verhalten (sicherheitskritisch)
  und braucht Test-VM-Beweis identischer effektiver Config. Drift-Warnung ist
  drin.
- **B-014-P-018-Reihenfolge:** Nur per Test-VM-Beweis entscheidbar → Blocker.
- **B-015-Messung (`retention.size`, `check.sh`, Leser):** D-Monitoring-
  Entscheidung nach Messung (Plattenkapazität, `docker stats`-Woche) → Blocker.
- **B-017-Flag (`CODER_DISABLE_PATH_APPS=true`):** Bewusst NICHT gesetzt –
  per Plan verboten ohne Template-Inventar (legitime Pfad-Apps brächen).
  Gated auf B-004-Inventar → Blocker.
- **B-018 (Workspace-RPO):** Reine Entscheidung + Kommunikation
  (D-Workspace-RPO) → Blocker, kein Code.
- **B-021-Nachweis:** Handshake-Serie mit gepinntem Image auf Testdomain
  (LE-Budget, nie Produktion) → Blocker, kein Code.
- **PLAN-Reparatur (Blocking 0), D-PLAN, D-SSH, D-TLS, D-Firewall, D-Reboot-
  Fenster, D-Caddy-Pin:** Entscheidungen mit Eigentümer/Datum, nicht vom
  Implementierer zu setzen → Blocker.
- **OPTIONAL (alle):** Nicht angefasst per Auftrag (`pid: host`, Caddy-Exakt-Pin,
  SC2034/SC2012-Kosmetik, `mem_limit`, Digest-Umstellung).

## Tests

Alle folgenden Tests wurden tatsächlich ausgeführt (lokal, lesend, keine
Produktivserver-Befehle). VM-/Integrationstests (T-010, T-026, T-030–T-033,
T-050, T-053, T-060–T-064, T-067, T-070–T-077, T-079–T-083, T-090–T-093,
T-100–T-106, T-110–T-113, T-120, T-123–T-126, Handshake-Serien) sind
**nicht** ausgeführt – sie brauchen eine isolierte Test-VM (Blocker).

1. `bash -n setup-coder.sh` → Exit 0 (`SETUP_OK`). Beleg: Syntax des
   Gesamtskripts inkl. aller neuen Blöcke gültig.
2. `bash -n ssh-harden.sh` → Exit 0 (`HARDEN_OK`).
3. `bash -n` aller 6 extrahierten Heredoc-Skripte
   (`backup.sh`, `update.sh`, `reset-passwords.sh`, `reset-coder.sh`,
   `boot-check.sh`, `check-tls.sh`) → je Exit 0. Beleg: eingebettete Skripte
   sind eigenständig gültig (äußeres `bash -n` prüft Heredocs nicht).
4. `shellcheck -S warning setup-coder.sh ssh-harden.sh` → einziger Befund
   SC2034 (`for i` ungenutzter Zähler, vorbestehendes Muster, per Plan
   OPTIONAL/ausgeschlossen). `ssh-harden.sh` ohne Befund. Heredocs:
   `backup`/`reset-coder`/`boot-check`/`check-tls` ohne Befund;
   `update` nur SC2034 (vorbestehend), `reset-passwords` nur SC2154
   (`rc` im Single-Quote-Trap, False Positive, vorbestehendes Muster).
5. `docker compose -f <extrahiert> config --quiet` (mit Dummy-Variablen) →
   `COMPOSE_CONFIG_OK` (nur erwartete „variable is not set"-Warnungen für
   Versionsvariablen, die zur Setup-Laufzeit aus Shell-Defaults kommen).
6. `docker compose config | grep image:` mit
   `CODER_VERSION=2.36.6 …` → `ghcr.io/coder/coder:2.36.6` (B-002-Beleg;
   daneben `caddy:2.10`, `postgres:15-alpine`, `prom/prometheus:v3.14.0`,
   `grafana/grafana:12.4.5`, `prom/node-exporter:v1.12.1`).
7. PyYAML-Parse des extrahierten Compose → `YAML_PARSE_OK`; dabei verifiziert:
   6 Services, `postgres.stop_grace_period: 30s` (B-011),
   `127.0.0.1`-Bindungen für 9090/9100/3001 intakt (B-007),
   kein `retention.size` (B-015), `coder.depends_on.postgres.condition:
   service_healthy` intakt, `caddy.depends_on: [coder]` unverändert.
8. Verschachtelungs-Repro (nur `/tmp`, gefahrlos):
   `flock -n /tmp/breaker-verify-v2.lock flock -n /tmp/breaker-verify-v2.lock true`
   → Exit 1 (Deadlock-Mechanik bestätigt, begründet B-001-Fix);
   `grep -c "flock -n /opt/coder/backups" setup-coder.sh` → 0;
   Cron-Zeile ist `0 1 * * * root /opt/coder/backup.sh >> …` (Z. 977).
9. Dump-Header-Probe (nur `/tmp`, echte `gzip`-Artefakte):
   legitimer Dump → `HEADER_OK`; leeres stdin → `HEADER_FAIL (keine Finaldatei)`;
   pg_dump-Fehlertext → `HEADER_FAIL (keine Finaldatei)`. Beleg für B-010-Logik
   (kein hartes Größenlimit nötig).
10. SSH-Key-Regex-Probe: 6/6 Zeilen matchen
    (`ssh-rsa`, `ssh-ed25519`, `ecdsa-sha2-nistp256`,
    `sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com`,
    `ssh-ed25519-cert-v01@openssh.com`) → B-006-Beleg.
11. Caddyfile-Apex-Probe:
    `echo 'coder.ghse-unterricht.de, *.coder.ghse-unterricht.de {' | awk -F'[ ,{]+'
    '/\*.*\{/ {print $1; exit}'` → `coder.ghse-unterricht.de` (Gate-Parsing OK).
12. Grep-Belege: `CODER_VERSION:=2.36.6` (Z. 86); kein aktiver
    `docker image prune`-Befehl (nur 3 Kommentarzeilen); `dropdb --if-exists`
    in `RESTORE.md` (Z. 32); Runbook-Copy-Block (Z. 1038);
    `ufw default deny incoming` / `allow outgoing` (Z. 557 f.);
    `CODER_DISABLE_PATH_APPS` abwesend (B-017-Gate eingehalten);
    16 `note_drift`-Aufrufe (15 Dateien + Definitionstreffer); kein Secret im
    Diff (Scan nur False Positives wie „keyring"/Kommentare).
13. Caddy-Validierung (`caddy validate`, T-004-Äquivalent) → **nicht
    ausgeführt** (`caddy`-Binär fehlt lokal); Site-Block ist textuell
    unverändert außer Kommentaren.

## Changed Files

- `setup-coder.sh` (+442/−67 mit `ssh-harden.sh`/`RESTORE.md` gesamt):
  B-001, B-002, B-003, B-005 (Kommentar + `check-tls.sh` + Cron), B-006
  (Provisoriums-Datum), B-007, B-008 (Runbook-Ablage), B-009 (Gate + Kommentar
  + Pull-Retry), B-010, B-011 (`boot-check.sh` + `@reboot`-Cron + Grace +
  Reboot-Kommentar), B-012 (Helper + 15 Wächter + Hash-Block), B-013 (Helper +
  Retries + Preflights), B-014 (Hex Setup-seitig), B-015 (Kommentar), B-016
  (Logger-Guards + Sweep + Reset-Pre-Check), B-019 (Wildcard-WARN), B-020
  (Break-Glass-Doku + Hinweis-Umzug).
- `ssh-harden.sh`: B-006 (Regex + Post-Check-Enforcement).
- `RESTORE.md`: B-008 (Pfad A `dropdb`/`createdb`).
- Neu angelegt: `ai-review/IMPLEMENTATION-REPORT-v2.md` (diese Datei).
- Unverändert: `templates/allowlist.md` (Inventar steht aus, nichts zu
  erfinden), `main`-Branch, alle OPTIONAL-Punkte.

## Regression Risks

- **Hex-Validierung (B-014):** Re-Run/Reset brechen bei bestehender Nicht-Hex-
  `.env` fail-closed ab (gewollt, per Plan). Einwandfrei laufende Legacy-
  Systeme mit ungefährlichen Zeichen (z. B. `-_`) müssen einmalig via
  `reset-passwords.sh` rotieren. Reparaturweg steht in der Fehlermeldung.
- **Update-Gate strenger (B-009):** Updates, die früher „grün" durchliefen
  (laufend, aber krank), scheitern jetzt sichtbar. Timeout 60 s +
  Parse-Fallback als Warnung begrenzen False-Red; On-Demand-Erstlatenz bleibt
  Restrisiko bei sehr langsamen Netzen (Gate dann zu Recht rot).
- **UFW-Defaults (B-007):** Erste Setzung auf Härtungsdrift-Systemen kann
  Exoten-Regeln entwerten – Defaults entsprechen Debian-Standard, Änderung
  sichtbar in `ufw status verbose`. DOCKER-USER fehlt weiter (bewusst,
  Entscheidung offen) – neue `ports:` bleiben bis dahin ufw-umgehungstauglich;
  Bindungsregel + Review-Check mindern, ersetzen aber keinen Enforcement.
- **Neue Cron-Dateien (`coder-bootcheck`, `coder-tlscheck`):** Additiv und
  lesend; `@reboot`-Lauf schreibt `/var/log/coder-boot.log` (kein Rotation-
  Eintrag – Datei wächst pro Boot um ~20 Zeilen, vernachlässigbar, aber
  unrotiert).
- **`remember_hash`-Store:** Neue Datei `/opt/coder/.generated-hashes`
  (root, 600). Hash-Mismatch nach abgebrochenem Setup-Lauf warnt einmalig zu
  viel (konservativ, kein Datenrisiko).
- **Jail-Include, In-Container-Healthcheck, Offsite, App/DB-Split, Mini-Restore,
  autoritative DNS-Probe, LE-Pull-Proben, Reboot-/Handshake-/Restore-Tests:**
  bewusst offen (siehe Blocker) – kein blind geratener Code, dafür fehlende
  Deckung bis zur Test-VM-Runde.

## Blockers

Was verhindert den nächsten Schritt (jeweils Eigentümer + Test-VM nötig,
keine Eigenentscheidung):

1. **Test-VM** (`coder-test-<datum>`, Debian 13, Snapshot-fähig, Testdomain):
   Ohne sie sind alle T-Tests (Fresh Install, Cron-Pfad, Rollback, Restore,
   Reboot, Scans, Handshakes) unbelegt. Nichts aus diesem Pass wurde auf
   Produktion ausgeführt oder für Produktion freigegeben.
2. **Beidseitige Pull-Probe** (`:2.36.6` muss gehen, `:v2.36.6` protokolliert):
   Vor Merge Pflicht (B-002-Risiko nur dadurch geschlossen).
3. **D-Offsite (D6/B-02):** Ziel, Verschlüsselung, Schlüsselverwahrung getrennt
   vom Host, Retention, Transport-Secrets, Verfallsdatum Leer-Zustand.
4. **D-SSH (B-03):** Key-Rollout-Termin, Zweit-Zugang-Bestätigung, Härtungsdatum.
5. **D-Socket (B-11):** Allowlist dauerhaft vs. Proxy vs. separater Host;
   davor B-004-Erstinventar + T-063-Protokoll.
6. **D-TLS (B-05):** echter `ask` vs. DNS-01-Wildcard (+ CAA, Provider-Token);
   davor B-021-Handshake-Serie mit gepinntem Image (LE-Budget schonen).
7. **D-Firewall (B-04):** DOCKER-USER ja/nein nach Dual-Stack-Test (T-060).
8. **D-Monitoring/Ressourcen (B-07):** Messauftrag (Platte, `docker stats`-
   Woche), danach `retention.size` + `check.sh`-Leser + Schwellen.
9. **D-Reboot-Fenster (B-011):** 03:00 mit Schulbetrieb abstimmen, Wartungsplan.
10. **D-Passwort-Reihenfolge (B-10/P-018):** DB-zuerst vs. `.env`-zuerst nur per
    Test-VM-Beweis.
11. **D-Workspace-RPO (B-018):** Versprechen der Schule + Kommunikation
    (Git-Push-Pflicht oder Server-Backup) + `.env`-Offsite-Verschlüsselung.
12. **D-Update-Split (B-14/K5):** `app`/`db`-Trennung + DB-Major-Prozess.
13. **D-Caddy-Pin / D-PLAN:** exakter Pin vs. Minor nach B-021-Befund;
    PLAN.md-Reparatur (Blocking 0, T-006-Voraussetzung).
14. **RTO-Zahl + Offsite-Probe** (T-080/T-082) und **Template-Inventar → B-017-
    Flag** (T-126) erst nach obigen Entscheidungen + Test-VM.
