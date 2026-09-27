# 07-complexity – Code-Qualität, Simplifizierung, Maintainability

Stand: 2026-09-27. Geprüft am HEAD: `setup-coder.sh` (~1616 Zeilen),
`ssh-harden.sh` (80 Zeilen), `RESTORE.md` (68 Zeilen),
`templates/allowlist.md` (34 Zeilen), `tests/` (leer),
`ai-review/PLAN.md`, `PLAN-REVIEW.md`, `FINAL-BREAKER-REVIEW.md`,
`FINAL-BREAKER-v2.md`.

Rolle: Principal Engineer für Code-Qualität. Keine Implementierung,
keine andere Datei verändert. Ausschließlich Komplexitätsanalyse.

Messwerte (per `rg`/`wc` verifiziert, kein Handwedeln):

- `setup-coder.sh`: ~1616 Zeilen, davon ~482 Kommentarzeilen (~30 %),
  ~1019 Codezeilen, ~115 Leerzeilen.
- 16 `note_drift`-Aufrufe, 22 `sudo tee`-Schreibstellen, 16 eingebettete
  Heredoc-Blöcke (6 Wartungsskripte + Configs + Cron/logrotate).
- 12 `docker inspect`-Stellen, 9 `ufw status`-Aufrufe (8 prüfend),
  94 B-/P-/F-Referenzen im Code.
- `ai-review/`: ~16.000 Zeilen Review-Doku vs. ~1.700 Zeilen
  produktiver Code; `tests/` leer, `TEST_PLAN.md` 2735 Zeilen ungeprüft.

Vorab-Urteil: Das Projekt ist **nicht** unnötig komplex im
sicherheitskritischen Kern (Fail-closed-Gates, atomare Writes, Locking
sind bewusst und bleiben). Es ist aber **messbar redundant** an den
Rändern: doppelte Prüfschleifen, dreifache Healthcheck-Varianten ohne
gemeinsame Semantik, doppelte Regex-Gates, Kommentarlast mit Drift-Risiko
und ein Review-Apparat, der ein Vielfaches des Codes beträgt, ohne dass
ein einziger VM-Test je lief.

---

## C-001 – Doppelte Container-Running-Schleife in reset-passwords.sh

Type:
DUPLICATION

Severity:
MEDIUM

Location:
`setup-coder.sh` Z. 1216–1221 und Z. 1243–1248 (eingebettetes
`reset-passwords.sh`)

Current behavior:
Zwei wörtlich identische Schleifen prüfen `coder-postgres` und
`coder-grafana` auf `State.Running` – einmal vor dem Vorab-Backup,
einmal danach vor dem Würfeln.

Why it is complex/redundant:
Exaktes Duplikat (6 Zeilen × 2). Die zweite Prüfung ist sachlich
berechtigt (Container könnte zwischen Backup und Rotation sterben),
aber als kopierter Block statt als wiederverwendeter Check conteúa
doppelte Wartungslast: Wer Meldung oder Containerliste ändert, muss
beide Stellen treffen.

Does the current complexity provide real value?
Die zweite Prüfung ja (Zeitfenster Backup→Rotation ist real). Die
Verdopplung als Copy-Paste nein – sie schützt kein zusätzliches
Fenster gegenüber einem Funktionsaufruf.

Proposed simplification:
Im eingebetteten `reset-passwords.sh` eine lokale Funktion
`require_containers` (3 Zeilen) definieren, zweimal aufrufen.
Kein Shared-Lib-Import über Heredoc-Grenzen hinweg.

What must remain unchanged:
Beide Prüfzeitpunkte (vor Backup, vor Rotation). Harter Abbruch mit
`docker compose up -d`-Hinweis an beiden Stellen.

Security impact:
Keiner (Verfügbarkeits-Guard, kein Security-Guard).

Regression risk:
Minimal – reine Zusammenlegung, Verhalten identisch.

Test:
T-033-Äquivalent: Container stoppen → beide Aufrufstellen müssen je
hart abbrechen (vor Backup, vor Rotation).

Classification:
CONFIRMED

---

## C-002 – Dreifache Postgres-Healthy-Warteschleife

Type:
DUPLICATION

Severity:
LOW

Location:
`setup-coder.sh` Z. 1029–1032 (Setup-Backup-Test), Z. 1103–1106
(eingebettetes `update.sh`), Variante Z. 768–773 (eingebettetes
`boot-check.sh`, 30×10 s statt 30×2 s)

Current behavior:
Drei Stellen warten per `seq 1 30` + `docker inspect Health.Status`
auf Postgres-healthy, mit je eigenem Timeout (60 s, 60 s, 5 min).

Why it is complex/redundant:
Gleiche Mechanik, dreimal ausgeschrieben. Unterschiedliche Timeouts
sind beabsichtigt (Boot braucht 5 min), aber im Code nicht als
Parameter sichtbar – nur als dritte kopierte Schleife.

Does the current complexity provide real value?
Die unterschiedlichen Timeouts ja. Die dreifache Ausschreibung nein.

Proposed simplification:
Kein Shared-Helper über Heredoc-Grenzen erzwingen (siehe C-006 –
würde Lesbarkeit verschlechtern). Minimal: Timeout als benannte
Variable (`WAIT=30` / `WAIT=30` / `WAIT=30` mit eigenem `SLEEP`)
pro Schleife dokumentieren, Mechanik sonst lassen. Echte
Zusammenlegung erst, wenn Skripte aus dem Monolithen ausgezogen
werden (C-012).

What must remain unchanged:
Alle drei Wartezeitpunkte, alle drei Timeouts, Break-on-healthy.

Security impact:
Keiner.

Regression risk:
Minimal (nur Benennung, keine Logikänderung).

Test:
T-050/T-110-Äquivalent: langsamer Postgres → alle drei Pfade warten
statt falsch-rot zu melden.

Classification:
CONFIRMED (Duplikat-Fakt); LIKELY (Nutzen einer Zusammenlegung –
Heredoc-Grenze spricht dagegen, siehe C-006).

---

## C-003 – Apex-Parser per awk zweimal identisch

Type:
DUPLICATION

Severity:
LOW

Location:
`setup-coder.sh` Z. 765 (`boot-check.sh`: `DOMAIN=$(awk …)`),
Z. 1115 (`update.sh`: `GATE_DOMAIN=$(awk …)`), identisches Muster
`awk -F'[ ,{]+' '/\*.*\{/ {print $1; exit}'`

