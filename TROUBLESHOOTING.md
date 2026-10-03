# TROUBLESHOOTING.md – Fehlerbilder, Diagnose, Behebung

Stand: 2026-09-28. Alle Meldungen und Befehle stammen aus dem tatsächlich
vorliegenden `setup-coder.sh` bzw. den von ihm erzeugten Skripten.
**Erst diagnostizieren, dann ändern.** Kein Problem wird dadurch gelöst,
dass eine Prüfung abgeschaltet, eine Firewall-Regel dauerhaft entfernt
oder eine Verifikation übersprungen wird.

Einstieg: [README.md](README.md) · Betrieb: [OPERATIONS.md](OPERATIONS.md) ·
Sicherheit: [SECURITY.md](SECURITY.md) · Restore: [RESTORE.md](RESTORE.md)

## 0. Immer zuerst

```bash
cd /opt/coder && sudo docker compose ps
sudo docker logs coder --tail=50
sudo docker logs coder-postgres --tail=50
sudo docker logs coder-caddy --tail=50
sudo docker compose -f /opt/coder/docker-compose.yml config --quiet
tail -50 /var/log/coder-backup.log
```

Zusammenfassung eines früheren Setup-Laufs steht am Ende dessen Ausgabe
(`[OK]`/`[WARNUNG]`/`[FEHLER]`). Das Setup meldet `FEHLER` nur, wenn es
auch `exit 1` liefert – Warnungen lassen den Stack laufen.

---

## A. Der Setup-Lauf bricht ab

### A1. `Fehler: Docker-GPG-Fingerprint unerwartet (...)`

| | |
|---|---|
| **Diagnose** | `sudo gpg --show-keys --with-colons /etc/apt/keyrings/docker.gpg \| awk -F: '/^fpr:/ {print $10; exit}'` |
| **Erwartete Ursache** | Docker hat den Signaturschlüssel rotiert; der im Skript hinterlegte Fingerprint `9DC8…CD88` stimmt nicht mehr. |
| **Sichere Behebung** | Fingerprint unter <https://docs.docker.com/engine/install/debian/> abgleichen, bei Abweichung den Wert **nach Prüfung** der Quelle im Skript anpassen, Setup erneut ausführen. Nicht das Prüfen entfernen. |

### A2. `Fehler: Docker-Daemon antwortet nicht (docker info)`

| | |
|---|---|
| **Diagnose** | `systemctl status docker --no-pager`, `sudo journalctl -u docker -n 50` |
| **Erwartete Ursache** | Dienst nicht gestartet, defekte Installation, Platte voll. |
| **Sichere Behebung** | `sudo systemctl start docker`; danach Setup erneut. Bei dauerhaftem Scheitern erst die Ursache im Journal klären, nicht das Setup weiterläufig erzwingen. |

### A3. `/opt/coder/.env existiert, ist aber unvollständig`

| | |
|---|---|
| **Diagnose** | `sudo awk -F= '{ if ($1 == "POSTGRES_PASSWORD") name=$1; else if ($1 == "GRAFANA_ADMIN_PASSWORD") name=$1; else next; print name ": " (substr($0, index($0, "=") + 1) != "" ? "vorhanden" : "leer") }' /opt/coder/.env`, `sudo stat -c '%a %U:%G %n' /opt/coder/.env` – zeigt keine Secret-Werte |
| **Erwartete Ursache** | Hand-Edit oder abgebrochener Lauf hat Schlüssel entfernt/geleert. |
| **Sichere Behebung** | Fehlende Schlüssel von Hand ergänzen, vorhandene Werte behalten (Reparaturtext des Setups), danach Setup erneut ausführen. Eine Passwort-Rotation (OPERATIONS §7) setzt nur `GRAFANA_ADMIN_PASSWORD` und vervollständigt keine fehlenden Schlüssel. Bei fehlender `.env` oder Totalverlust: vollständige `.env` wiederherstellen bzw. Restore nach Runbook. |

### A4. `/opt/coder/.env enthält Nicht-Hex-Passwörter`

| | |
|---|---|
| **Diagnose** | `sudo awk -F= '{ if ($1 == "POSTGRES_PASSWORD") name=$1; else if ($1 == "GRAFANA_ADMIN_PASSWORD") name=$1; else next; value=substr($0, index($0, "=") + 1); print name ": " (value ~ /^[0-9a-f]+$/ ? "hex" : "nicht-hex") }' /opt/coder/.env` – zeigt keine Secret-Werte |
| **Erwartete Ursache** | Legacy-Wert mit Sonderzeichen aus einer älteren Installation. |
| **Sichere Behebung** | Zuerst die betroffene Zeile bestimmen (Diagnose oben). **GRAFANA_ADMIN_PASSWORD betroffen:** nach OPERATIONS §7 neu setzen (Backup vorweg, stdin-Reset in Grafana, `.env`-Zeile atomar nachziehen), danach Setup erneut. **POSTGRES_PASSWORD betroffen:** Rezept darunter ausführen, danach Setup erneut. |

