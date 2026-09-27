# POST-IMPLEMENTATION-PLAN – Technische Bewertung der Breaker-Funde (B-001–B-021)

Stand: 2026-09-27. Geprüft: `setup-coder.sh` (1248 Zeilen, HEAD `570db50`,
Branch `ai/implementation-v1`), `ssh-harden.sh`, `RESTORE.md`,
`templates/allowlist.md`, `ai-review/FINAL-BREAKER-REVIEW.md` (B-001–B-021),
`ai-review/IMPLEMENTATION-REPORT.md`, `ai-review/PLAN.md` (F-001–F-012),
`ai-review/PLAN-REVIEW.md` (P-001–P-025), `ai-review/TEST_PLAN.md`.

Es wurde ausschließlich diese Datei erstellt. Keine Implementierung, keine
andere Datei verändert, keine Produktivserver-Befehle.

## Verifikationsmethodik

Jeder Breaker-Fund wurde gegen den aktuellen Code geprüft (Lesung +
`grep`-Abwesenheitsnachweise). Zwei Befunde wurden zusätzlich live verifiziert:

- B-001: verschachteltes `flock -n` auf derselben Datei lokal reproduziert
  (`flock -n /tmp/breaker-verify.lock flock -n /tmp/breaker-verify.lock true`
  → Exit 1, nur `/tmp`, gefahrlos).
- B-002: offizielle Release-Notes `coder/coder v2.36.6` (abgerufen 27.09.2026)
  nennen wörtlich `docker pull ghcr.io/coder/coder:2.36.6` (ohne `v`).

Korrektur zu einer Breaker-Nebenbehauptung: Die Release-Seite labelt v2.36.6
als „Stable (since September 17, 2026)". Die Einordnung „Mainline-Zweig" in
B-002 ist damit ungenau; sie ändert nichts am Fix (Tag-Form + Pull-Nachweis),
nur die Pin-Zweig-Frage gehört in eine echte Entscheidung statt in eine
Annahme.

---

### B-001 – Cron-Backup läuft nie (doppeltes `flock`-Deadlock)

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
CRITICAL

Related Finding:
F-009 (P-017)

Location:
`setup-coder.sh` L733 (Cron-Zeile mit äußerem `flock -n`), L637–642
(innerer Selbst-Lock in `backup.sh`).

Problem:
Cron-Zeile und `backup.sh` locken dieselbe Datei
(`/opt/coder/backups/.backup.lock`) mit `flock -n`. Der äußere Lock hält die
Sperre während `backup.sh` läuft; der innere `flock -n` scheitert
deterministisch. Jeder Cron-Lauf skippt sich selbst mit Exit 0. Der
Setup-Direktaufruf (ohne äußeren Lock) funktioniert – perfekte Tarnung.

Evidence:
Code-Lesung beider Stellen (identische Lock-Datei) + lokale Repro:
verschachteltes `flock -n` auf derselben Datei → Exit 1.

Reasoning:
Alle Backup-Verbesserungen (Rotation, `gzip -t`, df-Gate) laufen nie im
Cron-Pfad. Das einzige je existierende Backup ist das manuelle
Setup-Test-Backup und altert still. Angriffsszenario entfällt (kein
Angriff, sondern Totalausfall der Sicherungsfunktion); Wahrscheinlichkeit
100 % ab Tag 2; Auswirkung: kein Tages-Backup; Reproduzierbarkeit:
deterministisch.

