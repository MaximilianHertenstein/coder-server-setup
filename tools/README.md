# Klassen-Accounts anlegen und löschen

`create-class-accounts.sh` legt für eine Klasse Coder-Konten an und erzeugt
ein druckbares PDF mit Benutzername, E-Mail und Passwort.
`delete-class-accounts.sh` löscht eine Klasse samt Workspaces wieder.
Beide Skripte laufen auf dem Rechner des Betreibers, nicht auf dem Server.

## Voraussetzungen

- `curl`, `jq`, `typst`
- Ein **Owner-Token** auf dem Schulserver, nur für den Lauf:

```bash
coder login https://coder.ghse-unterricht.de
coder tokens create -n klasse-10a --lifetime 1h
```

- Danach den Token wieder löschen: `coder tokens rm <id>`.
- Erreichbarkeit: `https://coder.ghse-unterricht.de/healthz` muss 200
  liefern. Aus dem Schulnetz kann Hairpin-NAT fehlen
  ([TROUBLESHOOTING B6](../TROUBLESHOOTING.md)); dann von außen ausführen.

## Aufruf

```bash
./tools/create-class-accounts.sh
```

```
Klassenname (z. B. 10a): 10a
Anzahl der Schülerinnen und Schüler: 25
Owner-Token (Eingabe bleibt unsichtbar):
```

Das Skript fragt nach Klassenname, Anzahl der Schülerinnen und Schüler und
dem Owner-Token; die Token-Eingabe bleibt unsichtbar und landet nicht in der
Shell-History. Alternativ lassen sich Klasse und Anzahl als Flags übergeben
und der Token über `CODER_SESSION_TOKEN` setzen (für Automatisierung).

```bash
./tools/create-class-accounts.sh --class 10a --count 25
```

Ergebnis: Konten `10a-01` bis `10a-25`, E-Mails `10a-01@ghse.de`,
jeweils ein zufälliges Passwort (14 Zeichen, ohne `0/O`, `1/l/I`). Das PDF
liegt im aktuellen Verzeichnis und hat die Rechte `600`.

Das PDF enthält pro Seite höchstens 16 Konten, angeordnet als zwei Spalten
mit je acht Kästen. Jeder Kasten zeigt Benutzername, E-Mail und Passwort
und ist durch etwa 5 mm Abstand vom nächsten getrennt, sodass sich die
Zettel sauber auseinanderschneiden lassen. Bei genau 16 Konten nutzt das
Raster die Seite bis zum Rand aus; die Kästen werden dafür höher. Bei mehr
als 16 Konten beginnt eine neue Seite mit derselben Kopfzeile, die letzte
Seite bleibt entsprechend kürzer.

Erst testen, ohne etwas anzulegen:

```bash
./tools/create-class-accounts.sh --dry-run
```

Das Vorschau-PDF ist als solche markiert und enthält keine echten Konten.
Der Server ist per Default `https://coder.ghse-unterricht.de`; mit
`CODER_URL` lässt sich ein anderer Coder ansprechen.

### Optionen

| Option | Bedeutung |
|---|---|
| `--class <name>` | Klassenname, z. B. `10a` (sonst Abfrage) |
| `--count <n>` | Anzahl der Konten, 1–200 (sonst Abfrage) |
| `--email-domain <d>` | Domain der E-Mails, Default `ghse.de` |
| `--reset` | Vorhandene Konten mit neuen Passwörtern versorgen |
| `--dry-run` | Keine API-Aufrufe, nur ein Vorschau-PDF |
| `--out <dir>` | Zielverzeichnis für das PDF |
| `--help` | Hilfe |

## Was die Konten bekommen

- Benutzername `<klasse>-<nummer>`, z. B. `10a-01`
- Login-Typ `password`, Status `active`
- Rolle `member`, Mitglied der Default-Organisation
- Keine Template-Admin- oder Owner-Rechte

