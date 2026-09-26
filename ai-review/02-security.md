# Security Review

## Scope und Vertrauensmodell

Diese Review betrachtet den Inhalt dieses Repositorys, insbesondere
`setup-coder.sh`, als Installations- und Wartungsautomation. Es wurde kein
laufendes Zielsystem, keine Coder-Template-Konfiguration, keine Docker-Daemon-
Konfiguration und keine vorgelagerte Schulnetz-Firewall geprüft. Aussagen über
diese Punkte sind deshalb ausdrücklich als `ASSUMPTION` gekennzeichnet.

Ein Workspace-Benutzer wird als untrusted betrachtet. Das ist nicht dasselbe
wie ein lokaler Linux-Benutzer mit `sudo` oder Zugriff auf den Docker-Socket.
Die entscheidende Grenze ist hier: Der Coder-Service selbst hat den
Host-Docker-Socket; ein normaler Workspace bekommt ihn laut der vorliegenden
Compose-Datei nicht direkt.

## Befunde

## F-001 – Coder-Service hat Root-equivalenten Docker-Daemon-Zugriff
Status: CONFIRMED
Severity: CRITICAL

Location: `docker-compose`-Definition für `coder`: `group_add` mit `DOCKER_GID` und `/var/run/docker.sock`.

Threat: Der Unix-Docker-Socket ist eine privilegierte Host-API. Wer ihn nutzen
kann, kann typischerweise Container mit beliebigen Capabilities, Mounts und
Netzwerken erzeugen und damit Host-Dateien lesen oder den Host verändern.

Attack scenario: Eine Schwachstelle in Coder, ein kompromittierter Coder-
Prozess oder eine Funktion, die untrusted Workspace-Eingaben unsicher an den
Docker-Provisioner weitergibt, nutzt den Socket. Der Angreifer startet einen
Container mit `/:/host` und liest `/host/etc/shadow`, SSH-Schlüssel, `.env` und
Backup-Dateien. Mit einem beschreibbaren Host-Mount oder geeigneter Namespace-
Konfiguration kann daraus Codeausführung als Host-root werden.

Evidence: Der Socket wird ohne Proxy und ohne Read-only-Semantik gemountet:
`/var/run/docker.sock:/var/run/docker.sock`. `group_add` gibt dem Container
die Docker-Gruppen-GID. Es gibt keine Socket-Policy, keinen Rootless-Docker
und keine zusätzliche Autorisierungsschicht.

Impact: Kompromittierung des gesamten Hosts, aller Container, aller Daten und
aller Secrets. Das ist eine bewusste Architekturabhängigkeit des Docker-
Provisioners, keine normale Workspace-Isolation.

Proposed mitigation: Coder und Workspace-Provisioning auf einen dedizierten,
isolierten Docker-Host oder eine VM verlagern. Alternativ einen strikt
allowlistenden Docker-Socket-Proxy einsetzen und Templates so beschränken,
dass keine privilegierten Container, Host-Mounts, Host-PID- oder Host-Netzwerk-
Optionen möglich sind. Der Socket selbst darf nicht an Workspace-Container
weitergereicht werden.

Regression risk: Ein Socket-Proxy kann legitime Provisioner-Funktionen
brechen; ein separater Host erhöht Betriebs- und Netzwerkaufwand.

Validation: In einer isolierten Testumgebung prüfen, welche Docker-API-
Operationen Coder tatsächlich benötigt, und anschließend beweisen, dass ein
Workspace weder den Socket sieht noch einen Container mit Host-Mount oder
`--privileged` erzeugen kann.

## F-002 – Direkter Docker-Socket-Zugriff eines Workspace ist nicht belegt, aber Template-abhängig
Status: ASSUMPTION
Severity: HIGH

Location: Compose-Datei ohne Workspace-Definition; Workspaces werden laut
Kommentar von Coder direkt über den Docker-Socket erzeugt.

Threat: Ein Workspace mit Socket-Mount oder einer gleichwertigen Capability
ist praktisch ein Host-Administrator.

Attack scenario: Ein Coder-Template bind-mountet `/var/run/docker.sock`,
`/var/run`, `/`, `/proc` oder setzt `privileged`, `pid: host` bzw. `network:
host`. Code im Workspace liest dann andere Container, den Host oder startet
weitere privilegierte Container.

Evidence: Die vorliegende Datei zeigt nur den Socket-Mount im `coder`-
Container, nicht die Templates. Es gibt keine Prüfung oder Policy gegen
gefährliche Template-Optionen.

Impact: Je nach Template direkte oder indirekte Host- und Workspace-
Kompromittierung.

Proposed mitigation: Alle Templates inventarisieren und serverseitig
allowlisten. Socket-, Host-Root-, Host-PID-, Host-Network-, Device-,
Privileged- und beschreibbare System-Mounts für untrusted Benutzer verbieten.

Regression risk: Hardware- oder Docker-in-Docker-Workspaces können ihre
Funktion verlieren und brauchen einen separaten privilegierten Pool.

Validation: Mit einem normalen Workspace `mount`, `/proc/1/root`, Docker-
Socket-Pfade, Capabilities und erreichbare Netzwerke prüfen; anschließend
versuchen, einen fremden Workspace-Container zu inspizieren.

## F-003 – Container-zu-Host-Eskalation über den Coder-Provisioner
Status: CONFIRMED
Severity: CRITICAL

Location: Coder-Container mit Host-Docker-Socket; `node-exporter` zusätzlich
mit `pid: host` und Host-Dateisystem-Mounts.

