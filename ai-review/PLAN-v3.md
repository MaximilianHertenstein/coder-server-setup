# PLAN-v3 – Konsolidierter Implementierungsplan (nächste Version)

Stand: 2026-09-27. Baseline: Branch `ai/implementation-v2`, HEAD `a09c591`
(`setup-coder.sh` 1615 Newlines per `wc -l` / 1616 logische Zeilen – letzte
Zeile `fi` ohne abschließenden Newline; alle Zeilenreferenzen unten beziehen
sich auf diesen Stand), `ssh-harden.sh` (80 Zeilen), `RESTORE.md`
(68 Zeilen), `templates/allowlist.md` (34 Zeilen), `tests/` leer.
Setup-Diff `eadb61a..HEAD` ist leer (nur `ai-review/PLAN-v3.md` als Delta,
verifiziert per `git diff eadb61a..HEAD --stat`); Freigabe-Protokoll hält
`git rev-parse --short HEAD` + `git diff eadb61a..HEAD --stat` fest.
Geltungsbereich: ausschließlich Planung. Es wird nur diese Datei
(`ai-review/PLAN-v3.md`) erstellt. Keine Implementierung, keine
Produktivserver-Befehle, keine Secrets, `main` unverändert.

Eingaben: `setup-coder.sh`, `AGENTS.md`, `.github/copilot-instructions.md`
(im Repo als `copilot-instructions.md`), `ai-review/01`–`08`,
`PLAN.md`, `PLAN-REVIEW.md`, `TEST_PLAN.md`, `POST-IMPLEMENTATION-PLAN.md`,
`IMPLEMENTATION-REPORT-v2.md`, `FINAL-BREAKER-v2.md`.

Arbeitsregel: Reviews sind keine Wahrheit. Jeder unten genannte Befund wurde
gegen den aktuellen Code geprüft (vollständige Lesung `setup-coder.sh`,
`ssh-harden.sh`, `RESTORE.md`; Zeilenangaben unten beziehen sich auf diesen
Stand). Klassifizierung pro Befund: CONFIRMED / LIKELY / FALSE_POSITIVE /
ALREADY_FIXED / DECISION_REQUIRED. Unbekanntes ist als `OPEN` markiert und
wurde nicht erfunden.

Ziel (in dieser Reihenfolge, keine Abweichung):

```
correctness > security > recoverability > idempotency > testability
  > maintainability > performance > aesthetics
```

Keine Optimierung darf eine funktionierende Sicherheits-/Fehlerbarriere
entfernen, nur um Code zu sparen. Kein großes Refactoring gleichzeitig mit
einem kritischen Fix. Ziel ist NICHT Zeilenzahl, Modularisierung oder
Dokumentationsmenge, sondern maximale Sicherheit, Korrektheit,
Recoverability und Wartbarkeit bei minimaler unnötiger Komplexität.

Freigabe-Lage vorweg: `FINAL-BREAKER-v2.md` sperrt v2 zu Recht
(`B2-001`/`B2-002` CRITICAL, `B2-003` HIGH). v2 darf weder gemergt noch
ausgerollt werden, bis Phase A gefixt und per Phase B auf Test-VM belegt ist.

---

# Phase A – Critical Corrections (V2-Regressionen, klein und lokal)

Regel für diese Phase: minimale sichere Änderung, kein Refactoring, keine
zusätzlichen Features, keine Barrieren-Entfernung ohne gleichwertigen Ersatz.
Reihenfolge = Abhängigkeit (Backup zuerst, dann Gates, dann Warnsystem).

## B2-001 – Backup-Headercheck verwirft jeden produktionsgroßen Dump (SIGPIPE + pipefail)

Klassifizierung: **CONFIRMED**

Ursache: `backup.sh` läuft unter `set -euo pipefail`
(`setup-coder.sh` Z.851). Der Headercheck Z.918:

```bash
if ! zcat "${TMP}" 2>/dev/null | head -c 4000 | grep -q "PostgreSQL database dump"; then
```

