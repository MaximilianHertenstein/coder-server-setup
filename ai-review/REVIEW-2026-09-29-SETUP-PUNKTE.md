# Prüfung der Setup-Fundliste A1–A13, B1–B10 und C1–C5

Stand: 2026-09-29. Bewertet wurden die angehängten Punkte anhand des
Repository-Arbeitsstands. Zutreffende, begrenzte Fehler wurden korrigiert;
Vereinfachungen mit möglicher Auswirkung auf Zugang, Netzwerkregeln oder
Wartungsverhalten wurden nicht ohne Laufzeitnachweis übernommen.

## A. Fehler und Risiken

| Punkt | Ergebnis | Änderung oder Grund |
|---|---|---|
| A1 Setup ohne Wartungs-Lock | Umgesetzt | Vor Konfigurations- und Stack-Änderungen nimmt das Setup denselben Lock wie Backup, Update, Passwortwechsel und Reset. Ein lokaler Pipe-Kanal gibt den Lock beim regulären Ende frei; beim Abbruch schließt er sich mit dem Prozess. Der Backup-Selbsttest übernimmt den Lock-Marker und deadlockt nicht. |
| A2 Generierte Skripte in-place überschrieben | Umgesetzt | `write_managed()` schreibt in eine temporäre Datei im Zielverzeichnis und ersetzt atomar per `mv`. Bei Skripten läuft vor dem Austausch `bash -n`; unveränderter Inhalt löst keinen Austausch aus. |
| A3 `logrotate`/`iproute2` fehlen | Umgesetzt | Beide Pakete werden in Schritt 1 installiert. Der Abschlusscheck führt `logrotate -d /etc/logrotate.conf` aus statt nur eine Datei zu suchen. |
| A4 `grep -q`-Pipelines unter `pipefail` | Umgesetzt | SSH-, UFW- und APT-Ausgaben werden einmal eingelesen und mit Here-Strings geprüft; ein vorzeitig beendetes `grep` kann den Produzenten nicht mehr per SIGPIPE fehlschlagen lassen. |
| A5 `read -rs` trimmt Legacy-Werte | Umgesetzt | Das alte Postgres-Passwort wird für die Rotation nicht benötigt und nicht mehr gelesen. |
| A6 `.env` angeblich im SQL-Backup | Umgesetzt | Fehlermeldung und Restore-Doku stellen klar, dass `pg_dump` keine `.env` enthält. Für einen bestehenden Datenbestand braucht es eine separat gesicherte `.env`; Dumps und Daten liegen außerdem auf demselben Host, solange kein Offsite-Ziel eingerichtet ist. |
| A7 Alarmregeln ohne Empfänger | Nicht umgesetzt | Ohne vereinbarten Mail-/Webhook-Empfänger, Zugangsdaten und Zuständigkeit würde eine erfundene Konfiguration keine Zustellung belegen. Das fehlende Alerting bleibt dokumentiert. |
| A8 Workspace-Egress nicht geprüft | Teilweise umgesetzt | OPERATIONS beschreibt einen HTTPS-Healthcheck aus einem echten Workspace und das Öffnen einer echten Workspace-App-URL. Das wird bewusst nach dem ersten Workspace manuell geprüft: ein Host- oder Coder-Container-Test bildet dessen DNS, Egress und App-Route nicht zuverlässig ab. |
| A9 Erstlaufvalidierung | Umgesetzt | Nach dem Pull und vor `compose up` validieren die gezogenen Caddy- und Prometheus-Images die Caddyfile, Prometheus-Konfiguration und Alarmregeln. |
| A10 Root-Dateisystem-Mount des node-exporters | Umgesetzt | Der Root-Mount verwendet `ro,rslave`, damit Host-Mounts propagiert werden. |
| A11 Coder vertraut Proxy-Headern nicht | Nicht umgesetzt | Dafür müssen die tatsächliche Proxy-Kette, die durchgereichten Header und eine eng begrenzte vertrauenswürdige Proxy-Adresse feststehen. Vertrauen in das ganze Workspace-Netz wäre fälschbar. |
| A12 veralteter Kopfkommentar | Umgesetzt | Automatische Aufgaben sind jetzt vollständig aufgeführt: Backup täglich, TLS-Check wöchentlich, Boot-Check bei jedem Start und möglicher Reboot durch unattended-upgrades. |
| A13 PostgreSQL 15 / Docker-Socket-Risiko | Dokumentiert | Die Supportfrist für PostgreSQL 15 und der nötige Major-Upgrade-/Restore-Plan stehen in README und OPERATIONS. Die Host-root-Äquivalenz des Docker-Sockets bleibt ausdrücklich benannt; eine Architekturänderung braucht eine separate Entscheidung. |

## B. Vereinfachungen

