# SECURITY.md – Härtung, Grenzen, Entscheidungen

Diese Datei beschreibt den **tatsächlichen** Stand aus `setup-coder.sh` –
inklusive dessen, was bewusst noch nicht gemacht ist. Prüfbefehle stehen
jeweils daneben – Dokumentation ohne Nachweis zählt nicht.

Grundmodell: Coder-Workspace-Nutzer gelten als **nicht vertrauenswürdig**.
Der kritischste Punkt des Stacks ist der Docker-Socket im
Coder-Container (Abschnitt 6).

Einstieg: [README.md](README.md) · Betrieb: [OPERATIONS.md](OPERATIONS.md) ·
Restore: [RESTORE.md](RESTORE.md) · Fehler: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## 1. SSH

- **Passwort-Login ist Standard und bleibt es** (Entscheidung D-SSH).
  SSH ist laut Netzvorgabe **nur aus dem Schulnetz** erreichbar; diese
  Beschränkung liegt in der Netzwerkinfrastruktur, nicht in diesem Setup.
  Eine Verbindung von außen ist netzseitig nicht möglich (bestätigt).
- Das Setup schreibt das eigene Drop-In
  `/etc/ssh/sshd_config.d/01-coder.conf` (sortiert vor jeder `50-*`-Datei,
  z. B. cloud-init) und macht die Passwort-Policy damit explizit und
  überlebend gegenüber Debian-Updates: `PasswordAuthentication yes`,
  `KbdInteractiveAuthentication yes`, `PermitRootLogin prohibit-password`.
  Validiert wird über `sshd -T` auf der **gesamten** Konfiguration
  (Fehlschlag: Abbruch vor dem Reload), geladen nur bei Änderung.
- ufw stellt `allow` für die erkannten sshd-Ports – bewusst **kein**
  `limit`, weil ufw limit 6 Verbindungen/30 s je Quell-IP gelten würde und
  sich die ganze Schul-NAT das teilt. fail2ban ist die Brute-Force-Linie:
  5 Fehlversuche in 10 min → 1 h Ban (inkrementell).
- **Restrisiko der Entscheidung:** jedes Gerät im Schulnetz erreicht Port 22
  und kann per Passwort raten; ein geteiltes oder weitergegebenes Passwort
  bleibt gültig. Eine ufw-Quell-CIDR-Einschränkung (`allow from <Schulnetz>`)
  ist bewusst nicht eingebaut: Container auf dem Host würden sie sonst
  umgehen – dagegen steht die `DENY 172.16.0.0/12`-Gegenregel am sshd-Port
  (Abschnitt 4).

Prüfbefehle:

```bash
sudo ufw status verbose                      # 22/tcp ALLOW?
sudo fail2ban-client status sshd             # Jail aktiv, aktuelle Bans
sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'
sudo journalctl -u ssh -n 50 --no-pager
```

**Optionale Nachhärtung (Key-only) – nicht Standard.** Das Setup-Drop-In
`01-coder.conf` erlaubt Passwort-Login; ein **vorangestelltes** Drop-In
(`00-…`) gewinnt pro Keyword über die lexikalische Reihenfolge und
schaltet Passwort-Login damit ohne Eingriff ins Setup ab. Vorher:
Zweit-Zugang (Konsole/Proxmox/iDRAC) bereithalten und Key-Login aus einem
zweiten Fenster testen. Dann Drop-In anlegen:

```bash
sudo tee /etc/ssh/sshd_config.d/00-coder-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sudo sshd -t && sudo systemctl reload ssh
```

Vor dem Abmelden den Key-Login aus einer zweiten Sitzung verifizieren.
Rückweg bei Fehlschlag (wird **nicht** automatisch zurückgerollt):

```bash
sudo rm /etc/ssh/sshd_config.d/00-coder-hardening.conf
sudo sshd -t && sudo systemctl reload ssh
```

Die Nachhärtung selbst ist eine VM-/Produktionshandlung.

## 2. Secrets

- `/opt/coder/.env`: `600`, `root:root`, atomar erzeugt (Temp-Datei +
  `install -m 600` + `mv`), kein 644-Fenster.
- Passwörter ausschließlich `openssl rand -hex` (24 bzw. 16 Bytes) –
  hex kann die Postgres-Connection-URL und SQL-/Shell-Quoting nicht
  aufbrechen. `GRAFANA_ADMIN_PASSWORD` ist frei wählbar.
