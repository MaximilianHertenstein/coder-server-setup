# IMPLEMENTATION-REPORT-v3-B2-004

Stand: 2026-09-28. Branch: `ai/implementation-v3` (Basis-Commit `25e7ee9`).
Umfang: ausschliesslich B2-004 (Re-Run-Downgrade nur explizit).

Grundlagen: `ai-review/PLAN-v3.md` (B2-004, Z.251–342; PV-009),
`ai-review/PLAN-v3-FINAL-CHECK.md` (Bypass-Syntax, PV-009-Hinweis),
`ai-review/FINAL-BREAKER-v2.md` (B2-004).

## Aktuelles Verhalten (vor dem Fix)

`setup-coder.sh` Z.579–600: Detektor
`sudo ufw status | grep -Eq "22/(tcp|ssh).*(ALLOW|LIMIT).*([0-9]{1,3}\.)"`,
bei Treffer nur `warn`, danach drei `ufw --force delete …`-Zeilen und
`sudo ufw limit 22/tcp` – weltweit. Kein Abbruch, kein Opt-out, keine
Wiederherstellung.

## Problem (CONFIRMED, Breaker-Repro belegt)

1. Detektorlücke: `22 ALLOW 192.168.1.0/24` (reales `ufw status`-Format ohne
   `/tcp`) wird nicht gematcht, `22/tcp ALLOW 10.16.0.0/12` (with `/tcp`)
   dagegen schon. Die restriktive Regel überlebt die drei `delete`-Zeilen
   nicht zuverlässig, `limit 22/tcp` steht weltweit daneben.
2. Selbst bei Treffer gab es nur eine Warnung – die Härtung wurde still
   entfernt (Warn → Löschen → weltweit öffnen, ohne Abbruch).

Stelle: `setup-coder.sh` Z.579–585 (Detektor/Warn) und Z.670–680
(delete + `limit 22/tcp`).

## Umgesetzte Aenderung (Plan Z.266–325, wörtlicher Detektor, kein neuer Mechanismus)

Block zwischen `ufw default allow outgoing` und `limit 22/tcp`:

1. `UFW_OUT` wie gefordert (Pfad-C-Fallback `Status: inactive` bei
   Fehlschlag beider `ufw status`-Varianten).
2. Zweistufiger Detektor **wörtlich** aus dem Plan (POSIX `grep -Ei` +
   `grep -Ev '[[:space:]]Anywhere([[:space:]\(]|$)'`), nur der finale
   `grep -q .` wurde durch das Speichern der Ausgabe ersetzt, damit die
   erste restriktive Zeile für Abbruchtext und Wiederherstellung benutzt
   werden kann. Semantik identisch (`-n` != "" ≡ `| grep -q .`).
3. **Pfad C zuerst** (`Status:[[:space:]]*inactive`): kein Abbruch, `warn`
   als Hinweis, ufw-Setup-Pfad fährt fort.
