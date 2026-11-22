# ADR 0012 · Geprüfte Modellprofile aus der Live-Abnahme

**Status:** vorgeschlagen, 22. November 2026; Abnahme durch den Kontoinhaber offen (Standardwerte D1 bis D8 unten) · **Betrifft:** ADR 0005 §8, ADR 0008 §8, ADR 0003, ADR 0009, `CLAUDE.md`, `Plan/laufzeitvertrag.md` (`model_profile`)

## Kontext

Der Scheduler reserviert einen Autor nur mit einem nutzbaren Modellprofil (`verified_at` gesetzt, kein `disabled_reason`; `ModelProfile.isUsable`). Das Review-Blatt bietet einen Prüfer nur mit einem Prüfer-Profil des anderen Anbieters an (`ReviewerChoice.profile`). ADR 0005 §8 sagt: „`verified_at` setzt außerhalb von Tests nur Paket A.“ Paket A (ADR 0008) schrieb aber nur Bericht und Matrix, nie Profile. Außerhalb der UI-Tests legte deshalb kein Codepfad Profile für Claude und Codex an. Auf einer echten Datenbank wartete jede Aufgabe mit „Kein passendes Modellprofil“, und das Review-Blatt bot keinen Prüfer an. Das blockierte den Gesamtdurchlauf (Stufe 0.7, `docs/e2e-durchlauf.md`).

Der committete Bericht `docs/live-acceptance/20261120-1429-a265/report.json` hält je Anbieter fest, welches Modell live lief: Claude 2.1.329 (`claudeSubscription`) mit `sonnet`, Codex 0.170.0 (`codexCliManaged`) mit `gpt-6.2-sol`. Beide Matrixeinträge sind aus diesem Bericht `liveVerified` und durch einen Evidenztest an ihn gebunden.

Feststellungen, die den Entwurf bestimmen:

- `model_profile` (Migration v4) hat außer `id` keinen eindeutigen Schlüssel. Zeilen lassen sich nie löschen, weil `attempt.model_profile_id` auf sie verweist.
- Der Scheduler sucht erst das Profil, dann prüft er das Gate (`Scheduler.swift`). Fehlt das Profil, wartet die Aufgabe mit `profileMissing`, und der genaue Grund des Gates („Version x nicht live geprüft“) erscheint nie.
- Den installierten Build erzwingen schon heute Gate und `AdapterPolicy` bei jedem Start, unabhängig von Profilen (ADR 0009).
- Das Kit setzt kein Effort (`Runner.spec`), und der Bericht enthält keinen Tokenverbrauch.

## Entscheidungen

1. **Eine Quelle: `VerifiedModelProfiles`** (`Packages/KAIORXKit/Sources/Providers/VerifiedModelProfiles.swift`), neben der Kompatibilitätsmatrix. Ein Eintrag (`VerifiedModelEntry`) nennt Anbieter und Version (bindet an den Matrixeintrag und über ihn an dessen Builds), das Modell genau wie im Bericht, die Rollen, die Stufe, Effort (nil = wie abgenommen), typische Tokens (nil, solange Berichte keinen Verbrauch festhalten), `verifiedOn` (das Datum des Berichts, UTC) und den Beleg (`LiveEvidence`: Berichtspfad, SHA-256 des Berichts, Modus).
   - Es gibt keine zweite SHA-Liste: Der Build kommt aus dem Matrixeintrag.
   - **Profil-IDs sind stabil:** eine namensbasierte UUID (Version-5-Layout) aus SHA-256 über `kaiorx.verifiedProfile|anbieter|version|modell|rolle|stufe`. Eine neue CLI-Version bekommt neue Zeilen; alte Versuche behalten ihr Profil.
   - `verified_at` ist `verifiedOn` um 00:00 UTC in Millisekunden (a265: `1795132800000`).

2. **Evidenztest.** `EvidenceCheck.profileProblems` prüft jeden Eintrag bei jedem Build, wie `everyMatrixEntryHasConsistentEvidence` die Matrix:
   - Der Bericht liegt im Repository, ist unverändert (SHA-256) und lesbar.
   - Anbieter und Version haben darin bestanden, mit demselben Modus und demselben Modell.
   - Es gibt einen Matrixeintrag für Anbieter und Version mit Status `liveVerified`, und seine `builds` enthalten den Build des Berichts.
   - Für jede Rolle hat der Schritt bestanden, der sie ausübt (`StepID.exercising`).
   - `verifiedOn` ist das Datum des Berichts; die Rollen sind nicht leer und nicht doppelt.
   - Katalogregeln im Test: höchstens ein Eintrag je (Anbieter, Version, Rolle, Stufe), und jeder `liveVerified`-Matrixeintrag hat mindestens einen Katalogeintrag. Ein Eintrag ohne passenden Beleg lässt den Test scheitern.

