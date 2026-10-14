# RESTORE.md – Wiederherstellungs-Runbook

Status: Verfahren festgelegt (Pfad A/B), manuell. **Pfad A ist vollständig
geprobt** (2026-10-01 auf dem Test-Host `2.29.11.30`): Datenprobe `1`,
RTO **1 min 50 s** ohne VM-Boot (Details unten „Wiederholungspflicht").
**Nicht erfüllbar auf dem Test-Host:** der `/healthz`-TLS-Smoke, solange
die Domain auf eine fremde IP zeigt – ein grüner `/healthz` ist erst am
echten Zielserver belegbar. **Weiter offen:** RTO inklusive
VM-Boot/Paketinstallation (braucht eine frische VM) und Browser-Login am
Dashboard. **Nie auf Produktion üben, nur auf isolierter Test-VM.**

## Was gesichert wird – und was nicht (P-024, ehrlich)

- Gesichert (täglich, verifiziert per `gzip -t`): Postgres-Dump
  (`/opt/coder/backups/coder_*.sql.gz`, neueste 14, lokal auf derselben Platte).
- Gesichert (neben dem Dump, bei jedem Backup-Lauf erneuert): `.env`-Kopie
  `/opt/coder/backups/coder.env` (600, aktueller Stand aller Passwörter –
  lokal, **kein** Offsite).
- NICHT gesichert: Compose-/Caddy-/Prometheus-Config
  (entstehen per Setup-Re-Run neu), Caddy-Zertifikate (Caddy stellt neu aus),
  Grafana-Dashboards (das Setup-Provisioning legt sein Dashboard neu an;
  UI-eigene Dashboards exportieren oder Verlust akzeptieren),
  Prometheus-Historie
  (15 d, verzichtbar), Workspace-Dateien (Unterrichtsdaten!).
- **Was das nach einem Restore heißt:**
  - `caddy_data` (ACME-Kontostand, Zertifikate) fehlt auf frischer VM –
    Caddy stellt automatisch neu aus (Erstverzögerung 5–30 s, B3). Mehrere
    Restore-Versuche hart hintereinander können das Let's-Encrypt-Duplikat-
    Limit (5/Woche) erreichen – Restores nicht probeweise wiederholen,
    vorher kurz `docker logs coder-caddy` prüfen.
  - Workspace-Homes/-Dateien stehen **nur** in den Workspace-Volumes der
    Alt-Installation. Bei VM-/Plattenverlust ohne VM-Backup sind sie weg,
    der Dump hilft nicht. **Entschieden 2026-10-08:** die Homes werden über
    das Proxmox-VM-Backup (vzdump 02:00, idealerweise auf anderem
    Storage/Host) mitgesichert – separate Volume-Sicherung entfällt,
    Restverlust ≤ 1 Schultag (Snapshot-Stand). Voraussetzung: VM-Backup
    läuft tatsächlich; beim Einrichten einmal prüfen, dass die Homes
    wirklich in Docker-Volumes liegen.
- Offsite-Kopie: lokal nach wie vor **nur** auf demselben Host. **Weg
  entschieden 2026-10-08:** (a) vzdump/PBS-Ziel auf anderem Storage/Host,
  (b) monatlicher `rsync`-Pull `/opt/coder/backups` vom Betreiber-Rechner
  auf externe Platte, verschlüsselt (Dumps enthalten Tokens/Nutzerdaten).
  Bis zur Umsetzung gilt weiterhin: Platten-/Hostverlust = DB + alle
  lokalen Backups weg.

## Voraussetzungen (Eingangs-Gates, harter Abbruch bei Fehlen)

1. Gültiger Dump (`gzip -t` grün, Größe plausibel, T-080-Mini-Restore ok).
2. `.env`-Ersatz: entweder eine separat auf die Restore-VM übertragene
   `.env`-Kopie (zum Beispiel `.env.bak.*` oder verschlüsseltes Offsite nach
   B-02), die lokale Kopie `backups/coder.env` (solang das Dateisystem
   lesbar ist) oder Wissen, dass ein Neuaufbau neue Passwörter würfelt
   (Pfad B). `.env` und `.env.bak.*` sind nie Bestandteil des SQL-Dumps;
   lokale Kopien auf derselben ausgefallenen VM sind kein Offsite-Backup.
3. Frische Debian-13-VM + dieses Repo (getesteter Commit).
4. **Restore-Sonde im Quellsystem vor dem zu probenden Backup** – ohne sie
   meldet Pfad A Schritt 5 nachher rot (Zählung `0`/fehlende Tabelle gilt
   nicht als Erfolg). Genau eine Zeile je Backup-Datum, Wiederholung
   desselben Tages überschreibt statt zu verdoppeln:

   `AAAA-MM-JJ` = Datum des Backup-Laufes, den man später einspielt.

   ```bash
   sudo docker exec -i coder-postgres psql -v ON_ERROR_STOP=1 -U coder -d coder \
     -c "CREATE TABLE IF NOT EXISTS restore_probe(id serial primary key, marker text)" \
     -c "DELETE FROM restore_probe WHERE marker='RTO-PROBE-AAAA-MM-JJ'" \
     -c "INSERT INTO restore_probe(marker) VALUES ('RTO-PROBE-AAAA-MM-JJ')"
   ```

   Erst danach das Backup anstoßen (automatischer Tageslauf oder
   `backup.sh`), damit die Sonde im Dump steckt.

## Pfad A – Dump + originale `.env` vorhanden

1. **Originale `.env` vor dem ersten Setup-Lauf bereitstellen.** Auf der
   frischen VM das Zielverzeichnis anlegen und die gesicherte Datei mit
   Root-Eigentümer und Modus 600 installieren:

   ```bash
   sudo install -d -o root -g root -m 700 /opt/coder
   sudo install -o root -g root -m 600 /PFAD/ZUR/ORIGINALEN-ENV /opt/coder/.env
   ```

2. `setup-coder.sh` ausführen. Postgres und Grafana übernehmen so schon beim
   ersten Start die Passwörter aus der originalen `.env`. **Die `.env` danach
   nicht durch eine andere Version ersetzen.** Ein Tausch nach dem Start würde
   die gespeicherten Postgres-/Grafana-Passwörter nicht ändern und könnte
   Coder von Postgres trennen.
3. Coder für den Import stoppen:
   `sudo docker compose -f /opt/coder/docker-compose.yml stop coder`
4. Dump einspielen (B-008: eine Variante, kein „Fehlerprotokoll lesen"):
   `sudo docker exec coder-postgres dropdb -U coder --if-exists coder \
     && sudo docker exec coder-postgres createdb -U coder -O coder coder \
     && zcat coder_<TS>.sql.gz | sudo docker exec -i coder-postgres psql -v ON_ERROR_STOP=1 -U coder -d coder`
   `ON_ERROR_STOP=1` steht als `psql`-Option **vor** `-U`: bei jedem SQL-Fehler
   (fehlerhafte `CREATE TABLE`-Zeile, fehlende Extension, Versionsdrift) exit
   `psql` ≠ 0, die `&&`-Kette bricht ab. **STOPP bei Exit ≠ 0** – Fehlermeldung
   lesen, Schritt 5 NICHT ausführen (kein `up -d`, kein grüner Restore). Bei
   automatisierter Kette zusätzlich `set -o pipefail`, sonst läuft ein
   fehlschlagendes `zcat` still durch.
   (Passwort aus `.env`; `dropdb`/`createdb` räumt das frische Leer-Schema weg,
   statt an bestehendem `CREATE TABLE` zu scheitern. Alternative mit gleichem
   Ergebnis: `pg_restore --clean --if-exists`, falls im Custom-Format gesichert.)
5. Stack hochfahren und **zweistufig** prüfen – Liveness ≠ wiederhergestellte
   Daten: `sudo docker compose -f /opt/coder/docker-compose.yml up -d`, Postgres
   healthy abwarten, dann:
   - **Datenprobe (hart, Pflicht):**

     `sudo docker exec coder-postgres psql -v ON_ERROR_STOP=1 -U coder -d coder -tAc "SELECT count(*) FROM restore_probe WHERE marker='RTO-PROBE-AAAA-MM-JJ'"`

     muss `1` liefern. `0` (leere bzw. frisch erzeugte DB), `>1` oder
     psql-Fehler (Relation `restore_probe` fehlt, weil ohne Sonde gebackupt)
     ⇒ **Restore NICHT anerkennen**, rot bleiben, Dump/Verfahren prüfen.
   - **Liveness:** `/healthz` liefert 200, `SELECT 1` liefert `1`.
   - **Inhalt:** Dashboard-Login zeigt die wiederhergestellten Bestandsdaten
     aus dem Dump (Nutzer/Workspaces), nicht nur HTTP 200.
   `SELECT 1`/`/healthz` allein sind **keine** Restore-Bestätigung.
6. Zeit stoppen = RTO, ins Protokoll (Datum, Versionen, Dump-Alter,
   Datenprobe = 1).

## Pfad B – nur Dump, `.env` verloren

1. Auf der frischen VM sicherstellen, dass `/opt/coder/.env` nicht aus einem
   alten oder unvollständigen Restore-Versuch stammt, dann `setup-coder.sh`
   ohne vorher bereitgestellte `.env` ausführen. Das Setup erzeugt neue
   Passwörter und initialisiert Postgres damit.
2. Rollen-Passwörter stehen NICHT im `pg_dump` (nur `pg_dumpall --globals`
   sichert sie) – der Dump enthält Daten, keine Passwörter. Daher: Dump wie in
   Pfad A Schritt 4 einspielen; DB-Rolle behält das neue Setup-Passwort, Coder
   nutzt die neue `.env` – konsistent ohne Abgleich.
3. Grafana-Admin-Passwort ist neu und steht in der geschützten `.env`;
   bei Bedarf gezielt abrufen. Dashboards ggf. neu provisionieren.
4. Verifikation + RTO wie Pfad A Schritt 5–6.

## Negative Befunde und Fehlerfälle

Nichts davon gilt als erfolgreicher Restore. Im Zweifel rot bleiben und
das Protokoll führen, nicht die Prüfung streichen.

| Befund | Bedeutung | Weitere Schritte |
|---|---|---|
| `gzip -t` des Dumps schlägt fehl | Dump defekt | Diesen Dump verwerfen, älteren Dump nehmen; Ursache klären (Platte, Abbruch) |
| Import exit ≠ 0 (`ON_ERROR_STOP=1`) | Dump/Schema/Versionsproblem | **STOPP**: kein Schritt 5, kein `up -d`, Fehlermeldung lesen, neuen Anlauf |
| Datenprobe ≠ `1` (0, >1, psql-Fehler) | leer, doppelt oder ohne Sonde gebackupt | Restore nicht anerkennen, Dump/Verfahren prüfen, Sonde vor dem nächsten Probe-Backup setzen |
| Postgres nach `up -d` nicht `healthy` | Stack nicht hochgefahren | `docker logs coder-postgres`; Liveness zählt hier nichts, erst recht nicht ohne Datenprobe |
| `/healthz` 200, aber Dashboard zeigt keine Bestandsdaten | falscher/leerer Inhalt | Prüfen, welcher Dump eingespielt wurde; Login-200 ist **keine** Bestätigung |
| `.env` fehlt oder ist unvollständig | Zugangsdaten fehlen; ein SQL-Dump kann sie nicht liefern | Separat übertragene `.env`-Kopie verwenden, falls vorhanden; sonst Pfad B (Neuaufbau mit neuen Passwörtern). |
| Coder-Version neu als die des Dumps | Schema-Migration evtl. irreversibel | Nur auf gleiche/kleinere Version zurück; Major-Wechsel einzeln mit frischem Dump |
| Kein/kein belastbares Backup vorhanden | kein Restore möglich | Offsite-Status prüfen ([README.md](README.md)); ehrlich als Datenverlust führen, nichts beschönigen |

Wiederherstellungen im laufenden Betrieb (`reset-coder.sh`) sind **kein**
Ersatz für diesen Ablauf – sie erzeugen keinen Datenstand aus einem Dump.

## Coder-Migrationen / Workspace-Reste

- Coder migriert sein Schema beim Start selbst; Downgrades können irreversibel
  sein – Restore immer auf gleiche/kleinere Coder-Version fahren, Major-Wechsel
  nur einzeln mit frischem Dump.
- `setup-coder.sh` erzwingt das auch ohne Dump: die zuletzt wirksam gewesenen
  Versionen stehen in `/opt/coder/versions.env`, ein niedrigerer Wert bricht
  vor dem Stack ab. Bewusstes Zurücksetzen (nur mit verifiziertem Dump):
  `sudo env CODER_ALLOW_DOWNGRADE=yes CODER_VERSION=... ./setup-coder.sh`.
- Verwaiste Workspace-Container aus der Alt-Installation gibt es auf einer
  frischen VM nicht; beim Restore auf bestehendem Host vorher inventarisieren
  (`docker ps -a`, siehe reset-coder.sh).

## Wiederholungspflicht

Nach jedem Coder-Major-Update und einmal pro Semester auf Test-VM proben,
RTO-Zahl hier eintragen:

| Datum | Coder-Version | RTO | Datenprobe = 1 | Login ok |
|---|---|---|---|---|
| 2026-10-01 | v2.36.6 (Test-Host, Pfad A komplett) | **1 min 50 s** (ohne VM-Boot: Setup 58 s, Import 2,3 s) | ja (1) | teilweise: `owner` + API grün, kein Browser-Login; `/healthz`-TLS wegen externem DNS 000 |
| _offen_ (RTO inkl. VM-Boot und Paketinstallation) | – | – | – | – |

Durchführung: Sonde wie oben setzen, `backup.sh` laufen lassen, Dump per
`zcat | psql -v ON_ERROR_STOP=1` in einen temporären Container derselben
Image-Version einspielen (Import exit 0 in ~2–3 s; derselbe Ablauf hat
auch den Major-Wechsel 15 → 18 live getragen). Achtung beim Warten auf
den frischen Container: `pg_isready` meldet auch schon während des
Temp-Servers des Initialisierens – erst wiederholt `SELECT 1` mit den
echten Zugangsdaten gilt als bereit (sonst bricht der Import mitten in
der Initialisierung ab).

## Verwandte Dokumentation

- [README.md](README.md) – Einstieg, Voraussetzungen, was nur auf Test-VM/Produktion zu prüfen ist
- [OPERATIONS.md](OPERATIONS.md) – Backup-Steckbrief, Logs, Wartung
- [SECURITY.md](SECURITY.md) – Secrets (`.env`, manuelle Grafana-Rotation)
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) – Abschnitt F (Restore-Fehlerbilder)

Diese Datei wird vom Setup nach `/opt/coder/RESTORE.md` kopiert
(`B-008`), damit Verweise aus `setup-coder.sh` und `reset-coder.sh` auf dem
Server auflösen. Quelle ist die Version im Repository.
