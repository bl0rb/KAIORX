# ADR 0003 · Anbieteradapter vor der Live-Abnahme

**Status:** angenommen, 19. November 2026 · **Betrifft:** Paket D, `Plan/anbieter.md`, Paket A (Abnahme)

## Kontext

Paket D verlangt zwei persönliche Aboläufe und hängt von Paket A ab: Live-Abnahme mit den Konten des Benutzers. Diese Läufe kann nur der Kontoinhaber starten. Die Adapter, die Protokollverarbeitung und die Sicherheitsregeln lassen sich aber schon vorher bauen und gegen die installierten Versionen prüfen (`Claude Code 2.1.328`, `codex-cli 0.170.0`).

## Entscheidung

1. **Gate statt Vertrauen.**
   - `CompatibilityMatrix` führt jede geprüfte Version mit Status `offlineVerified` oder `liveVerified`.
   - Die Standard-`AdapterPolicy` startet automatische Läufe nur bei `liveVerified`. Bis Paket A durch ist, bleibt der automatische Modus gesperrt, und `probe` meldet ihn nicht.
   - Eine Version, die nicht in der Matrix steht, ist ebenfalls gesperrt.
   - Vor jedem Start wird das Binary neu aufgelöst und seine Datei-Signatur verglichen. Gestartet wird der aufgelöste Pfad, der die Prüfung bestanden hat. So läuft nach einem Selbst-Update keine ungeprüfte Version unter altem Namen.
   - Ohne OS-Isolation verweigert die Standard-Policy den Start (`requiresConfinement`).
   - Tests mit Fixture-Programmen schalten beides ausdrücklich ab (`AdapterPolicy.fixtureTesting`).

2. **Claude Code.**
   - Das Startprofil folgt dem Plan: `-p`, `stream-json`, `--restricted`, `--safe-mode`, `--strict-mcp-config`, `--disable-slash-commands`, `--permission-mode manual`, `--permission-prompts none`, `--no-session-persistence`, ein explizites `--model`.
   - Reviewer erhalten die Werkzeuge `Read,Grep,Glob`. Autoren erhalten zusätzlich `Edit,Write`, beschränkt per `--allowedTools` auf die freigegebenen Pfade.
   - Alle Flags stehen in `claude --help` von 2.1.328.
   - Der Prompt geht über stdin.
   - Die Umgebung enthält nur `PATH`, `HOME`, `TMPDIR`, `LANG` und KAIORXs eigenes `CLAUDE_CONFIG_DIR`. API-Schlüssel und Anbieter-Overrides erreichen den Prozess nie.
   - Usage wird je Message-ID nur einmal gezählt.
   - Endet der Prozess ohne `result`-Ereignis, bleibt der Ausgang offen und der Lauf wird `uncertain`.
   - Endet der Prozess vor der Sitzungsinitialisierung mit einem Fehler, ist das ein sicherer Fehlstart (`failed`).
   - Abbruch: SIGINT, dann TERM und KILL an die Prozessgruppe. Nur ein `result`-Ereignis bestätigt den Abbruch; ein nach der Frist beendeter Prozess hinterlässt einen offenen Ausgang.

3. **Codex App Server.**
   - Ein `codex app-server --listen stdio:// --strict-config` je Versuch mit eigenem `CODEX_HOME`.
   - Ablauf: `initialize`, `initialized`, `thread/start` (ephemer) und ein `turn/start`.
   - Bis einschließlich `thread/start` ist ein Fehler ein sicherer Fehlstart. Danach ist der Ausgang offen, bis `turn/completed` eintrifft.
   - Jede Anfrage hat eine wirksame Frist.
   - Nur eine ausdrückliche Ablehnung von `turn/start` beendet den Lauf sicher.
   - Ein unbekannter Endstatus, ein Prozessende oder ein Abbruch ohne Bestätigung lassen den Ausgang offen (`uncertain`).
   - Freigaben im M0:
     - Dateiänderungen nur für Autoren, nie mit zusätzlicher Schreibwurzel. Jeder Pfad der Änderung muss im Worktree und in den freigegebenen Pfaden liegen, außerhalb von `.git`, `.codex` und `.agents`. Das gilt für alle in `item/started` und `item/fileChange/patchUpdated` angekündigten Pfade.
       - Abgelehnt werden Pfade mit `..`-Teilen.
       - Abgelehnt werden Pfade, deren letzter Teil ein Symlink ist, auch ein ins Leere zeigender.
       - Der Elternordner wird mit Symlinks aufgelöst. Die Anfrage muss alle Pflichtfelder haben und zu diesem Thread und Turn gehören.
     - Befehle werden abgelehnt, weil Git und Tests über den Host laufen
     - Zusatzrechte werden mit leerer Menge beantwortet
     - alle anderen Serveranfragen mit einem JSON-RPC-Fehler
   - Werkzeugprozesse erben keine Umgebung (`shell_environment_policy.inherit="none"`).
   - SIWC übergibt das kurzlebige Token nur als `ACCESS_TOKEN` an diesen Prozess, mit den dokumentierten Provider-Einstellungen.
   - Abbruch: zuerst `turn/interrupt`, nach der Frist Prozessstopp.

4. **Vertragstests.**
   - Die Codex-Schemadateien sind mit `app-server generate-json-schema` aus dem installierten Binary erzeugt. Sie liegen in `Tests/ProvidersTests/Fixtures/codex-app-server-0.170.0`, zusammen mit dem SHA-256 des gesamten Schemas.
   - Jede Anfrage des Adapters und jede Nachricht des Fixture-Servers wird gegen diese Dateien geprüft.
   - Für Claude gibt es kein veröffentlichtes Schema. Die Claude-Fixtures sind synthetisch und als solche gekennzeichnet.

5. **Isolation der Anbieterprozesse.** Die Rolle `agentCLI` gibt dem CLI-Prozess:
   - Netzwerk und seinen eigenen Zustandsordner
   - Schreibzugriff auf den Worktree, wenn es ein Autor ist
   - keinen Zugriff auf KAIORX-Daten und Zugangsdaten-Ordner
   - Schreibschutz für die `.git`-Datei und für die eigenen Konfigurationsdateien des Anbieters (`RoleProfile.codexStateFiles` und `claudeStateFiles`: Konfiguration, Anweisungen, Regeln, Skills)
   - Zugriff auf den Login-Schlüsselbund nur für Claude Code, das dort seine Abo-Anmeldung speichert (`needsKeychain`)

## Offen bis Paket A

- Echte, redigierte Aufzeichnungen beider Protokolle ersetzen bzw. ergänzen die Fixtures.
- Die Felder von `claude auth status --json` und die Abrechnungsprüfung. Bis dahin meldet `probe` den Auth-Zustand `unknown`.
- Die Syntax und Wirkung der `--allowedTools`-Pfadregeln (neue Dateien, Symlinks, Git-Konfiguration).
- SIWC-Anmeldung, Token-Erneuerung, `account/rateLimits/read`.
- Ob Codex' eigene Sandbox innerhalb der KAIORX-Sandbox Befehle ausführen kann (verschachteltes `sandbox-exec`). Im M0 werden Befehle ohnehin abgelehnt.
- Erst ein bestandener Live-Lauf setzt eine Version in der Matrix auf `liveVerified`.