Threat: Die Docker-API und die Host-Metrik-Komponente vergrößern die
Angriffsfläche über die Containergrenze.

Attack scenario: Ein Angreifer kompromittiert den Coder-Prozess oder nutzt
eine vom Coder-Server akzeptierte Containeroption. Er startet einen
privilegierten oder mit `/` beschreibbar gemounteten Container und ersetzt
beispielsweise einen von systemd gestarteten Host-Pfad oder liest Secrets.

Evidence: `coder` hat volle Socket-Nutzung. `node-exporter` sieht mit
`pid: host` Host-Prozesse und bindet `/proc`, `/sys` und `/` lesend ein.
Weder der Socket noch die Docker-API sind auf erlaubte Operationen reduziert.

Impact: Host-root-equivalente Wirkung bei erfolgreicher Ausnutzung. Der
Node-Exporter-Mount allein ist lesend und beweist keinen Escape; der
Docker-Socket reicht dafür jedoch aus.

Proposed mitigation: F-001 umsetzen. Node-Exporter in einem möglichst
unprivilegierten Setup betreiben und nur die erforderlichen Metriken
freigeben.

Regression risk: Eingeschränkte Host-Metriken und möglicherweise inkompatible
Coder-Provisionierung.

Validation: Escape-Test in einer Wegwerf-VM mit Auditierung aller Container-
Capabilities, Mounts und Docker-API-Aufrufe.

## F-004 – Zugriff auf andere Workspaces und Postgres ist nicht abschließend nachweisbar
Status: ASSUMPTION
Severity: HIGH

Location: Compose-Netzwerk, `postgres` ohne veröffentlichten Host-Port und
Coder-Workspaces außerhalb der vorliegenden Compose-Datei.

Threat: Gemeinsame Docker-Netzwerke oder zu breite Coder-Berechtigungen können
Seitwärtsbewegung ermöglichen.

Attack scenario: Ein Workspace scannt Docker-DNS und interne IPs, verbindet
sich zu `postgres:5432` oder erreicht einen anderen Workspace über dessen
Container-IP. Bei Kenntnis des DB-Passworts liest oder verändert er die Coder-
Datenbank.

Evidence: Postgres ist im Compose-Netzwerk unter dem Servicenamen erreichbar;
der Port ist nicht an den Host veröffentlicht. Die Datei definiert aber weder
die von Coder angelegten Workspace-Netzwerke noch deren Isolation und enthält
keine Netzwerk- oder Datenbank-ACLs.

Impact: Bei gemeinsamer Netzwerkmitgliedschaft Zugriff auf Postgres und/oder
andere Workspaces; ohne diese Mitgliedschaft ist der Zugriff nicht belegt.

Proposed mitigation: Pro Workspace dedizierte Netzwerke verwenden, nur die
notwendigen Egress-Verbindungen erlauben und Postgres mit Netzwerk-ACL,
separatem Least-Privilege-Benutzer und TLS absichern. Workspace-Benutzer
dürfen keine Coder-Datenbank-Credentials erhalten.

Regression risk: Coder-Provisioning und Workspace-Kommunikation können
Netzwerkregeln benötigen, die explizit dokumentiert werden müssen.

Validation: Aus einem Workspace `getent hosts`, TCP-Verbindungen zu Postgres,
Coder- und fremden Workspace-Netzen testen; Docker-Netzwerkmitgliedschaften
und Coder-RBAC exportieren.

## F-005 – Monitoring-Daten sind lokal gebunden, aber nicht automatisch vertraulich
Status: CONFIRMED
für Bindung; ASSUMPTION für Workspace-Zugriff
Severity: MEDIUM

Location: Prometheus `127.0.0.1:9090`, Node-Exporter `127.0.0.1:9100`,
Grafana `127.0.0.1:3001`; Coder-Metriken auf `0.0.0.0:2112` innerhalb des
Coder-Containers.

Threat: Metriken können Benutzernamen, Workspace-Namen, Agent-Statistiken,
Host-Ressourcen und interne Topologie offenlegen.

Attack scenario: Ein lokaler Host-Benutzer oder ein Workspace mit erreichbarem
Host-Netzwerk, gemeinsamer Docker-Netzwerkmitgliedschaft oder einem Coder-
Endpoint ruft Prometheus/Grafana bzw. die Coder-Metriken ab. Grafana besitzt
zudem ein initiales Admin-Passwort aus `.env`.

Evidence: Kein Host-Port für `2112`; Prometheus/Grafana/Node-Exporter sind
nur auf Loopback veröffentlicht. Es gibt keine Authentifizierung für den
Coder-Metrik-Endpunkt im Container und keine gezeigte Netzwerkpolicy.

Impact: Vertraulichkeitsverlust der Monitoring-Daten; bei Grafana-Admin-
Zugriff eventuell Änderung von Dashboards und Datenquellen. Ein direkter
Workspace-Zugriff ist aus dem Repository allein nicht bestätigt.

Proposed mitigation: Monitoring über SSH-Tunnel mit starker Authentisierung
und getrennten Rollen betreiben; Prometheus/Grafana zusätzlich per Auth-
Proxy und Netzwerk-ACL schützen; Coder-Metriken auf das notwendige Interface
begrenzen.

Regression risk: Debugging und Agent-Monitoring können eingeschränkt werden.

Validation: Von Host, Coder-Netzwerk und Workspace jeweils Verbindungen zu
`9090`, `9100`, `3001` und `2112` testen.

