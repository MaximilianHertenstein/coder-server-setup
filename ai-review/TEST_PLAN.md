# TEST_PLAN.md – Ausführbarer Testplan für `setup-coder.sh`

Stand: 2026-09-26. Geprüft: `setup-coder.sh` (845 Zeilen).
Quellen: `setup-coder.sh`, `ai-review/PLAN.md` (lesbar: F-001–F-012, Rest
abgebrochen), `ai-review/PLAN-REVIEW.md` (P-001–P-025),
`ai-review/01-bash.md`, `02-security.md`, `03-debian-docker.md`,
`04-coder-caddy.md`, `05-backup-recovery.md`, `06-architecture.md`.

Es wurde ausschließlich diese Datei erstellt/geändert. Keine Implementierung.

## Grundsätze

1. **Nie auf Produktion.** Alle T-Tests laufen auf isolierter Test-VM
   (Debian 13 netinst, Snapshot-fähig, z. B. KVM/VirtualBox/Proxmox).
   Vor jedem destruktiven Test: Snapshot. Danach: Revert oder Cleanup.
2. **Jeder Test ist ausführbar:** Preconditions + Actions enthalten konkrete
   Befehle. Ergebnis ist binär (Expected vs. Failure).
3. **Protokollpflicht:** Je Test: Datum, VM-Name, `git rev-parse --short HEAD`
   von `setup-coder.sh`, Tool-Versionen (`shellcheck --version`,
   `docker --version`, `caddy version`), Exit-Codes, relevante Logs.
4. **Referenz-Check geht vor Fix-Tests:** T-006 muss grün sein, bevor
   Verhaltens-Tests als „PLAN-abdeckend" gewertet werden (P-021).
5. **Namenskonvention Test-VM:** `coder-test-<datum>`, Domain für externe
   Tests: separate **Testdomain** (nie `coder.ghse-unterricht.de`).

## Testumgebung (für alle VM-Tests)

- Frische Debian-13-VM (trixie), 2 vCPU / 4 GB RAM / 30 GB Platte,
  Snapshot `clean-install` vor erstem Setup-Lauf.
- Netzwerk: NAT + optional Host-only für externe Scans; für
  Netzwerk-Fehlertests reversibel blockierbar (iptables/resolv.conf).
- Auf der VM: `setup-coder.sh` aus dem getesteten Commit nach `/root/setup-coder.sh`
  kopiert, `chmod +x`.
- Externer Scanner: zweite VM/Rechner im selben Netz für T-060/T-120er.

---

## 1. Static validation

### T-001 – `bash -n` Syntaxcheck

Purpose:
Sicherstellen, dass `setup-coder.sh` syntaktisch gültig ist (Vorbedingung
für alle weiteren Tests; 05-Methodik, P-022).

Preconditions:
Repo-Checkout des getesteten Commits lokal vorhanden.

Actions:
```bash
bash -n setup-coder.sh && echo SYNTAX_OK
bash -n <(sed -n '/^sudo tee \/opt\/coder\/backup.sh/,/^EOF$/p' setup-coder.sh) || true
```

Expected result:
`SYNTAX_OK`, Exit 0.

Failure condition:
Exit ≠ 0 oder Syntaxfehler-Ausgabe.

Cleanup:
Keins.

Findings: P-022, 05-Methodik, 06/F-015.

### T-002 – ShellCheck Hauptdatei + extrahierte Heredoc-Skripte

