# PLAN-v3-FINAL-CHECK – Verifikation PV-001 bis PV-015

Stand: 2026-09-27. Geprüft: `ai-review/PLAN-v3.md` (1213 Zeilen) gegen
`ai-review/PLAN-v3-REVIEW.md` (908 Zeilen, PV-001 bis PV-015).
Methode: jede PV-Forderung gegen den tatsächlichen PLAN-v3-Inhalt geprüft,
nicht nur Schlagwörter. Mehrdeutiges gilt als NICHT geschlossen.
Keine Codeänderung, keine Planänderung, nur dieser Check.
Verifiziert per Lesung; Repo-Fakten: `setup-coder.sh` 1615 Newlines
(`wc -l`), letzte Zeile `fi` ohne Newline (= 1616 logische Zeilen),
`ssh-harden.sh` 80, `RESTORE.md` 68, `templates/allowlist.md` 34,
Setup-Dateien `eadb61a..HEAD` ohne Diff (nur `ai-review/`-Delta);
aktueller HEAD `afa13c0` (PLAN-v3 nennt `a09c591`, siehe PV-001).

---

## PV-001

Status:
PARTIAL

Evidence:
PLAN-v3.md Z3–10: Baseline `ai/implementation-v2`, HEAD `a09c591`,
`setup-coder.sh` 1615 Newlines / 1616 logische Zeilen, letzte Zeile `fi`
ohne Newline; Setup-Diff `eadb61a..HEAD` leer
(nur `ai-review/PLAN-v3.md` als Delta, per `git diff eadb61a..HEAD --stat`);
Freigabe-Protokoll hält `git rev-parse --short HEAD` +
`git diff eadb61a..HEAD --stat` fest.

Required correction from review:
Baseline auf `52493de` aktualisieren (oder `eadb61a` + nur-PLAN-Delta mit
leerem Setup-Diff dokumentieren) und Zählweise klarstellen
(1616 logische Zeilen, 1615 Newlines).

How PLAN-v3 addresses it:
Zählweise vollständig korrigiert (1615 Newlines / 1616 logische Zeilen +
Begründung fehlender End-Newline, verifiziert: `wc -l` = 1615,
`tail` = `fi` ohne Newline). Setup-Diff-Leerheit explizit behauptet und
Protokollierung (`rev-parse` + `diff --stat`) vorgeschrieben. HEAD von
`eadb61a` auf `a09c591` (Nachfolger von `52493de`) gehoben. Alle
Setup-Zeilenreferenzen bleiben gültig (Setup-Dateien ohne Diff).

Remaining gap:
HEAD-Angabe bereits wieder veraltet (aktuell `afa13c0`, PLAN nennt
`a09c591`; `a09c591..HEAD` = 345+/125- in PLAN-v3.md selbst). Delta-Aussage
`nur ai-review/PLAN-v3.md` ist unvollständig (`eadb61a..HEAD` enthält auch
`PLAN-v3-REVIEW.md`). Setup-Aussage (Diff leer) bleibt wahr, aber der
Klammerzusatz ist faktisch unpräzise.

Functional impact:
NONE

---

## PV-002

Status:
CLOSED

Evidence:
PLAN-v3.md B2-003 Z179–244: genau EINE Variante, keine Wahl im PR:
Variante (a), Reset migriert Legacy lesend, Setup bleibt fail-closed;
`docker exec -e PGPASSWORD` verboten (02/F-015 `inspect`-Leak);
STDIN-Prinzip (`printf '%s' "$OLD_PG_PW" | docker exec -i … sh -s` +
`read -rs` im Container), nie in SQL/URL, nie als `exec`-Argument;
`ALTER USER` nur mit Hex-NEU; Heredocs Z1263 quotiert (`<<'INNER_EOF'`),
Z1271/Z1281 begründet unquotiert (nur Hex-NEU aus `openssl rand -hex`);
Setup-Ersatztext wörtlich Z184–189; Reset-Spaltung ALT-lesend vs. NEU-Hex
Z190–195; Zeichenvorrat Z210–215 (druckbar ASCII 0x20–0x7E außer
Newline/NUL, inkl. `$`, Backtick, `"`, `'`, Space, `!` mit
Nicht-interaktiv-Begründung, führendes `-` via `printf '%s'`/`grep --`/
`cut -d= -f2-`, UTF-8 als ungetestet abgewiesen); Newline/NUL harter
Abbruch Exit 1 ohne Trimmen Z216–222; Migrationspfad Z223–227;
Leak-Test Z236–244 (`Legacy$Pass!23`, Spaces, Quotes, `$`, Backtick,
`-führend`, Newline-Negativ, `ps aux`- + `inspect`-Grep Vollwert +
8-Zeichen-Präfix, beide leer).

