# ADR 0010 · Testprofil-Register mit Tests-Knopf

**Status:** angenommen, 21. November 2026 · **Betrifft:** Stufe 0.6 (`Plan/paket-i.md`), `Plan/laufzeitvertrag.md` (Tabellen `policy` und `test_result`, `Verifier.run`, Ereignis `policy.decided`, Integrationsinvariante), `Plan/macos-und-git.md` Schritt 5, ADR 0004 (Belege), ADR 0005 §9, ADR 0007

## Kontext

`TestProfile` (`Workspace/TestRun.swift`) war reine API: `IntegrationService.runTests` nahm jedes beliebige Profil an, und das Gate zählte jeden grünen Test für den Kandidatencommit, gleich mit welchem Befehl. `PlanTaskDraft.testProfile` war nur ein Name, den das Gate bei sensiblen Aufgaben auf „nicht leer“ prüfte. Die App konnte keine Tests ausführen; Tests liefen nur aus Tests und `kaiorx-bench`. Der Plan verlangt eine „vorab bestätigte Projektkonfiguration“ (`macos-und-git.md` Schritt 5) und „explizit gewählte Testprofile“ (Entscheidung 06); der Laufzeitvertrag legte das Testprofil bisher in `policy.settings_json`. I.5 braucht das Register als Nutzer.

## Entscheidungen

1. **Register je Projekt.** Neue Migration 9 `testProfiles` mit der Tabelle `test_profile`: `id`, `project_id`, `name` (eindeutig je Projekt, 1–80 Zeichen, gezählt in Unicode-Codepunkten wie `length(name)` in SQLite; die Prüfung in `TestProfileSpec.issues` zählt genauso, sodass ein zu langer Name mit Begründung abgelehnt wird und nie an der CHECK-Bedingung scheitert), `executable` (absolut), `arguments_json`, `working_directory` (relativ zum Worktree), `timeout_seconds` (1–21 600), `writes_worktree`, `test_input_prefixes_json`, `digest`, `created_at`, `updated_at`, `confirmed_digest?`, `confirmed_at?`, `confirmed_by?`. Bestehende Migrationen bleiben unverändert. Registerprofile haben keine eigenen Umgebungsvariablen (die Testumgebung bleibt die minimale aus ADR 0002) und die Standard-Ausgabegrenze von 4 MiB; das Feld `environment` von `TestProfile` bleibt nur für die untere API.

2. **Prüfsumme und Bestätigung.**
   - Die Prüfsumme ist SHA-256 über das kanonische JSON aller Felder samt Name, Art und Version (`kind: testProfile`, `version: 1`).
   - Die Bestätigung nennt die Prüfsumme, die das Blatt zeigte (`confirmTestProfile(id, digest:)`, Akteur `user`). Weicht die gespeicherte Prüfsumme ab oder passt der gespeicherte Inhalt nicht mehr zu ihr, wird verweigert; das Blatt muss neu gezeigt werden.
   - Jede inhaltliche Änderung (Vorschlag mit demselben Namen) löscht die Bestätigung; derselbe Inhalt behält sie. Eine Umbenennung legt ein neues, unbestätigtes Profil an.
   - Das Schema erzwingt, dass eine Bestätigung nur die gespeicherte Prüfsumme deckt (`CHECK (confirmed_digest IS NULL OR confirmed_digest = digest)`, die drei Bestätigungsfelder nur gemeinsam). Beim Lesen wird die Prüfsumme aus dem Inhalt neu berechnet; ein am Store vorbei geänderter Befehl gilt als unbestätigt.
   - Vorschlagen, Bestätigen und Entfernen schreiben je ein `policy.decided` mit Profil-ID, Aktion, Prüfsumme und (beim Bestätigen) Entscheider.

3. **Nur bestätigte Profile laufen.** `IntegrationService.runTests(_:profile: TestProfileID)` ersetzt die Variante mit freiem `TestProfile`. Sie verweigert vor jedem Start ein unbekanntes oder projektfremdes Profil, ein unbestätigtes und eines, das nicht das von der Planaufgabe genannte ist (`TestProfileError`); verweigert heißt: kein Testergebnis, der Kandidat bleibt in seinem Zustand. Das Ergebnis trägt die bestätigte Prüfsumme in `test_result.profile_digest`. `GitRunner.runTests` und `WorkspaceService.runTests` bleiben die untere Ebene ohne Register.