`head -c 4000` schließt die Pipe nach 4000 Bytes; `zcat` erhält SIGPIPE
(Exit 141) sobald der unkomprimierte Dump den Pipe-Puffer (~64 KB)
übersteigt. Unter `pipefail` ist der Pipeline-Exit 141 ≠ 0, `! 141` ist wahr
→ Fail-Zweig. Kleine Fixtures (Report-Probe #9) passen in den Puffer und
bleiben grün – exakt deshalb wurde der Fehler nicht gefunden.

Stelle: `setup-coder.sh` Z.918 (eingebettetes `backup.sh`, Block Z.842–956).

Minimale sichere Änderung: SIGPIPE-Ursache entfernen, keine Schwelle raten.
Kopf in Variable lesen, Urteil auf Variable (kein Pipe-Exit im Urteil):

```bash
HEADER="$(zcat "${TMP}" 2>/dev/null | head -c 4000 || true)"
if ! printf '%s' "${HEADER}" | grep -q "PostgreSQL database dump"; then
  ... Fail ...
fi
```

Alternative mit gleichem Effekt (`set +o pipefail` um genau diese drei
Zeilen + sofortiges `set -o pipefail`) ist gleichwertig; es darf nur eine
Variante gewählt werden. `gzip -t` (Z.913), df-Gate, atomares `mv`,
flock-Selbst-Lock, Retention-Mindestbestand bleiben unverändert.

Erwartetes Verhalten: Dump > 1 MB unkomprimiert mit Header → `HEADER_OK`
+ Finaldatei; leeres stdin / `pg_dump`-Fehlertext → Fail ohne Finaldatei;
Cron-, Update-Pre-Backup-, Reset-Vorab-Backup- und Setup-Testlauf funktionieren
wieder für reale DB-Größen.

Regression Risk: gering. Falscher Fix (nur Schwelle erhöhen, `head` größer)
würde den Fehler nur verschieben. Deshalb Fixture-Größe ins Protokoll.

Test: T-071b (neu, UNIT-LIKE lokal + VM): Fixture-Dump mit Header +
**> 1 MB** unkomprimiert muss `HEADER_OK` liefern; leeres stdin und
Fehlertext weiter `HEADER_FAIL`. Kategorie: UNIT-LIKE (lokal, nur `/tmp`) +
VM (echter `backup.sh`-Lauf). Bestehende T-071-Fixtures sind zu klein und
zählen nicht als Beleg.

## B2-002 – TLS-Smoke via Host-Header gegen 127.0.0.1 ist immer rot (SNI schlägt Host-Header)

Klassifizierung: **CONFIRMED**

Ursache: TLS-SNI kommt aus dem URL-Host, nicht aus `-H Host:`.
`update.sh`-Gate Z.1115–1130 und `boot-check.sh` Z.765–782 fahren:

```bash
curl -sk --max-time 60 -o /dev/null -w "%{http_code}" -H "Host: ${DOMAIN}" "https://127.0.0.1/healthz"
```

SNI ist damit `127.0.0.1`. Caddy wählt das Zertifikat per SNI
(`certmagic/handshake.go`: `getNameFromClientHello`); ohne Treffer kein
Zertifikat bzw. On-Demand-Versuch für die IP (LE verweigert IP, Log-Spam +
Failed-Validation-Zähler). Der Host-Header erreicht den Server nie (Breaker-
Repro: v2-Muster → `000`/Exit 35; `--resolve`-Variante → `200`).
Perverse Folge heute: Gate wird nur grün, wenn die Apex nicht parsbar ist
(WARN-Fallback) – Gesundheit wird bestraft.

Stelle: `setup-coder.sh` Z.1115–1130 (eingebettetes `update.sh`),
Z.765–782 (eingebettetes `boot-check.sh`). Schritt-10-Probe Z.1559–1571
(echtes DNS+SNI) ist korrekt und bleibt Referenz.

Minimale sichere Änderung – drei Fälle wörtlich getrennt (kein Copy-Paste
von 60 s in den Boot-Loop, kein `--resolve` in Schritt 10):

- SCHRITT 10 (Z.1559–1571, Referenz, unverändert): echter DNS-Pfad, Domain
  als SNI, kein `--resolve`, `--max-time 10`. Darf NICHT auf `--resolve`
  umgestellt werden (sonst entfällt Real-Pfad/DNS-Coverage).
- UPDATE (Z.1115–1130, single-shot):

```bash
curl -sk --max-time 60 -o /dev/null -w "%{http_code}" \
  --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz"
```

  (`--connect-to` äquivalent; genau eine Variante wählen.) 60 s wegen
  On-Demand-Erstverzögerung 5–30 s.
- BOOT (Z.765–782, bestehende 30×10-Loop): `--resolve "${DOMAIN}:443:127.0.0.1"`
  mit Domain als SNI, `--max-time 10`, innerhalb der bestehenden
  Poll-Schleife (kein Fail, WARN bei unparsbar).

Überall SNI = Domain, nirgends SNI = `127.0.0.1` (kein `-H Host:` gegen
`https://127.0.0.1`). Nach dem Fix: Gate-Mechanismus erzeugt keine
`127.0.0.1`-bezogenen On-Demand-TLS-Versuche mehr (Beleg: Caddy-Log-Grep
`obtaining certificate` ohne `127.0.0.1`). WARN-statt-Fail bei unparsbarer
Domain bleibt. Keine neue Mechanik, keine `ask`- oder DNS-01-Änderung in
dieser Phase (D-TLS bleibt Entscheidung).

Erwartetes Verhalten: gesunder Stack → `HEALTH_CODE=200`, Gate grün;
gestoppter Coder → rot; keine On-Demand-Versuche für SNI `127.0.0.1` mehr
im Caddy-Log.

Regression Risk: mittel ohne Handshake-Nachweis. Sehr langsame Netze können
trotz 60 s rot melden – dann zu Recht rot (Gate), kein stilles Grün.
Freigabe nur nach Test-VM-Handshake (gesund + krank).

Test: T-090 (gesund → grün mit `HEALTH_CODE=200`-Protokoll), T-091 (Coder
gestoppt → rot), T-110 (gesunder Boot → `BOOT-GATE GRÜN` im laufenden Log)
+ Caddy-Log-Grep (kein `127.0.0.1`-`obtaining`). Kategorie: VM +
INTEGRATION. Reine `awk`-Parsing-Belege zählen nicht.

## B2-003 – Hex-Gate-Pingpong: Legacy-`.env` kann weder Setup noch Reset passieren

Klassifizierung: **CONFIRMED**

Ursache: Setup-Gate Z.248–253 und Reset-Gate Z.1210–1214 weisen beide
Nicht-Hex-`.env` fail-closed ab. Die Setup-Meldung verweist auf
`reset-passwords.sh` (Z.250–252), die Reset-Meldung verweist auf sich selbst
(Z.1211–1213). Alt-System mit `Legacy$Pass!23` o. ä. kann damit weder Setup-
Re-Run noch Rotation durchlaufen – dokumentierter Ausweg existiert nicht.
Zusatzkante: `reset-passwords.sh` interpoliert `OLD_PG_PW` in unquotiertem
Heredoc (`<<INNER_EOF`, Z.1263/1271); Sonderzeichen/Quotes brechen
`export`/`psql -c`-Zeile – das alte Passwort wird nie als reiner Env-Wert
durchgereicht.

Stelle: `setup-coder.sh` Z.241–253 (Setup-Gate), Z.1202–1214 (eingebettetes
`reset-passwords.sh`, Reset-Gate), Heredoc-Übergaben Z.1263/1271/1281.

Festgeschriebene Strategie (genau EINE, keine Wahl im Implementierungs-PR):
Variante (a) – Reset migriert Legacy lesend, Setup bleibt fail-closed.
`docker exec -e PGPASSWORD=...` wird NICHT verwendet (kein neues
`docker inspect`-Leak, 02/F-015). Das bestehende STDIN-Prinzip bleibt.

- Setup-Gate (Z.248–253): bleibt fail-closed für Nicht-Hex. Ersatztext
  wörtlich: `Fehler: /opt/coder/.env enthält Nicht-Hex-Passwörter.`
  `Reparatur: erst sudo /opt/coder/reset-passwords.sh laufen lassen`
  `(migriert Legacy lesend nach Hex), danach Setup erneut.` – zulässig,
  weil Reset nach diesem Fix Legacy lesend akzeptiert und daher NICHT
  denselben Gate-Fehler ausgibt (kein Pingpong).
- Reset-Gate (Z.1210–1214): wird aufgespalten in ALT lesend vs. NEU Hex.
  ALT (`OLD_PG_PW` aus `.env`) darf Legacy sein – kein Fehler. Fail-closed
  (Exit 1) bleibt für: unvollständige `.env` und für nicht-Hex NEU-Werte.
  Die Reset-Fehlermeldung bei unvollständiger `.env` verweist auf die
  Setup-Reparatur (fehlende Schlüssel ergänzen), NIEMALS auf
  `sudo /opt/coder/reset-passwords.sh` selbst.
- Postgres-Teil (Z.1263, ALT-Auth): Heredoc wird quotiert (`<<'INNER_EOF'`,
  gegen äußeres `<<'EOF'` geprüft – implementierbar, keine Host-Expansion).
  Das Alt-Passwort wird ausschließlich als Env-Wert via STDIN übertragen
  (Host: `printf '%s' "$OLD_PG_PW" | docker exec -i coder-postgres sh -s`
  + Container: `read -rs OLD_PG_PW; export PGPASSWORD="$OLD_PG_PW"`),
  nie in SQL oder URL interpoliert, nie als `docker exec`-Argument
  (weder `ps`- noch `inspect`-sichtbar). `ALTER USER` nutzt nur das
  gewürfelte Hex-NEU-Passwort (Container-Variable, `[0-9a-f]`, kann
  Shell-/SQL-Quoting nicht aufbrechen).
- Postgres-Verifikation (Z.1271) und Grafana-Teil (Z.1281): bleiben
  unquotiert, Begründung: ausschließlich Hex-NEU-Werte aus
  `openssl rand -hex` (kein Legacy-Zeichenvorrat, keine
  Interpolationsgefahr); ebenfalls ohne `docker exec -e` (kein
  `inspect`-Leak).
- Erlaubter Legacy-Fixture-Zeichenvorrat: alle druckbaren ASCII 0x20–0x7E
  außer Newline (0x0A) und NUL – explizit inkl. `$`, Backtick, `"`, `'`,
  Space, `!` (History-Expansion greift in nicht-interaktiven Skripten
  nicht, dokumentiert), führendem `-` (stets via `printf '%s'` /
  `grep --` / `cut -d= -f2-` verarbeiten, nie als Option). UTF-8 außerhalb
  ASCII: nicht garantiert, wird als ungetestet abgewiesen.
- Nicht unterstützte Zeichen (Newline/NUL in `.env`-Wert – kann in
  einzeiliger `.env` ohnehin nur via Hand-Edit entstehen): harter Abbruch
  Exit 1 mit Text `Fehler: .env-Wert enthält Newline/NUL – wird nicht`
  `still getrimmt. Reparatur: .env-Wert manuell auf einzeiliges Hex`
  `(openssl rand -hex 24/16) setzen, per ALTER USER + grafana-cli`
  `angleichen (Schrittfolge im Runbook), danach Setup erneut.` Kein
  stilles Trimmen, kein stilles Neuwürfeln (P-011 bleibt).
- Exakter Fehler-/Migrationspfad: Legacy-`.env` → `reset-passwords.sh`
  (liest ALT lesend, würfelt Hex NEU, schreibt `.env` atomar) → Setup-Re-Run
  grün + Reset-Re-Run grün (jetzt Hex). Genau ein grüner Weg, kein
  Reset→Reset-Verweis. DB-zuerst vs. `.env`-zuerst wird hier NICHT still
  umgestellt (D-Passwort-Reihenfolge, nur per Test-VM-Beweis).

Erwartetes Verhalten: Sonderzeichen-`.env` → genau ein definierter Weg
führt zu zwei grünen Gates (Setup + Reset); Endlosschleife ausgeschlossen.

Regression Risk: mittel. `docker exec -e` ist verboten (sonst `inspect`-
Leak); unquotierter ALT-Heredoc ist verboten (sonst Quote-Bruch). Deshalb
Pflicht-Fixture unten.

Test: Hex-Migrations-Test (B2-003, VM echte DB + `ALTER USER`): Legacy-`.env`
mit den Werten `Legacy$Pass!23`, `a b` (Spaces), `a"b`, `a'b`, `a$b`,
`` a`b `` (Backtick), `-führend` sowie ein Negativfall mit Newline im Wert
(dokumentiert abgewiesen, kein stilles Trimmen) durch beide Gates → genau
ein grüner Weg, danach beide Gates grün; während Rotation parallel
`ps aux | grep -F` + `docker inspect coder-postgres coder-grafana | grep -F`
auf Passwortfragmente (Grep nach Vollwert + nach 8-Zeichen-Präfix) – beide
Grep müssen leer bleiben (kein `ps`-Leak, kein `inspect`-Leak). Lokale
Regex-Probe (UNIT-LIKE) zusätzlich, aber kein Ersatz. Kategorie: VM.

## B2-004 – Re-Run warnt, löscht restriktive SSH-Regel aber trotzdem (Detektor lückenhaft)

Klassifizierung: **CONFIRMED** (keine neue Regression, MUST_FIX weiterhin
offen; v2 macht aus still nur laut)

Ursache: Warnung Z.564 → Löschen Z.571–573 → weltweit Öffnen Z.581 ohne
Abbruch/Opt-out/Wiederherstellung. Detektor
`22/(tcp|ssh).*(ALLOW|LIMIT).*([0-9]{1,3}\.)` trifft `ufw allow from
10.16.0.0/12 to any port 22` (Z.564 matcht), trifft aber `22 ALLOW
192.168.1.0/24` (reales `ufw status`-Format ohne `/tcp`) nicht (Breaker-
Repro per `grep -E` belegt). Die Regel überlebt die drei `delete`-Zeilen
nicht zuverlässig, `limit 22/tcp` tritt weltweit daneben.

Stelle: `setup-coder.sh` Z.564–581.

Minimale sichere Änderung (benutzbarer Mechanismus, kein „Regel vorher
sichern" als Handwedeln): Plan einhalten (Downgrade nur explizit). Exakter
Detektor (Snapshot `UFW_OUT=$(sudo ufw status numbered)` + Fallback
`sudo ufw status` ohne `numbered`): matcht restriktive Regeln in allen
unterstützten Formaten – IPv4 + IPv6 (`(v6)`-Zeilen), `22/tcp`, `22` ohne
Suffix, `OpenSSH`-Profilname, Quellen wie `10.16.0.0/12`, Formen
`22 ALLOW <source>` / `22/tcp ALLOW <source>` / `allow from <source> to any
port 22` / `OpenSSH ALLOW <source>` (je mit/ohne `(v6)`); Regex wörtlich im
Implementierungs-PR mit UNIT-LIKE-Fixtures belegt. Verhalten: (A) weltweit
offen (`22/tcp LIMIT Anywhere` / `ALLOW Anywhere`) → kein falscher Abort,
Lauf fährt fort; (B) restriktive Regel (Quelle ≠ Anywhere) → harter Abbruch
Exit 1 mit Anleitung + vorher/nachher-`ufw status`-Protokoll, kein stilles
Öffnen; (C) UFW nicht aktiv (`Status: inactive` / Befehl fehlt) → kein
Abbruch, Hinweis + `ufw`-Setup-Pfad fährt fort. Re-Run-Pfad (B): abgebrochene
restriktive Regel wird protokolliert, Setup wird mit dokumentierter
angepasster Regel gefahren (Anleitung im Abbruchtext), die Härtung wird
NICHT still entfernt. Bypass-Mechanismus: `CODER_ALLOW_SSH_DOWNGRADE=yes`
(explizit, kein Default) – Syntax: nur exakt `yes` (alles andere = Abbruch);
Verhalten: Lauf fährt trotz restriktiver Regel fort, protokolliert
vorher/nachher-`ufw status`, stellt nach Lauf die notierte restriktive Regel
verifiziert wieder her (`ufw`-Befehl + Check im Protokoll);
Sicherheitswirkung: Downgrade-Fenster ist explizit, zeitlich begrenzt und
belegt – kein stilles weltweites Öffnen. Kein automatisches
Wiederherstellen ohne Verifikation (mehr Mechanik = mehr Risiko).
Bindungsregel-Kommentar und Review-Check bleiben.

Erwartetes Verhalten: restriktive Regel (alle unterstützten Formate) +
Re-Run → entweder Regel erhalten oder Lauf bricht ab (oder expliziter
Bypass mit Wiederherstellung); `ufw status` vorher/nachher protokolliert;
kein stilles weltweites Öffnen.

Regression Risk: gering (nur Fehlerpfad). Zu strenger Detektor könnte
legitime Standard-Läufe abbrechen – deshalb Positiv-/Negativ-Fixtures
unten als Pflicht.

Test: T-062 + Re-Run-Downgrade-Probe (VM + UNIT-LIKE gegen reale
`ufw status`-Zeilenformate beider Schreibweisen + weltweit-Negativ +
IPv6-`(v6)` + No-UFW-Fall): restriktive Regel → Abbruch oder Erhalt mit
vorher/nachher-Protokoll (bzw. Bypass nur mit `CODER_ALLOW_SSH_DOWNGRADE=yes`
+ verifizierter Wiederherstellung), weltweit offen → kein Abort, UFW
inaktiv → definierter Pfad mit Hinweis; nie stilles Öffnen. Kategorie:
VM + UNIT-LIKE.

## B2-006 – Reset-Pre-Check steht hinter `down`: bei Treffer ist der Stack halb zerlegt

Klassifizierung: **CONFIRMED** (keine neue Regression im engeren Sinn;
v2-Verbesserung unvollständig)

Ursache: `reset-coder.sh`: `down --remove-orphans` Z.1445 vor
Volume-Ermittlung + Belegungs-Check Z.1474–1481. Bei Treffer (fremder
Workspace hält zu löschendes Volume): Daten intakt, aber Stack gestoppt,
Netz weg, Cron-Backup im Fenster rot; Wiederherstellung nur per
dokumentiertem Einzeiler (`up -d`). Versprochen war „Abbruch VOR
Zerstörung".

Stelle: `setup-coder.sh` Z.1440–1486 (eingebettetes `reset-coder.sh`).

Minimale sichere Änderung: Volume-Ermittlung + `docker ps -aq --filter
volume=`-Check **vor** `down` ziehen (beides lesend möglich); `down` erst
nach grünem Pre-Check. Meldung wahrheitsgemäß („nichts angefasst" statt
„nichts gelöscht, `.env` intakt (`up -d` stellt wieder her)"). Leer-Guard,
Allowlist, `--force`-Zweitphrase, TTY-Guard, Zertifikats-/Backup-Schutz
bleiben unverändert.

Erwartetes Verhalten: belegtes Volume → Abbruch vor `down`, alle Container
laufen weiter (`compose ps` grün), Volumes + `.env` intakt.

Regression Risk: gering (nur Reihenfolge lesender Checks). Ermittlung vor
`down` sieht ggf. andere Containerliste als nach `down` – das ist
gewollt (konservativ: lieber einmal zu viel abbrechen als halb zerlegen).

Test: T-102-Szenario (belegtes Volume) → nach Abbruch müssen alle Container
noch laufen, nicht nur Volumes intakt. Kategorie: VM (DESTRUCTIVE-Guard:
Snapshot + Revert, nie Produktion).

## B2-007 – Drift-Hashes erst in Schritt 10: abgebrochener Lauf erzeugt falschen Drift-Alarm

Klassifizierung: **CONFIRMED** (Mechanik B-012 neu; Fehlalarm-Pfad eingebaut)

Ursache: einziger `remember_hash`-Ort ist die Schleife Z.1514–1521
(Schritt 10). Jeder `exit 1`-Pfad davor (Hex-Gate Z.252,
Daemon-Preflight Z.507, `set -e`-Abbrüche) lässt stale Hashes zurück.
Lauf 1 grün → Datei-Template ändert sich (Version/Domain) → Lauf 2 schreibt
neu (Schritt 2), bricht vor Schritt 10 ab → Lauf 3 (Heilung) meldet
„Operator-Drift" für setup-eigene Residuen (Breaker-Repro mit exakter
`note_drift`/`remember_hash`-Logik belegt). Folge: Warnmüdigkeit, auch für
B-007-Downgrade-Warnung.

Stelle: `setup-coder.sh` Z.116–133 (Helper), 16 `note_drift`-Aufrufe,
Commit-Schleife Z.1514–1521.

Minimale sichere Änderung: `remember_hash` unmittelbar NACH der jeweiligen
erfolgreichen Schreib-/Installations-Sequenz, die die überwachte Datei
tatsächlich erzeugt oder ersetzt (also nach `tee`/`mv`/`chmod`/`install`,
NICHT an der `note_drift`-Zeile davor – `note_drift` steht heute VOR jedem
`tee`, wörtlich umgesetzt würde der Hash der ALTEN Datei committet).
Schritt-10-Schleife (Z.1514–1521) löschen. Keine neue Mechanik, nur
Ortswechsel. Deterministische Regeneration (Heilung bleibt), WARN-Semantik
(nie interaktiv stoppen), 600-Modus des Hashstores, Abdeckung aller 15
Dateien bleiben.
Residualkante (zulässig, dokumentiert): Kill zwischen erfolgreichem Write
und `remember_hash` erzeugt einmalig eine Fehl-WARN im nächsten Lauf –
kein Datenverlust, keine Fehlheilung; der folgende grüne Lauf heilt den
Hashstore.

Erwartetes Verhalten: Abbruch nach Schritt 2 → Heilungslauf ohne Fehlalarm
für setup-eigene Residuen; echte Hand-Drift meldet weiter WARN.

Regression Risk: mittel. Ortswechsel ohne Abbruch-Test vertauscht nur die
Fehlalarm-Richtung. Deshalb T-026-Pflicht (beide Pfade unten).

Test: T-026 erweitert (VM + UNIT-LIKE): (a) Abbruch nach Schritt 2
simulieren (Datei neu, kein Hash-Commit) → Heilungslauf ohne Drift-WARN
für setup-eigene Residuen; (b) echte Operator-Drift (Hand-Zeile) → WARN
bleibt; (c) Residualpfad: Kill zwischen Write und `remember_hash`
simulieren (Datei neu, Hash alt) → genau einmal Fehl-WARN, danach grüner
Lauf heilt ohne Datenverlust. Kategorie: VM.

## B2-008 – Port-Preflight warnt bei jedem Re-Run vor den eigenen Containern

Klassifizierung: **LIKELY** (Code-Fakt per Lesung; Auswirkung
verhaltensbasiert)

Ursache: Preflight Z.516–520 matcht reinen `ss`-Output ohne Abgleich gegen
eigene Compose-Container. Jeder Re-Run auf gesundem System (Caddy 80/443,
Prometheus/Grafana/Exporter 9090/9100/3001) erzeugt fünf WARN-Zeilen ohne
Informationswert (Kommentar Z.508 gibt das zu). Echte Fremd-Konflikte gehen
im Rauschen unter; zusammen mit B2-007/B2-002/Wildcard-WARN verliert SUMMARY
ihre Alarmfunktion.

Stelle: `setup-coder.sh` Z.507–525.

Minimale sichere Änderung (exakte Implementierung, kein abstrakter Filter):
TCP via `ss -tlnp`, UDP via `ss -ulnp` (getrennt – `ss -tlnp` allein ist
TCP-only und sieht UDP 443/QUIC nie). Docker-Port-Bindings via
`docker inspect --format '{{.HostConfig.PortBindings}}'` je Projekt-Container
(`coder`, `coder-postgres`, `coder-caddy`, `coder-prometheus`,
`coder-grafana`, `coder-node-exporter` – via `docker compose ps -q` im
Projekt `coder` identifiziert, Name-Präfix `coder-*`). Vergleich: exakte
Host-IP:Host-Port-Paare aus `inspect` gegen `ss`-Listener (Host-IP +
Host-Port müssen beide übereinstimmen, z. B. `0.0.0.0:80`, `:::443`,
`127.0.0.1:9090`). Unterdrückt werden dürfen NUR exakte Treffer
(Listener gehört belegbar zu eigenem Compose-Container). Jeder andere
Listener auf den geprüften Ports (80/tcp, 443/tcp, 443/udp, 9090/tcp,
9100/tcp, 3001/tcp) → WARN mit Prozessname, auch bei Port-Gleichheit ohne
IP-Gleichheit. Keine Ports aus der Prüfung streichen, nur exakte
eigene Treffer filtern – kein breiter Filter, der echte Konflikte
schluckt.

Erwartetes Verhalten: Re-Run gesund → keine Port-WARN; Fremd-Listener auf
80/tcp → WARN mit Prozessname; Fremd-Listener auf 9090/tcp → WARN;
fremder UDP-Listener auf 443 → WARN (via `ss -ulnp`).

Regression Risk: gering. Zu aggressive Filterung könnte echte Konflikte
schlucken – deshalb exakter IP:Port-Vergleich + Positivproben als Pflicht.

Test: Re-Run-Probe (VM): (1) gesund → keine WARN; (2) Fremd-Listener auf
80/tcp → WARN; (3) Fremd-Listener auf 9090/tcp → WARN; (4) fremder
UDP-Listener auf 443 → korrekt behandelt (WARN, nicht still). Kategorie:
VM.

## B2-009 – RESTORE Pfad A ohne `ON_ERROR_STOP`: stiller Teil-Restore möglich

Klassifizierung: **LIKELY** (Code-Fakt CONFIRMED: Flag fehlt; Live-Restore
nie gefahren, daher Auslösung LIKELY, Mechanik per `psql`-Handbuch belegt)

Ursache: v2 schrieb Pfad A auf `dropdb --if-exists`/`createdb` + `psql`-
Import fest (`RESTORE.md` Z.32–34) und strich die Kompensation
„Fehlerprotokoll lesen" ersatzlos. Ohne `-v ON_ERROR_STOP=1` führt `psql`
nach Fehler (abgebrochene Tabelle, fehlende Extension, Versionsdrift) weiter
aus und exitt 0; Schritt 5 (`/healthz` + Login) prüft keine
Daten-Vollständigkeit. Ergebnis: Restore „grün" auf lückigem Schema,
RTO-Zahl für kaputten Restore.

Stelle: `RESTORE.md` Z.32–34 (Pfad A), Verifikation Z.38–40.

Minimale sichere Änderung: Pfad-A-Zeile wörtlich (Flag-Position exakt –
`-v ON_ERROR_STOP=1` als `psql`-Option VOR `-U`, Abbruch hart, Kette stoppt
vor `up -d`):
`zcat coder_<TS>.sql.gz | sudo docker exec -i coder-postgres psql -v
ON_ERROR_STOP=1 -U coder -d coder` (bei Fehler: Exit ≠ 0, kein `up -d`,
kein grüner Restore). Verifikation nach Restore unterscheidet Liveness
(`/healthz` 200, `SELECT 1`) von korrekt wiederhergestellten Daten:
konkrete Datenprobe – vor Backup Testdatensatz anlegen (z. B. Tabelle
`restore_probe(id serial primary key, marker text)` + Zeile
`marker='RTO-PROBE-<datum>'`), nach Restore prüfen via
`SELECT count(*) FROM restore_probe WHERE marker='RTO-PROBE-<datum>'`
(muss `1` liefern) + Dashboard-Login zeigt Test-Datensatz (nicht nur 200).
Leere/frisch erstellte DB (Zählung `0`) wird NICHT als Restore-Erfolg
akzeptiert; defekter Dump (eine fehlerhafte `CREATE TABLE`-Zeile) muss rot
abbrechen.

Erwartetes Verhalten: defekter Dump (eine fehlerhafte `CREATE TABLE`-Zeile)
→ Pfad A bricht rot ab statt grün durchzulaufen; Voll-Restore zeigt
Testdatensatz, sonst rot.

Regression Risk: gering. Zu strikte Verifikation könnte legitime Restores
mit Warnungen rot melden – deshalb Verifikation als Datensicht (Zählung +
Login), nicht als Log-String-Match.

Test: T-080 mit defektem Dump (Negativprobe) → muss rot abbrechen.
Kategorie: VM + RECOVERY (Wegwerf-Postgres, nie Produktion).

## B2-005 – `check-tls.sh`-Erkennung erblindet bei Log-Rotation (mitgeführt, nicht Phase-A-pflichtig)

Klassifizierung: **LIKELY** (Mechanik belegt, Auslösung volumensabhängig)

Ursache: `check-tls.sh` Z.822 zählt `obtaining certificate` in
`docker logs --since 168h`; Compose begrenzt `json-file` auf 10 MB × 3
(Z.295–299). 7 Tage passen bei produktivem Schulbetrieb nicht in 30 MB;
Älteres ist rotiert und weg. Bericht meldet z. B. „3" statt „60" – exakt im
Angriffsfall (Budget-DoS erzeugt Traffic + Ausstellungen gleichzeitig).
`/var/log/coder-tls.log` selbst ist zusätzlich unrotiert.

Stelle: `setup-coder.sh` Z.295–299, Z.814–836; kein `logrotate` für
`coder-tls.log`/`coder-boot.log` (nur `coder-backup.log` hat eines).

Behandlung: kein Phase-A-Fix (falscher Schnellschuss = neues Risiko).
Bis zur Lösung Limit im Skript dokumentieren („nur was in 30 MB passt") +
Phase-E-Entscheidung: Zählung rotationsfest machen (wöchentlichen
Zählerstand persistent fortschreiben = Delta statt 7-Tage-Scan) oder
Caddy-Log in Datei-Volume mit eigener Rotation; `logrotate` für
`coder-tls.log`/`coder-boot.log` nachziehen. D-TLS bleibt Eigentümer.

Test: T-125 erweitert (VM): nach simulierter Log-Rotation muss der Zähler
als unvollständig erkennbar sein oder das persistente Delta stimmen.

---

# Teil 2 – Blocking Findings aus älteren Runden (Triage A/B/C/D)

Legende: A = muss vor Test-VM behoben werden (Phase-A-Fix oben). B = kann
erst auf Test-VM entschieden werden (Nachweis fehlt, kein Raten). C = braucht
menschliche Architekturentscheidung (Eigentümer + Frist, nicht vom
Implementierer zu setzen). D = derzeit nicht ausreichend belegt (kein
Blocking, kein Code ohne Nachweis).

| ID | Stand heute (Code-Fakt) | Klasse | Nächster Schritt |
|---|---|---|---|
| B-002 Pull-Probe | Code auf `2.36.6` korrigiert (Z.86), aber kein einziger `docker pull`-Beleg | B | Beidseitige Pull-Probe vor Merge (`:2.36.6` muss gehen, `:v2.36.6` protokollieren) + T-010 Fresh Install. Kein Hochziehen auf 2.37.x im selben Zug. |
| B-004 Docker Socket / Isolation | Mount schreibbar + `group_add` (Z.330–343), kein `:ro`, kein Proxy; `templates/allowlist.md` Stufe 1 vorhanden, Erstinventar `_offen_`, T-063 nie gelaufen | C (+B-Anteil) | Sofort ohne Umbau: Erstinventar + Abhakpflicht (T-064) + T-063-Selbsttest-Protokoll. Modell (Allowlist dauerhaft vs. Proxy vs. separater Host) als D-Socket mit Frist. Kein Proxy-Einbau ohne Beschluss. |
| B-005 On-Demand TLS | `ask http://example.com` aktiv (Z.472); nur Erkennung hinzu, Mechanik unverändert; Kommentar ehrlich korrigiert | C (+B-Anteil) | B-021-Handshake-Serie zuerst (Befund), dann D-TLS (echter `ask` vs. DNS-01-Wildcard + CAA + Token). Kein `ask`-Schnellschuss, kein DNS-01-Umbau ohne Token-Beschluss. |
| B-006 SSH | Provisorium (weltweit + Passwort aktiv) weiter Default; nur Datum im Log neu; `ssh-harden.sh` vorbereitet (Regex + Post-Check) | C | D-SSH (Key-Termin, Zweit-Zugang-Bestätigung, Härtungsdatum). Kein Key-only-Enforcement im Setup ohne Zweit-Zugang. T-061. |
| B-007 Firewall / DOCKER-USER | Defaults idempotent gesetzt (Z.557–558), Bindungsregel dokumentiert, IPv6-Pfad deklariert; DOCKER-USER bewusst fehlend (korrekt); Re-Run-Downgrade per B2-004 offen | A (B2-004) + C | B2-004-Fix vor Test-VM. DOCKER-USER nur als D-Firewall nach Dual-Stack-Test (T-060). Kein Einbau ohne Nachweis. |
| B-008 Offsite / RTO | Kein Transport (grep-negativ), RTO-Tabelle `_offen_`; Runbook-Ablage auf Server implementiert (Z.1047–1054), Pfad A festgelegt (aber B2-009) | A (B2-009) + C | B2-009-Fix vor Test-VM. Offsite als D6 (Ziel, Verschlüsselung, Schlüssel getrennt vom Host, Retention, Transport-Secrets, getrennte Exit-Codes). RTO-Zahl + T-080/T-082 erst danach. |
| B-010 Backup-Verifikation / Mini Restore | `gzip -t` + Header-Fail + Größen-Warnung vorhanden, aber Header per B2-001 defekt; Vorwert-Warnung + Skip-Alter vorhanden; wöchentlicher Wegwerf-Postgres fehlt | A (B2-001) + B | B2-001-Fix vor Test-VM. Mini-Restore-Automatisierung erst mit Test-VM-Entwurf (nicht blind raten). Kein hartes Größenlimit ohne Restore-Beweis (P-013). |
| B-011 Healthcheck / Boot | `boot-check.sh` + `@reboot`-Cron + `stop_grace_period: 30s` nur Postgres vorhanden, aber Boot-Gate per B2-002 dauer-rot; In-Container-Healthcheck + Caddy-`service_healthy` korrekt zurückgestellt (Tool im Coder-Image unbelegt) | A (B2-002) + B | B2-002-Fix vor Test-VM. In-Container-Check nur nach Test-VM-Verifikation (sonst Totalausfall via `depends_on`). Reboot-Fenster 03:00 mit Schulbetrieb abstimmen (D-Reboot). |
| B-012 Drift | `note_drift`/`remember_hash` + Store (root, 600) vorhanden, Warnung vor Schreiben für alle 15 Dateien; Commit-Ort per B2-007 falsch | A (B2-007) | B2-007-Fix (Hash an Schreibstelle) vor Test-VM. `jail.local`-Include korrekt zurückgestellt (braucht Merge-Nachweis). |
| B-014 Migration (Passwort-Reihenfolge) | Hex-Validierung fail-closed + getrennte Trap-Texte vorhanden; DB-zuerst unverändert; B2-003-Pingpong offen | A (B2-003) + C | B2-003-Fix vor Test-VM. Reihenfolge DB-zuerst vs. `.env`-zuerst nur per Test-VM-Beweis (D-Passwort-Reihenfolge). Kein stilles Redesign. |
| B-015 Storage / Log Limits | `logging` 10m×3 + `retention.time=15d` vorhanden; kein geratener `retention.size` (korrekt); 500-MB-Boden als UNVERMESSEN markiert; kein `check.sh`, kein Leser | C (+B-Anteil) | D-Monitoring nach Messung (Plattenkapazität, `docker stats`-Woche), danach `retention.size` + `check.sh`-Leser + Schwellen. Kein Fantasiewert. T-067/T-073/T-077/T-079. |
| B-017 Workspace Security | `CODER_DISABLE_PATH_APPS` korrekt abwesend (0 Treffer) | C | Gated auf B-004-Inventar: erst Template-Inventar, dann Flag. T-126. Kein Flag ohne Inventar (legitime Pfad-Apps brächen). |
| B-019 App Smoke | Apex-/Wildcard-Probe getrennt, `getent`-WARN nie Fail; autoritativer Server fehlt (kein `dig` garantiert); T-124 offen | B | WARN-Charakter bleibt (Setup soll bei fehlender Weiterleitung starten). T-120/T-124 + Wildcard-Negativprobe auf Test-VM. |
| B-020 Reset / Volume Safety | Projekt-Label-Filter + Allowlist + Leer-Guard + Belegungs-Pre-Check (halb) + `--force`-Doku + TTY-Guard vorhanden; Reihenfolge per B2-006 falsch; Labels unverifiziert | A (B2-006) + B | B2-006-Fix vor Test-VM. Label-Recherche (B-11) + gestoppte Workspaces/Volumes auf Test-VM. Break-Glass-Doku (wer/darf/Nachweis) festhalten. T-100–T-106. |
| B-021 Caddy / Handshake | Minor-Pin 2.10 unverändert; Site-Form ungeprobt; nie per Handshake getestet | B | Handshake-Serie mit gepinntem Image auf Testdomain (LE-Budget schonen, nie Produktion) + T-124/T-125. Speist D-TLS. Kein `force_automate`/Downgrade ohne Nachweis. |

Verifiziert keine Regression (Fix-Seite hält, per Code-Lesung): B-001-
`flock` (Cron ohne äußeres Lock, Z.988), B-003 kein aktives `prune`
(nur Kommentare), B-006 Regex/Post-Check, B-007 Defaults-Policy,
B-012-Warnmechanik, B-013-Retry-Mechanik, B-019-Wildcard-WARN,
B-020-Hinweis-Teil, B-015 kein geratenes `retention.size`.

Weiter bestehend ohne Phase-A-Anteil (korrekt zurückgestellt, kein Code
ohne Nachweis): `jail.d`-Include, In-Container-Healthcheck,
Offsite-Transport, App/DB-Split, Mini-Restore-Automatisierung,
autoritative DNS-Probe, Reboot-/Handshake-/Restore-Nachweise.

---

# Phase B – Automated Tests (Test-First)

Test-Source-of-Truth (entschieden, keine zwei konkurrierenden Pläne):
`ai-review/TEST_PLAN.md` bleibt die Master-Testmatrix. PLAN-v3 ergänzt nur
die neuen B2-Delta-Tests bzw. markiert sie als Delta: T-071b
(Groß-Dump > 1 MB), Gate-Handshake (T-090/T-091/T-110 inkl. T-110-rot),
Hex-Migration (B2-003-Vollvorrat inkl. `$`/Backtick/Quotes/Space/
führendes `-`/Newline-Abweisung + `ps`/`inspect`-Grep), T-026-erweitert
(inkl. Residualpfad Kill-zwischen-Write-und-Hash), T-102-erweitert
(Container-laufen-weiter), Downgrade-Probe (B2-004 inkl. IPv6/`numbered`/
weltweit-Negativ/No-UFW), T-080-negativ (Defekt-Dump + Datenprobe),
T-004-`caddy validate`. Ablage: neue B2-Tests werden in `tests/` als
STATIC/UNIT-LIKE-Harness umgesetzt (inkl. T-007-Selbsttest), was nur auf
der Test-VM möglich ist (Handshake, Full-Restore, Reboot, Destroy-Pfade)
läuft ausschließlich dort mit Artefakt. `ai-review/TEST_PLAN.md` wird als
Delta nachgezogen, bis dahin gilt die Phase-B-Matrix oben für den
B2-Umfang.

Grundsatz: Für jede relevante Änderung existiert ein Test. Ein Test, der
lokal gefahrlos ausführbar ist, wird nicht auf die Test-VM verschoben.
`tests/` ist heute leer – erster Schritt ist lokale Deckung für Phase A,
zweiter Schritt VM-Nachweis. Niemals „bestanden" ohne Artefakt (Datum,
VM-Name, Commit, Tool-Versionen, Exit-Codes, Logs). AGENTS.md gilt.

