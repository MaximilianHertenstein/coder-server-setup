# TODO (Betreiber)

Persönliche Checkliste. **Quelle der Wahrheit** ist die
[README „Offene Punkte – wer macht was"](README.md#offene-punkte--wer-macht-was);
bei Abweichungen gilt die README. Befehle und Details stehen in den
verlinkten Abschnitten (OPERATIONS/SECURITY/RESTORE/AGENTEN), nicht hier.

## Am Zielserver (Walkthrough)

- [x] **Pre-Flight + erster Lauf: erledigt 2026-10-14** (lief bis zur
      Zusammenfassung durch, nur WARNUNG `/healthz` = Portlage offen).
      `setup.conf` gab es noch nicht – das Gate hat korrekt gehalten,
      Werte liefen über `sudo env …` ([OPERATIONS §11](OPERATIONS.md))
- [x] **Erstkonto 2026-10-14 angelegt** (`maximilian`)
- [x] **DNS + Portweiterleitung: erledigt 2026-11-22** – Apex + Wildcard →
      `93.240.138.109`, Schul-Proxy → `10.16.1.13`, 80/443 und
      ACME-Challenges durchgereicht. `/healthz` = 200, Zertifikat gültig bis
      2027-02-20 ([OPERATIONS §11](OPERATIONS.md))
- [ ] **zweites** Owner-Konto anlegen (§11 Betreiber Schritt 4: nicht ein
      Zugang allein)
- [ ] **Abnahme** – Checks aus [§11 Schritt 5](OPERATIONS.md)/[OPERATIONS §5](OPERATIONS.md);
      `/healthz` ist jetzt 200. Offen: Test-Workspace anlegen und dessen
      App-URL vom Schulnetz-Client öffnen (Wildcard + On-Demand-TLS +
      Hairpin, [TROUBLESHOOTING B6/B7](TROUBLESHOOTING.md))
- [ ] Workspace-Container-Labels prüfen, die `reset-coder.sh` für den
      Cleanup braucht (ohne sie bricht der Reset hart ab,
      [OPERATIONS §7](OPERATIONS.md))
- [ ] Template-Schritt 4 (Limit-Spielraum) je Template abhaken –
      entschieden: erst nach dem Vorführen der konkreten Templates –
      [templates/allowlist.md](templates/allowlist.md)
- [x] `FAIL2BAN_IGNORE_IP`: entschieden – Default `127.0.0.1/8 ::1` bleibt;
      Admin-IP nur bei öffentlichem Admin-Zugang ergänzen
      ([SECURITY §4](SECURITY.md))

## Agenten und Testhost

- [ ] `template-agent` auf dem Schulserver anlegen (`login_type none`,
      Rollen `member` + `template-admin`), Deploy-Token als GitHub-Secret
      hinterlegen, Workflow für `coder templates push` einrichten
      ([AGENTEN.md](AGENTEN.md))
- [ ] Hetzner-Testhost für Workspace-Tests: `CODER_ACCESS_URL` auf
      `http://172.17.0.1:3000` und Port `172.17.0.1:3000:3000` setzen,
      coderd neu starten, Workspace neu bauen (Test-Override)
- [ ] Caddy auf dem Hetzner gestoppt halten (kommt nach jedem Setup-Lauf
      zurück); Test-Workspaces mit `--stop-after` anlegen
- [ ] Deploy-Token-Rotation terminieren (90 Tage)

## Extern klären (braucht andere Leute)

- [x] **DNS + Portweiterleitung beim Netzwerkadmin: erledigt 2026-11-22**
      (Zeilen 1–4 in §11)
- [ ] **DNS-01 nur als Fallback** – Zone liegt bei All-Inkl, DNS macht der
      Netzwerkadmin. KAS-Zugang erst anfragen, wenn der Proxy die
      ACME-Challenges dauerhaft blockiert oder das geteilte Budget zum
      Problem wird ([SECURITY §9 D-TLS](SECURITY.md))
- [x] **03:00-Rebootfenster: entschieden** – 03:00 bleibt,
      Ferien-/Prüfungsphasen vorher manuell abstimmen
      ([OPERATIONS §7](OPERATIONS.md))
- [ ] **Proxmox-VM-Backup** (vzdump/PBS) um 02:00 einrichten (Ziel =
      anderer Storage/Host) und einmal **Restore aus dem VM-Backup**
      testen ([OPERATIONS §7](OPERATIONS.md))

## Entscheidungen (dich treffen)

- [ ] **Produktionsfreigabe** aussprechen – bewusst nirgends dokumentiert
- [x] **Unterrichtsdaten:** Homes über das VM-Backup mitgesichert,
      Restverlust ≤ 1 Schultag ([RESTORE.md](RESTORE.md))
- [x] **Offsite:** vzdump/PBS auf anderem Storage/Host + monatlicher
      verschlüsselter `rsync`-Pull vom Betreiber-Rechner; Umsetzung
      bleibt Aufgabe
- [x] **Update-Fenster:** monatlich, erster Samstag 09:00
      ([OPERATIONS §7](OPERATIONS.md))
- [x] **Alarmweg:** `hert@ghse.de` über IServ-SMTP, Umsetzung sobald
      IServ produktiv ist ([SECURITY §9](SECURITY.md))
- [x] **Agenten-Zugriff:** `D-Agenten` – Testhost wegwerfbar, Produktion
      nur per GitHub Action, kein Git-Push/Repo-Admin für Agenten
      ([SECURITY §9](SECURITY.md))
- [x] **Nächster Push** auf `main` (Commit `017ddbc` ist auf
      `origin/main`)

## Offene Verifikationen (brauchen Aktionen, nicht nur dich)

- [ ] RTO inkl. **VM-Boot** auf einer frischen VM (Pfad A ohne VM-Boot
      ist erledigt)
- [x] `/healthz` unter **echtem DNS** (2026-11-22, Code 200,
      Let's-Encrypt-Zertifikat)
- [ ] Wildcard + App-URL unter echtem DNS: erster Test-Workspace, Aufruf
      vom Schulnetz-Client ([TROUBLESHOOTING B6](TROUBLESHOOTING.md))
- [ ] Verhalten bei **vollem Speicher** / 03:00-Fire beobachten
- [ ] Let's-Encrypt-**Budget-Sichtprüfung** manuell (OPERATIONS §5)

DNS und Ports stehen. Offen sind der Workspace-App-Test (Wildcard,
On-Demand-TLS, Hairpin) und der Agenten-Deploy über GitHub.