4. **Pfad B** (Kandidat minus `Anywhere` nicht leer):
   - `sudo ufw status numbered | sudo tee <TS>.before.log` – vor jedem
     Löschen;
   - ohne Bypass: harter `exit 1` mit Anleitung (Befundzeile, Pfad der
     `before.log`, Bypass-Befehl in beiden Aufrufvarianten, Hinweis „es
     wurde bisher nichts gelöscht", Anleitung ohne Bypass);
   - mit exakt `CODER_ALLOW_SSH_DOWNGRADE=yes`: `NOTED_SRC` (Quelle) und
     Aktion werden **wörtlich aus `before.log`** gelesen und validiert;
     ungültige Quelle → ebenfalls `exit 1` vor dem Löschen (keine
     Wiederherstellung ohne gesicherte Quelle); dann `warn` mit Befund.
5. **Pfad A** (nur `Anywhere`-Zeilen bzw. keine SSH-Regel): kein Abort,
   kein Eintrag, delete/`limit`-Verhalten unverändert.
6. **Restore** direkt nach `sudo ufw limit 22/tcp`:
   `sudo ufw "${UFW_RESTORE_ACTION}" from "${UFW_RESTORE_SRC}" to any port
   22 proto tcp`, danach `sudo tee <TS>.after.log` und
   `grep -F -- "${UFW_RESTORE_SRC}" <TS>.after.log` – ohne Treffer
   `fail` + `exit 1` (kein stilles Grün).

Die drei `delete`-Zeilen, der `limit 22/tcp`-Aufruf, der
Bindungsregel-Kommentar und der Review-Check bleiben unverändert.

## Abweichungen vom Planwortlaut (dokumentiert)

1. **`sudo tee` statt `tee`** in beiden Protokollzeilen: `tee` als
   aufrufender Benutzer darf nach `/var/log` nicht schreiben; unter
   `set -e`/`pipefail` würde `before.log` scheitern, noch vor dem
   Löschen. `sudo tee` ist die einzige funktionsfähige Variante.
   (Plan-Snippet Z.312/316 schreibt `tee`; Korrektur ist rein
   rechtebedingt, Inhalt identisch.)
2. **`NOTED_SRC`-Extraktion implementiert** – der Plan lässt den Platz-
   halter `<Quelle wörtlich aus before.log>` offen. Umsetzung: Quelle =
   letztes Feld der ersten restriktiven Zeile (bzw. der
   `from <src> to any port 22`-Form, sofern sie zuerst auftaucht),
   Aktion = `ALLOW|LIMIT|DENY|REJECT`-Token der Zeile. Beide Werte gehen
   unverändert in den Restore-Aufruf.
3. **PV-009 (Hinweis aus `PLAN-v3-FINAL-CHECK.md` Z.682–685)
   umgesetzt**: Restore verwendet die notierte Aktion
   (`limit` → `ufw limit from …`, `deny` → `ufw deny from …`), nicht
   pauschal `allow`. Fehlt ein Aktions-Token (nur bei der
   `from … to any port 22`-Form), greift der Plan-Default `allow`.
4. **Zusätzliche Quell-Validierung vor dem Löschen**: ohne
   `^[A-Za-z0-9][A-Za-z0-9._:/-]*$`-Form (und ohne Aktions-Wörter als
   Quelle) wird vor dem Löschen abgebrochen. Das ist eine Ausweitung des
   Plans „kein Auto-Restore ohne Verifikation" um eine Prüfung *vor* dem
   Downgrade-Fenster; ohne sie stünde das `ufw allow from <Unsinn>`
   ohnehin erst nach dem Löschen. Der Bypass kann diese Prüfung nicht
   überspringen.

Kein neuer Bypass, keine zweite Syntax, keine neue Abstraktion, kein
Helper über Heredoc-Grenzen.

## Moegliche Regressionen (geprueft)

- **Erster Lauf / inaktives UFW**: Pfad C, kein Abbruch, Setup fährt fort
  (belegt). Vorher Verhalten identisch, nur statt „kein Eintrag" jetzt ein
  `warn`-Hinweis (siehe Restpunkte).
- **Standard-Re-Run (`22/tcp LIMIT Anywhere`)**: Pfad A, kein Abort, kein
  zusätzlicher Output, delete/`limit` unverändert (belegt).
- **80/443/2222/122**: keine Fehltreffer, auch nicht in Stufe 1 (belegt).
- **Bestehende Tests**: B2-001/B2-002/B2-003/B2-006/B2-007 unberührt,
  weiterhin Exit 0.
- **`set -e`-Pfaddifferenz**: `UFW_RESTRICTED`-Auflösung endet mit
  `|| true`; bei leerer Ausgabe kein vorzeitiger Abbruch (belegt über
  Pfad-A/C-Fälle).
- **Order**: `exit 1` des Bypass-Gates steht vor den `delete`-Zeilen
  (belegt, Zeilenvergleich im Test).

## Testdefinition

`tests/t-b2-004-ufw-downgrade.sh` (neu, ausführbar, nur `/tmp`, kein Root,
keine Produktion) – STATIC + UNIT-LIKE, 61 Checks:

- **Extraktion der echten Fragmente aus `setup-coder.sh`**: Stufe-1-,
  Stufe-2-, Pfad-C- und Aktions-Muster; Extrahieren des kompletten
  Gate-Blocks und des Restore-Blocks nach Zeilennummer; `bash -n` auf beiden
  Extrakt. Der Test läuft damit das reale Code-Stück, nicht eine Kopie.
- **Pflicht-Fixtures (Plan Z.287–295) gegen beide Stufen**:
  restriktiv (`22/tcp ALLOW 10.16.0.0/12`, `22 ALLOW 192.168.1.0/24`,
  `OpenSSH ALLOW 10.0.0.0/8`, `[ 1] … ALLOW IN …`, `(v6)`-Zeile mit
  IPv6-Quelle, `allow from … to any port 22`, `22/tcp LIMIT 192.168.1.5`);
  weltweit (vier Zeilen → kein Treffer); Negativ (`80/tcp`, `443/tcp`,
  `2222/tcp`, `122` → schon in Stufe 1 kein Match).
- **Verhalten des extrahierten Gates** mit `sudo`-Shim und Fake-`ufw`
  (Ausgabe/Rückcode steuerbar): Pfad A (weltweit, nur 80/443) → rc 0,
  kein Restore, keine Warnung; Pfad C (`Status: inactive` und
  `ufw` fehlt/`rc=127`) → rc 0 + Hinweis; Pfad B ohne Bypass → rc 1,
  Befundzeile, Bypass-Anleitung, „nichts gelöscht", `before.log`
  geschrieben, kein Weiterlauf; Pfad B + `yes` → rc 0 mit
  `SRC=[192.168.1.0/24] ACTION=[allow]` (alte False-Negative-Form),
  Warnung, `before.log`; Bypass `YES`/`yes `/`true` → jeweils rc 1;
  LIMIT-Fixtur → `ACTION=[limit]` (PV-009); `(v6)`-Fixtur →
  `SRC=[fd00::/8]`; `from … to any port 22` → `SRC=[10.16.0.0/12]`.
- **Verhalten des extrahierten Restore-Blocks**: mit Treffer in der Fake-
  `after.log` → rc 0 + OK-Meldung + protokollierter
  `allow from 192.168.1.0/24 to any port 22 proto tcp`-Aufruf; ohne
  Treffer → rc 1, Fehlermeldung, kein Weiterlauf.
- **Struktur**: `exit 1` vor den delete-Zeilen (Zeilenvergleich),
  alter Detektor nicht mehr benutzt, alte reine Warnung entfernt,
  Pfad C vor Pfad B, zwei `sudo tee`, Restore-Aktion nicht hart kodiert,
  Bypass-Vergleich exakt `!= "yes"`.

Nicht Teil dieses Tests (Plan Z.336–342, Kategorie VM): T-062 plus
Re-Run-Downgrade-Probe mit echtem `ufw` auf Test-VM (reale
`ufw status`-Zeilen, tatsächliches Löschen/Wiederherstellen,
`numbered`-Ausgabe, IPv6-Regeln, Bypass-Lauf mit Protokoll).

# Changed

1. `setup-coder.sh` Z.579–665: alte Warn-Zeile ersetzt durch den
   zweistufigen B2-004-Detektor mit Pfad C / Pfad B / Pfad A, `before.log`,
   Abbruchtext und Bypass-Parsing.
2. `setup-coder.sh` nach `sudo ufw limit 22/tcp`: Restore-Block mit
   `after.log` und `grep -F`-Verifikation (sonst `exit 1`).
3. `setup-coder.sh` Kommentar zu `limit 22/tcp` und zu den delete-Zeilen:
   B2-004-Verhalten beschrieben (Kommentare synchron gehalten).
4. `tests/t-b2-004-ufw-downgrade.sh` (neu, ausführbar, 61 Checks).
5. `ai-review/IMPLEMENTATION-REPORT-v3-B2-004.md` (neu, diese Datei).

Diff-Kontrolle: `git diff --numstat setup-coder.sh` = 102/6, ausschliesslich
der B2-004-Zonen (alte Warnung raus, neuer Gate-Block, Restore-Block,
zwei Kommentare). Keine Änderung an `default deny/allow`, an den
delete-Zeilen, an `limit 22/tcp`, an fail2ban, an B2-006/B2-007 oder an
früheren Fixes.

# Tests Actually Run

Ausgeführt am 2026-09-28 auf dem Arbeitsrechner (kein Produktionsserver),
Basis-Commit `25e7ee9` + Arbeitskopie:

1. `bash -n setup-coder.sh` → ok (PASS, Exit 0).
2. `bash -n tests/t-b2-004-ufw-downgrade.sh` → ok (PASS, Exit 0).
3. `shellcheck -S warning setup-coder.sh` → einziger Befund SC2034
   (`for i in $(seq 1 30)`, Postgres-Wait-Loop, Z.1156, unberührte Zeile),
   identisch zur Baseline: kein neuer Befund.
4. `shellcheck -S warning tests/t-b2-004-ufw-downgrade.sh` → keine
   Befunde (Exit 0).
5. `./tests/t-b2-004-ufw-downgrade.sh` → Exit 0, 61x PASS,
   `T-B2-004: ALLE PRUEFUNGEN BESTANDEN`.
6. Regressionslauf aller bisherigen Artefakte → je Exit 0:
   `./tests/t-071b-headercheck.sh` (B2-001),
   `./tests/t-090-b2-002-tls-gate.sh` (B2-002),
   `./tests/t-b2-003-hex-migration.sh` (B2-003),
   `./tests/t-b2-006-reset-precheck.sh` (B2-006),
   `./tests/t-b2-007-drift-hash.sh` (B2-007).

Tool-Versionen: bash 5.3.15, ShellCheck 0.11.0, Git-Basis `25e7ee9`.

# Results

- Pfad A (weltweit offen, `22/tcp LIMIT Anywhere` / `ALLOW Anywhere`,
  `OpenSSH ALLOW Anywhere`) → kein Abort, Lauf läuft weiter, keine
  Wiederherstellung, keine Warnung (belegt).
- Pfad B (`22 ALLOW 192.168.1.0/24`, alte False-Negative-Form) ohne Bypass
  → Exit 1 mit Anleitung, `before.log` geschrieben, keine der delete-Zeilen
  erreicht (belegt).
- Pfad B mit exakt `CODER_ALLOW_SSH_DOWNGRADE=yes` → Lauf läuft weiter,
  Quelle wörtlich aus `before.log` notiert, nach dem Lauf
  `ufw <Aktion> from <Quelle> …` ausgeführt und per `grep -F` in
  `after.log` verifiziert; ohne Treffer Exit 1 (belegt).
- Aktion quellengetreu (`limit`/`allow`), IPv6- und `numbered`-Formen
  extrahiert korrekt (belegt).
- Pfad C (`Status: inactive` bzw. `ufw` fehlt) → kein Abort, Hinweis,
  Setup-Pfad läuft weiter (belegt).
- Negativ-Fixtures `80/tcp`, `443/tcp`, `2222/tcp`, `122` treffen den
  Detektor nicht (belegt).
- Regressionsstand: B2-001/002/003/006/007-Artefakte weiterhin Exit 0.

# Remaining Risk

- VM-Pflicht offen (Plan Z.336–342): T-062 + Re-Run-Downgrade-Probe mit
  echtem `ufw` (regeln anlegen/löschen/wiederherstellen, reale
  `ufw status`-Zeilen, IPv6, `numbered`). Besonders zu belegen:
  `ufw <allow|limit> from <src> to any port 22 proto tcp` akzeptiert die
  Syntax in der ausgelieferten ufw-Version (Pfadbefehl ist absichtlich
  quellengetreu; bei Ablehnung fällt `set -e` sauber aus, aber erst nach
  dem Downgrade-Fenster).
- Pfad C erzeugt auf einem sauberen Erstlauf einen `warn`-Eintrag
  („ufw ist inaktiv"), weil nur `ok`/`warn`/`fail` existieren und ein
  neuer `hinweis`-Helper eine neue Abstraktion wäre. Er ist zum Zeitpunkt
  des Aufrufs wahr und verschwindet nach `ufw --force enable` beim nächsten
  Lauf. Nicht blockierend, aber bei SUMMARY-Review zu kennen.
- Weitere geplante Pfad-B-Fixtures ohne eigenen Datensatz (z. B.
  `22/tcp LIMIT 192.168.1.5` als *einzige* Zeile) sind über die
  Einzelfixtures abgedeckt, aber nicht als vollständiger `ufw status`-Dump
  ausgeführt worden.

# Files Changed

- `setup-coder.sh` (M, 102/6, nur B2-004-Zonen)
- `tests/t-b2-004-ufw-downgrade.sh` (neu, ausführbar, 61 Checks)
- `ai-review/IMPLEMENTATION-REPORT-v3-B2-004.md` (neu, diese Datei)

# Related Finding

B2-004 (B-007-Re-Run-Downgrade, PV-009)
