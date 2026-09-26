# PLAN-REVIEW – Adversarial Review über `ai-review/PLAN.md`

Rolle: Independent Principal Engineer / Adversarial Reviewer.
Geprüft: `setup-coder.sh` (845 Zeilen, Stand im Repo), `ai-review/PLAN.md`
(543 Zeilen, abgebrochen), `ai-review/01-bash.md`, `02-security.md`,
`03-debian-docker.md`, `04-coder-caddy.md`, `05-backup-recovery.md`,
`06-architecture.md`.
Geändert wurde ausschließlich diese Datei. Keine Implementierung.

Methodik: Jeden übernommenen Plan-Befund (F-001–F-012, mehr enthält die
Datei nicht) gegen den Code geprüft; jede Verwerfungsentscheidung in
„Verworfene Befunde" und „Review-Konflikte (K1–K8)" gegen Code-Fakten und
AGENTS.md (Security-Modell: Workspace-Nutzer = untrusted; Restore-Test-Pflicht;
Idempotenz; keine Destruktion ohne explizite Anforderung) geprüft;
Abwesenheitsbehauptungen per `grep` nachvollzogen (flock, logrotate, restore,
Digest, DOCKER-USER, retention.size, logging, ask-Allowlist).

Vorab-Urteil: Der Plan hat in F-001, F-004, F-005, F-008, F-009, F-012 die
richtigen Defekte gefunden. Die Fix-Richtungen sind dort im Kern korrekt
(Einzelheiten dazu bei den jeweiligen P-Punkten). Als Implementierungsgrundlage
ist der Plan trotzdem **nicht freigabefähig**: er ist physisch abgebrochen,
referenziert nicht existierende Findings/Entscheidungen, lässt die drei
größten Risikoklassen (Docker-Socket, SSH-Passwort weltweit, TLS-On-Demand-DoS,
volle Platte durch Logging) ohne Finding und enthält mindestens einen
technisch falschen Fix-Vorschlag (F-006/umask). Details unten.

---

## P-001 – PLAN.md ist physisch abgebrochen: 12 von 26 Findings vorhanden, Rest fehlt

Severity: CRITICAL

