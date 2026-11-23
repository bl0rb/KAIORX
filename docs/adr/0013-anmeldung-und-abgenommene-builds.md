# ADR 0013 · Anmeldung aus der App und abgenommene Builds trotz Selbst-Update

**Status:** vorgeschlagen, 23. November 2026, auf Wunsch des Kontoinhabers während des Gesamtdurchlaufs 0.7; Abnahme durch den Kontoinhaber offen · **Betrifft:** ADR 0003 §1, ADR 0008 §2 und §6, ADR 0009 §6, ADR 0012 D7, `CLAUDE.md` („Do not run the real `claude`/`codex` binaries for inference or log-in from code or tests“), `docs/e2e-durchlauf.md`

## Kontext

Im Gesamtdurchlauf 0.7 wartete die erste Aufgabe mit „Claude ist in KAIORX nicht angemeldet“. Drei Lücken wurden sichtbar:

- **Anmeldung nur von Hand.** Das Onboarding bot nur „Befehl kopieren“. Ob die Anmeldung wirkt, zeigte erst der nächste automatische Start. Ein negatives Abo-Urteil hielt das Gate bis zu fünf Minuten fest (ADR 0009 §6), und „Erneut prüfen“ (ADR 0012 D7) prüfte die Anmeldung nicht.
- **Selbst-Update.** Beim Anmelden im Terminal hat sich Claude Code von 2.1.329 auf 2.1.330 aktualisiert. Das Gate sperrte danach jede Automatik („Version 2.1.330 ist nicht in der Kompatibilitätsliste“), obwohl der abgenommene Build unverändert unter `~/.local/share/claude/versions/2.1.329` lag.
- **Darstellung.** Die Onboarding-Liste scrollte nicht: Hinweise wurden abgeschnitten, die Knöpfe lagen außerhalb des Fensters.

## Entscheidungen

1. **„Im Terminal anmelden …“.** Jede Anmeldezeile des Onboardings und von „Einrichtung prüfen …“ hat diesen Knopf. Er öffnet ein Blatt mit einem Terminal (`ProcessHost.launchTerminal`), in dem die CLI selbst läuft: Claude Code interaktiv (anmelden, dann `/exit`), Codex als `codex login`.
   - Gestartet wird nur auf den Klick des Benutzers; nur der Benutzer tippt. KAIORX schickt keine Eingabe, liest keine Anmeldedaten und ruft kein Modell auf.
   - Der Arbeitsordner ist KAIORX' eigener Konfigurationsordner (`claude-config` bzw. `codex-home`, Rechte 0700). Die Umgebung ist fest: `PATH` (Systemordner), `HOME`, `USER`, `LOGNAME`, `LANG`, `TERM`, `COLORTERM`, `TERM_PROGRAM=KAIORX` und der Ordner des Anbieters (`CLAUDE_CONFIG_DIR` bzw. `CODEX_HOME`), bei Claude zusätzlich `DISABLE_AUTOUPDATER=1`. Kein Shell, keine Schlüssel, kein SSH-Agent.
   - Es läuft der Build, den auch die Läufe nutzen (Punkt 3). Die Anmeldeseite öffnet die CLI selbst im Browser; Links und Zwischenablage, die das Terminal anfragt, landen in einer eigenen Liste des Blatts und öffnen sich erst nach Bestätigung, wie im Benutzerterminal (ADR 0007).
   - Aus „Einrichtung prüfen …“ geöffnet, kehrt das Blatt nach „Fertig“ dorthin zurück, damit das Ergebnis sichtbar ist.
   - „Fertig“ beendet das Programm und prüft die Anmeldung (Punkt 2). Return gehört dem Terminal und schließt das Blatt nicht.
   - „Befehl kopieren“ bleibt für das eigene Terminal; der Befehl setzt bei Claude ebenfalls `DISABLE_AUTOUPDATER=1`.

2. **„Anmeldung prüfen“.** Der Knopf liest das Abo-Urteil sofort (`AutomationGate.checkSubscription`): dieselbe Produktvorprüfung wie vor automatischen Starts (ADR 0008 §2, ADR 0009 §6: `claude auth status --json` bzw. `account/read`, Isolation und Umgebung eines Prüfers, keine Inferenz), am Zwischenspeicher vorbei. Das Ergebnis ersetzt das gespeicherte Urteil; eine Aufgabe, die auf die Anmeldung wartet, startet beim nächsten Takt.
   - Vorher laufen dieselben billigeren Stufen wie vor einem automatischen Start (Kanal, abgenommener Build, wirksame Isolation): Ein nicht abgenommener Build wird nie gefragt. Die Zeile nennt dann die Stufe („Nicht geprüft: Die installierte Version Claude 2.1.330 ist nicht live abgenommen.“).
   - Läuft gerade eine Abfrage, die vor dem Klick begann (sie kann vor der Anmeldung liegen), wartet die Prüfung sie ab und fragt neu; andere Aufrufer teilen sich eine laufende Abfrage wie bisher. Wird während einer Prüfung erneut geprüft (etwa „Fertig“ nach der Anmeldung), folgt eine weitere Prüfung.
   - Die Zeile zeigt „Angemeldet mit Abo (Plan).“, „Nicht angemeldet.“, „Rechnet nicht nur über das Abo ab (…).“, „Nicht eindeutig: …“ oder „Noch nicht geprüft.“.
   - Wo das Gate nichts liest (vertriebener Kanal ohne Anbieterfreigabe, ADR 0009 §3), zeigt die Zeile „In dieser Ausgabe startet KAIORX keine Anbieter automatisch; die Anmeldung prüft der erste Lauf.“ und liest nichts.