Current behavior:
Zwei eingebettete Skripte parsen die Apex-Domain aus dem Caddyfile
mit byte-identischem awk.

Why it is complex/redundant:
Ein Parser, zwei Kopien. Ändert sich das Caddyfile-Format, driften
beide auseinander – und beide haben denselben WARN-Fallback, der
perverserweise Grün-für-nicht-parsbar belohnt (B2-002-Nebeneffekt).

Does the current complexity provide real value?
Nein. Der Parser ist kein Security-Guard, sondern Adressermittlung.

Proposed simplification:
Muster einmal als Kommentar-Referenz markieren („mit Z. 765/1115
synchron halten") oder – besser – Apex als Datei
(`/opt/coder/.domain`) vom Setup schreiben lassen, beide Skripte
lesen sie. Das entfernt den Parser an beiden Stellen ersatzlos.

What must remain unchanged:
WARN-statt-Fail bei unparsbarer Domain (kein harter Abbruch im
Boot-/Update-Pfad wegen Adressermittlung).

Security impact:
Keiner (liest lokale Config, kein secret).

Regression risk:
Gering – `.domain`-Datei ist neue Quelle, muss bei Domain-Wechsel
mitgeschrieben werden (Setup schreibt sie ohnehin deterministisch).

Test:
Caddyfile-Format ändern (Spacing) → beide Gates finden Apex weiter
oder melden WARN, nie falsches Grün.

Classification:
CONFIRMED

---

## C-004 – Drei /healthz-Proben mit drei Semantiken

Type:
DUPLICATION

Severity:
MEDIUM

Location:
`setup-coder.sh` Z. 1559–1571 (Schritt 10: `curl https://DOMAIN/healthz`),
Z. 1117 (`update.sh`: Host-Header gegen 127.0.0.1),
Z. 769 (`boot-check.sh`: Host-Header gegen 127.0.0.1)

Current behavior:
Drei Healthchecks prüfen nominell dasselbe („Caddy+TlS+App grün"),
tun aber Unterschiedliches: Schritt 10 geht über echtes DNS+SNI
(korrekt), Update- und Boot-Gate setzen SNI=127.0.0.1 (B2-002:
deterministisch rot, CONFIRMED per SNI-Repro).

Why it is complex/redundant:
Duplizierte Absicht bei divergierender Mechanik – der schlimmste
Duplikat-Typ: Er sieht aus wie dreifache Absicherung, ist aber
einfache Absicherung plus zwei defekte Kopien. Jede künftige
Fixierung (z. B. `--resolve`) muss zwei Stellen treffen.

Does the current complexity provide real value?
Schritt-10-Probe ja (echter Pfad). Die beiden Host-Header-Varianten
in aktueller Form nein – sie lügen täglich (Boot) bzw. blockieren
gesunde Updates.

Proposed simplification:
Eine kanonische Probe definieren (`--resolve DOMAIN:443:127.0.0.1`
gegen `https://DOMAIN/healthz`, B2-002-Fix) und an allen drei
Stellen wörtlich dieselbe Zwei-Zeilen-Sequenz verwenden. Kein
Helper nötig – identischer Code, dreimal, mit Verweis-Kommentar.

What must remain unchanged:
Timeout-Unterschiede (10 s Schritt 10, 60 s Update-Gate für
On-Demand-Erstverzögerung, 5-min-Fenster Boot). WARN-Semantik im
Boot-Gate (lesend, kein Eingriff).

Security impact:
Positiv bei Fix: beseitigt On-Demand-Versuche für SNI=127.0.0.1
(Log-Spam + Failed-Validation-Zähler, B2-002).

Regression risk:
Mittel – SNI-Fix braucht Handshake-Test auf Test-VM (T-090/T-110),
nie per Lesung allein freigeben.

Test:
T-090 (gesund→grün, Coder gestoppt→rot), T-110 (gesunder Boot→grün),
je mit `HEALTH_CODE`-Protokoll.

Classification:
CONFIRMED

---

## C-005 – .env-Vollständigkeits- und Hex-Gates doppelt

Type:
DUPLICATION

Severity:
MEDIUM

Location:
`setup-coder.sh` Z. 241–253 (Setup: Vollständigkeit + Hex-Gate),
Z. 1202–1214 (eingebettetes `reset-passwords.sh`: Vollständigkeit +
Hex-Gate)

Current behavior:
Beide Skripte prüfen dieselben drei Schlüssel mit denselben zwei
Regex-Stufen (`[^[:space:]]+` = vollständig, `[0-9a-f]+` = Hex).
Meldungen und Reparaturverweise sind je eigen formuliert.

Why it is complex/redundant:
Vier Regex-Paare für zwei Schlüssel an zwei Orten. B2-003 zeigt die
Folge: Setup verweist auf Reset, Reset verweist auf sich selbst –
Pingpong ohne Migrationspfad. Der Text-Drift ist bereits eingetreten,
nicht nur möglich.

Does the current complexity provide real value?
Die Prüfung selbst ja (fail-closed gegen Sonderzeichen-Bruch in
ALTER USER/grafana-cli/URL, B-014). Die doppelte, textuell
divergierende Formulierung nein.

Proposed simplification:
Regex-Paare und Reparaturweg an einer Stelle im Kopf von
`setup-coder.sh` als kanonische Zeilen festhalten; Reset-Meldung
darf nicht auf Reset verweisen (B2-003-Fix: dokumentierter manueller
Migrationspfad oder lesende Alt-Passwort-Akzeptanz). Keine
Shared-Funktion über Heredoc-Grenzen.

What must remain unchanged:
Fail-closed-Semantik an beiden Stellen (Exit 1 bei Nicht-Hex).
Kein stilles Neuwürfeln bei unvollständiger `.env` (P-011).

Security impact:
Positiv bei Fix: beendet Deadlock für Legacy-`.env` (derzeit weder
Setup noch Rotation möglich – schlimmer als jede Zeilenersparnis).

Regression risk:
Mittel – Migrationspfad braucht Sonderzeichen-Fixture-Test
(`Legacy$Pass!23`, Spaces, Quotes).

Test:
Hex-Migrations-Test (B2-003): Legacy-`.env` → genau ein definierter
Weg führt zu zwei grünen Gates; Endlosschleife per Protokoll
ausgeschlossen.

Classification:
CONFIRMED

---

## C-006 – Drei atomare .env-Schreibvarianten

Type:
ABSTRACTION

Severity:
LOW

Location:
`setup-coder.sh` Z. 216–233 (Ersterstellung: mktemp+install+tee+mv),
Z. 269–278 (GID-Refresh: grep-v+tee), Z. 1290–1298 (Reset-Tausch:
grep-v+printf+mv)

Current behavior:
Drei Stellen implementieren „atomar schreiben, 600, kein 644-Fenster"
mit je leicht anderer Befehlsfolge. Alle drei sind korrekt (P-010
wurde umgesetzt: `install -m 600` vor Schreiben, kein sed-i).

Why it is complex/redundant:
Gleiche Garantie, drei Rezepte. Der naheliegende Reflex („eine
Funktion `atomic_write`") scheitert an der Heredoc-Grenze: Zwei der
drei Stellen laufen in eingebetteten Skripten zur Laufzeit auf dem
Server, die Setup-Funktion existiert dort nicht.

Does the current complexity provide real value?
Ja – jede Variante ist an ihren Kontext angepasst (Vollschreibung
vs. GID-Tausch vs. Doppel-Schlüssel-Tausch). Eine erzwungene
Shared-Lib (sourcen, Pfadabhängigkeit) wäre fragiler als drei
explizite Blöcke.

Proposed simplification:
Keine Abstraktion. Stattdessen: das Muster einmal im Skriptkopf als
kanonische 5-Zeilen-Sequenz dokumentieren („atomar: mktemp gleiche
Partition → install/chmod 600 VOR Schreiben → mv → trap"),
Abweichungen nur mit Begründung. Das ist die Stelle, an der eine
Abstraktion die Verständlichkeit verschlechtern würde (§26).

What must remain unchanged:
Alle drei Atomaritäts- und Modus-Garantien, alle Traps.

Security impact:
Keiner bei dieser Entscheidung (kein Secret-Fenster wird geöffnet).

Regression risk:
Keins (nur Kommentar-Referenz).

Test:
Kein neuer Test; bestehende 600-Nachweise (`stat -c %a`) bleiben.

Classification:
SUBJECTIVE (bewusste Nicht-Abstraktion – siehe Do-Not-Simplify).

---

## C-007 – Acht `ufw status`- und vier `sshd -T`-Aufrufe statt Snapshots

Type:
REDUNDANT_CHECK

Severity:
LOW

Location:
`setup-coder.sh` Z. 564, 646, 651, 677, 682, 687 (plus 639 verbose,
654 Fallemeldung) – je `sudo ufw status | grep -q …`; Z. 671–672 und
Z. 1600–1601 – je doppeltes `sudo sshd -T | grep -qi …`

Current behavior:
Schritt 4 ruft `ufw status` sechsmal separat auf (je ~1 s Fork +
sudo), `sshd -T` wird pro Prüfung zweimal aufgerufen (viermal
gesamt für zwei identische Fragen: Passwort-Login aus?).

Why it is complex/redundant:
Jeder Aufruf forked `sudo`+Daemon-Abfrage für eine Frage, die ein
einziger Snapshot beantwortet. Sieben identische Pipeline-Muster
(`X | grep -q Y → ok/fail`) blähen Schritt 4 auf ~45 Zeilen.

Does the current complexity provide real value?
Die Fragen selbst ja (jede Regel einzeln benannt = diagnostizierbar).
Die wiederholten Prozessaufrufe nein.

Proposed simplification:
Je ein Snapshot pro Schritt: `UFW_OUT=$(sudo ufw status)` und
`SSHD_OUT=$(sudo sshd -T 2>/dev/null)`, alle Prüfungen per
`grep -q … <<<"$UFW_OUT"`. Fragen und Meldungen bleiben Zeile für
Zeile erhalten – nur die Datenquelle wird einmal geholt.

What must remain unchanged:
Alle Einzelaussagen (active, LIMIT, 80/443/udp, fail2ban-Jail,
SSH-Passwort-Warnung + Schluss-Warnung Z. 1600–1610). Keine Prüfung
streichen, nur Caching.

Security impact:
Keiner (lesende Prüfungen, kein Policy-Wechsel).

Regression risk:
Gering – Snapshot zwischen Regel-Setzen und Prüfen holen
(Reihenfolge beachten: nach `ufw --force enable`).

Test:
Schritt 4 auf Test-VM: SUMMARY vor/nach identisch (diff der
Zusammenfassung), Laufzeit sinkt.

Classification:
CONFIRMED

---

## C-008 – Crontab-Migrations-Duplikat (zwei Stellen)

Type:
DUPLICATION

Severity:
INFO

Location:
`setup-coder.sh` Z. 963–968 (Backup-Migration) und Z. 1163–1166
(Update-Migration): `(sudo crontab -l | grep -vF X || true) | sudo
crontab -`

Current behavior:
Zwei identische Migrationsblöcke für zwei verschiedene Alt-Zeilen
(`backup.sh`, `update.sh`), je mit F-001-`|| true`-Guard und
eigenem Erklärkommentar.

Why it is complex/redundant:
Formal ein Duplikat (6 gegen 4 Zeilen). Praktisch die Grenze, an der
YAGNI „zweimal kopieren" erlaubt: Eine Helper-Funktion
`migrate_crontab_entry <muster> <label>` spart ~6 Zeilen, kostet
aber eine Abstraktion für einen Einmal-Migrationspfad, der nach
Abschluss aller Alt-Hosts nie wieder feuert.

Does the current complexity provide real value?
Der `|| true`-Guard ja (F-001, reproduzierter Still-Abbruch). Die
Verdopplung: tolerierbar, kein Sicherheits- oder Wartungsrisiko –
Altlast-Code stirbt von selbst.

Proposed simplification:
Behalten. Falls eine dritte Migration hinzukommt, dann erst Helper
einführen (Komplexitätsbudget-Regel: Abstraktion ab dritter
Verwendung). Maximal: Kommentar an zweiter Stelle auf Verweis
kürzen („Muster wie Z. 963, F-001-Guard").

What must remain unchanged:
`|| true`-Guard an beiden Stellen, kein `set -e`-Abbruch.

Security impact:
Keiner.

Regression risk:
Keins (keine Änderung empfohlen).

Test:
Bestehender F-001-Test (eine Alt-Zeile → Exit 0) deckt beide ab.

Classification:
SUBJECTIVE (bewusst keine Änderung – YAGNI-Grenze dokumentiert).

---

## C-009 – `retry3` vs. Hand-Retry in update.sh

Type:
DUPLICATION

Severity:
LOW

Location:
`setup-coder.sh` Z. 138–152 (`retry3`, Setup-Kontext mit sudo) vs.
Z. 1081–1090 (eingebettetes `update.sh`: `_pull_ok`-Schleife, ohne
sudo)

Current behavior:
Zwei Retry-Schleifen (max. 3, 10 s Schlaf, Ursachen-Log) für
apt/curl/pull – eine als Funktion, eine handgeschrieben im
eingebetteten Update-Skript.

Why it is complex/redundant:
Gleiche Policy, zwei Implementierungen. Zusammenlegung scheitert wie
bei C-006 an der Laufzeitgrenze: `update.sh` läuft standalone auf
dem Server ohne Setup-Funktionen (und bewusst mit anderem
sudo-Kontext, Z. 1067–1069).

Does the current complexity provide real value?
Die Retry-Policy ja (B-013, Schulnetz). Die Doppelimplementierung:
unvermeidbar ohne Shared-Lib – und eine Shared-Lib für einen
3-Versuche-Loop ist Overengineering.

Proposed simplification:
Keine. Höchstens Policy in einer Kopfzeile je Stelle benennen
(„Retry max. 3×10 s, B-013") statt Mechanik zu vereinheitlichen.
Bei Auszug der Skripte aus dem Monolithen (C-012) eine gemeinsame
`lib.sh` erwägen – nicht vorher.

What must remain unchanged:
Max. 3 Versuche, kein Retry um LE-Ausstellung, Ursachen-Log,
finaler Exit-Code unter `set -e`.

Security impact:
Keiner.

Regression risk:
Keins (keine Änderung empfohlen).

Classification:
LIKELY (Fakt des Duplikats CONFIRMED, Nicht-Zusammenlegbarkeit
durch Laufzeitgrenze begründet).

---

## C-010 – Kommentarlast 30 % mit Drift-Risiko

Type:
COMMENT_DRIFT

Severity:
MEDIUM

Location:
Ganzes `setup-coder.sh` (482/1616 Kommentarzeilen), 94 B-/P-/F-Referenzen;
Beispiele: doppelte Hex-Begründung (Z. 210–212 vs. Z. 1251–1252),
`tee`-644-Erklärung (Z. 220–221), Caddy-`ask`-Dreifach-Doku
(Kopf Z. 14–26 + Z. 442–462 + Z. 451-Kommentar), obsolete
F-009(a)-Referenzen; Gegenbeispiel gelungener Kürze: Z. 353
(HTTP/3-Einzeiler).

Current behavior:
Fast jeder Block trägt Historie (F-/P-/B-Nummern), Upstream-Zitate,
Mechanik-Erklärungen und ausformulierte Trade-offs. Das war während
der Review-Iterationen richtig (Nachvollziehbarkeit), ist aber im
auslieferten Skript zu einem Drittel Kommentar geworden.

Why it is complex/redundant:
Drei konkrete Kosten, alle bereits eingetreten: (1) Drift –
PLAN-REVIEW P-010 wies nach, dass ein Kommentar („umask 077
übernehmen") technisch falsch war; (2) Doppelpflege – dieselbe
Hex-Begründung steht zweimal, B2-003 zeigt divergierende
Reparaturtexte; (3) Lese-Steuer – 1616 Zeilen schrecken ab, die
eigentliche Befehlsfolge (ca. 200 Zeilen) geht unter.

Does the current complexity provide real value?
Teilweise ja: On-Demand-TLS-Warnung, Prune-Warnung, Reihenfolge-
Begründungen (DB-zuerst) und Bindungsregel sind Betriebs-Wissen,
das am Code kleben muss. Offensichtliches (`tee kürzt nur`,
`chmod 600 vor Schreiben` als Vorgangsbeschreibung ohne Warum)
und Historien-Nummern ohne Entscheidungsgehalt nein.

Proposed simplification:
Kommentar-Diät mit Regel (siehe Budget): behalten, was ein Warum,
ein Nicht-Offensichtliches oder eine verworfene Alternative nennt;
kürzen, was den Code paraphrasiert; B-/P-/F-Nummern nur dort, wo
sie auf eine noch offene Entscheidung verweisen (D-TLS, D-Socket,
D-SSH), nicht als Vergangenheits-Stempel. Kein Big-Bang –
bei jeder künftigen Änderung die berührten Kommentare mitpflegen.

What must remain unchanged:
Alle Warnungen mit Betriebsfolge (LE-Budget, Prune-Verbot,
DB-zuerst-Fenster, Bindungsregel, SSH-Provisorium mit Datum,
Wildcard-Pflicht). Kein Informationsverlust bei sicherheits- oder
betriebsrelevanten Hinweisen.

Security impact:
Indirekt positiv: weniger Drift → weniger falsche Sicherheit
(P-010-Lehre). Kein direkter Security-Effekt.

Regression risk:
Gering – nur Text; jede Kürzung im Diff reviewbar.

Test:
`bash -n` + ShellCheck nach jeder Kommentar-Editierung (kein
Verhalten darf sich ändern – Diff muss reine `-`-Zeilen in
Kommentaren zeigen); Verweis-Check: jede verbleibende D-Referenz
löst auf eine existierende Entscheidung auf.

Classification:
SUBJECTIVE (Stil-Urteil), gestützt auf CONFIRMED-Fakten
(Zeilenanteile, P-010-Driftfall, B2-003-Textdrift).

---

## C-011 – Drift-System: 16 Messstellen, ein Commit-Ort

Type:
REDUNDANT_CHECK

Severity:
MEDIUM

Location:
`setup-coder.sh` Z. 116–133 (`note_drift`/`remember_hash`), 16
`note_drift`-Aufrufe, einziger Commit Z. 1514–1521 (Schritt 10)

Current behavior:
Jede generierte Datei wird vor dem Schreiben auf Drift geprüft
(WARN), alle Hashes werden erst in Schritt 10 festgeschrieben.

Why it is complex/redundant:
B2-007 (CONFIRMED per Logik-Repro): Bricht ein Lauf nach Schritt 2
ab (Netz, Hex-Gate, Daemon), meldet der Heilungslauf fälschlich
„Operator-Drift" für setup-eigene Residuen – das Warnsystem
rauscht genau dann, wenn es gebraucht wird (B-007-Downgrade-Warnung
inklusive). 16 Messstellen + Hashstore + 600-Pflege (~40 Zeilen
Mechanik) für einen Vergleich, der am falschen Ort committet.

Does the current complexity provide real value?
Die Drift-Warnung ja (B-012: schützt Operator-Tuning vor stillem
Clobber). Der zentrale Spät-Commit nein – er ist die Fehlerquelle.

Proposed simplification:
Hash unmittelbar nach jeder Schreibstelle committen (dort, wo heute
`note_drift` steht), Schritt-10-Schleife entfernen. Keine neue
Mechanik, nur Ortswechsel – danach ist der Hashstore nach Abbruch
konsistent mit dem Geschriebenen.

What must remain unchanged:
Deterministische Regeneration (Heilung bleibt), WARN-Semantik (nie
interaktiv stoppen, Idempotenz!), 600-Modus des Hashstores,
Abdeckung aller 15 Dateien.

Security impact:
Indirekt positiv: verlässliche B-007-Downgrade-Warnung statt
Rauschen (Warnmüdigkeit ist ein Security-Risiko).

Regression risk:
Mittel – Commit-Ort verschieben braucht Abbruch-Test (T-026
erweitert), sonst vertauscht man nur die Fehlalarm-Richtung.

Test:
T-026 erweitert: Abbruch nach Schritt 2 → Heilungslauf ohne
Fehlalarm; echte Hand-Drift → WARN bleibt.

Classification:
CONFIRMED (B2-007-Repro belegt Fehlalarm-Pfad).

---

## C-012 – Monolith: 6 Skripte als Heredocs in einer Datei

Type:
ABSTRACTION

Severity:
MEDIUM

Location:
`setup-coder.sh` Z. 741–1499 (boot-check, check-tls, backup, update,
reset-passwords, reset-coder als `sudo tee … <<'EOF'`-Blöcke)

Current behavior:
Eine Datei generiert sechs ausführbare Skripte plus sechs Configs
plus Cron/logrotate. Deployment = eine Datei kopieren, ein Lauf.

Why it is complex/redundant:
Vorteil (atomares Deployment, ein Review-Ort) gegen drei Kosten:
(1) Keine der sechs Einheiten ist isoliert testbar/lintbar
(ShellCheck über Heredoc-Inhalt läuft nicht im Normal-Setup);
(2) jede C-001/C-002/C-003/C-009-Zusammenlegung scheitert an der
Heredoc-Grenze – der Monolith zementiert die Duplikate; (3) 1616
Zeilen überschreiten jede Review-Arbeitsspeichergrenze (die
Review-Flut von 16.000 Zeilen ist auch eine Folge davon: Jede
Iteration musste den ganzen Monolithen neu lesen).

Does the current complexity provide real value?
Heute ja: Ein-Datei-Artefakt + deterministische Regeneration +
 attentatsichere Idempotenz sind reale Betriebswerte auf einem
Schulserver ohne Paketierung. Der Monolith ist kein Unfall.

Proposed simplification:
Nicht jetzt auftrennen (kein akuter Ausfall wird dadurch
verhindert – K6-Lehre aus PLAN.md). Stattdessen als Budget-Regel
festhalten: Auszug erst, wenn (a) `tests/` auf VM läuft und (b)
drei Stellen denselben Helper brauchen (C-006/C-009 sind die
Kandidaten). Dann: `lib.sh` + Einzeldateien + Generierungs-Test
(Hash-Vergleich generiert-vs-Repo). Bis dahin Monolith behalten.

What must remain unchanged:
Ein-Befehl-Deployment, deterministische Regeneration, Idempotenz,
alle Fail-closed-Gates während jeder Umstellung.

Security impact:
Keiner heute; bei späterem Auszug: Heredoc-Quoting-Fallen
(`<<EOF` vs `<<'EOF'` an Z. 224/294/469 – DOMÄNEN-Expansion!) als
Migrationsrisiko einplanen.

Regression risk:
Hoch bei voreiligem Auszug (Escaping-Migration, K6) – deshalb
zurückgestellt, nicht verworfen.

Test:
Bei Auszug: Byte-Vergleich generierte Dateien vorher/nachher +
volle T-Matrix auf Test-VM.

Classification:
SUBJECTIVE (Architektur-Urteil mit K6-Präzedenz).

---

## C-013 – Backup-Verifikation: 5 Schichten, 2 ohne Biss, 1 defekt

Type:
REDUNDANT_CHECK

Severity:
MEDIUM

Location:
Eingebettetes `backup.sh` (`setup-coder.sh` Z. 884–936): df-Gate,
`gzip -t` (hart), SQL-Headercheck (hart, B2-001-defekt),
512-Byte-Warnung, Halbierungs-Warnung; dazu Cron-Skip=Exit 0
(Z. 864–875)

Current behavior:
Fünf Prüfschichten hintereinander: Platz (Fail), gzip-Integrität
(Fail), Header (Fail, aber per SIGPIPE gegen jede reale DB –
B2-001 CONFIRMED), Kleinheit (Warnung), Schrumpfung (Warnung).
Beide Warnungen landen in Cron-Logs, die niemand liest (kein Leser,
B-015).

Why it is complex/redundant:
Schichtentiefe täuscht Sicherheit vor: Der einzige harte
SQL-Nachweis ist kaputt (B2-001), die zwei weichen Nachweise sind
ohne Leser wirkungslos (B-010), und der Skip-Fall meldet Exit 0
ohne Frische-Signal an `update.sh` (B-010c). Fünf Schichten, davon
eine defekt, zwei blind, eine stumm.

Does the current complexity provide real value?
df-Gate ja (Fail vor partieller Datei). `gzip -t` ja (notwendig,
nicht hinreichend). Rest in aktueller Form nein.

Proposed simplification:
Headercheck per B2-001-Fix reparieren (pipefail-Scope, kein
Schwellen-Raten); beide Größen-Warnungen zu einer
Vorwert-Vergleichs-Warnung mit Kontext falten (eine Logger-Zeile
statt zwei); Skip-Fall mit Backup-Alter anreichern (bereits
teilweise vorhanden Z. 866–873 – an `update.sh` durchreichen statt
doppelt prüfen). Mini-Restore (T-080) als einzigen hinreichenden
Nachweis automatisieren statt Schichten zu stapeln.

What must remain unchanged:
df-Gate (Fail), `gzip -t` (Fail), atomares mv, flock-Selbst-Lock,
Retention-Mindestbestand. Kein harter Größen-Fail ohne
Restore-Beweis (P-013: legitime Verkleinerung bleibt grün).

Security impact:
Keiner direkt; indirekt: verlässliches Backup ist Grundlage aller
Security-Annahmen (B-004: Sicherung auf kompromittierbarer Basis
nützt nichts ohne Restore).

Regression risk:
Mittel – Header-Fix und Warnungs-Faltung brauchen Groß-Dump-Fixture
(> 1 MB, T-071b), sonst wiederholt sich die Kleinst-Fixture-Falle.

Test:
T-071b (großer Dump→OK, leer/Fehlertext→Fail), T-072 (Abbruch→keine
Finaldatei), T-080 (Mini-Restore automatisiert).

Classification:
CONFIRMED (B2-001-Repro, B-010-Analyse).

---

## C-014 – Schritt-10-Prüfliste: lang, aber nicht redundant

Type:
REDUNDANT_CHECK

Severity:
INFO

Location:
`setup-coder.sh` Z. 1523–1583 (6× Container-Check + Socket-Probe +
Apex-curl + Wildcard-Probe) und Z. 646–691 (ufw/fail2ban/SSH-Checks)

Current behavior:
~15 Einzelaussagen in der SUMMARY, jede mit eigenem Befehl und
eigener Reparaturanleitung.

Why it is complex/redundant – und warum der Befund negativ ausfällt:
Auf den ersten Blick „wiederholte Healthchecks" (§8). Bei Prüfung
benennt jede Zeile einen anderen Fehlerfall mit anderer
Reparaturanleitung (Container X down ≠ Socket-GID falsch ≠
Wildcard fehlt). Zusammenfalten (z. B. ein Loop über Ports statt
drei ufw-Fragen) würde die Diagnose-Anweisung pro Fall opfern –
exakt die Prüfung, die AGENTS.md verlangt („keine zusätzliche
Prüfung ohne benannten Fehlerfall" gilt hier umgekehrt: jede
Prüfung HAT einen benannten Fehlerfall).

Does the current complexity provide real value?
Ja – siehe Do-Not-Simplify. Einzige echte Vereinfachung ist das
Snapshot-Caching (C-007), nicht das Streichen von Fragen.

Proposed simplification:
Keine Streichung. Nur C-007 (Snapshots) anwenden.

What must remain unchanged:
Alle Aussagen, alle Reparaturhinweise, Fail-vs-Warn-Trennung
(SSH bleibt WARN wegen Aussperrungsrisiko, B-006).

Security impact:
Jede Streichung wäre negativ (weniger Fehlererkennung ohne
Kompensation).

Regression risk:
Keins (keine Änderung).

Test:
SUMMARY-diff vor/nach C-007 muss leer sein.

Classification:
CONFIRMED (Negativ-Befund: kein Befund – bewusst dokumentiert,
damit niemand „15 Checks → 3" als Top-10 einreicht).

---

## C-015 – Review-Apparat 10× Code, Tests 0× ausgeführt

Type:
OVERENGINEERING

Severity:
MEDIUM

Location:
`ai-review/` (~16.000 Zeilen, 14 Dateien), `TEST_PLAN.md`
(2735 Zeilen), `tests/` (leer); `setup-coder.sh` (~1.700 Zeilen
inkl. Kommentare)

Current behavior:
Jede Iteration (PLAN → PLAN-REVIEW → FINAL-BREAKER → v2 → Report)
legt tausende Zeilen Doku ab; die T-Matrix (T-001–T-126+) wurde
noch nie ausgeführt („keine Test-VM verfügbar" steht in fast jedem
Befund). B2-001/B2-002 beweisen: Genau die Tests, die fehlten
(großer Dump, echter Handshake), hätten die CRITICAL-Regressionen
gefangen – stattdessen wuchs die Doku.

Why it is complex/redundant:
Doku ohne Ausführungsnachweis akkumuliert Behauptungen statt Wissen:
IMPLEMENTATION-REPORT-v2 behauptete „16 note_drift-Belege" und
„Dump-Header-Probe", B2-Review widerlegte beides per 5-Minuten-Repro.
Jede weitere Review-Runde ohne VM erhöht das Blätterrauschen, nicht
die Zuverlässigkeit. 2735 Zeilen Testplan bei 0 ausgeführten Tests
sind Komplexität ohne Gegenwert.

Does the current complexity provide real value?
Die Befund-Qualität ja (B-001/B-003/B-005/B-008/B-021 sind reale,
belegte Funde – ohne Reviews wäre das Projekt ein 845-Zeilen-
Happy-Path mit Totalausfällen). Die Wiederholungs- und
Umfangs-Eskalation nein.

Proposed simplification:
Review-Moratorium mit Ausführungs-Priorität: (1) Test-VM beschaffen
(Blocker vor jeder weiteren Doku-Runde); (2) T-071b + Handshake +
Hex-Migration zuerst ausführen (fangen B2-001–003); (3) neue
Reviews nur noch als Delta zu FINAL-BREAKER-v2 (kein Voll-Re-Review);
(4) `PLAN.md`-Trunkierung (F-012-Satz, „26 Findings"-Behauptung)
reparieren oder Datei als Entwurf kennzeichnen – eine abgebrochene
Freigabe-Basis ist schlimmer als keine.

What must remain unchanged:
Befund-Substanz (B-/B2-/P-Nummern als Referenzsystem – C-010
empfiehlt Kürzung im Code, nicht Löschung der Reviews),
Evidenz-Standard (CONFIRMED/LIKELY-Trennung, Repro-Pflicht),
AGENTS.md-Grundsätze.

Security impact:
Indirekt: Jede Woche Doku-statt-Test verlängert B-008 (kein
Offsite, kein Restore-Nachweis) und B-004 (kein Inventar).

Regression risk:
Keins (Prozess, kein Code).

Test:
Meta-Test: `ls tests/` nicht-leer + ein datierter VM-Protokoll-
Eintrag (RTO-Zahl) vor dem nächsten Review.

Classification:
SUBJECTIVE (Prozess-Urteil), gestützt auf CONFIRMED-Fakten
(Zeilenverhältnisse, „nie ausgeführt"-Selbstauskünfte, B2-Funde).

---

## Duplication Map

Zusammengehörige oder doppelte Logik im Überblick (Pfeil = teilen
sich Mechanik und Fehlerfall):

| Gruppe | Stellen | Art | Status |
|---|---|---|---|
| Container-Running | C-001 (Reset ×2), `check_container_running` (Setup ×6), Update-Gate-Loop, Boot-Loop | identische `docker inspect`-Phrase, 12 Stellen | C-001 sofort faltbar; Rest via C-012 |
| Postgres-healthy-Wait | C-002 (Setup, Update, Boot mit 3 Timeouts) | kopierte Schleife, `seq 1 30` ×3 | Parameter benennen, sonst lassen |
| Apex-Parser | C-003 (Boot Z. 765, Update Z. 1115) | byte-identisches awk | `.domain`-Datei entfernt beide |
| /healthz-Proben | C-004 (Schritt 10, Update-Gate, Boot-Gate) | gleiche Absicht, divergierende SNI-Semantik | kanonische `--resolve`-Probe ×3 |
| .env-Gates | C-005 (Setup Z. 241–253, Reset Z. 1202–1214) | doppelte Regex-Paare + divergierende Texte | Texte synchronisieren, Pingpong lösen |
| Atomare Writes | C-006 (Erstellung, GID-Refresh, Reset-Tausch) | 3 Rezepte, 1 Garantie | bewusst NICHT falten (Heredoc-Grenze) |
| Status-Snapshots | C-007 (ufw ×8, sshd-T ×4) | wiederholte Prozessaufrufe | Snapshots cachen, Fragen behalten |
| Crontab-Migration | C-008 (Backup, Update) | identischer Block ×2 | behalten (YAGNI-Grenze) |
| Retry-Policy | C-009 (`retry3`, Update-Hand-Retry) | gleiche Policy, 2 Mechaniken | bewusst NICHT falten (Laufzeitgrenze) |
| Backup-Verifikation | C-013 (df, gzip-t, Header, 2 Warnungen, Skip) | Schichten mit 1 Defekt + 2 blinden | Header fixen, Warnungen falten |
| Schritt-10-Liste | C-014 (~15 Aussagen) | sieht dupliziert aus, ist es nicht | NICHT falten (Negativ-Befund) |
| Hex-Begründung | C-010 (Z. 210–212, Z. 1251–1252) | doppelter Kommentar | bei nächster Berührung falten |

---

## Simplification Candidates

Sortiert nach erwarteter Wirkung (Wirkung = Risiko-Reduktion pro
geänderter Zeile, nicht Zeilenersparnis):

1. **C-004 kanonische /healthz-Probe** – beendet Dauer-Rot (Boot)
   und Update-Blockade; kleinster Diff mit größter
   Betriebswirkung. Bedingung: Handshake-Test auf VM.
2. **C-013 Header-Fix + Warnungs-Faltung** – stellt Backup-
   Verifikation für reale DBs wieder her (B2-001 ist CRITICAL).
   Bedingung: Groß-Dump-Fixture.
3. **C-005 Gate-Texte + Migrationspfad** – beendet
   Setup/Reset-Deadlock für Legacy-`.env` (B2-003 HIGH).
   Bedingung: Sonderzeichen-Fixture.
4. **C-011 Hash-Commit an Schreibstelle** – beendet
   Drift-Fehlalarme inkl. B-007-Warnmüdigkeit. Bedingung:
   T-026-Abbruch-Test.
5. **C-007 Snapshot-Caching** – halbiert Prozessaufrufe in
   Schritt 4, SUMMARY-diff als billiger Beweis. Bedingung: keine
   (rein lesend).
6. **C-001 Reset-Doppelschleife falten** – 6 Zeilen, trivialer
   Beweis (T-033). Bedingung: keine.
7. **C-003 `.domain`-Datei** – entfernt Parser-Duplikat ersatzlos.
   Bedingung: Domain-Wechsel-Pfad mitschreiben.
8. **C-010 Kommentar-Diät (inkrementell)** – senkt Review-Last und
   Drift-Risiko über Zeit. Bedingung: Disziplin, kein Big-Bang.
9. **C-015 Review-Moratorium + VM zuerst** – stoppt
   Doku-Eskalation, erzwingt Ausführungsnachweis. Bedingung:
   Management-Entscheidung (VM-Beschaffung).
10. **C-002 Timeout-Benennung** – 3 Zeilen, Lesbarkeit. Bedingung:
    keine.
11. **C-012 Monolith-Auszug** – erst nach (9) + drittem
    Shared-Bedarf. Bis dahin zurückgestellt.
12. **C-008/C-009 Nicht-Faltung** – dokumentiert, keine Aktion.

---

## Do Not Simplify

Bereiche, deren Komplexität sinnvoll und bewusst ist. Jeder
Eintrag nennt den Grund, warum Kürzung hier schaden würde:

- **Fail-closed `.env`-Gates (Setup + Reset).** Sonderzeichen
  brechen ALTER USER/grafana-cli/URL still – Abweisung mit
  Anleitung ist kein „defensives Extra", sondern die einzige
  Barriere vor selbstgebautem Lockout (B-014, P-011). Nie gegen
  Warnung abschwächen.
- **`.env`-Erstellung nur bei Fehlen, nie Neuwürfeln bei
  Unvollständigkeit.** P-011 bewies Destruktivität des
  „einfachen" Wegs. Abbruch + Reparaturanleitung ist korrekt.
- **Backup: flock-Selbst-Lock + atomares mv + `gzip -t` +
  Retention-Mindestbestand.** B-001 zeigte, dass jede
  abgeschwächte Variante (äußeres flock, direktes Schreiben,
  Zählen ohne Mindestbestand) Total- oder Schleich-Verlust
  erzeugt.
- **Reset: Projekt-Label-Filter + Allowlist + Leer-Guard +
  Belegungs-Pre-Check + `--force`-Zweitphrase + TTY-Guard.**
  F-004/P-016/P-019/B-020 belegen je eine reale
  Zerstörungskante pro Guard. Zusammenlegung der Checks in
  „einen Destroy-Befehl" wäre katastrophal.
- **Kein Auto-Prune nach Update (B-003).** Die „Vereinfachung"
  (`prune -f` = saubere Platte) zerstört den einzigen
  Offline-Rollback. Bleibt entfernt.
- **`CODER_DISABLE_PATH_APPS` weiter abwesend bis Inventar.**
  Die „Ein-Zeilen-Härtung" ohne Template-Prüfung bricht legitime
  Pfad-Apps – Zurückhaltung ist hier korrekt (B-017).
- **DOCKER-USER weiter abwesend bis Dual-Stack-Test.** Ungeprüfte
  Firewall-Härtung bricht Workspace-Apps/HTTP-3 (B-007). Nur
  Bindungsregel-Doku ist richtig.
- **SSH bleibt WARN statt FAIL.** Sofort-Fail sperrt ohne
  Zweit-Zugang aus (B-006). Provisorium mit Datum + Härtungspfad
  ist die korrekte Komplexität.
- **Schritt-10-Einzelaussagen (C-014).** Jede Prüfung benennt
  einen eigenen Fehlerfall mit Reparaturweg. Falten opfert
  Diagnose für Zeilen.
- **Drei Timeouts in C-002.** Boot (5 min) vs. Update/Setup
  (60 s) sind verschiedene Betriebsrealitäten, keine
  Inkonsistenz.
- **Kein `retention.size`-Fantasiewert, kein App/DB-Split ohne
  Entscheidung.** Geratene Konstanten und Vertrags-Refactorings
  ohne Messung sind die Komplexität, die PLAN.md zu Recht als
  Non-Goal verwarf (K4/K5).

---

## Complexity Budget

Konkrete Regeln für zukünftige Änderungen. Jede Regel ist
verletzt, sobald ihr Gegenbeispiel ohne Begründung gemergt wird:

1. **Keine neue Hilfsfunktion ohne dritten Verwender.**
   Zweimal kopieren ist billiger als einmal falsch
   abstrahieren (C-008-Grenze; C-006/C-009 als Präzedenz:
   Heredoc- und Laufzeitgrenzen schlagen DRY).
2. **Keine zusätzliche Prüfung ohne benannten Fehlerfall.**
   Jede `ok`/`warn`/`fail`-Zeile nennt im Meldungstext die
   Reparaturanleitung (C-014-Standard). Prüfung ohne
   Fehlerfall-Namen wird abgelehnt.
3. **Keine zusätzliche Abstraktion ohne Streichung.**
   Wer eine Lib/Helper/Config-Ebene einführt, benennt die
   Duplikate, die sie entfernt (C-012-Auszugs-Bedingung).
   Netto-Mehrcode ohne entfernte Duplikate wird abgelehnt.
4. **Keine Kommentare ohne Informationsmehrwert.**
   Erlaubt: Warum, verworfene Alternative, Betriebsfolge,
   offene Entscheidung mit Frist. Verboten: Code-Paraphrase,
   Historien-Stempel ohne Entscheidungsgehalt (C-010).
   B-/P-/F-Nummern nur bei offener Entscheidung.
5. **Kein harter Fail ohne Restore-/Heilungs-Beweis.**
   Neue `exit 1`-Pfade (insb. Größen-/Schwellen-Fails) brauchen
   Fixture-Beweis gegen False-Positive (P-013-Lehre:
   Kleinst-Fixtures lügen; T-071b-Maßstab > 1 MB).
6. **Keine Warnung ohne Leser.**
   Neue WARN/Logger-Zeilen brauchen einen benannten Leser
   (Boot-Log, TLS-Log mit Rotation, Check mit Eigentümer) –
   sonst ist es B-010-Theater (C-013-Lehre).
7. **Kein Duplikat-Fix über Heredoc-Grenzen ohne Auszugs-Plan.**
   Setup-Funktionen existieren in eingebetteten Skripten zur
   Laufzeit nicht (C-006/C-009). Wer dort vereinheitlichen
   will, liefert erst C-012 (Auszug + Byte-Vergleich).
8. **Kein Review ohne Ausführungs-Anteil.**
   Jede Review-Runde benennt die ausgeführten Repros/Tests mit
   Datum; reine Lesungs-Befunde bleiben LIKELY/SUBJECTIVE.
   Nächste Runde erst nach T-071b + Handshake + Hex-Migration
   (C-015).

---

## Top 10 Simplifications

Nur die zehn sinnvollsten Vereinfachungen (Wirkung zuerst):

1. **Kanonische `--resolve`-Probe an 3 Stellen (C-004).**
   Effekt: Boot-Gate ehrlich, Update-Gate entsperrt, SNI-Spam
   weg. Aufwand: 6 Zeilen + VM-Handshake-Test.
2. **Headercheck pipefail-fix + Warnungen falten (C-013).**
   Effekt: Backups für reale DBs wieder möglich. Aufwand:
   ~10 Zeilen + Groß-Fixture.
3. **Gate-Texte synchron + Migrationspfad statt Pingpong
   (C-005).** Effekt: Legacy-Hosts wieder wartbar. Aufwand:
   ~15 Zeilen + Sonderzeichen-Test.
4. **Hash-Commit an jede Schreibstelle, Schritt-10-Schleife
   löschen (C-011).** Effekt: keine Fehlalarme nach Abbruch,
   B-007-Warnung glaubwürdig. Aufwand: ~15 versetzte Zeilen +
   T-026-Abbruch-Test.
5. **ufw/sshd-Snapshots cachen (C-007).** Effekt: halbierte
   Prozesslast, identische SUMMARY. Aufwand: 4 Zeilen, kein
   VM-Test nötig.
6. **Reset-Doppelschleife in `require_containers` falten
   (C-001).** Effekt: 6 Zeilen weniger, eine Wartungsstelle.
   Aufwand: trivial + T-033.
7. **Apex-Parser durch `.domain`-Datei ersetzen (C-003).**
   Effekt: Duplikat ersatzlos weg, kein Drift-Paar mehr.
   Aufwand: 3 Zeilen Schreiben + 2×1 Zeile Lesen.
8. **Kommentar-Diät inkrementell (C-010).** Effekt: Datei
   schrumpft unter 1400 Zeilen, Reviews werden kürzer.
   Aufwand: Disziplin pro Änderung, kein Risiko.
9. **Review-Moratorium bis VM + 3 Kern-Tests (C-015).**
   Effekt: stoppt 16.000-Zeilen-Eskalation, erzwingt erste
   echte Nachweise (RTO-Zahl). Aufwand: organisatorisch.
10. **Timeouts als Variablen benennen (C-002).** Effekt:
    Absicht sichtbar, Kopie dokumentiert. Aufwand: 3 Zeilen.

Ausdrücklich NICHT in den Top 10 (trotz Zeilenersparnis):
Schritt-10-Liste falten, `.env`-Gates abschwächen, Backup-Schichten
streichen, Auto-Prune wiedereinführen, Monolith jetzt auftrennen –
siehe Do-Not-Simplify und C-012.
