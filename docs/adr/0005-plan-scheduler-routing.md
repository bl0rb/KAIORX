# ADR 0005 · Plan, Scheduler und Routing

**Status:** angenommen, 20. November 2026; ergänzt durch ADR 0012 (Modellprofile, vorgeschlagen) · **Betrifft:** Paket F, `Plan/ARCHITEKTURPLAN.md` (Abschnitt 3), `Plan/laufzeitvertrag.md` (Plan, Lease, Budget, Entscheidung), ADR 0003, ADR 0004

## Kontext

Paket F macht aus einzeln angelegten Aufgaben einen geprüften Plan, wählt Aufgaben in der richtigen Reihenfolge aus und bestimmt Anbieter, Modellstufe und Budget. Bis Paket A gibt es keine `liveVerified`-Version: Echte Anbieter starten nicht automatisch. Der Scheduler wird mit dem Fake-Adapter und virtueller Zeit geprüft. Drei unabhängige Kritiken des Entwurfs sind eingearbeitet.

## Entscheidungen

1. **Planentwurf.**
   - Aufgaben mit Schlüssel, Titel, Ziel, mindestens einem prüfbaren Kriterium, Lese- und Schreibbereichen, Vorgängern, optionalem Elternschlüssel, Risiko, vier Schwierigkeitsangaben und optionalem Testprofil.
   - Manuelle Zerlegung und Planervorschlag nutzen dasselbe Format und denselben Validator. Ein Planervorschlag ist der letzte ```json-Block einer Antwort (Regeln wie beim Review) und wird als `planner` gekennzeichnet. Den Planer als eigene Versuchsrolle zu starten, gehört nicht zu F.
   - Elternaufgaben gliedern nur und existieren nur im Entwurf. Ausgeführt werden Blätter: Vorgänger einer Elternaufgabe gelten für alle ihre Blätter, ein Nachfolger einer Elternaufgabe wartet auf alle ihre Blätter.
   - Schreibbereiche sind relative Pfadpräfixe. Fehlen sie, gilt das ganze Projekt. Absolute Pfade, `..`, `~`, Backslashes und `.git` sind unzulässig.

2. **Validierung.** Eindeutige Schlüssel; existierende Vorgänger und Eltern; keine Selbstkante; kein Zyklus, auch über Elternaufgaben (der Fehler nennt ihn); auflösbare Bereiche; mindestens ein Kriterium je Blatt; kein Blatt hängt von einer beendeten, nicht integrierten Aufgabe ab. Höchstens 12 Blätter und drei Ebenen (Startwerte des Plans); ein größerer Entwurf geht zur Überarbeitung zurück. Fehlende Schwierigkeitsangaben sind gültig und werden als unsicher markiert.

3. **Revisionen und Aufgabenidentität.**
   - Revisionen sind unveränderlich (`plan_revision` mit Digest und Entwurf als Artefakt, `plan_task` je Blatt, `dependency`). Befehle nennen die erwartete aktuelle Revision. Eine Revision merkt sich, auf welcher sie vorgeschlagen wurde; angenommen wird sie nur, wenn genau diese noch aktuell ist. Bei der Annahme wird sie gegen die dann geltenden Aufgabenzustände erneut geprüft.
   - Ein Schlüssel ist je Auftrag stabil: `task.plan_key`, eindeutig je Auftrag. Gleicher Schlüssel heißt dieselbe Aufgabe über alle Revisionen.
   - Annahme legt Aufgaben für neue Schlüssel in `pending` an. Eine entfernte, nicht gestartete Aufgabe wird `cancelled` (Grund `removedInRevision`). Eine gestartete Aufgabe (ab `running`, nicht beendet) darf nur unverändert bleiben; sonst wird die Annahme verweigert, bis sie gestoppt ist.
   - Erste Annahme: Auftrag `draft → planned`. Aktivieren (`planned → active`) ist ein Benutzerbefehl. Eine spätere Annahme lässt einen aktiven Auftrag aktiv. Pläne beendeter Aufträge ändern sich nicht.
   - Eine neue Revision liefert eine Differenz (Aufgaben neu, entfernt, geändert; Kanten neu, entfernt) und eine Aufwandsschätzung (Blätter je Stufe, erwartete Tokens aus den Profilen).
   - Hat ein Auftrag eine Revision, legt `createTask` keine freien Aufgaben mehr an. Aufträge ohne Revision (Pakete B–E) behalten ihr bisheriges Verhalten und werden nicht geplant. Host-Aufgaben für Reverts (ADR 0004) gehören zu keinem Plan.
   - `active → done` ist ein Benutzerbefehl und verlangt, dass alle Aufgaben des aktuellen Plans integriert sind und keine Aufgabe des Auftrags mehr offen ist.

4. **Bereitschaft und Basis.**
   - Eine geplante Aufgabe wird `ready`, wenn alle Vorgänger erfüllt sind: `integrated` und kein veröffentlichter Revert ihres veröffentlichten Kandidaten. Entschieden wird im Store, ohne Git.
   - Leeres Ergebnis: Der Benutzer kann eine Aufgabe in `resultReady`, deren Ergebnis leer oder schon enthalten ist, ausdrücklich als erledigt annehmen (`acceptEmptyResult`). Sie wird `integrated` (neuer Übergang `resultReady → integrated`, nur über diesen Befehl) und erfüllt ihre Nachfolger ohne Merge-Commit.
   - Die Basis eines Versuchs ist der Integrationsstand des Auftrags laut Store (letzter veröffentlichter Kandidat, sonst die Basis des Auftrags), festgehalten am Versuch bei der Reservierung. Jeder neue Versuch beginnt vom aktuellen Stand.
   - `ready_at` wird beim Wechsel nach `ready` gesetzt. Ein Befehl `pending → ready` für eine geplante Aufgabe wird verweigert.
   - Endet ein Vorgänger ohne Integration oder wird er zurückgenommen, warten seine Nachfolger mit Grund `predecessorEnded` bzw. `predecessorReverted`, bis eine neue Revision angenommen ist. Eine zurückgenommene Aufgabe zählt dabei wie eine beendete: Niemand kann von ihr abhängen.
   - Gibt eine neue Revision einer bereiten Aufgabe einen offenen Vorgänger, geht sie zurück nach `pending` (neuer Übergang `ready → pending`). Ein Halt des Benutzers bleibt; er führt dann nach `pending` zurück.

5. **Warten ist kein Aufgabenzustand.** `blocked` bleibt der Halt durch den Benutzer (ADR 0004). Wartet eine bereite Aufgabe auf Slot, Bereich, Freigabe, Quota, Budget, Profil oder unabhängigen Reviewer, bleibt sie `ready`. Der Grund steht in `task.wait_reason`; `task.blocked` bzw. `task.ready` werden nur bei einer Änderung des Grundes geschrieben. Das ergänzt die Vertragszuordnung „ausstehende Genehmigung/Quota → `blocked`“.

6. **Auswahl, Slots und Bereiche.**
   - Reihenfolge: längster verbleibender Abhängigkeitspfad (absteigend), `ready_at` (aufsteigend), das Projekt mit der ältesten letzten Reservierung, Schlüssel. Kein gespeicherter Rotationszeiger.
   - Grenzen (`SchedulerLimits`, einstellbar): zwei aktive Versuche global, einer je Anbieterkonto. Reviews zählen mit. Autoren nehmen nicht den letzten globalen Slot, solange ein Kandidat des Projekts ohne laufenden Reviewer auf sein Review wartet.
   - Aktiv sind Versuche in `reserved`, `starting`, `running`, `awaitingApproval`, `cancelling` und `uncertain` aus einem laufenden Stream dieses App-Laufs. Nach einem Neustart gibt jeder `uncertain` Versuch seinen Slot frei (`process_lost`), hält aber den Bereich seiner Aufgabe. Er wird nie automatisch wiederholt; der Benutzer gleicht ihn mit `transitionAttempt` ab.
   - Reviewer laufen unter der Reviewer-Freigabe ihres Anbieters und zählen für dessen Konto. Für Aufgaben eines Plans startet kein Review ohne diese Freigabe, und Autoren solcher Aufgaben starten nur über den Scheduler.
   - Die Reviewreserve gilt nur für Kandidaten, deren Aufgabe in Prüfung ist und für deren Commit noch kein lesbares Review vorliegt.
   - Ein Schreibbereich wird gehalten, solange die Aufgabe in `running`, `resultReady`, `verifying`, `awaitingMerge` oder `conflict` ist, `blocked` mit einer dieser Wiederaufnahmestufen, oder einen offenen Autorenversuch hat. `ready` und `needsChanges` geben ihn frei. Bereiche gelten je Auftrag (je Integrationsziel).
   - Überlappung wird je Pfadkomponente nach NFC und ohne Groß-/Kleinschreibung entschieden (APFS). Ein unbekannter Bereich überlappt alles. Manifest- und Lockdateien bilden einen gemeinsamen Bereich.
   - Abweichung vom Vertrag: Statt einer `lease`-Tabelle werden Slots und Bereiche in der Reservierungstransaktion aus Versuchs- und Aufgabenzuständen abgeleitet. Kein verwaister Lease kann nach einem Absturz Arbeit sperren.
   - Doppelter Start: Jeder Tick nutzt neue Befehls-IDs. Die Reservierung prüft im Store `ready`, die aktuelle Revision, den einen aktiven Autor, Slots und Bereiche; ein verlorenes Rennen ist kein Fehler, sondern „nichts zu tun“. Je Aufgabe ist höchstens ein offener Reviewer erlaubt.
   - Schreibt ein Autor außerhalb seiner Bereiche, verwirft das Versiegeln diese Pfade (Paket C). Ein Kandidat aus einem Ergebnis mit verworfenen Pfaden entsteht nur nach ausdrücklicher Bestätigung (manuelle Klärung).

7. **Befugnisse.**
   - `consent` bindet Projekt, optional Auftrag, Anbieter, Konto, Modus, Rollen, Schreibwurzeln, Wurzeln für sensible Bereiche, optional Ablauf und eine Obergrenze unbestätigter Versuche bei unbekannter Quota. `scope_digest` ist der Digest dieser Felder. Widerruf setzt `revoked_at`.
   - Der Scheduler reserviert nur mit gültiger Freigabe, deren Schreibwurzeln den Bereich decken (bei sensiblen Aufgaben die sensiblen Wurzeln). Ein Widerruf verhindert neue Reservierungen unter dieser Freigabe sofort; alle laufenden Versuche des Kontos, die vor dem Widerruf reserviert wurden, werden abgebrochen, auch unter anderen Freigaben.
   - Automatische Starts brauchen eine Freigabe über ein `CapabilityGate`: produktiv `liveVerified` in der Kompatibilitätsmatrix (ADR 0003), in Tests ist `fake` freigegeben. Ohne automatische Befugnis reserviert der Tick nichts und schreibt eine Entscheidung `awaitingUserStart`; ein Benutzerstart läuft durch dieselbe Reservierungstransaktion.
   - Vorab braucht es einen freigegebenen Reviewer-Anbieter, der vom Autor-Anbieter abweicht; sonst wartet die Aufgabe (`noIndependentReviewer`).

8. **Routing.**
   - Stufen `fast`, `standard`, `intensive` verweisen je Anbieter auf Modellprofile mit Rolle, Modell, Effort, Kontextgrenze, typischer Tokenmenge, beobachteter Dauer, `verified_at` und `disabled_reason`. Nur verifizierte, nicht gesperrte Profile zählen. `verified_at` setzt außerhalb von Tests nur Paket A.
   - Regeln in dieser Reihenfolge: (1) Freigabe, Auth oder Isolation unklar → warten mit Grund, keine Rechteausweitung; (2) Sperre, Widerruf, Budget → warten; (3) Schwierigkeit → Stufe; (4) sensibles Risiko → mindestens `standard`; (5) Fehlerhistorie → Reparatur, Eskalation oder Benutzerentscheidung.
   - Schwierigkeit: je +1 für mehrere Module, mehr als drei Dateien, unklaren Lösungsweg, fehlenden reproduzierbaren Test. 0–1 `fast`, 2 `standard`, 3–4 `intensive`.
   - Anbieterwahl: Hat die Aufgabe schon Autorenversuche, bleiben ihr Anbieter und ihr Konto; keine Konto- oder Anbieterrotation. Sonst der erste freigegebene Anbieter mit freiem Slot und passendem Profil.
   - Benutzerentscheidung: Wartet eine Aufgabe auf den Benutzer (Versuchsgrenze, oberste Stufe, Fehlstarts), kann er weitere Versuche freigeben (`grant`), optional auf höherer Stufe. Gezählt wird danach neu; die Freigabe steht als Entscheidung im Verlauf.
   - Fachlicher Fehler: roter Test oder Absturz (`failed`, `crashed`) des Kandidaten, oder ein Autorenversuch `failed` mit `providerFailed`. Alles andere (Infrastruktur, Timeout, Fehlstart, `rateLimited`) zählt weder als Versuch noch als Fingerabdruck.
   - Nach dem ersten fachlichen Fehler: ein Reparaturversuch auf derselben Stufe, sein Auftrag enthält den Bericht des letzten gezählten Fehlers (roter Test, blockierende Befunde oder Fehlermeldung). Derselbe Fingerabdruck zweimal oder ein zweiter blockierender Befund: genau eine Stufe höher. Höchstens drei Autorenversuche mit Turn je Aufgabe; danach, an der obersten Stufe und ohne Profil entscheidet der Benutzer. Der Scheduler setzt dafür `needsChanges → ready` selbst.
   - Fingerabdruck: SHA-256 nach Normalisierung in dieser Reihenfolge: Worktree-Wurzel → `<wt>`, absolute Pfade → `<path>`, Hex ab sieben Zeichen → `<hex>`, Zahlen → `<n>`, Leerraum zusammengefasst.
   - Technischer Fehlstart vor Turnbeginn: höchstens zwei Wiederholungen, Wartezeit `30 s · 2^n` plus Streuung `SHA-256(Aufgabe ‖ n) mod (Wartezeit / 2)`.
   - Ein gepinnter Zwischenstand vor der Eskalation gehört nicht zu F; jeder Versuch beginnt vom aktuellen Integrationsstand.
   - Jede Entscheidung wird als `decision` gespeichert: Regel, Regelversion, Evidenz, Ergebnis, verantwortlich (`scheduler` oder Benutzer), verbleibende Versuche, gewählte Alternative.

9. **Sensible Aufgaben.** Mindestens `standard`; eine Freigabe mit sensiblen Wurzeln; ein genanntes Testprofil, sonst hält das Gate; und zusätzlich zu einem unabhängigen Anbieter-Review ein zustimmendes, vom Benutzer importiertes Review (`userImported`). Das importierte Review zählt hier nicht zugleich als unabhängiges. Ergänzung zu ADR 0004 Punkt 5.

10. **Quota und Budget.**
    - Neue Adapterereignisse: `rateLimited` (Art, optional Retry-After, optional Reset) und `quotaObserved` (Fenster, Einheit, Verbrauch, Grenze, Reset). Der Store schreibt Beobachtung bzw. Sperre in derselben Transaktion wie das Ereignis.
    - Sperre (`quota_block`) je Konto: Retry-After, sonst Reset der letzten Beobachtung desselben Fensters, sonst 60 s, verdoppelt je weiterer Sperre, höchstens 15 min. Widerruf und Planstopp sperren bis zur Aufhebung. Eine offene Sperre, die mindestens so lange dauert, wird von einer neuen nicht verkürzt. Die Herkunft des Endes wird gespeichert: Ohne bekannten Reset (Rückfallwert oder offenes Ende) lässt sich eine Sperre einmal je Sperrfolge manuell aufheben, eine manuelle Sperre jederzeit. Eine abgelaufene Sperre hebt nur der Scheduler nach der Zugangsprüfung ohne Inferenz auf, auch vor einem Benutzerstart; scheitert die Prüfung, folgt eine zeitlich begrenzte Sperre. `quota.blocked` und `quota.released` werden bei jeder Sperre und Aufhebung geschrieben.
    - Eine Beobachtung, deren Reset vorbei ist, begrenzt nicht mehr; der Scheduler wacht zum Reset auf.
    - Ein Versuch mit Rate-Limit endet `failed` mit `rateLimited`: Infrastruktur, die Aufgabe kehrt nach `ready` zurück.
    - Ab 80 % eines bekannten Fensters keine weitere parallele Reservierung für das Konto, ab 100 % keine. Ohne bekannte Quota nur so viele Versuche, wie die Freigabe als unbestätigte Versuche erlaubt (Abweichung: Vorabbestätigung statt Bestätigung je Versuch). Gezählt werden Versuche, die den Anbieter erreicht haben oder noch offen sind, nicht technische Fehlstarts.
    - Budget (`budget_bucket`) je Konto und Auftrag; eine Reservierung je Versuch in Höhe der typischen Tokenmenge des Profils (ohne Angabe: fester Startwert, als unsicher markiert). Die Reviewreserve wird im Bucket des Reviewer-Kontos geprüft und angezeigt, nicht beim Autor gebucht. Bei terminalem Versuch wird mit dem gemeldeten Verbrauch ausgeglichen; ohne Endverbrauch bleibt sie `unresolved`, bis der Benutzer sie mit einem Betrag ausgleicht oder freigibt (`resolveReservation`). Von der Wiederherstellung abgebrochene Reservierungen werden freigegeben.
    - Codex: `account/rateLimits/updated` → `quotaObserved` (primäres und sekundäres Fenster, Prozent), `error` mit `usageLimitExceeded`, `rateLimitExceeded` oder HTTP 429 in einer der HTTP-Varianten und ohne `willRetry` → `rateLimited`. Codex nennt kein Retry-After. Claude: ohne veröffentlichtes Schema kein Mapping; eine Sperre setzt dort der Benutzer.

11. **Virtuelle Zeit.** `Store.now()` ist öffentlich; Store und Scheduler lesen dieselbe Uhr. `tick()` schläft nie und liefert reservierte Versuche, Wartegründe und den nächsten Weckzeitpunkt (frühestes Sperrende oder Wiederholungszeit). Die App weckt bei diesem Zeitpunkt oder einer Zustandsänderung.

12. **Ereignisse.** `plan.proposed`, `plan.accepted`, `task.ready`, `task.blocked` (Grund), `policy.decided`, `quota.blocked`, `quota.released`, `quota.observed`.

## Vertragsabweichungen

| Vertrag | Hier | Grund |
|---|---|---|
| `lease` | abgeleitet aus Zuständen | keine verwaisten Sperren |
| `capability`, `model_profile.capability_id`, `attempt.capability_id` | `model_profile.provider`; `attempt.model_profile_id` | Capability-Snapshots entstehen erst mit Paket A |
| `policy`, `consent.policy_id`, `attempt.policy_id` | keine Policy-Tabelle; `consent` mit expliziten Feldern und `scope_digest` | Policy-Revisionen folgen mit Paket H |
| `plan_revision` mit `validated_at?/accepted_at?` | zusätzlich `superseded_at`, Ersteller `user`/`planner` | Revisionen bleiben nachvollziehbar |
| `plan_task(spec_artifact_id, allowed_paths, requirements, risk, priority)` | Entwurf als Artefakt, Felder als Spalten, Priorität aus dem Abhängigkeitspfad | ein Format für Validator und Store |
| `decision.task_id` NOT NULL | nullable, plus Subjekt (Konto) | Kontosperren betreffen keine einzelne Aufgabe |
| — | `quota_block` (mit `end_source`), `task.plan_key/wait_reason/ready_at`, `attempt.base_oid/account_id/model_profile_id/process_lost`, `plan_revision.based_on_plan_id` | neu (Migrationen v4, v5) |
| Aufgabe `blocked` bei Quota/Genehmigung | `ready` mit `wait_reason` | `blocked` ist der Benutzerhalt (ADR 0004) |

## Nicht in F

Planer als Versuchsrolle, UI für DAG und Differenz (Paket H), Policy-Revisionen, Module mit generierten Ausgaben als Projekteinstellung, gepinnter Zwischenstand vor der Eskalation, automatisches Vorantreiben von Versiegeln, Kandidat, Test und Review (bleibt Serviceaufruf wie in M0).

## Folgen

- Migration v4 mit den genannten Tabellen und Spalten; bestehende Daten bleiben gültig (neue Spalten sind leer, Aufträge ohne Revision werden nicht geplant).
- Abnahme: Diamond-DAG, Zyklus, überlappende Schreibbereiche, doppelter Start aus zwei Schedulern, Widerruf, wiederholter Diagnosefehler und `429` in virtueller Zeit.
