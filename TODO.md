# TODO (Betreiber) – Stand 2026-10-08

Persönliche Checkliste. **Quelle der Wahrheit** ist die
[README „Offene Punkte – wer macht was"](README.md#offene-punkte--wer-macht-was-stand-2026-10-08);
bei Abweichungen gilt die README. Nicht hier committen (persönliche Notiz).

## Am Zielserver (Walkthrough)

- [ ] **Pre-Flight** durchlaufen, dann erster Lauf: `sudo ./setup-coder.sh`
      ([OPERATIONS §11](OPERATIONS.md#11-inbetriebnahme-am-zielserver-wer-macht-was))
- [ ] **`setup.conf` mit `ACME_EMAIL` anlegen** (`cp setup.conf.example
      setup.conf`) – Pflicht, kein Default, sonst bricht das Setup vor
      jeder Änderung ab (Pre-Flight Schritt 7)
- [ ] **Portlage 80/443 klären** – Zielserver ist frisches Debian ohne
      eigenen Webserver; IServ läuft auf dem zentralen Netzwerkserver,
      vermutlich dort auch der Reverse-Proxy: DNS direkt auf den
      Zielserver oder Durchreichung/Proxy-Regel am zentralen Server?
      (§11 Pre-Flight 1, Netzwerkadmin Zeile 4)
- [ ] **Erstkonto sofort beim/direkt nach dem ersten Lauf** anlegen
      (`sudo env CODER_FIRST_USER_* …`, §11 Betreiber Schritt 4),
      danach **zweites** Owner-Konto (nicht ein Zugang allein)
- [ ] **Zweiter Lauf + Abnahme** – `sudo ./setup-coder.sh` erneut
      (idempotent, holt jetzt das Zertifikat), dann die Checks aus
      [OPERATIONS §5](OPERATIONS.md) (Schritt 5):

      ```bash
      getent hosts coder.ghse-unterricht.de                       # zeigt auf den Zielserver
      curl -s -o /dev/null -w '%{http_code}\n' https://coder.ghse-unterricht.de/healthz   # muss 200 sein
      docker logs coder-caddy --tail=50 | grep -i 'obtaining certificate\|error'          # muss LEER bleiben (keine Zeile)
      sudo docker exec coder-caddy wget -qO- -T 3 'http://127.0.0.1:9123/ask?domain=8080--main--ws--user.coder.ghse-unterricht.de'
      ```

      Ask-Endpoint muss `ok` zurückgeben (ohne `ok` = TLS/Wildcard-Problem).
      Danach Test-Workspace anlegen und dessen App-URL **vom
      Schulnetz-Client** öffnen (prüft Hairpin-NAT + Wildcard-DNS, A9).
- [ ] **Test-Workspace vom Schulnetz-Client** öffnen (Hairpin-NAT, A9); danach
      die Workspace-Container-Labels prüfen, die `reset-coder.sh` braucht
      (**B-11** – ohne sie bricht der Reset hart ab, nichts wird gelöscht)
- [ ] Template-Schritt 4 (Limit-Spielraum) je Template abhaken:
      [templates/allowlist.md](templates/allowlist.md)
- [ ] `FAIL2BAN_IGNORE_IP` in `setup.conf` mit den **echten Admin-Plätzen**
      füllen (Default `127.0.0.1/8 ::1`, ausdrücklich **nicht** Schul-NAT);
      [SECURITY §2](SECURITY.md)

## Extern klären (braucht andere Leute)

- [ ] **DNS + Portweiterleitung beim Netzwerkadmin anfordern**
      (A-Record, Wildcard `*`, 80/443 1:1, ggf. Proxy-Durchreichung).
      Befund 2026-10-03: Zone bei Kasserver/All-Inkl, `A` zeigt aktuell auf
      die alte Schulseite `85.13.130.100`, `93.240.138.106` = Kreis-Proxy
      (451) – der Betreiber fordert nur Zeilen 1–4 an (§11 Netzwerkadmin).
      **Angefragt 2026-10-03 (E-Mail an Sascha):** externer Zugriff auf
      10.16.103.13, Apex + optional Wildcard, WebSocket-Pflicht – Antwort:
      erst mit **IServ-Produktivschaltung**, aktuell technisch nicht möglich
- [ ] **Zone/Hosting klären** und beim Domainverwalter das
      **DNS-API-Token** anfragen (erst danach DNS-01 einbauen; bis dahin
      läuft On-Demand-TLS, Budget 50 Zertifikate/Woche, Warnung ab 20);
      [SECURITY §9 D-TLS](SECURITY.md)
- [ ] **03:00-Rebootfenster** mit dem Schulbetrieb abstecken und im
      Wartungsplan hinterlegen ([OPERATIONS §7](OPERATIONS.md), SECURITY §9)
- [ ] **Proxmox-VM-Backup** (vzdump/PBS) um 02:00 einrichten – zwischen
      DB-Backup 01:00 und Reboot 03:00; `qemu-guest-agent` braucht den
      virtio-Channel in der VM (das Setup installiert ihn nur dann);
      einmal **Restore aus dem VM-Backup** testen
      ([OPERATIONS §7](OPERATIONS.md))

## Entscheidungen (dich treffen)

- [ ] **Produktionsfreigabe** aussprechen – bewusst nirgends dokumentiert
- [x] **Unterrichtsdaten (2026-10-08):** Workspace-Homes werden über das
      Proxmox-VM-Backup (vzdump 02:00) mitgesichert, separate
      Volume-Sicherung entfällt, Restverlust ≤ 1 Schultag;
      [RESTORE.md](RESTORE.md) „Was gesichert wird"
- [x] **Offsite-Backup (2026-10-08):** vzdump/PBS-Ziel = anderer
      Storage/Host als die VM-Disk, dazu monatlicher verschlüsselter
      `rsync`-Pull `/opt/coder/backups` vom Betreiber-Rechner (C-5:
      Source-zu-Target, kein Key/Script auf dem Server); Umsetzung bleibt
      Aufgabe (Proxmox-Zugang, Kalendereintrag)
- [x] **Update-Termin (2026-10-08):** monatlich, erster Samstag 09:00 –
      Backup grün → `sudo ./setup-coder.sh` (RC 0) → §5-Checks; Engine-
      Upgrade im selben Fenster, kritische CVEs ad hoc nach
      Unterrichtsende; [OPERATIONS §7](OPERATIONS.md)
- [x] **Alarmweg/Empfänger (2026-10-08):** Empfänger `hert@ghse.de`, Weg
      Grafana-Mail über IServ-SMTP, Umsetzung sobald IServ produktiv ist;
      [SECURITY §9](SECURITY.md), OPERATIONS §5
- [ ] **Push-Entscheidung:** Repo hat kein Remote – sagen, ob und wohin
      gepusht wird

## Offene Verifikationen (brauchen Aktionen, nicht nur dich)

- [ ] RTO inkl. **VM-Boot** auf einer frischen VM (Restore-Pfad A ist
      ohne VM-Boot erledigt)
- [ ] `/healthz` + Wildcard unter **echtem DNS** (sobald Punkt DNS steht)
- [ ] Verhalten bei **vollem Speicher** / 03:00-Fire beobachten
- [ ] Let's-Encrypt-**Budget-Sichtprüfung** manuell (OPERATIONS §5)

Sobald DNS + Ports stehen: einfach `sudo ./setup-coder.sh` erneut
ausführen – es ist idempotent und holt dann das Zertifikat.