## F-006 – Host-PID und Root-Dateisystem im Node-Exporter offenbaren Hostdaten
Status: CONFIRMED
Severity: HIGH

Location: `node-exporter`: `pid: host`, `/proc:/host/proc:ro`,
`/sys:/host/sys:ro`, `/:/rootfs:ro`.

Threat: Ein kompromittierter Node-Exporter-Prozess oder ein weiterer Zugriff
auf dessen Endpunkt erhält Einsicht in Host-Prozesse, Mounts und lesbare
Dateien.

Attack scenario: Der Angreifer erreicht den Node-Exporter oder nutzt eine
Schwachstelle im Image und liest aus `/rootfs` Konfigurationen, Logs,
Backup-Metadaten oder aus `/host/proc` Prozessargumente und Umgebungsdaten.

Evidence: Die Mounts sind ausdrücklich Host-weit und nur read-only. Read-only
verhindert das Lesen nicht und ist keine Geheimnisgrenze.

Impact: Informationsabfluss und mögliche Vorbereitung weiterer Angriffe;
allein kein bestätigter Schreibzugriff oder Escape.

Proposed mitigation: Exporter auf einem dedizierten Monitoring-Host oder mit
minimalen Collector-Rechten betreiben. Host-Root-Mount vermeiden, wenn die
benötigten Metriken anders erhoben werden können.

Regression risk: Host-Dateisystem- und Prozessmetriken können entfallen.

Validation: Effektive Mounts, Capabilities und HTTP-Metriken in einer
Testumgebung prüfen; gezielt nach Secrets in Labels und Collector-Ausgaben
suchen.

## F-007 – SSH-Passwort- und KbdInteractive-Login werden nicht deaktiviert
Status: LIKELY
Severity: HIGH

Location: Skriptkommentar und Abschlusscheck; es wird nur gewarnt, wenn
`sshd -T` nicht sowohl `passwordauthentication no` als auch
`kbdinteractiveauthentication no` liefert.

Threat: SSH ist laut Skript weltweit erreichbar. Passwort- oder interaktive
Authentisierung ermöglicht Online-Brute-Force und Phishing gegen Hostkonten.

Attack scenario: Ein Internetangreifer probiert gültige oder wiederverwendete
Passwörter. `ufw limit` und fail2ban reduzieren Versuche, verhindern aber
weder verteilte Angriffe noch kompromittierte Passwörter.

Evidence: Das Skript konfiguriert keine `sshd_config`, sondern meldet nur
eine Warnung und lässt den Installationslauf erfolgreich weiterlaufen. Der
Kommentar sagt ausdrücklich, dass Passwort-Login aktuell aktiv ist.

Impact: Direkte Host-Kompromittierung bei schwachem oder geleaktem
SSH-Passwort; danach Zugriff auf Docker, Backups und alle Secrets.

Proposed mitigation: Vor öffentlicher Erreichbarkeit Schlüsselzugriff
einrichten und `PasswordAuthentication no`,
`KbdInteractiveAuthentication no` sowie nach Bedarf `PermitRootLogin no`
erzwingen. SSH-Zugriff auf Admin-Netze oder VPN beschränken.

Regression risk: Aussperrung bei fehlerhaftem Key-Rollout; zweiter getesteter
Administrationszugang und `sshd -t` sind erforderlich.

Validation: Effektive Konfiguration mit `sshd -T`, externen Loginversuch mit
Passwort und Key sowie fail2ban-Ban-Verhalten prüfen.

## F-008 – UFW-Regeln schützen veröffentlichte Docker-Ports nicht zuverlässig
Status: CONFIRMED
Severity: HIGH

Location: UFW-Regeln für `80/tcp`, `443/tcp`, `443/udp`; Docker-Portpublishing
für Caddy in Compose.

Threat: Docker installiert eigene NAT-/Filterregeln, die den normalen UFW-
Pfad umgehen können. `ufw allow` ist deshalb keine zusätzliche Einschränkung
für Containerports.

Attack scenario: Ein später hinzugefügter `ports:`-Eintrag oder ein durch den
Coder-Daemon veröffentlichter Workspace-Port wird von Docker auf allen
Interfaces erreichbar gemacht, obwohl keine passende UFW-Regel existiert.

Evidence: Das Skript kommentiert selbst, dass Docker UFW für Containerports
üblicherweise umgeht. Es konfiguriert weder `DOCKER-USER` noch eine Docker-
Firewall-Policy.

Impact: Unbeabsichtigte öffentliche Dienste und Bypass von Herkunfts-
Beschränkungen; aktuelle Caddy-Ports sollen zwar öffentlich sein, beweisen
aber keine Sicherheit für dynamische Workspace-Ports.

Proposed mitigation: `DOCKER-USER`-Regeln oder eine dedizierte Firewall vor
Docker einführen, die erlaubte Zielports und Quellnetze explizit kontrolliert.
Docker-Bindings auf notwendige Adressen begrenzen und dynamische Workspace-
Ports vermeiden oder über Caddy authentisiert proxien.

Regression risk: Coder-Workspace-Apps und HTTP/3 können ohne korrekt getestete
Forwarding-Regeln ausfallen.

Validation: Von extern und lokal `nmap`/`ss` gegen alle Hostadressen und
Workspace-Ports testen; `iptables-save`/`nft list ruleset` inklusive
`DOCKER-USER` prüfen.

## F-009 – Tatsächlich beabsichtigte öffentliche Ports und unbekannte dynamische Ports
Status: CONFIRMED für Compose-Bindings; ASSUMPTION für Upstream-Forwarding
Severity: MEDIUM

