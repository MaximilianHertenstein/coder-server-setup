# Agenten-Setup

Kurzfassung: Der Agent arbeitet nur auf dem Testhost (Hetzner) über einen
SSH-Tunnel und einen eigenen Token. Du prüfst das Ergebnis, committest und
pushst. Die GitHub Action überträgt das getestete Template auf den
Schulserver. Der Agent hat keinen Produktionszugang.

Stand 2026-11-22: Der Schulserver ist öffentlich erreichbar
(`https://coder.ghse-unterricht.de`, Zertifikat bis 2027-02-20), der
Hetzner läuft nur per Tunnel, Caddy dort ist gestoppt. `template-agent` und
der Workflow werden nach §3 einmalig eingerichtet.

## 1. Rollen

| Wer/Wo | Zweck | Zugang | Daten |
|---|---|---|---|
| Schulserver `10.16.1.13` | Produktion | `https://coder.ghse-unterricht.de`, SSH nur aus dem Schulnetz | Workspaces der Nutzer |
| Hetzner `2.29.11.30` | Test/Staging | SSH als root, Coder nur per Tunnel | keine echten Nutzerdaten, wegwerfbar |
| GitHub | Quelle und Deployment | Repo, Actions | Templates, keine Secrets im Code |
| GitHub Action | Template-Push auf Produktion | Token von `template-agent` als Secret | Produktions-Token |

Nur der Schulserver beansprucht `coder.ghse-unterricht.de`. Auf dem Hetzner
läuft Caddy gestoppt, Port 80/443 sind dort zu.

## 2. Vertrauensmodell und Grundregeln

### 2.1 Vertrauensgrenzen

- **Hetzner:** Root-SSH bedeutet volle Kontrolle über die Coder-Instanz. Der
  Agent kann das Owner-Passwort zurücksetzen und sich Tokens selbst erzeugen.
  Der Token ist dort keine Sicherheitsgrenze, sondern Bequemlichkeit. Das ist
  vertretbar, weil der Host wegwerfbar ist und keine Produktionsdaten enthält.
- **Schulserver:** Produktion. Kein SSH, kein Token, kein GitHub-Secret für
  den Agenten. Templates gehen ausschließlich über die GitHub Action,
  Stack-Änderungen ausschließlich über den Betreiber.
- **GitHub:** Der Agent hat keine Push-Rechte und keinen Admin-Zugang. Sonst
  könnte er das Deploy-Gate umgehen oder das Secret lesen.
- Die echte Grenze sind Schulserver und GitHub, nicht der Hetzner-Token. Wird
  der Hetzner kompromittiert, setzt du ihn neu auf.

### 2.2 Regeln

- Der Agent bekommt nie einen Produktions-Token. Er sieht nur den Hetzner.
- Kein Secret in Repo, Chat, Log oder Issue. Ablage: Umgebungsvariable oder
  Datei mit `600` außerhalb des Repos.
- Der Agent committet und pusht nicht. Das machst du nach Durchsicht.
- Templates gehen über die GitHub Action auf Produktion, der Stack nur über
  dein eigenes `./setup-coder.sh` auf dem Schulserver.
- Test-Workspaces immer mit `--stop-after` anlegen und danach löschen.
- Auf den Hetzner kommen keine echten Nutzerdaten, auch nicht bei
  Restore-Proben (siehe §6).

## 3. Einmalige Einrichtung

### 3.1 Hetzner: Zugang für den Agenten

Tunnel in einem eigenen Terminal offen lassen:

```
ssh -N -L 3000:172.18.0.6:3000 root@2.29.11.30
```

Der Agent bekommt `CODER_URL=http://127.0.0.1:3000`.

Token: Der Owner-Account (`owner` / `owner@ghse-unterricht.de`) ist auf dem
Hetzner auf 7 Tage begrenzt. Für längere Läufe einen eigenen Account anlegen,
der sich nie anmelden kann:

```
# Einmal als Owner einloggen (Passwort ggf. vorher zurücksetzen):
#   docker exec -it coder coder reset-password owner
coder login http://127.0.0.1:3000

coder users create --username template-agent \
  --email maximilian.hertenstein+template-agent@ghse.de \
  --login-type none --full-name "Template Agent"
coder users edit-roles --roles member,template-admin template-agent
coder tokens create --user template-agent -n template-agent
```

Der Token liegt außerhalb des Repos:

```
install -m 600 /dev/null ~/.config/coder-agent/hetzner-token
# Wert eintragen, der Agent liest:
#   CODER_SESSION_TOKEN=$(cat ~/.config/coder-agent/hetzner-token)
```