4. **Auflösung.** Nennt die Planaufgabe ein Profil, läuft nur dieses (Name über das Register aufgelöst); sonst das gewählte; sonst das einzige bestätigte Profil des Projekts; bei mehreren muss der Benutzer wählen. Planannahme und Planprüfung prüfen den Namen nicht gegen das Register: Das Profil darf später angelegt werden, das Gate hält bis dahin.

5. **Gate.** Ein grüner Test zählt nur, wenn seine Prüfsumme die eines jetzt bestätigten Profils ist, bei einer Planaufgabe mit Namen die dieses Profils. Neue Gate-Punkte: `testProfileNotConfirmed(name)` (genanntes Profil fehlt oder ist unbestätigt) und `noConfirmedTestProfile` (das Projekt hat keines). Ändern oder Entfernen eines Profils zieht seine Ergebnisse zurück; ein angenommener Kandidat fällt bei der nächsten Auswertung (spätestens bei Freigabe oder Veröffentlichung) nach `reviewing` zurück, seine Freigaben werden widerrufen. Ein erneut bestätigter neuer Inhalt belebt alte Ergebnisse nicht. Ein solcher Kandidat wird erneut getestet: `runTests` nimmt neben `built` auch einen Kandidaten in `reviewing` oder `accepted` an, aber nur solange kein Test eines jetzt bestätigten Profils für ihn zählt (Gate-Punkt `noPassingTest`); ein angenommener wird dafür zuerst ausgewertet und fällt nach `reviewing` zurück. Der erneute Lauf bleibt in `reviewing` (kein Wechsel nach `testing`, die Zustandsmaschine des Kandidaten bleibt unverändert), bindet an denselben Kandidatencommit und dieselben Regeln (nur bestätigte, bei Planaufgaben nur das genannte Profil). Grün wertet aus und kann den Kandidaten wieder annehmen; rot, abgestürzt oder veränderte Eingaben verwerfen ihn; Infrastrukturfehler und Zeitüberschreitung lassen ihn in `reviewing`. ADR 0005 §9 gilt weiter: Eine sensible Aufgabe braucht einen Profilnamen (`noTestProfileForSensitiveTask`), jetzt zusätzlich bestätigt.

6. **App.**
   - Blatt „Testprofile“ je Projekt (Werkzeugleiste, Menü „Testprofile …“ ⌥⌘T, Hinweis in der Kandidatenprüfung). Formular mit einem Argument und einem Testeingabe-Pfad je Zeile; nichts wird von einer Shell zerlegt. Die Liste zeigt den vollständigen Befehl, Arbeitsordner, Zeitlimit, Schreibrecht und den Status („Bestätigt“, „Nicht bestätigt“, „Geändert – erneut bestätigen“).
   - Bestätigen über eine Entscheidungsseite (`DecisionSheet.confirmTestProfile`): vollständiger Befehl, Arbeitsordner, Zeitlimit, Schreibrecht, Testeingaben, Isolation und Prüfsumme; Return wählt „Nicht bestätigen“. Ändert sich das Profil, während die Seite offen ist, schließt sie mit Hinweis.
   - Kandidatenprüfung: Abschnitt „Tests“ mit den letzten Ergebnissen für genau diesen Commit (Status als Text und Symbol, Profilname oder „nicht mehr im Register – zählt nicht“, Zusammenfassung, geänderte Testeingaben) und bei `built` – oder in `reviewing`/`accepted`, wenn eine Profiländerung den Test zurückgezogen hat – der Knopf „Tests ausführen“ (⇧⌘T). Er löst das Profil wie das Gate auf (`TestRunChoice`): Nennt die Planaufgabe ein Profil, zeigt er genau dieses oder den Grund, warum es nicht laufen kann (fehlt im Register, nicht bestätigt), und ist dann gesperrt; nur ohne genanntes Profil gilt das einzige bestätigte Profil, bei mehreren mit Auswahl. VoiceOver sagt das Ergebnis an. Alle Steuerelemente sind per Tastatur erreichbar und beschriftet; „Bestätigen …“, „Bearbeiten“ und „Entfernen“ nennen für VoiceOver den Profilnamen.

