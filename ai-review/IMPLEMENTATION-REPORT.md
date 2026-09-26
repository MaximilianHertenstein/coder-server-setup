# IMPLEMENTATION-REPORT – ai/implementation-v1

Stand: 2026-09-26. Branch: `ai/implementation-v1` (Arbeit ausschließlich hier).
`main` wurde nicht verändert (kein Checkout, kein Commit, kein Push dorthin).
Baseline (Original-`setup-coder.sh`) wurde nicht angetastet – alle Änderungen
liegen als Diff auf diesem Branch. Verwendete Eingaben: `setup-coder.sh`,
`ai-review/PLAN.md` (lesbar: F-001–F-012, Rest abgebrochen), `ai-review/PLAN-REVIEW.md`
(P-001–P-025), `ai-review/TEST_PLAN.md`, `AGENTS.md`, `copilot-instructions.md`
(Root-Datei; `.github/copilot-instructions.md` existiert im Repo NICHT, siehe B-15).
Keine Produktivserver-Befehle, keine echten Secrets (Tests nur mit Dummy-Werten),
keine destruktiven Tests, keine Firewall-/SSH-/Docker-/Volume-Änderung an realen
Systemen. Alle VM-/Prod-pflichtigen Tests sind OFFEN (keine Test-VM verfügbar) –
sie werden unten als fehlgeschlagen/offen geführt, NICHT als bestanden.

## Implementierte Findings (mit PLAN-REVIEW-Korrekturen)

- F-001 (CRITICAL): `|| true` an beiden Crontab-Migrationsstellen. Repro: ohne Fix
  Pipeline-Exit 1 (Abbruch), mit Fix Exit 0.
- F-006 (HIGH, mit P-010/P-011): `.env`-Erzeugung atomar via `mktemp` + vorherigem
  `install -m 600` + `mv` + `chown root:root` (kein 644-Fenster durch `sudo tee`;
  reines `umask 077` wurde als falsch verworfen). Bestand prüft Vollständigkeit
  (alle Schlüssel nicht-leer, GID numerisch); unvollständige `.env` → Abbruch mit
  Reparaturanleitung, NIEMALS stilles Neuwürfeln (DB-Lockout-Schutz).
- F-007 (HIGH, mit P-012): GID-Guard (nicht-leer/numerisch, sonst Fail ohne
  `.env`-Berührung), Diff-Vergleich, atomarer Tausch nur der GID-Zeile, Recreate
  (`up -d --no-deps coder`) nur bei Diff UND laufendem Container. Abschlusscheck
  um host-seitige Socket-Probe (GroupAdd enthält GID) ergänzt.
- F-005 (HIGH, mit P-013): Backup schreibt Temp (gleiche Partition) + `trap`-Cleanup,
  `gzip -t` hart, Größe nur Warnung (< 512 B, kein Fail bei frischer/verkleinerter DB),
  `mv` erst nach Verifikation, `df`-Mindestplatz (500 MB, konservativ) vorher.
- F-008 (HIGH): stückzahlbasierte Rotation (neueste 14, Mindestbestand eingebaut),
  Kommentar-vs-Code-Mismatch behoben. Verifiziert: 20→14, Lücke 4→4, leer 0→0.
- F-009 (HIGH, mit P-017): `cron`-Paket + `enable --now` + Aktiv-Check (Fail statt
  stillem Nie-Backup), Selbst-`flock` in backup.sh UND `flock -n` in Cron-Zeile
  (Zweitlauf = skip mit Meldung + logger, Exit 0), Sekunden-Timestamp,
  `PATH`-Export, absolute `/usr/bin/flock`-Cron-Pfade, logrotate für
  `coder-backup.log` + Existenz-Check.
- F-004 (HIGH, mit P-016): Volume-Filter projektgebunden (`project` aus
  `docker compose config`, Fail bei Unklarheit), Anzeige vorher, zeilenweise
  Löschung, Allowlist-Guard, Leer-Fall = Abbruch VOR `rm .env`.
- F-010 (HIGH, mit P-018-Teil): Vorab-Backup (Abbruch vor Änderung), `.env.bak.<ts>`
  (600, genau eine Generation), `trap` mit Phasen-Anzeige + Reparaturanleitung
  (DB- und Grafana-Fenster), atomarer `.env`-Tausch (beide Schlüssel, GID bleibt),
  Neu-Passwort-Verifikation per STDIN-Muster (kein ps-Leak). Reihenfolge DB→.env
  beibehalten, siehe B-10.
- F-011 (HIGH, mit P-019): Inventar (alle Nicht-Compose-Container, ehrlich ohne
  Label-Behauptung) VOR Löschung, Bestätigung erst NACH Backup-Ergebnis, `--force`
  mit Backup-Statusanzeige + Zweitphrase `RESET-OHNE-BACKUP`, TTY-Guard
  (nicht-interaktiv ohne `--force` verweigert).