| Punkt | Ergebnis | Grund |
|---|---|---|
| B1 gemeinsamer Datei-Helper | Umgesetzt | `write_managed()` bündelt atomisches Schreiben, Modus, Driftmeldung und Hashpflege; spezialisierte Reload-Prüfungen bleiben dort, wo sie das Laufzeitverhalten steuern. |
| B2 Setup pauschal als root neu starten | Nicht umgesetzt | `sudo -E` würde die gesamte Operator-Umgebung weiterreichen und den bisherigen Aufruf- und Secret-Kontext ändern. Die gezielte `sudo`-Nutzung bleibt erhalten. |
| B3 UFW-SSH-Code kürzen | Nicht umgesetzt | Der bestehende Code erkennt und bewahrt Quellbeschränkungen auch bei inaktiver UFW. Das vereinfachte „Regel vorhanden, also unverändert lassen“ kann eine weltweite Allow-Regel stehenlassen; Löschen oder Ersetzen der vorhandenen Logik könnte den SSH-Zugang lockern. Der Punkt ist besonders relevant, weil der Schulserver per Passwort erreichbar bleiben und der Betreiber sich nicht aussperren will. |
| B4 altes Passwort ganz entfernen | Umgesetzt | Das neue Hex-Passwort wird über `psql`-stdin gesetzt und als psql-Variablenreferenz gequotet. Danach prüfen Negativ- und Positivkontrolle den TCP-Passwortpfad. |
| B5 Containerlisten / Warteschleifen zusammenziehen | Zurückgestellt | Die Checks haben unterschiedliche Wartezeiten und Folgen (Boot-Diagnose, Update-Abbruch, Setup-Zusammenfassung). Healthchecks für alle Dienste oder ein gemeinsames Compose-Warteverhalten wurden nicht auf einer isolierten VM nachgewiesen. |
| B6 `.env`-Schreiblogik vereinheitlichen | Nicht umgesetzt | Erstmalige Erzeugung, GID-Aktualisierung und Passwortrotation haben unterschiedliche Schlüssel- und Fehlerbedingungen. Ein gemeinsamer Setter wäre ein zusätzlicher Refactor ohne belegte Fehlerbehebung. |
| B7 Port-Preflight verkürzen | Nicht umgesetzt | Der aktuelle Check unterscheidet TCP/UDP, IPv4/IPv6, Loopback und eigene Compose-Bindungen und meldet fremde Listener vor `up`. Die Kurzform verlöre diese Zuordnung. |
| B8 Log-Limits nur einmal setzen | Nicht umgesetzt | Das Docker-Daemon-Limit gilt auch für später manuell gestartete Container; Compose wiederholt es gezielt für die sechs Stack-Dienste. Die doppelte Deklaration ist absichtlich. |
| B9 tautologische Checks ersetzen | Umgesetzt | Generierte Shellskripte werden vor Austausch und im Abschlusscheck mit `bash -n` geprüft. Der Reboot-Check wertet `apt-config dump` für beide wirksamen Reboot-Optionen aus. Cron-Dateien werden auf ihre erwartete Zeile geprüft. |
| B10 Cron-/logrotate-Dateien zusammenlegen | Nicht umgesetzt | Die getrennten Dateien trennen Aufgaben und Rotationsgruppen klar. Das Zusammenführen spart wenig, erfordert aber eine Migration bereits eingerichteter Dateien. |

## C. Kleinkram

| Punkt | Ergebnis | Änderung oder Grund |
|---|---|---|
| C1 Boot-Check-Einrückung | Umgesetzt | Überzählige Einrückung entfernt. |
| C2 ACME-Kontaktadresse | Nicht geändert | Eine Funktionsadresse wurde nicht vorgegeben. Eine unbekannte Adresse einzutragen könnte ACME-Hinweise ins Leere schicken; der bestehende Wert bleibt deshalb Betreiberkonfiguration. |
| C3 Grafana-Passwort im Terminal | Umgesetzt | Setup und Rotation zeigen den Secret-Wert nicht mehr automatisch. Sie nennen den gezielten Abruf aus der root-lesbaren `.env`. |
| C4 `grafana cli` | Umgesetzt | Passwortrotation und Reparaturanleitung verwenden `grafana cli`. Ein Lauf auf dem Grafana-Image fand in diesem Review nicht statt. |
| C5 führendes `v` beim Versionsvergleich | Umgesetzt | Der Downgradevergleich entfernt ein führendes `v` vor `sort -V`. |

## Sicherheits- und Prüfgrenzen

Die Änderungen haben SSH-Authentifizierung und UFW-Regeln nicht umgestellt.
Passwort-SSH bleibt für die erste Inbetriebnahme vorgesehen; die Beschränkung
auf das Schulnetz ist eine Vorgabe der externen Netz-Infrastruktur. Das Setup
prüft diese äußere Netzgrenze nicht und schaltet Passwort-Login nicht ab.

In diesem Review wurden weder Tests ausgeführt noch Befehle auf einem Server
ausgeführt. Insbesondere stehen Caddy-/Prometheus-Validierung und
Passwortrotation auf dem installierten Grafana-Image als Laufzeitprüfungen
noch aus. Die Validierungen sind jetzt in den Setup-Ablauf eingebaut und
laufen bei dessen nächster Ausführung vor dem Start des Stacks.
