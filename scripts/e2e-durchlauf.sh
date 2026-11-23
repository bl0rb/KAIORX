#!/bin/bash
# shellcheck disable=SC1111  # Die deutschen Anführungszeichen in Meldungen sind gewollt.
# Gesamtdurchlauf 0.7 (docs/e2e-durchlauf.md): bereitet vor und prüft, was sich prüfen lässt.
# Nur für den Kontoinhaber, selbst in Terminal.app getippt. Das Skript ruft kein Modell auf,
# meldet nirgends an und startet die App nicht; die Schritte in der App machst du selbst.
#
#   scripts/e2e-durchlauf.sh vorbereiten   Abschnitt 1 und 4: Protokoll, Debug-Build, Programme,
#                                          Anmeldung, Wegwerf-Repository, Vorher-Stand
#   scripts/e2e-durchlauf.sh profile       E5.4: nutzbare Modellprofile in der Datenbank (nur lesend)
#   scripts/e2e-durchlauf.sh nachher       E15.3, E16.3, E17.1: Refs, Lieferbranch, Checkout unverändert
#   scripts/e2e-durchlauf.sh bericht       Abschnitt 19: Codes, Git-Zustand, Versionen in eine Datei,
#                                          ohne Inhalte; vor dem Weitergeben selbst durchlesen
#
# Pfade lassen sich für Proben ändern: KAIORX_E2E_REPO, KAIORX_E2E_FILES (Protokoll und
# Vorher/Nachher-Dateien), KAIORX_E2E_SUPPORT (Application Support von KAIORX).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${KAIORX_E2E_REPO:-$HOME/kaiorx-e2e}"
FILES="${KAIORX_E2E_FILES:-$HOME}"
SUPPORT="${KAIORX_E2E_SUPPORT:-$HOME/Library/Application Support/KAIORX}"
DB="$SUPPORT/kaiorx.sqlite"
APP="$ROOT/build/DerivedData/Build/Products/Debug/KAIORX.app"
PROTOKOLL="$FILES/kaiorx-e2e-protokoll.md"
VORHER="$FILES/kaiorx-e2e-vorher.txt"
NACHHER="$FILES/kaiorx-e2e-nachher.txt"
BERICHT="$FILES/kaiorx-e2e-bericht.txt"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

FEHLER=0
ok() { printf '  OK      %s\n' "$1"; }
fehlt() { printf '  FEHLT   %s\n' "$1"; FEHLER=$((FEHLER + 1)); }
hinweis() { printf '          %s\n' "$1"; }
abschnitt() { printf '\n== %s\n' "$1"; }

# Wie kaiorx-acceptance (OwnerGuard): nicht aus Agenten, CI oder ohne Terminal.
nur_kontoinhaber() {
    local grund=""
    [ -t 0 ] && [ -t 1 ] || grund="keine interaktive Terminalsitzung"
    for name in CI GITHUB_ACTIONS BUILDKITE JENKINS_URL TF_BUILD GITLAB_CI TEAMCITY_VERSION; do
        [ -n "${!name+x}" ] && grund="automatisierte Umgebung ($name)"
    done
    if env | grep -Eq '^(CLAUDECODE|CLAUDE_CODE_|CODEX_SANDBOX|CODEX_MANAGED_|CODEX_THREAD)|^TERM_PROGRAM=KAIORX$'; then
        grund="Aufruf aus einem Agenten (Claude Code, Codex oder KAIORX)"
    fi
    if [ -n "$grund" ]; then
        echo "Abgelehnt: $grund. Tippe den Befehl selbst in Terminal.app (docs/e2e-durchlauf.md, Abschnitt 2)." >&2
        exit 2
    fi
}

# E-Mail-Adressen und den eigenen Benutzerordner nicht weitergeben.
redigieren() {
    sed -E -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<email>/g' -e "s#$HOME#~#g" -e "s#/Users/$(id -un)#~#g"
}

# --- Abschnitt 1 ----------------------------------------------------------------------------

