# SECURITY.md – Härtung, Grenzen, Entscheidungen

Stand: 2026-10-01. Diese Datei beschreibt den **tatsächlichen** Stand aus
`setup-coder.sh` – inklusive dessen, was bewusst noch nicht gemacht ist.
Provisorien sind als solche markiert.

Grundmodell: Coder-Workspace-Nutzer gelten als **nicht vertrauenswürdig**.
Der kritischste Punkt des Stacks ist der Docker-Socket im
Coder-Container (Abschnitt 6). Prüfbefehle stehen jeweils daneben –
Dokumentation ohne Nachweis zählt nicht.

Einstieg: [README.md](README.md) · Betrieb: [OPERATIONS.md](OPERATIONS.md) ·
Restore: [RESTORE.md](RESTORE.md) · Fehler: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## 1. SSH

**Ist-Zustand**

- **Zielbetrieb (Schulserver):** Passwort-Login ist **Standard und bleibt
  es** (Entscheidung D-SSH, 2026-09-30). SSH ist laut Netzvorgabe **nur aus dem
  Schulnetz** erreichbar; diese äußere Beschränkung liegt in der
  Netzwerkinfrastruktur, nicht in diesem Setup. ufw stellt `allow` für die
  erkannten sshd-Ports (Regelwerk 2026-10-03: kein `limit`, weil ufw limit
  6 Verbindungen/30 s je Quell-IP gelten würde und sich die ganze Schul-NAT
  das teilt), fail2ban sperrt wiederholte Fehlversuche.
  Das Setup schreibt das eigene Drop-In
  `/etc/ssh/sshd_config.d/01-coder.conf` (Sortiert vor jeder `50-*`-Datei,
  z. B. cloud-init) und macht die Passwort-Policy damit
  explizit und überlebend gegenüber Debian-Updates (`PasswordAuthentication
  yes`, `KbdInteractiveAuthentication yes`, `PermitRootLogin
  prohibit-password`); validiert wird über `sshd -T` auf der GESAMTEN
  Konfiguration (Fehlschlag: alter Inhalt wiederherstellen, Abbruch vor dem
  Reload), geladen nur bei Änderung. Key-only-Nachhärtung ist unten als
  vorrangiges Drop-In-Snippet dokumentiert (nicht Standard, D-SSH).
- **Test-Host (Hetzner `2.29.11.30`):** Login **nur per Key** – es existiert
  kein Konto mit Passwort in `/etc/shadow`, ein Passwort-Login schlägt bei
  jedem Konto fehl. Port 22 ist auf dieser separaten Test-VM von überall
  erreichbar; das ist nicht die Netzvorgabe für den Schulserver.
- Schutz zusätzlich zur jeweiligen Netzvorgabe: `ufw allow` der sshd-Ports
  (Netzgrenze am Router, Firewall sperrt nur versehentlich zu) und fail2ban
  als Brute-Force-Linie (5 Fehlversuche in 10 min → 1 h, inkrementell).
- Passwort-Login ist **nicht** deaktiviert – mit D-SSH (2026-09-30) ist das
  der gewollte Dauerzustand, nicht nur der Zustand der ersten
  Inbetriebnahme. Das Setup führt keine Key-only-Härtung aus, fixiert aber
  die Passwort-Policy im Drop-In; der
  Abschlusscheck meldet den Zustand bei jedem Lauf als `OK`
  (G2 in [TROUBLESHOOTING.md](TROUBLESHOOTING.md) beschreibt ihn
  weiterhin; gewarnt wird nur bei `permitrootlogin yes`).
- **Restrisiko der Entscheidung:** Jedes Gerät im Schulnetz erreicht Port 22
  und kann per Passwort raten; ein geteiltes oder weitergegebenes Passwort
  bleibt gültig. Die Netzbegrenzung verhindert Internetzugriffe, ersetzt
  aber keinen individuellen Schlüsselzugang. Eine SSH-Verbindung von außen
  ist netzseitig ohnehin nicht möglich (Betreiber-Bestätigung 2026-10-08);
  der einzige Weg, der diese Grenze umgeht, wäre Container auf dem Host
  selbst – dagegen steht die `DENY 172.16.0.0/12`-Gegenregel am sshd-Port
  (Abschnitt 4). Eine ufw-Quell-CIDR-Einschränkung (`allow from <Schulnetz>`)
  ist deshalb bewusst nicht eingebaut.

**Vorgehen bei der ersten Inbetriebnahme: Passwortzugang im Schulnetz**

Nichts zu ergänzen – das Setup liefert den Schutz bereits, gemessen auf dem
Test-Host (zuletzt geprüft 2026-10-03):