Location: Caddy `ports`: `80:80`, `443:443`, `443:443/udp`; Prometheus,
Node-Exporter und Grafana binden an `127.0.0.1`; SSH wird nicht durch dieses
Repository konfiguriert.

Threat: Jeder weitergeleitete Port ist eine Internet-Angriffsfläche.

Attack scenario: Extern erreichbar sind bei korrekt eingerichteter
Schulnetz-Portweiterleitung TCP 80, TCP 443, UDP 443 und laut Skript TCP 22.
Port 80 ist nicht intern, sondern tatsächlich an Caddy veröffentlicht und
wird vermutlich nur auf HTTPS umgeleitet. Coder-Workspace-Ports können
zusätzlich dynamisch veröffentlicht werden.

Evidence: Explizite Compose-Bindings; loopback-Bindings für `9090`, `9100`,
`3001`; Kopfkommentar fordert Weiterleitung von 22, 80 und 443.

Impact: Externe Angriffe auf Caddy/Coder/ACME und möglicherweise auf jeden
dynamisch publizierten Workspace-Dienst.

Proposed mitigation: Externes Portinventar regelmäßig mit IPv4 und IPv6
scannen. Nur 80/443 (und SSH über VPN/Admin-ACL) weiterleiten; dynamische
Workspace-Ports nicht direkt veröffentlichen.

Regression risk: Workspace-App-URLs brauchen ein bewusst implementiertes
Reverse-Proxy- und DNS-Modell.

Validation: Externer Scan für TCP 22/80/443/9090/9100/3001 sowie UDP 443;
Docker-Portliste und Schulnetz-NAT abgleichen.

## F-010 – IPv4/IPv6 und UFW-V6-Zustand werden nicht verifiziert
Status: ASSUMPTION
Severity: MEDIUM

Location: DNS-Kommentar erlaubt A- und ggf. AAAA-Records; das Skript prüft
weder UFW-IPv6 noch Docker-/Host-IPv6-Bindings.

Threat: Ein Dienst kann über IPv6 öffentlich sein, obwohl nur IPv4 getestet
oder abgesichert wurde.

Attack scenario: Ein AAAA-Record zeigt auf den Host, während `ufw`-V6-
Konfiguration, Docker-IPv6 und vorgelagerte Filter anders wirken als bei
IPv4. Der Angreifer erreicht Caddy, SSH oder dynamische Ports über IPv6.

Evidence: Keine Prüfung von `IPV6=yes`, `ip6tables`/nftables, Docker-
`ip6tables` oder externen AAAA-Verbindungen.

Impact: Unbemerkter Umgehungspfad für alle öffentlich gebundenen Dienste.

Proposed mitigation: IPv6 entweder vollständig konfigurieren und testen oder
AAAA/Docker-IPv6 deaktivieren. Regeln für beide Familien dokumentieren.

Regression risk: Erreichbarkeit aus IPv6-Netzen kann sich ändern.

Validation: Dual-Stack-Scan und `curl -6`; effektive UFW-, nftables- und
Docker-Regeln für beide Familien prüfen.

## F-011 – On-Demand TLS erlaubt Zertifikatsanfragen für jeden passenden Hostnamen
Status: CONFIRMED
Severity: HIGH

Location: Caddy `*.${DOMAIN_CODER}` mit `tls { on_demand }` und
`on_demand_tls { ask http://example.com }`.

Threat: Der `ask`-Endpoint ist keine fachliche Autorisierung; `example.com`
antwortet laut Skriptkommentar immer mit HTTP 200. Jede Anfrage mit passendem
SNI kann daher eine ACME-Ausstellung auslösen.

Attack scenario: Ein externer Angreifer erzeugt viele zufällige
`<name>.coder.example`-Anfragen. Bei passendem Wildcard-DNS und erreichbarem
Port 80 beantragt Caddy für die Namen Zertifikate. Der Angreifer verbraucht
ACME-/Caddy-Ressourcen, triggert Rate Limits oder lässt legitime Workspace-
Apps ausfallen.

Evidence: Es gibt keine Allowlist, keine Rate-Limit-Logik und keinen echten
Autorisierungsdienst; `ask` zeigt stattdessen auf eine externe Beispielseite.
Ein eigener DNS-API-Token wird nicht verwendet, daher ist dies kein
Wildcard-Zertifikat per DNS-01, sondern On-Demand-Ausstellung für konkrete
Namen.

Impact: Denial of Service, ACME-Rate-Limit-Verbrauch und potenzieller
Zertifikatsmissbrauch innerhalb der kontrollierten Domain. Keine Ausstellung
für fremde Domains, solange der Site-Block exakt greift.

Proposed mitigation: On-Demand-TLS durch vorab ausgestellte Zertifikate oder
ein echtes, authentisiertes `ask`-Allowlisting ersetzen. Requests pro Client
und Hostname begrenzen; Workspace-URLs nur nach existierender Coder-
Autorisierung zulassen.

Regression risk: Erste Aufrufe können ohne On-Demand-TLS eine Zertifikats-
oder DNS-Provisionierung benötigen.

Validation: In einer Testdomain zufällige Subdomains anfordern, Caddy- und
ACME-Logs sowie Rate Limits prüfen und sicherstellen, dass nicht registrierte
Workspace-Namen abgewiesen werden.

## F-012 – DNS-, HTTP- und Zertifikatsannahmen hängen vom externen Netz ab
Status: ASSUMPTION
Severity: MEDIUM

