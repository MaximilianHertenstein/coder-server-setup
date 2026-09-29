# Prüfung der angehängten Punkte A1–C6

Stand: 2026-09-29. Grundlage: die beigefügte Fundliste und der aktuelle
Arbeitsstand von `setup-coder.sh`, den Compose-Konfigurationen, Tests und
Betriebsdokumenten. Der Schulserver soll bei der ersten Inbetriebnahme
Passwort-SSH erlauben; laut Betreiber ist SSH netzseitig auf das Schulnetz
beschränkt. Diese Vorgabe bleibt maßgeblich.

## A. Falsch oder irreführend

| Punkt | Bewertung | Ergebnis |
|---|---|---|
| A1 Update-Aussage | Zugestimmt | README und OPERATIONS erklären jetzt: `update.sh` zieht die aktuellen Compose-Tags. Neue Inhalte kommen automatisch nur bei den beweglichen Caddy-/Postgres-Tags; die exakt gepinnten Images benötigen eine Pin-Änderung und Setup-Lauf. Docker-Engine-Updates laufen separat manuell. |
| A2 unattended-upgrades-Prüfung | Zugestimmt | Der Check verlangt jetzt exakt `APT::Periodic::Unattended-Upgrade "1";`; ein aktivierter Package-Lists-Check allein reicht nicht. |
| A3 Docker-Origin | Zugestimmt | Neue Setups geben Docker-Pakete nicht mehr für unattended-upgrades frei. Eine alte, hashverwaltete Drop-In-Datei wird beim Re-Run entfernt; veränderte oder fremde Dateien bleiben erhalten und erzeugen eine Warnung. OPERATIONS beschreibt ein manuelles APT-Upgrade samt Unterbrechungsrisiko. |
| A4 fail2ban-Start-Race | Zugestimmt | Vor dem Jail-Status wird bis zu 15 Sekunden auf `fail2ban-client ping` gewartet. |
| A5 temporäres Coder-Login | Zugestimmt | `/tmp/coder-firstuser` wird nach Erfolg oder Fehlschlag des optionalen Erst-Logins entfernt; ein Fehlschlag beim Entfernen wird gemeldet. |
| A6 versionsabhängige Nutzer-Spalte | Zugestimmt | Die SQL-Abfrage liest optionale Flags über `to_jsonb(row)`, statt optionale Spalten direkt zu referenzieren. |
| A7 `curl -k` | Zugestimmt | Boot- und Update-Smokes prüfen jetzt Zertifikatsvertrauen; `--resolve` erhält SNI und Hostname. |
| A8 Cron-Paketreihenfolge | Zugestimmt | `cron` wird zusammen mit den Grundpaketen in Schritt 1 installiert, bevor Cron-Dateien geschrieben werden. |
| A9 doppeltes Boot-Logging | Zugestimmt | Das Boot-Skript hängt den eingefangenen Lauf einmal selbst an die Logdatei und sendet ihn mit `logger < Datei` an syslog. Der Cron-Eintrag hat keinen zweiten Redirect mehr. |
| A10 TLS-Zähler und veraltete Messung | Teilweise zugestimmt | Die Logrotation kann alte Ereignisse aus dem Sieben-Tage-Fenster entfernen; der Zähler bleibt deshalb ausdrücklich eine Untergrenze. Ein Zeitstempel des letzten erfolgreichen Laufs und die Regel `TlsCheckStale` melden jetzt eine fehlende oder mehr als acht Tage alte Messung. Ein genauer Zähler aus den rotierten Logs ist damit nicht gewährleistet. |
| A11 Alarmempfänger | Nicht umgesetzt | Es fehlen ein vereinbarter Empfänger, SMTP-Zugang oder eine Healthchecks-URL. Die Regeln sind ohne Alertmanager weiterhin nur in Prometheus/Grafana sichtbar; das ist dokumentiert. |
| A12 Offsite-Backup | Nicht umgesetzt | Ein Zielsystem, Transportweg, Verschlüsselung und Schlüsselverwahrung sind nicht festgelegt. Dumps, `.env` und Grafana-Daten bleiben wie dokumentiert auf dem Host; Offsite und Restore-Probe bleiben offene Betriebsaufgaben. |
| A13 Proxy-Vertrauen | Nicht umgesetzt | Coder-Header-Vertrauen auf das ganze Compose-Netz wäre von anderen Workspaces fälschbar. Ein künftiger Fix braucht eine feste Caddy-Adresse und eine eng begrenzte Vertrauenskonfiguration; die bestehende Sicherheitsentscheidung bleibt bestehen. |
| A14 node-exporter-Netzwerk | Teilweise zugestimmt | Netzwerkmetriken aus dem Container-Namespace bilden den Host nicht vollständig ab. `network_mode: host` würde aber Service-DNS und Listener-Bindung ändern. Die Lücke und die dafür nötige sichere Scrape-Route sind dokumentiert; das Netzwerkmodell wird ohne VM-Prüfung nicht geändert. |
| A15 Caddy-`ask`-Deprecation | Zugestimmt | Die Caddyfile nutzt jetzt `permission http http://127.0.0.1:9123/ask`. Caddy 2.10.0 unterstützt diese Caddyfile-Form; der lokale Caddy-Parser war in dieser Arbeitsumgebung nicht installiert, daher wurde keine Laufzeitvalidierung behauptet. |