- Eine vorhandene, aber **unvollständige** `.env` wird nie still neu
  gewürfelt (das würde die DB-Anmeldung zerstören) – das Setup bricht ab
  und nennt die Reparatur (TROUBLESHOOTING.md A3/A4).
- Newline/NUL in `.env`-Werten wird hart abgewiesen, nicht still getrimmt.
- Passwörter landen nie in der Ausgabe; gezielt abrufen:
  `sudo sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /opt/coder/.env`.
  Nicht in Protokolle, Tickets oder Doku kopieren.
- Rotation (Grafana, manuell): Ablauf in [OPERATIONS.md](OPERATIONS.md) §7 –
  erst `backup.sh`, dann neues Hex-Passwort per STDIN an `grafana cli`
  (nie als `docker exec`-Argument), `.env`-Zeile danach atomar nachziehen.
  `POSTGRES_PASSWORD` bleibt unangetastet.
- Repository-Hygiene: `.gitignore` schließt `.env`, `*.env`, `*.sql`,
  `*.sql.gz`, `*.log`, `backups/` aus. Kein Secret liegt im Repository.

```bash
sudo stat -c '%a %U:%G %n' /opt/coder/.env /opt/coder/backups
git status --porcelain | grep -i env               # muss leer sein
```

## 3. TLS und SNI

Caddy terminiert TLS für `coder.…` und `*.coder.…` (Wildcard für
Workspace-Apps/Port-Forwarding) und proxied nach `coder:3000`.
Wildcard-Zertifikate sind per HTTP-01 nicht möglich; ohne DNS-API-Token
nutzt das Setup die von Coder empfohlene Lösung: **On-Demand-TLS**.

**`ask`-Endpunkt**

`on_demand_tls.permission http` zeigt auf `http://127.0.0.1:9123/ask` –
ein eigener Caddy-Site-Block; Port 9123 steht **nicht** in `ports:` und
hat keine ufw-Regel: von außen unerreichbar, nur aus dem Container-Netz.
Er antwortet `200` nur, wenn der beantragte `?domain=`-Parameter dem
Coder-Subdomänen-Muster entspricht, sonst `404`:

- Muster (Coder-Quellcode `coderd/workspaceapps/appurl/appurl.go`, Format
  `{PORT/APP_SLUG}[--{AGENT_NAME}]--{WORKSPACE_NAME}--{USERNAME}`):
  `^<label>(--<label>){2,}$` + `.` + Apex-Domain. Punkte in der ersten
  Gruppe sind ausgeschlossen – `evil.coder.…`, `a.b.coder.…` und der Apex
  selbst bekommen **kein** Zertifikat.
- Der Apex-Domain-Block läuft **ohne** `on_demand`: sein Zertifikat kommt
  beim Start bzw. bei der regulären Erneuerung.
- Geprüft (`t-b1-on-demand-ask.sh`): 200 für App-Namen mit 2 und 3
  `--`-Trennern, 404 für Apex, `evil.…`, geschachtelte Namen, falsche
  Pfade und fehlende Parameter.

**Was diese Absicherung NICHT leistet**

- Das Muster ist ein **Filter, kein Budgetschutz**: für jeden Namen, der
  hineinpasst, kann ein beliebiger Internet-Teilnehmer das Zertifikat
  weiterhin auslösen – ohne Coder-Account und ohne Authentifizierung.
- Das Wochenbudget (50 Ausstellungen pro registrierter Domain
  `ghse-unterricht.de`) ist **geteilt** mit allen anderen Schuldiensten
  derselben Domain. Bei Erschöpfung bekommen legitime neue Workspace-Apps
  kein Zertifikat → TLS-Fehler im Unterricht.
- Erster Handshake einer neuen Subdomain dauert 5–30 s länger (Zertifikat
  wird beim ersten Aufruf beantragt).
- **Keine automatische Budget-Überwachung** (bewusst, zu indirekt für das
  tatsächliche Budget). Bei Verdacht manuell zählen, ergänzend die
  ACME-Fehler in den Caddy-Logs:

```bash
sudo docker exec caddy sh -c "find /data/caddy/certificates -name '*.crt' -mtime -7" | wc -l
sudo docker logs coder-caddy --tail=200 | grep -iE 'error|acme|limit'
```