`POSTGRES_PASSWORD` neu setzen – Reihenfolge DB → `.env` → Coder, damit ein
Abbruch immer den alten, konsistenten Zustand lässt (F-010); ein Tausch in
umgekehrter Reihenfolge trennt Coder von der DB:

```bash
PG=$(openssl rand -hex 24)
printf "ALTER USER coder WITH PASSWORD '%s';\n" "$PG" \
  | sudo docker exec -i coder-postgres psql -v ON_ERROR_STOP=1 -U coder -d coder
sudo sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG}|" /opt/coder/.env
cd /opt/coder && sudo docker compose up -d --no-deps coder
```

Der neue Wert steht kurz in der Prozessliste der eigenen root-Shell (gleiche
Privilegienebene); nirgends in Logs, Tickets oder Chats weitergeben.

### A5. `.env-Wert enthält Newline/NUL – wird nicht still getrimmt`

| | |
|---|---|
| **Diagnose** | `sudo python3 -c 'from pathlib import Path; b=Path("/opt/coder/.env").read_bytes(); print("NUL:", "ja" if b"\0" in b else "nein", "Zeilen:", len(b.splitlines()))'` – die reguläre `.env` hat zwei Schlüsselzeilen (ältere Installationen drei); das Kommando gibt keine Werte aus |
| **Erwartete Ursache** | Zeilenumbruch beim Hand-Edit; grep/compose lesen nur die erste Zeile. |
| **Sichere Behebung** | Die fehlerhafte Zusatzzeile entfernen und die Schlüsselzeilen wiederherstellen, ohne Secret-Werte zu trimmen oder auszugeben. Danach Setup erneut ausführen; zeigt das Setup-Gate Nicht-Hex an: A4. |

### A6. `Port <p>/<pr> von fremdem Listener belegt (B2-008)`

| | |
|---|---|
| **Diagnose** | `ss -tlnp \| grep -E ':(80\|443\|9090\|9100\|3001) '`, `ss -ulnp \| grep 443`, `sudo docker ps --format '{{.Names}} {{.Ports}}'` |
| **Erwartete Ursache** | Ein anderer Dienst (Apache/nginx, alter Stack, Fremd-Container) hält einen der geprüften Ports. Eigene `coder`-Container werden unterdrückt – eine Meldung betrifft also wirklich jemand anderen. |
| **Sichere Behebung** | Fremden Dienst identifizieren und bewusst stoppen/umziehen (`sudo systemctl status <dienst>`), **bevor** `up -d` läuft. Die Warnung nicht ignorieren: Caddy startet sonst nicht sauber. |

### A7. Abbruch: SSH-Firewall-Preflight

| | |
|---|---|
| **Diagnose** | `sudo sshd -T \| grep '^port '`, `sudo ufw status numbered` |
| **Erwartete Ursache** | `sshd -T` ist fehlgeschlagen oder liefert keinen Port (dann bricht das Setup vor jeder Serveränderung ab); oder `ufw status` ist nicht lesbar. |
| **Sichere Behebung** | Das Setup hat vor jeder Firewall-Änderung abgebrochen. Ist sshd nicht lesbar/fehlt der Port: `openssh-server` installieren bzw. die Konfiguration reparieren, dann erneut ausführen. Von 22 abweichende Ports (z. B. `2222`) sind kein Abbruchgrund mehr – ufw-Regel und fail2ban-Port folgen der Erkennung; für die sshd_config-Seite selbst gilt: Port-Änderungen in `/etc/ssh/sshd_config.d/` eintragen (vorgezogene Drop-In-Datei), nicht in der Hauptdatei. Quellregeln und fremde ufw-Regeln werden nie angefasst; wer sie ändern will, tut das manuell (`sudo ufw status numbered`, `sudo ufw delete …`) – es gibt keinen Bypass-Parameter mehr. |

### A8. `Wenig Platte unter /opt/coder (< 1 GB)`

| | |
|---|---|
| **Diagnose** | `df -h /opt/coder`, `sudo docker system df`, `ls -lh /opt/coder/backups \| tail` |
| **Erwartete Ursache** | Images, Backups, Container-Logs. |
| **Sichere Behebung** | Alte Backups außerhalb der letzten 14 prüfen, alte Images manuell (`sudo docker image prune`, **nach** Prüfung, dass kein Rollback nötig ist), Logs bereinigen. Kein Auto-Prune im Update – alte Images sind die Rollback-Basis. |

### A9. Setup bricht mitten im Lauf ab (SSH-Abbruch, Reboot)

