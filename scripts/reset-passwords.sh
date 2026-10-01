#!/bin/bash
# Setzt das Grafana-Admin-Passwort neu (zufällig, hex): GF_SECURITY_ADMIN_PASSWORD
# wirkt nur beim allerersten Start – ein einfaches Ändern der .env genügt bei
# einer bereits laufenden Installation NICHT. POSTGRES_PASSWORD bleibt bewusst
# unberührt (Nicht-Hex-Reparatur dort: TROUBLESHOOTING.md A4).
#
# Reihenfolge Grafana -> .env: bei Abbruch heilt ein erneutes Ausführen
# (würfelt neu und synchronisiert beide Seiten), .bak stellt den alten Stand her.
# Nutzung: sudo /opt/coder/reset-passwords.sh
set -euo pipefail
cd /opt/coder

# Wartungs-Lock serialisiert Passwortrotation mit Update, Backup und Reset.
# FD 8 wird an backup.sh vererbt; das Marker-Env verhindert dort Deadlock.
(umask 077; : >> /opt/coder/.maintenance.lock)
chown root:root /opt/coder/.maintenance.lock
chmod 600 /opt/coder/.maintenance.lock
exec 8>>/opt/coder/.maintenance.lock
if ! flock -w 300 8; then
  echo "reset-passwords.sh: Wartungs-Lock nach 300 s nicht erhalten; Passwortwechsel abgebrochen." >&2
  exit 75
fi
export CODER_MAINTENANCE_LOCK_HELD=1

if [ ! -f .env ]; then
  echo "Fehler: /opt/coder/.env nicht gefunden. Erst setup-coder.sh ausführen." >&2
  exit 1
fi
# Beide Passwort-Schlüssel sind Voraussetzung, auch wenn nur GRAFANA rotiert
# wird: der atomare Tausch unten filtert nur die Grafana-Zeile heraus – ohne
# POSTGRES_PASSWORD-Zeile als Überlebende würde "grep -v" eine leere Datei
# erzeugen und set -e abbrechen (Fail-closed, .env unangetastet).
if ! grep -qE '^POSTGRES_PASSWORD=[^[:space:]]+' .env \
  || ! grep -qE '^GRAFANA_ADMIN_PASSWORD=[^[:space:]]+' .env; then
  echo "Fehler: /opt/coder/.env enthält nicht beide Passwort-Schlüssel (POSTGRES_PASSWORD, GRAFANA_ADMIN_PASSWORD). Erst nach Setup-Vorgabe ergänzen (vorhandene Werte behalten), dann erneut." >&2
  exit 1
fi
# B2-003: Newline/NUL im .env-Wert hart abweisen, kein stilles Trimmen. Ein
# Ein Hand-Edit kann die Compose-Env-Datei durch eine ungueltige Zusatzzeile
# unlesbar machen; in diesem Zustand wird nichts automatisch getrimmt.
if [ "$(LC_ALL=C tr -d -c '\000' < .env | wc -c)" -ne 0 ] \
  || grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=|^#|^$' .env; then
  echo "Fehler: .env-Wert enthält Newline/NUL – wird nicht still getrimmt." >&2
  echo "Reparatur: .env-Zeilenstruktur manuell korrigieren (Schlüssel=einzeiliger Wert), dann reset-passwords.sh erneut ausführen." >&2
  exit 1
fi

# Beide Container müssen laufen: Grafana direkt, Postgres für das Vorab-Backup.
for c in coder-postgres coder-grafana; do
  if [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)" != "true" ]; then
    echo "Fehler: Container ${c} läuft nicht. Erst 'docker compose up -d' ausführen." >&2
    exit 1
  fi
done

# Verifiziertes Vorab-Backup als Rollback-Basis (P-018): schlägt das fehl,
# wird gar nichts geändert.
echo "Ziehe Vorab-Backup (Rollback-Basis)..."
/opt/coder/backup.sh

ENV_BAK=".env.bak.$(date +%Y-%m-%d_%H%M%S)"
cp -a .env "${ENV_BAK}"
chmod 600 "${ENV_BAK}"
# Genau eine .bak-Generation behalten (P-018: keine Secret-Halde).
(ls -t .env.bak.* 2>/dev/null || true) | tail -n +2 | xargs -r rm -f
echo "Sicherung der alten .env: ${ENV_BAK}"

