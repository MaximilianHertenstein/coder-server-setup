# PLAN-v3-FINAL-CHECK – Verifikation PV-001 bis PV-015

Stand: 2026-09-27. Geprüft: `ai-review/PLAN-v3.md` (1255 Zeilen, aktualisierter Stand)
gegen `ai-review/PLAN-v3-REVIEW.md` (908 Zeilen, PV-001 bis PV-015).

Methode: Jeder PV-Befund wurde gegen den tatsächlichen aktuellen Inhalt von
PLAN-v3.md geprüft, nicht nur nach Schlagwörtern. Maßstab: konkret,
eindeutig, implementierbar, testbar. Mehrdeutiges gilt als nicht geschlossen.

Referenz-Setup-Stand im Plan: `setup-coder.sh` 1615 Newlines / 1616 logische
Zeilen, `ssh-harden.sh` (80), `RESTORE.md` (68), `templates/allowlist.md` (34),
`tests/` leer.

---

## PV-001 – Baseline/HEAD und Zeilenzählweise

Status:
CLOSED

Evidence:
PLAN-v3.md Z.3–15.

Required correction from review:
Baseline auf `52493de` aktualisieren (oder „eadb61a + nur PLAN-v3.md-Delta,
Setup-Diff leer" dokumentieren) und Zählweise klarstellen (1616 logische
Zeilen, 1615 Newlines).

How PLAN-v3 addresses it:
Zweite vom Review ausdrücklich zugelassene Variante ist umgesetzt:
Referenz-Commit `eadb61a` für alle Setup-Dateien; `setup-coder.sh`
„1615 Newlines per `wc -l` / 1616 logische Zeilen – letzte Zeile `fi` ohne
abschließenden Newline"; Setup-Diff `eadb61a..HEAD` für Setup-Dateien ist
leer (Plan-Delta nur `ai-review/*`); beide `--stat`-Ausgaben
(`-- setup-coder.sh ssh-harden.sh RESTORE.md templates/` muss leer sein;
volles `--stat` zeigt nur `ai-review/`) plus `git rev-parse --short HEAD`
sind als Freigabe-Protokoll vorgeschrieben; Zeilenreferenzen gelten nur,
solange der Setup-Diff leer ist, andernfalls Baseline neu verifizieren
(kein HEAD-Chasing im Plantext).

Remaining gap:
Keiner. Die gewählte Variante (fixer Referenz-Commit + Leer-Diff-Beweis
statt HEAD-Chasing) ist eindeutig und testbar.

Functional impact:
NONE

---

## PV-002 – Secret-Architekturentscheidung (B2-003)

Status:
CLOSED

Evidence:
PLAN-v3.md Z.184–249 (B2-003: Z.184–232 Strategie, Z.234–249 Test).

Required correction from review:
Eine Variante festschreiben (empfohlen (a) mit quotiertem Heredoc
`<<'INNER_EOF'` + Alt-PW ausschließlich als Env-Wert via STDIN, nie in
SQL/URL interpoliert, neues PW Hex; `docker exec -e` nur mit Begründung +
`inspect`-Warnung, kein Default). Exakte Stellen (Z.1263/Z.1271/Z.1281),
exakter Ersatztext für beide Gates, exakter Zeichenvorrat für die Fixture
(inkl. `$`, Backtick, `"`, `'`, Space, führendes `-`; Newline als
dokumentiert abgewiesen, nicht still getrimmt).

How PLAN-v3 addresses it:
- Genau EINE Strategie festgeschrieben, keine Wahl im Implementierungs-PR:
  Variante (a) – Reset migriert Legacy lesend, Setup bleibt fail-closed
  (Z.184–188). `docker exec -e PGPASSWORD=...` wird NICHT verwendet, kein
  neues `inspect`-Leak, STDIN-Prinzip bleibt (Z.186–187).
- Setup-Gate-Ersatztext wörtlich vorgegeben (Z.189–194); Reset-Gate
  aufgespalten in ALT lesend vs. NEU Hex, Fail-closed für unvollständige
  `.env` und nicht-Hex NEU-Werte; Reset-Fehlermeldung verweist auf
  Setup-Reparatur, NIEMALS auf sich selbst (Z.195–200). Kein Pingpong.
- Z.1263 (ALT-Auth): Heredoc quotiert (`<<'INNER_EOF'`), Alt-Passwort
  ausschließlich als Env-Wert via STDIN
  (`printf '%s' "$OLD_PG_PW" | docker exec -i ... sh -s` +
  `read -rs OLD_PG_PW; export PGPASSWORD=...`), nie in SQL/URL
  interpoliert, nie als `exec`-Argument (Z.201–209).
- Z.1271/Z.1281 bleiben unquotiert mit Begründung: ausschließlich
  Hex-NEU-Werte aus `openssl rand -hex`, ebenfalls ohne `docker exec -e`
  (Z.210–214).