Purpose:
ShellCheck-Befunde reproduzierbar machen; 01/F-006-Behauptung
(„nur SC1091/SC2034/SC2012") verifizieren; Regressionen bei
Escaping-Migrationen (F-006/F-007/F-010) früh fangen.

Preconditions:
`shellcheck --version` notiert (Referenz: 0.11.0).

Actions:
```bash
shellcheck -S warning -s bash setup-coder.sh | tee /tmp/sc-main.log; echo "exit=$?"
mkdir -p /tmp/sc-review
for s in backup update reset-passwords reset-coder; do :; done
# Heredocs extrahieren (sudo-tee-Blöcke) und einzeln prüfen:
python3 - <<'PY'
import re
src = open('setup-coder.sh').read()
for name, marker in [('backup','/opt/coder/backup.sh'),('update','/opt/coder/update.sh'),
                     ('reset-passwords','/opt/coder/reset-passwords.sh'),('reset-coder','/opt/coder/reset-coder.sh')]:
    m = re.search(r"tee %s > /dev/null <<'EOF'\n(.*?\n)EOF" % re.escape(marker), src, re.S)
    open('/tmp/sc-review/%s.sh' % name, 'w').write(m.group(1))
print("extracted")
PY
shellcheck -S warning -s bash /tmp/sc-review/*.sh | tee /tmp/sc-heredoc.log; echo "exit=$?"
```

Expected result:
Hauptdatei: nur bekannte Info/Warning-Klasse (SC1091, SC2034, SC2012),
kein `error`; Heredocs: keine Meldungen. Logs archiviert.

Failure condition:
`error`-Severity, oder neue Warning-Klasse ohne Dokumentation, oder
Extraktion schlägt fehl (Heredoc-Marker drifted).

Cleanup:
`rm -rf /tmp/sc-review /tmp/sc-*.log` (nach Archivierung ins Protokoll).

Findings: PLAN F-006/F-007/F-010 (Regressionsschutz), P-022, 01/F-006, 06/F-015.

### T-003 – Docker-Compose-Config-Validierung

Purpose:
YAML-Syntax und Variablen-Interpolation prüfen, bevor etwas gestartet wird
(Skript L344 selbst; P-022/06/F-003).

Preconditions:
Test-VM mit Docker-Engine + Compose-Plugin, `/opt/coder/` aus Setup
(Schritt 2) oder generierte Datei vorhanden.

Actions:
```bash
sudo docker compose -f /opt/coder/docker-compose.yml config --quiet && echo COMPOSE_CONFIG_OK
sudo docker compose -f /opt/coder/docker-compose.yml config | grep -E 'image:|POSTGRES_PASSWORD|DOCKER_GID' | sed 's/=hex.*/=<redacted>/'
# Negativprobe (Harness-Selbsttest):
cp /opt/coder/docker-compose.yml /tmp/compose-bad.yml
printf '  BAD_INDENT:\n bad' >> /tmp/compose-bad.yml
sudo docker compose -f /tmp/compose-bad.yml config --quiet; echo "bad-exit=$? (muss != 0)"
```

Expected result:
Gültige Datei: Exit 0. Bad-Datei: Exit ≠ 0.

Failure condition:
Gültige Datei rot, oder Bad-Datei grün (Harness blind).

Cleanup:
`rm -f /tmp/compose-bad.yml`.

Findings: P-022, 06/F-003, 06/F-015, 01/F-009 (Injektion sichtbar via config).

### T-004 – Caddy-Konfigurationsvalidierung

Purpose:
Generierte `Caddyfile` formal prüfen (`caddy validate`/`caddy fmt`);
Kommentar-vs-Verhalten-Mismatch (04/F-006) nicht als Validierungsfehler
tarnen.

Preconditions:
`/opt/coder/Caddyfile` vorhanden; Caddy-Image verfügbar
(`caddy:2.10` oder gesetzte `CADDY_VERSION`).

Actions:
```bash
sudo docker run --rm -v /opt/coder/Caddyfile:/etc/caddy/Caddyfile:ro \
  caddy:2.10 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && echo CADDY_VALID
sudo docker run --rm -v /opt/coder/Caddyfile:/etc/caddy/Caddyfile:ro \
  caddy:2.10 caddy fmt --overwrite /etc/caddy/Caddyfile 2>&1 || true
grep -n 'on_demand\|ask ' /opt/coder/Caddyfile
```

Expected result:
`CADDY_VALID`, Exit 0; `on_demand` + `ask http://example.com` wie im
Skript vorhanden (Ist-Zustand dokumentiert, kein Validierungsfehler).

Failure condition:
`validate` Exit ≠ 0.

Cleanup:
Keins (fmt läuft nur lesend im Container; Hostdatei unverändert lassen;
ggf. `git diff --no-index` verwerfen).

Findings: P-005, 04/F-001/F-006, 06/F-003.

### T-005 – YAML-Validierung aller generierten Dateien

Purpose:
Alle generierten YAML-Dateien (`docker-compose.yml`, `prometheus.yml`)
gegen Parser prüfen, unabhängig von Docker.

Preconditions:
Python3 mit PyYAML auf Test-/CI-Host.

Actions:
```bash
python3 - <<'PY'
import yaml, sys
for f in ['/opt/coder/docker-compose.yml', '/opt/coder/prometheus.yml']:
    yaml.safe_load(open(f))
    print(f, 'YAML_OK')
PY
echo "exit=$?"
```

Expected result:
Beide `YAML_OK`, Exit 0.

Failure condition:
`yaml.YAMLError` oder File-not-found.

Cleanup:
Keins.

Findings: P-022, 06/F-003/F-015.

### T-006 – Referenz-Check PLAN (Dangling Finder, P-001/P-021-Gate)

Purpose:
Jede `F-xxx`-/`D<n>`-Referenz in PLAN.md muss auf eine existierende
Überschrift auflösen. Muss rot sein, solange PLAN.md abgebrochen ist.

Preconditions:
`ai-review/PLAN.md` vorhanden.

Actions:
```bash
python3 - <<'PY'
import re, sys
t = open('ai-review/PLAN.md').read()
defined_f = set(re.findall(r'^## (F-\d+)', t, re.M))
defined_d = set(re.findall(r'^## (D\d+)', t, re.M))
refs_f = set(re.findall(r'F-(\d+)', t))
refs_d = set(re.findall(r'\bD(\d+)', t))
missing_f = {'F-%s' % n for n in refs_f} - defined_f - {'F-001'}  # F-001 = 01-review, kein PLAN-Finding
missing_d = {'D%s' % n for n in refs_d} - defined_d
print('defined F:', sorted(defined_f))
print('missing F:', sorted(missing_f))
print('missing D:', sorted(missing_d))
sys.exit(1 if (missing_f or missing_d) else 0)
PY
echo "exit=$? (derzeit erwartet: 1 wegen F-019/F-021/D4-D9)"
tail -5 ai-review/PLAN.md
```

Expected result:
Derzeit: Exit 1 mit `missing F: [F-019, F-021]`, `missing D: [D4..D9]`
(dokumentiert P-001/P-021 als Blocking, kein Test-Pass).

Failure condition:
Fälschlich Exit 0 bei bekanntem Abbruch (Check blind), oder nach
PLAN-Reparatur weiterhin Exit 1.

Cleanup:
Keins.

Findings: P-001, P-021, P-022.

### T-007 – Harness-Selbsttest (Meta, rot-nachweis)

Purpose:
Beweisen, dass T-001–T-006 echte Fehler fangen (P-022 „Required test Meta").

Preconditions:
Kopie des Repos unter `/tmp/harness-test`.

Actions:
```bash
cp setup-coder.sh /tmp/harness-bad.sh
printf 'if [ ' >> /tmp/harness-bad.sh   # absichtlicher Syntaxfehler
bash -n /tmp/harness-bad.sh; echo "bashn-exit=$? (muss != 0)"
printf 'for i in 1 2; do echo $i; done\n' > /tmp/sc2034.sh  # SC2034-Analogon: unused? nutze:
printf 'for i in $(seq 1 3); do echo hi; done\n' > /tmp/sc2034.sh
shellcheck -S warning -s bash /tmp/sc2034.sh | grep -q SC2034 && echo SC2034_CAUGHT || echo SC2034_ABSENT
```

Expected result:
`bashn-exit != 0`. SC2034-Analogon wird erkannt (oder begründet
abwesend mit Version).

Failure condition:
Harness bleibt grün trotz eingebautem Fehler.

Cleanup:
`rm -f /tmp/harness-bad.sh /tmp/sc2034.sh`.

Findings: P-022, 06/F-015.

---

## 2. Fresh installation

### T-010 – Frische Debian-13-Installation (Basispfad)

Purpose:
Nachweisen, dass Setup auf leerer Debian-13-VM grün durchläuft und den
versprochenen Stack baut.

Preconditions:
Snapshot `clean-install`: frisches Debian 13 (trixie), Sudo-User,
Netz/DNS/Registry erreichbar, keine Alt-Crontab, kein `/opt/coder`.

Actions:
```bash
sudo bash -x /root/setup-coder.sh 2>&1 | tee /var/log/coder-setup-test.log; echo "setup-exit=${PIPESTATUS[0]}"
echo "--- summary-tail ---"; tail -30 /var/log/coder-setup-test.log
```

Expected result:
Exit 0, Zusammenfassung ohne `[FEHLER]` (WARN zu DNS/TLS/SSH-Passwort
zulässig, falls Testdomain ohne DNS/Portforward – dann aber protokolliert).

Failure condition:
Exit ≠ 0, oder `[FEHLER]`-Zeile, oder Abbruch ohne Meldung (vgl. F-001).

Cleanup:
Snapshot behalten für T-020 (`post-install` Snapshot anlegen).

Findings: PLAN F-001 (Abbruchfreiheit), F-009 (cron/Backup-OK), 03/F-011
(trixie-Repo), P-023.

### T-011 – Alle Container laufen + Health-Status

Purpose:
Container- und Service-Nachweis nach Fresh Install.

Preconditions:
T-010 grün.

Actions:
```bash
sudo docker compose -f /opt/coder/docker-compose.yml ps
for c in coder-postgres coder coder-caddy coder-prometheus coder-node-exporter coder-grafana; do
  printf '%s: ' "$c"
  sudo docker inspect -f '{{.State.Running}} / {{if .State.Health}}{{.State.Health.Status}}{{else}}no-health{{end}}' "$c"
done
sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres
```

Expected result:
Alle sechs `Running=true`; `coder-postgres` `healthy`; restliche
`no-health` (kein Healthcheck definiert – Ist-Zustand) aber Running.

Failure condition:
Ein Container nicht Running, oder Postgres nicht healthy nach 60 s.

Cleanup:
Keins.

Findings: PLAN F-007 (läuft ≠ Socket-ok, hier nur Lauf-Nachweis;
Socket-Probe siehe T-024/T-063), P-009.

### T-012 – Services antworten (intern)

Purpose:
Dienste jenseits „Container läuft" prüfen.

Preconditions:
T-011 grün.

Actions:
```bash
sudo docker exec coder-postgres pg_isready -U coder -d coder
curl -s -o /dev/null -w 'prometheus=%{http_code}\n' --max-time 5 http://127.0.0.1:9090/-/healthy || true
curl -s -o /dev/null -w 'grafana=%{http_code}\n' --max-time 5 http://127.0.0.1:3001/login || true
curl -s -o /dev/null -w 'node-exporter=%{http_code}\n' --max-time 5 http://127.0.0.1:9100/metrics || true
curl -sk -o /dev/null -w 'caddy-local=%{http_code}\n' --max-time 5 https://127.0.0.1/healthz || true
```

Expected result:
`pg_isready: accepting connections`; Prometheus/Grafana/node-exporter
erreichbar (2xx/3xx); Caddy lokal per HTTPS (ggf. Zert-Warnung mit `-k`
akzeptiert, Code dokumentiert).

Failure condition:
Postgres nicht ready; alle Monitoring-Ports tot.

Cleanup:
Keins.

Findings: P-009, 03/F-002/F-009.

### T-013 – Port-Bindungen (ss-Abgleich, Ist-Zustand)

Purpose:
Bindungs-Ist-Zustand festhalten: Caddy öffentlich, Monitoring loopback.

Preconditions:
T-011 grün.

Actions:
```bash
ss -tlnp | tee /tmp/ss-test.log
ss -ulnp | grep 443 || true
echo '--- Erwartung: 0.0.0.0:80, 0.0.0.0:443 <- caddy; 127.0.0.1:9090, 127.0.0.1:9100, 127.0.0.1:3001 ---'
grep -E ':(80|443|9090|9100|3001) ' /tmp/ss-test.log
```

Expected result:
80/443 an `*:80/*:443` (caddy), 9090/9100/3001 nur an `127.0.0.1`.

Failure condition:
Monitoring-Port an `0.0.0.0` gebunden, oder Caddy-Port fehlt.

Cleanup:
`rm -f /tmp/ss-test.log` nach Protokollierung.

Findings: P-004, 02/F-008/F-009, 06/F-006.

### T-014 – Abschlusscheck-Inhalte (ufw/fail2ban/unattended/cron)

Purpose:
Schritt-4/5/6-Nachweise aus Setup-Protokoll verifizieren.

Preconditions:
T-010-Protokoll vorhanden.

Actions:
```bash
grep -E '\[OK\]|\[WARNUNG\]|\[FEHLER\]' /var/log/coder-setup-test.log
sudo ufw status verbose
sudo fail2ban-client status sshd
systemctl is-active cron fail2ban || true
cat /etc/cron.d/coder-backup
ls -l /opt/coder/backups/
```

Expected result:
`ufw active`, `22/tcp LIMIT`, fail2ban `sshd` aktiv, cron-Datei
vorhanden, mind. ein Backup-Testlauf (`coder_*.sql.gz`).

Failure condition:
`[FEHLER]`-Zeile, oder cron-Datei fehlt, oder kein Backup nach Testlauf.

Cleanup:
Keins.

Findings: PLAN F-009, P-017, 05/F-006.

---

## 3. Idempotency

### T-020 – Erster/Zweiter/Dritter Lauf + Zustandsdiff

Purpose:
Idempotenz-Versprechen („einfach erneut laufen lassen") prüfen; Drift und
Nebenwirkungen messen.

Preconditions:
Snapshot `post-install` (T-010 grün).

Actions:
```bash
# Fingerprint vor Re-Runs:
sha256sum /opt/coder/docker-compose.yml /opt/coder/Caddyfile /opt/coder/prometheus.yml | tee /tmp/state-run1.sha
sudo docker inspect -f '{{.State.StartedAt}}' coder-caddy | tee /tmp/caddy-start1
sudo fail2ban-client status sshd | grep -E 'Currently banned' | tee /tmp/ban1
sudo /root/setup-coder.sh >/var/log/coder-setup-run2.log 2>&1; echo "run2-exit=$?"
sudo /root/setup-coder.sh >/var/log/coder-setup-run3.log 2>&1; echo "run3-exit=$?"
sha256sum /opt/coder/docker-compose.yml /opt/coder/Caddyfile /opt/coder/prometheus.yml | tee /tmp/state-run3.sha
diff /tmp/state-run1.sha /tmp/state-run3.sha && echo CONFIG_STABLE || echo CONFIG_DRIFT
sudo docker inspect -f '{{.State.StartedAt}}' coder-caddy | tee /tmp/caddy-start3
diff /tmp/caddy-start1 /tmp/caddy-start3 && echo CADDY_UNTOUCHED || echo CADDY_RESTARTED
grep -cE '\[FEHLER\]' /var/log/coder-setup-run2.log /var/log/coder-setup-run3.log || true
```

Expected result:
run2/run3 Exit 0, keine `[FEHLER]`, Config-Hashes stabil.

Failure condition:
Exit ≠ 0, `[FEHLER]`, oder Config-Drift ohne Variablenänderung.

Cleanup:
Snapshots/Logs behalten bis Review-Ende.

Findings: PLAN F-001/F-006/F-007, P-025, 06/F-009.

### T-021 – Crontab-Migration Einzeiler/Leer/Fehlend (F-001)

Purpose:
F-001-Fix (`|| true`) an allen vier Crontab-Konstellationen beweisen.

Preconditions:
Test-VM, Snapshot; Root-Crontab manipulierbar.

Actions:
```bash
for case in single other none multi; do
  case $case in
    single) printf '0 1 * * * root /opt/coder/backup.sh\n' | sudo crontab - ;;
    other)  printf '0 5 * * * root /bin/true\n' | sudo crontab - ;;
    none)   sudo crontab -r 2>/dev/null || true ;;
    multi)  printf '0 5 * * * root /bin/true\n0 1 * * * root /opt/coder/backup.sh\n' | sudo crontab - ;;
  esac
  echo "=== case=$case ==="
  sudo bash -x /root/setup-coder.sh >/tmp/rerun-$case.log 2>&1; echo "exit=$?"
  grep -E '\[FEHLER\]' /tmp/rerun-$case.log || echo "no-FEHLER"
done
```

Expected result:
Alle vier: Exit 0, nachfolgende Schritte laufen (update/reset-Skripte +
Abschlusscheck im Log), kein stiller Abbruch.

Failure condition:
Ein Case mit Exit ≠ 0 oder fehlenden Schritten 7–10 (F-001-Regression).

Cleanup:
`sudo crontab -r 2>/dev/null || true`; Snapshot-Revert empfohlen.

Findings: PLAN F-001, P-022 (Missing-Tests-Forderung), 01/F-001.

### T-022 – `.env`-Halbierung wird nicht akzeptiert, aber auch nicht still neu gewürfelt

Purpose:
P-010/P-011 beachten: weder Ist-Zustand (akzeptieren) noch PLAN-Roh-F-006
(still neu würfeln) sind ok; erwartet: Abbruch mit Reparaturanleitung oder
gezieltes Ergänzen + `.bak`.

Preconditions:
T-010 grün; `.env`-Backup unter `/tmp/env-good`.

Actions:
```bash
sudo cp -a /opt/coder/.env /tmp/env-good
OLD_PW=$(sudo grep '^POSTGRES_PASSWORD=' /opt/coder/.env | cut -d= -f2-)
# eine Zeile entfernen (simuliert Abbruch während tee):
sudo sed -i '/^GRAFANA_ADMIN_PASSWORD=/d' /opt/coder/.env
cat /opt/coder/.env | sed 's/=.*$/=<redacted>/'
sudo /root/setup-coder.sh >/tmp/rerun-halfenv.log 2>&1; echo "exit=$?"
echo '--- Erwartung (nach P-011-Fix): Abbruch mit Meldung ODER Ergänzung, kein stilles Neuwürfeln ---'
sudo grep '^POSTGRES_PASSWORD=' /opt/coder/.env | cut -d= -f2- | grep -qx "$OLD_PW" && echo PG_PW_STABIL || echo PG_PW_GEWUERFELT
sudo docker exec coder-postgres pg_isready -U coder -d coder && echo DB_LOGIN_OK || echo DB_LOGIN_FAIL
```

Expected result:
Entweder Exit ≠ 0 mit Reparaturanleitung und `.env.bak.*`, oder
fehlende Zeile ergänzt bei stabilem `POSTGRES_PASSWORD` + `DB_LOGIN_OK`.

Failure condition:
Re-Run meldet „existiert bereits" und akzeptiert unvollständige `.env`;
oder alle Passwörter neu gewürfelt und `DB_LOGIN_FAIL` (P-011-Schaden).

Cleanup:
`sudo cp -a /tmp/env-good /opt/coder/.env; sudo chmod 600 /opt/coder/.env`.

Findings: PLAN F-006, P-010, P-011, 01/F-002.

### T-023 – `.env`-Rechte: kein 644-Fenster durch `sudo tee`

Purpose:
P-010 nachweisen: `stat 600` ohne Zwischen-644, auch mit Root-umask 022.

Preconditions:
Test-VM; `/opt/coder/.env` vorher weg (nur Test-VM!).

Actions:
```bash
sudo rm -f /opt/coder/.env
sudo bash -x /root/setup-coder.sh >/tmp/rerun-envperm.log 2>&1; echo "exit=$?"
stat -c %a /opt/coder/.env
grep -E 'tee.*\.env|chmod.*\.env|install.*\.env' /tmp/rerun-envperm.log || true
```

Expected result:
`600`, und im `-x`-Protokoll kein 644-Fenster (via `install -m 600` /
vorab-`chmod` vor Schreiben).

Failure condition:
`644` zu irgendeinem Zeitpunkt, oder reines `umask 077` in
Sudo-Nutzer-Shell als angeblicher Fix (P-010-Irrtum).

Cleanup:
Keins (neue `.env` + neue Passwörter notieren, DB neu – nur Test-VM).

Findings: PLAN F-006, P-010, 01/F-002.

### T-024 – `DOCKER_GID`-Refresh: Diff-Recreate, Leer-Guard, Socket-Probe

Purpose:
F-007 präzise testen (P-012): Refresh nur bei Diff + Recreate; leere GID
bricht ohne `.env`-Änderung ab; Re-Run ohne Änderung recreatet nicht.

Preconditions:
T-010 grün; aktuelle GID notiert.

Actions:
```bash
getent group docker
sudo grep DOCKER_GID /opt/coder/.env | sed 's/=.*$/=<n>/'
sudo docker inspect -f '{{.State.StartedAt}}' coder | tee /tmp/coder-start-before
# Fall A: GID ändern:
sudo groupmod -g 1999 docker || sudo groupmod -g 499 docker
getent group docker
sudo /root/setup-coder.sh >/tmp/rerun-gid.log 2>&1; echo "exit=$?"
sudo grep DOCKER_GID /opt/coder/.env
sudo docker exec coder stat -c %g /var/run/docker.sock || sudo docker exec coder docker info >/dev/null 2>&1 && echo SOCKET_PROBE_OK || echo SOCKET_PROBE_FAIL
# Fall B: Re-Run ohne Änderung darf nicht recreaten:
sudo docker inspect -f '{{.State.StartedAt}}' coder | tee /tmp/coder-start-after
diff /tmp/coder-start-before /tmp/coder-start-after && echo NO_NEEDLESS_RECREATE || echo RECREATED
```

Expected result:
Fall A: `.env`-GID folgt, genau dann Recreate + `SOCKET_PROBE_OK`.
Fall B: kein Recreate (Startzeit unverändert).

Failure condition:
Stale GID (Socket Permission denied), oder leere GID geschrieben, oder
blinder Recreate bei jedem Lauf (TLS-Unterbrechung ohne Config-Änderung).

Cleanup:
GID zurücksetzen (`sudo groupmod -g <orig> docker`), Re-Run, Probe
wiederholen.

Findings: PLAN F-007, P-012, 03/F-006, 06/F-009.

### T-025 – Re-Run ohne Config-Änderung: kein Caddy-Restart, Bans bleiben

Purpose:
P-025 prüfen (Caddy-nur-bei-Änderung, fail2ban-reload statt restart).

Preconditions:
T-010 grün.

Actions:
```bash
sudo docker inspect -f '{{.State.StartedAt}}' coder-caddy | tee /tmp/caddy-b
sudo fail2ban-client status sshd | tee /tmp/bans-b
sudo /root/setup-coder.sh >/tmp/rerun-norestart.log 2>&1; echo "exit=$?"
sudo docker inspect -f '{{.State.StartedAt}}' coder-caddy | tee /tmp/caddy-a
diff /tmp/caddy-b /tmp/caddy-a && echo CADDY_UNTOUCHED || echo CADDY_RESTARTED
sudo fail2ban-client status sshd | tee /tmp/bans-a
diff /tmp/bans-b /tmp/bans-a && echo BANS_KEPT || echo BANS_RESET
```

Expected result:
`CADDY_UNTOUCHED`, `BANS_KEPT`.

Failure condition:
`CADDY_RESTARTED` bei jedem Lauf + Bans verworfen (heute dokumentieren
als P-025-Verstoß).

Cleanup:
Keins.

Findings: P-025, P-009, 06/F-009.

### T-026 – Config-Drift wird nicht still zementiert (Schritt-2-Atomarität)

Purpose:
P-023: Kill während Schritt 2 → Re-Run heilt statt Drift zu übernehmen;
Re-Run ohne Änderung startet Caddy nicht neu.

Preconditions:
Snapshot `post-install`.

Actions:
```bash
sha256sum /opt/coder/docker-compose.yml /opt/coder/Caddyfile | tee /tmp/cfg-before.sha
# manuelle Drift simulieren:
sudo sh -c 'echo "# drift-test" >> /opt/coder/Caddyfile'
sudo /root/setup-coder.sh >/tmp/rerun-drift.log 2>&1; echo "exit=$?"
sha256sum /opt/coder/docker-compose.yml /opt/coder/Caddyfile | tee /tmp/cfg-after.sha
grep -iE 'drift|geändert|unchanged|reload|restart' /tmp/rerun-drift.log || echo "(keine Drift-Meldung)"
```

Expected result:
Drift erkannt (Diff/Warnung) und deterministisch regeneriert; Caddy nur
bei echter Änderung neugestartet.

Failure condition:
Drift still überschrieben ohne Meldung, oder Drift bleibt stehen
(unklarer Folgezustand).

Cleanup:
Snapshot-Revert.

Findings: P-023, P-025, 06/F-003.

---

## 4. Interrupted installation

### T-030 – Abbruch während Schritt 2 (Heredoc/`tee`-Phase)

Purpose:
Halb geschriebene Compose/Caddy/Prometheus-Dateien dürfen keinen
definierten Folgezustand vortäuschen (P-023, F-006-Analogon).

Preconditions:
Snapshot `clean-install` oder `post-install`.

Actions:
```bash
sudo timeout -s KILL 20 bash /root/setup-coder.sh || echo "killed-exit=$?"
ls -l /opt/coder/*.yml /opt/coder/Caddyfile /opt/coder/.env 2>&1
sudo /root/setup-coder.sh >/tmp/rerun-afterkill2.log 2>&1; echo "rerun-exit=$?"
sudo docker compose -f /opt/coder/docker-compose.yml config --quiet && echo CONFIG_HEALED
```

Expected result:
Re-Run heilt (Exit 0, `CONFIG_HEALED`), keine partielle Finaldatei als
„gültig" akzeptiert.

Failure condition:
Re-Run akzeptiert kaputte `.env`/Compose still, oder `config` rot.

Cleanup:
Snapshot-Revert bei Bedarf.

Findings: P-023, PLAN F-006, 01/F-002.

### T-031 – Abbruch während `apt-get` / Docker-Repo-Phase

Purpose:
Teil-Download darf Re-Run nicht als „fertig" tarnen (P-023).

Preconditions:
Snapshot `clean-install`.

Actions:
```bash
sudo timeout -s KILL 15 bash /root/setup-coder.sh || echo "killed-exit=$?"
sudo apt-get check && echo APT_CONSISTENT || echo APT_BROKEN
sudo /root/setup-coder.sh >/tmp/rerun-afterkill1.log 2>&1; echo "rerun-exit=$?"
```

Expected result:
`APT_CONSISTENT`, Re-Run Exit 0.

Failure condition:
APT-Bruch ohne klare Meldung, oder Re-Run läuft weiter „als wäre nichts".

Cleanup:
Snapshot-Revert.

Findings: P-023.

### T-032 – Abbruch während `docker compose pull` / `up -d`

Purpose:
Halbe Images/Container nach Kill → Re-Run konvergiert.

Preconditions:
Snapshot `post-install`, Images vorhanden.

Actions:
```bash
sudo docker compose -f /opt/coder/docker-compose.yml pull &
PULLPID=$!
sleep 10; sudo kill -KILL $PULLPID || true; wait $PULLPID || echo "pull-killed=$?"
sudo /root/setup-coder.sh >/tmp/rerun-afterkill3.log 2>&1; echo "rerun-exit=$?"
sudo docker compose -f /opt/coder/docker-compose.yml ps
```

Expected result:
Re-Run Exit 0, alle Container Running/Healthy.

Failure condition:
Dangling-Halbzustand mit `[FEHLER]` oder fehlenden Containern.

Cleanup:
`sudo docker compose -f /opt/coder/docker-compose.yml up -d`.

Findings: P-023, P-009.

### T-033 – Abbruch in `reset-passwords.sh`-Fenster (SIGTERM vor `sed`)

Purpose:
F-010/P-018: Warnung + `.bak` + Anleitung; Re-Run heilt statt doppelt zu würfeln.

Preconditions:
Test-VM, laufender Stack, `.env`-Backup.

Actions:
```bash
sudo cp -a /opt/coder/.env /tmp/env-pre-pwreset
# künstliche Verzögerung einbauen (nur Test-Kopie des Skripts):
sudo cp /opt/coder/reset-passwords.sh /tmp/rp-delayed.sh
sudo sed -i 's|^sed -i "s|sleep 5; sed -i "s|' /tmp/rp-delayed.sh
sudo bash /tmp/rp-delayed.sh & RPPID=$!; sleep 2; sudo kill -TERM $RPPID; wait $RPPID; echo "rp-exit=$?"
ls -l /opt/coder/.env.bak.* 2>&1 || echo "no-bak"
sudo docker exec coder-postgres pg_isready -U coder -d coder && echo DB_OK || echo DB_FAIL
```

Expected result:
Warnung mit Reparaturanleitung, `.env.bak.*` (600, genau eine Generation
oder rotiert), DB-vs-`.env`-Konsistenz prüfbar.

Failure condition:
Still inkonsistent (DB=neu/`.env`=alt) ohne Meldung; `.bak`-Halde wächst
unbegrenzt; oder Grafana-Fenster unabgedeckt (P-018).

Cleanup:
`sudo cp -a /tmp/env-pre-pwreset /opt/coder/.env; sudo chmod 600 /opt/coder/.env`;
`sudo rm -f /tmp/rp-delayed.sh`; Stack neu starten und Login prüfen.

Findings: PLAN F-010, P-018, 01/F-005, 05/F-017, 06/F-013.

### T-034 – SSH-Abbruch / Reboot während Setup (01:00 vs. 03:00-Kollision)

Purpose:
Schlimmster Abbruchpfad: Reboot 03:00 während Lang-Dump/Setup (P-009/P-023).

Preconditions:
Test-VM, Snapshot.

Actions:
```bash
sudo bash /root/setup-coder.sh &
SETUPPID=$!
sleep 15; sudo reboot || true
# nach Reboot:
sleep 90
sudo docker compose -f /opt/coder/docker-compose.yml ps || true
cat /var/log/coder-boot.log 2>&1 || echo "no-boot-log (P-009-Lücke)"
ls -l /opt/coder/backups/ || true
sudo /root/setup-coder.sh >/tmp/rerun-afterreboot.log 2>&1; echo "rerun-exit=$?"
```

Expected result:
Boot-Gate-Log vorhanden, Re-Run heilt (Exit 0).

Failure condition:
Halbzustand ohne Diagnose; Re-Run bricht (F-001) oder zementiert Drift.

Cleanup:
Snapshot-Revert.

Findings: P-009, P-023, 03/F-002, 06/F-010/F-011.

---

## 5. Network failures

### T-040 – DNS nicht verfügbar (Setup + Re-Run-Heilung)

Purpose:
P-023(b): ohne DNS kein harter Fail, aber auch kein grünes „fertig";
Re-Run nach DNS heilt ohne Abbruch; Wildcard separat geprüft.

Preconditions:
Test-VM mit Snapshot; Zugang via Konsole (nicht nur SSH/DNS-abhängig).

Actions:
```bash
sudo cp /etc/resolv.conf /tmp/resolv.good
echo 'nameserver 192.0.2.1' | sudo tee /etc/resolv.conf
getent hosts coder.ghse-unterricht.de || echo "DNS_FAIL_AS_EXPECTED"
sudo timeout 120 /root/setup-coder.sh >/tmp/setup-nodns.log 2>&1; echo "exit=$?"
grep -E 'DNS|WARNUNG|FEHLER' /tmp/setup-nodns.log | head -20
sudo cp /tmp/resolv.good /etc/resolv.conf
sudo /root/setup-coder.sh >/tmp/rerun-afterdns.log 2>&1; echo "rerun-exit=$?"
```

Expected result:
Ohne DNS: Exit 0 mit WARN (kein `[FEHLER]`), kein „Erfolg"-Missverständnis
(Wiedervorlage-Hinweis im Log); nach DNS: Re-Run Exit 0, `/healthz` 200
sobald extern korrekt (oder dokumentierte WARN mit Caddy-Log-Hinweis).

Failure condition:
Setup bricht kommentarlos ab (`set -e`-Tod), oder meldet Erfolg ohne
HTTPS-Bestätigung als „fertig".

Cleanup:
`/etc/resolv.conf` wiederhergestellt (Prüfen!); Snapshot-Revert empfohlen.

Findings: P-023, 04-Zusammenfassung (DNS/Portforward-Doku).

### T-041 – Internet vollständig weg während apt/pull

Purpose:
Retry mit begrenzten Versuchen + klare Fehlermeldung statt Stillstand (P-023).

Preconditions:
Test-VM, Snapshot.

Actions:
```bash
sudo iptables -A OUTPUT -m owner ! --uid-owner root -j DROP 2>/dev/null || \
  sudo iptables -A OUTPUT -d 0.0.0.0/0 -j DROP
sudo timeout 120 /root/setup-coder.sh >/tmp/setup-noinet.log 2>&1; echo "exit=$?"
grep -iE 'retry|Fehler|failed|network|nicht erreichbar' /tmp/setup-noinet.log | head -20
sudo iptables -F OUTPUT
sudo /root/setup-coder.sh >/tmp/rerun-afterinet.log 2>&1; echo "rerun-exit=$?"
```

Expected result:
Klarer Fail (Exit ≠ 0 mit Ursache), kein Hängen ohne Timeout; nach Netz:
Re-Run Exit 0.

Failure condition:
Hängen > Timeout ohne Meldung, oder Weiterlaufen „als wäre nichts".

Cleanup:
`sudo iptables -F OUTPUT` zwingend prüfen (`sudo iptables -S OUTPUT`).

Findings: P-023.

### T-042 – Docker-Registry nicht erreichbar / Image-Pull scheitert

Purpose:
`pull`-Fehler als klarer Fehler, kein Teil-Stack als „grün".

Preconditions:
Test-VM, Stack läuft.

Actions:
```bash
sudo iptables -A OUTPUT -d registry-1.docker.io -j DROP
sudo iptables -A OUTPUT -d ghcr.io -j DROP
sudo docker compose -f /opt/coder/docker-compose.yml pull; echo "pull-exit=$? (muss != 0)"
sudo iptables -D OUTPUT -d registry-1.docker.io -j DROP
sudo iptables -D OUTPUT -d ghcr.io -j DROP
```

Expected result:
`pull-exit != 0` mit klarer Registry-Fehlermeldung.

Failure condition:
Exit 0 trotz unerreichbarer Registry, oder korrupter Teil-Pull als ok.

Cleanup:
iptables-Regeln entfernt prüfen; `sudo docker compose pull` erfolgreich
nachholen.

Findings: P-023, 02/F-013 (Supply-Chain-Seite).

### T-043 – GPG-Key ohne Fingerprint-Prüfung (K1/F-018-Nachweis)

Purpose:
Belegen, dass Bootstrap ohne Out-of-Band-Fingerprint läuft (02/F-014);
nach Fix: Fingerprint-Check im Setup.

Preconditions:
Code-Lesung + Test-VM mit Netz.

Actions:
```bash
grep -n 'gpg --dearmor\| Fingerprint\|fingerprint' /root/setup-coder.sh || echo "no-fingerprint-check"
apt-key list 2>/dev/null || gpg --show-keys /etc/apt/keyrings/docker.gpg 2>&1 | head
# nach Fix zusätzlich: Fingerprint-Vergleich gegen offiziell dokumentierten Wert im Setup-Log prüfen
```

Expected result:
`no-fingerprint-check` (Lücke dokumentiert, K1-Versprechen offen).

Failure condition:
Setup verifiziert Fingerprint und bricht bei Mismatch mit Exit ≠ 0 ab.

Cleanup:
Keins.

Findings: P-023, K1, 02/F-014.

### T-044 – ACME/LE nicht erreichbar (Port 80 blockiert, DNS ok)

Purpose:
Caddy versucht im Hintergrund weiter; Setup meldet WARN statt Fehler
(Doku-Verhalten), aber mit Wiedervorlage.

Preconditions:
Testdomain mit DNS, aber Port 80/443 inbound blockiert (Schulnetz-Simulation
via Host-Firewall).

Actions:
```bash
sudo timeout 60 curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "https://coder-testdomain/healthz" || echo "code=000"
sudo docker compose -f /opt/coder/docker-compose.yml logs caddy --tail=50 | grep -iE 'obtaining|error|acme|challenge' || true
```

Expected result:
Kein HTTP 200, WARN im Setup-Log mit Caddy-Log-Hinweis, Exit 0
(per Design), aber kein „fertig"-Eindruck.

Failure condition:
Grünes „Erfolg" ohne Hinweis, oder harter Fail obwohl Doku WARN verspricht.

Cleanup:
Firewall-Regel entfernen.

Findings: P-023, 04-TLS-Summary.

### T-045 – Cron-Umgebung mit minimalem PATH (P-017)

Purpose:
`backup.sh` muss auch mit Cron-PATH (`/usr/bin:/bin`) grün sein: absolute
Pfade oder PATH-Export.

Preconditions:
Stack läuft.

Actions:
```bash
sudo env -i PATH=/usr/bin:/bin SHELL=/bin/sh /opt/coder/backup.sh; echo "cronpath-exit=$?"
ls -t /opt/coder/backups/coder_*.sql.gz | head -n1 | xargs gzip -t && echo GZIP_OK
```

Expected result:
`cronpath-exit=0`, `GZIP_OK`.

Failure condition:
`docker: command not found` o. ä. (PATH-Lücke P-017).

Cleanup:
Test-Backup nach Retention-Regel belassen oder löschen (dann aber
Mindestbestand beachten, T-075).

Findings: PLAN F-009, P-017, 05/F-006.

---

## 6. Docker failures

### T-050 – Image-Pull mit falscher `CODER_VERSION` schlägt selbst fehl

Purpose:
F-012/P-020: Fehl-Update fällt durch Gate auf, nicht erst durch
Nutzerbeschwerde.

Preconditions:
Test-VM, Snapshot.

Actions:
```bash
sudo CODER_VERSION=v9.99.99-never-exists docker compose -f /opt/coder/docker-compose.yml pull; echo "pull-exit=$? (muss != 0)"
sudo CODER_VERSION=v9.99.99-never-exists /opt/coder/update.sh >/tmp/update-badver.log 2>&1; echo "update-exit=$? (muss != 0 nach Fix)"
grep -iE 'health|FEHLER|failed|error' /tmp/update-badver.log | head
```

Expected result:
Update-Skript exitt ≠ 0 (Pull-Fail oder Health-Gate), kein stilles „Erfolg".

Failure condition:
Exit 0 trotz falscher Version (Ist-Lücke).

Cleanup:
Snapshot-Revert (Stack kann auf Bad-Image zeigen).

Findings: PLAN F-012, P-020, 05/F-010, 06/F-004.

### T-051 – Container startet nicht (Coder crash-loop simuliert)

Purpose:
Gate erkennt Fehl-Update; Boot-/Update-Log zeigt Ursache.

Preconditions:
Test-VM.

Actions:
```bash
sudo docker compose -f /opt/coder/docker-compose.yml stop coder
sudo docker compose -f /opt/coder/docker-compose.yml up -d coder || true
sudo docker compose -f /opt/coder/docker-compose.yml ps coder
sudo docker logs coder --tail=30 || true
```

Expected result:
`ps` zeigt Fehlerzustand (exit/restarting), Logs mit Ursache; Health-Gate
(nach Fix) meldet Fail.

Failure condition:
Abschlusscheck meldet `[OK] Coder läuft` obwohl Crash-Loop.

Cleanup:
`sudo docker compose -f /opt/coder/docker-compose.yml up -d coder`.

Findings: PLAN F-007/F-012, P-009, 03/F-002.

### T-052 – PostgreSQL wird unhealthy (Health-Gate + Coder-Verhalten)

Purpose:
`service_healthy`-Kette beweisen; Reboot-Crash-Loop dokumentieren (P-009).

Preconditions:
Test-VM, Stack gesund.

Actions:
```bash
sudo docker compose -f /opt/coder/docker-compose.yml stop postgres
sleep 5
sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>&1 || echo "pg-down"
sudo docker logs coder --tail=20 | grep -iE 'connect|password|postgres|error' || true
sudo docker compose -f /opt/coder/docker-compose.yml start postgres
for i in $(seq 1 30); do
  [ "$(sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null)" = healthy ] && break
  sleep 2
done
sudo docker inspect -f '{{.State.Health.Status}}' coder-postgres
sudo docker logs coder --tail=20 | grep -iE 'recover|connect|ready' || true
```

Expected result:
PG down → Coder-Logs mit Verbindungsfehlern; nach Start: PG `healthy`,
Coder selbstheilend (Crash-Loop endet). Boot-Gate (nach Fix) protokolliert.

Failure condition:
PG bleibt `unhealthy` ohne Diagnose, oder Coder-Loop ohne Ende ohne Log.

Cleanup:
Stack-Neustart, `pg_isready`-Check.

Findings: PLAN F-012, P-009, 03/F-002.

### T-053 – `CADDY_VERSION`-Wechsel + `prune -f`: altes Image weg? (03/F-001)

Purpose:
Prune-Mechanik beweisen: bewegliche Tags → altes Image dangling → `prune -f`
löscht (Kommentar-Versprechen falsch für Caddy/Postgres).

Preconditions:
Test-VM mit Netz, zwei reale Caddy-Tags bekannt (z. B. `2.10`, `2.9` –
vorher `docker manifest inspect` prüfen), Snapshot.

Actions:
```bash
sudo docker images caddy --format '{{.Repository}}:{{.Tag}} {{.ID}}' | tee /tmp/img-before.log
# update.sh-Pfad mit zwei Versionen fahren (nur Test-VM!):
sudo CADDY_VERSION=2.9 /root/setup-coder.sh >/tmp/setup-caddy29.log 2>&1; echo "exit29=$?"
sudo docker images caddy --format '{{.Repository}}:{{.Tag}} {{.ID}}' | tee /tmp/img-mid.log
sudo /opt/coder/update.sh >/tmp/update-prune.log 2>&1; echo "update-exit=$?"
sudo docker images --filter dangling=true --format '{{.ID}}' | tee /tmp/dangling.log
grep -iE 'prune' /tmp/update-prune.log | head
echo '--- Soll (nach Doku-Korrektur): für Caddy/Postgres ist altes Image weg ODER Guard (until-Filter) hält es ---'
```

Expected result:
Altes Caddy-Image nach `prune -f` weg (Rollback braucht Re-Pull) –
Kommentar-Korrektur erforderlich; nach Prune-Guard-Fix: altes Image
innerhalb `until`-Fenster noch da.

Failure condition:
Unklarer Zustand (weder dokumentiert weg mit Re-Pull-Nachweis noch da).

Cleanup:
Snapshot-Revert; `CADDY_VERSION` zurück auf Default, Re-Run.

Findings: PLAN F-012, P-020, 03/F-001, 06/F-004.

---

## 7. Security

### T-060 – Externe Ports (externer Scan + `ss` + `DOCKER-USER`-Abgleich)

Purpose:
Beabsichtigt öffentlich (22/80/443+udp) vs. versehentlich öffentlich
(9090/9100/3001/Workspace-Ports) trennen (P-004, 02/F-008/F-009).

Preconditions:
Stack läuft; Scanner-Host mit `nmap`, Ziel-IP bekannt; Schulnetz-NAT
dokumentiert.

Actions:
```bash
# auf Zielhost:
ss -tlnp | tee /tmp/ss-ports.log
sudo iptables-save | grep -E 'DOCKER-USER|DOCKER' | tee /tmp/iptables-docker.log || true
# auf Scanner-Host (extern):
nmap -sS -Pn -p 22,80,443,9090,9100,3001 <ZIEL-IP>
nmap -sU -Pn -p 443 <ZIEL-IP>
```

Expected result:
Extern offen: 22/80/443 tcp + 443 udp (sofern weitergeleitet);
geschlossen/gefiltert: 9090/9100/3001. `DOCKER-USER`: derzeit abwesend
(Lücke dokumentiert, P-004).

Failure condition:
9090/9100/3001 extern offen, oder unbekannter dynamischer Workspace-Port
extern offen ohne Caddy-Proxy.

Cleanup:
Scan-Logs archivieren.

Findings: P-004, 02/F-008/F-009, 06/F-006.

### T-061 – SSH: effektive Config, Key-only-Pfad, fail2ban-Ban

Purpose:
P-003: Ist-Zustand (Passwort aktiv + weltweit) belegen; nach Härtung:
Passwort-Login scheitert, Key gelingt, Ban greift. Nie ohne Zweit-Zugang
auf Produktion.

Preconditions:
Test-VM mit SSH; zweiter Zugang (Konsole) vorhanden.

Actions:
```bash
sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'
sudo ufw status | grep -E '22/tcp'
sudo fail2ban-client status sshd
# Negativprobe Ban (nur Test-VM, eigene IP danach entbannen!):
# for i in $(seq 1 6); do ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no testuser@<VM> || true; done
# sudo fail2ban-client status sshd | grep -E 'Banned'
```

Expected result:
`passwordauthentication yes` (WARN, Setup Exit 0) – Provisorium
dokumentiert mit Termin/Eigentümer (P-003-Forderung).
Nach `ssh-harden.sh` (mit Zweit-Zugang): `no`/`no`, externer
Passwort-Login scheitert, Key-Login gelingt.

Failure condition:
Härtung ohne Zweit-Zugang (Aussperrung), oder Passwort-Login gelingt nach
angeblicher Härtung.

Cleanup:
Eigene Test-IP entbannen (`sudo fail2ban-client set sshd unbanip <IP>`).

Findings: P-003, 02/F-007, 06/F-012.

### T-062 – UFW-Regeln + `ufw`-vor-`enable`-Guard

Purpose:
SSH-Limit vor Enable, 80/443-Doku-Charakter (P-025, 03/F-012).

Preconditions:
Test-VM.

Actions:
```bash
sudo ufw status verbose
sudo ufw status | grep -q '22/tcp.*LIMIT' && echo SSH_LIMIT_OK || echo SSH_LIMIT_MISSING
sudo ufw status | grep -E '80/tcp|443/tcp|443/udp'
```

Expected result:
`active`, `22/tcp LIMIT`, 80/443-Einträge vorhanden (als Doku, nicht als
Container-Schutz – Kommentar im Skript korrekt).

Failure condition:
`inactive`, oder `22/tcp ALLOW` ohne LIMIT, oder Enable ohne SSH-Regel
(Lockout-Risiko).

Cleanup:
Keins.

Findings: P-004/P-025, 02/F-008, 03/F-012.

### T-063 – Docker-Socket: Mount-Nachweis + Workspace-Selbsttest (CRITICAL)

Purpose:
P-002: Socket = Host-root-äquivalent belegen; Allowlist-Stufe prüfen;
Workspace darf Socket weder sehen noch nutzen, `postgres:5432` nicht
erreichen, fremde Workspace-Container nicht inspizieren.

Preconditions:
Stack läuft; normaler (unprivilegierter) Test-Workspace in Coder angelegt.

Actions:
```bash
# Host/Compose-Seite:
sudo docker inspect coder --format '{{json .Mounts}}' | grep -o 'docker.sock' && echo SOCKET_MOUNTED
sudo docker inspect coder --format '{{json .HostConfig.GroupAdd}}'
# Workspace-Seite (im normalen Workspace-Terminal):
mount | grep -i 'docker.sock' && echo WS_SOCKET_VISIBLE || echo WS_SOCKET_HIDDEN
ls -l /var/run/docker.sock 2>&1 || echo "no-ws-socket (gut)"
getent hosts postgres || echo "postgres-nicht-aufgelöst (gut)"
(timeout 5 bash -c '</dev/tcp/postgres/5432') 2>&1 && echo PG_REACHABLE || echo PG_UNREACHABLE
docker ps 2>&1 | head -3 || echo "kein-docker-im-workspace (gut)"
```

Expected result:
`SOCKET_MOUNTED` nur im `coder`-Container (bekannt, P-002-Restrisiko mit
D1-Entscheidung); im Workspace: `WS_SOCKET_HIDDEN`, `PG_UNREACHABLE`,
kein Docker-Zugriff, Fremd-Container unsichtbar.

Failure condition:
Workspace sieht Socket, erreicht `postgres:5432`, oder kann fremde
Container inspizieren (Allowlist-Verletzung).

Cleanup:
Test-Workspace löschen.

Findings: P-002, 02/F-001–F-004, 06/F-005.

### T-064 – Template-Allowlist-Abhak-Test (pro neuem Template)

Purpose:
06/F-005-Stufe-1 ohne Host-Umbau: jedes Template gegen
`templates/allowlist.md` geprüft (verboten: Socket-Mount, privileged,
Host-PID/-Netz, Host-Root-Mounts, gemeinsame Netze mit `postgres`).

Preconditions:
`templates/allowlist.md` im Repo (nach Fix); Test-Template-Definition.

Actions:
```bash
grep -iE 'docker.sock|privileged|pid:\s*host|network_mode:\s*host|/:\s*|postgres' <TEMPLATE.tf> && echo TEMPLATE_SUSPECT || echo TEMPLATE_CLEAN
# manuell: Checkliste abhaken, Reviewer + Datum notieren
```

Expected result:
`TEMPLATE_CLEAN` + abgehakte Checkliste im PR.

Failure condition:
Verbotene Option vorhanden und trotzdem freigegeben.

Cleanup:
Keins.

Findings: P-002, 02/F-002, 06/F-005.

### T-065 – Dateirechte (`.env` 600, Backups 600/700, Cron 644, Skripte +x)

Purpose:
Rechte-Ist-Zustand beweisen (02/F-015/F-016-Seite, F-006).

Preconditions:
T-010 grün.

Actions:
```bash
stat -c '%a %U:%G %n' /opt/coder/.env /opt/coder/backups /opt/coder/backups/coder_*.sql.gz | sed 's/hex[^ ]*/<redacted>/'
stat -c '%a %n' /etc/cron.d/coder-backup /opt/coder/*.sh
sudo -u nobody cat /opt/coder/.env 2>&1 && echo SECRET_LEAK || echo SECRET_PROTECTED
```

Expected result:
`.env 600 root:root`, `backups 700`, Dumps `600`, cron `644`,
Skripte `+x`; `SECRET_PROTECTED`.

Failure condition:
Breitere Rechte, oder lesbar als `nobody`.

Cleanup:
Keins.

Findings: PLAN F-006, P-010, 02/F-015/F-016, 05/F-001.

### T-066 – Secrets-Hygiene (`inspect`/History/Journal/Logs ohne Klartext)

Purpose:
02/F-015: keine Re-Ausgabe nach Erstlauf; `inspect`/Logs auf Secret-Muster
prüfen; Rotation nach Offenlegung.

Preconditions:
Stack läuft.

Actions:
```bash
sudo docker inspect coder | grep -iE 'password|PG_CONNECTION' | sed -E 's/(password.|:[^@:]*@)/\1<redacted>/i' | head
sudo grep -rE 'POSTGRES_PASSWORD=.+' /var/log/coder-backup.log 2>&1 | head -3 || echo "no-secret-in-backup-log"
history | grep -iE 'password' | head -3 || echo "no-secret-in-history"
sudo journalctl -u docker --no-pager -n 200 2>&1 | grep -iE 'POSTGRES_PASSWORD' | head -3 || echo "no-secret-in-journal"
```

Expected result:
Secrets nur als Container-Env (bekannt, Docker-Admin = voll privilegiert,
dokumentiert), sonst nirgends im Klartext; keine Re-Ausgabe nach Erstlauf.

Failure condition:
Klartext-Passwort in Backup-Log/History/Journal/Ticket-Kopie.

Cleanup:
Befund rotiert Passwort via `reset-passwords.sh` (nur Test-VM, danach
Konsistenz prüfen).

Findings: P-024, 02/F-015, 06/F-013.

### T-067 – Logging-Limits (`LogConfig`) + Log-Flut-Rotationstest

Purpose:
P-007/03/F-004: `json-file` begrenzt (`max-size`/`max-file`), sonst
Plattenkiller Nr. 1.

Preconditions:
Stack läuft (vor Fix: Lücke dokumentieren; nach Fix: Nachweis).

Actions:
```bash
for c in coder coder-caddy coder-postgres coder-prometheus coder-node-exporter coder-grafana; do
  printf '%s: ' "$c"; sudo docker inspect --format '{{json .HostConfig.LogConfig}}' "$c"
done
# Flut-Test (nur Test-VM, nach Fix):
# sudo docker exec coder sh -c 'yes FLOOD | head -n 200000 >&2' || true
# ls -lh /var/lib/docker/containers/*/*-json.log | head
```

Expected result:
`{"Type":"json-file","Config":{"max-file":"3","max-size":"10m"}}` o. ä.
pro Service; Flut rotiert statt zu wachsen.

Failure condition:
`{"Type":"json-file","Config":{}}` (unbegrenzt) – P-007 offen.

Cleanup:
Flut-Logs rotieren lassen; keine manuellen Deletes im Daemon-Verzeichnis.

Findings: P-007, 03/F-004, 06/F-016.

### T-068 – `node-exporter`-Privilegien (`pid: host`-Hygiene, 03/F-007/K3)

Purpose:
K3-Entscheidung (LOW/Hygiene) verifizieren: ohne `processes`-Collector
kein `pid: host` nötig; Mounts ro; Ports loopback.

Preconditions:
Compose-Datei lesbar.

Actions:
```bash
grep -A8 'node-exporter:' /opt/coder/docker-compose.yml | grep -E 'pid:|collector|path\.'
curl -s --max-time 5 http://127.0.0.1:9100/metrics | grep -cE '^node_(cpu|memory|filesystem)' || true
curl -s --max-time 5 http://127.0.0.1:9100/metrics | grep -c '^node_processes' || echo "no-process-metrics"
```

Expected result:
Entweder `pid: host` entfernt und Standard-Metriken weiter da, oder
bewusst behalten + `--collector.processes` + Dashboard-Nutzung belegt.

Failure condition:
`pid: host` ohne genutzten Zweck und ohne Begründung (Hygiene offen).

Cleanup:
Keins.

Findings: K3, 02/F-006, 03/F-007.

### T-069 – Destruktiv-Guard (`sudo -l`, Rechte, Audit, kein Auto-Reset)

Purpose:
02/F-017: keine pauschalen sudo-Rechte auf Wartungsskripte; Reset nur per
Operator + Break-Glass.

Preconditions:
Test-VM.

Actions:
```bash
sudo -l | tee /tmp/sudo-l.log
ls -l /opt/coder/*.sh
grep -rE 'reset-coder|update\.sh' /etc/cron* /var/spool/cron/* 2>&1 || echo "no-auto-destructive-cron (gut)"
```

Expected result:
Keine `NOPASSWD`-Freigabe für Skripte an untrusted User; kein Cron für
`update.sh`/`reset-coder.sh`.

Failure condition:
Pauschal-Sudo oder Auto-Reset/Update per Cron.

Cleanup:
`rm -f /tmp/sudo-l.log` nach Archivierung.

Findings: 02/F-017, P-019, 06/F-014.

---

## 8. Backup

### T-070 – Backup erzeugen + `gzip -t` + Plausibilität

Purpose:
Basispfad: `backup.sh` grün, Datei gültig (F-005/05/F-003).

Preconditions:
Stack läuft, Postgres healthy.

Actions:
```bash
sudo /opt/coder/backup.sh; echo "backup-exit=$?"
LATEST=$(ls -t /opt/coder/backups/coder_*.sql.gz | head -n1)
echo "latest=$LATEST"; ls -lh "$LATEST"
gzip -t "$LATEST" && echo GZIP_OK
stat -c %s "$LATEST"
```

Expected result:
Exit 0, `GZIP_OK`, Größe > 0 (Warnschwelle bei Mini-Dump siehe T-071).

Failure condition:
Exit ≠ 0, oder `gzip -t` rot, oder keine Datei.

Cleanup:
Datei behalten (Retention beachten).

Findings: PLAN F-005, P-013, 01/F-003, 05/F-003.

### T-071 – Größen-/Leerheits-Semantik (kein harter Fail bei legitimer Verkleinerung)

Purpose:
P-013: Warnung statt Fail bei `< 50 %`; leeres stdin → Warnung, nicht
still OK; frische DB (~1–2 KiB) darf nicht fälschlich scheitern.

Preconditions:
Test-VM.

Actions:
```bash
# leeres stdin simuliert (nur Test-Verzeichnis, nie Prod-Backup überschreiben!):
printf '' | gzip > /tmp/empty-test.sql.gz; gzip -t /tmp/empty-test.sql.gz && echo EMPTY_GZIP_VALID
stat -c %s /tmp/empty-test.sql.gz
LATEST=$(ls -t /opt/coder/backups/coder_*.sql.gz | head -n1); stat -c %s "$LATEST"
```

Expected result:
Leeres/Mini-Archiv → Warnung im Log, kein stilles OK; halbierte DB
(legitime Verkleinerung) → kein harter Fail.

Failure condition:
Leerer Dump als „Erfolg" ohne Warnung, oder frische Installation scheitert
an `> 1 KiB`-Hartschwelle (P-013-Fehlertyp).

Cleanup:
`rm -f /tmp/empty-test.sql.gz`.

Findings: PLAN F-005, P-013, 05/F-003.

### T-072 – Abbruch mitten im Stream hinterlässt keine Finaldatei

Purpose:
F-005-Kern: Temp gleiche Partition + `mv`; Fake-`pg_dump` bricht nach
N Bytes ab → keine Datei unter finalem Namen.

Preconditions:
Test-VM; nur Test-Kopie von `backup.sh`-Logik (nie Prod-`docker`-Binary
ersetzen – stattdessen Wrapper-PATH).

Actions:
```bash
mkdir -p /tmp/fakebin
printf '#!/bin/bash\necho PARTIAL-DATA; echo PARTIAL-DATA; exit 1\n' > /tmp/fakebin/docker
chmod +x /tmp/fakebin/docker
BEFORE=$(ls /opt/coder/backups/coder_*.sql.gz 2>/dev/null | wc -l)
PATH=/tmp/fakebin:$PATH sudo -E bash -c 'PATH=/tmp/fakebin:$PATH /opt/coder/backup.sh'; echo "exit=$? (muss != 0)"
AFTER=$(ls /opt/coder/backups/coder_*.sql.gz 2>/dev/null | wc -l)
echo "before=$BEFORE after=$AFTER (muss gleich sein)"
ls -t /opt/coder/backups/ | head -5
```

Expected result:
Exit ≠ 0, `before == after`, keine partielle Finaldatei (Temp entfernt).

Failure condition:
Defekte Datei unter gültigem Namen bleibt liegen (Ist-Lücke).

Cleanup:
`rm -rf /tmp/fakebin`; keine Fake-Artefakte in `/opt/coder/backups`
belassen (ggf. jüngste partielle Datei nach Prüfung löschen und im
Protokoll vermerken).

Findings: PLAN F-005, 01/F-003, 05/F-003.

### T-073 – Volles Dateisystem simuliert (tmpfs, ENOSPC ohne partielle Finaldatei)

Purpose:
P-007/05/F-016: `df`-Vorabcheck bricht klar ab; keine partielle Finaldatei.

Preconditions:
Test-VM; kleines tmpfs möglich.

Actions:
```bash
sudo mkdir -p /tmp/fulltest && sudo mount -t tmpfs -o size=5M tmpfs /tmp/fulltest
dd if=/dev/zero of=/tmp/fulltest/fill bs=1M count=4 2>&1 | tail -1
df -h /tmp/fulltest
# backup.sh gegen volles Ziel (nur Test-Zielverzeichnis, via Kopie mit BACKUP_DIR-Override falls unterstützt; sonst df-Check-Codepfad lesen):
grep -n 'df\|ENOSPC\|freier Platz\|Mindestplatz' /opt/coder/backup.sh || echo "no-df-gate (P-007-Lücke)"
sudo umount /tmp/fulltest
```

Expected result:
Klarer Abbruch („zu wenig Platz") ohne partielle Finaldatei, `logger`-Zeile.

Failure condition:
Partielle Datei + versandete Cron-Fehlermeldung (Ist-Zustand).

Cleanup:
`sudo umount /tmp/fulltest 2>/dev/null || true`.

Findings: P-007, 05/F-016, PLAN F-005.

### T-074 – Timestamp-Kollision + `flock`-Parallelität

Purpose:
F-004/F-009: Sekunden-Timestamp + `flock -n`; zweiter paralleler Lauf
bricht sauber ab statt zu trunkieren.

Preconditions:
Stack läuft.

Actions:
```bash
grep -n 'TIMESTAMP=\|flock' /opt/coder/backup.sh /etc/cron.d/coder-backup || echo "no-flock-no-seconds (Lücke)"
sudo /opt/coder/backup.sh & P1=$!
sleep 1; sudo /opt/coder/backup.sh & P2=$!
wait $P1; echo "p1=$?"; wait $P2; echo "p2=$? (nach Fix: einer 0, einer sauberer Abort mit Meldung)"
LATEST=$(ls -t /opt/coder/backups/coder_*.sql.gz | head -n1); gzip -t "$LATEST" && echo GZIP_OK
```

Expected result:
Minutengleichheit unmöglich (Sekunden); paralleler Zweitlauf: definierter
Abort (Exit + `logger` „übersprungen"), erste Datei `gzip -t`-gültig,
keine trunkierte Zweitdatei.

Failure condition:
Beide schreiben dieselbe Minutendatei per `>` und trunkieren einander.

Cleanup:
Überzählige Test-Backups nach Retention-Regel aufräumen.

Findings: PLAN F-009, P-017, 05/F-004/F-006, 06/F-011.

### T-075 – Retention: Stückzahl statt Alter + Mindestbestand + Lückenszenario

Purpose:
F-008: neueste 14 behalten; Lücke (> 14 Tage alt + ein neues) löscht
Altbestand nicht komplett; nur gültige zählen (F-005-Kopplung).

Preconditions:
Isoliertes Testverzeichnis (nie `/opt/coder/backups` direkt faken ohne
Snapshot).

Actions:
```bash
mkdir -p /tmp/ret-test && cd /tmp/ret-test
for i in $(seq 1 20); do f="coder_2026-01-$(printf '%02d' $i)_0100.sql.gz"; printf 'x' | gzip > "$f"; touch -d "$i days ago" "$f"; done
ls | wc -l
# Rotationszeile aus backup.sh hier trocken nachstellen (nach Fix: stückzahlbasiert):
ls -t coder_*.sql.gz | tail -n +15 | tee /tmp/would-delete.log | wc -l
echo '--- Erwartung nach Fix: genau 6 Löschkandidaten (20 -> 14 neueste) ---'
# Lückenszenario:
mkdir -p /tmp/ret-gap && cd /tmp/ret-gap
for i in 20 25 30; do f="coder_old_$i.sql.gz"; printf 'x' | gzip > "$f"; touch -d "$i days ago" "$f"; done
printf 'x' | gzip > "coder_fresh.sql.gz"
echo '--- Erwartung: Altbestand bleibt (Mindestbestand), kein Komplett-Löschen ---'
```

Expected result:
20 → 14 neueste; Gap-Case: kein Totalverlust.

Failure condition:
`find -mtime +14 -delete` löscht nach Alter inkl. Gesamt-Historie nach
Lücke (Retention-Cliff).

Cleanup:
`rm -rf /tmp/ret-test /tmp/ret-gap /tmp/would-delete.log`.

Findings: PLAN F-008, P-013, 05/F-005.

### T-076 – Cron-Daemon installiert, aktiv, Datei vorhanden

Purpose:
F-009(a): auf Minimal-VM läuft Backup sonst still nie.

Preconditions:
Frische Minimal-Test-VM nach Setup.

Actions:
```bash
systemctl is-active cron && echo CRON_ACTIVE || echo CRON_MISSING
cat /etc/cron.d/coder-backup
apt-cache policy cron | head -5
```

Expected result:
`CRON_ACTIVE`, Datei vorhanden, Paketbezug trixie belegt.

Failure condition:
`CRON_MISSING` bei `[OK]`-Meldung im Setup (Totalausfall ohne Meldung).

Cleanup:
Keins.

Findings: PLAN F-009, 05/F-006, 06/F-011.

### T-077 – `coder-backup.log`: Rotation + `logger`-Signal statt stiller Defekt

Purpose:
05/F-007: `logrotate` gegen Wachstum; Fehler erzeugen Signal (nicht nur
Log-Datei).

Preconditions:
Test-VM.

Actions:
```bash
ls -lh /var/log/coder-backup.log
cat /etc/logrotate.d/coder-backup 2>&1 || echo "no-logrotate (Lücke)"
sudo logrotate --debug /etc/logrotate.d/coder-backup 2>&1 | head -20 || true
# Fehlschlag simulieren:
sudo docker compose -f /opt/coder/docker-compose.yml stop postgres
sudo /opt/coder/backup.sh; echo "fail-exit=$? (muss != 0)"
sudo docker compose -f /opt/coder/docker-compose.yml start postgres
journalctl --no-pager -n 5 2>&1 | grep -i coder || echo "no-logger-signal (Lücke)"
```

Expected result:
`fail-exit != 0` + `logger`-Zeile/Journal + `logrotate --debug` grün.

Failure condition:
Nur Log-Datei wächst, kein Signal, kein `logrotate`.

Cleanup:
Postgres wieder healthy warten; Logzeilen protokollieren.

Findings: P-007, 05/F-007, 06/F-007.

### T-078 – Backup-Umfangslücke belegen (nur DB, Rest fehlt)

Purpose:
P-024/05/F-001: frische VM nur aus Backup → was fehlt, wird protokolliert
(Dump allein ≠ Server-Backup).

Preconditions:
Laufender Stack mit Backup.

Actions:
```bash
LATEST=$(ls -t /opt/coder/backups/coder_*.sql.gz | head -n1)
echo "backup=$LATEST"
tar -tzf "$LATEST" 2>&1 | head -3 || echo "(kein Tar, pg_dump-Text erwartet)"
zcat "$LATEST" | head -20 | grep -iE 'PostgreSQL|CREATE|COPY' | head -5
echo '--- Nicht im Backup (erwartet, Gap): .env, compose/caddy/prometheus-Config, caddy_data, grafana_data, Workspace-Dateien ---'
ls /opt/coder/.env /opt/coder/docker-compose.yml /opt/coder/Caddyfile
```

Expected result:
Dump enthält DB-Text; Gap-Liste protokolliert als bekannte Lücke
(bis F-002/F-003-Umfang entschieden, D6/D5).

Failure condition:
Behauptung „vollständiges Server-Backup" trotz nur-DB-Inhalt.

Cleanup:
Keins.

Findings: P-024, 05/F-001/F-009/F-014/F-015, 06/F-008.

### T-079 – TSDB-Retention: `retention.size`-Grenze (200-MB-Probe)

Purpose:
P-007/03/F-008: Zeit allein schützt nicht vor Kardinalitäts-Spike.

Preconditions:
Test-VM.

Actions:
```bash
grep -n 'retention' /opt/coder/docker-compose.yml
# Probe nur Test-VM (nach Fix): retention.size=200MB setzen, up -d prometheus,
# Log auf "retention" beobachten:
# sudo docker compose -f /opt/coder/docker-compose.yml logs prometheus --tail=30 | grep -i reten || true
```

Expected result:
`retention.time` + `retention.size` gesetzt (Wert an Platte angepasst,
kein Fantasiewert ohne Messung).

Failure condition:
Nur `retention.time`, kein `size` (Lücke).

Cleanup:
Probe-Wert zurücksetzen, `up -d prometheus`.

Findings: P-007, 03/F-008, 06/F-016.

---

## 9. Restore

### T-080 – Restore in Wegwerf-Postgres (Mini-Restore statt nur `gzip -t`)

Purpose:
AGENTS.md-Pflicht: Backup-Datei ≠ Backup-Erfolg; SQL-Gültigkeit über
`gzip -t` hinaus (P-013/05/F-003).

Preconditions:
Gültiges Backup vorhanden; Docker verfügbar.

Actions:
```bash
LATEST=$(ls -t /opt/coder/backups/coder_*.sql.gz | head -n1)
sudo docker run --rm -d --name pg-restore-test -e POSTGRES_PASSWORD=test -e POSTGRES_USER=coder -e POSTGRES_DB=coder postgres:15-alpine
sleep 8
zcat "$LATEST" | sudo docker exec -i pg-restore-test psql -U coder -d coder; echo "restore-exit=$?"
sudo docker exec pg-restore-test psql -U coder -d coder -c '\dt' | head -20
sudo docker stop pg-restore-test
```

Expected result:
`restore-exit=0`, Tabellen vorhanden (`\dt` nicht leer).

Failure condition:
`gzip -t` grün aber `psql` rot (korruptes/leeres SQL) – dann ist F-005
ungelöst.

Cleanup:
`sudo docker rm -f pg-restore-test 2>/dev/null || true`.

Findings: PLAN F-003/F-005, P-013/P-015, 05/F-003/F-008.

### T-081 – Restore nach `.env`-Verlust (Passwort-Puzzle mit Runbook)

Purpose:
05/F-009: Dump + neue `.env` → Runbook heilt (Passwort-Abgleich,
Leer-Schema, Migrationen). Derzeit: Gap.

Preconditions:
Test-VM, Snapshot, Backup + alte `.env` gesichert.

Actions:
```bash
sudo cp -a /opt/coder/.env /tmp/env-orig-restore
LATEST=$(ls -t /opt/coder/backups/coder_*.sql.gz | head -n1); echo "dump=$LATEST"
# .env-Verlust simulieren:
sudo rm -f /opt/coder/.env
sudo /root/setup-coder.sh >/tmp/setup-newenv.log 2>&1; echo "setup-exit=$?"
# Runbook-Schritt (nach F-003-Runbook, derzeit manuell):
# 1) Stack hoch, 2) Coder stoppen, 3) Dump einspielen, 4) Passwort-Abgleich, 5) Login-Verifikation
# Ergebnis + RTO stoppen:
date +%s | tee /tmp/restore-start
```

Expected result:
Wiederherstellung mit gemessener RTO-Zahl (Sekunden + Datum + Version),
Coder-Login grün.

Failure condition:
Improvisation ohne Verfahren (RTO unbekannt/maximal) – als Gap
protokollieren, nicht als Pass werten.

Cleanup:
`/tmp/env-orig-restore` zurückspielen oder Snapshot-Revert.

Findings: PLAN F-003, P-015, 05/F-008/F-009.

### T-082 – Vollständige Coder-Wiederherstellung mit RTO-Messung (frische VM)

Purpose:
F-002/F-003/P-014/P-015: Snapshot verwerfen → nur aus Offsite + Runbook
wiederherstellen, Zeit stoppen (= RTO), Login prüfen. Nie Produktion.

Preconditions:
Frische Test-VM Nr. 2; Offsite-Kopie (nach D6) + Runbook (nach F-003);
Testdaten in VM Nr. 1 (User, Template, Workspace, Datei).

Actions:
```bash
date +%s | tee /tmp/rto-start
# 1) setup-coder.sh auf frischer VM (neue .env)
# 2) Stack hoch, Coder stoppen: sudo docker compose -f /opt/coder/docker-compose.yml stop coder
# 3) Offsite-Dump einspielen (exakter psql-Befehl aus Runbook)
# 4) Passwort-Abgleich (.env vs. DB)
# 5) Coder starten, Login prüfen: curl -s -o /dev/null -w '%{http_code}\n' https://<TESTDOMAIN>/healthz
date +%s | tee /tmp/rto-end
python3 -c "s=int(open('/tmp/rto-start').read()); e=int(open('/tmp/rto-end').read()); print('RTO=%ss (%s min)' % (e-s, round((e-s)/60,1)))"
```

Expected result:
RTO als Zahl im Repo protokolliert; Coder-Login grün; Testdaten vorhanden
(DB-Seite; Workspace-Datei: Soll derzeit Gap, siehe T-083).

Failure condition:
Kein Offsite vorhanden (F-002-Default-leer) → Test blockiert, als
CRITICAL-Gap protokollieren.

Cleanup:
Beide VMs revert/löschen.

Findings: PLAN F-002/F-003, P-014/P-015, 05/F-002/F-008, 06/F-008.

### T-083 – Workspace-Datei-Test (Soll: Gap dokumentiert)

Purpose:
05/F-015: Datei in Workspace → Backup+Restore → da? Beweist größte reale
Lücke.

Preconditions:
Test-Workspace mit Datei `/home/coder/SCHULARBEIT.txt` (Inhalt hashiert).

Actions:
```bash
echo "schularbeit-$(date +%s)" | tee /tmp/schularbeit-orig.txt
# (Inhalt in Workspace-Datei kopieren, Hash notieren)
sha256sum /tmp/schularbeit-orig.txt
# Backup + Restore nach Runbook (T-082) durchführen, danach:
# sha256sum ~/SCHULARBEIT.txt (im wiederhergestellten Workspace)
echo 'Erwartung derzeit: Datei weg (Gap), DB-Metadaten ggf. da'
```

Expected result:
Gap dokumentiert (Datei weg) + D5-Entscheidung (Server-Backup vs.
Git-Push-Pflicht, RPO) als offen markiert.

Failure condition:
Behauptung „Workspace-Backup vorhanden" ohne Nachweis.

Cleanup:
Test-Workspace löschen.

Findings: P-024, 05/F-015, 06/F-008 (D5).

### T-084 – Transportfehler-Trennung (lokal grün / Transport rot)

Purpose:
P-014: Offsite-Hook außerhalb lokalem Erfolg; Transportfehler ≠ lokaler
Fehler, getrennte Exit-Codes/Logs.

Preconditions:
Offsite-Hook konfiguriert (nach F-002-Fix), Transportziel simulierbar
unerreichbar (falsche URL/Key).

Actions:
```bash
sudo /opt/coder/backup.sh; echo "local-exit=$? (muss 0)"
# Offsite-Copy mit kaputtem Ziel (Befehl aus Hook-Doku):
# sudo /opt/coder/offsite-copy.sh; echo "offsite-exit=$? (muss != 0)"
# grep -E 'local OK|offsite FAIL' /var/log/coder-backup.log || true
echo "(derzeit: kein Hook -> als Gap protokollieren)"
```

Expected result:
Lokal 0 + Transport ≠ 0, getrennt sichtbar im Log.

Failure condition:
Hook-Fehler unter `set -e` markiert lokales Backup als fehlgeschlagen
(oder umgekehrt verschleiert), oder Secret im Log.

Cleanup:
Transportziel reparieren.

Findings: PLAN F-002, P-014.

---

## 10. Updates

### T-090 – Update durchführen (Normalpfad mit Health-Gate)

Purpose:
`update.sh`-Normalpfad inkl. Pre-Backup-Verifikation + Gate (F-012).

Preconditions:
Test-VM, Snapshot, Stack gesund.

Actions:
```bash
sudo /opt/coder/update.sh 2>&1 | tee /tmp/update-normal.log; echo "update-exit=$?"
sudo docker compose -f /opt/coder/docker-compose.yml ps
curl -sk -o /dev/null -w 'healthz=%{http_code}\n' --max-time 10 https://127.0.0.1/healthz || \
  curl -s -o /dev/null -w 'healthz=%{http_code}\n' --max-time 10 http://127.0.0.1:3001/login || true
```

Expected result:
Exit 0 nur bei grünem Gate (Container gesund + `/healthz` 200 innert
Timeout); sonst Exit ≠ 0 mit Hinweis.

Failure condition:
Exit 0 trotz ungesundem Stack (Ist-Lücke: kein Gate).

Cleanup:
Snapshot-Revert bei Bedarf.

Findings: PLAN F-012, P-020, 05/F-010, 06/F-004.

### T-091 – Fehlgeschlagenes Update simuliert (falsche Version → Gate rot)

Purpose:
Siehe T-050, hier als Update-Pfad (nicht nur Pull-Pfad).

Preconditions:
Test-VM, Snapshot.

Actions:
```bash
sudo cp -a /opt/coder /tmp/coder-pre-badupdate 2>/dev/null || true
# update.sh mit überschriebener Version (nur Test-VM, via Env falls unterstützt, sonst temporär .env/Compose-Tag ändern):
sudo CODER_VERSION=v0.0.0-bad /opt/coder/update.sh >/tmp/update-fail.log 2>&1; echo "exit=$? (muss != 0 nach Fix)"
sudo docker compose -f /opt/coder/docker-compose.yml ps
```

Expected result:
Exit ≠ 0, Stack entweder alt-gesund oder klar als gebrochen gemeldet
(kein stilles Grün).

Failure condition:
Exit 0 + gebrochener Stack.

Cleanup:
Snapshot-Revert (sicherster Weg); kein manuelles Image-Gefummel auf Prod.

Findings: PLAN F-012, P-020.

### T-092 – Rollback nach Update (exakt gepinnt vs. beweglich + DB-Vorbehalt)

Purpose:
Rollback-Versprechen differenziert prüfen: Coder/Prometheus/Grafana
(exakt) vs. Caddy/Postgres (beweglich, Re-Pull nötig) + DB-Downgrade-
Vorbehalt bei Migrationen.

Preconditions:
Test-VM, Snapshot, Pre-Update-Backup verifiziert (T-080).

Actions:
```bash
sudo docker images --format '{{.Repository}}:{{.Tag}}' | sort | tee /tmp/imgs-pre.log
# Update fahren, danach alte CODER_VERSION zurücksetzen + setup-coder.sh (Rollback-Pfad aus Kommentar):
# sudo /root/setup-coder.sh
sudo docker images --format '{{.Repository}}:{{.Tag}}' | sort | tee /tmp/imgs-post.log
# DB-Major-Probe (nur Test-VM): postgres-Tag wechseln, Rollback versuchen, dokumentieren ob geht oder begründet nicht
curl -sk -o /dev/null -w 'healthz=%{http_code}\n' --max-time 10 https://127.0.0.1/healthz || true
```

Expected result:
Dokumentiert: exakt Gepinnte rollbackfähig ohne Re-Pull; Caddy/Postgres
nur mit Re-Pull; DB-Major-Rollback geht oder ist begründet unmöglich
(Migrations-Vorbehalt im Runbook).

Failure condition:
Rollback vertraut Kommentar und scheitert im Ernstfall (ungetestet).

Cleanup:
Snapshot-Revert.

Findings: PLAN F-012, P-020, 03/F-001, 05/F-010.

### T-093 – `app`/`db`-Trennung (nach Fix; Default `app`)

Purpose:
K5-Revision (P-020): `update.sh app` zieht kein Postgres-Image; `db` nur
explizit mit Dump+Migrations-Hinweis.

Preconditions:
Test-VM mit Fix-Version von `update.sh`.

Actions:
```bash
sudo docker images postgres --format '{{.ID}}' | tee /tmp/pgimg-before
sudo /opt/coder/update.sh app 2>&1 | tee /tmp/update-app.log; echo "exit=$?"
sudo docker images postgres --format '{{.ID}}' | tee /tmp/pgimg-after
diff /tmp/pgimg-before /tmp/pgimg-after && echo PG_UNTOUCHED || echo PG_CHANGED
```

Expected result:
`PG_UNTOUCHED` bei `app`; `db`-Pfad verlangt Bestätigung + verifizierten
Dump.

Failure condition:
Ein Befehl zieht alles (`pull` ohne Service-Auswahl) – als Kopplung
dokumentiert.

Cleanup:
Keins.

Findings: P-020, 06/F-004.

### T-094 – Docker-Engine-Update-Pfad (Origins vs. Kalendertermin, P-008)

Purpose:
Eine der beiden Optionen muss nachweisbar gelten (F-013-Analog).

Preconditions:
Test-VM.

Actions:
```bash
apt-cache policy docker-ce | head -10
grep -rn 'origin=Docker\|Docker' /etc/apt/apt.conf.d/ | head || echo "no-docker-origin"
sudo unattended-upgrade --debug --dry-run 2>&1 | grep -iE 'docker-ce|containerd|kept back|will be upgraded' | head || true
```

Expected result:
Entweder Origin aufgenommen (dann `docker-ce` upgradebar + Test-Reboot
grün) oder manueller Pfad (Befehl/Intervall/Eigentümer/Nachweis im
Boot-/Update-Log).

Failure condition:
Weder noch (dritter vergessener Update-Pfad).

Cleanup:
Keins.

Findings: P-008, 03/F-003, 06/F-010 (D4).

---

## 11. Reset

### T-100 – Sicherheitsbackup vor Reset (ohne `--force`: Abbruch ohne Löschung)

Purpose:
F-011: Backup-Fehlschlag → ohne `--force` Abbruch, nichts gelöscht.

Preconditions:
Test-VM, Snapshot.

Actions:
```bash
sudo docker compose -f /opt/coder/docker-compose.yml stop postgres
printf 'RESET\n' | sudo /opt/coder/reset-coder.sh; echo "exit=$? (muss != 0)"
sudo docker volume ls | grep -E 'postgres|grafana|prometheus' && echo VOLUMES_KEPT || echo VOLUMES_GONE
test -f /opt/coder/.env && echo ENV_KEPT || echo ENV_GONE
sudo docker compose -f /opt/coder/docker-compose.yml start postgres
```

Expected result:
Exit ≠ 0, `VOLUMES_KEPT`, `ENV_KEPT` (nichts gelöscht).

Failure condition:
Teillöschung trotz Backup-Fehlschlag.

Cleanup:
Postgres healthy abwarten.

Findings: PLAN F-011, P-019, 05/F-012.

### T-101 – Reset mit `--force`: Zweitbestätigung mit frischem Backup-Status

Purpose:
F-011/P-019: `--force` trotz bekanntem Backup-Fehlschlag nur mit
Zweitbestätigung + Anzeige (Alter/Größe/`gzip -t` des neuesten Backups).

Preconditions:
Test-VM, Snapshot, Postgres gestoppt (Backup-Fehlschlag sicher).

Actions:
```bash
LATEST=$(ls -t /opt/coder/backups/coder_*.sql.gz 2>/dev/null | head -n1 || echo NONE)
echo "latest=$LATEST"; stat -c %y\ %s "$LATEST" 2>&1 || true; gzip -t "$LATEST" 2>&1 && echo GZIP_OK || echo GZIP_FAIL
printf 'RESET\n' | sudo /opt/coder/reset-coder.sh --force; echo "exit=$? (nach Fix: verlangt Zweitbestätigung, Pipe ohne TTY ohne Flag verweigert)"
```

Expected result:
Zweitbestätigung mit Backup-Status; nicht-interaktiv (`|`) ohne explizites
Flag verweigert (`[ -t 0 ]`-Guard).

Failure condition:
Stilles Löschen auf vorher erteilter Bestätigung (Ist-Zustand).

Cleanup:
Snapshot-Revert (falls doch gelöscht).

Findings: PLAN F-011, P-019, 05/F-012.

### T-102 – Reset löscht nur Projekt-Volumes (Fremd-Volume-Test + Allowlist)

Purpose:
F-004/P-016: nur `project=coder` + drei logische Namen; Anzeige vorher;
zeilenweise; Fremd-Volume bleibt.

Preconditions:
Test-VM, Snapshot; zwei Test-Volumes mit gleichem `volume`-Label,
verschiedenen `project`-Labels (oder simuliert via `docker volume create`
+ Label).

Actions:
```bash
sudo docker volume create --label com.docker.compose.volume=postgres_data --label com.docker.compose.project=fremd test-fremd-pg
sudo docker volume ls --filter label=com.docker.compose.volume=postgres_data
printf 'RESET\n' | sudo /opt/coder/reset-coder.sh --dry-run 2>&1 || printf 'RESET\n' | sudo /opt/coder/reset-coder.sh 2>&1 | tee /tmp/reset-vol.log; echo "exit=$?"
sudo docker volume ls | grep -q test-fremd-pg && echo FREMD_KEPT || echo FREMD_GONE
```

Expected result:
`FREMD_KEPT`; Löschmenge vorher angezeigt = exakt deklarierte Liste;
Mehrzeilen-Fall iteriert ohne Abbruch.

Failure condition:
`FREMD_GONE` (Fremdlöschung) oder Abbruch nach Teillöschung.

Cleanup:
`sudo docker volume rm test-fremd-pg 2>/dev/null || true`; Snapshot-Revert
falls echter Reset lief.

Findings: PLAN F-004, P-016, 01/F-004, 05/F-011, 06/F-014.

### T-103 – Reset-Leer-Fall: Abbruch vor `rm .env` (kein stiller Halb-Reset)

Purpose:
P-016: kein Treffer (Label-Mismatch, falscher Projektname) → harter
Abbruch vor `.env`-Löschung, Stack weiter lauffähig.

Preconditions:
Test-VM (nur mit COMPOSE_PROJECT_NAME-Variante oder simuliertem Mismatch;
vorsichtig, Snapshot!).

Actions:
```bash
test -f /opt/coder/.env && echo ENV_BEFORE_OK
# Trockenlauf-Auswertung des Filters:
sudo docker volume ls -q --filter "label=com.docker.compose.volume=postgres_data" | cat -A | head
# Nach Fix: Skript bricht bei leerer Treffermenge vor rm .env ab:
echo "(Prüfung gegen Fix-Version: Leer-Fall -> Exit != 0, ENV_KEPT, Stack ok)"
```

Expected result:
Exit ≠ 0, `ENV_KEPT`, `docker compose ps` weiter gesund.

Failure condition:
`.env` weg bei verwaisten alten Volumes (weder alt noch neu lauffähig).

Cleanup:
Snapshot-Revert bei Bedarf.

Findings: P-016, PLAN F-004.

### T-104 – Prüfung auf verbleibende Daten + Workspace-Container (vor/nach Reset)

Purpose:
05/F-013 + Aufgabenstellung: verwaiste Workspace-Container werden VOR
Löschung inventarisiert (`docker ps -a` + Volumes), nicht danach.

Preconditions:
Test-VM mit Dummy-Containern außerhalb Compose (Workspace-Simulation).

Actions:
```bash
sudo docker run -d --name ws-dummy --label coder.workspace=true alpine sleep 3600 2>&1 || \
  sudo docker run -d --name ws-dummy alpine sleep 3600
sudo docker ps -a | tee /tmp/ps-before-reset.log
printf 'RESET\n' | sudo /opt/coder/reset-coder.sh 2>&1 | tee /tmp/reset-ws.log || true
grep -iE 'workspace|ws-dummy|docker ps' /tmp/reset-ws.log | head || echo "no-ws-inventory (Lücke)"
sudo docker ps -a | tee /tmp/ps-after-reset.log
```

Expected result:
Dummy vorher angezeigt (mit Label sobald Coder-Label recherchiert,
bis dahin „alle Nicht-Compose-Container" + Namen); Abbruch oder explizite
Behandlung angeboten.

Failure condition:
Hinweis erst nach Zerstörung (L762–766), Container verwaist.

Cleanup:
`sudo docker rm -f ws-dummy`; Snapshot-Revert falls Reset durchlief.

Findings: PLAN F-011, P-019, 05/F-013.

### T-105 – Reset-Nachprüfung: Backups bleiben, Zertifikate bleiben, DB/Grafana/Prometheus weg

Purpose:
Reset-Vertrag beweisen (Warntext L713–721): Backups + `caddy_data`/
`caddy_config` erhalten; DB/Grafana/Prometheus-Volumes + `.env` weg;
danach Neuaufbau per Setup.

Preconditions:
Test-VM, Snapshot, Backup vorhanden.

Actions:
```bash
ls /opt/coder/backups/ | tee /tmp/backups-before.log
sudo docker volume ls | tee /tmp/vols-before.log
printf 'RESET\n' | sudo /opt/coder/reset-coder.sh; echo "reset-exit=$?"
ls /opt/coder/backups/ | tee /tmp/backups-after.log
test ! -f /opt/coder/.env && echo ENV_GONE_OK || echo ENV_KEPT_WRONG
sudo docker volume ls | tee /tmp/vols-after.log
sudo /root/setup-coder.sh >/tmp/setup-afterreset.log 2>&1; echo "setup-exit=$?"
sudo docker compose -f /opt/coder/docker-compose.yml ps
```

Expected result:
Backups identisch vorher/nachher; Caddy-Volumes da; DB/Grafana/Prometheus-
Volumes weg; `.env` weg; Neuaufbau Exit 0.

Failure condition:
Backups gelöscht, oder Zertifikate weg (Rate-Limit-Risiko), oder Neuaufbau
rot.

Cleanup:
Snapshot-Revert empfohlen (neue Passwörter!).

Findings: PLAN F-004/F-011, P-016, 05/F-011/F-012/F-014.

### T-106 – TTY-Guard: Pipe ohne Flag verweigert destruktiven Reset

Purpose:
P-019: `echo RESET | reset-coder.sh` ohne explizites Flag darf nicht
löschen.

Preconditions:
Test-VM, Snapshot.

Actions:
```bash
printf 'RESET\n' | sudo /opt/coder/reset-coder.sh; echo "exit=$? (nach Fix: != 0 ohne --yes/--force-TTY-Flag)"
test -f /opt/coder/.env && echo ENV_KEPT || echo ENV_GONE
```

Expected result:
Verweigerung ohne Flag (`[ -t 0 ]`-Check), `ENV_KEPT`.

Failure condition:
Pipe löscht ohne interaktive Bestätigung im eigentlichen Sinn.

Cleanup:
Snapshot-Revert falls gelöscht.

Findings: P-019.

---

## 12. Reboot

### T-110 – Host-Reboot: Boot-Gate + Selbstheilungsnachweis (erste 2 Minuten)

Purpose:
P-009/03/F-002/06/F-010: Reboot 03:00 ohne Ordnung, aber mit Zeuge
(Boot-Log); Coder-Crash-Loop dokumentiert als selbstheilend oder rot.

Preconditions:
Test-VM, Stack gesund, Snapshot.

Actions:
```bash
sudo reboot || true
# nach Reboot (90-120 s warten):
sleep 100
cat /var/log/coder-boot.log 2>&1 || echo "no-boot-log (P-009-Lücke)"
sudo docker compose -f /opt/coder/docker-compose.yml ps
sudo docker logs coder --tail=40 2>&1 | grep -iE 'postgres|connect|error|ready|migrat' | head -20 || true
sudo docker logs coder --since 3m 2>&1 | head -40 || true
curl -sk -o /dev/null -w 'healthz=%{http_code}\n' --max-time 10 https://127.0.0.1/healthz || true
```

Expected result:
Boot-Log mit Container-Gesundheit + `/healthz` 200 innert N Minuten,
sonst `logger`-Eintrag; Coder-Logs zeigen ggf. kurze Postgres-Retries,
dann Ready.

Failure condition:
Dauer-Crash-Loop ohne Diagnose, oder Schritt-10-ähnlicher Check fehlt
komplett (erste Meldung = Schüler morgens).

Cleanup:
Keins.

Findings: P-009, 03/F-002/F-009/F-010, 06/F-010.

### T-111 – Nach Reboot: Docker-Daemon + alle sechs Container

Purpose:
Aufgabenstellung: Docker, Coder, PostgreSQL, Caddy, Prometheus, Grafana,
node-exporter je einzeln nach Reboot prüfen.

Preconditions:
Nach T-110-Reboot.

Actions:
```bash
systemctl is-active docker && echo DOCKER_OK
for c in coder-postgres coder coder-caddy coder-prometheus coder-node-exporter coder-grafana; do
  printf '%-22s ' "$c"
  sudo docker inspect -f '{{.State.Running}} {{.State.RestartCount}} {{.State.StartedAt}}' "$c"
done
sudo docker exec coder-postgres pg_isready -U coder -d coder
```

Expected result:
Alle `Running=true`, Postgres ready; RestartCounts protokolliert
(Crash-Loop-Anzeichen sichtbar).

Failure condition:
Ein Dienst dauerhaft down ohne Boot-Log-Eintrag.

Cleanup:
Keins.

Findings: P-009.

### T-112 – Daemon-Neustart ohne Host-Reboot (`systemctl restart docker`)

Purpose:
Gleiche Ordnungslücke wie Reboot, aber ohne Kernel (apt-Upgrade von
docker-ce simuliert).

Preconditions:
Test-VM, Stack gesund.

Actions:
```bash
sudo systemctl restart docker
sleep 30
sudo docker compose -f /opt/coder/docker-compose.yml ps
sudo docker logs coder --tail=20 2>&1 | grep -iE 'postgres|connect|error' | head || true
```

Expected result:
Alle Container zurück (ggf. nach Retries), Logs dokumentiert.

Failure condition:
Stack bleibt teilweise down.

Cleanup:
`sudo docker compose -f /opt/coder/docker-compose.yml up -d` bei Bedarf.

Findings: P-009, 03/F-002.

### T-113 – `stop_grace_period`-Probe für Postgres (30 s, `pgbench`-Last)

Purpose:
03/F-010 (LOW, selten wirksam): sauberer Shutdown statt SIGKILL +
WAL-Replay-Beweis.

Preconditions:
Test-VM, `pgbench` verfügbar (oder manuell Last via `pgbench -i`).

Actions:
```bash
grep -n 'stop_grace_period' /opt/coder/docker-compose.yml || echo "no-grace (Ist-Zustand 10s)"
sudo docker compose -f /opt/coder/docker-compose.yml stop postgres 2>&1 | tail -3
sudo docker logs coder-postgres --tail=10 | grep -iE 'shut down|checkpoint|received fast shutdown' || true
sudo docker compose -f /opt/coder/docker-compose.yml start postgres
```

Expected result:
`stop_grace_period: 30s`, „database system is shut down" vor Ablauf;
nächster Start ohne langes WAL-Replay.

Failure condition:
SIGKILL nach 10 s unter Last (WAL-Replay-Ausfallzeit).

Cleanup:
Postgres healthy abwarten.

Findings: 03/F-010, P-009.

---

## 13. External validation

### T-120 – DNS: A/AAAA/Wildcard/CAA gegen autoritative Nameserver

Purpose:
02/F-012: öffentliche Auflösung (nicht nur `getent` lokal) + CAA-Hinweis;
IPv6-Pfad deklariert (Betrieb oder abgeschaltet, P-004).

Preconditions:
Testdomain mit gesetzten Records (oder Prod-Domain nur lesend prüfen,
keine Änderung).

Actions:
```bash
D=desk-test.example
dig +short A $D @8.8.8.8
dig +short AAAA $D @8.8.8.8 || echo "no-AAAA"
dig +short A zufall-$RANDOM.$D @8.8.8.8 | head -2 || echo "no-wildcard"
dig +short CAA $D @8.8.8.8 || echo "no-CAA (optional, 04/F-004)"
getent hosts $D || echo "local-unresolved"
```

Expected result:
A (und Wildcard-A) zeigen auf Server-IP; AAAA entweder konsistent
(Dual-Stack getestet, T-060) oder bewusst abwesend + dokumentiert;
CAA optional dokumentiert.

Failure condition:
Lokal auflösbar aber öffentlich nicht (Schritt-10-`getent`-Trugschluss),
oder Wildcard fehlt (Workspace-Apps kaputt).

Cleanup:
Keins (nur lesend).

Findings: P-004/P-023, 02/F-012, 04/F-004/F-007.

### T-121 – HTTP (Port 80, Challenge-Pfad, Redirect)

Purpose:
Port-80-Pflicht (ACME + HTTP→HTTPS) von außen beweisen.

Preconditions:
Portweiterleitung 80 steht (Testdomain).

Actions:
```bash
curl -sI --max-time 10 http://<TESTDOMAIN>/ | head -5
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' --max-time 10 http://<TESTDOMAIN>/healthz || true
```

Expected result:
301/308 → `https://` (oder 200 mit Caddy-Redirect-Doku), Challenge-Pfad
erreichbar (Caddy-Log bei Bedarf).

Failure condition:
Timeout/Connection refused (Portweiterleitung fehlt).

Cleanup:
Keins.

Findings: 04-TLS-Summary, P-023.

### T-122 – HTTPS + `/healthz` 200 über echten Browser-Pfad

Purpose:
Schritt-10-`curl`-Pfad von außen (DNS+TCP+TLS in einem Schritt).

Preconditions:
Wie T-121 + LE-Zertifikat ausgestellt.

Actions:
```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "https://<TESTDOMAIN>/healthz"
```

Expected result:
`200`.

Failure condition:
`000`/nicht-200 mit WARN-Diagnose (lokal auflösbar? Caddy-Log?),
kein stilles Grün.

Cleanup:
Keins.

Findings: P-023, 04-Coder-Summary.

### T-123 – Zertifikat: Kette, Ablauf, Issuer (LE), Root + Wildcard)

Purpose:
Echtes öffentliches Vertrauen (kein Self-Signed-Fallback), Erneuerungs-
Vorlauf (~30 Tage) sichtbar.

Preconditions:
Wie T-122.

Actions:
```bash
echo | openssl s_client -connect <TESTDOMAIN>:443 -servername <TESTDOMAIN> 2>/dev/null | openssl x509 -noout -dates -issuer -subject
```

Expected result:
`issuer=C = US, O = Let's Encrypt`, Gültigkeit ≥ 30 Tage (sonst
Erneuerungs-Beobachtung), Subject/SAN = Domain.

Failure condition:
Self-Signed/Expired/Wrong-Host, oder On-Demand-Erstaufruf hängt
(`example.com`-Pfad, 04/F-003).

Cleanup:
Keins.

Findings: 04/F-003/F-006/F-007.

### T-124 – Workspace-App über Subdomain (Wildcard-Nachweis)

Purpose:
Wildcard-DNS + Caddy-Proxy + Coder-Routing Ende-zu-Ende (Kopfkommentar-
Voraussetzung).

Preconditions:
Test-Workspace mit `coder_app` (`subdomain = true`), Wildcard-DNS gesetzt.

Actions:
```bash
APPHOST="8080--agent--ws--user.<TESTDOMAIN>"
curl -sk -o /dev/null -w '%{http_code}\n' --max-time 30 "https://$APPHOST/" || true
sudo docker compose -f /opt/coder/docker-compose.yml logs caddy --tail=20 | grep -iE 'obtaining|certificate' | tail -5 || true
```

Expected result:
App erreichbar (200/302/401 je nach Auth, aber TLS grün); Erstaufruf ggf.
5–30 s (On-Demand-Doku, 04/F-006 korrekt für Root+Wildcard).

Failure condition:
TLS-Fehler (LE-Budget erschöpft, F-001-DoS) oder Wildcard-DNS fehlt.

Cleanup:
Test-App/Workspace löschen.

Findings: P-005, 04/F-001/F-006, 06/F-017.

### T-125 – Fake-Subdomain-TLS (On-Demand-`ask`-Ist-Zustand vs. Fix)

Purpose:
P-005-Kernnachweis: heute löst jede erfundene Subdomain
`obtaining certificate` aus (DoS-Vektor); nach `ask`-Fix Abweisung.

Preconditions:
Testdomain, Caddy-Log-Zugriff.

Actions:
```bash
FAKE="fake-$RANDOM-$RANDOM.<TESTDOMAIN>"
echo | openssl s_client -connect <TESTDOMAIN>:443 -servername "$FAKE" 2>&1 | head -5 || true
sleep 3
sudo docker compose -f /opt/coder/docker-compose.yml logs caddy --since 2m 2>&1 | grep -iE "obtaining certificate.*$FAKE|$FAKE" | head -5 || echo "(kein Eintrag)"
echo 'Erwartung heute: obtaining certificate für Fake-Namen (Lücke); nach Fix: Handshake-Abweisung'
```

Expected result:
Log zeigt Zertifikatsanforderung für erfundenen Namen (P-005 bestätigt).

Failure condition:
Fake-Name wird nach Fix weiterhin mit echtem Zertifikat versorgt.

Cleanup:
Keins (Fake-Namen verfallen; LE-Budget der Testdomain beachten – max.
wenige Versuche/Woche).

Findings: P-005, 02/F-011, 04/F-001, 06/F-017.

### T-126 – Path-Apps nach `CODER_DISABLE_PATH_APPS=true` (Inventar zuerst)

Purpose:
04/F-002/P-006: Pfad-URL abgelehnt, Subdomain-URL ok; vorher
Template-Inventar (`coder_app` ohne `subdomain = true`).

Preconditions:
Test-VM mit Fix (`CODER_DISABLE_PATH_APPS=true`); je eine Test-App mit
und ohne `subdomain = true`.

Actions:
```bash
grep -n 'CODER_DISABLE_PATH_APPS' /opt/coder/docker-compose.yml && echo PATH_APPS_DISABLED || echo PATH_APPS_ENABLED
curl -sk -o /dev/null -w 'path-app=%{http_code}\n' --max-time 10 "https://<TESTDOMAIN>/@user/ws/apps/slug-ohne-subdomain" || true
curl -sk -o /dev/null -w 'subdomain-app=%{http_code}\n' --max-time 10 "https://<slug>.<TESTDOMAIN>/" || true
```

Expected result:
Pfad-URL abgelehnt (4xx), Subdomain-URL funktioniert.

Failure condition:
Pfad-App teilt weiter Coder-Origin (Cookie-Missbrauchspfad offen), oder
Fix bricht legitime Templates ohne Inventar (Regression ohne Vorprüfung).

Cleanup:
Test-Apps löschen.

Findings: P-006, 04/F-002, 06/F-017.

---

## Traceability: PLAN-Finding → Test(s)

| PLAN-Finding | Test(s) | Status |
|---|---|---|
| F-001 Crontab-`pipefail`-Abbruch | T-010, T-020, T-021 | ausführbar |
| F-002 nur lokale Backups, kein Offsite | T-078, T-082, T-084 | ausführbar (Negativnachweis + Offsite-Probe) |
| F-003 kein Restore-Verfahren | T-080, T-081, T-082, T-083 | ausführbar (Gap + Runbook-Probe) |
| F-004 Reset-Volume-Filter | T-102, T-103, T-105 | ausführbar |
| F-005 Backup weder atomar noch verifiziert | T-070, T-071, T-072, T-073, T-080 | ausführbar |
| F-006 `.env` weder atomar noch geprüft | T-022, T-023, T-065 | ausführbar (mit P-010/P-011-Korrektur) |
| F-007 `DOCKER_GID` stale | T-011 (Lauf≠Socket), T-024 | ausführbar |
| F-008 Retention Alter-vs-Stückzahl | T-075 | ausführbar |
| F-009 Cron/Flock/Timestamp | T-014, T-045, T-074, T-076 | ausführbar (mit P-017-Ergänzung) |
| F-010 `reset-passwords` nicht transaktional | T-033 | ausführbar (mit P-018-Reihenfolge) |
| F-011 Reset-Dialog/`--force`/Workspace zu spät | T-100, T-101, T-104, T-106 | ausführbar (mit P-019-Label/TTY-Guard) |
| F-012 Update ohne Gate/irreführender Rollback | T-050, T-053, T-090, T-091, T-092, T-093 | ausführbar (mit P-020-Prune/app-db) |
| F-013–F-026 (behauptet, Datei abgebrochen) | — | **nicht testbar, siehe unten (P-001)** |

### Traceability: PLAN-REVIEW (P-001–P-025) → Test(s)

| P-Finding | Test(s) |
|---|---|
| P-001 PLAN abgebrochen | T-006 (Gate, derzeit rot) |
| P-002 Docker-Socket ohne Finding | T-063, T-064 |
| P-003 SSH weltweit+Passwort | T-061 |
| P-004 Firewall ohne Finding | T-013, T-060, T-062 |
| P-005 On-Demand-TLS ohne Finding | T-004, T-124, T-125 |
| P-006 Path-Apps gestrichen | T-126 |
| P-007 volle Platte ohne Finding | T-067, T-073, T-077, T-079 |
| P-008 Docker-Engine-Updates | T-094 |
| P-009 Reboot ohne Ordnung/Zeuge | T-034, T-052, T-110, T-111, T-112, T-113 |
| P-010 F-006-umask falsch | T-023 |
| P-011 F-006-Neuwürfeln destruktiv | T-022 |
| P-012 F-007 unterspezifiziert | T-024 |
| P-013 Backup-Schwellwerte/ENOSPC | T-071, T-073, T-080 |
| P-014 Offsite-Hook leer = kein Fix | T-082, T-084 |
| P-015 Restore nur Doku/Phantome | T-081, T-082 |
| P-016 Volume-Fix vage/Leer-Fall/Zertifikate | T-102, T-103, T-105 |
| P-017 PATH/Flock/Cron-Annahmen | T-045, T-074, T-076 |
| P-018 Passwort-Reihenfolge/`.bak`/Grafana | T-033 |
| P-019 Workspace-Inventar/`--force`/TTY | T-100, T-101, T-104, T-106 |
| P-020 Gate zu spät/Prune/DB-Kopplung | T-050, T-053, T-090–T-093 |
| P-021 Dangling Refs | T-006 |
| P-022 kein Harness/leere TEST_PLAN | T-001–T-007 (dieser Plan schließt die Lücke) |
| P-023 Netz/DNS/Platte/Teilfehler | T-026, T-030–T-032, T-034, T-040–T-045 |
| P-024 Backup-Umfang/Secrets/Workspace | T-065, T-066, T-078, T-083 |
| P-025 Zweitlauf-Nebenwirkungen | T-020, T-025, T-026 |

### Traceability: Reviews 01–06 (Auswahl, je mindestens ein Test)

- 01/F-001→T-021; F-002→T-022/T-023; F-003→T-070/T-072; F-004→T-102;
  F-005→T-033; F-006→T-002; F-007 (hex-Sonderzeichen)→T-033-Seitennotiz
  (hex garantiert, nur Hand-Edit-Fall, Negativprobe optional);
  F-008 (ufw-Perf)→T-062-Seitennotiz (Stil, kein Verhaltenstest);
  F-009 (Domain-Validierung)→T-003.
- 02/F-001/F-003→T-063; F-002/F-004→T-063/T-064 (Allowlist statt unbelegter
  Behauptung); F-005→T-013/T-060; F-006→T-068; F-007→T-061; F-008/F-009→T-060;
  F-010→T-060/T-120; F-011→T-125; F-012→T-120; F-013→T-042/T-092;
  F-014→T-043; F-015→T-066; F-016→T-065/T-078; F-017→T-069/T-100–T-106;
  F-018→T-003; F-019→T-064 (Template-Fuzzing erst mit Templates möglich).
- 03/F-001→T-053/T-092; F-002→T-052/T-110/T-112; F-003→T-094; F-004→T-067;
  F-005 (`mem_limit`)→kein automatischer Test ohne Messung, siehe „nicht
  testbar"; F-006→T-024; F-007→T-068; F-008→T-079; F-009→T-012/T-110;
  F-010→T-113; F-011/F-012 (Bestätigungen)→T-010/T-062 (Negativprobe, kein Defekt).
- 04/F-001→T-125; F-002→T-126; F-003→T-123/T-125; F-004 (CAA)→T-120
  (optional); F-005 (korrekt abwesend)→kein Defekt-Test, T-124 als
  Routing-Nachweis; F-006→T-004/T-124 (Doku-Abgleich); F-007→T-120/T-123.
- 05/F-001→T-078; F-002→T-082; F-003→T-070–T-072/T-080; F-004→T-074;
  F-005→T-075; F-006→T-074/T-076; F-007→T-077; F-008→T-081/T-082;
  F-009→T-081; F-010→T-090–T-092; F-011→T-102; F-012→T-100/T-101;
  F-013→T-104; F-014→T-105; F-015→T-083; F-016→T-073; F-017→T-033;
  F-018 (`pg_hba`-Trust)→T-080-Seitenprobe (auf `scram-sha-256` umstellen,
  nur Test-PG; Upstream-Annahme, kein Prod-Test).
- 06/F-001 (`--converge`)→T-020/T-025 (Teilmenge-Verhalten; CLI-Vertrag erst
  nach Einführung testbar); F-002 (STATE-Inventar)→T-102/T-105
  (Löschmenge = deklarierte Liste, nach Einführung); F-003 (Templates)→T-003–
  T-005 (nach Migration: byte-identischer Generierungsvergleich);
  F-004→T-093; F-005→T-063/T-064; F-006→T-060; F-007→T-077;
  F-008→T-082; F-009→T-020/T-022/T-024/T-025; F-010→T-110; F-011→T-074;
  F-012→T-061; F-013→T-033/T-066; F-014→T-100–T-105; F-015→T-001–T-007;
  F-016→T-067/T-079/T-105; F-017→T-124–T-126. D1–D10→siehe „nicht testbar".

## Nicht testbare Findings (mit Begründung)

1. **PLAN F-013–F-026:** existieren nicht (Datei bricht in F-012 ab, P-001).
   Kein Test ableitbar; erst nach PLAN-Reparatur (oder ehrlicher Kürzung auf
   F-001–F-012) verknüpfbar. T-006 enforced das als Gate.
2. **Dangling D4–D9, F-019, F-021 (P-021):** referenzierte Entscheidungen ohne
   Eigentümer/Optionen/Frist. Test blockiert bis zur Entscheidung (D-Liste in
   PLAN-REVIEW „Missing Decisions"); bis dahin werden abhängige Tests
   (Offsite-, Restore-, TLS-Modell-Tests) als Gap-Protokoll, nicht als Pass
   gewertet (T-082/T-084/T-125).
3. **Menschliche Grundsatzentscheidungen D1–D10 (06/D1–D10, P-003/P-004/P-008/
   P-014/P-024):** Socket-Modell, TLS-Modell, SSH-Termin, Docker-Engine-Pfad,
   Workspace-Verantwortung/RPO, Offsite-Ziel/Schlüssel, Monitoring-Ambition,
   Ressourcen-Limits, Firewall-Modell, RPO/RTO/Reset-Ermächtigung. Nicht per
   Code-Test entscheidbar; testbar erst nach Beschluss (dann als
   Abnahmekriterium je D).
4. **03/F-005 `mem_limit` (K4):** kein Limit ohne Messung (Exit-137-Risiko).
   Testbar erst nach `docker stats`-Woche auf Zielhardware (Messauftrag);
   bis dahin nur Beobachtung, kein Grenzwert-Test.
5. **Rein stilistische Befunde 01/F-006 (SC2034/SC2012/Newline), 01/F-008
   (7× `ufw status`):** per T-002 statisch prüfbar, aber ohne Verhaltens-
   Failure; eigene T-Tests wären Theater. Korrektur separat von destruktiven
   Pfaden (AGENTS.md: keine unrelated changes).
6. **Bestätigungen ohne Defekt (04/F-005, 03/F-011, 03/F-012, 04/F-007,
   05/F-018-Anteil):** korrektes Verhalten (`PROXY_TRUSTED_ORIGINS`
   abwesend, trixie-Repo, UFW-Kommentar, LE-Limit-Zahl, `pg_hba`-Trust).
   Nur Negativ-/Lesenachweis (T-003/T-010/T-062/T-120/T-080-Seitenprobe),
   kein Fail-Test sinnvoll.
7. **02/F-002/F-004-Anteile jenseits Allowlist (ASSUMPTION):** konkrete
   Template-Gefährlichkeit ohne Templates im Repo nicht beweisbar. Ersatz:
   prüfbare Allowlist + Workspace-Selbsttest (T-063/T-064) statt unbelegter
   Behauptung.
8. **`pid: host` als „reine Hygiene" (K3):** Angriffsfläche ohne Nutzen ist
   per T-068 prüfbar, aber kein akuter Schaden beweisbar (Mounts ro, Ports
   loopback). Test endet mit Begründungspflicht (entfernen oder Collector
   begründen), nicht mit Exploit-Nachweis.

## Freigaberegel (aus PLAN-REVIEW Blocking Issues)

Kein Implementierungs-PR vor: T-006 grün (P-001/P-021 bereinigt, PLAN ehrlich:
F-013–F-026 oder Kürzung), P-002/P-010/P-011/P-007/P-005+P-006/P-003-Gates
dieses Plans als Abnahmekriterien benannt, pro Fix-PR: betroffene
P-/F-Punkte, Regression, Test-Nachweis (Log/Befehl/Datum/VM-Name) beigelegt.