Required correction from review:
Eine Variante festschreiben (empfohlen (a) mit quotiertem Heredoc +
Alt-PW nur als Env-Wert via STDIN, nie interpoliert, Neu-PW Hex;
`docker exec -e` nur begründet, kein Default); exakte Stellen
Z1263/Z1271/Z1281, exakter Ersatztext beider Gates, exakter
Zeichenvorrat inkl. `$`/Backtick/`"`/`'`/Space/führendes `-`,
Newline dokumentiert abgewiesen.

How PLAN-v3 addresses it:
Wörtlich umgesetzt: Variante (a) festgeschrieben, alle drei Heredoc-Stellen
genannt mit Begründung, beide Gate-Texte wörtlich, Voll-Zeichenvorrat +
Negativfall, Leak-Grep (Vollwert + Präfix, `ps` + `inspect`), genau ein
grüner Weg. Kein `docker exec -e`-Default (Verbot + Leak-Begründung).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-003

Status:
CLOSED

Evidence:
PLAN-v3.md B2-007 Z352–377: `remember_hash` unmittelbar NACH jeweiliger
erfolgreicher Schreib-/Installations-Sequenz (`tee`/`mv`/`chmod`/`install`),
ausdrücklich NICHT an der `note_drift`-Zeile davor (`note_drift` steht heute
VOR jedem `tee`, Hash der ALTEN Datei wäre falsch); Schritt-10-Schleife
Z1514–1521 löschen; 600-Modus, 15 Dateien, deterministische Regeneration,
WARN-nie-interaktiv bleiben; Residualkante Z361–364 dokumentiert (Kill
zwischen Write und `remember_hash` → einmalig Fehl-WARN, kein Datenverlust,
nächster grüner Lauf heilt); Test T-026 Z372–377 mit (a) Abbruch-nach-
Schritt-2 → keine Fehl-WARN, (b) Hand-Drift → WARN, (c) Residual-Kill →
genau einmal Fehl-WARN + Heilung.

Required correction from review:
Unmittelbar NACH jeder `tee`/`mv`/`chmod`-Stelle (nicht `note_drift`-Zeile),
Schritt-10-Schleife löschen, 600 + 15 Dateien + Regeneration + WARN behalten;
Residualfenster als Restkante dokumentieren.

How PLAN-v3 addresses it:
Wörtlich umgesetzt inkl. Negativabgrenzung (`NICHT an der note_drift-Zeile`),
Loop-Löschung und dokumentiertem Residualfenster mit Heilpfad; T-026 deckt
alle drei Pfade ab.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-004

Status:
CLOSED

Evidence:
PLAN-v3.md Stop-Regel Z642–658: `offen` ist KEIN Freigabezustand für
CRITICAL/HIGH; Pflicht grün: B2-001/B2-002/B2-003, B-002-Pull-Probe, B2-009,
B-004-Inventar + T-063 + D-Socket-Frist, B2-004, B-008-Offsite-Probe
(T-082 nur aus Offsite + Runbook, RTO als Zahl) + B2-005-Limit-Doku +
`logrotate` für `coder-tls.log`/`coder-boot.log` + T-125,
Blocking-0-Reparatur; CRITICAL/HIGH (D-Socket, D-TLS, D-SSH, D-Offsite,
B-008) brauchen geschlossene Entscheidung (Owner + Datum/Frist + Nachweis)
ODER explizite Production-Sperre; `_offen_`/`_OPEN_` ohne Owner+Frist nur für
LOW/MEDIUM mit Verfallsdatum + Ticket; ohne Offsite + ohne gemessene RTO
keine Production-Freigabe. DoD Z1184–1188 wiederholt die Verschärfung
wörtlich (CRITICAL/HIGH: `_offen_` kein Freigabestatus).

