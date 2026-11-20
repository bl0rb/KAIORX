# ADR 0008 · Live-Abnahme durch den Kontoinhaber

**Status:** angenommen, 20. November 2026 · **Betrifft:** Paket A, `Plan/anbieter.md` §5, `Plan/ARCHITEKTURPLAN.md` (Paket A, Qualitätsnachweis), ADR 0003, ADR 0006, ADR 0007

## Kontext

Automatische Läufe sind gesperrt, bis eine Version `liveVerified` ist (ADR 0003). Das darf nur ein bestandener Live-Lauf des Kontoinhabers belegen (`CLAUDE.md`). Claude, Tests und CI starten die echten CLIs nie für Inferenz oder Anmeldung. Paket A liefert deshalb ein Werkzeug, das ausschließlich der Kontoinhaber selbst startet, und einen prüfbaren Weg vom Bericht zur Matrix. Installiert sind Claude Code 2.1.328 (`~/.local/bin/claude`) und codex-cli 0.170.0 über nvm: ein Node-Starter, der ein natives Programm aus dem npm-Paket startet.

## Entscheidungen

1. **Eigenes Programm `kaiorx-acceptance`.** Ein eigenes Package-Target `Acceptance` und ein ausführbares Programm, getrennt von App und `kaiorx-dev`.
   - Es verweigert den Start ohne interaktives Terminal, in CI- und Testumgebungen, bei Variablen von Agenten-CLIs und wenn ein Elternprozess `claude`, `codex`, `node`, die Claude-App oder KAIORX ist. Der Kontoinhaber startet es in Terminal.app.
   - Je Sitzung die Besitzerbestätigung des Macs (LocalAuthentication).
   - Vor jedem Schritt mit Modellaufruf eine getippte Phrase aus Schritt, Anbieter, Version und SHA-Präfix; die Zustimmung gilt nie für einen anderen Schritt, ein anderes Programm oder einen fortgesetzten Lauf.
   - Kein `--yes`, keine Umgebungsvariable zum Überspringen. Die eigentliche Garantie bleibt der Bericht und der eigene Commit des Kontoinhabers.

