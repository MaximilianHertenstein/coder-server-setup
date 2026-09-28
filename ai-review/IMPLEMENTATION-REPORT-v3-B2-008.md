# IMPLEMENTATION-REPORT-v3-B2-008

Stand: 2026-09-28. Branch: `ai/implementation-v3` (Basis-Commit `13f8a99`).
Umfang: ausschliesslich B2-008 (Port-Preflight ohne Fremd-/Eigen-Trennung).

Grundlagen: `ai-review/PLAN-v3.md` (B2-008, Z.419–460),
`ai-review/PLAN-v3-FINAL-CHECK.md`, `ai-review/FINAL-BREAKER-v2.md` (B2-008).

## Aktuelles Verhalten (vor dem Fix)

`setup-coder.sh` Z.535–539:

```bash
for _p in 80 443 9090 9100 3001; do
  if sudo ss -tlnp 2>/dev/null | grep -Eq ":${_p}([^0-9]|$)"; then
    warn "Port ${_p} belegt (B-013): …"
  fi
done
```

Reiner `ss`-Match ohne Abgleich gegen eigene Compose-Container, nur TCP.

## Problem (LIKELY, Code-Fakt)

Auf einem gesunden Re-Run belegen die eigenen Container 80/443 (Caddy),
9090 (Prometheus), 9100 (node-exporter) und 3001 (Grafana) – das ergab
fünf WARN-Zeilen ohne Informationswert bei jedem Lauf. Echte
Fremd-Konflikte gingen im Rauschen unter; zusammen mit B2-007/B2-002/
Wildcard-WARN verlor die SUMMARY ihre Alarmfunktion. Zusätzlich war
`443/udp` (QUIC) gar nicht geprüft, weil `ss -tlnp` TCP-only ist.

Stelle: `setup-coder.sh` Z.526–544 (Kommentar + Portschleife).

## Umgesetzte Aenderung (Plan Z.433–448, exakte Implementierung)

Neu zwischen Docker-Daemon-Check und Platte-Check (Position unverändert,
also vor `docker compose up -d`):

1. `PORT_CHECK="80/tcp 443/tcp 443/udp 9090/tcp 9100/tcp 3001/tcp"` –
   alle sechs Paare, keiner gestrichen, `443/udp` neu.
2. **Eigene Bindings**: `docker compose ps -q` (Projekt `coder`), pro
   Container `docker inspect --format '{{.Name}}'` mit Filter `coder-*`
   (Plan-Vorgabe; der Service `coder` selbst hat keine Host-Ports und
   bleibt damit korrekt draußen), dann
   `docker inspect --format '{{.HostConfig.PortBindings}}'`. Ein
   awk-Parsing zerlegt das Go-Format
   `map[80/tcp:[{ 80}] 9090/tcp:[{127.0.0.1 9090}]]` in Schlüssel
   `PROTOKOLL|HOST-IP|HOST-PORT`; leere Host-IP (Wildcard) wird auf **v4
   und v6** aufgelöst (`v4*`/`v6*`), `0.0.0.0` → `v4*`, `::` → `v6*`,
   sonst die konkrete IP.
3. **Listener**: getrennte Schleifen `tcp` (`sudo ss -tlnp`) und `udp`
   (`sudo ss -ulnp`); Local-Address wird nach demselben Schema
   normalisiert (`0.0.0.0` → `v4*`, `*` und `::` → `v6*`, `[IPv6]` ohne
   Klammern, Port = alles nach dem letzten `:`).
4. **Vergleich exakt**: Port/Protokoll muss in `PORT_CHECK` stehen, dann
   exakter Zeilenvergleich `PROTOKOLL|HOST-IP|HOST-PORT` gegen die
   eigenen Schlüssel (`grep -qxF`). Nur ein exakter Treffer wird
   unterdrückt; alles andere – auch Port-Gleichheit ohne IP-Gleichheit –
   erzeugt WARN mit Prozessname (Prozessspalte von `ss`, Fallback
   Local-Address).
5. Header-Zeilen (`State …`) und Zeilen ohne `IP:PORT` werden übersprungen;
   Ports außerhalb von `PORT_CHECK` werden ignoriert.

Kommentarblock B-013 (ohne Portteil) und Platte-Check bleiben unverändert,
der alte Portteil des Kommentars wurde entfernt, damit kein Kommentar mehr
das alte Verhalten behauptet.

## Abweichungen vom Planwortlaut

Keine funktional. Detailentscheidungen innerhalb der Plan-Vorgaben:

