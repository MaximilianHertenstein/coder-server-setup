# Template-Allowlist (P-002, Stufe 1 – ohne Host-Umbau)

Stand: 2026-09-26. Status: Regelwerk ab sofort, Abhakpflicht pro Template.
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

- CPU-/Memory-Limits pro Workspace, eigene Bridge-Netze, Workspace-Volume.

## Abnahme pro Template/Änderung

1. Template-Datei gegen obige Listen geprüft (`grep` nach
   `docker.sock|privileged|pid:.*host|network_mode:.*host|postgres`).
2. Workspace-Selbsttest aus normalem Workspace (T-063): kein
   `/var/run/docker.sock`, kein `postgres:5432`, keine fremden Container.
3. Reviewer + Datum unten eingetragen.

## Abnahmen

| Datum | Template/Version | Prüfer | Ergebnis |
|---|---|---|---|
| _offen_ | _alle bestehenden_ | _–_ | Erstinventar steht aus (BLOCKER B-11-Teil) |