Erschöpfung fällt als HTTPS-Fehler auf (Diagnose: TROUBLESHOOTING.md B3).
**Eigentlicher Fix bleibt DNS-01** (Wildcard ohne On-Demand): Zone
`ghse-unterricht.de` liegt bei **All-Inkl** (KAS-API), dafür existiert
das Caddy-Modul `caddy-dns/all-inkl`. Die Zugangsdaten liegen beim
Domainverwalter, nicht beim Betreiber – der hat keinen DNS-Zugang. Die
Umstellung ist **aufgeschoben**, solange unklar ist, ob die Zone bei
All-Inkl bleibt und wie 80/443 zum Zielserver kommen.

## 4. Firewall

**Regeln (vom Setup gesetzt, idempotent)**

| Regel | Wert |
|---|---|
| Default-Policy | `deny incoming`, `allow outgoing` (explizit gesetzt) |
| SSH | **zuerst** `ufw insert 1 deny 172.16.0.0/12 → <sshd-Port>/tcp` (Container aus Docker-Netzen erreichen den Host-SSH-Port sonst über die weltweite `allow`-Zeile), danach `ufw allow <sshd-Port>/tcp` (Ports aus `sshd -T`, meist `22/tcp`) – die `deny`-Gegenprobe ist Teil des Abschlusschecks |
| Workspace-Egress | `/opt/coder/workspace-egress.sh` (systemd, nach `docker.service` und jedem Reboot): `iptables -I DOCKER-USER 1 -d 10.0.0.0/8 -j DROP` und `-d 192.168.0.0/16 -j DROP`. Gesperrt: kompromittierte Workspace-Container → RFC1918 außerhalb der Docker-Netze (auch Schulnetz-Dienste, Proxmox-Oberfläche). Offen: Internet-Ausgang und die Docker-eigenen Netze (`172.16.0.0/12`); kein `ip6tables`, weil die Compose-Netze `EnableIPv6=false` haben. DNS der Container läuft über Dockers Embedded-Resolver `127.0.0.11` (Host-Ebene, `OUTPUT`) und wird von der Sperre nicht getroffen; Wege über publizierte Ports (DNAT → Container-IP in `172.16/12`) ebenfalls nicht – Workspace ↔ Coder über `*:443/80` bleibt heil. Der Re-Run des Setups setzt die Regeln erneut an |
| Web | `ufw allow 80/tcp`, `443/tcp`, `443/udp` (HTTP/3) |
| Grafana | **keine Regel**: nur `127.0.0.1:3001`, Zugang per SSH-Tunnel; vorhandene Alt-Regeln für 3001 und Quellregeln werden beim Lauf innerhalb dieser harten Allowlist entfernt |
| Aktivierung | `ufw --force enable`, gleiche Policy für v4+v6 (sonst WARN und nur v4) |

**Re-Run-Schutz**: Das Setup löscht keine SSH-Regel, die es nicht selbst
angelegt hat. Es setzt `allow <erkannter sshd-Port>/tcp` (idempotent) und
entfernt danach ausschließlich eine vorhandene eigene `limit 22/tcp`-Regel
– erst nach dem `allow`, also nie ein Augenblick ohne SSH-Regel. Ohne
lesbaren ufw-Status bricht das Setup vor jeder Regel- oder Policy-Änderung
ab. Port-Abweichungen von 22 (z. B. `2222`) sind erlaubt: ufw-Regel und
fail2ban-`port` folgen der `sshd -T`-Erkennung.

**Was ufw hier nicht schützt**: Docker trägt für per `ports:`
publizierte Container-Ports eigene iptables-Regeln ein, die ufw dabei
üblicherweise umgehen. Für 80/443 ist das akzeptabel (dort läuft ohnehin
der öffentliche Coder-Zugang); der Schutz der übrigen Dienste kommt aus
der `127.0.0.1`-Bindung (Abschnitt 6), nicht aus ufw. Für SSH (Host-Dienst)
greifen ufw und fail2ban – **außer** für Verkehr aus Docker-Netzen,
deshalb steht die `deny`-Gegenregel für `172.16.0.0/12` als allererste
Regel darüber. Ein `DOCKER-USER`-Einbau für publizierte Ports wurde
geprüft und **nicht** eingebaut (D-Firewall); die Kette wird ausschließlich
für die Egress-Sperre genutzt.

