# CHANGELOG.md

Append-only Dokumentation des tatsächlichen Repository-Stands.
**Es gibt keine Releases.** Dieses Verzeichnis kennt keine Versionsnummern
und keine Freigaben – nur Daten, Commits und was sich tatsächlich geändert
hat. Kein Eintrag behauptet eine Prüfung, die nicht stattgefunden hat.

Format je Eintrag: Datum, Umfang, geänderte Dateien, nachweisbarer Teststand,
offene Punkte. Ältere Einträge werden nicht umgeschrieben; Korrekturen kommen
als neuer Eintrag.

Stand: 2026-10-03 · Basisstand dieses Eintrags: `824f1c6` auf `main`.
Änderungen dieses Eintrags werden mit diesem Commit eingecheckt.

---

## 2026-10-03 (4) – Grafana-Dashboard „Server-Last", Wartungsskripte vor dem Stack-Start, SSH-Drop-In `01-coder.conf`, Versions-Gate fürs Pre-Upgrade-Backup, `.env`-Kopie im Backup

**Basisstand:** `167f378` (davor: Altstands-Phrasierungen aus Docs/Kommentaren
entfernt, IServ-Fakten korrigiert – docs-only, ohne eigenen Eintrag).

- **Umfang:** Aufträge 2026-10-03: (a) Dashboard laut Coder-Monitoring-Doku
  mitprovisionieren (Gesamtlast des Servers als Zeitverlauf), (b) Review-Runde
  „Punkte bewerten, umsetzen wenn zugestimmt".
- **Umgesetzt:**
  - Grafana-Provisioning um Dashboards erweitert (`dashboards.yml` +
    `server-load.json`: CPU, RAM, Load-Average, Wurzelpartition), eigener
    Container-Mount, Neustart-Trigger = Hash des gesamten Provisioning-Baums.
  - `scripts/*.sh` werden am Ende von Schritt 2 geschrieben (vor `up -d`):
    eine Unterbrechung zwischen Schritt 3 und 5 ließ den Re-Run vor
    „inkonsistente Installation" (Volume ohne `backup.sh`) abbrechen.
  - SSH-Drop-In `99-coder.conf` → `01-coder.conf`: sshd nimmt pro Keyword den
    ersten Wert, 99 verlor gegen jede `50-*`-Datei (z. B. cloud-init); das
    eigene Alt-Drop-In wird nur mit unserer Markierung entfernt, das
    Härtungs-Snippet `00-coder-hardening.conf` sortiert weiterhin davor.
  - Pre-Upgrade-Backup nur noch bei Versionswechsel gegen `versions.env`
    (`-Fqx`-Abgleich, ohne Datei = Backup) – deckt den Code mit der längst
    dokumentierten Erwartung („Bild-Wechsel"); Re-Runs ohne Versionssprung
    laufen ohne Dump.
  - `backup.sh` legt `backups/coder.env` (600, atomar, kein Zeitstempel)
    ab; RESTORE.md nennt es als lokale `.env`-Quelle (weiterhin kein Offsite).
  - Review-Runde „eindeutige Fehler" – 6 Funde, alle nachgeprüft und
    umgesetzt: (1) Erstlauf-Abbruch vor `GRAFANA_PROV_BEFORE`, weil `find`
    ohne Verzeichnis Exit 1 liefert und pipefail+set -e die Zuweisung still
    beenden (jetzt `install -d` vor dem Hash, `|| true` an beiden Hashes);
    (2) reset löscht `versions.env` mit – sonst blockiert der Downgrade-
    Guard den Neuaufbau mit niedrigerer Version nach frischem Reset;
    (3) docker-GID-Prüfung matcht jetzt als Vollstring im JSON
    (`"99"` trifft nicht mehr `"999"`); (4) Kommentar „Fünf Regeln" auf die
    drei realen Alarmregeln korrigiert (TLS-Regeln waren entfallen);
    (5) Fertigstellungshinweis nennt README.md statt „Kopf des Skripts";
    (6) reset-Hinweise nennen das Repo-Verzeichnis (setup liegt nicht in
    `/opt/coder`).
  - Erstkonto-Prompt bleibt bewusst (`read -rs`) und ist jetzt an den drei
    maßgeblichen Stellen dokumentiert: Setup-Kopf, README „Schneller
    Einstieg", OPERATIONS §11 – inkl. der Bedingungen (kein Konto,
    EMAIL+USERNAME gesetzt, TTY) und der Browser-/Env-Variante.
  - Review-Runde „eindeutige Fehler" (zweite Sammlung, 9 Funde, alle im Code
    nachgeprüft und umgesetzt): (1) nach Erstkontosanlage kam zusätzlich
    „Noch kein Nutzerkonto" – `HUMAN_USERS` wird im Erfolgszweig auf 1
    gesetzt; (2) Hex-Zwang im .env-Gate nur noch für `POSTGRES_PASSWORD`
    (Grafana-Passwort brach sonst den nächsten Lauf, obwohl die Doku die
    Rotation per `grafana cli` vorschreibt – README/OPERATIONS/SECURITY/
    TROUBLESHOOTING A4 synchronisiert); (3) Abschlusscheck liest
    `State.Status` statt `State.Running` – im Restart-Loop meldet Docker
    `Running=true` (auf dem Testhost gemessen), das wäre ein falsches
    `[OK]` gewesen, dazu `--type container`; (4) nicht-interaktiver
    Passwortweg bevorzugt über `CODER_FIRST_USER_PASSWORD_FILE` (root-only
    Datei statt ps/History), A4-Kommentar ehrlich neu formuliert;
    (5) `postgres_data`-Filter zusätzlich auf Projektlabel `coder`
    (`name: coder` in der Compose-Datei) – ein fremdes Projekt-Volumen
    löst Backup-/Startpfad nicht mehr aus; (6) P-025-Kommentar bereinigt
    (P-025 = Restart-Verbot; die fail2ban-Behauptung war doppelt falsch);
    (7) Wartungs-Lock wandert hinter alle read-only Preflights vor Schritt 1 –
    „Abbruch vor jeder Serveränderung" ist dadurch wörtlich wahr und der
    Kommentar bei der Downgrade-Guard wieder stimmt; (8) backup.sh:
    Platz-Check vor der `.env`-Kopie (volle Platte = klare Meldung mit
    logger statt stillem `set -e`-Abbruch); (9) reset: Argument- und
    TTY-Prüfung vor dem Lock (Tippfehler/Pipe melden sofort, nicht nach bis
    zu 300 s Wartezeit).
- **Bewusst nicht umgesetzt:** Grafana-/Mail-Alerting (braucht SMTP-
  Empfänger – offener Punkt Alarmweg; die 3 Prometheus-Regeln bleiben und
  werden im UI gezeigt, ohne Anspruch auf Zustellung); Streichen von
  `write_managed`-Validierung/Atomizität, Wartungs-Locks, `ok/warn/fail`-
  Abschlusschecks, setup.conf-Parser (CRLF/Quotes/Domain-Guard),
  `versions.env`-Downgrade-Guard, backup-Retention `KEEP_MIN`
  (`find -mtime +14 -delete` könnte bei Cron-Lücke den ganzen Bestand
  löschen), reset-`--force`/Volume-Gates, Erstkonto-CLI (in §11 vorgesehen),
  Ticket-Kürzel in Kommentaren (Rückkopplung zur CHANGELOG-Disposition).
- **Geänderte Dateien:** `setup-coder.sh`, `scripts/backup.sh`,
  `scripts/reset-coder.sh`, `tests/t-b2-007-write-managed.sh` (11
  `write_managed`-Adressen, 01-Pfad, Erstlauf-Hash-Guard, Status/Projektlabel/
  Lock-Reihenfolge), `tests/t-b2-006-reset-precheck.sh` (versions.env-Löschung,
  Checks vor dem Lock), `tests/t-b2-003-hex-migration.sh` (Gate nur noch
  POSTGRES, Datei-Weg, `HUMAN_USERS=1`), `tests/t-071b-headercheck.sh`
  (Reihenfolge Platz-Check/.env-Kopie), `README.md`, `OPERATIONS.md`,
  `SECURITY.md`, `RESTORE.md`, `TROUBLESHOOTING.md`.
- **Teststand (tatsächlich ausgeführt):** `bash -n` + `shellcheck -S warning`
  sauber; Suite **294 PASS / 0 FAIL**; Pipefail-Mechanismus, GID-Match und
  Restart-Loop-Zustand (`Status=restarting Running=true`) als Einzelbefunde
  nachgestellt; Testhost `2.29.11.30`: Läufe 1–4 je RC=0 (Lauf 2:
  „Grafana-Provisioning unverändert – kein Neustart", Version-Gate greift;
  Lauf 3 nach sechs Fixes: 56 [OK]; Lauf 4 nach den neun Punkten: 56 [OK],
  kein [FEHLER], deployte Positionen geprüft: Argument 40 < Lock 63 (reset),
  sshd 322 < Lock 337 (setup), Platz-Check 73 < .env-Kopie 94 (backup),
  `State.Status=running` liefert `[OK]`), `ls /etc/ssh/sshd_config.d/` = nur
  `01-coder.conf`, `sshd -T` password/kbd=yes und
  permitrootlogin=without-password, ufw aktiv (22/80/443 ALLOW), Grafana-API
  `uid/server-load` liefert das Dashboard, 3 Alarmregeln geladen,
  `backups/coder.env` 600 nach manuellem Backup-Lauf.
- **Offene Punkte:** Alarmweg/Empfänger (SMTP-Kontaktpunkt), Inbetriebnahme-
  Lauf am Zielserver.

## 2026-10-03 (3) – Versions-Bumps auf die aktuellen stabilen Upstream-Stände (Coder v2.37.3, Caddy 2.11, Prometheus v3.15.0, Grafana 12.4.12) + Verifikationslessons in AGENTS.md

- **Umfang:** Auftrag „alle Versionsnummern prüfen und ggf. einbauen"
  (2026-10-03). Pins in `setup-coder.sh` gegen die Upstream-Quellen geprüft
  (GitHub-Releases inkl. `prerelease`-Flags, Docker-Hub-Tags) und umgestellt:
  - `CODER_VERSION` `v2.36.6` → **`v2.37.3`** (`prerelease: false`,
    2026-09-22; ghcr.io-Tag mit `v`-Präfix erneut live geprüft → HTTP 200)
  - `CADDY_VERSION` `2.10` → **`2.11`** (bewusst Minor-Pin; Tags `2.11`/
    `2.11-alpine` vorhanden, 2.11.7 released 2026-10-03)
  - `PROMETHEUS_VERSION` `v3.14.0` → **`v3.15.0`** (2026-09-25)
  - `GRAFANA_VERSION` `12.4.5` → **`12.4.12`** (`prerelease: false`;
    12.x-Security-Backport-Linie)
  - `NODE_EXPORTER_VERSION` `v1.12.1` = aktueller Latest-Stand, unverändert;
    `postgres:18-alpine` bleibt (19 nur `beta4`, außerdem Major-Entscheidung
    mit Backup, Fehler 7); Docker-Engine ohnehin apt-gesteuert und unpinned.
- **Bewusst nicht gebumpt:** Grafana-Major 13 (Daten-Migration der lokalen
  SQLite, erst im Upgrade-Fenster nach Compat-Check); Coder-Downgrade-Schutz
  bleibt unverändert (Upgrades ohne Rückfrage, Gate nur gegen runter).
- **Caddy-Kommentare mit `caddy:2.11` neu verifiziert:** Entrypoint leer +
  Cmd `caddy run …` (weiterhin `--entrypoint` nötig) und
  `unrecognized ACME issuer property: acme_ca` im Issuer-Block reproduziert;
  beide Kommentare nennen jetzt 2.11.
- **Doku synchron:** README-Bild- und Default-Tabellen auf die neuen Pins,
  SECURITY §5 Pin-Beispiel `2.11`; nebenbei in der README-Architektur-Tabelle
  „ufw `limit` + fail2ban" → „`allow` + fail2ban" (Stand der D-SSH-Revision
  von 2026-10-03); der Versions-Open-Point entfällt, weil umgesetzt.
- **AGENTS.md:** die in dieser Runde tatsächlich ausgeführten Test- und
  Verifikationsbefehle als Lessons festgehalten (Suite-Loop mit `ROT`-Meldung,
  Testhost-rsync + Doppellauf, Abnahme-Greps; Pitfalls: `grep -c` bei null
  Treffern → `|| true`, Test-/Doku-Counts bei Datei-Rotation mitziehen).
- **Geänderte Dateien:** `setup-coder.sh`, `README.md`, `SECURITY.md`,
  `AGENTS.md`, `CHANGELOG.md`.
- **Teststand (lokal):** 9 Dateien, 278 PASS, 0 FAIL; `bash -n` und
  `shellcheck -S warning` ohne Befund.
- **Teststand (Test-Host `2.29.11.30`, 2026-10-03):** rsync + zwei volle
  Läufe RC 0 (Lauf 2: 56× `[OK]`, 0 Fehler). Nachweise: `versions.env` =
  `CODER_VERSION=v2.37.3`; `compose ps` zeigt alle sechs neuen Images
  (`caddy:2.11`, `prom/prometheus:v3.15.0`, `grafana/grafana:12.4.12`,
  `ghcr.io/coder/coder:v2.37.3`); volumenbasiertes Pre-Upgrade-Backup 13:55
  vor dem Bildwechsel; Coder-API `buildinfo` = `v2.37.3+3a24816`; alte
  Images bleiben als Rollback-Basis; Pre-Flights (`caddy validate` mit 2.11,
  `promtool` 3.15) grün; die `healthz`-WARNung bleibt der bekannte externe
  Blocker (Domain zeigt nicht auf den Host).
- **Offene Punkte:** Grafana-Major 13 erst nach Compat-Check, Postgres-Major
  erst mit Backup-Entscheidung; sonst unverändert aus dem Eintrag oben
  (DNS-Weg 80/443 + Kasserver-Zugang, Offsite-Ziel, B-11-Labels,
  Budget-Sichtprüfung).

## 2026-10-03 (2) – Externes Review „Korrekturen + Vereinfachung" dispositioniert: Grafana auf Loopback, SSH-Drop-In, Reset-Gate, check-tls/Hashstore-Ära beendet

