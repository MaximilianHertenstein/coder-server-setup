# TODO (Betreiber) – Stand 2026-10-03

Persönliche Checkliste. **Quelle der Wahrheit** ist die
[README „Offene Punkte – wer macht was"](README.md#offene-punkte--wer-macht-was-stand-2026-10-03);
bei Abweichungen gilt die README. Nicht hier committen (persönliche Notiz).

## Am Zielserver (Walkthrough)

- [ ] **Pre-Flight** durchlaufen, dann erster Lauf: `sudo ./setup-coder.sh`
      ([OPERATIONS §11](OPERATIONS.md#11-inbetriebnahme-am-zielserver-wer-macht-was))
- [ ] **Portlage 80/443 klären** – Zielserver ist frisches Debian ohne
      eigenen Webserver; IServ läuft auf dem zentralen Netzwerkserver,
      vermutlich dort auch der Reverse-Proxy: DNS direkt auf den
      Zielserver oder Durchreichung/Proxy-Regel am zentralen Server?
      (§11 Pre-Flight 1, Netzwerkadmin Zeile 4)
- [ ] **Erstkonto sofort beim/direkt nach dem ersten Lauf** anlegen
      (`sudo env CODER_FIRST_USER_* …`, §11 Betreiber Schritt 4),
      danach **zweites** Owner-Konto (nicht ein Zugang allein)
- [ ] **Zweiter Lauf + Abnahme** mit den Checks aus §11/Betreiber Schritt 5
      (`/healthz` muss 200 sein, Caddy-Logs leer, Ask-Endpoint `ok`)
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
      (451) – der Betreiber fordert nur Zeilen 1–4 an (§11 Netzwerkadmin)
- [ ] **Zone/Hosting klären** und beim Domainverwalter das
      **DNS-API-Token** anfragen (erst danach DNS-01 einbauen; bis dahin
      läuft On-Demand-TLS, Budget 50 Zertifikate/Woche, Warnung ab 20);
      [SECURITY §9 D-TLS](SECURITY.md)
- [ ] **03:00-Rebootfenster** mit dem Schulbetrieb abstecken und im
      Wartungsplan hinterlegen ([OPERATIONS §7](OPERATIONS.md), SECURITY §9)

## Entscheidungen (dich treffen)

- [ ] **Produktionsfreigabe** aussprechen – bewusst nirgends dokumentiert
- [ ] **Unterrichtsdaten:** Workspace-Homes als Verlust deklarieren **oder**
      eigene Volume-Sicherung einrichten (vor Produktivbetrieb);
      [RESTORE.md](RESTORE.md) „Was gesichert wird"
- [ ] **Offsite-Backup:** Ziel und Rhythmus festlegen (Anforderung an den
      Betrieb, kein Automatismus im Repo)
- [ ] **Alarmweg/Empfänger:** klären, sobald Alarme zugestellt werden sollen
      (3 Regeln existieren, kein Kanal – D-Monitoring);
      [SECURITY §9](SECURITY.md)
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