| Maßnahme | Ist-Wert | Quelle |
|---|---|---|
| `ufw allow 22/tcp` (v4 + v6) | aktiv (allow statt limit seit 2026-10-03, Quelle: Anywhere – Netzgrenze liegt am Router) | `ufw status` |
| fail2ban-Jail `sshd` | 5 Fehlversuche / 10 min / 1 h Ban (mit `bantime.increment`), `backend=systemd`, `ignoreip=127.0.0.1/8 ::1` – enabled/backend/maxretry/findtime kommen aus Debians Defaults (`jail.conf`, `jail.d/defaults-debian.conf`), port/bantime/increment/ignoreip aus dem Setup-Drop-In | `/etc/fail2ban/jail.d/10-coder-sshd.local` + Debian-Defaults |
| fail2ban tatsächlich am Sperren | `Total banned: 134`, `Currently banned: 10` | `fail2ban-client status sshd` |
| Root per Passwort gesperrt | `permitrootlogin prohibit-password` (Drop-In, Warnung fängt Vorrang fremder Drop-Ins ab) | `sshd -T` |
| Leere Passwörter / Kbd-Interactive | `permitemptypasswords no`, `kbdinteractiveauthentication yes` (PAM-Pfad, bewusst mit dem Drop-In gesetzt) | `sshd -T` |
| Passwort-Login allgemein | `passwordauthentication yes` (Drop-In, bewusst offen) | `sshd -T` + `/etc/ssh/sshd_config.d/01-coder.conf` |

Optional und derzeit **nicht** gesetzt: ein Drop-In mit `MaxAuthTries 3`
und `LoginGraceTime 30`. Der Effekt wäre gering, weil fail2ban ohnehin
nach 5 Fehlversuchen in 10 Minuten sperrt.

```bash
sudo ufw status verbose                      # 22/tcp ALLOW?
sudo fail2ban-client status sshd             # Jail aktiv, aktuelle Bans
sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'
sudo journalctl -u ssh -n 50 --no-pager
```

**Optionale Nachhärtung (Key-only, vorrangiges Drop-In)**

Mit D-SSH (2026-09-30) **nicht** Standard; B19 hat das alte
`ssh-harden.sh` entfernt. Das Setup-Drop-In `01-coder.conf` erlaubt
Passwort-Login – ein **vorangestelltes** Drop-In (`00-…`) gewinnt pro
Keyword über die lexikalische Reihenfolge und schaltet Passwort-Login
damit ohne Eingriff ins Setup ab. Vorher: Zweit-Zugang
(Konsole/Proxmox/iDRAC) bereithalten und Key-Login aus einem zweiten
Fenster testen. Dann Drop-In anlegen (lädt vor der Debian-Standarddatei
und vor `01-coder.conf`):

```bash
sudo tee /etc/ssh/sshd_config.d/00-coder-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sudo sshd -t && sudo systemctl reload ssh
```

Vor dem Abmelden den Key-Login aus einer zweiten Sitzung verifizieren.
Ein fehlgeschlagener Test wird nicht automatisch zurückgerollt – Rückweg
manuell:

```bash
sudo rm /etc/ssh/sshd_config.d/00-coder-hardening.conf
sudo sshd -t && sudo systemctl reload ssh
```

Dauerzustand bis dahin: starkes Passwort, fail2ban-Beobachtung,
ufw-`allow`, Netzbegrenzung auf das Schulnetz (D-SSH, 2026-09-30).
Die Nachhärtung selbst ist eine VM-/Produktionshandlung.

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
- Nicht-Hex in `POSTGRES_PASSWORD` führt zum Abbruch mit der Reparatur aus
  TROUBLESHOOTING.md A4 (Wert manuell in DB und `.env` abgleichen).
  `GRAFANA_ADMIN_PASSWORD` ist vom Hex-Zwang ausgenommen – Rotation nach
  OPERATIONS §7 (dort wirkt `grafana cli`, nicht der Neustart).
- Newline/NUL in `.env`-Werten wird hart abgewiesen, nicht still getrimmt.
- Rotation (Grafana, manuell ohne Skript): Ablauf in OPERATIONS §7 –
  erst `backup.sh`, dann neues Hex-Passwort per STDIN an `grafana cli`
  (nie als `docker exec`-Argument), `.env`-Zeile danach atomar nachziehen
  (Temp+mv) und im Passwort-Manager sichern. `POSTGRES_PASSWORD` bleibt
  unangetastet – keine DB-Änderung, kein Coder-/Postgres-Neustart.
- Repository-Hygiene: `.gitignore` schließt `.env`, `*.env`, `*.sql`,
  `*.sql.gz`, `*.log`, `backups/` aus. Kein Secret liegt im Repository.
- Beim Erstlauf und bei Rotation werden die Passwörter in der geschützten
  `.env` gespeichert, aber nicht automatisch in die Terminalausgabe geschrieben.
  Das Grafana-Passwort nur bei Bedarf gezielt abrufen:
  `sudo sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /opt/coder/.env`. Nicht in
  Protokolle, Tickets oder Doku kopieren.

```bash
sudo stat -c '%a %U:%G %n' /opt/coder/.env /opt/coder/backups
git status --porcelain | grep -i env               # muss leer sein
```

## 3. TLS und SNI

