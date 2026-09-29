# SECURITY.md – Härtung, Grenzen, offene Entscheidungen

Stand: 2026-09-28. Diese Datei beschreibt den **tatsächlichen** Stand aus
`setup-coder.sh` und `ssh-harden.sh` – inklusive dessen, was bewusst noch
nicht gemacht ist. Provisorien sind als solche markiert.

Grundmodell: Coder-Workspace-Nutzer gelten als **nicht vertrauenswürdig**.
Der kritischste Punkt des Stacks ist der Docker-Socket im
Coder-Container (Abschnitt 6). Prüfbefehle stehen jeweils daneben –
Dokumentation ohne Nachweis zählt nicht.

Einstieg: [README.md](README.md) · Betrieb: [OPERATIONS.md](OPERATIONS.md) ·
Restore: [RESTORE.md](RESTORE.md) · Fehler: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## 1. SSH

**Ist-Zustand**

- **Zielbetrieb (Schulserver):** Zugang dort ist **derzeit nur per Passwort**
  möglich – es ist noch kein SSH-Key eingerichtet. Erreichbar ist SSH nur aus
  dem Schulnetz bzw. per VPN (Einschränkung liegt in der Netzwerkinfrastruktur,
  nicht im Setup). **Deshalb darf `ssh-harden.sh` dort nicht laufen, bevor ein
  Key gesetzt und aus einem zweiten Fenster getestet ist** – sonst wird die
  einzige Zugangsart abgeschaltet. Reihenfolge: `ssh-copy-id` → Login in
  zweitem Fenster testen → dann erst über Härtung entscheiden. Das Skript
  erzwingt das ohnehin (beide Flags + erkannter Key, sonst Abbruch).
  **Entscheidung 2026-09-29: bis dahin nur die Minimalvariante gegen
  fehlgeschlagene Logins, kein vollständiges `ssh-harden.sh`** (Skript
  bleibt vorbereitet, unausgeführt).
- **Test-Host (Hetzner `2.29.11.30`):** Login **nur per Key** – es existiert
  kein Konto mit Passwort in `/etc/shadow`, ein Passwort-Login schlägt bei
  jedem Konto fehl. Port 22 ist von überall erreichbar, damit Zugriff von
  zuhause möglich ist; die Schulnetz-Infrastruktur muss 22 zusätzlich zu
  80/443 weiterleiten.
- Schutz in beiden Fällen: `ufw limit 22/tcp` (eingebautes Rate-Limiting von
  ufw) und fail2ban als zweite Linie.
- Passwort-Login ist **nicht** deaktiviert. Das Setup führt `ssh-harden.sh`
  nicht aus; der Abschlusscheck meldet den Zustand bei jedem Lauf und
  fordert auf, Key-Login zuerst zu testen.
- **Restrisiko der Entscheidung:** Jedes Gerät im Schulnetz/VPN erreicht
  Port 22 und kann per Passwort raten; ein geteiltes oder weitergegebenes
  Passwort bleibt gültig. Härtung nachholen, sobald der Server von außen
  erreichbar wird, der Zugang geteilt wird oder die Zugriffswege reduziert
  werden sollen.

**Vorgehen 2026-09-29: Minimalvariante (gegen fehlgeschlagene Logins)**

Nichts zu ergänzen – das Setup liefert den Schutz bereits, gemessen auf dem
Test-Host am 2026-09-29:

| Maßnahme | Ist-Wert | Quelle |
|---|---|---|
| `ufw limit 22/tcp` (v4 + v6) | aktiv, Rate-Limiting | `ufw status` |
| fail2ban-Jail `sshd` | 5 Fehlversuche / 10 min / 1 h Ban, `backend=systemd` | `/etc/fail2ban/jail.d/10-coder-sshd.local` |
| fail2ban tatsächlich am Sperren | `Total banned: 134`, `Currently banned: 10` | `fail2ban-client status sshd` |
| Root per Passwort gesperrt | `permitrootlogin without-password` | `sshd -T` |
| Leere Passwörter / Kbd-Interactive | `permitemptypasswords no`, `kbdinteractiveauthentication no` | `sshd -T` |
| Passwort-Login allgemein | `passwordauthentication yes` (bewusst offen) | `sshd -T` |

Optional und derzeit **nicht** gesetzt: ein Drop-In mit `MaxAuthTries 3`
und `LoginGraceTime 30`. Der Effekt wäre gering, weil fail2ban ohnehin
nach 5 Fehlversuchen in 10 Minuten sperrt.

