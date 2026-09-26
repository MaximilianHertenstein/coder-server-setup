# 06 – Architektur-Review: `setup-coder.sh` als Produktionssystem

Rolle: Principal Engineer / Infrastructure Architect.
Geprüft: `setup-coder.sh` (845 Zeilen) als zusammenhängendes System aus
Provisionierung, Konfiguration, Wartung, Monitoring, Backup, Update und
Reset – plus [AGENTS.md](../AGENTS.md),
[copilot-instructions.md](../copilot-instructions.md),
[.gitignore](../.gitignore) und die Reviews
[01-bash](01-bash.md), [02-security](02-security.md),
[03-debian-docker](03-debian-docker.md), [04-coder-caddy](04-coder-caddy.md),
[05-backup-recovery](05-backup-recovery.md).
`tests/` ist leer (keine automatisierten Tests vorhanden).

Es wurde ausschließlich diese Datei (`ai-review/06-architecture.md`)
bearbeitet. Keine Implementierung, keine Änderung an `setup-coder.sh`.

## Methodik

- Vollständige Lesung von `setup-coder.sh` inkl. aller vier eingebetteten
  Wartungsskripte (`backup.sh`, `update.sh`, `reset-passwords.sh`,
  `reset-coder.sh`) und aller generierten Artefakte (`docker-compose.yml`,
  `Caddyfile`, `prometheus.yml`, `jail.local`, `52-coder-reboot`,
  `/etc/cron.d/coder-backup`).
- Architekturbewertung gegen: Kopplung, Zustandsmanagement, Idempotenz,
  Wartbarkeit, Testbarkeit, Recovery, Security, Update-/Rollbackfähigkeit,
  Observability, Betrieb über mehrere Jahre.