3. **Abgenommene Builds trotz Selbst-Update.** Claude Code installiert jede Version als `…/claude/versions/<Version>` und verlinkt `claude` auf die neueste. Ist der verlinkte Build nicht live abgenommen, nutzt die App den neuesten aufbewahrten Build, dessen Version und SHA-256 ein `liveVerified`-Eintrag nennt (`VerifiedInstall.prefer`, `Onboarding.locate(…, preferVerified: true)`). Gehasht werden nur Dateien, die wie eine abgenommene Version heißen.
   - Das gilt für Adapter, Onboarding, Profilabgleich und Anmeldeterminal der App. Das Onboarding nennt den verlinkten Build („claude zeigt auf einen anderen Build (2.1.330); KAIORX nutzt den abgenommenen“).
   - **Nicht** für das Abnahme-Kit: `kaiorx-acceptance` prüft genau den verlinkten Build, sonst ließe sich eine neue Version nie abnehmen.
   - Die Sicherheit hängt nicht daran: Gate und `AdapterPolicy` prüfen weiter jeden Start gegen Version **und** Build. Fehlt ein abgenommener Build, bleibt der verlinkte gewählt und gesperrt.
   - Codex (npm) hält keine alten Versionen; dort ändert sich nichts.

4. **Kein Selbst-Update aus KAIORX.** Jeder Claude-Aufruf von KAIORX setzt `DISABLE_AUTOUPDATER=1`: Läufe, Abo-Vorprüfung, Versionsabfrage und Anmeldeterminal. Eine neue Version kommt nur, wenn der Benutzer sie selbst installiert; abgenommen wird sie wie bisher nur durch die Live-Abnahme des Kontoinhabers.

5. **Darstellung.** Onboarding und „Einrichtung prüfen …“ scrollen; Hinweise brechen um. Status und Text einer Zeile sind ein Element für VoiceOver, die Knöpfe bleiben eigene Steuerelemente mit dem Namen des Anbieters.

6. **UI-Tests mit Test-CLIs.** Mit `-KAIORXUITest` und `KAIORX_UITEST_CLIS=1` legt die App (nur Debug) zwei Shellskripte `claude` und `codex` im Testordner an. Sie antworten auf `--version` wie die abgenommenen Builds; ihre „Anmeldung“ legt eine Markierung im Konfigurationsordner an, bei Claude nur mit gesetztem `DISABLE_AUTOUPDATER=1`. Die Prüfung liest bei Claude die Ausgabe über den Parser des Produkts (`ClaudeAuthStatus`). Kein UI-Test startet ein echtes `claude` oder `codex`.

## Abweichungen von früheren Entscheidungen

- **`CLAUDE.md`:** „Do not run the real `claude`/`codex` binaries for inference or log-in from code or tests“ gilt weiter für automatische Abläufe und Tests. Das Anmeldeterminal startet die echte CLI nur auf den Klick des Benutzers, interaktiv, und die Anmeldung macht der Benutzer selbst. Vorschlag für `CLAUDE.md`, den der Kontoinhaber selbst einträgt: „The only exception is the user-started login terminal (ADR 0013): the real CLI, interactive, after the user's click; tests use fake CLIs.“
- **ADR 0009 §6:** Ein Abo-Urteil gilt fünf Minuten, außer der Benutzer prüft neu.
- **ADR 0003 §1:** Die App wählt unter installierten Claude-Builds den abgenommenen; welche Builds laufen dürfen, entscheidet weiter allein die Matrix.

## Prüfung

- `VerifiedInstallTests`: Wahl des neuesten abgenommenen aufbewahrten Builds, abgenommener verlinkter Build bleibt, fremder Build derselben Version wird nie gewählt, nur Claudes Versionsordner, nur passend benannte Dateien werden gehasht.
- `LoginCheckGateTests`: „Anmeldung prüfen“ liest am Zwischenspeicher vorbei und hebt eine veraltete Sperre auf; ein nicht abgenommener Build oder unwirksame Isolation werden nicht gefragt; eine vor dem Klick begonnene Abfrage ist nicht die Antwort; vertriebener Kanal ohne Freigabe liest nichts.
- `ProviderLoginTests`: Umgebung und Befehl des Anmeldeterminals, Zeilen für jedes Urteil, Hinweis auf einen anderen verlinkten Build, Prüfung über die Konfiguration oder das Gate.
- Adaptertest: Claude-Läufe setzen `DISABLE_AUTOUPDATER=1`.
- XCUITest `testTheLoginButtonsLogInAndCheckWithoutARestart` mit Test-CLIs.

## Folgen

- Neu: `VerifiedInstall` mit Prüfsummen-Zwischenspeicher je Datei (Providers), `AutomationGate.checkSubscription`, `SubscriptionCheck` (Orchestration), `ProviderLogin`, `LoginCheck`, `ProbeResults.linked` und `.logins`, `OnboardingItem.login`, `AppConfiguration.loginCheck` (Workbench), in der App `LoginTerminalSheet`, `LoginButtons`, `UITestCLIs`.
- Der Kontoinhaber muss nach einem Selbst-Update von Claude Code nichts zurückstellen, solange der abgenommene Build aufbewahrt ist; Claude Code löscht alte Versionen irgendwann selbst. Dann hilft nur eine neue Live-Abnahme.