```bash
sudo ufw status verbose                      # 22/tcp LIMIT?
sudo fail2ban-client status sshd             # Jail aktiv, aktuelle Bans
sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'
sudo journalctl -u ssh -n 50 --no-pager
```

**Härtungspfad (`ssh-harden.sh`, vorbereitet, nicht automatisch)**

Das Skript schreibt als Drop-In `/etc/ssh/sshd_config.d/60-coder-hardening.conf`:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

Sicherheitsvorkehrungen im Skript selbst:

1. Beide Flags müssen gesetzt sein
   (`--i-have-key-access --i-have-second-access`) – sie bestätigen ein
   **getestetes** Key-Login und einen Zweit-Zugang (Konsole/Proxmox/iDRAC).
2. Ohne passenden Key in `/root/.ssh/authorized_keys` oder
   `/home/<sudo-user>/.ssh/authorized_keys` gibt es einen Abbruch
   (auch FIDO2- und Zertifikats-Keys werden erkannt).
3. `sshd -t` muss sauber sein, sonst wird das Drop-In sofort entfernt.
4. Nach `systemctl reload ssh` prüft das Skript die **effektive** Config
   (`sshd -T`) – ist einer der drei Werte nicht `no`, meldet es Fehler und
   nennt den Rollback: `sudo rm /etc/ssh/sshd_config.d/60-coder-hardening.conf && sudo systemctl reload ssh`.

**Vor der Härtung**: Zweit-Zugang testen, Key-Login aus einem zweiten
Fenster verifizieren, Termin + Eigentümer festhalten (D-SSH). Bis dahin
gilt als Provisorium: starkes Passwort, fail2ban-Beobachtung, reduzierte
Zugriffswege. Die Härtung selbst ist eine **VM-/Produktionshandlung**
(Tropfen-/Rollback-Verhalten ist hier nicht belegt).

## 2. Secrets

- `/opt/coder/.env`: `600`, `root:root`. Erzeugung atomar (Temp-Datei +
  `install -m 600` + `mv`), kein 644-Fenster, bei Abbruch wird das
  Temp-File entfernt.
- Passwörter ausschließlich `openssl rand -hex` (24 bzw. 16 Bytes) –
  hex kann die Postgres-Connection-URL und SQL-/Shell-Quoting nicht
  aufbrechen.
- Eine vorhandene, aber **unvollständige** `.env` wird nie still neu
  gewürfelt (das würde die DB-Anmeldung zerstören) – das Setup bricht ab
  und nennt die Reparatur.
- Nicht-Hex-Werte in der `.env` führen zum Abbruch mit Verweis auf
  `sudo /opt/coder/reset-passwords.sh` (migriert Legacy-Werte lesend nach
  Hex).
- Newline/NUL in `.env`-Werten wird hart abgewiesen, nicht still getrimmt.
- Rotation: `reset-passwords.sh` zieht zuerst ein Backup, sichert die alte
  `.env` (genau eine Generation), übergibt beide Passwörter über STDIN in
  den Container – nicht als `docker exec`-Argument, damit sie weder in
  `ps aux` noch in `docker inspect` auftauchen – und recreated nur den
  Coder-Container (`--no-deps`).
- Repository-Hygiene: `.gitignore` schließt `.env`, `*.env`, `*.sql`,
  `*.sql.gz`, `*.log`, `backups/` aus. Kein Secret liegt im Repository.
- Passwort-Ausgaben passieren nur im Terminal des Operators (Erstlauf,
  Rotation) – sie gehören nicht in Protokolle, Tickets oder Doku.

```bash
sudo stat -c '%a %U:%G %n' /opt/coder/.env /opt/coder/backups
sudo ls -la /opt/coder/.env.bak.* 2>/dev/null      # genau eine Generation
git status --porcelain | grep -i env               # muss leer sein
```

## 3. TLS und SNI

**Konfiguration**: Caddy terminiert TLS für `coder.…` und `*.coder.…`
(Wildcard für Workspace-Apps/Port-Forwarding), Reverse-Proxy auf
`coder:3000`, ACME-Account `ACME_EMAIL`. Wildcard-Zertifikate sind per
HTTP-01 nicht möglich; ohne DNS-Provider-API-Token nutzt das Setup die von
Coder empfohlene Lösung: **On-Demand-TLS**.

**`ask`-Endpunkt (B1)**