- F-012 (HIGH, mit P-020-Minimal/K5): Health-Gate nach `up -d` (alle Running +
  Postgres healthy ≤ 60 s, sonst Exit 1), Prune-Guard (`until=24h` statt sofort),
  Rollback-Kommentar korrigiert (Garantie nur exakt Gepinnte; Caddy/Postgres
  brauchen Re-Pull; DB-Downgrade-Vorbehalt). Keine app/db-Aufspaltung (B-14).
- P-007-Teil: `logging`-Limits (json-file 10m×3, via `x-logging`-Anker, alle
  6 Services, per `compose config` validiert) + logrotate + df-Gate.
- P-025-Teil: Caddy-Restart nur bei Hash-Änderung UND vorher laufend; fail2ban
  `reload`-statt-`restart` (Fallback restart), sonst `start` (No-Op, Bans bleiben).
- K1-billig (F-018): Docker-GPG-Fingerprint-Prüfung mit Rotations-Hinweis.
- P-005a: TLS-On-Demand-Grenzen ehrlich kommentiert (Root auch on-demand, Budget
  gehört `ghse-unterricht.de` geteilt, Erkennung via Caddy-Log).
- F-003-Doku: `RESTORE.md` (Pfad A/B, Gates, Workspace-Gap, RTO-Tabelle offen).
- P-002-Stufe-1-Doku: `templates/allowlist.md` + Abnahme-Tabelle (Erstinventar offen).
- P-003-Pfad: `ssh-harden.sh` (Drop-In, Key-/Zweit-Zugang-Guards, `sshd -t` beidseitig,
  reversibel; wird NICHT vom Setup aufgerufen).

## Nicht implementierte Findings (bewusst, mit BLOCKER)

- F-002 Offsite-Hook (B-02): leerer Default wäre dokumentiertes Weiter-so (P-014).
- `CODER_DISABLE_PATH_APPS=true` (B-06): braucht Template-Inventar (Regression).
- Echter TLS-`ask`/DNS-01 (B-05), DOCKER-USER-Kette (B-04), Boot-Gate (B-09),
  Docker-Origins-Auto vs. Kalender (B-08), `retention.size`-Wert (B-07),
  `mem_limit` (B-13), app/db-Split (B-14), apt/curl/pull-Retries (Non-Blocking P-023,
  bewusst zurückgestellt gegen Hammer-Risiko), atomare Config-Generierung (Re-Run
  heilt deterministisch, daher zurückgestellt).

## Geänderte / neue Dateien

- `setup-coder.sh`: +463/−60 (nur geplante Finding-Eingriffe, s. Diff-Review).
- Neu: `ai-review/IMPLEMENTATION-REPORT.md` (diese Datei), `RESTORE.md`,
  `ssh-harden.sh` (+x), `templates/allowlist.md`.

## Wichtige Designentscheidungen

1. PLAN-REVIEW sticht PLAN: bei Widerspruch (umask P-010, Neuwürfeln P-011,
   Schwellwerte P-013, Reihenfolge P-018) gilt die Korrektur; P-018-Reihenfolge
   (.env-zuerst) wurde als einzige NICHT übernommen (Verhaltens-Redesign ohne
   Test-VM → B-10), abgesichert wurde der Status-quo.
2. Flock-Zweitlauf exitt 0 (Skip, kein Fail-Alarm): Ein laufendes Backup ist für
   Cron wie update.sh frisch genug; Fail würde Warnungsmüdigkeit trainieren.
3. `retention.size`, Offsite-Ziel, TLS-Modell, SSH-Termin, Boot-Gate, DOCKER-USER
   werden NICHT geraten (Werte/Architektur ohne Messung/Beschluss = neuer Schaden).