Die E-Mail-Adresse ist nur ein eindeutiger Bezeichner. Coder verschickt
keine Mails (kein SMTP); das Postfach muss nicht existieren. Wenn die
Schule später Benachrichtigungen über E-Mail einführt, ist eine Domain mit
Zustellung sinnvoll.

## Wiederholte Läufe

- Ohne `--reset` werden vorhandene Konten übersprungen und erscheinen
  **nicht** im PDF (es gibt kein Passwort im Klartext).
- Mit `--reset` bekommen vorhandene Konten ein neues Passwort und stehen
  wieder im PDF. Das ist der Weg, wenn das PDF verloren gegangen ist.
- Vorhandene Konten behalten ihre E-Mail-Adresse. Weicht sie von der
  gewünschten Domain ab, warnt das Skript und druckt die tatsächliche
  Adresse aus Coder ins PDF. `--email-domain` wirkt nur auf neue Konten.
- Der Klassenname muss eindeutig bleiben. Wird dieselbe Klasse in einem
  späteren Schuljahr wiederverwendet, entweder die alten Konten löschen
  oder einen eigenen Namen vergeben (`10a-2026`).

## Sicherheit

- Das PDF enthält **Klartext-Passwörter**. Es wird mit `600` angelegt;
  nicht ins Repository, nicht in Cloud-Speicher, nach dem Verteilen
  löschen (Papier schreddern).
- Der Owner-Token wird beim Start unsichtbar abgefragt oder per
  `CODER_SESSION_TOKEN` übergeben; nicht in eine Datei im Repo schreiben.
  Das Skript übergibt ihn per curl-Konfigurationsdatei (`600`) und die
  Passwörter per stdin, damit sie nicht in `ps` stehen.
- Der Token wird im Skript nicht ausgegeben.

## Klasse löschen

`delete-class-accounts.sh` löscht alle Konten `<klasse>-<nummer>` samt
ihren Workspaces. Die Löschung ist endgültig und nicht umkehrbar.

```bash
./tools/delete-class-accounts.sh
```

```
Klassenname (z. B. 10a): 10a
Owner-Token (Eingabe bleibt unsichtbar):
Konten der Klasse 10a auf https://coder.ghse-unterricht.de:
  10a-01 ...
Zum endgültigen Löschen "10a" eingeben: 10a
```

Erst ansehen, ohne etwas zu ändern:

```bash
./tools/delete-class-accounts.sh --class 10a --dry-run
```

Ablauf:

1. Konten werden exakt nach dem Muster `<klasse>-<nummer>` gesucht; es
   werden keine ähnlichen Namen oder Präfixe gelöscht.
2. Owner-Konten, Service-Accounts und das eigene Konto verweigert das
   Skript.
3. Die Konten werden gesperrt, damit während des Aufräumens keine neuen
   Workspaces entstehen.
4. Alle Workspaces der Konten werden gelöscht; das Skript wartet auf den
   Abschluss der Lösch-Builds.
5. Erst danach werden die Konten gelöscht.

| Option | Bedeutung |
|---|---|
| `--class <name>` | Klassenname, z. B. `10a` (sonst Abfrage) |
| `--dry-run` | Nur anzeigen, was gelöscht würde |
| `--yes` | Bestätigung überspringen (nur für Automatisierung) |
| `--timeout <sek>` | Zeitlimit für Workspace-Löschungen, Default `600` |
| `--help` | Hilfe |

Ein Lauf ohne Treffer endet ohne Fehler. Bricht ein Lauf nach dem Sperren
ab (Zeitlimit, Fehler beim Workspace-Abbau), bleiben die Konten gesperrt;
ein erneuter Lauf setzt die Löschung fort. Einzelne Konten lassen sich
weiterhin mit `coder users suspend` sperren und mit `coder users delete`
löschen.

## Konten später verwalten

```bash
coder users list
coder users suspend <name>      # sperren, z. B. nach dem Schuljahr
coder users delete <name>       # löschen (Workspaces vorher aufräumen)
```

Ein suspendiertes Konto kann sich nicht anmelden; die Workspaces bleiben
erhalten. Vor dem Löschen die Workspaces des Kontos löschen.
