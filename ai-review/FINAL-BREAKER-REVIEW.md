# FINAL-BREAKER-REVIEW – Adversarial Security + Reliability

Stand: 2026-09-27. Geprüft: `setup-coder.sh` (1248 Zeilen, HEAD `570db50`),
`ssh-harden.sh`, `RESTORE.md`, `templates/allowlist.md`,
`ai-review/PLAN.md` (F-001–F-012, abgebrochen), `ai-review/PLAN-REVIEW.md`
(P-001–P-025), `ai-review/TEST_PLAN.md`, `ai-review/IMPLEMENTATION-REPORT.md`
sowie `ai-review/chatty_review.md` (Stand 26.09.2026 18:26, am 27.09.2026 in
diesen Review übernommen und danach gelöscht – übernommen: Nr. 1, 3, 5–18;
verworfen: Nr. 2, siehe Nicht-Befund unten; Lobabschnitte entfallen
rollenbedingt).

Rolle: Breaker, nicht Lober. Jede Verifikation unten wurde tatsächlich
ausgeführt (Code-Lesung am HEAD, Live-Repro wo gefahrlos möglich,
Upstream-Doku per Abruf am 27.09.2026). Keine Codeänderung, keine
Produktivbefehle.

Verifiziert und **nicht** bestätigt (kein Befund, Warnung vor falschem Fix):
Die Behauptung aus `chatty_review.md` Nr. 2 (`[[ ... =\~ ... ]]`,
Syntaxfehler/Blocker) trifft auf den aktuellen HEAD **nicht** zu – Zeile 151
enthält korrekt `=~`, `bash -n` ist grün, Regex-Probe (`997` → OK) läuft.
Die Variante mit Backslash stammt nachweislich aus der
Markdown-Einfügung des Fremd-Reviews (deren eigene Vorab-Warnung, Z3).
Ein „Fix" dort würde funktionierenden Code beschädigen.

---

## B-001 – Cron-Backup läuft nie: doppeltes `flock`-Deadlock auf derselben Datei

Severity:
CRITICAL

Reproduction scenario:
Normaler erster Installationslauf (Setup grün, Test-Backup per Direktaufruf
OK), danach Alltag: Cron feuert täglich um 01:00. Es entsteht nie ein
Cron-Backup. Entdeckt wird das erst im Ernstfall (Restore nötig, nur ein
uraltes Direkt-Test-Backup vorhanden). Zweiter/dritter Lauf ändern nichts –
der Cron-Eintrag bleibt defekt.

Evidence:
- `setup-coder.sh` L733 (Cron-Zeile): `/usr/bin/flock -n
  /opt/coder/backups/.backup.lock /opt/coder/backup.sh`
- `setup-coder.sh` L637–638 (in `backup.sh` selbst):
  `exec 9>"${BACKUP_DIR}/.backup.lock"` + `if ! flock -n 9` → Skip mit
  Exit 0.
- Live-Repro (gefahrlos, nur `/tmp`): `flock -n /tmp/breaker-test.lock
  flock -n /tmp/breaker-test.lock true` → Exit 1. Der äußere `flock` hält den
  Lock während `backup.sh` läuft; der innere `flock -n` auf derselben Datei
  scheitert deterministisch. Jeder Cron-Lauf wird als „Vorgänger läuft noch"
  übersprungen.

Impact:
Totalschaden mit Zeitverzögerung: Das einzige Backup, das je existiert, ist
das manuelle Setup-Test-Backup. Ab Tag 2 altert es still. Der Setup-Check
(L777–786) ruft `backup.sh` **direkt** auf (ohne äußeren `flock`) und meldet
`[OK]` – die Verifikation ist blind für den Cron-Pfad. Backup-Rotation,
`gzip -t`, `df`-Gate – alles irrelevant, weil nie ausgeführt.

Expected behavior:
Cron-Lauf erzeugt täglich ein verifiziertes Backup; innerer und äußerer Lock
schließen sich nicht gegenseitig aus.

Observed/problematic behavior:
Cron-Lauf skipt sich selbst immer (Exit 0 + Logger-Zeile, kein Alarm).
Direktaufruf funktioniert – perfekte Tarnung.

Recommended fix:
Äußeren `flock` aus `/etc/cron.d/coder-backup` entfernen (innerer
Selbst-Lock in `backup.sh` schützt Cron, `update.sh` und manuelle Läufe
gemeinsam). Danach Cron-Pfad separat testen (nicht Direktaufruf).

Related finding:
IMPLEMENTATION-REPORT behauptet fälschlich „Selbst-flock UND flock in
Cron-Zeile" als korrekte Doppelabsicherung; P-017/P-014; T-074/T-076.

Test:
`sudo /usr/bin/flock -n /opt/coder/backups/.backup.lock
/opt/coder/backup.sh; echo $?` muss ein Backup erzeugen (nicht skippen);
danach `/var/log/coder-backup.log` auf „übersprungen"-Zeile beim Cron-Takt
prüfen. Nur Test-VM.

Classification:
CONFIRMED

---

## B-002 – `CODER_VERSION=v2.36.6`: Image-Tag mit `v`-Präfix vermutlich unpullbar

Severity:
CRITICAL

Reproduction scenario:
Normaler erster Installationslauf auf frischer Debian-13-VM: Schritt 1–2
grün, Schritt 3 `docker compose pull` / `up -d` scheitert, weil
`ghcr.io/coder/coder:v2.36.6` nicht existiert. Setup bricht unter `set -e`
mit Docker-Fehlermeldung ab; Schritte 4–10 laufen nie.

Evidence:
- `setup-coder.sh` L77: `: "${CODER_VERSION:=v2.36.6}"`, Kopfkommentar
  behauptet, das Tag brauche das `v`-Präfix.
- Upstream (abgerufen 27.09.2026): GitHub-Release `v2.36.6` nennt als
  Container-Image wörtlich `docker pull ghcr.io/coder/coder:2.36.6` (ohne
  `v`); ebenso `v2.36.1` → `coder:2.36.1`. Git-Tag (`v…`) ≠ Image-Tag.
- Vergleich: `PROMETHEUS_VERSION=v3.14.0` (mit `v` korrekt),
  `GRAFANA_VERSION=12.4.5` (ohne `v` korrekt) – nur Coder ist inkonsistent.
- Kein Gegenbeweis im Repo: `compose config --quiet` (L441) validiert nur
  YAML, kein Pull; T-050/T-090 nie ausgeführt (keine Test-VM).

Impact:
Falls kein `v`-Aliastag existiert: frische Installation ist auf Anhieb tot,
ebenso jeder `update.sh`-Lauf und jeder Reset-Neuaufbau. Der Skriptkopf
verteidigt die falsche Schreibweise mit Nachdruck, sodass der Fehler als
„Upstream-Problem" misdiagnostiziert wird. Verschärfend: der Pin liegt auf
dem Mainline-Zweig (2.36 = Mainline, nicht Stable) und ist bereits
überholt – v2.37.x existiert (seit 01.09.2026, inkl. Agents-GA und
Tasks-Deprecation ab v2.37). Ein bloßes „Tag korrigieren" ohne
Versionsentscheidung greift zu kurz.

Expected behavior:
Gepinnte Defaults sind pullbar; ein Pin-Change wird per `docker pull`
verifiziert, bevor er Default wird; der Pin-Zweig (Stable vs. Mainline) ist
bewusst gewählt und dokumentiert.

Observed/problematic behavior:
Default-Pin widerspricht dem offiziell dokumentierten Pull-Befehl; kein Test
hat je gepullt; Pin-Entscheidung (Mainline, überholt) nie getroffen.

Recommended fix:
Default auf `2.36.6` korrigieren **und** vor Merge `docker pull
ghcr.io/coder/coder:2.36.6` sowie Negativprobe `:v2.36.6` auf Test-VM
protokollieren. Pin-Existenz in Zukunft pro Version belegen. **Kein**
opportunistisches Hochziehen auf 2.37.x im selben Zug: Major-Update nur
einzeln mit verifiziertem Dump (Tasks-Deprecation, Agents-GA – Migrations-
und Downgrade-Risiko, siehe B-009).

Related finding:
chatty_review Nr. 3 (zutreffend); K1/D4 (Digest vs. Tag – Tag-Form muss
zumindest stimmen); T-003 (config ≠ pullbar).

Test:
Test-VM mit Netz: `docker pull ghcr.io/coder/coder:2.36.6` (muss gehen),
`docker pull ghcr.io/coder/coder:v2.36.6` (Ergebnis protokollieren). Nie
Produktion.

Classification:
LIKELY

---

## B-003 – Prune-`until=24h` schützt kein Rollback: `until` misst Image-Erstellung, nicht Dangling-Zeitpunkt

Severity:
HIGH