Kategorien: STATIC (Syntax/Lint/Config ohne Lauf) · UNIT-LIKE (lokal, nur
`/tmp`, echte Artefakte wie `gzip`) · TEMPORARY LOCAL REPRO (isolierte
Repro-Skripte, `/tmp` only, gefahrlos) · VM (isolierte Test-VM, Snapshot-
pflicht) · INTEGRATION (Zusammenspiel Caddy/TLS/App) · RECOVERY (Backup/
Restore, defekte Dumps) · DESTRUCTIVE (Snapshot + Revert zwingend, nie
Produktion).

Pflichtmatrix für die 17 geforderten Gegenstände:

| Gegenstand | Kategorie | Test | Bestehenskriterium |
|---|---|---|---|
| PostgreSQL-Dump > 1 MB | UNIT-LIKE + VM (T-071b neu) | Headercheck gegen Fixture > 1 MB unkomprimiert + echten `backup.sh`-Lauf | groß → OK, leer/Fehlertext → Fail ohne Finaldatei |
| SIGPIPE / pipefail | TEMPORARY LOCAL REPRO | exakte v2-Pipeline unter `pipefail`, `PIPESTATUS`-Protokoll (141-Nachweis) | nach Fix kein 141-Urteil mehr |
| TLS SNI | TEMPORARY LOCAL REPRO + VM | lokaler TLS-Server mit SNI-Auswahl (Caddy-äquivalent) + B-021-Handshake-Serie auf Testdomain | SNI-Mechanik belegt, `--resolve` grün |
| `--resolve` | VM + INTEGRATION | kanonische Probe an allen 3 Stellen (Update, Boot, Schritt 10 als Referenz) | gesund → 200, Coder gestoppt → rot |
| Update Gate gesund | VM + INTEGRATION (T-090) | Update auf gesundem Stack | Gate grün + `HEALTH_CODE=200`-Protokoll |
| Update Gate krank | VM + INTEGRATION (T-091/T-050) | Bad-`CODER_VERSION` / gestoppter Coder | Gate rot, Exit 1 mit Hinweis |
| Boot Gate gesund | VM + INTEGRATION (T-110) | gesunder Boot | `BOOT-GATE GRÜN` im laufenden Log (nicht kumulativ) |
| Boot Gate krank (Negativprobe) | VM + INTEGRATION (T-110-rot) | kranker Boot (Postgres gestoppt / Coder gestoppt, abhängiger Dienst nicht gesund) | `BOOT-GATE ROT` + Exit 1, Beleg im laufenden `$OUT` (nicht kumulativ) |
| Legacy `.env` Sonderzeichen | VM (B2-003) + UNIT-LIKE (Regex) | `Legacy$Pass!23`, Spaces, Quotes durch beide Gates | genau ein Weg grün, kein Pingpong |
| Drift nach Abbruch | VM (T-026 erweitert) | Abbruch nach Schritt 2 → Heilungslauf | keine Fehl-WARN für setup-eigene Residuen; Hand-Drift → WARN |
| UFW restriktive SSH-Regel | VM + UNIT-LIKE | beide `ufw status`-Formate (`22/tcp ... <ip>`, `22 ALLOW <ip>`) + Re-Run | Abbruch oder Erhalt, nie stilles Öffnen |
| Reset mit belegtem Volume | VM DESTRUCTIVE (T-102 erweitert) | Fremd-Container hält zu löschendes Volume | Abbruch vor `down`, Container laufen weiter |
| fehlerhafter Dump | VM RECOVERY (T-080 Negativ) | eine fehlerhafte `CREATE TABLE`-Zeile | Pfad A bricht rot ab (`ON_ERROR_STOP`) |
| `caddy validate` | STATIC + VM (T-004) | `caddy validate` mit gepinntem Image gegen generiertes Caddyfile | `CADDY_VALID`, Exit 0 |
| `docker compose config` | STATIC (T-003) | `config --quiet` + Dummy-Variablen + Negativprobe (Bad-YAML muss rot) | gültig grün, bad rot |
| `docker pull` / Image-Verfügbarkeit | VM (B-002-Probe) | beidseitiger Pull (`:2.36.6` muss gehen, `:v2.36.6` protokollieren) | Protokoll vor Merge, danach T-010 |
| Backup Atomicity | VM RECOVERY (T-072/T-073) | Fake-Abbruch nach N Bytes + tmpfs-voll (ENOSPC) | keine partielle Finaldatei, klarer Fehler, Temp entfernt |
| Restore (mini + voll) | VM RECOVERY (T-080–T-083) | Wegwerf-Postgres + Full-Restore nur aus Offsite + Runbook, RTO gestoppt | RTO-Zahl im Repo; defekter Dump rot |