Location: Anforderungen an A/AAAA- und Wildcard-DNS, öffentliche
Portweiterleitung und Caddy-ACME.

Threat: Falsche DNS-Ziele, fremde Wildcard-Einträge oder HTTP-01-Erreichbarkeit
können Zertifikatsausstellung und Routing kontrollieren.

Attack scenario: Ein Angreifer kontrolliert DNS oder ein vorgelagertes Proxy-
System, zeigt `*.DOMAIN` auf einen eigenen Dienst oder verhindert die
Challenge. Nutzer senden dann Tokens und Workspace-Daten an den falschen
Endpunkt oder Caddy fällt auf HTTP/kein Zertifikat zurück.

Evidence: Das Repository prüft nur lokal `getent hosts` und einen einzelnen
`curl`-Aufruf. DNSSEC, autoritative Nameserver, CAA, Challenge-Pfad und
vorgelagerte Proxy-Regeln werden nicht geprüft.

Impact: Phishing/MitM bei DNS- oder Proxy-Kompromittierung, Ausfall oder
falsche Zertifikatsanträge.

Proposed mitigation: DNS-Verantwortung, CAA für die verwendete ACME-CA,
DNSSEC und HTTP-01-Pfad festlegen. Externe Tests von mehreren Netzen und
autoritative DNS-Abfragen in die Betriebsprüfung aufnehmen.

Regression risk: Strengere DNS-/CAA-Regeln können bestehende Zertifikate
oder Schulnetz-Proxies beeinflussen.

Validation: `dig` gegen autoritative Nameserver, A/AAAA/Wildcard/CAA prüfen,
TLS-SNI von extern testen und Caddy-ACME-Logs kontrollieren.

## F-013 – Image-Tags und Docker-Repository sind nicht unveränderlich gepinnt
Status: CONFIRMED
Severity: HIGH

Location: `postgres:15-alpine`, `caddy:2.10`,
`ghcr.io/coder/coder:v2.36.6`, Prometheus/Grafana/Node-Exporter-Tags;
`docker compose pull` in `update.sh`.

Threat: Tags sind veränderlich. Ein kompromittiertes Registry-Konto, ein
Supply-Chain-Vorfall oder ein unerwarteter Tag-Move kann beim nächsten Update
fremden Code auf dem Host ausführen.

Attack scenario: Ein Tag zeigt auf ein manipuliertes Image. Der manuelle
Update-Lauf zieht es und startet es; Coder besitzt wegen F-001 den
Docker-Socket, wodurch ein manipuliertes Coder-Image direkt Host-Kontrolle
erlangen kann.

Evidence: Keine `@sha256:`-Digests, keine Signaturprüfung und keine
Provenance-/SBOM-Prüfung. Caddy ist nur auf Minor-Version gepinnt; auch
exakte Tags ersetzen keine kryptografische Identitätsprüfung.

Impact: Vollständige Host- und Datenkompromittierung über besonders
privilegierte Images.

Proposed mitigation: Images per Digest pinnen, Signaturen/Attestierungen mit
einer festgelegten Vertrauenskette prüfen und Updates kontrolliert promoten.
Registry-Zugriff und Rollback-Prozess dokumentieren.

Regression risk: Digest-Updates erfordern bewusste Pflege; Patch-Updates
kommen nicht mehr automatisch durch bloßes Pull.

Validation: Vor und nach Pull Image-Digests, Signaturen und SBOM vergleichen;
Update in isolierter Umgebung starten und Smoke-/Security-Tests durchführen.

## F-014 – Externe Downloads und GPG-Key-Vertrauen sind nicht vollständig abgesichert
Status: CONFIRMED
Severity: HIGH

Location: `curl -fsSL https://download.docker.com/linux/debian/gpg | gpg
--dearmor`; anschließend Docker-APT-Repository und externe Image-Registries.

Threat: Der Bootstrap vertraut auf Netzwerk, DNS, TLS-CA und den geladenen
GPG-Schlüssel. Ein falscher Schlüssel kann ein bösartiges Repository
legitim erscheinen lassen.

Attack scenario: DNS-, Proxy- oder CA-Kompromittierung liefert einen anderen
Schlüssel und ein manipuliertes Docker-Paket. Das Skript installiert es mit
Root-Rechten, bevor der Stack überhaupt startet.

Evidence: Der Schlüssel wird geladen und direkt verwendet; Fingerprint,
Out-of-Band-Prüfung, Ablauf/Rotation und Transport-Pinning fehlen.

Impact: Root-Kompromittierung während der Installation.

Proposed mitigation: Offiziellen Schlüssel-Fingerprint außerhalb des
Downloads verifizieren, Repository auf erwartete Distribution/Architektur
begrenzen und Pakete/Images in einer kontrollierten Mirror-/Signaturkette
beziehen.

Regression risk: Key-Rotation und Mirror-Betrieb erzeugen Wartungsaufwand;
zu strikte Pins können legitime Sicherheitsupdates blockieren.

Validation: APT-Quelle, Schlüssel-Fingerprint, Paket-Signaturen und
Netzwerkpfad in einer sauberen VM protokolliert prüfen.

## F-015 – Secrets sind rootgeschützt, erscheinen aber in Ausgabe und mehreren privilegierten Stellen
Status: CONFIRMED
Severity: MEDIUM

Location: `/opt/coder/.env` mit `600 root:root`; initiale Ausgabe und
`reset-passwords.sh` geben Postgres- und Grafana-Passwörter aus; Compose-
Umgebungen enthalten diese Werte.