Required change:
Äußeren `flock` aus `/etc/cron.d/coder-backup` entfernen. Innerer
Selbst-Lock in `backup.sh` bleibt einzige Sperre (schützt Cron-,
`update.sh`-Pre-Backup- und manuelle Läufe gemeinsam). Kommentar an beiden
Stellen korrigieren (keine „Doppelabsicherung" behaupten).

Do not change:
Innerer Lock (Exit-0-Skip-Semantik bleibt); Sekunden-Timestamp;
Cron-Zeit 01:00; Logrotate.

Dependencies:
Keine. Erste Code-Änderung (danach existiert überhaupt erst ein Backup,
von dem alle folgenden Tests abhängen).

Regression risks:
Gering. Entfernt nur redundante Sperre; parallele Läufe weiter per
innerem Lock serialisiert.

Required test:
Cron-Pfad statt Direktaufruf testen: `/usr/bin/flock`-freie Cron-Zeile auf
Test-VM feuern lassen (oder manuell exakt wie Cron aufrufen) → Backup-Datei
muss entstehen, kein „übersprungen" in `/var/log/coder-backup.log`.
Danach T-074 (Parallelität: genau ein Gewinner, ein sauberer Skip).

Rollback:
Cron-Zeile aus Git-Historie wiederherstellen (eine Zeile).

---

### B-002 – `CODER_VERSION=v2.36.6`: Default-Tag widerspricht offiziellem Pull-Befehl

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
CRITICAL

Related Finding:
NONE (K1/D4 berührt Tag-vs-Digest, nicht Tag-Form)

Location:
`setup-coder.sh` L77 (Default), L42–44 (Kommentar „braucht das v-Präfix"),
L256 (Image-Referenz).

Problem:
Default `v2.36.6` widerspricht dem offiziell dokumentierten
`docker pull ghcr.io/coder/coder:2.36.6` (ohne `v`). Der Kopfkommentar
verteidigt die falsche Form mit Nachdruck (Fehldiagnose-Risiko). Kein Test
hat je gepullt (`compose config` validiert nur YAML). Ob ein `v`-Aliastag
existiert, ist ungeprüft – der Fix darf das nicht voraussetzen.

Evidence:
Code-Fakt (Default + Kommentar) + offizielle Release-Notes v2.36.6
(Container-Image-Zeile ohne `v`, live abgerufen). Inkonsistenz im Skript
selbst: `PROMETHEUS_VERSION=v3.14.0` (mit `v` korrekt),
`GRAFANA_VERSION=12.4.5` (ohne `v` korrekt) – nur Coder weicht vom
Upstream-Pull-Befehl ab.

Reasoning:
Frischer Installationslauf stirbt in Schritt 3 (`pull`/`up -d`), ebenso
jedes `update.sh` und jeder Reset-Neuaufbau. Wahrscheinlichkeit: hoch
(sobald kein `v`-Alias existiert: 100 %); Auswirkung: Totalausfall der
Erstinstallation; Reproduzierbarkeit: deterministisch per `docker pull`.

Required change:
Default auf `2.36.6` korrigieren + Kommentar korrigieren (Git-Tag ≠
Image-Tag, kein `v`-Präfix bei Coder-Images). Vor Merge auf Test-VM mit
Netz protokollieren: `docker pull ghcr.io/coder/coder:2.36.6` (muss gehen)
und Negativprobe `docker pull ghcr.io/coder/coder:v2.36.6` (Ergebnis
protokollieren, kein Fail erzwungen – nur Beleg). Pin-Existenz künftig pro
Version per Pull belegen. Kein Hochziehen auf 2.37.x im selben Zug
(Migrations-/Downgrade-Risiko, siehe B-009).

Do not change:
Pin-Prinzip (exakte Version) bleibt; keine Digest-Umstellung in diesem
Schritt (D4 offen); kein Major-Update.

Dependencies:
Keine, aber logisch vor allen VM-Tests (ohne pullbaren Pin läuft kein
Fresh-Install-Test).

Regression risks:
Gering (eine Variable + Kommentar). Risiko nur, falls ausgerechnet der
`v`-Alias existierte und `2.36.6` nicht – dagegen schützt die
Pull-Probe vor Merge.

Required test:
Beide `docker pull`-Proben mit Protokoll (Datum, VM, Exit-Codes). Danach
T-010 (Fresh Install) als eigentlicher Nachweis.

Rollback:
Eine Zeile (`CODER_VERSION`) + Kommentar revertieren.

---

### B-003 – Prune-`until=24h` schützt kein Rollback (Erstellungs- statt Dangling-Zeit)

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
F-012 (P-020)

Location:
`setup-coder.sh` L832–836 (eingebettetes `update.sh`: Kommentar „behält
die Images von gestern" + `docker image prune -f --filter "until=24h"`).

Problem:
Docker-`until` filtert nach Image-**Erstellungs**datum, nicht danach, wann
das Image dangling wurde. Bewegliche Tags (`caddy:2.10`,
`postgres:15-alpine`) werden nach `pull` dangling, sind aber Wochen alt →
sofort gelöscht. Der Kommentar beschreibt Zerstörung als Schutz; Rollback
braucht Re-Pull (ohne Netz im Ernstfall: kein Rückweg).

Evidence:
Code-Lesung (Filter + Kommentar) + Docker-Referenz (`until` – „only remove
images created before given timestamp"). Mechanik aus beweglichen Tags im
Skriptkopf abgeleitet.

Reasoning:
Update-Fehlschlag + „Rollback wie kommentiert" → altes Image weg.
Wahrscheinlichkeit: hoch bei jedem Caddy-/Postgres-Update (Normalfall);
Auswirkung: kein Offline-Rollback; Reproduzierbarkeit: deterministisch
(T-053, noch nie ausgeführt).

Required change:
`prune`-Zeile aus `update.sh` entfernen (Platte der Schul-VM ist kein
akuter Engpass; alte Images sind der billigste Rollback). Kommentar
ersetzen: kein Auto-Prune nach Update; manuelles Aufräumen nur bewusst.
Kein „sichere Image-IDs vorher in Datei"-Mechanismus (neue Logik ohne
nachgewiesenen Zusatznutzen gegenüber Weglassen).

Do not change:
`pull` → `up -d`-Reihenfolge; Health-Gate (B-009); Rollback-Doku für exakt
Gepinnte bleibt.

Dependencies:
Vor B-009-Tests (Rollback-Verhalten T-092 hängt daran).

Regression risks:
Gering. Folge: alte Images akkumulieren (Platte) – bewusst in Kauf
genommen, per Doku sichtbar; kein Laufzeitrisiko.

Required test:
T-053 (zwei reale Caddy-Tags fahren, nach `update.sh` muss altes Image noch
da sein).

Rollback:
Eine Zeile wieder einfügen.

---

### B-004 – Docker-Socket im Coder-Container ohne technische Schranke

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
CRITICAL

Related Finding:
P-002 (02/F-001, 06/F-005)

Location:
`setup-coder.sh` L275–276 (Socket-Mount schreibbar, kein `:ro`, kein
Proxy), L265–266 (`group_add`); `templates/allowlist.md` (reine Doku, kein
Enforcement, Erstinventar offen).

Problem:
Wer den Socket nutzen kann, startet Container mit beliebigen
Mounts/Capabilities (Host-root-äquivalent). Workspace-Nutzer sind per
AGENTS.md untrusted. Allowlist ist Doku ohne Zwang, Inventar offen,
Selbsttest nie gelaufen – jede künftige Unterrichtsanforderung ist eine
unsichtbare Sicherheitsentscheidung.

Evidence:
Code-Lesung (Mount + `group_add`) + Allowlist-Datei ohne Enforcement +
offene Blocker B-11 im IMPLEMENTATION-REPORT.

Reasoning:
Angriffsszenario: kompromittierter Workspace / zu permissives Template /
Provisioner-CVE → `.env`, Backups, Host-Persistenz. Wahrscheinlichkeit:
niedrig heute (kein bekannter Exploit im Repo), aber deterministisch bei
Kompromittierung; Auswirkung: total (alle Secrets, alle Backups).
Reproduzierbarkeit: per Workspace-Selbsttest belegbar.

Required change:
Sofort (ohne Architekturumbau): Template-Erstinventar nachholen +
Abhakpflicht pro Template-PR (T-064, Reviewer + Datum) + protokollierter
Negativ-Selbsttest aus normalem Workspace (Socket unsichtbar,
`postgres:5432` unerreichbar, keine fremden Container, T-063). Socket-Modell
(Allowlist dauerhaft vs. Proxy vs. separater Host) als D-Entscheidung mit
Eigentümer + Frist festhalten. Kein Proxy-Einbau in dieser Runde (Umbau
ohne Beschluss = Regression Risk).

Do not change:
Socket-Mount selbst bleibt (Coder braucht ihn für Provisionierung);
kein `:ro` (würde Provisionierung brechen); keine Template-Funktionsänderung.

Dependencies:
Vor B-017-Flag (Inventar wird gemeinsam genutzt).

Regression risks:
Gering (Doku + lesende Tests, kein Produktiv-Eingriff). Falsch-Positive im
Selbsttest möglich (Netz-Aliasnamen) – deshalb dokumentierte Erwartung
(`PG_UNREACHABLE` etc.), kein Fail-Automatismus.

Required test:
T-063 + T-064 auf Test-VM mit normalem Workspace, Protokoll ins Repo.

Rollback:
Doku-Dateien revertieren; keine Produktivänderung zum Zurückrollen.

---

### B-005 – On-Demand-TLS mit `ask http://example.com` (LE-Budget-DoS + Hostnamen-Leak)

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
P-005 (02/F-011, 04/F-001/F-003/F-006/F-007)

Location:
`setup-coder.sh` L401–416 (`ask http://example.com` + `tls { on_demand }`
für Apex **und** Wildcard); Kommentar L14–20 (Budget als „unkritisch"
verniedlicht, Apex-Betroffenheit falsch dargestellt).

Problem:
Jeder Internet-Teilnehmer (ohne Account) löst per SNI echte
Let's-Encrypt-Ausstellungen aus (`ask` antwortet immer 200). Budget: 50 pro
Woche pro registrierter Domain `ghse-unterricht.de`, geteilt mit allen
anderen Schuldiensten → legitime Workspace-Apps ohne Zertifikat.
Parallel: jeder angefragte Hostname per Klartext-HTTP an US-Dritten
(Caddy sendet `?domain=` per GET, kein Redirect-Follow, 10 s Timeout).
Keine Erkennung implementiert.

Evidence:
Code-Lesung (Caddyfile-Template) + Caddy-Source (`ondemand.go`:
`qs.Set("domain", name)`) + Caddy-Doku (Endpoint „not exposed publicly" –
hier an öffentlichen Dritten) + LE-Rate-Limit-Doku.

Reasoning:
Angriffsszenario: accountloser Fremd-DoS aufs Zertifikatsbudget +
systematischer Hostnamen-Abfluss (Schulkontext). Wahrscheinlichkeit: niedrig
bis mittel (erfordert gezielte Anfragen); Auswirkung: TLS-Fehler im
Unterricht + Datenabfluss; Reproduzierbarkeit: per Fake-Subdomain-Handshake
belegbar.

Required change:
Kurzfristig (diese Runde): Kommentar ehrlich korrigieren (Apex ebenfalls
on-demand; Budget gehört `ghse-unterricht.de`, geteilt) + Erkennung:
Caddy-Log auf `obtaining certificate` überwachen (einfacher
`check.sh`/Logger, kein Alertmanager). Echter `ask`-Endpoint vs.
DNS-01-Wildcard (+ CAA) als D-TLS-Entscheidung mit Frist – kein stiller
Default. `CODER_DISABLE_PATH_APPS` erst nach Inventar (B-017).

Do not change:
On-Demand-Mechanik selbst bleibt bis D-TLS-Entscheidung; keine
DNS-01-Umstellung ohne Provider-Token-Beschluss; kein `ask`-Schnellschuss
mit veralteten API-Daten (Falsch-Negativ-Risiko).

Dependencies:
Nach B-021-Nachweis (Kompatibilität zuerst belegen, dann Modell wählen).

Regression risks:
Gering (Kommentar + lesendes Monitoring). Echter `ask` später: Risiko
legitime Apps zu blockieren – deshalb Entscheidung, nicht Einzeiler.

Required test:
T-125 (Fake-Subdomain-Handshake + Caddy-Log zeigt heute `obtaining
certificate` pro Fake-Namen = Ist-Beleg); T-123 (Issuer/Kette). Wenige
Versuche/Woche (Budget!).

Rollback:
Kommentar + Monitoring-Skript revertieren.

---

### B-006 – SSH weltweit + Passwort aktiv (grünes Setup), Härtungsskript ohne Nachbedingung

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
P-003 (02/F-007, 06/F-012)

Location:
`setup-coder.sh` L28–34 (Design weltweites SSH + Passwort aktiv),
L480 (`limit 22/tcp`), L1235–1242 (nur Warnung, Exit 0); `ssh-harden.sh`
L30 (Key-Regex), L41 (nur Warnung bei fehlender `sshd -T`-Zeile),
L48–50 (Drop-In), L62–63 (Config wird nur **ausgegeben**, kein
Enforcement-Check).

Problem:
Setup meldet Erfolg im unsichersten zulässigen Zustand; Provisorium ohne
Termin versteinert. `ssh-harden.sh` wird nie vom Setup aufgerufen und hat
selbst drei Kanten: keine Nachbedingung nach `reload` (bei ignoriertem
Drop-In Exit 0 trotz wirkungslosem Fix), Key-Regex erkennt keine
FIDO2-SK-Keys (`sk-ssh-ed25519@…`, `sk-ecdsa-sha2-…`) und keine
`-cert-v01@…`-Zertifikate (falscher Abbruch), `PermitRootLogin no` sperrt
Root-Key-Admins ohne Prüfung des bestätigten Kontos.

Evidence:
Code-Lesung aller zitierten Stellen (Warnung-statt-Enforcement per Lesung;
Zielhost-Live-Status nicht geprüft – ändert nichts am fehlenden Finding).

Reasoning:
Angriffsszenario: verteilter Angriff / kompromittiertes Passwort umgeht
Rate-Limit + fail2ban; SSH-Passwort = Host = Docker-Admin = `.env` +
Backups + DB. Wahrscheinlichkeit: mittel über Jahre (Lehrerwechsel,
Weitergabe); Auswirkung: total; Reproduzierbarkeit: per Config lesbar.
Kein CRITICAL (sofortiges Abschalten ohne Zweit-Zugang = Aussperrung).

Required change:
`ssh-harden.sh`: Post-Check nach `reload` (`sshd -T` parsen –
`passwordauthentication`/`kbdinteractiveauthentication`/`permitrootlogin`
müssen effektiv `no` sein, sonst Exit 1 + Rollback-Hinweis); Key-Regex um
`sk-ssh-ed25519@`, `sk-ecdsa-sha2-`, `-cert-v01@` ergänzen; Provisoriums-Alter
ins Setup-Log schreiben. Härtungstermin + Eigentümer + Zweit-Zugang als
D-SSH-Entscheidung (nicht vom Implementierer zu setzen). Setup selbst
bleibt warnend-grün bis dahin.

Do not change:
Kein Key-only-Enforcement im Setup (Aussperrungsrisiko); kein automatischer
Härtungsaufruf; `limit 22/tcp` + fail2ban bleiben.

Dependencies:
Keine Code-Dependency; D-SSH-Entscheidung parallel einholen.

Regression risks:
Mittel bei falscher Härtung (Aussperrung) – deshalb Guards + Zweit-Zugang
als Voraussetzung, Tests nur mit Zweit-Zugang.

Required test:
T-061 (effektive Config vor/nach, externer Passwort-Login scheitert,
Key-Login gelingt, Ban separat; SK-Key-Negativprobe: SK-Key wird als
gültig erkannt, kein falscher Abbruch).

Rollback:
Drop-In löschen + `reload` (im Skript dokumentiert).

---

### B-007 – UFW ohne Default-Policy, ohne DOCKER-USER; Re-Run weitet SSH still aus; IPv6 undeklariert

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
P-004 (02/F-008–F-010, 06/F-006)

Location:
`setup-coder.sh` L470–480 (Delete-Regeln + `limit 22/tcp` weltweit),
L524–527 (allows + enable); kein `default deny/allow` (grep-negativ), kein
`DOCKER-USER`/kein `daemon.json` (grep-negativ); Abschlusscheck prüft nur
Anwesenheit.

Problem:
(a) Keine expliziten Defaults – Verlass auf Debian-Defaults nach
Härtungsdrift. (b) Jeder künftige `ports:`-Eintrag erscheint öffentlich
(Docker-iptables umgeht UFW, Kommentar sagt es selbst, Policy fehlt);
`ufw status` suggeriert Schutz. (c) Re-Run löscht restriktivere
Operator-Regeln (z. B. `10.16.0.0/12`-only, L472) und setzt weltweit-offen
ohne Hinweis – stilles Sicherheits-Downgrade durch den empfohlenen
Bedienweg. (d) IPv6 weder Betriebs- noch Abschaltpfad.

Evidence:
Code-Lesung (Delete + Limit + Enable ohne Defaults) + doppelte
grep-Negativnachweise + Loopback-Bindungen beweisen nichts für künftige
Ports.

Reasoning:
Angriffsszenario: versehentlich öffentlicher Debug-Port / revertierte
SSH-Härtung. Wahrscheinlichkeit: mittel über Lebensdauer (genau der
erweiterungsfreudige Schul-Host); Auswirkung: unbemerkt offene Dienste;
Reproduzierbarkeit: per Re-Run deterministisch (c).

Required change:
`ufw default deny incoming` / `allow outgoing` idempotent setzen;
Re-Run warnt bei restriktiverer vorgefundener SSH-Regel statt sie still zu
löschen (Abweichung melden, Downgrade nur explizit); Bindungsregel
dokumentieren („neue `ports:` nur `127.0.0.1`, Ausnahme nur Caddy") +
Review-Check; IPv6-Pfad deklarieren (Betrieb oder abgeschaltet). DOCKER-USER
als D-Firewall-Entscheidung mit Dual-Stack-Test (kein Default-Deny ohne
externen Scan – bricht sonst Workspace-Apps/HTTP-3).

Do not change:
`limit 22/tcp` als Default bleibt (bis D-SSH); bestehende 80/443-Regeln;
kein DOCKER-USER-Einbau ohne Dual-Stack-Nachweis.

Dependencies:
Keine.

Regression risks:
Mittel bei DOCKER-USER (deshalb Entscheidung + Scan); gering bei Defaults
+ Warnung (lesend bis auf explizite Policy).

Required test:
T-060 (externer Scan TCP 22/80/443/9090/9100/3001 + UDP 443, `ss -tlnp`,
`iptables-save`/`nft`, Schulnetz-NAT-Abgleich), T-062, T-120
(A/AAAA/Wildcard/CAA). Re-Run-Probe: restriktivere SSH-Regel setzen →
Re-Run muss warnen, nicht still revertieren.

Rollback:
UFW-Regeln/Defaults per `ufw`-Befehle zurücksetzen (dokumentieren).

---

### B-008 – Kein Offsite, kein geprobter Restore; Pfad A wahrscheinlich defekt; Runbook nicht auf Server

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
CRITICAL

Related Finding:
F-002/F-003 (P-014/P-015)

Location:
`setup-coder.sh` L631–632 (einziger Schreibpfad `${BACKUP_DIR}` unter
`/opt`; kein rsync/scp/rclone, grep-negativ); `RESTORE.md` L32–35 (Pfad A
Schritt 4 ohne `dropdb`/`--clean`-Verfahren); Verweise L845 + L1088 auf
`RESTORE.md`, das das Setup auf dem Server nie ablegt.

Problem:
Platten-/Host-Verlust = DB + alle Backups weg (irreversibel). Pfad A sagt
„Tabellen per Dump überschreiben lassen" – Standard-`pg_dump` ohne
`--clean`/`--if-exists` bricht an bestehendem `CREATE TABLE` ab bzw.
produziert PK-Konflikte beim `COPY`. RTO-Tabelle „offen" (nie gelaufen).
Wer nur Skripte auf den Server kopiert, hat Verweise auf ein Runbook, das
dort nicht liegt.

Evidence:
Code-Lesung + grep-Negativnachweise + RESTORE.md-Zitat + offene Blocker
B-02/B-12 im IMPLEMENTATION-REPORT (selbst zugegeben).

Reasoning:
Angriffsszenario entfällt (kein Angriff); Szenario Plattenverlust:
Wahrscheinlichkeit niedrig, Auswirkung total irreversibel. Pfad-A-Defekt:
Wahrscheinlichkeit hoch beim ersten Ernstfall (deterministisch an
bestehendem Leer-Schema). Reproduzierbarkeit: per Test-Restore belegbar.

Required change:
Pfad A auf `dropdb --if-exists` / `createdb` oder
`--clean --if-exists`-Dump-Verfahren festlegen (eine Variante, kein
„Fehlerprotokoll lesen" als Verfahren); `RESTORE.md` (oder `restore.sh`)
vom Setup auf dem Server ablegen lassen, damit L845/L1088 dort auflösen –
oder Verweise auf Repo-Pfad ändern (eines von beiden, kein Dangling);
RTO als Zahl ins Repo (Datum, Versionen, Dump-Alter). Offsite als
D6-Entscheidung mit Eigentümer/Frist (Ziel, Verschlüsselung,
Schlüsselverwahrung getrennt vom Host, Retention, Transport-Secrets,
getrennte Exit-Codes/Logs, kein leerer Dauer-Default). Restore nach jedem
Major-Update erneut proben.

Do not change:
Lokales Backup-Verfahren (B-001/B-010) bleibt Basis; kein Offsite-Hook mit
leerem Default (P-014: dokumentiertes Weiter-so ist kein Fix);
Transportfehler ≠ lokaler Fehler.

Dependencies:
B-001 + B-010 zuerst (nur verifizierte lokale Backups kopieren/proben).

Regression risks:
Gering (Doku + Verfahren + Ablage). Transport: Secrets-Exfiltration bei
falscher Konfiguration – deshalb D6-Entscheidung statt Raten.

Required test:
T-082 (Snapshot verwerfen, nur aus Offsite + Runbook, Zeit stoppen),
T-080 (Mini-Restore in Wegwerf-Postgres), T-083 (Workspace-Gap-Beleg).

Rollback:
RESTORE.md-Änderungen revertieren; Server-Ablage entfernen.

---

### B-009 – Update ohne echten Health-Nachweis, ohne Rollback, DB+App gekoppelt

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
F-012 (P-020, K5)

Location:
`setup-coder.sh` L799–836 (eingebettetes `update.sh`): Pre-Backup L801–803
ohne Frische-Unterscheidung (Skip = Exit 0), Gate L810–830 (nur
`State.Running` + Postgres-`healthy`), Prune L836; `docker`-Aufrufe ohne
`sudo` (Setup nutzt `sudo docker` – inkonsistente Konvention).

Problem:
Ein Coder, der läuft, aber wegen Passwort-Drift/fehlgeschlagener Migration
keine Requests bedient, ist „grün". Caddy-TLS, `/healthz`,
Grafana/Prometheus nie geprüft. Schema beim Gate bereits migriert
(Downgrade ggf. irreversibel). DB- und App-Images in einem `pull` (aus Angst
vor DB-Major kein Coder-Patch). Inkonsistente sudo-Konvention.

Evidence:
Gate-Volltext per Lesung; Pre-Backup-Skip-Semantik aus B-001/B-010;
Kommentar ehrlich, Guard fehlend.

Reasoning:
Fehl-Update fällt bestenfalls durch Crash auf, schlimmstenfalls als „grün"
durch – ohne Rückweg (B-003) und ohne Risikotrennung. Wahrscheinlichkeit:
mittel (jede Update-Runde); Auswirkung: Totalausfall mit ungewissem
Rückweg; Reproduzierbarkeit: per Bad-Version belegbar.

Required change:
Gate um `/healthz`-200 innert Timeout + Caddy-TLS-Smoke erweitern; Prune
entfernen (B-003); Pre-Backup bei Skip das Backup-Alter loggen lassen
(B-010-Kopplung); sudo-Konvention vereinheitlichen. `app`/`db`-Trennung
(Default `app` = Coder/Caddy + Gate; `db` = Postgres nur explizit mit
verifiziertem Dump + Downgrade-Warnung) als SHOULD_FIX in derselben Runde,
falls ohne Vertragsüberraschung machbar – sonst als dokumentierte
Folgeänderung (ändert Bedienvertrag, siehe K5).

Do not change:
Manueller Update-Betrieb bleibt (kein Auto-Update per Cron); kein
Gate, das bei legitimer Erstverzögerung (On-Demand-TLS 5–30 s) fälschlich
rot zeigt (Timeout großzügig + dokumentiert).

Dependencies:
B-001 (Skip-Semantik), B-003 (Prune), B-010 (Backup-Alter).

Regression risks:
Mittel: zu striktes Gate lässt legitime Updates scheitern
(Warnungsmüdigkeit); app/db-Split ändert Bedienvertrag – deshalb Gate
MUST, Split SHOULD mit Doku.

Required test:
T-050/T-091 (Bad-Version muss selbst scheitern), T-090 (Normalpfad),
T-092 (Rollback exakt vs. beweglich differenziert), T-093 (`app` lässt
Postgres unberührt).

Rollback:
`update.sh`-Block aus Git-Historie wiederherstellen.

---

### B-010 – Backup-„Verifikation" erklärt leere/fehlerhafte Dumps für gültig; Skip zählt als Erfolg

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
F-005 (P-013)

Location:
`setup-coder.sh` L663–689 (`gzip -t` hart, Größe nur Warnung < 512 B, `mv`
danach); L637–642 (Zweitlauf-Skip Exit 0 ohne Frische-Signal).

Problem:
`pg_dump`-Fehlertext nach stdout oder leeres stdin → `gzip -t` grün, ggf.
≥ 512 B → per `mv` zum „gültigen" Backup, rotiert unter neueste 14.
Mini-Dump (< 512 B): Warnung, Datei trotzdem final. Restore davon: `psql`
grün ohne Tabellen, Coder mit leerem Schema – Datenverlust spät bemerkt.
Cron-Skip/B-001-Skip für `update.sh`-Pre-Backup ununterscheidbar von
„frisch gesichert". Warnung ohne Leser (niemand liest täglich Cron-Logs).

Evidence:
Code-Lesung (Warnung-statt-Fail + Skip-Exit-0) + 05/F-003
(leeres-stdin-Artefakt).

Reasoning:
Stille Unbrauchbarkeit der einzigen Sicherung; „Backup OK" ohne
SQL-Semantik. Wahrscheinlichkeit: niedrig bis mittel (tritt bei
PG-Fehlern/ENOSPC-Resten auf); Auswirkung: Totalverlust-Gefühl bei
vorhandenen Dateien; Reproduzierbarkeit: per Fake-`pg_dump` belegbar.

Required change:
Größenabweichung als Warnung mit Vorwert-Vergleich (Relation zum letzten
Dump, kein harter Fail bei legitimer Verkleinerung); Leere/Fehlertext =
Fail (leerer Dump darf keine Finaldatei werden); wöchentlicher Mini-Restore
in Wegwerf-Postgres als automatisierte Pflicht (T-080, nicht nur
Runbook-Satz); Skip meldet Alter des gültigen Backups (für `update.sh`
unterscheidbar).

Do not change:
Keine harte `> 1 KiB`-/`> 50 %`-Schwelle (P-013: False-Positive bei
frischer/verkleinerter DB); `gzip -t` bleibt notwendige (nicht
hinreichende) Prüfung.

Dependencies:
B-001 zuerst (sonst ist jeder Cron-Lauf ein Skip mit Altersmeldung).

Regression risks:
Mittel bei falschen Schwellwerten (legitime Backups rot →
Warnungsmüdigkeit) – deshalb Warnung + Mini-Restore statt Hartschwelle.

Required test:
T-071 (leeres stdin → Fail/Warnung, halbierte DB → kein Fail), T-072
(Fake-Abbruch → keine Finaldatei), T-080 (Mini-Restore automatisiert).

Rollback:
Backup-Block aus Git-Historie wiederherstellen.

---

### B-011 – Automatischer Reboot 03:00 ohne Ordnung und ohne Zeuge

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
P-009 (03/F-002/F-010, 06/F-010/F-011)

Location:
`setup-coder.sh` L590–594 (Reboot-Config 03:00); Restart-Policies überall
(`restart: unless-stopped`); kein `stop_grace_period`, kein
Coder-HTTP-Healthcheck, kein Boot-Gate (grep-negativ).

Problem:
`depends_on` gilt nur für Compose-CLI, nicht für Daemon-Restart nach Reboot:
alle sechs Container starten gleichzeitig, Coder crash-loopt gegen
unbereites Postgres. Kein Boot-Gate, kein Boot-Log, Schritt 10 nur bei
manuellem Setup – erste Meldung: Schüler morgens. Backup 01:00 / Reboot
03:00 / manuelles Update unkoordiniert. 03:00 reißt zusätzlich laufende
Workspaces/Sessions/Übernacht-Jobs ab – ohne Betriebsfenster-Abstimmung.

Evidence:
Code-Lesung (Reboot-Config + Restart-Policies + Abwesenheit aller
Ordnungs-/Zeugen-Mechanismen) + dokumentiertes Docker-Verhalten
(Restart = Daemon-Ebene).

Reasoning:
Wahrscheinlichste Reboot-Ursache (planmäßig automatisiert) ohne
Gesundheitsnachweis. Wahrscheinlichkeit: hoch (jeder Kernel-Reboot);
Auswirkung: morgendlicher Unterrichtsausfall ohne Diagnose;
Reproduzierbarkeit: per Test-Reboot belegbar.

Required change:
Lesendes Boot-Gate (Container gesund + `/healthz` innert N Minuten, sonst
`logger` + `/var/log/coder-boot.log`, kein Eingriff);
`stop_grace_period: 30s` für Postgres; Coder-HTTP-Healthcheck (`/healthz`)
+ Caddy-`condition: service_healthy` (in Test-VM verifiziert);
Reboot-Zeit mit Betriebsfenster abstimmen + im Wartungsplan hinterlegen.
Docker-Engine-Pfad (B-013-Entscheidung) mitführen.

Do not change:
Reboot-Automatik selbst bleibt (Sicherheitsupdates); kein eingreifendes
Boot-Skript (nur lesend + Logging); kein `stop_grace_period` für alle
Services pauschal (nur Postgres mit Nachweis).

Dependencies:
B-009-Gate-Muster wiederverwenden (Healthcheck-Form).

Regression risks:
Mittel bei falsch konfiguriertem Healthcheck (zusätzliche
Neustartschleife) – deshalb Test-VM-Verifikation; gering bei lesendem Gate
+ Grace-Period (längerer Shutdown).

Required test:
T-110 (Reboot + Boot-Log + erste 2 Min `docker logs coder`), T-111 (alle
sechs nach Reboot), T-112 (Daemon-Restart), T-113 (Grace-Probe).

Rollback:
Boot-Gate entfernen, Grace-Period/Healthcheck aus Compose streichen.

---

### B-012 – Jeder Re-Run überschreibt Operator-Anpassungen still (Config-Clobber)

Classification:
CONFIRMED

Priority:
SHOULD_FIX

Severity:
MEDIUM

Related Finding:
P-023/P-025 (06/F-003/F-009)

Location:
Unbedingte `tee`-Schreibstellen (Compose, Caddyfile, prometheus.yml,
jail.local, Cron, logrotate, 52-coder-reboot); Hash-Vergleiche nur für
Restart-Entscheidung (Caddy, fail2ban), nie Drift-Meldung; kein
Hash-Vergleich mit Warnung, keine `.bak` (T-026 erwartet genau das – nicht
implementiert).

Problem:
Manuelle Nacharbeit (z. B. `retention.size`, Caddy-Snippet,
`recidive`-Jail, Cron-Zeit) wird beim nächsten Re-Run plattgewalzt.
Hand-Tuning ist Verfallsmaterial; Operator lernt, nichts anzupassen.

Evidence:
Code-Lesung (alle Schreibstellen unbedingt) + Abwesenheit jeder
Drift-Meldung (grep-negativ).

Reasoning:
Gute Härtung geht verloren (im B-007-c-Fall sogar Downgrade). Aber:
deterministisches Heilen (Re-Run heilt Kill-Zustände) erkauft mit
deterministischem Vergessen – Abwägung, kein Totalausfall.
Wahrscheinlichkeit: hoch bei aktivem Betrieb; Auswirkung: mittel
(Verlust von Härtung, kein Datenverlust).

Required change:
Hash-Vergleich + Warnung vor dem Schreiben (Caddy-Muster auf alle
generierten Dateien ausweiten); `jail.local`-Operator-Jails per
Include-Datei statt Vollüberschreibung. Nur Warnung + deterministisches
Regenerieren (kein `--force`-Interaktivismus im Setup – würde Idempotenz
brechen).

Do not change:
Deterministische Regeneration bleibt (kein „Drift bleibt stehen");
kein interaktiver Stopp des Setups bei Drift.

Dependencies:
Nach B-007 (sonst warnt der Re-Run auch vor der eigenen SSH-Policy).

Regression risks:
Gering (lesender Vergleich + Warnung). Falsch-Positive bei Whitespace/
Kommentar-Drift möglich – Hash über normalisierte Datei oder exakter
Vergleich mit klarer Meldung.

Required test:
T-026 (Drift-Zeile → Re-Run meldet + regeneriert deterministisch; ohne
Änderung kein Caddy-Restart).

Rollback:
Vergleichs-Zeilen entfernen (reine Addition, leicht revertierbar).

---

### B-013 – Keine Preflights, keine Retries (Netz-/Docker-/Port-Fehler kommentararm)

Classification:
CONFIRMED

Priority:
SHOULD_FIX

Severity:
MEDIUM

Related Finding:
P-023 (T-026/T-030–T-032/T-040–T-045)

Location:
Schritt 1/3 (`apt-get update`, `curl | gpg`, `compose pull` ohne
Retry/Timeout außer Step-10-curl); kein `ss`-Bind-Check vor `up`; kein
`df`-Gate außer Backup.

Problem:
Banale Fehlerpfade (Schulnetz, belegter Port 80/443 oder
127.0.0.1:9090/9100/3001, voller Datenträger beim `tee`, toter
Docker-Daemon erst spät in Schritt 3) enden in `set -e`-Tod mit
Roh-Fehlermeldung. „Einfach erneut laufen lassen" gilt erst, wenn die
Ursache erraten ist.

Evidence:
Code-Lesung (kein Retry/Timeout/Preflight/df-Gate – grep-negativ);
GPG-Fingerprint als positives Gegenbeispiel (fail-closed vorhanden).

Reasoning:
Kein Sicherheits-, sondern Bedienbarkeitsdefekt am Happy-Path-Ende.
Wahrscheinlichkeit: mittel (Schulnetz!); Auswirkung: Zeitverlust +
Fehldiagnosen, kein Datenverlust.

Required change:
Preflight-Block vor Schritt 3 (Ports 80/443/9090/9100/3001 per `ss -tlnp`
mit Prozess-Hinweis + Docker-Daemon + Mindestplatz); Retry-Schleife
(max. 3, mit Schlaf) für apt/curl/pull mit Ursachen-Log. Kein
Hammer-Retry gegen LE-/APT-Limits.

Do not change:
Keine endlosen Retries; keine Retry-Logik um LE-Ausstellung (Budget!);
`set -e`-Charakter des Skripts bleibt.

Dependencies:
Keine.

Regression risks:
Gering. Zu aggressive Retries könnten Limits treffen – deshalb max. 3 mit
dokumentierten Ausnahmen (LE/APT ausgenommen).

Required test:
T-041 (offline → klarer Fail + Heilung), T-042 (Registry-Block),
T-030–T-032 (Kill → Re-Run heilt), Port-Konflikt-Probe (Alt-Listener auf
80 → lesbare Meldung).

Rollback:
Preflight-/Retry-Blöcke entfernen.

---

### B-014 – `reset-passwords.sh`: Hex-Annahme vs. Reparaturpfad, DB-zuerst-Fenster, Grafana-Fenster

Classification:
LIKELY

Priority:
SHOULD_FIX

Severity:
MEDIUM

Related Finding:
F-010 (P-018, 01/F-005)

Location:
`setup-coder.sh` L894 (Vollständigkeits-Regex `[^[:space:]]+`, kein
Hex-Zwang), L944–947 (unquotiertes Heredoc `<<INNER_EOF` mit
String-Interpolation), L957–964 (Grafana-Fenster), L911–915
(`.bak`-Rotation via `ls | tail | xargs`).

Problem:
(a) Hand-reparierte `.env` mit Sonderzeichen/Quotes passiert die Prüfung,
bricht aber `ALTER USER … '${NEW_PW}'` bzw. `grafana-cli … "${NEW_GF_PW}"`
(Spaces) – sicher nur solange alle Passwörter Hex bleiben, erzwungen wird
das nirgends. (b) Abbruch zwischen `ALTER USER` und `.env`-Tausch:
DB=neu/`.env`=alt → verzögerter Lockout mit Zündung beim nächsten Reboot;
Trap warnt, heilt nicht; Grafana drittes Fenster. (c) `.bak`-Rotation bei
exotischen Namen brüchig (kontrollierte Namen – brüchig, nicht kaputt).

Evidence:
Code-Lesung (Reihenfolge + Quoting + Regex); P-018-Reihenfolge bewusst
vertagt (IMPLEMENTATION-REPORT B-10). Live-Abbruch nie durchgespielt –
daher LIKELY, nicht CONFIRMED.

Reasoning:
Selbstgebauter Lockout, Diagnose ohne Klartext-Log schwer.
Wahrscheinlichkeit: niedrig (braucht Abbruch im Sekunden-Fenster oder
Hand-Edit mit Sonderzeichen); Auswirkung: hoch bei Treffer (Lockout);
Reproduzierbarkeit: per SIGTERM-Probe belegbar.

Required change:
Hex-Validierung für beide Passwort-Schlüssel (Setup, Reset, Refresh –
fail-closed statt still brechen); Trap-Texte pro Fenster trennen (PG vs.
Grafana vs. `.env`); P-018-Reihenfolge (.env-zuerst vs. DB-zuerst) per
Test-VM-Beweis entscheiden statt vertagen (D-Entscheidung mit Beweis, kein
Redesign ohne Test-VM).

Do not change:
DB-zuerst-Reihenfolge bis zur entschiedenen Probe (kein stilles
Redesign); Vorab-Backup + `.bak` (eine Generation) + STDIN-Muster bleiben.

Dependencies:
D-P-018-Entscheidung; T-033 als Beweis-Setup.

Regression risks:
Gering (Validierung fail-closed; Reihenfolge erst nach Beweis).

Required test:
T-033 (SIGTERM vor Tausch → Warnung + `.bak` + Anleitung; Re-Run heilt ohne
Doppel-Würfeln) + Sonderzeichen-`.env` (muss abgewiesen werden, nicht
still brechen).

Rollback:
Regex-/Trap-Zeilen revertieren; Reihenfolge unverändert lassen.

---

### B-015 – Volle Platte: TSDB ohne Größenbremse, 500-MB-Gate willkürlich, Ausfall ohne Alarm

Classification:
LIKELY

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
P-007 (03/F-004/F-008, 05/F-007/F-016, 06/F-007/F-016)

Location:
`setup-coder.sh` L305 (nur `retention.time=15d`, kein `retention.size`,
grep-negativ); `MIN_FREE_BYTES=524288000` ohne Plattenbezug; kein
`check.sh`, kein Alerting (`prometheus.yml` 2 Jobs ohne Alert-Sektion);
Logging-Limits vorhanden (ok-Seite).

Problem:
Kardinalitäts-Spike → Platte voll trotz 15d. 500-MB-Boden auf kleiner VM
Dauer-Rot (Warnungsmüdigkeit) oder auf großer VM wirkungslos – geraten
statt gemessen. `logger`-Calls teils ohne `|| true` (bei defektem `/dev/log`
falscher Exit-Pfad). Niemand liest Cron-Logs täglich. Voll = Postgres-
Schreibfehler, kein Backup, APT blockiert.

Evidence:
Code-Lesung + grep-Negativnachweise; df-Gate-Code vorhanden aber
unvermessener Bodenwert. Live-Plattenvoll-Szenario nie gefahren – daher
LIKELY (Mechanik belegt, Auslösung szenarioabhängig).

Reasoning:
Wahrscheinlichster schleichender Totalausfall. Wahrscheinlichkeit: mittel
über Lebensdauer (wächst mit Workspaces/Metriken); Auswirkung: total
(Server lahm, kein Backup, Blockade); Reproduzierbarkeit: per tmpfs-Probe
belegbar.

Required change:
D-Monitoring + D-Ressourcen beschließen (Messauftrag: Plattenkapazität,
`docker stats`-Woche, Schwellen, Leser – kein Fantasiewert); danach
`retention.size` konservativ nach Messung setzen + minimaler `check.sh`
(Backup-Alter + `df` + `/healthz`, per `logger`/Mail an Eigentümer).
Bis dahin: 500-MB-Wert als „konservativ, un vermessen" kommentieren (kein
Raten als Fix tarnen).

Do not change:
Kein geratener `retention.size`-Wert ohne Messung (falsche Bremse löscht
Metriken oder wirkt nicht – beides schlechter); kein voller Alertmanager
(überdimensioniert, siehe 06/F-007).

Dependencies:
Messung auf (Test-)VM mit realer Plattengröße; B-010 (Backup-Alter-Signal).

Regression risks:
Mittel bei falschem Wert (Dauer-Rot oder wirkungslos) – deshalb Messung
zuerst, konservativ danach.

Required test:
T-067 (LogConfig + Flut-Rotation), T-079 (200-MB-Retention-Probe), T-073
(tmpfs-voll → klarer Abbruch ohne Finaldatei), T-077 (`logrotate --debug`
+ Fail-Signal).

Rollback:
`retention.size` entfernen, `check.sh` aus Cron nehmen.

---

### B-016 – Kleine Robustheitslücken: `logger` ohne Guard, SIGKILL-Orphans, Reset-Teillöschung

Classification:
CONFIRMED

Priority:
SHOULD_FIX

Severity:
MEDIUM

Related Finding:
F-004/F-005 (P-016)

Location:
`setup-coder.sh` L651/L667/L677 (`logger` ohne `|| true`; L640/L689 haben
es – inkonsistent); `TMP=...tmp.$$` + `trap EXIT` (SIGKILL/Reboot nicht
abfangbar → `.tmp.*`- und `.env.tmp.*`-Orphans, Rotations-Glob matcht nie);
Reset-Schleife (zeilenweises `volume rm` unter `set -e`, kein Pre-Check).

Problem:
(a) Fällt `logger` aus, exitt `backup.sh` mit Logger-Code statt
Backup-Diagnose. (b) Orphans (600/root, harmlos, aber ewig). (c) Ein Volume
in Benutzung → Abbruch nach `compose down` + Teillöschung: weder alt noch
neu lauffähig, kein dokumentierter Weiterweg.

Evidence:
Grep (3× ohne, 2× mit Guard) + Unix-Trap-Semantik + Reset-Lesung.

Reasoning:
Je einzeln klein, gemeinsam fehlerpfadverschleiernd. Wahrscheinlichkeit:
niedrig bis mittel; Auswirkung: gering bis mittel (irreführender Exit-Code,
Plattenkrümel, halb zerlegter Stack).

Required change:
`|| true` an allen reinen Signal-`logger`s vereinheitlichen; Orphan-Sweep
beim Backup-Start (stale `.tmp.*` älter als N Stunden löschen, nur eigenes
Muster); Reset: `docker volume inspect`-Vorabprüfung (Benutzung) vor `down`
+ Teillöschungs-Fall ins Runbook.

Do not change:
`trap EXIT`-Struktur bleibt; kein Fortsetzen-bei-Fehler im Reset (lieber
harter Abbruch vor Zerstörung als stilles Überspringen).

Dependencies:
Keine (B-020 ergänzt Reset-Seite).

Regression risks:
Minimal (Guards + Sweep eigenes Muster + lesender Pre-Check).

Required test:
T-072 (Abbruch → keine Finaldatei + keine Orphans nach Sweep), T-102
(Fremd-Volume bleibt), T-103 (Leer-Fall → Abbruch vor `rm .env`).

Rollback:
Guards/Sweep/Pre-Check entfernen (reine Additionen).

---

### B-017 – `CODER_DISABLE_PATH_APPS` fehlt (Cookie-Missbrauch über Path-Apps)

Classification:
CONFIRMED

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
P-006 (04/F-002)

Location:
`setup-coder.sh` L271 (`CODER_WILDCARD_ACCESS_URL` gesetzt),
`CODER_DISABLE_PATH_APPS` grep-negativ abwesend.

Problem:
Path-Apps teilen Origin mit Dashboard/API; Workspace mit clientseitigem
Code kann Session-Cookies desselben Benutzers für API-Aufrufe missbrauchen.
Upstream-Best-Practice verlangt für genau diese Konstellation das
Deaktivieren. Seit Plan-Streichung ohne Eigentümer.

Evidence:
Umgebungsblock per Lesung + Upstream-Best-Practice-Zitat in 04/F-002 +
Abwesenheit per grep.

Reasoning:
Angriffsszenario: bösartiger/kompromittierter Workspace-Code im selben
Browser → Session-Missbrauch. Wahrscheinlichkeit: niedrig (braucht
Angreifer-Workspace + Opfer im selben Browser); Auswirkung: hoch
(Account-Takeover); Reproduzierbarkeit: per Pfad-vs-Subdomain-Probe.

Required change:
Template-Inventar (`coder_app` ohne `subdomain = true` → auf `subdomain`
umstellen), dann `CODER_DISABLE_PATH_APPS=true` setzen. Inventar mit B-004
zusammenlegen (ein Durchgang). Pfad-vs-Subdomain als T-126 beweisen.

Do not change:
Kein Flag ohne Inventar (Regression real: legitime Pfad-Apps brechen);
keine Template-Umstellung ohne PR-Abnahme.

Dependencies:
B-004-Inventar zuerst (gemeinsamer Durchgang).

Regression risks:
Mittel ohne Inventar (brechende Templates) – deshalb gated: erst Inventar,
dann Flag.

Required test:
T-126 (Pfad-URL abgelehnt 4xx, Subdomain-URL funktioniert; vorher Inventar).

Rollback:
Flag entfernen (eine Zeile) + Templates zurückstellen.

---

### B-018 – Workspace-Daten + `.env`-Verlust: größte reale Verlustklasse ohne Konzept

Classification:
CONFIRMED

Priority:
SHOULD_FIX

Severity:
HIGH

Related Finding:
P-024 (05/F-015, 06/F-008)

Location:
Backup-Umfang = nur `pg_dump` (DB-Dump; 5 Compose-Volumes, 1 gesichert);
`.env`/Configs/Zertifikate/Dashboards/Workspaces ungesichert oder nur per
Re-Run rekonstruierbar; RPO in keinem Finding mit Eigentümer.

Problem:
DB-Restore funktioniert (Pfad B korrekt dokumentiert), aber alle
Workspace-Dateien (Schülerarbeiten) leben außerhalb jedes Backups.
Verlustrealisierung trotz „täglichem Backup". Ehrliche Gap-Doku ohne
Beschluss, Frist, Kommunikation.

Evidence:
Backup-Scope per Lesung + offene Blocker im IMPLEMENTATION-REPORT;
T-083 nie ausgeführt.

Reasoning:
Sozial größter Schaden (alle Schülerarbeiten), technisch kein Code-Defekt,
sondern fehlende RPO-Entscheidung. Wahrscheinlichkeit: mittel (Serververlust
oder Reset); Auswirkung: hoch (Arbeiten weg); kein Angriff.

Required change:
D-Workspace-Daten beschließen (was verspricht die Schule bei Serververlust,
wem, mit welcher RPO?) + Kommunikationssatz (z. B. Git-Push-Pflicht mit
Anleitung) oder Server-Backup-Umfang erweitern (laufende Container berührt
– deshalb Entscheidung, kein Einzeiler). `.env` verschlüsselt ins Offsite
(Schlüssel getrennt vom Host).

Do not change:
Kein stiller Volume-Backup-Einzeiler ohne Entscheidung (konsistente Dumps
laufender Container + Secrets im Backup = neue Risiken); kein
unverschlüsseltes `.env`-Offsite.

Dependencies:
D6 (Offsite-Entscheidung, B-008) trägt `.env`-Teil.

Regression risks:
Keine Code-Regression (Entscheidung + Kommunikation); falsche
Backup-Erweiterung hätte welche – deshalb Entscheidung zuerst.

Required test:
T-083 (Datei in Workspace → Backup+Restore → Gap heute: weg; nach Beschluss:
da oder per Push-Pflicht abgedeckt).

Rollback:
Kommunikationssatz zurückziehen; kein Code zum Rollen.

---

### B-019 – Abschlusscheck prüft Apex, nicht Wildcard (Workspace-Apps still kaputt)

Classification:
CONFIRMED

Priority:
SHOULD_FIX

Severity:
MEDIUM

Related Finding:
P-023 (04/F-006/F-007)

Location:
`setup-coder.sh` L1206–1218 (nur `https://${DOMAIN_CODER}/healthz` + lokales
`getent`; keine Wildcard-Probe, kein App-Routing, kein On-Demand-Erstaufruf).

Problem:
Wildcard-DNS fehlt → Setup `[OK]`, Exit 0; Workspace-Apps/Port-Forwarding
(eigene Subdomains, On-Demand-Erstverzögerung 5–30 s) scheitern ab Montag –
Entdeckung durch Nutzer statt Check. Apex-OK wird als Gesamt-OK gelesen.

Evidence:
Check-Volltext per Lesung; Wildcard-Abwesenheit per grep-negativ;
T-120/T-124 nie ausgeführt.

Reasoning:
Fehlende DNS-Zeile (Kopfkommentar fordert beides) bleibt grün.
Wahrscheinlichkeit: mittel (Wildcard wird leicht vergessen);
Auswirkung: mittel (Kernfunktion Apps kaputt, aber behebbar per DNS +
Re-Run); Reproduzierbarkeit: per Negativprobe belegbar.

Required change:
DNS-Probe für Apex + Wildcard getrennt (gegen autoritativen Server, nicht
nur lokales `getent`) als WARN mit Wiedervorlage; App-Smoke (T-124) nach
erstem Workspace. Kein Fail (Setup soll bei fehlender Weiterleitung
starten + warnen, Kopfkommentar-Prinzip bleibt).

Do not change:
Warn-statt-Fehler-Charakter des Checks bleibt; kein „fertig"-Eindruck ohne
– aber auch kein harter Fail bei legitimer Verzögerung.

Dependencies:
Keine.

Regression risks:
Gering (lesende Proben + Warnung). Falsch-Positive bei langsamem DNS –
deshalb WARN, nie Fail.

Required test:
T-120 (A/AAAA/Wildcard/CAA), T-124 (App über Subdomain Ende-zu-Ende),
Wildcard-Negativprobe (Wildcard fehlt → WARN erscheint).

Rollback:
Probe-Zeilen entfernen.

---

### B-020 – Reset: Teillöschung ohne Rollback, Koexistenz brüchig, `--force` per Pipe fütterbar

Classification:
LIKELY

Priority:
SHOULD_FIX

Severity:
MEDIUM

Related Finding:
F-004/F-011 (P-016/P-019)

Location:
`setup-coder.sh` L1029–1157 (`reset-coder.sh`): `down --remove-orphans`
vor Volume-Löschung; `PROJECT` aus `docker compose config | awk '/^name:/'`
(versionsabhängig, kein Fallback-Test); TTY-Guard nur ohne `--force`
(L1038–1042); Inventar ohne Label-Spec (L1053–1063); Aufräum-Hinweis erst
nach Löschung (L1153–1155).

Problem:
(a) Volume in Benutzung → `set -e`-Abbruch nach `down` + Teillöschung
(halb zerlegt, `.env` bleibt – fail-closed, aber inkonsistent, Weiterweg
nur „Setup erneut" gegen halb gelöschte Volumes). (b) Zweites
Compose-Projekt: falscher Projektname → `down` lief bereits (Netz weg,
Container gestoppt), Leer-Guard schützt nur `.env`. (c) `echo
RESET-OHNE-BACKUP | reset-coder.sh --force`: Zwei-Geheimnisse-Zustimmung,
aber per Pipe/Automatisierung fütterbar, landet in Shell-History.
(d) Verwaiste Workspace-Container: Operator unterscheidet Workspaces nicht
von Test-Containern; Hinweis nach Löschung (Neuaufbau → Namens-/Port-
Konflikte).

Evidence:
Reset-Volltext per Lesung; Dialog-Reihenfolge (Backup → Bestätigung →
Zweitphrase) korrekt, Mechanik darunter mit Restkanten. Live-Reset nie
gefahren – daher LIKELY.

Reasoning:
Destruktivster Pfad des Repos mit schmalen, echten Kanten.
Wahrscheinlichkeit: niedrig (braucht belegtes Volume / Zweitprojekt /
Pipe-Missbrauch); Auswirkung: mittel bis hoch (halb zerlegter Stack);
Reproduzierbarkeit: per Test-VM belegbar.

Required change:
Pre-Checks (Volume-Benutzung via `inspect` vor `down`, Abbruch **vor**
Zerstörung); Coder-Workspace-Label recherchieren (B-11) + gestoppte
Workspaces/Volumes einbeziehen; `--force`-Semantik als Break-Glass-Freigabe
(wer darf, mit Nachweis) statt nur Phrase dokumentieren; Aufräum-Hinweis
vor die Löschung ziehen (bereits Inventar oben – Hinweis nur
umplatzieren, kein neuer Mechanismus).

Do not change:
Zwei-Stufen-Bestätigung (Backup-Status + Zweitphrase) bleibt; Leer-Guard
vor `rm .env` bleibt; Zertifikate/Backups bleiben unangetastet.

Dependencies:
B-11-Label-Recherche; B-016-Pre-Check-Muster.

Regression risks:
Gering (lesende Pre-Checks + Hinweis-Umzug). Schärfere Guards könnten
legitime Resets blockieren – deshalb klare Meldung mit Weiterweg.

Required test:
T-100 (Backup-Fail ohne `--force` → nichts gelöscht), T-101
(Zweitbestätigung + frischer Backup-Status), T-102 (Fremd-Volume bleibt),
T-103 (Leer-Fall), T-104 (Inventar vor Löschung), T-105 (Backups +
Zertifikate bleiben, DB/Grafana/Prometheus + `.env` weg), T-106 (Pipe ohne
Flag verweigert).

Rollback:
Pre-Check-Zeilen entfernen; Hinweistext zurückverschieben.

---

### B-021 – Caddy 2.10: Wildcard-/On-Demand-Verhalten geändert, Site-Form ungeprobt

Classification:
LIKELY

Priority:
MUST_FIX

Severity:
HIGH

Related Finding:
B-005/B-019 (04-Coder-Summary)

Location:
`setup-coder.sh` L78 (`CADDY_VERSION:=2.10`, Minor-Pin), L408–416
(Site-Block Apex + `*.…` in einem Block, `tls { on_demand }`, kein
`dns`-Provider, kein `force_automate`).

Problem:
Seit Caddy 2.10 werden verwaltete Wildcard-Zertifikate für einzelne
Subdomains bevorzugt (#6959); echte Wildcards brauchen DNS-01 (LE-Pflicht),
das wir nicht haben. Offenes Issue #6996: On-Demand-Wildcard-Sites brechen
in 2.10 andere passende Sites („no certificate available"). Ob Apex,
Erst-Subdomain und Folge-Subdomains in unserer Ein-Block-Form je ein
einzelnes On-Demand-Zertifikat bekommen – oder in die 2.10-Präferenz laufen
– ist mit dem gepinnten Image nie per Handshake getestet (nur
`validate`/`adapt` ohne Handshake).

Evidence:
Code-Fakt (Version + Site-Form) + Caddy-v2.10.0-Release-Notes + Automatic-
HTTPS-Doku (beide abgerufen 27.09.2026) + offenes Upstream-Issue. Live-
Handshake nie ausgeführt – daher LIKELY (Upstream-Beleg stark,
Host-Betroffenheit ungeprüft).

Reasoning:
Trotz grünem Setup + gültigem Apex-Zertifikat können Workspace-App-
Subdomains per TLS-Handshake ausfallen – exakt die Funktion, für die
On-Demand eingeführt wurde. Wahrscheinlichkeit: mittel (hängt von
2.10.x-Stand + LE-Pfad ab); Auswirkung: hoch (Kernfunktion Apps);
Reproduzierbarkeit: per Handshake-Serie belegbar.

Required change:
Kompatibilitätsnachweis mit exakt gepinntem Image auf Testdomain **vor**
Produktionsfreigabe: Apex + echte App-Subdomain + zwei zufällige
Fake-Subdomains (je Subject/SAN/Issuer/Ablauf + Caddy-Log auf `obtaining
certificate` / `no certificate matching` / `on_demand`-Flags; Erst- vs.
Zweit-Handshake-Latenz). Ergebnis ins Repo. Bei Fehlschlag: D-TLS-Pfad
(B-005) statt Workaround raten. Langfristig: Caddy exakt pinnen oder
2.10.x-Änderungen als Update-Ereignis behandeln (B-009).

Do not change:
Kein `force_automate`/DNS-01-Schnellschuss ohne Nachweis (Workaround raten
gegen Upstream-Issue = neues Risiko); kein Caddy-Downgrade ohne Beschluss.

Dependencies:
B-002 zuerst (Test-VM-Stack muss pullbar sein); speist D-TLS (B-005).

Regression risks:
Keine Code-Regression (Nachweis zuerst). Späterer Fix je nach Befund –
deshalb gated.

Required test:
B-021-Handshake-Serie (neu, keine T-Nummer) + T-124/T-125. Wenige
Versuche/Woche (LE-Budget, B-005). Nie Produktion.

Rollback:
Kein Code zum Rollen (Nachweis-Artefakt bleibt); eventueller Folge-Fix
separat revertierbar.

---

# Blocking Issues

Vor jedem Produktionslauf zu schließen (Voraussetzung = Reihenfolge):

0. **PLAN-Reparatur (P-001/T-006-Voraussetzung):** `ai-review/PLAN.md`
   behauptet 26 Findings, enthält F-001–F-012 mit abgebrochenem F-012-Satz;
   D4–D9/F-019/F-021 dangling. Entweder F-013–F-026 wiederherstellen oder
   ehrlich auf F-001–F-012 kürzen (Zahlen + Referenzen fixieren). Ohne das
   ist T-006 rot und jede „vollständig nach Plan"-Aussage unbelegt.
1. **B-001** (Cron-Deadlock) – ohne das existiert kein Tages-Backup.
2. **B-002** (Coder-Tag) – ohne das stirbt Erstinstallation/Update/Reset-
   Neuaufbau in Schritt 3.
3. **B-003 + B-009-Gate** (kein Auto-Prune, `/healthz`-Gate) – Update sonst
   ohne Rückweg und ohne Krankheitsnachweis.
4. **B-010** (Backup-Aussagekraft: Leer = Fail, Mini-Restore-Pflicht, Skip
   mit Alter) – sonst „Backup OK" ohne SQL-Semantik.
5. **B-008** (Offsite-Entscheidung + Pfad-A-Fix + Runbook auf Server + Probe
   mit RTO-Zahl) – Plattenverlust heute Totalverlust, Pfad A ungeprobt
   defekt.
6. **B-015-Entscheidung** (Messung + `retention.size` + `check.sh`-Leser) –
   sonst tötet der schleichendste Ausfall das verifizierte Backup.
7. **B-004-Inventar + Selbsttest** (D-Socket mit Frist) – sonst steht jede
   Sicherung auf kompromittierbarer Basis.
8. **B-005-Erkennung + B-021-Nachweis** (D-TLS mit Frist) – Fremd-DoS und
   2.10-Semantik bleiben sonst offen.
9. **B-017-Inventar → Flag** – Cookie-Pfad bleibt sonst offen.
10. **B-006-Skriptfix + D-SSH** (Termin, Zweit-Zugang, Härtungsdatum) – kein
    grünes Dauer-Provisorium.
11. **B-007** (Defaults + kein stilles SSH-Downgrade + Bindungsregel +
    IPv6-Deklaration; DOCKER-USER als Entscheidung) – sonst falsches
    Schutzgefühl + Re-Run revertiert Härtung.
12. **B-011** (Boot-Gate + Grace + Healthcheck + Betriebsfenster) – sonst
    rebootet der Server planmäßig blind.

# Required Changes (MUST_FIX, sichere Reihenfolge)

1. PLAN-Reparatur (Blocking 0 – kein Code, aber Freigabe-Voraussetzung).
2. B-002 (Tag-Form + Kommentar + beidseitige Pull-Probe).
3. B-001 (äußeren `flock` entfernen + Kommentar).
4. B-003 (Prune-Zeile entfernen + Kommentar).
5. B-010 (Leer = Fail, Vorwert-Warnung, Mini-Restore-Automatisierung,
   Skip mit Backup-Alter).
6. B-008-Code: Pfad-A-Verfahren (`dropdb`/`createdb` oder
   `--clean --if-exists`) + Runbook auf Server ablegen (oder Verweise
   fixieren).
7. B-009-Gate (`/healthz` + Caddy-TLS-Smoke + Backup-Alter-Log +
   sudo-Konvention).
8. B-011 (Boot-Gate lesend + `stop_grace_period` Postgres +
   Coder-Healthcheck + Caddy-`depends_on` + Betriebsfenster-Doku).
9. B-007 (UFW-Defaults + Re-Run-Downgrade-Warnung + Bindungsregel-Doku +
   IPv6-Deklaration).
10. B-006-Skript (Post-Check-Enforcement + SK-/Cert-Regex +
    Provisoriums-Alter-Log).
11. B-005-Erkennung (Kommentar + `obtaining certificate`-Monitoring) +
    B-021-Nachweis (Handshake-Serie mit gepinntem Image).
12. B-004-Prozess (Erstinventar + Abhakpflicht + T-063-Selbsttest-Protokoll).
13. B-017 (Inventar-Auswertung → `CODER_DISABLE_PATH_APPS=true`).
14. B-015 nach Messung (`retention.size` + `check.sh` + Leser).

# Recommended Changes (SHOULD_FIX)

- B-009-Split (`app` vs. `db`, mit Doku des neuen Bedienvertrags).
- B-012 (Drift-Warnung + `jail.local`-Include).
- B-013 (Preflights + max-3-Retries mit Ausnahmen).
- B-014 (Hex-Validierung + getrennte Trap-Texte; P-018-Reihenfolge per
  Test-VM-Beweis entscheiden).
- B-016 (Logger-Guards + Orphan-Sweep + Reset-Pre-Check + Runbook-Eintrag).
- B-018-Entscheidung (Workspace-RPO + Kommunikationssatz).
- B-019 (Apex + Wildcard-DNS-Probe als WARN + App-Smoke).
- B-020 (Reset-Pre-Checks + Label-Recherche + Break-Glass-Doku +
  Hinweis-Umzug).

# Optional Changes

- `pid: host` bei node-exporter entfernen oder begründen (Hygiene, K3 –
  kein Breaker-Befund, kein Ausfallnutzen).
- Caddy exakt pinnen statt Minor-Pin (langfristig, nach B-021-Befund).
- ShellCheck-Kosmetik (SC2034/SC2012, End-Newline – 01/F-006, kein
  Ausfallnutzen, nur bei Anfassen der Zeilen nebenbei).
- `mem_limit` erst nach `docker-stats`-Woche (K4/B-13 – Messauftrag, kein
  geratener Wert).

# Rejected Findings

Kein Breaker-Befund (B-001–B-021) wurde als FALSE_POSITIVE verworfen – alle
halten der Code-Prüfung stand (B-001/B-002 zusätzlich live/upstream-belegt,
B-003/B-005/B-021 per Upstream-Doku belegt, Rest per Lesung +
grep-Negativnachweise).

Abgelehnt wird ausschließlich eine externe Nebenbehauptung (kein
Breaker-Fund): `chatty_review.md` Nr. 2 (`[[ … =\~ … ]]`-Syntaxfehler) –
am HEAD falsch (L151 enthält korrekt `=~`, `bash -n` grün). Ein „Fix" dort
würde funktionierenden Code beschädigen. Korrigiert wurde außerdem die
B-002-Nebenbehauptung „Mainline-Zweig": v2.36.6 ist laut Release-Seite
Stable – ändert nichts am Fix.

# Decisions Required (nicht vom Implementierer zu setzen)

- **D-PLAN:** PLAN.md vervollständigen oder kürzen (Blocking 0).
- **D-Offsite (D6/B-02):** Ziel, Verschlüsselung, Schlüsselverwahrung
  (getrennt vom Host), Retention, Transport-Secrets, Verfallsdatum für
  Leer-Zustand – Eigentümer + Frist.
- **D-SSH (B-03):** Key-Rollout-Termin, Zweit-Zugang-Bestätigung,
  Härtungsdatum – Eigentümer + Datum.
- **D-Socket (B-11):** Allowlist dauerhaft vs. Socket-Proxy vs. separater
  Provisioning-Host – Eigentümer + Frist.
- **D-TLS (B-05):** echter `ask` vs. DNS-01-Wildcard (+ CAA, Provider-Token,
  Custom-Build) – Eigentümer + Frist.
- **D-Firewall (B-04):** DOCKER-USER ja/nein nach Dual-Stack-Test.
- **D-Monitoring/Ressourcen (B-07):** `retention.size`-Wert nach Messung,
  `check.sh` vs. Alerting, Schwellen, Leser (Eigentümer).
- **D-Reboot-Fenster (B-011):** 03:00 mit Betrieb abstimmen + Wartungsplan.
- **D-Passwort-Reihenfolge (B-10/P-018):** DB-zuerst vs. `.env`-zuerst nur
  per Test-VM-Beweis.
- **D-Workspace-RPO (B-018):** Versprechen der Schule + Kommunikation
  (Git-Push-Pflicht oder Server-Backup).
- **D-Update-Split (B-14/K5):** `app`/`db`-Trennung + DB-Major-Prozess.
- **D-Caddy-Pin:** exakt vs. Minor nach B-021-Befund.

# Implementation Order

0. PLAN-Reparatur (D-PLAN) – Freigabe-Voraussetzung, kein Code.
1. B-002 → B-001 → B-003 (Installierbarkeit → Backup-Existenz →
   Rollback-Basis; jeweils einzeilig, kein Zusammenspiel).
2. B-010 → B-008-Code → B-015-Messung/Entscheidung (Backup-
   Glaubwürdigkeit → Restore-Verfahren → Plattenbremse).
3. B-009-Gate → B-011 (Update-Gesundheit → Boot-Gesundheit, Muster
   wiederverwenden).
4. B-007 → B-006-Skript (Firewall-Policy → SSH-Pfad; beide mit
   Entscheidungen D-Firewall/D-SSH parallel einholen).
5. B-021-Nachweis → B-005-Erkennung → D-TLS (Beweis vor Modellwahl).
6. B-004-Inventar → B-017-Flag (ein Inventar-Durchgang, dann Flag).
7. SHOULD-Reihe beliebig: B-016 → B-014 → B-019 → B-012 → B-013 → B-020
   (kleinste, entkoppelte zuerst) + B-009-Split + B-018-Entscheidung.
8. Nach jedem Block: betroffene TEST_PLAN-Tests auf Test-VM mit Artefakt.

# Regression Test Matrix

| Fix | Test(s) | Bestehenskriterium |
|---|---|---|
| PLAN-Reparatur | T-006 | Exit 0, keine Dangling Refs, kein Trunkierungsmarker |
| B-002 | Pull-Probe beider Tag-Formen + T-010 | `:2.36.6` pullbar (Protokoll), Fresh Install grün |
| B-001 | Cron-Pfad-Probe + T-074/T-076 | Cron-Lauf erzeugt Backup, kein Selbst-Skip |
| B-003 | T-053/T-092 | Altes Image nach `update.sh` vorhanden |
| B-010 | T-070/T-071/T-072/T-080 | Leer = Fail, Verkleinerung = kein Fail, Mini-Restore grün |
| B-008 | T-080/T-082/T-083 | Restore nur aus Offsite + Runbook, RTO-Zahl im Repo |
| B-009 | T-050/T-090/T-091/T-092/T-093 | Bad-Version scheitert selbst, `/healthz`-Gate greift |
| B-011 | T-034/T-110/T-111/T-112/T-113 | Boot-Log + Gesundheit nach Reboot/Daemon-Restart |
| B-007 | T-060/T-062/T-120 + Re-Run-Downgrade-Probe | Scan wie erwartet, Re-Run warnt statt revertiert |
| B-006 | T-061 + SK-Key-Probe | Nachbedingung enforced, SK-/Cert-Keys kein falscher Abbruch |
| B-005 | T-004/T-123/T-125 | Ist-Beleg Fake-Subdomain, danach Erkennungs-Log |
| B-021 | Handshake-Serie (neu) + T-124 | Zertifikat je Host + Caddy-Log im Repo |
| B-004 | T-063/T-064 | Selbsttest-Protokoll + abgehakte Allowlist |
| B-017 | T-126 | Pfad 4xx, Subdomain funktioniert |
| B-015 | T-067/T-073/T-077/T-079 | Rotation statt Wachstum, tmpfs-Abbruch sauber |
| B-016 | T-072/T-102/T-103 | Keine Orphans, kein Logger-Fehl-Exit |
| B-014 | T-033 + Sonderzeichen-Probe | Warnung + `.bak` + Heilung; Sonderzeichen abgewiesen |
| B-012 | T-026 | Drift-Meldung + deterministische Regeneration |
| B-013 | T-030–T-032/T-040–T-042 + Port-Probe | Klare Meldung + Heilung nach Ursache |
| B-019 | T-120/T-124 + Wildcard-Negativprobe | Fehlende Wildcard → WARN |
| B-020 | T-100–T-106 | Nichts gelöscht ohne Freigabe, Fremd-Volumen bleibt |
| B-018 | T-083 | Gap belegt oder Beschluss-abgedeckt |
| Static Gates je Änderung | T-001/T-002/T-003/T-004/T-007 | Syntax, ShellCheck, Compose, Caddy, Harness-Selbsttest |

Alle VM-Tests: isolierte Test-VM (`coder-test-<datum>`, Debian 13,
Snapshot-fähig), Testdomain (nie `coder.ghse-unterricht.de`),
Protokollpflicht (Datum, VM-Name, Commit, Tool-Versionen, Exit-Codes,
Logs). „Bestanden" nur mit Artefakt, nie per Lesung. Nie Produktion.

# Definition of Done (Version 2)

1. Alle MUST_FIX-Änderungen (Blocking 1–12) implementiert, jede mit
   mindestens einem Test aus obiger Matrix, bestanden mit Artefakt auf
   Test-VM.
2. Static Gates grün: T-001, T-002 (Haupt + alle Heredocs + `ssh-harden.sh`),
   T-003, T-004, T-007 – plus T-006 nach PLAN-Reparatur (Blocking 0).
3. Alle D-Entscheidungen (D-PLAN, D-Offsite, D-SSH, D-Socket, D-TLS,
   D-Firewall, D-Monitoring, D-Reboot-Fenster, D-Passwort-Reihenfolge,
   D-Workspace-RPO, D-Update-Split, D-Caddy-Pin) mit Eigentümer + Datum/Frist
   im Repo festgehalten; Offene ohne Frist gibt es nicht.
4. RTO als Zahl im Repo (Datum, Versionen, Dump-Alter) + Offsite-Probe grün
   (lesbare, aktuelle, entschlüsselbare Sicherung außerhalb der VM).
5. Template-Erstinventar + T-063-Selbsttest-Protokoll im Repo; B-021-
   Handshake-Nachweis im Repo.
6. Keine Änderung ohne zugeordneten Test; kein Test als „bestanden" ohne
   Artefakt; keine Produktivserver-Befehle im Rahmen dieser Runde.
7. Bekannte Restrisiken (ufw-Umgehung als Doku, Socket als übernommene
   Tutorial-Architektur, Provisorien mit Verfallsdatum) stehen mit
   Eigentümer + Frist im Repo statt als Kommentar-Hoffnung im Skript.

Ausdrückliche Feststellung: Kein Befund fordert ein großes Refactoring.
Der belastbarste nächste Stand entsteht aus kleinen, gezielten Fixes +
belegten Tests, nicht aus Umbauten (kein Proxy-Einbau, keine Timer- oder
Template-Migration, kein Alertmanager, keine Digest-Umstellung in dieser
Runde).