Reproduction scenario:
`update.sh`-Normalpfad: `pull` (Caddy `2.10` / `postgres:15-alpine` sind
beweglich) → altes Image wird dangling → `docker image prune -f --filter
"until=24h"` löscht es sofort, weil das alte Image vor Wochen **erstellt**
wurde. Rollback („alte Version setzen + Setup erneut") braucht Re-Pull.
Ohne Netz im Ernstfall: kein Rückweg.

Evidence:
- `setup-coder.sh` L834–836 (eingebettetes `update.sh`): Kommentar „behält
  die Images von gestern für einen schnellen Rollback" + `docker image
  prune -f --filter "until=24h"`.
- Docker-Referenz (abgerufen 27.09.2026): „`until` – only remove images
  **created before** given timestamp"; Beispiel: `until=24h` prunt „images
  … **created more than 24 hours ago**". Entscheidend ist das
  Erstellungsdatum, nicht wann das Image dangling wurde.
- Bewegliche Tags aus Skriptkopf (Caddy `2.10`, `postgres:15-alpine`) machen
  genau diesen Pfad zum Normalfall.

Impact:
Falsches Sicherheitsgefühl im Ernstfall: Update-Fehlschlag + „Rollback wie
kommentiert" → altes Image weg, Re-Pull nötig, ggf. mit neuem (inkompatiblem)
Patchstand. Kommentar beschreibt Zerstörung als Schutz.

Expected behavior:
Entweder tatsächlicher Rollback-Schutz (alte Image-IDs vorher sichern) oder
kein automatisches Pruning direkt nach dem Update.

Recommended fix:
`prune`-Zeile entfernen (Platte ist auf Schul-VM kein akuter Engpass; alte
Images sind der billigste Rollback) oder vor `pull` laufende Image-IDs
(`docker images --digests`) in Datei sichern und gezielt behalten.
Kommentar korrigieren.

Related finding:
chatty_review Nr. 5 (zutreffend); P-020; T-053/T-092 (nie ausgeführt).

Test:
Test-VM: zwei reale Caddy-Tags fahren, nach `update.sh` prüfen ob altes
Image noch da ist (Soll heute: weg → Befund bestätigt, Fix: da).

Classification:
CONFIRMED

---

## B-004 – Docker-Socket im Coder-Container: Host-Takeover-Pfad ohne technische Schranke

Severity:
CRITICAL

Reproduction scenario:
Kompromittierter Workspace (Schüler-Code, Template mit zu viel Recht, oder
Coder-Provisioner-CVE): Angreifer erreicht Coder-Control-Plane oder ein
Template erlaubt Socket-Mount/`privileged`. Über
`/var/run/docker.sock` (schreibbar gemountet, L276, plus `group_add:
${DOCKER_GID}`, L265–266) startet er einen Container mit Host-Mounts
(`-v /:/host`) und liest `.env`, Backups, oder schreibt sich Persistenz.
AGENTS.md erklärt Workspace-Nutzer für untrusted – genau dieser Pfad ist
unreguliert.

Evidence:
- `setup-coder.sh` L275–276: `- /var/run/docker.sock:/var/run/docker.sock`
  (kein `:ro`, kein Proxy); L265–266 `group_add`.
- `templates/allowlist.md` existiert, ist aber reine Doku: kein
  Enforcement, kein Pre-Receive-Hook, Erstinventar „offen" (BLOCKER B-11),
  Workspace-Selbsttest (T-063) nie ausgeführt.
- Coder-Upstream dokumentiert das Socket-Muster – übernommene
  Tutorial-Architektur, keine Fehlkonfiguration, aber auf diesem Host die
  weitreichendste Vertrauensgrenze.

Impact:
Host-root-Äquivalenz ab Coder-Kompromittierung: Secrets (DB, Grafana),
Backups (unverschlüsselt), UFW/fail2ban-Konfig – alles les-/schreibbar.
Jede Backup-/Restore-Verbesserung steht auf kompromittierbarer Basis.

Expected behavior:
Mindestens: Allowlist wird pro Template abgehakt (Reviewer + Datum),
Workspace-Selbsttest ist grün dokumentiert; Socket-Modell hat Eigentümer +
Frist (Proxy/separater Host als Entscheidung).

Observed/problematic behavior:
Doku ohne Zwang, Inventar offen, Tests offen – jede künftige
Unterrichtsanforderung („Docker-in-Docker für die Klasse?") ist eine
unsichtbare Sicherheitsentscheidung.

Recommended fix:
Sofort: Template-Erstinventar nachholen + Abhakpflicht pro Template-PR
(T-064). Mit Frist: D-Socket entscheiden (Allowlist dauerhaft vs.
Socket-Proxy vs. separater Provisioning-Host). Negativ-Selbsttest aus
Workspace (`/var/run/docker.sock`, `postgres:5432`, fremde Container)
protokollieren.

Related finding:
P-002; 02/F-001; 06/F-005; B-11; T-063/T-064.

Test:
T-063/T-064 auf Test-VM mit normalem Workspace (Mount-, Socket-,
DB-Erreichbarkeits-, Fremdcontainer-Probe). Nie Produktion.

Classification:
CONFIRMED

---

## B-005 – On-Demand-TLS mit `ask http://example.com`: LE-Budget-DoS plus Hostnamen-Leak an Dritten

Severity:
HIGH

Reproduction scenario:
Beliebiger Internet-Teilnehmer (kein Coder-Account nötig) spricht
`zufall123.coder.ghse-unterricht.de` per TLS an. Caddy fragt
`http://example.com?domain=zufall123.…` (immer 200) und stößt eine echte
Let's-Encrypt-Ausstellung an. Wiederholt mit vielen Namen → 50-Zertifikate-
Wochenbudget der registrierten Domain `ghse-unterricht.de` (geteilt mit allen
anderen Schuldiensten) ist aufgebraucht → legitime neue Workspace-Apps
bekommen in derselben Woche kein Zertifikat (TLS-Fehler im Unterricht).
Parallel sieht ein US-Dritter per Klartext-HTTP jeden angefragten
Workspace-Hostnamen.

Evidence:
- `setup-coder.sh` L401–416: `ask http://example.com` + `tls { on_demand }`
  für Apex **und** Wildcard (Kommentar L14–16 suggeriert fälschlich nur
  Wildcard sei betroffen).
- Caddy-Source (`modules/caddytls/ondemand.go`, abgerufen 27.09.2026):
  `qs.Set("domain", name)` per HTTP-GET, 10 s Timeout, kein Redirect-Follow.
  Caddy-Doku: „this endpoint is not exposed publicly to avoid a minor
  information leak" – hier geht der Leak **an** einen öffentlichen Dritten.
- LE-Rate-Limit 50/Woche pro registrierter Domain (Upstream-Doku).
- Keine Erkennung implemeniert (kein `obtaining certificate`-Monitoring,
  kein Alarm); Kommentar P-005a dokumentiert nur.

Impact:
Fremd auslösbarer, accountloser Teil-DoS aufs Zertifikatsbudget +
systematischer Hostnamen-Abfluss (Schulkontext: ggf. personenbeziehbar) +
Erst-Handshake hängt an Erreichbarkeit/Latenz von `example.com`.

Expected behavior:
Echter `ask`-Endpunkt (Allowlist) oder DNS-01-Wildcard (Entscheidung D-TLS
mit Frist); bis dahin Erkennung (Caddy-Log-Monitoring) + ehrliche Doku
(Apex ebenfalls on-demand, Budget gehört `ghse-unterricht.de`).

Observed/problematic behavior:
Tutorial-Muster 1:1 übernommen, Schutzbehauptung („kleine Klasse
unkritisch") falsch, kein Sensor.

Recommended fix:
Kurzfristig: `CODER_DISABLE_PATH_APPS=true` erst nach Template-Inventar
(B-017); Caddy-Log auf `obtaining certificate` überwachen (einfacher
`check.sh`/Logger statt vollem Alertmanager). Mit Frist: D-TLS entscheiden
(echter ask vs. DNS-01 + CAA).

Related finding:
P-005/P-006; 02/F-011; 04/F-001/F-003/F-006/F-007; chatty_review Nr. 7/8
(zutreffend); T-004/T-124/T-125.

Test:
T-125 (Fake-Subdomain-Handshake + Caddy-Log) auf Testdomain; T-123
(Issuer/Kette/Ablauf). Wenige Versuche/Woche (Budget!).

Classification:
CONFIRMED

---

## B-006 – SSH: weltweit offen + Passwort-Login aktiv, Setup meldet trotzdem Erfolg

Severity:
HIGH

Reproduction scenario:
Normaler erster Lauf: UFW `limit 22/tcp` (weltweit), `PasswordAuthentication
yes` (Kommentar L31–34 gibt es zu), Abschlusscheck nur `warn`
(L555–560, L1235–1242), `ERROR_COUNT` bleibt 0 → Exit 0. Zustand versteinert
über Lehrerwechsel/Passwort-Weitergabe zum Dauerzustand. Verteilter
Angriff / kompromittiertes Passwort umgeht Rate-Limit + fail2ban.
SSH-Passwort = Host = Docker-Admin = `.env` + Backups + DB.

Evidence:
- `setup-coder.sh` L28–34 (Design-Entscheid weltweites SSH), L480 (`limit`),
  L555–560/L1235–1242 (nur Warnung, kein Fail).
- `ssh-harden.sh` existiert, wird aber **nie** vom Setup aufgerufen;
  Härtungsdatum/Eigentümer offen (B-03). Lücken im Härtungsskript selbst:
  keine Nachbedingung (nach `reload` wird `sshd -T` nur **ausgegeben**,
  L62–63 – bei ignoriertem Drop-In (fehlendes `Include`) exitt das Skript
  trotzdem 0); Key-Regex L30 erkennt keine FIDO2-SK-Keys
  (`sk-ssh-ed25519@…`, `sk-ecdsa-sha2-…`) und keine `-cert-v01@…`-Zertifikate
  → falscher Abbruch; `PermitRootLogin no` (L50) sperrt Root-Key-Admins ohne
  Prüfung, welches Konto der bestätigte Zugang nutzt.

Impact:
Grünes Setup im unsichersten zulässigen Zustand; Härtungspfad vorhanden,
aber ohne Termin, ohne Zweit-Zugangs-Nachweis und mit Lockout-Kanten
(Root-Login, fehlendes Include, SK-Keys).

Expected behavior:
Provisorium mit Verfallsdatum (Eigentümer + Termin + Zweit-Zugang-Nachweis);
Härtungsskript mit Nachbedingung (nach Reload müssen `no`/`no`/`no`
effektiv sein, sonst Exit ≠ 0).

Observed/problematic behavior:
„Bescheid geben" ist kein Plan; Skript druckt Config statt sie zu
erzwingen.

Recommended fix:
D-SSH beschließen (Key-Termin, Zweit-Zugang-Bestätigung, Härtungsdatum);
`ssh-harden.sh` um Post-Check (`sshd -T` parsen, bei weiter `yes` Exit 1 +
Rollback-Hinweis) und SK-/Cert-Key-Muster ergänzen; Provisoriums-Alter ins
Setup-Log schreiben.

Related finding:
P-003; 02/F-007; 06/F-012; T-061.

Test:
T-061 (effektive Config vor/nach, externer Passwort-Login scheitert,
Key-Login gelingt, Ban separat). Nur mit Zweit-Zugang, nie Produktion ohne.

Classification:
CONFIRMED

---

## B-007 – UFW ohne Default-Policy, ohne DOCKER-USER; Re-Run weitet SSH still aus; IPv6 undeklariert

Severity:
HIGH

Reproduction scenario:
(a) Frischer Host mit unerwarteten UFW-Defaults (z. B. nach Härtungsdrift):
Skript setzt nie `default deny incoming` / `default allow outgoing`
(grep-negativ verifiziert) und verlässt sich auf Debian-Defaults.
(b) Jeder später hinzugefügte `ports:`-Eintrag (z. B. Workspace-Debugport)
erscheint öffentlich: Docker-iptables umgeht UFW (Kommentar L515–523 sagt es
selbst), keine `DOCKER-USER`-Kette, `ufw status` suggeriert Schutz.
(c) Operator härtet SSH zwischenzeitlich auf `10.16.0.0/12`-only; nächster
Setup-Re-Run (empfohlener Bedienweg!) löscht genau diese Regel (L472) und
setzt `limit 22/tcp` weltweit (L480) – stille Sicherheits-Downgrade.
(d) IPv6: weder als Betriebs- noch als Abschaltpfad deklariert; Monitoring
bindet `127.0.0.1` (nur v4-Loopback), Caddy `80/443` dual – ungetestet.

Evidence:
- Kein `default deny/allow` im gesamten Skript (grep-negativ).
- L470–472 Delete-Regeln, L480 `limit 22/tcp`, L524–527 allows + enable.
- Kein `DOCKER-USER`, kein `daemon.json` (grep-negativ); Loopback-Bindungen
  L310/L333/L348 beweisen nichts für künftige Ports.
- Abschlusscheck L530–575 prüft nur Anwesenheit, nie Defaults/Dual-Stack.

Impact:
Falsches Schutzgefühl bei Container-Ports; Re-Run als „sicherster Pfad"
(so beworben) ist der Pfad, der manuelle Härtung revertiert; IPv6-Seite
ungeprüft (offen oder kaputt – unbekannt).

Expected behavior:
Defaults explizit setzen; Bindungsregel-Disziplin („neue `ports:` nur
`127.0.0.1`, Ausnahme nur Caddy") + Review-Check; `DOCKER-USER` als
vorbereitete Entscheidung mit Dual-Stack-Test; Re-Run warnt bei
Abweichung von restriktiveren Operator-Regeln statt sie zu löschen.

Observed/problematic behavior:
Doku der UFW-Umgehung steht im Code, Konsequenz (Policy) fehlt; Re-Run
konvergiert auf weltweit-offen ohne Hinweis.

Recommended fix:
`ufw default deny incoming` / `allow outgoing` idempotent setzen;
Bindungsregel dokumentieren; D-Firewall (DOCKER-USER ja/nein) mit externem
Scan (TCP 22/80/443/9090/9100/3001 + UDP 443, `ss -tlnp`,
`iptables-save`/`nft`, Schulnetz-NAT-Abgleich) entscheiden; IPv6-Pfad
deklarieren.

Related finding:
P-004; 02/F-008–F-010; 06/F-006; chatty_review Nr. 15 (zutreffend);
T-013/T-060/T-062/T-120.

Test:
T-060 (externer Scan + ss + DOCKER-USER-Abgleich), T-062, T-120 (A/AAAA/
Wildcard/CAA). Nur Test-VM/Testdomain.

Classification:
CONFIRMED

---

## B-008 – Kein Offsite, kein geprobter Restore; Runbook-Pfad A über Leer-Schema wahrscheinlich defekt

Severity:
CRITICAL

Reproduction scenario:
Platten-/Host-Verlust (Quelle und alle Backups liegen auf derselben Platte,
`/opt/coder/backups`): DB + alle Backups weg – Totalverlust, irreversibel.
Oder weicherer Fall: `.env` verloren, Dump vorhanden. `RESTORE.md` Pfad B
behauptet Konsistenz ohne Abgleich (korrekt nur, weil `pg_dump` keine
Rollenpasswörter sichert – steht auch so drin). Pfad A (originale `.env` +
Dump in frischen Stack mit bereits angelegtem Leer-Schema) sagt: „Tabellen
per Dump überschreiben lassen, Fehlerprotokoll lesen statt `--clean` zu
raten" – Standard-`pg_dump` ohne `--clean`/`--if-exists` bricht aber an
jedem bestehenden `CREATE TABLE` ab bzw. produziert PK-Konflikte beim
`COPY`. Das Verfahren ist nie gelaufen (RTO-Tabelle: „offen"), also ist der
erste Restore-Versuch der erste Test – unter Druck, nachts, zum Semesterende.

Evidence:
- Einziger Schreibpfad `${BACKUP_DIR}` unter `/opt` (L632, L139–140); kein
  rsync/scp/rclone im Skript (grep-negativ); IMPLEMENTATION-REPORT und
  `RESTORE.md` geben Offsite- und Probe-Lücke offen zu (B-02/B-12).
- `RESTORE.md` L32–35 (Pfad A Schritt 4) ohne `dropdb`/`--clean`-Verfahren;
  kein `restore.sh`, kein Mini-Restore automatisiert.
- Das Setup-Skript selbst erzeugt `RESTORE.md` auf dem Server **nie**,
  verweist aber darauf: Kommentar L845 (Update-Hinweis „siehe RESTORE.md")
  und `reset-coder.sh`-Ausgabe L1088 („kein Ersatz für Restore-Test, siehe
  RESTORE.md"). Wer nur `setup-coder.sh`/`ssh-harden.sh` auf den Server
  kopiert, hat im Ernstfall Verweise auf ein Runbook, das dort nicht liegt.
- AGENTS.md verlangt Restore-Tests; es gibt null.

Impact:
„Tägliches Backup" schützt vor versehentlichem Reset/Update-Fehler, aber
nicht vor dem Fehlerszenario Platte/Host – und nicht einmal der
wiederherstellbare Pfad ist geprobt. Backup ohne geprobten Restore ist
Dekoration.

Expected behavior:
Offsite-Pflicht mit Eigentümer/Frist (Ziel, Verschlüsselung,
Schlüsselverwahrung getrennt vom Host, Retention); Runbook mit gemessener
RTO-Zahl (Datum, Versionen, Dump-Alter); Restore nach jedem Major-Update
erneut geprobt.

Observed/problematic behavior:
Leerer Offsite-Default + ungeprobtes Runbook mit wackeligem Kernschritt.

Recommended fix:
D6 ausformulieren (kein leerer Dauer-Default, Transportfehler ≠ lokaler
Fehler, getrennte Exit-Codes/Logs); Pfad A auf `dropdb --if-exists` /
`createdb` oder `--clean --if-exists`-Dump-Verfahren festlegen und genau das
in T-080–T-083 proben; RTO als Zahl ins Repo. `RESTORE.md` (oder ein
`restore.sh`) vom Setup auf dem Server ablegen lassen, damit die Verweise
L845/L1088 dort auflösen – oder die Verweise auf Repo-Pfad ändern.

Related finding:
F-002/F-003; P-014/P-015/P-024; 05/F-001/F-008/F-009/F-014/F-015;
chatty_review Nr. 9/10 (zutreffend); T-078/T-080–T-084.

Test:
T-082 (Snapshot verwerfen, nur aus Offsite + Runbook, Zeit stoppen),
T-080 (Mini-Restore in Wegwerf-Postgres statt nur `gzip -t`), T-083
(Workspace-Datei-Gap). Nur Test-VM.

Classification:
CONFIRMED

---

## B-009 – Update ohne echten Health-Nachweis, ohne Rollback, DB+App gekoppelt

Severity:
HIGH

Reproduction scenario:
Update-Normalpfad (`update.sh` L799–836): `backup.sh` (kann per B-001-Skip
mit Exit 0 „gelingen") → `pull` → `up -d --remove-orphans` → Gate prüft nur
`State.Running` aller Container + Postgres-`healthy` (L811–826). Ein Coder,
der läuft, aber wegen Passwort-Drift/fehlgeschlagener Migration keine
Requests bedient, ist „grün". Caddy-TLS, `/healthz`, Grafana/Prometheus
werden nie geprüft. Bei Coder-Schema-Migration ist das Schema beim Gate
bereits migriert – Downgrade startet ggf. nie wieder (Upstream-Vorbehalt,
im Kommentar ehrlich, als Guard fehlend). DB- und App-Images werden in einem
`pull` gezogen (K5-Entscheidung gegen Split) – aus Angst vor DB-Major wird
kein Coder-Patch gefahren.

Evidence:
- Gate L810–830 per Lesung (Running + PG-healthy, sonst nichts);
  Pre-Backup L801–803 ohne Frische-Unterscheidung (Skip = Exit 0);
  Prune L836 (B-003); Rollback-Kommentar L838–850 (nur Doku).
- `update.sh` nutzt bare `docker` (Setup: `sudo docker`) – läuft nur via
  sudo/Cron-Root stabil; inkonsistente Aufrufkonvention.

Impact:
Fehl-Update fällt im besten Fall durch Gate auf (besser als vorher), im
schlimmsten Fall als „grün" durch – ohne Rückweg (B-003) und ohne Trennung
von Risikoklassen. Brandmelder nach Brandstiftung.

Expected behavior:
Gate mit `/healthz`-200 innert Timeout + Caddy-TLS-Smoke; Prune-Guard oder
kein Prune (B-003); `app`/`db`-Trennung (Default `app`, DB nur explizit mit
verifiziertem Dump + Downgrade-Warnung).

Observed/problematic behavior:
Gate erkennt Crash, nicht Krankheit; Kommentar ersetzt Mechanik.

Recommended fix:
Gate um `/healthz` erweitern; Prune entfernen/Guard (B-003); Update-Pfad in
`app` (Coder/Caddy + Gate) vs. `db` (Postgres, explizit) trennen.

Related finding:
F-012; P-020; K5; 05/F-010; 06/F-004; T-050/T-053/T-090–T-093.

Test:
T-050/T-091 (Bad-Version muss selbst scheitern), T-090 (Normalpfad mit
Gate), T-092 (Rollback differenziert exakt vs. beweglich), T-093
(`app` lässt Postgres unberührt).

Classification:
CONFIRMED

---

## B-010 – Backup-„Verifikation" erklärt leere/fehlerhafte Dumps für gültig; Cron-Skip zählt als Erfolg

Severity:
HIGH

Reproduction scenario:
(a) `pg_dump` schreibt Fehlermeldungen nach stdout (statt Daten) oder stdin
ist leer: `gzip -t` ist grün, Größe ≥ 512 B möglich (Warnung nur < 512 B,
kein Fail) → Datei wird per `mv` zum „gültigen" Backup, rotiert unter den
neuesten 14. (b) Leerer Mini-Dump (< 512 B): Warnung ins Cron-Log, Datei
trotzdem final. Restore davon: `psql` läuft vakuos grün (keine Tabellen),
Coder startet mit leerem Schema – Datenverlust wird spät bemerkt.
(c) Cron-Skip (B-001) bzw. paralleler Zweitlauf: Exit 0 + Logger-Zeile –
für `update.sh`-Pre-Backup ununterscheidbar von „frisch gesichert".

Evidence:
- L663–689: `gzip -t` hart, Größe nur Warnung (`< 512`, kein Fail – bewusst
  gegen False-Positive bei frischer DB, aber damit auch kein Fail bei
  echter Leere); `mv` erst nach Prüfung (gut), aber Schwellwert zahnlos.
- L638–642: Zweitlauf-Skip Exit 0 (Design-Entscheid, aber ohne
  Frische-Signal an Aufrufer).
- Kein SQL-Gültigkeitsnachweis automatisiert (T-080 manuell, nie gelaufen).

Impact:
Stille Unbrauchbarkeit der einzigen Sicherung; „Backup OK"-Logzeile ohne
SQL-Semantik; Pre-Update-Gefühlssicherheit auf möglicherweise uraltem oder
leerem Stand.

Expected behavior:
Größenabweichung = Warnung mit Kontext (Relation zum letzten Dump), aber
Leere/Fehlertext = Fail; periodischer Mini-Restore automatisiert (nicht nur
Runbook-Satz); Skip meldet Alter des ersetzten Backups.

Observed/problematic behavior:
`gzip -t` beweist gzip, nicht Datenbank; Warnung ohne Leser (niemand liest
täglich Cron-Logs ohne Alerting).

Recommended fix:
Plausibilität als Warnung mit Vorwert-Vergleich; wöchentlicher
Mini-Restore in Wegwerf-Postgres als Pflicht (T-080) statt Satz;
`update.sh` bei Skip das Backup-Alter loggen lassen.

Related finding:
F-005; P-013; 05/F-003; chatty_review Nr. 10 (zutreffend); T-070–T-072.

Test:
T-071 (leeres stdin → Warnung, halbierte DB → kein Fail), T-072
(Fake-`pg_dump` bricht ab → keine Finaldatei), T-080 (Mini-Restore).

Classification:
CONFIRMED

---

## B-011 – Automatischer Reboot 03:00 ohne Ordnung und ohne Zeuge

Severity:
HIGH

Reproduction scenario:
Kernel-Update → `unattended-upgrades` rebootet 03:00 (L591–594) mitten in
langem Backup/Setup oder regulärem Betrieb. `dockerd` startet alle sechs
Container gleichzeitig (`restart: unless-stopped` überall, L241–352);
`depends_on`/`service_healthy` gilt nur für die Compose-CLI, nicht für
Daemon-Restart. Coder crash-loopt gegen unbereites Postgres; kein Boot-Gate,
kein Boot-Log, Schritt 10 läuft nur bei manuellem Setup. Erste Meldung:
Schüler morgens. Backup 01:00 vs. Reboot 03:00 vs. manuelles Update: drei
Akteure ohne Koordination.

Evidence:
- L591–594 Reboot-Config; L241–352 Restart-Policies; kein `stop_grace_period`
  für Postgres, kein Coder-HTTP-Healthcheck, kein `@reboot`-/Boot-Gate im
  gesamten Skript (grep-negativ); P-009 im Code unbehandelt.
- 03:00-Reboot trifft ggf. Schul-Übernacht-Jobs/Workspaces ohne
  Betriebsfenster-Abstimmung (Hinweis fehlt im Wartungsplan).

Impact:
Planmäßiger, automatisierter Reboot als wahrscheinlichste Reboot-Ursache –
ohne Gesundheitsnachweis danach. Selbstheilung (Crash-Loop bis Postgres
bereit) ohne Zeuge ist kein Betriebskonzept. Unabhängig von der
Boot-Reihenfolge reißt 03:00 laufende Workspaces, Schüler-/Lehrer-Sessions
und Übernacht-Jobs ab – ohne Abstimmung mit dem realen Betriebsfenster und
ohne Hinweis im Wartungsplan.

Expected behavior:
Lesendes Boot-Gate (Container gesund + `/healthz` innert N Minuten, sonst
`logger` + `/var/log/coder-boot.log`); `stop_grace_period: 30s` für
Postgres; Coder-Healthcheck + Caddy-`depends_on`-Kopplung (in Test-VM
verifiziert); Reboot-Zeit mit Betriebsfenster abgestimmt und im
Wartungsplan hinterlegt (Betroffene wissen, dass 03:00 alles abreißt).

Observed/problematic behavior:
Reboot-Automatik ohne Beobachtung; Update-Health (F-012) ja, Boot-Health
nein.

Recommended fix:
Boot-Gate + Grace-Period + Healthcheck wie oben; Docker-Engine-Pfad (B-013/
P-008) mitführen, damit Reboot-Grund (Debian-Kernel) und Docker-Alterung
nicht auseinanderlaufen.

Related finding:
P-009; 03/F-002/F-010; 06/F-010/F-011; chatty_review Nr. 17 (zutreffend);
T-034/T-052/T-110–T-113.

Test:
T-110 (Reboot + Boot-Log + erste 2 Min `docker logs coder`), T-111
(alle sechs nach Reboot), T-112 (Daemon-Restart), T-113 (Grace-Probe).

Classification:
CONFIRMED

---

## B-012 – Jeder Re-Run überschreibt Operator-Anpassungen still (Config-Clobber)

Severity:
MEDIUM

Reproduction scenario:
Zweiter/dritter Lauf nach manueller Nacharbeit: Operator hat
`retention.size` in `docker-compose.yml` ergänzt, Caddy-Snippet angepasst,
`recidive`-Jail in `/etc/fail2ban/jail.local` hinzugefügt oder Cron-Zeit
verschoben. Re-Run (`tee` ohne Diff, ohne Warnung: Compose L230–360,
Caddyfile L401–417, prometheus.yml L420–431, jail.local L492–500,
cron L732–734, logrotate L738–748, 52-coder-reboot L590–594) walzt alles
platt. Caddy/fail2ban haben Change-Detection nur für Restart-Entscheidung,
nicht für Drift-Meldung. Hand-Tuning ist auf diesem Host kein
Konfigurieren, sondern Verfallsmaterial.

Evidence:
Unbedingte `tee`-Schreibstellen per Lesung; kein Hash-Vergleich mit
Warnung, keine `.bak`, keine „Drift erkannt"-Meldung (T-026 erwartet genau
die – nicht implementiert; Report stellt „atomare Config-Generierung"
bewusst zurück).

Impact:
Gute Härtung (B-007-c-Fall ausgenommen – dort ist Clobber sogar
Downgrade) geht verloren; Operator lernt, nichts anzupassen; Diff zwischen
Repo und Host driftet.

Expected behavior:
Vor dem Schreiben Hash vergleichen; bei Drift warnen (und nur mit
`--force`/expliziter Bestätigung überschreiben) oder Operator-Overlay
(`*.local`-Includes) unterstützen.

Observed/problematic behavior:
Deterministisches Heilen erkauft mit deterministischem Vergessen.

Recommended fix:
Hash-Vergleich + Warnung (Caddy-Muster L399–457 auf alle generierten
Dateien ausweiten); `jail.local`-Operator-Jails per Include-Datei statt
Vollüberschreibung.

Related finding:
P-023/P-025; T-026; 06/F-003/F-009.

Test:
T-026 (Drift-Zeile einfügen → Re-Run muss melden + deterministisch
regenerieren; Re-Run ohne Änderung → kein Caddy-Restart).

Classification:
CONFIRMED

---

## B-013 – Keine Preflights, keine Retries: Netz-/Docker-/Port-Fehler brechen das Setup kommentararm ab

Severity:
MEDIUM

Reproduction scenario:
(a) Internet weg während Schritt 1/3: `apt-get update`, `curl … | gpg`,
`docker compose pull` ohne Retry/Timeout (außer Step-10-curl) → `set -e`-
Tod mit Roh-Fehlermeldung, Schritte danach entfallen. (b) Port 80/443 (oder
127.0.0.1:9090/9100/3001) belegt (Alt-Caddy, Test-Stack): `compose up -d`
scheitert, kein Hinweis „Port belegt – Prozess X". (c) Docker-Daemon tot:
`compose config --quiet` (L441) failt erst in Schritt 3 – `.env` wurde in
Schritt 2 bereits erzeugt (harmlos, da stabil, aber ohne Diagnose).
(d) Volle Platte während `tee` der Compose/Caddy-Dateien: kein `df`-Gate
(Backup hat eines, L647–654; Rest nicht) → partielle Dateien, Re-Run heilt
nur, weil alles überschrieben wird (B-012).

Evidence:
L103/L106/L125–126/L443 per Lesung (kein Retry, kein Timeout außer L1206);
kein `ss`-Bind-Check vor `up`; kein `df`-Gate außer Backup; GPG-Fingerprint
dagegen vorbildlich fail-closed (L114–118).

Impact:
Jeder banale Fehlerpfad (Schulnetz, belegter Port, voller Datenträger)
endet in Abbruch ohne Wegweiser; „einfach erneut laufen lassen" gilt erst,
wenn die Ursache erraten ist.

Expected behavior:
Begrenzte Retries mit Backoff + klarer Fehlermeldung (welcher Schritt,
welche Ursache, welcher Re-Run); Port-Preflight (`ss -tlnp` auf
80/443/9090/9100/3001) vor `up -d`; `df`-Mindestplatz vor apt/pull/dump.

Observed/problematic behavior:
Robustheit endet am Happy Path; Härtefälle (B-001 ausgenommen) sind
unbehandelt zurückgestellt (P-023-Non-Blocking).

Recommended fix:
Preflight-Block vor Schritt 3 (Ports + Docker-Daemon + Mindestplatz);
Retry-Schleife (max. 3, mit Schlaf) für apt/curl/pull mit Ursachen-Log;
kein Hammer-Retry gegen LE/APT-Limits.

Related finding:
P-023; T-026/T-030–T-032/T-040–T-045; AGENTS.md-Idempotenz (abgebrochener
Lauf, kein Netz, volle Platte).

Test:
T-041 (offline während apt → klarer Fail + Heilung nach Netz),
T-042 (Registry-Block), T-030–T-032 (Kill in Schritt 1/2/3 → Re-Run heilt),
Port-Konflikt-Probe (Alt-Listener auf 80 → lesbare Meldung erwartet).

Classification:
CONFIRMED

---

## B-014 – `reset-passwords.sh`: hex-Annahme vs. Reparaturpfad, DB-zuerst-Fenster, Grafana-Fenster

Severity:
MEDIUM

Reproduction scenario:
(a) Operator repariert `.env` von Hand (P-011-Pfad erlaubt das) mit
Sonderzeichen/Quotes: Vollständigkeits-Regex (`[^[:space:]]+`, L894) winkt
durch, was kein Hex ist. Danach `ALTER USER … WITH PASSWORD '…'` (L946, per
lokal expandiertem unquotiertem Heredoc L944) bricht an Quotes bzw. wird
injizierbar; Grafana-`reset-admin-password "${NEW_GF_PW}"` (L963, im
Container neu geparst) splittet an Spaces. Sicher nur, solange alle
Passwörter Hex bleiben – erzwungen wird das nirgends. (b) Abbruch zwischen
`ALTER USER` (L944–947) und `.env`-Tausch (L971–979): DB=neu, `.env`=alt –
jeder spätere `up`/Reboot startet Coder mit falschem Passwort (verzögerter
Lockout). Trap (L922) warnt und nennt `.bak`, heilt aber nicht; Grafana
(L957–964) hat ein eigenes drittes Fenster (DB neu, Grafana alt/neu, `.env`
alt). (c) `.bak`-Rotation „genau eine Generation" (L911–915) via
`ls | tail | xargs` – bei exotischen Namen brüchig (kontrollierte Namen,
daher nur brüchig, nicht kaputt).

Evidence:
Reihenfolge + Heredoc-Quoting (`<<INNER_EOF` unquotiert, L944/L952/L962)
per Lesung; Hex nur in Kommentaren, Regex prüft nur Nicht-Leere;
P-018-Entscheid (.env-zuerst) bewusst vertagt (IMPLEMENTATION-REPORT B-10).

Impact:
Selbstgebauter Lockout mit Zündung beim nächsten Reboot; Diagnose ohne
Klartext-Log (zu Recht) schwer; Hand-Reparaturpfad untergräbt die
Quoting-Sicherheit des Normalpfads.

Expected behavior:
Passwort-Alphabet erzwingen (Hex-Regex statt Nicht-Leer) oder
Quoting-feste Übergabe (Base64-/File-basiert, `psql -v` statt
String-Interpolation); Vorab-Backup als Rollback-Basis ist vorhanden (gut)
– zusätzlich `.env`-zuerst-Entscheidung per Test-VM-Beweis schließen.

Observed/problematic behavior:
Status-quo-DB-zuerst abgesichert (Backup, `.bak`, Trap, STDIN statt
`ps`-leakbar – alles gut), aber Fensterstruktur + Alphabet-Annahme offen.

Recommended fix:
Hex-Validierung für beide Passwort-Schlüssel (Setup, Reset, Refresh);
P-018-Reihenfolge per Test-VM entscheiden statt vertagen; Trap-Texte pro
Fenster (PG vs. Grafana vs. `.env`) trennen.

Related finding:
F-010; P-018; 01/F-005; T-033.

Test:
T-033 (SIGTERM vor Tausch → Warnung + `.bak` + Anleitung; Re-Run heilt ohne
Doppel-Würfeln), plus Sonderzeichen-`.env` (muss abgewiesen werden, nicht
still brechen).

Classification:
LIKELY

---

## B-015 – Volle Platte: TSDB ohne Größenbremse, 500-MB-Gate willkürlich, Ausfall ohne Alarm

Severity:
HIGH

Reproduction scenario:
Schul-VM mit kleiner Platte: Prometheus sammelt mit Kardinalitäts-Spike
(neue Coder-Agent-Metriken, B-004-Workspaces) – `retention.time=15d` (L305)
bremst Zeit, nicht Bytes. `retention.size` fehlt (grep-negativ).
Backup-`df`-Gate (500 MB, L647) failt geschlossen (gut), aber meldet nur
ins Cron-Log + Journal (`logger`, L651/667/677 teils ohne `|| true` –
bei defektem `/dev/log` falscher Exit-Pfad). Niemand liest das (kein
`check.sh`, kein Alerting, `prometheus.yml` hat nur 2 Scrape-Jobs ohne
Alert-Sektion). Voll bedeutet: Postgres-Schreibfehler, kein Backup, APT
blockiert – ungebremster TSDB-Stream legt den Server lahm.

Evidence:
L305 (nur `retention.time`); kein `retention.size`, kein `mem_limit`, kein
Alerting (Lesung); Logging-Limits dagegen vorhanden (L231–235 `10m×3`,
T-067-Seite ok); `MIN_FREE_BYTES=524288000` ohne Messung/Plattenbezug;
node-exporter misst, niemand wertet aus.

Impact:
Wahrscheinlichster schleichender Totalausfall; 500-MB-Boden kann auf kleiner
VM Dauer-Rot (falscher Alarm → Warnungsmüdigkeit) oder auf großer VM
wirkungslos sein – geraten statt gemessen.

Expected behavior:
`retention.size` an reale Platte angepasst (nach Messung); minimaler
`check.sh` (Backup-Alter + `df` + `/healthz`, per `logger`/Mail an
Eigentümer); Schwellwerte aus `docker stats`-Woche, nicht geraten.

Observed/problematic behavior:
Drei Plattenkiller (Logs ok, TSDB offen, Backup-Log rotiert ok) – einer
offen, keiner alarmiert.

Recommended fix:
D-Monitoring + D-Ressourcen beschließen (Messauftrag statt Fantasiewert);
bis dahin `retention.size` konservativ nach Plattenmessung setzen, nicht
raten.

Related finding:
P-007; 03/F-004/F-008; 05/F-007/F-016; 06/F-007/F-016; chatty_review Nr. 13
(zutreffend); T-067/T-073/T-077/T-079.

Test:
T-067 (LogConfig + Flut-Rotation), T-079 (200-MB-Retention-Probe),
T-073 (tmpfs-voll → klarer Abbruch ohne Finaldatei), T-077
(`logrotate --debug` + Fail-Signal).

Classification:
LIKELY

---

## B-016 – Kleine Robustheitslücken mit Assistenten-Potenzial: `logger` ohne Guard, SIGKILL-Orphans, `reset`-Teillöschung

Severity:
MEDIUM

Reproduction scenario:
(a) `logger`-Aufrufe L651/L667/L677 ohne `|| true` (L640/L689 haben es):
fällt `logger` aus (kein `/dev/log`, Journal down), exitt `backup.sh` unter
`set -e` mit dem Logger-Code statt mit Backup-Diagnose. (b) SIGKILL/Reboot
während Backup oder `.env`-Erzeugung: `trap EXIT` läuft nicht →
`coder_*.sql.gz.tmp.<pid>`- und `.env.tmp.XXXXXX`-Orphans (600/root,
harmlos, aber ewig – Rotations-Glob `coder_*.sql.gz` matcht `.tmp`-Suffix
nie, Cleanup nie). (c) `reset-coder.sh`: `docker volume rm` zeilenweise
(L1140–1143) – scheitert ein Volume (in Benutzung), bricht `set -e` nach
`compose down` + Teillöschung ab: halb zerlegt, kein Rollback, `.env` bleibt
(fail-closed, aber Stack weder alt noch neu lauffähig).

Evidence:
Logger-Zeilen per grep verifiziert (3× ohne, 2× mit Guard); Unix-Trap-
Semantik (SIGKILL unabfangbar); Reset-Schleife L1127–1143 per Lesung
(kein Fortsetzen-bei-Fehler, kein Pre-Check „in Benutzung").

Impact:
Je einzeln klein, gemeinsam: stille Plattenkrümel + irreführender Exit-Code
im Fehlerfall + halb zerlegter Stack nach Reset-Fehlschlag.

Expected behavior:
Einheitlich `|| true` an allen reinen Signal-`logger`s; Orphan-Sweep beim
Backup-Start (stale `.tmp.*` älter als N Stunden löschen, nur eigenes
Muster); Reset prüft Volume-Benutzung vor `down` und bricht **vor**
Zerstörung ab.

Observed/problematic behavior:
Inkonsistente Guards; Traps decken TERM/EXIT, nicht KILL (physikalisch
korrekt, operativ Lücke).

Recommended fix:
`|| true` vereinheitlichen; Sweep-Zeile + `docker volume inspect`-Vorab-
prüfung im Reset; Teillöschungs-Fall ins Runbook.

Related finding:
F-004/F-005; P-016; T-072/T-102/T-103.

Test:
T-072 (Abbruch → keine Finaldatei + keine Orphans nach Sweep), T-102
(Fremd-Volume bleibt), T-103 (Leer-Fall → Abbruch vor `rm .env`).

Classification:
CONFIRMED

---

## B-017 – `CODER_DISABLE_PATH_APPS` fehlt: Cookie-Missbrauch über Path-Apps bei gesetzter Wildcard

Severity:
HIGH

Reproduction scenario:
`CODER_WILDCARD_ACCESS_URL=*.${DOMAIN_CODER}` ist gesetzt (L271),
`CODER_DISABLE_PATH_APPS` fehlt (grep-negativ). Workspace mit
clientseitigem Code bedient Path-App unter Coder-Origin (`/@user/…/apps/…`):
Session-Cookies desselben Benutzers sind für API-Aufrufe missbrauchbar.
Upstream-Best-Practice verlangt für genau diese Konstellation das
Deaktivieren (Coder mildert teilweise, empfiehlt trotzdem explizit).

Evidence:
Umgebungsblock L267–274 per Lesung (kein `CODER_DISABLE_PATH_APPS`);
PLAN.md erwähnt die Variable nirgends (kommentarlos gestrichen); kein
Template-Inventar, welche `coder_app` ohne `subdomain = true` läuft –
Fix ohne Inventar bricht legitime Templates (Regression real, aber prüfbar).

Impact:
Origin-teilender App-Pfad bleibt offen, bis jemand das Inventar macht –
seit Plan-Streichung ohne Eigentümer.

Expected behavior:
Template-Inventar (`coder_app` ohne `subdomain = true` → auf `subdomain`
umstellen), dann `CODER_DISABLE_PATH_APPS=true` setzen.

Observed/problematic behavior:
Ein-Zeilen-Upstream-Härtung ersatzlos entfallen, nicht einmal als Non-Goal
mit Messauftrag.

Recommended fix:
B-06 schließen: Inventar → Umstellung → Flag; Pfad-vs-Subdomain-Verhalten
als T-126 auf Test-VM beweisen.

Related finding:
P-006; 04/F-002; T-126.

Test:
T-126 (Pfad-URL abgelehnt 4xx, Subdomain-URL funktioniert; vorher Inventar).

Classification:
CONFIRMED

---

## B-018 – Restore-Pfad B/`.env`-Verlust + Workspace-Gap: größte reale Verlustklasse ohne Konzept

Severity:
HIGH

Reproduction scenario:
Semesterende: Server weg (B-008) oder Reset gelaufen. DB-Dump vorhanden,
`.env` neu gewürfelt. Pfad B funktioniert für die DB (Rollenpasswort bleibt
Setup-neu – korrekt dokumentiert). Aber: alle Workspace-Dateien
(Schülerarbeiten, Repos, Hausaufgaben) leben außerhalb jedes Backups
(05/F-015, `RESTORE.md` gibt die Lücke zu). Niemand hat je entschieden
(Server-Backup vs. Git-Push-Pflicht) und niemand hat es kommuniziert.
Verlustrealisierung: trotz „täglichem Backup" sind alle Arbeiten weg.

Evidence:
Backup-Umfang = nur `pg_dump` (L663); 5 Compose-Volumes, 1 gesichert;
`.env`/Configs/Zertifikate/Dashboards/Workspaces ungesichert oder nur per
Re-Run rekonstruierbar; Workspace-Verantwortung (RPO!) in keinem Finding
mit Eigentümer (P-024/D5-Analog offen); T-083 nie ausgeführt.

Impact:
Sozial größter Schaden (alle Schülerarbeiten), technisch als „Gap
dokumentiert" abgelegt – Dokumentation ersetzt keine RPO-Entscheidung.

Expected behavior:
D-Workspace-Daten beschließen (was verspricht die Schule bei Serververlust,
wem, mit welcher RPO?), an Schüler/Lehrer kommunizieren; `.env`
verschlüsselt ins Offsite (Schlüssel getrennt vom Host).

Observed/problematic behavior:
Ehrliche Gap-Doku ohne Beschluss, ohne Frist, ohne Kommunikation.

Recommended fix:
RPO-Entscheidung + Kommunikationssatz (z. B. Git-Push-Pflicht mit
Anleitung) oder Server-Backup-Umfang erweitern (laufende Container berührt
– deshalb Entscheidung, kein Einzeiler).

Related finding:
P-024; 05/F-015; 06/F-008/D5; T-083.

Test:
T-083 (Datei in Workspace → Backup+Restore → Gap heute: weg; nach
Beschluss: da oder per Push-Pflicht abgedeckt).

Classification:
CONFIRMED

---

## B-019 – Abschlusscheck prüft Apex, nicht Wildcard: Workspace-Apps still kaputt

Severity:
MEDIUM

Reproduction scenario:
DNS für `coder.…` gesetzt und weitergeleitet, Wildcard `*.coder.…` fehlt
(Kopfkommentar fordert beides, L8–10). Setup-Check L1206 curlet nur
`https://${DOMAIN_CODER}/healthz` → `[OK]`, Exit 0. Workspace-Apps/Port-
Forwarding (eigene Subdomains, On-Demand-TLS mit 5–30 s Erstverzögerung)
scheitern ab Montag im Unterricht – kein Hinweis, kein Re-Run-Trigger.

Evidence:
L1206–1218 per Lesung (nur Apex-URL, nur `getent` als Zusatzdiagnose);
Wildcard-Erreichbarkeit, App-Routing und On-Demand-Erstaufruf nirgends
geprüft; T-124/T-120 nie ausgeführt.

Impact:
Grünes Setup, kaputte Kernfunktion (Apps/Vorschau) – Entdeckung durch Nutzer
statt durch Check.

Expected behavior:
Wildcard-Probe (zufälliger `*.DOMAIN`-Name auflösbar? mind. DNS-Probe +
Caddy-Log-Hinweis) als WARN mit Wiedervorlage; kein „fertig"-Eindruck ohne.

Observed/problematic behavior:
Apex-OK wird als Gesamt-OK gelesen.

Recommended fix:
DNS-Probe für Apex + Wildcard getrennt (`dig` gegen autoritativen Server,
nicht nur lokales `getent`); App-Smoke (T-124) nach erstem Workspace.

Related finding:
P-023; 04/F-006/F-007; T-120/T-122–T-124.

Test:
T-120 (A/AAAA/Wildcard/CAA), T-124 (App über Subdomain Ende-zu-Ende).

Classification:
CONFIRMED

---

## B-020 – Reset: Teillöschung ohne Rollback, Fremdprojekt-Koexistenz brüchig, `--force` per Pipe fütterbar

Severity:
MEDIUM

Reproduction scenario:
(a) `reset-coder.sh` nach erfolgreichem Backup: `compose down
--remove-orphans` (L1115), dann Volume-Löschung (L1140–1143) – ein Volume in
Benutzung → `set -e`-Abbruch: Container weg, Volumes teilweise weg, `.env`
noch da (fail-closed, aber Stack inkonsistent, kein dokumentierter
Weiterweg außer „Setup erneut" – das gegen halb gelöschte Volumes läuft).
(b) Host mit zweitem Compose-Projekt (z. B. `COMPOSE_PROJECT_NAME`-Lauf):
`PROJECT` aus `docker compose config | awk '/^name:/'` (L1047) – Feld
versionsabhängig, kein Fallback-Test im Repo; falscher Projektname →
Leer-Fall schützt (Abbruch vor `rm .env`, L1134–1138, gut), aber
`down --remove-orphans` lief bereits (Netzwerk weg, Container gestoppt).
(c) `echo RESET-OHNE-BACKUP | reset-coder.sh --force` bei Backup-Fehlschlag:
TTY-Guard (L1039) greift nur ohne `--force`; mit Flag + Phrase aus Pipe
löscht das Skript nicht-interaktiv – Zwei-Geheimnisse-Zustimmung (Flag +
Phrase), aber in Shell-History und per Automatisierung fütterbar.
(d) Verwaiste Workspace-Container (B-004): Inventar zeigt „alle
Nicht-Compose-Container" ohne Label-Spec (ehrlich, aber Operator kann
Workspaces von Test-Containern nicht unterscheiden); Hinweis auf manuelles
Aufräumen erst nach Löschung (L1153–1155) – nach Neuaufbau drohen
Namens-/Port-Konflikte.

Evidence:
Reset-Volltext L1029–1157 per Lesung; TTY-Guard L1036–1042; Zweitphrase
L1096–1100; Inventar L1053–1063; Aufräum-Hinweis L1153–1155.

Impact:
Destruktivster Pfad des Repos mit schmalen, aber echten Kanten:
halb zerlegt, Koexistenz ungeprobt, Break-Glass per Pipe möglich.

Expected behavior:
Benutzungs-Vorabprüfung vor `down`; Coder-Workspace-Label recherchieren
(B-11) und gestoppte Workspaces/Volumes einbeziehen; `--force`-Pipe nur mit
zusätzlicher expliziter Umgebungsbestätigung (statt Phrase-allein).

Observed/problematic behavior:
Dialog-Reihenfolge (Backup → Bestätigung → Zweitphrase) korrekt, Mechanik
darunter mit Restkanten.

Recommended fix:
Pre-Checks (Volume-Benutzung, Label-Recherche per Test-VM, T-104);
`--force`-Semantik als Break-Glass-Freigabe (wer darf, mit Nachweis) statt
nur Phrase dokumentieren.

Related finding:
F-004/F-011; P-016/P-019; 05/F-011–F-013; T-100–T-106.

Test:
T-100 (Backup-Fail ohne `--force` → nichts gelöscht), T-101
(Zweitbestätigung + frischer Backup-Status), T-102 (Fremd-Volume bleibt),
T-103 (Leer-Fall), T-104 (Workspace-Inventar vor Löschung), T-105
(Backups + Zertifikate bleiben, DB/Grafana/Prometheus + `.env` weg),
T-106 (Pipe ohne Flag verweigert).

Classification:
LIKELY

---

## B-021 – Caddy 2.10: Wildcard-/On-Demand-Verhalten geändert, unsere Site-Form ungeprobt

Severity:
HIGH

Reproduction scenario:
Setup mit exakt `caddy:2.10` (beweglicher Minor-Pin, löst heute 2.10.x):
Site-Block `${DOMAIN_CODER}, *.${DOMAIN_CODER}` mit `tls { on_demand }`
(L408–416). Seit Caddy 2.10 bevorzugt Caddy verwaltete Wildcard-Zertifikate
für einzelne Subdomains (#6959, Release-Notes v2.10.0); echte Wildcards
brauchen DNS-01 (LE-Pflicht), das wir nicht haben (kein Provider-Token,
kein Custom-Build). Offenes Upstream-Issue #6996 belegt: On-Demand-
Wildcard-Sites können in 2.10 andere, auf die Wildcard passende Sites
brechen („no certificate available", kein `ask`-Request geloggt,
Workaround `tls force_automate`). Ob Apex, Erst-Subdomain und
Folge-Subdomains in unserer Ein-Block-Form je ein einzelnes
On-Demand-Zertifikat bekommen – oder in die 2.10-Wildcard-Präferenz laufen
und hängen – ist am HEAD nie mit dieser Caddy-Version getestet (nur
`caddy validate`/`adapt` ohne Handshake, IMPLEMENTATION-REPORT).

Evidence:
- `setup-coder.sh` L401–416 (Caddyfile-Template); `CADDY_VERSION:=2.10`
  (L78, Minor-Pin – jede 2.10.x-Verhaltensänderung läuft per `pull` ein).
- Caddy v2.10.0 Release-Notes (abgerufen 27.09.2026): „Wildcards used by
  default … will be utilized for subdomains, rather than obtaining
  individual certificates"; „Prefer managed wildcard certs over individual
  subdomain certs (#6959)".
- Caddy-Doku „Automatic HTTPS" (abgerufen 27.09.2026): „As of Caddy 2.10,
  when automating a wildcard certificate, Caddy will use the wildcard
  certificate for individual subdomains … It will not get certificates for
  individual subdomains unless explicitly configured (e.g. with
  `force_automate`)"; „Let's Encrypt requires the DNS challenge to obtain
  wildcard certificates."
- Issue caddyserver/caddy#6996 (open, abgerufen 27.09.2026): „Caddy 2.10.0
  on-demand wildcard sites break other separate sites matching the
  wildcard" – mit Debug-Logs (`no certificate matching TLS ClientHello`,
  `on_demand: false` am betroffenen Host).
- Unsere Form (Apex + `*.…` in einem Block, `on_demand`, kein `dns`-Provider,
  kein `force_automate`) entspricht keinem der dokumentierten sicheren
  Muster.

Impact:
Trotz grünem Setup und gültigem Apex-Zertifikat können Workspace-App-
Subdomains per TLS-Handshake-Fehler ausfallen – exakt die Funktion, für die
On-Demand-TLS eingeführt wurde. Entdeckung im Unterricht statt im Test.
Bei greifender Wildcard-Präferenz ohne DNS-01 droht zusätzlich Dauerfehler
statt nur Erstverzögerung (5–30 s laut Kopfkommentar).

Expected behavior:
Vor Produktionsfreigabe ist mit exakt dem gepinnten Caddy-Image belegt:
Apex, eine Test-Subdomain und mehrere zufällige `*.DOMAIN`-Hosts bekommen
je das richtige Zertifikat (welches Subject/SAN, welcher Issuer, Erst- vs.
Folge-Handshake). Abweichung → `force_automate`- oder DNS-01-Entscheidung
(D-TLS, B-005).

Observed/problematic behavior:
Coder-Tutorial-Form 1:1 übernommen, 2.10-Semantikwechsel weder bemerkt noch
getestet; Minor-Pin lässt künftige 2.10.x-Änderungen still einlaufen.

Recommended fix:
Kompatibilitätsnachweis mit gepinntem Image auf Testdomain (siehe Test),
Ergebnis (Zertifikat je Host, Logs) ins Repo; bei Fehlschlag D-TLS-Pfad
wählen statt Workaround raten. Langfristig Caddy exakt pinnen oder
2.10.x-Änderungen als Update-Ereignis behandeln (B-009).

Related finding:
B-005/B-019; 04-Coder-Summary; T-004/T-124/T-125.

Test:
Testdomain mit DNS + Portweiterleitung, gepinntes Image:
`openssl s_client -connect` gegen Apex, eine echte App-Subdomain und zwei
zufällige Fake-Subdomains (je Subject/SAN/Issuer/Ablauf protokollieren) +
`docker compose logs caddy` auf `obtaining certificate` /
`no certificate matching` / `on_demand`-Flags; Erst- vs. Zweit-Handshake-
Latenz messen. Wenige Versuche/Woche (LE-Budget, B-005). Nie Produktion.

Classification:
LIKELY

---

## Blocking Findings

Vor jedem Produktionslauf zu schließen (Reihenfolge = Voraussetzung):

1. **B-001** (Cron-Deadlock): äußeren `flock` entfernen + Cron-Pfad-Test.
   Ohne das existiert kein einziges Tages-Backup – alles andere ist
   Dekoration.
2. **B-002** (`CODER_VERSION`): Tag-Form per Pull beweisen + Default
   korrigieren. Ohne das stirbt die Erstinstallation in Schritt 3.
3. **B-008** (Offsite + Restore-Probe mit RTO-Zahl): Platten-/Host-Verlust
   ist heute Totalverlust; Pfad A ist ungeprobt und wahrscheinlich defekt.
4. **B-004** (Socket): Template-Erstinventar + Abhakpflicht + Selbsttest;
   D-Socket mit Frist. Ohne das steht jede Sicherung auf
   kompromittierbarer Basis.
5. **B-005/B-017** (TLS + Path-Apps): Erkennung sofort, Modell-Entscheidung
   (ask vs. DNS-01) + Template-Inventar mit Frist. Fremd-DoS und
   Cookie-Pfad bleiben sonst offen.
6. **B-006** (SSH): Key-Termin + Zweit-Zugang + Härtungsdatum; Skript um
   Nachbedingung ergänzen. Kein grünes Dauer-Provisorium.
7. **B-003/B-009** (Prune + Update-Gate): kein Auto-Prune nach Update,
   `/healthz`-Gate, app/db-Trennung. Sonst Update ohne Rückweg.
8. **B-010** (Backup-Aussagekraft): Mini-Restore-Pflicht statt nur
   `gzip -t`; Leer/Fehlertext = Fail; Skip mit Backup-Alter.
9. **B-015** (Platte/Monitoring): `retention.size` nach Messung +
   minimaler Check mit Leser. Sonst tötet der schleichendste Ausfall das
   verifizierte Backup (ENOSPC).
10. **B-011** (Reboot): Boot-Gate + Grace-Period + Betriebsfenster. Sonst
    rebootet der Server planmäßig blind.
11. **B-021** (Caddy-2.10-Kompatibilität): Zertifikatsnachweis mit gepinntem
    Image (Apex + echte + zufällige Subdomains). Sonst bleibt die
    Kernfunktion Workspace-Apps auf einer ungeprobten 2.10-Semantik.

## High Risk Findings

- **B-007** (UFW/DOCKER-USER/IPv6/Re-Run-Downgrade): Schutzbehauptung bei
  Container-Ports; Re-Run revertiert manuelle SSH-Härtung.
- **B-013** (Preflights/Retries/df-Gates): banale Fehlerpfade brechen das
  Setup kommentararm ab.
- **B-014** (Passwort-Fenster/Alphabet): Lockout mit Zündung beim Reboot;
  P-018 per Test-VM entscheiden.
- **B-018** (Workspace-RPO): größte reale Verlustklasse ohne Beschluss und
  ohne Kommunikation.
- **B-020** (Reset-Kanten): Teillöschung, Koexistenz, Pipe-`--force`.

## Remaining Risks

- **B-012** (Config-Clobber): Re-Run walzt Operator-Tuning still platt –
  bewusst gegen „deterministisches Heilen" abwägen, Drift-Warnung fehlt.
- **B-016** (Logger-Guards/Orphans/Teillöschung): klein, aber
  fehlerpfadverschleiernd.
- **B-019** (Wildcard-Blindheit): Apex-OK ≠ Apps-OK.
- Caddy-2.10-Verhalten ist jetzt als **B-021** Blocking (kein Restrisiko
  mehr): Nachweis mit gepinntem Image steht aus.
- Supply-Chain: Tags ohne Digest/Signatur (`ghcr.io`, Docker-Hub, `curl|gpg`
  mit Fingerprint-Check als einzigem Anker – dieser Check ist vorhanden und
  korrekt); Kompromittierung einer Registry = Host-Takeover via Socket.
  Keine Gegenmaßnahme ohne Digest-Policy (D4 offen).
- `pid: host` bei node-exporter ohne genutzten `processes`-Collector:
  Angriffsfläche ohne Nutzen (Hygiene, entfernen oder begründen).
- Grafana 12.4.5-Pin: konservativ vertretbar, Major-Wechsel separat testen
  (kein Defekt, nur dokumentieren).
- Unattended-Reboot 03:00 vs. Unterrichts-/Nachtbetrieb: Zeitpunkt mit
  Betriebsfenster abstimmen (B-011-Teil).

## Tests That Must Be Run Before Production

Kein Test wurde auf Produktivhardware ausgeführt; alle folgenden auf
isolierter Test-VM (`coder-test-<datum>`, Debian 13, Snapshot-fähig),
Testdomain (nie `coder.ghse-unterricht.de`), Protokollpflicht (Datum,
VM-Name, Commit, Tool-Versionen, Exit-Codes, Logs). „Bestanden" gilt nur
mit Artefakt, nie per Lesung.

- **Pflicht-Gates:** T-001 (`bash -n`), T-002 (ShellCheck Haupt + Heredocs +
  `ssh-harden.sh`), T-003 (`compose config`), T-004 (Caddy-Validate),
  T-006 (Referenz-Gate – derzeit rot, PLAN-Reparatur vorausgesetzt), T-007
  (Harness-Selbsttest).
- **Fresh + Idempotenz:** T-010/T-011/T-012/T-013/T-014, T-020 (1./2./3. Lauf
  + Caddy-Startzeit + Ban-Erhalt), T-021 (Crontab 4 Fälle), T-022 (`.env`-
  Halbierung), T-023 (600 ohne Fenster), T-024 (GID-Diff/Leer/Socket-Probe),
  T-025 (kein Blind-Restart, Bans bleiben), T-026 (Drift-Meldung).
- **Abbruch/Netz/Docker:** T-030–T-034 (Kill Schritt 1/2/3, Passwort-Fenster,
  Reboot während Setup), T-040–T-045 (DNS fehlt + Heilung, offline, Registry-
  Block, GPG-Fingerprint, ACME-Block, Cron-Minimal-PATH).
- **Security:** T-060 (externer Scan + `ss` + `DOCKER-USER`), T-061 (SSH
  vor/nach + Ban), T-062 (UFW), T-063 (Socket-/Workspace-Selbsttest),
  T-064 (Allowlist pro Template), T-065/T-066 (Rechte/Secrets-Hygiene),
  T-067 (Log-Limits + Flut), T-068 (`pid: host`), T-069 (kein
  Auto-Destruktiv-Cron).
- **Backup/Restore:** T-070–T-077 (Erzeugung, Leer-Semantik, Stream-Abbruch,
  tmpfs-voll, `flock`-Parallelität, Retention 20→14 + Lücke, Cron aktiv,
  Logrotate + Logger-Signal), T-078 (Umfangslücke), T-079 (retention.size),
  T-080 (Mini-Restore!), T-081 (`.env`-Verlust), T-082 (frische VM + RTO-
  Zahl), T-083 (Workspace-Datei), T-084 (Transport-Trennung).
- **Update/Reset/Reboot/Extern:** T-050/T-090–T-094 (Bad-Version, Normalpfad,
  Rollback differenziert, app/db, Engine-Pfad), T-100–T-106 (Reset-Serie),
  T-110–T-113 (Reboot-Serie), T-120–T-126 (DNS, HTTP, HTTPS, Zertifikat,
  Wildcard-App, Fake-Subdomain, Path-Apps).
- **Neu aus diesem Review (keine T-Nummer, vor Freigabe ausführen):**
  `docker pull` beider Coder-Tag-Formen (B-002); Cron-Pfad-Backup statt
  Direktaufruf (B-001); `ask`-Abfluss an `example.com?domain=` per
  Caddy-Debug-Log belegen (B-005); `until=24h`-Prune an zwei realen
  Caddy-Tags beweisen (B-003); Post-`reload`-Enforcement von
  `ssh-harden.sh` inkl. SK-Key-Negativprobe (B-006); Port-Preflight bei
  belegtem 80/443 (B-013); Wildcard-DNS-Negativprobe (B-019);
  Caddy-2.10-Kompatibilität: Apex + echte + zufällige Subdomains mit
  gepinntem Image, Zertifikat je Host + Caddy-Log (B-021); Tiefen-Smoke
  nach Setup: Postgres-healthy, Coder-`/healthz`-200, Prometheus-API,
  Grafana-HTTP, Caddy-Zertifikat, Wildcard-App, ein echter
  Test-Workspace (Provisionierung Ende-zu-Ende – `/healthz` allein beweist
  sie nicht).
