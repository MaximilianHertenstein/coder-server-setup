# PLAN-v3-REVIEW – Independent Plan Validation (Falsifikationsversuch)

Stand: 2026-09-27. Geprüft: `ai-review/PLAN-v3.md` (993 Zeilen) gegen
`setup-coder.sh` (1615 Newlines / 1616 logische Zeilen, HEAD `52493de`),
`ssh-harden.sh` (80), `RESTORE.md` (68), `templates/allowlist.md` (34),
`tests/` (leer), `AGENTS.md`, `copilot-instructions.md`,
`ai-review/01`–`08`, `PLAN.md`, `PLAN-REVIEW.md`, `TEST_PLAN.md`,
`POST-IMPLEMENTATION-PLAN.md`, `IMPLEMENTATION-REPORT-v2.md`,
`FINAL-BREAKER-v2.md`.

Regeln: keine Codeänderung, keine Implementierung, keine Änderung an
PLAN-v3.md oder anderen Dateien, keine Produktivserver-Befehle. Nur diese
Datei wurde erstellt.

Vorab-Urteil: PLAN-v3 ist die mit Abstand beste Planungsiteration in diesem
Repo (B2-001/B2-002-Ursachen korrekt verstanden, Fixture-Größen-Falle
explizit benannt, kein leerer Offsite-Default, kein stiller Proxy/ask/
DOCKER-USER/Key-only-Schnellschuss, Heredoc-Auszug korrekt zurückgestellt).
Als Freigabe-Basis ist der Plan trotzdem **nicht bereit**: B2-003 überlässt
eine Secret-Architekturentscheidung dem Implementierer (BLOCKER), B-008/
kritische Ds fehlen im Phase-C-Stop (BLOCKER), DoD erlaubt `_offen_` für
CRITICAL und referenziert das VM-Gate nicht explizit (MUST_FIX), B2-007-
Ortsangabe ist bei wörtlicher Lesung falsch (MUST_FIX). Details unten.

Klassifizierung pro PV: BLOCKER | MUST_FIX | SHOULD_FIX | NICE_TO_HAVE |
FALSE_POSITIVE. Kategorien wie vorgegeben.

---

## PV-001 – Baseline-HEAD veraltet (Setup-Code unberührt, daher kein Bruch)

Classification:
SHOULD_FIX

Category:
PROCESS