protokoll_anlegen() {
    if [ -f "$PROTOKOLL" ]; then
        ok "Protokoll vorhanden: $PROTOKOLL (nicht überschrieben)"
        return
    fi
    {
        echo "# Protokoll Gesamtdurchlauf 0.7"
        echo
        echo "- Begonnen: $(date '+%Y-%m-%d %H:%M')"
        echo "- KAIORX: $(git -C "$ROOT" rev-parse --abbrev-ref HEAD) @ $(git -C "$ROOT" rev-parse --short HEAD)"
        echo "- macOS: $(sw_vers -productVersion)"
        echo
        echo "| Zeit | Schritt | Erwartet | Beobachtet | OK / Abweichung | Bild |"
        echo "|---|---|---|---|---|---|"
        echo
        echo "## Checkliste (aus docs/e2e-durchlauf.md, Abschnitt 20)"
        awk 'found { print } /^## 20 Checkliste/ { found = 1 }' "$ROOT/docs/e2e-durchlauf.md"
    } > "$PROTOKOLL"
    ok "Protokoll angelegt: $PROTOKOLL"
}

# --- Abschnitt 4.1 --------------------------------------------------------------------------

debug_build() {
    local log="$ROOT/build/e2e-build.log"
    mkdir -p "$ROOT/build"
    echo "  Debug-Build läuft (einige Minuten, Ausgabe in build/e2e-build.log) …"
    if (cd "$ROOT" && xcodebuild -project KAIORX.xcodeproj -scheme KAIORX -configuration Debug \
        -skipPackagePluginValidation -derivedDataPath build/DerivedData build) > "$log" 2>&1; then
        ok "E4.1 Debug-Build gebaut"
    else
        fehlt "E4.1 Debug-Build gescheitert; siehe $log"
        grep -E 'error:' "$log" | head -5 | while read -r line; do hinweis "$line"; done
        return
    fi
    local kanal
    kanal="$(/usr/libexec/PlistBuddy -c 'Print :KAIORXDistributionChannel' "$APP/Contents/Info.plist" 2>/dev/null)"
    if [ "$kanal" = "personal" ]; then
        ok "E4.1 Kanal personal"
    else
        fehlt "E4.1 Kanal ist „$kanal“ statt personal: in diesem Build startet nichts automatisch"
    fi
}

# --- Abschnitt 4.2 --------------------------------------------------------------------------

# Das Kit läuft nur an einem Terminal (OwnerGuard); `script` gibt ihm eines und fängt die
# Ausgabe auf. Seine Prüfung auf Agenten und CI sieht dieselbe Umgebung wie dieses Skript.
kit_preflight() {
    script -q /dev/null "$1" preflight 2>&1 < /dev/null | tr -d '\r\010' | sed 's/^\^D//'
}

programme_pruefen() {
    local bin
    echo "  Baue kaiorx-acceptance für die Vorprüfung (preflight: nur --version, Prüfsumme, Sandbox) …"
    if ! swift build --package-path "$ROOT/Packages/KAIORXKit" --product kaiorx-acceptance > "$ROOT/build/e2e-kit.log" 2>&1; then
        fehlt "E4.2 kaiorx-acceptance ließ sich nicht bauen; siehe build/e2e-kit.log"
        return
    fi
    bin="$(swift build --package-path "$ROOT/Packages/KAIORXKit" --show-bin-path)/kaiorx-acceptance"
    local ausgabe
    ausgabe="$(kit_preflight "$bin")"
    printf '%s\n' "$ausgabe" | redigieren | sed 's/^/          /'
    preflight_auswerten "$ausgabe"
}

# Liest die Ausgabe von `kaiorx-acceptance preflight` (Zeilen aus Acceptance/Preflight.swift).
preflight_auswerten() {
    local ausgabe="$1"
    if printf '%s\n' "$ausgabe" | grep -q '^Abgelehnt'; then
        fehlt "E4.2 kaiorx-acceptance hat die Vorprüfung abgelehnt (siehe oben)"
        return
    fi
    for anbieter in claude codex; do
        local block
        block="$(printf '%s\n' "$ausgabe" | awk -v a="$anbieter:" '$1 == a { on = 1; print; next } /^[a-z]+:/ { on = 0 } on')"
        if [ -z "$block" ] || printf '%s\n' "$block" | grep -q "nicht gefunden"; then
            fehlt "E4.2 $anbieter nicht gefunden"
        elif printf '%s\n' "$block" | grep -Eq '^  Build [0-9a-f]{16}…: live abgenommen$'; then
            ok "E4.2 $anbieter: Version und Build live abgenommen"
        else
            fehlt "E4.2 $anbieter: dieser Build ist nicht live abgenommen; erst eine neue Live-Abnahme (docs/live-acceptance/README.md)"
        fi
    done
    if printf '%s\n' "$ausgabe" | grep -q "OS-Isolation: wirksam"; then
        ok "Schreibschutz (sandbox-exec) wirkt"
    else
        fehlt "Schreibschutz (sandbox-exec) wirkt nicht: keine Automatik (E5.3)"
    fi
}

