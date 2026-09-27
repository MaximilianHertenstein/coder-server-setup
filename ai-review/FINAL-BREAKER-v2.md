# FINAL-BREAKER-v2 – Adversarial Review der Iteration 2

Stand: 2026-09-27. Rolle: Breaker, nicht Lober. Keine Codeänderung, keine
Produktivserver-Befehle, keine Secrets.

Verglichen (alle am HEAD `407bcd6`, Branch `ai/implementation-v2`):

- `baseline` (Tag) vs. `ai/implementation-v1` vs. `ai/implementation-v2`
  (`git diff`: v1→v2 = `setup-coder.sh` + `ssh-harden.sh` + `RESTORE.md` +
  `IMPLEMENTATION-REPORT-v2.md`, 739 Zeilen)
- `ai-review/POST-IMPLEMENTATION-PLAN.md` (B-001–B-021, Maßstab)
- `ai-review/IMPLEMENTATION-REPORT-v2.md` (Behauptungen des Implementierers)

Verifikation: Code-Lesung der gesamten `setup-coder.sh` (1616 Zeilen),
`ssh-harden.sh`, `RESTORE.md` + **vier ausgeführte Gegenbeweise** (nur
`/tmp`, gefahrlos, kein Produktivsystem):

1. SIGPIPE-Probe des B-010-Headerchecks (großer vs. kleiner Dump, `pipefail`)
2. SNI-Probe des B-009-TLS-Smokes (eigener TLS-Server mit SNI-Auswahl wie
   Caddy + `curl` exakt im v2-Muster vs. `--resolve`)
3. Hex-Gate-Probe (Legacy-`.env` gegen beide neuen Gates)
4. Drift-Fehlalarm-Probe (exakte `note_drift`/`remember_hash`-Logik)
5. Upstream-Belege: certmagic-`handshake.go` (SNI-Auswahl,
   `"obtaining certificate"`-Logzeile existiert), Caddy-Issue zu IP-SNI

Ergebnis vorweg: **v2 führt zwei neue CRITICAL-Regressionen ein (B2-001,
B2-002), die Backup- und Update-Pfad vollständig brechen, sobald die DB
real groß ist bzw. immer.** v2 darf so nicht in Produktion.

---

## B2-001 – B-010-Headercheck verwirft jeden produktionsgroßen Dump (SIGPIPE + `pipefail`)

Severity:
CRITICAL

Classification:
CONFIRMED

Related finding:
B-010 (POST-IMPLEMENTATION-PLAN)

Regression:
YES (v2 neu: `setup-coder.sh` Z. 918, Backup-Block)

Reproduction scenario:
1. Setup läuft grün, DB wächst im Unterrichtsbetrieb (beliebig > ~64 KB
   unkomprimiert – jede reale Coder-DB nach kurzer Zeit).
2. Nächster Cron-Lauf 01:00: `pg_dump` erfolgreich, `gzip -t` grün, dann
   Headercheck → „FEHLGESCHLAGEN: kein SQL-Dump-Header, keine Finaldatei
   angelegt", Exit 1.
3. Ab dann: kein einziges neues Backup mehr. Alte rotieren nicht (Abbruch
   vor Rotation), sondern altern still. `update.sh`-Pre-Backup schlägt
   fehl → **Updates blockiert** (`set -e`). `reset-passwords.sh`-Vorab-
   Backup schlägt fehl → **Passwort-Rotation blockiert**. Setup-Re-Run
   meldet `[FEHLER]` in Schritt 6.
4. Diagnose-Irreführung: Die Meldung zeigt auf PG/SQL-Probleme, die
   Ursache liegt im Prüfcode selbst.

Evidence:
Ausgeführt (exakte v2-Pipeline unter `pipefail`):

```
if ! zcat "${TMP}" 2>/dev/null | head -c 4000 | grep -q "PostgreSQL database dump"; then
```

- Kleiner Dump (33 B SQL): `RESULTAT: OK (Header akzeptiert)`
- Großer Dump (414 KB SQL, Header in den ersten Bytes vorhanden):
  `RESULTAT: FAIL (kein SQL-Dump-Header -> keine Finaldatei)`
- `PIPESTATUS=141 0 0`, Pipeline-Exit `141`.