Threat: Ein Secret ist nicht nur durch die Datei gefährdet. Terminal-History,
CI-/Wrapper-Logs, Mitschnitte, `docker inspect` und Root-/Docker-Admin-Zugriff
können es offenlegen.

Attack scenario: Der Operator kopiert die Ausgabe in ein Ticket oder ein
Terminal-Logging-System. Ein lokaler Benutzer mit Docker-Socket-Zugriff liest
Container-Environment oder ein kompromittiertes Coder-Image liest seine
Prozessumgebung und erhält das Postgres-Passwort.

Evidence: Passwörter werden explizit nach stdout geschrieben. Das Passwort
steht als Container-Environment in `CODER_PG_CONNECTION_URL` und
`GF_SECURITY_ADMIN_PASSWORD`; `.env` ist zwar `600`.

Impact: Datenbankzugriff, Grafana-Admin-Zugriff und bei erreichbarer DB
Manipulation der Coder-Instanz.

Proposed mitigation: Secrets nicht ausgeben, per Secret-Store oder Docker-
Secrets zuführen, DB-Verbindung ohne Passwort in Prozessargumenten/Logs
gestalten und nach jeder möglichen Offenlegung rotieren. Docker-Admin als
vollständig privilegiert behandeln.

Regression risk: Secret-Store und Rotation müssen beim Neustart verfügbar sein.

Validation: Prozessliste, `docker inspect`, Journald, Shell-History und
Installations-/Backup-Logs auf Secret-Muster prüfen.

## F-016 – Backup-Dateien enthalten vollständige Coder-Datenbank
Status: CONFIRMED
Severity: HIGH

Location: `/opt/coder/backup.sh`, täglicher Root-Cronjob und
`/opt/coder/backups`; `pg_dump | gzip`.

Threat: Ein Backup ist eine Kopie aller Coder-Daten, nicht nur eine technische
Datei. Es kann Benutzerinformationen, Tokens, Hashes und Konfigurationen
enthalten.

Attack scenario: Ein lokaler Angreifer, kompromittiertes Hostkonto,
Fehlkonfiguration des Verzeichnisses oder ein über F-001 erlangter Root-
Container liest ein Backup und stellt daraus die Coder-Instanz oder Secrets
wieder her.

Evidence: Backups bleiben bei Reset erhalten, werden 14 Tage aufbewahrt und
sind nur mit Unix-Rechten (`700` Verzeichnis, `600` Datei) geschützt. Es gibt
keine Verschlüsselung, Offsite-Policy oder Restore-Prüfung im Repository.

Impact: Vollständiger Datenabfluss und potenziell dauerhafte Übernahme der
Coder-Organisation.

Proposed mitigation: Backups clientseitig mit getrennt verwaltetem Schlüssel
verschlüsseln, Zugriff strikt auditieren, Aufbewahrung minimieren und
regelmäßig in einer isolierten Umgebung wiederherstellen. Schlüssel nicht auf
dem selben Host speichern.

Regression risk: Restore ohne Schlüssel wird unmöglich; Schlüsselverlust wird
zum Datenverlust.

Validation: Rechte/Owner, Verschlüsselung, Backup-Inhalt und dokumentierter
Restore-Test mit einem nicht produktiven Schlüssel prüfen.

## F-017 – Reset- und Wartungsskripte besitzen bewusst destruktive Root-Wirkung
Status: CONFIRMED
Severity: HIGH

Location: `/opt/coder/reset-coder.sh`, `update.sh`, `backup.sh`; Aufruf jeweils
mit `sudo` vorgesehen.

Threat: Ein Nutzer, der diese Skripte ausführen darf, kann Datenbank,
Grafana-/Prometheus-Volumes, Credentials oder Images beeinflussen.

Attack scenario: Ein kompromittiertes Hostkonto mit zu breitem sudo startet
`reset-coder.sh --force`, bestätigt `RESET` und löscht die Volumes. Ein
manipulierter Inhalt unter `/opt/coder` oder ein Registry-Update verändert
anschließend den Stack. Ein Workspace kann dies nur auslösen, wenn zusätzlich
Hostzugriff, Socket-Missbrauch oder eine Coder-Eskalation besteht.

Evidence: `docker volume rm`, `rm -f .env`, `docker compose down` und
`docker compose pull` werden ausgeführt. `--force` erlaubt Reset trotz
fehlgeschlagenem Backup.

Impact: Verfügbarkeit, Datenverlust und Supply-Chain-Auswirkung.

Proposed mitigation: Keine pauschalen sudo-Rechte auf Skripte vergeben;
Root-Wartung nur über kontrollierten Operatorzugang. Reset mit separater
Break-Glass-Freigabe, unveränderlichem Backup und zusätzlicher Ziel-/Volumen-
Allowlist absichern.

Regression risk: Notfall-Recovery wird langsamer und braucht einen Operator.

Validation: `sudo -l`, Owner/Rechte aller `/opt/coder`-Dateien, Audit-Logs und
Reset-Verhalten in einer Wegwerfinstallation prüfen.

## F-018 – Umgebungsvariablen können Konfiguration und Angriffsfläche verändern
Status: CONFIRMED für Konfigurationssteuerung; LIKELY für Injection-Auswirkung
Severity: MEDIUM

Location: `: "${DOMAIN_CODER:=...}"`, `ACME_EMAIL`, sämtliche Versionsvariablen
und Shell-Heredocs.

Threat: Jeder Aufrufer kann vor dem Root-Installationslauf Domain, E-Mail,
Image-Tag und Version verändern. Werte werden in Caddyfile und Compose-Datei
geschrieben, ohne Formatvalidierung.