3. **Rollen aus den Schritten (D2).** Der lesende Schritt läuft als Prüfer (`StepID.read.exercisedRole == .reviewer`), der schreibende als Autor. `Runner` nimmt die Rolle dieser Läufe aus `StepID.exercisedRole`, damit die Zuordnung per Konstruktion gilt. Beide Schritte sind Pflicht; ein bestandener Bericht deckt also beide Rollen ab.
   - Der lesende Lauf nutzt denselben Prüferweg wie das Produkt: Claude bekommt als Prüfer nur Lesewerkzeuge, Codex erhält für Nicht-Autoren keine Schreibfreigaben, und die Isolation (`writesWorktree: role == .author`, `RoleProfile.agentCLIConfinement`) ist in Kit und App gleich. Das Modell erreicht die CLI auf demselben Weg.
   - **Offene Lücke:** Der Review-Prompt des Produkts (Diff plus `ReviewReport.instructions`) und das Auslesen des Berichts liefen noch nie live, nur offline. Stufe 0.7 ist ihr erster Live-Lauf. Der Review-Worktree des Produkts ist zusätzlich auf der Platte schreibgeschützt, also strenger als der Lauf im Kit.

4. **Stufe, Tokens, Effort sind Produkteinstellungen, keine Belege.** Der Test prüft die Stufe nicht und verlangt Effort und typische Tokens als nil, bis Berichte sie festhalten.
   - **D3, Stufe `standard`** für beide Modelle. Aufgaben `fast` und `standard` laufen, der Versuch zählt als `standard`. Eine Eskalation nach `intensive` und geplante `intensive`-Aufgaben warten mit „Kein passendes Modellprofil“, bis ein stärkeres Profil abgenommen ist. Prüfer arbeiten auf jeder Stufe.
   - **D4, typische Tokens nil.** Der Scheduler reserviert dann 50.000 Tokens und markiert die Größe als unsicher; für das Review wird nichts reserviert. Die Codex-Aufzeichnung des Autorenschritts zeigt rund 65.000 Tokens für einen trivialen, synthetischen Auftrag, meist aus dem Cache; das ist nicht repräsentativ.
   - **D6, Effort und Kontextgrenze nil**, wie abgenommen.

5. **Registrierung in der App (`ModelProfileSync`).** `verified_at` für Claude und Codex setzt außerhalb von Tests nur `ModelProfileSync` aus `VerifiedModelProfiles`.
   - `Store.syncCatalogModelProfiles(_:managed:)` gleicht in einer Transaktion ab und löscht nie: fehlende Zeilen einfügen; bei vorhandenen `verified_at`, `typical_tokens`, `effort`, `context_limit` nachführen. `disabled_reason` setzt oder löscht der Abgleich nur, wo es leer ist oder mit `catalog:` beginnt; jeder andere Grund (eine spätere Sperre durch den Benutzer) bleibt. Jede andere Zeile von Claude oder Codex bekommt `catalog:removed`. Zeilen von `fake` bleiben unberührt. Keine Migration.
   - **Aktive Version je Anbieter:** die installierte, wenn genau dieser Build live abgenommen ist; sonst (nicht installiert, nicht erkannt, nicht gelistet, nicht live, anderer Build, oder im Kanal ohne Automatik nicht gelesen) die neueste Katalogversion mit `liveVerified`-Matrixeintrag (nach `verifiedOn`, dann Katalogreihenfolge). Profile anderer Versionen bekommen `catalog:otherVersion <version>`, solche ohne `liveVerified`-Eintrag `catalog:versionNotLiveVerified`.
   - **D5:** Ist der installierte Build nicht abgenommen, bleiben die Profile der neuesten abgenommenen Version nutzbar. So zeigt die Aufgabe den genauen Grund des Gates („Die installierte Version Claude 2.1.330 ist nicht live abgenommen“) statt „Kein passendes Modellprofil“. Die Sicherheit hängt nicht daran: Gate und `AdapterPolicy` verweigern jeden Start eines nicht abgenommenen Builds.
   - **Konfiguration:** `AppConfiguration.profileRegistration`, Standard `.none` (Unit-Tests, UI-Tests und Bench behalten ihre Attrappen). `AppConfiguration.standard` setzt `.verifiedCatalog(installed: nil)`. Ohne eigene Quelle fragt die App ihr `AutomationGate` (`installedIdentity`): Es nutzt den Versionsabgleich, den der Adapter für seine Starts zwischenspeichert, und liest im vertriebenen Kanal ohne Freigabe nichts über die Installation (ADR 0009 §3).
   - **Start:** `AppBootstrap` gleicht direkt nach `gate.prepare` ab, bevor Scheduler und Kette entstehen. Ein Fehler ist nicht fatal; er steht in `AppServices.profileSync`, und die App startet. Zweimal ausgeführt gibt es dasselbe Ergebnis.
   - **D7:** Abgeglichen wird nur beim Start der App. Nach einem CLI-Update startet der Kontoinhaber die App neu.

