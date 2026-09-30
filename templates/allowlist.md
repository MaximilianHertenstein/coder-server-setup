# Template-Allowlist (P-002, Stufe 1 – ohne Host-Umbau)

Stand: 2026-09-30. Status: Regelwerk gilt; Erstinventar (Schritt 1) am
2026-09-30 durchgeführt, Workspace-Selbsttest (Schritt 2, T-063) und
fachliche Freigabe offen. Abhakpflicht pro Template bleibt.
Hintergrund: Der `coder`-Container hält `/var/run/docker.sock` schreibbar
(Host-root-äquivalent). Jedes Workspace-Template entscheidet damit über die
Host-Sicherheit. Echte Trennung (Proxy/separater Host) ist BLOCKER B-02
(D-Socket) – bis dahin gilt diese Allowlist.

## Verboten (führt zu Ablehnung im Review)

- `/var/run/docker.sock`-Mount (auch `:ro`)
- `privileged: true` / erweiterte Capabilities (`SYS_ADMIN`, `NET_ADMIN`, ...)
- `pid: host`, `network_mode: host`, `ipc: host`
- Host-Root- oder sensible Mounts (`/`, `/etc`, `/root`, `/opt/coder`, ...)
- Gemeinsame Docker-Netze mit `postgres` (DB nur für `coder` erreichbar)
- `--gpus`/Devices ohne dokumentierten Unterrichtsgrund

## Erlaubt (Normalfall Unterricht)

- CPU-/Memory-Limits pro Workspace (für Schüler-Workspaces verpflichtend,
  Werte passend zum Unterrichtsbedarf festlegen), eigene Bridge-Netze,
  Workspace-Volume.

## Abnahme pro Template/Änderung

1. Template-Datei gegen obige Listen geprüft (`grep` nach
   `docker.sock|privileged|pid:.*host|network_mode:.*host|postgres`).
2. Workspace-Selbsttest aus normalem Workspace (T-063): kein
   `/var/run/docker.sock`, kein `postgres:5432`, keine fremden Container.
3. Reviewer + Datum unten eingetragen.
4. CPU-/Memory-Limits sind im Template gesetzt und mit einem repräsentativen
   Workspace auf ausreichend Spielraum geprüft.

## Abnahmen

Quelle der Templates: separates Repository
`/home/max/Dokumente/referendariat/SJ2022_2023/informatik/coder_templates`
(Stand `7bd2b92`; Ordner `cpp`, `html-css`, `java`, `java-intellij`,
`python`, `sql` – `server/` ist leer und kein Template). Inventur am
2026-09-30: Schritt 1 (grep gegen die Verbotsliste) ohne Treffer, dazu
`terraform fmt -check`, `terraform validate` je Template und
`shellcheck -S warning` – alles ohne Befund. **Nicht** geprüft: Schritt 2
(Workspace-Selbsttest), Schritt 4 im laufenden Workspace und die
fachliche Freigabe. Der Selbsttest läuft mit `test-workspaces.sh` aus dem
Template-Repo; der Test-Host `2.29.11.30` hat (Stand 2026-09-30) **0**
Templates in der Coder-DB, braucht dafür also erst ein Veröffentlichen.

| Datum | Template/Version | Prüfer | Ergebnis |
|---|---|---|---|
| 2026-09-30 | `cpp` @ `7bd2b92` | Schritt 1 (grep) | kein Verbotsmuster; Limits 2 CPU / 4096 MB gesetzt; Schritt 2/4 offen |
| 2026-09-30 | `html-css` @ `7bd2b92` | Schritt 1 (grep) | kein Verbotsmuster; Limits 1 CPU / 2048 MB gesetzt; Schritt 2/4 offen |
| 2026-09-30 | `java` @ `7bd2b92` | Schritt 1 (grep) | kein Verbotsmuster; Limits 2 CPU / 4096 MB gesetzt; Schritt 2/4 offen |
| 2026-09-30 | `java-intellij` @ `7bd2b92` | Schritt 1 (grep) | kein Verbotsmuster; Limits 4 CPU / 8192 MB gesetzt; Schritt 2/4 offen |
| 2026-09-30 | `python` @ `7bd2b92` | Schritt 1 (grep) | kein Verbotsmuster; Limits 1 CPU / 2048 MB gesetzt; Schritt 2/4 offen |
| 2026-09-30 | `sql` @ `7bd2b92` | Schritt 1 (grep) | kein Verbotsmuster; Limits 2 CPU / 4096 MB gesetzt; container-lokaler sudoers-Eintrag (Vermerk, greift nur im Workspace-Container); Schritt 2/4 offen |