STATIC-Gates vor jedem Merge (lokal, billig, kein VM-Zwang):
`bash -n` (T-001, auch alle 6 Heredoc-Skripte extrahiert einzeln),
ShellCheck `-S warning` (T-002, einziger bekannter Befund SC2034-Vorbestand;
`reset-passwords`-SC2154 `rc`-Trap als False Positive dokumentieren),
`compose config --quiet` (T-003), `caddy validate` (T-004-Äquivalent, Binär
via gepinntem Image), PyYAML-Parse (6 Services, `stop_grace_period`,
`127.0.0.1`-Bindungen, kein `retention.size`, `depends_on`-Semantik),
Grep-Belege (Tag-Form, kein aktives `prune`, `dropdb --if-exists`,
Runbook-Copy, UFW-Defaults, Abwesenheit `CODER_DISABLE_PATH_APPS`,
`note_drift`-Abdeckung). Harness-Selbsttest (T-007): Bad-YAML + SC-Analogon
müssen rot werden, sonst ist der Harnisch blind.

VM-Pflicht vor jeder Production-Freigabe (Phase C): Fresh Install (T-010),
Second/Third Run + Zustandsdiff (T-020), Interrupted Run (T-030–T-034),
Reboot (T-110–T-113), Backup (T-070–T-077), Restore (T-080–T-083),
Update (T-090–T-093), Rollback (T-092, exakt vs. beweglich differenziert),
Security Smoke (T-060–T-069), Caddy/TLS (B-021-Serie + T-123–T-125),
Workspace-Isolation (T-063/T-064/T-126). Kein VM-Test auf Produktion.