- Keine pauschale Empfehlung („alles modularisieren"). Jede Empfehlung nennt
  den konkreten betrieblichen Nutzen (weniger Ausfall, schnellere Recovery,
  überprüfbarer Zustand).
- Überschneidungen mit 01–05 werden nicht dupliziert, sondern aus
  Architektursicht referenziert und eingeordnet.

„Classification" pro Befund:
- **CONFIRMED**: Code-Fakt durch Lesung nachgewiesen.
- **LIKELY**: Code-Fakt nachgewiesen, konkretes Auslöse-Szenario am
  Zielsystem nicht durchgespielt.
- **ASSUMPTION**: Plausible Annahme ohne belastbaren Nachweis im Code.

---

## Komponentenbewertung (Kurzurteil je Baustein)

| Komponente | Architektururteil | Tragender Befund |
|---|---|---|
| Docker Socket (`/var/run/docker.sock` → `coder`) | Fundamentale, bewusste Kopplung von Steuerungsebene und Host-Privilegien; Single Point of Total Compromise | F-005 |
| Coder (`ghcr.io/coder/coder:v2.36.6`) | Korrekt verdrahtet (Access URL, Wildcard, Healthcheck-Pfad), aber ohne Path-App-Härtung und ohne Start-Healthcheck | 04/F-002, F-009 |
| PostgreSQL (`postgres:15-alpine`, floating Tag) | Einzige zustandstragende DB, aber Update-Pfad und App-Update-Pfad sind ein einziger Befehl; Shutdown-Grace fehlt | F-004, 03/F-010 |
| Caddy (TLS-Terminierung, On-Demand) | Funktional korrekt nach offiziellem Tutorial, aber Autorisierung (`ask`) wirkungslos; Root-Domain ebenfalls on-demand | 04/F-001, F-006 |
| Prometheus (15d Retention, 2 Targets) | Sammelt, aber niemand konsumiert: kein Alerting, keine Größenbegrenzung | F-007, 03/F-008 |
| Grafana (loopback-only, Dashboards in Volume) | Erreichbarkeitsmodell richtig (nur SSH-Tunnel), Inhalt (Dashboards) weder versioniert noch gesichert | F-007, 05/F-014 |
| node-exporter (`pid: host` + Host-Mounts) | Berechtigung ohne genutzten Zweck (kein `processes`-Collector); lesender Host-Zugriff ohne Alarmierung | 03/F-007, 02/F-006 |
| SSH (Port 22, weltweit, Passwort aktiv) | Architektur toleriert dauerhaft den unsicheren Zwischenzustand (Warnung statt Enforcement) | F-012 |
| UFW | Deklarierte Grenze, die für Docker-Ports technisch nicht greift; für SSH (Host-Dienst) wirksam | F-006 |
| fail2ban (`sshd`, `backend=systemd`) | Korrekt konfiguriert für den einen Fall (SSH-Brute-Force), deckt nichts anderes ab | Stärke (siehe unten) |
| unattended-upgrades (auto + Reboot 03:00) | Deckt Debian ab, nicht das Docker-Fremdrepo; Reboot unkoordiniert mit Backup-/Coder-Zustand | F-010, 03/F-003 |
| Backups (`pg_dump` lokal, 01:00) | Genau eine Schicht (DB-Dump), lokal, ungeprüft, ohne Restore-Pfad; Workspace-Daten außerhalb des Modells | F-008 |
| Reset (`reset-coder.sh`) | Destruktiv, grob projektunscharf (Volume-Filter), Bestätigung vor statt nach Backup | 05/F-011, 05/F-012 |
| Updates (`update.sh` manuell) | Ein Befehl für alles (`pull` + `up` + `prune`), kein Health-Gate, kein Migrations-Vorbehalt | F-004, 05/F-010 |

---

## Befunde

## F-001 – Ein Skript, drei Rollen: Erstprovisionierung, Konvergenz und Skriptgenerator in einer Datei

Severity:
HIGH

Category:
Architektur / Kopplung / Wartbarkeit

Location:
- [setup-coder.sh](../setup-coder.sh#L100-L845) (Schritte 1–10, 845 Zeilen)
- Generierte Artefakte: `docker-compose.yml`, `Caddyfile`, `prometheus.yml`,
  `backup.sh`, `update.sh`, `reset-passwords.sh`, `reset-coder.sh`,
  `jail.local`, `52-coder-reboot`, `/etc/cron.d/coder-backup`

Problem:
`setup-coder.sh` erfüllt gleichzeitig drei architektonisch verschiedene
Rollen: (a) einmalige Erstprovisionierung (Docker-Repo, Pakete, `.env`-
Erzeugung), (b) wiederholte Konvergenz („einfach erneut laufen lassen",
Schritt 3/4/5/10), (c) Generator für vier Wartungsskripte plus drei
Konfigurationsdateien per Heredoc. Jede Änderung an einem Wartungsskript
erfordert einen vollen Setup-Lauf (inkl. `apt-get update`, Docker-Install,
Firewall-Restart, `compose restart caddy`), weil es keinen separaten
Pfad „nur Wartungsskripte regenerieren" gibt. Umgekehrt triggert jeder
Setup-Re-Run (z. B. nur für eine Domain-Änderung) Nebenwirkungen in allen
drei Rollen (Paketinstallation, Container-Restart, Cron-Umschreibung).

Evidence:
Schritt 1 (Pakete), Schritt 2 (Heredoc-Generierung aller Dateien),
Schritt 3 (`compose up -d` + `restart caddy`), Schritte 4–7 (Firewall,
unattended-upgrades, Cron, eingebettete Skripte) stehen in einer
linearen, nicht einzeln aufrufbaren Sequenz; `set -e` bricht bei Fehler
in einer Rolle alle folgenden ab (vgl. 01/F-001: Abbruch in Schritt 6
verhindert Schritte 7–10).

Operational impact:
- Ursache-Wirkung ist über Jahre nicht mehr zuordenbar: War ein Ausfall
  Folge eines Config-Wechsels, eines Paket-Updates oder eines
  Skript-Regenerats? Alles lief im selben Lauf.
- Wartungsskript-Fix (z. B. `backup.sh`-Atomarität) kann nicht isoliert
  ausgerollt und getestet werden.
- Re-Run zur kleinen Korrektur (Domain, Version) zieht immer das volle
  Nebenwirkungsprofil nach sich (Caddy-Restart, Image-Pull-Verhalten).

Proposed change:
Keine Aufspaltung in viele Dateien (das wäre Kosmetik). Stattdessen zwei
aufrufbare Modi im selben Skript mit konkretem Nutzen: `./setup-coder.sh`
(Erstlauf, alles) und `./setup-coder.sh --converge` (nur Schritte 2, 3,
10: Dateien regenerieren, `compose config --quiet`, `up -d`, Healthcheck).
Nutzen: Wartungsskript- und Config-Änderungen werden ohne Paket- und
Firewall-Seiteneffekte ausrollbar; der riskante Teil (Schritt 1/4/5)
läuft nur bei Bedarf.

Regression risk:
Gering, wenn `--converge` strikt eine Teilmenge der bestehenden Schritte
aufruft (keine neue Logik, nur Sprungmarken). Risiko: Operator ruft aus
Gewohnheit weiter den Volllauf auf – dokumentieren.

Test:
1. In Test-VM Volllauf, dann `--converge`-Lauf nach Caddyfile-Änderung;
   prüfen, dass `apt-get`/ufw/fail2ban-Schritte übersprungen werden
   (`bash -x`-Protokoll), Container-Konvergenz aber stattfindet.
2. Idempotenz-Test: `--converge` zweimal hintereinander, zweiter Lauf
   ohne Container-Recreate (`docker compose ps`, Container-Startzeiten).

Classification:
CONFIRMED

---

## F-002 – Zustandsmanagement: der gemanagte Zustand ist nirgends deklariert

Severity:
HIGH

Category:
Zustandsmanagement / Wartbarkeit / Recovery

Location:
- Zustandsträger: `/opt/coder/.env` ([setup-coder.sh](../setup-coder.sh#L134-L157)),
  Docker-Volumes (`postgres_data`, `caddy_data`, `caddy_config`,
  `prometheus_data`, `grafana_data`,
  [setup-coder.sh](../setup-coder.sh#L275-L280)), Backups
  ([setup-coder.sh](../setup-coder.sh#L128-L129)), Host-Config
  (`jail.local`, `52-coder-reboot`, `/etc/cron.d/coder-backup`)
- Kein State-Inventar, keine Besitzdeklaration im Skript

Problem:
Das Skript verwaltet über die Jahre verteilten Zustand (Secrets,
DB-Volume, Zertifikats-Volumes, Monitoring-Volumes, Host-Dateien), aber
es gibt keine Stelle, die aufzählt, *welcher* Zustand zum System gehört
und *wem* er gehört. Folge: `reset-coder.sh` muss Volume-Namen per
Label-Filter raten (vgl. 01/F-004, 05/F-011), das Backup sichert nur
einen der sechs Zustandsträger (Postgres-Dump, vgl. 05/F-001), und
niemand kann nach zwei Jahren beantworten, ob `grafana_data` wegwerfbar
ist oder rekonstruiert werden muss.

Evidence:
Code-Lesung: Volltextsuche nach dem gemanagten Zustand liefert sechs
Quellen in drei Orten (Dateisystem, Docker-Volumes, Host-Config), aber
kein Kommentar und keine Variable listet sie gemeinsam auf. Der
Reset-Warntext ([setup-coder.sh](../setup-coder.sh#L713-L721)) nennt
Datenbank/Grafana/Prometheus/`.env`, verschweigt aber
`prometheus.yml`-Drift und Host-Config.

Operational impact:
- Jede Recovery (Serververlust, Reset-Reue, Operatorwechsel) beginnt mit
  Reverse-Engineering statt mit einer Liste.
- Teil-Resets (nur Grafana? nur Zertifikate?) sind ohne Inventar nicht
  sicher durchführbar.
- Über Jahre akkumuliert „vergessener" Zustand (alte Images, verwaiste
  Workspace-Container, vgl. 05/F-013).

Proposed change:
Einen einzigen Kommentarblock + drei Variablen am Skriptkopf
(`STATE_VOLUMES`, `STATE_FILES`, `STATE_HOSTFILES`) als maschinenlesbares
Inventar, das `backup.sh` (Umfang), `reset-coder.sh` (Allowlist statt
Label-Raten) und der Abschlusscheck (Vollständigkeit) gemeinsam nutzen.
Nutzen: Backup-Umfang, Reset-Zielmenge und Check-Vollständigkeit können
nicht mehr auseinanderdriften – ein Eintrag, drei Konsumenten.

Regression risk:
Gering – zunächst nur Deklaration plus Nutzung als Allowlist im Reset
(statt nur Filter). Keine Verhaltensänderung im Erfolgsfall.

Test:
1. `bash -n` + `shellcheck` nach Einführung.
2. Reset-Trockentest in Test-VM: angezeigte Löschmenge muss exakt der
   deklarierten Liste entsprechen, fremde Volumes bleiben unangetastet.

Classification:
CONFIRMED

---

## F-003 – Konfiguration wird generiert, aber nicht versioniert: Heredocs statt Artefakte

Severity:
MEDIUM

Category:
Wartbarkeit / Testbarkeit / Konfiguration

Location:
- `docker-compose.yml`-Heredoc ([setup-coder.sh](../setup-coder.sh#L163-L281))
- `Caddyfile`-Heredoc ([setup-coder.sh](../setup-coder.sh#L304-L320))
- `prometheus.yml`-Heredoc ([setup-coder.sh](../setup-coder.sh#L323-L334))
- Kommentar zur `\$`-Escapelogik ([setup-coder.sh](../setup-coder.sh#L160-L162))

Problem:
Die drei laufzeitwirksamen Konfigurationen existieren nur als Heredocs
*innerhalb* des Setup-Skripts. Es gibt keine eigenständige,
versionierte Datei `docker-compose.yml`/`Caddyfile`/`prometheus.yml` im
Repo. Das hat drei konkrete Folgen: (a) `docker compose config` und
Caddy-Validierung sind nur auf dem Zielhost nach Generierung möglich,
nicht in CI gegen das Repo; (b) die `\$`-vs-`$`-Escapelogik (Shell
expandiert `DOMAIN_CODER`, Compose expandiert `POSTGRES_PASSWORD`) ist
fehleranfällig und nur durch sorgfältiges Lesen prüfbar (vgl. 01/F-009:
keine Validierung der eingesetzten Werte); (c) Config-Drift auf dem Host
(manuelle Handänderung an `/opt/coder/Caddyfile`) wird beim nächsten
Re-Run still überschrieben, ohne Diff oder Warnung.

Evidence:
Repo enthält nur `setup-coder.sh`, `ai-review/`, `tests/` (leer); kein
`compose/`, kein `caddy/`, keine Check-in-Kopie der generierten Dateien.
Der `compose config --quiet`-Check ([setup-coder.sh](../setup-coder.sh#L344))
läuft erst nach dem Schreiben auf dem Host.

Operational impact:
- Kein Pre-Deployment-Check: fehlerhafte Config erreicht immer erst den
  Produktionshost.
- Drift ist unsichtbar: Host-Config ≠ Repo-Stand, ohne dass es jemand merkt.
- Review-Aufwand: jede Config-Änderung muss im Heredoc-Kontext (Escaping,
  Einrückung) statt als reines Config-Diff gelesen werden.

Proposed change:
Die drei Dateien als Templates (`compose/docker-compose.yml.tmpl`,
`caddy/Caddyfile.tmpl`, `prometheus/prometheus.yml`) ins Repo legen und
im Skript nur noch per `envsubst`/Platzhalter ersetzen und schreiben.
Nutzen: `docker compose config` und `caddy validate` werden in CI gegen
jeden Commit prüfbar, ohne Zielhost; Drift wird per `diff tmpl vs. Host`
sichtbar. Kein neues Tooling, keine neue Sprache.

Regression risk:
Mittel bei der Migration (Escaping-Fehler beim Herauslösen). Mitigation:
generierte Ausgabe vor/nach dem Herauslösen byte-identisch vergleichen
(`diff <(alt) <(neu)`) für Default-Variablen.

Test:
1. Generierungsvergleich: alte vs. neue Generierung mit identischen
   Env-Werten müssen byte-identisch sein.
2. CI-Check (neu möglich): `docker compose config --quiet` und
   `caddy fmt --overwrite`/`caddy validate` gegen Repo-Dateien.

Classification:
CONFIRMED

---

## F-004 – Ein Update-Befehl für Datenbank, App und Proxy: keine Trennung von Risiko-Klassen

Severity:
HIGH

Category:
Updatefähigkeit / Rollback / Zustandsmanagement

Location:
- Eingebettetes `update.sh` ([setup-coder.sh](../setup-coder.sh#L561-L588)):
  `backup.sh` → `pull` → `up -d --remove-orphans` → `image prune -f`
- Versionierungs-Kommentar ([setup-coder.sh](../setup-coder.sh#L46-L53)):
  Coder/Prometheus/Grafana exakt, Caddy Minor-Pin, Postgres floating
- Kein Health-Gate, kein Versions-Guard nach `up -d`

Problem:
Ein einziger manueller Befehl aktualisiert vier verschiedene
Risiko-Klassen gemeinsam: zustandslose App (Coder, Caddy), zustandslose
Beobachtung (Prometheus, Grafana) und zustandsbehaftete Datenbank
(`postgres:15-alpine`, floating Major-Tag). Ein Coder-Patch zieht damit
immer auch einen potenziellen Postgres-Image-Wechsel nach sich – und
umgekehrt blockiert Vorsicht vor dem DB-Update auch harmlose
Coder-Patches. Nach `up -d` prüft nichts, ob der Stack gesund ist
(Schritt-10-Logik existiert nur im Setup, nicht im Update). Der
Prune-Kommentar verspricht Rollback-Fähigkeit, die für Caddy/Postgres
mit beweglichen Tags nicht gilt (vgl. 03/F-001) und bei
Coder-Schema-Migrationen auch für exakt gepinnte Images brüchig ist
(vgl. 05/F-010).

Evidence:
`update.sh`-Volltext per Lesung: keine Service-Auswahl, kein
`--health`-Gate, kein DB-Guard. Der Kommentar in `update.sh` selbst
räumt ein, dass Versionswechsel nur über Re-Run von `setup-coder.sh`
wirken (Zeilen 582–587) – Update-Pfad und Versions-Pfad sind also
bereits heute zwei verschiedene Mechanismen, nur ohne Trennung im
Aufruf.

Operational impact:
- Aufschub-Effekt über Jahre: weil jedes Update „alles" zieht, wird bei
  Unsicherheit gar nicht upgedatet – dann veralten Coder-Patches
  zusammen mit der gefürchteten DB.
- Fehlgeschlagenes Update fällt erst durch Nutzerbeschwerde auf.
- Rollback-Vertrauen stützt sich auf einen Kommentar, der für die
  Hälfte der Services nicht zutrifft.

Proposed change:
`update.sh` in zwei dokumentierte Pfade teilen, ohne neue Automatik:
`update.sh app` (nur Coder/Caddy: `pull coder caddy && up -d coder caddy`,
danach `/healthz`-Gate) und `update.sh db` (nur Postgres, mit explizitem
Hinweis auf Backup-Verifikation + Downgrade-Vorbehalt bei Migrationen).
Nutzen: Coder-Sicherheitspatches werden ohne DB-Angst eingespielt;
DB-Updates bleiben bewusste, seltene Entscheidungen mit eigenem
Runbook. Kein Auto-Update, keine neue Abhängigkeit.

Regression risk:
Gering – nur Aufruftrennung plus Health-Gate nach `up -d`. Risiko:
Operator ruft weiter `update.sh` ohne Argument auf → Default auf
`app`-Verhalten mit Hinweis festlegen, `db` nur explizit.

Test:
1. Test-VM: `update.sh app` bei verfügbarer Postgres-Neuerung darf das
   Postgres-Image nicht wechseln (`docker images` vorher/nachher).
2. Absichtlich falsche `CODER_VERSION` fahren: Skript muss per
   Health-Gate selbst fehlschlagen, nicht still „erfolgreich" enden.

Classification:
CONFIRMED (Code-Fakt Update-Ablauf); LIKELY (Migrations-Irreversibilität,
hängt von Coder-Upstream ab, vgl. 05/F-010).

---

## F-005 – Docker-Socket-Architektur: Steuerungsebene und Host-Privileg sind ein Container

Severity:
CRITICAL

Category:
Security / Architektur / Kopplung

Location:
- `coder`-Service: `/var/run/docker.sock:/var/run/docker.sock` +
  `group_add: DOCKER_GID` ([setup-coder.sh](../setup-coder.sh#L188-L201))
- Workspace-Provisionierung „direkt über den Docker-Socket"
  ([setup-coder.sh](../setup-coder.sh#L762-L764))

Problem:
Der Coder-Server (netzwerkerreichbar, Multi-User-Eingaben, Templates)
besitzt die unbeschränkte Host-Docker-API. Das ist keine
Fehlkonfiguration im engeren Sinn – es ist die offizielle
Docker-Provisioner-Architektur –, aber architektonisch bedeutet es: Die
gesamte Host-Sicherheit (Secrets, Backups, DB, andere Container) hängt
an der Fehlerfreiheit von Coder, seinen Templates und seiner
Eingabevalidierung. Workspace-Isolation ist damit eine
Anwendungs-Eigenschaft von Coder, keine Infrastruktur-Eigenschaft des
Hosts. Über Jahre (neue Coder-Versionen, neue Templates durch neue
Kollegen, neue Workspace-Typen für den Unterricht) wächst genau die
Fläche, die nie wieder verkleinert wird.

Evidence:
Mount ohne Proxy, ohne Read-only-Semantik, ohne Policy-Layer; keine
Template-Allowlist im Repo (ausführlich in 02/F-001 bis F-004 belegt).
Workspaces entstehen laufzeitseitig außerhalb von Compose, also
außerhalb jeder im Repo sichtbaren Netzwerk-/Mount-Policy.

Operational impact:
- Ein Coder- oder Template-Fehler ist kein App-Fehler, sondern ein
  Host-Takeover (Lesen von `.env`, Backups, `/etc/shadow`-äquivalenten
  Mounts; Schreiben via Host-Mount).
- Jede neue Unterrichtsanforderung („Docker-in-Docker für die Klasse?",
  „privilegierter Workspace für Hardware?") wird zur
  Sicherheitsentscheidung ohne sichtbaren Entscheidungsort.

Proposed change:
Keine Sofort-Migration (das wäre eine Grundsatzentscheidung, siehe
„Decisions Requiring Human Approval"). Architektonisch fällig ist die
kleine, sofort nutzbare Stufe: Template-Policy als checkbare Datei im
Repo (`templates/allowlist.md`: verbotene Optionen – kein Socket-Mount,
kein `privileged`, kein Host-PID/-Netz, keine Host-Root-Mounts, keine
gemeinsamen Netzwerke mit `postgres`), plus ein manueller Abnahmeschritt
vor jedem neuen Template. Nutzen: Der heutige Schutz („wir geben nur
harmlose Templates frei") wird von impliziter Praxis zu expliziter,
prüfbarer Regel – ohne Host-Umbau, ohne Proxy-Betrieb.

Regression risk:
Mittel bei strikter Durchsetzung (spezielle Unterrichts-Workspaces
könnten Privilegien brauchen → separater Pool, siehe 02/F-002).
Die reine Dokumentationsstufe (Allowlist + Abnahme) hat kein
Regressionrisiko.

Test:
1. Aus normalem Workspace: `mount`, Socket-Pfade, Capabilities,
   Erreichbarkeit von `postgres:5432`/fremden Workspaces prüfen;
   dokumentieren (vgl. Validierungsvorschläge 02/F-002, F-004).
2. Bei jedem neuen Template: Checkliste gegen Allowlist abhaken.

Classification:
CONFIRMED (Socket-Fakt); ASSUMPTION (konkrete Template-Gefährlichkeit,
Templates nicht im Repo).

---

## F-006 – Firewall-Architektur ohne Durchsetzungspfad für Container-Ports

Severity:
HIGH

Category:
Security / Architektur (Netzwerk)

Location:
- UFW-Regeln ([setup-coder.sh](../setup-coder.sh#L409-L413)):
  `allow 80/tcp, 443/tcp, 443/udp`, `limit 22/tcp`
- Caddy-`ports:` ([setup-coder.sh](../setup-coder.sh#L207-L210))
- Selbstkommentar zur UFW-Umgehung durch Docker
  ([setup-coder.sh](../setup-coder.sh#L400-L408])

Problem:
Das Skript baut zwei Firewalls, von denen eine für Container-Ports nicht
zuständig ist: UFW regelt Host-Dienste (SSH – wirksam), Docker regelt
Container-Ports über eigene iptables-Ketten (UFW-wirkungslos, im Skript
selbst korrekt kommentiert, vgl. 03/F-012). Es gibt keine
`DOCKER-USER`-Policy, keine Bindungsregel (`127.0.0.1` vs. `0.0.0.0`) für
künftige Services und kein Modell für dynamische Workspace-Ports, die
Coder über den Socket publizieren kann (vgl. 02/F-008, F-009). Über
Jahre bedeutet das: Jeder später hinzugefügte `ports:`-Eintrag oder
Workspace-Port erscheint öffentlich, obwohl „die Firewall doch alles
regelt" – die UFW-Ausgabe suggeriert Schutz, wo keiner ist.

Evidence:
Keine `DOCKER-USER`-Regel, keine `daemon.json`-Bindungsvorgabe im
Skript; Monitoring-Ports sind korrekt an `127.0.0.1` gebunden
([setup-coder.sh](../setup-coder.sh#L233-L234), [setup-coder.sh](../setup-coder.sh#L255),
[setup-coder.sh](../setup-coder.sh#L269)), Caddy bewusst an `0.0.0.0` –
das Muster ist richtig, aber nirgends als Regel festgeschrieben.

Operational impact:
- Stille Exposition künftiger Dienste (nächstes Compose-Experiment,
  Debug-Port, Workspace-App mit eigenem `ports:`).
- UFW-Status als falscher Sicherheitsnachweis („alles erlaubt, was soll,
  blockiert den Rest" – stimmt für Docker-Ports nicht).

Proposed change:
Eine einzige, dokumentierte Bindungsregel plus eine `DOCKER-USER`-
Default-Deny-Überlegung als menschliche Entscheidung vorbereiten (siehe
Entscheidungen): Regel „Jeder neue `ports:`-Eintrag bindet an
`127.0.0.1`, außer Caddy-80/443; Ausnahme nur mit Caddy-Proxy davor".
Nutzen: Der nächste Dienst ist per Default nicht öffentlich, ohne dass
jemand iptables verstehen muss. `DOCKER-USER`-Kette erst nach
Dual-Stack-Test (vgl. 02/F-010) einführen.

Regression risk:
Mittel bei `DOCKER-USER` (Workspace-Apps/HTTP/3 können brechen – nur mit
externem Scan testen). Die Bindungsregel allein hat kein Risiko für den
Bestand (nur künftige Einträge betroffen).

Test:
1. Externer Scan (TCP 22/80/443/9090/9100/3001, UDP 443) + `ss -tlnp`
   auf dem Host + `iptables-save` inkl. `DOCKER-USER` vor/nach Änderung.
2. Jede neue `ports:`-Zeile in Review gegen Bindungsregel prüfen.

Classification:
CONFIRMED

---

## F-007 – Observability ohne Operation: Metriken ohne Konsument

Severity:
MEDIUM

Category:
Observability / Betrieb über mehrere Jahre

Location:
- `prometheus.yml` (nur 2 Scrape-Jobs, kein Alerting,
  [setup-coder.sh](../setup-coder.sh#L322-L334))
- Prometheus-Retention nur zeitbasiert (`15d`,
  [setup-coder.sh](../setup-coder.sh#L228)), keine Größenbegrenzung
- Grafana loopback-only ([setup-coder.sh](../setup-coder.sh#L268-L269)),
  Dashboards in `grafana_data` (nicht versioniert, nicht gesichert)
- node-exporter misst Platte, niemand wertet aus (vgl. 05/F-007, 05/F-016)

Problem:
Der Stack bezahlt die vollen Kosten von Monitoring (drei zusätzliche
Container, RAM ohne Limits, Platte für 15 Tage TSDB, Wartung von drei
Versions-Pins), liefert aber keine einzige operative Antwort: Kein
Alarm bei voller Platte, kein Alarm bei fehlgeschlagenem Backup, kein
Alarm bei Coder-Down, kein versioniertes Dashboard, das ein neuer
Kollege übernehmen könnte. node-exporter misst exakt die Größe, die bei
vollem Datenträger tötet (vgl. 03/F-004 Logging, 03/F-008 Retention),
aber die Kette Messung → Bewertung → Benachrichtigung existiert nicht.
Über Jahre verkommt das zu „Grafana ist da, schaut aber niemand rein".

Evidence:
`prometheus.yml` per Lesung: keine `alerting_rules`, kein Alertmanager;
kein `logrotate`, kein `MAILTO`, keine Frische-Prüfung im Skript (vgl.
05/F-007). Grafana-Dashboards existieren nur im Volume (vgl. 05/F-014).

Operational impact:
- Jeder schleichende Defekt (Platte voll, Backup fehlt seit Wochen,
  Cron tot) wird zum stillen Defekt mit maximaler Entdeckungsverzögerung.
- Monitoring-Kosten (RAM/Platte/Updates) ohne Monitoring-Nutzen.

Proposed change:
Nicht „mehr Monitoring" (Alertmanager wäre Überbau), sondern die
kleinste Kette mit Nutzen: ein `check.sh` (Cron, täglich nach Backup):
prüft Alter/Größe des neuesten gültigen Backups + `df` (>85 % → Warnung
per `logger` + Exit-Code ≠ 0) + `/healthz`-Status; schreibt eine Zeile
ins Backup-Log. Nutzen: Die drei häufigsten Todesursachen (kein Backup,
Platte voll, Coder down) werden erstmals überhaupt maschinell bemerkt –
ohne neuen Container, ohne Alertmanager, ohne Grafana-Pflicht. Echte
Alert-Regeln erst, wenn `check.sh`-Logs zeigen, welche Schwellwerte im
Schulbetrieb sinnvoll sind.

Regression risk:
Gering – nur lesende Prüfungen, kein Eingriff in den Stack.

Test:
1. Backup absichtlich fehlschlagen lassen (Container gestoppt) →
   `check.sh` muss Fehler signalisieren (nicht nur Log-Datei).
2. Platte per tmpfs simuliert füllen → Schwellwert-Warnung prüfen.

Classification:
CONFIRMED (Abwesenheit von Alerting per Lesung); LIKELY (Nutzen-Häufigkeit,
abhängig vom realen Störungsprofil).

---

## F-008 – Backup ist ein Dump, Recovery ist Improvisation

Severity:
CRITICAL

Category:
Recovery / Zustandsmanagement / Langzeitbetrieb

Location:
- `backup.sh` ([setup-coder.sh](../setup-coder.sh#L502-L515)): nur `pg_dump`
- Backup-Umfangslücke, Offsite-Lücke, Restore-Lücke, `.env`-Lücke,
  Workspace-Daten-Lücke (vollständig belegt in 05/F-001, F-002, F-008,
  F-009, F-015 – hier architektonisch eingeordnet)

Problem (Architektursicht):
Backup und Recovery sind im System als „Cronjob-Anhängsel" modelliert,
nicht als gleichberechtigte Lebenszyklus-Phase neben Setup/Update/Reset.
Die Folgen sind strukturell, nicht einzeln: (a) Sicherungsquelle und
-quell teilen sich das Fehlerszenario (selbe Platte, kein Offsite);
(b) das einzige Sicherungsobjekt (DB-Dump) ist ohne `.env` und ohne
Verfahren nicht einspielbar; (c) die wertvollsten Daten
(Workspace-Inhalte, Unterrichtsarbeiten) sind in keinem Modell enthalten;
(d) RPO/RTO sind undefiniert, also ist jede Störung eine Grundsatzdebatte
unter Druck. Dass der Dump rechte-sauber (`umask 077`, `600`) und mit
`pipefail` geschrieben wird, ist korrekt – aber es sichert die falsche
Vollständigkeit: technisch sauberer Dump eines unvollständigen Umfangs.

Evidence:
Verweis auf 05-Nachweise (Code-Lesung, grep-Abwesenheit von
`restore`/`offsite`/`rsync`, Cron-Zeile
[setup-coder.sh](../setup-coder.sh#L530-L534]); Antwort auf die
Wiederherstellungsfrage („frische VM aus Backups?") ist Nein (05,
„Entscheidende Frage").

Operational impact:
- Totalverlust (Platte/Host) = Totalverlust der Daten, trotz „täglichem
  Backup".
- Jede Recovery wird zur Improvisation mit unbekannter Dauer (RTO
  ungemessen) – im Schulbetrieb (Semesterende, Prüfung) maximal
  schmerzhaft.

Proposed change:
Drei Stufen mit jeweils eigenem Nutzen, keine als „alles auf einmal":
(1) Offsite-Kopie des Dumps (auch manuell dokumentiert + verifiziert –
Nutzen: Totalverlust wird erstmals überlebbar); (2) Restore-Runbook +
einmaliger Probelauf in Wegwerf-VM mit gemessener RTO (Nutzen: Dauer und
Verfahren sind bekannt, bevor sie gebraucht werden); (3) erst danach
Umfangs-Feinschliff (`.env` verschlüsselt, Config-Sicherung,
Workspace-Strategie als Verantwortungsentscheidung Git-Push-Pflicht vs.
Server-Backup). Reihenfolge beachten: (3) ohne (1)+(2) ist Dekoration.

Regression risk:
(1) mittel (Transport-Secrets exponierbar – getrennt vom lokalen Backup
einführen); (2) keins (nur Doku + Test-VM); (3) mittel (zusätzliche
Secret-Träger, Workspace-Backup berührt laufende Container).

Test:
Siehe 05/F-002, F-008, F-015: VM verwerfen, nur aus Offsite + Runbook
wiederherstellen, RTO stoppen, Workspace-Datei-Vorhandensein prüfen.

Classification:
CONFIRMED

---

## F-009 – Idempotenz als Behauptung, nicht als Eigenschaft

Severity:
HIGH

Category:
Idempotenz / Zustandsmanagement

Location:
- Idempotenz-Versprechen ([setup-coder.sh](../setup-coder.sh#L25-L26))
- `.env`-Existenzcheck ([setup-coder.sh](../setup-coder.sh#L134-L157];
  vgl. 01/F-002: keine Vollständigkeitsprüfung, kein atomares Schreiben)
- `DOCKER_GID`-Stale (vgl. 03/F-006: einmal geschrieben, nie aufgefrischt)
- Crontab-Migration unter `set -e`+`pipefail` (vgl. 01/F-001: Abbruch bei
  genau einer Alt-Zeile)
- Blinder `restart caddy` bei jedem Lauf ([setup-coder.sh](../setup-coder.sh#L352))

Problem:
Das Skript verspricht Mehrfachausführbarkeit, implementiert sie aber nur
für den Schönwetterpfad (alles gesund, alles vorhanden). Vier konkrete
Zweitlauf-Pfade sind gebrochen oder riskant: (a) halb geschriebene `.env`
wird als „konfiguriert" akzeptiert; (b) veraltete `DOCKER_GID` überlebt
jeden Re-Run (Docker-Neuinstallation, Hardwarewechsel); (c) die
Alt-Crontab-Migration beendet das Skript bei genau einem Treffer lautlos
(CRITICAL in 01/F-001); (d) jeder Re-Run startet Caddy neu (kurze
TLS-Unterbrechung), auch wenn sich die Caddyfile gar nicht geändert hat.
Für den Langzeitbetrieb („Skript nach DNS-Einrichtung einfach erneut
laufen lassen") ist das der falsche Vertrag: Der empfohlene Bedienweg
(Re-Run) ist gleichzeitig der am schlechtesten abgesicherte.

Evidence:
Zeilen- und Mechanik-Nachweise in 01/F-001 (reproduziert), 01/F-002,
03/F-006 per Lesung bestätigt.

Operational impact:
- Zweitlauf nach Unterbrechung (SSH-Abbruch, Reboot) kann Zustand
  verschlechtern statt heilen (kaputte `.env` wird permanent).
- Socket-Zugriffsverlust nach Docker-Neuinstallation ohne Fehlermeldung
  im Abschlusscheck (nur „Container läuft", kein Socket-Test).
- Empfohlener Re-Run nach DNS-Fertigstellung riskiert Abbruch mitten im
  Lauf (Crontab-Fall).

Proposed change:
Drei kleine Korrekturen mit jeweils direktem Zweitlauf-Nutzen (kein
Redesign): `.env`-Check auf Vollständigkeit (alle drei Schlüssel
nicht-leer) + atomares Schreiben (Nutzen: unterbrochener Erstlauf wird
beim Re-Run erkannt und neu erzeugt statt akzeptiert); `DOCKER_GID` bei
jedem Lauf auffrischen + bei Abweichung `coder` recreaten (Nutzen:
Socket-Zugriff überlebt Docker-Neuinstallation); Caddy nur bei
Caddyfile-Änderung neu starten (Hash-Vergleich, Nutzen: Re-Run ohne
TLS-Unterbrechung). Crontab-`|| true`-Fix aus 01/F-001 übernehmen.

Regression risk:
Gering je einzeln (nur Fehlerpfad-/Bedingungslogik). `DOCKER_GID`-
Auffrischung braucht Recreate, sonst wirkungslos – als Einheit testen.

Test:
1. `.env` halbiert in Test-VM → Re-Run muss neu erzeugen, nicht
   akzeptieren.
2. `groupmod -g` für `docker` in Test-VM → Re-Run muss Socket-Zugriff
   wiederherstellen.
3. Re-Run ohne Config-Änderung → kein Caddy-Restart
   (Container-Startzeit unverändert).

Classification:
CONFIRMED (Code-Fakte); LIKELY (Auslösungswahrscheinlichkeit der
einzelnen Pfade im realen Betrieb).

---

## F-010 – Neustart-Semantik: Compose-Reihenfolge gilt nur am CLI, Reboot kommt nachts um 03:00 ohne Gesundheitsprüfung

Severity:
HIGH

Category:
Architektur (Lifecycle) / Betrieb über mehrere Jahre

Location:
- `restart: unless-stopped` überall, `depends_on`-Bedingungen nur für
  CLI-`up` ([setup-coder.sh](../setup-coder.sh#L168-L273); vgl. 03/F-002,
  03/F-009)
- `52-coder-reboot`: `Automatic-Reboot-Time "03:00"`
  ([setup-coder.sh](../setup-coder.sh#L475-L479))
- Backup 01:00 ([setup-coder.sh](../setup-coder.sh#L530-L534)), kein
  Boot-Healthcheck, kein Alerting

Problem:
Drei Lifecycle-Annahmen greifen ineinander, ohne je gemeinsam gedacht zu
sein: (a) Nach Host-Reboot/Daemon-Neustart starten alle Container
gleichzeitig ohne Reihenfolge (Compose-`depends_on` wird vom Daemon
ignoriert – dokumentiertes Docker-Verhalten, 03/F-002); Coder kann vor
Postgres-Bereitschaft crash-loopen. (b) Genau dieser Reboot ist
automatisiert (Kernel-Update → 03:00-Reboot), also die wahrscheinlichste
Reboot-Ursache ist eingeplant, nicht zufällig. (c) Nach dem Reboot prüft
nichts, ob der Stack gesund zurückgekehrt ist – der Schritt-10-Check
läuft nur bei manuellem Setup-Lauf, nie nach automatischem Reboot. Das
System kann also nachts um 03:05 in einem selbstheilenden, aber
fehlerwerfenden (oder im schlechtesten Fall dauerhaft crash-loopenden)
Zustand stehen, und die erste Meldung kommt morgens von den Schülern.
Zusätzlich deckt `unattended-upgrades` das Docker-Fremdrepo nicht ab
(03/F-003): Der Reboot wird meist von Debian-Kernel-Updates ausgelöst,
während Docker-Engine-Sicherheitslücken manuell altern.

Evidence:
Docker-Restart-vs-`depends_on`-Verhalten (dokumentiert, 03/F-002);
Reboot-Config per Lesung; Abwesenheit eines Boot-Checks per Lesung
(Schritt 10 nur im Setup-Pfad).

Operational impact:
- Planmäßiger, aber unbeobachteter nächtlicher Reboot mit möglicher
  morgendlicher Unterrichtsstörung als Entdeckungsmechanismus.
- Docker-Engine altert sicherheitstechnisch unbemerkt (kritisch wegen
  F-005: Docker ist die Vertrauensschicht).

Proposed change:
Zwei Ergänzungen ohne Architekturwechsel: (a) `@reboot`- bzw.
systemd-`on-boot`-Health-Gate (Container gesund + `/healthz` 200 innert
N Minuten, sonst `logger`-Eintrag + lesbarer Status in
`/var/log/coder-boot.log`; Nutzen: morgendlicher Blick ins Log statt
Schülermeldung); (b) Docker-Repo-Entscheidung treffen (automatisch per
`Origins-Pattern` aufnehmen ODER bewusst manuell mit Kalendertermin –
Nutzen: kein dritter, vergessener Update-Pfad neben `update.sh` und
unattended-upgrades). Zusätzlich `stop_grace_period: 30s` für Postgres
(03/F-010) und auf Dauer Coder-Healthcheck für Caddy-`depends_on`
(03/F-009).

Regression risk:
(a) gering (nur lesend + Logging); (b) mittel bei Auto-Aufnahme
(Docker-Major kann Stack destabilisieren – in Test-VM mit
Reboot-Zyklus prüfen).

Test:
1. Test-VM-`reboot`, danach Boot-Log + `docker logs coder` (erste
   2 Minuten) auf Postgres-Verbindungsfehler und Selbstheilung prüfen.
2. `unattended-upgrade --debug --dry-run`: erscheint `docker-ce` als
   upgradebar oder „kept back" (je nach Entscheidung)?

Classification:
CONFIRMED (Restart-Verhalten, Reboot-Config); LIKELY (sichtbare Fehler
nach Reboot, timing-abhängig).

---

## F-011 – Drei Update-Zeiten, keine Koordination: 01:00 Backup, 03:00 Reboot, manuelles Update

Severity:
MEDIUM

Category:
Architektur (Zeit-/Koordination) / Wartbarkeit

Location:
- Backup-Cron 01:00 ([setup-coder.sh](../setup-coder.sh#L530-L534))
- Reboot 03:00 ([setup-coder.sh](../setup-coder.sh#L475-L479))
- `update.sh` manuell, mit Pre-Update-Backup ohne Lock
  ([setup-coder.sh](../setup-coder.sh#L561-L588]); Timestamp nur
  minutengenau ([setup-coder.sh](../setup-coder.sh#L507]; vgl. 05/F-004)
- Kein `flock`, Cron-Umgebung fragil (vgl. 05/F-006)

Problem:
Das System hat drei zeitgesteuerte Akteure, die sich gegenseitig nicht
kennen: Cron-Backup (01:00), unattended-Reboot (03:00), menschliches
Update (beliebig, mit eigenem Backup). Es gibt keinen Overlap-Schutz
(`flock`), keine minutenscharfe Eindeutigkeit (Timestamp ohne Sekunden),
keine Garantie, dass der Cron-Daemon überhaupt existiert (Paket weder
installiert noch geprüft, 05/F-006). Konkrete Kollision: Update um 01:00
vs. Cron-Backup um 01:00 schreiben in dieselbe Minutendatei (zweiter Lauf
trunkiert den ersten); Reboot um 03:00 während eines langen Dumps bricht
das Backup ab (partielle Datei unter gültigem Namen, vgl. 01/F-003).

Evidence:
Zeiten und fehlende `flock`/`cron`-Installation per Lesung bestätigt
(05/F-004, F-006). Timestamp-Format `%Y-%m-%d_%H%M` deterministisch.

Operational impact:
- Selten, aber exakt im falschen Moment: Das Backup, das ein Update
  absichern soll, ist das korrupte.
- Auf Minimal-Images läuft nie ein Backup, obwohl Setup „[OK]" meldete.

Proposed change:
`flock -n` in der Cron-Zeile + Sekunden im Timestamp + `cron`-Paket
installieren und im Abschlusscheck verifizieren. Nutzen: Die drei
Akteure können sich nicht mehr gegenseitig die Datei zerschneiden, und
„Backup läuft" wird von Behauptung zu geprüfter Tatsache. Kosten:
drei Zeilen, kein neues System (systemd-Timer wäre sauberer, aber ein
Wechsel des Schedulers ist für den Nutzen überdimensioniert).

Regression risk:
Gering – nur Namensgebung, Lock, Paketinstallation.

Test:
1. Zwei `backup.sh`-Läufe parallel in Test-VM: zweiter muss per `flock`
   sauber abbrechen statt zu trunkieren.
2. Frische Minimal-VM: `systemctl is-active cron` nach Setup muss aktiv
   sein.

Classification:
CONFIRMED (Zeiten, Format, fehlendes flock per Lesung); LIKELY
(Daemon-Abwesenheit auf konkretem Zielimage, vgl. 05/F-006).

---

## F-012 – SSH: weltweit offen, Passwort aktiv, Enforcement fehlt

Severity:
HIGH

Category:
Security / Architektur (Zugang)

Location:
- Kopfkommentar ([setup-coder.sh](../setup-coder.sh#L28-L34]): SSH „absichtlich
  für Zugriff von überall offen", Passwort-Login „aktuell noch aktiv"
- `ufw limit 22/tcp` ([setup-coder.sh](../setup-coder.sh#L375)),
  fail2ban-Jail ([setup-coder.sh](../setup-coder.sh#L384-L392])
- Abschlusscheck warnt nur ([setup-coder.sh](../setup-coder.sh#L440-L445],
  [setup-coder.sh](../setup-coder.sh#L832-L839])

Problem (Architektursicht):
Der Fernzugang ist die einzige Management-Ebene (kein VPN, kein
Bastion, kein Admin-Netz – Schulnetz muss 22 zusätzlich weiterleiten).
Das Skript sichert ihn mit zwei Dämpfungsschichten (ufw-Rate-Limit,
fail2ban), lässt aber die Authentisierungsebene (Passwort +
KbdInteractive aktiv) als dauerhaften, nur gewarnten Zwischenzustand zu.
Architektonisch heißt das: Der unsicherste zulässige Zustand ist der
stabile Dauerzustand – es gibt keinen Pfad im System, der ihn beendet
(kein Skript, kein Check mit Fehler, kein Runbook-Schritt „Key
verifizieren, dann Enforcement"). Über Jahre (Lehrerwechsel,
Passwort-Weitergabe, vergessene Warnung) normalisiert sich der
Provisoriums-Zustand zum Produktions-Zustand. Rate-Limit und fail2ban
begrenzen Raten, nicht verteilte Angriffe und nicht kompromittierte
Passwörter (vgl. 02/F-007).

Evidence:
Kein `sshd_config`-Eingriff im Skript, nur Warnung; Exit-Code bleibt 0
bei aktiver Passwort-Auth (Setup meldet Erfolg). Kommentar kündigt
Enforcement als künftiges „Bescheid geben" an – ohne Eigentümer und
ohne Frist.

Operational impact:
- Kompromittiertes/erratenes SSH-Passwort = Host = Docker-Admin = alle
  Secrets, Backups, DB (Kette in 02, „Critical Attack Paths" Nr. 1).
- Jede Verzögerung („Key kommt nächste Woche") verlängert das Fenster
  ohne sichtbaren Druck, weil Setup grün meldet.

Proposed change:
Kein sofortiges Abschalten (Aussperrungsgefahr – menschliche
Entscheidung, siehe unten). Architektonisch fällig: ein
`ssh-harden.sh`-Pfad im Repo (setzt `PasswordAuthentication no` +
`KbdInteractiveAuthentication no` + `PermitRootLogin no`, mit
`sshd -t`-Check und dokumentierter Zweit-Zugangs-Voraussetzung), der
heute vorbereitet und nach Key-Abnahme genau einmal läuft. Nutzen: Das
Provisorium bekommt einen definierten Ausgang statt einer ewigen
Warnung; der Eingriff ist reversibel dokumentiert statt improvisiert.

Regression risk:
Hoch bei falscher Ausführung (Aussperrung) – deshalb als separater,
bestätigter Schritt mit Zweit-Zugang und `sshd -t`, nie als stiller
Setup-Nebeneffekt.

Test:
1. `sshd -T | grep -i passwordauthentication` vor/nach in Test-VM.
2. Externer Passwort-Loginversuch muss scheitern, Key-Login gelingen;
   fail2ban-Ban-Verhalten separat prüfen.

Classification:
LIKELY (Passwort-Status per `sshd -T`-Logik im Skript; tatsächlicher
Zielhost-Status nicht live geprüft).

---

## F-013 – Secrets: eine Datei, viele Leser, keine Rotation ohne Fenster

Severity:
HIGH

Category:
Security / Zustandsmanagement

Location:
- `/opt/coder/.env` (`600 root:root`, [setup-coder.sh](../setup-coder.sh#L141-L147))
- Terminal-Ausgabe der Klartext-Passwörter (Schritt 2,
  `reset-passwords.sh` [setup-coder.sh](../setup-coder.sh#L671-L676])
- `CODER_PG_CONNECTION_URL` mit Klartext-Passwort als Container-Env
  ([setup-coder.sh](../setup-coder.sh#L193]); `GF_SECURITY_ADMIN_PASSWORD`
  ([setup-coder.sh](../setup-coder.sh#L263])
- `reset-passwords.sh`-Reihenfolge (DB zuerst, `.env` danach;
  vgl. 01/F-005, 05/F-017)

Problem:
Das Secrets-Modell ist „eine Datei + Hoffnung": `.env` ist korrekt
geschützt (`600`), aber die Secrets leben zusätzlich in Terminal-Output,
`docker inspect`-sichtbarem Container-Environment, Shell-History-Risiko
und (ungewollt) in Backups/Logs. Rotation (`reset-passwords.sh`) ist
nicht transaktional: DB-Passwort zuerst, `.env` danach – Abbruch
dazwischen hinterlässt einen verzögert zündenden Lockout (nächster
Reboot/Update startet Coder mit falschem Passwort, vgl. 01/F-005).
Für einen Schulserver mit wechselnden Admins und Jahren Laufzeit ist das
das klassische Muster „Passwort kennt niemand mehr / steht im alten
Ticket / wurde nie rotiert".

Evidence:
Ausgabe- und Env-Zeilen per Lesung; Reihenfolge in
`reset-passwords.sh` per Lesung (02/F-015, 05/F-017 bestätigen
Secret-Fläche und Transaktionalitätslücke).

Operational impact:
- Jede Offenlegung (Ticket, Log, Screenshot) erfordert Rotation – die
  selbst riskant ist (Inkonsistenzfenster).
- `.env`-Verlust = DB-Passwort-Verlust (kein Backup, vgl. 05/F-009);
  Recovery wird zum Rate-Puzzle.

Proposed change:
Kein Secret-Store (Überbau für einen Schulserver – nur Kosmetik mit
Betriebsrisiko bei Neustart-Verfügbarkeit). Stattdessen: (a) keine
Klartext-Ausgabe mehr nach Erstlauf (nur beim Erzeugen, mit Hinweis auf
Rotation statt Kopie); (b) `.env`-Sicherung als verschlüsselter
Offsite-Bestandteil (vgl. F-008 (3)); (c) Rotation transaktional machen
(`.env`-Kopie + atomarer Tausch, Backup vorher, Trap mit Warnung bei
Abbruch – vgl. 01/F-005-Vorschlag). Nutzen: Weniger Exemplare, sichere
Rotation, kein Lockout nach SSH-Abbruch – ohne neue Infrastruktur.

Regression risk:
Gering bei (a)/(c) (nur Ausgabe/Reihenfolge); mittel bei (b)
(Schlüsselverlust = Datenverlust – Schlüssel getrennt vom Host
verwahren).

Test:
1. `docker inspect coder | grep -i password`, Shell-History und
   `journalctl` auf Secret-Muster prüfen (vgl. 02/F-015-Validierung).
2. Rotations-Abbruchtest mit Verzögerung vor `sed` in Test-VM (vgl.
   01/F-005-Test).

Classification:
CONFIRMED (Ausgabe, Env, Reihenfolge per Lesung).

---

## F-014 – Destruktive Pfade ohne Leitplanken: Reset und Update vertrauen auf Aufmerksamkeit

Severity:
HIGH

Category:
Recovery / Betriebssicherheit

Location:
- `reset-coder.sh` ([setup-coder.sh](../setup-coder.sh#L689-L768]):
  `down` → Volume-`rm` → `rm -f .env`; Workspace-Hinweis erst am Ende
  ([setup-coder.sh](../setup-coder.sh#L762-L766]); `--force` nach
  Backup-Fehlschlag ([setup-coder.sh](../setup-coder.sh#L730-L738])
- `update.sh` ohne Gate (siehe F-004)

Problem:
Die beiden gefährlichsten Befehle des Systems sind auf menschliche
Aufmerksamkeit im richtigen Moment angewiesen: Reset filtert Volumes per
Rate-Label (Fremdtreffer möglich, Mehrfachtreffer = Abbruch nach
Teil-Löschung, vgl. 05/F-011), verlangt die unwiderrufliche Bestätigung
*vor* dem Backup (vgl. 05/F-012) und warnt vor verwaisten
Workspace-Containern erst *nach* der Zerstörung (vgl. 05/F-013). Update
prüft weder Backup-Gültigkeit noch Ergebnis. Das funktioniert, solange
der eine erfahrene Admin alles weiß – und scheitert beim ersten
Vertretungsfall, bei Müdigkeit oder nach zwei Jahren ohne Reset-Übung.

Evidence:
Ablauf per Lesung bestätigt (05/F-011 bis F-013 mit Mechanik-Reproduktion
in 01/F-004).

Operational impact:
- Halb durchgeführter Reset (Abbruch nach Teil-Löschung) ohne definierten
  Folgezustand.
- `--force`-Reset nach Backup-Fehlschlag auf vorher erteilter Bestätigung:
  bewusster, aber uninformierter Datenverlust.
- Verwaiste Workspace-Container nach Neuaufbau (Port-/Namenskonflikte,
  entkoppelte Nutzerdaten).

Proposed change:
Vier Leitplanken ohne Funktionsänderung: Projekt-scharfer Volume-Filter
(`project=coder`) + Anzeige der Löschmenge vor `rm` (Nutzen: kein
Fremdtreffer, kein Blindflug); Bestätigung *nach* erfolgreichem Backup
bzw. Zweitbestätigung bei `--force` mit Backup-Alter/Größe (Nutzen: die
Bestätigung bezieht sich auf Fakten statt auf Hoffnung);
Workspace-Inventar (`docker ps`) *vor* der Löschung (Nutzen: keine
verwaisten Container nach Neuaufbau). Nutzen jeweils: Der Befehl wird
auch um 23 Uhr von der Vertretung sicher ausführbar.

Regression risk:
Gering – nur Filter-Schärfung, Dialog-Reihenfolge, lesende Inventur.

Test:
1. Fremd-Volume mit gleichem `volume`-Label, anderem `project`-Label in
   Test-VM → Reset-Trockenlauf darf es nicht anzeigen/löschen.
2. Backup-Fehlschlag simulieren → ohne `--force` Abbruch ohne Löschung,
   mit `--force` Zweitbestätigung mit Backup-Status.

Classification:
CONFIRMED (Ablauf per Lesung; Quoting-Mechanik reproduziert in 01/F-004).

---

## F-015 – Nicht testbar ohne Produktion: `tests/` ist leer, jede Prüfung braucht den Zielhost

Severity:
MEDIUM

Category:
Testbarkeit / Wartbarkeit

Location:
- `tests/` (leer, Repo-Lesung)
- Validierungspräferenzen in [AGENTS.md](../AGENTS.md) (ShellCheck,
  Compose-Validierung, isolierte VM, Idempotenz-, Restore-Tests)
- Einzige eingebaute Validierung: `compose config --quiet`
  ([setup-coder.sh](../setup-coder.sh#L344]) + Schritt-10-Checks

Problem:
Jede Architekturänderung (Firewall, Compose, Backup, Update) ist heute
nur auf dem Produktionshost verifizierbar – genau dort, wo laut AGENTS.md
nie destruktiv getestet werden darf. Es gibt keine einzige
automatiserte Prüfung im Repo (kein ShellCheck-Gate, keine
Compose-Validierung, kein Heredoc-Extraktions-Test, kein
Rotations-Test). Die Schritt-10-Checks sind Laufzeit-Checks auf dem
Zielhost, keine vorab lauffähigen Tests. Über Jahre heißt das: Änderungen
werden seltener (Angst) oder mutiger (Hoffnung) – beides schlecht.

Evidence:
Leeres `tests/`-Verzeichnis per Lesung; AGENTS.md-Testpräferenzen ohne
eine einzige Umsetzung im Repo.

Operational impact:
- Jede der in 01–05 vorgeschlagenen Korrekturen ist ohne Testharnisch
  nur „wahrscheinlich richtig".
- Regressionen (z. B. Escaping-Fehler nach F-003-Migration) fallen erst
  auf dem Produktionshost auf.

Proposed change:
Die kleinste Testschicht mit Nutzen, ohne VM-Pflicht: (1) `shellcheck`
über `setup-coder.sh` + extrahierte Heredoc-Skripte (fängt 01/F-006-
Klasse dauerhaft); (2) `docker compose config` gegen generierte/geplante
Compose-Datei (fängt YAML-/Interpolationsfehler vor dem Host);
(3) Rotations- und Timestamp-Test gegen Testverzeichnis (fängt
05/F-004/F-005); (4) dokumentierter manueller VM-Protokoll-Check für
Reboot/Restore (kein Automatikzwang). Nutzen: Die häufigsten
Fehlerklassen werden vor dem Produktionshost gefangen; VM-Tests bleiben
für die seltenen, gefährlichen Fälle (Reboot, Restore, Reset) reserviert.

Regression risk:
Keins – nur prüfende Hülle, kein Verhaltenswechsel.

Test (Meta):
Selbsttest des Harnischs: absichtlich fehlerhafte Compose-Zeile und
`SC2034`-Analogon einführen → CI/Testlauf muss rot werden.

Classification:
CONFIRMED (leeres `tests/`, Check-Abwesenheit per Lesung).

---

## F-016 – Langzeit-Degradation: Platte, RAM und Zertifikate haben kein Sicherheitsnetz

Severity:
MEDIUM

Category:
Betrieb über mehrere Jahre / Kapazität

Location:
- Kein `logging`-Block in Compose (vgl. 03/F-004: `json-file` unbegrenzt)
- Keine `mem_limit` (vgl. 03/F-005)
- Prometheus nur `retention.time=15d`, keine `retention.size`
  (vgl. 03/F-008)
- Caddy-Zertifikate in `caddy_data` (persistent, aber ungesichert;
  vgl. 05/F-014); On-Demand-Erstaufruf 5–30 s
  ([setup-coder.sh](../setup-coder.sh#L14-L20]); LE-Limit 50/Woche pro
  registrierter Domain (geteilt mit anderen Schuldiensten, vgl. 04/F-007)
- Keine `logrotate` für `/var/log/coder-backup.log` (vgl. 05/F-007)

Problem:
Das System ist für den Erstbetrieb dimensioniert, nicht für den
Dauerbetrieb: Logs wachsen unbegrenzt (der wahrscheinlichste
Plattenkiller), RAM ist unbegrenzt belegbar (OOM-Killer trifft ggf.
Postgres), TSDB-Wachstum ist nur zeit-, nicht größenbegrenzt, Backup-Logs
rotieren nie. Nach Totalausfall müssen alle Workspace-Zertifikate neu
ausgestellt werden (Voraussetzungen: DNS + Portweiterleitung + LE-Budget
der *gesamten* Domain `ghse-unterricht.de`, nicht nur des Coder-Servers).
Keiner dieser Punkte tötet am ersten Tag – jeder tötet im dritten Jahr.

Evidence:
Abwesenheit von `logging:`/`mem_limit`/`retention.size`/`logrotate` per
Lesung (03/F-004, F-005, F-008; 05/F-007); LE-Limit-Semantik per
Upstream-Doku verifiziert (04/F-007).

Operational impact:
- Voller Datenträger als schleichender Totalausfall (Postgres-Schreibfehler,
  Backup-Fehlschlag, APT-Blockade gleichzeitig – vgl. 03/F-004).
- OOM-Kill von Postgres mit WAL-Replay-Ausfallzeit statt gradueller
  Degradation.
- Zertifikats-RTO nach Neuaufbau ungemessen (jede Workspace-Subdomain
  5–30 s + LE-Budget-Risiko).

Proposed change:
Vier Zeilen-Klasse statt Kapazitätsplanung: `logging: {max-size: 10m,
max-file: 3}` pro Service (Nutzen: Plattenkiller Nr. 1 entfällt);
`retention.size` zusätzlich zu `retention.time` (Nutzen: TSDB mit harter
Obergrenze); `logrotate` für `coder-backup.log` (Nutzen: kein
mitwachsendes Root-Log); konservative `mem_limit` erst nach
`docker stats`-Beobachtung über eine Schulwoche (Nutzen: OOM trifft nicht
mehr die DB zuerst). Zertifikats-RTO einmal in Test-VM messen (Nutzen:
bekannte Wiederanlaufdauer statt Überraschung).

Regression risk:
Gering (Log-Rotation verliert alte Historie – sicherer als volle Platte);
`mem_limit` nur mit Puffer nach Messung, sonst Exit-137-Risiko (03/F-005).

Test:
1. `docker inspect --format '{{json .HostConfig.LogConfig}}'` nach
   Einführung; künstlicher Log-Flut-Test mit Rotationsnachweis.
2. Test-Neuaufbau: Zeit bis `/healthz` 200 + Zeit bis N
   Workspace-Subdomains Zertifikate haben (Zertifikats-RTO).

Classification:
CONFIRMED (Abwesenheit per Lesung); LIKELY (Eintrittszeitpunkt und
OOM-Opfer, lastabhängig).

---

## F-017 – TLS-Bequemlichkeit mit DoS-Preis: On-Demand ohne Autorisierung

Severity:
HIGH

Category:
Security / Architektur (TLS)

Location:
- `Caddyfile`: `on_demand_tls { ask http://example.com }` +
  `${DOMAIN_CODER}, *.${DOMAIN_CODER} { tls { on_demand … } }`
  ([setup-coder.sh](../setup-coder.sh#L304-L320))
- Kopfkommentar ([setup-coder.sh](../setup-coder.sh#L14-L20],
  [setup-coder.sh](../setup-coder.sh#L286-L294]) – offizielles
  Coder-Tutorial-Muster, keine Repo-Fehlkonfiguration
- LE-Limit-Hinweis ([setup-coder.sh](../setup-coder.sh#L17-L20];
  Präzisierung in 04/F-007: registrierte Domain = `ghse-unterricht.de`)

Problem (Architektursicht):
Die TLS-Architektur tauschtBetriebsbequemlichkeit (kein DNS-API-Token
nötig) gegen eine offene Zertifikatsausstellung: Jeder Internet-Teilnehmer
kann per SNI mit beliebigem `*.DOMAIN`-Namen ein echtes LE-Zertifikat
auslösen, weil `ask` immer 200 antwortet (vgl. 04/F-001, 02/F-011).
Das Wochenbudget (50 pro registrierter Domain, geteilt mit allen anderen
Schuldiensten unter `ghse-unterricht.de`) ist damit von außen
verzehrbar – mit der Folge, dass legitime neue Workspace-Apps in derselben
Woche kein Zertifikat mehr bekommen (TLS-Fehler im Unterricht). Zusätzlich
gilt On-Demand auch für die Root-Domain selbst (vgl. 04/F-006), und jeder
Erst-Handshake hängt an der Erreichbarkeit von `example.com` (vgl.
04/F-003).

Evidence:
Caddy-Doku (`ask` als Missbrauchsschutz-Voraussetzung für Produktion) +
Tutorial-Wortlaut + LE-Rate-Limits (Stand 26.09.2026), verifiziert in 04.

Operational impact:
- Realistischer DoS-Vektor gegen die Zertifikatsversorgung neuer
  Workspace-Apps, ohne Coder-Account auslösbar.
- Geteiltes Domain-Budget verschärft den Schaden über den Coder-Server
  hinaus (andere Schuldienste derselben Domain).

Proposed change:
Keine Sofort-Umstellung (braucht DNS-Provider-Entscheidung, siehe unten).
Architektonisch fällig: (a) Kommentar präzisieren (Root-Domain ebenfalls
on-demand; Budget gehört der registrierten Domain – Nutzen: kein
Operator unterschätzt das Risiko mehr, vgl. 04/F-006, F-007);
(b) `CODER_DISABLE_PATH_APPS=true` setzen (vgl. 04/F-002 – Nutzen:
Workspace-Apps teilen nicht mehr den Coder-API-Origin; Voraussetzung
Wildcard ist bereits erfüllt); (c) DNS-01-Wildcard vs. echter
`ask`-Endpoint als vorbereitete menschliche Entscheidung (siehe
Entscheidungen). (b) ist sofort und unabhängig vom TLS-Modell richtig.

Regression risk:
(a) keins (Kommentar); (b) mittel falls Templates Pfad-Apps ohne
`subdomain = true` nutzen → vorher Template-Inventar prüfen (04/F-002-Test);
(c) mittel (eigener `ask`-Endpoint mit veralteten Daten blockiert neue Apps;
DNS-01 braucht Provider-Token + eigenen Caddy-Build).

Test:
1. Test-Domain: TLS-Handshakes für erfundene Subdomains → `caddy`-Log
   muss `obtaining certificate` zeigen (Ist-Zustand); nach `ask`-Fix muss
   der Handshake abgewiesen werden (vgl. 04/F-001-Test).
2. Pfad-App-Test nach (b): Pfad-URL abgelehnt, Subdomain-URL funktioniert.

Classification:
CONFIRMED (Mechanik, Doku-Stand).

---

## Beantwortung der zehn Architekturfragen

### 1. Welche Aufgaben gehören in `setup-coder.sh`?

Erstprovisionierung und Konvergenz des *stateless* Anteils: Docker-Repo
und -Pakete (Schritt 1), Generierung der drei Konfigurationen
(Schritt 2, künftig aus Templates – F-003), Stack-Start mit Validierung
(Schritt 3), Abschluss-Healthcheck (Schritt 10). Dazu ein schlanker
`--converge`-Modus für Config-/Skript-Aktualisierung ohne Paket- und
Firewall-Seiteneffekte (F-001). Alles, was Zustand bewertet (Backup-Gültigkeit),
Zustand vernichtet (Reset) oder Rotation berührt (Passwörter), gehört
nicht in den Setup-Pfad, sondern in eigene, einzeln aufrufbare Skripte
mit eigenen Guards.

### 2. Welche Aufgaben gehören in Wartungsskripte?

In je ein Skript mit genau einem Auftrag und eigenem Gate:
`backup.sh` (Dump + atomares Schreiben + `gzip -t` + Größenprüfung;
vgl. 01/F-003, 05/F-003), `check.sh` (neu: Backup-Frische, `df`,
`/healthz` – F-007, F-010), `update-app.sh` vs. `update-db.sh` (getrennte
Risiko-Klassen mit Health-Gate – F-004), `reset-passwords.sh`
(transaktional mit Vorab-Backup – F-013), `reset-coder.sh` (projekt-scharf,
Bestätigung nach Backup, Workspace-Inventar vorher – F-014),
`ssh-harden.sh` (vorbereitet, einmalig nach Key-Abnahme – F-012).
Gemeinsame Regel: Jedes destruktive Skript zeigt vorher, was es
vernichten wird, und verweigert den Lauf bei fehlender Sicherung ohne
informierte Zweitbestätigung.

### 3. Welche Konfiguration sollte separat sein?

Die drei laufzeitwirksamen Dateien als versionierte Templates im Repo
(`docker-compose.yml.tmpl`, `Caddyfile.tmpl`, `prometheus.yml` – F-003);
die Template-Allowlist für Coder-Workspaces (`templates/allowlist.md` –
F-005); das Zustandsinventar (`STATE_*` am Skriptkopf – F-002);
Umgebungs-/Domain-Werte weiter per Env-Override, aber mit
Format-Sanity-Check (vgl. 01/F-009). Host-Config (`jail.local`,
`52-coder-reboot`, Cron-Datei) bleibt generiert, wird aber ins Inventar
aufgenommen, damit Drift sichtbar wird.

### 4. Welche Teile sollten automatisiert getestet werden?

Alles, was ohne Zielhost prüfbar ist, sofort (F-015): ShellCheck über
Haupt- und Heredoc-Skripte, `docker compose config` gegen Repo-Templates,
Rotations-/Timestamp-Logik gegen Testverzeichnis, Generierungsvergleich
byte-identisch nach F-003-Migration. Auf Test-VM (manuell protokolliert,
nicht zwingend automatisiert): Reboot-Verhalten (F-010), Restore mit
gemessener RTO (F-008), Reset gegen Fremd-Volumes (F-014),
Update-Health-Gate mit falscher Version (F-004), Socket-/Netzwerk-Isolation
aus Workspace-Sicht (F-005). Regel: Was den Host zerstören kann, wird nie
automatisch gegen Produktion getestet (AGENTS.md-Produktionsschutz).

### 5. Welche Teile sind zu stark gekoppelt?

(a) Coder ↔ Host via Docker-Socket (F-005: Anwendungsfehler wird
Host-Takeover); (b) Update-Pfad: DB-Image und App-Images in einem Befehl
(F-004); (c) Setup-Rollen: Provisionierung, Konvergenz und
Skriptgenerierung in einer linearen Sequenz (F-001); (d) UFW-Annahme ↔
Docker-Realität: deklarierte Grenze ohne Durchsetzungspfad (F-006);
(e) Backup ↔ Platte: Quelle und Sicherung teilen sich das
Fehlerszenario (F-008); (f) Secrets: ein Wert in `.env`, Env, Logs,
Terminal und Backups gleichzeitig (F-013). Entkopplung jeweils nur dort,
wo der betriebliche Nutzen (Überlebbarkeit, isoliertes Update,
prüfbarer Reset) die Kosten übersteigt – keine Entkopplung um der Form willen.

### 6. Welche Annahmen sind derzeit implizit?

DNS + Portweiterleitung stehen (nur gewarnt, Schritt 10); lokale
Namensauflösung ≈ öffentliche (vgl. Schritt-10-Kommentar
[setup-coder.sh](../setup-coder.sh#L788-L795]); Docker-`trixie`-Repo
verfügbar (verifiziert in 03/F-011, aber extern veränderlich);
`postgres:15-alpine`-`pg_hba`-Trust für `pg_dump` ohne Passwort (vgl.
05/F-018); Coder-Retries bei Postgres-Noch-nicht-bereit nach Reboot
(unbestätigt, vgl. 03/F-002); `example.com` erreichbar für jeden
Erst-Handshake (vgl. 04/F-003); Cron-Daemon existiert (nicht installiert/
geprüft, vgl. 05/F-006); `DOCKER_GID` stabil über Jahre (vgl. 03/F-006);
LE-Budget der Domain ungenutzt durch Dritte (vgl. 04/F-007);
Templates harmlos (nicht im Repo, vgl. F-005); Platte/RAM wachsen nie zu
(vgl. F-016). Jede dieser Annahmen ist ein Wartungsrisiko genau dann,
wenn sie unbemerkt falsch wird – deshalb gehören die billigen davon in
Checks (`check.sh`, Boot-Gate, Cron-Verifikation).

### 7. Welche Teile sind nicht wirklich idempotent?

`.env`-Erzeugung (Existenz statt Vollständigkeit, nicht atomar –
01/F-002); `DOCKER_GID`-Persistenz (stale nach Docker-Neuinstallation –
03/F-006); Crontab-Migration (Abbruch bei genau einer Alt-Zeile –
01/F-001, CRITICAL); `restart caddy` bei jedem Lauf (Unterbrechung ohne
Änderung); `docker compose up -d` nach Domain-Wechsel ohne Garantie, dass
Caddy die neue Datei übernimmt (deshalb der blinde Restart –
Kommentar [setup-coder.sh](../setup-coder.sh#L348-L352]); Rotation per
Alter statt Stückzahl (Kommentar verspricht 14 Backups – 05/F-005);
Passwort-Rotation (nicht wiederholbar nach Abbruch – 01/F-005).
Idempotent im engeren Sinn sind Paketinstallation, ufw-Regelsetzung
(mit Bereinigung) und die Cron-Datei (reines Überschreiben).

### 8. Welche Änderungen reduzieren das Risiko am stärksten?

In Wirkungsreihenfolge (siehe „Top Priorities"): Offsite-Kopie +
Restore-Runbook mit Probelauf (F-008 – verwandelt Totalverlust von
sicher in überlebbar); Template-Allowlist + Abnahmeprozess (F-005 –
schließt die größte Privilegienlücke ohne Host-Umbau);
`CODER_DISABLE_PATH_APPS=true` nach Template-Inventar (F-017(b), 04/F-002 –
eine Zeile gegen Cookie-Missbrauch über Path-Apps); Logging-Limits +
`retention.size` + `logrotate` (F-016 – beseitigt den wahrscheinlichsten
schleichenden Totalausfall); Update-Trennung app/db mit Health-Gate
(F-004 – macht Patches einspielbar statt aufschiebbar); `check.sh` +
Boot-Gate (F-007, F-010 – beendet die Ära stiller Defekte);
SSH-Härtungspfad vorbereiten und nach Key-Abnahme ausführen (F-012);
Idempotenz-Fixes (F-009 – macht den empfohlenen Re-Run sicher).

### 9. Welche Änderungen wären nur kosmetisch?

ShellCheck-Stil (`SC2034`-Variable, `ls` vs. `find`, fehlender
End-Newline – 01/F-006); mehrfache `ufw status`-Aufrufe zu einer
Auswertung zusammenfassen (01/F-008); Kommentarpräzisierungen ohne
Verhaltensänderung (On-Demand-Geltung Root-Domain 04/F-006, LE-Budget-
Ebene 04/F-007, Update-Prune-Kommentar 03/F-001 als reine
Kommentarkorrektur); `stop_grace_period: 30s` (03/F-010 – korrekt, aber
bei kleiner Schul-DB selten wirksam); CAA-Empfehlung (04/F-004 –
Defense in Depth ohne Bezug zur aktuellen Bedrohungslage);
`pid: host`-Entfernung ohne `processes`-Collector (03/F-007 – richtige
Hygiene, aber kein akuter Schaden, da Mounts ohnehin lesend bestehen
bleiben); Format-Validierung von Domain/E-Mail (01/F-009 – frühere
Fehlermeldung statt neuer Sicherheit). Wichtig: Kosmetisch heißt nicht
wertlos – Stilfixes senken Review-Aufwand –, aber keines davon verhindert
einen Ausfall oder Datenverlust.

### 10. Welche Architekturentscheidungen müssen vom Menschen getroffen werden?

Siehe „Decisions Requiring Human Approval" – zusammengefasst: (D1)
Docker-Provisioner-Modell (Single-Host mit Socket vs. separater
Provisioning-Host vs. Socket-Proxy); (D2) TLS-Modell (On-Demand mit
echtem `ask` vs. DNS-01-Wildcard mit Provider-Token); (D3) SSH-Modell
(Key-only-Termin, Admin-Netz/VPN ja/nein); (D4) Update-Modell für die
Docker-Engine (automatisch via `Origins-Pattern` vs. manueller
Kalendertermin); (D5) Workspace-Daten-Verantwortung (Server-Backup vs.
Git-Push-Pflicht, RPO); (D6) Backup-Offsite-Ziel und Schlüsselverwahrung
(wohin, verschlüsselt womit, wer hält den Schlüssel); (D7) Monitoring-
Ambition (minimales `check.sh` vs. volles Alerting); (D8) Ressourcen-
Limits (konkrete `mem_limit`-Werte nach Messung); (D9) Firewall-Modell
(`DOCKER-USER`-Default-Deny vs. Bindungsregel-Disziplin);
(D10) RPO/RTO-Ziele und Reset-Ermächtigung (wer darf `--force`, mit
welcher Freigabe). Keine dieser Entscheidungen kann das Review abnehmen –
sie legen Kosten, Verantwortung und Risiko für Jahre fest.

---

## Architectural Strengths

- **Referenzarchitektur statt Eigenbau.** Coder + Postgres +
  Caddy-TLS-Terminierung folgt exakt dem offiziellen Coder-Caddy-Tutorial
  (04, „Architecture Summary"): Access-URL, Wildcard-URL, `reverse_proxy`
  ohne Host-Umschreibung (`CODER_PROXY_TRUSTED_ORIGINS` korrekt nicht
  gesetzt, 04/F-005), `/healthz` als dokumentierter Health-Endpoint.
  Kein Framework-, kein Proxy-, kein Auth-Eigenbau.
- **Erreichbarkeitsmodell für Monitoring richtig gewählt.**
  Prometheus/Grafana/node-exporter an `127.0.0.1`, Grafana nur per
  SSH-Tunnel – kein öffentlicher Monitoring-Zugang (02/F-005,
  03-Bestätigung). Die Bindungsdisziplin ist das richtige Muster, sie muss
  nur zur Regel werden (F-006).
- **Postgres-Abhängigkeit sauber modelliert – am CLI.** Healthcheck +
  `condition: service_healthy` für `coder → postgres` (03, „Operational
  Summary") ist die korrekte Compose-Modellierung; `compose config
  --quiet` vor `up -d` fängt Syntax-/Interpolationsfehler früh.
- **Sicherheitsdetails an den richtigen Stellen korrekt.**
  `umask 077`/`700`/`600` für Backups und `.env`; Passwortübergabe per
  STDIN statt `ps`-sichtbarer CLI-Argumente (01, „korrekt gelöst");
  `backend=systemd` für fail2ban statt brüchigem `auto`; eigene
  `52-coder-reboot`-Datei statt dpkg-verwaltetem Config-Konflikt;
  `/etc/cron.d`-Datei statt Crontab-Parsen (01-Bestätigungen).
- **Destruktivschutz-Ansätze vorhanden.** `RESET`-Bestätigung,
  Sicherungsbackup vor Reset mit Abbruch ohne `--force`,
  Zertifikats-/Backup-Verschonung beim Reset (Rate-Limit-Schutz),
  `prune -f` statt `-a` (Rollback-Absicht, auch wenn unvollständig –
  03/F-001). Die Ansätze sind richtig, sie brauchen Leitplanken (F-014).
- **Betriebsrealismus in Kommentaren.** UFW/Docker-Umgehung,
  On-Demand-Verzögerung, manuelle Updates, Passwort-Provisorium und
  Wildcard-DNS-Voraussetzungen sind ehrlich dokumentiert statt
  verschwiegen. Das ist die beste Ausgangslage für Härtung: Die Lücken
  sind benannt, nicht versteckt.
- **Richtige Default-Pins für einen Schulserver.** Exakte Pins für
  Coder/Prometheus/Grafana (Reproduzierbarkeit), bewegliche Pins für
  Caddy/Postgres (Sicherheitsfixes) – die Abwägung ist bewusst und
  kommentiert. Nur die Rollback-Folgerung daraus ist zu korrigieren
  (03/F-001, F-004).

## Architectural Weaknesses

- **Steuerungsebene = Host-Privileg (F-005).** Docker-Socket im
  Coder-Container macht jede Coder-/Template-Schwäche zum Host-Takeover.
  Keine Policy-Schicht, keine Template-Allowlist, Workspaces außerhalb
  jeder sichtbaren Netzwerk-/Mount-Policy.
- **Recovery existiert nicht als Phase (F-008).** Ein lokaler,
  ungeprüfter DB-Dump ohne Offsite, ohne Verfahren, ohne `.env`, ohne
  Workspace-Daten, ohne RPO/RTO. Die Wiederherstellungsfrage („frische
  VM?") ist mit Nein beantwortet (05).
- **Updates sind Alles-oder-Nichts (F-004).** Ein Befehl für DB, App,
  Proxy und Monitoring, ohne Gate, mit brüchigem Rollback-Versprechen.
  Fördert Update-Aufschub über Jahre.
- **Idempotenz versprochen, nicht gehalten (F-009).** Vier Zweitlauf-Pfade
  (`.env`, `DOCKER_GID`, Crontab-Migration, Caddy-Restart) sind gebrochen
  oder riskant – der empfohlene Bedienweg ist der unsicherste.
- **Netzwerkgrenze ohne Durchsetzung (F-006).** UFW regelt Host-Dienste,
  nicht Container-Ports; keine `DOCKER-USER`-Policy, kein Modell für
  dynamische Workspace-Ports, IPv6 unverifiziert (02/F-010).
- **TLS ohne Autorisierung (F-017).** `ask http://example.com` ist formal
  vorhanden, faktisch wirkungslos; LE-Budget der gesamten Schuldomain von
  außen verzehrbar.
- **Beobachtung ohne Konsument (F-007).** Voller Monitoring-Stack ohne
  Alarm, ohne Dashboard-as-code, ohne Frische-Prüfung. Stille Defekte als
  Normalfall.
- **Lebenszyklus ohne Koordination (F-010, F-011).** 01:00-Backup,
  03:00-Reboot, manuelles Update kennen sich nicht; kein Boot-Gate, kein
  Lock, kein Cron-Nachweis.
- **Zugang im Dauer-Provisorium (F-012).** SSH weltweit + Passwort aktiv,
  Enforcement als „Bescheid geben" ohne Pfad und Frist.
- **Nicht testbar (F-015).** Leeres `tests/`, keine CI-fähige Prüfung,
  jede Verifikation braucht den Produktionshost.
- **Degradation ohne Sicherheitsnetz (F-016).** Unbegrenzte Logs,
  unbegrenzter RAM, nur zeitbegrenzte TSDB, unrotierte Backup-Logs,
  ungemessene Zertifikats-RTO.

---

## Decisions Requiring Human Approval

Jede Entscheidung nennt Optionen, Kosten und die Frage an den Menschen.
Das Review empfiehlt keine Option als „richtig" – es benennt den Preis.

- **D1 – Docker-Provisioner-Modell.** Optionen: (a) Status quo
  (Single-Host + Socket, mit Template-Allowlist aus F-005);
  (b) separater Provisioning-Host/VM für Workspaces;
  (c) Socket-Proxy mit Allowlist der Docker-API-Operationen.
  Kosten: (a) keine, aber Host-Sicherheit = Coder-Fehlerfreiheit;
  (b) Betriebs-/Netzwerkaufwand + Latenz; (c) Proxy-Pflege, Risiko
  gebrochener Provisioner-Funktionen. Frage: Welches Modell trägt die
  Schule über Jahre (Admin-Kapazität vs. Risiko)? Erst danach sind
  Proxy-/Host-Entscheidungen sinnvoll.
- **D2 – TLS-Modell.** Optionen: (a) On-Demand + echter `ask`-Endpoint
  (Abgleich gegen Coder-API/Allowlist); (b) DNS-01-Wildcard (eigener
  Caddy-Build + DNS-Provider-Token der Schule). Kosten: (a) kleiner Dienst
  mit Falsch-Negativ-Risiko für neue Apps; (b) Token-Verwaltung +
  Build-Pflege, dafür kein On-Demand-DoS und keine Erstaufruf-Latenz.
  Frage: Gibt es einen DNS-Provider-Token (wer verwaltet ihn), oder wird
  der `ask`-Dienst gebaut und betrieben?
- **D3 – SSH-Modell und Key-Termin.** Optionen: Key-only sofort nach
  Zweit-Zugangs-Nachweis vs. befristeter Weiterbetrieb mit starkem
  Passwort. Kosten: Aussperrungsrisiko vs. Brute-Force-Fenster.
  Frage: Wer bestätigt den funktionierenden Key-Zugang (Zweit-Zugang
  vorhanden?), und ab wann gilt `ssh-harden.sh` (F-012) als ausgeführt?
- **D4 – Docker-Engine-Updates.** Optionen: Docker-Origin in
  `unattended-upgrades` aufnehmen (automatisch, inkl. Reboot-Risiko) vs.
  manueller Kalendertermin (z. B. monatlich, dokumentiert). Kosten:
  Destabilisierungsrisiko vs. Vergessensrisiko (03/F-003). Frage: Wer
  trägt den manuellen Termin im Kalender, oder wird Automatik mit
  Test-Reboot in Kauf genommen?
- **D5 – Workspace-Daten-Verantwortung.** Optionen: (a) Server-seitiges
  Workspace-Backup (berührt laufende Container, vgl. 05/F-015);
  (b) Nutzer-Export-Pflicht (z. B. Git-Push-Pflicht, dokumentiert, ohne
  Server-Technik). Kosten: (a) Technik + Störungsrisiko;
  (b) Disziplin + möglicher Datenverlust bei Nichtbefolgung. Frage: Was
  verspricht die Schule bei Serververlust – und wem (RPO für
  Schülerarbeiten)?
- **D6 – Offsite-Ziel und Schlüssel.** Optionen: Zielmedium/Konto
  (externer Speicher, zweiter Server, manuelle Kopie), Verschlüsselung
  (womit), Schlüsselverwahrung (wer, wo, getrennt vom Host). Kosten:
  Transport-Secrets, Schlüsselverlust = Datenverlust (F-008, F-013).
  Frage: Wohin täglich, verschlüsselt womit, Schlüssel bei wem?
- **D7 – Monitoring-Ambition.** Optionen: (a) minimales `check.sh`
  (F-007: Frische + `df` + `/healthz` per `logger`); (b) volles
  Prometheus-Alerting + Alertmanager + Dashboards-as-code. Kosten:
  (a) fast null, aber nur Log-Sichtbarkeit; (b) Betrieb eines
  Alert-Pfads (wer liest Alarme nachts?). Frage: Wer reagiert auf welche
  Meldung – oder reicht die morgendliche Log-Sicht?
- **D8 – Ressourcen-Limits.** Optionen: konkrete `mem_limit`-Werte und
  `retention.size` nach Messung (`docker stats` über eine Schulwoche,
  Plattenkapazität). Kosten: zu enge Limits töten Container (Exit 137),
  zu weite schützen nicht (03/F-005, F-016). Frage: Wie viel RAM/Platte
  hat der Zielserver real, und welche Dienste dürfen bei Knappheit zuerst
  degradieren (Monitoring vor DB)?
- **D9 – Firewall-Modell für Container.** Optionen: (a) Bindungsregel-
  Disziplin (`127.0.0.1`-Default, Ausnahme nur Caddy – F-006);
  (b) zusätzlich `DOCKER-USER`-Default-Deny mit Dual-Stack-Test
  (02/F-010). Kosten: (a) Disziplin ohne Durchsetzung; (b) Test- und
  Pflegeaufwand, Bruchrisiko für Workspace-Apps/HTTP-3. Frage: Wer testet
  extern (Scan) nach jeder Netzwerkänderung, und gilt IPv6 als
  Betriebs- oder als abgeschalteter Pfad?
- **D10 – RPO/RTO und Reset-Ermächtigung.** Optionen: RPO (wie viel
  Backup-Alter ist akzeptabel), RTO (wie lange darf Recovery dauern –
  gemessen in F-008-Stufe 2), Reset-Freigabe (wer darf `--force`, mit
  welcher Zweitbestätigung/Freigabe). Kosten: Strenge kostet
  Geschwindigkeit im Notfall, Freizügigkeit kostet Daten. Frage: Wer
  unterschreibt RPO/RTO, und wer darf im Notfall unwiderruflich löschen?

---

## Top Priorities

1. **F-008 – Offsite-Kopie + Restore-Runbook mit Probelauf.**
   Nutzen: Totalverlust wird erstmals überlebbar; RTO wird gemessen statt
   geraten. Ohne dies ist alles Folgende Dekoration. (CRITICAL, CONFIRMED)
2. **F-005 – Template-Allowlist + Abnahmeprozess für neue Templates.**
   Nutzen: Größte Privilegienlücke (Socket → Host) wird ohne Host-Umbau
   von Praxis zu prüfbarer Regel. (CRITICAL, CONFIRMED/ASSUMPTION)
3. **F-017(b) – `CODER_DISABLE_PATH_APPS=true` nach Template-Inventar.**
   Nutzen: Eine Zeile schließt Cookie-Missbrauch über Path-Apps bei
   bereits vorhandener Wildcard-URL. (HIGH, CONFIRMED)
4. **F-016 – Logging-Limits + `retention.size` + `logrotate`.**
   Nutzen: Beseitigt den wahrscheinlichsten schleichenden Totalausfall
   (volle Platte). Drei kleine Änderungen, kein neues System. (MEDIUM,
   CONFIRMED)
5. **F-004 – Update-Trennung `app`/`db` mit `/healthz`-Gate.**
   Nutzen: Sicherheitspatches werden ohne DB-Angst eingespielt;
   Fehl-Updates melden sich selbst statt durch Schüler. (HIGH, CONFIRMED)
6. **F-007 + F-010 – `check.sh` (Backup-Frische, `df`, `/healthz`) +
   Boot-Gate nach 03:00-Reboot.** Nutzen: Beendet die Ära stiller Defekte;
   morgendlicher Log-Blick statt Schülermeldung. (MEDIUM/HIGH, CONFIRMED)
7. **F-012 – `ssh-harden.sh` vorbereiten, nach Key-Abnahme ausführen.**
   Nutzen: Das Provisorium (Passwort + weltweit) bekommt einen definierten
   Ausgang mit Zweit-Zugangs-Garantie. (HIGH, LIKELY)
8. **F-009 – Idempotenz-Fixes (`.env`-Vollständigkeit + atomar,
   `DOCKER_GID`-Refresh, Caddy-nur-bei-Änderung, Crontab-`|| true`).**
   Nutzen: Der dokumentierte Bedienweg (Re-Run) wird sicher statt
   riskant. (HIGH, CONFIRMED)
9. **F-002 + F-003 – Zustandsinventar + Config-Templates im Repo.**
   Nutzen: Backup, Reset und Check können nicht mehr auseinanderdriften;
   Config wird CI-prüfbar vor dem Produktionshost. (HIGH/MEDIUM, CONFIRMED)
10. **F-014 – Reset-Leitplanken (Projekt-Filter, Anzeige, Bestätigung nach
    Backup, Workspace-Inventar vorher).** Nutzen: Reset wird auch um
    23 Uhr von der Vertretung sicher ausführbar. (HIGH, CONFIRMED)
11. **F-015 – Minimale Testschicht (ShellCheck, `compose config`,
    Rotations-Test).** Nutzen: Häufigste Fehlerklassen werden vor dem
    Produktionshost gefangen. (MEDIUM, CONFIRMED)
12. **F-006 + D9 – Bindungsregel sofort, `DOCKER-USER` als vorbereitete
    Entscheidung.** Nutzen: Nächster Dienst ist per Default nicht
    öffentlich. (HIGH, CONFIRMED)
13. **F-011 – `flock` + Sekunden-Timestamp + `cron`-Nachweis.**
    Nutzen: Die drei Zeit-Akteure (Backup, Reboot, Update) zerschneiden
    sich nicht mehr gegenseitig. (MEDIUM, CONFIRMED)
14. **F-013 – Secrets-Hygiene (keine Re-Ausgabe, Transaktionale Rotation,
    `.env` ins verschlüsselte Offsite).** Nutzen: Weniger Exemplare,
    kein Lockout nach Abbruch. (HIGH, CONFIRMED)
15. **D1–D10 – Menschliche Grundsatzentscheidungen (Provisioner-Modell,
    TLS-Modell, SSH-Termin, Docker-Engine-Pfad, Workspace-Verantwortung,
    Offsite/Schlüssel, Monitoring-Ambition, Limits, Firewall-Modell,
    RPO/RTO).** Nutzen: Legt Kosten, Verantwortung und Risiko für Jahre
    fest, bevor Technik sie implizit festlegt.