| | |
|---|---|
| **Diagnose** | Letzte Ausgabe lesen; das Setup nennt die fehlgeschlagene Prüfung/Datei. Jede Datei wird atomar geschrieben (Temp validieren, dann `mv`) – eine abgebrochene Validierung lässt die Live-Datei unangetastet. |
| **Erwartete Ursache** | SSH-Abbruch, Reboot oder ein Preflight-/Validierungsfehler mitten im Lauf. |
| **Sichere Behebung** | Setup erneut ausführen (idempotent, setzt am nächsten fehlenden Punkt ein). Bei einer abgebrochenen Passwort-Rotation (Grafana schon neu, `.env` noch alt): OPERATIONS §7 nochmals durchlaufen. Kein Secret als Befehlsargument, Ticket- oder Logtext weitergeben. |

### A10. `Fehler: /etc/docker/daemon.json existiert, enthält aber kein Log-Limit (max-size/max-file)`

| | |
|---|---|
| **Diagnose** | `sudo cat /etc/docker/daemon.json`; `sudo docker info --format '{{.LoggingDriver}}'` |
| **Erwartete Ursache** | Vorhandene Docker-Konfiguration (z. B. von einem anderen Setup-Skript) ohne Log-Opts. Das Setup schreibt fremde Konfigurationen bewusst weder um noch mergt sie (kein jq als Abhängigkeit) – das wäre ein stiller Verlust von `insecure-registries`, `live-restore` o. Ä. |
| **Sichere Behebung** | Die beiden Schlüssel von Hand ergänzen, übrige Einträge behalten, dann `sudo systemctl restart docker` und Setup erneut ausführen: `{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }`. Die Datei **nicht** löschen, solange dort weitere Optionen stehen. |

---

## B. Zugriff, DNS, TLS

### B1. `https://…/healthz` liefert nicht 200

| | |
|---|---|
| **Diagnose** | `curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://coder.ghse-unterricht.de/healthz`; `getent hosts coder.ghse-unterricht.de`; `sudo docker logs coder-caddy --tail=50`; `sudo docker compose ps` |
| **Erwartete Ursache** | (1) DNS fehlt → Code `000` und `getent` ohne Ergebnis; (2) Portweiterleitung 80/443 fehlt; (3) Zertifikat noch nicht ausgestellt (On-Demand-Erstverzögerung 5–30 s); (4) Coder-Container down. |
| **Sichere Behebung** | Ursache 1/2: DNS-Eintrag und Weiterleitung im Schulnetz einrichten, dann Setup erneut ausführen (Kopfprinzip: Stack läuft trotzdem). Ursache 3: `sudo docker logs coder-caddy --since 10m` beobachten, kurz erneut abfragen. Ursache 4: siehe Abschnitt C. **Nicht** TLS-Prüfungen abschalten oder auf `http://` umstellen. |

### B2. `Wildcard-DNS fehlt (*.… löst nicht auf)`

| | |
|---|---|
| **Diagnose** | `getent hosts setup-probe-$RANDOM.coder.ghse-unterricht.de` |
| **Erwartete Ursache** | Es existiert nur der A-Eintrag für die Apex-Domain, kein Wildcard-Eintrag. |
| **Sichere Behebung** | Wildcard-A-Eintrag `*.coder.…` → öffentliche IP setzen, dann Setup erneut. Ohne ihn laufen Workspace-Apps/Port-Forwarding nicht (Apex-OK gilt nicht für Apps). |

### B3. Workspace-App-URL braucht 5–30 s beim ersten Aufruf / TLS-Fehler

| | |
|---|---|
| **Diagnose** | `sudo docker logs coder-caddy --since 1h \| grep -iE 'obtaining\|error\|acme'`; `sudo /opt/coder/check-tls.sh`; `/var/log/coder-tls.log`; letzter Check: `curl -s http://127.0.0.1:9100/metrics \| grep coder_tls_check_last_success` |
| **Erwartete Ursache** | On-Demand-TLS: Zertifikat wird erst bei Bedarf ausgestellt. Bei Erschöpfung des Wochenbudgets (50/Domain, geteilt) schlägt die Ausstellung fehl. |
| **Sichere Behebung** | Abwarten und erneut prüfen; Ausstellungen bis zur Entscheidung D-TLS beobachten (`curl -s http://127.0.0.1:9100/metrics \| grep '^coder_tls_issuances'` bzw. `sudo /opt/coder/check-tls.sh`, Regel `TlsIssuanceBudgetHigh` ab >20/7 d). Budget-DoS-Muster: steigende Zählung + TLS-Fehler im Unterricht → D-TLS-Eigentümer melden. **Nicht** `ask` entfernen (damit bricht die On-Demand-Ausstellung komplett) und kein zweites Zertifikat-Setup parallel aufsetzen. |

### B4. SSH-Login schlägt fehl / ich sitze draußen

