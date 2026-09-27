# IMPLEMENTATION-REPORT-v3-B2-002

Stand: 2026-09-27. Branch: `ai/implementation-v3` (Basis-Commit `44c6610`).
Umfang: ausschliesslich B2-002 (TLS-SNI / Update-Gate / Boot-Gate).

Grundlagen: `ai-review/PLAN-v3.md` (B2-002), `ai-review/PLAN-v3-FINAL-CHECK.md`
(PV-014), `ai-review/FINAL-BREAKER-v2.md` (B2-002), `ai-review/07-complexity.md`
(C-004).

## Aktuelles Verhalten (vor dem Fix)

`update.sh`-Gate (`setup-coder.sh`, eingebettetes `update.sh`) und
`boot-check.sh` (`setup-coder.sh`, eingebettetes `boot-check.sh`) fuhren:

```bash
curl -sk --max-time 60 -o /dev/null -w "%{http_code}" -H "Host: ${GATE_DOMAIN}" "https://127.0.0.1/healthz"
curl -sk --max-time 10 -o /dev/null -w "%{http_code}" -H "Host: ${DOMAIN}" "https://127.0.0.1/healthz"
```

## Problem (CONFIRMED per Handshake-Repro, kein Lesungsbefund)

TLS-SNI kommt aus dem URL-Host (`127.0.0.1`), nicht aus `-H Host:`.
Caddy waehlt das Zertifikat per SNI; ohne Treffer kein Zertifikat bzw.
On-Demand-Versuch fuer die IP (LE verweigert IP, Log-Spam +
Failed-Validation-Zaehler). Der Host-Header erreicht den Server nie.

Repro-Beleg (lokal, nur /tmp, Caddy-aequivalenter SNI-Server, s. Test):
altes Muster `curl -sk -H "Host: gate.test.local"
https://127.0.0.1:<PORT>/healthz` -> `code=000 exit=35`
(Handshake-Fehler); `--resolve`-Variante -> `code=200`.
Zusaetzlich sendet curl fuer IP-Literale gar kein SNI (SNI-Log: `None`);
`openssl s_client -servername 127.0.0.1` wird mit Alert 112
(`unrecognized name`) abgewiesen. Perverse Folge: Gate wird nur gruen,
wenn die Apex nicht parsbar ist (WARN-Fallback) – Gesundheit wird bestraft.

## Vorgeschlagene / umgesetzte Aenderung (PLAN-v3 / PV-014, woertlich)

SNI = Domain, Verbindung trotzdem lokal – drei Faelle strikt getrennt:

- SCHRITT 10: NICHT veraendert. Bleibt echter DNS-Pfad, Domain als SNI,
  kein `--resolve`, `--max-time 10` (Referenz, echte DNS-Coverage).
- UPDATE-GATE (single-shot, `--max-time 60` wegen On-Demand-Erstverzoegerung):

```bash
curl -sk --max-time 60 -o /dev/null -w "%{http_code}" \
  --resolve "${GATE_DOMAIN}:443:127.0.0.1" "https://${GATE_DOMAIN}/healthz"
```

- BOOT-GATE (bestehende 30x10-Loop, `--max-time 10`, WARN bei unparsbar):

```bash
curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
  --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz"
```

Keine Stelle verwendet TLS-SNI = 127.0.0.1 mehr. Der veraltete
Host-Header-Kommentar am Update-Gate wurde synchronisiert
(SNI-korrekte `--resolve`-Probe). Fehlermeldung (`via 127.0.0.1`)
bleibt: beschreibt weiterhin zutreffend die lokale Verbindung.

## Moegliche Regressionen (geprueft, keine offen)

- Boot-Loop klemmt / dauert zu lang: ausgeschlossen – Schleife
  (`for _ in $(seq 1 30)`, `sleep 10`, WARN-Fallback, GRUEN/ROT-Auswertung
  auf laufendem `$OUT`) unveraendert, nur die `curl`-Zeile getauscht.