## B. Vereinfachungsvorschläge

| Punkt | Bewertung | Grund |
|---|---|---|
| B1 globaler Root-Reexec / alle `sudo` entfernen | Nicht umgesetzt | Ändert den Ausführungskontext und reicht mit `sudo -E` die gesamte Operator-Umgebung weiter, einschließlich optionaler Zugangsdaten. Das ist ein großer Umbau, kein isolierter Korrekturfix. |
| B2 Hashstore durch `.bak` ersetzen | Nicht umgesetzt | Der Hashstore meldet Operator-Drift explizit und erlaubt die geprüfte Generierung. Ein automatisches Backup jeder Abweichung ändert die Drift- und Aufbewahrungssemantik. |
| B3 Heredocs in Dateien auslagern | Zurückgestellt | Bestehende statische Tests extrahieren Skripte über Zeilenmarker aus `setup-coder.sh`. Ein Split erfordert erst eine parallele Test-/Installationsmigration. |
| B4 gemeinsamen Health-Check einführen | Zurückgestellt | Boot-Gate, Update und Abschlusscheck haben unterschiedliche Wartezeiten und Fehlerfolgen. Zusammenziehen wäre ein Verhaltenseingriff ohne VM-Nachweis. |
| B5 Port-Preflight vereinfachen | Abgelehnt | Der bestehende Prüfer berücksichtigt eigene Compose-Listener sowie Docker-/Dual-Stack-Bindungen. Die vorgeschlagene vereinfachte `ss`-Zeilenprüfung würde diese Fälle wieder anfällig machen. |
| B6 alte Passwort-Migration entfernen | Abgelehnt | Das Reset-Skript unterstützt absichtlich bestehende Legacy-Secrets. Ohne Inventar produktiver `.env`-Dateien könnte deren Rotation danach scheitern. |
| B7 Caddyfile-Shared-Snippet | Nicht umgesetzt | Das ist eine Stilvereinfachung ohne belegten Verhaltensfehler. Nur die relevante veraltete Permission-Syntax wurde migriert. |
| B8 Docker-Key und deb822 umstellen | Nicht umgesetzt | Die vorhandene Key-Fingerprint-Prüfung und Repo-Einrichtung funktionieren; die empfohlene Form ist kein notwendiger Sicherheitsfix für den gefundenen Fehler. |
| B9 Compose-Log-Limits entfernen | Abgelehnt | Das Daemon-Limit deckt alle Container ab; explizite Compose-Limits sichern zusätzlich die sechs Stack-Dienste ab. Die doppelte Deklaration ist hier absichtlich. |
| B10 Prometheus-Neustart ersetzen | Zugestimmt | Geänderte Prometheus-Konfiguration und Regeln werden jetzt mit SIGHUP neu geladen. Grafana startet bei geänderter Datasource-Provisioning-Datei weiter neu. Prometheus dokumentiert SIGHUP als Reload-Weg ohne Lifecycle-Flag. |
| B11 Legacy-Migrationen löschen | Nicht umgesetzt | Es ist nicht belegt, dass keine älteren Installationen existieren. Insbesondere alte Firewall-/fail2ban-Aufräumlogik ohne Bestandsinventar zu löschen wäre riskant. |
| B12 Audit-Kürzel aus Kommentaren entfernen | Nicht umgesetzt | Kürzel verknüpfen Code, Tests und bestehende Review-Berichte. Der Vorschlag ist redaktionell und hätte keine Sicherheitskorrektur zur Folge. |
| B13 Cron durch systemd-Timer ersetzen | Zurückgestellt | `Persistent=true` ändert, wann verpasste Jobs nachgeholt werden. Die Migration von drei Jobs und dem Boot-Gate braucht einen VM-Test und wird nicht nebenbei vorgenommen. |