**Konfiguration**: Caddy terminiert TLS für `coder.…` und `*.coder.…`
(Wildcard für Workspace-Apps/Port-Forwarding), Reverse-Proxy auf
`coder:3000`, ACME-Account `ACME_EMAIL`. Wildcard-Zertifikate sind per
HTTP-01 nicht möglich; ohne DNS-Provider-API-Token nutzt das Setup die von
Coder empfohlene Lösung: **On-Demand-TLS**.

**`ask`-Endpunkt (B1)**

`on_demand_tls.permission http` zeigt auf `http://127.0.0.1:9123/ask` – ein eigener
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
- Echter Fix bleibt DNS-01-Wildcard ohne On-Demand. Der Anbieter ist
  bekannt: Zone `ghse-unterricht.de` liegt bei **All-Inkl** (KAS-API), und
  dafür existiert das Caddy-Modul `caddy-dns/all-inkl`
  (`dns.providers.allinkl`, KAS-Username/-Passwort; Modul seit 11/2025,
  jung, 9 Sterne). Die Zugangsdaten liegen beim Domainverwalter, nicht beim
  Betreiber – der hat keinen DNS-Zugang. Die Umstellung ist **aufgeschoben**:
  unklar ist, ob die Zone bei All-Inkl bleibt und wie 80/443 zum
  Zielserver kommen (IServ läuft auf einem anderen zentralen
  Netzwerkserver, vermutlich samt Reverse-Proxy). Bis dahin gilt:
  **keine automatische Budget-Überwachung** (manuelle Zählung in
  Abschnitt 3). Erschöpfung fällt als HTTPS-Fehler auf (Caddy meldet
  ACME-Fehler, neue Workspace-Apps bekommen kein Zertifikat).

**Erkennung (manuell)**: Bei Verdacht auf Budget-Erschöpfung zählen die
Zertifikatsdateien im `caddy_data`-Volume der letzten 7 Tage direkt im
Caddy-Container; ergänzend die ACME-Fehler in den Caddy-Logs. Das Wochenbudget
(50/Domain) gilt als Fakt.

```bash
sudo docker exec caddy sh -c "find /data/caddy/certificates -name '*.crt' -mtime -7" | wc -l
sudo docker logs coder-caddy --tail=200 | grep -iE 'error|acme|limit'
sudo journalctl -t coder-backup -n 50 --no-pager
```

## 4. Firewall

**Regeln (vom Setup gesetzt, idempotent)**

| Regel | Wert |
|---|---|
| Default-Policy | `deny incoming`, `allow outgoing` (explizit gesetzt, nicht auf Debian-Default verlassen) |
| SSH | **zuerst** `ufw insert 1 deny 172.16.0.0/12 → <sshd-Port>/tcp` (Container aus Docker-Netzen erreichen den Host-SSH-Port nicht; ohne diese Gegenregel würde die weltweite `allow`-Zeile darunter auch für sie gelten), danach `ufw allow <sshd-Port>/tcp` (Ports aus `sshd -T`, meist `22/tcp`) – beide Schritte idempotent, die `deny`-Gegenprobe ist Teil des Abschlusschecks |
| Workspace-Egress | `/opt/coder/workspace-egress.sh` (systemd: `coder-egress-firewall.service`, nach `docker.service`, bei jedem Reboot): `iptables -I DOCKER-USER 1 -d 10.0.0.0/8 -j DROP` und `-d 192.168.0.0/16 -j DROP`, idempotent. Gesperrt: kompromittierte Workspace-Container → RFC1918 außerhalb der Docker-Netze (damit auch Schulnetz-Dienste und Proxmox-Oberfläche). Offen: Internet-Ausgang, die Docker-eigenen Netze (`172.16.0.0/12` – darin laufen die Workspace-Netze selbst, und der Gateway `172.31.1.1` des Test-Hosts) und kein `ip6tables`, weil die Compose-Netze `EnableIPv6=false` haben. **Zwei Sonderfälle bleiben absichtlich unberührt:** (1) DNS der Container läuft über Dockers Embedded-Resolver `127.0.0.11` (am Testhost verifiziert) – die Weiterleitung passiert in der Host-Ebene (`OUTPUT`), nie in `FORWARD`, und trifft die Sperre nicht; (2) Wege über publizierte Ports: `nat/PREROUTING` (DNAT) läuft vor `filter/FORWARD` um und schreibt das Ziel auf die Container-IP (in `172.16/12`), bevor die Kette die `10/8`-Prüfung sieht – Workspace ↔ Coder über `*:443/80` bleibt also auch dann heil, wenn interne DNS-Antworten eine RFC1918-Adresse des Hosts liefern. Gewollt gesperrt bleibt der Rest des Schulnetzes (z. B. IServ, 10.16.x.x). Der Re-Run des Setups setzt die Regeln erneut an |
| Web | `ufw allow 80/tcp`, `443/tcp`, `443/udp` (HTTP/3) |
| Grafana | **keine Regel**: Grafana ist nur an `127.0.0.1:3001` gebunden, Zugang per SSH-Tunnel; vorhandene Quellregeln (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) und eine `3001/tcp`-Regel werden beim Lauf innerhalb dieser harten Allowlist entfernt (idempotenter No-Op, wenn nichts steht) |
| Aktivierung | `ufw --force enable` |
| IPv6 | gleiche Policy für v4+v6, solange `IPV6=yes` in `/etc/default/ufw`; sonst WARN und nur v4 |