- Zeichenvorrat explizit: alle druckbaren ASCII 0x20–0x7E außer
  Newline/NUL, inkl. `$`, Backtick, `"`, `'`, Space, `!`, führendem `-`
  (mit Verarbeitungsregel `printf '%s'` / `grep --` / `cut -d= -f2-`);
  UTF-8 außerhalb ASCII als ungetestet abgewiesen (Z.215–220).
- Newline/NUL: harter Abbruch Exit 1 mit wörtlichem Text, kein stilles
  Trimmen/Neuwürfeln (Z.221–227).
- Exakter Migrationspfad: Legacy-`.env` → `reset-passwords.sh` →
  Setup-Re-Run grün + Reset-Re-Run grün; DB-zuerst vs. `.env`-zuerst wird
  NICHT still umgestellt (Z.228–232).
- Leak-Test: Vollvorrat (`Legacy$Pass!23`, Spaces, Quotes, `$`,
  Backtick, `-führend`) + Newline-Negativfall durch beide Gates; parallel
  `ps aux | grep -F` + `docker inspect ... | grep -F` auf Vollwert und
  8-Zeichen-Präfix, beide Grep müssen leer bleiben (Z.241–249).

Remaining gap:
Keiner im Sinne der Review-Forderung. Alle vier geforderten Punkte
(Variante, Heredoc-Stellen, Zeichenvorrat/Migration, Leak-Tests) sind
spezifiziert.

Functional impact:
NONE

---

## PV-003 – Drift-Hash-Ort (B2-007)

Status:
CLOSED

Evidence:
PLAN-v3.md Z.392–417 (B2-007: Z.392–404 Fix, Z.406–417 Test).

Required correction from review:
„Unmittelbar NACH jeder `tee`/`mv`/`chmod`-Stelle (nicht an der
`note_drift`-Zeile davor), Schritt-10-Schleife löschen, 600-Modus +
Abdeckung aller 15 Dateien behalten, deterministische Regeneration +
WARN-nie-interaktiv behalten." Residualfenster dokumentieren.

How PLAN-v3 addresses it:
- `remember_hash` unmittelbar NACH der jeweiligen erfolgreichen
  Schreib-/Installations-Sequenz (`tee`/`mv`/`chmod`/`install`), mit
  ausdrücklichem Warnhinweis: NICHT an der `note_drift`-Zeile davor –
  `note_drift` steht heute VOR jedem `tee`, wörtlich umgesetzt würde der
  Hash der ALTEN Datei committet (Z.392–396).
- Schritt-10-Schleife (Z.1514–1521) löschen; keine neue Mechanik, nur
  Ortswechsel (Z.397).
- Deterministische Regeneration, WARN-Semantik (nie interaktiv), 600-Modus,
  Abdeckung aller 15 Dateien bleiben (Z.398–400).
- Residualkante dokumentiert: Kill zwischen Write und `remember_hash`
  erzeugt einmalig Fehl-WARN im nächsten Lauf, kein Datenverlust, kein
  Fehlheilen, nächster grüner Lauf heilt (Z.401–404).
- Test T-026 erweitert mit allen drei Pfaden: (a) Abbruch nach Schritt 2
  → kein Fehlalarm, (b) echte Hand-Drift → WARN bleibt, (c) Residualpfad
  Kill-zwischen-Write-und-Hash → genau einmal Fehl-WARN, danach Heilung
  (Z.412–417).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-004 – Offsite/Recovery und kritische Security Decisions als Production-Blocking

Status:
CLOSED

Evidence:
PLAN-v3.md Phase C Stop-Regel Z.682–698; DoD Z.1217–1235; Phase D/E als
Kontext.

Required correction from review:
Stop-Regel ergänzen: B-008 (Offsite-Probe T-082 + RTO-Zahl) +
B2-005-Limit-Doku + `logrotate` für tls/boot-Logs + T-125; DoD
verschärfen: D-Socket/D-TLS/D-SSH/D-Offsite (CRITICAL/HIGH) brauchen
Eigentümer + Frist vor Produktion, `_offen_` genügt nur für LOW/MEDIUM
mit Verfallsdatum + Ticket. Alternativ: „ohne Offsite keine Produktion".

How PLAN-v3 addresses it:
- Stop-Regel verlangt grün für B2-001/B2-002/B2-003, B-002-Pull-Probe,
  B2-009, B-004-Inventar + T-063 + D-Socket-Frist, B2-004,
  B-008-Offsite-Probe (T-082 nur aus Offsite + Runbook, RTO als Zahl im
  Repo) + B2-005-Limit-Doku + `logrotate` für `coder-tls.log`/
  `coder-boot.log` + T-125, Blocking-0 (Z.682–689).
- Für CRITICAL/HIGH (D-Socket, D-TLS, D-SSH, D-Offsite,
  B-008/Offsite-Recovery) gilt: entweder geschlossene Entscheidung mit
  Owner + Datum/Frist + Nachweis, oder explizite Production-Sperre; kein
  Production-Lauf, im Gate-Protokoll vermerkt (Z.690–694).