7. **UI-Test-Ausgangslage.** `UITestSeed.builtCandidate` legt einen Auftrag mit einer Aufgabe und einem gebauten Kandidaten an, ohne Anbieterlauf (aufgezeichnetes Autorenergebnis). Die App nutzt das nur mit `-KAIORXUITest` (nur Debug) und `KAIORX_UITEST_SEED=candidate`; die Workbench-Tests nutzen dieselbe Funktion.

8. **Sicherungen.** Eine Wiederherstellung widerruft Zustimmungen (ADR 0007), Testprofil-Bestätigungen aber nicht: Sie binden an den Inhalt und übertragen nichts an Anbieter.

## Änderung des Laufzeitvertrags

`Plan/` ist lokal und nicht versioniert; diese Änderungen sind dort nachzutragen:

- **Tabelle `policy`:** „Settings inkl. … Testprofil“ entfällt; Testprofile stehen nicht in `settings_json`, sondern im Register.
- **Neue Tabelle `test_profile`:** `id PK, project_id, name, executable, arguments_json, working_directory, timeout_seconds, writes_worktree, test_input_prefixes_json, digest, created_at, updated_at, confirmed_digest?, confirmed_at?, confirmed_by?`, UNIQUE(project_id,name). Eine Bestätigung deckt nur die gespeicherte Prüfsumme; jede Inhaltsänderung verlangt eine neue.
- **`test_result.profile_digest`:** die Prüfsumme des Registerprofils beim Lauf. Das Ergebnis zählt nur, solange ein bestätigtes Profil des Projekts diese Prüfsumme trägt.
- **`Verifier.run`:** Eingabe ist ein bestätigtes Registerprofil (ID). Ein vor dem Start verweigertes Profil ist kein Testergebnis, sondern ein Fehler des Aufrufs.
- **Ereignis `policy.decided`:** umfasst auch Testprofil-Aktionen (Profil-ID, Aktion, Prüfsumme, Entscheider).
- **Invariante:** „Integration erfordert separat grünes Testprofil …“ lautet „… grünen Test eines zum Prüfzeitpunkt bestätigten Testprofils (bei Planaufgaben des genannten) …“.

## Prüfung

- Migration auf einer v8-Datenbank (Daten bleiben, Sicherung `backup-v8-…`, Register leer und nutzbar).
- Bindung an die Prüfsumme: falsche Prüfsumme, geänderter Inhalt, Änderung am Store vorbei, Schema-CHECK.
- Unbestätigte, geänderte, projektfremde und unbekannte Profile laufen nicht.
- Gate: nur Ergebnisse jetzt bestätigter Profile; Ändern und Entfernen ziehen zurück; Planaufgabe mit Namen läuft nur mit diesem; nach Ändern und erneutem Bestätigen erreicht ein erneuter Test wieder `accepted` und die Veröffentlichung.
- Namenslänge in Codepunkten (kombinierende Zeichen, Emoji) ohne SQLite-Fehler.
- Workbench-Aktionen vom Vorschlag bis zum grünen und roten Lauf, Formular und Befehlszeile.
- XCUITest (`-KAIORXUITest`): Profil anlegen, Return bestätigt nicht, bestätigen, „Tests ausführen“ auf dem Kandidaten.

## Folgen

- Nichts startet Tests automatisch; der Scheduler bleibt unverändert. Tests laufen weiter unter der Test-Runner-Isolation (ADR 0002) und nur für vertrauenswürdige Projekte; fremde Repositories bleiben I.5.
- Die Migrationsnummer wird beim Landen vergeben (`Plan/paket-i.md`); landet ein anderes Vorhaben vorher eine Migration 9, bekommt diese die nächste freie Nummer bei unverändertem SQL.