anmeldung_zeigen() {
    hinweis "E4.2c Anmeldung in den KAIORX-Ordnern (E-Mail-Adressen sind ersetzt):"
    if command -v claude > /dev/null; then
        hinweis "Claude:"
        CLAUDE_CONFIG_DIR="$SUPPORT/claude-config" claude auth status 2>&1 | redigieren | sed 's/^/            /'
    else
        hinweis "Claude: claude ist nicht im PATH; prüfe die Anmeldung wie in Abschnitt 4.2."
    fi
    if command -v codex > /dev/null; then
        hinweis "Codex:"
        CODEX_HOME="$SUPPORT/codex-home" codex login status 2>&1 | redigieren | sed 's/^/            /'
    else
        hinweis "Codex: codex ist nicht im PATH; prüfe die Anmeldung wie in Abschnitt 4.2."
    fi
    hinweis "Erwartet: Claude mit Abo (kein API-Schlüssel), Codex mit ChatGPT. Zusatzguthaben bei beiden aus."
    hinweis "Nicht angemeldet? Die Anmeldebefehle stehen oben unter „Anmeldung (selbst ausführen)“."
}

# --- Abschnitt 4.3 ---------------------------------------------------------------------------

repo_anlegen() {
    if [ -e "$REPO" ]; then
        if git -C "$REPO" rev-parse --verify -q HEAD > /dev/null && [ -f "$REPO/check.sh" ]; then
            ok "E4.3 Wegwerf-Repository vorhanden: $REPO (nicht verändert)"
            [ -f "$REPO/lokal.txt" ] || hinweis "lokal.txt fehlt; ohne sie zeigt E17.1 weniger."
            [ -e "$REPO/hallo.txt" ] && hinweis "hallo.txt liegt schon im Checkout; nimm für den Hauptweg ein frisches Repository."
        else
            fehlt "E4.3 $REPO gibt es, aber nicht als Wegwerf-Repository mit check.sh; nimm einen anderen Pfad (KAIORX_E2E_REPO)"
        fi
        return
    fi
    if mkdir -p "$REPO" && (
        cd "$REPO" || exit 1
        git init -q -b main
        printf '# KAIORX E2E\n\nWegwerf-Repository für den Gesamtdurchlauf.\n' > README.md
        cat > check.sh <<'SKRIPT'
#!/bin/sh
# Prüft hallo.txt nur, wenn es die Datei gibt.
if [ -f hallo.txt ]; then
  grep -qx 'Hallo Welt' hallo.txt
fi
SKRIPT
        git add -A && git commit -qm start
        printf 'nicht committet\n' > lokal.txt
    ); then
        ok "E4.3 Wegwerf-Repository angelegt: $REPO (mit uncommittetem lokal.txt)"
    else
        fehlt "E4.3 Wegwerf-Repository nicht angelegt"
    fi
}

# --- Abschnitt 4.4 und 4.5 -------------------------------------------------------------------

umgebung_pruefen() {
    local frei
    frei="$(df -g "$HOME" | awk 'NR == 2 { print $4 }')"
    if [ "${frei:-0}" -ge 5 ]; then ok "E4.4 $frei GB frei"; else fehlt "E4.4 nur ${frei:-?} GB frei (einige GB nötig)"; fi
    if pgrep -x KAIORX > /dev/null; then
        fehlt "E4.4 KAIORX läuft schon; beende die App vor dem Start des Debug-Builds"
    else
        ok "E4.4 keine laufende KAIORX-Instanz"
    fi
}

checkout_stand() { (cd "$REPO" && git rev-parse HEAD && git status --porcelain=v2 --branch && git branch --list); }

vorher_festhalten() {
    if [ -f "$VORHER" ]; then
        ok "E4.5 Vorher-Stand vorhanden: $VORHER (nicht überschrieben)"
    elif checkout_stand > "$VORHER" 2> /dev/null; then
        ok "E4.5 Vorher-Stand geschrieben: $VORHER"
    else
        rm -f "$VORHER"
        fehlt "E4.5 Vorher-Stand nicht geschrieben (kein Repository unter $REPO)"
    fi
}