Required correction from review:
Stop-Regel ergänzen (B-008 + RTO, B2-005-Doku + `logrotate` + T-125); DoD
verschärfen (D-Socket/D-TLS/D-SSH/D-Offsite brauchen Owner + Frist,
`_offen_` nur LOW/MEDIUM); alternativ `ohne Offsite keine Produktion`.

How PLAN-v3 addresses it:
Alle drei Forderungen wörtlich in Stop-Regel + DoD; Offsite-Satz als
harter Ausschluss formuliert. Phase-D-`OPEN`-Tabellen bleiben `OPEN`,
wirken aber per Stop-Regel als Sperre (erlaubte Alternative laut Review:
geschlossene Entscheidung ODER explizite Sperre).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-005

Status:
CLOSED

Evidence:
PLAN-v3.md DoD Z1175–1193: Static Gates (T-001/T-002/T-003/T-004/T-007) +
Phase-C-VM-Gate vollständig grün (Fresh Install, Second Run, Third Run,
Interrupted Run, Reboot, Backup, Restore, Update, Rollback, Security Smoke,
Caddy/TLS, Workspace-Isolation, je Artefakt Datum/VM/Commit/Tool-Versionen/
Exit-Codes/Logs, nie Produktion) + Phase-G-Doku-Gates (`test -f` +
Stichwort-Greps + `_offen_`-Zählung + `tail -5 CHANGELOG.md` +
`ls tests/` nicht-leer + datierter VM-Eintrag mit RTO-Zahl, C-015-Meta-Test).
Phase C Z633–640 listet dieselben Pflichten mit Artefaktpflicht.

Required correction from review:
DoD ergänzen: Phase-C-VM-Gate grün (alle Pflichten mit Artefakt, nie
Produktion) + Phase-G-Verifikation grün (`test -f`, Greps, `_offen_`-Zählung,
`tail -5 CHANGELOG`, `ls tests/`, RTO-Eintrag, C-015).

How PLAN-v3 addresses it:
Wörtlich übernommen; Gate-Bypass-Lesart (`nur MUST_FIX auf VM`) damit
geschlossen; Doku-Gates in DoD verankert.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-006

Status:
CLOSED

Evidence:
PLAN-v3.md C-003 Z899–916: Variante A festgeschrieben, keine `.domain`-Datei
in dieser Runde; Duplikat behalten + Sync-Kommentar (`mit Z.765/1115 synchron
halten`), solange zwei Verwender (Complexity-Regel 1, Z1101–1103:
Helfer erst ab drittem Verwender, Heredoc-/Laufzeitgrenzen schlagen DRY);
Begründung stale-Source-Risiko; Konditional-Spec für künftiges `.domain`
(Quelle `${DOMAIN_CODER}`, Schritt 2 deterministisch, 644/root, 16. Datei im
Hashstore, Missing = WARN-Fallback, Wechsel = Rewrite, Hand-Edit = WARN nie
falsches Grün; Tests Spacing/Wechsel/Delete/Hand-Edit); Test Variante A:
Spacing-Change → Apex oder WARN, nie falsches Grün.

Required correction from review:
Entweder Duplikat + Sync-Kommentar (`.domain` erst bei drittem Parser,
Regel 1) ODER volle File-Spec mit Sync-Beweis.

How PLAN-v3 addresses it:
Erste Option gewählt + zweite als konditionale Voll-Spec mitgegeben;
Regel-1-Konformität begründet; stale-Source ausgeschlossen.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-007

Status:
CLOSED

Evidence:
PLAN-v3.md B2-008 Z393–420: TCP `ss -tlnp` + UDP `ss -ulnp` getrennt
(TCP-only-Falle benannt, UDP 443/QUIC); Docker-Bindings
`docker inspect --format '{{.HostConfig.PortBindings}}'` je Container
(`coder`, `coder-postgres`, `coder-caddy`, `coder-prometheus`,
`coder-grafana`, `coder-node-exporter` via `docker compose ps -q`,
Präfix `coder-*`); exakter Host-IP:Host-Port-Vergleich
(`0.0.0.0:80`, `:::443`, `127.0.0.1:9090`); nur exakte Treffer suppressen,
jeder andere Listener auf 80/tcp, 443/tcp, 443/udp, 9090/tcp, 9100/tcp,
3001/tcp → WARN mit Prozessname; keine Ports streichen; Test Z417–420:
gesund → keine WARN, fremd 80/tcp → WARN, fremd 9090/tcp → WARN,
fremd UDP 443 → WARN.