`on_demand_tls.ask` zeigt auf `http://127.0.0.1:9123/ask` – ein eigener
Caddy-Site-Block, der Port steht **nicht** in `ports:` der compose-Datei
und hat keine ufw-Regel: von außen unerreichbar, nur aus dem Container-
Netz. Er antwortet `200` nur, wenn der beantragte `?domain=`-Parameter dem
Coder-Subdomänen-Muster entspricht, sonst `404`:

- Muster (Quelle: Coder-Quellcode `coderd/workspaceapps/appurl/appurl.go`,
  Format `{PORT/APP_SLUG}[--{AGENT_NAME}]--{WORKSPACE_NAME}--{USERNAME}`):
  `^<label>(--<label>){2,}$` + `.` + Apex-Domain. Punkte in der ersten
  Gruppe sind ausgeschlossen, deshalb greifen `evil.coder.…`,
  `a.b.coder.…` und der Apex selbst **nicht**.
- Der Apex-Domain-Block (`coder.…`) läuft **ohne** `on_demand`: sein
  Zertifikat kommt beim Start bzw. bei der regulären Erneuerung und
  berührt das On-Demand-Budget nicht.
- Geprüft (live, `t-b1-on-demand-ask.sh`): 200 für App-Namen mit 2 und 3
  `--`-Trennern, 404 für Apex, für `evil.…`, für geschachtelte Namen,
  für falsche Pfade und für fehlende Parameter.

**Was diese Absicherung NICHT leistet (P-005)**

- Das Muster ist ein **Filter, kein Budgetschutz**: für jeden Namen, der
  hineinpasst, kann ein beliebiger Internet-Teilnehmer das Zertifikat
  weiterhin auslösen – ohne Coder-Account und ohne Authentifizierung.
  Ein Angreifer kann ausreichend gültige Namen konstruieren (beliebige
  Workspace-Namen), wenn er das Wochenbudget erschöpfen will.
- Das Wochenbudget (50 Ausstellungen pro registrierter Domain
  `ghse-unterricht.de`) ist **geteilt** mit allen anderen Schuldiensten
  derselben Domain. Bei Erschöpfung bekommen legitime neue Workspace-Apps
  kein Zertifikat → TLS-Fehler im Unterricht.
- Erster Handshake einer neuen Subdomain dauert 5–30 s länger (Zertifikat
  wird beim ersten Aufruf beantragt).
- Echter Fix bleibt DNS-01-Wildcard ohne On-Demand (eigener API-Token des
  DNS-Anbieters, offene Entscheidung D-TLS mit Frist). Bis dahin gilt:
  Budget über `check-tls.sh` beobachten.

**Erkennung**: `check-tls.sh` zählt `obtaining certificate` im Caddy-Log
der letzten 7 Tage, schreibt nach `/var/log/coder-tls.log` und ins
Journal; läuft montags 06:30. Exit-Code ist immer 0 (reine Diagnose).

**Grenze dieser Erkennung**: Die Container-Logs sind auf 10 MB × 3 Dateien
gedeckelt; das 7-Tage-Fenster passt bei hohem Logvolumen nicht hinein,
Älteres ist rotiert und geht in der Zählung verloren. Der Befund dazu
(B2-005) ist im Repository dokumentiert und **nicht** behoben – die Zahl
ist also eine Untergrenze, kein Vollzählwerk.

```bash
grep -E '^IPV6=' /etc/default/ufw; sudo docker logs coder-caddy --since 168h 2>&1 | grep -c "obtaining certificate"
sudo docker logs coder-caddy --tail=100 | grep -iE 'obtaining|error|acme'
sudo /opt/coder/check-tls.sh
```

## 4. Firewall

**Regeln (vom Setup gesetzt, idempotent)**

| Regel | Wert |
|---|---|
| Default-Policy | `deny incoming`, `allow outgoing` (explizit gesetzt, nicht auf Debian-Default verlassen) |
| SSH | `ufw limit 22/tcp` |
| Web | `ufw allow 80/tcp`, `443/tcp`, `443/udp` (HTTP/3) |
| Aktivierung | `ufw --force enable` |
| IPv6 | gleiche Policy für v4+v6, solange `IPV6=yes` in `/etc/default/ufw`; sonst WARN und nur v4 |