Location:
PLAN-v3.md Z.3–5 („Baseline: Branch ai/implementation-v2, HEAD eadb61a")

Problem:
Aktueller HEAD ist `52493de`, nicht `eadb61a`. `setup-coder.sh` hat 1615
Newlines (`wc -l`) / 1616 logische Zeilen (letzte Zeile ohne Newline, vgl.
01/F-006) – PLAN nennt 1616, was logisch stimmt, aber die HEAD-Angabe ist
veraltet.

Evidence:
`git log --oneline -5` → `52493de` (HEAD) über `eadb61a`;
`git diff eadb61a..HEAD --stat` → nur `ai-review/PLAN-v3.md` (+993), kein
Setup-Diff. Alle im Plan zitierten Zeilen (B2-001 Z.918, B2-002 Z.1115–1130 /
Z.765–782, B2-003 Z.248–253 / Z.1202–1214 / Z.1263, B2-004 Z.564–581, B2-006
Z.1445 / Z.1474–1481, B2-007 Z.116–133 / Z.1514–1521) wurden gegen den
aktuellen Stand verifiziert und stimmen.

Why PLAN-v3 is insufficient or wrong:
„Zeilenangaben beziehen sich auf diesen Stand" ist mit falschem HEAD ein
leeres Versprechen. Hier ohne funktionale Folge (Setup-Diff leer), aber der
nächste Leser kann das nicht wissen.

Required change to PLAN-v3:
Baseline auf `52493de` aktualisieren (oder „eadb61a + nur PLAN-v3.md-Delta,
Setup-Diff leer (`git diff eadb61a..HEAD --stat`)" dokumentieren) und
Zählweise klarstellen (1616 logische Zeilen, 1615 Newlines).

Risk if unchanged:
Misstrauen gegen alle Zeilenreferenzen, unnötige Re-Verifikation.

Suggested test:
`git rev-parse --short HEAD` + `git diff eadb61a..HEAD --stat` im
Freigabe-Protokoll.

---

## PV-002 – B2-003 überlässt Secret-Handling dem Implementierer (stille Sicherheitsentscheidung)

Classification:
BLOCKER

Category:
SECURITY

Location:
PLAN-v3.md B2-003 Z.144–187 („eine der beiden, dokumentiert wählen, kein
doppeltes Raten" + „`docker exec -e PGPASSWORD=...`-Trade-off dokumentieren:
`ps`- vs. `inspect`-Sichtbarkeit")

Problem:
Varianten (a) lesendes Alt-PW als `PGPASSWORD` vs. (b) manueller
Migrationspfad sind keine äquivalenten Optionen, sondern zwei verschiedene
Secret-Architekturen. (a) zerfällt weiter in zwei Untervarianten mit
entgegengesetztem Leck: unquotiertes Heredoc interpoliert Sonderzeichen
kaputt (aktuell Z.1263/Z.1271/Z.1281 `<<INNER_EOF`), `docker exec -e`
erscheint in `docker inspect` (02/F-015: Container-Env für Docker-Admins
lesbar). Der heutige STDIN-Weg ist bewusst anti-`ps`-Leak (01-Befund positiv
bestätigt). „Dokumentiert wählen" heißt: Der Implementierer trifft im
Implementierungs-PR eine Architekturentscheidung über Secret-Sichtbarkeit,
die Phase D („Code bleibt bis zur Entscheidung unverändert, kein
Proxy-/ask-/DOCKER-USER-/Key-only-Schnellschuss") gerade verbietet. Zusätzlich
unvollständig: Z.1281 (Grafana-Heredoc) nicht genannt, Zeichenvorrat nicht
definiert (Legacy$Pass!23, Spaces, Quotes genannt – `$`, Backtick, `!`
(History), Newline, UTF-8, führendes `-` nicht), Ersatzmeldung („darf nicht
auf Reset verweisen") ohne Wortlaut.

Evidence:
Setup Z.1263–1283 drei unquotierte Heredocs; Z.1258–1262 Kommentar begründet
STDIN gegen `ps aux`; 02/F-015 belegt `docker inspect`-Lesbarkeit von Env;
Breaker-Repro B2-003 belegt Pingpong (Setup verweist auf Reset Z.250–252,
Reset auf sich selbst Z.1211–1213).

Why PLAN-v3 is insufficient or wrong:
Fail-closed ohne Ausgang (HIGH, CONFIRMED) wird mit „wähle (a) oder (b)"
nicht geschlossen, sondern an den Implementierer delegiert. Falsche Wahl =
Secrets in `ps`/`inspect` oder weiter gebrochen bei Quotes.

Required change to PLAN-v3:
Eine Variante festschreiben (empfohlen: (a) mit quotiertem Heredoc
`<<'INNER_EOF'` + altes PW ausschließlich als Env-Wert via STDIN, nie in
SQL/URL interpoliert, neues PW Hex; `docker exec -e` nur mit Begründung +
`inspect`-Warnung, kein Default). Exakte Stellen (Z.1263/Z.1271/Z.1281),
exakter Ersatztext für beide Gates (Setup verweist auf manuelle Migration
ODER Reset akzeptiert lesend, nie Reset→Reset), exakter Zeichenvorrat für
die Fixture (inkl. `$`, Backtick, `"`, `'`, Space, führendes `-`; Newline
als dokumentiert abgewiesen, nicht still getrimmt).

Risk if unchanged:
Implementierer baut `ps`- oder `inspect`-Leck auf Produktion, oder
Pingpong bleibt (zweite Meldung zeigt weiter auf Reset).

Suggested test:
Hex-Migrations-Test (VM, echte DB + `ALTER USER`): Legacy-`.env`
(`Legacy$Pass!23`, Spaces, Quotes, `$`, Backtick) durch beide Gates → genau
ein grüner Weg, danach beide Gates grün; `ps aux` + `docker inspect`-Grep
während Rotation zeigt kein Secret; UNIT-LIKE Regex-Probe zusätzlich, nie
als Ersatz.

---

## PV-003 – B2-007: „dort, wo heute note_drift steht" ist vor dem Schreiben (falscher Ort)

Classification:
MUST_FIX

Category:
CORRECTNESS

Location:
PLAN-v3.md B2-007 Z.258–289 („Hash unmittelbar nach jeder Schreibstelle
festschreiben (dort, wo heute `note_drift` steht), Schritt-10-Schleife
entfernen")

Problem:
`note_drift` steht VOR jedem `tee` (z. B. Z.293 vor Z.294, Z.468 vor Z.469,
15 Stellen), `remember_hash` muss NACH `tee`/`mv`/`chmod` stehen. Wörtlich
implementiert committet der Fix den Hash der ALTEN Datei – Drift danach
permanent falsch (invertierter Fehlalarm). Residualfenster (Kill zwischen
`tee` und Hash) wird verschwiegen; es ist kleiner als heute (eine Zeile
statt 8 Schritte), aber nicht null.

Evidence:
15 `note_drift`-Aufrufe (Z.293/468/488/593/706/740/798/814/827/841/986/993/
1059/1184/1328) je vor Schreibstelle; einziger Commit Z.1514–1521 (Schritt 10);
jeder `exit 1` davor (Hex-Gate Z.252, Daemon-Preflight Z.512, `set -e`)
lässt stale Hashes zurück (Breaker-Repro B2-007 mit exakter Helper-Logik).

Why PLAN-v3 is insufficient or wrong:
Ortswechsel in die falsche Richtung vertauscht nur die Fehlalarm-Richtung.
T-026 würde das bei wörtlicher Umsetzung nicht fangen, weil T-026
„Abbruch nach Schritt 2 → Heilungslauf ohne Fehl-WARN" mit Hash-vorher
trotzdem rot meldet (Hash = alt, Datei = neu).

Required change to PLAN-v3:
„Unmittelbar NACH jeder `tee`/`mv`/`chmod`-Stelle (nicht an der
`note_drift`-Zeile davor), Schritt-10-Schleife löschen, 600-Modus +
Abdeckung aller 15 Dateien behalten, deterministische Regeneration +
WARN-nie-interaktiv behalten." Residualfenster als bekannte Restkante
dokumentieren (Kill zwischen Write und Hash → einmalige Fehl-WARN,
kein Datenrisiko).

Risk if unchanged:
Permanente falsche Drift-WARNs (inkl. B-007-Downgrade-WARN als Rauschen),
Warnmüdigkeit als Security-Risiko.

Suggested test:
T-026 erweitert (VM + UNIT-LIKE): Abbruch nach Schritt 2 (Datei neu, kein
Hash-Commit) → Heilungslauf ohne Fehl-WARN für setup-eigene Residuen;
echte Hand-Drift (eine Zeile von Hand) → WARN bleibt.

---

## PV-004 – B-008/Offsite und kritische Ds fehlen im Phase-C-Stop; DoD akzeptiert `_offen_` für CRITICAL

Classification:
BLOCKER

Category:
RECOVERY

Location:
PLAN-v3.md Phase C Stop-Regel Z.509–514; DoD Z.979–987; Phase E/D-Offsite
Z.587–599/Z.700–708

Problem:
Stop-Regel verlangt grün für B2-001/002/003, B-002-Pull-Probe, B2-009,
B-004-Inventar+T-063+D-Socket-Frist, B2-004, Blocking-0 – aber NICHT B-008
Offsite+RTO, NICHT B2-005-Limit-Doku, NICHT D-TLS/D-SSH/D-Offsite mit
Frist. DoD verlangt „alle D-Entscheidungen mit Eigentümer + Datum/Frist
ODER sichtbar `_offen_`". `_offen_` ohne Eigentümer/Frist erfüllt DoD also
auch für D-Socket (Host-Takeover), D-TLS (Budget-DoS), D-SSH (weltweites
Passwort), D-Offsite (Totalverlust). „VM-Gate grün" kann als
produktionsbereit gelesen werden, während Plattenverlust = Totalverlust
(05/F-002 CRITICAL, CONFIRMED, kein rsync im Code; RESTORE RTO `_offen_`;
Breaker-Blocking 5).

Evidence:
Code: einziger Schreibpfad `${BACKUP_DIR}` unter `/opt`, grep-negativ für
rsync/scp/rclone; RESTORE Z.66–68 RTO `_offen_`; PLAN Phase E selbst:
„kein leerer Dauer-Default" (korrekt), aber ohne Frist im Stop.

Why PLAN-v3 is insufficient or wrong:
Richtiges Ziel (kein leerer Dauer-Default, P-014-Lehre) ohne Durchsetzung.
DoD mit `_offen_`-Alternative für kritische Ds ist Freigabe mit bekanntem
Totalverlust.

Required change to PLAN-v3:
Stop-Regel ergänzen: B-008 (Offsite-Probe T-082 + RTO-Zahl im Repo) +
B2-005-Limit-Doku + `logrotate` für tls/boot-Logs + T-125; DoD verschärfen:
D-Socket/D-TLS/D-SSH/D-Offsite (CRITICAL/HIGH) brauchen Eigentümer + Frist
vor Produktion, `_offen_` genügt nur für LOW/MEDIUM mit Verfallsdatum +
Ticket. Alternativ ehrlich: „ohne Offsite keine Produktion" als Satz in
Stop-Regel.

Risk if unchanged:
Produktion mit täglichen, verifizierten, aber ausschließlich lokalen Dumps;
erster Platten-/Host-Verlust ist irreversibel (größter realer Schaden:
Workspace-Unterrichtsdaten, 05/F-015).

Suggested test:
T-082 (Snapshot verwerfen, nur aus Offsite + Runbook, RTO gestoppt, Zahl +
Datum + Versionen + Dump-Alter + Login ok in Tabelle) + Transportfehler-
Trennung (lokal grün / Transport rot, getrennte Exit-Codes).

---

## PV-005 – DoD referenziert das VM-Gate und die Doku-Gates nicht explizit

Classification:
MUST_FIX

Category:
PROCESS

Location:
PLAN-v3.md Z.979–987 (Done) vs. Phase C Z.500–507 (Pflicht) und Phase G
Z.862–868 (Verifikation)

Problem:
DoD verlangt MUST_FIX-Tests + Static Gates (T-001/002/003/004/007) + D +
RTO + Inventar + Handshake, aber nicht wörtlich „Phase-C-Pflicht grün"
(Fresh/Second/Third/Interrupted/Reboot/Backup/Restore/Update/Rollback/
Security Smoke/Caddy-TLS/Workspace-Isolation). „Artefakt auf Test-VM" kann
als „nur MUST_FIX-Tests brauchen VM" gelesen werden – Second Run (T-020),
Reboot (T-110–113), Security Smoke (T-060–069) wären dann optional, obwohl
sie B-011-, Idempotenz- und Socket-Regressions fangen. Doku-Gates
(`test -f` + `grep`-Stichworte + `_offen_`-Zählung + `tail -5 CHANGELOG`)
stehen in Phase G, aber nicht in DoD.

Evidence:
Phase C Pflichtliste vollständig (Fresh/Second/Third/Interrupted/Reboot/
Backup/Restore/Update/Rollback/Security/Caddy/Workspace mit Artefaktpflicht
Datum/VM/Commit/Tool-Versionen/Exit-Codes/Logs); DoD zitiert sie nicht.

Why PLAN-v3 is insufficient or wrong:
Gate-Bypass per Lesart: lokal grün + MUST_FIX-VM-Tests grün = „Done", ohne
je Reboot/Second-Run/Security-Scan gefahren zu sein.

Required change to PLAN-v3:
DoD ergänzen: „Phase-C-VM-Gate grün (alle Pflichttests mit Artefakt, nie
Produktion) + Phase-G-Verifikation grün (`test -f` + Stichwort-Greps +
`_offen_`-Zählung + `tail -5 CHANGELOG` + `ls tests/` nicht-leer +
datierter VM-Protokoll-Eintrag mit RTO-Zahl, C-015-Meta-Test)". Static Gates
bleiben, VM-Gate kommt hinzu.

Risk if unchanged:
Ungetesteter Reboot (03:00-Blindheit), ungetesteter Second Run
(GID/Drift/Caddy-Restart), ungetesteter Socket (T-063) als „Done".

Suggested test:
C-015-Meta-Test als DoD-Gate: `ls tests/` nicht-leer + ein datierter
VM-Protokoll-Eintrag (RTO-Zahl) vor jeder Freigabe; Referenz-Check
T-006-Gate gegen PLAN-v3 (kein Dangling, kein Trunkierungsmarker).

---

## PV-006 – C-003 `.domain`-Datei verletzt eigene Regel 1 und erzeugt stale Source

Classification:
SHOULD_FIX

Category:
ARCHITECTURE

Location:
PLAN-v3.md Phase F C-003 Z.740–745 (Parser durch `/opt/coder/.domain`-Datei
ersetzen)

Problem:
Neue Zustandsdatei für 2 Verwender verletzt Complexity-Regel 1 („Helfer erst
ab drittem Verwender; Heredoc-/Laufzeitgrenzen schlagen DRY"). Schlimmer:
`.domain` (aus `${DOMAIN_CODER}` geschrieben) vs. live-Caddyfile (ggf. von
Hand gedriftet) divergieren – Gates prüfen dann die falsche Domain (falsches
Grün/Rot), während Caddy die gedriftete Datei serviert. Live-`awk` respektiert
heute Hand-Drift (mit WARN). Keine Spec: Pfad-Rechte (600? 644?), Drift-Hash
(16. Datei?), Domain-Wechsel-Rewrite (bei Env-Override?), Missing-File-
Fallback, wer schreibt wann (Schritt 2 deterministisch?), Verhältnis zur
Caddyfile-Generierung (gleiche Variable = single source?).

Evidence:
Z.765/Z.1115 byte-identisches `awk -F'[ ,{]+' '/\*.*\{/ {print $1; exit}'`;
Caddyfile Z.469–485 aus `${DOMAIN_CODER}` generiert; 07/C-003 selbst nennt
Alternative „Kommentar-Referenz (mit Z.765/1115 synchron halten)".

Why PLAN-v3 is insufficient or wrong:
Duplikat-Entfernung mit neuem State ohne Sync-Beweis. Billigere Variante
(Sync-Kommentar, 0 neue Dateien) nicht widerlegt.

Required change to PLAN-v3:
Entweder (bevorzugt, minimal): Duplikat behalten + Sync-Kommentar, `.domain`
erst bei drittem Parser (Regel 1). Oder falls Datei: `/opt/coder/.domain`
deterministisch in Schritt 2 aus `${DOMAIN_CODER}`, 644/root, in Hashliste
(dann 16 Dateien), beide Skripte lesen mit WARN-Fallback bei
fehlend/unparsbar, Caddyfile-Generierung nutzt dieselbe Variable (single
source), Tests: Spacing-Change + Domain-Wechsel + gelöschte Datei +
hand-editierte Caddyfile (Gate muss WARN oder Live-Domain zeigen, nie
falsches Grün).

Risk if unchanged:
Gates prüfen stale SNI (B2-002-Rezidiv), TLS-Smoke für falsche Domain grün.

Suggested test:
Caddyfile-Spacing ändern → beide Gates finden Apex oder melden WARN, nie
falsches Grün; Domain-Wechsel-Re-Run → `.domain` + Caddyfile synchron;
Datei gelöscht → WARN statt Fail.

---

## PV-007 – B2-008-Filter ohne konkrete Abbildung, UDP-Lücke

Classification:
SHOULD_FIX

Category:
TESTING

Location:
PLAN-v3.md B2-008 Z.290–317 („`ss -tlnp`-PIDs gegen `docker compose ps`-
Ports abgleichen; nur Fremd-Listener → WARN")

Problem:
Abbildung unspezifiziert: `ss -tlnp` zeigt Host-PIDs (docker-proxy), nicht
`coder-*`-Namen; `docker compose ps` zeigt Ports, nicht PIDs. Ohne
`docker port`/`docker inspect --format '{{.HostConfig.PortBindings}}'` +
Projekt-Filter ist das nicht implementierbar; zu aggressiver Filter schluckt
echte Konflikte (z. B. Fremd-Listener auf 9090). Zusätzlich: `ss -tlnp` ist
TCP-only – UDP 443 (QUIC, Caddy `443:443/udp` Z.353) wird nie geprüft,
obwohl Schleife Z.516 `443` ohne tcp/udp-Trennung matcht.

Evidence:
Z.516–520 reiner `ss`-Match ohne Compose-Abgleich; Z.508 Kommentar gibt
Eigenbelegung zu; Z.353 UDP-Binding vorhanden, kein `ss -ulnp` im Preflight.

Why PLAN-v3 is insufficient or wrong:
Unimplementierbare Anweisung + Over-Filter-Risiko (echte Hijacks still) +
UDP-Blindheit. Positivprobe („Fremd-Listener auf 80 → WARN") genügt nicht
(9090/9100/3001-Fremd-Fälle fehlen).

Required change to PLAN-v3:
Konkreten Filter festschreiben (z. B. `ss -tlnpu` + Abgleich exakter
IP:Port gegen `docker inspect` der Projekt-Container `coder-*`, nur exakte
Treffer suppressen, sonst WARN mit Prozessname; keine Ports aus Prüfung
streichen). UDP 443 explizit (`ss -ulnp` oder deklariert ungeprüft mit
Begründung). Beide Fixtures Pflicht: gesund → keine WARN; fremd auf 80 UND
auf 9090 → WARN.

Risk if unchanged:
Warnrauschen bleibt oder echte Konflikte werden suppressiert (zweite
Warnmüdigkeit neben B2-007/B2-002).

Suggested test:
Re-Run-Probe (VM): gesund → keine Port-WARN; Fremd-Listener auf 80 und auf
9090 → je WARN mit Prozessname (Kategorie VM).

---

## PV-008 – Phase H unvollständig (Host-Dateien fehlen), C-012-Budget unprüfbar

Classification:
SHOULD_FIX

Category:
ARCHITECTURE

Location:
PLAN-v3.md Phase H Z.872–906; C-012 Z.784–808

Problem:
H listet 9 Heredoc-Artefakte + ssh-harden (Repo-Referenz), verschweigt die
ebenfalls heredoc-generierten Host-Dateien (`jail.local`,
`52-coder-reboot`, 3 Cron-Dateien, `logrotate`) – bleiben sie für immer
Heredoc (warum?), oder gehören sie zu B (dann Escaping-/Rechte-/Idempotenz-
Retest für sie)? C-012-Budget („Tests auf VM grün + dritter Shared-Bedarf")
undefiniert: C-006 (3 `.env`-Varianten) und C-009 (2 Retries) sind per
eigener Analyse explizit NICHT zu vereinheitlichen – welcher Triple löst
dann `lib.sh` aus? Derzeit kein Kandidat, Budget also nie reif (= Monolith
für immer, ehrlich, aber dann so schreiben).

Evidence:
15 Drift-Dateien (Schritt-10-Schleife Z.1514–1521) vs. 9 H-Dateien;
07/C-006/C-009 als Nicht-Faltungs-Präzedenz.

Why PLAN-v3 is insufficient or wrong:
Teilmigration (nur Compose/Caddy) hinterließe Drift-Split (Hashstore vs.
`diff tmpl vs. Host` für verschiedene Dateien). Budget ohne Beispiel ist
kein Gate.

Required change to PLAN-v3:
Alle 15 Dateien in H-Scope aufnehmen (Host-Dateien bleiben bis Budget-Reife
Heredoc, danach gleiche Byte-Vergleichs-Regel); Budget konkretisieren
(„dritter identischer Runtime-Helper in standalone Skripten, C-006/C-009-
Präzedenz ausgenommen; bis dahin kein `lib.sh`") + Byte-Vergleich
`diff <(alt-generiert) <(neu-generiert)` bei Defaults muss leer sein +
volle T-Matrix (T-020/T-026/T-003/T-004/T-002, Idempotenz/Drift, Caddy-nur-
bei-Änderung, fail2ban-Bans bleiben) als H-Gate behalten.

Risk if unchanged:
Partieller Auszug mit Escaping-Bruch bei Secrets/URLs (P-010-Falle:
`<<EOF` mit Domain-Expansion Z.224/294/469 vs. `<<'EOF'` ohne).

Suggested test:
Bei Auszug: Byte-Vergleich + volle T-Matrix auf Test-VM (wie geplant,
erweitert um Host-Dateien).

---

## PV-009 – B2-004-Abbruch ohne Bypass macht gehärtete Hosts un-rerunbar

Classification:
SHOULD_FIX

Category:
COMPLETENESS

Location:
PLAN-v3.md B2-004 Z.189–224 („hart abbrechen mit Anleitung, kein
automatisches Wiederherstellen")

Problem:
Harter Abbruch bei jeder restriktiven Regel ohne Bypass-Flag/Env blockiert
legitime Re-Runs (Version-Bump, Caddyfile-Change) auf gehärteten Hosts: Der
Operator muss Härtung manuell revertieren (Downgrade, den der Fix verhindern
soll), Setup fahren, Härtung manuell wieder anlegen (Fehlerquelle). Detektor-
Erweiterung („`ufw status numbered`-Formate, `22 ALLOW <ip>`,
OpenSSH-Profil mit Quelle, `22/tcp` + `22` ohne Suffix") ohne exakten Regex,
ohne IPv6-`(v6)`-Zeilen, ohne Default-Weltweit-Negativ-Fixture (darf NICHT
abbrechen), ohne No-UFW-Fall.

Evidence:
Z.564 Detektor `22/(tcp|ssh).*(ALLOW|LIMIT).*([0-9]{1,3}\.)` matcht
`10.16.0.0/12`-Zeile, aber nicht `22 ALLOW 192.168.1.0/24` (Breaker-Repro per
`grep -E`); Z.571–573 drei `delete`-Zeilen + Z.581 `limit 22/tcp` ohne
Abbruch/Opt-out.

Why PLAN-v3 is insufficient or wrong:
Fix löst Downgrade, schafft aber Non-Konvergenz (gehärtet = nie wieder
Setup). „Mit angepasster Regel fahren" ohne Mechanismus ist Handwedeln.

Required change to PLAN-v3:
Exakten Detektor + Negativ-Fixtures (weltweit + `limit` → kein Abbruch;
kein UFW → kein Abbruch mit Hinweis) + Bypass-Verfahren festschreiben
(z. B. restriktive Regel notieren (`ufw status numbered` vorher/nachher im
Protokoll), Setup mit dokumentierter angepasster Regel fahren ODER Regel
nach Lauf verifiziert wiederherstellen – eines davon, kein „wähle im PR").
Kein automatisches Wiederherstellen ohne Verifikation (korrekt), aber
Wiederherstellungs-Befehl mit Check angeben.

Risk if unchanged:
Härtung wird revertiert (Sicherheitsverlust) oder Setup wird nie wieder
gefahren (Update-/Drift-Stau).

Suggested test:
T-062 + Re-Run-Downgrade-Probe (VM + UNIT-LIKE gegen reale `ufw status`-
Zeilenformate beider Schreibweisen + weltweit-Negativ): restriktive Regel →
Abbruch oder Erhalt mit vorher/nachher-Protokoll, nie stilles Öffnen.

---

## PV-010 – Boot-Rot-Probe fehlt, check.sh ohne Pfad/SNI-Bindung

Classification:
SHOULD_FIX

Category:
TESTING

Location:
PLAN-v3.md Phase B Matrix Z.430–448 (T-110 nur grün); Phase E Z.668–676
(check.sh)

Problem:
T-110 verlangt `BOOT-GATE GRÜN` im laufenden Log (korrekt, nicht kumulativ
– boot-check Z.787–795 greppt `$OUT`), aber keine Rot-Probe (Postgres down /
Coder gestoppt → `BOOT-GATE ROT` + Exit 1). Immer-grünes Boot-Gate bestünde
T-110. check.sh („Cron täglich nach Backup, nur lesend, eine Zeile ins
Backup-Log, `df` >85% → Warnung + Exit≠0 + `/healthz`-Status") ohne Pfade
(`/opt/coder/check.sh`? `/etc/cron.d/coder-freshness`? welches Log?
Rotation/Leser/Eigentümer?), ohne SNI-Bindung (muss kanonische
`--resolve`-Probe nach B2-002 nutzen, nicht Host-Header-Rezidiv), 85% ohne
Messung (neuer UNVERMESSEN-Wert neben 500 MB).

Evidence:
boot-check Z.749–795 (30×10-Schleife, `$OUT`-Auswertung korrekt);
`coder-backup.log` hat logrotate, `coder-boot.log`/`coder-tls.log` nicht
(B2-005-Nebenpunkt korrekt erkannt).

Why PLAN-v3 is insufficient or wrong:
Grün-nur-Gate + pfadloses Check-Skript = nächste B2-002-Klasse (SNI-Bug im
neuen Skript) + unrotiertes Log.

Required change to PLAN-v3:
T-110-rot hinzufügen (kranker Boot → ROT + Exit 1, Log im laufenden `$OUT`
belegt); check.sh konkretisieren (Pfad, 755/root, Cron-Pfad/Zeit
„täglich nach 01:00-Backup", Log in `coder-backup.log` (rotiert) oder
eigener Pfad + logrotate, Leser/Eigentümer = morgendlicher Operator-Check,
`--resolve`-Probe + `df`-Schwelle bis D-Monitoring als WARN/UNVERMESSEN,
kein Alertmanager – korrekt).

Risk if unchanged:
Boot-Gate immer grün, neues Skript mit altem SNI-Fehler, unrotiertes
Check-Log als nächster Plattenfresser.

Suggested test:
Gesunder Boot → GRÜN; Postgres gestoppt → ROT + Exit 1; Backup absichtlich
fehlschlagen → check.sh rot (nicht nur Log); tmpfs-voll → Schwellen-Warnung;
`logrotate --debug` grün.

---

## PV-011 – Phase A als Bundle ohne Commit-/Test-Ordnung

Classification:
SHOULD_FIX

Category:
PROCESS

Location:
PLAN-v3.md Z.969–972 („Phase A (B2-001→…; jeweils einzeilig, kein
Zusammenspiel) + lokale STATIC/UNIT-LIKE-Belege")

Problem:
B2-007 ist nicht einzeilig (15 Schreibstellen + Loop-Löschung) und berührt
dieselben Dateien wie B2-004 (Schritt 4) und B2-008 (Schritt 3). Ohne
Commit-Reihenfolge (Backup→Gates→Warn, wie Z.45 korrekt sagt) und ohne
Per-Fix-Beleg kann ein gebrochenes B2-007 die Verifikation von B2-004
verdecken (Drift-Fehl-WARNs übertönen SSH-Downgrade-WARN).

Evidence:
Z.45 („Reihenfolge = Abhängigkeit (Backup zuerst, dann Gates, dann
Warnsystem)") vs. Z.969 (Gruppierung B2-004/B2-006/B2-007/B2-008/B2-009
ohne Ordnung).

Why PLAN-v3 is insufficient or wrong:
Richtige Ordnung als Satz, aber nicht als Gate (kein „pro B2 ein Commit +
pro B2 ein Artefakt vor nächstem B2").

Required change to PLAN-v3:
Phase A als 8 Commits in Abhängigkeitsreihenfolge (B2-001, B2-002, B2-003,
B2-009? – nein: B2-009-Restore ist Recovery, nach Backup; konkret:
B2-001→B2-002→B2-003→B2-006→B2-007→B2-004→B2-008→B2-009) mit je
STATIC/UNIT-LIKE-Artefakt; T-071b + Handshake + Hex-Migration zuerst
(wie Z.971–972 korrekt sagt) als Merge-Gate vor Rest.

Risk if unchanged:
Bundle-PR mit 8 Fehlerquellen, B2-Rezidiv (kleine Fixture grün,
Produktion rot).

Suggested test:
`git log --oneline` zeigt 8 Phase-A-Commits, jeder mit Test-Artefakt
(Datum, Commit, Exit-Codes).

---

## PV-012 – Handover-Pointer falsch (D-001–D-015 ≠ Checkliste), TROUBLESHOOTING-Entscheidung offen

Classification:
SHOULD_FIX

Category:
DOCUMENTATION

Location:
PLAN-v3.md Phase G Z.862–868 („Handover-Checkliste (D-001–D-015-
Gegenstände...)" + „TROUBLESHOOTING als Verweis oder umgekehrt")

Problem:
D-001–D-015 in 08 sind Doku-Lücken (D-001=README fehlt, D-002=generierte
Dateien unsichtbar…), nicht die Handover-Checkliste. Die Checkliste in 08
ist „Handover Checklist 1–6" (Zugang/Bestand, Voraussetzungen-Gate,
Gesundheit lesend, Backup/Restore-Kern, Wartung erst nach 1–4,
Entscheidungen/Doku, Z.761–852). Falscher Pointer schickt den Operator in
die Lückenliste statt in die Schrittfolge. TROUBLESHOOTING
„OPERATIONS als Quelle, TROUBLESHOOTING als Verweis ODER umgekehrt"
delegiert Single-Source-Entscheidung an den Implementierer – bei Wahl
„umgekehrt" steht die 11-Fehler-Tabelle in der Druck-/Notfall-Datei statt
im Betriebshandbuch.

Evidence:
08 Z.761–852 Checklist 1–6; Z.853–922 Struktur (README ~200, OPERATIONS,
SECURITY, RESTORE, CHANGELOG, Single-Source-Regel).

Why PLAN-v3 is insufficient or wrong:
Operator folgt Lücken- statt Schrittliste; Duplikat-Tabelle driftet
(gegen eigene Regel „kein beidseitiges Kopieren").

Required change to PLAN-v3:
Pointer auf 08-Checklist 1–6 (aus OPERATIONS verlinkt, nicht dupliziert);
Single-Source jetzt entscheiden (empfohlen: OPERATIONS als Quelle,
TROUBLESHOOTING als reine Pointer-Datei ohne Tabellenkopie, verifiziert per
`grep -c`-Guard „Tabelle in genau einer Datei").

Risk if unchanged:
Unvollständige Übernahme (Zugang/Bestand vergessen), divergierende
Fehler→Befehl-Tabellen im Notfall.

Suggested test:
`grep`-Single-Source-Guard + jede Tabellenzeile auf Test-VM je einmal krank
gestellt mit Soll-Output-Protokoll (T-051/T-052/T-073/T-110-Muster).

---

## PV-013 – B2-009-Verifikation ohne konkrete Queries (falsches Grün bleibt möglich)

Classification:
SHOULD_FIX

Category:
RECOVERY

Location:
PLAN-v3.md B2-009 Z.318–346 („Verifikationsschritt (Tabellenzahl /
Probe-Login mit echter Datensicht, nicht nur `/healthz`)"); Phase E
Z.678–689

Problem:
„Tabellenzahl / Probe-Login mit echter Datensicht" ohne Tabelle, ohne Query,
ohne Pass-Kriterium. `SELECT 1` (Liveness) oder reines `/healthz`+Login ohne
Datenabgleich bestünde die Verifikation auf lückigem Schema (exakt der
B2-009-Fehler: `psql` ohne `ON_ERROR_STOP` exitt 0, Schritt 5 prüft keine
Vollständigkeit). `psql -v ON_ERROR_STOP=1`-Stelle im Runbook-Zitat fehlt
(exakte Zeile `zcat … | psql …` mit Flag-Platzierung).

Evidence:
RESTORE Z.32–34 ohne Flag, mit `dropdb --if-exists`/`createdb` (v2-Fix ok,
aber ohne Abbruch-Flag); `psql`-Handbuch (ohne Flag Exit 0 trotz Fehler);
Breaker-Repro B2-009 (defekte `CREATE TABLE` → grün).

Why PLAN-v3 is insufficient or wrong:
Hart-Abbruch ohne Datensicht-Nachweis schließt Teil-Restore nicht aus
(leere DB nach `createdb` ist „gesund" per `/healthz`).

Required change to PLAN-v3:
Exakte Pfad-A-Zeile (`zcat dump | sudo docker exec -i coder-postgres psql
-v ON_ERROR_STOP=1 -U coder -d coder`, Abbruch vor `up -d`) + exakte
Verifikation (z. B. `SELECT count(*) FROM <Coder-Kerntabelle>` >0 mit
vorher bekannter Testzeile aus Pre-Backup + Dashboard-Login zeigt
Test-Datensatz, nicht nur 200). Defekt-Fixture (eine fehlerhafte
`CREATE TABLE`-Zeile) muss rot abbrechen.

Risk if unchanged:
Restore „grün" auf lückigem Schema, RTO-Zahl für kaputten Restore.

Suggested test:
T-080 mit defektem Dump (Negativprobe, VM + RECOVERY, Wegwerf-Postgres, nie
Produktion) → muss rot abbrechen; Voll-Restore T-082 nur aus Offsite +
Runbook mit RTO.

---

## PV-014 – B2-002-Timeouts pro Stelle nicht wörtlich (Boot-Loop-Risiko, Schritt-10-Verwässerung)

Classification:
SHOULD_FIX

Category:
CORRECTNESS

Location:
PLAN-v3.md B2-002 Z.118–130; C-004 Z.746–750

Problem:
Kanonisches Snippet zeigt `--max-time 60`, Text sagt „Timeouts bleiben
unterschiedlich (Update 60 s, Boot 5-Min-Fenster, Schritt 10 als Referenz)".
Boot nutzt heute `--max-time 10` in 30×10-Loop (Z.768–773), Update
`--max-time 60` single-shot (Z.1117), Schritt 10 `--max-time 10` mit echtem
DNS+SNI (Z.1559, korrekt, darf NICHT auf `--resolve` umgestellt werden –
sonst entfällt Real-Pfad-Check). Copy-Paste von 60 s in Boot-Loop = ~30 min
Boot-Fenster; Vereinheitlichung auf `--resolve` überall = Schritt 10 verliert
DNS-Coverage.

Evidence:
Z.1117 (60 s), Z.769 (10 s im Loop), Z.1559 (10 s real DNS); Breaker-Nachweis
SNI aus URL-Host, nicht `-H Host:` (Exit 35 vs. 200 mit `--resolve`).

Why PLAN-v3 is insufficient or wrong:
Richtige Regel („nur Timeouts differieren"), aber ohne wörtliche Per-Stelle-
Flags unimplementierbar ohne Fehlerrisiko.

Required change to PLAN-v3:
Wörtlich pro Stelle: Schritt 10 unverändert (echtes DNS+SNI, 10 s,
Referenz); Update single-shot `--resolve DOMAIN:443:127.0.0.1 … 60 s`;
Boot `--resolve … --max-time 10` in bestehender 30×10-Loop, WARN bei
unparsbar (kein Fail); überall SNI=Domain, nirgends SNI=127.0.0.1; nach Fix
keine On-Demand-Versuche für 127.0.0.1 im Caddy-Log (`obtaining
certificate`-Grep).

Risk if unchanged:
30-min-Boot oder Schritt-10-DNS-Blindheit, SNI-Spam mit Failed-Validation-
Zählern.

Suggested test:
T-090 (gesund→grün mit `HEALTH_CODE=200`-Protokoll), T-091 (Coder gestoppt→
rot), T-110 (gesunder Boot→GRÜN im laufenden Log) + Caddy-Log-Grep
(kein 127.0.0.1-`obtaining`).

---

## PV-015 – TEST_PLAN-Delta fehlt (B2-neue Tests ohne Ablage)

Classification:
NICE_TO_HAVE

Category:
DOCUMENTATION

Location:
PLAN-v3.md Phase B (Matrix ohne TEST_PLAN-Bezug); `ai-review/TEST_PLAN.md`
(2735 Zeilen, ohne T-071b/Handshake/Hex/Drift-Abbruch/Reset-Ordnung/
Downgrade/Defekt-Restore/caddy-validate)

Problem:
Neue Tests (T-071b, Gate-Handshake, Hex-Migration, T-026-erweitert,
T-102-erweitert, Downgrade-Probe, T-080-negativ, T-004-`caddy validate`)
existieren nur in PLAN-v3 Phase B, nicht als Delta zu TEST_PLAN.md oder als
`tests/`-Harness. Nächster Implementierer fährt „nach TEST_PLAN" und
verfehlt genau die B2-Regressionstests (Wiederholung der v2-Lücke:
kleine Fixture grün).

Evidence:
TEST_PLAN T-001–T-126 ohne B2-Namen; `tests/` leer; C-015-Meta-Test verlangt
`ls tests/` nicht-leer.

Why PLAN-v3 is insufficient or wrong:
Testdefinition ohne Ablage verrottet (2735-Zeilen-Plan + 993-Zeilen-PLAN-v3
nebeneinander, unklar was gilt).

Required change to PLAN-v3:
Ein Satz: „Phase-B-Matrix ersetzt TEST_PLAN für B2-Umfang; TEST_PLAN.md wird
als Delta (T-071b, Handshake, Hex, Drift-Abbruch, Reset-Ordnung, Downgrade,
Defekt-Restore, caddy-validate) nachgezogen ODER als superseded markiert;
`tests/` enthält STATIC/UNIT-LIKE-Harness + T-007-Selbsttest (Bad-YAML +
SC-Analogon müssen rot)".

Risk if unchanged:
B2-Tests werden nie gefahren, weil sie in keinem ausführbaren Plan stehen.

Suggested test:
T-007-Harness-Selbsttest + `ls tests/` nicht-leer als DoD-Gate (bereits in
DoD-Text, aber ohne TEST_PLAN-Klärung).

---

# Abschluss

## Blocking Plan Problems

- PV-002 (B2-003 Secret-Wahl an Implementierer, BLOCKER)
- PV-004 (B-008/Offsite + kritische Ds nicht im Stop, `_offen_` genügt für
  CRITICAL, BLOCKER)

## Missing Changes

- PV-003 (B2-007 exakter Nach-Ort + Residualfenster, MUST_FIX)
- PV-005 (DoD: Phase-C-VM-Gate + Doku-Gates explizit, MUST_FIX)
- PV-009 (B2-004 exakter Regex + Negativ-Fixtures + Bypass-Verfahren)
- PV-010 (T-110-rot + check.sh-Pfade/SNI/Rotation)
- PV-013 (B2-009 exakte Zeile + Daten-Queries)
- PV-014 (B2-002 wörtliche Per-Stelle-Flags + Caddy-Log-Grep)
- PV-007 (B2-008 konkrete Abbildung + UDP)
- PV-006 (C-003 Sync-Kommentar statt Datei ODER volle File-Spec)
- PV-008 (Phase H alle 15 Dateien + Budget-Definition)
- PV-011 (Phase A 8 Commits in Abhängigkeitsreihenfolge)
- PV-012 (Handover-Pointer 1–6 + Single-Source-Entscheidung)
- PV-015 (TEST_PLAN-Delta vs. `tests/`-Harness)
- PV-001 (Baseline-HEAD + Zählweise)

## Incorrect Assumptions

Keine neue falsche Tatsachenbehauptung in PLAN-v3 gefunden – im Gegenteil:
B2-001 (SIGPIPE/pipefail/PIPESTATUS 141, Puffer ~64 KB, Kleinst-Fixture-
Tarnung), B2-002 (SNI aus URL-Host, certmagic `getNameFromClientHello`,
Exit 35 vs. `--resolve`-200), B2-004-Detektorlücke (`22 ALLOW <ip>` ohne
/tcp), B2-007-Stale-Hash-Pfad und B2-009-`ON_ERROR_STOP`-Mechanik sind
korrekt verstanden und per Repro-Referenz belegt. PLAN-v3 irrt nicht in der
Ursache, sondern in Spezifikationslücken (PV-002/003/007/009/013/014) und
Gates (PV-004/005). Korrekt zurückgestellt (kein Befund, ausdrücklich
bestätigt): `jail.d`-Include, In-Container-Healthcheck + Caddy-
`service_healthy`, Offsite-Transport (als Entscheidung, nicht als leerer
Hook – P-014-Lehre beachtet), App/DB-Split (Bedienvertrag), Mini-Restore-
Automatisierung (erst mit Test-VM-Entwurf), autoritative DNS-Probe,
Digest-Umstellung, Proxy-Einbau, Alertmanager, Monolith-Auszug,
`retention.size`-Fantasiewert, `CODER_DISABLE_PATH_APPS` ohne Inventar,
DOCKER-USER ohne Dual-Stack-Test, Key-only ohne Zweit-Zugang. Diese
Zurückhaltung ist richtig und minimal.

## Unnecessary Complexity

- C-003 `.domain`-Datei für 2 Verwender (verletzt eigene Regel 1, stale
  Source – PV-006; billiger: Sync-Kommentar bis drittem Parser).
- C-001-lokale Funktion für 2 Call-Sites ohne Regel-1-Ausnahme zu benennen
  (trivial, kein Blocker – entweder Regel 1 um „lokale Funktionen in
  selbem Heredoc ausgenommen" ergänzen oder C-001 zurückstellen).
- Im Übrigen korrekt minimal: keine neue Abstraktion ohne Duplikat-Entfernung
  (C-006/C-008/C-009/C-014 bewusst nicht gefaltet), kein Alertmanager/
  Proxy/Digest/Timer-Refactoring, Kommentar-Diät nur inkrementell bei
  berührten Stellen (C-010), keine Zeilenzahl als Ziel. Phase E check.sh ist
  kein Feature-Creep, sondern benannter Leser für sonst theaterhafte
  Warnungen (Regel 3) – gerechtfertigt, aber pfadlos (PV-010).

## Missing Tests

- T-110-rot (kranker Boot → ROT + Exit 1, laufendes Log – PV-010)
- Boot/Inner-Timeout-Spec + Caddy-Log-Grep (kein 127.0.0.1-`obtaining`,
  PV-014)
- UFW-Negativ-Fixtures (weltweit → kein Abbruch) + `numbered`-Formate +
  vorher/nachher-`ufw status`-Protokoll (PV-009)
- Fremd-auf-9090-Probe + UDP-443-Probe (PV-007)
- Defekt-Dump mit exakter Query-Verifikation (nicht nur Exit, sondern
  Datenzeile – PV-013)
- `.domain`-Divergenz-Proben (Spacing/Domain-Wechsel/Delete/Hand-Edit –
  PV-006, falls Datei gewählt wird)
- Sonderzeichen-Vollvorrat (`$`, Backtick, `"`, `'`, Space, führendes `-`,
  Newline-Abweisung) + `ps`/`inspect`-Leak-Grep (PV-002)
- TEST_PLAN-Delta + T-007-Selbsttest-Ablage (PV-015)
- Im Übrigen vollständig und mit richtigen Maßstäben: T-071b >1 MB
  unkomprimiert + „kleine Fixtures zählen nicht", PIPESTATUS-141-Repro,
  SNI-Handshake gesund/krank (kein reines `awk`-Parsing), Hex durch beide
  Gates (VM + UNIT-LIKE), T-026-Abbruch/Hand-Drift, T-102 „Container laufen
  weiter", T-080-negativ mit `ON_ERROR_STOP`, `caddy validate` via gepinntem
  Image, beidseitige Pull-Probe, Fresh/Second/Third/Interrupted/Reboot/
  Backup/Restore/Update/Rollback/Security/TLS/Workspace-Matrix mit
  Artefaktpflicht (Datum/VM/Commit/Tool-Versionen/Exit-Codes/Logs).

## Missing Decisions

Keine fehlende Entscheidung im Sinne „stillschweigend getroffen" außer den
in PV-002/006/008/012 genannten (Secret-Variante, `.domain` vs. Kommentar,
H-Scope, TROUBLESHOOTING-Quelle – alle jetzt zu entscheiden, nicht im PR).
Alle großen Ds sind als `OPEN` mit Owner/Frist-Feldern angelegt (D-Socket,
D-TLS, D-SSH, D-Firewall, D-Reboot, D-Offsite, D-Workspace-RPO,
D-Update-Split + D-Monitoring/D-Passwort/D-Caddy-Pin/D-PLAN) und Code bleibt
bis dahin unverändert (kein Proxy-/ask-/DOCKER-USER-/Key-only-Schnellschuss
– korrekt). Lücke allein: DoD lässt `_offen_` ohne Frist für kritische Ds
zu (PV-004) – Entscheidungstabelle ohne Durchsetzung ist Doku statt Gate.

## Documentation Gaps

- Handover-Pointer D-001–D-015 statt Checklist 1–6 (PV-012)
- TROUBLESHOOTING-Quelle unentschieden (PV-012)
- TEST_PLAN vs. Phase-B-Matrix vs. `tests/` unklar (PV-015)
- check.sh-Pfade/Leser/Rotation fehlen (PV-010)
- Im Übrigen vorbildlich: Ist-nur-nach-Beleg (Code-Zeile/Log/Scan/Datum,
  sonst `OPEN`/WARN-Box), keine Hypothese als Tatsache, Reviews bleiben
  Referenz statt Handbuch, keine Review-Kopie (OPERATIONS-Quelle +
  11-Fehler-Tabelle mit WARN-Boxen für B2-001/002/009 bis Fix), Status-Box
  (Commit/Sperren/Test-Status/RTO-`_offen_`), Entscheidungs-Tabelle mit
  `_offen_`-Zählung, Verifikation je Datei (`test -f` + Stichwort-Grep +
  `tail -5 CHANGELOG`), Handover-Verlinkung statt Duplikat.

## Recommended Plan Corrections

1. B2-003 eine Variante festschreiben + exakte Heredocs (Z.1263/1271/1281)
   + Ersatzwortlaut + Voll-Fixture + Leak-Grep (PV-002, BLOCKER).
2. B2-007 „NACH jeder Schreibstelle", Loop löschen, Residualfenster
   dokumentieren (PV-003, MUST_FIX).
3. Stop-Regel + DoD: B-008/RTO + B2-005-Doku + kritische Ds mit
   Eigentümer+Frist (kein `_offen_` für CRITICAL/HIGH), Phase-C-Gate +
   Doku-Gates wörtlich in DoD (PV-004 BLOCKER + PV-005 MUST_FIX).
4. C-003 zurück auf Sync-Kommentar ODER volle File-Spec mit Sync-Beweis
   (PV-006); Phase H auf alle 15 Dateien + Budget-Beispiel (PV-008).
5. B2-004/B2-008/B2-002/B2-009-Testspecs wörtlich (exakter Regex, konkrete
   Abbildung, Per-Stelle-Flags, exakte Runbook-Zeile + Daten-Queries –
   PV-009/007/014/013).
6. T-110-rot + check.sh-Pfade/SNI/Rotation (PV-010); Phase A 8 Commits in
   Ordnung mit je Artefakt (PV-011); Handover-Pointer + Single-Source +
   TEST_PLAN-Delta + Baseline-HEAD (PV-012/015/001).

## Final Assessment

NOT_READY_FOR_IMPLEMENTATION