- Schritt 10 verliert Real-Pfad-Coverage: ausgeschlossen – Zeile
  unberuehrt (Test prueft `kein --resolve` + `max-time 10` auf der
  `DOMAIN_CODER`-Zeile).
- 60 s ins Boot-Gate kopiert: ausgeschlossen – Boot bleibt `--max-time 10`
  (Test prueft beide Timeouts getrennt).
- Falsches Gruen bei unparsbarer Apex: unveraendert WARN-statt-Fail
  (kein Fail eingebaut).
- Neue On-Demand-Versuche fuer 127.0.0.1: ausgeschlossen – kein
  `https://127.0.0.1` mehr im Setup (Test: statischer Guard + live
  SNI-Log ohne `127.0.0.1` nach reinen Gate-Proben).

## Testdefinition (T-090)

`tests/t-090-b2-002-tls-gate.sh` (ausfuehrbar, nur /tmp): statische Guards
(beide `--resolve`-Zeilen mit korrekten Timeouts, kein
`https://127.0.0.1/healthz`, kein Host-Header gegen 127.0.0.1, Schritt 10
ohne `--resolve` mit max-time 10, 30x-Loop erhalten) plus echter
TLS-Handshake gegen einen Caddy-aequivalenten Python-Testserver
(SNI-Callback: nur erwartete Domain bekommt Zertifikat, sonst Alert 112
`unrecognized name`; SNI wird geloggt; Cert nur mit Domain-SAN, kein
IP-SAN): altes Muster muss scheitern (000/35, SNI != Domain),
neue Update- und Boot-Proben muessen 200 liefern, SNI-Log muss Domain
enthalten und kein `127.0.0.1`, `openssl s_client` mit Domain-SNI muss
Zertifikat liefern und mit IP-SNI abgewiesen werden, gestoppter Server
muss fuer beide Gates ROT liefern. Testport statt 443;
`--resolve`-Semantik (SNI + Host = Domain, Verbindung lokal) identisch.
Boot-Loop live als Einzelprobe (volle 30x10 = 5 Min als Live-Test nicht
sinnvoll; Loop-Struktur statisch verifiziert).

# Changed

1. `setup-coder.sh` (Boot-Gate, +1/−1): `curl`-Zeile auf
   `--resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/healthz"`.
2. `setup-coder.sh` (Update-Gate, +5/−4): Kommentar synchronisiert +
   `curl`-Zeile auf
   `--resolve "${GATE_DOMAIN}:443:127.0.0.1" "https://${GATE_DOMAIN}/healthz"`.
   Schritt 10 und alle anderen Zeilen unberuehrt.
3. `tests/t-090-b2-002-tls-gate.sh` (neu): T-090-Harness (s. o.).

# Tests Actually Run

Ausgefuehrt am 2026-09-27 auf dem Arbeitsrechner (kein Produktionsserver,
kein Docker noetig, nur /tmp), Commit `44c6610` + Arbeitskopie-Aenderung:

1. `bash -n setup-coder.sh` -> `SETUP_SYNTAX_OK` (PASS).
2. `bash -n tests/t-090-b2-002-tls-gate.sh` -> ok (PASS).
3. `shellcheck -S warning setup-coder.sh` -> einziger Befund SC2034
   (`for i in $(seq 1 30)`, Postgres-Wait-Loop, unberuehrte Zeile).
   Vorbestand (gleicher Befund bereits im B2-001-Report auf Basis-Stand);
   `git diff` belegt: nur Gate-Hunks geaendert. Kein neuer Befund (PASS
   mit dokumentiertem Vorbestand).
4. `shellcheck -S warning tests/t-090-b2-002-tls-gate.sh` -> keine
   Befunde (PASS).
5. Extrahierte Heredocs (`awk`-Extrakt `boot-check.sh` 54 Zeilen,
   `update.sh` 98 Zeilen): je `bash -n` ok; `boot-check.sh` ShellCheck
   sauber; `update.sh` nur derselbe SC2034-Vorbestand (PASS).