- **Review-Set (143 Z., 9 Fehler + Overengineering A–K) je Punkt gegen den
  Code verifiziert** (Fakten getrennt von Annahmen; vereinzelte Review-Punkte
  trafen die Quelle nicht – s. u. „abgelehnt"). Zugestimmt und umgesetzt:
  - **Fehler 1–3 (Grafana):** `ports` auf `127.0.0.1:3001:3000`; die drei
    alten ufw-Quellregeln und eine `3001/tcp`-Regel werden idempotent
    entfernt (harte Allowlist, nur diese vier Spezifikationen); Abschluss-
    check verlangt das **Fehlen** jeder 3001-Regel; Zugang ausschließlich
    per SSH-Tunnel (Zusammenfassung nennt den Befehl).
  - **Fehler 4:** Abschlusscheck prüft `apt-daily-upgrade.timer`
    (aktiv + enabled) statt `is-active unattended-upgrades` (auf Debian
    oneshot – der alte Check war ein False-Failure).
  - **Fehler 5:** Pre-Upgrade-Backup volumen-basiert erkannt
    (`label=com.docker.compose.volume=postgres_data`), hart bei
    fehlendem `backup.sh`, Postgres wird gestartet und per `pg_isready`
    (30×2 s) abgeklopft, dann Backup.
  - **Fehler 6/7 (teilweise):** `versions.env` enthält nur noch
    `CODER_VERSION` (allein Coder führt irreversible DB-Migrationen aus;
    Postgres bewusst manuell, als „Fehler-7-Entscheidung" kommentiert).
    Die SchreibPOSITION direkt nach `up -d` bleibt **bewusst**: erst
    Healthcheck würde die Downgrade-Warnung schwächen, die Migration
    läuft beim Start, nicht bei „gesund" (Begründung im Code).
  - **Fehler 12:** `backup.sh`: schlägt `df` fehl, bricht der Lauf ab
    (sonst läuft der Dump ohne Platzprüfung in die ENOSPC).
  - **SSH-Policy:** eigenes Drop-In `/etc/ssh/sshd_config.d/99-coder.conf`
    (`PasswordAuthentication yes`, `KbdInteractiveAuthentication yes`,
    `PermitRootLogin prohibit-password`), validiert über `sshd -T` auf der
    GESAMTEN Konfiguration – bei Fehlschlag alter Inhalt wiederherstellen
    und vor dem Reload abbrechen; Reload nur bei aktivem Dienst; Effekt-
    Check gegen die **neu geladene** Konfiguration; Passwort-Check
    invertiert (Warnung, wenn die Policy nicht wirkt), Warnung bei
    `permitrootlogin yes` fremder Drop-Ins.
  - **Reset (§3):** unbekannte Argumente werden abgelehnt (nur `[]` und
    `--force`, Verhaltensfixture im Test); Nicht-Compose-Container =
    **harter Abbruch vor Backup/Bestätigung/down** (Inventar-Format 3
    Spalten, auch Unlabelled), `--force` hebt das Gate nicht auf; die
    weichen B-020-Hinweise sind entfallen.
  - **Overengineering entfernt:** Hashstore/`note_drift`/`remember_hash`
    samt Drift-Warnung und Schritt-10-Heilschleife (A) – `write_managed`
    bleibt der atomare Schreiber (Verhalten fixture-getestet: Inode
    stabil bei gleichem Inhalt, bash -n-Guard, Validierer vor Austausch);
    `check-tls.sh` + Cron `coder-tlscheck` + `coder_tls.prom` + logrotate
    `coder-logs` + Alerts `TlsIssuanceBudgetHigh`/`TlsCheckStale` +
    `tests/t-b2-005` (D, Fehler 8–9) – Altbestand wird beim Lauf still
    entfernt; Daemon-Restartbedingung ehrlich auf „beliebiger Container"
    (Log-Limits bleiben daemon-weit, weil Workspace-Container sie brauchen).
  - **fail2ban `ignoreip` (Punkt 3):** Entscheidung festgeschrieben – NUR
    echte Admin-Plätze, Default bleibt `127.0.0.1/8 ::1`, die geteilte
    Schul-NAT wird bewusst **nicht** eingetragen (Rateversuche aus dem
    Schulnetz sollen sperren; Recovery: anderes Netz oder Proxmox-
    Konsole). Kommentare in Setup, README-Offener-Punkt und SECURITY §2
    sind synchronisiert.
  - **Version-Kommentar v-Präfix:** live gegen die Registry geprüft
    2026-10-03 – `ghcr.io/coder/coder:v2.36.6` und `:v2.37.3` → HTTP 200,
    ohne `v` → 404. Der Review-Punkt traf die Release-Notes, nicht die
    Registry; der Setup-Kommentar bleibt und nennt jetzt beide Daten.
- **Abgelehnt (Grund):** First-User-Automatik (Erstbesitzer-Race =
  Sicherheitspropert – bleibt manuelle Prozedur), Auto-Reboot 03:00
  (Fenster mit Schulbetrieb abgestimmt, D-Reboot-Fenster), Zeitzone im
  Installer (C1-Lokalzeit-Prüfung bleibt), `.env`-Validator (Parse-Check +
  hex-Guard reichen), `DOMAIN_CODER_REGEX` (Security-Filter mit Tests),
  Reload-Orchestrierung (bereits eine Schleife je Dienst),
  versions.env-Schreibposition (siehe Fehler 6), globales `daemon.json`
  (Log-Limits müssen auch Workspace-Container decken), Versions-Bumps
  (Caddy 2.11.7/Prometheus 3.15/Grafana 13 Major – als Empfehlung
  dokumentiert, kein Blind-Bump, Grafana-Major erst nach Compat-Check),
  Alertkanal und Offsite-Automatismus (bleiben Entscheidungs-/Doku-
  punkte, Review zwingt hier zu nichts).
- **Geänderte Dateien:** `setup-coder.sh`, `scripts/backup.sh`,
  `scripts/reset-coder.sh`; entfernt: `scripts/check-tls.sh`,
  `tests/t-b2-005-tls-window.sh`; umbenannt+umschrieben:
  `tests/t-b2-007-drift-hash.sh` → `tests/t-b2-007-write-managed.sh`
  (Struktur: 9 direkte Zieldateien + SSH-Drop-In; Verhalten a–d als
  Extrakt-Fixture); ergänzt: `tests/t-b2-004-ufw-ssh-rules.sh`
  (Delete-Zählung 2/1 + 3001-Allowlist-Prüfung),
  `tests/t-b2-006-reset-precheck.sh` (Argument-Ablehnung + Fremd-Gate
  inkl. Position vor Volumen-Ermittlung); Doku: `README.md`,
  `SECURITY.md`, `OPERATIONS.md`, `TROUBLESHOOTING.md`.
- **Teststand (lokal):** 9 Dateien, 278 PASS, 0 FAIL; `bash -n` und
  `shellcheck -S warning` ohne Befund.
- **Teststand (Test-Host `2.29.11.30`, 2026-10-03):** rsync + zwei volle
  Läufe RC 0 (0 Fehler). Am Host nachgewiesen: `sshd -T` mit
  `passwordauthentication yes`, `kbdinteractiveauthentication yes`,
  `permitrootlogin without-password`; ufw ohne jede 3001-Regel;
  `127.0.0.1:3001` gebunden (docker-proxy); `/etc/cron.d/coder-tlscheck`,
  `/opt/coder/check-tls.sh`, `/opt/coder/.generated-hashes` und
  `/etc/logrotate.d/coder-logs` entfernt; `versions.env` nur
  `CODER_VERSION=v2.36.6`; genau 3 Alarmregeln (`BackupStale`,
  `CoderTargetDown`, `RootPartitionFillingUp`); `apt-daily-upgrade.timer`
  aktiv+enabled; `/opt/coder/` enthält nur noch `backup.sh` und
  `reset-coder.sh`. Die `healthz`-WARNung bleibt der bekannte externe
  Blocker (Domain zeigt nicht auf den Host).
- **Offene Punkte:** Versions-Bumps je Empfehlung prüfen (Open-Point
  oben); Budget-Sichtprüfung ohne Automation (manuell, OPERATIONS §5);
  Offsite-Ziel/Rhythmus entscheiden (Doku-Pflicht, kein Code); DNS-Weg
  für 80/443 + Kasserver-Zugang beim Schulträger klären (Befund
  2026-10-03: Zone bei Kasserver/All-Inkl, `A` zeigt aktuell auf die alte
  Schulseite, `93.240.138.106` ist der Kreis-Proxy `logoip.de`); Reset-
  Gate braucht vor Produktivbetrieb Workspace-Labels bzw. sauberes
  Inventar (B-11). dispositioniert: SSH auf allow+fail2ban, sechs Bugs gefixt, Rest abgelehnt

- **Review-Set (143 Z., Abschnitte 1–4) je Punkt gegen Code verifiziert.**
  Zugestimmt und umgesetzt:
  - **§1 SSH** (Empfehlung „allow statt limit + fail2ban" akzeptiert, 1.1–1.5):
    Port-Erkennungsschleife `sshd -T` statt Abbruch bei Port != 22 (leerer
    Port bleibt harter Abbruch); weltweite `allow 22/tcp` wird gesetzt,
    danach `delete limit 22/tcp` – Reihenfolge ohne Fenster ohne
    SSH-Regel, Quellregeln und fremde Allows bleiben unangetastet;
    Abschlusscheck verlangt `ALLOW` (eine `LIMIT`-Regel zählt nicht);
    TROUBLESHOOTING A7 neu (Passwort-Login in `sshd_config.d/*.conf`,
    keine Komma-Port-Regeln, kein `show added`) und E1 neu; fail2ban-
    Drop-In auf die nicht-default Keys reduziert (`sshd`, `port`,
    `bantime`+`increment`, `ignoreip`) – Defaults am Test-Host verifiziert
    (`jail.d/defaults-debian.conf` enabled+systemd, `jail.conf` 5/10m),
    Begründung als Kommentar (B13).
  - **§2:** 2.1 Doppel-Installation der `scripts/*.sh` (write_managed +
    `install`) durch eine Schleife ersetzt, Schritt 7 entfällt
    (`[x/8]`→`[x/7]` überall); 2.2 setup.conf-Parser: CR- und Quote-Strip
    plus Domain-Regex-Guard mit hartem Abbruch; 2.4 check-tls: `find`-RC
    wird weitergereicht (echte Lesefehler = Exit 1 ohne Metrik), dazu der
    frische-Installation-Fall – fehlendes `certificates`-Verzeichnis zählt
    als 0 Ausstellungen MIT Erfolgszeitpunkt, sonst feuert `TlsCheckStale`
    bis zum ersten Zertifikat; 2.5 reset-coder: Nicht-TTY wird immer
    verweigert, auch mit `--force` (am Test-Host: Pipe → Verweigerung,
    rc 1); 2.9 Update-Cadence „mind. monatlich + kritische CVEs" in
    OPERATIONS §7; 2.11 geprüft – die README-Dokuliste führt
    TROUBLESHOOTING bereits, kein Änderungsbedarf (Head-Liste im Setup
    ist bewusst die Inhaltsdoku).
  - **§3:** 3.11 `tee > /dev/null` → Redirects (5 Stellen).
  - **3.1 = Nutzerentscheidung:** Monitoring bleibt (Option 1), offene
    Zeile „Alarmweg/Empfänger klären" in README, D-Monitoring in SECURITY
    aktualisiert; **Q2 umgesetzt:** Grafana `3001:3000` auf allen
    Interfaces (Router leitet nur 80/443/22) plus drei ufw-Quellregeln
    (10/8, 172.16/12, 192.168/16), Abschlusscheck, A7b-Bindungs-Ausnahme
    mit Begründung, Setup-Zusammenfassung nennt `http://<IP>:3001`.
  - **§4 Reihenfolge** als Arbeitsreihenfolge gefolgt (Bugs → SSH →
    Klein-Vereinfachungen → Doku/Tests); keine eigenständige Änderung.
- **Abgelehnt (Grund):** 2.3 Pflichtfelder für Domain/ACME-Adresse
  (Einzelschul-Repo, Werte überall in Doku/Git – Reibung ohne Schutz);
  2.6 Allowlist-`case` in reset-coder (bewusster Tripwire auf ein
  unbekanntes Volume-Label, kein toter Code); 2.7 Workspace-Cleanup
  (blockiert auf Label-Verifikation A9/B-11, offener Punkt mit Owner);
  2.8 Offsite/Volumes (D-Offsite 2026-09-30 entschieden, Workspace-Homes
  bereits akzeptierter Verlust); 2.10 LE-Budget (bereits offener Punkt,
  Option 1: Warnung ab 20, DNS-01 wartet auf Token); 3.2 On-Demand-TLS
  (geparkt bis TLS-Strategie entschieden – ohne DNS-01 aktuell kein TLS);
  3.3 Drift-System, 3.4 Downgrade-Schutz, 3.5 Locks, 3.7 Erstkonto,
  3.13 Kommentar-IDs (vorherige Entscheidungen B3-Kern/B15/B4/Q6-A4/B20
  bleiben); 3.6 Abschlusschecks (dokumentierter Betriebswert – `set -e`
  prüft nicht, ob Konfiguration auch aktiv ist); 3.8 Backup-Verifikation
  und -Rotation (Datensicherungspfad: Größenregressions-Check fängt leere
  Dumps, Mindestbestand 7); 3.9 retry3 (Schulnetz: Pause + Ursachen-Log
  beabsichtigt); 3.10 Logdateien/logrotate (Dateien überleben
  Journal-Vacuum, getestet, in Doku tabelliert); 3.12 node-exporter-Port
  (OPERATIONS §5 checks curlen `127.0.0.1:9100`).
- **Testhost-Fund (2026-10-03, Durchläufe auf `2.29.11.30`):** erster
  Lauf RC 1 – `ufw allow from 10.0.0.0/8,172.16.0.0/12,…` (Komma-Liste)
  meldet `ERROR: Bad source address`; Fix = drei Einzelregeln. Danach
  drei Re-Runs RC 0 (0 FEHLER). Weitere Live-Befunde: die vorhandene
  `22/tcp LIMIT`-Regel wird von `allow` konvertiert („Rule updated",
  eine Regel, kein Doppel – deshalb verlangt der Abschlusscheck ALLOW);
  Drift-Warnung zweimal real verifiziert (Hand-Edits an backup.sh und
  check-tls.sh → WARN → regeneriert, Hashstore stimmt); TLS-Check einmalig
  OK über den frischen-Installation-Pfad (Metrik 0 + Timestamp); ufw =
  `22/tcp ALLOW` (kein LIMIT), 3× 3001-ALLOW aus Privatnetzen; Grafana
  lauscht auf `0.0.0.0:3001`; fail2ban-Jail `sshd` aktiv, Drop-In enthält
  nur die vier Keys; alle `/opt/coder/*.sh` Mode 755.
- **Datums-Korrektur:** die in dieser Runde gesetzten Datumsangaben
  waren um einen Tag auf 2026-10-02 verschoben (Review kam am
  2026-10-03 07:49 an) – in README, SECURITY, OPERATIONS, setup-coder.sh
  und t-b2-004 auf 2026-10-03 gezogen; OPERATIONS §10-Teststand
  gleichzeitig von 267 auf 280 PASS angehoben (war von der vorigen Runde
  stehen geblieben).
- **Nachtrag gleicher Runde (Todo-Abarbeitung):** OPERATIONS-Satz zum
  Reset korrigiert – ohne Terminal wird der Reset **immer** verweigert,
  auch mit `--force` (die alte Formulierung beschrieb das Verhalten vor
  2.5); offene Punkt-Zeile „`FAIL2BAN_IGNORE_IP` mit der öffentlichen
  Schul-NAT-IP vor der Inbetriebnahme setzen" in README (braucht die
  IP-Adresse des Betreibers); Vorkommen von offsite/Workspace-Volumes,
  Docker-Patchtermin und Reset-Verhalten in der Doku gegengeprüft.
- **Teststand (lokal, 2026-10-03, tatsächlich ausgeführt):** 10 Dateien,
  280 `PASS`, 0 `FAIL`; `bash -n setup-coder.sh scripts/*.sh tests/*.sh`
  und `shellcheck -S warning` derselben ohne Befund. Geänderte Dateien:
  `setup-coder.sh`, `scripts/check-tls.sh`, `scripts/reset-coder.sh`,
  `tests/` (t-b2-003/-004/-005/-006/-007, t-071b, t-090), `README.md`,
  `SECURITY.md`, `OPERATIONS.md`, `TROUBLESHOOTING.md`, `CHANGELOG.md`.
  Offene Punkte: unverändert (DNS-API-Token, A9/Hairpin + B-11-Labels,
  RTO/frische VM, Produktionsfreigabe, Push) plus neu „Alarmweg/
  Empfänger klären" (Owner Betreiber).

---

## 2026-10-02 – Review-Nachlese §3/§4: B2 als letzter Punkt dispositioniert (abgelehnt), drei Doku-Korrekturen

- **§3/§4 des Reviews gegengelesen, jeder Punkt dispositioniert.**
  §3 (SSH) im Code/Doku bestätigt: B11-Regelpfad (Quellregeln bleiben,
  `ufw limit 22/tcp`), fail2ban mit `FAIL2BAN_IGNORE_IP` hinter `setup.conf`
  (A5, Warnung „Tippfehler sperrt die Schul-NAT" in SECURITY §2),
  PermitRootLogin-WARN und `HINWEIS` statt `[OK]` für den Passwort-Check
  (A7), SSH-Nachhärtung als 10-Zeilen-Drop-In `00-coder-hardening.conf`
  in SECURITY §1 (Q4). Nachgetragen: **Passwortstärke-Satz in OPERATIONS
  §11** (lange Passphrase, kein Standard-/Schulpasswort – Review §3.5,
  bisher nirgends dokumentiert).
- **B2/Zielbild (§4) abgelehnt** – der einzige bisher nicht
  dispositionierte Punkt der Review-Liste. Begründung: Die Kritik an
  unvalidierten Live-Überschreibungen ist mit A2 neutralisiert
  (Temp-Datei validieren, dann atomar ersetzen); ein Umzug aller Heredocs
  nach `files/` und der Pins nach `config.env` ändert keine
  Sicherheitseigenschaft, verschiebt nur den Speicherort, koppelt aber an
  die Pin-Mechanik (B15, bewusst so belassen) und fassen kurz vor der
  Inbetriebnahme alle generierten Dateien und die Mehrheit der Tests an –
  nach 3× Live-RC0 ohne Funktionsgewinn. Zeilenzahl ist kein
  Sicherheitsattribut. Bei späterem Wartungsschmerz nachholen.
- **Doku-Korrekturen:** SECURITY §7 – Log-Rotation-Liste nannte noch
  `/var/log/coder-boot.log` (entfiel mit B8, es gibt keinen Schreiber
  mehr); README „was die Tests belegen" – „Drift-Hashes über 13 Dateien"
  präzisiert zu „13 `write_managed`-Zieldateien samt Drift-Warnung und
  Hash-Heilung" (11 davon gelabelt und gehasht, dazu `versions.env`
  ohne Label).
- **Testhost-Aufräumarbeit (kein Repo-Code):** Hashstore
  `/opt/coder/.generated-hashes` von 16 auf 11 Zeilen – Geisterzeilen
  entfernter Altdateien (`boot-check`, `update`, `reset-passwords`,
  `coder-bootcheck`) und der nicht mehr verfolgte `reset-coder.sh`-Rest
  entfernt; die Einträge waren inert (`note_drift` läuft nur pro
  `write_managed`-Ziel), aufräumen nur, damit §10-Prüfbefehl und
  Dokumentation zusammenpassen.
- **Teststand (lokal, 2026-10-02, tatsächlich ausgeführt):** 10 Dateien,
  267 `PASS`, 0 `FAIL`; `bash -n setup-coder.sh scripts/*.sh tests/*.sh`
  und `shellcheck -S warning` derselben ohne Befund; `show-sources.sh`
  (Standard und Teilmenge) ohne Befund. Geänderte Dateien: `README.md`,
  `OPERATIONS.md`, `SECURITY.md`, `CHANGELOG.md`. Offene Punkte
  unverändert: DNS-API-Token, A9-Test, RTO/frische VM, Workspace-Homes,
  Produktionsfreigabe.

---

## 2026-10-01 – Testhost-Lauf der Review-Runde: Rechte-Fix im A2-Validierer, check-tls still

- **Live-Lauf (Test-Host `2.29.11.30`, keine Produktion, Stand `e39d0d1`
  per rsync ohne `.git`):** erster Lauf bewusst RC 1 – `validate_prom_rules`
  scheiterte mit `permission denied`, weil `mktemp` die Temp-Datei als
  `600` anlegt, der `promtool`-Container aber als `nobody` läuft (Fund der
  neuen A2-Validierung, fail-closed: Live-Datei blieb unangetastet).
  **Fix:** `write_managed` hebt die Temp-Datei vor dem Validierer auf 644
  (Endmodus folgt ohnehin per `chmod "${mode}"`); statischer Check in
  `t-b2-007`. Danach drei Läufe RC 0 (je 46 s), `0 [FEHLER]`, nur der
  bekannte healthz-WARN (DNS/Portweiterleitung fehlt extern weiterhin).
- **Verifiziert am Host:** Metriken `coder_tls_issuances_7d` +
  `coder_tls_check_last_success_timestamp_seconds` vorhanden, kein
  `coder_tls_log_*` mehr; Prometheus lädt die **5** Alarmregeln; ufw genau
  eine `22/tcp LIMIT`-Regel (v4/v6); `/etc/cron.d/` ohne `coder-bootcheck`,
  Logrotate `coder-logs` ohne `coder-boot.log`; `backup.sh` RC 0,
  `gzip -t` grün; die drei Wartungsskripte byte-identisch zu `scripts/`.
  Veraltete Altstand-Dateien manuell entfernt (wie zuvor `ssh-harden.sh`):
  `/opt/coder/{update,reset-passwords,boot-check}.sh`, `/opt/coder/domain`,
  `/etc/cron.d/coder-bootcheck`.
- **Zwei Feinfixes aus dem Lauf:** `check-tls.sh` unterdrückt den
  `find`-Fehler für den noch nicht angelegten `certificates`-Ordner (auf
  diesem Host normal, solange nie ein Zertifikat ausgestellt wurde – sonst
  wöchentliches Rauschen im Log); Idempotenz-Hinweis: nach B10 erneuert
  `install(1)` die mtime der drei Skripte bei jedem Lauf, der **Inhalt**
  bleibt byte-identisch (Drift 0, Hashstore unverändert).
- **Teststand (lokal, tatsächlich ausgeführt):** 10 Dateien, **267
  `PASS`**, 0 `FAIL`; `bash -n` und `shellcheck -S warning` ohne Befund.
  Offene Punkte unverändert aus dem Eintrag oben (DNS-API-Token, A9,
  RTO/frische VM, Workspace-Homes).

---

## 2026-10-01 – Review-Runde A1–A12/B1–B21: Setup-Prüfungen gestärkt, tote Wartungsskripte entfernt, Doku synchron

- **Umfang:** Umsetzung der externen Review-Liste (Bewertung je Punkt,
  Umsetzung oder dokumentierte Ablehnung). Satz „Basisstand bis zur
  expliziten Freigabe" blieb gilt: alles lokal committet, kein Push, kein
  Eingriff auf Produktion.
- **Umgesetzt (Setup/Code):** A2 – `write_managed` validiert die Temp-Datei
  vor dem `mv` (`validate_compose|caddyfile|prom_rules|prom_config`),
  `docker compose pull` (retry 3) direkt nach dem Compose-Schreiben in
  Schritt 2, Post-Start-Validierungen entfallen (Caddy: nur noch `reload`).
  A4 – Erstpasswort interaktiv per `read -rs` abfragen (TTY + Variable leer;
  niemals als Argument). A5 – `setup.conf` mit Parser vor den Defaults,
  Allowlist (`DOMAIN_CODER|ACME_EMAIL|ACME_CA|FAIL2BAN_IGNORE_IP`),
  Vorrang Env > setup.conf > Default, `setup.conf.example`, `.gitignore`.
  A6 – `scripts/check-tls.sh` komplett neu: zählt `*.crt` mit `mtime -7`
  im `caddy_data`-Volume statt `docker logs`, exportiert
  `coder_tls_issuances_7d` + `coder_tls_check_last_success_timestamp_seconds`
  atomar; Alert `TlsLogTruncated` und Metriken `coder_tls_log_*` entfallen
  (Regelwerk: 5 statt 6). A7 – `.env` per `install`/`chown`/`chmod`,
  Kommentarkorrekturen (80/443, Backup 01:00, `${VERSION_CODENAME}`,
  Passwort-Hinweis als `echo` statt leerem `else`), A7c als Kommentarfehler
  korrigiert. A8 – `CODER_PROXY_TRUSTED_HEADERS`/`_ORIGINS` (172.16.0.0/12,
  127.0.0.1/8) gesetzt. A10 – `sshd`-Binary- und `sshd -T`-Port-Check im
  Preflight vor Schritt 1. B3 – `forget_hash` und hashbasierte
  Reload-Entscheidung entfernt; B9 – `iproute2` und drittes
  `apt-get update` entfallen; B10/B21 – Skript-Copy als eine
  `install -m 755 -t /opt/coder`-Zeile (Schritt 7), Test-Backup nur ohne
  vorhandenen Dump; B11 – ufw-Pfad neu: alte `allow 22/tcp`-Weltregeln
  entfernen, Quellregeln bleiben unangetastet, Abschluss mit
  `ufw limit 22/tcp` (Entscheidung Q1: Quellbeschränkung bleibt allein der
  Netzvorgabe überlassen); B12c – Docker-Origin-Check entfernt; B13 –
  `systemctl enable --now fail2ban` + reload-retry, ein einziger
  Abschluss-Check (Bans liegen in SQLite, kein Jail-Restart nötig); B16 –
  Bash-n-Prüfung eingebaut; Schritt-Nummerierung 10 → 8 (`[1/8]`…`[8/8]`).
- **Entfernt (Q4 „alle vier"):** B5 `scripts/update.sh`, B7
  `scripts/reset-passwords.sh`, B8 `scripts/boot-check.sh`, B19
  `ssh-harden.sh` samt `tests/t-b2-010-boot-gate-health.sh` und
  `/opt/coder/domain`-Schreibblock; Cron `coder-bootcheck`,
  `@reboot`-Gate und Logrotate-Zeile `coder-boot.log` entfallen. Ersatz in
  der Doku: Update = Pin-Änderung + erneuter Setup-Lauf (OPERATIONS §7),
  Grafana-Rotation manuell (OPERATIONS §7), SSH-Nachhärtung als
  10-Zeilen-Drop-In `00-coder-hardening.conf` (SECURITY §1), Wiederanlauf
  nach Reboot per `docker ps`/`/healthz`.
- **Abgelehnt (mit Grund):** A1 (Limit 50/Zertifikats-Woche bleibt,
  Warnung ab 20; DNS-01 = offener Punkt mit Owner + DNS-API-Token), A3,
  A11, A12, B1, B3-Kern (Drift-System bleibt), B4, B6, B12a/b, B14-SighUP
  und Hash-Subpunkt, B15, B16a, B17, B18, B20, D-Monitoring (B5:
  Client-IPs bleiben aus dem Audit).
- **Doku:** README (Schritte-Tabelle 8 Zeilen, Setup.conf, Testszahlen,
  offene Punkte: DNS-API-Token- Anfrage und A9-Hairpin-Test mit Owner),
  OPERATIONS (§1/§2 Dateiliste, §3 setup.conf, §5/§6 Metriken und Logs,
  §7 Update/Rotation/Reboot, §8 Lock, §9 Cron, §10 Tests, §11 Abnahme),
  SECURITY (§1 Drop-In statt Skript, §2 Rotation, §3/§7–§9 dateibasierte
  Zählung, D-TLS/D-SSH-Zeilen), TROUBLESHOOTING (§0, A3, A4, A9, B3, B4,
  C1, C3, C4, D, F, G2), RESTORE (Verweise).
- **Teststand (lokal, 2026-10-01, tatsächlich ausgeführt):** 10 Dateien in
  `tests/`, 266 `PASS`, 0 `FAIL`, alle Exit 0; `bash -n setup-coder.sh
  scripts/*.sh tests/*.sh` ohne Befund; `shellcheck -S warning` derselben
  Dateien ohne Befund. Neu geschrieben: `t-b2-003` (Setup-Guards +
  A4-Live-Test), `t-b2-004` (B11-Regelpfad mit Fake-ufw),
  `t-b2-005` (dateibasierte TLS-Zählung, kein `docker logs`-Code);
  angepasst: `t-090`, `t-b2-006`, `t-b2-007`, `t-b1`; gelöscht:
  `t-b2-010`. Kein VM-/Produktionslauf in dieser Runde.
- **Offene Punkte:** DNS-API-Token für DNS-01 beim Netzwerkadmin anfragen
  (Betreiber, OPERATIONS §11 Zeile 6); A9-Test (Test-Workspace +
  Port-Forwarding vom Schulnetz aus, OPERATIONS §11 Abnahme); RTO inkl.
  VM-Boot und `/healthz` unter echtem DNS (braucht frische VM/DNS);
  Workspace-Homes: Verlust deklarieren oder eigene Volume-Sicherung
  (RESTORE.md).

- **Live-Prüfung der Skript-Extraktion (Test-Host `2.29.11.30`, keine
  Produktion):** Stand `bc05da2` per rsync eingespielt. Re-Run RC 0 in
  56 s; alle sechs Wartungsskripte in `/opt/coder` byte-identisch zu
  `scripts/` (md5), 0 Warnungen, 0 Fehler. Zweiter Re-Run RC 0 in 47 s
  ohne einzige mtime-Änderung an den sechs Skripten – identischer Inhalt
  wird nicht umgeschrieben (Idempotenz), 0 Drift. Anschließend
  `backup.sh` RC 0 mit frischem Dump (`gzip -t` grün) und `check-tls.sh`
  RC 0 (Logfenster 0 h nach Container-Neustart, Meldung korrekt).
  Veraltete Kopie `/opt/coder/ssh-harden.sh` vom Altstand entfernt
  (Review 0.2: das Setup legt sie nicht mehr an).
- **Bugfix:** `setup-coder.sh` stand seit dem ersten Commit als `100644`
  im Repo, die Doku ruft aber überall `sudo ./setup-coder.sh` auf – ein
  frischer Clone scheiterte mit Permission denied (RC 126, festgestellt
  beim Live-Deploy). Jetzt `100755` (ebenso `scripts/*.sh`), Guard gegen
  Wiederverlust in `t-root-guard.sh` ergänzt.
- **Geänderte Dateien:** `setup-coder.sh`, `scripts/` (nur Modus),
  `tests/t-root-guard.sh`, `README.md`, `OPERATIONS.md`, `CHANGELOG.md`.
- **Teststand (tatsächlich ausgeführt, 2026-10-01):** alle 11 Dateien in
  `tests/` grün (329 PASS, 0 FAIL); `bash -n` und `shellcheck -S warning`
  ohne Befund; Setup-Re-Runs auf dem Test-Host wie oben.
- **Offene Punkte:** unverändert, gebündelt in README „Offene Punkte –
  wer macht was".

---

## 2026-10-01 – Externe Review-Liste (0.x–3.x) abgearbeitet, Wartungsskripte nach `scripts/`

- **Anlass:** externe Review-Liste (SSH 0.x, Risiken 1.x, Vereinfachungen
  2.1–2.11, Entscheidungen 3.x), im Chat stattgefunden; die Liste selbst
  liegt nicht im Repo. Umsetzung, Ablehnungen und Review-Befunde werden
  hier als Einzelnachweis festgehalten, die Punktnummern stammen aus den
  Commit-Meldungen und Code-Kommentaren der Umsetzung.
- **Umfang (7 Commits, `8a5f78c`..`1e51f0d`):**

  | Commit | Review-Punkte | Inhalt |
  |---|---|---|
  | `8a5f78c` | 1.1, 1.7, 1.8 | kein Upgrade ohne frisches Pre-Backup (bricht vor `up -d` ab), Backup-Rotation nach Alter mit Mindestbestand 7, unbelegte Telemetrie-/Editions-Aussagen aus Kommentaren und Grafana-Analytics raus |
  | `67cf4e8` | 0.1, 0.2, 0.3, 1.4, 2.3, 2.4 | ufw/SSH-Schritt als feste Sequenz (Quellbeschränkungen unangetastet, nur die drei weltweiten Allow-Schreibweisen gelöscht, `limit 22/tcp` verifiziert), Passwort-Nag-Block und Kopie von `ssh-harden.sh` nach `/opt/coder` raus, fail2ban `bantime.increment`+`ignoreip`, Warnung bei `PermitRootLogin yes`, jail.d-Lese-Reihenfolge korrigiert, Warnung statt Hash-Guard bei vorhandenem `jail.local` |
  | `374d0ab` | 2.3, 2.5 | tote Migrationspfade raus (Alt-Mounts, `52-coder-docker-upgrades`, Root-Crontab – Test-Host per ssh geprüft, nichts davon vorhanden); warn-only Port-Preflight raus, `t-b2-008` gestrichen (ein echter Konflikt bricht `compose up` ohnehin mit klarem Fehler ab) |
  | `b24d418` | 2.6, 2.9, 2.10 | Caddy/Prometheus statt Hash-Gate jetzt Validierung+SIGHUP/Admin-Reload bei jedem Lauf (Grafana behält sein Hash-Gate, nur sein Neustart ist störend); ACME-Email globale Caddy-Option statt zwei Issuer-Blöcke (mit `caddy:2.10 validate/adapt` verifiziert); x-logging-Anker und sechs Referenzen raus (`daemon.json` ist Einzelquelle) |
  | `a9b0d08` | 2.7, 2.8 | Compose-`group_add` mit numerischer GID direkt aus dem Lauf (kein `.env`-Umweg, kein Refresh/Recreate-Block), Passwort-Reset auf Grafana beschränkt (Zwei-Schlüssel-Gate, kein Postgres-`ALTER USER` mehr) |
  | `f3c6383` | Kopf/Version | Setup-Kopf von 89 auf 24 Zeilen (DNS, On-Demand, SSH, Skriptlisten usw. leben in README/OPERATIONS/SECURITY), Versionswissen an die `CODER_VERSION`-Definitionsstelle |
  | `1e51f0d` | 2.1 | sechs Wartungsskripte als echte Dateien unter `scripts/` (erstmals `bash -n`- und shellcheck-bar), Setup spielt sie per `write_managed` ein; sechs Tests auf Dateipfade umgestellt, je mit Link-Wächter; SC2106-Fix: `\|\| continue` bei der Backup-Rotation stand innerhalb der Subshell |

- **Bewusst nicht umgesetzt / abgelehnt:**

  | Punkt | Entscheidung und Grund |
  |---|---|
  | 2.2 (Drift-Mechanik vereinfachen) | behalten: Drift-Prüfung vor dem atomaren Austausch, Hash danach, über `t-b2-007` abgesichert |
  | 0.3-Teil „Drop-In auf Default-Werte schrumpfen" | behalten: explizite Werte bleiben (z. B. `backend=systemd` mit Begründung im Code); die übrigen 0.3-Vorschläge (`bantime.increment`, `ignoreip`) sind umgesetzt |
  | Vorschlag zur 9100-Bindung | unverändert: Port bleibt an `127.0.0.1` gebunden |
  | 1.2 (Offsite-Backup neu aufsetzen) | kein Vorschlag ohne festgelegtes Ziel/Transport/Schlüsselverwahrung; D-Offsite ist entschieden 2026-09-30: kein zweiter Standort, Restrisiko akzeptiert ([SECURITY.md](SECURITY.md) §9) |
  | 1.3, 3.1, 3.2 (Alarmwege) | kein erfundener Empfänger, Kanal oder Zugang; D-Monitoring ist entschieden 2026-09-30: kein Kanal, Grafana/Prometheus sind die Anlaufstelle (SECURITY §9). Umentscheiden bleibt dem Betreiber vorbehalten |
  | Review-Befund „`ssh-harden.sh` fehlt im Repo" | widerlegt: die Datei liegt im Repo, wird nur nicht vom Setup aufgerufen (D-SSH) |
  | Review-Befund „`ai-review/` fehlt" | widerlegt: das Verzeichnis ist mitgeliefert |

- **Neu in der Doku:** RESTORE „Was das nach einem Restore heißt"
  (ACME-/Rate-Limit-Folgen ohne `caddy_data`, Workspace-Homes-Verlust),
  TROUBLESHOOTING B6 (NAT-Hairpin: lokal `--resolve` ok, öffentlicher Pfad
  von innen tot – extern verifizieren, nicht am Stack drehen), README
  „Offene Punkte" um die Workspace-Homes-Entscheidung.
- **Geänderte Dateien:** `setup-coder.sh`, `scripts/` (neu: `backup.sh`,
  `boot-check.sh`, `check-tls.sh`, `reset-coder.sh`, `reset-passwords.sh`,
  `update.sh`), `tests/` (6 umgestellt, `t-b2-003` neu geschrieben,
  `t-b2-008` gestrichen), `README.md`, `OPERATIONS.md`, `SECURITY.md`,
  `RESTORE.md`, `TROUBLESHOOTING.md`, `CHANGELOG.md`.
- **Teststand (tatsächlich ausgeführt, 2026-10-01):** alle 11 Dateien in
  `tests/` grün (328 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh
  scripts/*.sh` und `shellcheck -S warning` ohne Befund.
- **Offene Punkte:** gebündelt in README „Offene Punkte – wer macht was";
  neu und vor Produktivbetrieb zu entscheiden: Unterrichtsdaten
  (Workspace-Homes) als akzeptierter Verlust oder eigene Volume-Sicherung.

---

## 2026-10-01 – Owner-E-Mail für den Erstlauf festgelegt

- **Festgesetzt (Betreiber):** die E-Mail des Owner-Kontos für den
  ersten Lauf am Schulserver ist `maximilian.hertenstein@ghse.de`.
  OPERATIONS §11 Schritt 4 verwendet sie im Beispiel
  (Benutzername `maximilian`, Full Name abgeleitet; **Passwort bleibt
  Platzhalter** und gehört nicht ins Repo – beim Lauf als `…_PASSWORD`
  hinter `sudo env` setzen, niemals vorher speichern oder committen).
- **Geänderte Dateien:** `OPERATIONS.md`, `CHANGELOG.md`.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** unverändert, gebündelt in README „Offene Punkte –
  wer macht was".

---

## 2026-10-01 – Doku-Regel in AGENTS.md

- **Regel festgehalten (Betreiber, 2026-10-01):** alles Wichtige gehört
  in die Dokumentation, nicht nur in den Chat – und die Doku bleibt
  dabei fokussiert und gut lesbar. Nachtrag in AGENTS.md „Documentation":
  Operator-/Betriebswissen an seine Einzelquelle (offene Punkte: README
  „Offene Punkte – wer macht was"; Verfahren: OPERATIONS/RESTORE;
  Entscheidungen: SECURITY); Chroniken, Chat-Transkripte und
  Session-Exporte bleiben draußen.
- **Geänderte Dateien:** `AGENTS.md`, `CHANGELOG.md`.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** unverändert, gebündelt in README „Offene Punkte –
  wer macht was".

---

## 2026-10-01 – Dokumentations-Konsistenzdurchgang und Bündelung der offenen Punkte

- **Anlass:** Betreiber-Frage, ob alles, was er zu tun hat, auch in den
  Dokumenten steht (Chat-Verlauf ist weg, Doku nicht).
- **Neu in README:** Abschnitt „Offene Punkte – wer macht was" direkt
  hinter der Statustabelle – acht Zeilen mit Verantwortlichkeiten
  (Betreiber, Netzwerkadmin, Domainverwalter, „wartet auf …") und
  Verweisen: Pre-Flow/Erstlauf, IServ-Portkonflikt, DNS-Anfrage,
  03:00-Fenster im Wartungsplan, Template-Schritt 4, DNS-01-Klärung,
  Produktionsfreigabe, offene Verifikationen. Vorher war das über
  README/OPERATIONS/SECURITY/CHANGELOG verstreut.
- **Veraltete Teststände korrigiert:** README Dateitabelle 10 → 12
  Testskripte; README-Testabsatz und OPERATIONS §10 von „10/10, 311 PASS,
  SC2034-Befund, Caddy-Test übersprungen" auf 2026-10-01 / 12 Dateien /
  346 PASS / ohne Befund / ohne SKIP; Prüfstand-Kopfzeile auf 2026-10-01.
- **Aufräumen:** `session-ses_f0f3.md` (5618-zeiliger Chat-Export dieser
  Sitzung) war in `2dd2b4d` mit `git add -A` versehentlich gelandet –
  entfernt und `session-*.md` in `.gitignore` aufgenommen; der Inhalt
  bleibt in der Historie, falls er noch gebraucht wird.
- **Geänderte Dateien:** `README.md`, `OPERATIONS.md`, `.gitignore`,
  `CHANGELOG.md`; entfernt: `session-ses_f0f3.md`.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** identisch mit der neuen README-Tabelle – nix davon
  ist hier ohne Betreiber/Netzwerkadmin/VM/DNS erledigbar.

---

## 2026-10-01 – Monitoring abgenommen

- **Anlass:** D-Monitoring (2026-09-30) sagte „Grafana reicht, kein
  zusätzlicher Kanal" – belegt, dass die Kette überhaupt läuft, war bisher
  nicht gemacht.
- **Ergebnis am Test-Host:** Prometheus `/-/ready` 200; **alle sechs
  Alarmregeln geladen** (`BackupStale`, `CoderTargetDown`,
  `RootPartitionFillingUp`, `TlsCheckStale`, `TlsIssuanceBudgetHigh`,
  `TlsLogTruncated`); Targets `coder` und `node` auf `up`; node-exporter
  textfile-Collector liefert die fünf `coder_*`-Metriken (Backup-Laufzeit,
  TLS-Check-Laufzeit, Ausstellungen der letzten 7 Tage, Truncated-Flag,
  Logfenster); Grafana `api/health` 200 auf 127.0.0.1:3001.
- **Doku:** README-Statustabelle, neue Zeile „Monitoring".
- **Geänderte Dateien:** `README.md`, `CHANGELOG.md`.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** unverändert (VM-Boot-RTO, `/healthz` + DNS, volle
  Platte, 03:00-Fire, Inbetriebnahme/IServ, DNS-01-Aufschub).

---

## 2026-10-01 – Passwortrotation live, Reboot-Fenster konfiguriert, Doku synchron

- **`reset-passwords.sh` live auf dem Test-Host:** RC 0, Rotation von
  `POSTGRES_PASSWORD` und `GRAFANA_ADMIN_PASSWORD` nachweisbar (Werte
  nirgends ausgegeben, Vergleich per Hash), `.env` bleibt Modus 600 mit
  drei Keys (`DOCKER_GID` + beide Passwörter), Coder-Container sofort neu
  erstellt (API grün), danach der dokumentierte C2-Schritt
  `docker compose up -d`, damit auch Postgres und Grafana das neue Env
  übernehmen: postgres healthy, Stack komplett grün. Wartungspfad damit
  in der Praxis bestätigt.
- **Reboot-Fenster konfiguriert geprüft (Matrix-Punkt 5 Rest):**
  `/etc/apt/apt.conf.d/52-coder-reboot` vorhanden mit
  `Automatic-Reboot "true"` und `Automatic-Reboot-Time "03:00"` samt
  Kommentar zu D-Reboot-Fenster/B-011. Der tatsächliche Fire um 03:00 ist
  weiter nicht beobachtet (braucht eine Nacht am Zielrechner).
- **Doku synchronisiert:** README-Statustabelle auf 2026-10-01
  angehoben, Zeilen „Lokale Tests", „Vollständiger Setup-Lauf" (neuester
  Lauf = Pfad-A-Aufbau 2026-10-01), „Restore-Test" (Pfad A komplett)
  und Matrix-Zeile 5 (Reboot-Fenster konfiguriert) aktualisiert; kein
  „nicht geprobt"-Rest mehr im Bestand außer den ehrlich offenen
  Punkten (VM-Boot-RTO, `/healthz` mit echtem DNS, volle Platte).
- **Geänderte Dateien:** `README.md`, `CHANGELOG.md`.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** RTO inkl. VM-Boot (frische VM), `/healthz` + Wildcard
  (DNS auf den Server), volle Platte (Rettungskonsole), 03:00-Fire
  beobachten, Inbetriebnahme-Termin (IServ/Netzwerkadmin), DNS-01-Aufschub.

---

## 2026-10-01 – Pre-Flight-Checkliste für den Schulserver

- **Anlass:** der Betreiber will `setup-coder.sh` bald am echten
  Schulserver laufen lassen; bisher gab es keine Sammlung dessen, was das
  Skript selbst **nicht** vorflightet.
- **Neu in OPERATIONS.md §11:** „Pre-Flight vor dem ersten Lauf"
  (Betreiber-Checkliste vor Schritt 1): Webserver-Konflikt mit IServ/
  nginx/Apache auf 80/443 samt Entscheidungshilfe (Port-Übergabe vs.
  anderer Ort, Verweis Netzwerkadmin-Zeile 4), `sshd` muss Port 22 sein
  (sonst bricht das Skript vor der Firewall-Änderung ab – eigene Regel),
  Internetabbindung Docker Hub + ghcr.io, Ressourcen, DNS/Weiterleitung
  (läuft auch ohne, aber ohne Zertifikat), `CODER_FIRST_USER_*` nur per
  `sudo env`, danach Zweiter-Lauf/Checks/Cron/Backup.
- **Bewusst nicht aufgenommen:** nicht belegte Richtwerte für RAM/Platte
  (keine Zahl im Repo, keine erfunden) und jede Annahme darüber, wo IServ
  tatsächlich läuft – das bleibt Punkt 1 der Klärung.
- **Geänderte Dateien:** `OPERATIONS.md`, `CHANGELOG.md`.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** unverändert (RTO inkl. VM-Boot, `/healthz` + DNS,
  volle Platte, Inbetriebnahme-Termin/IServ, DNS-01-Aufschub).

---

## 2026-10-01 – Pfad A komplett, Wartungspfade live geprüft

- **Pfad A (Restore-Runbook) am Test-Host vollständig gespielt**, nicht nur
  der Import: Alt-Verzeichnis beiseite (mit `.env` + 14 Dumps),
  DB-/Grafana-/Prometheus-Volumes gelöscht, Caddy-Zertifikate behalten →
  `setup-coder.sh` frisch (RC 0 in 58 s, übernimmt die bereitgelegte
  `.env`, meldet „Noch kein Nutzerkonto") → `coder` stoppen,
  `dropdb`/`createdb`, Import per `zcat | psql -v ON_ERROR_STOP=1`
  (**RC 0, 2,3 s**) → Stack hoch. Ergebnis: Datenprobe **1**,
  **119/944**, `owner` + `prebuilds` wieder da, `SELECT 1` und API grün.
  Zeitspanne „Volumen weg → alles verifiziert": **1 min 50 s** (ohne
  VM-Boot). Nicht erfüllbar hier: `/healthz`-TLS-Smoke (000, Domain zeigt
  auf fremde IP) – grün wird dieser Punkt erst am Zielserver.
  Alt-Verzeichnis nach Prüfung entfernt (Dumps doppelt vorhanden).
- **`update.sh` live:** RC 1 wie designt – Backup und Stack-Update liefen,
  das Update-Gate blieb **ausschließlich** am TLS-Smoke rot (dieser
  externe DNS-Blocker), sonst grün. Verhalten also korrekt: Gate rot statt
  stummem Erfolg.
- **`check-tls.sh` live:** RC 0, schreibt `coder_tls.prom`
  (4 Ausstellungen, Logfenster 0 Std. wegen frischer Container – Zähler
  ehrlich als Untergrenze markiert).
- **fail2ban ohne eigenen Angriffstest belegt:** das Jail hatte bereits
  312 Ban-Einträge (2 IPs aktiv gesperrt), und nach dem Reboot um 19:07
  kamen „Restore Ban"-Meldungen – Bannen überleben den Neustart damit in
  der Praxis.
- **Doku:** RESTORE.md (dritter Beleg-Absatz, RTO-Tabelle mit drei Zeilen
  statt „offen", offene Reste klar benannt), README Prüfstand-Zeile 4.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** RTO inkl. VM-Boot (braucht frische VM),
  `/healthz`-Grün und Wildcard-DNS (braucht DNS auf den Server),
  volle Platte (braucht Rettungskonsole), Inbetriebnahme-Termin
  (Netzwerkadmin-Zeilen 1–4, IServ unklar), DNS-01-Aufschub;
  Vor-Flug-Checkliste für den Schulserver als Nächstes.

---

## 2026-09-30 – Matrix-Punkt 7 vollständig, Template-Test abgegeben

- **Punkt 7 Rest (fremde Workspace-Container):** bewusst fremden Container
  (`alpine`, nicht im Compose-Projekt) gestartet, dann
  `printf 'RESET\n' | reset-coder.sh --force`: die Inventar-Vorabmeldung
  hat ihn korrekt als `fremd: fremd-inventartest` ausgewiesen (Pfad B-020),
  die Löschung traf ihn nicht, DB-/Grafana-/Prometheus-Volumes weg.
  Danach `setup-coder.sh` mit `CODER_FIRST_USER_*` neu aufgebaut: RC 0,
  `[OK] Erstkonto (Owner) angelegt: owner`, 6 Container healthy, 18.6,
  fremden Container anschließend entfernt. **Punkt 7 damit erledigt.**
- **Punkt 3 Rest (volle Platte) bleibt offen, absichtlich:** ein
  Vollausfall lässt sich auf dem Test-Host nur gefahrlos testen, wenn eine
  Rettungskonsole bereitsteht (sonst riskiert man einen wedge-Host ohne
  Zugang). Ein „fast volles“ Laufwerk schiebt den winzigen Dump trotzdem
  durch und wäre kein Test.
- **Template-Abnahme Schritt 4 abgegeben:** der Betreiber testet die
  Templates im separaten Repo `coder_templates`; der Anlauf hier endete
  am fehlenden `code-server-settings.json` im Push (Datei liegt im Quell-
  Ordner, der Test-Container-Kopie fehlte sie) und wird bewusst nicht
  fortgesetzt.
- **Nicht-interaktiver Zugang für künftige Testläufe dokumentiert:**
  Passwort per `docker exec coder coder reset-password <user>` (Pipe
  erlaubt), Session-Token über `POST /api/v2/users/login` (HTTP 201,
  JSON `session_token`), Token nur im Container verwandt. Dabei ist
  einmal ein Test-Token in die Konsole gelangt (Analysefehler); er ist
  wertlos, weil das Passwort danach und beim Neuaufbau erneut rotiert
  wurde – Passwort und Token stehen nicht im Repository.
- **Geänderte Dateien:** `README.md` (Prüfstand-Zeilen 3 und 7).
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/`
  grün (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte (unverändert):** Punkt 4 (volle VM-RTO, Pfad A/B –
  braucht eine frische VM), Punkt 9 Rest (Wildcard-DNS/Workspace-Subdomain,
  braucht DNS auf den Server), Punkt 3 Rest (volle Platte, braucht
  Rettungskonsole), Inbetriebnahme-Termin (Netzwerkadmin-Zeilen 1–4,
  IServ unklar), DNS-01-Aufschub. Schritt 4 der Template-Abnahme liegt
  beim Betreiber (anderes Repo).

---

## 2026-09-30 – Testmatrix am Test-Host abgearbeitet (Punkte 2, 3, 5, 6, 7, 11)

Test-Host `2.29.11.30` gilt laut Betreiber ausdrücklich als reines
Wegwerf-Gerät – die Läufe hier sind deshalb ohne weitere Rückfrage
durchgeführt worden.

- **Punkt 2 (Re-Run/Idempotenz):** `setup-coder.sh` aus dem aktuellen
  Repo-Stand (per `git archive` übertragen) erneut ausgeführt – RC 0 in
  48 s. Mein manueller Compose-Patch vom Migrationsschritt wurde als
  **Drift erkannt und deterministisch regeneriert** (WARN, wie
  vorgesehen), Stack nicht neu erstellt, Container liefen weiter.
- **Punkt 6 (ufw/fail2ban):** nach dem Re-Run unverändert genau eine
  `22/tcp LIMIT`-Regel (v4 + v6), keine zweite Weltregel daneben;
  `fail2ban` aktiv.
- **Punkt 3 (Backup):** Cron-Läufe um 01:00 nachweisbar
  (`coder_2026-09-29_010001.sql.gz`, `coder_2026-09-30_010001.sql.gz`,
  `gzip -t` grün), 14 Dumps in der Rotation, `/etc/logrotate.d/coder-backup`
  aktiv. Volle Platte nicht geprobt.
- **Punkt 5 (Reboot + Boot-Gate):** Reboot 19:07, SSH nach ~35 s wieder
  da, alle 6 Container + Postgres healthy nach 51 s, Coder-API grün,
  DB 18.6 mit unveränderten Daten. Die `/healthz`-Zeile des Boot-Gates
  bleibt auf dem Test-Host rot, weil die Domain auf eine fremde IP zeigt
  (kein Zertifikat) – externer Blocker, kein Gate-Defekt; 03:00-Fenster
  nicht beobachtet.
- **Punkt 7 (Reset):** `printf 'RESET\n' | reset-coder.sh --force` –
  Backup lief zuerst, dann Löschung von DB-/Grafana-/Prometheus-Volumes
  und `.env`; Caddy-Zertifikate und alle 14 Dumps blieben erhalten
  (wie dokumentiert). Inventar-Vorabmeldung lief, es gab keine fremden
  Container (Pfad „fremder Workspace-Container" damit weiter ungeprüft).
- **Punkt 11 (Erstanlage):** danach Neuaufbau mit
  `CODER_FIRST_USER_*` (Passwort nur im Host-Schatten erzeugt, nie
  geloggt) – RC 0, `[OK] Erstkonto (Owner) angelegt: owner`. Zweiter
  Lauf mit denselben Variablen bei existierendem Konto: RC 0 ohne
  Abbruch (Block läuft korrekt nur bei `HUMAN_USERS=0`).
- **Neuer Zustand Test-Host:** frische DB (118 Tabellen, ohne
  `restore_probe`-Sonde – vor dem nächsten Probe-Backup Sonde setzen),
  `owner` + `prebuilds` als Nutzer, `.env` neu generiert, 18.6 healthy.
- **Doku:** README, neuer Abschnitt „Prüfstand der Liste" mit Status je
  Matrix-Punkt; Status-Tabelle: PostgreSQL-Punkt auf erledigt.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/`
  grün (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** Matrix-Punkt 4 (volle VM-RTO, Pfad A/B),
  Punkt 9 Rest (Wildcard-DNS/Workspace-Subdomain, braucht DNS auf den
  Server), Punkt 3 Rest (volle Platte), Punkt 7 Rest (fremde
  Workspace-Container), Schritt 4 der Template-Abnahme,
  Inbetriebnahme-Termin (Netzwerkadmin-Zeilen 1–4, IServ unklar).

---

## 2026-09-30 – Beobachtung: ein Testlauf mit 1 FAIL, nicht reproduzierbar

- Im Commit-Lauf zu `cfed8ca` meldete die Sammelschleife einmal **345 PASS,
  1 FAIL**; der Name des fehlgeschlagenen Tests wurde damals nicht mitgeloggt
  (mein Fehler). Danach **7 volle Läufe** nacheinander: jeweils 346 PASS,
  0 FAIL, auch Einzellauf aller 12 Dateien ohne FAIL.
- Verdacht: Flake über den gebundenen Loopback-Port in `t-090` (der Lauf
  hing zuvor schon einmal an fremden Listern). Kein belegter Defekt.
- Konsequenz: Fail-Namen künftig immer mitschreiben, bei FAIL nicht
  committen.

---

## 2026-09-30 – Major-Migration 15 → 18 auf dem Test-Host (Praxisbeleg)

- **Freigabe des Betreibers** für die Migration samt Löschen des alten
  Volumes; Test-Host gilt ausdrücklich als reines Testgerät, das irgendwann
  abgeschaltet wird (Betreiber-Aussage am 2026-09-30) – künftig keine
  Rückfragen mehr für Reboot/Reset/Re-Run dort.
- **Sicherungen vor dem Eingriff:** Sonde `RTO-PROBE-2026-09-30` gesetzt,
  `backup.sh` → `coder_2026-09-30_182342.sql.gz` (`gzip -t` grün), plus
  `postgres_volume_pg15_2026-09-30.tar.gz` (12 MB, komplettes altes Volume).
  Altes Volume danach gelöscht (freigegeben), Daten existieren weiter in
  Dump + tar-Archiv.
- **Befund beim Hochfahren mit18:** das 18er-Image lehnt das alte Mount
  `/var/lib/postgresql/data` absichtlich ab (Layout-Wechsel zu
  `/var/lib/postgresql/<major>/`, docker-library/postgres #1259) und
  crashloopt – **ein Major-Wechsel ist nie nur ein Tag**. Repo-Fix:
  `setup-coder.sh` mountet `postgres_data` künftig unter
  `/var/lib/postgresql`, Fehlerhinweis auf `pg_hba.conf` zeigt
  `/var/lib/postgresql/18/…`; OPERATIONS §8 nennt die Pflicht, Compose und
  Image zusammenzuändern.
- **Ergebnis:** `postgres:18-alpine` = **18.6**, healthy. Alter Dump
  eingespielt nach RESTORE.md-Pfad A: `dropdb`/`createdb`, dann
  `zcat | psql -v ON_ERROR_STOP=1` → **Import exit 0 in 2,3 s**. Datenprobe:
  Sonde **1/1**, **131/131** Tabellen, **937/937** Zeilen (exakt der
  Vorzustand 15.19), `ANALYZE` vor der Zeilenzahl. Stack komplett wieder
  hoch (6 Container, postgres healthy), Coder-API liefert `v2.36.6`, 1 User
  wieder da. Die vier `InmemoryListener is already closed`-Meldungen sind
  Shutdown-Rauschen des Stopp/Starts, kein DB-Fehler.
- **Geänderte Dateien:** `setup-coder.sh` (Mount + Hinweis), `OPERATIONS.md`
  (§8 Layout-Warnung), `RESTORE.md` (zweiter Praxisbeleg).
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** Rest der Testmatrix (Setup-Re-Run auf dem Host,
  Reboot-Fenster, externe Ports-Prüfung steht als erledigt in der History),
  Schritt 4 der Template-Abnahme, Restore-Pfad A/B auf frischer VM,
  Inbetriebnahme-Termin, PostgreSQL-Punkt damit erledigt.

---

## 2026-09-30 – PostgreSQL 15 → 18 im Setup

- **Frage des Betreibers „warum nicht eine aktuellere Version?"** – Antwort:
  15 war die Baseline des Original-Setups, der Major-Wechsel als eigener
  Punkt bis zum Supportende (11/2027) vertagt. Da noch keine
  Produktionsdaten im Volume liegen, ist der Wechsel jetzt am billigsten.
- **Geprüft:** `postgres:18-alpine` existiert und zeigt aktuell auf **18.6**
  (`18.5` existiert nicht mehr, `18.6-alpine` schon – Major-Tag `18-alpine`
  holt künftige 18.x-Patches automatisch, gleiche Politik wie vorher bei 15).
  Coder-Anforderung laut offizieller Doku: PostgreSQL **13 oder höher** – 18
  ist damit gedeckt (Quelle: coder.com/docs, „version 13 or higher").
- **Geändert (Commit davor):** `setup-coder.sh` (Image-Zeile
  `postgres:18-alpine`, drei Kommentarstellen), README (Bildtabelle,
  Update-Absatz, Versions-Absatz), OPERATIONS (§8 Bullets, neue
  Major-Wechsel-Regel: nie reiner `pull`, sondern Dump/Restore im
  Wartungsfenster), SECURITY (§7 Zeile und §9 Zeile 13). RESTORE.md folgt
  mit dem Migrationstest auf dem Test-Host.
- **Altes Verhalten:** `postgres:15-alpine` als beweglicher Major-Tag.
- **Neues Verhalten:** `postgres:18-alpine`, sonst nichts – Port, Netz,
  Backup und Restore-Verfahren bleiben unverändert.
- **Mögliche Regressionen:** unbekanntes Major-Verhalten von Postgres 18
  unter Coder; Rollback-Variante: altes (behaltenes) Volume plus vorherigen
  Image-Tag, da kein Auto-Prune.
- **Geänderte Dateien:** `setup-coder.sh`, `README.md`, `OPERATIONS.md`,
  `SECURITY.md`.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh ssh-harden.sh` und
  `shellcheck -S warning setup-coder.sh ssh-harden.sh` ohne Befund.
- **Offene Punkte:** Migration des Test-Host-Volumes von 15 auf 18 (Dump/
  Restore, altes Volume als Rollback behalten) und Wiederholung der
  Restore-Probe mit dem 18er-Bild – danach RESTORE.md aktualisieren; dann
  Schritt 4 der Template-Abnahme, Restore-Pfad A/B, Testmatrix,
  Inbetriebnahme-Termin.

---

## 2026-09-30 – Korrektur: KAS-Zugang gehört zum Domainverwalter

- **Korrektur zum Eintrag „DNS-01 recherchiert und aufgeschoben" von heute:**
  die KAS-Zugangsdaten von All-Inkl kann und soll der Betreiber **nicht**
  besorgen – er hat keinen DNS-Zugang und kann sich nur an den
  Netzwerkadmin wenden. Zugangsdaten und eine Umstellung auf DNS-01 sind
  Aufgabe des Domainverwalters und nur dann nötig, wenn 80/443 dauerhaft
  nicht 1:1 weitergeleitet werden können.
- **Was der Betreiber vom Netzwerkadmin anfordert (und nichts weiter):**
  OPERATIONS.md §11, Zeilen 1–4 – A-Record, Wildcard, 80/443-Weiterleitung
  und im Proxy-Fall ACME-Durchreichung/TLS-Passthrough. Zeile 6 (KAS/DNS-01)
  ist dessen eigene Aufgabe, falls Zeile 3 nicht geht.
- **Doku:** OPERATIONS.md (§11 Zeile 6 in der Netzwerkadmin-Tabelle,
  DNS-01-Absatz mit Zuständigkeit statt „siehe unten"), SECURITY.md (§3
  Zuständigkeit, §9 Voraussetzung der D-TLS-Zeile), README.md
  (Zielbetrieb-Absatz: kein DNS-Zugang beim Betreiber).
- **Geänderte Dateien:** `OPERATIONS.md`, `SECURITY.md`, `README.md`.
- **Teststand (tatsächlich ausgeführt):** nach den Änderungen alle 12
  Dateien in `tests/` grün (346 PASS, 0 FAIL); `bash -n setup-coder.sh
  ssh-harden.sh` und `shellcheck -S warning setup-coder.sh ssh-harden.sh`
  ohne Befund.
- **Offene Punkte:** unverändert – IServ-/Hosting-Klärung und
  Netzwerkadmin-Zeilen 1–4, Schritt 4 der Template-Abnahme, Restore auf
  frischer VM, Testmatrix, PostgreSQL-15-Migration.

---

## 2026-09-30 – DNS-01 recherchiert und aufgeschoben (Zone/IServ unklar)

- **Recherche (Quellen: `github.com/caddy-dns/all-inkl`, `pypi.org/project/kasserver`):**
  Zone `ghse-unterricht.de` liegt bei All-Inkl; deren DNS-Verwaltung läuft
  über die KAS-API (Benutzername/Passwort, kein granularer Token). Für
  Caddy existiert das Modul `caddy-dns/all-inkl` (`dns.providers.allinkl`)
  mit `kas_username`/`kas_password` – aber jung (Repository seit 11/2025,
  9 Sterne, 14 Commits) und **nicht** im Standard-Image `caddy:2.10`:
  nötig wäre ein eigener xcaddy-Build plus Zugangsdaten in einer `600`-Datei
  auf dem Server, nie im Repository.
- **Entscheidung (Fortsetzung D-TLS): Umstellung auf DNS-01 aufgeschoben.**
  Grund: laut Betreiber läuft der Schulserver künftig mit **IServ** auf dem
  zentralen Netzwerkserver und es ist weder geklärt, ob die Zone bei
  All-Inkl bleibt, noch wer DNS, Wildcard und 80/443 künftig übernimmt.
  Aufwand jetzt wäre möglicherweise weggeworfen. On-Demand-`ask` und die
  Budget-Beobachtung (`check-tls.sh`, `TlsIssuanceBudgetHigh`,
  `TlsLogTruncated`) bleiben unverändert in Betrieb.
- **Festgehalten:** DNS-01 löst nur die ACME-Frage; der Nutzerverkehr
  braucht weiterhin 80/443 bis zum Server. Auch ein DNS-01-Zertifikat
  nützt nichts, wenn die Weiterleitung fehlt.
- **Was später von dir gebraucht wird:** KAS-Zugangsdaten von All-Inkl
  (als `600`-Datei auf dem Server ablegen, nicht hierhereinsenden) und ein
  OK fürs Wartungsfenster; dann bild-, Caddyfile- und Test-Runde zuerst auf
  dem Test-Host (der wäre mit DNS-01 sogar von seinem 80/443-Problem der
  externen nginx befreit).
- **Doku:** SECURITY.md (§3 Recherche-/Aufschub-Absatz, §8 Zeile 3, §9
  Intro/D-TLS-Zeile/Fußnote), README.md (Zielbetrieb-Absatz mit IServ,
  Entscheidungs-Zeile), OPERATIONS.md (§11 DNS-01-Absatz aktualisiert,
  neue Vorab-Klär-Notiz über der Netzwerkadmin-Tabelle).
- **Geänderte Dateien:** `SECURITY.md`, `README.md`, `OPERATIONS.md`.
- **Teststand (tatsächlich ausgeführt):** nach den Änderungen alle 12
  Dateien in `tests/` grün (346 PASS, 0 FAIL); `bash -n setup-coder.sh
  ssh-harden.sh` und `shellcheck -S warning setup-coder.sh ssh-harden.sh`
  ohne Befund.
- **Offene Punkte:** Klärung Zone/Hosting/IServ (Betreiber +
  Netzwerkadmin), danach DNS-01-Umstellung; Schritt 4 der Template-Abnahme,
  volles Restore-Prozedere auf frischer VM (RTO), Testmatrix,
  Inbetriebnahme-Termin (DNS/80-443), PostgreSQL-15-Migration vor 11/2027.

---

## 2026-09-30 – D-Monitoring und B5 entschieden, T-063 vom Betreiber bestätigt

- **D-Monitoring entschieden:** kein Benachrichtigungskanal – Grafana und
  Prometheus bleiben die Anlaufstelle, das Risiko (Ausfälle sieht nur, wer
  hinsieht) wird getragen. Alertmanager/Contact Point werden nicht
  gebaut, erst auf neuen Wunsch. Umsetzung nur in der Doku, keine
  Konfigurationsänderung.
- **B5 entschieden:** Client-IPs bleiben **nicht** im Audit – die
  Empfehlung vom 2026-09-29 („so lassen") ist übernommen; die
  technische Fall-Option (`CODER_PROXY_TRUSTED_ORIGINS` nur auf eine feste
  Caddy-IP) bleibt in SECURITY §8 als Weg für den Fall vermerkt, dass es
  doch gebraucht wird.
- **Template-Abnahme, Schritt 2:** der Betreiber hat den
  Workspace-Selbsttest am 2026-09-30 als gelaufen bestätigt („läuft").
  Eingetragen als Aussage des Betreibers, **nicht** von mir reproduziert;
  Schritt 4 (Spielraum der Limits im laufenden Workspace) ist weiter nicht
  separat protokolliert und bleibt als Lücke markiert.
- **Damit offen von den D-Entscheidungen nur noch:** der DNS-01-Teil von
  D-TLS (braucht Zonen-Zugang; Antwort darauf steht aus).
- **Doku:** SECURITY.md (§5 Monitoring-Absatz, §6 Inventar-/T-063-Stand,
  §8 Zeilen 9, 10 und 11, §9 Intro, D-Monitoring-Zeile, Fußnote),
  README.md (Entscheidungs-Zeile), templates/allowlist.md (Status,
  Prüfstext, sechs Abnahmen-Zeilen).
- **Geänderte Dateien:** `SECURITY.md`, `README.md`, `templates/allowlist.md`.
- **Teststand (tatsächlich ausgeführt):** nach den Änderungen alle 12
  Dateien in `tests/` grün (346 PASS, 0 FAIL); `bash -n setup-coder.sh
  ssh-harden.sh` und `shellcheck -S warning setup-coder.sh ssh-harden.sh`
  ohne Befund.
- **Offene Punkte:** DNS-01/Zonen-Zugang (D-TLS-Teil), Schritt 4 der
  Template-Abnahme, volles Restore-Prozedere auf frischer VM (RTO),
  Testmatrix, Inbetriebnahme (DNS + 80/443-Weiterleitung, Termin unbekannt),
  PostgreSQL-15-Migration vor 11/2027.

---

## 2026-09-30 – D-SSH entschieden (Passwort bleibt) und Template-Erstinventar

Aktualisiert zwei Zeilen der Liste „Offene Punkte" weiter oben
(SSH-Härtung, Template-Erstinventar) und die Entscheidungs-Spalte.

- **D-SSH entschieden:** Passwort-Login ist der Dauerzustand und bleibt
  Standard; `ssh-harden.sh` ist ausdrücklich **nicht** Standard und wird
  nur auf gesonderten Wunsch ausgeführt. Restrisiko (Raten im Schulnetz)
  wird getragen, abgefedert durch ufw `limit 22/tcp`, fail2ban und die
  Netzbegrenzung. Umgesetzt als reine Dokuänderung – weder `sshd` noch
  `ssh-harden.sh` noch die Firewall wurden angefasst.
- **Template-Erstinventar (Schritt 1) durchgeführt:** Quelle ist das
  separate Repository
  `/home/max/Dokumente/referendariat/SJ2022_2023/informatik/coder_templates`
  (Stand `7bd2b92`), sechs Templates (`cpp`, `html-css`, `java`,
  `java-intellij`, `python`, `sql`; `server/` leer). Grep gegen die
  Verbotsliste der Allowlist (docker.sock, `privileged`, `pid/host`,
  `network_mode host`, `ipc/host`, `--gpus`, `cap_add`/`SYS_ADMIN`,
  Host-Mounts, `postgres`-Netz) über **alle** Dateien ohne Treffer;
  CPU-/Memory-Limits in allen sechs `main.tf` gesetzt. Ergebniszeilen
  stehen jetzt in der Abnahmen-Tabelle von
  [templates/allowlist.md](templates/allowlist.md), inklusive Vermerk zum
  container-lokalen sudoers-Eintrag in `sql`.
- **Was dabei geprüft wurde (tatsächlich ausgeführt, im Template-Repo):**
  `terraform fmt -check -recursive` (rc 0), `terraform validate` je
  Template (6× OK), `shellcheck -S warning` über alle Skripte (sauber).
  Das Template-Repo wurde **nicht** verändert (Baum sauber).
- **Weiter offen bei den Templates:** Schritt 2 (Workspace-Selbsttest
  T-063) und die fachliche Freigabe. Der Test-Host `2.29.11.30` hat 0
  Templates in der Coder-DB und keine `coder`-CLI; ein Selbsttest braucht
  also erst ein Veröffentlichen der Templates plus Zugang
  (`test-workspaces.sh` im Template-Repo).
- **Doku:** SECURITY.md (§1 Passwort-Dauerzustand und Härtungsoption,
  §6 Inventarstand, §8 Zeilen 2 und 10, §9 Intro/D-SSH-Zeile/Fußnote),
  README.md (Status-Zeile SSH, Entscheidungs-Zeile, Hardening-Kurzfassung,
  Testmatrix-Punkte 8 und 10), OPERATIONS.md (§11 Punkt 6),
  TROUBLESHOOTING.md (G2 dauerhaft erwartbar, kein Handlungsbedarf),
  templates/allowlist.md (Stand, Status, Abnahmen-Tabelle mit sechs Zeilen).
- **Geänderte Dateien:** `SECURITY.md`, `README.md`, `OPERATIONS.md`,
  `TROUBLESHOOTING.md`, `templates/allowlist.md`.
- **Teststand (tatsächlich ausgeführt):** nach den Änderungen alle 12
  Dateien in `tests/` grün (346 PASS, 0 FAIL); `bash -n setup-coder.sh
  ssh-harden.sh` und `shellcheck -S warning setup-coder.sh ssh-harden.sh`
  ohne Befund.
- **Offene Punkte:** D-Monitoring (Kanal fehlt), DNS-01/Zonen-Zugang
  (D-TLS-Teil), T-063 + fachliche Template-Freigabe, volles
  Restore-Prozedere auf frischer VM (RTO), Testmatrix.

---

## 2026-09-30 – Offene Punkte, aktualisierte Liste

Ersetzt die Liste „Offene Punkte (Stand 2026-09-29)" weiter unten; die
ältere bleibt aus Append-only-Grund stehen.

| Punkt | Status 2026-09-30 |
|---|---|
| TLS/ACME auf dem Test-Host | **weiterhin blockiert extern**: `healthz` meldet in beiden Läufen am 2026-09-30 weiterhin 000; Weiterleitung 80/443 liegt beim Netzwerkadmin |
| C2 Log-Limit wirksam | erledigt 2026-09-29 (unverändert) |
| B2-005 (TLS-Zählung blind gegenüber Log-Rotation) | erledigt 2026-09-30, Commit `ccc6181` |
| Restore-Probe + RTO-Zahl | **teilweise** erledigt 2026-09-30, Commit `35d3a57`: Dump-Import in isolierten Probencontainer grün (Datenprobe 1, 3,0 s); Pfad A/B auf frischer VM mit Stack-Start und volle RTO bleiben offen |
| Offsite-Backup | entschieden 2026-09-30: kein zweiter Standort, Risiko akzeptiert – bleibt bewusst nicht eingerichtet |
| SSH-Härtung (`ssh-harden.sh`) | offen: braucht gesetzten und aus zweitem Fenster getesteten Key plus Zweit-Zugang; bis dahin Minimalvariante (ufw `limit` + fail2ban) |
| Template-Erstinventar + Workspace-Selbsttest (T-063) | offen; Befund 2026-09-30: der Test-Host hat **0 Templates** in der DB, das echte Inventar liegt auf dem Zielserver |
| VM-/Integrationstests der Testmatrix | nicht ausgeführt |
| Entscheidungen D-* | vier entschieden (D-Socket, D-Firewall, D-Reboot-Fenster, D-Offsite), D-TLS teilentschieden, offen: D-SSH und D-Monitoring |

---

## 2026-09-30 – Vier D-Entscheidungen getroffen, eine teilentschieden

- **Vom Betreiber entschieden:** D-Reboot-Fenster (Reboot 03:00 bleibt,
  Unterrichtsbeginn 07:45), D-Socket (keine zweite VM, also Status quo +
  Template-Allowlist als Dauerregel), D-Firewall (kein `DOCKER-USER`,
  127.0.0.1-Bindung bleibt der Schutz), D-Offsite (kein zweiter Standort,
  Verlustrisiko bewusst akzeptiert, Daten nicht extrem kritisch).
  D-TLS ist **teilentschieden**: Beobachtung über `TlsLogTruncated` ist
  übernommen, DNS-01/Zonen-Zugang bleibt offen.
- **Offen bleiben:** D-SSH (braucht getesteten Key- und Zweit-Zugang),
  D-Monitoring (braucht SMTP- oder Webhook-Zugang) – bewusst nicht
  umgesetzt, dafür fehlt der Zugang.
- **Umsetzung:** reine Dokumentation. Konfiguration bleibt unangetastet
  (Reboot steht schon auf 03:00, kein `DOCKER-USER` eingebaut, kein
  Alertmanager ergänzt, `ssh-harden.sh` weiter nicht aufgerufen).
- **Doku:** SECURITY.md (Titel, §3 D-TLS-Formulierungen, §4 D-Firewall,
  §5 Reboot-Fenster, §6 D-Socket, §7 D-Offsite, §8 Status-Spalte der
  Zeilen 1/3/5/8, §9 mit neuer Spalte „Status 2026-09-30" und neuem Intro;
  Empfehlungen der entschiedenen Zeilen auf den Entscheidungsstand
  umgeschrieben), README.md (Status-Zeile auf 2026-09-30, Quellstand-,
  Test- und Setup-Lauf-Zeile auf den tatsächlichen Stand, Offsite-Zeile,
  Entscheidungs-Zeile).
- **Geänderte Dateien:** `SECURITY.md`, `README.md`.
- **Teststand (tatsächlich ausgeführt):** nach den Änderungen alle 12
  Dateien in `tests/` grün (346 PASS, 0 FAIL); `bash -n setup-coder.sh`
  und `shellcheck -S warning setup-coder.sh` ohne Befund. Kein Test hängt
  an den geänderten Formulierungen (vorab geprüft).
- **Offene Punkte:** D-SSH, D-Monitoring, DNS-01/Zonen-Zugang (D-TLS-Teil),
  volles Restore-Prozedere auf frischer VM (RTO), Template-Erstinventar +
  T-063, Testmatrix, SSH-Härtung nach getestetem Key-Zugang.

---

## 2026-09-30 – Entscheidungsliste für die sieben D-Entscheidungen

- **Warum:** D-TLS, D-Socket, D-SSH, D-Firewall, D-Reboot-Fenster,
  D-Monitoring und D-Offsite waren an sieben Stellen verstreut als
  „offene Entscheidung" vermerkt, aber nirgends gebündelt – der Betreiber
  konnte sie nicht in einem Rutsch entscheiden.
- **Neu:** SECURITY.md Abschnitt 9 „Offene Entscheidungen" mit Tabelle
  (ID, Entscheidung, Optionen, Empfehlung, Voraussetzung) für alle sieben;
  Eigentümer (Betreiber, OPERATIONS.md §11) und fehlende Fristen sind
  einmalig über der Tabelle benannt, statt sie siebenmal zu wiederholen.
  Empfehlungen sind als Empfehlung markiert, nichts davon ist entschieden.
  Fußnote nennt die zwei ähnlichen offenen Punkte ohne D-Kürzel (B5, B4b)
  und trennt sie von den reinen Schritten (T-063, Restore-Pfad A/B,
  Testmatrix).
- **Doku:** README.md Status-Zeile „Offene Befunde" heißt jetzt „Offene
  Entscheidungen" und verweist auf SECURITY.md §9 (die früher genannten
  Punkte B5 und PostgreSQL-15 bleiben genannt).
- **Geänderte Dateien:** `SECURITY.md`, `README.md`.
- **Teststand (tatsächlich ausgeführt):** nach der Änderung alle 12 Dateien
  in `tests/` grün (346 PASS, 0 FAIL); `bash -n setup-coder.sh` und
  `shellcheck -S warning setup-coder.sh` ohne Befund.
- **Offene Punkte:** die sieben Entscheidungen selbst (jetzt entscheidungs-
  bereit), volles Restore-Prozedere auf frischer VM (RTO),
  Template-Erstinventar, Testmatrix, Offsite-Backup, SSH-Härtung nach
  getestetem Key-Zugang.

---

## 2026-09-30 – Testhost-Lauf: neuer TLS-Fenstercheck live verifiziert

- **Durchgeführt:** zweiter Lauf von `setup-coder.sh` auf `2.29.11.30`
  (Skript per `scp` nach `/tmp`, Aufruf als root, im Anschluss `/tmp`
  aufgeräumt) – nach `ccc6181` (B2-005) und `35d3a57` (Restore-Probe).
- **Ergebnis:** Exit 0, 0 `[FEHLER]`, 4 verschiedene `[WARNUNG]` (dieselben
  vier wie zuvor: SSH-Passwort-Login, `RESTORE.md`/`ssh-harden.sh` fehlen
  neben dem Skript in `/tmp`, healthz ohne HTTP 200). Firewall unverändert,
  Regel weiter `22/tcp LIMIT`, Wartungs-Lock nach dem Lauf sofort frei.
- **Neuer Check bestätigt:** `coder-alerts.yml` enthält 6 Regeln und
  Prometheus lädt alle 6 (API-Abfrage: u. a. `TlsLogTruncated`); die
  Metrikdatei führt `coder_tls_log_window_seconds 0` und
  `coder_tls_log_truncated 0`, die Ausgabezeile nennt das Fenster
  (`Logfenster: 0 Std.`) und meldet korrekt nur einen `HINWEIS` (frischer
  Caddy-Container aus diesem Lauf), keine Fehlwarnung über Rotation.
  Gleichzeitig sieht man die Untergrenze live: `coder_tls_issuances_7d 11`
  bei 0 Std. Fenster.
- **Geänderte Dateien:** keine (nur Dokumentation dieses Laufs).
- **Teststand (tatsächlich ausgeführt):** vor dem Lauf alle 12 Dateien in
  `tests/` grün (346 PASS, 0 FAIL); nach dem Lauf keine Dateien geändert.
- **Offene Punkte:** volles Restore-Prozedere auf frischer VM (RTO),
  D-TLS, Template-Erstinventar, Testmatrix, übrige D-Entscheidungen,
  Offsite-Backup, SSH-Härtung nach getestetem Key-Zugang.

---

## 2026-09-30 – Restore-Probe: Dump-Import in isoliertem Probencontainer

(Die zugehörigen Dokuänderungen liegen im Commit `35d3a57`; dieser Eintrag
kommt als eigener Commit nach.)

- **Durchgeführt** auf dem Test-Host `2.29.11.30` (kein Eingriff in den
  laufenden Stack): Restore-Sonde `RTO-PROBE-2026-09-30` gemäß RESTORE.md
  gesetzt, `backup.sh` angestoßen, neuer Dump (`coder_2026-09-30_104829`,
  74 KB) per `gzip -t` verifiziert und auf Vorhandensein der Sonde
  geprüft; danach `zcat | psql -v ON_ERROR_STOP=1` in einen eigenen
  `postgres:15-alpine`-Probencontainer (Bildversion wie der Stack,
  kein veröffentlichten Port).
- **Ergebnis:** Import exit 0 in 3,0 s; Datenprobe = 1; 119 von 119
  Tabellen vorhanden; Summe aller Zeilenzahlen über alle 119 Tabellen
  Quelle 937 = Ziel 937; keine Fehler im Importlog. Probencontainer
  inklusive anonymem Volume entfernt, Volume-Anzahl vor/nach unverändert
  (7), kein Restcontainer.
- **Zwei Anläufe, beide protokolliert:** der erste scheiterte mit
  `relation … does not exist` bzw. `database system is shutting down`,
  weil `pg_isready` auch schon während des Temp-Servers der Initialisierung
  antwortet – erst wiederholtes `SELECT 1` mit den echten Zugangsdaten
  gilt als bereit. Diese Lektion steht jetzt in RESTORE.md, sonst wäre
  der nächste Probenlauf gleich wieder rot gewesen. Der zweite Anlauf
  (stabiles Bereit-Signal) war der grüne.
- **Was weiterhin offen bleibt:** Pfad A/B auf einer frischen VM mit
  Stack-Start, `/healthz` und Dashboard-Login – und damit die volle RTO;
  gemessen ist nur der Importteil (3,0 s bei 3 Min. Dump-Alter).
- **Doku:** RESTORE.md (Statuskopf, Protokolltabelle mit erster Zeile,
  Durchführungsnotiz mit der `pg_isready`-Fallen), README.md (Zeile
  Restore-Test), SECURITY.md (Grenzen-Tabelle Zeile 6).
- **Geänderte Dateien:** `RESTORE.md`, `README.md`, `SECURITY.md`
  (Commit `35d3a57`).
- **Teststand (tatsächlich ausgeführt):** vor und nach den Dokuänderungen
  alle 12 Dateien in `tests/` grün (346 PASS, 0 FAIL); `bash -n
  setup-coder.sh` und `shellcheck -S warning setup-coder.sh` ohne Befund.
- **Offene Punkte:** volles Restore-Prozedere auf frischer VM (RTO),
  D-TLS, Template-Erstinventar, Testmatrix, übrige D-Entscheidungen,
  Offsite-Backup, SSH-Härtung nach getestetem Key-Zugang.

---

## 2026-09-30 – B2-005: Logfenster messbar machen (Zählung als Untergrenze)

- **Befund:** Offener Punkt aus der Kritikliste: `check-tls.sh` zählt
  `obtaining certificate` in `docker logs --since 168h`, der Puffer ist
  aber 10 MB × 3 pro Container – bei hohem Volumen ist Älteres rotiert und
  weg. SECURITY.md hielt das als „nicht behoben" fest und die Grenzen-Tabelle
  als „Meldung fehlt weiterhin": im Ernstfall (Budget-DoS erzeugt Traffic
  und Ausstellungen gleichzeitig) meldete das Instrument Entwarnung, ohne
  dass der Verlust sichtbar war.
- **Änderung:** `check-tls.sh` bestimmt die vorhandene Loghistorie aus der
  ältesten zeitgestempelten Zeile, deckelt sie auf 604800 s (7 Tage) und
  unterscheidet zwei Fälle: frischer Container (Fenster kürzer als 7 Tage,
  weil der Container jung ist) = `HINWEIS`, und Container älter als 7 Tage
  bei kürzerem Fenster = `WARNUNG … die Zahl ist eine Untergrenze` plus
  syslog-Eintrag mit `trunc=1`. Beides landet als Metrik in
  `coder_tls.prom`: `coder_tls_log_window_seconds` (Fenster) und
  `coder_tls_log_truncated` (0/1); die Ausgabezeile nennt das Fenster in
  Stunden. Neue Prometheus-Regel `TlsLogTruncated`
  (`coder_tls_log_truncated == 1`, `for: 30m`) – Regeln damit 5 → 6.
  Die Zählung selbst bleibt bewusst eine Untergrenze: ein Zählwerk unabhängig
  von der Logaufbewahrung (Delta-Stand oder eigenes Caddy-Log-Volume) ist
  weiterhin die offene Entscheidung D-TLS.
- **Doku:** SECURITY.md (Grenzen-Absatz der Erkennung, Grenzen-Tabelle
  Zeile 4, Alerting-Absatz, Zeile 9 der Zusammenfassung), OPERATIONS.md
  (Dateitabelle, Metrik-Abfragen, Regelzahl), README.md (Bind-Mounts),
  TROUBLESHOOTING.md (B3-Diagnose um die Fenster-Abfrage).
- **Geänderte Dateien:** `setup-coder.sh`, `SECURITY.md`, `OPERATIONS.md`,
  `README.md`, `TROUBLESHOOTING.md`, neu `tests/t-b2-005-tls-window.sh`.
- **Teststand (tatsächlich ausgeführt):** alle 12 Dateien in `tests/` grün
  (346 PASS, 0 FAIL); `bash -n setup-coder.sh` und
  `shellcheck -S warning setup-coder.sh` ohne Befund. Der neue Test
  extrahiert das Produktions-Skript, ersetzt Pfad und PATH für /tmp, arbeitet
  mit Fake-`docker`/`logger` und prüft drei Szenarien (Puffer voll →
  Fenster 604800 und keine Meldung; Rotation bei 30 Tage altem Container →
  `trunc=1`, WARNUNG, syslog `trunc=1`; frischer Container → nur HINWEIS)
  plus die Metrikwerte und die Alert-Definition. Zusätzlich: die erzeugte
  Regel-Datei per `promtool check rules` geprüft – SUCCESS, 6 rules, mit
  dem Produktionspin `prom/prometheus:v3.14.0` (und v3.5.0).
- **Offene Punkte:** D-TLS (Zählwerk unabhängig von der Logaufbewahrung),
  Restore-Probe, Template-Erstinventar, Testmatrix, übrige D-Entscheidungen.

---

## 2026-09-30 – Testhost-Lauf unter Root-Guard und ohne sudo-Präfixe

- **Durchgeführt:** `setup-coder.sh` per `scp` nach `/tmp` auf dem Testhost
  `2.29.11.30`; zuerst der Guard-Test als `nobody`, danach der volle Lauf
  als root; `ufw status numbered` vor dem Lauf und danach verglichen.
- **Guard ohne root:** Exit 1, Meldung „dieses Setup muss als root laufen –
  Aufruf: sudo ./setup-coder.sh" plus `sudo env`-Hinweis, kein Schritt
  1 erreicht.
- **Lauf als root:** Exit 0, alle 10 Schritte, 0 `[FEHLER]`, 8
  `[WARNUNG]`-Zeilen = 4 verschiedene (SSH-Passwort-Login, `RESTORE.md`
  fehlt neben dem Skript, `ssh-harden.sh` fehlt daneben, healthz ohne
  HTTP 200) – dieselben vier wie in der früheren Runde; die Zusammenfassung
  in Schritt 10 zeigt jeden Eintrag ein zweites Mal. Firewall unverändert:
  `diff` vor/nach byte-identisch, Regel weiter `22/tcp LIMIT IN Anywhere`.
  Wartungs-Lock danach sofort frei (`flock -n`), `.maintenance.lock`
  600 root:root, `.env` 600, `docker-compose.yml` 644 root:root, Testlauf
  des Backups erfolgreich (Datei angelegt).
- **Geänderte Dateien:** keine (nur Dokumentation dieses Laufs).
- **Teststand (tatsächlich ausgeführt):** vor dem Lauf alle 11 Dateien in
  `tests/` grün (318 PASS, 0 FAIL); nach dem Lauf wurden keine Dateien
  mehr geändert.
- **Offene Punkte:** Lauf gegen den Produktionsserver (bewusst nicht
  durchgeführt).

---

## 2026-09-30 – Root-Lauf, Teil 2: sudo-Präfixe aus dem Setup-Code entfernt

- **Befund:** Nach dem Root-Guard (Teil 1) lief das Setup als root und
  lieferte dennoch jeder Aktion ein `sudo` voran – 160 ausführbare Zeilen
  plus die beiden `sudo tee`-Aufrufe vor ihren Heredocs. Neben dem
  Rauschen war das auch sachlich falsch: `sudo` brauchte das Skript nur,
  weil es als Nicht-root lief.
- **Änderung:** alle ausführbaren `sudo`-Präfixe entfernt, inklusive der
  Sonderfälle `sudo -n rm` (jetzt `rm -f`) und `sudo env A=B …`
  (jetzt `env A=B …`). Bewusst **nicht** entfernt: `sudo` in
  kommentierenden Meldungen, die dem Betreiber sagen, was er in seiner
  Shell auszuführen hat (`Prüfen mit: sudo ufw status …`, `Aufruf: sudo
  /opt/coder/reset-passwords.sh` …), `sudo` in Kommentaren und in den
  erzeugten Wartungsskripten. Drei Kommentare, die das alte Verhalten
  begründeten, sind auf den neuen Stand gebracht: der `env`-Kommentar bei
  `apt_install`, der P-010-Kommentar zur `install -m 600`-Sicherung und
  die sudo-Konvention im erzeugten `update.sh`.
- **Tests angepasst:** die String-Anker in `t-b2-004` (Gate, Check-Start,
  drei Delete-Zeilen, tee-Zählung), `t-b2-007` (mv/mktemp-Helfer, die
  Verbotene-jail.local-Zeile), `t-b2-008` (`ss -tlnp`/`-ulnp`) und
  `t-root-guard` (Guard-Reihenfolge) zeigen jetzt auf den Code ohne
  `sudo`; die Test-`sudo`-Shims bleiben als Netz drin, `t-b2-009` ist
  unberührt (prüft RESTORE.md, das `sudo` nach wie vor enthält).
- **Geänderte Dateien:** `setup-coder.sh`, `tests/t-b2-004-ufw-ssh-rules.sh`,
  `tests/t-b2-007-drift-hash.sh`, `tests/t-b2-008-port-preflight.sh`,
  `tests/t-root-guard.sh`.
- **Teststand (tatsächlich ausgeführt):** alle 11 Dateien in `tests/` grün
  (318 PASS, 0 FAIL); `bash -n setup-coder.sh` und
  `shellcheck -S warning setup-coder.sh` ohne Befund. Nicht geprüft:
  der Lauf als root auf dem Testhost (offener Punkt).
- **Offene Punkte:** Testhost-Lauf als root unter Teil 1+2.

---

## 2026-09-30 – Root-Lauf, Teil 1: Root-Guard und Lock am Deskriptor

- **Befund:** Das Setup ließ sich ohne root starten und fiel erst mitten
  im Lauf auf (Lock, Rechte unter /opt/coder). Das Setup nahm den
  Wartungs-Lock über einen eigenen `sudo flock`-Wächterprozess
  (coproc) und las die Freigabe per Pipe; die Wartungsskripte sperren
  dieselbe Datei aber selbst über ihren eigenen Deskriptor. Außerdem
  setzte `sudo -v` eine Passworteingabe voraus, die ein reiner root-Lauf
  nicht kennt.
- **Änderung:** Root-Guard als allererste Anweisung nach `set -euo
  pipefail`: ohne root Exit 1 mit dem Aufruf `sudo ./setup-coder.sh` und
  dem Hinweis, dass Umgebungsvariablen hinter das sudo gehören
  (`sudo env DOMAIN_CODER=… ./setup-coder.sh`) – danach bricht ab, was
  das Setup ohne root nicht erledigen kann. Der coproc-Wächter ist
  ersetzt: `exec 8>>/opt/coder/.maintenance.lock` + `flock -w 300 8` in
  diesem Prozess, Exit 75 bei Zeitüberschreitung; `CODER_MAINTENANCE_LOCK_HELD=1`
  und `trap setup_cleanup EXIT` bleiben. `sudo -v` entfernt. Header-Kommentar,
  README.md (Aufruf, Voraussetzungen, Beispiele) und OPERATIONS.md
  (Abschnitt 3, Übergabe an den Auftraggeber) auf `sudo ./setup-coder.sh`
  und `sudo env …` umgestellt.
- **Geänderte Dateien:** `setup-coder.sh`, `README.md`, `OPERATIONS.md`,
  neu `tests/t-root-guard.sh`.
- **Teststand (tatsächlich ausgeführt):** alle 11 Dateien in `tests/` grün
  (318 PASS, 0 FAIL), der neue Test prüft die Zeilenreihenfolge
  (Guard vor der ersten Systemänderung), den Wegfall des coproc-Wächters
  und den echten Abbruch ohne root vor Schritt 1; `bash -n
  setup-coder.sh` und `shellcheck -S warning setup-coder.sh` ohne Befund.
- **Offene Punkte:** sudo-Präfixe aus dem Code streichen (Teil 2),
  Testhost-Lauf als root.

---

## 2026-09-30 – Ticket-Kürzel aus den Laufzeitmeldungen entfernt

- **Befund:** 27 Meldungen des Setups trugen interne Kürzel
  (`(B6)`, `(A1)`, `(B-007)`, `(B2-004 Pfad C, kein Abbruch)`,
  `HINWEIS (B2):` …). Für Leser ohne Ticket-Zugang ist das Rauschen, die
  Aussage steht hinter dem Kürzel ohnehin.
- **Änderung:** Kürzel aus allen `warn`/`ok`/`fail`/`echo`/`printf`-Meldungen
  entfernt; wo eine Klammer die Begründung trug, blieb der Klartext
  (`(neu würfeln würde die Datenbank-Anmeldung zerstören)`). Ein reiner
  Historien-Kommentar (doppelter Container-Check vor der trap-Zeile)
  gestrichen. Kürzel in Kommentaren, die ein Verhalten begründen, bleiben
  bewusst; Überschriften in TROUBLESHOOTING.md bleiben.
- **Geänderte Dateien:** `setup-coder.sh`.
- **Teststand (tatsächlich ausgeführt):** alle 10 Dateien in `tests/` grün
  (306 PASS, 0 FAIL); `bash -n setup-coder.sh` und
  `shellcheck -S warning setup-coder.sh` ohne Befund. Kein Test hing an den
  Meldungstexten, keine Doc-Stelle zitiert sie.
- **Offene Punkte:** Root-Lauf.

---

## 2026-09-30 – Testhost-Lauf unter den neuen ufw-Regeln

- **Durchgeführt:** zweimal `bash setup-coder.sh` auf dem Testhost
  `2.29.11.30` (Re-Run, Skript per `scp` nach `/tmp`), `ufw status numbered`
  vor dem ersten und nach dem zweiten Lauf protokolliert und verglichen.
- **Ergebnis:** beide Läufe Exit 0, 0 `[FEHLER]`, 4 unterschiedliche
  `[WARNUNG]` (Healthz-Hintergrundpfad, fehlende `RESTORE.md`/
  `ssh-harden.sh` neben dem Skript in `/tmp`, SSH-Passwort-Login) – keine
  ufw-Warnung. Firewall unverändert: `diff` vor/nach byte-identisch, Regel 1
  weiter `22/tcp LIMIT IN Anywhere`, also tatsächlich kein Delete und kein
  `limit 22/tcp`-Neuaufruf (No-Op-Zweig). Abschlusscheck: „SSH ist offen,
  aber per ufw rate-limitiert (22/tcp LIMIT)".
- **Nicht geprüft:** Pfad B (quellbeschränkte SSH-Regel) nur gegen Fakes im
  Test (`t-b2-004-ufw-ssh-rules.sh`), nicht live – eine Umgewandlung der
  Firewall-Regel auf dem Testhost würde den SSH-Zugang riskieren.
- **Geänderte Dateien:** keine (nur Dokumentation dieses Laufs).
- **Teststand (tatsächlich ausgeführt):** alle 10 Dateien in `tests/` grün
  (306 PASS, 0 FAIL) vor dem Lauf; `bash -n` und `shellcheck -S warning`
  ohne Befund.
- **Offene Punkte:** Ticket-Kürzel, Root-Lauf.

---

## 2026-09-30 – ufw-Runde: kein Löschen von SSH-Bestandsregeln, Bypass entfällt

- **Befund:** Der B2-004-Block löschte beim Re-Run drei SSH-Regeln
  (`allow OpenSSH`, `allow 22/tcp`, `allow from 10.16.0.0/12 …`) und setzte
  sie danach neu – mit Bypass-Variable, Before-/After-Log und
  Restore-Verifikation. Ein Abbruch zwischen Löschen und Wiederherstellen
  ließ SSH ohne Regel bzw. ohne Beschränkung zurück; die Schulnetz-Regel
  war zudem als hart kodiertes Löschziel im Skript. Eine vorgefundene
  Quellbeschränkung brach den Lauf zusätzlich komplett ab, obwohl sie nicht
  angefasst werden muss.
- **Änderung:** Das Setup löscht keine SSH-Regel, die es nicht selbst
  angelegt hat. Pfad B (Quellbeschränkung bei aktiver UFW): Warnung, keine
  Änderung, kein Abbruch, keine weltweite `limit 22/tcp`-Regel daneben;
  steht schon eine weltweite 22-Regel neben der Beschränkung, wird auch das
  nur gemeldet. Einzige Bestandsänderung: Umwandlung einer weltweiten
  `allow`- in eine `limit`-Regel (Debian-Default `ufw allow OpenSSH`), mit
  erneutem `ufw status` und hartem `[FEHLER]`, wenn eine weltweite
  `ALLOW`-Zeile stehen bleibt. Fehlt jede 22-Regel, wird
  `ufw limit 22/tcp` gesetzt; eine vorhandene `limit`-Regel ist No-Op.
  Entfernt: `CODER_ALLOW_SSH_DOWNGRADE`, Quellenextraktion/Restore,
  Before-/After-Protokolle (`/var/log/coder-ssh-downgrade-*`), die
  delete-Zeilen außerhalb der Umwandlung. Unverändert: sshd-Port-Preflight,
  Status- und `show added`-Preflight (fail-closed), Pfad C (inaktiv ohne
  gespeicherte Quellregel = Warnung, mit gespeichertem Bestand = Abbruch),
  pfadabhängiger Abschlusscheck (jetzt gegen `UFW_RESTRICTED`).
- **Geänderte Dateien:** `setup-coder.sh`,
  `tests/t-b2-004-ufw-downgrade.sh` → `tests/t-b2-004-ufw-ssh-rules.sh`,
  `OPERATIONS.md`, `README.md`, `SECURITY.md`, `TROUBLESHOOTING.md`.
- **Teststand (tatsächlich ausgeführt):** alle 10 Dateien in `tests/` grün
  (306 PASS, 0 FAIL); `bash -n setup-coder.sh` und
  `shellcheck -S warning setup-coder.sh` ohne Befund. Ein Lauf gegen den
  Testhost wurde in dieser Runde nicht ausgeführt.
- **Offene Punkte:** Sanierungslauf auf dem Testhost (unter den neuen Regeln
  für 22-Regeln ein No-op), Ticket-Kürzel, Root-Lauf.

---

## 2026-09-30 – Testsuite wieder vollständig grün (t-071b, t-b2-004)

- **Befund:** Beide Tests fielen bereits bei `c66eb30` durch, ohne dass der
  Produktionscode defekt war – die Prüfungen selbst waren veraltet.
  `t-b2-004` hatte als Startanker `UFW_OUT="$(sudo ufw status numbered` und
  traf damit den neu davorstehenden SSH-Port-Preflight statt des Gate-Blocks;
  dadurch wurde ein 4-Zeilen-Fragment extrahiert, das mit `exit 1` endete und
  19 Folgefehler produzierte. Zusätzlich erwartete der Test beim fehlenden
  `ufw`-Befehl einen Weiterlauf mit Warnung, während das Setup bewusst
  abbricht (`ufw-Status nicht lesbar – Abbruch vor jeder Regel-/Policy-
  Änderung`), und suchte zwei alte grep-Formeln des A1-Abschlusschecks, die
  inzwischen in einer Variablen und einem `grep -Eq` zusammengefasst sind.
  `t-071b` suchte die alte `printf | grep`-Formel des Headerchecks, nicht die
  aktuelle here-string-Form.
- **Änderung:** Anker auf den kompletten Gate-Bereich umgestellt
  (Start `if ! UFW_OUT=…`, Ende `# B-007: explizite Default-Policy`) mit
  Eindeutigkeits-Prüfung beider Anker, Erwartungen an die bewusste
  fail-closed-Verhaltensweise und an die aktuellen A1-Stellen sowie
  Angleichen des Header-Guards an die here-string-Form.
- **Geänderte Dateien:** `tests/t-b2-004-ufw-downgrade.sh`,
  `tests/t-071b-headercheck.sh`.
- **Teststand (tatsächlich ausgeführt):** alle 10 Dateien in `tests/` grün
  (zuvor 8 grün / 2 rot); `bash -n setup-coder.sh` und
  `shellcheck -S warning setup-coder.sh` ohne Befund. Der Produktionscode
  wurde in dieser Runde nicht angefasst.
- **Offene Punkte:** ufw-Umbau, Root-Lauf, Ticket-Kürzel.

---

## 2026-09-30 – Fünf Fehler aus der Kritikliste: Mount-Inode, TLS-Metrik, pipefail, Grafana-Passwort, GID-Quote

- **Mounts (Fehler 1):** Die Compose-Datei band `Caddyfile`,
  `prometheus.yml` und `rules/` als **Einzeldateien** ein. Ein Datei-Mount
  hält den Inode fest, `write_managed` ersetzt die Datei aber per Temp-Datei
  und `mv` – der laufende Container hätte bis zum nächsten Recreate die alte
  Fassung gesehen, während Hash-Vergleich und Preflight-Validierung die neue
  bestätigt hätten. Jetzt gebunden: `./caddy:/etc/caddy:ro` und
  `./prometheus:/etc/prometheus:ro` (Regeln darunter, eigener Mount entfällt).
  Pfade entsprechend angepasst in `CADDY_BEFORE`/`CADDY_AFTER`, der
  Prometheus-Hash-Signatur, den drei Preflight-Prüfungen. Die Alt-Dateien
  `/opt/coder/Caddyfile`, `/opt/coder/prometheus.yml` und
  `/opt/coder/rules/coder-alerts.yml` werden nach dem Neuschreiben nur
  entfernt, wenn sie inhaltsgleich sind; eine abweichende Datei bleibt liegen
  und wird als Warnung gemeldet.
- **TLS-Metrik (Fehler 2):** `check-tls.sh` lief bislang nur wöchentlich
  (Mo 06:30), die Metrik `coder_tls_check_last_success_timestamp_seconds`
  existierte bis dahin nicht und die Regel `TlsCheckStale` meldete
  `absent()` als veraltetes Ergebnis. Das Setup führt den Check jetzt einmal
  direkt nach der Installation aus und meldet einen Fehlschlag als Warnung.
- **pipefail (Fehler 3):** `getent group docker | cut …` brach unter
  `set -o pipefail` ohne jede Meldung ab, ebenso `docker compose config` in
  der von `reset-coder.sh` erzeugten Reparaturanleitung (dort war `stderr`
  zusätzlich auf `/dev/null` geleitet). Beide Stellen laufen weiter
  (`|| true`), eine fehlende Docker-Gruppe bricht jetzt mit Klartext ab.
- **Grafana-Passwort (Fehler 4):** `reset-passwords.sh` übergab das neue
  Passwort als **Argument** an `grafana cli` (sichtbar in `ps aux`), obwohl
  der Kommentar STDIN behauptete. Jetzt `--password-from-stdin` (im
  laufenden Image `grafana/grafana:12.4.5` vorhanden, per
  `grafana cli --help` geprüft).
- **Sonniges (Fehler 5):** GID-Wert in `grep -q` quotiert (sonst würde
  `998` gegen `["998"]` fälschlich treffen), ungenutzte Schleifenvariable,
  tote Variable `WRITE_MANAGED_CHANGED` und die konkurrierenden
  Umleitungen beim Lock-Release (`SC2261`) entfernt.
- **Preflight-Bug (beim Testlauf gefunden):** `docker run caddy:2.10 validate …`
  scheiterte mit `exec: "validate": executable file not found in $PATH`,
  weil das Image **keinen** ENTRYPOINT hat (nur
  `CMD ["caddy","run",…]`) und `validate` damit als Binary ausgeführt wurde.
  Die Erstlauf-Validierung hatte noch nie gelaufen (der Eintrag vom
  2026-09-29 nennt diese Prüfungen ausdrücklich als nicht ausgeführt).
  Jetzt `--entrypoint caddy`, passend zu `--entrypoint /bin/promtool` bei den
  beiden Prometheus-Zeilen.
- **Geänderte Dateien:** `setup-coder.sh`,
  `tests/t-b1-on-demand-ask.sh` (Pfad des Caddyfile-Heredocs),
  `tests/t-b2-003-hex-migration.sh` (einer statt zwei unquotierter Heredocs,
  Grafana-Statement-Extraktion), `tests/t-b2-007-drift-hash.sh`
  (Pfadliste), `README.md`, `OPERATIONS.md`, `TROUBLESHOOTING.md`.
- **Teststand (tatsächlich ausgeführt):** `bash -n setup-coder.sh` ohne
  Befund; `shellcheck -S warning setup-coder.sh` grün (bei `c66eb30` noch
  rc=1 mit vier Befunden); Suite `tests/*.sh`: 8 von 10 Dateien grün,
  `t-071b-headercheck.sh` (1 FAIL) und `t-b2-004-ufw-downgrade.sh`
  (19 FAIL) rot – beide bereits vor der Änderung bei `c66eb30` rot
  (veraltete statische Guards, nicht Gegenstand dieser Runde); die erzeugte
  Compose-YAML geht durch `docker compose config`. Inode-Nachweis auf dem
  Testhost `2.29.11.30`: nach `mv` zeigt der Datei-Mount im laufenden
  Container weiter `ALT`, der Verzeichnis-Mount `NEU`; beide Probe-Container
  wurden wieder entfernt.
- **Testlauf Testhost `2.29.11.30` (zwei Läufe):** der erste endete im
  Preflight (Befund oben), der zweite komplett ohne `[FEHLER]`. Nachweis vor
  Ort: Mounts `…/caddy -> /etc/caddy` und `…/prometheus -> /etc/prometheus`
  (Verzeichnisse, `ro`), `Valid configuration` im Preflight, alle fünf
  Alarmregeln in Prometheus geladen, `coder_tls.prom` enthält jetzt beide
  Metriken inklusive `coder_tls_check_last_success_timestamp_seconds`, und
  `[OK] TLS-Check einmalig ausgeführt`. Die beiden Alt-Dateien wichen inhaltlich
  ab (alter `ask`-Block bzw. fehlende `TlsCheckStale`-Regel – reine
  Skript-Evolution, kein Hand-Edit), wurden nach Diff und Referenzprüfung
  gelöscht; danach ist kein Alt-Pfad mehr irgendwo referenziert.
- **Nicht ausgeführt:** kein Test des ufw-Downgrade-Pfads, kein Root-Lauf,
  kein Lauf auf der Schul-Produktionsmaschine.
- **Offene Punkte:** ufw-Block (Regel-Erhalt, `limit` als Ausnahme),
  Root-Lauf (Root-Guard, Wartungs-Lock, sudo-Präfixe) und die
  Ticket-Kürzel-Runde sind bewusst noch offen; Passwort-Login-Warnungen
  bleiben unverändert.

---

## 2026-09-29 – Prüfung der Setup-Fundliste A1–A13, B1–B10 und C1–C5

- **Umsetzung:** gemeinsamer Setup-Wartungs-Lock mit sauberer Freigabe,
  atomarer Helper für generierte Dateien, Installations- und wirksame
  Konfigurationsprüfungen, `bash -n` für generierte Skripte, Erstlauf-
  Validierung von Caddy/Prometheus/Regeln, sichere Passwortrotation ohne
  Lesen des alten Postgres-Passworts und ohne automatische Secret-Ausgabe.
  Außerdem node-exporter-Mount-Propagation, Versionsvergleich ohne `v`,
  zutreffende `.env`-Restore-Meldungen und korrigierte Betriebsdoku zu
  Workspace-Prüfung und Logrotation.
- **Zurückgestellt:** kein Alarmempfänger oder Offsite-Ziel ohne abgestimmte
  Betriebsparameter; keine Proxy-Header-Freigabe ohne geprüfte Proxy-Kette;
  keine Root-Reexec- oder `.env`-Refactor-Runde; Container-, Port- und
  Log-Limit-Prüfungen bleiben wegen ihrer unterschiedlichen Sicherheits- und
  Laufzeitwirkung bestehen. Die ACME-Kontaktadresse wurde mangels bestätigter
  Funktionsadresse nicht ersetzt. Einzelbewertungen stehen in
  [ai-review/REVIEW-2026-09-29-SETUP-PUNKTE.md](ai-review/REVIEW-2026-09-29-SETUP-PUNKTE.md).
- **SSH/Firewall:** Passwort-Login und UFW-Regelverhalten wurden nicht
  umgestellt. Die Schulnetz-Beschränkung bleibt eine externe Netzvorgabe; das
  Setup behauptet nicht, sie selbst durchzusetzen.
- **Prüfstand:** keine Tests und keine Serverbefehle ausgeführt. Insbesondere
  wurden die neu eingebauten Caddy-/Prometheus-Preflights und der Grafana-CLI-
  Passwortwechsel nicht zur Laufzeit ausgeführt.

---

## 2026-09-29 – Debian-Zielplattform vorab prüfen

- **Befund:** Das Skript verwendete `VERSION_CODENAME` für die Docker-APT-
  Quelle, ohne das Betriebssystem zu prüfen. Ein Lauf auf einer anderen
  Distribution konnte deshalb mit einer unpassenden Quelle fortfahren.
- **Änderung:** `setup-coder.sh` bricht jetzt vor Serveränderungen ab, wenn
  `/etc/os-release` nicht Debian 13 (`ID=debian`, `VERSION_CODENAME=trixie`)
  ausweist. README nennt dieselbe Voraussetzung und Prüfung.
- **SSH/Firewall:** unverändert.
- **Prüfstand:** Tests nicht ausgeführt. Definierte Fälle: Debian 13 „trixie“
  passiert den Guard; Ubuntu und Debian 12 brechen vor Schritt 1 ab.

---

## 2026-09-29 – Wartungs-, Restore- und SSH-Helfer-Nacharbeit

- **Restore:** Pfad A stellt jetzt die originale `.env` vor dem ersten Setup-
  Lauf bereit. Damit initialisieren Postgres und Grafana von Anfang an mit
  diesen Zugangsdaten; ein nachträglicher `.env`-Tausch hätte die bereits
  initialisierten Passwörter nicht geändert. Pfad B beschreibt separat den
  Neuaufbau mit neuen Zugangsdaten.
- **Wartung:** Backup, Update, Passwortrotation und Reset teilen einen
  root-eigenen Wartungs-Lock (Modus 600). Parallele Abläufe warten bis zu
  300 Sekunden und brechen danach ohne Folgeaktion mit Exit 75 ab. Das Backup
  behält seinen zusätzlichen eigenen Lock. Ein Setup-Re-Run muss weiterhin
  separat geplant werden und darf nicht parallel dazu laufen.
- **Firewall-Preflight:** Bei inaktiver UFW prüft das Setup auch gespeicherte
  Regeln. Eine dort hinterlegte SSH-Quellbeschränkung führt zum Abbruch vor
  jeder UFW-Policy-/Regeländerung; die aktive UFW-Regelprüfung bleibt erhalten.
  Ein nicht lesbarer oder fehlender SSH-Port wird ebenfalls fail-closed
  behandelt.
- **Boot-Gate:** Kommentare und Betriebshandbuch nennen jetzt die tatsächlichen
  Wartephasen (bis zu 120 s Postgres, weitere 120 s Container, bis zu 10 min
  TLS-Smoke; knapp 14 min insgesamt).
- **Secrets-Diagnose:** Die Troubleshooting-Befehle prüfen Vorhandensein,
  Format und Zeilenstruktur der `.env`, ohne die Passwörter auszugeben.
- **SSH-Helfer:** `ssh-harden.sh` verlangt nun einen getesteten Nicht-root-
  Sudo-Login mit nicht-leerer effektiver `AuthorizedKeysFile`. Bei Fehlern
  während Validierung, Reload oder Nachprüfung wird das vorherige Drop-In
  wiederhergestellt. Der Helfer wurde nicht ausgeführt; Passwort-SSH,
  Schulnetzgrenze und Server-Firewall wurden nicht verändert.
- **Prüfstand:** Für diese Nacharbeit keine Tests ausgeführt und keine
  Serverbefehle ausgeführt. Vorgesehene Prüfungen: parallele Fake-Läufe der
  Wartungsskripte, inaktive-UFW-Fälle mit und ohne gespeicherte SSH-Quelle,
  Shell-Syntax und isolierte `sshd -t`-/Rollback-Szenarien.
  Der geänderte Restore-Pfad muss auf einer Debian-13-Test-VM mit Datenprobe
  und Grafana-Login geprobt werden.
  Der Restore-Ablauf ist weiterhin ungeprobt. Offsite-Ziel,
  Workspace-Isolation und verpflichtende Erstkonto-Absicherung bleiben wegen
  offener Betriebsentscheidungen unverändert.

---

## 2026-09-29 – Prüfung der angehängten Fundliste A1–C6

**Umfang:** Fundliste am aktuellen Arbeitsstand geprüft. Bewertung aller
Einzelpunkte und Gründe für zurückgestellte oder abgelehnte Vorschläge stehen
in [ai-review/REVIEW-2026-09-29-ANHANG.md](ai-review/REVIEW-2026-09-29-ANHANG.md).
SSH-Passwortzugang bleibt auf dem Schulserver für die erste Inbetriebnahme
bewusst aktiv; die externe Netzvorgabe beschränkt Port 22 auf das Schulnetz.

- **Code (`setup-coder.sh`):** Docker-Origin aus unattended-upgrades entfernt
  (unveränderte alte Setup-Datei wird hashgeprüft entfernt, geänderte/fremde
  Datei bleibt mit Warnung); Update-Status exakt geprüft; `cron` in Schritt 1
  installiert; fail2ban-Readiness abgewartet; Caddy-`permission http` statt
  deprecated `ask`; TLS-Smokes validieren Zertifikate; TLS-Zählerfehler und
  veraltete Messung sichtbar; Prometheus-Regeln per SIGHUP geladen; optionales
  Coder-Erstlogin räumt den temporären Token-Ordner auf; Postgres-Klartext
  wird nicht mehr ausgegeben; Backup-/Update-Zusammenfassung präzisiert.
- **Dokumentation:** README, OPERATIONS, SECURITY, TROUBLESHOOTING und
  `templates/allowlist.md` mit Update-Verhalten, SSH-Netzgrenze, fehlendem
  Alert-Empfänger/Offsite-Ziel, Limits der TLS-Zählung und node-exporter-
  Netzwerkmetriken abgeglichen. Anzahl der verwalteten Dateien von 17 auf 16
  aktualisiert.
- **Tests:** `bash -n setup-coder.sh ssh-harden.sh tests/*.sh` sauber;
  10/10 Testskripte Exit 0 mit 311 `PASS`, 0 `FAIL`. Der isolierte
  TLS-SNI-Gate-Test lief nach Sandbox-Ablehnung des Loopback-Binds mit
  Freigabe außerhalb der Sandbox und bestand. PyYAML las die fünf
  Prometheus-Regeln erfolgreich. ShellCheck meldet weiterhin einen
  vorhandenen SC2034-Befund im Retry-Schleifenzähler. Kein lokales Caddy-Image
  vorhanden, daher kein `caddy validate`/`adapt`; kein vollständiger Setup-,
  VM- oder Produktionslauf.

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
