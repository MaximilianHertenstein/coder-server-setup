# CHANGELOG.md

Append-only Dokumentation des tatsächlichen Repository-Stands.
**Es gibt keine Releases.** Dieses Verzeichnis kennt keine Versionsnummern
und keine Freigaben – nur Daten, Commits und was sich tatsächlich geändert
hat. Kein Eintrag behauptet eine Prüfung, die nicht stattgefunden hat.

Format je Eintrag: Datum, Umfang, geänderte Dateien, nachweisbarer Teststand,
offene Punkte. Ältere Einträge werden nicht umgeschrieben; Korrekturen kommen
als neuer Eintrag.

Stand: 2026-09-28 · aktueller Quellstand: `git log -1 --oneline`
(Branch `ai/implementation-v3`).

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

## Offene Punkte (Stand 2026-09-28, ohne Frist/Eigentümer)

| Punkt | Status |
|---|---|
| B2-005 (TLS-Zählung blind gegenüber Log-Rotation) | offen, nicht umgesetzt |
| Restore-Probe + RTO-Zahl | offen, `RESTORE.md`-Tabelle `_offen_` |
| Offsite-Backup | nicht eingerichtet |
| SSH-Härtung (`ssh-harden.sh`) | vorbereitet, nicht ausgeführt |
| Template-Erstinventar + Workspace-Selbsttest (T-063) | `_offen_` in [templates/allowlist.md](templates/allowlist.md) |
| VM-/Integrationstests der Testmatrix | nicht ausgeführt |
| Entscheidungen D-TLS, D-Socket, D-SSH, D-Firewall, D-Reboot-Fenster, D-Monitoring, D-Offsite | offen |