**fail2ban** – eigenes Drop-In
`/etc/fail2ban/jail.d/10-coder-sshd.local`; eine vorgefundene `jail.local`
wird nie angefasst (sie hat laut Lese-Reihenfolge Vorrang – das Setup
meldet das). Jail `sshd`, `backend=systemd`, `maxretry=5`, `findtime=10m`,
`bantime=1h`, `bantime.increment = true`. `ignoreip` schützt Admin-Adressen
vor der geteilten Schul-NAT (sonst sperrt ein Tippfehler die gemeinsame
Quell-IP): Default `127.0.0.1/8 ::1`, setzen per
`sudo env FAIL2BAN_IGNORE_IP='… <Admin-IP>' ./setup-coder.sh` – nur
Admin-Plätze, nicht das ganze Schülernetz. Ohne Änderung lädt das Setup
den Dienst **nicht** neu (sonst würden aktive Bans verworfen).

```bash
sudo ufw status numbered
sudo fail2ban-client status sshd
sudo iptables-save | grep -i docker | head      # Docker-eigene Regeln sichtbar machen
```

## 5. Host-Grundhärtung

- `unattended-upgrades` aktiviert; der Abschlusscheck prüft den
  auslösenden `apt-daily-upgrade.timer` (aktiv + enabled – auf Debian ein
  oneshot-Dienst). Automatischer Reboot um 03:00 Uhr – abgestimmte
  Dauerregel gegen den Unterrichtsbeginn 07:45; in Ferien-/Prüfungsphasen
  vorher manuell abstimmen.
- Docker-apt-Repo mit Fingerprint-Prüfung: weicht der Wert von
  `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` ab, bricht das Setup ab.
- Retry-Begrenzung: `apt`/`curl`/`pull` max. 3 Versuche mit 10 s Pause.
- Docker-Engine und Compose sind von `unattended-upgrades` **ausgenommen**
  (dockerd-Neustart unterbricht Workspaces) – Updates manuell im
  Wartungsfenster ([OPERATIONS.md](OPERATIONS.md) §7).
- Container-Logs daemon-weit begrenzt (`daemon.json`, json-file
  10 MB × 3). Liegt eine fremde `daemon.json` ohne diese Schlüssel vor,
  bricht das Setup ab, statt sie umzuschreiben (TROUBLESHOOTING.md A10).
- **Es gibt Alarmregeln, aber noch keinen Kanal**: drei Prometheus-Regeln
  (Coder-Target down, Root-Partition <10 % frei, letztes Backup >25 h)
  sind in Prometheus/Grafana sichtbar, aber kein Alertmanager. **Entscheidung
  D-Monitoring:** Empfänger ist `hert@ghse.de`, Weg ist Grafana-Mail über
  IServ-SMTP – Umsetzung wartet auf die IServ-Produktivschaltung. Bis
  dahin klingelt nichts automatisch; wer hinsieht, sieht die Regeln unter
  `http://127.0.0.1:9090/alerts`, und der tägliche BackupStale-Check
  ([OPERATIONS.md](OPERATIONS.md) §5) fängt den kritischsten Fall als
  Mensch-Linie ab.