| | |
|---|---|
| **Diagnose** | `sudo fail2ban-client status sshd` (eigene IP gebannt?), `sudo ufw status numbered`, `sudo journalctl -u ssh -n 50` |
| **Erwartete Ursache** | fail2ban-Ban nach 5 Fehlversuchen (1 h), ufw-Regel geändert, oder nach dem SSH-Härtungs-Drop-In (SECURITY Abschnitt 1) ohne funktionierenden Key. |
| **Sichere Behebung** | Über Zweit-Zugang (Konsole/Proxmox/iDRAC): `sudo fail2ban-client set sshd unbanip <ip>`. Ohne funktionierenden Key-Zugang das Härtungs-Drop-In entfernen: Rollback wie in [SECURITY.md](SECURITY.md) Abschnitt 1 (`rm` + `sshd -t` + `reload`). Das Drop-In nur nach getestetem Key-Login und Zweit-Zugang anlegen. |

### B5. Workspace-Subdomain bekommt kein Zertifikat (ask meldet 404 / Connection refused)

| | |
|---|---|
| **Diagnose** | `docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=<NAME>'` (200 = erlaubt, 404 = verboten); `docker exec coder-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`; `docker logs coder-caddy --tail=50`; `sudo docker compose -f /opt/coder/docker-compose.yml config \| grep -A3 on_demand` |
| **Erwartete Ursache** | (1) Der Name passt nicht zum Coder-Muster (mindestens zwei `--`-Trenner, keine Punkte in der ersten Gruppe) – dann ist 404 **korrekt**; das Subformat steht in `SECURITY.md` Abschnitt 3. (2) `Connection refused` = Endpunkt nicht erreichbar, weil Caddyfile/Container-Status defekt ist. (3) Caddyfile-Syntaxfehler. |
| **Sichere Behebung** | Bei (1): Subdomain-Format prüfen, nicht das Muster aufweiten (`.*` würde jede Zertifikatsausstellung öffnen). Bei (2)/(3): Caddyfile aus `setup-coder.sh` neu schreiben (Setup erneut ausführen), danach den Befehl oben wiederholen. **Nicht** `on_demand` entfernen – dann scheitert die Wildcard-Ausstellung komplett. |

### B6. Lokal geht es (mit `--resolve`), von außen/öffentlicher Pfad nicht

| | |
|---|---|
| **Diagnose** | Beide Pfade wie in Schritt 7 getrennt testen: lokal `curl -sS --max-time 10 -o /dev/null -w '%{http_code}\n' --resolve coder.…:443:127.0.0.1 https://coder.…/healthz`, öffentlich ohne `--resolve` (echter DNS-Weg), zusätzlich von einem externen Netz (Handy-Hotspot) derselben URL. `getent hosts coder.…` zeigt die öffentliche IP. |
| **Erwartete Ursache** | NAT-Hairpin/Loopback: der Router im Schulnetz erlaubt es LAN-Clients nicht, die eigene öffentliche IP anzusprechen (Verbindung hängt/`000`), während der lokale `--resolve`-Pfad und echte externe Clients einwandfrei laufen. |
| **Sichere Behebung** | Ergebnis außerhalb des Schulnetzes verifizieren (Hotspot/externes Netz): dort 200 = Betrieb in Ordnung, Hairpin ist nur ein Testeffekt. Hairpin-NAT am Router aktivieren, falls vorhanden und gewünscht; sonst LAN-Tests über den lokalen Pfad dokumentieren und den öffentlichen Pfad nur extern prüfen. **Nicht** Caddy/TLS umkonfigurieren – die Ursache liegt am NAT, nicht am Stack. |

---

## C. Stack und Container

### C1. Ein Container läuft nicht / `[FEHLER] … läuft NICHT`

| | |
|---|---|
| **Diagnose** | `sudo docker ps -a`, `sudo docker logs <name> --tail=100`, `sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres` |
| **Erwartete Ursache** | Postgres nicht healthy → Coder startet nicht (Bedingung `service_healthy`); nach Reboot starten alle parallel und Coder kann gegen unbereites Postgres crash-loopen. |
| **Sichere Behebung** | `cd /opt/coder && sudo docker compose up -d` (winkelt den Stack an), bei Postgres `sudo docker logs coder-postgres` lesen. Nach Reboot den Wiederanlauf prüfen: `sudo docker ps`, Postgres `healthy`, `/healthz` 200. |

### C2. `[FEHLER] Coder-Container GroupAdd enthält docker-GID … NICHT`

| | |
|---|---|
| **Diagnose** | `getent group docker`, `sudo docker inspect -f '{{json .HostConfig.GroupAdd}}' coder` |
| **Erwartete Ursache** | docker-GID hat sich geändert (Neuinstallation/Docker-Update), Compose-Datei und Container sind nicht mehr synchron → kein Socket-Zugriff, keine Workspace-Provisionierung. |
| **Sichere Behebung** | Setup erneut ausführen: es trägt die aktuelle GID fest in die Compose-Datei ein und stellt den Coder-Container bei Änderung neu auf. Danach muss die Probe `[OK] … Socket-Zugriff konfiguriert` lauten. |