2. **Was gestartet wird.** Erlaubt sind `--version`, `--help`, die Schemaerzeugung von Codex mit leerem `CODEX_HOME` (wie bisher) und neu, nur im Kit und in der späteren Produktvorprüfung: `claude auth status --json` und bei Codex `account/read` und `account/rateLimits/read`. Beides liest den Anmeldestand, ist weder Inferenz noch Anmeldung und läuft mit derselben Umgebung und Isolation wie ein Versuch. Anmelden tut sich der Kontoinhaber selbst mit dem angezeigten Befehl in KAIORXs eigenen Konfigurationsordnern (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Das Kit liest keine Zugangsdaten, keine Dateien in diesen Ordnern und nicht den Schlüsselbund.

3. **Natives Programm.** `NativeBinary.resolve` folgt dem npm-Starter von Codex zum mitgelieferten Mach-O-Programm (gleiche Version); die Adapter starten es ohne Node. Das Onboarding sucht auch unter `~/.nvm/versions/node/*/bin`.

4. **Freigabe-Gate.** `AdapterPolicy` hat drei Formen: das Produkt (nur `liveVerified`, und wenn die Matrix Programm-SHAs nennt, nur diese), `ownerAcceptance(binarySHA256:)` (eine Version aus der Matrix und genau dieses Programm, immer isoliert) und `fixtureTesting` (nur Tests). Die freie öffentliche Initialisierung entfällt. Ein Quelltext-Test hält `ownerAcceptance` im Kit und `fixtureTesting` in den Tests.

5. **Schritte** (billig zuerst, die Anmeldung störend zuletzt; Pflicht = für „bestanden“ nötig):
   - Pflicht: Programm identifizieren (Mach-O, SHA, Signatur, alle Startoptionen in `--help` bzw. unverändertes Protokollschema, wirksame OS-Isolation); Anmeldung und Plan (reines Abo, vom Kontoinhaber als eigenes Konto bestätigt); Abrechnung (Zusatz-Credits aus, „vom Benutzer bestätigt“); lesender Auftrag auf synthetischen Daten (Kennwort genannt, Ordner unverändert); Isolation (deterministische Proben unter der Agenten-Isolation ohne Modell, dann ein Auftrag, der Nachbar-Repository, Benutzerordner, Link nach außen und eine Umgebungsvariable ausgeben soll); schreibender Auftrag (nur der freigegebene Pfad, keine Git-Metadaten, kein fremder Hook); Abbruch (bestätigt oder als ungeklärt erfasst, kein Prozess übrig); Widerruf (der Kontoinhaber meldet ab, kein Abo erkennbar, Start vor jedem Turn verweigert).
   - Optional, sonst als Einschränkung im Bericht: lesender Auftrag mit verborgenem Benutzerordner, beobachtetes Kontingent (Erschöpfung wird nie herbeigeführt), zweites Konto erkannt, zwei Anbieter gleichzeitig.
   - Synthetische Daten: zwei Wegwerf-Repositories, ein Link nach außen, feindliche Projektdateien (`AGENTS.md`, `.claude/settings.json` mit Hook, `.codex/config.toml`), Kanarienwerte im Kit-Umfeld und eine Kanariendatei im Benutzerordner, die am Ende entfernt wird.

6. **Benutzerordner.** Die Rolle `agentCLI` verbirgt bisher nur die Zugangsdaten-Ordner; der übrige Benutzerordner ist lesbar. Das Kit misst das und wertet es als nicht bestandene Isolation. Zusätzlich misst es einen Lauf mit verborgenem Benutzerordner (`RoleProfile.confinement(hideHome:homeExceptions:)`, Ausnahmen: Installationsordner des Programms, bei Claude der Schlüsselbund). Das Produkt übernimmt das Verbergen erst, wenn dieser Lauf belegt, dass die CLIs damit arbeiten. In einer gewöhnlichen Arbeitskopie ist `.git` jetzt als ganzer Ordner schreibgeschützt.

7. **Aufzeichnungen.** Die Protokollzeilen eines Schritts bleiben im Speicher, werden redigiert (Schlüssel wie `session_id`, `email`, `account` werden zu stabilen Platzhaltern; JWT, Schlüssel, E-Mail, UUID, lange Hex-Werte und alle bekannten Pfade werden ersetzt) und nur geschrieben, wenn danach weder ein Geheimnismuster noch ein privater Wert (Benutzername, Rechnername, Benutzerordner, Kanarien) vorkommt. Echte Aufzeichnungen heißen `<anbieter>-<version>-<schritt>.jsonl`; die bisherigen Claude-Fixtures bleiben als synthetisch gekennzeichnet.

8. **Bericht und Matrix.** Alles liegt unter `~/Library/Application Support/KAIORX/acceptance/<lauf>`; das Kit schreibt nie ins Repository und führt kein Git mit Schreibwirkung aus.
   - `report.json` ist die Quelle, `report.md` wird daraus erzeugt (Version, Datum, macOS, Modus, Ergebnis, Einschränkungen zuerst).
   - Bei bestandenem Lauf entsteht `matrix.patch`: Status `liveVerified`, die Programm-SHA (`builds`) und `LiveEvidence` (Berichtspfad unter `docs/live-acceptance/<lauf>/`, SHA-256 des Berichts, Modus).
   - `export` kopiert Bericht, Aufzeichnungen und Patch; der Kontoinhaber prüft, wendet an und committet.
   - Ein Test prüft bei jedem Build jeden `liveVerified`-Eintrag gegen seinen Bericht (vorhanden, unverändert, bestanden, gleicher Anbieter, Version, Programm und Modus, alle Aufzeichnungen vorhanden).

9. **Codex-Anmeldeweg.** Abgenommen wird `cliManaged` (Anmeldung des Originalprogramms in KAIORXs `CODEX_HOME`). SIWC hat noch keinen Client und bleibt offline.

## Prüfrunde

Eine unabhängige Prüfung fand 35 Befunde, 28 bestätigt (nach Entdoppeln 16), alle behoben; dazu drei billige Härtungen aus widerlegten Befunden.

- **Zustimmung:** Der Widerruf-Schritt startet keinen Lauf, solange noch ein Abo antwortet. Der Parallel-Schritt prüft vorher erneut Anmeldung und dasselbe Konto. Das zweite Konto zählt nur, wenn es angemeldet ist und sich unterscheidet.
- **Abo-Urteil:** API-Schlüssel-Hinweise jeder Form (Text, Schalter, Zahl, Liste, auch in Listenobjekten) gelten als andere Abrechnung; ein fehlgeschlagener Statusbefehl bestätigt nie; bei Codex zählen nur die Abo-Pläne `go`, `plus`, `pro`, `prolite`, `promax`, `team`, `business`, `edu`, nutzungsbasierte und unbekannte Pläne sind unklar.
- **Schritte:** Der Abbruch besteht nur bestätigt oder ungeklärt, nicht bei normalem Ende. Der schreibende Auftrag prüft den ganzen übrigen Arbeitsordner; der Marker des fremden Hooks liegt im Arbeitsordner, wo er auch bei wirksamer Isolation entstehen kann. Die Identifikation prüft die Signatur (`codesign --verify --strict`). Kontingent zählt nur bei echten Limitsignalen, nicht bei Tokenzahlen. „Gleichzeitig“ misst die Zeit ab dem `started`-Ereignis. Ein in Teilstücken gesendeter Kanarienwert wird erkannt.
- **Redaktion:** Anzeigenamen (`*Name`, `*_name`) und alles innerhalb identifizierender Objekte werden ersetzt, Protokollvokabular (Typ, Plan, Rolle) bleibt. Private Literale werden nur als ganzes Wort gesucht, damit ein kurzer Benutzername keine Aufzeichnung verwirft. Ein verworfener Mitschnitt steht als Hinweis im Bericht.
- **Pfade:** Der Benutzerordner wird ohne abschließenden Schrägstrich geführt; sonst blieben die Ausnahmen beim verborgenen Benutzerordner leer.
- **Belegprüfung:** Ein Eintrag muss genau das Programm des Berichts nennen, und alle Pflichtschritte nach dieser Version des Kits müssen bestanden sein (nicht nach den Angaben im Bericht). Der Quelltext-Test umfasst auch `App/`.

## Erster Live-Lauf (20. November 2026)

Der Kontoinhaber hat den ersten Lauf (`20261120-1023-2a9f`) ausgeführt; kein Anbieter hat bestanden. Ergebnisse:

- **Claude:** Das Programm hatte sich während der Vorbereitung auf 2.1.329 aktualisiert; das Kit lehnte die nicht gelistete Version ab, wie vorgesehen. Die Anmeldung meldete `loggedIn: false`: Sie war mit dem alten Ordnerpfad mit doppeltem Schrägstrich erfolgt, und Claude bindet die Anmeldung an den genauen Pfad. 2.1.329 steht jetzt `offlineVerified` in der Matrix (alle 15 Startoptionen in `--help`). Die echten Felder von `claude auth status --json` sind bekannt: `loggedIn`, `authMethod`, `apiProvider`, `loginExpiresAt`, `configDirectory`.
- **Codex:** Identität (gültige Signatur von OpenAI, Schema unverändert), Anmeldung (Plus), Schreiben, Abbruch und Kontingentsignale bestanden. Isolation scheiterte nur am lesbaren Benutzerordner. Der lesende Auftrag fand das Kennwort nicht: **Codex liest Dateien nur über Befehle** (`/bin/zsh -lc 'cat FACTS.md'`), und KAIORX lehnte jeden Befehl ab. Der Lauf mit verborgenem Benutzerordner endete mit einem Protokollfehler (die Ursache wird künftig redigiert mitgeschrieben).
- **Verschachtelte Sandbox (offener Punkt aus ADR 0003):** Codex' eigene Sandbox arbeitet innerhalb von KAIORXs `sandbox-exec` nicht; Codex fragt dann „retry without sandbox?“. Angenommen wird das nur, wenn die Freigaberegeln erfüllt sind; die OS-Isolation von KAIORX bleibt in jedem Fall wirksam.

Entscheidung des Kontoinhabers daraus: **Codex darf lesende Befehle ausführen.** Angenommen wird ein Befehl nur, wenn Codex jede Aktion als `read`, `listFiles` oder `search` einstuft, jeder genannte Pfad im Arbeitsordner liegt (nicht in `.git`, `.codex`, `.agents`, kein Symlink, kein `..`), der Arbeitsordner der des Versuchs ist, kein Netzwerk verlangt wird und der Befehl keine Shell-Operatoren enthält (`;`, `|`, `&`, `>`, `<`, `$`, Backtick, Backslash, Zeilenumbruch). Alles andere bleibt abgelehnt; Schreiben nur über geprüfte Dateiänderungen. Reviewer-Läufe sind auf OS-Ebene ohnehin schreibgeschützt.

Weitere Korrekturen: Der Bericht führt bestandene Schritte nicht mehr als Einschränkung. Die Redaktion leert nur noch Personen-, Konto- und Organisationsobjekte vollständig, in Protokollobjekten (`item`, `thread`) nur die Kennungen. Die Ordner der Anmeldung haben keinen doppelten Schrägstrich mehr, und der Preflight legt sie an.

## Nicht in A

SIWC-Anmeldung und Token-Erneuerung, natürlicher Ablauf einer Anmeldung (der Widerruf ist der Stellvertreter), absichtlich erschöpftes Kontingent, verschachtelte Codex-Sandbox, Installation verwalteter Hooks, gespeicherte erwartete Kontoidentität im Produkt (braucht eine Migration).

## Folgen

- Neue Targets `Acceptance`, `kaiorx-acceptance`, `AcceptanceTests`; drei Codex-Kontoschemas in den Fixtures (Digest unverändert).
- Bis zum ersten bestandenen und committeten Bericht bleiben beide Versionen `offlineVerified`. Mit dem heutigen Stand des Benutzerordners wird der Isolationsschritt nicht bestehen; der Bericht nennt das als Einschränkung, und die Automatik bleibt gesperrt, bis das Verbergen übernommen ist.
