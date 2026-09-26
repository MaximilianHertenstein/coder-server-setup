# Debian 13 / Docker / System-Administration Review

## Scope

Geprüft wird ausschließlich `setup-coder.sh` (und die darin per Heredoc
erzeugten Artefakte: `docker-compose.yml`, `Caddyfile`, `prometheus.yml`,
`backup.sh`, `update.sh`, `reset-passwords.sh`, `reset-coder.sh`,
`/etc/fail2ban/jail.local`, `/etc/apt/apt.conf.d/52-coder-reboot`,
`/etc/cron.d/coder-backup`) gegen den Zielstand Debian 13 (trixie) mit
Docker Engine + Compose-Plugin. Es wurde kein laufendes System ausgeführt;
Aussagen zu Debian-/Docker-internem Verhalten stützen sich auf offizielle
Dokumentation (docs.docker.com, sources.debian.org, mvo5/unattended-upgrades)
und sind entsprechend als CONFIRMED/LIKELY/ASSUMPTION gekennzeichnet.
Rein sicherheitsbezogene Bedrohungsmodellierung (Docker-Socket-Zugriff,
Host-PID als Angriffsfläche etc.) ist bereits Gegenstand von
[02-security.md](02-security.md) und wird hier nicht dupliziert, sondern nur
insoweit wieder aufgegriffen, wie es um technische Korrektheit statt um
Bedrohungsszenarien geht.

## Befunde

## F-001 – `update.sh`-Kommentar zur Rollback-Fähigkeit stimmt nur für exakt gepinnte Images, nicht für Caddy/Postgres
Severity:
HIGH