vorbereiten() {
    nur_kontoinhaber
    abschnitt "Abschnitt 1: Protokoll";               protokoll_anlegen
    abschnitt "4.1 Debug-Build";                      debug_build
    abschnitt "4.2 Claude Code und Codex";            programme_pruefen; anmeldung_zeigen
    abschnitt "4.3 Wegwerf-Repository";               repo_anlegen
    abschnitt "4.4 und 4.5 Umgebung und Vorher-Stand"; umgebung_pruefen; vorher_festhalten
    abschnitt "Ergebnis"
    if [ "$FEHLER" -eq 0 ]; then
        echo "  Alles bereit. Prüfe die Anmeldung oben selbst, setze bei Bedarf export DISABLE_AUTOUPDATER=1"
        echo "  und starte dann die App (E5.1):"
        echo
        echo "    open '$APP'"
        echo
        echo "  Nach dem Start und dem Onboarding: scripts/e2e-durchlauf.sh profile"
    else
        echo "  $FEHLER Punkt(e) fehlen (siehe FEHLT). Behebe sie, dann rufe das Skript erneut auf;"
        echo "  Vorhandenes (Protokoll, Repository, Vorher-Stand) bleibt dabei unverändert."
    fi
    [ "$FEHLER" -eq 0 ]
}

# --- E5.4 ------------------------------------------------------------------------------------

profile() {
    abschnitt "E5.4 nutzbare Modellprofile (nur lesend)"
    if [ ! -f "$DB" ]; then
        fehlt "keine Datenbank unter $DB; starte zuerst die App"
        return 1
    fi
    local zeilen
    if ! zeilen="$(sqlite3 -readonly "$DB" "SELECT provider, role, tier, model FROM model_profile WHERE verified_at IS NOT NULL AND disabled_reason IS NULL ORDER BY provider, role;" 2>&1)"; then
        fehlt "Datenbank nicht lesbar: $zeilen"
        return 1
    fi
    printf '%s\n' "$zeilen" | sed '/^$/d; s/^/          /'
    for paar in claude\|author claude\|reviewer codex\|author codex\|reviewer; do
        if printf '%s\n' "$zeilen" | grep -q "^$paar|standard|"; then ok "$paar"; else fehlt "$paar: kein nutzbares Profil der Stufe standard"; fi
    done
    if [ "$FEHLER" -gt 0 ]; then
        hinweis "Den Grund zeigt der Onboarding-Eintrag „Modellprofile“ oder „Einrichtung prüfen …“; das Systemprotokoll:"
        hinweis "log show --last 1h --predicate 'subsystem == \"dev.kaiorx.KAIORX\" AND category == \"profiles\"'"
    fi
    [ "$FEHLER" -eq 0 ]
}

# --- E15.3, E16.3, E17.1 ---------------------------------------------------------------------

nachher() {
    abschnitt "E15.3 Refs und Integrationsstand"
    if ! git -C "$REPO" rev-parse -q --verify HEAD > /dev/null 2>&1; then
        fehlt "kein Repository unter $REPO"
        return 1
    fi
    for art in integrations results candidates; do
        local anzahl
        anzahl="$(git -C "$REPO" for-each-ref --format='%(refname)' "refs/kaiorx/$art/" | wc -l | tr -d ' ')"
        if [ "$anzahl" -gt 0 ]; then ok "refs/kaiorx/$art/: $anzahl"; else fehlt "keine Refs unter refs/kaiorx/$art/"; fi
    done
    local integration
    integration="$(git -C "$REPO" for-each-ref --format='%(refname)' 'refs/kaiorx/integrations/*' | head -1)"
    if [ -n "$integration" ] && [ "$(git -C "$REPO" show "$integration:hallo.txt" 2> /dev/null)" = "Hallo Welt" ]; then
        ok "hallo.txt im Integrationsstand: Hallo Welt"
    else
        fehlt "hallo.txt im Integrationsstand fehlt oder lautet anders"
    fi
    local fremd
    fremd="$(git -C "$REPO" worktree list --porcelain | awk '/^worktree / { sub(/^worktree /, ""); print }' | grep -vx "$(cd "$REPO" && pwd -P)" | grep -v "^$SUPPORT/workspace/" || true)"
    if [ -z "$fremd" ]; then ok "Worktrees nur unter Application Support/KAIORX/workspace"; else fehlt "Worktrees außerhalb: $(printf '%s' "$fremd" | redigieren | tr '\n' ' ')"; fi

    abschnitt "E16.3 Lieferbranch"
    local branches
    branches="$(git -C "$REPO" branch --list 'kaiorx/*' --format='%(refname:short)')"
    if [ -z "$branches" ]; then
        fehlt "kein Lieferbranch kaiorx/* (E16.2)"
    else
        for branch in $branches; do
            if [ "$(git -C "$REPO" show "$branch:hallo.txt" 2> /dev/null)" = "Hallo Welt" ]; then ok "$branch enthält hallo.txt"; else fehlt "$branch ohne passendes hallo.txt"; fi
        done
    fi

    abschnitt "E17.1 Checkout unverändert"
    if [ ! -f "$VORHER" ]; then
        fehlt "kein Vorher-Stand ($VORHER); E17.1 lässt sich nicht vergleichen"
    else
        checkout_stand > "$NACHHER"
        local unterschied
        unterschied="$(diff "$VORHER" "$NACHHER" | grep -E '^[<>]' || true)"
        local neu_erwartet
        neu_erwartet="$(printf '%s\n' "$unterschied" | grep -Ev '^>   kaiorx/' | sed '/^$/d' || true)"
        if [ -z "$neu_erwartet" ]; then
            ok "einziger Unterschied: neue Branches kaiorx/* (Nachher-Stand: $NACHHER)"
        else
            fehlt "Checkout verändert:"
            printf '%s\n' "$neu_erwartet" | sed 's/^/            /'
        fi
    fi
    if [ -e "$REPO/hallo.txt" ]; then fehlt "hallo.txt liegt im Checkout"; else ok "kein hallo.txt im Checkout"; fi
    if [ "$(cat "$REPO/lokal.txt" 2> /dev/null)" = "nicht committet" ]; then ok "lokal.txt unverändert"; else fehlt "lokal.txt fehlt oder ist verändert"; fi
    [ "$FEHLER" -eq 0 ]
}