- Normalisierungsvorschrift `v4*`/`v6*`: Der Plan nennt die Beispiele
  `0.0.0.0:80`, `:::443`, `127.0.0.1:9090`. Neuere `ss`-Versionen
  (iproute2 7.x, auf diesem Arbeitsrechner gemessen) geben IPv6-Wildcards
  als `*:PORT` statt `:::PORT` aus; beide Formen werden auf dieselbe
  `v6*`-Kennung abgebildet, ebenso `:::PORT`. Ohne das würde ein eigener
  v6-Listener als fremd gemeldet.
- Leere Host-IP im `PortBindings` wird zu `v4*` **und** `v6*`, weil Docker
  mit leerer Host-IP auf allen Interfaces publiziert (IPv4 + IPv6).
  Exakter Treffer bleibt trotzdem exakter – ein fremder Listener mit
  anderer IP wird weiterhin gemeldet.
- Der Prozessname wird aus der Prozessspalte von `ss` entnommen; ohne
  lesbare Prozessspalte (kein root) steht die Local-Address als Fallback
  in der WARN.

## Moegliche Regressionen (geprueft, keine offen)

- **Erstlauf (keine eigenen Container, keine Listener auf den Ports)**:
  keine WARN (Fall 1-Variante über Fall 6 abgedeckt; Fall 1 ist der
  Re-Run-Fall).
- **Gesunder Re-Run**: 0 statt 5 WARN (Fall 1, belegt, inkl. UDP).
- **Echte Konflikte bleiben laut**: Fremd-80 (Fall 2), Port gleich/IP
  ungleich auf 9090 (Fall 3), fremdes UDP-443 (Fall 4).
- **Kein breiter Filter**: `grep -qxF` matcht genau eine Zeile; ein
  fremder `0.0.0.0:9090` wird nicht durch den eigenen
  `127.0.0.1:9090` gedeckt (Fall 3).
- **Kein Port gestrichen**: alle sechs Paare im Test gegen die Quelle
  geprüft.
- **Position**: weiterhin vor `docker compose up -d`; auf einem Re-Run
  laufen die eigenen Container bereits, ihre Bindings sind also
  lesbar. Nach `down` (z. B. nach `reset-coder.sh`) gibt es weder
  eigene Bindings noch eigene Listener – Verhalten unverändert korrekt.
- **`set -e`/`pipefail`**: alle optionalen Aufrufe (`compose ps`,
  `inspect`, `ss`) mit `|| true`; der `grep -qxF`-Vergleich steht in
  einer `if`-Bedingung (belegt, Block läuft in der Test-Subshell mit
  `set -euo pipefail`).
- Regressionsstand der anderen Artefakte: unverändert Exit 0.

## Testdefinition

`tests/t-b2-008-port-preflight.sh` (neu, ausführbar, nur `/tmp`, kein
Root, keine Produktion) – STATIC + UNIT-LIKE, 26 Checks. Der komplette
Port-Preflight-Block wird aus `setup-coder.sh` nach Zeilen extrahiert und
mit Fake-`docker`, Fake-`ss` und `sudo`-Shim ausgeführt (echter Code, keine
Kopie); die Fakes protokollieren, welche `ss`-Varianten aufgerufen wurden.

1. Gesunder Re-Run (eigene Bindings 80/443/443-udp v4+v6, Loopback
   9090/9100/3001, dazu sshd/cups auf nicht geprüften Ports) → 0 WARN,
   `ss -tlnp` **und** `ss -ulnp` aufgerufen.
2. Fremder `0.0.0.0:80` ohne eigene Container → genau eine WARN mit
   `nginx` und `80/tcp`.
3. Eigener `127.0.0.1:9090` **und** fremder `0.0.0.0:9090` → genau eine
   WARN (`rogue`), eigener Loopback-Listener unterdrückt.
4. Fremder UDP-Listener `0.0.0.0:443` → eine WARN als `443/udp` mit
   Prozessname (nur über `ss -ulnp` sichtbar – Nachweis, dass der
   UDP-Teil existiert).
5. Container mit exakterm Namen `coder` (ohne `coder-`-Präfix) und
   Binding auf 80 → fremder `0.0.0.0:80` warnt weiterhin (Präfilter greift).
6. Port 9999 → keine WARN.
7. Struktur gegen die Quelle: alle sechs Paare, `ss -tlnp`, `ss -ulnp`,
   `HostConfig.PortBindings`, `docker compose ps -q`, exakter
   Zeilenvergleich, alter roher `ss`-Match entfernt.

Nicht Teil dieses Tests (Plan Z.457–460, Kategorie VM): Re-Run-Probe auf
Test-VM (gesund → keine WARN; Fremd-Listener auf 80, 9090 und UDP 443 →
WARN) mit echtem `ss`/`docker` und laufendem Stack.

# Changed