6. `./tests/t-090-b2-002-tls-gate.sh` (3x Laeufe, deterministisch) ->
   Exit 0, je 16x PASS (PASS). Ein Lauf im Wortlaut:
   `Boot-Gate SNI-korrekt`, `Update-Gate SNI-korrekt`,
   `kein https://127.0.0.1/healthz mehr`,
   `kein Host-Header gegen 127.0.0.1 mehr`, `Schritt 10 unveraendert`,
   `Boot-Poll-Schleife 30x erhalten`,
   `altes Host-Header-Muster scheitert (code=000, exit=35)`,
   `altes Muster sendet SNI != Domain (SNI-Log: None)`,
   `Update-Gate gesund -> 200 / GRUEN`,
   `Boot-Gate gesund -> BOOT-GATE GRUEN`,
   `TLS-SNI ist Domain (gate.test.local)`,
   `kein 127.0.0.1-SNI durch Gate-Proben`,
   `openssl Domain-SNI liefert Zertifikat CN=gate.test.local`,
   `openssl IP-SNI abgewiesen (unrecognized name, Alert 112)`,
   `Update-Gate krank -> ROT (code=000)`,
   `Boot-Gate krank -> BOOT-GATE ROT (code=000)`,
   `T-090/B2-002: ALLE PRUEFUNGEN BESTANDEN`.

Tool-Versionen: bash 5.3.15, OpenSSL 3.5.3, curl 8.22.0, ShellCheck
0.11.0, Python 3.13.15.

Nicht ausgefuehrt (ausserhalb B2-002-Umfang / Test-VM-Pflicht):
Full-Stack-Gates gegen echten Caddy (gesunder Stack -> 200, gestoppter
Coder -> rot auf Test-VM), Caddy-Log-Grep (`obtaining certificate` ohne
`127.0.0.1`), Reboot-/Update-E2E (T-091/T-110/T-110-rot auf VM,
B-021-Handshake-Serie). Kein „bestanden“ dafuer behauptet.

# Results

- Gesundes Update-Gate -> HTTP 200 / GRUEN (echter Handshake).
- Kranker Zustand (Server gestoppt) -> ROT fuer Update- und Boot-Gate.
- Gesunder Boot -> BOOT-GATE GRUEN; kranker Boot -> BOOT-GATE ROT.
- TLS-SNI ist die Domain (SNI-Log + openssl-Zertifikatsnachweis).
- Keine 127.0.0.1-On-Demand-Versuche durch die Gate-Proben (SNI-Log ohne
  `127.0.0.1`; statisch kein `https://127.0.0.1` mehr im Setup).
- Schritt 10 unveraendert (echter DNS-Pfad als Referenz erhalten).
- Diff-Kontrolle: `git diff --stat` zeigt nur `setup-coder.sh`
  (+6/−5); keine ungeplanten/kosmetischen Aenderungen, keine neuen
  Abstraktionen, keine Abhaengigkeiten.

# Remaining Risk

- Echte Caddy-Gates (Test-VM mit Testdomain, LE-Budget schonen):
  T-090/T-091/T-110/T-110-rot + Caddy-Log-Grep vor Production-Freigabe
  nachholen (PLAN-v3 Phase C, Stop-Regel).
- Uebrige B2-Fixes (B2-003 ff.), Offsite/RTO (B-008), D-Entscheidungen
  sind ausserhalb dieses B2-002-Scopes und bleiben offen.
- Kein Blocker durch diese Aenderung verursacht; keiner noetig
  ausserhalb des erlaubten Umfangs (keine Erweiterung vorgenommen).

# Files Changed

- `setup-coder.sh` (M, +6/−5, nur B2-002-Gate-Zeilen + Kommentar)
- `tests/t-090-b2-002-tls-gate.sh` (neu, ausfuehrbar)
- `ai-review/IMPLEMENTATION-REPORT-v3-B2-002.md` (neu, diese Datei)

# Related Finding

B2-002