---

# Phase C – Test VM Gate (keine weiteren großen Refactorings davor)

Nach Phase A + B (lokal) beginnt kein großes Refactoring, bevor eine reale
Test-VM existiert. Jede weitere Iteration ohne VM bleibt Blindflug (Beweis:
B2-001/B2-002 wurden nur durch Repro, nicht durch Doku gefunden).

Test-VM-Definition:

- Image: Debian 13 (trixie) netinst, frisch; Snapshot-fähig (KVM/VirtualBox/
  Proxmox); Snapshots `clean-install` vor erstem Setup, `post-install` nach
  T-010 grün; vor jedem DESTRUCTIVE-Test Snapshot + danach Revert/Cleanup.
- Größe: 2 vCPU / 4 GB RAM / 30 GB Platte (TEST_PLAN-Referenz für
  Vergleichbarkeit). Produktionsgröße separat vermessen (D-Monitoring, siehe
  Phase D); Test-VM-Größe ist kein Produktionsmaß. Wo unbekannt: `OPEN`.
- Name: `coder-test-<datum>`; Domain für externe Tests: separate
  **Testdomain** (nie `coder.ghse-unterricht.de`, LE-Budget schonen, wenige
  Versuche/Woche).
- DNS: A + Wildcard auf Test-VM-IP (extern auflösbar); autoritative Abfrage
  dokumentiert (`dig` gegen autoritativen Server, nicht nur `getent`).
- Netz: NAT + Host-only für externe Scans (zweiter Scanner-Host für T-060/
  T-120); reversibel blockierbar (iptables/resolv.conf) für Netz-Fehlertests.
- Daten: keine Produktionsdaten, keine Produktions-Secrets; `.env`- und
  Dump-Fixtures nur synthetisch.
- Startzustand: reproduzierbar (`/root/setup-coder.sh` aus getestetem Commit,
  `chmod +x`; `git rev-parse --short HEAD` im Protokoll).
- Protokollpflicht je Test: Datum, VM-Name, Commit, Tool-Versionen
  (`shellcheck --version`, `docker --version`, `caddy version`), Exit-Codes,
  relevante Logs. „Bestanden" nur mit Artefakt.

Pflichttests vor jeder Production-Freigabe (mit Artefakt, nie Produktion):
Fresh Install · Second Run · Third Run · Interrupted Run · Reboot ·
Backup · Restore (mini + voll + defekt-negativ) · Update (gesund + krank) ·
Rollback (exakt vs. beweglich) · Security Smoke (Ports, SSH, Socket,
Rechte, Secrets-Hygiene, Logging-Limits) · Caddy/TLS (Apex + echte App-
Subdomain + zwei Fake-Subdomains, je Subject/SAN/Issuer/Ablauf + Caddy-Log,
Erst- vs. Zweit-Handshake-Latenz) · Workspace-Isolation (T-063-Selbsttest +
T-064-Allowlist-Abhakung + T-126 Pfad-vs-Subdomain).

Stop-Regel (nicht unterschiedlich interpretierbar – „offen" ist KEIN
Freigabezustand für CRITICAL/HIGH): B2-001/B2-002/B2-003, B-002-Pull-Probe,
B2-009, B-004-Inventar + T-063-Protokoll + D-Socket-Frist, B2-004,
B-008-Offsite-Probe (T-082 nur aus Offsite + Runbook, RTO als Zahl im Repo)
+ B2-005-Limit-Doku + `logrotate` für `coder-tls.log`/`coder-boot.log` +
T-125, Blocking-0-PLAN-Reparatur (dieser Plan repariert PLAN.md nicht
rückwirkend, ersetzt ihn aber als Freigabe-Basis; T-006-Gate gilt ab hier
gegen PLAN-v3) müssen grün sein, bevor irgendetwas in Richtung Produktion
bewegt wird. Für CRITICAL/HIGH sicherheits- oder recoveryrelevante
Entscheidungen (D-Socket, D-TLS, D-SSH, D-Offsite, B-008/Offsite-Recovery)
gilt: entweder geschlossene Entscheidung mit Owner + Datum/Frist + Nachweis
(Test-Protokoll), oder explizite Production-Sperre (kein Production-Lauf,
im Gate-Protokoll vermerkt). `_offen_`/`_OPEN_` ohne Owner + Frist ist bei
CRITICAL/HIGH kein gültiger Production-Freigabestatus (gilt nur für
LOW/MEDIUM mit Verfallsdatum + Ticket). Ohne geklärten Production-Offsite
(kein leerer Dauer-Default ohne Verfallsdatum + Ticket) und ohne gemessene
RTO aus echtem Restore-Test keine Production-Freigabe.

---

# Phase D – Security Decisions (keine automatische Codeänderung)

Jede Entscheidung braucht: Decision · Options · Trade-offs · Impact ·
Required test · Owner · Deadline · Status. Unbekanntes ist `OPEN` (nicht
erfunden). Code bleibt bis zur Entscheidung unverändert (kein Proxy-, kein
`ask`-, kein DOCKER-USER-, kein Key-only-Schnellschuss).

## D-Socket (Docker Socket + Workspace Isolation)

Decision: `OPEN` (Allowlist dauerhaft vs. Socket-Proxy vs. separater
Provisioning-Host).
Options: (a) Status quo + `templates/allowlist.md` + Abnahme (kein Umbau);
(b) Socket-Proxy mit API-Allowlist; (c) separater Provisioning-Host/VM.
Trade-offs: (a) keine Kosten, aber Host-Sicherheit = Coder-Fehlerfreiheit;
(b) Proxy-Pflege, Bruchrisiko Provisioner; (c) Betriebs-/Netzaufwand + Latenz.
Impact: Total-Compromise-Pfad (`.env`, Backups, Host-Persistenz) bei
Kompromittierung. Required test: B-004-Erstinventar + T-063-Selbsttest-
Protokoll + T-064-Abhakung pro Template. Owner: `OPEN`. Deadline: `OPEN`.
Status: `OPEN` (Stufe 1 sofort: Inventar nachholen; Modell mit Frist).

## D-TLS (On-Demand TLS)

Decision: `OPEN` (echter `ask` vs. DNS-01-Wildcard).
Options: (a) echter `ask`-Endpoint (Abgleich Coder-API/Allowlist);
(b) DNS-01-Wildcard (eigener Caddy-Build + Provider-Token).
Trade-offs: (a) Falsch-Negativ-Risiko für neue Apps + Betrieb; (b) Token-
Verwaltung + Build-Pflege, dafür kein On-Demand-DoS und keine 5–30-s-
Erstlatenz. Impact: Budget-DoS (50/Woche auf `ghse-unterricht.de`, geteilt)
+ Hostnamen-Abfluss (`?domain=` per Klartext-HTTP an US-Dritten). Required
test: B-021-Handshake-Serie mit gepinntem Image + T-123/T-125 (Fake-
Subdomain-Ist-Beleg, wenige Versuche/Woche). Owner: `OPEN`. Deadline:
`OPEN`. Status: `OPEN` (+ CAA `issue`/`issuewild` letsencrypt.org als Teil
der Entscheidung; B2-005-`check-tls`-Grenze bis dahin dokumentiert).

## D-SSH (öffentliches SSH + PasswordAuthentication)

Decision: `OPEN` (Key-Termin + Zweit-Zugang + Härtungsdatum).
Options: Key-only nach Zweit-Zugangs-Nachweis vs. befristeter Weiterbetrieb
mit starkem Passwort. Trade-offs: Aussperrungsrisiko vs. Brute-Force-/
Phishing-Fenster (Rate-Limit + fail2ban begrenzen Raten, nicht verteilte
Angriffe/kompromittierte Passwörter). Impact: SSH-Passwort = Host =
Docker-Admin = alle Secrets/Backups/DB. Required test: T-061 (effektive
Config vor/nach, externer Passwort-Login scheitert, Key gelingt, Ban separat;
SK-Key-Negativprobe). Owner: `OPEN`. Deadline: `OPEN`. Status: `OPEN`
(Setup bleibt warnend-grün; `ssh-harden.sh` nur mit beiden Flags +
`sshd -t` + Post-Check-Enforcement; Provisoriums-Alter wird geloggt).

## D-Firewall (DOCKER-USER)

Decision: `OPEN` (ja/nein nach Dual-Stack-Test T-060).
Options: Bindungsregel-Disziplin sofort (`ports:` nur `127.0.0.1`, Ausnahme
nur Caddy-80/443) vs. zusätzlich DOCKER-USER-Default-Deny.
Trade-offs: Disziplin ohne Durchsetzung vs. Test-/Pflegeaufwand +
Bruchrisiko Workspace-Apps/HTTP-3. Impact: stille Exposition künftiger
Dienste; `ufw status` suggeriert Schutz für Docker-Ports, wo keiner ist.
Required test: externer Scan TCP 22/80/443/9090/9100/3001 + UDP 443,
`ss -tlnp`, `iptables-save`/`nft` inkl. DOCKER-USER, Schulnetz-NAT-Abgleich;
IPv6 als Betriebs- oder Abschaltpfad deklarieren (`IPV6=yes`?). Owner:
`OPEN`. Deadline: `OPEN`. Status: `OPEN` (kein Einbau ohne Nachweis).

## D-Reboot-Fenster (automatischer Reboot)

Decision: `OPEN` (03:00 mit Schulbetrieb abstimmen + Wartungsplan).
Options: 03:00 behalten vs. neues Fenster. Trade-offs: nächtlicher Abriss
laufender Workspaces/Sessions/Übernacht-Jobs vs. Tages-Risiko. Impact:
planmäßiger Reboot ohne Gesundheitsnachweis → morgendliche Störung als
Entdeckungsmechanismus. Required test: T-110–T-113 (Boot-Log + erste
2 Min `docker logs coder`, Daemon-Restart, Grace-Probe). Owner: `OPEN`.
Deadline: `OPEN`. Status: `OPEN`.

## D-Offsite (Offsite Backup)

Decision: `OPEN` (Ziel, Verschlüsselung, Schlüsselverwahrung getrennt vom
Host, Retention, Transport-Secrets, Verfallsdatum Leer-Zustand).
Options: externes Medium/Konto (zweiter Server, Speicher, manuelle Kopie).
Trade-offs: Transport-Secrets als neue Exfiltrationsfläche; Schlüsselverlust
= Datenverlust; unverschlüsseltes Offsite = zweite schlechtere Kopie.
Impact: ohne Offsite ist Platten-/Host-Verlust Totalverlust. Required test:
T-082 (Snapshot verwerfen, nur aus Offsite + Runbook, RTO gestoppt) +
Transportfehler-Trennung (lokal grün / Transport rot). Owner: `OPEN`.
Deadline: `OPEN`. Status: `OPEN` (kein Hook mit leerem Dauer-Default;
Default leer nur mit Verfallsdatum + Ticket).

## D-Workspace-RPO (Workspace-RPO)

Decision: `OPEN` (was verspricht die Schule bei Serververlust, wem, mit
welcher RPO?).
Options: Server-Backup-Umfang erweitern (berührt laufende Container) vs.
Nutzer-Export-Pflicht (z. B. Git-Push-Pflicht mit Anleitung).
Trade-offs: Technik + Störungsrisiko vs. Disziplin + Verlust bei
Nichtbefolgung. Impact: größter realer Verlust (Schülerarbeiten) trotz
„täglichem Backup". Required test: T-083 (Datei in Workspace → Backup +
Restore → Gap heute: weg; nach Beschluss: da oder per Push-Pflicht
abgedeckt). Owner: `OPEN`. Deadline: `OPEN`. Status: `OPEN`.