**Re-Run-Schutz**: Das Setup löscht keine SSH-Regel, die es nicht selbst
angelegt hat. Es setzt `allow <erkannter sshd-Port>/tcp` (idempotent) und
entfernt danach ausschließlich eine vorhandene eigene `limit 22/tcp`-Regel
– erst nach dem `allow`, also nie ein Augenblick ohne
SSH-Regel. Die einzige weitere Löschung ist die harte Allowlist für den
Grafana-3001-Altbestand (oben). Vorgefundene andere Quellregeln
(Quelle ≠ Anywhere) und fremde allow-Schreibweisen bleiben unangetastet;
wer sie ändern will, tut das manuell (`sudo ufw status numbered`,
`sudo ufw delete …`). Ohne lesbaren ufw-Status bricht das Setup vor
jeder Regel- oder Policy-Änderung ab.

**Port-Vorabprüfung (B6):** Bevor das Setup eine UFW-Policy oder -Regel
anfasst, liest es die konfigurierten SSH-Ports aus `sshd -T`. Ist die
Konfiguration nicht lesbar oder fehlt eine Port-Angabe, bricht es ab, statt
den SSH-Port ungeschützt zu lassen. Von 22 abweichende Ports (z. B. `2222`)
sind dagegen erlaubt: ufw-Regel und fail2ban-`port` folgen der Erkennung.

**Was ufw hier nicht schützt** (vom Setup selbst so dokumentiert):
Docker trägt für per `ports:` publizierte Container-Ports eigene
iptables-Regeln ein, die ufw dabei üblicherweise umgehen. Für 80/443 ist
das akzeptabel, weil dort ohnehin der öffentliche Coder-Zugang laufen
soll; der Schutz der übrigen Dienste kommt deshalb **nicht** aus ufw,
sondern aus der 127.0.0.1-Bindung (Abschnitt 6). Für SSH (Host-Dienst,
kein Container) greifen ufw und fail2ban tatsächlich – **außer** für
Verkehr aus Docker-Netzen: dessen Weg zum Host-SSH-Port läuft über die
ufw-`allow`-Zeile, deshalb steht die `deny`-Gegenregel für
`172.16.0.0/12` als allererste Regel darüber (Tabelle oben, B3a).
Ein `DOCKER-USER`-Einbau für publizierte Ports wurde am 2026-09-30 als
Entscheidung D-Firewall geprüft und **nicht** eingebaut: solange
öffentliche Ports ausschließlich über Caddy laufen, bleibt die
127.0.0.1-Bindung der Schutz. Die `DOCKER-USER`-Kette wird seit
2026-10-08 (B3b) ausschließlich für die Egress-Sperre genutzt (Tabelle
oben) – die D-Firewall-Entscheidung zu publizierten Ports bleibt damit
unverändert.

**Reihenfolge ist die Sicherheitsfunktion (A1)**: Ohne lesbaren
`ufw status`- oder `ufw show added`-Output bricht das Setup ab, bevor es
etwas ändert – ebenso bei inaktivem ufw mit gespeicherten SSH-Quellregeln.
Gelöscht wird nur im nicht-beschränkten Zweig und dort ausschließlich eine
der drei weltweiten Schreibweisen (`allow 22/tcp`, `allow 22`,
`allow OpenSSH`); eine Quellregel taucht nirgends als Löschziel auf. Nach
dem Löschen liest das Setup den Status neu: steht noch eine weltweite
`ALLOW`-Zeile, meldet es `[FEHLER]` und bricht ab – der Lauf endet dann
mit Fehlern statt still mit offenem SSH. Eine vorgefundene
quellbeschränkte Regel bleibt unangetastet, es wird keine weltweite
`limit`-Regel daneben gesetzt.

**fail2ban** – eigene Jails liegen im Drop-In
`/etc/fail2ban/jail.d/10-coder-sshd.local` (B7). Eine vorgefundene
`jail.local` wird nie angefasst; das Setup meldet dann nur, dass das
Drop-In laut Lese-Reihenfolge (`jail.conf → jail.d/*.conf → jail.local →
jail.d/*.local`) Vorrang hat und in `jail.local` eingetragene Jails nicht
greifen. Jail `sshd`, `backend=systemd`, `maxretry=5`, `findtime=10m`,
`bantime=1h`, `bantime.increment = true`. `ignoreip` schützt Admin-Adressen
vor der geteilten Schul-NAT (sonst sperrt ein Tippfehler die gemeinsame
Quell-IP); Default `127.0.0.1/8 ::1`, setzen per
`sudo env FAIL2BAN_IGNORE_IP='… <Admin-IP>' ./setup-coder.sh` – nur
Admin-Plätze, nicht das ganze Schülernetz. Ohne Änderung lädt das Setup
den Dienst **nicht** neu (sonst würden aktive Bans verworfen).

