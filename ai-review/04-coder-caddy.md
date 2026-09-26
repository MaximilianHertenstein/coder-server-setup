# Coder + Caddy + TLS Architecture Review

## Scope und Methodik

Geprüft wird ausschließlich die Coder-/Caddy-/TLS-relevante Konfiguration in
`setup-coder.sh`: die `coder`- und `caddy`-Services in der per Heredoc
erzeugten `docker-compose.yml`, die per Heredoc erzeugte `Caddyfile`, sowie
der Abschlusscheck gegen `${DOMAIN_CODER}/healthz` in Schritt 10. Es wurde
kein laufendes System ausgeführt und keine echte TLS-Handshake-Sequenz gegen
einen Server durchgeführt; alle Aussagen zu Coder-, Caddy- und
Let's-Encrypt-Verhalten stützen sich auf die aktuell (26.09.2026) online
abrufbare offizielle Dokumentation:

- `coder.com/docs/admin/setup` (Access URL, Wildcard Access URL, TLS &
  Reverse Proxy)
- `coder.com/docs/admin/networking`, `.../networking/port-forwarding`,
  `.../networking/wildcard-access-url`
- `coder.com/docs/admin/infrastructure/architecture`
- `coder.com/docs/admin/monitoring/health-check`
- `coder.com/docs/tutorials/reverse-proxy-caddy` (das offizielle
  Caddy-Tutorial, dessen Caddyfile-Beispiel praktisch wortgleich mit der
  hier geprüften Datei ist)
- `coder.com/docs/tutorials/best-practices/security-best-practices`
- `caddyserver.com/docs/caddyfile/options` (Abschnitt `on_demand_tls`),
  `caddyserver.com/docs/caddyfile/directives/tls`,
  `caddyserver.com/docs/json/apps/tls/automation/policies/`
- `letsencrypt.org/docs/rate-limits`

Docker-Socket-Zugriff, Workspace-Isolation und Provisioner-Vertrauensmodell
sind primär Gegenstand von [02-security.md](02-security.md) und werden hier
nur so weit erneut aufgegriffen, wie sie unmittelbar mit TLS-Zertifikaten
oder dem Caddy-Reverse-Proxy zusammenhängen.

## Befunde

## F-001 – `ask http://example.com` prüft nichts außer dem bereits von Caddy erzwungenen Hostname-Muster – On-Demand-TLS ist de facto ungefiltert
Severity:
HIGH

Source:
Official documentation (caddyserver.com/docs/caddyfile/options#on-demand-tls,
caddyserver.com/docs/json/apps/tls/automation/policies/) + inference

Location:
`Caddyfile`-Heredoc in `setup-coder.sh`: globaler Block
`on_demand_tls { ask http://example.com }` zusammen mit
`${DOMAIN_CODER}, *.${DOMAIN_CODER} { tls { on_demand ... } }`.