Required correction from review:
Konkreten Filter (`ss` + exakter IP:Port-Abgleich gegen Projekt-`inspect`,
nur exakte Treffer suppressen, sonst WARN; keine Ports streichen);
UDP 443 explizit; Fixtures gesund → keine WARN, fremd 80 UND 9090 → WARN.

How PLAN-v3 addresses it:
Vollständig wörtlich umgesetzt inkl. UDP-Trennung, Containerliste,
IP:Port-Beispielen und allen vier Testproben.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-008

Status:
CLOSED

Evidence:
PLAN-v3.md Phase H Z1048–1095: alle 15 überwachten + Laufzeit-Dateien
(`docker-compose.yml`, `Caddyfile`, `prometheus.yml`, 6 Skripte,
`jail.local`, `52-coder-reboot`, 3 Cron-Dateien, `logrotate`
`coder-backup`, `ssh-harden.sh` als Referenz); 9 Dateien = Repo-Kandidaten
Phase B, Rest (Host-Config) bleibt bis Budget-Reife Heredoc mit Begründung
(Rechte/Idempotenz-Retest, kein akuter Ausfall durch Auszug); Budget-Trigger
Z1078–1084 (`tests/` auf VM grün UND dritter Standalone-Runtime-Verwender,
C-006/C-009 ausdrücklich ausgenommen, bis dahin kein `lib.sh`);
Migration nur mit `diff <(alt-generiert) <(neu-generiert)` leer +
voller T-Matrix (T-020/T-026/T-003/T-004/T-002, Idempotenz/Drift,
Caddy-nur-bei-Änderung, fail2ban-Bans).

Required correction from review:
Alle 15 Dateien in Scope (Host-Dateien bis Budget-Reife Heredoc, danach
gleiche Byte-Regel); Budget (`dritter Helper`, C-006/C-009 ausgenommen,
kein `lib.sh`) + Byte-Vergleich + volle T-Matrix als H-Gate.

How PLAN-v3 addresses it:
Wörtlich umgesetzt; Drift-Split (Hashstore vs. `diff tmpl vs. Host`)
durch einheitliche Regel + Gate geschlossen.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-009

Status:
PARTIAL

Evidence:
PLAN-v3.md B2-004 Z261–302: Snapshot `UFW_OUT=$(sudo ufw status numbered)` +
Fallback ohne `numbered`; Abdeckung IPv4/IPv6 (`(v6)`), `22/tcp`, `22` ohne
Suffix, `OpenSSH`-Profil, Formen `22 ALLOW <src>` / `22/tcp ALLOW <src>` /
`allow from <src> to any port 22` / `OpenSSH ALLOW <src>` (je mit/ohne
`(v6)`); Verhalten (A) weltweit (`LIMIT/A ALLOW Anywhere`) → kein Abort,
(B) restriktiv (Quelle ≠ Anywhere) → Exit 1 + Anleitung +
vorher/nachher-`ufw status`, kein stilles Öffnen, (C) inaktiv/fehlend →
Hinweis, Pfad fährt fort; Re-Run (B) mit angepasster Regel, kein stilles
Entfernen; Bypass `CODER_ALLOW_SSH_DOWNGRADE=yes` (nur exakt `yes`),
vorher/nachher-Protokoll, verifizierte Wiederherstellung (`ufw`-Befehl +
Check); Tests Z296–302 (VM + UNIT-LIKE, beide Formate, weltweit-Negativ,
IPv6, No-UFW, nie stilles Öffnen).

Required correction from review:
Exakten Detektor + Negativ-Fixtures (weltweit/`limit` → kein Abort,
kein UFW → Hinweis) + Bypass-Verfahren (notieren/vorher-nachher ODER
verifiziert wiederherstellen, eines, kein `wähle im PR`) +
Wiederherstellungs-Befehl mit Check; kein Auto-Restore ohne Verifikation.

How PLAN-v3 addresses it:
Verhalten A/B/C, Negativ-Fixtures, Bypass-Syntax (`yes`), Logging,
No-Auto-Restore exakt festgelegt; IPv6-, `numbered`- und No-UFW-Lücken aus
dem Review geschlossen.