- `_offen_`/`_OPEN_` ohne Owner + Frist ist bei CRITICAL/HIGH kein
  gültiger Freigabestatus, nur für LOW/MEDIUM mit Verfallsdatum + Ticket
  (Z.694–696).
- Ohne geklärten Production-Offsite (kein leerer Dauer-Default ohne
  Verfallsdatum + Ticket) und ohne gemessene RTO keine Freigabe
  (Z.696–698).
- DoD wiederholt dieselbe Verschärfung wörtlich (Z.1226–1230) und verlangt
  RTO als gemessene Zahl + Offsite-Probe grün (Z.1230).

Remaining gap:
Keiner. Dass Phase D die Tabellen weiterhin als `OPEN` (Owner/Deadline
`OPEN`) führt, ist kein Widerspruch: `OPEN` bedeutet dort Sperre, nicht
Freigabe – genau das stellt Stop-Regel/DoD sicher.

Functional impact:
NONE

---

## PV-005 – Phase-C-VM-Gate als Bestandteil der Definition of Done

Status:
CLOSED

Evidence:
PLAN-v3.md Z.1217–1235 (Done); Phase C Z.673–680 (Pflichtliste);
Phase G Z.1075–1082 (Doku-Gates).

Required correction from review:
DoD ergänzen: „Phase-C-VM-Gate grün (alle Pflichttests mit Artefakt, nie
Produktion) + Phase-G-Verifikation grün (`test -f` + Stichwort-Greps +
`_offen_`-Zählung + `tail -5 CHANGELOG` + `ls tests/` nicht-leer +
datierter VM-Protokoll-Eintrag mit RTO-Zahl, C-015-Meta-Test)".