### C3. Caddy-Änderung wirkt nicht

| | |
|---|---|
| **Diagnose** | `sudo sha256sum /opt/coder/caddy/Caddyfile`, `sudo docker ps --filter name=coder-caddy` |
| **Erwartete Ursache** | Compose merkt sich Änderungen an eingebundenen Dateien nicht; das Setup lädt die Konfiguration nur bei geändertem Inhalt per `reload` neu (validiert wurde bereits beim Schreiben; kein `restart`: der bräche bestehende Verbindungen). |
| **Sichere Behebung** | Zuerst validieren, dann laden: `docker exec coder-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` und danach dasselbe mit `caddy reload`. Schlägt `validate` fehl, behält Caddy die alte Konfiguration – dann erst den Fehler suchen. Besser: Änderung in `setup-coder.sh` vornehmen und das Setup erneut ausführen – sonst meldet der Folgelauf Drift (Abschnitt G). |

### C4. Nach Reboot: Container fehlen oder Postgres nicht `healthy`

| | |
|---|---|
| **Diagnose** | `sudo docker ps -a`, `sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres`, `sudo docker logs coder-postgres --tail=50`, `sudo journalctl -u docker -n 50 --no-pager` |
| **Erwartete Ursache** | Docker startet nach dem Netzwerk; Postgres braucht bis `healthy`, Coder hält sich an `depends_on: service_healthy`, `/healthz` braucht bei On-Demand-Erstausstellung ggf. Minuten. |
| **Sichere Behebung** | Wie C1 (`docker compose up -d` winkelt den Stack an), danach `docker ps` und `/healthz` prüfen. Das frühere lesende Boot-Gate (`boot-check.sh`, `/var/log/coder-boot.log`) entfällt seit B8. |

### C5. Prometheus zeigt 0 Alarmregeln / Grafana ohne Datasource

| | |
|---|---|
| **Diagnose** | `curl -s http://127.0.0.1:9090/api/v1/rules \| grep -c '"name"'` (erwartet > 0); `docker logs coder-grafana --tail=50 \| grep -i provision`; `ls -l /opt/coder/prometheus/rules/ /opt/coder/grafana/provisioning/datasources/` |
| **Erwartete Ursache** | Prometheus hat SIGHUP nicht verarbeitet oder Grafana hat die geänderte Provisioning-Datei noch nicht eingelesen. |
| **Sichere Behebung** | Prometheus-Konfiguration prüfen und bei Bedarf `sudo docker kill -s HUP coder-prometheus`; Grafana mit `sudo docker restart coder-grafana` neu einlesen lassen. Danach die Diagnose wiederholen. Nicht die `rule_files`-Zeile oder die Provisioning-Mounts entfernen. |

---

## D. Backup

### D1. Kein neues Backup in `/opt/coder/backups`