6. **Künftige Läufe schlagen die Einträge vor (D8).** `ProfileProposal.propose` ist eine reine Textfunktion wie `MatrixProposal`. Sie fügt je bestandenem Anbieter einen Eintrag über der Markierung `// kaiorx-acceptance: new entries above this line` ein oder ersetzt den Eintrag derselben Version (die gewählte Stufe bleibt dabei). Die Rollen kommen aus `StepID.exercising`, die Stufe ist `standard` mit einem Kommentar, dass der Kontoinhaber sie im Patch ändern darf; Effort und Tokens sind nil. `writeReport` hängt diesen Vorschlag als zweite Datei an dasselbe `matrix.patch`; `export` und `git apply` bleiben gleich.

7. **Regel für Änderungen.** Ein Katalogeintrag darf nur hinzukommen oder sich ändern, wenn `EvidenceCheck.profileProblems` ihn gegen einen committeten Bericht des Kontoinhabers belegt, normalerweise über das `matrix.patch` des Kits. **D1:** Die beiden Einträge aus Lauf a265 sind ein einmaliger Nachtrag aus dem committeten Bericht (das Kit konnte damals noch keine Profile vorschlagen), geprüft durch denselben Test; ein Test zeigt, dass das Kit für diesen Bericht genau diese Einträge vorschlagen würde. Andere Handänderungen gibt es nicht; nur die Stufe darf der Kontoinhaber wählen.

## Entscheidungen für den Kontoinhaber (Standard zuerst, umgesetzt)

- **D1** a265 jetzt aus dem committeten Bericht nachtragen, geprüft durch den Evidenztest. Alternative: neuer Lauf des Kits.
- **D2** Die Prüferrolle gilt durch den lesenden Schritt als abgedeckt (gleicher Adapterweg, gleiche Isolation), mit der benannten Lücke bei Review-Prompt und Berichtsauswertung.
- **D3** Stufe `standard` für beide Modelle. Alternative: `intensive`; dann läuft alles, und die erste Eskalation endet bei `topTierReached` beim Benutzer.
- **D4** Typische Tokens nil (50.000 reserviert, als unsicher markiert). Alternative: etwa 65.000 aus der Codex-Aufzeichnung.
- **D5** Ist der installierte Build nicht abgenommen, bleiben die Profile der neuesten abgenommenen Version nutzbar, damit der genaue Grund des Gates erscheint. Alternative: sperren mit `catalog:installedNotVerified`; dann erscheint „Kein passendes Modellprofil“.
- **D6** Effort und Kontextgrenze nil, wie abgenommen.
- **D7** Abgleich nur beim Start der App; nach einem CLI-Update neu starten. Alternative: zusätzlich bei der erneuten Prüfung im Onboarding.
- **D8** Das Kit schlägt die Stufe `standard` vor; der Kontoinhaber darf sie im Patch vor dem Commit ändern. Die Stufe ist kein Beleg.

## Abweichungen von früheren Entscheidungen

- **ADR 0005 §8:** „`verified_at` setzt außerhalb von Tests nur Paket A“ heißt jetzt: nur `ModelProfileSync`, aus Katalogeinträgen, die durch Belege aus Paket A bewiesen sind.
- **ADR 0008 §8:** `matrix.patch` schlägt zusätzlich die Modellprofile vor (zweite Datei im selben Patch).
- **ADR 0003:** Neben der Matrix gibt es den Katalog geprüfter Modellprofile; beide hängen am selben Bericht.
- **`Plan/laufzeitvertrag.md`:** `model_profile` hat weiter keinen eigenen Versionsbezug; die Version steckt in der stabilen ID.

## Folgen

- Neu: `VerifiedModelEntry`, `VerifiedModelProfiles` (Providers), `StepID.exercisedRole`, `EvidenceCheck.profileProblems`, `ProfileProposal` (Acceptance), `Store.syncCatalogModelProfiles`, `ModelProfileSyncReport` (Storage), `ModelProfileSync`, `ProfileRegistration`, `ProfileSyncOutcome`, `AppServices.profileSync` (Workbench), `AutomationGate.installedIdentity` (Orchestration).
- Ein Quelltext-Test hält `registerModelProfile(` im Store, im UI-Test-Seed und im UI-Test-Zweig der App, `syncCatalogModelProfiles(` in `ModelProfileSync` und `ModelProfileSync.run(` im Start der App.
- Auf einer echten Datenbank stehen nach dem Start vier nutzbare Profile: Claude `sonnet` und Codex `gpt-6.2-sol`, je als Autor und Prüfer, Stufe `standard`. Ein Autor kann starten, und das Review-Blatt bietet den anderen Anbieter an.
- Nicht verändert: Gate, `AdapterPolicy`, Zustimmungen, Budgets. Ein Benutzerstart braucht weiter einen live abgenommenen, isolierten Build.
