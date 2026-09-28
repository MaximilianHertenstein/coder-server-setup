# RESTORE.md – Wiederherstellungs-Runbook (F-003)

Stand: 2026-09-28. Status: Verfahrenstiefe 1 (manuell, aber festgelegt).
Noch NICHT geprobt (keine Test-VM verfügbar) – RTO unbekannt, siehe BLOCKER.
Nie auf Produktion üben, nur auf isolierter Test-VM (T-080–T-083).

## Was gesichert wird – und was nicht (P-024, ehrlich)

- Gesichert (täglich, verifiziert per `gzip -t`): Postgres-Dump
  (`/opt/coder/backups/coder_*.sql.gz`, neueste 14, lokal auf derselben Platte).
- NICHT gesichert: `.env` (alle Passwörter!), Compose-/Caddy-/Prometheus-Config
  (entstehen per Setup-Re-Run neu), Caddy-Zertifikate, Grafana-Dashboards
  (als Code/Export pflegen oder Verlust akzeptieren), Prometheus-Historie
  (15 d, verzichtbar), Workspace-Dateien (Unterrichtsdaten!).
- Offsite-Kopie: NICHT eingerichtet (BLOCKER B-02/Offsite). Platten-/Host-
  Verlust = DB + alle Backups weg, solange das gilt.

## Voraussetzungen (Eingangs-Gates, harter Abbruch bei Fehlen)

1. Gültiger Dump (`gzip -t` grün, Größe plausibel, T-080-Mini-Restore ok).
2. `.env`-Ersatz: entweder die originale `.env` (aus `.env.bak.*` oder
   verschlüsseltem Offsite nach B-02) oder Wissen, dass ein Neuaufbau neue
   Passwörter würfelt (dann Pfad B unten).
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

1. `setup-coder.sh` auf frischer VM laufen lassen (erzeugt Stack + neue `.env`).
2. Stack stoppen: `sudo docker compose -f /opt/coder/docker-compose.yml stop coder`
3. Originale `.env` zurückspielen (`cp -a`, `chmod 600`, `chown root:root`).
4. Dump einspielen (B-008: eine Variante, kein „Fehlerprotokoll lesen"):
   `sudo docker exec coder-postgres dropdb -U coder --if-exists coder \
     && sudo docker exec coder-postgres createdb -U coder -O coder coder \
     && zcat coder_<TS>.sql.gz | sudo docker exec -i coder-postgres psql -v ON_ERROR_STOP=1 -U coder -d coder`
   `ON_ERROR_STOP=1` steht als `psql`-Option **vor** `-U`: bei jedem SQL-Fehler
   (fehlerhafte `CREATE TABLE`-Zeile, fehlende Extension, Versionsdrift) exitt
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

1. Wie Pfad A Schritt 1 (neue `.env`, neues DB-Passwort).
2. Rollen-Passwörter stehen NICHT im `pg_dump` (nur `pg_dumpall --globals`
   sichert sie) – der Dump enthält Daten, keine Passwörter. Daher: Dump wie in
   Pfad A Schritt 4 einspielen; DB-Rolle behält das neue Setup-Passwort, Coder
   nutzt die neue `.env` – konsistent ohne Abgleich.
3. Grafana-Admin-Passwort ist neu (Setup-Wert) – notieren, Dashboards ggf. neu.
4. Verifikation + RTO wie Pfad A Schritt 5–6.

## Negative Befunde und Fehlerfälle

Nichts davon gilt als erfolgreicher Restore. Im Zweifel rot bleiben und
das Protokoll führen, nicht die Prüfung streichen.

| Befund | Bedeutung | Weitere Schritte |
|---|---|---|
| `gzip -t` des Dumps schlägt fehl | Dump defekt | Diesen Dump verwerfen, älteren Dump nehmen; Ursache klären (Platte, Abbruch) |
| Import exitt ≠ 0 (`ON_ERROR_STOP=1`) | Dump/Schema/Versionsproblem | **STOPP**: kein Schritt 5, kein `up -d`, Fehlermeldung lesen, neuen Anlauf |
| Datenprobe ≠ `1` (0, >1, psql-Fehler) | leer, doppelt oder ohne Sonde gebackupt | Restore nicht anerkennen, Dump/Verfahren prüfen, Sonde vor dem nächsten Probe-Backup setzen |
| Postgres nach `up -d` nicht `healthy` | Stack nicht hochgefahren | `docker logs coder-postgres`; Liveness zählt hier nichts, erst recht nicht ohne Datenprobe |
| `/healthz` 200, aber Dashboard zeigt keine Bestandsdaten | falscher/leerer Inhalt | Prüfen, welcher Dump eingespielt wurde; Login-200 ist **keine** Bestätigung |
| `.env` fehlt oder ist unvollständig | Passwörter weg | Pfad B (Neuaufbau mit neuen Passwörtern) bzw. `.env.bak.*`; nicht still neu würfeln |
| Coder-Version neu als die des Dumps | Schema-Migration evtl. irreversibel | Nur auf gleiche/kleinere Version zurück; Major-Wechsel einzeln mit frischem Dump |
| Kein/kein belastbares Backup vorhanden | kein Restore möglich | Offsite-Status prüfen ([README.md](README.md)); ehrlich als Datenverlust führen, nichts beschönigen |

Wiederherstellungen im laufenden Betrieb (`reset-passwords.sh`,
`reset-coder.sh`) sind **kein** Ersatz für diesen Ablauf – sie erzeugen
keinen Datenstand aus einem Dump.

## Coder-Migrationen / Workspace-Reste

- Coder migriert sein Schema beim Start selbst; Downgrades können irreversibel
  sein – Restore immer auf gleiche/kleinere Coder-Version fahren, Major-Wechsel
  nur einzeln mit frischem Dump.
- Verwaiste Workspace-Container aus der Alt-Installation gibt es auf einer
  frischen VM nicht; beim Restore auf bestehendem Host vorher inventarisieren
  (`docker ps -a`, siehe reset-coder.sh).

## Wiederholungspflicht

Nach jedem Coder-Major-Update und einmal pro Semester auf Test-VM proben,
RTO-Zahl hier eintragen:

| Datum | Coder-Version | Dump-Alter | RTO | Datenprobe = 1 | Login ok |
|---|---|---|---|---|---|
| _offen_ | – | – | – | – | – |

## Verwandte Dokumentation

- [README.md](README.md) – Einstieg, Voraussetzungen, was nur auf Test-VM/Produktion zu prüfen ist
- [OPERATIONS.md](OPERATIONS.md) – Backup-Steckbrief, Logs, Wartung
- [SECURITY.md](SECURITY.md) – Secrets-Rotation (`.env`, `reset-passwords.sh`)
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) – Abschnitt F (Restore-Fehlerbilder)
- [CHANGELOG.md](CHANGELOG.md) – Stand dieser Datei und offene Punkte

Diese Datei wird vom Setup nach `/opt/coder/RESTORE.md` kopiert
(`B-008`), damit Verweise aus `update.sh` und `reset-coder.sh` auf dem
Server auflösen. Quelle ist die Version im Repository.