Der Agent darf sich den Token auch selbst holen: Mit root auf dem Hetzner
setzt er per `docker exec -it coder coder reset-password owner` das
Owner-Passwort neu, loggt sich ein und erzeugt den Token. Sauberer ist, er
legt einmal `template-agent` an und legt dessen Token unter dem Pfad oben ab.
Ein Reset betrifft den gemeinsamen Owner-Account, auf dem Testhost ist das
unkritisch.

Caddy bleibt aus (kommt nach einem Setup-Lauf zurück, dann erneut stoppen):

```
docker compose -f /opt/coder/docker-compose.yml stop caddy
```

Für echte Workspace-Tests muss der Workspace die API erreichen. Die
Produktionsdomain gehört dem Schulserver, deshalb testweise die eigene
Adresse im Docker-Netz (wird vom Setup überschrieben):

```yaml
    ports:
      - "172.17.0.1:3000:3000"
    environment:
      CODER_ACCESS_URL: http://172.17.0.1:3000
```

Danach `docker compose -f /opt/coder/docker-compose.yml up -d coder` und den
Workspace neu bauen. Ohne diese Einstellung baut der Workspace, aber der
Agent verbindet nicht: kein `coder ssh`, keine Ports, keine App.

### 3.2 Schulserver: Deploy-Account

```
coder login https://coder.ghse-unterricht.de        # als maximilian

coder users create --username template-agent \
  --email maximilian.hertenstein+template-agent@ghse.de \
  --login-type none --full-name "Template Agent"
coder users edit-roles --roles member,template-admin template-agent
coder tokens create --user template-agent -n github-deploy --lifetime 90d \
  --scope coder:templates.author
```

Der Deploy-Token ist bewusst gescopet: `coder:templates.author` erlaubt
Dateien und Templates, aber keine Nutzer, Rollen oder Server-Einstellungen.
Falls die Action mit 403 abbricht, fehlt eine Berechtigung – dann eng
nachziehen, nicht auf `coder:all` gehen.

Für Eingriffe von Hand (Diagnose, Hotfix) lieber einen kurzlebigen Token
erzeugen und danach löschen:

```bash
coder tokens create --user template-agent -n handeingriff --lifetime 8h \
  --scope coder:templates.author \
  --scope coder:workspaces.create \
  --scope coder:workspaces.access \
  --scope coder:workspaces.delete
```

`member` ist Pflicht: `template-admin` darf Workspaces nur lesen. Der Account
hat kein Passwort und kann sich nicht anmelden. Den Token nach GitHub legen,
nicht in eine Datei im Repo.

### 3.3 GitHub

- **Variable** `CODER_URL` = `https://coder.ghse-unterricht.de` (keine URL ist
  ein Secret).
- **Secret** `CODER_SESSION_TOKEN` = der 90-Tage-Token von `template-agent`.
- Optional ein Environment `production` mit Reviewer, damit ein Push nicht
  sofort deployt.

Workflow `.github/workflows/deploy-template.yml`:

```yaml
name: deploy-template
on:
  push:
    branches: [main]
    paths: ["templates/**", ".github/workflows/deploy-template.yml"]
  workflow_dispatch:

concurrency:
  group: deploy-template
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    env:
      CODER_URL: ${{ vars.CODER_URL }}
      CODER_SESSION_TOKEN: ${{ secrets.CODER_SESSION_TOKEN }}
    strategy:
      matrix:
        template: [python]
    steps:
      - uses: actions/checkout@v4
      - name: Coder CLI installieren
        run: curl -fsSL "$CODER_URL/install.sh" | sudo sh
      - name: Template pushen
        run: coder templates push "${{ matrix.template }}" --directory "templates/${{ matrix.template }}" --yes
```

Die Matrix um die vorhandenen Templates erweitern. Kein `pull_request_target`
verwenden, damit Fork-PRs nie an den Token kommen.

## 4. Arbeitsablauf

1. Der Agent schreibt das Template unter `templates/<name>/`.
2. Test auf dem Hetzner:

```
export CODER_URL=http://127.0.0.1:3000
export CODER_SESSION_TOKEN=$(cat ~/.config/coder-agent/hetzner-token)

coder templates push <name> --directory templates/<name> --yes
coder create test-<name> -t <name> --stop-after 1h -y
coder ssh test-<name> -- <smoke-test>
coder delete test-<name> -y
```

   Der Smoke-Test prüft, was das Template verspricht: Werkzeuge vorhanden,
   Startskript sauber durchgelaufen, Dateien im Home.
3. Du prüfst den Diff, committest und pusht.
4. Die Action pusht das Template auf den Schulserver. Run und Log prüfen.
5. Smoke-Test auf Produktion mit einer Test-Workspace (`--stop-after 1h`),
   danach löschen.