Remaining gap:
Kein wörtlicher Regex im Plan (`Regex wörtlich im Implementierungs-PR mit
UNIT-LIKE-Fixtures belegt`, Z268–269); kein wörtlicher
Wiederherstellungs-Befehl (nur `ufw-Befehl + Check im Protokoll`, Z281).
Die Was-muss-matchen-Entscheidung ist gefallen, die Zeichenkette selbst bleibt
PR-Sache und wird nur mittelbar über Pflicht-Fixtures determiniert. Bei
falschem PR-Regex droht verpasste restriktive Regel → stilles Öffnen oder
falscher Abort legitimer Läufe.

Functional impact:
MEDIUM

---

## PV-010

Status:
CLOSED

Evidence:
PLAN-v3.md Phase B Z570–571: T-110 grün (`BOOT-GATE GRÜN` im laufenden Log)
+ T-110-rot (krank: Postgres/Coder gestoppt → `BOOT-GATE ROT` + Exit 1,
Beleg im laufenden `$OUT`, nicht kumulativ). Phase E Z815–831: `check.sh`
Pfad `/opt/coder/check.sh`, `root:root`, 755, Cron
`/etc/cron.d/coder-freshness` 01:30 nach 01:00-Backup, nur lesend;
Prüfungen Backup-Alter (>26 h → ≠0), `df` (>85 % → `logger` + ≠0, bis
D-Monitoring WARN/UNVERMESSEN, kein Alertmanager), `/healthz` via
`--resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz"`
(Domain-SNI, `--max-time 10`, nirgends SNI `127.0.0.1`); Log
`/var/log/coder-backup.log` (vorhandene `logrotate`, kein neues Log);
Leser morgendlicher Operator-Check; Exit 0 nur bei allen drei grün;
`logrotate`-Nachzug `coder-boot.log`/`coder-tls.log` vermerkt.

Required correction from review:
T-110-rot (krank → ROT + Exit 1, laufendes `$OUT`); `check.sh` mit Pfad,
755/root, Cron-Pfad/Zeit, Log (rotiert), Leser, `--resolve`-Probe,
`df`-Schwelle als WARN/UNVERMESSEN, kein Alertmanager.

How PLAN-v3 addresses it:
Beide Forderungen wörtlich umgesetzt; SNI-Rezidiv und unrotiertes
Check-Log ausgeschlossen.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-011

Status:
CLOSED

Evidence:
PLAN-v3.md Z48–50 (Backup zuerst, Gates, Warnsystem) + Z1159–1166:
Phase A 8 Commits in Abhängigkeitsreihenfolge (1 B2-001 → 2 B2-002 →
3 B2-003 → 4 B2-006 → 5 B2-007 → 6 B2-004 → 7 B2-008 → 8 B2-009),
je genau ein Fix + lokales STATIC/UNIT-LIKE-Artefakt (Datum, Commit,
Exit-Codes) vor nächstem Commit, Anti-Verdeckung (B2-007-WARNs dürfen
B2-004 nicht übertönen); Merge-Gate T-071b + Handshake + Hex-Migration zuerst.

Required correction from review:
8 Commits in Ordnung B2-001→002→003→006→007→004→008→009 mit je Artefakt;
Kern-Tests zuerst als Merge-Gate.

How PLAN-v3 addresses it:
Reihenfolge und Per-Fix-Gate wörtlich identisch übernommen.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-012

Status:
CLOSED

Evidence:
PLAN-v3.md Z1025–1029: `docs/TROUBLESHOOTING.md` nur Pointer auf
`OPERATIONS.md`, keine Tabellenkopie (Single Source OPERATIONS, entschieden,
`grep`-Guard `Tabelle in genau einer Datei`). Z1038–1042: Handover-Punkte
1–6 aus 08 (Zugang/Bestand, Gate, Gesundheit, Backup/Restore, Wartung,
Entscheidungen/Doku), D-001–D-015 ausdrücklich NICHT die Checkliste,
aus OPERATIONS verlinkt, nicht dupliziert.

Required correction from review:
Pointer auf 08-Checklist 1–6 (verlinkt, nicht dupliziert); Single-Source
jetzt entscheiden (OPERATIONS Quelle, TROUBLESHOOTING Pointer, `grep`-Guard).

How PLAN-v3 addresses it:
Wörtlich umgesetzt; Implementierer-Wahl (`oder umgekehrt`) entfernt.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-013

Status:
CLOSED