# --- Abschnitt 19 ----------------------------------------------------------------------------

bericht() {
    nur_kontoinhaber
    {
        echo "# KAIORX Gesamtdurchlauf 0.7: Angaben für die Fehlersuche ($(date '+%Y-%m-%d %H:%M'))"
        echo
        echo "## Versionen"
        echo "KAIORX $(git -C "$ROOT" rev-parse --short HEAD), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
        local bin
        bin="$(swift build --package-path "$ROOT/Packages/KAIORXKit" --show-bin-path 2> /dev/null)/kaiorx-acceptance"
        if [ -x "$bin" ]; then kit_preflight "$bin" | grep -Ev 'Anmeldung \(selbst'; else echo "(kaiorx-acceptance nicht gebaut; erst vorbereiten)"; fi
        echo
        echo "## Zustände (Codes, keine Inhalte)"
        if [ -f "$DB" ]; then
            sqlite3 -readonly "$DB" "
              SELECT 'task', state, resume_state, wait_reason FROM task ORDER BY created_at;
              SELECT 'attempt', role, provider, model, state, error_class, process_lost FROM attempt ORDER BY reserved_at;
              SELECT 'candidate', kind, state FROM candidate ORDER BY created_at;
              SELECT 'test', status, exit_code FROM test_result ORDER BY at;
              SELECT 'review', origin, reviewer_provider, status FROM review ORDER BY at;
              SELECT 'gitop', kind, state FROM git_operation ORDER BY created_at;
              SELECT 'profile', provider, role, tier, verified_at IS NOT NULL FROM model_profile;" 2>&1
        else
            echo "(keine Datenbank)"
        fi
        echo
        echo "## Git-Zustand des Wegwerf-Repositories"
        git -C "$REPO" for-each-ref --format='%(refname)' refs/kaiorx/ 2>&1
        git -C "$REPO" worktree list 2>&1
        if [ -f "$VORHER" ] && [ -f "$NACHHER" ]; then
            echo
            echo "## diff vorher/nachher"
            diff "$VORHER" "$NACHHER"
        fi
    } | redigieren > "$BERICHT"
    echo "Geschrieben: $BERICHT"
    echo "Lies die Datei vor dem Weitergeben durch. Dazu gehören das Protokoll und „Redigiert kopieren“ aus dem Monitor."
    echo "Nicht weitergeben: kaiorx.sqlite, claude-config/, codex-home/, Ausgaben von auth/login status."
}

hauptprogramm() {
    case "${1:-}" in
        vorbereiten) vorbereiten ;;
        profile) profile ;;
        nachher) nachher ;;
        bericht) bericht ;;
        *) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; [ -z "${1:-}" ] || exit 1 ;;
    esac
}

# Beim Einlesen mit `source` (Proben einzelner Schritte) läuft nichts von selbst.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    hauptprogramm "$@"
fi