| | |
|---|---|
| **Diagnose** | `tail -50 /var/log/coder-backup.log`; `systemctl is-active cron`; `cat /etc/cron.d/coder-backup`; `sudo /opt/coder/backup.sh` (manueller Lauf mit Meldung) |
| **Erwartete Ursache** | Cron-Daemon aus (`[FEHLER] Cron-Daemon läuft NICHT`), Lock belegt („übersprungen, Vorgänger läuft noch"), zu wenig Platz, `pg_dump` fehlgeschlagen. |
| **Sichere Behebung** | `sudo systemctl enable --now cron`. Bei Lock: Vorgänger abwarten (Meldetext nennt das Alter des letzten gültigen Backups). Sonst die konkrete Fehlerzeile aus dem Log bearbeiten. **Nicht** das Skript durch häufiges manuelles Ausführen überlagern und **nicht** den Cron-Eintrag löschen. |

### D2. `gzip-Integritätstest fehlgeschlagen` / `kein SQL-Dump-Header`

| | |
|---|---|
| **Diagnose** | `gzip -t <datei>`; `zcat <datei> \| head -c 200` |
| **Erwartete Ursache** | Abbruch mitten im Stream, leeres Stdin, pg_dump-Fehlertext statt Dump. |
| **Sichere Behebung** | Prüfen, ob `coder-postgres` gesund (`pg_isready`), manuellen Lauf wiederholen. Das Skript erzeugt in diesem Fall **keine** Finaldatei – ein defektes Backup wird nie als gültig abgelegt. Das defekte File ggf. entfernen, nachdem das letzte gültige identifiziert ist. |

### D3. `zu wenig freier Platz … Abbruch ohne Datei`

| | |
|---|---|
| **Diagnose** | `df -h /opt/coder/backups`, `ls -lt /opt/coder/backups \| head` |
| **Erwartete Ursache** | Unter 500 MB frei. |
| **Sichere Behebung** | Platz schaffen (alte Logs/Backups außerhalb der letzten 14, alte Images). Der Bodenwert ist bewusst konservativ, aber **unvermessen** – er ersetzt kein Platten-Monitoring. |

### D4. Backup-Datei deutlich kleiner als der Vorgänger (Warnung)

| | |
|---|---|
| **Diagnose** | `ls -l /opt/coder/backups`; Inhaltsvergleich mit dem Vorgänger (`sudo docker exec coder-postgres psql -U coder -d coder -c '\dt'`), Zeitpunkt von Resets prüfen |
| **Erwartete Ursache** | Entweder legitime Verkleinerung (Reset, gelöschte Daten) oder Teilverlust. |
| **Sichere Behebung** | Ursache klären, bevor die Warnung akzeptiert wird. Das Kriterium ist absichtlich nur eine Warnung – eine frische/verkleinerte DB darf nicht abbrechen. |

### D5. Backup läuft, aber `coder_backup_last_success_timestamp_seconds` fehlt

| | |
|---|---|
| **Diagnose** | `ls -ld /opt/coder/node-textfile`; `cat /opt/coder/node-textfile/coder_backup.prom`; `docker exec coder-node-exporter ls -l /var/lib/node-exporter/textfile`; `docker logs coder-node-exporter --tail=20`; `grep -i 'Metrik' /var/log/coder-backup.log` |
| **Erwartete Ursache** | Verzeichnis fehlt oder ist enger als `0755` (backup.sh läuft mit `umask 077`), der textfile-collector ist nicht aktiv, oder nach dem Verzeichnis-Lauf wurde node-exporter nicht neu gestartet. |
| **Sichere Behebung** | `sudo install -d -m 0755 /opt/coder/node-textfile`, `sudo /opt/coder/backup.sh` erneut, `sudo docker restart coder-node-exporter` falls nötig. Wichtig: ein fehlgeschlagener Metrik-Schreibversuch macht ein **gutes Backup nicht** zu einem Fehler – die Dump-Datei bleibt gültig, betroffen ist allein die Alarmregel `BackupStale`. |

---

## E. Firewall, Updates, Wartung

### E1. `[FEHLER] ufw ist NICHT aktiv` / `SSH-ALLOW-Regel fehlt`

| | |
|---|---|
| **Diagnose** | `sudo ufw status verbose`, `grep IPV6 /etc/default/ufw` |
| **Erwartete Ursache** | Lauf abgebrochen vor Schritt 4, oder Regeln wurden manuell verändert. |
| **Sichere Behebung** | Setup erneut ausführen (Regeln werden idempotent gesetzt). Die SSH-Regel ist `ufw allow <sshd-Port>/tcp` (Revision 2026-10: kein `limit` mehr – es würde die geteilte Schul-NAT drosseln); eine alte `limit 22/tcp`-Regel eigener Läufe entfernt das Setup automatisch. Vorgefundene Quellregeln bleiben unangetastet (siehe A7 und [SECURITY.md](SECURITY.md)). |

### E2. `[FEHLER] fail2ban läuft NICHT` / `Jail 'sshd' ist nicht aktiv`

| | |
|---|---|
| **Diagnose** | `sudo systemctl status fail2ban --no-pager`, `sudo fail2ban-client status`, `sudo journalctl -u fail2ban -n 50` |
| **Erwartete Ursache** | Dienst nicht gestartet, Drop-In defekt, `sshd -T` liefert keine `PasswordAuthentication`-Zeile (Drop-In-Problem). Achtung Lese-Reihenfolge: eine vorhandene `/etc/fail2ban/jail.local` hat **Vorrang** vor dem Setup-Drop-In. |
| **Sichere Behebung** | `sudo systemctl restart fail2ban`, danach `sudo fail2ban-client status sshd` muss wieder grün sein. Bei Config-Fehlern `/etc/fail2ban/jail.d/10-coder-sshd.local` und eine vorhandene `jail.local` gegeneinander prüfen (Abschnitt „Vom Setup erzeugte Dateien" in [OPERATIONS.md](OPERATIONS.md)) und das Journal lesen. **Nicht** fail2ban deaktivieren, um die Meldung loszuwerden. |

### E3. `[FEHLER] … 80/tcp fehlt in ufw` u. ä.

| | |
|---|---|
| **Diagnose** | `sudo ufw status numbered` |
| **Erwartete Ursache** | Regeln gelöscht/verändert. |
| **Sichere Behebung** | Setup erneut ausführen. Danach `sudo ufw status` muss `Status: active` und die Regeln (22/tcp ALLOW, 80, 443/tcp, 443/udp, 3001 nur aus privaten Quellen) zeigen. |

### E4. Update läuft nicht durch / `Update-Gate rot`

| | |
|---|---|
| **Diagnose** | Ausgabe des Setup-Laufs (Pre-Upgrade-Backup, `pull`, `up -d`); `sudo docker ps`; `sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres`; `sudo docker logs coder-caddy --tail=50` |
| **Erwartete Ursache** | Pull fehlgeschlagen (Netz/Registry, max. 3 Versuche), Container down, Postgres nicht healthy, `/healthz` ≠ 200 (TLS-Smoke). |
| **Sichere Behebung** | Ursache beheben, Setup erneut ausführen. Rückweg: exakt gepinnte Version in `setup-coder.sh` setzen und Setup erneut ausführen; alte Images sind bis zu manuellem `docker image prune` erhalten. Coder-Major-Updates nur mit verifiziertem Dump ([RESTORE.md](RESTORE.md)), nicht zusammen mit einem DB-Update. |

### E5. `reset-coder.sh` bricht ab: `Volume … wird noch von Container(n) benutzt`

| | |
|---|---|
| **Diagnose** | Meldung nennt die Container-ID; `sudo docker ps -a --filter volume=<name>` |
| **Erwartete Ursache** | Ein fremder Container (Workspace-Rest) hält das Volume. Der Check läuft **vor** `docker compose down` – es wurde nichts verändert. |
| **Sichere Behebung** | Fremden Container inventarisieren und bewusst entfernen (`sudo docker ps -a`, `docker rm …`), danach Reset erneut. Projekt-eigene Container sind von diesem Check ausgenommen. |

### E6. `reset-coder.sh` verweigert die Ausführung

| | |
|---|---|
| **Diagnose** | Meldung nennt den Grund: kein Terminal (Pipe/CI), Bestätigung falsch, oder Backup fehlgeschlagen. |
| **Erwartete Ursache** | Schutz vor unbeabsichtigter Zerstörung. |
| **Sichere Behebung** | Interaktiv ausführen und `RESET` eingeben. Ohne funktionierendes Backup nur nach Kenntnis des neuesten Backups mit `--force` **und** der zweiten Eingabe `RESET-OHNE-BACKUP`. Nie als Routine. |

### E7. Passwort-Rotation meldet einen Abbruch in Phase X

| | |
|---|---|
| **Diagnose** | Phasenname im Fehlertext (`Grafana-Reset`, `.env-Tausch`), `.env.bak.<ts>` |
| **Erwartete Ursache** | Zwischenzustand Grafana/.env. |
| **Sichere Behebung** | Skript erneut ausführen; es würfelt ein neues Grafana-Passwort und synchronisiert die `.env` (alter Stand: `.env.bak.<ts>`). Bleibt der Fehler bestehen, die genannte Phase, Container-Logs und die gesicherte `.env.bak.<ts>` prüfen, bevor weitere Passwortänderungen vorgenommen werden. |

### E8. Warnung: vorhandene Docker-Origin könnte automatische Engine-Updates aktivieren

| | |
|---|---|
| **Diagnose** | Setup-Warnung lesen; `apt-config dump \| grep -E 'Unattended-Upgrade::Origins-Pattern'`; `grep -rn 'o=Docker' /etc/apt/apt.conf.d/` |
| **Erwartete Ursache** | Eine ältere Setup-Version oder eine manuell geänderte APT-Datei erlaubt Docker-Origin-Pakete für unattended-upgrades. |
| **Sichere Behebung** | Das Setup entfernt seine frühere Datei automatisch, wenn sie unverändert ist. Bei einer geänderten/unverwalteten Datei erst den Eigentümer und Inhalt prüfen; keine fremde Origins-Konfiguration blind löschen. Zielzustand: Docker Engine wird in einem abgestimmten Fenster manuell aktualisiert (siehe [OPERATIONS.md](OPERATIONS.md) §7). |

---

## F. Restore

### F1. Import bricht mit Exit ≠ 0 ab

| | |
|---|---|
| **Diagnose** | Fehlermeldung von `psql` lesen (fehlerhafte SQL-Zeile, fehlende Extension, Versionsdrift) |
| **Erwartete Ursache** | `psql` läuft mit `-v ON_ERROR_STOP=1` und stoppt beim ersten Fehler – genau das ist gewollt. |
| **Sichere Behebung** | **STOPP**: Schritt 5 nicht ausführen, kein `up -d`, kein grüner Restore. Dump bzw. Version klären und erneut versuchen. Bei automatisierten Ketten zusätzlich `set -o pipefail`, sonst läuft ein fehlschlagendes `zcat` still durch. |

### F2. Datenprobe liefert nicht `1`

| | |
|---|---|
| **Diagnose** | `sudo docker exec coder-postgres psql -v ON_ERROR_STOP=1 -U coder -d coder -tAc "SELECT count(*) FROM restore_probe WHERE marker='RTO-PROBE-<datum>'"` |
| **Erwartete Ursache** | `0` = leere bzw. frisch erzeugte DB; `>1` = Sonde doppelt; psql-Fehler = Tabelle fehlt, weil ohne Sonde gebackupt wurde. |
| **Sichere Behebung** | Restore **nicht** anerkennen, rot bleiben, Dump/Verfahren prüfen ([RESTORE.md](RESTORE.md)). `SELECT 1` und `/healthz 200` sind ausdrücklich **keine** Bestätigung. Vor dem nächsten Probe-Backup die Sonde wie in den Voraussetzungen anlegen. |

### F3. Grafana-Login schlägt fehl nach Restore/Reset

| | |
|---|---|
| **Diagnose** | `sudo awk -F= '$1 == "GRAFANA_ADMIN_PASSWORD" { found = (substr($0, index($0, "=") + 1) != ""); exit } END { if (found) print "Grafana-Passwort ist gesetzt"; else print "Grafana-Passwort fehlt" }' /opt/coder/.env` – zeigt den Secret-Wert nicht an |
| **Erwartete Ursache** | Das Passwort gilt nur beim allerersten Start; ein Restore/Datenbanktausch ändert es nicht automatisch. |
| **Sichere Behebung** | Nach OPERATIONS §7 neu setzen und den neuen Wert im Passwort-Manager notieren. Nicht das alte Passwort im Klartext suchen oder in Logs posten. |

---

## G. Drift- und Warnmeldungen

### G1. `[WARNUNG] Drift in <datei> …`

| | |
|---|---|
| **Diagnose** | `sudo cat /opt/coder/.generated-hashes`, `sudo sha256sum <datei>` |
| **Erwartete Ursache** | Hand-Änderung an einer generierten Datei (Caddy-Snippet, Cron-Zeit, fail2ban-Drop-In `jail.d/10-coder-sshd.local`, Logrotate). |
| **Sichere Behebung** | Gewollte Änderung in `setup-coder.sh` aufnehmen und Setup erneut ausführen. Der Lauf schreibt die Datei ohnehin neu – die Hand-Änderung geht sonst verloren. Warnung ist beabsichtigt (kein Still-Lauf). |

### G2. Passwort-Login: Setup meldet `OK` (D-SSH)

| | |
|---|---|
| **Diagnose** | `sudo sshd -T \| grep -iE '^(passwordauthentication\|kbdinteractiveauthentication\|permitrootlogin)'` |
| **Erwartete Ursache** | Passwort-Login ist mit D-SSH (2026-09-30) dauerhaft bewusst aktiv; der Abschlusscheck meldet ihn als `OK` (Setup-Versionen vor 2026-10-01 warnten hier). Die Netzvorgabe beschränkt SSH auf das Schulnetz. |
| **Sichere Behebung** | Kein Handlungsbedarf: D-SSH (2026-09-30) lässt Passwort-Login zu. Auf dem Schulserver starkes individuelles Passwort und fail2ban beibehalten und sicherstellen, dass SSH nicht öffentlich weitergeleitet wird. Warnung ist nur dann beabsichtigt, wenn `permitrootlogin yes` steht (muss auf `prohibit-password`). Erst bei gewünschtem Schlüsselzugang: getesteter Key + zweiter Zugang, dann kann das Drop-In aus [SECURITY.md](SECURITY.md) Abschnitt 1 bewusst angelegt werden. Siehe [SECURITY.md](SECURITY.md) Abschnitt 1. |

### G3. Warnung: `ufw-IPv6-Pfad unklar (kein IPV6=yes …)`

| | |
|---|---|
| **Diagnose** | `grep IPV6 /etc/default/ufw` |
| **Erwartete Ursache** | `IPV6=no` → ufw gilt nur für IPv4, Dual-Stack-Annahme greift nicht. |
| **Sichere Behebung** | Ursache klären und dokumentieren (D-Firewall). Nicht still umschalten und so tun, als gälte dieselbe Policy für v6. |

---

## Niemals so „beheben"

| Verlockung | Warum nicht |
|---|---|
| `ufw disable` / Regeln löschen, bis es läuft | Öffnet den Host vollständig; Ursache gehört gefunden (A7, E1, E3). |
| `PasswordAuthentication yes` „vorübergehend“ ohne Key-Test | Brute-Force-Exposition; Härtung nur mit Key + Zweit-Zugang. |
| `--force` bei `reset-coder.sh` als Standardweg | Zerstört Daten ohne funktionierendes Backup. |
| Restore als erfolgreich werten, weil `/healthz` 200 liefert | Liveness ist kein Datenbeweis; Datenprobe muss `1` liefern (F2). |
| `gzip`-/Header-Fehler durch erneutes Überschreiben „reparieren“ | Ein unverifiziertes Backup ist kein Backup; erst die Ursache klären. |
| On-Demand-`ask` entfernen oder abschalten | Zerstört die Wildcard-Ausstellung; D-TLS-Entscheidung nötig (B3). |
| Generierte Dateien dauerhaft auf dem Server korrigieren | Beim nächsten Setup-Lauf werden sie neu geschrieben (G1). |
| Warnungen in Skripten entfernen, damit die Zusammenfassung grün wird | Das Setup meldet Fehler mit `exit 1`; grün ohne Prüfung ist kein Zustand. |