Attack scenario: Ein privilegierter lokaler Aufrufer setzt eine Domain auf
eine fremde oder unerwartete Konfiguration, eine Version auf ein manipuliertes
Image oder fügt über Zeilenumbrüche Caddy-/Compose-Konfiguration ein. Shell-
Ausführung des Variableninhalts ist im Heredoc nicht automatisch belegt, die
resultierende Konfigurationsinjektion aber möglich.

Evidence: Keine Regex-/Allowlist-Prüfung für Domain, E-Mail oder Image-Tags;
alle Werte werden als Shell-Expansion in Root-Dateien geschrieben.

Impact: Falsches Routing, fremde Zertifikatsanfragen, DoS oder Installation
unvertrauenswürdiger Images.

Proposed mitigation: Domain/Email/Versionswerte streng validieren und
Versionen auf eine signierte Allowlist begrenzen. Bei produktiven Läufen
keine untrusted Umgebung vererben; Compose/Caddy nach der Generierung
prüfen.

Regression risk: Bewusst unterstützte Domainwechsel müssen weiterhin möglich
bleiben.

Validation: Testwerte mit Newline, Quotes, Leerzeichen, Shell-Metazeichen und
unerwarteten Image-Referenzen durchspielen; anschließend `docker compose
config` und Caddy-Validierung ausführen.

## F-019 – Shell-/SQL-Injection ist im gezeigten Reset-Pfad begrenzt, nicht global ausgeschlossen
Status: CONFIRMED für begrenzte Eingaben; ASSUMPTION für externe Coder-Eingaben
Severity: MEDIUM

Location: `reset-passwords.sh` und `backup.sh`; Coder-Templates nicht im
Repository enthalten.

Threat: Shell-Kommandos und SQL sind besonders gefährlich, wenn Workspace-
oder Benutzereingaben ungefiltert in Provisioningpfade gelangen.

Attack scenario: Im gezeigten Reset-Skript sind Benutzername, Datenbankname
und neue Passwörter fest bzw. hexadezimal generiert; dadurch ist dort keine
offensichtliche Benutzerinput-SQL-Injection. Eine nicht gezeigte Coder-
Template-/Provisioning-Schicht könnte Workspace-Namen oder Parameter dennoch
unsicher an Shell, Docker-Labels oder SQL weitergeben.

Evidence: `pg_dump -U coder coder` und generierte Hex-Secrets sind statisch;
das Repository enthält keine Template-Shells und keine Benutzereingabe-
Validierung.

Impact: Bei einem externen Injection-Pfad Container- oder Host-Codeausführung;
für die zwei gezeigten Skripte kein bestätigter Exploit.

Proposed mitigation: Coder-Templates und Provisioner separat auditieren,
Argument-Arrays statt Shell-Strings verwenden, Eingaben allowlisten und SQL-
Parameterbindung nutzen.

Regression risk: Restriktive Namen/Parameter können bestehende Templates
brechen.

Validation: Fuzzing von Workspace-/Template-Parametern und ShellCheck plus
isolierte Provisioning-Tests.

## Beantwortung der Kernfragen

### A. Was kann ein kompromittierter Coder-Workspace tun?

Sicher ableitbar: Code im Workspace kann den eigenen Container und alle dort
verfügbaren Coder-/Netzwerkzugänge missbrauchen. Ein direkter Zugriff auf den
Host-Docker-Socket, Host-Dateien, andere Workspaces oder Secrets ist aus der
Compose-Datei nicht belegt. Er wird möglich, wenn ein Template entsprechende
Mounts, Capabilities, Host-PID/-Netzwerk oder gemeinsame Netzwerke gewährt.

### B. Kann ein kompromittierter Workspace den Host kompromittieren?

Ja, wenn der Workspace direkt oder indirekt den Docker-Socket bzw. eine
gleichwertige Host-Capability erhält. Der Coder-Service kann den Host wegen
F-001 bereits kompromittieren, falls dieser Service selbst kompromittiert
wird. Für einen normalen, korrekt isolierten Workspace ist der direkte Escape
nicht durch dieses Repository bestätigt.

### C. Kann ein Workspace andere Workspaces beeinflussen?

Über Coder-RBAC/API nur entsprechend der vergebenen Rechte; über Docker-
Netzwerk oder Socket bei zu breiten Templates möglicherweise vollständig.
Die konkrete Netzwerk- und Template-Isolation fehlt und muss geprüft werden.

### D. Kann ein Workspace auf Postgres zugreifen?

Nicht über einen veröffentlichten Host-Port. Zugriff ist möglich, wenn Coder-
Workspaces im Compose-Netzwerk hängen, ein Host-Netzwerk nutzen oder über
eine andere Fehlkonfiguration routen. Das ist eine offene `ASSUMPTION`.

### E. Kann ein Workspace auf Grafana-/Prometheus-Daten zugreifen?

Die Host-Bindings auf Loopback verhindern normalen externen Zugriff. Gemeinsame
Docker-Netzwerke, Host-Netzwerk, Coder-Proxy-Funktionen oder Credentials
könnten das ändern. Der direkte Zugriff ist daher nicht bestätigt; die Daten
enthalten trotzdem sensible Betriebsinformationen.

### F. Welche Secrets sind für einen Workspace erreichbar?