6. Rollback: in der UI beim Template die vorherige Version aktivieren.

## 5. Sicherheit

- Least Privilege: `member` + `template-admin`, nie `owner` für Agenten.
- Scopes statt `coder:all`: der Deploy-Token nur `coder:templates.author`,
  Handeingriffe kurzlebig und auf Templates/Workspaces begrenzt.
- Token-Laufzeiten: Nicht-Owner maximal 100 Jahre, Owner maximal 7 Tage,
  ohne `--lifetime` gilt die Obergrenze. `--lifetime 0` heißt 30 Tage, nicht
  unendlich.
- Widerruf: `coder tokens ls`, dann `coder tokens rm <id>`.
- GitHub: Secret nur im Workflow, nicht echoen, Actions mit fester Version
  pinnen, Deploy-Job an ein Environment mit Reviewer hängen.
- `.gitignore` deckt `.env`, `.env.*` und `*.token`. Trotzdem gilt: Secrets
  gehören außerhalb des Repos, nicht nur in eine ignorierte Datei.
- Kein Push-Recht: Der Agent darf keine Git-Credentials und keinen
  Repo-Admin-Zugang haben. Sonst umgeht er das Deploy-Gate. Prüfen mit
  `git config --get credential.helper`, `git remote -v` und den
  GitHub-Rollen.
- Der Produktions-Token liegt nur in GitHub Actions. Der Agent kennt weder
  den Wert noch hat er Schreibzugriff auf das Secret.
- SSH auf dem Hetzner ist root. Wenn möglich, per Hetzner-Cloud-Firewall auf
  deine Adresse beschränken.

## 6. Robustheit

- Beide Hosts kommen aus demselben Repo mit denselben Pins. Erst auf dem
  Hetzner testen, dann auf den Schulserver.
- Das Setup ist idempotent. Test-Overrides (Access-URL, Caddy aus) werden
  beim nächsten Lauf überschrieben, das ist so gewollt.
- Backups laufen nur auf Produktion. Restore-Proben laufen auf dem Hetzner
  nach [RESTORE.md](RESTORE.md), danach das Ziel wieder verwerfen. Echte
  Nutzerdaten dabei nicht dauerhaft auf dem Testhost liegen lassen.
- Überwachung: `/healthz`, Zertifikatslaufzeit, BackupStale-Check und Grafana
  nach [OPERATIONS.md](OPERATIONS.md) §6.
- Test-Workspaces mit `--stop-after` anlegen, damit die Platte nicht vollläuft.
- Stack-Updates macht nur der Betreiber per `./setup-coder.sh` auf dem
  Schulserver. Die GitHub Action ändert nur Templates.

## 7. Checks

Produktion:

```
curl -s -o /dev/null -w '%{http_code}\n' https://coder.ghse-unterricht.de/healthz
echo | openssl s_client -connect coder.ghse-unterricht.de:443 \
  -servername coder.ghse-unterricht.de 2>/dev/null | \
  openssl x509 -noout -dates
```

Hetzner:

```
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/healthz
ss -tlnp | grep -E ':80\b|:443\b'      # leer, solange Caddy gestoppt ist
```

Vor dem ersten Agentenlauf:

- SSH zum Schulserver schlägt fehl.
- Gegen `https://coder.ghse-unterricht.de` hat der Agent keinen Token und
  kann auch keinen erzeugen.
- `git config --get credential.helper` ist leer, `git remote -v` enthält
  keinen Token, und der Agent hat keinen GitHub-Admin-Zugang.

Fehlerbilder und Gegenmaßnahmen stehen in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 8. Offene Punkte

- **Hairpin:** Der erste Workspace auf dem Schulserver muss zeigen, ob der
  Agent `https://coder.ghse-unterricht.de` aus dem Schulnetz erreicht. Wenn
  nicht, im Template `coder.ghse-unterricht.de` auf `10.16.1.13` zeigen
  lassen.
- **Hetzner-Access-URL** ist ein Test-Override und wird vom Setup
  zurückgesetzt.
- **Docker-DNS auf dem Schulserver:** `127.0.0.53` aus systemd-resolved
  landet in den Containern; die Templates umgehen das mit
  `network_mode = "host"` und expliziten Resolvern. Dauerhaft `dns` in
  `/etc/docker/daemon.json` setzen (Schul-Resolver, keine öffentlichen),
  dann die Workarounds entfernen ([TROUBLESHOOTING B7](TROUBLESHOOTING.md)).
- **Caddy auf dem Hetzner** startet nach jedem Setup-Lauf wieder.
- **Token-Rotation** für den GitHub-Deploy-Token terminieren (90 Tage).