Evidence:
PLAN-v3.md B2-009 Z437–451 + Phase E Z833–857: Pfad-A-Zeile wörtlich
`zcat coder_<TS>.sql.gz | sudo docker exec -i coder-postgres psql -v
ON_ERROR_STOP=1 -U coder -d coder` (Flag VOR `-U`, Abbruch vor `up -d`,
Exit ≠0, kein Grün); Datensicht statt Liveness (`restore_probe(id serial
primary key, marker text)` + `marker='RTO-PROBE-<datum>'`,
`SELECT count(*) …` = 1 + Dashboard zeigt Datensatz, leere DB = rot);
defekter Dump (fehlerhafte `CREATE TABLE`) muss rot; T-080-Negativprobe
(VM + RECOVERY, Wegwerf-Postgres).

Required correction from review:
Exakte Pfad-A-Zeile (`-v ON_ERROR_STOP=1`, Abbruch vor `up -d`) + exakte
Verifikation (`SELECT count(*)` auf bekannter Testzeile + Login mit
Datensatz, nicht nur 200); Defekt-Fixture rot.

How PLAN-v3 addresses it:
Wörtlich umgesetzt; `SELECT 1`/`/healthz`-allein als Beleg explizit
ausgeschlossen.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-014

Status:
CLOSED

Evidence:
PLAN-v3.md B2-002 Z126–147 + C-004 Z917–922: Schritt 10 (Z1559–1571)
echter DNS, Domain-SNI, kein `--resolve`, `--max-time 10`, unverändert
(Umstellung verboten, DNS-Coverage bleibt); Update single-shot
`--resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz"`
`--max-time 60` (On-Demand 5–30 s); Boot bestehende 30×10-Loop
`--resolve …` Domain-SNI `--max-time 10`, WARN bei unparsbar; überall
SNI = Domain, nirgends `127.0.0.1` (kein `-H Host:` gegen
`https://127.0.0.1`); Caddy-Log-Grep (`obtaining certificate` ohne
`127.0.0.1`); Tests T-090/T-091/T-110 + Grep.

Required correction from review:
Wörtlich pro Stelle (10 unverändert 10 s, Update `--resolve` 60 s,
Boot `--resolve` 10 s im Loop, WARN bei unparsbar, SNI = Domain,
Log-Grep).

How PLAN-v3 addresses it:
Wörtlich umgesetzt; Copy-Paste- (60 s in Boot) und
Vereinheitlichungs-Fehler (`--resolve` in Schritt 10) explizit verboten.

Remaining gap:
Keiner (Phase-B-Matrix Z567 `kanonische Probe an allen 3 Stellen (Update,
Boot, Schritt 10 als Referenz)` ist unglücklich formuliert, normativ gelten
B2-002/C-004; siehe N-02).

Functional impact:
NONE

---

## PV-015

Status:
CLOSED

Evidence:
PLAN-v3.md Z531–545: `ai-review/TEST_PLAN.md` Master-Matrix, PLAN-v3 nur
B2-Delta (T-071b, T-090/T-091/T-110 inkl. T-110-rot, Hex-Vollvorrat +
`ps`/`inspect`-Grep, T-026 inkl. Residual, T-102-erweitert, Downgrade-Probe
inkl. IPv6/`numbered`/weltweit/No-UFW, T-080-negativ + Datenprobe,
T-004-`caddy validate`); Ablage `tests/` STATIC/UNIT-LIKE-Harness inkl.
T-007-Selbsttest; nur-VM-Anteile (Handshake, Full-Restore, Reboot, Destroy)
ausschließlich dort mit Artefakt; `TEST_PLAN.md` wird als Delta nachgezogen,
bis dahin Phase-B-Matrix für B2-Umfang.

Required correction from review:
Ein Satz (Phase-B-Matrix für B2-Umfang / TEST_PLAN-Delta nachziehen oder
superseded; `tests/`-Harness + T-007-Selbsttest Bad-YAML/SC-Analogon rot).

How PLAN-v3 addresses it:
Source-of-Truth + Übergangsvorrang + Ablage + Nachzugspflicht festgelegt;
B2-Tests damit ausführbar statt lose erwähnt.

Remaining gap:
Keiner.

Functional impact:
NONE

---

# Blocking Issues Remaining