## D-Update-Split + DB-Major-Updates (Datenbank-Major-Updates)

Decision: `OPEN` (`app`/`db`-Trennung + DB-Major-Prozess + Caddy-Pin).
Options: `update.sh app` (Coder/Caddy + Gate, Default) vs. `db` (Postgres
nur explizit mit verifiziertem Dump + Downgrade-Warnung); Caddy exakt vs.
Minor nach B-021-Befund.
Trade-offs: Aufschub-Effekt (aus Angst vor DB-Major kein Coder-Patch) vs.
neuer Bedienvertrag. Impact: Schema-Migrationen können Downgrades
irreversibel machen. Required test: T-093 (`app` lässt Postgres unberührt),
T-092 (Rollback exakt vs. beweglich), Major-Update inkl. dokumentiertem
Rollback in Test-VM. Owner: `OPEN`. Deadline: `OPEN`. Status: `OPEN`
(Gate ist MUST, Split als dokumentierte Folgeänderung; kein Major-Update
ohne verifizierten Dump + Versionsnotiz).

Weitere mitgeführte Entscheidungen (gleiche Tabellenform, hier nur
referenziert, Details in Phase E/F): D-Monitoring/Ressourcen (Messauftrag
Platte + `docker stats`-Woche, danach `retention.size` + `check.sh` + Leser),
D-Passwort-Reihenfolge (DB-zuerst vs. `.env`-zuerst nur per Test-VM-Beweis),
D-Caddy-Pin (exakt vs. Minor nach B-021), D-PLAN (dieser Plan ersetzt PLAN.md
als Freigabe-Basis; PLAN.md-Trunkierung wird nicht rückwirkend repariert,
sondern als Entwurf markiert).

---

# Phase E – Backup / Recovery (Datei existiert ≠ Restore-Nachweis)

## Backup-Erstellung

Umfang heute: nur Postgres-Dump (`pg_dump -U coder coder | gzip`,
`/opt/coder/backups/coder_*.sql.gz`, täglich 01:00 via `/etc/cron.d/`).
Nicht gesichert: `.env`, Compose-/Caddy-/Prometheus-Config (entstehen per
Re-Run neu), `caddy_data`/`caddy_config` (Zertifikate), `grafana_data`
(Dashboards), `prometheus_data` (15 d, verzichtbar), Workspace-Dateien
(Unterrichtsdaten!), Host-Config (UFW/fail2ban/unattended). Das ist ehrlich
zu dokumentieren, nicht zu verschweigen. `.env` nur verschlüsselt ins
Offsite (Schlüssel getrennt vom Host); kein unverschlüsseltes `.env`-Offsite.
Kein stiller Volume-Backup-Einzeiler ohne D-Workspace-RPO (konsistente Dumps
laufender Container + Secrets-Risiko).

Mechanik (nach Phase A): flock-Selbst-Lock (einziger Lock, kein äußeres
`flock` in Cron), Sekunden-Timestamp, Temp gleiche Partition + atomares `mv`,
Orphan-Sweep (eigenes Muster, > 24 h), `cron`-Paket + `enable --now` +
Abschlusscheck, absolute Pfade/`PATH`-Export (P-017), `trap EXIT` + `rm -f
TMP`. Kein Auto-Prune nach Update (B-003 bleibt entfernt).

## Backup-Verifikation (hart vs. weich, nach B2-001-Fix)

Hart (Fail, keine Finaldatei): df-Gate (500 MB als UNVERMESSEN markiert,
kein Ersatz für Monitoring), `gzip -t`, SQL-Headercheck (repariert, kein
hartes Größenlimit). Weich (Warnung + `logger`, kein Fail): 512-Byte-
Warnung + Halbierungs-Warnung (zu einer Vorwert-Vergleichs-Warnung mit
Kontext gefaltet; legitime Verkleinerung bleibt grün, P-013). Skip (Lock
belegt) = Exit 0 + Alter des letzten gültigen Backups (für `update.sh`
unterscheidbar, kein Frische-Gate ohne Leser). Warnung ohne Leser ist
Theater (C-013): beide Warnungen brauchen `check.sh`-Leser (Phase F).

## Backup-Freshness

Frische-Prüfung (`check.sh`, vollständig spezifiziert – kein pfadloses
Skript, kein neuer SNI-Fehler): Pfad `/opt/coder/check.sh`, Besitzer
`root:root`, Rechte `755`; Cron-Datei `/etc/cron.d/coder-freshness`,
Ausführungszeit täglich `01:30` (nach 01:00-Backup); nur lesend, keine
Eingriffe. Prüfungen: Alter/Größe des neuesten gültigen Backups (älter als
26 h → Exit ≠ 0) + `df` (`> 85 %` → Warnung per `logger` + Exit ≠ 0,
Schwelle bis D-Monitoring als WARN/UNVERMESSEN, kein Alertmanager) +
`/healthz`-Status via kanonischer SNI-korrekter `--resolve`-Probe
(`--resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz"`,
Domain als SNI, `--max-time 10` – dieselbe Strategie wie das korrigierte
Update-Gate, nirgends SNI `127.0.0.1`); eine Zeile ins Backup-Log
`/var/log/coder-backup.log` (rotiert via vorhandener `logrotate`, kein
neues unrotiertes Log). Leser/Eigentümer: morgendlicher Operator-Check.
Exit-Code: `0` nur wenn alle drei Prüfungen grün, sonst `≠ 0`. Kein
Alertmanager in dieser Runde (Überbau; Schwellen erst nach Messung,
D-Monitoring). `logrotate` für `coder-backup.log` vorhanden; für
`coder-boot.log`/`coder-tls.log` nachziehen (B2-005-Nebenpunkt).

## Restore (Pfad A/B + Verifikation)

Pfad A (Dump + originale `.env`): Setup auf frischer VM → `stop coder` →
originale `.env` zurück (`cp -a`, `chmod 600`, `chown root:root`) → Dump
via `dropdb --if-exists`/`createdb` + `zcat coder_<TS>.sql.gz | sudo docker
exec -i coder-postgres psql -v ON_ERROR_STOP=1 -U coder -d coder`
(B2-009-Fix, Flag-Position exakt, Abbruch vor `up -d`) → `up -d` →
Postgres healthy → Datensicht-Verifikation (Liveness `/healthz` + konkrete
Datenprobe: `restore_probe`-Testzeile `RTO-PROBE-<datum>` per
`SELECT count(*) ...` = 1 + Dashboard-Login zeigt Test-Datensatz; leere DB
= rot) → RTO stoppen. Pfad B (nur Dump, `.env` verloren): wie A, aber DB-Rolle behält
neues Setup-Passwort (`pg_dump` sichert keine Rollen-Passwörter, nur
`pg_dumpall --globals` täte das) – konsistent ohne Abgleich; Grafana-Passwort
neu notieren. Version-Gleichheit (Restore auf gleiche/kleinere Coder-Version;
Major-Wechsel nur einzeln mit frischem Dump). Runbook liegt per Setup auch
auf dem Server (`/opt/coder/RESTORE.md`, sonst WARN, kein Fail – B-008-Code).

## Mini-Restore / vollständiger Restore

Mini-Restore (Wegwerf-Postgres, automatisierte Pflicht, T-080, nicht nur
Runbook-Satz): wöchentlich, mit Protokoll; defekter Dump muss rot abbrechen
(T-080-Negativprobe). Vollständiger Restore (T-082): VM verwerfen, nur aus
Offsite + Runbook wiederherstellen, RTO stoppen (= Zahl + Datum + Versionen
+ Dump-Alter + Login ok in Tabelle). Wiederholung bei jedem Coder-Major und
einmal pro Semester. Nie auf Produktion.

## Offsite / RPO / RTO

Offsite: siehe D-Offsite (kein leerer Dauer-Default). RPO/RTO: keine
erfundenen Zahlen. RPO-Vorschlag erst nach D-Workspace-RPO + D-Offsite;
RTO erst als gemessene Zahl (erste echte Messung aus T-082) ins Repo, nicht
als Zielsatz. Verlusttabelle Totalverlust (DB ohne Offsite + Workspace-
Dateien + Dashboards + Zertifikats-Neuausstellung mit LE-Budget-Risiko) steht
im Runbook als unterschriebene Kenntnis, nicht als Fußnote.

## Verhalten bei vollem Datenträger

`df`-Vorabcheck bricht klar ab ohne partielle Finaldatei (`trap` räumt Temp
bei ENOSPC mitten im Stream); `logger`-Zeile (mit `|| true`-Guards an allen
reinen Signal-`logger`s, B-016); Cron-Fehlermeldung versandet nicht (Frische-
Prüfung meldet). Plattenfresser (Images, Prometheus, unrotierte Logs) sind
D-Monitoring-Sache, nicht Backup-Sache. Test: tmpfs-voll → Abbruch ohne
Finaldatei (T-073).

## Verhalten bei beschädigtem Dump

`gzip -t` rot oder Header-Fail → keine Finaldatei, Exit 1, `logger`; Rotation
zählt nur Verifiziertes (Mindestbestand: bei ≤ 14 keine Löschung, kein
Totalverlust nach Lücken); defekter Dump im Restore → Pfad A bricht per
`ON_ERROR_STOP` hart ab statt grün durchzulaufen. Test: Fake-Abbruch nach N
Bytes → `before == after` (T-072); defekter Restore-Dump → rot (T-080 neg).

---

# Phase F – Complexity Reduction (keine Zeilenzahl als Ziel)

Ziel: weniger echte Duplikate, weniger divergierende Kopien, weniger unnötige
Parser, weniger redundante Prozessaufrufe, weniger Kommentar-Drift, klare
Verantwortlichkeiten. Jede Vereinfachung nennt entfernte Duplikation +
Test; jede nicht durchgeführte Vereinfachung nennt den Grund (Do-Not-
Simplify). Reihenfolge = Wirkung pro geänderter Zeile (07-Analyse).

- **C-001** (doppelte Container-Running-Schleife `reset-passwords.sh`
  Z.1216–1221 + Z.1243–1248): lokale Funktion `require_containers`, zweimal
  aufrufen. Beide Prüfzeitpunkte + harter Abbruch bleiben. Test T-033-
  Äquivalent. Aufwand trivial, nach Phase A.
