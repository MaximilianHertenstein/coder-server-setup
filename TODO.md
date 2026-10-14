# TODO (Betreiber) – Stand 2026-10-08

Persönliche Checkliste. **Quelle der Wahrheit** ist die
[README „Offene Punkte – wer macht was"](README.md#offene-punkte--wer-macht-was-stand-2026-10-08);
bei Abweichungen gilt die README. Befehle und Details stehen in den
verlinkten Abschnitten (OPERATIONS/SECURITY/RESTORE), nicht hier.

## Am Zielserver (Walkthrough)

- [x] **Pre-Flight + erster Lauf: erledigt 2026-10-14** (lief bis zur
      Zusammenfassung durch, nur WARNUNG `/healthz` = Portlage offen).
      `setup.conf` gab es noch nicht – das Gate hat korrekt gehalten,
      Werte liefen über `sudo env …` ([OPERATIONS §11](OPERATIONS.md))
- [x] **Erstkonto 2026-10-14 angelegt** (`maximilian`)
- [ ] **zweites** Owner-Konto anlegen (§11 Betreiber Schritt 4: nicht ein
      Zugang allein)
- [ ] **Abnahme** – der zweite Lauf lief 2026-10-14 durch; Checks aus
      [§11 Schritt 5](OPERATIONS.md)/[OPERATIONS §5], sobald Portlage
      steht (`/healthz` → 200); Test-Workspace anlegen, App-URL vom
      Schulnetz-Client öffnen (Hairpin-NAT + Wildcard, A9)
- [ ] Workspace-Container-Labels prüfen, die `reset-coder.sh` für den
      Cleanup braucht (B-11: ohne sie bricht der Reset hart ab)
- [ ] Template-Schritt 4 (Limit-Spielraum) je Template abhaken –
      entschieden 2026-10-08: erst nach dem Vorführen der konkreten
      Templates – [templates/allowlist.md](templates/allowlist.md)
- [x] `FAIL2BAN_IGNORE_IP`: entschieden 2026-10-08 – Default
      `127.0.0.1/8 ::1` bleibt; Admin-IP nur bei öffentlichem
      Admin-Zugang ergänzen ([SECURITY §2](SECURITY.md))

## Extern klären (braucht andere Leute)

- [ ] **DNS + Portweiterleitung beim Netzwerkadmin** (Zeilen 1–4 in
      §11); Status der Anfrage 2026-10-03: Einrichtung erst, sobald
      **IServ in Produktion** ist
- [ ] **Zone/Hosting klären** und **DNS-API-Token** anfragen (erst dann
      DNS-01; bis dahin On-Demand-TLS) – [SECURITY §9 D-TLS](SECURITY.md)
- [x] **03:00-Rebootfenster: entschieden 2026-10-08** – 03:00 bleibt,
      Ferien-/Prüfungsphasen vorher manuell abstimmen
      ([OPERATIONS §7](OPERATIONS.md))
- [ ] **Proxmox-VM-Backup** (vzdump/PBS) um 02:00 einrichten (Ziel =
      anderer Storage/Host, entschieden 2026-10-08) und einmal
      **Restore aus dem VM-Backup** testen ([OPERATIONS §7](OPERATIONS.md))

## Entscheidungen (dich treffen)

- [ ] **Produktionsfreigabe** aussprechen – bewusst nirgends dokumentiert
- [x] **Unterrichtsdaten (2026-10-08):** Homes über das VM-Backup
      mitgesichert, Restverlust ≤ 1 Schultag ([RESTORE.md](RESTORE.md))
- [x] **Offsite (2026-10-08):** vzdump/PBS auf anderem Storage/Host +
      monatlicher verschlüsselter `rsync`-Pull vom Betreiber-Rechner;
      Umsetzung bleibt Aufgabe
- [x] **Update-Fenster (2026-10-08):** monatlich, erster Samstag 09:00
      ([OPERATIONS §7](OPERATIONS.md))
- [x] **Alarmweg (2026-10-08):** `hert@ghse.de` über IServ-SMTP, Umsetzung
      sobald IServ produktiv ist ([SECURITY §9](SECURITY.md))
- [ ] **Nächster Push** auf `main` (remote `origin` = GitHub existiert)

## Offene Verifikationen (brauchen Aktionen, nicht nur dich)

- [ ] RTO inkl. **VM-Boot** auf einer frischen VM (Pfad A ohne VM-Boot
      ist erledigt)
- [ ] `/healthz` + Wildcard unter **echtem DNS** (sobald DNS steht)
- [ ] Verhalten bei **vollem Speicher** / 03:00-Fire beobachten
- [ ] Let's-Encrypt-**Budget-Sichtprüfung** manuell (OPERATIONS §5)

Sobald DNS + Ports stehen: einfach `sudo ./setup-coder.sh` erneut
ausführen – es ist idempotent und holt dann das Zertifikat.