**Re-Run-Schutz**: Findet das Setup beim erneuten Lauf eine
restriktivere SSH-Regel (Quelle ≠ Anywhere), bricht es **vor** dem ersten
`delete` ab und nennt den Bypass
`sudo env CODER_ALLOW_SSH_DOWNGRADE=yes ./setup-coder.sh`. Nur exakt `yes`
löst den Bypass aus; die vorgefundene Regel wird danach quellengetreu
wiederhergestellt und per `grep` gegen das After-Log verifiziert, sonst
Exit 1. Before/After liegen unter
`/var/log/coder-ssh-downgrade-<zeitstempel>.{before,after}.log`.

**Port-Vorabprüfung (B6):** Bevor das Setup die erste Firewall-Regel
anfasst, liest es die konfigurierten SSH-Ports aus `sshd -T`. Weicht die
Liste von exakt `22` ab (z. B. `2222`), bricht es ab, statt eine Regel auf
`22/tcp` zu setzen und den eigentlichen SSH-Port ungeschützt zu lassen.

**Was ufw hier nicht schützt** (vom Setup selbst so dokumentiert):
Docker trägt für per `ports:` publizierte Container-Ports eigene
iptables-Regeln ein, die ufw dabei üblicherweise umgehen. Für 80/443 ist
das akzeptabel, weil dort ohnehin der öffentliche Coder-Zugang laufen
soll; der Schutz der übrigen Dienste kommt deshalb **nicht** aus ufw,
sondern aus der 127.0.0.1-Bindung (Abschnitt 6). Für SSH (Host-Dienst,
kein Container) greifen ufw und fail2ban tatsächlich. Ein
`DOCKER-USER`-Einbau ist eine offene Entscheidung (D-Firewall) und wurde
bewusst nicht eingebaut.

**Reihenfolge ist die Sicherheitsfunktion (A1)**: Im Bypass-Lauf steht
zuerst die Wiederherstellung der vorgefundenen restriktiven Regel samt
Verifikation gegen das After-Log, erst danach wird die weltweite
`22/tcp LIMIT Anywhere` entfernt. Ein Abbruch dazwischen lässt die
Beschränkung stehen; der schlimmste Fall ist der Ausgangszustand, nie ein
neues Loch. Fehlt die Quelle im After-Log oder steht die weltweite Limit-
Regel noch, bricht das Setup mit `[FEHLER]` ab.

**fail2ban** – eigene Jails liegen im Drop-In
`/etc/fail2ban/jail.d/10-coder-sshd.local` (B7), nicht in `jail.local`:
jail.local hat laut Lese-Reihenfolge Vorrang und würde Hand-Änderungen des
Operators überschreiben. Eine zuvor setup-eigene `jail.local` wird nur
entfernt, solange ihr Hash noch der gespeicherten entspricht; sonst bleibt
sie (mit WARN) und hat Vorrang. Jail `sshd`, `backend=systemd`,
`maxretry=5`, `findtime=10m`, `bantime=1h`. Ohne Änderung lädt das Setup
den Dienst **nicht** neu (sonst würden aktive Bans verworfen).

```bash
sudo ufw status numbered
sudo fail2ban-client status sshd
sudo fail2ban-client get sshd logpath
sudo iptables-save | grep -i docker | head      # Docker-eigene Regeln sichtbar machen
```

## 5. Host-Grundhärtung

- `unattended-upgrades` aktiviert (nicht-interaktiv, `20auto-upgrades`),
  automatischer Reboot um 03:00 Uhr (`52-coder-reboot`). Das Fenster ist
  **nicht** mit dem Schulbetrieb abgestimmt (D-Reboot-Fenster) – vor
  Produktionsfreigabe abstimmen.
- Docker-apt-Repo mit Fingerprint-Prüfung: entspricht der Wert nicht
  `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`, bricht das Setup ab
  (Rotation dort abgleichen, nicht blind übernehmen).
- Retry-Begrenzung: `apt`/`curl`/`pull` max. 3 Versuche mit 10 s Pause –
  keine endlosen Wiederholungen, kein Retry um Let's-Encrypt.
- Log-Rotation für alle drei Logs des Stacks: `/var/log/coder-backup.log`
  (`coder-backup`) sowie `/var/log/coder-boot.log` und
  `/var/log/coder-tls.log` (`coder-logs`, wöchentlich, 8×, `copytruncate`).
  Container-Logs sind zusätzlich daemon-weit begrenzt (s. u.).
- Container-Logs sind daemon-weit begrenzt (`daemon.json`, json-file
  10 MB × 3). Liegt eine fremde `daemon.json` ohne diese Schlüssel vor,
  bricht das Setup ab, statt sie umzuschreiben (C2).