Problem:
Caddy dokumentiert `on_demand_tls.ask` ausdrücklich als das Werkzeug, mit dem
Missbrauch von On-Demand-TLS verhindert werden soll ("Required for use in
production environments, to prevent abuse"). Der Kommentar im Skript begründet
`ask http://example.com`, das jede Anfrage mit HTTP 200 beantwortet, damit,
dass "der eigentliche Schutz gegen Missbrauch [...] vom Site-Block-Muster
selbst [kommt]": Caddy frage ohnehin nur für Hostnamen nach, die zu
`*.${DOMAIN_CODER}` passen. Das ist technisch zutreffend (die
`on_demand`-Subdirective aktiviert On-Demand-TLS nur "for the hostnames given
in the site block's address(es)", die Automation-Policy filtert zusätzlich
über `subjects`) – **aber** dieses Hostname-Muster ist kein
Autorisierungsmechanismus, sondern nur ein *Namensfilter*. Jeder, der TCP/443
des Servers erreichen kann (das ist laut ufw-Konfiguration in Schritt 4
öffentlich das gesamte Internet), kann einen TLS-Handshake mit einem
beliebigen SNI-Wert senden, der auf `*.${DOMAIN_CODER}` passt (z. B.
`irgendwas123.coder.ghse-unterricht.de`), ohne jemals bei Coder authentifiziert
zu sein oder überhaupt eine existierende Workspace-App anzusprechen. Caddy
fragt dafür `http://example.com` (immer 200), erhält also immer grünes Licht,
und fordert bei Let's Encrypt ein echtes, öffentlich vertrauenswürdiges
Zertifikat für genau diesen erfundenen Hostnamen an. Der `ask`-Endpoint prüft
an keiner Stelle, ob zu diesem Hostnamen tatsächlich eine gültige,
existierende Coder-Workspace-App gehört.

Evidence:
- Caddy-Doku zu `on_demand_tls`: "ask will cause Caddy to make an HTTP
  request to the given URL, asking whether a domain is allowed to have a
  certificate issued. [...] If the endpoint returns a 2xx status code, Caddy
  will be authorized to obtain a certificate for that name." `example.com`
  antwortet unverändert mit 200 auf jeden Pfad.
- `tls`-Direktive-Doku: "`on_demand` enables On-Demand TLS for the hostnames
  given in the site block's address(es)." – bestätigt, dass die Filterung
  ausschließlich über das Adressmuster des Site-Blocks läuft, nicht über eine
  Positivliste tatsächlich existierender Workspace-Apps.
- Offizielles Coder-Caddy-Tutorial (`coder.com/docs/tutorials/reverse-proxy-caddy`)
  verwendet exakt dieselbe Konfiguration inkl. des Hinweises "DO NOT CHANGE the
  `ask http://example.com` line!" – das Muster ist also keine
  Repo-spezifische Fehlkonfiguration, sondern die von Coder selbst empfohlene
  Minimal-Variante ohne DNS-Provider-Zugang.

Impact:
Let's Encrypt begrenzt neue Zertifikate auf 50 pro **registrierter Domain**
alle 7 Tage (siehe F-002 unten für Details zur "registrierten Domain"). Da
der `ask`-Endpoint keinerlei reale Prüfung vornimmt, kann jede beliebige
externe Partei – ohne Coder-Account, ohne Kenntnis eines echten Workspace-
Namens – durch simples wiederholtes Verbinden mit unterschiedlichen,
frei erfundenen Hostnamen unter `*.${DOMAIN_CODER}` dieses Wochenkontingent
erschöpfen. Ergebnis: Schüler/Lehrkräfte, die in derselben Woche zum ersten
Mal eine neue Workspace-App-URL oder eine neue Port-Forwarding-Subdomain
öffnen, bekommen kein Zertifikat mehr ausgestellt und sehen einen
TLS-Handshake-Fehler, bis sich das Kontingent (Refill: 1 Zertifikat alle
~202 Minuten) wieder erholt hat. Das ist die exakte Missbrauchsklasse, für
die Caddy den `ask`-Mechanismus vorsieht – hier ist er nur formal vorhanden,
aber wirkungslos.

Proposed change:
Einen echten `ask`-Endpoint implementieren (kleiner interner Dienst oder
sogar ein einfaches Shell-Skript hinter einem minimalen HTTP-Server), der nur
für Hostnamen mit 2xx antwortet, für die tatsächlich eine aktive
Coder-Ressource existiert – z. B. Abgleich gegen die Coder-API
(`/api/v2/workspaceagents`/`/api/v2/applications`) oder wenigstens gegen ein
striktes Regex, das dem tatsächlichen Coder-Subdomain-Schema entspricht
(`<port>--<agent>--<workspace>--<user>[.<suffix>]`) UND gegen eine Liste
bekannter, existierender Workspace-/User-Namen. Alternativ (vom offiziellen
Tutorial selbst als Produktionsempfehlung genannt): auf ein echtes
Wildcard-Zertifikat per DNS-01-Challenge umsteigen (Caddy-Build mit
`caddy-dns`-Plugin für den DNS-Provider der Schule), wodurch On-Demand-TLS
und damit die Notwendigkeit für `ask` komplett entfällt.

Regression risk:
Ein zu strenger eigener `ask`-Endpoint kann legitime, gerade erst erzeugte
Workspace-Apps blockieren, wenn der Abgleich veraltete Daten nutzt oder die
Coder-API nicht rechtzeitig erreichbar ist. Ein DNS-01-Umstieg erfordert
API-Zugangsdaten beim DNS-Provider der Schule (aktuell laut Kopfkommentar
nicht vorhanden) und einen eigenen Caddy-Build.

Test:
In einer Testumgebung mit eigener Testdomain: mit `curl --resolve` oder
`openssl s_client` gezielt TLS-Handshakes für mehrere frei erfundene,
niemals in Coder existierende Subdomains gegen den Server fahren und
beobachten, ob Caddy jedes Mal ein neues Zertifikat anfordert (Log:
`docker compose logs caddy` sollte `obtaining certificate` für jeden Fake-
Namen zeigen). Nach Einführung eines echten `ask`-Endpoints sollte dieselbe
Aktion mit einem Fehler/Abbruch des Handshakes enden.

Classification:
CONFIRMED

## F-002 – `CODER_DISABLE_PATH_APPS` ist nicht gesetzt, obwohl eine Wildcard Access URL konfiguriert ist
Severity:
HIGH

Source:
Official documentation (coder.com/docs/tutorials/best-practices/security-best-practices)

Location:
`docker-compose.yml`-Heredoc, `coder`-Service-`environment`-Block: enthält
`CODER_ACCESS_URL` und `CODER_WILDCARD_ACCESS_URL`, aber kein
`CODER_DISABLE_PATH_APPS`.

Problem:
Coders eigene Security-Best-Practices sagen explizit: "For production
deployments, we recommend that you disable path-based apps after you've
configured a wildcard access URL. Path-based apps share the same origin as
the Coder API [...] A malicious workspace could reuse Coder cookies to call
the API or interact with other workspaces owned by the same user." Diese
Bedingung ("Wildcard Access URL konfiguriert, aber Path-Apps nicht
deaktiviert") ist hier exakt gegeben.

Evidence:
`environment`-Liste des `coder`-Service enthält weder
`CODER_DISABLE_PATH_APPS=true` noch das äquivalente CLI-Flag
`--disable-path-apps`. `CODER_WILDCARD_ACCESS_URL=*.${DOMAIN_CODER}` ist
gesetzt, die Voraussetzung für die Empfehlung ist also erfüllt.

Impact:
Solange Path-Apps aktiv bleiben, teilen sich Workspace-Anwendungen, die über
einen Pfad statt eine Subdomain erreichbar sind, denselben Origin wie das
Coder-Dashboard/die Coder-API. Ein Workspace mit clientseitig ausführbarem
Code (z. B. eine im Unterricht gestartete Webanwendung) könnte damit
theoretisch Coder-Session-Cookies desselben Benutzers missbrauchen, um
API-Aufrufe im Namen dieses Benutzers auszuführen oder auf andere
Workspaces desselben Benutzers zuzugreifen. Coder mildert das Risiko bereits
über eingebaute Schutzmaßnahmen (Path-Apps können z. B. standardmäßig nicht
mit anderen Nutzern geteilt werden, Site-Owner-Zugriff ist eingeschränkt),
empfiehlt aber ausdrücklich zusätzlich das explizite Deaktivieren.

Proposed change:
`CODER_DISABLE_PATH_APPS=true` (bzw. äquivalent `CODER_REDIRECT_TO_ACCESS_URL`
für HTTP→HTTPS, das aber getrennt zu betrachten ist) zur `environment`-Liste
des `coder`-Service hinzufügen, da `*.${DOMAIN_CODER}` als Subdomain-Weg für
Apps/Port-Forwarding bereits vorhanden und funktionsfähig ist.

Regression risk:
Falls irgendein aktuell genutztes Template `coder_app`-Ressourcen ohne
`subdomain = true` definiert (also klassische Pfad-Apps erwartet), würden
diese nach der Änderung nicht mehr erreichbar sein, bis die Templates auf
`subdomain = true` umgestellt werden. Vor der Änderung prüfen, welche
Templates/Apps aktuell im Einsatz sind.

Test:
Nach der Änderung: Eine Test-`coder_app`-Ressource ohne `subdomain = true`
starten und beobachten, dass der Pfad-Zugriff (z. B.
`https://${DOMAIN_CODER}/@user/workspace/apps/slug`) mit einem klaren Fehler
abgelehnt wird, während dieselbe App mit `subdomain = true` über
`*.${DOMAIN_CODER}` weiterhin funktioniert.

Classification:
CONFIRMED

## F-003 – On-Demand-TLS macht jeden ersten Subdomain-Zugriff dauerhaft von der Erreichbarkeit von `example.com` abhängig
Severity:
LOW

Source:
Inference (aus offizieller Caddy-Dokumentation zu `on_demand_tls.ask`)

Location:
`Caddyfile`-Heredoc: `on_demand_tls { ask http://example.com }`.

Problem:
Jeder TLS-Handshake für einen noch nicht zwischengespeicherten Hostnamen
unter `*.${DOMAIN_CODER}` (oder sogar für `${DOMAIN_CODER}` selbst – siehe
F-006) löst laut Caddy-Doku synchron eine HTTP-Anfrage an
`http://example.com` aus, **bevor** das Zertifikat angefordert wird. Das ist
laut Kommentar im Skript beabsichtigt ("keine zu ersetzende Platzhalter-URL,
sondern exakt so von Coder empfohlen"). Damit hängt aber jeder
Erstzugriff auf eine neue Workspace-App-URL dauerhaft (nicht nur einmalig
beim Setup) von der Erreichbarkeit und Antwortzeit von `example.com` über
das öffentliche Internet ab.

Evidence:
Caddy-Doku: "The ask endpoint should return as fast as possible, in a few
milliseconds, ideally." – ein externer, nicht selbst kontrollierter Dienst
kann diese Erwartung nicht garantieren.

Impact:
`example.com` wird von IANA/ICANN betrieben und ist in der Praxis extrem
stabil, das Risiko ist daher gering. Sollte der Dienst dennoch einmal nicht
erreichbar sein oder ungewöhnlich langsam antworten (z. B. durch ein
Netzwerkproblem im Schulnetz, DNS-Filterung, oder eine Störung bei IANA),
schlägt die Zertifikatsausstellung für **jede** neue Subdomain fehl, bis der
Endpoint wieder normal antwortet – inklusive des allerersten Zugriffs auf die
Coder-Startseite selbst, falls deren Zertifikat noch nicht vorher ausgestellt
wurde (siehe F-006).

Proposed change:
Keine zwingende Änderung nötig (offizielle Empfehlung); optional einen
eigenen, lokal gehosteten `ask`-Endpoint (siehe F-001) einsetzen, der
gleichzeitig das Missbrauchsproblem behebt und die externe Abhängigkeit
entfernt.

Regression risk:
Gering, siehe F-001.

Test:
Nicht separat testbar ohne F-001 zu adressieren; bei Umsetzung von F-001
entfällt dieser Punkt automatisch.

Classification:
CONFIRMED (Mechanik), LIKELY (praktische Auswirkung, da von der Verfügbarkeit
eines fremden Dienstes abhängig)

## F-004 – Keine CAA-Empfehlung für die DNS-Konfiguration
Severity:
LOW

Source:
Inference / general TLS best practice, not specific to this repository's code

Location:
Kopfkommentar `setup-coder.sh` (DNS-Voraussetzungen) und
`ai-review/PLAN.md`-Scope – betrifft DNS, die außerhalb dieses Skripts liegt.

Problem:
Die dokumentierten DNS-Anforderungen (A/AAAA für `${DOMAIN_CODER}` und
`*.${DOMAIN_CODER}`) sind vollständig und korrekt für den Betrieb, enthalten
aber keinen Hinweis auf einen optionalen `CAA`-Record, der ausstellende
Zertifizierungsstellen auf Let's Encrypt beschränken würde.

Evidence:
Kein `CAA`-Eintrag im Skript oder in der Doku erwähnt. Dies ist Defense in
Depth, keine Voraussetzung für die Funktion.

Impact:
Ohne CAA-Eintrag könnte theoretisch jede öffentlich vertrauenswürdige CA
(nicht nur Let's Encrypt) für die Domain ein Zertifikat ausstellen, sofern
sie eine Domainvalidierung besteht. Das ist ein rein defensives Detail ohne
unmittelbaren Bezug zur aktuellen Konfiguration.

Proposed change:
Optional: `CAA 0 issue "letsencrypt.org"` (und ggf. `issuewild` für die
Wildcard-Subdomains) beim DNS-Provider der Schule ergänzen. Nicht
Teil dieses Skripts, da DNS außerhalb des Servers verwaltet wird.

Regression risk:
Falsch gesetzte CAA-Records können die Zertifikatsausstellung komplett
blockieren (auch für Let's Encrypt, falls der Eintrag fehlerhaft ist).

Test:
`dig CAA ${DOMAIN_CODER}` nach Einrichtung prüfen; testweise Zertifikat
anfordern und Ausstellung beobachten.

Classification:
ASSUMPTION (reine Empfehlung, keine im Code identifizierte Schwachstelle)

## F-005 – `CODER_PROXY_TRUSTED_ORIGINS` fehlt, ist hier aber korrekt nicht gesetzt
Severity:
INFO (keine Schwachstelle – Klarstellung, um eine plausible Fehlannahme zu vermeiden)

Source:
Official documentation (coder.com/docs/admin/networking/wildcard-access-url)

Location:
`docker-compose.yml`-Heredoc, `coder`-Service-`environment`; `Caddyfile`
`reverse_proxy coder:3000`.

Problem/Klarstellung:
Die Coder-Doku warnt: "If your reverse proxy rewrites the request `Host`
and forwards the original host in `X-Forwarded-Host`, configure
`CODER_PROXY_TRUSTED_ORIGINS` [...] Otherwise Coder will ignore
`X-Forwarded-Host` for subdomain app routing." Das könnte man als fehlende
Konfiguration missverstehen. Tatsächlich schreibt Caddys `reverse_proxy`-
Direktive den `Host`-Header standardmäßig NICHT um (er wird unverändert an
`coder:3000` durchgereicht) – das genannte Szenario liegt hier also nicht
vor, `CODER_PROXY_TRUSTED_ORIGINS` ist folgerichtig nicht nötig.

Evidence:
`reverse_proxy coder:3000` ohne `header_up Host ...`-Override in der
Caddyfile; Caddy-Standardverhalten laut offizieller `reverse_proxy`-Doku ist
Passthrough des ursprünglichen `Host`-Headers.

Impact:
Keiner – dies ist eine Bestätigung, dass die aktuelle Konfiguration in
diesem Punkt korrekt und vollständig ist, kein Bug.

Proposed change:
Keine. Falls in Zukunft ein zusätzlicher Layer (z. B. CDN, Load Balancer)
vor Caddy eingefügt wird, der den `Host`-Header umschreibt, muss dieser
Punkt neu bewertet werden.

Regression risk:
Keiner.

Test:
`curl -v -H "Host: test.${DOMAIN_CODER}" https://${DOMAIN_CODER}` (oder
äquivalent über SNI) und im Coder-Log prüfen, dass der Original-Host beim
Routing der Subdomain-App ankommt.

Classification:
CONFIRMED

## F-006 – Kommentar suggeriert, nur Wildcard-Subdomains seien On-Demand, tatsächlich gilt das auch für die Root-Domain
Severity:
LOW

Source:
Inference (Caddyfile-Mechanik gemäß offizieller Doku)

Location:
Kopfkommentar `setup-coder.sh` ("Wildcard-Subdomains bekommen ihr Zertifikat
erst bei Bedarf [...] beim allerersten Aufruf einer neuen
Workspace-App-URL dauert das 5-30 Sekunden länger") vs. `Caddyfile`-Block
`${DOMAIN_CODER}, *.${DOMAIN_CODER} { tls { on_demand ... } } }`.

Problem:
Die `on_demand`-Subdirective gilt laut Caddy-Doku für "the hostnames given
in the site block's address(es)" – also für **beide** in diesem einen
Site-Block aufgeführten Adressen gemeinsam, nicht nur für die
Wildcard-Adresse. Der Kommentar im Skript erweckt den Eindruck, als bekäme
nur `*.${DOMAIN_CODER}` sein Zertifikat verzögert, während
`${DOMAIN_CODER}` (die Coder-Dashboard-Domain) implizit sofort/proaktiv
versorgt würde. Tatsächlich wird auch für `${DOMAIN_CODER}` selbst erst beim
allerersten eingehenden TLS-Handshake ein Zertifikat angefordert.

Evidence:
Ein Site-Block in Caddy hat genau eine `tls`-Automation-Policy; diese wird
laut JSON-Doku (`automation/policies`) über `subjects` gefiltert, aber die
`on_demand`-Eigenschaft ist ein Attribut der gesamten Policy, nicht pro
einzelner Adresse innerhalb des Site-Blocks.

Impact:
Rein informativ/dokumentarisch – funktional ändert sich nichts (der
Abschlusscheck in Schritt 10 mit `curl .../healthz` funktioniert unabhängig
davon, ob das Zertifikat proaktiv oder on-demand geholt wurde, und wartet
ohnehin per Retry/erneutem Skriptlauf). Es besteht aber ein
Kommentar-Verhalten-Mismatch gemäß AGENTS.md-Vorgabe ("Keep comments
synchronized with actual behavior").

Proposed change:
Kommentar präzisieren, z. B.: "Sowohl die Haupt-Domain als auch
Wildcard-Subdomains bekommen ihr Zertifikat erst bei Bedarf (der ganze
Site-Block nutzt On-Demand-TLS) – der allererste Aufruf von
`https://${DOMAIN_CODER}` UND jeder neuen Workspace-App-URL dauert dadurch
5-30 Sekunden länger."

Regression risk:
Keiner (reine Kommentaränderung).

Test:
Kein funktionaler Test nötig; Dokumentationsabgleich ausreichend.

Classification:
CONFIRMED

## F-007 – Let's-Encrypt-Rate-Limit-Kommentar ist aktuell und korrekt
Severity:
INFO (Bestätigung, keine Schwachstelle)

Source:
Official documentation (letsencrypt.org/docs/rate-limits, Stand 26.09.2026)

Location:
Kopfkommentar `setup-coder.sh`: "Let's Encrypt begrenzt neue Zertifikate auf
50 pro Woche pro registrierter Domain".

Problem/Klarstellung:
Diese Aussage ist mit dem aktuellen offiziellen Stand von Let's Encrypt
identisch ("Up to 50 certificates can be issued per registered domain [...]
every 7 days.") und nicht veraltet. Wichtige Ergänzung, die im Skript fehlt:
Die "registrierte Domain" im Sinne der Public Suffix List ist hier
`ghse-unterricht.de` (nicht `coder.ghse-unterricht.de`) – das Limit gilt
also gebündelt für **alle** Zertifikate, die für irgendeine Subdomain von
`ghse-unterricht.de` ausgestellt werden, nicht nur für den Coder-Server.
Zusätzlich existiert ein separates, engeres Limit ("New Certificates per
Exact Set of Identifiers": 5 pro 7 Tage für exakt dieselbe Hostnamen-Menge),
das für wiederholte Anfragen für denselben Einzelnamen relevant wird, aber
durch das On-Demand-Modell (jede Subdomain ist ein eigener, einmaliger
Identifier) hier meist unkritisch bleibt.

Evidence:
letsencrypt.org/docs/rate-limits, Abschnitte "New Certificates per
Registered Domain" und "New Certificates per Exact Set of Identifiers".

Impact:
Falls die Schule weitere Dienste unter `ghse-unterricht.de` (oder anderen
Subdomains derselben registrierten Domain) ebenfalls über Let's Encrypt
absichert, teilen sich diese Dienste dasselbe 50er-Wochenkontingent mit dem
Coder-Server – das verschärft F-001 zusätzlich.

Proposed change:
Kommentar um den Hinweis auf die "registrierte Domain" (Public-Suffix-Ebene)
ergänzen, damit klar ist, dass das Kontingent serverübergreifend geteilt
wird, falls unter derselben Domain weitere Let's-Encrypt-Zertifikate laufen.

Regression risk:
Keiner (reine Kommentarergänzung).

Test:
Kein funktionaler Test nötig.

Classification:
CONFIRMED

## Architecture Summary

Der Aufbau folgt exakt dem offiziellen Coder-Referenzmuster für
Docker-Compose-Deployments mit Caddy als TLS-terminierendem Reverse Proxy
(`coder.com/docs/tutorials/reverse-proxy-caddy`): `coderd` (Coder-Container)
verbindet sich mit einer dedizierten Postgres-Instanz
(`CODER_PG_CONNECTION_URL`), Caddy terminiert TLS auf 80/443(+443/udp) und
reicht alle Anfragen unverändert an `coder:3000` weiter. Es handelt sich um
ein Single-Region-/Single-Node-Deployment ohne Workspace-Proxies, ohne
externe Provisioner und ohne High-Availability – für eine einzelne
Schulklasse angemessen dimensioniert. Der Coder-Container erhält zusätzlich
Zugriff auf den Host-Docker-Socket (Docker-basiertes Workspace-Provisioning);
dieser Aspekt ist bereits ausführlich in [02-security.md](02-security.md)
behandelt und wird hier nicht erneut bewertet. WebSockets, die Coder für
Terminal/Web-IDE/Agent-Kommunikation zwingend benötigt, werden von Caddys
`reverse_proxy` transparent unterstützt, ohne dass zusätzliche Konfiguration
nötig wäre.

## TLS Summary

Die Caddyfile-Konfiguration (`on_demand_tls { ask http://example.com }` +
Site-Block mit `tls { on_demand issuer acme { email ... } }`) ist
**funktional korrekt** und entspricht wortgleich dem offiziellen
Coder-Caddy-Tutorial – es handelt sich nicht um eine veraltete oder
Repo-spezifische Fehlkonfiguration. Sie ist jedoch nur **teilweise sicher**:
Das Site-Block-Hostname-Muster verhindert zuverlässig, dass Zertifikate für
komplett fremde Domains angefordert werden (F-001 bestätigt dies technisch),
aber der `ask`-Endpoint selbst führt keine echte Autorisierungsprüfung
gegen tatsächlich existierende Coder-Ressourcen durch – jeder beliebige
Hostname unter `*.${DOMAIN_CODER}` kann von jedem Internet-Teilnehmer ein
echtes Zertifikat auslösen (F-001). Kombiniert mit dem geteilten
50-Zertifikate/Woche-Limit auf Ebene der registrierten Domain
`ghse-unterricht.de` (F-007) ergibt sich ein realistischer
Denial-of-Service-Vektor gegen die Zertifikatsversorgung neuer,
legitimer Workspace-Apps. DNS-Anforderungen (A/AAAA für Root **und**
Wildcard), Portweiterleitung (80 für ACME-Challenges + HTTP→HTTPS-Redirect,
443 tcp/udp) und das Verhalten bei fehlendem DNS/fehlender Portweiterleitung
(Caddy versucht im Hintergrund weiter, Skript meldet nur eine Warnung, kein
harter Fehler) sind vollständig und korrekt dokumentiert. Zertifikate
werden nach einem Neustart von Caddy oder des Hosts nicht neu angefordert,
da `caddy_data` ein persistentes Docker-Volume ist; automatische Erneuerung
erfolgt im Hintergrund rund 30 Tage vor Ablauf, ohne manuelles Eingreifen.

## Coder Summary

`CODER_ACCESS_URL` und `CODER_WILDCARD_ACCESS_URL` sind gemäß aktuellem
Namensschema korrekt gesetzt (`https://${DOMAIN_CODER}` bzw.
`*.${DOMAIN_CODER}`, genau ein `*` am Anfang des Hostnamens, wie von der
aktuellen Dokumentation gefordert). Der Health-Check in Schritt 10 verwendet
mit `/healthz` exakt den Endpoint, den auch Coder selbst intern für die
"Access URL"-Gesundheitsprüfung nutzt. Die Postgres-Abhängigkeit ist über
`depends_on: condition: service_healthy` sauber modelliert. Der einzige
konkrete, gegen aktuelle offizielle Empfehlungen verstoßende Punkt ist das
Fehlen von `CODER_DISABLE_PATH_APPS=true` trotz konfigurierter Wildcard
Access URL (F-002) – dies ist eine explizite, benannte
Production-Best-Practice von Coder selbst und keine Ermessensfrage.

## Top Priorities

1. **F-001** – Echten `ask`-Endpoint einführen (oder auf DNS-01-Wildcard-Zertifikate
   umsteigen), um die aktuell wirkungslose On-Demand-TLS-Autorisierung durch
   eine echte Prüfung gegen existierende Coder-Ressourcen zu ersetzen.
2. **F-002** – `CODER_DISABLE_PATH_APPS=true` setzen, da eine Wildcard Access
   URL bereits konfiguriert ist und die Coder-eigenen Security-Best-Practices
   dies für Produktivbetrieb ausdrücklich verlangen.
3. **F-007** – Kommentar zum Let's-Encrypt-Rate-Limit um den Hinweis auf die
   registrierte Domain (`ghse-unterricht.de`, geteiltes Kontingent mit
   anderen Diensten) ergänzen, damit das Risiko aus F-001 nicht unterschätzt
   wird.
4. **F-006** – Kommentar zur On-Demand-TLS-Verzögerung präzisieren, damit er
   auch die Root-Domain korrekt beschreibt.