```bash
sudo ufw status numbered
sudo fail2ban-client status sshd
sudo fail2ban-client get sshd logpath
sudo iptables-save | grep -i docker | head      # Docker-eigene Regeln sichtbar machen
```

## 5. Host-Grundhärtung

- `unattended-upgrades` aktiviert (nicht-interaktiv, `20auto-upgrades`);
  der Abschlusscheck prüft den auslösenden
  `apt-daily-upgrade.timer` (aktiv + enabled) – unattended-upgrades selbst
  ist auf Debian ein
  oneshot-Dienst. Automatischer Reboot um 03:00 Uhr (`52-coder-reboot`). Das Fenster ist
  am 2026-09-30 mit dem Schulbetrieb abgestimmt (D-Reboot-Fenster):
  Unterrichtsbeginn 07:45, Reboot um 03:00 bleibt.
- Docker-apt-Repo mit Fingerprint-Prüfung: entspricht der Wert nicht
  `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`, bricht das Setup ab
  (Rotation dort abgleichen, nicht blind übernehmen).
- Retry-Begrenzung: `apt`/`curl`/`pull` max. 3 Versuche mit 10 s Pause –
  keine endlosen Wiederholungen, kein Retry um Let's-Encrypt.
- Log-Rotation des Stacks: `/var/log/coder-backup.log`
  (`coder-backup`). Container-Logs sind zusätzlich daemon-weit begrenzt (s. u.).
- Container-Logs sind daemon-weit begrenzt (`daemon.json`, json-file
  10 MB × 3). Liegt eine fremde `daemon.json` ohne diese Schlüssel vor,
  bricht das Setup ab, statt sie umzuschreiben (C2).
- Docker-Engine- und Compose-Pakete sind von `unattended-upgrades`
  ausgenommen. Ein dockerd-Neustart unterbricht Workspaces; die Pakete werden
  in einem geplanten Wartungsfenster manuell aktualisiert. Beim Upgrade von
  älteren Setup-Ständen schreibt das Setup die Docker-Origin-Datei
  `/etc/apt/sources.list.d/docker.list` bei jedem Lauf neu (`signed-by`,
  Distribution aus `VERSION_CODENAME`) – eine vorhandene Altdatei am
  gleichen Pfad wird überschrieben (bewusst; fremde Quelldateien an
  anderen Pfaden bleiben unangetastet).
- Es gibt **Alarmregeln, aber kein Alerting**: drei Prometheus-Regeln
  (Coder-Target down, Root-Partition <10 % frei, letztes Backup >25 h)
  sind in Prometheus/Grafana sichtbar, aber
  **kein Kanal**, der jemanden weckt – kein Alertmanager, keine
  Benachrichtigung. **Entschieden (D-Monitoring, 2026-09-30): es bleibt
  ohne Kanal** – Grafana/Prometheus sind die Anlaufstelle, das Risiko
  (Ausfälle sieht nur, wer hinsieht) wird getragen; ein Contact Point
  bräuchte weiterhin SMTP-Zugang und wäre nur auf neuen Wunsch zu bauen.
  Gesundheit meldet sich nur, wer sie abfragt (manuelle Checks in
  [OPERATIONS.md](OPERATIONS.md)).
- Image-Pinning: Coder/Prometheus/Grafana/node-exporter exakt, Caddy minor
  (`2.11`) und `postgres:18-alpine` mit beweglichen Tags. Ein
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
| Grafana | `127.0.0.1:3001` | nein – nur per SSH-Tunnel (`ssh -L 3001:127.0.0.1:3001 …`, HTTP, Login Pflicht, kein TLS) |
| sshd | `22/tcp` (Host) | ja, `ufw allow` + fail2ban (Brute-Force-Schutz) |

Bindungsregel: neue `ports:`-Einträge
nur als `127.0.0.1:<port>:<port>`; öffentliche Ports bleiben Caddy
vorbehalten. Ausnahmen gibt es nicht: auch Grafana ist an `127.0.0.1`
gebunden, hat keine ufw-Regel und ist ausschließlich per SSH-Tunnel
erreichbar.

**Docker-Socket – das größte Restrisiko**

- `/var/run/docker.sock` wird dem Coder-Container **schreibbar** gemountet
  (offizielles Coder-Docker-Setup) und die docker-Gruppe per `group_add`
  vergeben. Wer den Coder-Container oder ein davon provisioniertes
  Workspace-Image kontrolliert, kontrolliert den Host (root-äquivalent).