- Docker-Pakete laufen in die automatischen Sicherheitsupdates mit ein
  (`52-coder-docker-upgrades`, C6); ohne diesen Origin fielen
  `docker-ce`/`containerd.io` still heraus.
- Es gibt **Alarmregeln, aber kein Alerting**: vier Prometheus-Regeln
  (Coder-Target down, Root-Partition <10 % frei, letztes Backup >25 h,
  TLS-Ausstellungen >20/7 d) sind in Prometheus/Grafana sichtbar, aber
  **kein Kanal**, der jemanden weckt – kein Alertmanager, keine
  Benachrichtigung. Ein Contact Point bräuchte SMTP-Zugang (D-Monitoring). Gesundheit meldet
  sich nur, wer sie abfragt (Boot-Gate, TLS-Check, manuelle Checks in
  [OPERATIONS.md](OPERATIONS.md)).
- Image-Pinning: Coder/Prometheus/Grafana/node-exporter exakt, Caddy minor
  (`2.10`) und `postgres:15-alpine` mit beweglichen Tags. Ein
  bit-genauer Pin bräuchte Digests (`sha256:…`) – nicht umgesetzt.
  Alte Images bleiben nach Updates als Rollback-Basis erhalten (kein
  Auto-Prune).

## 6. Docker-Netzwerk und Listener

| Dienst | gebunden auf | öffentlich erreichbar? |
|---|---|---|
| Caddy | `80/tcp`, `443/tcp`, `443/udp` (Host) | ja – der einzige öffentliche Einstieg |
| Coder | `0.0.0.0:3000` **im Compose-Netz**, kein `ports:` | nein, nur über Caddy |
| PostgreSQL | kein Host-Port | nein, nur im Compose-Netz |
| Prometheus | `127.0.0.1:9090` | nein |
| node-exporter | `127.0.0.1:9100` | nein |
| Grafana | `127.0.0.1:3001` | nein (SSH-Tunnel) |
| sshd | `22/tcp` (Host) | ja, rate-limitiert |

Bindungsregel (im Setup als Review-Check hinterlegt): neue `ports:`-Einträge
nur als `127.0.0.1:<port>:<port>`; öffentliche Ports bleiben Caddy
vorbehalten.

**Docker-Socket – das größte Restrisiko**

- `/var/run/docker.sock` wird dem Coder-Container **schreibbar** gemountet
  (offizielles Coder-Docker-Setup) und die docker-Gruppe per `group_add`
  vergeben. Wer den Coder-Container oder ein davon provisioniertes
  Workspace-Image kontrolliert, kontrolliert den Host (root-äquivalent).