1. `setup-coder.sh` Z.526–630: B-013-Kommentar ohne Portteil, neue
   B2-008-Sektion mit `PORT_CHECK`, eigenem-Bindings-Sammler
   (`docker compose ps -q` + `inspect`) und TCP-/UDP-Listener-Abgleich;
   alter Port-`for`-Loop entfernt; Platte-Check unverändert an alter
   Position.
2. `tests/t-b2-008-port-preflight.sh` (neu, ausführbar, 26 Checks).
3. `ai-review/IMPLEMENTATION-REPORT-v3-B2-008.md` (neu, diese Datei).

Diff-Kontrolle: `git diff --numstat setup-coder.sh` = 99/8, ausschliesslich
die B2-008-Zonen (Kommentar, Portschleife, Platte-Kontext). Keine Änderung
an `docker info`-Check, an `docker compose config/up -d`, an B2-004,
B2-006, B2-007 oder an früheren Fixes.

# Tests Actually Run

Ausgeführt am 2026-09-28 auf dem Arbeitsrechner (kein Produktionsserver),
Basis-Commit `13f8a99` + Arbeitskopie:

1. `bash -n setup-coder.sh` → ok (PASS, Exit 0).
2. `bash -n tests/t-b2-008-port-preflight.sh` → ok (PASS, Exit 0).
3. `shellcheck -S warning setup-coder.sh` → einziger Befund SC2034
   (`for i in $(seq 1 30)`, Postgres-Wait-Loop, Z.1247, unberührte Zeile),
   identisch zur Baseline: kein neuer Befund.
4. `shellcheck -S warning tests/t-b2-008-port-preflight.sh` → keine
   Befunde (Exit 0).
5. `./tests/t-b2-008-port-preflight.sh` → Exit 0, 26x PASS,
   `T-B2-008: ALLE PRUEFUNGEN BESTANDEN`.
6. Regressionslauf aller bisherigen Artefakte → je Exit 0:
   `./tests/t-071b-headercheck.sh` (B2-001),
   `./tests/t-090-b2-002-tls-gate.sh` (B2-002),
   `./tests/t-b2-003-hex-migration.sh` (B2-003),
   `./tests/t-b2-004-ufw-downgrade.sh` (B2-004),
   `./tests/t-b2-006-reset-precheck.sh` (B2-006),
   `./tests/t-b2-007-drift-hash.sh` (B2-007).

Tool-Versionen: bash 5.3.15, ShellCheck 0.11.0, iproute2-7.1.0
(`ss`-Format-Vorlage), Git-Basis `13f8a99`.

# Results

- Re-Run auf gesundem System → keine Port-WARN (vorher fünf) (belegt).
- Fremder Listener auf 80/tcp → WARN mit Prozessname `nginx` (belegt).
- Fremder Listener auf 9090/tcp bei eigenem `127.0.0.1:9090` → WARN
  (Port gleich, IP ungleich) (belegt).
- Fremder UDP-Listener auf 443 → WARN als `443/udp` über `ss -ulnp`
  (belegt).
- Container ohne `coder-`-Präfix zählt nicht als eigen (belegt).
- Nicht geprüfter Port erzeugt keine WARN (belegt).
- Regressionsstand: B2-001/002/003/004/006/007-Artefakte weiterhin Exit 0.

# Remaining Risk

- VM-Pflicht offen (Plan Z.457–460): Re-Run-Probe mit echtem Stack und
  echtem `ss`/`docker` (gesund, Fremd-80, Fremd-9090, Fremd-UDP-443).
  Besonders zu belegen, dass `docker inspect --format
  '{{.HostConfig.PortBindings}}'` auf dem Zielserver genau das
  Go-Format liefert, das das awk-Parsing erwartet (Leerfeld bei
  Wildcard-IP, mehrere Bindings pro Port) – lokal mangels laufender
  Container nicht ausführbar.
- Falls die Zielmaschine `ss` so ausgibt, dass die Local-Address nicht
  in Feld 4 steht (andere Spaltenordnung als iproute2 7.x), fällt der
  Check still auf „kein Treffer" (keine eigene Unterdrückung → eher mehr
  WARN, kein stilles Übersehen von Fremd-Listenern). Abfangen ließe sich
  das nur mit einem VM-Beleg.
- Echte Fremd-Listener, die über iptables/DNAT ohne Host-Listener
  published sind, bleiben für `ss` unsichtbar – unverändert, bewusst
  nicht Teil von B2-008.

# Files Changed

- `setup-coder.sh` (M, 99/8, nur B2-008-Zonen)
- `tests/t-b2-008-port-preflight.sh` (neu, ausführbar, 26 Checks)
- `ai-review/IMPLEMENTATION-REPORT-v3-B2-008.md` (neu, diese Datei)

# Related Finding

B2-008 (B-013-Preflight-Warnflut)