# Abbruch-Falle (F-010/B-014): weist bei Ctrl-C/SSH-Abbruch/Fehler den Weg, statt
# still Grafana=neu/.env=alt zu hinterlassen. Texte pro Fenster getrennt
# (Grafana vs. .env), damit der Zustand ohne Klartext-Log diagnostizierbar ist.
# Re-Run heilt (würfelt erneut und synchronisiert Grafana+.env); .bak stellt
# den Vorzustand wieder her.
PHASE="Vorbereitung"
reset_passwords_cleanup() {
  local rc=$?
  rm -f .env.tmp.??????
  if [ "${rc}" -ne 0 ]; then
    echo "ABBRUCH in Phase [${PHASE}]." >&2
    case "${PHASE}" in
      Grafana-Reset)
        echo "Fenster Grafana: Grafana evtl. bereits neu, .env noch alt." >&2 ;;
      .env-Tausch)
        echo "Fenster .env: Grafana bereits neu, .env evtl. noch alt." >&2 ;;
      *)
        echo "Fenster Vorbereitung: noch nichts geändert (.bak liegt vor)." >&2 ;;
    esac
    echo "Reparatur: reset-passwords.sh erneut ausführen; es würfelt ein neues Grafana-Passwort und synchronisiert die .env. Der alte Stand steht in ${ENV_BAK}." >&2
  fi
  return "${rc}"
}
trap reset_passwords_cleanup EXIT

# hex statt base64: garantiert nur 0-9a-f. Das Setup-Gate verlangt für jeden
# .env-Passwortwert hex (auch nach Hand-Edit) – die Neuwürfelung muss diese
# Grenze erfüllen und kann nie Quotes/Sonderzeichen über stdin tragen.
NEW_GF_PW=$(openssl rand -hex 16)
# B2-003: Fail-closed für nicht-Hex NEU, BEVOR Grafana/.env angerührt wird.
# openssl -hex liefert immer Hex; die Prüfung ist die harte Grenze, falls hier
# je ein anderes Zeichenset gewählt würde (sonst bricht das Setup-Gate beim
# nächsten Lauf still ab).
case "${NEW_GF_PW}" in
  ''|*[!0-9a-f]*)
    echo "Fehler: Neuwürfelung lieferte kein Hex – Abbruch ohne Änderung." >&2
    exit 1
    ;;
esac

echo "Setze neues Grafana-Admin-Passwort..."
PHASE="Grafana-Reset"
# Nur STDIN, kein Argument und kein Heredoc in die Shell: sonst stünde das
# neue Passwort in der Argumentliste der CLI bzw. kurzzeitig über
# "ps aux" auf dem Host. --password-from-stdin gibt es seit Grafana 11.
printf '%s\n' "${NEW_GF_PW}" | docker exec -i coder-grafana \
  grafana cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin

# .env aktualisieren, damit der neue Wert abrufbar dokumentiert ist
# (GF_SECURITY_ADMIN_PASSWORD wirkt nur beim Erststart). F-010: atomar per
# Temp+mv statt "sed -i" (Abbruch während sed korrumpierte .env).
PHASE=".env-Tausch"
ENV_TMP_PW=$(mktemp .env.tmp.XXXXXX)
chmod 600 "${ENV_TMP_PW}"
# Kein "|| true": Exit 1 hieße "alle Zeilen gefiltert" (der Gate oben sichert,
# dass die POSTGRES_PASSWORD-Zeile als Überlebende bleibt) – dann ist Abbrechen
# (Fail-closed, .env unangetastet) richtig.
grep -v '^GRAFANA_ADMIN_PASSWORD=' .env > "${ENV_TMP_PW}"
printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "${NEW_GF_PW}" >> "${ENV_TMP_PW}"
chmod 600 "${ENV_TMP_PW}"
mv "${ENV_TMP_PW}" .env

PHASE="fertig"
trap - EXIT

echo "------------------------------------------------------------"
echo "Neues Grafana-Admin-Passwort wurde in /opt/coder/.env (Modus 600) gespeichert."
echo "Bei Bedarf gezielt abrufen: sudo sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' /opt/coder/.env"
echo "  POSTGRES_PASSWORD wurde NICHT verändert (bleibt in /opt/coder/.env, nur root lesbar)."
echo "  C2: Beim nächsten vollständigen 'docker compose up -d' wird Grafana neu"
echo "      erstellt (Env-Hash) – kurzer Neustart, Volumes/Dashboards bleiben."
echo "      Postgres und Coder sind nicht betroffen."
echo "------------------------------------------------------------"