- Die docker-GID wird bei jedem Lauf gegen den Host abgeglichen; der
  Abschlusscheck prüft, dass `GroupAdd` die aktuelle GID enthält
  (`[OK]`/`[FEHLER]` „Socket-Zugriff").
- Echte Trennung (Proxy/ separater Host) ist eine offene Entscheidung
  (D-Socket). Bis dahin greift die Template-Allowlist:
  [templates/allowlist.md](templates/allowlist.md) – verboten sind dort
  u. a. Socket-Mounts, `privileged`, `pid/host`/`network_mode: host`,
  Host-Root-Mounts und gemeinsame Netze mit `postgres`.
- Der Erstinventar aller Templates und der Workspace-Selbsttest (T-063)
  sind in der Allowlist-Tabelle als `_offen_` eingetragen – sie sind
  **noch nicht** durchgeführt.

Weiteres: `node-exporter` läuft mit `pid: host` und bringt `/proc`, `/sys`
und `/` nur lesend eingebunden. Container-Logs sind mengenmäßig begrenzt
(10 MB × 3), damit die Root-Partition nicht wächst.

```bash
sudo docker inspect coder | grep -A3 -i mounts
sudo docker inspect -f '{{json .HostConfig.GroupAdd}}' coder
sudo docker inspect -f '{{json .HostConfig.PortBindings}}' $(sudo docker compose -f /opt/coder/docker-compose.yml ps -q)
ss -tlnp; ss -ulnp | grep 443
```

## 7. Backups

- `/opt/coder/backups` ist `700`, Dateien `600`, Inhalt: nur
  verifizierte Postgres-Dumps (14 Stück).
- Es gibt **keine Offsite-Kopie**. Platten- oder Hostverlust bedeutet
  Datenbank und alle Backups gleichzeitig (offene Entscheidung D-Offsite).
- Workspace-Dateien und `.env` sind nicht Teil des Backups – siehe
  Verlusttabelle in [RESTORE.md](RESTORE.md).
- Ein grüner Backup-Lauf ist kein Restore-Nachweis; die Probe gehört auf
  eine Test-VM ([RESTORE.md](RESTORE.md)).

## 8. Bekannte Grenzen (Zusammenfassung)

| # | Grenze | Risiko in einem Satz | Status |
|---|---|---|---|
| 1 | Docker-Socket im Coder-Container | Kompromittierung eines Workspaces = Kompromittierung des Hosts | Trennung offen (D-Socket), Allowlist greift bis dahin |
| 2 | SSH-Passwort-Login aktiv; im Zielbetrieb nur Schulnetz/VPN erreichbar, auf dem Test-Host weltweit | Brute-Force trotz ufw/fail2ban möglich (Test-Host; im Schulnetz nur durch jeden Rechner dort) | Entscheidung 2026-09-29: vorerst keine Härtung, `ssh-harden.sh` vorbereitet (D-SSH) |
| 3 | On-Demand-`ask` prüft nur das Namensmuster | für jedes Muster-taugliche Namen kann ohne Account ein Zertifikat ausgelöst werden, geteiltes Wochenbudget erschöpfbar | `ask` gefiltert (B1), Budget-Schutz bleibt bis D-TLS mit Frist |
| 4 | TLS-Zählung blind gegenüber Log-Rotation | Budget-DoS fällt unter Umständen nicht auf (B2-005) | `coder_tls_issuances_7d` + Regel TlsIssuanceBudgetHigh seit 2026-09-29 (B4); Meldung fehlt weiterhin |
| 5 | Kein Offsite-Backup | Totalverlust bei Platten-/Hostschaden | offen (D-Offsite) |
| 6 | Restore nie geprobt, RTO unbekannt | im Ernstfall ist der Wiederherstellungsweg ungeprüft | offen, Probe nur auf Test-VM |
| 7 | ufw greift für Docker-Published-Ports nicht | „ufw grün" heißt für Container-Ports nicht „geschützt" | dokumentiert, 127.0.0.1-Bindung ist der eigentliche Schutz |
| 8 | Reboot automatisch 03:00 | abgebrochene Unterrichtssitzungen | offen (D-Reboot-Fenster) |
| 9 | Kein Benachrichtigungskanal (nur Regeln), keine Digest-Pins | Ausfälle heben keine Alarmierung aus, Prometheus/Grafana zeigen sie nur dem, der hinsieht | Regeln vorhanden (4 Stück), Logs rotiert, Kanal offen (D-Monitoring) |
| 10 | Template-Erstinventar und Workspace-Selbsttest offen | unbekannte Templates könnten Socket/Privilegien nutzen | `_offen_` in [templates/allowlist.md](templates/allowlist.md) |
| 11 | Coder sieht hinter Caddy nur dessen Container-IP | Audit-Einträge nennen keine Client-IP; Konfiguration über `CODER_PROXY_TRUSTED_HEADERS`/`CODER_PROXY_TRUSTED_ORIGINS` ist bewusst unterlassen (Vertrauen auf das ganze Compose-Netz wäre durch einen im selben Netz hängenden Workspace-Container fälschbar) | Entscheidung offen (B5): erst festlegen, ob Client-IPs im Audit geführt werden sollen (Datenschutz/Schule). Empfehlung 2026-09-29: **so lassen**. Wenn doch: feste IP für `caddy` im Compose-Netz vergeben und `CODER_PROXY_TRUSTED_ORIGINS` **nur auf diese IP** setzen (nie auf das ganze Netz) |
| 12 | ACME läuft über http-01/tls-alpn-01 statt DNS-01 | Zertifikat braucht 80/443 am Server; Schul-Proxy oder gesperrte Ports blockieren die Ausstellung | Alternative dokumentiert: DNS-01 mit `_acme-challenge`-CNAME, braucht Zonen-Zugang beim Provider (B4b) |

**Regel für Reparaturen:** Kein Fehlerbild wird durch Abschalten von
Prüfungen, Zurücklassen von Firewall-Regeln im ungünstigen Zustand oder
Überspringen der Verifikation gelöst. Wenn eine Maßnahme die Sicherheit
senkt, braucht sie eine dokumentierte Entscheidung mit Eigentümer und
Frist – siehe [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