Bei korrekter Isolation keine Secrets aus `.env`, Backups oder Container-
Umgebungen. Bei Docker-Socket-/Host-Mount-/Host-PID-Eskalation: Postgres-
Passwort, Grafana-Admin-Passwort, Coder-Datenbankdaten, Backups, Prozess-
Umgebungen und weitere Host-Secrets. Die Root-Rechte `600` sind dann keine
Schutzgrenze.

### G. Welche Angriffswege bestehen über Caddy und On-Demand TLS?

Öffentlich sind HTTP, HTTPS und HTTP/3. Der `ask`-Endpunkt autorisiert jeden
passenden Wildcard-Hostnamen, sodass externe Anrufer ACME-Anfragen und
Rate-Limit-Verbrauch auslösen können. DNS-/AAAA-/Portweiterleitungsfehler
können zusätzlich Routing und HTTP-01-Challenges beeinflussen.

### H. Welche öffentlichen Ports sind tatsächlich erreichbar?

Nach der im Skript vorausgesetzten Weiterleitung: TCP 22 (SSH), TCP 80,
TCP 443 und UDP 443. Die Ports 9090, 9100 und 3001 sind an Loopback gebunden.
Coder-Workspace-Ports sind dynamisch und aus dem Repository nicht bestimmbar.

### I. Sind die UFW-Regeln angesichts von Docker wirklich ausreichend?

Nein. Sie erlauben die beabsichtigten Caddy-Ports und limitieren SSH, liefern
aber keine belastbare Policy für Docker-publizierte oder dynamische Ports.
`DOCKER-USER`/nftables-Filter und externe Scans fehlen.

### J. Welche Änderungen sind echte Security-Fixes, welche nur Hardening?

Echte Security-Fixes: Workspace- und Coder-Isolation vom Host-Docker-Socket,
Verbot gefährlicher Template-Capabilities/Mounts, Firewall-Policy vor Docker,
Deaktivierung von Passwort-/KbdInteractive-SSH vor Internetfreigabe,
On-Demand-TLS-Allowlist statt offenem `ask`, unveränderliche/signierte Images
und verschlüsselte Backups.

Hardening: `umask 077`, bereits vorhandene Loopback-Bindings, kürzere
Backup-Aufbewahrung, zusätzliche Header/Rate Limits, restriktivere
Monitoring-Bindings, SBOM/Logging und häufigere Updates. Hardening ersetzt
keine der genannten Vertrauensgrenzen.

## Security Summary

Die Installation ist für einen einzelnen, vollständig vertrauenswürdigen
Operator mit Coder-Docker-Provisioner funktional plausibel, aber nicht als
starke Multi-User-Sicherheitsgrenze bewiesen. Der zentrale kritische Fakt ist
der unbeschränkte Host-Docker-Socket im Coder-Service. Damit hängt die gesamte
Host-Sicherheit von Coder, seinen Templates, dem Provisioner und dessen
Eingabevalidierung ab. Der Socket ist kein sicherer Mehrbenutzer-Sandbox-
Mechanismus.

SSH bleibt nach dem Skript wahrscheinlich passwortfähig, Docker-Publishing
umgeht die angenommene UFW-Grenze, Images sind nicht digest-/signaturgepinnt,
und On-Demand-TLS besitzt keine echte Allowlist. Für Workspace-Benutzer sind
direkte Zugriffe auf Postgres, Monitoring und andere Workspaces offen, weil
die relevanten Coder-Netzwerk- und Template-Konfigurationen fehlen.

## Critical Attack Paths

1. Externer Angreifer -> SSH-Passwort-Brute-Force oder geleaktes Passwort ->
	Hostkonto -> Docker-Admin -> alle Container, `.env` und Backups.
2. Coder-/Provisioner-Kompromittierung -> `/var/run/docker.sock` -> Container
	mit Host-Mount/Capabilities -> Host-root-equivalente Kontrolle.
3. Workspace mit gefährlichem Template -> Docker-Socket, Host-Mount, Host-PID
	oder Host-Netzwerk -> andere Workspaces, Postgres, Monitoring oder Host.
4. Externer Angreifer -> zufällige passende Workspace-Subdomains -> offenes
	On-Demand-TLS/ACME -> Rate-Limit- oder Verfügbarkeitsangriff.
5. Manipuliertes Registry-Image oder APT-/GPG-Vertrauenskette -> Root-
	Installations-/Updateprozess -> Coder-Container mit Docker-Socket -> Host.

## Top Security Priorities

1. Coder-Docker-Socket auf einen isolierten Provisioning-Host verlagern oder
	durch einen minimalen, getesteten API-Proxy ersetzen.
2. Alle Workspace-Templates auf Socket, Privileged, Host-Mounts, Host-PID,
	Host-Netzwerk, Devices und gemeinsame Netzwerke prüfen und untrusted
	Benutzern entziehen.
3. SSH-Key-only erzwingen, `PasswordAuthentication` und
	`KbdInteractiveAuthentication` abschalten und den externen SSH-Zugang
	per VPN/Admin-ACL begrenzen.
4. Docker-Firewall mit `DOCKER-USER`/nftables und Dual-Stack-Tests einführen;
	dynamische Workspace-Ports nicht ungefiltert veröffentlichen.
5. On-Demand-TLS durch echte Coder-Allowlist, Rate Limits und kontrollierte
	Zertifikatsausstellung ersetzen.
6. Images per Digest und Signatur/Provenance pinnen; APT-Key-Fingerprint und
	Updateprozess unabhängig verifizieren.
7. Backups verschlüsseln, Restore testen, Secrets nicht ausgeben und nach
	jeder möglichen Offenlegung rotieren.
