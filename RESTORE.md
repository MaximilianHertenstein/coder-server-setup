# RESTORE.md – Wiederherstellungs-Runbook (F-003)

Stand: 2026-09-26. Status: Verfahrenstiefe 1 (manuell, aber festgelegt).
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

## Pfad A – Dump + originale `.env` vorhanden

1. `setup-coder.sh` auf frischer VM laufen lassen (erzeugt Stack + neue `.env`).
2. Stack stoppen: `sudo docker compose -f /opt/coder/docker-compose.yml stop coder`
3. Originale `.env` zurückspielen (`cp -a`, `chmod 600`, `chown root:root`).
4. Dump einspielen (B-008: eine Variante, kein „Fehlerprotokoll lesen"):
   `sudo docker exec coder-postgres dropdb -U coder --if-exists coder \
     && sudo docker exec coder-postgres createdb -U coder -O coder coder \
     && zcat coder_<TS>.sql.gz | sudo docker exec -i coder-postgres psql -U coder -d coder`
   (Passwort aus `.env`; `dropdb`/`createdb` räumt das frische Leer-Schema weg,
   statt an bestehendem `CREATE TABLE` zu scheitern. Alternative mit gleichem
   Ergebnis: `pg_restore --clean --if-exists`, falls im Custom-Format gesichert.)
5. `sudo docker compose -f /opt/coder/docker-compose.yml up -d`, Postgres
   healthy abwarten, Coder-Login prüfen (`/healthz` 200 + Dashboard-Login).
6. Zeit stoppen = RTO, ins Protokoll (Datum, Versionen, Dump-Alter).

## Pfad B – nur Dump, `.env` verloren

1. Wie Pfad A Schritt 1 (neue `.env`, neues DB-Passwort).
2. Rollen-Passwörter stehen NICHT im `pg_dump` (nur `pg_dumpall --globals`
   sichert sie) – der Dump enthält Daten, keine Passwörter. Daher: Dump wie in
   Pfad A Schritt 4 einspielen; DB-Rolle behält das neue Setup-Passwort, Coder
   nutzt die neue `.env` – konsistent ohne Abgleich.
3. Grafana-Admin-Passwort ist neu (Setup-Wert) – notieren, Dashboards ggf. neu.
4. Verifikation + RTO wie Pfad A Schritt 5–6.

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

| Datum | Coder-Version | Dump-Alter | RTO | Login ok |
|---|---|---|---|---|
| _offen_ | – | – | – | – |