How PLAN-v3 addresses it:
DoD verlangt kumulativ: alle MUST_FIX-Änderungen mit Test-Artefakt;
Static Gates (T-001/T-002/T-003/T-004/T-007) grün; Phase-C-VM-Gate
vollständig grün mit ausgeschriebener Liste (Fresh Install, Second Run,
Third Run, Interrupted Run, Reboot, Backup, Restore, Update, Rollback,
Security Smoke, Caddy/TLS, Workspace-Isolation – je mit Artefakt
Datum/VM/Commit/Tool-Versionen/Exit-Codes/Logs, nie Produktion);
Phase-G-Dokumentationsgates grün (`test -f` + Stichwort-Greps +
`_offen_`-Zählung + `tail -5 CHANGELOG.md` + `ls tests/` nicht-leer +
datierter VM-Protokoll-Eintrag mit RTO-Zahl, C-015-Meta-Test)
(Z.1217–1226). Gate-Bypass per Lesart („nur MUST_FIX braucht VM") ist
damit geschlossen.

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-006 – `.domain`-Entscheidung und Complexity-Regeln

Status:
CLOSED

Evidence:
PLAN-v3.md C-003 Z.939–956; C-012-Budget Z.1011–1019;
Komplexitätsregel 1 Z.1141–1145.

Required correction from review:
Entweder (bevorzugt): Duplikat behalten + Sync-Kommentar, `.domain`
erst bei drittem Parser (Regel 1). Oder falls Datei: volle File-Spec
(Quelle, Rechte, Hashliste, Fallback, Sync-Beweis, Tests).

How PLAN-v3 addresses it:
- Variante A festgeschrieben, keine `.domain`-Datei in dieser Runde:
  Apex-Parser beibehalten, nur Sync-Kommentar („mit Z.765/1115 synchron
  halten"), solange zwei Verwender (Regel 1: Helfer erst ab drittem
  Verwender; Heredoc-/Laufzeitgrenzen schlagen DRY); Begründung
  stale-Source-Risiko (Z.939–947).
- Künftiges `.domain` nur bei drittem Parser, mit vollständiger
  Bedingungs-Spec (Quelle `${DOMAIN_CODER}`, Schritt 2, 644/root,
  16. Hashstore-Datei, WARN-Fallback, Rewrite, Hand-Edit=WARN) + Tests
  (Z.948–954). Das ist aufgeschoben, nicht delegiert.
- Test Variante A: Spacing-Change → beide Gates finden Apex oder WARN,
  nie falsches Grün (Z.955–956).
- Regel 1 enthält jetzt die ausdrücklich benannte Ausnahme (lokale
  Funktion im selben Heredoc/Skript wie C-001 `require_containers` bei
  2 Call-Sites zulässig), sodass C-001 die Regel nicht verletzt und C-003
  weiterhin unter die 3-Verwender-Schwelle fällt (Z.1141–1145).

Remaining gap:
Keiner. Entscheidung eindeutig (keine Datei), Regelwiderspruch
ausgeräumt.

Functional impact:
NONE

---

## PV-007 – Port-Preflight (B2-008)

Status:
CLOSED

Evidence:
PLAN-v3.md Z.433–460 (B2-008 Fix + Erwartung + Test).

Required correction from review:
Konkreten Filter festschreiben (exakter IP:Port-Abgleich gegen
`docker inspect` der Projekt-Container, nur exakte Treffer suppressen,
sonst WARN mit Prozessname; keine Ports streichen). UDP 443 explizit.
Fixtures: gesund → keine WARN; fremd auf 80 UND auf 9090 → WARN.

How PLAN-v3 addresses it:
- TCP via `ss -tlnp`, UDP via `ss -ulnp` getrennt, mit Begründung
  (TCP-only sieht UDP 443/QUIC nie) (Z.434–435).
- Docker-Port-Bindings via
  `docker inspect --format '{{.HostConfig.PortBindings}}'` je
  Projekt-Container (`coder`, `coder-postgres`, `coder-caddy`,
  `coder-prometheus`, `coder-grafana`, `coder-node-exporter` via
  `docker compose ps -q`, Präfix `coder-*`) (Z.435–439).
- Vergleich: exakte Host-IP:Host-Port-Paare (beide müssen stimmen,
  Beispiele `0.0.0.0:80`, `:::443`, `127.0.0.1:9090`); NUR exakte
  Treffer dürfen unterdrückt werden; jeder andere Listener auf
  80/tcp, 443/tcp, 443/udp, 9090/tcp, 9100/tcp, 3001/tcp → WARN mit
  Prozessname, auch bei Port-Gleichheit ohne IP-Gleichheit; keine Ports
  aus der Prüfung gestrichen (Z.439–448).
- Erwartung: Re-Run gesund → keine WARN; Fremd-Listener 80/tcp → WARN;
  Fremd-Listener 9090/tcp → WARN; fremder UDP-Listener 443 → WARN
  (Z.450–452).
- Test: 4-teilige Re-Run-Probe (gesund, fremd 80/tcp, fremd 9090/tcp,
  fremd UDP 443) auf VM (Z.457–460).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-008 – Phase H (alle Heredoc-/Host-Dateien) und Complexity-Budget

Status:
CLOSED

Evidence:
PLAN-v3.md Phase H Z.1088–1135; C-012 Z.996–1019.

Required correction from review:
Alle 15 Dateien in H-Scope aufnehmen; Budget konkretisieren („dritter
identischer Runtime-Helper in standalone Skripten, C-006/C-009 ausgenommen;
bis dahin kein `lib.sh`") + Byte-Vergleich + volle T-Matrix als H-Gate.

How PLAN-v3 addresses it:
- Vollständige Host-Dateiliste: `docker-compose.yml`, `Caddyfile`,
  `prometheus.yml`, `backup.sh`, `update.sh`, `reset-passwords.sh`,
  `reset-coder.sh`, `boot-check.sh`, `check-tls.sh`, `jail.local`,
  `52-coder-reboot`, 3 Cron-Dateien, `logrotate` (`coder-backup`),
  `ssh-harden.sh` als Repo-Referenz (Z.1088–1094).
- Entscheidung je Datei: 9 Dateien = Repo-Kandidaten für Phase B;
  `jail.local`, `52-coder-reboot`, alle 3 Cron-Dateien,
  `logrotate`-Konfiguration = bis Budget-Reife Heredoc, mit Begründung
  (kleine rechte-sensitive Host-Config, eigener Retest, kein akuter
  Ausfall durch Auszug) (Z.1096–1104).
- Budget-Trigger nachvollziehbar: `tests/` auf VM grün UND dritter echter
  Standalone-Runtime-Verwender desselben Helper-Verhaltens;
  C-006/C-009-Präzedenzfälle ausdrücklich ausgenommen, bis dahin kein
  `lib.sh` (Z.1118–1123).
- Migration nur als eigene Phase mit Byte-Vergleich
  (`diff <(alt-generiert) <(neu-generiert)` bei Defaults muss leer sein)
  + volle T-Matrix (T-020/T-026/T-003/T-004/T-002, Idempotenz/Drift,
  Caddy-nur-bei-Änderung, fail2ban-Bans) (Z.1130–1135).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-009 – SSH-Re-Run-Downgrade (B2-004)

Status:
CLOSED

Evidence:
PLAN-v3.md Z.266–342 (B2-004 Fix + Erwartung + Test).

Required correction from review:
Exakten Detektor + Negativ-Fixtures (weltweit → kein Abbruch; kein UFW →
kein Abbruch mit Hinweis) + Bypass-Verfahren festschreiben (eines, kein
„wähle im PR"); Wiederherstellungs-Befehl mit Check.

How PLAN-v3 addresses it:
- Detektor wörtlich, genau so zu implementieren, keine Wahl, POSIX
  `grep -E`, kein `\S`/`\b` (Z.266–270).
- `UFW_OUT` aus `ufw status numbered || ufw status || 'Status: inactive'`
  (Z.272–274); Pfad C zuerst (inactive → kein Abbruch, Hinweis,
  `ufw`-Setup-Pfad fährt fort) (Z.276–279).
- Pfad-A/B-Stufe mit wörtlicher Zwei-Grep-Pipeline (Kandidat minus
  weltweit; nicht-leer = restriktiv) (Z.281–285).
- Pflicht-Fixtures UNIT-LIKE: 7 restriktive Treffer (inkl. altem
  False-Negative `22 ALLOW 192.168.1.0/24` ohne `/tcp`,
  `numbered`-Formen, `(v6)` inkl. IPv6-Quelle, `allow from <src> to any
  port 22`, `22/tcp LIMIT 192.168.1.5`); 4 weltweit-Negativ
  (`LIMIT/Anywhere`, `(v6)`-Varianten, `ALLOW Anywhere`);
  Negativ `80/443/2222/122` dürfen nie matchen (Z.287–295).
- Verhalten: (A) weltweit offen → kein Abort; (B) restriktiv → harter
  Abbruch Exit 1 mit Anleitung + vorher/nachher-Protokoll, kein stilles
  Öffnen; (C) UFW inaktiv → definierter Pfad mit Hinweis (Z.295–299).
  Re-Run-Pfad (B): Regel protokolliert, Setup mit dokumentierter
  angepasster Regel fahren, Härtung NICHT still entfernen (Z.299–302).
- Bypass festgeschrieben (genau einer): `CODER_ALLOW_SSH_DOWNGRADE=yes`,
  nur exakt `yes`; vorher/nachher-`ufw status` protokolliert; verifizierte
  Wiederherstellung mit wörtlicher Befehlsfolge (`before.log`,
  `NOTED_SRC` wörtlich aus `before.log`, `ufw allow from ...`,
  `after.log`, `grep -F ... || exit 1`); ohne erfolgreichen Check gilt
  Wiederherstellung als fehlgeschlagen (Z.302–321). Kein
  Auto-Restore ohne Verifikation (Z.324).
- Test T-062 + Downgrade-Probe (VM + UNIT-LIKE, beide Schreibweisen,
  weltweit-Negativ, IPv6, No-UFW): restriktiv → Abbruch/Erhalt mit
  Protokoll bzw. Bypass nur mit Env + verifizierter Wiederherstellung;
  weltweit → kein Abort; inaktiv → definierter Pfad; nie stilles Öffnen
  (Z.336–342).

Remaining gap:
Kein Review-Gap. Hinweis (nicht blockierend, für Implementierung
vormerken): Die Bypass-Wiederherstellung normalisiert auf `allow`
(`ufw allow from ... proto tcp`), auch wenn die notierte Regel ein
`LIMIT` war. Rate-Limit-Semantik sollte beim Restore quellengetreu
(`allow` vs. `limit`) wiederhergestellt werden. Kein CLOSED-Hindernis:
Ablauf ist implementierbar, verifiziert und testbar.

Functional impact:
NONE (Hinweis: LOW, nicht blockierend, als Implementierungsdetail zu
beachten)

---

## PV-010 – Boot-Gate negativ und check.sh-Konkretisierung

Status:
CLOSED

Evidence:
PLAN-v3.md Phase B Matrix Z.610–611; Phase B Header Z.573–574;
Phase E Z.855–871; Stop-Regel Z.686 (logrotate/T-125).

Required correction from review:
T-110-rot hinzufügen (kranker Boot → ROT + Exit 1, laufendes `$OUT`);
check.sh konkretisieren (Pfad, 755/root, Cron-Pfad/Zeit, Log + Rotation,
Leser/Eigentümer, `--resolve`-Probe, `df`-Schwelle als WARN/UNVERMESSEN,
kein Alertmanager).

How PLAN-v3 addresses it:
- T-110 (gesund → `BOOT-GATE GRÜN` im laufenden Log, nicht kumulativ)
  und T-110-rot (kranker Boot, Postgres/Coder gestoppt → `BOOT-GATE ROT`
  + Exit 1, Beleg im laufenden `$OUT`, nicht kumulativ) beide in Matrix
  und Delta-Liste (Z.610–611, Z.573–574).
- check.sh vollständig spezifiziert: Pfad `/opt/coder/check.sh`,
  `root:root`, `755`; Cron `/etc/cron.d/coder-freshness`, täglich
  `01:30` nach 01:00-Backup; nur lesend (Z.855–859).
- Prüfungen: Backup-Alter/Größe (>26 h → Exit≠0) + `df` (>85 % →
  `logger` + Exit≠0, Schwelle bis D-Monitoring WARN/UNVERMESSEN, kein
  Alertmanager) + `/healthz` via kanonischer `--resolve`-Probe (Domain
  als SNI, `--max-time 10`, nirgends SNI `127.0.0.1`) (Z.859–865).
- Eine Zeile ins rotierte `/var/log/coder-backup.log`, kein neues
  unrotiertes Log; Leser/Eigentümer: morgendlicher Operator-Check;
  Exit 0 nur bei allen drei grün (Z.865–869).
- `logrotate` für `coder-boot.log`/`coder-tls.log` nachziehen
  (Z.870–871, Stop-Regel Z.686).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-011 – Phase-A-Reihenfolge und Per-Fix-Verifikation

Status:
CLOSED

Evidence:
PLAN-v3.md Z.53–55 (Phasenregel); Z.1201–1210 (Reihenfolge/DoD);
Phase B Z.1209–1210.

Required correction from review:
Phase A als 8 Commits in Abhängigkeitsreihenfolge
(B2-001→B2-002→B2-003→B2-006→B2-007→B2-004→B2-008→B2-009) mit je
STATIC/UNIT-LIKE-Artefakt; T-071b + Handshake + Hex-Migration zuerst als
Merge-Gate.

How PLAN-v3 addresses it:
- Phasenregel: minimale Änderung, Reihenfolge = Abhängigkeit (Backup
  zuerst, dann Gates, dann Warnsystem) (Z.53–55).
- 8 Commits in genau der geforderten Reihenfolge, keine Sammelzeile, je
  Commit genau ein B2-Fix + je ein lokales STATIC/UNIT-LIKE-Artefakt
  (Datum, Commit, Exit-Codes) vor dem nächsten Commit; nachfolgender Fix
  darf vorherigen Fehler nicht verdecken (B2-007-WARNs vs.
  B2-004-Verifikation als Beispiel) (Z.1201–1207).
- Merge-Gate: T-071b + Handshake + Hex-Migration zuerst, dann Rest
  (Z.1208, Z.1209–1210).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-012 – Handover-Pointer und TROUBLESHOOTING-Single-Source

Status:
CLOSED

Evidence:
PLAN-v3.md Phase G Z.1065–1069 (TROUBLESHOOTING); Z.1078–1082
(Handover-Checkliste).

Required correction from review:
Pointer auf 08-Checklist 1–6 (aus OPERATIONS verlinkt, nicht dupliziert);
Single-Source jetzt entscheiden (empfohlen OPERATIONS als Quelle,
TROUBLESHOOTING als reine Pointer-Datei, `grep`-Guard).

How PLAN-v3 addresses it:
- TROUBLESHOOTING als Pointer-Datei für Druck/Notfall: ausschließlich
  Pointer/Navigation auf OPERATIONS.md, keine duplizierte
  Fehler→Befehl-Tabelle; Single Source OPERATIONS.md jetzt entschieden,
  nicht delegiert; `grep`-Guard („Tabelle in genau einer Datei")
  (Z.1065–1069).
- Handover-Checkliste: Punkte 1–6 des 08-Reviews (Zugang/Bestand,
  Voraussetzungen-Gate, Gesundheit lesend, Backup/Restore-Kern, Wartung
  erst nach 1–4, Entscheidungen/Doku); D-001–D-015 ausdrücklich als
  Dokumentationsbefunde, NICHT die Checkliste, benannt; aus OPERATIONS
  verlinkt, nicht dupliziert (Z.1078–1082).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-013 – Restore-Verifikation B2-009 (exakt, Daten, Negativtest)

Status:
CLOSED

Evidence:
PLAN-v3.md B2-009 Z.479–502 (Fix + Erwartung + Test); Phase E Z.873–897.

Required correction from review:
Exakte Pfad-A-Zeile (`zcat dump | sudo docker exec -i coder-postgres psql
-v ON_ERROR_STOP=1 -U coder -d coder`, Abbruch vor `up -d`) + exakte
Verifikation (`SELECT count(*)` mit vorher bekannter Testzeile +
Dashboard-Login zeigt Datensatz, nicht nur 200). Defekt-Fixture (eine
fehlerhafte `CREATE TABLE`-Zeile) muss rot abbrechen.

How PLAN-v3 addresses it:
- Pfad-A-Zeile wörtlich mit exakter Flag-Position (`-v ON_ERROR_STOP=1`
  als `psql`-Option VOR `-U`), Abbruch hart, Kette stoppt vor `up -d`;
  bei Fehler Exit≠0, kein `up -d`, kein grüner Restore (Z.479–482).
- Verifikation trennt Liveness (`/healthz` 200, `SELECT 1`) von Daten:
  vor Backup `restore_probe(id serial primary key, marker text)` +
  `marker='RTO-PROBE-<datum>'`, nach Restore
  `SELECT count(*) ... = 1` + Dashboard-Login zeigt Test-Datensatz;
  leere DB (Zählung 0) NICHT als Erfolg; defekter Dump (eine fehlerhafte
  `CREATE TABLE`-Zeile) muss rot abbrechen (Z.483–491).
- Phase E wiederholt Befehl, Datenprobe, Leer=rot, Pfad B (`.env`
  verloren, Rollen-Passwort-Hinweis), Runbook-Ablage, RTO-Messung
  (Z.873–897); Test T-080-negativ VM + RECOVERY auf Wegwerf-Postgres
  (Z.501–502).

Remaining gap:
Keiner.

Functional impact:
NONE

---

## PV-014 – Drei TLS-Fälle getrennt und korrekt

Status:
CLOSED

Evidence:
PLAN-v3.md B2-002 Z.128–165 (Fix + Erwartung + Test); C-004 Z.957–962;
Phase B Matrix Z.607; Phase E check.sh Z.862–865.

Required correction from review:
Wörtlich pro Stelle: Schritt 10 unverändert (echtes DNS+SNI, 10 s,
Referenz); Update single-shot `--resolve DOMAIN:443:127.0.0.1 … 60 s`;
Boot `--resolve … --max-time 10` in 30×10-Loop, WARN bei unparsbar;
überall SNI=Domain, nirgends SNI=127.0.0.1; Caddy-Log-Grep (kein
127.0.0.1-`obtaining`).

How PLAN-v3 addresses it:
- Schritt 10 (Z.1559–1571, Referenz, unverändert): echter DNS-Pfad,
  Domain als SNI, kein `--resolve`, `--max-time 10`; darf NICHT auf
  `--resolve` umgestellt werden (Z.131–133).
- Update (Z.1115–1130, single-shot): wörtliches `curl`-Snippet mit
  `--resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz"`,
  `--max-time 60` (60 s wegen On-Demand-Erstverzögerung 5–30 s)
  (Z.134–142).
- Boot (Z.765–782, 30×10-Loop): `--resolve` mit Domain-SNI,
  `--max-time 10`, innerhalb der Poll-Schleife, WARN bei unparsbar
  (Z.143–145).
- Überall SNI=Domain, nirgends `127.0.0.1` (kein `-H Host:` gegen
  `https://127.0.0.1`); nach Fix keine `127.0.0.1`-On-Demand-Versuche
  (Beleg Caddy-Log-Grep `obtaining certificate` ohne `127.0.0.1`);
  WARN-statt-Fail bleibt (Z.147–151).
- Tests T-090/T-091/T-110 + Caddy-Log-Grep (Z.162–165); C-004 wiederholt
  Drei-Fall-Spec wörtlich (Z.957–962); Matrix normiert
  Update+Boot=`--resolve`, Schritt 10=Real-DNS ohne `--resolve`
  (Z.607); check.sh nutzt dieselbe `--resolve`+Domain-SNI+10-s-Strategie
  (Z.862–865).

Remaining gap:
Keiner. SNI `127.0.0.1` wird nirgends verwendet.

Functional impact:
NONE

---

## PV-015 – TEST_PLAN-Source-of-Truth und B2-Test-Ablage

Status:
CLOSED

Evidence:
PLAN-v3.md Phase B Z.571–585; DoD Z.1223–1226, Z.1191–1192.

Required correction from review:
Ein Satz: Phase-B-Matrix ersetzt TEST_PLAN für B2-Umfang bzw.
TEST_PLAN.md wird als Delta nachgezogen oder superseded; `tests/`
enthält STATIC/UNIT-LIKE-Harness + T-007-Selbsttest.

How PLAN-v3 addresses it:
- Source-of-Truth entschieden, keine zwei konkurrierenden Pläne:
  `ai-review/TEST_PLAN.md` bleibt Master-Testmatrix; PLAN-v3 ergänzt nur
  B2-Delta-Tests bzw. markiert sie als Delta (T-071b, Gate-Handshake
  inkl. T-110-rot, Hex-Migration, T-026-erweitert inkl. Residualpfad,
  T-102-erweitert, Downgrade-Probe, T-080-negativ, T-004-`caddy
  validate`) (Z.571–580).
- Ablage: neue B2-Tests in `tests/` als STATIC/UNIT-LIKE-Harness (inkl.
  T-007-Selbsttest); was nur auf Test-VM möglich ist, läuft dort mit
  Artefakt (Z.580–583).
- `ai-review/TEST_PLAN.md` wird als Delta nachgezogen; bis dahin gilt
  Phase-B-Matrix für den B2-Umfang (Z.583–585).
- DoD-Gates (`ls tests/` nicht-leer, datierter VM-Protokoll-Eintrag mit
  RTO-Zahl, C-015-Meta-Test) verankert (Z.1223–1226, Z.1191–1192).

Remaining gap:
Keiner.

Functional impact:
NONE

---

# Neue Widersprüche durch die Korrekturen

Geprüft: Security-Fix vs. Komplexität; Test vs. Phasenreihenfolge;
Production-Gate vs. andere Stellen; Doku vs. Plan; Complexity-Regel vs.
Änderung; Test-gegen-Behauptung; implizite Architektur; Implementierbarkeit.

- B2-003 (STDIN + quotierter Heredoc): keine neue Abstraktion, kein
  Helper über Heredoc-Grenzen, kein `lib.sh`; konsistent mit Regel 1
  (C-001-Ausnahme ausdrücklich lokal begrenzt). Kein Widerspruch.
- Phase A (8 Commits, T-071b/Handshake/Hex zuerst) vs. Phase B
  („T-071b + Handshake + Hex-Migration zuerst"): konsistent, kein
  Widerspruch.
- Stop-Regel vs. DoD (`_offen_`-Regel für CRITICAL/HIGH, Owner+Frist
  oder Production-Sperre): wortgleich konsistent; Phase-D-`OPEN`-Tabellen
  bedeuten Sperre, nicht Freigabe. Kein Widerspruch.
- Phase G vs. DoD (Doku-Gates `test -f` + Greps + `_offen_`-Zählung +
  `tail -5` + `ls tests/` + VM-Protokoll): in DoD vollständig enthalten.
  Kein Widerspruch.
- Regel 1 vs. C-001/C-003: Ausnahme lokal begrenzt, C-003 bleibt bei
  zwei Verwendern ohne Helper. Kein Widerspruch.
- Tests prüfen behauptete Eigenschaften: T-071b (>1 MB), PIPESTATUS-Repro,
  Handshake gesund/krank + Caddy-Grep, Hex-Vollvorrat + `ps`/`inspect`-Grep,
  T-026 (Abbruch/Hand-Drift/Residual), T-102 (Container laufen weiter),
  T-080 (Defekt + Datenprobe `=1`, Leer=rot), `caddy validate`,
  beidseitige Pull-Probe, Downgrade-Fixtures inkl. Negativ. Kein
  Schein-Test gefunden.
- Architekturentscheidungen explizit: Secret-Variante (a), keine
  `.domain`-Datei, H-Scope (9 Kandidaten + Rest Heredoc bis Budget),
  TROUBLESHOOTING-Quelle (OPERATIONS), TEST_PLAN-SoT, Bypass-Syntax
  (`CODER_ALLOW_SSH_DOWNGRADE=yes` exakt). Keine Delegation an den
  Implementierer.
- Hinweis (nicht blockierend): B2-004-Bypass-Restore normalisiert auf
  `allow` (`ufw allow from ... proto tcp`). Falls die notierte Regel ein
  `LIMIT` war, sollte quellengetreu (`allow` vs. `limit`)
  wiederhergestellt werden. Implementierungsdetail, kein Gate-Verstoß.

Ergebnis: keine neuen blockierenden Widersprüche.

---

# Abschlussbewertung

# Blocking Issues Remaining

Keine. PV-002 (Secret-Strategie) und PV-004 (Production-Stop/B-008) sind
geschlossen.

# Must-Fix Issues Remaining

Keine. PV-003 (Hash-Ort + Residualfenster) und PV-005 (VM-Gate + Doku-Gates
in DoD) sind geschlossen.

# Partial Issues

Keine.

# Non-Blocking Open Issues

Keine offenen PV. Einziges vorgemerktes Implementierungsdetail (nicht
blockierend): B2-004-Bypass-Restore `allow` vs. `limit` quellengetreu
beachten (siehe PV-009-Hinweis).

# New Plan Contradictions

Keine blockierenden. Details siehe Abschnitt „Neue Widersprüche durch die
Korrekturen".

# Final Assessment

Alle 15 PV-Befunde sind konkret, eindeutig, implementierbar und testbar
geschlossen:

- PV-001 CLOSED (Referenz + Leer-Diff-Beweis + Zählweise)
- PV-002 CLOSED (Variante (a), STDIN, alle Heredocs, Wortlaut, Vorrat,
  Leak-Grep)
- PV-003 CLOSED (NACH Write, Loop-Löschung, Residualpfad + T-026abc)
- PV-004 CLOSED (B-008/RTO + B2-005/logrotate/T-125 im Stop; `_offen_`
  für CRITICAL/HIGH kein Freigabestatus)
- PV-005 CLOSED (vollständiges Phase-C-VM-Gate + Phase-G-Gates in DoD)
- PV-006 CLOSED (Variante A, keine `.domain`-Datei, Regel-1-Ausnahme
  begrenzt)
- PV-007 CLOSED (TCP/UDP getrennt, inspect-Abgleich, exakte Treffer,
  4-teilige Probe)
- PV-008 CLOSED (alle 15 Dateien, Budget-Trigger, Byte-Vergleich,
  volle T-Matrix)
- PV-009 CLOSED (wörtlicher Detektor, Fixtures, Pfade A/B/C, exakt ein
  Bypass mit verifiziertem Restore, T-062-Probe)
- PV-010 CLOSED (T-110 + T-110-rot, check.sh mit Pfad/Rechten/Cron/Log/
  Leser/SNI)
- PV-011 CLOSED (8 Commits in Ordnung, je Artefakt, Merge-Gate)
- PV-012 CLOSED (Checkliste 1–6, D-001–D-015 abgegrenzt, OPERATIONS als
  Single Source mit Guard)
- PV-013 CLOSED (exakte `ON_ERROR_STOP`-Zeile, `restore_probe`-Probe
  `=1`, Leer=rot, Defekt=rot)
- PV-014 CLOSED (Schritt 10 / Update / Boot wörtlich getrennt, SNI
  überall Domain)
- PV-015 CLOSED (TEST_PLAN.md = Master, B2-Delta + `tests/`-Harness +
  T-007, Übergangsregel)

Bedingungen erfüllt: kein BLOCKER offen, kein MUST_FIX offen, kein PARTIAL
mit funktionaler Auswirkung, PV-002/PV-004/PV-005 vollständig geschlossen,
kritische V2-Regressionen eindeutig spezifiziert, Teststrategie
implementierbar und eindeutig, keine kritische Architekturentscheidung
delegiert.

READY_FOR_IMPLEMENTATION