Mechanik: `head -c 4000` schließt die Pipe nach 4000 Bytes; `zcat` bekommt
SIGPIPE (141) beim Weiterschreiben. `backup.sh` läuft unter
`set -o pipefail` → Pipeline-Exit 141 ≠ 0 → `! 141` = wahr → Fail-Zweig.
Trifft deterministisch jeden Dump, dessen **unkomprimierte** Größe den
Pipe-Puffer (~64 KB) übersteigt. Kleine Dumps passen komplett in den
Puffer → `zcat` exitt 0 → grün. Exakt deshalb hat die Report-Probe #9
(„legitimer Dump → HEADER_OK") bestanden: Fixture zu klein.

Impact:
Totalausfall der Sicherungsfunktion mit Zeitbombe: frische Test-DB grün,
Produktions-DB rot. Betroffen sind Cron-Backup, Update-Pre-Backup,
Reset-Vorab-Backup und Setup-Testlauf – also der gesamte
Wartungsvertrag. Zusätzlich: jeder künftige T-071 mit kleiner Test-DB
besteht und verdeckt den Fehler weiter.

Required fix:
SIGPIPE-Ursache entfernen, nicht Schwelle raten. Z. B. Dump-Kopf in
Variable lesen ohne früh schließenden Pipe-Konsumenten:

```
set +o pipefail
if ! zcat "${TMP}" 2>/dev/null | head -c 4000 | grep -q "PostgreSQL database dump"; then
  set -o pipefail
  ... Fail ...
fi
set -o pipefail
```

oder `HEADER=$(zcat "${TMP}" 2>/dev/null | head -c 4000 || true)` und
`grep -q` auf der Variablen (kein Pipe-Exit mehr im Urteil). Danach
erneut gegen echten produktionsgroßen Dump verifizieren.

Required test:
Neuer Test T-071b: Fixture-Dump mit Header + **> 1 MB** unkomprimiert
muss `HEADER_OK` liefern; leeres stdin und Fehlertext weiter
`HEADER_FAIL`. Bestehende T-071-Fixtures sind zu klein und hätten diesen
Fehler nie gefunden – Fixture-Größe ins Testprotokoll.

---

## B2-002 – TLS-Smoke via Host-Header gegen 127.0.0.1 ist immer rot (SNI schlägt Host-Header)

Severity:
CRITICAL

Classification:
CONFIRMED

Related finding:
B-009 (Update-Gate), B-011 (Boot-Gate)

Regression:
YES (v2 neu: `update.sh`-Gate Z. 1115–1130, `boot-check.sh` Z. 765–782)

Reproduction scenario:
1. Vollständig gesunder Stack (alle Container Running, Postgres healthy,
   Apex-Zertifikat gültig, `/healthz` per Browser 200).
2. `sudo /opt/coder/update.sh` nach erfolgreichem `up -d`:
   `curl -sk --max-time 60 -H "Host: ${GATE_DOMAIN}" "https://127.0.0.1/healthz"`
   → Handshake-Fehlschlag → `HEALTH_CODE=000` → „FEHLER: Caddy-TLS-Smoke
   rot" → `GATE_OK=false` → **jedes Update exitt 1**, auch das gesunde.
3. Nach jedem Reboot: `boot-check.sh` meldet `BOOT-GATE ROT`, obwohl alles
   läuft – morgendlicher Fehlalarm als Normalzustand.
4. Nebeneffekt: Jeder Gate-Lauf löst einen On-Demand-Versuch für SNI
   `127.0.0.1` aus (`ask` antwortet 200, LE verweigert IP) – Log-Spam im
   Caddy plus Zähler für Failed-Validation-Limits.

Evidence:
Ausgeführt gegen TLS-Server mit Caddy-äquivalenter SNI-Auswahl
(unbekanntes SNI → Handshake-Alert):

- v2-Muster `curl -sk -H "Host: good.test" https://127.0.0.1:18443/healthz`
  → `HTTP_CODE=000 CURL_EXIT=35` (Handshake-Fehler; der Host-Header
  erreicht den Server nie).
- Korrektur `curl --resolve good.test:18443:127.0.0.1 https://good.test:18443/`
  → `HTTP_CODE=200`.

Mechanik (deterministisch, kein Timing): TLS-SNI kommt aus dem
URL-Host (`127.0.0.1`), nicht aus `-H Host:`. Caddy wählt das Zertifikat
per SNI (`certmagic/handshake.go`: `getNameFromClientHello`,
`getCertificateFromCache(hello)`; ohne Treffer `no certificate
available` bzw. On-Demand-Versuch für die IP). Der Report behauptet
„Host-Header gegen 127.0.0.1 (kein DNS nötig)" – das verwechselt
HTTP-Routing mit TLS-Handshake. Perverse Folge: Das Gate wird nur dann
grün, wenn die Apex **nicht** parsbar ist (WARN-Fallback) – Gesundheit
wird bestraft, Nicht-Prüfbarkeit belohnt.

Impact:
Update-Gate wertlos + Update-Pfad blockiert (gesunde Updates scheitern
sichtbar → Operator lernt, das Gate zu ignorieren/zu umgehen → auch
kranke Updates gehen durch). Boot-Zeuge invertiert (Dauer-Rot →
Warnmüdigkeit → echter Reboot-Schaden fällt nicht auf). B-009 und B-011
sind damit trotz „implementiert" nicht geschlossen.

Required fix:
SNI = Domain setzen, Verbindung trotzdem lokal halten – an beiden
Stellen identisch:

```
curl -sk --max-time 60 -o /dev/null -w "%{http_code}" \
  --resolve "${GATE_DOMAIN}:443:127.0.0.1" "https://${GATE_DOMAIN}/healthz"
```

(`--connect-to` äquivalent.) Danach Gate auf Test-VM je einmal gegen
gesunden Stack (muss 200) und gegen gestoppten Coder (muss rot)
verifizieren. Bogus-`ask`-Treffer für `127.0.0.1` im Caddy-Log nach
Fix erneut prüfen (sollten ab dann ausbleiben).

Required test:
T-090 erweitern: Update auf gesundem Stack muss Gate-grün liefern
(Protokoll mit `HEALTH_CODE=200`); Negativprobe T-091 (Coder gestoppt)
muss Gate-rot liefern. Boot-Gate T-110: gesunder Boot muss
`BOOT-GATE GRÜN` loggen. Beide Tests wären mit v2-Code rot – sie fehlen
genau deshalb im Report (nur statische Belege, kein einziger
Handshake).

---

## B2-003 – Hex-Gate-Pingpong: Legacy-`.env` kann weder Setup noch Reset passieren (kein Migrationspfad)

Severity:
HIGH

Classification:
CONFIRMED

Related finding:
B-014

Regression:
YES (v2 neu: Setup-Gate Z. 248–253 + Reset-Gate Z. 1210–1214)

Reproduction scenario:
1. Bestehende `.env` ist vollständig, aber enthält Nicht-Hex-Zeichen
   (Alt-System, Hand-Edit – exakt der Fall, für den das Gate gebaut wurde).
2. `setup-coder.sh` Re-Run → „Fehler: Nicht-Hex … Reparatur:
   `sudo /opt/coder/reset-passwords.sh`" → Exit 1.
3. `sudo /opt/coder/reset-passwords.sh` → identische Prüfung →
   „Fehler: Nicht-Hex … Reparatur: `sudo /opt/coder/reset-passwords.sh`"
   → Exit 1. **Das Skript verweist auf sich selbst.**
4. Endzustand: Passwort-Rotation unmöglich, Setup-Re-Run unmöglich,
   dokumentierter Ausweg existiert nicht (Hand-Edit der `.env` ist
   nirgends beschrieben und riskant).

Evidence:
Ausgeführt mit Legacy-Fixture
(`POSTGRES_PASSWORD=Legacy$Pass!23`, vollständig): Setup-Gate verweigert
mit Verweis auf Reset; Reset-Gate verweigert mit Verweis auf sich selbst.
Beide Meldungen wörtlich aus dem Code (Z. 250–252, Z. 1211–1213).

Impact:
Fail-closed ohne Ausgang: Genau die Systeme, die das Gate schützen soll,
sind danach nicht mehr wartbar. Bei akutem Rotationsbedarf (Verdacht auf
kompromittiertes Passwort, Lehrerwechsel) steht der Operator ohne
Verfahren da.

Required fix:
Eines von beiden (Entscheidung dokumentieren, kein doppeltes Raten):
(a) `reset-passwords.sh` akzeptiert altes Nicht-Hex-Passwort nur lesend
als `PGPASSWORD` (altes PW wird nie in SQL/URL interpoliert, nur als
Env-Wert übergeben – dafür Heredoc quoten oder `docker exec -e` mit
`docker inspect`-Tradeoff dokumentieren) und würfelt Hex neu; oder
(b) dokumentierter manueller Migrationspfad (Hex per `openssl rand`
erzeugen, `.env` + `ALTER USER` + `grafana-cli` angleichen). In jedem
Fall: Reset-Meldung darf nicht auf Reset verweisen.

Required test:
Sonderzeichen-`.env` (`Legacy$Pass!23`, Spaces, Quotes) → genau ein
definierter Weg muss zum Ziel führen (Reset grün + danach beide Gates
grün); Endlosschleife per Protokoll ausgeschlossen.

---

## B2-004 – B-007 nur halb gefixt: Re-Run warnt, löscht restriktive SSH-Regel aber trotzdem (Detektor lückenhaft)

Severity:
HIGH

Classification:
CONFIRMED

Related finding:
B-007 (POST-IMPLEMENTATION-PLAN verlangte „Downgrade nur explizit")

Regression:
NO (MUST_FIX weiterhin bestehend; v2 macht aus still nur laut)

Reproduction scenario:
1. Operator härtet SSH: `ufw allow from 10.16.0.0/12 to any port 22`.
2. Empfohlener Bedienweg Re-Run: WARN erscheint in SUMMARY („Re-Run
   weitet SSH aus"), danach löschen Z. 571–573 exakt diese Regel und
   `limit 22/tcp` öffnet weltweit. Downgrade vollzogen, Warnung nur
   Beobachter.
3. Variante ohne jede Warnung: `ufw allow from 192.168.1.0/24 to any
   port 22` zeigt `ufw status` als `22 ALLOW 192.168.1.0/24` – der
   Detektor (`22/(tcp|ssh).*(ALLOW|LIMIT).*([0-9]{1,3}\.)`, Z. 564)
   verlangt `22/tcp` oder `22/ssh` und **trifft nicht** (ausgeführt
   verifiziert: `10.16.0.0/12`-Zeile matcht, `22 ALLOW 192.168.1.0/24`
   nicht). Die Regel überlebt die drei `delete`-Zeilen ebenfalls nicht
   zuverlässig, `limit 22/tcp` tritt weltweit daneben – Restriktion
   faktisch aufgehoben, ohne einen Mucks.

Evidence:
Code-Reihenfolge Z. 564 (Warnung) → Z. 571–573 (Löschen) → Z. 581
(weltweit öffnen): kein Abbruch, kein Opt-out, kein Wiederherstellen.
Detektor-Verhalten per `grep -E` gegen reale `ufw status`-Zeilenformate
ausgeführt.

Impact:
Der B-007(c)-Angriffspfad (Re-Run revertiert SSH-Härtung) besteht fort;
die Warnung erzeugt zusätzlich falsche Sicherheit („wurde ja gemeldet").
Betriebsrisiko mittel-hoch über Lebensdauer (jeder Re-Run nach Härtung).

Required fix:
Plan einhalten: bei detektierter restriktiver Regel Downgrade nur
explizit – z. B. hart abbrechen mit Anleitung (Regel notieren,
Setup mit angepasster Regel fahren) oder Regel nach Lauf automatisch
wiederherstellen + verifizieren. Detektor auf `ufw status numbered`-
Formate erweitern (`22 ALLOW <ip>`, `OpenSSH`-Profil mit Quelle).
Danach Re-Run-Probe aus der Matrix (restriktiv → kein stilles Öffnen).

Required test:
T-062 + neue Re-Run-Downgrade-Probe: restriktive Regel (beide
Schreibweisen) setzen → Re-Run → Regel muss entweder erhalten bleiben
oder der Lauf muss abbrechen; `ufw status` danach protokollieren.

---

## B2-005 – `check-tls.sh`-Erkennung erblindet bei Log-Rotation (30-MB-Deckel vs. 7-Tage-Fenster)

Severity:
MEDIUM

Classification:
LIKELY

Related finding:
B-005 (Erkennung), B-015 (Logging-Limits)

Regression:
NO (v2-neues Feature, fehlerhaft dimensioniert)

Reproduction scenario:
1. Produktiver Schulbetrieb: Caddy-Access-Logs füllen die
   `json-file`-Limits (10 MB × 3 Dateien = 30 MB pro Container,
   `docker-compose.yml` Z. 295–299).
2. `check-tls.sh` (Z. 822) zählt `obtaining certificate` in
   `docker logs --since 168h` – die letzten 7 Tage passen nicht in
   30 MB, Älteres ist rotiert und weg.
3. Ergebnis: wöchentlicher Bericht meldet z. B. „3 Ausstellungen",
   während 60 stattfanden – exakt im Angriffsfall (Budget-DoS erzeugt
   Traffic + Ausstellungen gleichzeitig) zeigt das Instrument Entwarnung.

Evidence:
Code-Fakten: Limit 10m×3 im Repo (Z. 295–299); `--since 168h`-Fenster
im Skript (Z. 822); Upstream-Beleg, dass die gezählte Zeile existiert
(`tls.obtain: "obtaining certificate"`, INFO-Level – Phrase korrekt,
Quelle der Blindheit ist allein die Aufbewahrung). Auslösung
szenarioabhängig (Logvolumen), daher LIKELY, Mechanik belegt.

Impact:
B-005-Erkennung als Entscheidungsgrundlage für D-TLS untauglich;
Budget-DoS wird im Ernstfall nicht bemerkt.

Required fix:
Zählung rotationsfest machen: wöchentlichen Zählerstand persistent
fortschreiben (Delta statt 7-Tage-Scan) oder Caddy-Log in Datei-Volume
mit eigener Rotation + `logrotate` für `/var/log/coder-tls.log`
(letzteres fehlt ebenfalls) schreiben. Bis dahin Limit im Skript
dokumentieren („nur was in 30 MB passt").

Required test:
T-125 erweitern: nach simulierter Log-Rotation (`docker logs` sichtbar
gekürzt) muss der Zähler als unvollständig erkennbar sein oder das
persistente Delta stimmen.

---

## B2-006 – Reset-Pre-Check steht hinter `down`: bei Treffer ist der Stack halb zerlegt

Severity:
MEDIUM

Classification:
CONFIRMED

Related finding:
B-016(c), B-020(a)

Regression:
NO (v2-Verbesserung, aber unvollständig: Pre-Check Z. 1474–1481 nach
`down --remove-orphans` Z. 1445)

Reproduction scenario:
1. Fremder Container (Workspace-Rest, paralleler Lauf) hält ein zu
   löschendes Volume.
2. `reset-coder.sh`: Inventar → Backup → Bestätigung → `down
   --remove-orphans` (Container gestoppt, Netz weg) → Volume-Ermittlung
   → **jetzt erst** Pre-Check → Abbruch „VOR dem ersten rm".
3. Zustand: Daten intakt (gut), aber Stack gestoppt und ohne Netz mitten
   im destruktivsten Pfad des Repos; Cron-Backup in diesem Fenster
   scheitert; Wiederherstellung nur per dokumentiertem Einzeiler
   (`up -d`), den der gestresste Operator erst finden muss. Versprochen
   war „Abbruch VOR Zerstörung".

Evidence:
Code-Reihenfolge Z. 1445 (`down`) vor Z. 1474 (`volume rm`-Pre-Check);
Meldung Z. 1478 bestätigt implizit („nichts gelöscht, .env intakt
(`docker compose up -d` stellt wieder her)") – Wiederherstellung nötig
heißt Zerstörung (Betrieb) bereits eingetreten.

Impact:
Kein Datenverlust, aber selbstgebauter Teilausfall im Reset-Fenster;
bei gleichzeitigem Cron-Takt kaskadiert das (Backup-Fehlalarm,
`update.sh`-Folgefehler).

Required fix:
Volume-Ermittlung + Belegungs-Check **vor** `down` ziehen (beides lesend
möglich); `down` erst nach grünem Pre-Check. Meldung dann wahrheitsgemäß:
„nichts angefasst".

Required test:
T-102-Szenario (belegtes Volume) → nach Abbruch müssen alle Container
noch laufen (`docker compose ps` grün), nicht nur Volumes intakt.

---

## B2-007 – Drift-Hashes erst in Schritt 10: abgebrochener Lauf erzeugt falschen Drift-Alarm im Heilungslauf

Severity:
MEDIUM

Classification:
CONFIRMED

Related finding:
B-012 (v2 neu)

Regression:
YES (Mechanik B-012 neu; Fehlalarm-Pfad eingebaut)

Reproduction scenario:
1. Lauf 1 erfolgreich → Hashes für alle 15 Dateien in
   `/opt/coder/.generated-hashes` festgeschrieben.
2. Skript/Zeit/Env ändert Template-Inhalt (Version bump, Domain-Wechsel);
   Lauf 2 schreibt neue Dateien (Schritt 2), bricht dann ab (Netz,
   Daemon, Hex-Gate) **vor** Schritt 10 → Hashstore veraltet.
3. Lauf 3 (Heilung): `note_drift` meldet „Drift … Hand-Anpassung geht
   verloren", obwohl niemand Hand angelegt hat – das Residuum stammt vom
   Setup selbst. Wiederholt bei jedem Versionssprung mit Netzwerkfehler.
   Folge: B-012-Warnungen werden als Rauschen gelernt und echte
   Operator-Drift später ignoriert.

Evidence:
Ausgeführt mit exakter `note_drift`/`remember_hash`-Logik: nach
Hashstore-v1 + Datei-v2 ohne `remember_hash` meldet `note_drift`
„WARN: Drift". Code-Fakt: einziger `remember_hash`-Ort ist die
Schleife Z. 1514–1521 (Schritt 10); jeder `exit 1`-Pfad davor
(Hex-Gate Z. 252, Daemon-Preflight Z. 507, `set -e`-Abbrüche) lässt
stale Hashes zurück.

Impact:
Kein Datenrisiko (Regeneration deterministisch), aber Vertrauensschaden
am Warnsystem – demselben System, das B-007-Downgrades melden soll.

Required fix:
Hash unmittelbar nach jeder Schreibstelle festschreiben (dort, wo heute
`note_drift` steht), Schritt-10-Schleife entfernen. Dann ist der
Hashstore nach Abbruch konsistent mit dem Geschriebenen.

Required test:
T-026 erweitern: Abbruch nach Schritt 2 simulieren (Datei neu, kein
Hash-Commit) → Heilungslauf darf keine Drift-WARN für setup-eigene
Residuen melden; echte Operator-Drift (Zeile von Hand) muss weiter
melden.

---

## B2-008 – Port-Preflight warnt bei jedem Re-Run vor den eigenen Containern (Warnmüdigkeit)

Severity:
LOW

Classification:
LIKELY

Related finding:
B-013 (v2 neu, Z. 516–520)

Regression:
YES (neu; v1 hatte keinen Preflight)

Reproduction scenario:
Jeder Re-Run auf gesundem System: Caddy belegt 80/443/443-udp,
Prometheus/Grafana/Exporter 9090/9100/3001 → fünf WARN-Zeilen mit
Prozess-Hinweis, immer, ohne Informationswert. Der Kommentar (Z. 508)
gibt das zu („eigene Container belegen 80/443 beim Re-Run zu Recht").
Echte Fremd-Konflikte gehen im gewohnten Rauschen unter.

Evidence:
Code-Lesung (kein Abgleich gegen eigene Compose-Container, reiner
`ss`-Match); Auswirkung verhaltensbasiert, daher LIKELY.

Impact:
Gering direkt, aber systematisch: v2 fügt an vier Stellen (Ports,
Drift-Fehlalarm B2-007, Dauer-Rot B2-002, Wildcard-WARN) Warnrauschen
hinzu – die SUMMARY verliert ihre Alarmfunktion.

Required fix:
Eigene Listener ausnehmen (Ports, die zu `coder-*`-Containern gehören,
nicht warnen) oder auf Re-Run nur Fremd-PIDs melden.

Required test:
Re-Run auf gesundem Stack → keine Port-WARN; Fremd-Listener auf 80 →
WARN mit Prozessname.

---

## B2-009 – RESTORE Pfad A ohne `ON_ERROR_STOP`: stiller Teil-Restore möglich (Kompensation entfernt)

Severity:
MEDIUM

Classification:
LIKELY

Related finding:
B-008

Regression:
PARTIAL (v2 schrieb Pfad A um und strich die Kompensation
„Fehlerprotokoll lesen" ersatzlos)

Reproduction scenario:
1. Restore nach Runbook auf frischer VM: `dropdb`/`createdb` ok,
   `zcat dump | psql` läuft.
2. Dump enthält einen Fehler (abgebrochene Tabelle, Extension fehlt,
   Versionsdrift): `psql` ohne `ON_ERROR_STOP` führt weiter aus und
   exitt 0 – Schritt 5 (`/healthz` + Login) prüft keine
   Daten-Vollständigkeit.
3. Ergebnis: Restore „grün", Coder startet auf lückigem Schema –
   bemerkt erst im Unterricht. v1 verlangte wenigstens
   „Fehlerprotokoll lesen"; v2 streicht den Satz („kein
   Fehlerprotokoll lesen", Z. 31) und setzt nichts an seine Stelle.

Evidence:
Befehlszeile `RESTORE.md` Z. 32–34 (kein `-v ON_ERROR_STOP=1`, kein
`set -e`-Äquivalent); `psql`-Handbuchverhalten (ohne `ON_ERROR_STOP`
Exit 0 trotz Skriptfehlern). Kein Live-Restore je gefahren (Report
gibt zu), daher LIKELY.

Impact:
Schlimmste Restore-Eigenschaft: falsches Grün bei Datenlücke; RTO-Zahl
wird für einen kaputten Restore protokolliert.

Required fix:
`psql -v ON_ERROR_STOP=1` in Pfad A (Abbruch hart, Kette stoppt vor
`up -d`) + Verifikationsschritt (Tabellenzahl/Probe-Login mit echter
Datensicht, nicht nur `/healthz`).

Required test:
T-080 mit defektem Dump (eine fehlerhafte `CREATE TABLE`-Zeile) → Pfad
A muss rot abbrechen statt grün durchzulaufen.

---

# Verifizierte Nicht-Befunde (v2-Behauptungen halten)

- B-001 Cron-Deadlock-Fix: Cron-Zeile ohne `flock` (Z. 988), innerer
  Lock einzige Sperre – `grep -c "flock -n /opt/coder/backups"` = 0. OK.
- B-003 Prune: kein aktiver `docker image prune`-Befehl (nur 3
  Kommentarzeilen Z. 1137–1149). OK.
- B-017-Gate eingehalten: `CODER_DISABLE_PATH_APPS` 0 Treffer. OK
  (korrekt nicht gesetzt ohne Inventar).
- B-015: kein geratener `retention.size` (2 Treffer, beide Kommentare).
  OK. DOCKER-USER nur Kommentar. OK. Kein `jail.d`-Include (ehrlich
  zurückgestellt). OK. Caddy `depends_on: [coder]` unverändert, kein
  ungeprüfter `service_healthy`-Umbau. OK.
- B-006 ssh-harden: Post-Check-Enforcement + SK-/Cert-Regex vorhanden;
  Report-Probe 6/6 Key-Typen plausibel (Regex deckt `sk-*` und
  `-cert-v01@` ab). OK.
- `note_drift`/`remember_hash`-Dateilisten konsistent (15 Dateien,
  Schritt-10-Schleife deckt alle `note_drift`-Stellen ab). OK.

# Weiterhin bestehende MUST_FIX-Probleme (nicht durch v2 geschlossen)

Durch Code- und Grep-Nachweise bestätigt, jeweils mit Plan-Referenz:

1. **B-002-Pull-Probe offen:** Code auf `2.36.6` korrigiert (Z. 86),
   aber kein einziger `docker pull`-Beleg – frische Installation weiter
   unbelegt. BLOCKING.
2. **B-004 Socket:** Mount weiter schreibbar + `group_add`, kein `:ro`,
   kein Proxy (Z. 332–333, 343); Allowlist weiter Doku ohne Inventar
   und Selbsttest. BLOCKING (D-Socket ohne Frist).
3. **B-005-Mechanik:** `ask http://example.com` aktiv (Z. 472);
   nur Erkennung hinzu, Modellentscheidung D-TLS offen. Budget-DoS +
   Hostnamen-Abfluss bestehen.
4. **B-006 D-SSH:** Provisorium (weltweit + Passwort) weiter Default;
   nur Datum im Log neu. Termin/Zweit-Zugang offen.
5. **B-007 DOCKER-USER:** bewusst fehlend (korrekt), aber jede neue
   `ports:`-Zeile weiter öffentlich – nur Doku-Bindungsregel.
6. **B-008 Offsite + RTO:** kein Transport, RTO-Tabelle leer
   (`_offen_`); Runbook-Ablage auf Server implementiert (Z. 1047–1054),
   Pfad-A-Verfahren festgelegt (siehe aber B2-009).
7. **B-009 app/db-Split:** bewusst zurückgestellt (Bedienvertrag). OK,
   aber DB-Major weiter ungetrennt.
8. **B-010 Mini-Restore-Automatisierung:** fehlt (nur Header Fail +
   Größen-Warnung – und der Header-Fail ist per B2-001 kaputt).
9. **B-011 In-Container-Healthcheck + Caddy-`service_healthy`:**
   zurückgestellt (korrekt ohne Image-Nachweis); Boot-Gate neu, aber
   per B2-002 dauer-rot.
10. **B-012 jail.local-Include:** zurückgestellt (korrekt ohne
    Merge-Nachweis); Operator-Jails weiter vollüberschrieben.
11. **B-014 P-018-Reihenfolge:** DB-zuerst unverändert, Beweis offen
    (siehe B2-003 für den akuten Teil).
12. **B-015 Messung:** nur Kommentar („UNVERMESSEN"), kein
    `retention.size`, kein `check.sh`, kein Leser.
13. **B-017-Flag:** korrekt abwesend (Gegenbefund oben), Inventar fehlt.
14. **B-018 Workspace-RPO:** keine Entscheidung, keine Kommunikation.
15. **B-019 App-Smoke:** nur `getent`-WARN (Z. 1578–1583), T-124 offen;
    Negativprobe ungefahren.
16. **B-020 Label-Recherche + Pipe-Guard:** Labels weiter unverifiziert;
    `--force`-Doku neu, Mechanik unverändert.
17. **B-021 Handshake-Serie:** nie ausgeführt (LE-Budget/VM fehlen);
    Caddy weiter Minor-Pin 2.10.
18. **Blocking 0 PLAN-Reparatur:** `PLAN.md` F-012 endet weiter mitten
    im Satz („Soll nach Dok" + Trunkierungsmarker, Z. ~518); T-006
    weiter rot. Kein Code, aber Freigabe-Voraussetzung.

# Blocking Findings

Vor jedem Produktionslauf zu schließen (Code rot, nicht nur Entscheidung
offen):

1. **B2-001** (Headercheck tötet echte Backups + blockiert Updates und
   Rotationen) – Backup-Pfad defekt.
2. **B2-002** (TLS-Smoke immer rot – Updates scheitern, Boot-Zeuge
   invertiert) – Update- und Reboot-Pfad defekt.
3. **B2-003** (Hex-Pingpong ohne Migrationspfad) – Wartbarkeit für
   Alt-`.env` blockiert.
4. **B-002-Pull-Probe** (beidseitiger Pull-Beleg `:2.36.6` muss gehen) –
   Installierbarkeit unbelegt.
5. **B-008-Offsite + RTO-Probe** – Plattenverlust weiter Totalverlust.
6. **B2-009** (`ON_ERROR_STOP` + Restore-Verifikation) – sonst falsches
   Grün im Ernstfall.
7. **B-004-Inventar + T-063-Protokoll + D-Socket-Frist** – Sicherung auf
   kompromittierbarer Basis.
8. **B2-004** (Re-Run-Downgrade nur explizit) – Härtung sonst
   Verfallsmaterial.
9. **Blocking 0** (PLAN-Reparatur) – Freigabe-Basis.

# Remaining High-Risk Findings

- B2-004 (SSH-Downgrade trotz Warnung; Detektorlücke `22 ALLOW <ip>`).
- B2-005 (TLS-Erkennung rotationsblind).
- B2-006 (Reset lässt gestoppten Stack zurück).
- B2-009 (stiller Teil-Restore).
- B-005-Mechanik (Budget-DoS + Leak, nur beobachtet).
- B-004-Socket (Host-root-äquivalent bei Kompromittierung).
- B-015 (schleichender Plattenvoll-Ausfall, weiter ohne Bremse/Leser).
- B-021 (Caddy-2.10-Semantik weiter ungeprobt – B2-002-Fix braucht
  denselben Handshake-Teststand).
- B-011-Betriebsfenster (03:00-Reboot weiter unabgestimmt).

# Regression Findings

Durch v2-Änderungen neu eingeführt oder verschlechtert:

| ID | Regression | Schwere |
|---|---|---|
| B2-001 Headercheck-SIGPIPE | YES (neu, Backup/Update/Rotation tot ab ~64 KB) | CRITICAL |
| B2-002 TLS-Smoke-SNI | YES (neu, Update-Gate + Boot-Gate dauer-rot) | CRITICAL |
| B2-003 Hex-Pingpong | YES (neu, Migrationspfad blockiert) | HIGH |
| B2-007 Drift-Fehlalarm nach Abbruch | YES (neu, B-012-Mechanik) | MEDIUM |
| B2-009 ON_ERROR_STOP-Kompensation gestrichen | PARTIAL (Pfad-A-Umschreibung) | MEDIUM |
| B2-008 Port-WARN-Rauschen | YES (neu, B-013-Preflight) | LOW |

Fix-Seite positiv verifiziert (keine Regression): B-001-`flock`,
B-003-Prune-Entfernung, B-002-Tag (Code), B-006-Regex/Post-Check,
B-007-Defaults (Policy), B-012-Warnung (Mechanik), B-013-Retry (Mechanik),
B-019-Wildcard-WARN, B-020-Hinweis/Pre-Check-Teil.

# Tests Still Missing

`tests/` ist leer. Kein einziger VM-Test aus der Matrix wurde
ausgeführt (Report gibt zu: T-010, T-026, T-030–T-033, T-050, T-053,
T-060–T-064, T-067, T-070–T-077, T-079–T-083, T-090–T-093, T-100–T-106,
T-110–T-113, T-120, T-123–T-126, Handshake-Serien). Zusätzlich fehlen –
sie hätten genau die v2-Regressionen gefangen:

- **T-071b (neu, B2-001):** Headercheck gegen Dump **> 1 MB**
  unkomprimiert. Alle bisherigen Fixtures waren zu klein.
- **Gate-Handshake-Tests (B2-002):** Update-Gate grün auf gesundem
  Stack / rot bei gestopptem Coder; Boot-Gate grün nach gesundem Boot.
  Noch nie per Handshake geprüft – nur `awk`-Parsing.
- **Hex-Migrations-Test (B2-003):** Sonderzeichen-`.env` durch beide
  Skripte; Endlosschleife ausgeschlossen.
- **Drift-Abbruch-Test (B2-007):** Abbruch vor Hash-Commit →
  Heilungslauf ohne Fehlalarm.
- **Reset-Ordnungs-Test (B2-006):** belegtes Volume → Container laufen
  weiter nach Abbruch.
- **Downgrade-Probe (B2-004):** beide `ufw`-Regelformate.
- **Defekt-Dump-Restore (B2-009):** T-080 mit fehlerhaftem Dump muss
  rot abbrechen.
- **`caddy validate`** (T-004-Äquivalent): weiter nicht ausgeführt
  (Binär fehlt lokal) – der Caddyfile-Block ist seit v1 ungeprüft.
- **B-021-Handshake-Serie + T-124/T-125/T-126:** weiter keine Artefakte.

# Assessment of v2

v2 schließt nachweislich B-001 (Cron-Deadlock) und B-003 (Prune) und
liefert lesbare, korrekte Teile (UFW-Defaults, ssh-harden-Post-Check,
Drift-Warnmechanik, Retry/Preflight-Mechanik). Die ehrliche
Blocker-Dokumentation im Report ist gut – aber unvollständig: Der
Report behauptet getestete Sicherheit („Dump-Header-Probe",
„Gate-Parsing OK", „16 note_drift-Belege"), wo nur Kleinst-Fixtures und
Text-Proben liefen. Genau diese Lücke ließ zwei CRITICAL-Regressionen
durch, die schlimmer sind als die gefixten Befunde:

- B-001 (v1) ließ Backups nie entstehen – sichtbar am Fehlen von Dateien.
- B2-001 (v2) lässt Backups erst entstehen und dann **für immer
  versagen**, sobald die DB real wird – mit irreführender Diagnose.
- B-009 (v1) hatte kein Gate – Updates liefen blind durch.
- B2-002 (v2) hat ein Gate, das **nie grün** wird – Updates scheitern
  grundsätzlich, der Boot-Zeuge lügt täglich.

v2 ist damit in Backup-, Update- und Reboot-Pfad **schlechter als v1**
und darf weder gemergt noch ausgerollt werden, bis B2-001, B2-002 und
B2-003 gefixt und per neuem Test (großer Dump, echter Handshake,
Legacy-`.env`) auf Test-VM belegt sind. Der Fix-Aufwand ist klein
(drei Stellen, keine Architektur) – aber ohne Test-VM mit
produktionsgroßer DB und echter Domain bleibt jede weitere Iteration
Blindflug. Die dafür nötigen Tests stehen oben; `tests/` ist leer.