Location:
`update.sh`-Heredoc: `docker compose pull` gefolgt von `docker image prune -f`;
Kommentar direkt darüber ("Bewusst '-f' statt '-a' ... macht aber einen
schnellen Rollback ... unmöglich"); Versionierungs-Kommentar im Skriptkopf zu
`CADDY_VERSION`/`postgres:15-alpine` als "bewusst nur auf Minor-Version
gepinnt" bzw. gleichem Prinzip folgend.

Problem:
Der Kommentar suggeriert, dass `docker image prune -f` (ohne `-a`) *immer*
ein Zurückwechseln auf die vorherige Version ermöglicht, weil nur
dangling/untagged Images gelöscht werden. Das stimmt nur für Images, die über
einen **exakten** Tag referenziert werden (`ghcr.io/coder/coder:v2.36.6`,
`prom/prometheus:v3.14.0`, `grafana/grafana:12.4.5`). Für `caddy:2.10` und
`postgres:15-alpine` ist der Tag dagegen absichtlich beweglich (mutable) –
das ist im Kopf-Kommentar sogar explizit so gewollt ("Patch-Updates sollen
dort über 'docker compose pull' automatisch ankommen"). Zeigt `caddy:2.10`
nach einem `pull` auf ein neues Image, wird das alte, vorher unter demselben
Tag laufende Image dadurch zu einem *dangling* (`<none>:<none>`) Image – und
genau das entfernt `docker image prune -f` im unmittelbar folgenden Befehl.
Ein Rollback auf die vorherige Caddy-/Postgres-Patch-Version durch bloßes
Zurücksetzen von `CADDY_VERSION` ist danach nicht mehr ohne erneuten Download
aus dem Internet möglich – exakt das Szenario, das der Kommentar als
verhindert beschreibt.

Evidence:
Docker-Dokumentation zu `docker image prune`: ohne `-a` werden nur
"dangling" Images entfernt; ein Tag-Wechsel auf denselben Repository:Tag
macht das vorherige Image dangling. Der Skriptkopf beschreibt
`CADDY_VERSION`/`postgres:15-alpine` ausdrücklich als bewegliche Tags, im
Gegensatz zu den exakt gepinnten `CODER_VERSION`/`PROMETHEUS_VERSION`/
`GRAFANA_VERSION`.

Operational impact:
Nach einem `sudo /opt/coder/update.sh`, das ein fehlerhaftes Caddy- oder
Postgres-Patch-Release zieht, ist ein schneller Rollback ("Version in
`setup-coder.sh` zurücksetzen, Skript erneut ausführen") für genau diese
beiden Dienste NICHT mehr möglich, ohne das alte Image erneut aus dem
Internet zu laden – was bei einem Netzwerkproblem, einer zurückgezogenen
Version oder einem gesperrten Registry-Zugriff scheitern kann. Für Coder
selbst (der wahrscheinlichste Kandidat für ein fehlerhaftes Update)
funktioniert der beschriebene Rollback dagegen wie dokumentiert.

Proposed change:
Kommentar präzisieren: Rollback-Garantie nur für exakt gepinnte Images
(Coder/Prometheus/Grafana) erwähnen. Für Caddy/Postgres entweder bewusst in
Kauf nehmen (dokumentieren, dass ein Rollback dort einen erneuten Pull
erfordert) oder `docker image prune -f --filter "until=24h"` bzw. ein
kurzes Zeitfenster vor dem Prune einbauen, damit das zuvor aktive Image nicht
sofort weggeräumt wird.

Regression risk:
Ein Zeitfenster vor dem Prune lässt kurzfristig mehr alte Images auf der
Platte liegen (Plattenplatz) – gering, da Caddy/Postgres-Alpine-Images klein
sind.

Test:
In einer Testumgebung `CADDY_VERSION` zweimal auf unterschiedliche, real
existierende Tags setzen, `update.sh` zweimal laufen lassen, danach prüfen ob
das vorherige `caddy`-Image noch lokal vorhanden ist (`docker images` vor und
nach `docker image prune -f`).

Classification:
CONFIRMED

## F-002 – Docker-Neustart-Policy respektiert `depends_on`/Healthcheck-Reihenfolge nach Host-Reboot oder Daemon-Neustart nicht
Severity:
HIGH

Location:
`docker-compose.yml`: alle Services mit `restart: unless-stopped`;
`depends_on: condition: service_healthy` (coder→postgres), `depends_on`
ohne Bedingung (caddy→coder, grafana→prometheus).

Problem:
`depends_on`/`condition: service_healthy` wird nur von der Compose-CLI beim
expliziten `docker compose up` ausgewertet. Nach einem Host-Reboot oder einem
Neustart des Docker-Daemons (z. B. durch `apt`-Upgrade von `docker-ce`,
`systemctl restart docker`, OOM des Daemons) startet `dockerd` alle
Container mit einer Restart-Policy selbstständig neu – dabei wird die in der
Compose-Datei definierte Abhängigkeits-/Gesundheits-Reihenfolge NICHT erneut
ausgewertet. Postgres, Coder, Caddy, Prometheus, Grafana können also in
beliebiger Reihenfolge gleichzeitig hochfahren.

Evidence:
Dies ist dokumentiertes Verhalten von Docker: Restart-Policies wirken auf
Container-Ebene im Docker-Daemon, `depends_on`/Healthcheck-Bedingungen sind
eine reine Compose-CLI-Funktion, die nur beim Aufruf von `docker compose up`
gilt, nicht bei einem vom Daemon selbst ausgelösten Neustart.

Operational impact:
Nach einem automatischen Reboot (siehe F-006/Kernel-Update-Reboot) oder
einem Daemon-Neustart kann der `coder`-Container versuchen, sich zu einer
noch nicht bereiten Postgres-Instanz zu verbinden, und mit einem
Verbindungsfehler beenden. Da `restart: unless-stopped` gilt, startet Docker
ihn danach automatisch erneut (Crash-Loop), bis Postgres bereit ist – meist
selbstheilend, aber mit sichtbaren Fehlern in `docker logs coder` und
temporär nicht erreichbarem Dienst, ohne dass ein Administrator informiert
wird (kein Alerting).

Proposed change:
Für produktionsnahe Robustheit entweder (a) in Coder selbst prüfen/dokumentieren,
ob es bereits eingebaute Connection-Retries besitzt (typischerweise ja, aber
unbestätigt für diese Coder-Version), oder (b) einen kleinen
Wartezyklus/Healthcheck-abhängigen Start-Wrapper (z. B. `depends_on`
zusätzlich mit eigenem Healthcheck für `coder`) ergänzen, damit Caddy nicht
auf einen dauerhaft neu startenden Coder-Container zeigt.

Regression risk:
Zusätzlicher Healthcheck für `coder` kann bei falscher Konfiguration den
Container fälschlich als "unhealthy" markieren und weitere Neustart-Schleifen
auslösen – vor Einführung in einer Testumgebung verifizieren.

Test:
`sudo reboot` (nur in Testumgebung!) und danach `docker compose ps` sowie
`docker logs coder` in den ersten 1–2 Minuten nach dem Boot beobachten, ob
Verbindungsfehler zu Postgres auftreten und sich selbst heilen.

Classification:
CONFIRMED (Docker-Verhalten), LIKELY (dass es hier zu sichtbaren, aber
selbstheilenden Fehlern führt – abhängig vom tatsächlichen Boot-Timing).

## F-003 – `unattended-upgrades` deckt Docker-Pakete aus dem Docker-Fremdrepository standardmäßig nicht ab
Severity:
HIGH

Location:
Schritt `[5/10]`: `sudo apt-get install -y unattended-upgrades`,
`dpkg-reconfigure -f noninteractive unattended-upgrades`; keine eigene
`Unattended-Upgrade::Origins-Pattern`/`Allowed-Origins`-Ergänzung.

Problem:
Das Debian-Paket `unattended-upgrades` installiert standardmäßig
`/etc/apt/apt.conf.d/50unattended-upgrades` mit einer
`Origins-Pattern`-Liste, die nur Ursprünge mit `origin=Debian,...` (Debian
selbst und Debian-Security) enthält. Das in Schritt `[1/10]` eingerichtete
Docker-Repository (`https://download.docker.com/linux/debian`, Origin
"Docker") ist darin nicht enthalten und wird vom Skript auch nicht
nachgetragen. Damit werden `docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-buildx-plugin` und `docker-compose-plugin` von den automatischen
Sicherheitsupdates NICHT erfasst.

Evidence:
Offizielle Dokumentation des `unattended-upgrades`-Projekts (README,
Abschnitt "Setup"/"Allowed-Origins"/"Origins-Pattern"): "The default setup
auto-updates packages in the main and security archives" – bezogen auf die
Debian-Archive, nicht auf beliebige Drittanbieter-Repositories. Ein
Drittanbieter-Ursprung muss explizit über `Origins-Pattern` ergänzt werden.

Operational impact:
Docker-Engine-Sicherheitslücken (z. B. in `runc`/`containerd`, die in
`containerd.io` bzw. `docker-ce` gebündelt sind) werden auf diesem Host NICHT
automatisch geschlossen. Das widerspricht dem im Skriptkopf und in
AGENTS.md dokumentierten Sicherheitsanspruch ("Sicherheitsupdates" als
Bewertungskriterium), obwohl der Docker-Socket-Zugriff des Coder-Containers
(siehe 02-security.md F-001) gerade diesen Layer besonders kritisch macht.

Proposed change:
Eigene Konfigurationsdatei `/etc/apt/apt.conf.d/52-coder-reboot` (oder eine
weitere, z. B. `53-coder-docker-origin`) um einen zusätzlichen
`Unattended-Upgrade::Origins-Pattern`-Eintrag für `origin=Docker` ergänzen,
oder bewusst dokumentieren, dass Docker-Engine-Updates manuell über
`sudo apt-get update && sudo apt-get upgrade docker-ce ...` (getrennt von
Coder/Caddy-Image-Updates) einzuspielen sind, und dies regelmäßig zu tun.

Regression risk:
Automatische Docker-Engine-Updates können Container-Runtime-Verhalten
ändern und im schlimmsten Fall den laufenden Coder-Stack destabilisieren
(z. B. bei Major-Versionssprüngen von `docker-ce`) – vor Aktivierung mit
einem Test-Reboot/Update-Zyklus in einer Nicht-Produktionsumgebung prüfen.

Test:
`apt-cache policy docker-ce` prüfen, welcher Origin-String ("o=…")
tatsächlich für das Docker-Repository gemeldet wird; danach
`sudo unattended-upgrade --debug --dry-run` ausführen und im Log
kontrollieren, ob `docker-ce`/`containerd.io` bei einem anstehenden Update
als "kept back"/nicht erlaubt oder als "will be upgraded" erscheinen.

Classification:
CONFIRMED (Standardverhalten von unattended-upgrades gegenüber
Fremdrepositories), LIKELY bezüglich des exakten Origin-Strings ohne
Live-Prüfung auf dem Zielsystem.

## F-004 – Kein Logging-Limit für Container: unbegrenztes Wachstum von `json-file`-Logs
Severity:
HIGH

Location:
`docker-compose.yml`: kein Service definiert einen `logging:`-Block
(`driver`/`options`).

Problem:
Ohne explizite `logging`-Konfiguration verwendet Docker den Standard-
Log-Treiber `json-file` ohne Größenbegrenzung (kein `max-size`/`max-file`),
sofern der Docker-Daemon selbst nicht global anders konfiguriert wurde
(`/etc/docker/daemon.json` wird vom Skript nicht angelegt). Die Logs aller
sechs Container (insbesondere `coder`, `coder-caddy` mit potenziell
chattyem Access-/On-Demand-TLS-Logging, und `coder-postgres`) wachsen damit
unbegrenzt auf der Root-Partition unter `/var/lib/docker/containers/`.

Evidence:
Docker-Dokumentation zum `json-file`-Log-Treiber: Standardwerte für
`max-size`/`max-file` sind "-1" (unbegrenzt), sofern nicht per
Daemon-Konfiguration oder pro Service überschrieben.

Operational impact:
Direkte Verbindung zum explizit angefragten Prüfpunkt "Verhalten bei vollem
Datenträger": Wächst `/var/lib/docker` unkontrolliert, kann die Root-Partition
volllaufen. Das betrifft dann nicht nur Docker, sondern auch Postgres
(Schreibfehler, im schlimmsten Fall DB-Inkonsistenz), das tägliche Backup
(`backup.sh` kann nicht mehr schreiben, siehe verwandte Bash-Befunde in
01-bash.md F-003) und `unattended-upgrades`/APT selbst (keine
Paketinstallation mehr möglich). Ein einzelner ungebremster Log-Stream kann
so den gesamten Schul-Server lahmlegen.

Proposed change:
Für jeden Service (mindestens `coder`, `coder-caddy`, `coder-postgres`)
einen `logging`-Block mit z. B.
`driver: "json-file"`, `options: {max-size: "10m", max-file: "3"}` ergänzen,
oder global in `/etc/docker/daemon.json` setzen und den Docker-Daemon danach
neu laden.

Regression risk:
Ältere Log-Ausschnitte gehen nach Erreichen der Rotationsgrenze verloren –
für Debugging nach einem Vorfall ungünstig, aber deutlich sicherer als ein
volles Dateisystem. Test vor Rollout: sicherstellen, dass 10m/3 Dateien für
den vorgesehenen Anwendungsfall ausreichend Historie liefern.

Test:
Nach Einführung: `docker inspect coder --format '{{json .HostConfig.LogConfig}}'`
prüfen; künstlich viel Log-Output erzeugen (z. B. per `yes | head` in einem
Testcontainer) und beobachten, dass die Logdatei bei der konfigurierten
Grenze rotiert statt unbegrenzt zu wachsen.

Classification:
CONFIRMED

## F-005 – Keine Speicherlimits (`mem_limit`/`deploy.resources`) für die sechs Container
Severity:
MEDIUM

Location:
`docker-compose.yml`: kein Service definiert Speicher- oder CPU-Limits.

Problem:
Ohne `mem_limit` (bzw. `deploy.resources.limits.memory` im
Compose-Spec-Format) kann jeder einzelne Container den gesamten verfügbaren
Arbeitsspeicher des Hosts beanspruchen. Auf einer kleinen Schul-VM mit
begrenztem RAM kann z. B. ein Speicherleck in Grafana/Prometheus oder viele
gleichzeitige Coder-Workspace-Verbindungen dazu führen, dass der
Linux-OOM-Killer eingreift – und dabei ist nicht garantiert, dass er den
"richtigen" Prozess trifft; er kann ebenso gut `coder-postgres` beenden.

Evidence:
Allgemeines Linux-/Docker-Verhalten: Ohne Cgroup-Speicherlimit gibt es
keinen Container-spezifischen Schutz vor globalem Speicherdruck; die
OOM-Killer-Heuristik (`oom_score_adj`) bevorzugt keine Datenbank-Prozesse
automatisch.

Operational impact:
Ein durch Speicherdruck ausgelöster harter Kill von `coder-postgres`
mitten in einer Transaktion ist grundsätzlich WAL-sicher (PostgreSQL
repliziert nach einem Crash über sein WAL), aber es sind Ausfallzeiten und
im ungünstigsten Fall ein state, in dem mehrere Container gleichzeitig
neu starten (siehe F-002) zu erwarten – auf einer bereits speicherknappen
Maschine ein zusätzliches Risiko.

Proposed change:
Für Prometheus/Grafana (die unvorhersehbarsten Verbraucher bei wachsender
Retention/Dashboards) und optional auch für die übrigen Dienste konservative
`mem_limit`-Werte setzen, passend zur tatsächlichen RAM-Ausstattung des
Zielservers.

Regression risk:
Zu knapp bemessene Limits können Container unter Last mit "OOM killed"
(Exit-Code 137) beenden, statt dass sie graduell degradieren – Limits nur
nach Beobachtung des realen Speicherbedarfs (`docker stats`) über einen
längeren Zeitraum festlegen.

Test:
`docker stats` über mehrere Tage/eine Schulwoche unter realer Last
protokollieren, danach Limits mit ca. 20–30 % Puffer über dem beobachteten
Peak setzen und erneut über mehrere Tage beobachten, ob "OOM killed"-Events
auftreten.

Classification:
LIKELY (allgemeines, gut dokumentiertes Risiko fehlender Cgroup-Limits;
konkrete Wahrscheinlichkeit hängt von der nicht bekannten RAM-Ausstattung
des Zielservers ab)

## F-006 – `DOCKER_GID` wird nur beim allerersten Lauf ermittelt und persistiert, nie aufgefrischt
Severity:
MEDIUM

Location:
Schritt `[1/10]`: `DOCKER_GID=$(getent group docker | cut -d: -f3)`;
Schritt `[2/10]`: `if [ ! -f /opt/coder/.env ]; then ... DOCKER_GID=${DOCKER_GID} ... fi`;
`docker-compose.yml`: `group_add: - "${DOCKER_GID}"` beim `coder`-Service.

Problem:
`DOCKER_GID` wird zwar bei JEDEM Lauf neu aus `getent group docker`
gelesen, aber nur beim allerersten Lauf (wenn `.env` noch nicht existiert)
in die `.env`-Datei geschrieben. Bei allen späteren, erneuten Ausführungen
des idempotenten Skripts (z. B. nach einem Debian-Upgrade, einer
Neuinstallation von Docker oder einer Wiederherstellung aus einem
Server-Backup auf neuer Hardware, bei der die `docker`-Gruppe eine andere
GID bekommen könnte) wird der in `.env` gespeicherte, unter Umständen
veraltete Wert weiterverwendet.

Evidence:
Lesbar direkt im Skript: Die einzige Stelle, an der `DOCKER_GID` in `.env`
geschrieben wird, steht innerhalb des `if [ ! -f /opt/coder/.env ]`-Blocks.

Operational impact:
Weicht die tatsächliche GID der `docker`-Gruppe von der in `.env`
gespeicherten ab, bekommt der `coder`-Container über `group_add` die
FALSCHE Gruppen-ID zugewiesen und kann auf den gemounteten
`/var/run/docker.sock` nicht mehr zugreifen (Permission denied) – Coder
kann dann keine Workspace-Container mehr provisionieren. Das wird vom
Abschlusscheck in Schritt `[10/10]` nicht spezifisch erkannt (nur
"Container läuft" wird geprüft, nicht "kann auf den Socket zugreifen").

Proposed change:
`DOCKER_GID` bei jedem Lauf in `.env` aktualisieren (z. B. per
`sed -i`-Ersetzung wie bereits bei `reset-passwords.sh` für Passwörter
verwendet), unabhängig davon, ob `.env` neu angelegt oder wiederverwendet
wird, und anschließend bei Abweichung automatisch
`docker compose up -d --no-deps coder` erneut ausführen.

Regression risk:
Ein Update von `DOCKER_GID` in einer bestehenden `.env` ist unkritisch,
solange anschließend der `coder`-Container neu erstellt wird, damit die
neue GID wirksam wird (reines Aktualisieren der Datei ohne Recreate wirkt
nicht).

Test:
`getent group docker` vor und nach einem erneuten Lauf vergleichen; gezielt
die GID der `docker`-Gruppe in einer Testumgebung ändern
(`groupmod -g <neue-gid> docker`) und prüfen, ob der `coder`-Container nach
erneutem Skriptlauf weiterhin Zugriff auf den Socket hat.

Classification:
CONFIRMED

## F-007 – `node-exporter` läuft mit `pid: host`, obwohl kein Collector diese Berechtigung nutzt
Severity:
MEDIUM

Location:
`docker-compose.yml`, Service `node-exporter`: `pid: host`; `command:`-Liste
enthält nur `--path.procfs`, `--path.sysfs`, `--path.rootfs`,
`--collector.filesystem.mount-points-exclude`.

Problem:
`pid: host` gibt dem Container Sicht auf den vollständigen
Host-Prozessbaum (PID-Namespace des Hosts). Das ist in vielen
node_exporter-Setups nötig, wenn der (standardmäßig deaktivierte)
`processes`-Collector über `--collector.processes` aktiviert wird. Die
hier konfigurierte `command:`-Liste aktiviert diesen Collector jedoch
NICHT. Die Standard-Collectors (cpu, diskstats, filesystem, loadavg,
meminfo, netdev, …) benötigen kein `pid: host`, sondern lesen ihre Daten
über die bereits vorhandenen `/host/proc`- und `/host/sys`-Bind-Mounts.

Evidence:
Offizielle node_exporter-Dokumentation: der `processes`-Collector ist
standardmäßig deaktiviert ("disabled by default") und ist der einzige in
Frage kommende Collector, der von einem gemeinsamen PID-Namespace
profitiert; alle anderen Standard-Collectors arbeiten über die
`/proc`/`/sys`-Bind-Mounts.

Operational impact:
Kein unmittelbarer funktionaler Schaden, aber unnötig erweiterte
Angriffsfläche/Sichtbarkeit (bereits in 02-security.md F-006 aus
Bedrohungssicht bewertet) für einen Nutzen, der mit der aktuellen
Konfiguration gar nicht eingelöst wird – ein Konfigurationsfehler bzw. eine
nicht mehr benötigte Altlast.

Proposed change:
`pid: host` entfernen, sofern nicht bewusst `--collector.processes`
aktiviert und die damit gewonnenen Metriken tatsächlich in Grafana genutzt
werden sollen. Falls Prozess-Metriken gewünscht sind: `pid: host` behalten
UND `--collector.processes` explizit ergänzen, damit Recht (Berechtigung)
und Zweck (genutzter Collector) wieder übereinstimmen.

Regression risk:
Keines, wenn Prozess-Metriken ohnehin nicht in vorhandenen
Grafana-Dashboards verwendet werden. Vor dem Entfernen kurz prüfen, ob ein
Dashboard `node_processes_*`-Metriken referenziert.

Test:
Nach Entfernen von `pid: host`: `docker compose up -d node-exporter`,
danach `curl 127.0.0.1:9100/metrics` und prüfen, dass die bisher genutzten
Standard-Metriken (cpu/mem/disk/net) weiterhin vorhanden sind.

Classification:
LIKELY (Standard-Collector-Verhalten ist dokumentiert; ob ein Grafana-
Dashboard bereits `node_processes_*`-Metriken referenziert, ist ohne
Zugriff auf die Dashboards nicht abschließend prüfbar)

## F-008 – Prometheus-Retention nur zeitbasiert (15d), keine Größenbegrenzung als Sicherheitsnetz
Severity:
LOW

Location:
`docker-compose.yml`, Service `prometheus`: `command:` mit
`--storage.tsdb.retention.time=15d`, kein
`--storage.tsdb.retention.size`.

Problem:
Die zeitbasierte Begrenzung schützt nicht vor einem Datenträger-Vollauf,
wenn die Scrape-Kardinalität oder -Frequenz unerwartet steigt (z. B. durch
viele gleichzeitige Coder-Workspaces mit vielen Metrik-Labels). Eine
zusätzliche größenbasierte Grenze wäre ein einfaches zweites Sicherheitsnetz.

Evidence:
Prometheus-Dokumentation: `--storage.tsdb.retention.size` kann parallel zu
`--storage.tsdb.retention.time` gesetzt werden; ohne diese Option gibt es
keine harte Obergrenze für die Größe der TSDB auf der Platte.

Operational impact:
Trägt zum unter F-004 beschriebenen Gesamtrisiko "volles Dateisystem" bei,
allerdings mit geringerer Eintrittswahrscheinlichkeit als das unbegrenzte
Container-Logging, da die Scrape-Konfiguration mit zwei statischen Targets
(`coder`, `node-exporter`) aktuell eine überschaubare, stabile Kardinalität
hat.

Proposed change:
Zusätzlich `--storage.tsdb.retention.size=2GB` (oder passend zur
verfügbaren Plattenkapazität) ergänzen.

Regression risk:
Bei zu knapp gewähltem Größenlimit werden ältere Metrikdaten früher
gelöscht als die 15 Tage Zeitretention vorsehen – Wert an tatsächlich
verfügbaren Plattenplatz anpassen.

Test:
Mit einem niedrig gesetzten Testwert (`--storage.tsdb.retention.size=200MB`)
in einer Testumgebung prüfen, ob Prometheus beim Erreichen der Grenze
tatsächlich ältere Blöcke entfernt (Log-Meldung "retention" beobachten).

Classification:
LIKELY

## F-009 – `depends_on` für Caddy/Grafana ist reine Start-Reihenfolge, keine Bereitschaftsprüfung
Severity:
LOW

Location:
`docker-compose.yml`: `caddy: depends_on: - coder` und
`grafana: depends_on: - prometheus` (jeweils ohne `condition:`); weder
`coder` noch `prometheus` besitzen einen `healthcheck:`-Eintrag.

Problem:
Ohne `condition: service_healthy` (wie beim `postgres`→`coder`-Bezug korrekt
verwendet) startet Docker Compose den abhängigen Container, sobald der
referenzierte Container GESTARTET (nicht: bereit) ist. Da weder `coder`
noch `prometheus` einen eigenen Healthcheck definieren, kann `caddy` bzw.
`grafana` seinen jeweiligen Upstream ansprechen, bevor dieser tatsächlich
auf Anfragen antwortet.

Evidence:
Docker-Compose-Dokumentation zu `depends_on`: ohne `condition` wird nur
"container started" abgewartet, nicht Anwendungsbereitschaft.

Operational impact:
Bei einem frischen Start (Schritt `[3/10]`) oder nach einem Reboot (siehe
F-002) kann es zu kurzzeitigen 502/Connection-Refused-Antworten von Caddy
bzw. zu einer initial leeren Grafana-Datenquelle kommen, bis Coder/
Prometheus tatsächlich lauschen. Caddys `reverse_proxy` und Grafanas
Datenquellen-Abfrage sind beide so gebaut, dass sie bei einem späteren
Request automatisch erneut versuchen – das Problem ist also meist
selbstheilend, aber sichtbar für die ersten Nutzer:innen nach einem
Neustart.

Proposed change:
Für `coder` einen einfachen HTTP-Healthcheck auf `/healthz` ergänzen (der
im Abschlusscheck in Schritt `[10/10]` ohnehin bereits als Kriterium
verwendet wird) und `caddy` darauf mit `condition: service_healthy` warten
lassen; analog optional für `prometheus`/`grafana`.

Regression risk:
Ein zu strenger/zu früh greifender Healthcheck kann den Start unnötig
verzögern (Caddy wartet dann aktiv, bis Coder healthy ist) – Timeout-Werte
bewusst wählen.

Test:
`docker compose up -d` in einer Testumgebung mit und ohne den vorgeschlagenen
Healthcheck durchführen und die ersten HTTP-Antworten von Caddy in den
ersten 10–20 Sekunden nach dem Start vergleichen (`watch curl -s -o
/dev/null -w '%{http_code}\n' https://<domain>/healthz`).

Classification:
CONFIRMED

## F-010 – Kein angepasster `stop_grace_period` für Postgres
Severity:
LOW

Location:
`docker-compose.yml`, Service `postgres`: kein `stop_grace_period` gesetzt.

Problem:
Ohne explizite Angabe verwendet Docker Compose den Standardwert von 10
Sekunden zwischen SIGTERM und dem folgenden SIGKILL beim Stoppen eines
Containers (z. B. beim Herunterfahren des Hosts über `docker compose down`
in `reset-coder.sh`, oder beim regulären Shutdown des Hosts). Für eine
kleine Schul-Instanz mit wenig Last ist das in aller Regel ausreichend,
unter ungünstigen Bedingungen (viele offene Verbindungen, laufender
Autovacuum/Checkpoint bei größerer Datenbank) kann PostgreSQL den
"Fast Shutdown" nicht innerhalb von 10 Sekunden abschließen und wird
hart per SIGKILL beendet.

Evidence:
Docker-Compose-Dokumentation: Standard-`stop_grace_period` ist 10s, sofern
nicht anders konfiguriert; PostgreSQL-Dokumentation zum
"Smart"/"Fast"/"Immediate"-Shutdown-Verhalten (SIGTERM entspricht "Fast
Shutdown", SIGKILL entspricht "Immediate Shutdown" mit potenziellem
Crash-Recovery-Bedarf beim nächsten Start).

Operational impact:
Ein per SIGKILL abgebrochener Postgres-Prozess ist dank WAL beim nächsten
Start grundsätzlich wiederherstellbar (kein Datenverlust bestätigter
Transaktionen), führt aber zu einem etwas längeren nächsten Start (WAL-
Replay) statt eines sauberen, schnellen Neustarts.

Proposed change:
`stop_grace_period: 30s` (oder höher, je nach erwarteter Datenbankgröße)
für den `postgres`-Service ergänzen.

Regression risk:
Verlängert im Zweifel die Zeit, die `docker compose down`/ein Host-Shutdown
insgesamt benötigt – auf einer kleinen Schul-VM praktisch vernachlässigbar.

Test:
Unter künstlicher Last (`pgbench` o. ä.) `docker compose stop postgres`
ausführen und in `docker logs coder-postgres` prüfen, ob "database system
is shut down" sauber vor Ablauf der Grace-Period erscheint.

Classification:
ASSUMPTION (allgemein bekanntes PostgreSQL-Shutdown-Verhalten; ob die
Schul-Datenbank in der Praxis überhaupt so groß/belastet wird, dass 10s
nicht reichen, ist ohne Produktivdaten nicht zu belegen)

## F-011 – Bestätigung: Docker-APT-Repository unterstützt Debian 13 (trixie) korrekt
Severity:
INFO

Location:
Schritt `[1/10]`: `... $(. /etc/os-release && echo "$VERSION_CODENAME") stable`.

Problem/Prüfung:
Zu prüfen war, ob `download.docker.com/linux/debian` für den auf Debian 13
gemeldeten Codenamen `trixie` überhaupt eine Distribution bereitstellt –
ohne das wäre das nachfolgende `apt-get update` mit einem "404 Not Found"
für die neue Quelle fehlgeschlagen.

Evidence:
`https://download.docker.com/linux/debian/dists/` listet u. a. ein
`trixie/`-Verzeichnis; die offizielle Docker-Installationsanleitung für
Debian nennt "Debian Trixie 13 (stable)" explizit als unterstützte
OS-Voraussetzung.

Operational impact:
Keiner – die im Skript verwendete dynamische Codename-Ermittlung ist für
Debian 13 technisch korrekt und funktioniert wie vom Skript angenommen.

Proposed change:
Keine Änderung nötig.

Regression risk:
Entfällt.

Test:
`curl -s https://download.docker.com/linux/debian/dists/trixie/` auf dem
Zielsystem gegenprüfen (funktioniert nur mit Netzwerkzugriff nach außen).

Classification:
CONFIRMED

## F-012 – Bestätigung: UFW-Regeln für 80/443 sind gegenüber Docker-veröffentlichten Ports weitgehend wirkungslos (wie im Skript kommentiert)
Severity:
INFO

Location:
Schritt `[4/10]`, Kommentar direkt vor `sudo ufw allow 80/tcp` sowie
`docker-compose.yml` Service `caddy` mit `ports: "80:80"`, `"443:443"`,
`"443:443/udp"`.

Problem/Prüfung:
Der Skript-Kommentar behauptet, Docker trage für per `ports:`
veröffentlichte Container-Ports eigene `iptables`-Regeln ein, die UFW dabei
üblicherweise umgehen. Das wurde gegen die offizielle Docker-Dokumentation
zu Firewalls geprüft.

Evidence:
Docker-Dokumentation ("Docker and ufw" / Packet filtering and firewalls):
Von Docker mit `-p`/`ports:` veröffentlichte Ports werden über eigene
`DOCKER`-Ketten in `iptables` erreichbar gemacht und umgehen dabei
tatsächlich UFWs Standard-Regelwerk; die empfohlene Methode, um Docker-
Container gezielt einzuschränken, ist die `DOCKER-USER`-Kette, nicht UFW.

Operational impact:
Keiner im Sinne eines Fehlers – die Aussage im Skript-Kommentar ist
technisch korrekt, und die tatsächliche Absicherung von 80/443 (bewusst
offen für Coder) sowie 9090/9100/3001 (`127.0.0.1`-Bindung statt UFW)
folgt bereits einem für dieses Docker-Verhalten passenden Muster.

Proposed change:
Keine Änderung nötig; ggf. den Hinweis auf die `DOCKER-USER`-Kette als
"offizieller Ansatzpunkt, falls doch einmal Docker-Ports gefiltert werden
müssen" ergänzen, für zukünftige Erweiterungen des Stacks.

Regression risk:
Entfällt.

Test:
Auf einem Testsystem `sudo iptables -S` bzw. `sudo iptables -t nat -L
DOCKER` nach dem Start des Stacks mit `sudo ufw status verbose`
vergleichen, um die getrennten Regelwerke zu beobachten.

Classification:
CONFIRMED

## Operational Summary

Der Stack ist für eine kleine Schulinstallation grundsätzlich sauber
strukturiert (Healthcheck+`condition: service_healthy` zwischen Postgres und
Coder, `127.0.0.1`-Bindung für Monitoring, dokumentierte UFW/Docker-
Interaktion). Die größten technischen Lücken liegen nicht in offensichtlich
falschem Code, sondern in impliziten Annahmen, die unter Last oder nach
längerer Laufzeit brechen: unbegrenztes Log-Wachstum (F-004), fehlende
Speicherlimits (F-005) und eine nur teilweise zutreffende Rollback-Garantie
in `update.sh` (F-001). Diese drei Punkte betreffen genau die im Auftrag
geforderten Themen "Speicherverbrauch", "Logs", "Dateisystem" und
"Verhalten bei vollem Datenträger" am direktesten und sollten vor einem
produktiven Dauerbetrieb behoben werden.

## Boot / Reboot Risks

- Nach Host-Reboot oder Docker-Daemon-Neustart wird die in der
  Compose-Datei kodierte Start-Reihenfolge (Postgres zuerst, dann Coder,
  dann Caddy) NICHT erneut erzwungen; alle Container mit
  `restart: unless-stopped` starten unabhängig voneinander (F-002).
- `Unattended-Upgrade::Automatic-Reboot-Time "03:00"` verwendet intern
  `shutdown -r 03:00`, was einen Reboot zur konfigurierten Uhrzeit korrekt
  einplant, unabhängig davon, wann genau der tägliche
  `apt-daily-upgrade.timer` ausgelöst wurde – hier wurde keine Abweichung
  vom dokumentierten Verhalten festgestellt.
- Docker-Engine-Updates selbst laufen nicht automatisch mit
  (`unattended-upgrades` deckt das Docker-Repository nicht ab, F-003) –
  ein automatischer Reboot wird also in aller Regel durch Debian-eigene
  Kernel-/System-Updates ausgelöst, nicht durch Docker-Updates.

## Docker Risks

- F-001 (Rollback-Annahme trifft nicht auf alle Images zu),
  F-002 (Restart-Policy vs. Startreihenfolge),
  F-004 (unbegrenztes Log-Wachstum),
  F-005 (keine Speicherlimits),
  F-006 (veraltete `DOCKER_GID` nach erneutem Lauf möglich),
  F-007 (unnötiges `pid: host` ohne genutzten Collector),
  F-009 (fehlende Healthcheck-Kopplung für Caddy/Grafana).

## Debian Risks

- F-003 (Docker-Fremdrepository nicht in automatischen
  Sicherheitsupdates enthalten) ist der zentrale Debian-spezifische Befund:
  Das System-Update-Modell des Skripts (Debian-Pakete automatisch, Coder/
  Caddy/Postgres-Images manuell/über `update.sh`) hat eine Lücke genau in
  der Mitte – der Docker-Engine-Host-Ebene.
- Die Docker-Repository-Einrichtung selbst (Codename-Ermittlung,
  GPG-Key-Verfahren, Paketnamen) ist für Debian 13 (trixie) korrekt
  (F-011).

## Top Priorities

1. F-004 – Logging-Limits für alle Container ergänzen (verhindert das
   wahrscheinlichste "voller Datenträger"-Szenario).
2. F-003 – Docker-Repository in die Sicherheitsupdate-Strategie
   aufnehmen oder bewusst dokumentieren und einen manuellen Prüfprozess
   dafür festlegen.
3. F-001 – `update.sh`-Kommentar zur Rollback-Fähigkeit korrigieren bzw.
   das Prune-Verhalten für Caddy/Postgres anpassen, bevor im Ernstfall auf
   die (nicht zutreffende) Dokumentation vertraut wird.
4. F-002 – Verhalten nach Host-Reboot/Daemon-Neustart in einer
   Testumgebung gezielt beobachten und ggf. einen Healthcheck für `coder`
   ergänzen (siehe auch F-009).
5. F-005 / F-006 – Speicherlimits und eine bei jedem Lauf aktualisierte
   `DOCKER_GID` ergänzen, um zwei unabhängige, aber jeweils den ganzen
   Stack betreffende Ausfallquellen zu schließen.