Affected finding(s): PLAN.md als Ganzes (Eigenbehauptung Z11–16: „26 übernommene Findings"; Datei enthält nur F-001–F-012); F-012 bricht mitten im Satz ab.

Problem: Die Datei endet in F-012/Test mit dem wörtlichen Inhalt
`ist (Soll nach Dok` + Zeile `...[truncated 15821 chars]`. Das ist kein
korrekter Satz, sondern ein abgeschnittener Puffer. Die versprochenen
F-013–F-026, jede Implementierungsreihenfolge, jede Blocking/Non-Blocking-Liste
und die in K1/K7/K8 sowie in F-002/F-003 referenzierten Entscheidungen D4–D9
existieren in der Datei nicht (per `grep "^## F-"` verifiziert: nur F-001–F-012).

Why the plan may be wrong: Der Plan stellt sich als vollständige Triage dar
(„60 Rohbefunde → 26 übernommene"), ist aber als Artefakt unvollständig. Jede
Freigabe würde etwas freigeben, dessen zweite Hälfte unbekannt ist. Insbesondere
ist nicht prüfbar, ob die unten als „fehlend" gerügten Security-Findings
(Docker-Socket, SSH, TLS-ask, Logging-Limits) in F-013–F-026 standen oder
bewusst entfielen – der „Verworfene Befunde"-Tabelle ist damit nicht zu trauen.

Evidence:
- `ai-review/PLAN.md` Z11–16 behauptet 26 Findings; `grep -n "^## F-"` liefert
  nur 12 Treffer (F-001–F-012).
- Dateiende (Z540–544): `ist (Soll nach Dok` + `...[truncated 15821 chars]`,
  per Byte-Lesung bestätigt (Zeilenlängen 76/76/19/26, keine weiteren Zeilen).
- `ai-review/TEST_PLAN.md` ist 0 Bytes – der Plan verweist implizit auf Tests,
  die nicht existieren.

Potential regression: Implementierung „nach Plan" implementiert eine
unbekannte Teilmenge; als erledigt abgehakte Security-Fixes (Digest-Pins,
TLS-ask, Socket-Policy) existieren ggf. nur im abgeschnittenen Teil und werden
nie umgesetzt, ohne dass es jemand merkt.

Required correction: PLAN.md reparieren oder als Entwurf kennzeichnen:
vollständige F-013–F-026 wiederherstellen (oder ehrlich auf F-001–F-012
zurückschneiden inkl. Korrektur der „26"-Behauptung), abgebrochenen Satz in
F-012 vervollständigen, alle referenzierten D-Entscheidungen entweder
ausformulieren oder aus den Dependencies streichen. Bis dahin: kein
Implementierungsstart.

Required test: `grep -c "^## F-" ai-review/PLAN.md` muss der im Kopf genannten
Zahl entsprechen; `tail -5 ai-review/PLAN.md` darf kein Trunkierungsmarker
enthalten; jede `D[0-9]`- und `F-[0-9]`-Referenz muss auf eine existierende
Überschrift auflösen (Skript-Check, kein Handwedeln).

Classification: CONFIRMED

---

## P-002 – Kritischster Befund (Docker-Socket = Host-Takeover) hat kein Finding

Severity: CRITICAL

Affected finding(s): 02/F-001 (CRITICAL, CONFIRMED), 02/F-003, 06/F-005 – in PLAN.md ersatzlos entfallen; kein F-xxx, keine D1-Entscheidung im lesbaren Teil.

Problem: `coder` erhält `/var/run/docker.sock` schreibbar plus `group_add:
DOCKER_GID` (`setup-coder.sh` L188–201). Wer den Socket nutzen kann, erzeugt
Container mit beliebigen Mounts/Capabilities – das ist Host-root-äquivalent.
AGENTS.md erklärt Workspace-Nutzer für untrusted. Der Plan enthält dafür kein
einziges Finding: keine Template-Allowlist, kein Socket-Proxy, kein
Netzwerk-Guard, nicht einmal die „billige Stufe" aus 06/F-005
(`templates/allowlist.md` + Abnahmeprozess). Die „Verworfen"-Tabelle wirft
02/F-002/F-004 als ASSUMPTION raus und behauptet Ersatz durch „prüfbare
Template-Allowlist (F-019-Testschritt)" – F-019 existiert nicht (siehe P-021).

Why the plan may be wrong: Der Plan priorisiert nach „tatsächlichem Risiko auf
diesem Single-Host-Schulserver" (Z21), stuft aber einen deterministischen,
per Code-Lesung CONFIRMEDen Total-Compromise-Pfad auf null Findings herunter,
während er eine Crontab-Einzeiler-Konstellation (F-001) als CRITICAL führt.
Das ist eine invertierte Priorisierung: F-001 trifft nur Hosts mit genau einer
Alt-Crontab-Zeile; der Socket trifft jede Installation, sofort und immer. Die
Begründung „Templates nicht im Repo" verwechselt Abwesenheit von Templates mit
Abwesenheit von Risiko: Der Socket ist im Repo, die Workspaces entstehen laut
Kommentar L762–764 laufzeitseitig über genau diesen Socket außerhalb jeder
sichtbaren Policy.

Evidence:
- `setup-coder.sh` L201: `- /var/run/docker.sock:/var/run/docker.sock`
  (kein `:ro`, kein Proxy), L190–191 `group_add: ${DOCKER_GID}`.
- 02/F-001 als CONFIRMED belegt; 06/F-005 ordnet es als „Single Point of Total
  Compromise" ein.
- PLAN.md `grep -i "socket"` trifft nur in F-007 als Nebensatz („Socket-Probe"),
  nie als Finding.

Potential regression: Ohne Allowlist/Proxy bleibt jede künftige
Unterrichtsanforderung („Docker-in-Docker für die Klasse?") eine unsichtbare
Sicherheitsentscheidung. Ein einziges privilegiertes Template oder eine
Coder-Provisioner-Schwäche liest `.env`, Backups, `/etc/shadow`-äquivalente
Mounts.

Required correction: Eigenes Finding (CRITICAL) wieder einführen, mindestens
Stufe 1 aus 06/F-005: `templates/allowlist.md` im Repo (verboten: Socket-Mount,
privileged, Host-PID/-Netz, Host-Root-Mounts, gemeinsame Netze mit `postgres`),
plus manueller Abnahmeschritt pro neuem Template, plus negativer
Workspace-Selbsttest (`mount`, Socket-Pfade, `postgres:5432`-Erreichbarkeit aus
normalem Workspace). Proxy/separater Host als echte D-Entscheidung (mit
Eigentümer und Frist), nicht als Non-Goal.

Required test: Aus normalem Workspace: `mount | grep docker.sock`,
`ls /var/run/docker.sock`, `getent hosts postgres`, `nc -z postgres 5432`,
Versuch, fremden Workspace-Container zu inspizieren – alles dokumentiert
fehlschlagend. Bei jedem neuen Template: Checkliste gegen Allowlist abgehakt.

Classification: CONFIRMED

---

## P-003 – SSH weltweit + Passwort aktiv: ohne Finding, nur Warnung – Dauer-Provisorium wird stabil

Severity: CRITICAL

Affected finding(s): 02/F-007 (HIGH, LIKELY), 06/F-012 – in PLAN.md kein Finding; Skript L28–34, L440–445, L832–839.

Problem: SSH ist per Design weltweit offen (`ufw limit 22/tcp`, L375) und
Passwort-/KbdInteractive-Login ist aktiv (Kommentar L31–34 sagt es ausdrücklich;
Abschlusscheck warnt nur, Exit-Code bleibt 0). Der Plan übernimmt dazu nichts:
kein Key-only-Enforcement, kein `ssh-harden.sh`-Pfad, kein Termin, kein
Zweit-Zugangs-Nachweis. Rate-Limit + fail2ban begrenzen Raten, nicht verteilte
Angriffe und nicht kompromittierte/wiederverwendete Passwörter. Ein
kompromittiertes SSH-Passwort ist Host = Docker-Admin = `.env` + Backups + DB
(Angriffspfad Nr. 1 in 02).

Why the plan may be wrong: Der Plan behandelt SSH als „menschliche
Entscheidung später" und meldet Setup-Erfolg (grün) im unsichersten zulässigen
Zustand. Über Jahre (Lehrerwechsel, Passwort-Weitergabe) normalisiert sich das
Provisorium zum Produktionszustand – exakt die Architekturkritik aus 06/F-012,
die der Plan durch Streichung bestätigt statt behebt. „Später Bescheid geben"
ist kein Plan.

Evidence:
- L31–34: „Passwort-Login ist aktuell noch aktiv … unbedingt Bescheid geben,
  damit [es] deaktiviert wird".
- L440–445 und L832–839: nur `warn`, kein `fail`; `ERROR_COUNT` bleibt 0,
  Skript exitt 0.
- 02/F-007 und 06/F-012 belegen Status; PLAN.md enthält kein SSH-Finding
  (grep „sshd|PasswordAuthentication" trifft nur in F-007-Nebensatz nicht).

Potential regression: Falsche Härtung (sofortiges Abschalten ohne Zweit-Zugang)
sperrt aus – deshalb ist die Plan-Lücke kein Argument für Schnellschuss,
sondern für vorbereiteten Pfad. Umgekehrt: Jede Verzögerung ohne Frist
verlängert das Brute-Force-/Phishing-Fenster ohne sichtbaren Druck.

Required correction: Finding (HIGH, nicht CRITICAL wegen Aussperrungsrisiko)
mit: vorbereitetem `ssh-harden.sh` (setzt `PasswordAuthentication no` +
`KbdInteractiveAuthentication no` + `PermitRootLogin no`, mit `sshd -t`-Check
und dokumentierter Zweit-Zugangs-Voraussetzung), heute ins Repo, Ausführung
genau einmal nach Key-Abnahme mit Datum/Eigentümer. Bis dahin: Warnung
verschärfen (Alter des Provisoriums loggen), aber Setup weiter grün.

Required test: Test-VM: `sshd -T | grep -i passwordauthentication` vor/nach;
externer Passwort-Login muss scheitern, Key-Login gelingen; fail2ban-Ban
separat prüfen. Nie Produktion ohne Zweit-Zugang.

Classification: CONFIRMED (Code-Fakt Warnung-statt-Enforcement; Zielhost-Live-Status LIKELY, nicht live geprüft – ändert nichts am fehlenden Finding).

---

## P-004 – Firewall-Finding fehlt: UFW regelt keine Container-Ports, dynamische Workspace-Ports ohne Modell

Severity: HIGH

Affected finding(s): 02/F-008 (HIGH, CONFIRMED), 02/F-009, 06/F-006 – in PLAN.md kein Finding; Skript L400–413, L207–210.

Problem: Das Skript kommentiert selbst korrekt, dass Docker-`ports:` eigene
iptables-Ketten einträgt und UFW umgeht (L400–408). Es gibt keine
`DOCKER-USER`-Policy, keine `daemon.json`-Bindungsvorgabe, kein Modell für
dynamische Workspace-Ports, die Coder über den Socket publizieren kann. Der
Plan übernimmt nichts davon – weder Bindungsregel-Disziplin
(„neue `ports:` nur an 127.0.0.1, Ausnahme nur Caddy-80/443") noch
`DOCKER-USER`-Default-Deny-Vorbereitung noch Dual-Stack-Test. Jeder später
hinzugefügte `ports:`-Eintrag erscheint öffentlich, während `ufw status`
Schutz suggeriert.

Why the plan may be wrong: Die „Verworfen"-Tabelle erklärt 02/F-009/F-010
(IPV6, Port-Inventar) zu „kein Code-Defekt" und verweist IPv6/DNS als
„Testschritte in D9" – D9 existiert im lesbaren Plan nicht. Damit wird eine
CONFIRMEDе Durchsetzungslücke (kein `DOCKER-USER`, per Lesung bestätigt) zu
einer Phantom-Referenz entsorgt. Korrekte Loopback-Bindungen für
9090/9100/3001 (L233, L255, L269) beweisen nichts für künftige Ports.

Evidence:
- L207–210 Caddy-`ports: 80/443/443udp` an allen Interfaces (bewusst offen);
  L409–411 `ufw allow` dazu (dokumentarisch, nicht durchsetzend).
- Kein `DOCKER-USER`, kein `daemon.json` im gesamten Skript (grep-bestätigt
  abwesend in 02/06).
- 03/F-012 bestätigt die UFW-Umgehung als korrekt kommentiert – der Plan macht
  daraus „kein Handlungsbedarf", obwohl 02/F-008/06/F-006 daraus eine
  fehlende Policy ableiten.

Potential regression: `DOCKER-USER`-Default-Deny ohne Dual-Stack-Test bricht
Workspace-Apps/HTTP-3 – deshalb nur mit externem Scan einführen. Die reine
Bindungsregel hat kein Bestandsrisiko (nur künftige Einträge).

Required correction: Finding (HIGH) mit: dokumentierter Bindungsregel + Review-
Check für jede neue `ports:`-Zeile; `DOCKER-USER`-Kette als vorbereitete
D-Entscheidung mit Dual-Stack-Test (IPv4+IPv6, `iptables-save`/`nft list`,
externer Scan TCP 22/80/443/9090/9100/3001 + UDP 443, `ss -tlnp`-Abgleich,
Schulnetz-NAT-Abgleich). IPv6 entweder als Betriebs- oder als abgeschalteter
Pfad deklarieren, nicht undefiniert lassen.

Required test: Externer Scan + `ss -tlnp` + `iptables-save` inkl. `DOCKER-USER`
vor/nach; jede neue `ports:`-Zeile wird in Review gegen Bindungsregel geprüft.

Classification: CONFIRMED

---

## P-005 – On-Demand-TLS ohne Autorisierung: Plan erkennt an (K8), liefert aber kein Finding

Severity: HIGH

Affected finding(s): 02/F-011 (HIGH, CONFIRMED), 04/F-001 (HIGH, CONFIRMED),
04/F-003/F-006/F-007; PLAN-K8 verspricht „Doku + Erkennung (F-016)" – F-016
existiert nicht im lesbaren Teil.

Problem: `on_demand_tls { ask http://example.com }` (L306) antwortet immer
200 – jeder Internet-Teilnehmer kann per SNI mit beliebigem
`*.coder.ghse-unterricht.de`-Namen ein echtes Let's-Encrypt-Zertifikat
auslösen, ohne Coder-Account. Wochenbudget: 50 pro registrierter Domain
(`ghse-unterricht.de`, geteilt mit allen anderen Schuldiensten derselben
Domain – 04/F-007). Folge: legitime neue Workspace-Apps bekommen in derselben
Woche kein Zertifikat (TLS-Fehler im Unterricht). Zusätzlich: On-Demand gilt
auch für die Root-Domain selbst (04/F-006, Kommentar L14–16 falsch), und jeder
Erst-Handshake hängt an der Erreichbarkeit von `example.com` (04/F-003).

Why the plan may be wrong: K8 nennt das Muster korrekt „übernommene
Tutorial-Schwäche" und verspricht kurzfristig „nur Doku + Erkennung", echten
Fix nur per D5. Im lesbaren Plan gibt es weder D5 noch F-016 noch eine
Erkennungslogik (Caddy-Log-Monitoring, Rate-Limit-Alarm). Das ist DoS per
Vertagung: Der realistischste Fremd-DoS-Vektor (ohne Account auslösbar) bleibt
vollständig offen, während der Plan Kommentarpräzisierungen als ausreichend
darstellt. Doku verhindert kein Zertifikats-DoS.

Evidence:
- L304–319 Caddyfile: `ask http://example.com` + `tls { on_demand }` für
  `${DOMAIN_CODER}, *.${DOMAIN_CODER}`.
- Caddy-Doku (`ask` als Missbrauchsschutz-Voraussetzung für Produktion) +
  Tutorial-Wortlaut („DO NOT CHANGE") + LE-Rate-Limits, verifiziert in 04.
- PLAN-K8 Z65–70 verspricht F-016/D5 – beide im lesbaren Teil abwesend.

Potential regression: Echter `ask`-Endpoint mit veralteten Coder-API-Daten
blockiert legitime neue Apps (Falsch-Negativ); DNS-01-Wildcard braucht
Provider-Token + eigenen Caddy-Build. Deshalb ist (b) `CODER_DISABLE_PATH_APPS`
(siehe P-006) zuerst richtig, TLS-Modell danach als echte Entscheidung.

Required correction: Finding (HIGH) mit: (a) sofort Kommentar präzisieren
(Root-Domain ebenfalls on-demand; Budget gehört `ghse-unterricht.de`,
geteilt); (b) `CODER_DISABLE_PATH_APPS=true` nach Template-Inventar (P-006);
(c) TLS-Modell als D-Entscheidung vorbereiten (echter `ask` gegen Coder-API/
Allowlist vs. DNS-01-Wildcard mit Token-Verwaltung), plus Erkennungs-Seite
(Caddy-`obtaining certificate`-Monitoring). Kein stiller Default.

Required test: Test-Domain: TLS-Handshakes für erfundene Subdomains
(`openssl s_client`/`curl --resolve`) – `docker compose logs caddy` muss heute
`obtaining certificate` pro Fake-Namen zeigen (Ist-Zustand); nach `ask`-Fix muss
der Handshake abgewiesen werden.

Classification: CONFIRMED

---

## P-006 – `CODER_DISABLE_PATH_APPS=true` ersatzlos gestrichen (eine Zeile gegen Cookie-Missbrauch)

Severity: HIGH

Affected finding(s): 04/F-002 (HIGH, CONFIRMED) – in PLAN.md weder übernommen noch in „Verworfen" begründet; Skript L192–199.

Problem: `CODER_WILDCARD_ACCESS_URL=*.${DOMAIN_CODER}` ist gesetzt (L196),
`CODER_DISABLE_PATH_APPS` fehlt. Coders eigene Security-Best-Practices verlangen
für genau diese Konstellation das Deaktivieren von Path-Apps: Path-Apps teilen
den Origin mit Dashboard/API, ein Workspace mit clientseitigem Code kann
Session-Cookies desselben Benutzers für API-Aufrufe missbrauchen. Coder mildert
bereits/teils (kein Teilen mit anderen Nutzern), empfiehlt aber ausdrücklich
zusätzlich das Deaktivieren.

Why the plan may be wrong: Der Plan streicht einen expliziten, benannten
Upstream-Production-Hinweis ohne ein Wort Begründung – nicht einmal als
Non-Goal mit Messauftrag (wie bei mem_limit/K4). Das ist kein
Risiko-Nutzen-Abwägen, sondern Schweigen. Die Regression (Templates mit
`coder_app` ohne `subdomain = true` brechen) ist real, aber per
Template-Inventar prüfbar – exakt der Test, den 04/F-002 vorschreibt und den
der Plan nie verlangt.

Evidence:
- L192–199 `environment` enthält `CODER_ACCESS_URL`, `CODER_WILDCARD_ACCESS_URL`,
  kein `CODER_DISABLE_PATH_APPS` (grep-bestätigt abwesend in 04).
- 04/F-002 zitiert Upstream-Best-Practice wörtlich; PLAN.md erwähnt die
  Variable nirgends.

Potential regression: Mittel, falls Templates Pfad-Apps ohne `subdomain = true`
nutzen – vorher Inventar prüfen, Templates auf `subdomain = true` umstellen.

Required correction: Finding (HIGH) wieder einführen: `CODER_DISABLE_PATH_APPS=true`
setzen, aber erst nach Template-Inventar (welche `coder_app` ohne
`subdomain = true`?). Unabhängig vom TLS-Modell sofort richtig, sobald
Wildcard funktioniert.

Required test: Test-`coder_app` ohne `subdomain = true` → Pfad-URL
(`https://DOMAIN/@user/workspace/apps/slug`) wird abgelehnt; dieselbe App mit
`subdomain = true` über `*.DOMAIN` funktioniert.

Classification: CONFIRMED

---

## P-007 – Volle Platte: wahrscheinlichster schleichender Totalausfall hat kein Finding

Severity: HIGH

Affected finding(s): 03/F-004 (HIGH, CONFIRMED – Logging ohne Limit),
03/F-008 (LOW – retention.size fehlt), 05/F-007 (Log ohne logrotate/Alerting),
05/F-016 (kein df-Check) – in PLAN.md kein einziges Finding; Skript L164–281
(kein `logging:`-Block), L228 (nur `retention.time=15d`), L531 (Log-Redirect
ohne Rotation).

Problem: Ohne `logging`-Block nutzt Docker `json-file` unbegrenzt
(`max-size`/`max-file` = -1, sofern Daemon nicht global anders konfiguriert –
`daemon.json` wird nicht angelegt). Alle sechs Container (insbesondere `coder`,
`caddy` mit Access-/On-Demand-Logging, `postgres`) wachsen auf der
Root-Partition unter `/var/lib/docker/containers/`. Dazu: TSDB nur
zeitbegrenzt (Kardinalitäts-Spike → Platte voll trotz 15d), `coder-backup.log`
ohne `logrotate` (wächst als Root-Log), kein `df`-Vorabcheck, kein
Platten-Alarm (node-exporter misst, niemand wertet aus). Voll bedeutet:
Postgres-Schreibfehler/WAL-Risiko, Backup kann nicht schreiben, APT blockiert –
ein ungebremster Log-Stream legt den Schul-Server lahm. Die Aufgabenstellung
(21. „vollem Datenträger") wird vom Plan damit ignoriert.

Why the plan may be wrong: Der Plan behandelt Backup-Atomarität (F-005) und
Cron-Locks (F-009) sorgfältig, lässt aber die drei Plattenkiller (Logs, TSDB,
Backup-Log) unangetastet – als wären sie „Hygiene". 03/F-004 ist CONFIRMED per
Upstream-Doku, nicht ASSUMPTION. „Im Zweifel behalten" (F-008-Philosophie) plus
stückzahlbasierte Retention ohne Größenobergrenze verschärft das Problem sogar.

Evidence:
- Kein `logging:` in `docker-compose.yml` (Lesung L164–281); kein
  `retention.size` (L228 nur `retention.time`); kein `logrotate`, kein `MAILTO`,
  keine Alerting-Sektion in `prometheus.yml` (L323–334 nur 2 Scrape-Jobs).
- 03/F-004/F-008, 05/F-007/F-016 belegen je per Lesung/grep.

Potential regression: Gering – `logging: {max-size: 10m, max-file: 3}` verliert
alte Historie (schlechter für Forensik, besser als volle Platte);
`retention.size` löscht alte Metriken früher bei knappem Wert – an reale
Platte anpassen; `logrotate` nur Beobachtung.

Required correction: Finding (HIGH) mit: `logging`-Block pro Service
(mindestens coder/caddy/postgres), `retention.size` zusätzlich zu
`retention.time` (z. B. an Plattenkapazität, kein Fantasiewert ohne Messung),
`logrotate` für `coder-backup.log`, `df`-Vorabcheck im Backup-Skript (klar
abbrechen ohne partielle Datei) + Frische-/Platten-Prüfung (minimal `check.sh`
statt vollem Alertmanager, siehe 06/F-007).

Required test: `docker inspect --format '{{json .HostConfig.LogConfig}}'`;
künstliche Log-Flut → Rotation statt Wachstum; TSDB mit kleinem Testwert
(200 MB) → alte Blöcke werden entfernt; tmpfs füllen → `backup.sh` bricht klar
ab ohne partielle Finaldatei; `logrotate --debug`.

Classification: CONFIRMED

---

## P-008 – Docker-Engine altert ungepatcht: Origins-Lücke ohne Finding, nur Phantom-D7

Severity: HIGH

Affected finding(s): 03/F-003 (HIGH, CONFIRMED/LIKELY) – PLAN-K7 vertagt auf „D7"; D7 existiert im lesbaren Teil nicht; Skript Schritt 5 ohne Origins-Pattern.

Problem: Standard-`unattended-upgrades` deckt `origin=Docker`
(`https://download.docker.com`, Schritt 1) nicht ab – `docker-ce`,
`containerd.io`, `runc`-Bündel werden nie automatisch gepatcht. Gerade diese
Schicht ist wegen P-002 (Socket = Vertrauensschicht) besonders kritisch. Der
Plan verlangt in keinem Finding, dass *eine* der beiden Optionen (automatisch
per Origins-Pattern vs. manueller Kalendertermin mit Eigentümer) nachweisbar
gilt – er verlangt gar nichts. Ergebnis: dritter, vergessener Update-Pfad
neben `update.sh` (Images) und unattended-upgrades (Debian).

Why the plan may be wrong: K7 beschreibt den echten Zielkonflikt (Automatik
schließt Lücke, riskiert Major-Destabilisierung) korrekt, zieht aber die
falsche Konsequenz (kein Finding). „Kein automatischer Fix, siehe D7" ohne D7
ist kein Kompromiss, sondern ein Loch. Exakter Origin-String (`o=Docker` vs.
Varianten) ist ohne Live-`apt-cache policy`/`dry-run` unbestätigt – der Plan
fordert den Nachweis nicht einmal.

Evidence:
- Schritt 5 (L465–497): kein `Origins-Pattern`/`Allowed-Origins`-Eintrag
  (Lesung); Upstream-README: Default deckt nur Debian-Archive, nicht
  Drittrepos.
- PLAN-K7 Z59–64 verspricht D7 – im lesbaren Teil kein D-Kapitel.

Potential regression: Mittel bei Auto-Aufnahme (Docker-Major kann Stack
destabilisieren – nur mit Test-Reboot in Nicht-Produktion); manuell ohne
Kalendereigentümer vergisst.

Required correction: Finding (HIGH): *Entweder* `origin=Docker` per eigener
Conf-Datei aufnehmen (mit Test-Reboot-Zyklus) *oder* bewussten manuellen Pfad
festlegen (Befehl, Intervall, Kalendereigentümer, Nachweis im Boot-/Update-Log).
F-013-Analog („eine der beiden Optionen muss nachweisbar gelten") als
Abnahmekriterium, nicht als Wunsch.

Required test: `apt-cache policy docker-ce` (Origin-String notieren);
`unattended-upgrade --debug --dry-run` – `docker-ce` erscheint je nach
Entscheidung als upgradebar oder begründet „kept back"; Reboot-Zyklus in
Test-VM.

Classification: CONFIRMED (Standardverhalten Fremdrepo); LIKELY (exakter
Origin-String ohne Live-Prüfung – Nachweis im Test nachholen).

---

## P-009 – Reboot ohne Ordnung, ohne Zeuge: 03:00-Auto-Reboot + Daemon-Restart ignorieren `depends_on`

Severity: HIGH

Affected finding(s): 03/F-002 (HIGH, CONFIRMED), 03/F-009/F-010, 06/F-010 –
in PLAN.md kein Finding; Skript L168–273 (`restart: unless-stopped` überall),
L475–479 (Reboot 03:00), L530–534 (Backup 01:00).

Problem: `depends_on`/`service_healthy` wertet nur die Compose-CLI bei
`up` aus. Nach Host-Reboot (automatisch 03:00 bei Kernel-Updates) oder
Daemon-Neustart (`apt`-Upgrade von docker-ce, `restart docker`, OOM) startet
`dockerd` alle Container gleichzeitig ohne Reihenfolge. Coder kann vor
Postgres-Bereitschaft crash-loopen; Caddy/Grafana treffen unbereite Upstreams
(kein Healthcheck für `coder`/`prometheus`). Nach dem Reboot prüft nichts die
Gesundheit (Schritt 10 läuft nur bei manuellem Setup, nie nach Auto-Reboot).
Erste Meldung: Schüler morgens. Zusätzlich P-008: Reboot meist durch
Debian-Kernel, während Docker-Engine ungepatcht altert.

Why the plan may be wrong: Der Plan verbessert Update-Health (F-012), aber
nicht Boot-Health – obwohl der Reboot automatisiert und damit die
wahrscheinlichste Reboot-Ursache ist. „Selbstheilend via restart" (Crash-Loop
bis Postgres bereit) ist kein Betriebskonzept ohne Zeuge (kein Boot-Log, kein
Alert). `stop_grace_period` (03/F-010) allein heilt nichts.

Evidence:
- Dokumentiertes Docker-Verhalten (Restart-Policy = Daemon-Ebene,
  `depends_on` = CLI-Ebene), referenziert in 03/F-002; Reboot-Config L475–479
  per Lesung; Abwesenheit eines Boot-Checks per Lesung (Schritt 10 nur im
  Setup-Pfad).
- Backup 01:00 vs. Reboot 03:00 vs. manuelles Update: drei Akteure ohne
  Koordination (06/F-011) – Plan fixiert nur Cron-Seite (F-009).

Potential regression: Gering für lesendes Boot-Gate (`@reboot`/systemd-on-boot:
Container gesund + `/healthz` 200 innert N Minuten, sonst `logger` +
`/var/log/coder-boot.log`); mittel für `stop_grace_period: 30s` (längerer
Shutdown, vernachlässigbar) und Coder-Healthcheck für Caddy-`depends_on`
(falsch konfiguriert → zusätzliche Neustartschleife – in Test-VM verifizieren).

Required correction: Finding (HIGH): Boot-Gate (lesend + Logging, kein
Eingriff), `stop_grace_period: 30s` für Postgres, Coder-HTTP-Healthcheck
(`/healthz`, wie in Schritt 10) + Caddy-`condition: service_healthy`
nachziehen; Docker-Repo-Entscheidung aus P-008 hier mitführen (kein dritter
Update-Pfad).

Required test: Test-VM-`reboot`, danach Boot-Log + `docker logs coder` (erste
2 Minuten) auf Postgres-Verbindungsfehler/Selbstheilung; `docker compose ps`
nach Boot.

Classification: CONFIRMED (Restart-Verhalten, Reboot-Config); LIKELY
(sichtbare Fehler nach Reboot, timing-abhängig).

---

## P-010 – F-006-Fix technisch falsch: `umask 077` wirkt nicht durch `sudo tee`

Severity: HIGH

Affected finding(s): PLAN F-006 (Z279–313); Skript L141–147 (`sudo tee /opt/coder/.env`).

Problem: Der Plan schlägt vor: „Mit `umask 077` schreiben (Backup-Skript L505
nutzt das bereits – Muster übernehmen)". Das Muster ist nicht übertragbar:
`backup.sh` läuft als Root (Cron) und setzt `umask 077` im selben Prozess, der
die Datei erzeugt. `setup-coder.sh` läuft als normaler Sudo-Nutzer; `sudo tee`
erzeugt die Datei im `tee`-Prozess als Root mit Roots-umask (typisch 022),
nicht mit der umask der aufrufenden Shell. `umask 077` im Setup-Skript ändert
daran nichts – das 644-Fenster bleibt. Der Fix verspricht Schließung eines
Secret-Exposure-Fensters, das er nicht schließt.

Why the plan may be wrong: Analogieschluss ohne Privilegien-Modell. 01/F-002
hatte das Fenster korrekt als umask-abhängig beschrieben („je nach Host-umask");
der Plan macht daraus eine pauschale `umask`-Anweisung ohne `sudo`-Kontext.
Zusätzlich: Temp-Datei + `mv` ohne Eigentümer-/Modus-Angabe (`install -m 600`,
`mktemp` gleiche Partition, `chown root:root`) lässt dasselbe Fenster an
anderer Stelle.

Evidence:
- L141 `sudo tee /opt/coder/.env`, L146 `sudo chmod 600` erst danach;
  L505 `umask 077` steht in `backup.sh` (Root-Kontext), nicht im Setup-Pfad.
- Generischer Unix-Mechanismus (022 → 644 vor chmod) in 01/F-002 lokal
  verifiziert; `sudo`-umask-Separation ist dokumentiertes sudo-Verhalten.

Potential regression: Gering bei korrekter Variante (`sudo install -m 600` /
`mktemp` + `mv` + `chown`), aber der Plan-Vorschlag wie geschrieben gibt
falsche Sicherheit (Reviewer hakt „umask gesetzt" ab, Fenster offen).

Required correction: F-006 umschreiben: atomar via Temp-Datei gleiche
Partition + `sudo install -m 600 /dev/null` (oder `mktemp` + `chmod 600` vor
Schreiben) + `mv` + `chown root:root`; kein Vertrauen auf Shell-umask durch
sudo hindurch. Idempotenz-Check auf Vollständigkeit (alle drei Schlüssel
nicht-leer, `DOCKER_GID` numerisch) – siehe zusätzlich P-011.

Required test: Test-VM mit `umask 022` + simuliertem Root-umask 022: `stat -c %a`
direkt nach Erzeugung muss ohne Zwischen-644 `600` zeigen; `grep` auf
644-Fenster im `bash -x`-Protokoll entfällt. Halbierte `.env` → Re-Run muss neu
erzeugen (P-011-Test).

Classification: CONFIRMED

---

## P-011 – F-006-„Neu erzeugen" bei unvollständiger `.env` ist destruktiv, nicht idempotent

Severity: HIGH

Affected finding(s): PLAN F-006 („sonst neu erzeugen"); Skript L134–157.

Problem: Wenn eine vorhandene `.env` unvollständig ist (Abbruch während `tee`,
Hand-Edit, Plattenfehler), will der Plan sie neu würfeln. Neue
`POSTGRES_PASSWORD` invalidiert die bestehende Datenbank-Instanz: Postgres
kennt das alte Passwort, Coder bekäme nach Recreate das neue – Lockout beim
nächsten `compose up`. Das ist kein Heilen, sondern Zerstören des einzigen
Credentials, das zur laufenden DB passt. Der „Idempotenz-Fix" macht den
Zweitlauf gefährlicher als den Erstfehler.

Why the plan may be wrong: Verwechslung von „fehlend" und „kaputt". Fehlend →
erzeugen ist sicher. Kaputt → neu würfeln ohne DB-Abgleich ist destruktiv.
Der Plan nennt keine Sicherung (`.env.bak`), keinen Abgleich (DB-Passwort
testen vor Würfeln), keine Warnung. AGENTS.md verbietet destruktive
Operationen ohne explizite Anforderung.

Evidence:
- L134 `if [ ! -f .env ]` prüft nur Existenz; Plan will auf Vollständigkeit
  umstellen und „sonst neu erzeugen" – ohne DB-Konsistenzprüfung.
- `reset-passwords.sh`-Problematik (F-010) beweist, dass DB- und `.env`-Seite
  auseinanderlaufen können – neu würfeln ohne Transaktion wiederholt den
  Fehler im Setup-Pfad.

Potential regression: Re-Run nach Teilfehler (SSH-Abbruch, Reboot) verwandelt
reparierbaren Zustand (eine Zeile fehlt) in Total-Lockout (alle Passwörter neu,
DB unerreichbar).

Required correction: Bei unvollständiger `.env`: abbrechen mit klarer Meldung
statt still neu zu würfeln – oder reparieren (fehlende Schlüssel ergänzen,
vorhandene nicht-leere behalten), plus `.env.bak.<ts>` (600) vor jeder
Änderung. Nur bei vollständig fehlender Datei neu erzeugen. `DOCKER_GID`
separat auffrischen (P-012), Passwörter nie ungefragt rotieren.

Required test: Test-VM: `.env` halbieren (eine Zeile löschen) → Re-Run darf
weder akzeptieren (Ist-Zustand) noch alle Passwörter würfeln (Plan-Zustand),
sondern muss fehlende Zeile ergänzen oder mit Reparaturanleitung abbrechen;
DB-Login danach weiterhin grün.

Classification: LIKELY (Destruktionsmechanik per Code-Lesung CONFIRMED;
Auslösungswahrscheinlichkeit hängt von Teilfehler-Häufigkeit ab).

---

## P-012 – F-007 (`DOCKER_GID`-Refresh) unterspezifiziert: nicht-atomar, ohne Leer-Guard, ohne Abweichungserkennung

Severity: MEDIUM

Affected finding(s): PLAN F-007 (Z315–350); Skript L119, L144, L191.

Problem: Der Plan will „bei jedem Lauf GID in `.env` auffrischen (`sed -i`-
Muster) … bei Abweichung recreaten". Drei Lücken: (1) `sed -i` ist nicht
atomar (gleicher Fehler wie F-006, nur kleiner) – Abbruch während `sed`
korrumpiert `.env`. (2) Kein Guard für leere GID: `getent group docker` leer
(Gruppe gelöscht, `groupmod`-Fehler, frische Docker-Deinstallation) → leere
`DOCKER_GID` in `.env` → `group_add: [""]` → Compose-Fehler oder Coder ohne
Socket-Recht. (3) „Bei Abweichung recreaten" ohne Spezifikation: Vorher/Nachher-
Vergleich wo? `compose up -d --no-deps coder` immer (Downtime bei jedem Lauf)
oder nur bei Diff (wo gespeichert)? Ohne Recreate wirkt die Dateiänderung nicht;
mit immer-Recreate hat jeder Re-Run eine TLS-Unterbrechung.

Why the plan may be wrong: Der Befund (stale GID → Permission denied, Check
prüft nur „Container läuft" L782) ist korrekt und wichtig – der Fix ist aber
Skizze, kein Patch. „Muster wie in reset-passwords.sh L662" übernehmen heißt,
dessen `sed -i`-Nicht-Atomarität zu kopieren, die F-010 gleichzeitig abschaffen
will (Widerspruch im Plan).

Evidence:
- L119 liest jedes Mal neu, L144 schreibt nur im Erstlauf (Lesung CONFIRMED).
- Abschlusscheck L781–786 prüft nur `State.Running`, keinen Socket-Zugriff.
- `sed -i`-Zeilen L662–663 per Lesung nicht-atomar.

Potential regression: Leere GID oder fehlgeschlagenes `sed` brickt den
Socket-Zugriff bei jedem folgenden `up`; blinder Recreate bei jedem Lauf
unterbricht laufende Workspaces/TLS ohne Config-Änderung.

Required correction: F-007 präzisieren: GID lesen, auf nicht-leer/numerisch
prüfen (sonst Fail mit Meldung, `.env` unangetastet); alten/neuen Wert
vergleichen, nur bei Diff atomar (Temp+`mv`, F-006-Muster korrigiert nach P-010)
tauschen und genau dann `compose up -d --no-deps coder` + Socket-Probe
(`docker exec coder docker info` bzw. `stat`-Probe – vorher verifizieren, dass
das Tool im Coder-Image existiert, sonst Host-seitige GID-Prüfung des
Socket-Files).

Required test: Test-VM: `groupmod -g <neu> docker` → Re-Run → Probe grün;
`getent` leer simulieren → Abbruch ohne `.env`-Änderung; Re-Run ohne Änderung →
kein Recreate (Container-Startzeit unverändert).

Classification: CONFIRMED (Befund); LIKELY (Auslösung nur nach
Docker-Neuinstallation/Hardwarewechsel – Fix-Lücken aber deterministisch).

---

## P-013 – F-005-Schwellwerte willkürlich, `gzip -t` unzureichend, ENOSPC ungeregelt

Severity: MEDIUM

Affected finding(s): PLAN F-005 (Z242–277); Skript L510, L548.

Problem: Der Plan fordert `gzip -t` + „Mindestgröße (> leer-Archiv, z. B.
> 1 KiB oder > 50 % der letzten Größe – großen Wert vermeiden, klein und robust
wählen)". Beide Schwellwerte sind geraten: Ein frischer `pg_dump` (leere
Coder-DB) gzipped liegt bei ~1–2 KiB – `> 1 KiB` scheitert auf Neuinstallation
(False-Positive) oder lässt leere Dumps durch (False-Negative je nach
Exaktheit). `> 50 % der letzten Größe` scheitert nach legitimer Verkleinerung
(Workspaces/Projekte gelöscht, Vacuum) und verlangt „letzte Größe" als
vertrauenswürdigen Zustand, den es ohne Verifikation (Henne-Ei) nicht gibt.
`gzip -t` prüft nur gzip-Integrität, nicht SQL-Gültigkeit (`pg_dump` kann
Fehlermeldungen in stdout mischen; leeres stdin ergibt „gültiges" kleines
Archiv – 05/F-003 belegt). ENOSPC während Temp-Schreiben: Plan sagt „Temp
löschen, Exit ≠ 0" – unter ENOSPC kann selbst Löschen/Logging scheitern; kein
`df`-Vorabcheck (P-007), keine Reservierung.

Why the plan may be wrong: Der Plan ist hier ehrlich („klein und robust"),
aber Robustheit kommt nicht aus kleinen Konstanten, sondern aus
Test-Restore. Wöchentlicher Test-Restore als „Runbook-Pflicht" (unautomatisiert)
wird im Schulbetrieb verrotten – exakt die „stille Defekt"-Klasse aus 05/F-007,
die der Plan an anderer Stelle beklagt.

Evidence:
- L510 `pg_dump | gzip > finaler Name` per Lesung nicht-atomar, ohne Prüfung;
  L548 nur Existenzprüfung. `gzip -t`/Größenprüfung per grep abwesend
  (verifiziert 26.09.2026, plausibel).
- 05/F-003 belegt leeres-stdin-Artefakt; AGENTS.md verlangt Restore-Tests.

Potential regression: Zu strikte Schwellwerte lassen legitime Backups
scheitern (nächtlicher Cron rot statt grün, Operator lernt Warnungen zu
ignorieren); zu lockere lassen korrupte durch – beides schlechter als heute,
wenn Schwellwert ohne Messung gewählt wird.

Required correction: F-005 härten: Temp gleiche Partition + `mv`; `gzip -t`
als notwendige, nicht hinreichende Prüfung deklarieren; Größenprüfung nur als
Plausibilität (z. B. `> 0` + Warnung bei `< 50 %`, kein harter Fail ohne
Restore-Beweis); periodischer Test-Restore automatisieren oder als
`check.sh`-Pflicht mit `logger` (nicht nur Runbook-Satz); ENOSPC via
`df`-Vorabcheck (P-007) abfangen, partielle Temp-Datei immer entfernen.

Required test: Fake-`pg_dump` bricht nach N Bytes ab → keine Datei unter
finalem Namen; leeres stdin → Warnung (nicht still OK); gültiger Dump →
`gzip -t` Exit 0; Verkleinerungs-Szenario (halbe DB) → kein harter Fail.

Classification: LIKELY

---

## P-014 – F-002-Offsite als „Hook mit leerem Default" ist kein Fix, sondern dokumentiertes Weiter-so

Severity: HIGH

Affected finding(s): PLAN F-002 (Z124–163); Skript L128–129, L507–511 (nur lokal).

Problem: Der Plan will „nach erfolgreichem lokalem Backup (F-005-Gate) einen
konfigurierbaren Copy-Hook (`OFFSITE_DEST`, leer = nur dokumentiert überspringen
mit Warnung) aufrufen". Mit leerem Default ändert sich operativ nichts:
Quelle und Ziel teilen weiter das Fehlerszenario Platte/Host; Plattenverlust =
DB + alle Backups weg. Die Warnung versandet (kein Alerting, P-007). Dependency
D6 (Ziel, Verschlüsselung, Schlüsselverwahrung) existiert im lesbaren Teil
nicht – F-002 hängt an einem Phantom. Hook-Semantik (wo aufgerufen: in
`backup.sh` unter `set -e`? Dann markiert Transportfehler das lokale Backup als
fehlgeschlagen; außerhalb? Dann wer ruft wann?) ist unspezifiziert.
Transport-Secrets (SSH-Key, S3-Token) als neue Exfiltrationsfläche: kein Wort
zu Rechten/Trennung („Getrennt vom lokalen Backup einführen" ist Absicht, kein
Mechanismus).

Why the plan may be wrong: Der Plan erklärt F-002 selbst zu CRITICAL („Alle
anderen Backup-Verbesserungen sind nachrangig") und liefert dann einen
No-Op-Default. Das ist Prioritätsinversion per Konfiguration: Das Wichtigste
wird als einziges opt-in. „Warnung statt Fehlschlag" wiederholt den
SSH-Fehlertyp (P-003) im Backup-Pfad.

Evidence:
- Einziger Schreibpfad `${BACKUP_DIR}` unter `/opt` (Lesung); kein
  rsync/scp/rclone im Skript (grep-verifiziert).
- F-002-Dependencies „D6, F-005" – D6 im lesbaren Teil abwesend; F-005-Gate
  selbst unfertig (P-013).

Potential regression: Mittel – falsch konfigurierter Transport exponiert
Secrets (Backup enthält Voll-DB inkl. Token-Hashes, 02/F-016); Hook-Fehler
unter `set -e` korrumpiert Backup-Status; unverschlüsseltes Offsite schafft
zweite, schlechtere Kopie.

Required correction: F-002 zu echtem Finding machen: Offsite-Pflicht mit
Eigentümer/Frist (D6 ausformulieren: wohin, womit verschlüsselt, Schlüssel bei
wem, getrennt vom Host); Hook außerhalb des lokalen Erfolgs (Transportfehler ≠
lokaler Fehler, getrennte Exit-Codes/Logs); Default leer nur mit Verfallsdatum
(z. B. Warnung + Ticket, kein Dauerzustand); Retention für Offsite definieren.

Required test: Test-VM-Snapshot verwerfen → außerhalb der VM liegt lesbare,
aktuelle, entschlüsselbare Sicherung; Restore daraus nach F-003-Runbook mit
gestoppter RTO. Transportfehler simulieren → lokales Backup weiter grün,
Transport rot (getrennt sichtbar).

Classification: CONFIRMED (Lokal-only per Lesung); LIKELY (Transport-Risiken
ohne Zielsystem – Mechanik aus 02/F-016 belegt).

---

## P-015 – F-003-Restore als reine Doku: ohne Skript, ohne `.env`, mit Phantom-Dependencies

Severity: HIGH

Affected finding(s): PLAN F-003 (Z165–200); Skript: kein restore/pfad (grep
`restore|pg_restore` nur Reset-Kommentar L689–704 + `ALTER USER`-psql L649).

Problem: Der Plan will `RESTORE.md` (Voraussetzungen, Schrittfolge, Umgang mit
Leer-Schema/Migrationen, Login-Verifikation, RTO-Protokoll). Das ist Richtung,
kein Verfahren: Reihenfolge `.env` vs. Stack vs. Dump bei abweichendem Passwort,
exakter `psql`-Befehl, Zertifikats-/Workspace-Reste, Coder-Migrationen bleiben
Handarbeit unter Druck – RTO unbekannt/maximal. Dependencies „F-005, F-021,
D6, D8-anteilig": F-021 und D6/D8 existieren im lesbaren Teil nicht (dangling).
Der Plan verlangt damit Restore aus Offsite (F-002, leerer Default) + `.env`
(F-021, Phantom) + RTO-Ziel (D8, Phantom) – ein Haus aus Phantomen.

Why the plan may be wrong: „Kein neues Produktiv-Feature, nur Doku + Test-VM"
unterschätzt, dass Doku ohne Automatisierung beim ersten Stress (nachts,
Semesterende) improvisiert wird. 05/F-008–F-010 zeigen: Dump + neue `.env`
(Reset würfelt neu, L754–755 `rm -f .env`) + bereits angelegtes Leer-Schema +
Migrationen = Puzzle, kein Lauf. Einmaliges Durchspielen ohne Regressionsschutz
(Test verrottet, Coder-Version driftet) ist Dekoration mit Protokoll.

Evidence:
- Restore-Abwesenheit per Lesung+grep (CONFIRMED in 01/05/06).
- F-003-Dependencies im Plan wörtlich: „F-005, F-021, D6, D8-anteilig" – F-021+
  D-Teil im lesbaren Teil abwesend (grep `^## (F-021|D)` leer).

Potential regression: Keins durch Doku allein – aber falsches Vertrauen
(„Runbook existiert" ohne `.env`/Offsite/Workspace-Abdeckung) verzögert echte
Fixes (P-014, P-024).

Required correction: F-003 erweitern: Runbook + minimaler `restore.sh`-Pfad
(Dump einspielen, Passwort-Abgleich, Coder-Stopp/Start, Login-Check) oder
ehrlich als „manuell, aber geprobt" mit Checkliste (Dump + `.env`-Ersatz +
Offsite-Zugang als Eingangs-Gates, harter Abbruch bei Fehlen); RTO messen und
als Zahl ins Repo (nicht „gemessen", sondern Zahl + Datum + Version);
Wiederholungsplan (bei jedem Major-Update erneut proben). Dependencies auf
existierende Findings umschreiben oder D/F nachliefern (P-021).

Required test: Isolierte Test-VM: Stack hoch, Testdaten, Backup, VM verwerfen,
nur aus Offsite + Runbook wiederherstellen, Zeit stoppen (= RTO), Coder-Login
prüfen. Nie Produktion. Wiederholung bei Coder-Major.

Classification: CONFIRMED

---

## P-016 – F-004-Volume-Fix richtig, aber Ableitung vage, Leer-Fall destruktiv, Zertifikats-Seite blind

Severity: HIGH

Affected finding(s): PLAN F-004 (Z202–240); Skript L747–752 (eingebettetes reset-coder.sh).

Problem: Der Befund ist korrekt (Filter nur `volume=<name>`, generische Namen,
quotierter Mehrzeilen-String = ein Argument → `set -e`-Abbruch nach
`compose down`/Teil-Löschung; Mechanik 26.09.2026 reproduziert). Der Fix
(„Filter um `project=coder` einschränken, falls Projektname abweicht aus
`docker compose config` ableiten, zeilenweise löschen, Allowlist") ist Richtung,
aber: (1) „aus config ableiten statt raten" ohne Befehl (welches Feld?
`name:` oben? Label am Volume? `docker compose config --format json` + jq?
jq vorhanden?). (2) Leer-Fall (kein Treffer wegen Label-Mismatch, z. B. nach
`COMPOSE_PROJECT_NAME`-Lauf): Schleife löscht nichts, Skript löscht trotzdem
`.env` (L755) → alte Volumes verwaist (Plattenleck), neue Volumes leer, Backup
+ alte Daten entkoppelt – halb-Reset ohne Fehlermeldung. (3) `caddy_data`/
`caddy_config` bleiben bewusst (Rate-Limit-Schutz L694–697) – bei Serververlust
nie gesichert (P-024); Reset schützt Zertifikate, Totalverlust vernichtet sie –
Plan adressiert nur eine Seite.

Why the plan may be wrong: K2 stuft 05-CRITICAL auf HIGH herunter („heute kein
zweites Compose-Projekt, Annahme plausibel"). Das ist Wette auf Zukunft auf
einem Host, dessen Zweck (Unterricht) Erweiterung geradezu einlädt. Der
wahrscheinlichere Schaden ist ohnehin nicht Fremd-Löschung, sondern
Abbruch-nach-Teillöschung (deterministisch bei zwei Treffern) – der Plan nennt
ihn, testet ihn aber nur als Trockenlauf, nicht als echten Abbruch mit
`.env`-Zustand.

Evidence:
- L747–752 Filterzeile + `docker volume rm "${VOL_NAME}"` per Lesung;
  Quoting-Mechanik reproduziert (01/F-004).
- L741 `docker compose down --remove-orphans`, L755 `rm -f .env` – Reihenfolge
  down → rm volumes → rm .env per Lesung.
- Projektname = Verzeichnisname (`/opt/coder`) ist Compose-Default, aber per
  `-p`/Env überstimmbar – im Skript nirgends fixiert.

Potential regression: Gering im Normalfall (ein Treffer) – aber schärferer
Filter ohne Leer-Guard verwandelt „falsch löschen" in „still nichts löschen +
trotzdem `.env` weg" (schlechterer Folgezustand: weder alt noch neu lauffähig).

Required correction: F-004 härten: Projektname determinieren (ein Befehl,
z. B. `docker compose config --format json | jq -r .name` mit Fallback +
Fail bei Unklarheit, kein Raten); Treffer vor Löschen anzeigen (Namen +
Größe); zeilenweise (`while IFS= read -r`); Allowlist der drei logischen Namen
als Guard; Leer-Fall = harter Abbruch vor `.env`-Löschung (kein stiller
Weiterlauf); Fremd-Volume-Fall = Abbruch statt Teil-Löschung.

Required test: Test-VM: zwei Volumes gleiches `volume`-Label, verschiedene
`project`-Labels → nur `project=coder` angezeigt/gelöscht; Mehrzeilen-Fall →
kein Abbruch; Leer-Fall (falscher Projektname) → Abbruch vor `rm .env`,
Stack weiter lauffähig.

Classification: CONFIRMED

---

## P-017 – F-009 lässt PATH-Lücke offen, `flock`-Semantik und Cron-Annahmen ungeprüft

Severity: MEDIUM

Affected finding(s): PLAN F-009 (Z386–425); Skript L507, L510, L530–534, Paketlisten L104/L115/L359/L466.

Problem: Der Befund nennt drei Teilprobleme: (a) kein `cron`-Paket, (b) kein
`flock`, (c) Cron-PATH minimal mit bloßen `docker`/`gzip`-Aufrufen „ungeprüft
vorausgesetzt". Der Fix (Paket + enablen + Check, `flock -n`, Sekunden) behebt
(a)+(b), aber (c) überhaupt nicht: `backup.sh` nutzt weiter bare `docker`,
`gzip`, `date` ohne absolute Pfade. Auf Minimal-Images oder nach
`PATH`-Änderung läuft das Backup weiter still nie – mit grünem Setup (`[OK]`
L534). Zusätzlich: `flock -n` ohne Exit-Semantik (zweiter Lauf exitt ≠ 0 →
Cron-Log-Spam oder stiller Skip ohne `logger`?), Lock-File
`/opt/coder/backups/.lock` im 700-Verzeichnis (als Root ok, aber nie
dokumentiert/rotiert); `cron`-Paketname auf trixie (`cron` vs. `cron-daemon-
common`?) und Service-Name (`cron.service` vs. `cron`?) ungeprüft; Sekunden-
Timestamp bricht Sortierungsannahmen alter Tooling (`ls -t` vs. Name)?

Why the plan may be wrong: „Kein systemd-Timer-Wechsel (überdimensioniert)"
ist richtig, aber „PATH ungeprüft" als Befund ohne Fix ist unvollständig.
Der Test („zwei parallele Läufe, beide `gzip -t`-gültig") widerspricht
`flock -n` (zweiter bricht ab – dann gibt es keine zweite gültige Datei, sondern
einen sauberen Abort; was ist Soll-Exit-Code?).

Evidence:
- Cron-Zeile L531 per Lesung ohne `flock`; Timestamp L507 ohne Sekunden;
  Paketlisten ohne `cron` (Lesung); Abschlusscheck ohne Cron-Prüfung (L781–815
  prüfen Container/ufw/fail2ban/DNS, nie cron).
- 05/F-006 belegt PATH-Fragilität (`/usr/bin/docker` üblich, aber
  vorausgesetzt).

Potential regression: Gering – Paketinstallation + Lock + Namensformat; aber
`flock -n` ohne saubere Abort-Meldung trainiert „Cron-Fehler ignorieren".

Required correction: F-009 vervollständigen: absolute Pfade (`/usr/bin/docker`,
oder `PATH`-Export in Cron-Zeile/`backup.sh` + Verifikation), `flock -n` mit
definiertem Abort (Exit-Code + `logger`-Zeile „übersprungen, Vorgänger läuft",
kein Fail-Alarm), Paket+Service-Name für trixie verifizieren
(`apt-cache policy cron`, `systemctl cat cron`), Abschlusscheck
(`systemctl is-active cron` + Datei vorhanden). Rotation-Glob
(`coder_*.sql.gz`) gegen Sekunden-Format regressionstesten.

Required test: Frische Minimal-Test-VM: nach Setup `systemctl is-active cron`
aktiv; zwei parallele Läufe → zweiter Abort mit klarer Meldung, erste Datei
`gzip -t`-gültig, keine trunkierte Zweitdatei; Cron-Env-Test (minimales PATH)
→ Backup grün.

Classification: CONFIRMED

---

## P-018 – F-010-Reihenfolge („DB zuerst ist richtig") falsch begründet, `.bak`-Halden, Grafana-Lücke

Severity: MEDIUM

Affected finding(s): PLAN F-010 (Z427–460); Skript L647–669 (`ALTER USER` L649 → Grafana L657 → `sed -i` L662–663 → Recreate L669).

Problem: Der Plan behält „DB→`.env`" bei („DB zuerst ist richtig, nur
absichern") – ohne Beweis. Umgekehrt (`.env` zuerst per Temp+`mv`, dann DB,
dann Verifikation, dann Recreate) wäre wiederholbar: Abbruch nach `.env`-
Tausch, vor DB-Änderung → Re-Run heilt (DB noch alt, `.env` neu → Retry setzt
DB neu). DB-zuerst → Abbruch hinterlässt DB=neu/`.env`=alt, jeder spätere
`compose up` (Reboot!) startet Coder falsch – verzögerter Lockout ohne
Erkennung. Der Plan sichert nur per `.env.bak.<ts>` + Trap-Warnung, repariert
aber nicht. Zusätzlich: `.bak.<ts>` ohne Rotation/Cleanup = wachsende
Secret-Halde (jedes Backup enthält Voll-Passwörter, 600, aber ewig);
Grafana-Reset (L657) zwischen PG und `.env` mit eigenem Abbruchfenster (DB neu,
Grafana alt/neu, `.env` alt) – Trap-Text nennt nur DB; kein Vorab-Backup
(DB-Dump) vor Rotation – bei Verlust des neuen Passworts (Scroll, Terminal)
hilft `.bak` (altes Passwort) nicht, weil DB bereits neu ist.

Why the plan may be wrong: 01/F-005 schlug „`.env` möglichst unmittelbar vor
`ALTER USER`" vor (umgekehrte Reihenfolge); der Plan verwirft das kommentarlos
zugunsten Status-quo. Das ist kein Fix, sondern Absicherung eines
fehleranfälligen Ablaufs. „Trap mit Warnung" ist ehrlich, aber Warnung ≠
Transaktion.

Evidence:
- Reihenfolge L647–669 per Lesung; kein Backup-Aufruf im Skript (grep).
- 01/F-005 vs. PLAN-F-010: Reihenfolge-Entscheidung ohne Begründung geändert.

Potential regression: Gering im Erfolgsfall – aber `.bak`-Halden erweitern
Secret-Fläche (02/F-015); Trap ohne Auto-Repair lässt Vertretung nachts mit
Warnung allein.

Required correction: F-010 umstellen: `.env`-Tausch zuerst (atomar Temp+`mv`,
mit `.bak` genau einer Generation + Cleanup alter `.bak`, 600), dann
`ALTER USER` + Grafana-Reset, dann Verifikation (DB-Login mit neu, Coder-Recreate,
Login-Probe), dann erst Erfolgsmeldung mit neuen Passwörtern; Trap für beide
Fenster (vor/nach DB) mit konkreter Reparaturanleitung (welches Passwort gilt
wo, wie synchronisieren). Vorab DB-Dump (verifiziert nach F-005) als
Rollback-Basis.

Required test: Test-Postgres: `sleep 5` vor `sed`/`ALTER` je Variante, per
SIGTERM abbrechen → Warnung + `.bak` + Anleitung; danach Re-Run muss heilen
(nicht doppelt würfeln); beide Passwort-Seiten (DB vs. `.env` vs. Grafana)
vergleichbar.

Classification: LIKELY

---

## P-019 – F-011-Workspace-Inventar nicht implementierbar, `--force` bleibt, nicht-interaktiv ungeregelt

Severity: MEDIUM

Affected finding(s): PLAN F-011 (Z462–499); Skript L723–768 (Confirm L723 → Backup L730 → `--force` L731–737, Hinweis L762–766).

Problem: Der Plan will „`docker ps`-Inventar aller Nicht-Compose-Container
anzeigen und bei laufenden Workspaces abbrechen". Woran erkennt das Skript
Workspaces? Coder-Labels für Workspace-Container stehen nirgends im Repo
(Templates nicht im Repo – derselbe Grund, mit dem der Plan 02/F-002 verwarf).
`docker ps` zeigt alles (Build-Cache, Test-Container, fremde Stacks) – der
Operator kann Workspaces von Rest nicht unterscheiden; „abbrechen oder explizit
behandeln" ohne Label-Spec ist Handwedeln. Weiter: Bestätigung erst nach Backup
ist richtig, aber `--force` bleibt als „Weiter trotz bekanntem
Backup-Fehlschlag" mit nur Zweitbestätigung – AGENTS.md-Produktionsschutz
(keine Destruktion ohne explizite Anforderung) wird per Flag umgangen, nicht
per Break-Glass-Freigabe (02/F-017, 06/D10). Nicht-interaktives
`echo RESET | reset-coder.sh` / CI-Pipe umgeht jede Bestätigung – kein Guard
(`[ -t 0 ]`-Check, `--yes`-Pflicht).

Why the plan may be wrong: Dialog-Reihenfolge fixen ohne Identifikations-
Grundlage verschiebt das Problem von „zu spät gewarnt" zu „falsch gewarnt"
(False-Positive-Abbruch bei harmlosen Containern, False-Negative bei
gestoppten-but-volumes Workspaces). Zweitbestätigung mit Backup-Status hängt an
F-005-Verifikation (wöchentlich, nicht per-Reset) – Statusanzeige ohne frische
Verifikation ist Theater.

Evidence:
- Ablauf L723→L730→L731 per Lesung; Hinweis L762–766 nach Löschung per Lesung.
- Kein Workspace-Label, kein `docker ps --filter label=...` im Skript (grep);
  06/F-005 bestätigt Workspaces außerhalb Compose ohne sichtbare Policy.

Potential regression: Gering (Dialog + lesende Inventur) – aber strenger
Abbruch bei jedem Fremd-Container blockiert legitime Resets (Test-Container
nebenbei) ohne `--force`-Druck (dann wieder uninformiert).

Required correction: F-011 konkretisieren: Workspace-Erkennung per
Coder-Label recherchieren (welches Label setzt Coder v2.36.6 auf
Workspace-Container? `coder.*`? – in Test-VM verifizieren, dann erst filtern;
bis dahin ehrlich „alle Nicht-Compose-Container" + Namen anzeigen, kein
Auto-Urteil); gestoppte Workspace-Container/Volumes mit einbeziehen
(`docker ps -a` + Volume-Liste); `--force` an Break-Glass-Freigabe binden
(wer darf, mit Zweitbestätigung + Backup-Alter/Größe/`gzip -t`-Frischcheck,
nicht Wochenwert); nicht-interaktiv ohne explizites Flag verweigern.

Required test: Test-VM: Backup-Fehlschlag (Postgres gestoppt) → ohne `--force`
Abbruch ohne Löschung; mit `--force` Zweitbestätigung mit frischem
Backup-Status; Dummy-Container außerhalb Compose → vorher angezeigt (mit Label,
sobald bekannt); Pipe ohne TTY → Verweigerung ohne Flag.

Classification: CONFIRMED (Ablauf); ASSUMPTION (Label-Spec – erst in Test-VM zu
verifizieren, deshalb darf der Plan sie nicht voraussetzen).

---

## P-020 – F-012-Gate kommt zu spät, `prune -f` bleibt destruktiv, DB/App-Kopplung bleibt (K5-Fehlentscheidung)

Severity: HIGH

Affected finding(s): PLAN F-012 (Z501–544, abgebrochen), K5; Skript L561–588 (`pull` L569 → `up -d` L570 → `prune -f` L580), Kopf L46–53 (Pins).

Problem: Drei Teilprobleme, ein halber Fix: (a) Health-Gate nach `up -d`
erkennt Fehl-Update, verhindert es nicht – bei Coder-Schema-Migration ist das
Schema beim Gate bereits migriert, Downgrade (altes Image) startet nicht mehr
(05/F-010, als „unbestätigt für v2.36.6" ehrlich markiert – Plan übernimmt die
Unsicherheit als Doku-Satz, nicht als Guard). (b) Prune-Kommentar wird „präzisiert"
(Rollback nur für exakt Gepinnte, Caddy/Postgres brauchen Re-Pull) – der
destruktive Befehl (`prune -f` direkt nach `pull` bei beweglichen Tags
`caddy:2.10`/`postgres:15-alpine`) bleibt. Altes Caddy-/Postgres-Image wird
dangling und sofort gelöscht – exakt das als verhindert beschriebene Szenario
(03/F-001 CONFIRMED). Doku, die Zerstörung beschreibt, ist keine Korrektur.
(c) Ein `pull` zieht DB- und App-Images gemeinsam; K5 lehnt `app`/`db`-Trennung
als „Verhaltens-Refactoring mit neuem Bedienvertrag" ab. Damit bleibt der
Aufschub-Effekt (06/F-004): Aus Angst vor DB-Major wird kein Coder-Patch
eingespielt – über Jahre.

Why the plan may be wrong: „Minimal-Fix jetzt (F-012), Aufspaltung Non-Goal bis
D7" (K5) verwechselt Bedienkomfort mit Risiko: `update.sh app` (nur Coder/Caddy
+ Gate) vs. `db` (nur Postgres mit Dump+Migrations-Vorbehalt) ist kein
„neuer Vertrag", sondern Trennung von Risiko-Klassen – Default `app` mit Hinweis
ist abwärtskompatibel (06/F-004 zeigt wie). Health-Gate ohne DB-Guard ist
Brandmelder nach Brandstiftung.

Evidence:
- `update.sh`-Volltext per Lesung (kein Gate, kein Guard); bewegliche Tags aus
  Skriptkopf L46–53; Prune-Mechanik (Tag-Wechsel → dangling → `prune -f` löscht)
  aus Docker-Doku + 03/F-001 CONFIRMED.
- F-012-Test im Plan selbst abgebrochen („Soll nach Dok …[truncated]") –
  Abnahmekriterium unlesbar.

Potential regression: Gering für Gate allein (nur Prüfung); mittel für Prune-
Änderung (`until=24h`-Filter behält alte Images – Platte, siehe P-007);
gering für app/db-Trennung (nur Aufruftrennung + Gate, Default `app`).

Required correction: F-012 erweitern: Gate (Container gesund + `/healthz` 200
innert Timeout, Exit ≠ 0) + Prune-Guard (`until`-Filter oder Prune nur nach
grünem Gate, nie davor) + DB-Trennung (`pull`/`up` pro Risikoklasse, Major-DB
nur mit verifiziertem Dump + Versionsnotiz + Downgrade-Warnung). Kommentar
allein genügt nicht – Befehl ändern oder ehrlich als „bekannt destruktiv"
mit Freigabe versehen.

Required test: Test-VM falsche `CODER_VERSION` → Skript failt selbst (nicht
still grün); `CADDY_VERSION` zweimal reale Tags → altes Image nach `prune`
noch da (je nach Guard) oder begründet weg mit Re-Pull-Nachweis; DB-Major in
Test-VM inkl. dokumentiertem Rollback (geht oder begründet nicht).

Classification: CONFIRMED (Gate-Lücke, Prune-Mechanik); LIKELY
(Migrations-Irreversibilität, Upstream-abhängig – als Vorbehalt richtig, als
Doku-Ersatz falsch).

---

## P-021 – Dangling References: F-019/F-021/D4–D9 werden versprochen, existieren nicht

Severity: HIGH

Affected finding(s): PLAN „Verworfene Befunde" (F-019-Testschritt), F-003 (F-021, D6, D8), K1 (D4), K5 (D7), K7 (D7), K8 (D5), F-009↔F-005-Kette.

Problem: Der lesbare Plan referenziert mindestens: F-019 (Template-Allowlist-
Testschritt als Ersatz für verworfene 02/F-002/F-004), F-021 (`.env`/Configs
als F-003-Dependency), D4 (Digest vs. Patchversorgung), D5 (TLS-Modell), D6
(Offsite/Schlüssel), D7 (Update-Modell/Docker-Origin/app-db), D8 (RTO/Messung),
D9 (IPv6/DNS-Testschritte). Keine dieser Nummern löst im lesbaren Teil auf
(keine `## F-019`-, `## F-021`-, `## D`-Überschrift; `grep` leer). Dependencies
wie „F-005 (nur gültige Dateien zählen)", „D6 (Ziel/Verschlüsselung)" sind
damit unprüfbar – der Plan ist intern inkonsistent, unabhängig von P-001.

Why the plan may be wrong: Entweder standen die Referenzen im abgeschnittenen
Teil (dann ist P-001 der Root-Cause und jede Freigabe blockiert) oder sie
wurden nie geschrieben (dann sind Verwerfungen („ersetzt durch F-019") und
Dependencies („hängt von D6 ab") leere Beruhigung). Beide Fälle verbieten
Implementierung: „Hängt von D6 ab" ohne D6 heißt „wartet auf Gott".

Evidence:
- Z78: „Ersetzt durch prüfbare Template-Allowlist (F-019-Testschritt)" –
  `grep "^## F-019"` leer.
- Z193: „Dependencies: F-005, F-021, D6, D8-anteilig" – F-021/D6/D8 im
  lesbaren Teil abwesend.
- K1/K5/K7/K8 verweisen auf D4/D5/D7 – kein D-Kapitel im lesbaren Teil.

Potential regression: Implementierer baut F-005-Rotation mit „nur gültige
zählen" ohne Definition von „gültig" (P-013), Offsite-Hook wartet auf D6 ohne
Eigentümer (P-014), Restore wartet auf F-021/D8 (P-015) – alles blockiert
still oder wird geraten.

Required correction: Referenzen auflösen oder streichen: entweder fehlende
Findings/Entscheidungen nachliefern (mit Eigentümer/Frist pro D) oder
Dependencies auf existierende Findings umschreiben und Verwerfungen ehrlich als
„entfallen ohne Ersatz" kennzeichnen (mit Risiko-Akzeptanz durch Menschen, nicht
durch Phantom-Nummer).

Required test: Referenz-Check per Skript: jede `F-[0-9]+`-/`D[0-9]`-Erwähnung
muss auf Überschrift auflösen; CI/Review-Gate rot bei Dangling.

Classification: CONFIRMED

---

## P-022 – Verifikation unbelegbar: `tests/` leer, TEST_PLAN.md leer, „Reproduktion 26.09.2026" ohne Artefakt

Severity: HIGH

Affected finding(s): PLAN „Arbeitsweise" Z11–16 (bash -n, shellcheck, grep-Abwesenheit, Pipefail-Reproduktion); alle F-xxx-Tests.

Problem: Der Plan behauptet Prüfung („Lesung + gezielte Reproduktion:
Pipefail-Mechanik, bash -n, shellcheck, grep-Abwesenheit für flock, logrotate,
Origins-Pattern, restore, mem_limit, retention.size"). Im Repo liegt davon
nichts: `tests/` ist leer (06 bestätigt), `TEST_PLAN.md` 0 Bytes, keine
Repro-Skripte, keine Logs, keine Commit-Hashes der Tool-Läufe. AGENTS.md
verlangt: „Never claim a test passed unless it was actually executed" und
bevorzugt ShellCheck/Compose-Validierung/isolierte VM/Idempotenz-/Restore-Tests
– null davon im Repo umgesetzt. Jede F-xxx-„Evidence" ist damit Behauptung,
jeder „Test:"-Abschnitt Zukunftsmusik ohne Harness.

Why the plan may be wrong: Der Plan übernimmt die Stärken der Einzelreviews
(reproduzierte Pipefail-/Quoting-Mechanik in 01, grep-Nachweise in 05) als
eigene Leistung, ohne deren Artefakte zu sichern. „ShellCheck bestätigt nur
drei Meldungen" (Verworfen-Tabelle) ohne Log/Datum/Version im Repo ist nicht
prüfbar – und widerspricht 01/F-006 teilweise (dort SC1091/SC2034/SC2012 +
fehlender Newline; ob „kein funktionaler Fehler" stimmt, hängt vom Lauf ab).

Evidence:
- `ls tests/` leer; `TEST_PLAN.md` 0 Bytes (per `ls -la` + Byte-Lesung).
- 06/F-015 belegt leeres `tests/` als CONFIRMED; AGENTS.md-Testpräferenzen ohne
  Umsetzung.
- Einzige eingebaute Validierung im Skript: `compose config --quiet` L344 +
  Schritt-10-Laufzeitchecks – keine Vorab-Tests.

Potential regression: Ohne Harness wird jede Korrektur (Escaping-Migration bei
Template-Extraktion, `sed`-Refresh, Prune-Guard) „wahrscheinlich richtig" und
fällt erst auf Produktion auf – genau dort, wo AGENTS.md Destruktion verbietet.

Required correction: Minimale Testschicht vor Implementierung (kein VM-Zwang):
(1) shellcheck über Haupt- + extrahierte Heredoc-Skripte; (2) `compose config`
gegen generierte/geplante Datei; (3) Rotations-/Timestamp-Test gegen
Testverzeichnis; (4) Referenz-Check (P-021) + `bash -n`. Manuelle VM-Protokolle
(Reboot/Restore/Reset/Update-Gate) als versionierte Checklisten, nicht als
Sätze. Erst dann Fix-PRs.

Required test (Meta): Harnisch-Selbsttest – absichtlich fehlerhafte
Compose-Zeile + SC2034-Analogon → Lauf muss rot werden.

Classification: CONFIRMED

---

## P-023 – Fehlendes Netz/DNS/Platte/Teilfehler: Apt/Curl/Pull ohne Retry, Abbruch mitten im Lauf ungeplant

Severity: HIGH

Affected finding(s): Skript L103–115 (apt/docker-Repo), L106 (curl|gpg), L346
(pull/up), L803–815 (curl-Healthcheck als Warnung); AGENTS.md-Idempotenz
(Erst-/Zweit-/abgebrochener Lauf, Reboot, kein Netz, volle Platte).

Problem: Der Plan fixiert Crontab/`.env`/GID-Zweitläufe, aber nicht die
banalen Ausfallpfade: (a) `apt-get update/install`, `curl docker-gpg`,
`docker compose pull`, ACME-Issuance setzen Netz/DNS voraus – kein Retry,
kein Timeout (außer curl-Healthcheck 10 s), keine Prüfsumme außer implizitem
APT-Signieren. Teil-Download (abgebrochenes `apt update`, halbes Image) → Re-Run
läuft weiter, als wäre nichts (kein `apt`-Fehler-Gate mit klarer Meldung).
(b) Fehlendes DNS/fehlende Portweiterleitung: Stack startet, Caddy versucht im
Hintergrund, Schritt 10 warnt nur – Setup exitt 0 („Erfolg" ohne HTTPS). Das ist
per Design (Kommentar L22–26), aber Operator liest grün als fertig; Wildcard-
DNS (`*.DOMAIN` für Apps) separat ungeprüft. (c) Volle Platte während
apt/pull/dump (P-007): kein `df`-Gate, partielle Dateien, ENOSPC mitten in
`tee`/Herodoc-Generierung (P-010/P-011). (d) Abbruch mitten im Setup (SSH-Abbruch,
Reboot 03:00 während Lauf, Ctrl-C): halb geschriebene Compose/Caddy/Prometheus-
Dateien (direkt per `tee` ins Ziel, nicht atomar – gleicher Fehler wie `.env`,
aber ohne Finding!), halb installierte Pakete, `ufw --force enable` nach
Teil-Regeln, `restart fail2ban` verwirft Bans bei jedem Lauf.

Why the plan may be wrong: AGENTS.md verlangt Erst-/Zweit-/abgebrochenen/
teilfertigen Lauf + Reboot + kein Netz + volle Platte als Pflichtfälle. Der
Plan deckt 3 von ~10 ab (Crontab, `.env`-Existenz, GID) und nennt den Rest
„Non-Goals" oder gar nicht. „Einfach erneut laufen lassen" (L25) gilt für
halb generierte Configs genauso wenig wie für halb geschriebene `.env` – aber
nur `.env` bekommt ein Finding.

Evidence:
- L103 `apt-get update` ohne Retry/Check; L106 `curl … | gpg --dearmor` ohne
  Fingerprint (02/F-014 CONFIRMED, K1 übernimmt „nur billige Hälfte F-018" –
  F-018 im lesbaren Teil nicht existent); L346 `pull` ohne Retry; L352 blinder
  `restart caddy` bei jedem Lauf (TLS-Unterbrechung ohne Änderung).
- L304–320/Caddyfile + L788–815: curl-Healthcheck warnt, `ERROR_COUNT` zählt
  nur `fail`, nicht `warn` → Exit 0 ohne TLS.
- Schritt-2-Heredocs (L163–334) direkt per `tee` ins Ziel (nicht atomar, kein
  Hash-Vergleich) – Re-Run überschreibt Drift still.

Potential regression: Retry-Schleifen ohne Backoff hämmern (APT/LE-Rate-Limit);
atomare Config-Schreibung ohne Diff versteckt Drift weiter – deshalb Hash-
Vergleich (nur bei Änderung neu starten, 06/F-009) statt blindem Restart.

Required correction: Findings ergänzen (MEDIUM, nicht CRITICAL): apt/curl/pull
mit Retry (begrenzt, mit klarer Fehlermeldung statt Stillstand); GPG-
Fingerprint-Prüfung (K1-Versprechen einlösen, mit Rotation-Hinweis);
Config-Generierung atomar (Temp+`mv`) + Caddy nur bei Hash-Änderung restarten
(kein Blind-Restart); Schritt-10-Warnung mit Wiedervorlage (DNS/Wildcard separat
prüfen: `getent` + `curl` + Caddy-Log-Hinweis, kein grünes „fertig" ohne
HTTPS-Bestätigung); `df`-Mindestplatz vor apt/pull/dump.

Required test: Isolierte Test-VM je Pfad: Netz weg während apt/pull (Retry +
klarer Fail); DNS fehlt (Warnung + Exit 0, aber kein „Erfolg"-Missverständnis,
Re-Run nach DNS heilt ohne Abbruch); Platte voll während `tee`/dump (keine
partielle Finaldatei, klarer Fehler); Kill während Schritt 2 → Re-Run heilt
statt Drift zu zementieren; Re-Run ohne Config-Änderung → kein Caddy-Restart
(Startzeit unverändert).

Classification: CONFIRMED (Code-Fakten per Lesung); LIKELY (Häufigkeit –
abhängig von Schulnetz/Platte, Mechanik deterministisch).

---

## P-024 – Backup-Umfang unvollständig, Secrets falsch behandelt, Workspace-Daten ohne Konzept

Severity: HIGH

Affected finding(s): 05/F-001 (nur DB), F-009 (`.env` nie gesichert/beim Reset gelöscht), F-014 (Zertifikate/Dashboards/Historie nie gesichert), F-015 (Workspace-Nutzdaten gar nicht), 02/F-015/F-016 (Secrets in stdout/inspect, Backups unverschlüsselt) – PLAN: F-002/F-003 decken nur DB-Dump + Offsite-Hook ab, Rest ohne Finding im lesbaren Teil.

Problem: Gesichert wird nur `pg_dump` (L510). Nicht gesichert: `.env` (alle
Passwörter, L141–147), `docker-compose.yml`/`Caddyfile`/`prometheus.yml`
(werden generiert, aber Drift wird still überschrieben, P-023),
`/etc/cron.d/coder-backup`, UFW/fail2ban/unattended-Config, `caddy_data`/
`caddy_config` (alle On-Demand-Zertifikate), `grafana_data` (Dashboards),
`prometheus_data` (egal, 15 d), Workspace-Container/-Daten (die eigentlichen
Unterrichtsdaten – Dateien/Repos/Hausaufgaben leben außerhalb jedes Backups).
`.env` wird bei Reset gelöscht (L755) und neu gewürfelt – alter Dump passt ohne
Handarbeit nicht mehr. Backups liegen unverschlüsselt (`700`/`600` schützt vor
Welt, nicht vor Socket-Takeover P-002 oder falschem Offsite-Transport P-014).
Passwörter erscheinen im Klartext auf Terminal (L149–154, L671–676) und als
Container-Env (`CODER_PG_CONNECTION_URL` L193, `GF_...` L263 – per
`docker inspect` lesbar für jeden Docker-Admin).

Why the plan may be wrong: Der Plan nennt F-002/F-003 CRITICAL und hat recht –
aber „DB-Dump + Offsite-Hook + Runbook" ohne `.env`/Configs/Workspace-
Verantwortung beantwortet die „frische VM"-Frage weiter mit Nein (05,
„Entscheidende Frage"). Schlimmer: Der Plan wiederholt Secret-Fehler (`.bak`-
Halden P-018, Terminal-Ausgabe unangetastet, kein Rotations-Zwang nach
Offenlegung). Workspace-Strategie (Server-Backup vs. Git-Push-Pflicht, RPO für
Schülerarbeiten – 06/D5) existiert im lesbaren Teil nicht – der größte reale
Verlust (Semesterende, alle Arbeiten weg trotz „täglichem Backup") bleibt
konzeptionell leer.

Evidence:
- L510 einziger Sicherungsinhalt; `rm -f .env` L755; Compose-Volumes L275–280
  (5 Volumes, 1 gesichert); Terminal-Ausgabe L149–154/L671–676; Env-Secrets
  L193/L263; keine Verschlüsselung/Offsite im Skript (grep).
- 05/F-001/F-009/F-014/F-015 je CONFIRMED per Lesung; PLAN-Verworfen-Tabelle
  erklärt 02/F-005/F-015-Teile zu „kein Code-Defekt"/Non-Goal ohne Ersatz.

Potential regression: Mittel – `.env`-Sicherung (zusätzlicher Secret-Träger;
nur mit `umask 077`/600 + idealerweise verschlüsselt für Offsite, Schlüssel
getrennt vom Host, sonst neue Exfiltrationsfläche); Workspace-Backup berührt
laufende Container (Störungsrisiko – deshalb als Verantwortungsentscheidung,
nicht als Einzeiler).

Required correction: Findings (HIGH): Backup-Umfang definieren (DB-Dump +
`.env` verschlüsselt + Compose/Caddy/Prometheus-Config + Volume-Inventar) oder
explizit dokumentieren, dass nur DB gesichert wird und Rest per Re-Run neu
entsteht (mit Zertifikats-RTO-Hinweis: DNS/Ports/LE-Budget, 5–30 s Erstaufruf);
Zertifikate = rekonstruierbar (Voraussetzungen nennen), Grafana = als Code/Export,
Prometheus = verzichtbar deklarieren; Workspace-Verantwortung entscheiden
(Server-Backup vs. Nutzer-Export, RPO!); Secrets-Hygiene (keine Re-Ausgabe nach
Erstlauf, Rotation nach jeder Offenlegung, `.env` ins verschlüsselte Offsite).

Required test: Frische Test-VM nur aus Backup + Runbook (ohne Repo-Zugriff auf
`setup-coder.sh` für Config-Teil): was fehlt, wird protokolliert; Workspace-
Datei-Test (Datei anlegen → Backup+Restore → da? Soll derzeit: nein, Gap
dokumentiert); `docker inspect`/History/Journal auf Secret-Muster prüfen.

Classification: CONFIRMED

---

## P-025 – Zweitlauf-Nebenwirkungen ohne Finding: blinder Caddy-Restart, fail2ban-Restart, ufw-Enable

Severity: MEDIUM

Affected finding(s): Skript L352 (`restart caddy` immer), L397–398
(`systemctl enable+restart fail2ban` immer), L412 (`ufw --force enable` immer);
PLAN F-009/06-F-009 erwähnen Caddy-Restart nur als Nebensatz, kein Finding.

Problem: Jeder Re-Run (empfohlener Bedienweg nach DNS-Fertigstellung, L25–26)
startet Caddy neu – kurze TLS-Unterbrechung, auch wenn sich die Caddyfile gar
nicht geändert hat (Kommentar L348–352 begründet Restart mit Compose-
Blindheit gegenüber Datei-Inhalt, löst es aber mit immer-Restart statt
Hash-Vergleich). `systemctl restart fail2ban` bei jedem Lauf verwirft aktive
Bans (Angreifer entbannt per Re-Run – ironisch für ein Härtungsskript);
`ufw --force enable` bei jedem Lauf ohne Pre-Check (SSH-Regel vorher gesetzt?
L375 vor L412 ja, aber kein Guard gegen Hand-Drift). Paketinstallation
(`apt-get install -y` ohne Versions-Guard) bei jedem Lauf holt neue
Minor-Versionen (gewollt für Caddy/Postgres-Patches, ungewollt für
Docker-Major – P-008). Der Plan nennt das „idempotent" (Paketinstallation,
ufw-Regelsetzung, Cron-Datei), ohne Unterbrechungs-/Ban-/Versions-Seite.

Why the plan may be wrong: „Erfolgsfall unverändert" (Standard-
Regressionssatz fast aller F-xxx) stimmt für Blind-Restarts nicht: Erfolgsfall
mit Änderung ≠ Erfolgsfall ohne Änderung. 06/F-009 schlägt Hash-Vergleich vor –
der Plan übernimmt nur Crontab-`|| true`, nicht Caddy-nur-bei-Änderung. Das ist
Rosinenpicken aus eigenem Befund.

Evidence:
- L352 `sudo docker compose restart caddy` unbedingt; L397–398 enable+restart
  unbedingt; L412 enable unbedingt – je per Lesung.
- 06/F-009 listet alle vier Zweitlauf-Pfade (`.env`, GID, Crontab, Caddy-Restart);
  PLAN-F-006/F-007/F-001 übernehmen drei, Caddy-Restart entfällt kommentarlos.

Potential regression: Gering für Hash-Guard (nur Bedingungslogik); `reload`
statt `restart` (Caddy kann `caddy reload` ohne Downtime – aber Compose-`restart`
ist gewählt, Wechsel testen).

Required correction: Caddy nur bei Hash-Änderung (`sha256sum` vorher/nachher,
oder `compose up -d` ohne Force + gezielter `reload`); fail2ban `reload` statt
`restart` wo möglich (oder nur bei `jail.local`-Änderung restarten); ufw-Regeln
vor `enable` verifizieren (SSH-Limit vorhanden, sonst Fail statt Lockout).

Required test: Re-Run ohne Config-Änderung → kein Caddy-Restart (Startzeit
unverändert), Bans bleiben (`fail2ban-client status sshd` vorher/nachher);
Re-Run mit Caddyfile-Änderung → Reload/Restart + neue Config wirksam
(`caddy validate` + `/healthz`).

Classification: CONFIRMED

---

## Wo der Plan ausdrücklich korrekt ist (kein Widerspruch)

- **F-001 (Crontab-`|| true`):** Befund real, reproduziert, Richtung korrekt.
  Kritik (P-021-Testlücken, leerer Crontab-Fall) ändert nichts am Kern –
  der Fix gehört an erste Stelle (Abhängigkeit aller späteren Schritte stimmt).
- **F-004 (Volume-Filter):** Befund real (fehlende Projektbindung +
  Quoting-Mechanik reproduziert), `project=coder`-Einschränkung +
  zeilenweise Löschung + Anzeige richtig. Kritik betrifft nur
  Ableitungs-Befehl, Leer-Guard, Zertifikats-Gegenstück (P-016).
- **F-005 (atomar + `gzip -t`):** Temp gleiche Partition + `mv` + Löschen bei
  Fehlschlag richtig; Existenz ≠ Gültigkeit (AGENTS.md-Konformität) richtig.
  Kritik betrifft nur Schwellwert-Willkür und fehlende Automatisierung (P-013).
- **F-008 (Alter vs. Stückzahl):** Kommentar-vs-Code-Mismatch real, „im Zweifel
  behalten" + Mindestbestand richtig. Kritik betrifft nur Zählgrundlage
  („gültig" undefiniert, Platten-Seite P-007).
- **F-009 (cron + flock + Sekunden):** Paket-Verifikation + Lock + Sekunden
  richtig, systemd-Timer-Ablehnung (überdimensioniert) richtig. Kritik betrifft
  nur PATH-Lücke und Abort-Semantik (P-017).
- **F-012 (Health-Gate):** Gate nach `up -d` richtig und überfällig; Prune-
  Kommentar-Korrektur sachlich richtig (nur für exakt Gepinnte gilt Rollback).
  Kritik: Gate allein verhindert Migrationsschaden nicht, `prune -f` und
  DB-Kopplung bleiben (P-020).
- **Verworfen-Tabelle, soweit sie Stil entsorgt:** 01/F-006 (SC2034/SC2012/
  Newline), 01/F-008 (7× `ufw status`), 03/F-009 (`depends_on` ohne condition –
  selbstheilend), 03/F-010 (`stop_grace_period` – WAL-sicher, selten wirksam),
  04/F-005 (`PROXY_TRUSTED_ORIGINS` korrekt abwesend), 03/F-011 (trixie-Repo ok),
  03/F-012 (UFW-Kommentar korrekt) – jeweils korrekt verworfen bzw. bestätigt
  ohne Änderung. **Falsch** verworfen: 02/F-002/F-004 (Socket-Lateral als
  ASSUMPTION entsorgt statt Allowlist – P-002), 02/F-008/F-010/F-011/F-013
  (Firewall/TLS/Images als „kein Code-Defekt"/Phantom-D – P-004/P-005/P-008),
  03/F-004 (Logging als implizit enthalten? – fehlt, P-007), 04/F-002
  (Path-Apps kommentarlos entfallen – P-006).
- **K2 (HIGH statt CRITICAL für Volume-Filter):** Vertretbar – Fremd-Löschung
  heute unwahrscheinlich (Single-Host), Abbruch-nach-Teillöschung
  deterministisch. Kein Widerspruch (P-016 verschärft nur Leer-Fall).
- **K3-Einordnung als Tatsachen:** `pid: host` gesetzt, `processes`-Collector
  aus, Mounts ro, Ports loopback – sachlich richtig. Die Folgerung „LOW, reine
  Hygiene" ist dagegen zu mild (Angriffsfläche ohne Nutzen gehört entfernt oder
  begründet – 03/F-007 LIKELY, kein Plan-Finding); hier bleibt Kritik bestehen,
  aber Tatsachenbasis korrekt.

---

## Blocking Issues

Vor Implementierung zu beheben (Reihenfolge = Implementierungsvoraussetzung):

1. **P-001:** PLAN.md vervollständigen (F-013–F-026 oder ehrliche Kürzung auf
   F-001–F-012 + Zahlenkorrektur; F-012-Satz beenden; Trunkierungsmarker
   entfernen). Ohne lesbaren Plan keine Freigabe.
2. **P-021:** Alle Dangling References auflösen (F-019/F-021/D4–D9 entweder
   nachliefern mit Eigentümer/Frist oder streichen + Dependencies umschreiben).
   Betrifft F-002/F-003/K1/K5/K7/K8 direkt.
3. **P-002:** Docker-Socket-Finding (CRITICAL) wieder einführen (mindestens
   Template-Allowlist + Abnahme + Workspace-Selbsttest). Ohne das wird jede
   Backup-/Idempotenz-Arbeit auf kompromittierbarer Basis gebaut.
4. **P-010:** F-006-Fix korrigieren (`umask`-Irrtum raus, `install -m 600`/
   Temp+`mv`+`chown` rein). Sonst wird falsche Sicherheit implementiert.
5. **P-011:** F-006-„Neu erzeugen" entschärfen (abbrechen/reparieren + `.bak`,
   nie still neu würfeln). Sonst brickt der erste Teilfehler-Re-Run die DB-
   Anmeldung.
6. **P-007:** Full-Disk-Finding (Logging-Limits + retention.size + logrotate +
   df-Gate) einführen. Sonst tötet der wahrscheinlichste schleichende Ausfall
   jedes verifizierte Backup (ENOSPC während Temp-Schreiben).
7. **P-005 + P-006:** TLS-ask-Finding + `CODER_DISABLE_PATH_APPS`-Finding
   einführen (Kommentar + Inventar sofort, Modell-Entscheidung mit Frist).
   Sonst bleibt Fremd-DoS aufs LE-Budget + Cookie-Missbrauch über Path-Apps.
8. **P-003:** SSH-Finding mit vorbereitetem `ssh-harden.sh` + Key-Termin
   (Eigentümer/Datum). Sonst bleibt weltweites Passwort-Setup grün.
9. **P-022:** Minimale Testschicht + Referenz-Check vor Fix-PRs (shellcheck,
   compose-config, Rotations-Test, `bash -n`). Sonst ist jede Korrektur
   „wahrscheinlich richtig" und fällt auf Produktion auf.
10. **P-014 + P-015 + P-024:** Offsite (D6 mit Ziel/Schlüssel/Eigentümer),
    Restore-Runbook mit RTO-Zahl, Backup-Umfang (`.env` verschlüsselt,
    Configs, Workspace-Verantwortung mit RPO). Sonst bleibt „frische VM?"
    mit Nein beantwortet und jede Einzelverbesserung Dekoration.

---

## Non-Blocking Issues

Nach Blocking-Freigabe, vor oder parallel zu Fix-PRs zu klären:

- **P-008:** Docker-Engine-Update-Pfad (Origins-Pattern vs. Kalendertermin mit
  Eigentümer + Nachweis). Kein neues Feature, aber eine der beiden Optionen
  muss gelten.
- **P-009:** Boot-Gate + `stop_grace_period` + Coder-Healthcheck für Caddy.
  Nur lesend + Logging zuerst; Healthcheck-Kopplung in Test-VM verifizieren.
- **P-004:** Firewall-Bindungsregel + `DOCKER-USER`-Vorbereitung mit
  Dual-Stack-Test. Bindungsregel sofort (Disziplin), Kette nur mit Scan.
- **P-012/P-016/P-017/P-018/P-019/P-020/P-025:** Fix-Präzisierungen (GID-Guard +
  Diff-Recreate; Volume-Leer-Guard + Ableitungs-Befehl; PATH + flock-Abort;
  Passwort-Reihenfolge + `.bak`-Rotation; Workspace-Label-Recherche +
  TTY-Guard; Prune-Guard + app/db-Trennung; Caddy-nur-bei-Änderung +
  fail2ban-reload). Je einzeln geringes Risiko, als Einheit testen.
- **P-013:** Backup-Schwellwerte (Warnung statt Fail bei Größenabweichung,
  Test-Restore-Automatisierung statt Runbook-Satz).
- **P-023:** Netz/DNS/Teilfehler-Robustheit (Retry, Fingerprint, atomare
  Configs, Wildcard-DNS-Check, Wiedervorlage statt grün-ohne-HTTPS).
- `pid: host` ohne `processes`-Collector (03/F-007): entfernen oder Collector
  begründen – Hygiene, kein Blocker (Mounts bleiben lesend, Ports loopback).

---

## Missing Tests

Jeder Punkt braucht vor Merge einen ausführbaren Nachweis (isolierte Test-VM,
nie Produktion). Der Plan listet Tests als Sätze; folgende fehlen oder sind
unbrauchbar (abgebrochen/ohne Harness):

- Referenz-Check (P-021): Dangling-Finder über PLAN.md (jede `F-`/`D`-Nummer
  löst auf). Fehlt vollständig.
- Harness-Selbsttest (P-022): absichtlicher Compose-/ShellCheck-Fehler → rot.
  Fehlt (kein Harness).
- Crontab (F-001): nur Einzeiler-Fall spezifiziert; fehlen: leere Crontab,
  keine Crontab (`crontab -l` exitt 1), Mehrzeiler mit/ohne Treffer. Honoriert
  `|| true`-Platzierung beide?
- `.env` (F-006/P-010/P-011): fehlen: 644-Fenster-Nachweis durch sudo hindurch,
  Halbierungs-Test mit Reparatur-vs-Neuwürfel-Erwartung, `DOCKER_GID`-
  Nichtnumerik-Test.
- GID (F-007/P-012): fehlen: Leer-GID-Test (Abbruch ohne Änderung),
  Diff-vs-immer-Recreate-Test (Startzeit-Vergleich), Socket-Probe-
  Existenztest (Tool im Coder-Image vorhanden?).
- Backup (F-005/P-013): fehlen: Verkleinerungs-Szenario (halbe DB, kein Fail),
  ENOSPC-Test (tmpfs voll, keine Finaldatei), SQL-Gültigkeit über `gzip -t`
  hinaus (Mini-Restore statt nur `gzip -t`).
- Retention (F-008): fehlt: Zählgrundlage-Test („gültig" definiert? korrupte
  Datei mitgezählt?), Namens- vs. mtime-Sortierung, Lückenszenario mit
  Mindestbestand-Zahl.
- Cron (F-009/P-017): fehlen: Minimal-PATH-Test, `flock`-Abort-Exit-Code +
  `logger`-Erwartung, trixie-Paket-/Service-Name-Nachweis, Sekunden-Glob-
  Regression (`coder_*.sql.gz` greift weiter?).
- Passwörter (F-010/P-018): fehlen: Grafana-Fenster-Test, `.bak`-Rotations-
  Test (keine Halde), Re-Run-heilt-Test (kein Doppel-Würfeln).
- Reset (F-011/P-019, F-004/P-016): fehlen: Label-Recherche-Nachweis
  (welches Coder-Label? verifiziert oder „alle Fremd-Container"?), TTY-Pipe-
  Test, Leer-Volume-Test (Abbruch vor `rm .env`), gestoppte-Workspace-Test.
- Update (F-012/P-020): Testsatz abgebrochen („Soll nach Dok …"); fehlen:
  Falsch-Versions-Fail-Test (wer failt: `pull` oder Gate?), Caddy-Alt-Image-
  Nachweis vor/nach `prune` (mit Guard), DB-Major-Rollback-Probe (geht oder
  begründet nicht).
- Offsite/Restore (F-002/F-003/P-014/P-015): fehlen: Transportfehler-Trennungs-
  Test (lokal grün/Transport rot), Snapshot-verwerfen-Test mit RTO-Zahl,
  `.env`-Fehlt-Test (Dump + neue `.env` → Runbook heilt?), Workspace-Datei-
  Test (Soll: Gap dokumentiert).
- Security (P-002–P-006): fehlen vollständig: Workspace-Selbsttest (mount/
  Socket/`postgres:5432`/Fremd-Container), Template-Allowlist-Abhak-Test pro
  neuem Template, Path-App-Test (Pfad abgelehnt/Subdomain ok), SSH-vor/nach-
  Test (`sshd -T` + externer Login), TLS-Fake-Subdomain-Test (Caddy-Log
  `obtaining certificate` heute vs. Abweisung nach Fix).
- Platte/Reboot (P-007/P-009): fehlen: Log-Flut-Rotations-Test, TSDB-Grenz-
  Test (200 MB), `logrotate --debug`, tmpfs-voll-Backup-Test, Reboot-Boot-Log-
  Test (erste 2 Minuten `docker logs coder`).
- Zweitlauf (P-025): fehlt: Re-Run-ohne-Änderung-Test (kein Caddy-Restart,
  Bans bleiben), Re-Run-mit-Änderung-Test (Reload wirksam).

---

## Missing Decisions

Im lesbaren Teil referenziert, aber ohne Eigentümer/Optionen/Frist – keine
Implementierung darf sie implizit festlegen:

- **D-Offsite/Schlüssel (F-002/D6):** Wohin täglich (Medium/Konto)? Womit
  verschlüsselt? Schlüssel bei wem, getrennt vom Host? Retention offsite?
  Transport-Secrets wo (Rechte/Trennung)? Default-leer bis wann?
- **D-Restore/RPO/RTO (F-003/D8/D10-Analog):** RPO (wie alt darf Backup sein?),
  RTO (wie lange darf Recovery dauern – gemessene Zahl, nicht Zielsatz)? Wer
  darf `--force`/unwiderruflich löschen, mit welcher Freigabe? Wiederholungs-
  rhythmus für Restore-Proben (pro Major? pro Semester?)?
- **D-Socket/Provisioner (P-002/D1-Analog):** Single-Host+Socket mit Allowlist
  vs. separater Provisioning-Host vs. Socket-Proxy – wer trägt was über Jahre
  (Admin-Kapazität vs. Risiko)? Bis Entscheidung: Allowlist-Stufe sofort, Rest
  mit Frist.
- **D-TLS (K8/D5):** echter `ask` (wer baut/betreibt, Falsch-Negativ-Regel für
  neue Apps?) vs. DNS-01-Wildcard (Provider-Token bei wem? eigener Caddy-Build,
  Pflege?). Plus: CAA (`issue`/`issuewild` letsencrypt.org – wer setzt DNS?),
  IPv6/AAAA-Betriebs- vs. Abschalt-Pfad.
- **D-SSH (P-003):** Key-only-Termin (Datum)? Zweit-Zugang vorhanden (wer
  bestätigt)? Admin-Netz/VPN ja/nein (Schulnetz-Weiterleitung 22 bleibt?)?
- **D-Docker-Engine (K7/D7, P-008):** Origins-Automatik (mit Test-Reboot) vs.
  manueller Kalendertermin (wer, wann, Nachweis wo)? Docker-Major-Risiko
  akzeptiert von wem?
- **D-Update (K5, P-020):** app/db-Trennung ja/nein (Default `app`)? Prune-Guard
  (`until`-Fenster – wie lang, Plattenbudget)? DB-Major nur mit verifiziertem
  Dump + Versionsnotiz (wer prüft)?
- **D-Workspace-Daten (P-024/D5-Analog):** Server-Backup vs. Git-Push-Pflicht –
  was verspricht die Schule bei Serververlust, wem, mit welcher RPO? Wer
  kommuniziert das an Schüler/Lehrer?
- **D-Monitoring (P-007):** minimales `check.sh` (Frische+df+healthz per
  `logger` – wer liest morgens?) vs. volles Alerting (wer reagiert nachts?)?
  Schwellen (df-%? Backup-Alter?) nach Messung, nicht geraten.
- **D-Ressourcen (K4/D8-Analog):** RAM/Platte real (wie viel hat Zielhost)?
  `mem_limit`-/`retention.size`-Werte nach `docker stats`-Woche (wer misst?)?
  Degradationsreihenfolge (Monitoring vor DB)?
- **D-Firewall (P-004/D9-Analog):** Bindungsregel-Disziplin (wer prüft neue
  `ports:`?) vs. `DOCKER-USER`-Default-Deny (wer testet extern nach jeder
  Änderung, IPv6 ein oder aus?)?
- **D-Secrets (P-024/P-018):** Terminal-Ausgabe ab wann stumm? Rotation nach
  Offenlegung (wer rotiert, wie nachgewiesen)? `.env`-Offsite verschlüsselt
  (Schlüssel wie oben)? `.bak`-Retention (eine Generation? Cleanup?)?

Jede Entscheidung braucht: Optionen mit Preis, gewählte Option, Eigentümer,
Datum/Frist. „Später" ohne beides ist keine Entscheidung, sondern P-003 im
neuen Gewand.

---

## Recommended Plan Changes

1. **Plan reparieren und ehrlich machen (P-001/P-021):** F-013–F-026
   wiederherstellen oder Kopf auf F-001–F-012 korrigieren; F-012-Satz
   beenden; alle D-Referenzen entweder ausformulieren (mit Eigentümer/Frist)
   oder aus Dependencies/Verwerfungen streichen. Referenz-Check als Gate.
2. **Security-Findings wieder einführen (P-002–P-006):** Socket-Allowlist
   (CRITICAL), SSH-Härtungspfad (HIGH), Firewall-Bindungsregel + DOCKER-USER-
   Vorbereitung (HIGH), TLS-ask + Path-Apps (HIGH). Kein Security-Fix darf
   länger Phantom-Nummer sein. K1-Digest-Entscheidung (D4) mit Frist versehen
   (persistent: Digest-Pins + Signatur-Check vs. dokumentierte Patch-Automatik
   mit Eigentümer – nicht ewig „beides korrekt").
3. **F-006/F-007 korrigieren (P-010–P-012):** `umask`-Irrtum ersetzen
   (`install -m 600`/Temp+`mv`+`chown`), „neu erzeugen" durch
   abbrechen/reparieren + `.bak` ersetzen, GID-Guard (nicht-leer/numerisch) +
   Diff-Recreate + Socket-Probe-Existenztest. Als Einheit testen (Datei +
   Recreate + Probe).
4. **Backup/Restore vom Kopf auf die Füße (P-007/P-013–P-015/P-024):**
   Full-Disk-Finding zuerst (Logging/retention/logrotate/df), dann F-005 mit
   Warnung-statt-Fail bei Größe + automatisierter Restore-Prüfung, dann
   Offsite-Pflicht mit D6 (kein leerer Dauer-Default), dann Runbook mit
   RTO-Zahl + `.env`-/Config-/Workspace-Umfang. Reihenfolge beachten:
   Umfang ohne Offsite+Restore ist Dekoration (05/06-Einigkeit).
5. **Reset/Update ent-schärfen statt beschreiben (P-016/P-019/P-020):**
   Volume-Leer-Guard + Ableitungs-Befehl + Anzeige; Workspace-Label erst
   recherchieren, dann filtern (+ TTY-Guard, `--force` an Freigabe);
   Update-Gate + Prune-Guard + app/db-Trennung (Default `app`) statt
   Kommentar-Präzisierung allein. K5-Entscheidung revidieren (Trennung ist
   kein „neuer Vertrag", sondern Risikotrennung).
6. **Zweitlauf/Nebenwirkungen einpreisen (P-023/P-025/P-009/P-017):** Configs
   atomar + Caddy-nur-bei-Änderung, fail2ban-reload statt restart, ufw-Guard
   vor enable, PATH absolut, flock-Abort definiert, Boot-Gate nach 03:00,
   Retry/Fingerprint für apt/curl/pull, Wildcard-DNS separat geprüft. Der
   empfohlene Re-Run muss der sicherste Pfad werden, nicht der riskanteste.
7. **Testschicht vor Fix-PRs (P-022 + Missing Tests):** ShellCheck/Heredoc-
   Extraktion, Compose-Validierung, Rotations-/Timestamp-Test, Referenz-Check,
   `bash -n` als Gate; VM-Protokolle (Reboot/Restore/Reset/Update/Security/
   Platte) versioniert. AGENTS.md-Konformität („kein Test behauptet ohne Lauf")
   wiederherstellen; TEST_PLAN.md befüllen oder löschen (0-Byte-Datei mit
   Namen, der Tests verspricht, ist irreführend).
8. **Entscheidungen mit Namen und Datum versehen (Missing Decisions):**
   D-Liste oben als Beschlussvorlage an Operator: je Option/Preis/Eigentümer/
   Frist. Technik wartet auf Beschlüsse, rät sie nicht. Bis dahin: kein
   „Non-Goal", sondern „offen seit <Datum>, Eigentümer <Name>".
9. **Priorisierung korrigieren:** CRITICAL = Socket (P-002), Offsite/Restore-
   Unfähigkeit (F-002/F-003, nur mit P-014/P-015/P-024 zusammen), Plan-
   Unvollständigkeit (P-001/P-021). HIGH = SSH (P-003), TLS (P-005/P-006),
   Platte (P-007), Engine-Updates (P-008), Reboot-Blindheit (P-009), destruktive
   Idempotenz (P-010/P-011). Crontab-Abbruch (F-001) bleibt wichtig (blockiert
   alles danach), aber nicht wichtiger als Total-Compromise/Totalverlust –
   Reihenfolge im Plan („Muss zuerst") als Ablauf-, nicht als Wichtigkeits-
   Ordnung kennzeichnen.
10. **Freigaberegel:** Kein Implementierungs-PR vor Blocking-Liste (oben).
    Pro Fix-PR: betroffene P-Punkte nennen, Regression benennen, Test-
    Nachweis (Log/Befehl/Datum, Test-VM-Name) beilegen. Stil-Fixes (SC2034,
    ufw-Einmal-Auswertung, Newline) separat, nie im selben PR wie destruktive
    Pfade (AGENTS.md: keine unrelated changes).