- Die docker-GID wird bei jedem Lauf gegen den Host abgeglichen; der
  Abschlusscheck prüft, dass `GroupAdd` die aktuelle GID enthält
  (`[OK]`/`[FEHLER]` „Socket-Zugriff").
- Echte Trennung (Proxy/ separater Host) ist am 2026-09-30 als D-Socket
  entschieden: keine zweite VM, also bleibt es beim schreibbaren Socket.
  Damit ist die Template-Allowlist **Dauerregel**, kein Provisorium:
  [templates/allowlist.md](templates/allowlist.md) – verboten sind dort
  u. a. Socket-Mounts, `privileged`, `pid/host`/`network_mode: host`,
  Host-Root-Mounts und gemeinsame Netze mit `postgres`.
- Das Erstinventar (Schritt 1 der Abnahme: Prüfung gegen die Verbotsliste)
  ist am 2026-09-30 für die sechs Templates aus dem separaten Repository
  `coder_templates` durchgeführt und in der Allowlist-Tabelle eingetragen.
  Der Workspace-Selbsttest (T-063, Schritt 2) ist vom Betreiber am
  2026-09-30 als gelaufen bestätigt (nicht von mir reproduziert);
  Schritt 4 (Spielraum der Limits im laufenden Workspace) ist nicht
  separat protokolliert.

Weiteres: `node-exporter` läuft mit `pid: host` und bringt `/proc`, `/sys`
und `/` nur lesend eingebunden. Weil es **kein** `network_mode: host` nutzt,
Netzwerkzähler zeigen nur den Container-Namespace. Die Host-Netzwerkmetriken
sind damit eine bekannte Lücke; Host-Netzwerk würde eine neue Scrape-Route
und eine gezielte Listener-Bindung erfordern und wird nicht still aktiviert.
Container-Logs sind mengenmäßig begrenzt (10 MB × 3), damit die Root-Partition
nicht wächst.

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
  Datenbank und alle Backups gleichzeitig. Diese Entscheidung D-Offsite
  ist am 2026-09-30 bewusst getroffen: kein zweiter Standort, das
  Verlustrisiko wird akzeptiert (Inhalte sind nicht extrem kritisch).
  **Betriebsanforderung ohne Automatismus:** Die Forderung „Backup-Kopie
  außerhalb des Hosts"
  bleibt – Ziel (z. B.
  Schulträger-NAS, anderes Rechenzentrum) und Rhythmus sind zu
  entscheiden; bis dahin steht hier bewusst „nicht umgesetzt".
- Workspace-Dateien und `.env` sind nicht Teil des Backups – siehe
  Verlusttabelle in [RESTORE.md](RESTORE.md).
- Ein grüner Backup-Lauf ist kein Restore-Nachweis; die Probe gehört auf
  eine Test-VM ([RESTORE.md](RESTORE.md)).

## 8. Bekannte Grenzen (Zusammenfassung)

| # | Grenze | Risiko in einem Satz | Status |
|---|---|---|---|
| 1 | Docker-Socket im Coder-Container | Kompromittierung eines Workspaces = Kompromittierung des Hosts | entschieden 2026-09-30 (D-Socket): keine zweite VM, Restrisiko akzeptiert, Allowlist gilt dauerhaft |
| 2 | SSH-Passwort-Login (jetzt als Drop-In fixiert); Zielserver nur aus dem Schulnetz erreichbar, separater Test-Host weltweit erreichbar | Geräte im Schulnetz können trotz ufw/fail2ban Passwörter raten; Test-Host hat eine andere Netzgrenze | entschieden 2026-09-30 (D-SSH): Passwort-Login bleibt Standard, Restrisiko getragen; Setup schreibt `01-coder.conf` (Policy sichtbar), Nachhärtung via vorrangigem `00-*.conf` nur auf gesonderten Wunsch |
| 3 | On-Demand-`ask` prüft nur das Namensmuster | für jedes Muster-taugliche Namen kann ohne Account ein Zertifikat ausgelöst werden, geteiltes Wochenbudget erschöpfbar | `ask` gefiltert (B1); D-TLS 2026-09-30 teilentschieden (keine automatische Beobachtung, manuelle Sichtprüfung siehe Abschnitt 3), Budget-Schutz bleibt, DNS-01 aufgeschoben (Anbieter All-Inkl bekannt, Zone/Hosting/Zuständigkeit unklar) |
| 4 | Keine automatische TLS-Budget-Überwachung | bei Erschöpfung des Wochenbudgets fällt erst die Zertifikatsausstellung als Fehler auf (HTTPS-Fehler im Unterricht) | manuelle Zählung in Abschnitt 3 – eine automatische Zählung gibt es bewusst nicht (zu indirekt für das tatsächliche Budget); DNS-01 bleibt der eigentliche Fix |
| 5 | Kein Offsite-Backup | Totalverlust bei Platten-/Hostschaden | entschieden 2026-09-30 (D-Offsite): kein zweiter Standort, Risiko akzeptiert |
| 6 | Restore nur teilweise geprobt, volle RTO unbekannt | der Wiederherstellungsweg mit Stack-Start und Login ist ungeprüft | Dump-Import in Probencontainer mit Datenprobe = 1 am 2026-09-30; Pfad A/B auf frischer VM bleibt offen (Probe nur auf Test-VM) |
| 7 | ufw greift für Docker-Published-Ports nicht | „ufw grün" heißt für Container-Ports nicht „geschützt" | dokumentiert; 127.0.0.1-Bindung ist der Schutz von Prometheus, node-exporter und (seit 2026-10-03) Grafana – ufw greift hier nicht, deshalb Bindung statt Quellregel |
| 8 | Reboot automatisch 03:00 | abgebrochene Unterrichtssitzungen | entschieden 2026-09-30 (D-Reboot-Fenster): 03:00 bleibt, Unterrichtsbeginn 07:45 |
| 9 | Kein Benachrichtigungskanal (nur Regeln), keine Digest-Pins | Ausfälle heben keine Alarmierung aus, Prometheus/Grafana zeigen sie nur dem, der hinsieht | Regeln vorhanden (3 Stück seit 2026-10-03), Logs rotiert; entschieden 2026-09-30 (D-Monitoring): kein Kanal, Grafana reicht – Ausfälle sieht nur, wer hinsieht |
| 10 | Workspace-Selbsttest (T-063) und fachliche Freigabe noch offen | unbekannte Templates könnten Socket/Privilegien nutzen | Erstinventar (Schritt 1) am 2026-09-30 für 6 Templates ohne Befund, Schritt 2 vom Betreiber bestätigt; Schritt 4 nicht protokolliert, siehe [templates/allowlist.md](templates/allowlist.md) |
| 11 | Coder sieht hinter Caddy nur dessen Container-IP | Audit-Einträge nennen keine Client-IP; Konfiguration über `CODER_PROXY_TRUSTED_HEADERS`/`CODER_PROXY_TRUSTED_ORIGINS` ist bewusst unterlassen (Vertrauen auf das ganze Compose-Netz wäre durch einen im selben Netz hängenden Workspace-Container fälschbar) | entschieden 2026-09-30 (B5): Client-IPs bleiben **nicht** im Audit, Empfehlung vom 2026-09-29 übernommen (Datenschutz/Schule). Falls doch: feste IP für `caddy` im Compose-Netz vergeben und `CODER_PROXY_TRUSTED_ORIGINS` **nur auf diese IP** setzen (nie auf das ganze Netz) |
| 12 | ACME läuft über http-01/tls-alpn-01 statt DNS-01 | Zertifikat braucht 80/443 am Server; Schul-Proxy oder gesperrte Ports blockieren die Ausstellung | Alternative dokumentiert: DNS-01 mit `_acme-challenge`-CNAME, braucht Zonen-Zugang beim Provider (B4b) |
| 13 | PostgreSQL-Major-Version braucht Wartung | Wechsel 15 → 18 am 2026-09-30 vor Inbetriebnahme per Dump/Restore (Coder braucht 13+); Support für 18 endet im November 2030, Major-Wechsel sind nie ein reiner `pull` | bei weiterem Major-Wechsel: Wartungsfenster, Dump/Restore wie RESTORE.md, Datenprobe danach; [Upstream-Lifecycle](https://www.postgresql.org/support/versioning/) |

## 9. Offene Entscheidungen (Entscheidungsliste)

**Stand 2026-09-30:** sechs Entscheidungen sind getroffen (D-Socket,
D-Firewall, D-Reboot-Fenster, D-Offsite, D-SSH, D-Monitoring), D-TLS ist
teilentschieden – ihr DNS-01-Teil ist aufgeschoben, bis Zone, Hosting und
die Zuständigkeit für DNS/Ports (zentraler IServ-Server) geklärt sind. Eigentümer jedes
Punktes ist der Betreiber ([OPERATIONS.md](OPERATIONS.md) Abschnitt 11),
für DNS-01 zusätzlich der DNS-/Netzwerk-Verantwortliche. Die Abschnitte 1–7
begründen die Lage, diese Tabelle ist der Sammelpunkt.

| ID | Entscheidung | Optionen | Empfehlung | Voraussetzung | Status 2026-09-30 |
|---|---|---|---|---|---|
| D-TLS | TLS-Ausstellungen robust zählen bzw. On-Demand-Budget schützen; ggf. Umstellung auf DNS-01 | Status quo (On-Demand + `ask`, dateibasierte Zählung); DNS-01-Wildcard ohne On-Demand (B4b) | Status quo; Budget-Warnung ab 20 Ausstellungen/7 Tage; DNS-01 nur mit Zonen-Zugang und Abstimmung | KAS-Zugang von All-Inkl (beim Domainverwalter, nicht beim Betreiber), erst nach Klärung von Zone/Hosting; DNS-API-Token beim Netzwerkadmin anfragen | teilentschieden: Zählung dateibasiert (A6); DNS-01 aufgeschoben bis Zone, Hosting und Zuständigkeit für DNS/Ports geklärt sind (Modul `caddy-dns/all-inkl` bekannt) |
| D-Socket | Workspace-Trennung vom Host (Coder-Container hält den Docker-Socket schreibbar) | Status quo + Template-Allowlist; Workspaces auf separater VM; kompletter Plattformwechsel | Status quo + Allowlist bleiben dauerhaft; Erstinventar und T-063 bleiben Pflicht | – | entschieden: Empfehlung übernommen – keine zweite VM |
| D-SSH | Wann Passwort-Login abgeschaltet wird (Drop-In-Snippet aus Abschnitt 1) | Status quo (Passwort + `ufw allow` der sshd-Ports + fail2ban + Netzbegrenzung); Härtung nach getestetem Key- und Zweit-Zugang; Passwort dauerhaft behalten | Passwort-Login bleibt Standard; Härtung nur auf gesonderten Wunsch | – | entschieden: Passwort bleibt, Nachhärtung ist nicht Standard; Regelwerk 2026-10-03 revidiert: `allow` statt `limit` (geteilte Schul-NAT darf ufw nicht drosseln), fail2ban bleibt Brute-Force-Schutz |
| D-Firewall | `DOCKER-USER`-Regeln für Docker-publizierte Ports ergänzen | Status quo (ufw für Host-Dienste, Schutz über 127.0.0.1-Bindung); `DOCKER-USER`-Kette ergänzen | Status quo, solange öffentliche Ports ausschließlich über Caddy laufen | – | entschieden: Empfehlung übernommen – kein `DOCKER-USER` für publizierte Ports; **2026-10-08 (B3b) ergänzt:** `DOCKER-USER` wird nun gezielt nur für die Egress-Sperre genutzt (10.0.0.0/8 + 192.168.0.0/16 DROP, Abschnitt 4), publizierte Ports bleiben davon unberührt |
| D-Reboot-Fenster | Reboot um 03:00 (`/etc/apt/apt.conf.d/52-coder-reboot`) mit dem Schulbetrieb abstimmen | 03:00 beibehalten; anderes Fenster eintragen; automatischen Reboot abschalten | 03:00 bleibt, abgestimmt gegen Unterrichtsbeginn 07:45 | – | entschieden: Empfehlung übernommen – 03:00 bleibt |
| D-Monitoring | Alarme an einen Empfänger senden (es gibt Regeln, aber keinen Kanal) | Status quo (nur Regeln); Alertmanager mit SMTP/Contact Point; Webhook an bestehenden Schulkanal | Grafana/Prometheus bleiben die Anlaufstelle, kein Kanal | – | entschieden: kein Kanal, Grafana reicht; **2026-10-08 fortgeschrieben:** Empfänger `hert@ghse.de`, Weg Grafana-Mail über IServ-SMTP – Umsetzung wartet auf IServ-Produktivschaltung; bis dahin fängt der tägliche BackupStale-Routine-Check (OPERATIONS §5) den kritischen Fall ab |
| D-Offsite | Offsite-Kopie der Backups einrichten | Status quo (nur lokal, Totalverlust bei Hostschaden); rsync/scp auf zweiten Host im Schulnetz; verschlüsselter Objekt-Speicher | kein zweiter Standort; lokal bleiben Dumps 700/600 und die Restore-Probe der Schutz | – | entschieden: kein zweiter Standort, Restrisiko akzeptiert; **2026-10-08 Transport festgelegt:** vzdump/PBS-Ziel auf anderem Storage/Host + monatlicher verschlüsselter `rsync`-Pull vom Betreiber-Rechner (kein Repo-Automatismus) |
| D-Update-Fenster | Wann die manuellen Stack-/Engine-Updates laufen | nur ad hoc; wöchentlich; monatlich im Fenster | monatlich, erster Samstag 09:00 (Backup grün → Setup-Rerun → §5-Checks), kritische CVEs ad hoc nach Unterrichtsende | – | entschieden 2026-10-08 (OPERATIONS §7 „Update") |

Nur noch offen: **DNS-01** (D-TLS-Teil, deckt sich mit **B4b**) –
aufgeschoben bis Zone, Hosting und die Zuständigkeit für DNS/Ports
geklärt sind; dann wäre der
KAS-Zugang von All-Inkl das Einzige, was noch fehlt. **B5** (Client-IPs im Audit) ist am 2026-09-30 entschieden:
so lassen, Abschnitt 8 Zeile 11. Nicht Teil dieser Liste, weil sie Schritte
und keine Entscheidungen sind: Schritt 4 der Template-Abnahme, volle
Restore-Probe auf frischer VM, Testmatrix, Inbetriebnahme mit DNS/Port-
Weiterleitung.

**Regel für Reparaturen:** Kein Fehlerbild wird durch Abschalten von
Prüfungen, Zurücklassen von Firewall-Regeln im ungünstigen Zustand oder
Überspringen der Verifikation gelöst. Wenn eine Maßnahme die Sicherheit
senkt, braucht sie eine dokumentierte Entscheidung mit Eigentümer und
Frist – siehe [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