- **C-003** (Apex-Parser `awk` identisch Boot Z.765 / Update Z.1115):
  Entscheidung Variante A (Minimalvariante, festgeschrieben – keine
  `.domain`-Datei): Apex-Parser zunächst beibehalten, doppelte Logik nur
  sauber dokumentieren (Sync-Kommentar „mit Z.765/1115 synchron halten"),
  solange es bei zwei Verwendern bleibt (Complexity-Regel 1: Helfer erst
  ab drittem Verwender; Heredoc-/Laufzeitgrenzen schlagen DRY). Begründung:
  eine neue State-Datei für zwei Verwender erzeugt stale-Source-Risiko
  (`.domain` vs. live-Caddyfile bei Hand-Drift → Gates prüfen falsche
  Domain), ohne ausreichenden Nutzen. Keine `.domain`-Datei in dieser
  Runde. Falls künftig dennoch `.domain` (erst bei drittem Parser):
  Quelle = `${DOMAIN_CODER}`, Schreibzeitpunkt = deterministisch in
  Schritt 2, Rechte 644/root, Driftprüfung = als 16. Datei im Hashstore,
  Missing-File = WARN-Fallback auf Live-`awk`, Domain-Wechsel =
  Rewrite bei Env-Override, Hand-Edit der Caddyfile = WARN (nie falsches
  Grün); Tests: Spacing-Change + Domain-Wechsel + gelöschte Datei +
  hand-editierte Caddyfile. WARN-statt-Fail bei fehlender/unparsbarer
  Domain bleibt. Test (Variante A): Caddyfile-Spacing ändern → beide
  Gates finden Apex oder melden WARN, nie falsches Grün.
- **C-004** (drei `/healthz`-Proben, divergierende SNI-Semantik): Drei-Fall-
  Spec aus B2-002 wörtlich (Schritt 10 echter DNS+SNI 10 s als Referenz
  unverändert; Update `--resolve` 60 s single-shot; Boot `--resolve`
  `--max-time 10` in 30×10-Loop); überall SNI = Domain. Kein Helper über
  Heredoc-Grenzen. Test T-090/T-091/T-110 + Caddy-Log-Grep. Höchste
  Wirkung, Bedingung Handshake-Test.
- **C-005** (`.env`-Gates doppelt Setup Z.241–253 / Reset Z.1202–1214):
  Regex-Paare + Reparaturweg synchronisieren; Reset-Meldung darf nicht auf
  Reset verweisen (B2-003-Fix). Fail-closed + P-011 bleiben. Test
  Hex-Migration. Text-Drift ist bereits eingetreten – wird mit B2-003
  zusammen gefixt, nicht separat.
- **C-007** (`ufw status` ×8, `sshd -T` ×4 statt Snapshots): je ein Snapshot
  (`UFW_OUT`, `SSHD_OUT`), alle Prüfungen per `grep -q <<<"$OUT"`. Alle
  Einzelaussagen + Reparaturhinweise bleiben (C-014 gilt: keine Prüfung
  streichen, nur Datenquelle cachen). Test: SUMMARY-diff vor/nach leer.
  Rein lesend, kein VM-Zwang.
- **C-010** (Kommentarlast ~30 %, 94 B-/P-/F-Referenzen): inkrementelle Diät
  bei jeder berührten Stelle (behalten: Warum, verworfene Alternative,
  Betriebsfolge, offene Entscheidung mit Frist; kürzen: Code-Paraphrase,
  Historien-Stempel ohne Entscheidungsgehalt; B-/P-/F-Nummern nur bei
  offener Entscheidung). Kein Big-Bang. Diff muss reine Kommentar-`-`-Zeilen
  zeigen + `bash -n`/ShellCheck grün. Alle Warnungen mit Betriebsfolge
  (LE-Budget, Prune-Verbot, DB-Fenster, Bindungsregel, SSH-Provisorium mit
  Datum, Wildcard-Pflicht) bleiben.
- **C-011** (Drift 16 Messstellen, ein Commit-Ort): siehe B2-007-Fix (Hash an
  Schreibstelle, Schritt-10-Schleife löschen). Kein zusätzlicher Fix.
- **C-013** (Backup-Verifikation 5 Schichten, 1 defekt, 2 blind, 1 stumm):
  siehe B2-001-Fix + Warnungs-Faltung (eine Vorwert-Vergleichs-Warnung mit
  Kontext, eine Logger-Zeile) + Skip-Alter an `update.sh` durchreichen +
  Mini-Restore als einzigen hinreichenden Nachweis. Kein harter Größen-Fail
  ohne Restore-Beweis. Test T-071b/T-072/T-080.
- **C-002/C-006/C-008/C-009/C-014** (bewusst keine Änderung): dreifache
  Postgres-Waits nur Timeout als Variable benennen (C-002); drei atomare
  `.env`-Varianten nicht abstrahieren (Heredoc-/Laufzeitgrenze, C-006);
  Crontab-Duplikat behalten (YAGNI-Grenze ab dritter Verwendung, C-008);
  `retry3` vs. Hand-Retry nicht vereinheitlichen (Laufzeitgrenze, C-009);
  Schritt-10-Liste nicht falten (Negativ-Befund: jede Prüfung hat eigenen
  Fehlerfall + Reparaturweg, C-014). Nur C-007-Snapshots anwenden.

## C-012 separat: Soll der Monolith aufgeteilt werden?

Bewertung (kein Automatismus, keine Stilentscheidung):

| Kriterium | A. Monolith behalten | B. Repo-Dateien + Installer | C. teilweise Aufteilung |
|---|---|---|---|
| Sicherheit | keine Escaping-Migration (`<<EOF` vs `<<'EOF'`, Z.224/294/469 DOMÄNEN-Expansion!), keine neuen Pfad-/Sourcing-Risiken | höchstes Migrationsrisiko (Escaping-Fehler → falsche Secrets/URLs auf Produktion) | mittleres Risiko |
| Testbarkeit | Heredoc-Inhalt nicht isoliert lintbar (ShellCheck läuft nicht im Normal-Setup) | `compose config`/`caddy validate`/ShellCheck in CI gegen jeden Commit prüfbar | nur für ausgelagerte Teile |
| Reviewbarkeit | 1616 Zeilen überschreiten Arbeitsgedächtnis; jede Iteration liest alles neu (Mitursache 16.000-Zeilen-Reviews) | Config-Diffs als reine Config-Diffs lesbar, Drift per `diff tmpl vs. Host` sichtbar | gemischt |
| Handover | Ein-Datei-Artefakt + ein Befehl (passt zu Schulserver ohne Paketierung) | mehr Dateien + Generierungs-Test (Hash-Vergleich) als neue Pflicht | gemischt |
| Escaping | Status quo bewährt (P-010-Falle bekannt) | Byte-Vergleich Pflicht (`diff <(alt) <(neu)` bei Defaults), sonst Privilegien-/Secret-Bruch | wie B für ausgelagerte Teile |
| Idempotenz | deterministische Regeneration + attentatsichere Idempotenz bewährt | Retest aller Zweitlauf-Pfade nötig (`.env`, GID, Crontab, Caddy-Restart, Drift) | wie B |
| Komplexität | zementiert C-001/C-002/C-003/C-009-Duplikate (Heredoc-Grenze) | entfernt Duplikat-Ursache, kostet Lib-/Pfad-Komplexität (`lib.sh`-Sourcing) | Kompromiss ohne klaren Schnitt |
| Betriebsrisiko | kein akuter Ausfall wird durch Aufteilung verhindert (K6-Lehre) | voreiliger Auszug = Hoch-Risiko (Escaping + Idempotenz + Drift gleichzeitig) | wie B abgeschwächt |

Entscheidung: **A bis auf Weiteres, mit Budget-Regel.** Auszug erst, wenn
(a) `tests/` auf VM läuft und (b) drei Stellen denselben Helper brauchen
(C-006/C-009 sind die Kandidaten). Dann: `lib.sh` + Einzeldateien +
Byte-Vergleich generiert-vs-Repo + volle T-Matrix auf Test-VM. Wenn
Aufteilung geplant wird: eigene Phase, niemals nebenbei in derselben
Änderung wie ein kritischer Fix (Regel 6 unten). Bis dahin Monolith behalten;
C-001/C-003/C-004/C-005/C-007/C-011/C-013 werden innerhalb des Monolithen
gefixt (kein Helper über Heredoc-Grenzen, nur identischer Code + Verweis-
Kommentar; C-003 ohne `.domain`-Datei, siehe Variante A oben).

---

# Phase G – Dokumentation (Ist-Zustand, keine Hypothesen als Tatsache)

Reviews bleiben Referenzmaterial, werden nicht zum Operator-Handbuch.
Jede Operator-Aussage beschreibt den freigegebenen Ist-Zustand (nach Phase
A + B + VM-Beleg); ungeprüfte Eigenschaften stehen als `OPEN`/WARN-Box,
nie als Tatsache.

- **README.md** (neu, ~150–250 Zeilen): Was/Wofür (3 Sätze) + Status-Box
  (freigegebener Commit, bekannte Sperren B2-001/B2-002/B2-003, Test-Status
  0/X, RTO `_offen_` bis Messung) + Architektur-Kurzbild (Host vs.
  Container, Ports, Volumes, Ablageorte) + Voraussetzungen-Checkliste mit
  kopierbaren Befehlen + Installation in 5 Zeilen (Erfolg = Exit 0 + 0×
  `[FEHLER]`, zulässige WARNs mit Wiedervorlage Re-Run) + je 3-Zeilen-
  Verweis auf OPERATIONS/SECURITY/RESTORE/CHANGELOG + Entscheidungs-Tabelle
  (1 Zeile je D-Punkt, `_offen_`-Zahl) + Doku-Landkarte.
- **docs/OPERATIONS.md** (neu, ~300–500 Zeilen): generierte-Dateien-Tabelle
  (Quelle → Zielpfad → Regenerationsregel + Drift-WARN + Prüfbefehl) +
  Variablen-Tabelle + Secrets-Verfahren (Erstausgabe, `.env.bak`-eine-
  Generation, Rotation nur via `reset-passwords.sh`) + Start/Stop/Status/
  Logs/Healthchecks je Komponente (4-Zeilen-Karte + Tunnel-Beispiel
  `ssh -L 3001:127.0.0.1:3001 -L 9090:127.0.0.1:9090`) + Wartung je Verfahren
  (Befehl, Pre-Check, Gate-Erwartung, Rollback-Zweig exakt-Pin vs. Re-Pull
  vs. Restore) + Monitoring/Logs/Grafana (Zugänge, Log-Tabelle Pfad →
  Rotation → Leser, Freshness-Check) + Backup-Steckbrief (Zeit/Ort/Retention/
  Verifikation/Lock/Orphan-Sweep/Log) + Troubleshooting-Tabelle für die 11
  Fehler (Symptom → Befehl → Gesund- vs. Krank-Output → Verweis; B2-001/
  B2-002/B2-009 als WARN-Box bis Fix) + Test-Status + Pflicht-Tests vor
  Freigabe.
- **docs/SECURITY.md** (neu, ~150–250 Zeilen): Ist-Tabelle je Grenze (SSH,
  UFW/Docker, Socket/Templates, TLS, Images, Secrets, Backups, öffentliche
  Dienste) mit aktuellem Zustand + Risiko (1 Satz) + Nachweisbefehl
  (`sshd -T`, `ufw status verbose`, `docker inspect … Mounts/GroupAdd`,
  `nmap`, Caddy-`obtaining certificate`-Zählung, Template-`grep`) +
  Provisorien als solche (SSH-Passwort weltweit, Offsite leer, `ask`
  immer-200) mit Eigentümer + Frist + Template-Allowlist-Verweis
  (Erstinventar + T-063) + Scan-Nachweise + Rotations-Regel.
- **docs/RESTORE.md** (`RESTORE.md` erweitern, ~80–150 Zeilen, schlank):
  behalten (Was-gesichert/was-nicht, Pfad A/B, Migrationen, RTO-Tabelle);
  hinzufügen: State-Inventar-Tabelle, Verlusttabelle Totalverlust,
  `psql -v ON_ERROR_STOP=1` + Datensicht-Verifikation (B2-009), `.env`-
  Rückspielung, Versions-Gleichheits-Regel, erste echte RTO-Messung.
  Kein allgemeiner Betriebs-/Security-Inhalt (nur Verweise).
- **docs/TROUBLESHOOTING.md** (neu, Pointer-Datei für Druck/Notfall):
  enthält ausschließlich Pointer/Navigation auf OPERATIONS.md, keine
  duplizierte Fehler→Befehl-Tabelle (Single Source: OPERATIONS.md –
  jetzt entschieden, nicht an den Implementierer delegiert; verifiziert
  per `grep`-Guard „Tabelle in genau einer Datei").
- **CHANGELOG.md** (neu, append-only): je Eintrag Datum, Commit,
  Komponenten-Versionen, Pre-Backup-Datei, Gate-Ergebnis, RTO/Login,
  Operator, geschlossene D-Punkte; Sperrvermerke (B2-001/B2-002/B2-003) +
  Freigaben. Keine Essays, keine Review-Duplikate.

Verifikation je Datei: `test -f` + `grep`-Stichwort (`Architektur|
Voraussetzung|Installation|Betrieb|Restore`, `generated-hashes`,
`docker logs|journalctl|/var/log`, D-Tabelle mit `_offen_`-Zählung);
`tail -5 CHANGELOG.md` zeigt letzten Update-Eintrag. Handover-Checkliste
(Punkte 1–6 des Documentation/Handover-Reviews aus 08: Zugang/Bestand,
Voraussetzungen-Gate, Gesundheit lesend, Backup/Restore-Kern, Wartung erst
nach 1–4, Entscheidungen/Doku – D-001 bis D-015 sind Dokumentationsbefunde,
NICHT die Checkliste) wird aus OPERATIONS verlinkt, nicht dupliziert.

---

# Phase H – Generierte Dateien (Heredoc vs. Repository-Dateien)

Vollständige Host-Dateiliste (alle 15 überwachten + Laufzeit-Dateien):
`docker-compose.yml`, `Caddyfile`, `prometheus.yml`, `backup.sh`,
`update.sh`, `reset-passwords.sh`, `reset-coder.sh`, `boot-check.sh`,
`check-tls.sh`, `jail.local`, `52-coder-reboot`, Cron-Dateien
(`coder-backup`, `coder-bootcheck`, `coder-tlscheck`),
`logrotate`-Konfiguration (`coder-backup`), `ssh-harden.sh` (bereits
Repo-Datei, Referenz für Stil).

Entscheidung je Datei: `docker-compose.yml`, `Caddyfile`, `prometheus.yml`,
`backup.sh`, `update.sh`, `reset-passwords.sh`, `reset-coder.sh`,
`boot-check.sh`, `check-tls.sh` = Repo-Kandidaten für Phase B (eigener
Migrationsschritt je Datei + Regressionstests); `jail.local`,
`52-coder-reboot`, alle 3 Cron-Dateien, `logrotate`-Konfiguration = bleiben
bis zur Budget-Reife Heredoc – Begründung: kleine, rechte-sensitive
Host-Config mit eigenem Idempotenz-/Rechte-Retest pro Datei, kein akuter
Ausfall wird durch ihren Auszug verhindert; voreiliger Auszug riskiert
Escaping-/Rechte-Bruch für Review-Komfort.

Bewertung (keine Stilentscheidung, mit C-012- und D-002-Anteil):

- **A. weiterhin als Heredoc:** kein Migrationsrisiko (Escaping, Pfade,
  Rechte, Idempotenz bleiben bewährt); Ein-Befehl-Deployment bleibt;
  Preis: keine CI-Prüfbarkeit, Drift nur via Hashstore, Review im
  Heredoc-Kontext, C-001/C-003/C-009-Duplikate bleiben zementiert.
- **B. als versionierte Repository-Dateien:** `compose config`/`caddy
  validate`/ShellCheck in CI gegen jeden Commit; Drift per `diff tmpl vs.
  Host` sichtbar; Preis: Escaping-Migration (`\$` vs. `$`, `<<EOF` mit
  Domain-Expansion vs. `<<'EOF'` ohne) mit eigenem Fehlerrisiko für Secrets/
  URLs; Idempotenz-/Rechte-/Sourcing-Pfad muss neu bewiesen werden.

Entscheidung: **A bis zur C-012-Budget-Reife, dann B als eigene Phase.**
Budget-Trigger (nachvollziehbar, kein reines DRY): `tests/` auf VM grün UND
ein dritter echter Standalone-Runtime-Verwender desselben Helper-Verhaltens
(C-006/C-009-Präzedenzfälle – drei `.env`-Varianten, zwei Retries – sind
ausdrücklich ausgenommen und lösen `lib.sh` NICHT aus; bis dahin kein
`lib.sh`). Begründung: kein akuter Ausfall wird durch B verhindert;
voreiliges B riskiert Secret-/URL-Bruch auf Produktion für Review-Komfort.
Bis dahin: Ablageprinzip in README + OPERATIONS dokumentieren (Tabelle
Quelle-Zeilenbereich → Zielpfad → „deterministisch regeneriert,
Hand-Anpassung wird überschrieben (Drift-WARN via `.generated-hashes`)" →
Prüfbefehl `compose config --quiet`/`caddy validate`/`bash -n`).

Wenn B (eigene Phase, nie neben kritischem Fix): Migration mit
Byte-/Output-Vergleich (`diff <(alt-generiert) <(neu-generiert)` bei
Default-Variablen muss leer sein) + Regressionstests (volle T-Matrix auf
Test-VM, insbesondere T-020/T-026/T-003/T-004/T-002, Idempotenz- und
Drift-Nachweise, Caddy-nur-bei-Änderung, fail2ban-Bans bleiben). Erst nach
grünem Vergleich wird umgestellt; Hashstore-Format und 600-Modus bleiben.

---

# Komplexitätsregeln (C-001–C-015 übernommen, verschärft)

1. Keine neue Abstraktion ohne entfernte echte Duplikation (Helfer erst ab
   drittem Verwender; Heredoc-/Laufzeitgrenzen schlagen DRY – C-006/C-008/
   C-009-Präzedenz).
2. Keine neue Prüfung ohne konkretes Fehler-/Angriffsszenario (jede
   `ok`/`warn`/`fail`-Zeile nennt Reparaturanleitung; Prüfung ohne
   Fehlerfall-Namen wird abgelehnt – C-014-Standard).
3. Keine Warnung ohne Leser und Reparaturpfad (neue WARN/Logger-Zeilen
   brauchen benannten Leser – sonst B-010-Theater, C-013-Lehre).
4. Keine neue Komplexität ohne Test (neue `exit 1`-Pfade brauchen
   Fixture-Beweis gegen False-Positive; Kleinst-Fixtures lügen –
   T-071b-Maßstab > 1 MB, P-013-Lehre).
5. Keine Entfernung einer Sicherheitsbarriere ohne funktional gleichwertigen
   Ersatz (Fail-closed-Gates, atomare Writes, Locking, Allowlist-Guards,
   `--force`-Zweitphrase, TTY-Guard, `CODER_DISABLE_PATH_APPS`-Zurückhaltung
   und DOCKER-USER-Zurückhaltung bis Nachweis – siehe Do-Not-Simplify).
6. Kein großes Refactoring gleichzeitig mit einem kritischen Fix (C-012-
   Auszug, App/DB-Split, `jail.d`-Migration, Alertmanager, Digest-Umstellung
   je eigene Phase nach Phase A + B).
7. Keine Zielvorgabe „weniger Zeilen" ohne funktionale Begründung
   (Kommentar-Diät nur inkrementell bei berührten Stellen; Schritt-10-Liste,
   Timeouts, Retention-Mindestbestand und Warnungen mit Betriebsfolge werden
   nicht für Zahl gefaltet).

Do-Not-Simplify (bleibt, Begründung je Punkt in 07-Analyse): Fail-closed-
`.env`-Gates; `.env`-Erstellung nur bei Fehlen; Backup-Lock + `mv` +
`gzip -t` + Mindestbestand; Reset-Guards (Label-Filter + Allowlist + Leer-
Guard + Pre-Check + Zweitphrase + TTY); kein Auto-Prune; `DISABLE_PATH_APPS`
und DOCKER-USER weiter abwesend bis Nachweis; SSH WARN statt FAIL;
Schritt-10-Einzelaussagen; drei Timeouts; kein geratenes `retention.size`,
kein App/DB-Split ohne Entscheidung.

---

# Dokumentationsqualität (Gates, kein Wunsch)

Jede Behauptung braucht Beleg (Code-Zeile, Log, Scan, Datum) oder ist als
Annahme/`OPEN` gekennzeichnet. Keine hypothetische oder ungeprüfte
Eigenschaft als Tatsache (insbesondere: kein „TLS Modell X schützt",
kein „Backup Y ist verifiziert", kein „Test Z bestanden" ohne Artefakt).
Kommentare im Code nennen Warum / verworfene Alternative / Betriebsfolge /
offene Entscheidung mit Frist; Code-Paraphrase und Historien-Stempel ohne
Entscheidungsgehalt werden bei Berührung gekürzt (C-010). B-/P-/F-Nummern im
Code nur bei offener Entscheidung (D-TLS, D-Socket, D-SSH), nicht als
Vergangenheits-Stempel. Jede neue WARN braucht Leser + Reparaturpfad
(C-013/C-014). Reviews bleiben mit Evidenz-Standard (CONFIRMED/LIKELY-
Trennung, Repro-Pflicht) Referenz; nächste Review-Runde erst als Delta zu
FINAL-BREAKER-v2 nach T-071b + Handshake + Hex-Migration (C-015-
Moratorium: Test-VM + 3 Kern-Tests zuerst, kein Voll-Re-Review ohne
Ausführungs-Anteil). Meta-Test: `ls tests/` nicht-leer + ein datierter
VM-Protokoll-Eintrag (RTO-Zahl) vor dem nächsten Review.

---

# Reihenfolge und Definition of Done

0. Dieser Plan (PLAN-v3) ist Freigabe-Basis (ersetzt die abgebrochene
   PLAN.md als Referenz; PLAN.md selbst wird als Entwurf markiert, nicht
   rückwirkend umgeschrieben).
1. Phase A in 8 Commits in Abhängigkeitsreihenfolge (keine Sammelzeile):
   Commit 1 B2-001 → Commit 2 B2-002 → Commit 3 B2-003 → Commit 4 B2-006 →
   Commit 5 B2-007 → Commit 6 B2-004 → Commit 7 B2-008 → Commit 8 B2-009;
   je Commit genau ein B2-Fix + je ein lokales STATIC/UNIT-LIKE-Artefakt
   (Datum, Commit, Exit-Codes) vor dem nächsten Commit – ein nachfolgender
   Fix darf einen Fehler eines vorherigen Fixes nicht verdecken (z. B.
   B2-007-Fehl-WARNs dürfen B2-004-Verifikation nicht übertönen).
   Merge-Gate: T-071b + Handshake + Hex-Migration zuerst, dann Rest.
2. Phase B (T-071b + Handshake + Hex-Migration zuerst – sie fangen B2-001–
   003; danach Restmatrix) auf Test-VM mit Artefakt.
3. Phase C (VM-Gate grün) vor jedem Produktionsgedanken.
4. Phase D (Entscheidungen mit Eigentümer/Frist parallel einholen, nicht
   raten) + Phase E (Offsite-Probe + RTO-Zahl + Mini-Restore-Pflicht).
5. Phase F (C-004/C-013/C-005/C-011 zuerst – Wirkung zuerst) + Phase G/H
   (Doku + Generierungs-Entscheidung als eigene Phasen).

Done erst, wenn: alle MUST_FIX-Änderungen (Phase A + Blocking-A-Anteile)
mit mindestens einem Test bestanden (Artefakt auf Test-VM); Static Gates
(T-001/T-002/T-003/T-004/T-007) grün; Phase-C-VM-Gate vollständig grün
(Fresh Install, Second Run, Third Run, Interrupted Run, Reboot, Backup,
Restore, Update, Rollback, Security Smoke, Caddy/TLS, Workspace-Isolation –
je mit Artefakt Datum/VM/Commit/Tool-Versionen/Exit-Codes/Logs, nie
Produktion); Phase-G-Dokumentationsgates grün (`test -f` je Datei +
Stichwort-Greps + `_offen_`-Zählung + `tail -5 CHANGELOG.md` +
`ls tests/` nicht-leer + datierter VM-Protokoll-Eintrag mit RTO-Zahl,
C-015-Meta-Test); alle D-Entscheidungen mit Eigentümer + Datum/Frist –
`_offen_` genügt nur für LOW/MEDIUM mit Verfallsdatum + Ticket, für
CRITICAL/HIGH (D-Socket, D-TLS, D-SSH, D-Offsite, B-008) ist `_offen_`
kein Freigabestatus (siehe Stop-Regel: geschlossene Entscheidung oder
explizite Production-Sperre); RTO als gemessene Zahl + Offsite-Probe grün;
Erstinventar + T-063-Protokoll + B-021-Handshake-Nachweis im Repo; keine
Änderung ohne Test; kein Test „bestanden" ohne Artefakt; keine
Produktivserver-Befehle in dieser Runde; bekannte Restrisiken (UFW-Umgehung
als Doku, Socket als übernommene Tutorial-Architektur, Provisorien mit
Verfallsdatum) mit Eigentümer + Frist im Repo.

Ausdrücklich kein großes Refactoring in dieser Runde (kein Proxy-Einbau,
keine Timer-/Template-Migration, kein Alertmanager, keine Digest-Umstellung,
kein Monolith-Auszug, kein App/DB-Split als Default-Änderung ohne Beschluss).
Der belastbarste nächste Stand entsteht aus kleinen gezielten Fixes +
belegten Tests, nicht aus Umbauten.

---

# Plan Validation Requirements

* `ai-review/PLAN-v3-REVIEW.md` ist vollständig berücksichtigt – kein
  PV-001 bis PV-015 bleibt ohne Begründung offen.
* BLOCKER (PV-002 Secret-Strategie, PV-004 Production-Stop/B-008) und alle
  MUST_FIX (PV-003, PV-005) sind geschlossen.
* Alle Änderungen sind testbar (je B2-Fix mindestens ein Test mit Artefakt;
  neue `exit 1`-Pfade mit Positiv-/Negativ-Fixtures).
* Keine Architekturentscheidung ist an den Implementierer delegiert
  (Secret-Variante, `.domain` vs. Kommentar, H-Scope, TROUBLESHOOTING-Quelle,
  TEST_PLAN-Source-of-Truth, Bypass-Syntax – alle oben entschieden).