4. Zwischenfall (Regel „neue Nebenwirkung → pausieren + dokumentieren"): Erstdraft
   nutzte `MAPFILE` (ungültig, wäre Backup-Fail unter `set -e` gewesen). Gefangen
   durch isolierten Rotationstest VOR Abschluss, behoben (`mapfile`), re-verifiziert
   (20→14/4→4/0→0). Kein stilles Lösen – siehe auch ausgeführte Tests.

## Ausgeführte Tests (alle tatsächlich gelaufen, Arbeitsrechner, 2026-09-26)

- `bash -n` setup-coder.sh, ssh-harden.sh, alle 4 extrahierten Heredocs: OK.
- ShellCheck 0.11.0 (`-S warning`): Haupt + Heredocs + ssh-harden.sh – nur
  vorbekanntes SC2034 (Schleifenzähler als Iterationsbudget, Stil, verworfen) und
  SC2154-Fehlalarm (`rc` im `trap`-Single-Quote, wird zur Laufzeit zugewiesen).
- `docker compose config --quiet` gegen extrahierte Compose-Datei (Dummy-Secrets): OK;
  Logging-Blöcke für alle Services im `config`-Output bestätigt; YAML-Parse OK.
- Caddy: `caddy adapt` der extrahierten Caddyfile via stdin: OK (nur fmt-Kosmetikwarnung;
  Datei-Bind-Mount scheiterte in dieser Umgebung mit permission denied – Umgebungs-,
  kein Config-Problem, dokumentiert).
- prometheus.yml: YAML-Parse OK.
- F-001-Repro (pipefail-Modell): ohne Fix Exit 1, mit Fix Exit 0.
- Rotation (F-008), `.env`-Tausch, F-004-Leer/Treffer/Inventar-Logik: isoliert OK.
- Git-Diff-Review: alle 60 Entfernungen den Findings zugeordnet, keine Fremdänderung.

## Fehlgeschlagene / offene Tests (nicht bestanden, nicht behauptet)

- T-006 Referenz-Gate: ROT wie erwartet (PLAN abgebrochen, F-013+/D4–D9 fehlen) – B-01.
- ALLE Test-VM-Tests (T-010ff Fresh/Idempotenz/Interrupt/Netz/Docker/Security/Backup/
  Restore/Update/Reset/Reboot/extern: T-020–T-126): NICHT ausgeführt (keine Test-VM
  verfügbar). Insbesondere: cron-Paketname/Service auf trixie (T-076), GID-Recreate,
  Reset-Leer/Fremd-Volumen, Update-Gate mit Bad-Version, Restore+ RTO, SSH-Härtung,
  TLS-Fake-Subdomain, Workspace-Selbsttest – alles offen, Freigabe erst nach Nachholen.

## Bekannte Restrisiken

- Setup wurde nie Ende-zu-Ende auf frischer VM gefahren; trotz statischer
  Validierung können Laufzeitfehler (Tippfehler in seltenen Pfaden, `cron`-Paketname,
  `reload`-Verhalten fail2ban auf trixie) erst dort auffallen.
- Backup-Offsite fehlt (Totalverlust bei Platten-/Host-Schaden); Restore nie geprobt
  (RTO unbekannt); Socket bleibt Host-root-äquivalent bis D-Socket-Entscheidung;
  SSH-Passwort bleibt weltweit aktiv bis Härtungstermin; LE-Budget-DoS und Path-Apps
  bleiben bis TLS-/Template-Entscheidung; `retention.size`/Monitoring fehlen.
- df-Boden (500 MB) und Logging (10m×3) sind konservative Setzungen ohne Messung.

## Offene BLOCKER (Eigentümer + Frist erforderlich, kein Raten)

- B-01 (P-001/P-021): PLAN.md vervollständigen (F-013–F-026 oder Kürzung + Zahlenfix,
  F-012-Satz beenden) + Dangling Refs auflösen.
- B-02 (P-014/D6): Offsite-Ziel, Verschlüsselung, Schlüsselverwahrung, Retention,
  Transport-Secrets, Verfallsdatum für Leer-Default.
- B-03 (P-003/D-SSH): Key-Rollout-Termin, Zweit-Zugang-Bestätigung, Härtungsdatum.
- B-04 (P-004): Bindungsregel-Disziplin + DOCKER-USER-Vorbereitung + Dual-Stack-Test.
- B-05 (P-005/D-TLS): echter `ask` vs. DNS-01-Wildcard + CAA + Erkennungs-Betrieb.
- B-06 (P-006): Template-Inventar (`coder_app` ohne `subdomain`), dann Path-Apps aus.
- B-07 (P-007): `retention.size` nach Plattenmessung + Monitoring-Ambition (check.sh vs.
  Alerting, Schwellen, Leser).
- B-08 (P-008/D7): Docker-Engine-Pfad (Origins-Automatik mit Test-Reboot vs. Kalender).
- B-09 (P-009): Boot-Gate + `stop_grace_period` + Coder-Healthcheck für Caddy.
- B-10 (P-018): Passwort-Reihenfolge DB-zuerst vs. .env-zuerst (Test-VM-Beweis nötig).
- B-11 (P-002/P-019): Coder-Workspace-Label recherchieren + Template-Erstinventar.
- B-12 (P-014/P-015): Restore-Probe mit RTO-Zahl + Offsite-Probe + Workspace-RPO.
- B-13 (K4): `mem_limit` erst nach `docker-stats`-Woche.
- B-14 (K5/D7): app/db-Trennung + Prune-Fenster-Budget + DB-Major-Prozess.
- B-15: `.github/copilot-instructions.md` fehlt (nur Root-Datei vorhanden/verwendet).
- B-16: T-076-Verifikation (cron-Paket/Service trixie) + alle T-020–T-126 auf Test-VM.