- Image-Pinning: Coder/Prometheus/Grafana/node-exporter exakt, Caddy minor
  (`2.11`) und `postgres:18-alpine` mit beweglichen Tags; bit-genaue
  Digests nicht umgesetzt. Alte Images bleiben als Rollback-Basis (kein
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
| sshd | `22/tcp` (Host) | ja, `ufw allow` + fail2ban |

Bindungsregel: neue `ports:`-Einträge **nur** als
`127.0.0.1:<port>:<port>`; öffentliche Ports bleiben Caddy vorbehalten.
Ausnahmen gibt es nicht.

**Docker-Socket – das größte Restrisiko**

- `/var/run/docker.sock` wird dem Coder-Container **schreibbar** gemountet
  (offizielles Coder-Docker-Setup), docker-Gruppe per `group_add`. Wer den
  Coder-Container oder ein davon provisioniertes Workspace-Image
  kontrolliert, kontrolliert den Host (root-äquivalent).
- Die docker-GID wird bei jedem Lauf gegen den Host abgeglichen; der
  Abschlusscheck prüft, dass `GroupAdd` die aktuelle GID enthält.
- **Entscheidung D-Socket:** keine zweite VM – es bleibt beim
  schreibbaren Socket. Die Template-Allowlist ist deshalb **Dauerregel**,
  kein Provisorium: [templates/allowlist.md](templates/allowlist.md) –
  verboten sind dort u. a. Socket-Mounts, `privileged`, `pid/host`,
  `network_mode: host`, Host-Root-Mounts und gemeinsame Netze mit
  `postgres`. Das Erstinventar der sechs Templates ist ohne Befund
  eingetragen; Schritt 4 der Abnahme (Spielraum der Limits im
  laufenden Workspace) ist noch nicht protokolliert.

Weiteres: `node-exporter` läuft mit `pid: host` und bringt `/proc`, `/sys`
und `/` nur lesend eingebunden; ohne `network_mode: host` zeigen
Netzwerkzähler nur den Container-Namespace – Host-Netzwerkmetriken sind
eine bekannte Lücke und werden nicht still aktiviert.

```bash
sudo docker inspect coder | grep -A3 -i mounts
sudo docker inspect -f '{{json .HostConfig.GroupAdd}}' coder
sudo docker inspect -f '{{json .HostConfig.PortBindings}}' $(sudo docker compose -f /opt/coder/docker-compose.yml ps -q)
ss -tlnp; ss -ulnp | grep 443
```

## 7. Backups

- `/opt/coder/backups` ist `700`, Dateien `600`, Inhalt: nur verifizierte
  Postgres-Dumps (14 Stück, lokal auf derselben Platte).
- **Offsite: noch nicht umgesetzt.** Entscheidung D-Offsite: Transport ist
  festgelegt – vzdump/PBS-Ziel auf anderem Storage/Host plus monatlicher
  verschlüsselter `rsync`-Pull `/opt/coder/backups` vom Betreiber-Rechner.
  Bis zur Umsetzung bedeutet Platten- oder Hostverlust: Datenbank und alle
  Backups gleichzeitig weg.
- Workspace-Dateien und `.env` sind nicht Teil des Backups – Verlusttabelle
  in [RESTORE.md](RESTORE.md).
- Ein grüner Backup-Lauf ist **kein** Restore-Nachweis; die Probe gehört
  auf eine Test-VM ([RESTORE.md](RESTORE.md)).

## 8. Bekannte Grenzen

| # | Grenze | Risiko in einem Satz | Status |
|---|---|---|---|
| 1 | Docker-Socket im Coder-Container | Kompromittierung eines Workspaces = Kompromittierung des Hosts | entschieden (D-Socket): keine zweite VM, Restrisiko akzeptiert, Allowlist gilt dauerhaft |
| 2 | SSH-Passwort-Login | Geräte im Schulnetz können trotz ufw/fail2ban Passwörter raten | entschieden (D-SSH): bleibt Standard; Nachhärtung via `00-*.conf` nur auf gesonderten Wunsch (Abschnitt 1) |
| 3 | On-Demand-`ask` prüft nur das Namensmuster | für muster-taugliche Namen kann ohne Account ein Zertifikat ausgelöst werden, geteiltes Wochenbudget erschöpfbar | `ask` gefiltert; Budget-Schutz bleibt; DNS-01 aufgeschoben (Zone/Hosting/Zuständigkeit unklar) |
| 4 | Keine automatische TLS-Budget-Überwachung | bei Erschöpfung fällt erst die Zertifikatsausstellung als HTTPS-Fehler auf | manuelle Zählung in Abschnitt 3; DNS-01 bleibt der eigentliche Fix |
| 5 | Kein Offsite-Backup | Totalverlust bei Platten-/Hostschaden | Transport entschieden (D-Offsite), Umsetzung offen |
| 6 | Restore nicht vollständig geprobt, volle RTO unbekannt | der Wiederherstellungsweg mit Stack-Start und Login ist ungeprüft | Pfad A komplett geprobt (Datenprobe = 1, RTO ~2 min ohne VM-Boot); VM-Boot und Browser-Login bleiben offen |
| 7 | ufw greift für Docker-Published-Ports nicht | „ufw grün" heißt für Container-Ports nicht „geschützt" | `127.0.0.1`-Bindung ist der Schutz der lokalen Dienste |
| 8 | Reboot automatisch 03:00 | abgebrochene Unterrichtssitzungen | entschieden (D-Reboot-Fenster): bleibt, abgestimmt gegen Unterrichtsbeginn 07:45 |
| 9 | Kein Benachrichtigungskanal, keine Digest-Pins | Ausfälle heben keine Alarmierung aus, sie sind nur sichtbar, wer hinsieht | Kanal-Entscheidung D-Monitoring: `hert@ghse.de` über IServ-SMTP, Umsetzung wartet auf IServ |
| 10 | Template-Schritt 4 (Spielraum der Limits) nicht protokolliert | unbekannte Templates könnten Socket/Privilegien nutzen | Erstinventar ohne Befund, Schritt 2 bestätigt; Schritt 4 offen, siehe [templates/allowlist.md](templates/allowlist.md) |
| 11 | Coder sieht hinter Caddy nur dessen Container-IP | Audit-Einträge nennen keine Client-IP; vertrauenswürdige Header-Konfiguration wurde **unterlassen** (das ganze Compose-Netz wäre fälschbar) | entschieden: Client-IPs bleiben nicht im Audit; Fällt doch Bedarf: feste IP für `caddy` und `CODER_PROXY_TRUSTED_ORIGINS` **nur** auf diese IP |
| 12 | ACME läuft über http-01/tls-alpn-01 statt DNS-01 | Zertifikat braucht 80/443 am Server; Schul-Proxy oder gesperrte Ports blockieren die Ausstellung | Alternative DNS-01 dokumentiert (Abschnitt 3) |
| 13 | PostgreSQL-Major-Version braucht Wartung | Major-Wechsel sind nie ein reiner `pull`, sondern Dump/Restore | Support für 18 bis November 2030; bei weiterem Wechsel: Wartungsfenster nach [RESTORE.md](RESTORE.md) |

## 9. Entscheidungen (Stand)

Alle Entscheidungen sind getroffen, Eigentümer jeweils der Betreiber
([OPERATIONS.md](OPERATIONS.md) §11); für DNS-01 zusätzlich der
DNS-/Netzwerk-Verantwortliche.

| ID | Entscheidung | Ergebnis |
|---|---|---|
| D-Socket | Workspace-Trennung vom Host | keine zweite VM; schreibbarer Socket bleibt, Template-Allowlist ist Dauerregel |
| D-SSH | Passwort-Login | bleibt Standard; Nachhärtung per vorrangigem Drop-In nur auf gesonderten Wunsch; ufw `allow` statt `limit` (geteilte Schul-NAT), fail2ban bleibt Brute-Force-Schutz |
| D-Firewall | `DOCKER-USER` für publizierte Ports | nein – Schutz kommt aus der `127.0.0.1`-Bindung; `DOCKER-USER` ausschließlich für die Egress-Sperre (10/8 + 192.168/16 DROP) |
| D-Reboot-Fenster | Reboot 03:00 | bleibt als Dauerregel, in Ferien-/Prüfungsphasen vorher manuell abstimmen |
| D-Monitoring | Alarmweg | Empfänger `hert@ghse.de`, Weg Grafana-Mail über IServ-SMTP – Umsetzung wartet auf IServ-Produktiv; bis dahin fängt der tägliche BackupStale-Check den kritischen Fall ab |
| D-Offsite | Offsite-Kopie der Backups | Transport festgelegt: vzdump/PBS auf anderem Storage/Host + monatlicher verschlüsselter `rsync`-Pull vom Betreiber-Rechner; Umsetzung offen |
| D-Update-Fenster | Wann manuelle Stack-/Engine-Updates laufen | monatlich, erster Samstag 09:00 (Backup grün → Setup-Rerun → §5-Checks); kritische CVEs ad hoc nach Unterrichtsende |
| D-TLS | TLS-Robustheit / DNS-01 | On-Demand-TLS mit `ask` bleibt; DNS-01 **aufgeschoben**, bis Zone, Hosting und die Zuständigkeit für DNS/Ports geklärt sind – dann ist der All-Inkl-KAS-Zugang das Einzige, was fehlt |

Nicht Teil der Liste, weil es Schritte und keine Entscheidungen sind:
Template-Schritt 4, volle Restore-Probe auf frischer VM, Inbetriebnahme
mit DNS/Port-Weiterleitung.

**Regel für Reparaturen:** Kein Fehlerbild wird durch Abschalten von
Prüfungen, Zurücklassen von Firewall-Regeln im ungünstigen Zustand oder
Überspringen der Verifikation gelöst. Wenn eine Maßnahme die Sicherheit
senkt, braucht sie eine dokumentierte Entscheidung mit Eigentümer und
Frist – siehe [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
