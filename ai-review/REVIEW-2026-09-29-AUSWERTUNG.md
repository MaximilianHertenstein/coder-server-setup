# Auswertung Review-Runde 2026-09-29 (Funde A1–D2)

**Stand:** 2026-09-29, nach Phasen 1–7 (Code, Tests, Doku).
**Grundlage:** die im Review übermittelte Fundliste mit den IDs A1–A10, B1–B7,
C1–C9, D1–D2. Vereinbarung mit dem Betreiber: *alle Fixes außer D1*,
B1 = Apex-Block + lokaler Ask-Endpunkt, Betrieb = *nur Messbares im Code, Rest
Doku*.

**Unsicherheit (dokumentiert, nicht beschönigt):** Die Originalliste lag
dieser Sitzung **nicht als Datei** vor – sie stammt aus der Besprechung. Die
Zuordnung unten ist für die umgesetzten Punkte aus dem Code und seinen Tests
belegbar; für die IDs **A10, B4, B5, C5, C8** gibt es hier keine gesicherte
Originalbeschreibung. Vor einer Weitergabe dieser Datei gegen das Original-Review
abgleichen (und die Zeile dann streichen).

---

## 1. Umgesetzt

| ID | Befund (Kurzfassung) | Umsetzung | Beleg |
|---|---|---|---|
| A1 | ufw: restriktive SSH-Regel und weltweite `limit 22/tcp` wirken nebeneinander; ein Abbruch im Bypass-Lauf öffnet SSH weltweit | Reihenfolge umgekehrt: erst Wiederherstellung + Verifikation, dann Löschung der weltweiten Limit-Regel; Abschlusscheck pfadenabhängig (nur noch prüfen, wenn eine Beschränkung gesetzt ist); `10.16.0.0/12` wird nicht gelöscht, wenn genau diese Regel wiederhergestellt wird | `setup-coder.sh` (B2-004-Block), `tests/t-b2-004-ufw-downgrade.sh` (inkl. Abbruchfall „restriktiv + worldwide LIMIT") |
| A2 | `psql -U coder -d coder` lauft über den Socket und akzeptiert das falsche Passwort (misst also nichts) | `PGH` aus `hostname -i`, Schleife mit Host-Adresse, Loopback-Guard, Negative-Kontrolle per `sh -c` mit `read -rs`, danach Positivprüfung | `setup-coder.sh` (A2-Block), `tests/t-b2-003-hex-migration.sh` (setzt `PGH`) |
| A3 | Bei belegtem Lock meldete `backup.sh` Exit 0 – `update.sh`/`reset-*` behandelten „übersprungen" als Erfolg | `flock -w 300`, danach Exit 75 (`EX_TEMPFAIL`), Kommentare an den Aufrufern angeglichen | `setup-coder.sh` (`flock -w 300 9`), `tests/t-b2-003-hex-migration.sh` |
| A4 | Kommentar im `update.sh`-Heredoc nannte nicht alle fünf Versionen | Wortlaut auf alle fünf Pins korrigiert | `setup-coder.sh` (update.sh-Heredoc) |
| A5 | Falsche/niedrigere Versionen würden den Stack still zurücksetzen (Schema-Migrationen irreversibel) | `versions.env` mit den zuletzt wirksam gewesenen Versionen, harter Abbruch bei Downgrade, nur `CODER_ALLOW_DOWNGRADE=yes` erlaubt es | `setup-coder.sh` (Guard vor Schritt 1), [RESTORE.md](../RESTORE.md) |
| A6 | Kein `docker compose pull` vor `up -d` – falscher Tag brach mitten im Lauf ab | `retry3 sudo docker compose pull` vor `up -d` | `setup-coder.sh` (Schritt 3) |
| A7 | Schritt-10-TLS-Gate prüfte nur einen Weg und lief bei fehlendem DNS ins Leere | Zweiphasig: lokaler Pfad per `--resolve` (6 × 10 s, bricht bei 200/keinem DNS ab) → danach **ein** öffentlicher Versuch ohne `--resolve`; Fehlschlag dort = WARN mit Hairpin-/Portweiterleitungshinweis | `setup-coder.sh` (Schritt 10), `tests/t-090-b2-002-tls-gate.sh` |
| A9 | `ssh-harden.sh` existierte nur im Repo, nie auf dem Server | Kopie nach `/opt/coder/ssh-harden.sh` mit Mode 755 + OK/WARN | `setup-coder.sh` (neben der `RESTORE.md`-Kopie) |
| B1 | Caddyfile nutzte `ask http://example.com` (antwortet immer 200) und On-Demand auf der Apex | Eigener ask-Endpunkt `:9123` mit CEL-`matches()` gegen das Coder-Subdomänen-Muster, **nur im Container** (kein `ports:`, keine ufw-Regel); Apex ohne `on_demand`, Wildcard mit | `setup-coder.sh` (Caddyfile-Heredoc), `tests/t-b1-on-demand-ask.sh` (gerenderte Datei, Falluntersuchung, `caddy validate` + `caddy adapt`, Live-Sonde) |
| B2 | Kein erster Nutzer/Owner geprüft, „create-admin-user" als Lösung vorgeschlagen | Rein lesende Zählung menschlicher Konten in Schritt 10 + Hinweis, dass der erste Anmeldende Owner wird; **keine** erzwungene Nutzererzeugung | `setup-coder.sh` (Schritt 10, `HUMAN_USERS`) |
| B6 | Telemetrie an Coder, Inc. nicht abgeschaltet | `CODER_TELEMETRY_ENABLE=false` im Compose | `setup-coder.sh` (coder-Servicesection) |
| B7 | Eigene Jails lagen in `jail.local` und hätten Hand-Änderungen überschrieben (Lese-Reihenfolge: jail.local vor jail.d/*.local) | Drop-In `/etc/fail2ban/jail.d/10-coder-sshd.local`, hash-guardtes Entfernen der alten `jail.local`, `forget_hash()`, Neuladen nur bei tatsächlicher Änderung | `setup-coder.sh` (B7-Block), `tests/t-b2-007-drift-hash.sh` |
| C1 | Backup-Erfolg war für Prometheus unsichtbar | `backup.sh` schreibt nach jedem erfolgreichen Lauf atomar `/opt/coder/node-textfile/coder_backup.prom` (644, trotz `umask 077`), Verzeichnis wird mit 0755 angelegt; node-exporter mit textfile-collector | `setup-coder.sh` (backup.sh-Heredoc, node-exporter), `tests/t-b2-007`-/`t-090`-Läufe |
| C2 | Container-Logs ohne Limit daemon-weit unbegrenzt | `/etc/docker/daemon.json` (json-file, 10 m × 3); fremde Datei ohne die Schlüssel = Abbruch mit Merge-Anleitung, nicht Überschreiben; Neustart nur, wenn keine eigenen Container laufen | `setup-coder.sh` (Schritt 1), `tests/t-071b-headercheck.sh` |
| C3 | Grafana-Datasource manuell einzutragen, keine Alarmregeln | Provisioning-Datei für die Datasource + `rules/coder-alerts.yml` (Coder-Target down, Root-Partition <10 %, Backup >25 h); Neustart nur bei Hash-Änderung und laufendem Container | `setup-coder.sh` (Schritt 2/3, `prom_cfg_sig`, `restart_on_cfg_change`), `promtool check config` lokal grün |
| C4 | `docker compose restart caddy` bei jeder Änderung (Verbindungsabbruch, keine Vorab-Prüfung) | `caddy validate` → bei grün `caddy reload`; bei rot bewusst **kein** Fallback auf restart, Caddy behält die alte Konfiguration | `setup-coder.sh` (Schritt 3), `tests/t-b1-on-demand-ask.sh` |
| C6 | Docker-Pakete fielen aus den Sicherheitsupdates heraus (fehlender Origin) | Drop-In `/etc/apt/apt.conf.d/52-coder-docker-upgrades` mit `::` (anhängen, nicht ersetzen), Suite aus `os-release`, danach Gegenprobe per `apt-config dump` | `setup-coder.sh` (Schritt 5); Match und Append-Semantik mit unattended-upgrades **2.12 live gegengeprüft** |
| C7 | `apt-get install` konnte bei konfigurgerechtem Paket hängen | `apt_install()` mit `DEBIAN_FRONTEND=noninteractive` + `--force-confold`, fünf Aufrufstellen | `setup-coder.sh` (Hilfsfunktion) |
| C9 | `acme_ca` stand in `issuer acme { }` (dort ungültig) und wurde nicht injiziert | Globale Option `acme_ca` im Caddyfile-Globalblock aus `ACME_CA` (nur wenn gesetzt), in beide Issuer durchschlagend | `setup-coder.sh` (Caddyfile), `caddy:2.10`-Adapt nachgewiesen |
| D2 | Port-Preflight meldete die eigenen Container als fremd / falsche IP-Formate | Docker-Range-Template-Inspektion + 12-Zeilen-Normalisierung (`containerport\|hostip\|hostport`, Wildcards zu `v4*`/`v6*`) | `setup-coder.sh` (Schritt-3-Preflight), `tests/t-b2-008-port-preflight.sh` (neue Fixtures + Fälle) |
| – | Doku: veraltete Aussagen („ask antwortet immer 200", `jail.local`, `restart caddy`, Zeilenangaben, Teststände) | README, SECURITY, OPERATIONS, TROUBLESHOOTING, RESTORE angeglichen | diese Dateien, jeweils Abschnitt „Stand" |

## 2. Bewusst **nicht** umgesetzt

| ID | Was | Grund |
|---|---|---|
| A8 | Log-Rotation für `/var/log/coder-boot.log` und `/var/log/coder-tls.log` | Vereinbarung *„nur Messbares im Code, Rest Doku"*: beide Logs wachsen, das ist als Grenze in [SECURITY.md](../SECURITY.md)/[OPERATIONS.md](../OPERATIONS.md) dokumentiert (zusammen mit B2-005: die TLS-Zählung ist dadurch eine Untergrenze) |
| B3 | `PermitRootLogin no` | Würde den laufenden Root-Key-Login abschalten und den Zugang zerstören (`sshd -T` → `without-password`); **Doku-Entscheidung**, Härtung nur über `ssh-harden.sh` mit getestetem Key + Zweit-Zugang |
| D1 | Aufteilung von `setup-coder.sh` in Dateien | Würde die Test-Extraktion (Zeilenmarker) brechen; Baseline bleibt bis zu einer expliziten Freigabe |
| – | `create-admin-user` erzwingen | versionseitig fragil, bei Re-Run wirkungslos; sinnfrei, solange die DB ohnehin schon Systemkonten enthält |

## 3. Offene Entscheidungen (unverändert)

`D-TLS` (DNS-01-Wildcard ohne On-Demand, Wochenbudget), `D-SSH`
(Passwort-Login + Härtungstermin), `D-Offsite`, `D-Monitoring`
(Benachrichtigungskanal fehlt – Regeln allein klingeln nirgends),
`D-Reboot-Fenster` (03:00), `D-Firewall` (`DOCKER-USER`), `D-Socket`
(Trennung Workspace/Host), `templates/allowlist.md` (Erstinventar).

## 4. Teststand Runde 1 (tatsächlich ausgeführt, 2026-09-29; neuerer Stand in Abschnitt 6)

```
bash -n setup-coder.sh                      → 0 Befunde
shellcheck -S warning setup-coder.sh        → genau 1 Befund (SC2034, Retry-Zähler)
shellcheck -S warning tests/t-b1-*.sh       → 0 Befunde
for f in tests/*.sh; do bash "$f"; done     → 10/10 Exit 0, 314 PASS, 0 FAIL
promtool check config (prometheus.yml)      → 3 Regeln valid
caddy validate / caddy adapt (caddy:2.10)   → ask-Regel + Policies korrekt
```

**Nicht belegt (gehört in Phase 8 / Test-VM):** vollständiger Setup-Lauf auf
echtem Debian 13, Re-Run-Idempotenz, wirksames `daemon.json` nach
Docker-Neustart, `apt-config`-Gegenprobe auf dem Host, ask-Endpunkt live
(200/404), Prometheus-Regeln im laufenden Container, Backup-Metrik nach
echtem Cron-Lauf.

## 5. Mitgelieferte Risiken der Runde

- Neue Bind-Mounts (`rules/`, `grafana/provisioning/datasources/`,
  `node-textfile/`) hängen davon ab, dass die Verzeichnisse vor `up -d`
  existieren – beides wird in Schritt 2 mit `install -d -m 0755` angelegt.
- `daemon.json` ist ein Neustart-Gefahrenpunkt: bewusst nur, wenn **wir** die
  Datei geschrieben haben und keine eigenen Container laufen.
- Prometheus-/Grafana-Neustarts sind an Hash **und** Laufstatus gekoppelt;
  ein unterdrückter Neustart zeigt sich als „0 Regeln / keine Datasource"
  (Fehlerbild C5).
- Das ask-Muster ist ein Filter, kein Budgetschutz (P-005) – bewusst so
  entschieden und in [SECURITY.md](../SECURITY.md) Abschnitt 3 beschrieben.

---

## 6. Review-Runde 2 (zweite Fundliste 2026-09-29)

**Grundlage:** zweite, eigenständige Fundliste mit **neu gestarteter
Numerierung** A1–A7, B1–B6, C1–C7 (nicht verwechseln mit Runde 1).
Bewertung je Punkt: *zugestimmt → umgesetzt* oder *abgelehnt → Beleg*.

| ID | Befund | Bewertung | Umsetzung / Beleg |
|---|---|---|---|
| A1 | `versions.env` wurde vor `mkdir /opt/coder` geschrieben (Abbruch auf frischem Host) | zugestimmt | Schreibvorgang erst nach erfolgreichem `up -d` inkl. `install -d -m 0755 /opt/coder` |
| A2 | Domain-Auswertung per awk über die Caddyfile traf die Matcher-Zeile `@askOK` → leere Domain → TLS-Smoke still übersprungen | zugestimmt | explizites `/opt/coder/domain` (vor Caddyfile-Drift), beide Leser nutzen `tr -d '[:space:]'` und melden leer |
| A3 | Pipe mit 64-KB-Buffer könne bei `sshd -T`/`apt-config dump`/`ufw status` zu 141/SIGPIPE führen | **abgelehnt** | gemessen: `sshd -T` 4 700 B, `apt-config dump` 10 903 B, `ufw status` 633 B, `crontab -l` 0 B – alles deutlich unter dem Pipe-Buffer, Abbruch nicht erreichbar (der frühere Fund B2-001 lag daran, dass ein Dump 1,2 MB hatte) |
| A4 | Container-Schleife in `boot-check.sh` lief vor jedem Warten | zugestimmt | PG-Health-Warte-Schleife zuerst, dann Warten auf **alle** Container, danach Meldung |
| A5 | Volume-Guard fehlte bei vorhandenem `coder_postgres_data` (P-011 deckt nur unvollständige `.env`) | zugestimmt | Abbruch direkt nach dem `.env`-Guard, Hinweis auf RESTORE statt Volume-Löschung |
| A6 | `fail2ban-client get sshd logpath` liefert rc=0 ohne Aussagekraft | zugestimmt | `fail2ban-client status sshd` → `Total failed` numerisch geprüft; **Drop-in geändert nicht nötig**: Debian-Filter enthält bereits `journalmatch … _COMM=sshd-session`, 63/63 Fehlversuche laufen auf `sshd-session` |
| A7 | Persistenz-Fall 2 stand vor dem erfolgreichen `up -d` | zugestimmt | wie A1, ein gemeinsamer Fix |
| B1 | Erster Nutzer (= Owner) wird derjenige, der zuerst die Seite öffnet | zugestimmt | optional über `CODER_FIRST_USER_EMAIL/USERNAME/PASSWORD/_FULL_NAME` beim ersten Lauf; Flags in `coder login --help` von v2.36.6 geprüft; Passwort per stdin, nie als exec-Argument |
| B2 | Docker-Socket | bereits erledigt | Trennung = offene Entscheidung `D-Socket`, Allowlist in [templates/allowlist.md](../templates/allowlist.md) |
| B3 | Backups nur DB, gleiche Platte, kein Restore-Test | bereits erledigt | offene Punkte `D-Offsite` + Restore-Probe in [SECURITY.md](../SECURITY.md) §8, [README.md](../README.md) |
| B4 | TLS-Budget-Überschreitung nur im Log sichtbar | zugestimmt | `check-tls.sh` schreibt `node-textfile/coder_tls.prom`, vierte Regel `TlsIssuanceBudgetHigh` (>20/7 d) |
| B4b | Wildcard ohne offene 80/443 nur über DNS-01 | zugestimmt, nur Doku | Alternative in [OPERATIONS.md](../OPERATIONS.md) §11: `_acme-challenge.`-CNAME, braucht DNS-Provider-Zugang **und** ein Caddy-Image mit DNS-Plugin (Standardimage hat keines) |
| B5 | Coder sieht hinter Caddy nur dessen Container-IP | **Entscheidung offen** | Env-Namen belegt: `CODER_PROXY_TRUSTED_HEADERS`, `CODER_PROXY_TRUSTED_ORIGINS`. Nicht konfiguriert, weil das Vertrauen auf das ganze Compose-Netz durch einen Workspace-Container im selben Netz fälschbar wäre; für die Schule vorher festlegen, ob Client-IPs im Audit geführt werden sollen (Datenschutz) |
| B6 | `ufw`-Regeln würden auch bei anderem SSH-Port gesetzt | zugestimmt | Port-Vorabprüfung aus `sshd -T` vor der ersten `ufw`-Änderung, sonst Abbruch |
| C1 | Zeitzone nie gesetzt → 03:00-Uhr-Restart nicht garantiert | zugestimmt | `timedatectl set-timezone Europe/Berlin` idempotent zu Beginn von Schritt 1/10 |
| C2 | Nach `reset-passwords.sh` neu erstellte Container nur beim nächsten `up -d` | zugestimmt | Hinweis in der Ausgabe des Skripts **und** in [OPERATIONS.md](../OPERATIONS.md) §7 |
| C3 | Doppelter Container-Check in `reset-passwords.sh` | zugestimmt | zweiter Block entfernt (Prüfung genau einmal, vor dem Backup) |
| C4 | `/var/log/coder-boot.log` und `/var/log/coder-tls.log` ohne Rotation | zugestimmt | `/etc/logrotate.d/coder-logs` (wöchentlich, 8×, `copytruncate`), Drift-Test auf 17 Dateien |
| C5 | Datei-Split von `setup-coder.sh` | **abgelehnt** | Tests extrahieren Code über Zeilenmarker in `setup-coder.sh`; jeder Split bricht `tests/t-b2-*.sh`. Legende unten ersetzt die vermissten Definitionsstellen |
| C6 | Tippfehler (`konfigurgerecht`, `Prometheums`, `Kontrabuch`, `einmallig`, `präsizt`) | zugestimmt | alle fünf korrigiert |
| C7 | Zugangsdaten als Klartext auf stdout ohne Hinweis | zugestimmt | Hinweis zum Leeren des Scrollbacks in `setup-coder.sh` und in `reset-passwords.sh` |

**ID-Legende (C5):** `A…/B…/C…/D…` = Fundlisten-IDs; Runde 1 und Runde 2
starten jeweils neu. `B2-001 … B2-010` = Tickets der Umsetzungsrunde 1,
identisch mit den Dateien `tests/t-b2-00*.sh`. `P-0xx` = geplante
Maßnahmen aus dem Plan, `F-0xx` = Fehlerbefunde desselben Plans;
`D-…` = offene Entscheidungen, `D-Socket`, `D-Offsite`,
`D-Monitoring`, `D-TLS`, `D-SSH`, `D-Reboot-Fenster`, `D-Firewall`.

### Teststand nach Runde 2 (tatsächlich ausgeführt, 2026-09-29)

```
bash -n setup-coder.sh                      → 0 Befunde
shellcheck -S warning setup-coder.sh        → genau 1 Befund (SC2034, Retry-Zähler, wie in Runde 1)
for f in tests/t-*.sh; do bash "$f"; done   → 10/10 Exit 0, 316 PASS, 0 FAIL
yaml.safe_load (coder-alerts.yml)           → 4 Regeln, u. a. TlsIssuanceBudgetHigh
yaml.safe_load (prometheus.yml)           → ok (docker-compose.yml unverändert in Runde 2)
logrotate -d (coder-logs) auf dem Test-Host → Syntax akzeptiert, 2 Pfade
Linkprüfung über 37 Markdown-Dateien        → 198 lokale Links, 0 tote
```

Zusätzlich auf dem Test-Host `2.29.11.30` ausgeführt: Lauf 10 und Lauf 11
je Exit 0 / 0 `[FEHLER]` / 0 Drift (Lauf 11 ohne Container-Neustart),
`check-tls.sh` → `coder_tls_issuances_7d 32` → Regel `TlsIssuanceBudgetHigh`
firing, `boot-check.sh` → PG zuerst, dann Container, dann `/healthz` ROT
(wegen externem nginx), `logrotate -d` für `coder-logs` ohne Fehler.