## C. Kleineres

| Punkt | Bewertung | Ergebnis |
|---|---|---|
| C1 Postgres-Passwort ausgeben | Zugestimmt | Setup und Passwort-Rotation geben nur noch das für den Operator benötigte Grafana-Admin-Passwort aus. Das interne Postgres-Passwort bleibt in der root-lesbaren `.env`. |
| C2 `systemctl status` im Setup | Zugestimmt | Die Statusausgabe ohne Prüffolge wurde aus Schritt 5 entfernt. |
| C3 Update ohne Änderungen abkürzen | Nicht umgesetzt | Vor jedem Lauf gibt es bewusst ein verifiziertes Pre-Update-Backup; ein zuverlässiger No-Op-Test müsste Image-Digests vor und nach dem Pull vergleichen. Der Vorschlag behebt keinen Fehler. |
| C4 Backup-Rotation mit `find` | Nicht umgesetzt | Dateinamen werden vom Skript mit festen Zeitstempeln ohne Leerzeichen erzeugt; die vorhandene Stückzahlrotation ist getestet. Ein Wechsel der Sortiermethode hat hier keinen belegten Sicherheitsgewinn. |
| C5 Tippfehler | Zugestimmt | Die im Quellskript gefundenen Schreibfehler („falschem Tag“, „dieser Block“, „Konsolenzugang“, „Zeitfenster ohne SSH-Regel“) und die fehlerhafte `jq`-Formulierung wurden korrigiert. |
| C6 Docker-Socket-Hinweis | Zugestimmt | Der Header nennt jetzt ausdrücklich die Host-root-Äquivalenz. Die Template-Allowlist verlangt CPU-/Memory-Limits für Schüler-Workspaces; konkrete Werte müssen zum Unterrichtsbedarf passen. |

## Upstream-Nachweise

- Caddy dokumentiert `ask` als deprecated und die HTTP-Permission als Ersatz; der Parser im Tag 2.10.0 akzeptiert `permission http <endpoint>`: [Caddyfile-Optionen](https://caddyserver.com/docs/caddyfile/options), [Caddy 2.10.0 Parser](https://github.com/caddyserver/caddy/blob/v2.10.0/caddyconfig/httpcaddyfile/options.go).
- Prometheus dokumentiert SIGHUP zum Laden von Konfiguration und Regeldateien: [Prometheus Management API](https://prometheus.io/docs/prometheus/latest/management_api/).
- node-exporter weist bei Containerbetrieb auf die nötigen Host-Namespace-Einstellungen hin: [node-exporter Docker-Hinweise](https://github.com/prometheus/node_exporter#docker).