Keine. PV-002 (BLOCKER, Secret-Architektur) und PV-004 (BLOCKER,
Offsite/kritische Ds) sind vollständig geschlossen.

# Must-Fix Issues Remaining

Keine. PV-003 (Hash-Ort + Residual) und PV-005 (VM-Gate + Doku-Gates in DoD)
sind vollständig geschlossen.

# Partial Issues

- PV-001 (SHOULD_FIX, PROCESS): Zählweise + Setup-Leerheit belegt, aber
  HEAD-Angabe (`a09c591` vs. aktuell `afa13c0`) und Delta-Klammer
  (`nur PLAN-v3.md`) unpräzise. Impact NONE.
- PV-009 (SHOULD_FIX, COMPLETENESS): Ablauf, Abdeckung, Bypass-Syntax,
  Negativ-Fixtures und Tests konkret; wörtlicher UFW-Regex und wörtlicher
  Restore-Befehl erst im PR. Impact MEDIUM (verpasste restriktive Regel →
  stilles Öffnen; falscher Regex → falscher Abort).

# Non-Blocking Open Issues

Keine vollständig offenen PVs. Einziges prozessuales Residuum ohne
Funktionswirkung ist die PV-001-HEAD/Delta-Präzisierung (SHOULD_FIX, NONE).

# New Plan Contradictions

- N-01 Doku-Präzision (LOW/NONE): Z10 `nur ai-review/PLAN-v3.md als Delta`
  vs. Realität (`PLAN-v3.md` + `PLAN-v3-REVIEW.md`; HEAD-Drift `a09c591` →
  `afa13c0`). Setup-Aussage (kein Setup-Diff) wahr, Klammer falsch.
  Fix: HEAD auf `afa13c0` heben, Delta als `nur ai-review/*` formulieren.
- N-02 Matrix-Wortlaut (LOW): Phase-B-Matrix Z567 `kanonische Probe an allen
  3 Stellen (Update, Boot, Schritt 10 als Referenz)` vs. B2-002/C-004
  (Schritt 10 Real-DNS, `--resolve`-Verbot). Normativ eindeutig (B2-002),
  informativ missverständlich. Fix: `Schritt 10 Real-DNS-Referenz ohne
  --resolve` schreiben.
- N-03 Delegationsrest (MEDIUM, = PV-009-Gap): B2-004 `Regex wörtlich im PR`
  vs. Plan-Validierung Z1211–1213 `keine Architekturentscheidung delegiert`.
  Bypass-Syntax ist entschieden, Detektor-Zeichenkette nicht. Kein kritischer
  Architekturwechsel, aber Bruch des `exakter Detektor im Plan`-Versprechens.
  Fix: Regex + Restore-Befehl wörtlich in B2-004 aufnehmen.
- N-04 Regel-1-Ausnahme fehlt (TRIVIAL/NONE): C-001 lokale Funktion bei
  2 Call-Sites vs. Complexity-Regel 1 (Helfer erst ab drittem Verwender).
  Bereits im REVIEW als trivial benannt. Fix: Ausnahme `lokale Funktion im
  selben Heredoc` in Regel 1 aufnehmen oder C-001 zurückstellen.
- Kein neuer Security-/Recovery-/Gate-Widerspruch: B2-003 verbietet
  `docker exec -e` (kein `inspect`-Leak), B2-007 ändert nur Hash-Ort
  (kein Refactoring im Fix), Stop-Regel/DoD konsistent, `check.sh`-85-% als
  WARN/UNVERMESSEN markiert (kein Fantasiewert), kein Proxy/`ask`/
  DOCKER-USER/Key-only-Schnellschuss.

# Final Assessment

PV-002, PV-004, PV-005 vollständig geschlossen; kein BLOCKER und kein
MUST_FIX offen. Offen bleibt PV-009 als PARTIAL mit funktionaler Wirkung
(MEDIUM): UFW-Detektor ohne wörtlichen Regex und ohne wörtlichen
Restore-Befehl ist implementierbar und testbar umzäunt, aber nicht
verwechslungsfrei im Plan festgeschrieben (Kriterien konkret/eindeutig nicht
voll erfüllt). PV-001-PARTIAL ist ohne Funktionswirkung. Kritische
V2-Regressionen sind bis auf diesen Detektor-Rest eindeutig spezifiziert.
Daher kein READY.

NOT_READY_FOR_IMPLEMENTATION
