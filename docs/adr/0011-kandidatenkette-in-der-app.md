# ADR 0011 · Kandidatenkette: Host-Schritte automatisch, Anbieter- und Testschritte beim Benutzer

**Status:** Vorgeschlagen – wartet auf Abnahme durch den Kontoinhaber (21. November 2026) · **Betrifft:** `Plan/ARCHITEKTURPLAN.md` (Abschnitt 3, Koordinator), `Plan/macos-und-git.md` Schritte 3–6, ADR 0004, ADR 0005 §4, §6 und „Nicht in F“, ADR 0009 §8, ADR 0010

## Kontext

Der Plan verlangt eine Kette ohne Handarbeit: „Nach Abschluss versiegelt der Koordinator das Ergebnis, baut einen Merge-Kandidaten … übergibt ihn an Test und Gegenreview“ (`ARCHITEKTURPLAN.md`), und „Nach Prozessende Schreibzugriff entziehen“ (`macos-und-git.md` Schritt 3). ADR 0005 hat das automatische Vorantreiben von Versiegeln, Kandidat, Test und Review ausdrücklich zurückgestellt („Nicht in F“). Seitdem sind alle Bausteine Serviceaufrufe (`WorkspaceService.seal`, `IntegrationService.buildCandidate`, `runTests`, `startReview`, `collectReview`), aber in der App ruft sie niemand: Ein Autorenlauf endet in `resultReady`, und dort bleibt die Aufgabe.

Beim Verdrahten fielen vier Lücken auf, die ein automatischer Treiber offenlegen würde:

- Ein beim Neustart wiederhergestelltes Versiegeln (`WorkspaceService.reconcileRef`) verliert seine Liste verworfener Pfade; `buildCandidate` würde ein solches Ergebnis ohne Rückfrage bauen.
- Ein angehaltener Bereich (`blocked`) mit Wiederaufnahme nach `conflict` hält seinen Schreibbereich nicht, obwohl ADR 0005 §6 das verlangt.
- `recordReview` prüft nicht, ob der Reviewer genau den Commit des Kandidaten gesehen hat; ein Review eines älteren Kandidaten derselben Aufgabe könnte für einen neueren zählen.
- `buildCandidate` legt den Kandidaten vor dem Pin-Ref an; ein Absturz dazwischen hinterlässt einen gebauten Kandidaten, dessen Commit kein Ref hält, und `recover()` räumt den Integrations-Worktree trotzdem weg.

## Entscheidungen

1. **Automatisch, nur auf dem Host.** Ein eigener Treiber (`CandidateChain.step()`, einmal je Sekunde in einer eigenen Schleife neben dem Scheduler) erledigt diese Schritte ohne Rückfrage:
   - **Versiegeln**, sobald der Autorenversuch `succeeded` ist und sein Stream beendet ist. Auch eine angehaltene Aufgabe wird versiegelt: Versiegeln entzieht nur Schreibrechte und bewegt die Aufgabe nicht.
   - **Kandidat bauen**, wenn das versiegelte Ergebnis keine verworfenen Pfade hat, nicht schon im Integrationsstand enthalten ist und die Aufgabe einen Kandidaten annimmt (`resultReady`, kein offener Kandidat, nicht angehalten).
   - **Neu bauen**, wenn der Integrationsstand weitergezogen ist und der Kandidat dadurch `superseded` wurde. Ein Kandidat aus demselben Ergebniscommit gab es schon; seine verworfenen Pfade waren also bereits bestätigt.
   - **Fertige Reviews einsammeln** (`collectReview`) und auswerten. Ein leeres Gate macht den Kandidaten `accepted`; Freigabe und Veröffentlichung bleiben beim Benutzer wie bisher.
   - **Worktrees gescheiterter Reviewer entfernen.**

   Diese Schritte starten nie einen Anbieter, führen keinen Projektcode aus und liegen deshalb außerhalb des Automatik-Gates (ADR 0009). Merges laufen je Repository nacheinander (`macos-und-git.md` Schritt 4); dieselbe Aufgabe bearbeitet zu jeder Zeit nur ein Aufruf, Benutzeraktionen eingeschlossen (sonst „gerade in Bearbeitung“). Ein dauerhaft scheiternder Bau wartet mit wachsendem Abstand (5 s × 2ⁿ, höchstens 5 min, nur im Speicher) und zeigt den Grund. Das revidiert ADR 0005 „Nicht in F“ für diese Schritte.

2. **Beim Benutzer bleiben:**
   - **Tests.** Unverändert ADR 0010: Nichts startet Tests automatisch.
   - **Review-Start.** Unverändert ADR 0009 §8: Nur der Benutzer startet Reviews; ein ausdrücklicher Start fragt das Gate nicht, `AdapterPolicy` gilt weiter. Der Hinweis des Gates erscheint im Blatt nur zur Information. Ein Review kann auch als Text eingefügt werden; das ist der einzige Weg für sensible Aufgaben.
   - **Verworfene Pfade.** Ein Kandidat aus einem Ergebnis mit verworfenen Pfaden entsteht nur nach ausdrücklicher Bestätigung, jetzt für **jede** Aufgabe mit mindestens einem verworfenen Pfad, nicht nur für Planaufgaben. Das ist strenger als ADR 0005 §6 und schließt die Lücke beim wiederhergestellten Versiegeln.
   - **Leere oder schon enthaltene Ergebnisse.** Werden nie automatisch angenommen; der Benutzer nimmt sie wie in ADR 0005 §4 ausdrücklich als erledigt an.
   - **Konflikte.** Der Benutzer entscheidet je Datei „Integrationsstand behalten“, „Ergebnis übernehmen“ (beim Revert „Rücknahme übernehmen“) oder „Datei löschen“. Er sieht dazu beide Seiten als schreibgeschützte Diffs ab der Merge-Basis. Eigenes Bearbeiten des Inhalts gibt es in v1 nicht.
   - **Verwerfen** eines Ergebnisses (Punkt 7).

3. **Schreibbereich.** Die erlaubten Pfade beim Versiegeln kommen aus der Planrevision des Autorenversuchs (`attempt.planID`), also aus dem Bereich, der dem Autor genannt wurde, nicht aus einer späteren Revision. Hat die Aufgabe einen Planschlüssel, aber diese Revision kennt die Aufgabe nicht, wird nicht versiegelt (`planTaskMissing`); es gibt nie einen Rückfall auf „ganzes Projekt“. Aufgaben ohne Plan (Pakete B–E, Reverts) versiegeln über das ganze Projekt.

4. **Review an den Commit gebunden.** Der Reviewer-Worktree entsteht am Kandidatencommit; seine `base_oid` ist der geprüfte Commit. `recordReview` verlangt künftig `worktree.base_oid == candidate_oid` und lehnt sonst ab. Der Treiber sammelt nur Reviewer ein, deren Worktree auf dem aktuellen Commit steht. Keine Migration nötig.

5. **Wiederherstellung.**
   - Ein beim Neustart wiederhergestelltes Versiegeln trägt jeden Unterschied zwischen eingefrorenem Worktree und versiegeltem Baum als verworfenen Pfad mit Grund `recoveredUnknown` („nach Neustart ermittelt“) ein. Damit verlangt Punkt 2 auch hier eine Bestätigung.
   - `IntegrationService.recover()` pinnt jeden offenen Kandidaten mit Commit neu, bevor es Integrations-Worktrees entfernt. Fehlt das Objekt, wird der Kandidat abgelehnt („commit lost before pin“).
   - Der Treiber startet erst, wenn `recover()` gelungen ist; nach einem Neustart versiegelt und sammelt er, was nur im Store als beendet steht.

6. **Wartegrund „Nacharbeit“.** Eine Aufgabe in `needsChanges` ohne Verlauf und ohne nutzbare Freigabe kehrt heute still nicht zum Autor zurück. Sie wartet künftig mit `userDecision("rework")`; die bestehende Entscheidung bietet „Weitere Versuche erlauben“.

7. **Verwerfen startet die Zählung neu.** „Ergebnis verwerfen“ ist zuerst eine Freigabe (`scheduler.grant`) und dann `needsChanges`. Die Zählung der Versuche beginnt dadurch neu; das Blatt sagt das sichtbar („Die Zählung der Versuche beginnt neu“) und weist darauf hin, dass ein neuer Lauf Kontingent verbrauchen kann.

8. **Review-Plätze.** Ein ausdrücklicher Review-Start wird verweigert, wenn alle Plätze belegt sind (global oder für das Prüferkonto; ADR 0005 §6 „Reviews zählen mit“). Die Prüfung ist eine nicht atomare Vorprüfung beim Start; eine atomare Prüfung in der Reservierung folgt später.

9. **Vorgaben des Kontoinhabers.** Die offenen Fragen sind mit diesen Vorgaben entschieden; der Kontoinhaber bestätigt oder ändert sie bei der Abnahme:
   1. Versiegeln, Bauen, Neubauen und Einsammeln laufen automatisch und nur auf dem Host (Punkt 1).
   2. Ein ausdrücklicher Review-Start wird bei vollen Plätzen verweigert, nicht nur gewarnt (Punkt 8).
   3. Verworfene Pfade brauchen für jede Aufgabe eine Bestätigung (Punkt 2).
   4. Konflikte werden in v1 ohne eigenes Bearbeiten des Inhalts gelöst (Punkt 2). Grund: `.content` verliert das Ausführungsbit, und der Editor schreibt nach ADR 0007 nur in den Checkout des Benutzers.
   5. Verwerfen startet die Zählung der Versuche neu, sichtbar angezeigt (Punkt 7).
   6. Der Grund einer Ablehnung oder eines Verwerfens geht nicht in den nächsten Autoren-Prompt; das berührt `Scheduler.makeSpec` und die Prompt- und Memory-Regeln und bekommt ein eigenes Vorhaben.

## Abweichungen von früheren Entscheidungen

- **ADR 0005 „Nicht in F“:** Versiegeln, Kandidat bauen und neu bauen, Reviews einsammeln und gescheiterte Reviewer-Worktrees entfernen laufen jetzt automatisch. Test und Review-Start bleiben Benutzeraktionen.
- **ADR 0005 §6:** Die Bestätigung verworfener Pfade gilt für jede Aufgabe, nicht nur für Planaufgaben. `blocked` mit Wiederaufnahme nach `conflict` hält den Schreibbereich, wie dort schon verlangt.
- **ADR 0004:** Ein Review zählt nur für den Commit, an dem sein Worktree angelegt wurde.

## Bekannte Grenzen

- Liefert ein Neubau `alreadyContained`, bleibt die Aufgabe in `verifying`: `acceptEmptyResult` verlangt `resultReady`. Praktisch kaum erreichbar, weil der Ergebniscommit nur zu dieser Aufgabe gehört; die App zeigt es als Grund (`containedAfterRebuild`).
- Übrig gebliebene Prozesse in der Prozessgruppe des Anbieters können nach Prozessende noch schreiben wollen; Versiegeln macht den Worktree zuerst schreibgeschützt und engt das ein.
- Autoren-Worktrees werden nicht aufgeräumt.
- Der Nacharbeits-Prompt enthält keinen Ablehnungsgrund (Punkt 9.6).
- Eine nicht geplante Aufgabe in `needsChanges` nimmt der Scheduler nicht auf; „Ergebnis verwerfen“ wird deshalb nur für Planaufgaben angeboten.

## Änderung des Laufzeitvertrags

Keine. `Workspace.prepare / seal / buildCandidate / publish` bleiben wie beschrieben; der Vertrag nennt nicht, wer sie auslöst. Die Zustandstabellen für Aufgabe und Kandidat bleiben unverändert. Keine Migration.

## Prüfung

- Store: `recordReview` lehnt einen Reviewer mit anderer Worktree-Basis ab; `blocked` mit Wiederaufnahme nach `conflict` hält den Bereich.
- Wiederherstellung: verworfene Pfade eines wiederhergestellten Versiegelns bleiben als `recoveredUnknown`; ein ungepinnter Kandidat wird neu gepinnt, ein verlorener Commit abgelehnt.
- Treiber (Attrappen-Anbieter, injizierter Stream-Status): kein Versiegeln während des Streams; Bau im Bereich; verworfene Pfade bauen nichts ohne Bestätigung; leere und enthaltene Ergebnisse werden nie automatisch angenommen; angehaltene Aufgaben werden versiegelt, aber nicht gebaut; Neustart; Schreibbereich aus der Revision des Versuchs; Konfliktlösung; automatisches Einsammeln auch nach Neustart, aber nie für einen älteren Commit; Neubau nach `superseded`; Rückzug bei dauerhaftem Baufehler; zwei gleichzeitige Durchläufe bauen einen Kandidaten; Hinderungsgründe beim Review-Start; das Gate sperrt keinen ausdrücklichen Start.
- Gemeinsame Reviewer-Wahl (`ReviewerChoice`): Scheduler und Review-Blatt wählen denselben Prüfer wie bisher.
- XCUITest (`-KAIORXUITest`): vom Autorenlauf zum Kandidaten, Bestätigen verworfener Pfade, leeres Ergebnis, Konflikte, Review bis „Freigeben …“; Return löst in keinem neuen Blatt die Freigabe aus.

## Folgen

- Neu: `Domain/Chain.swift` mit den gemeinsamen Typen (`ResultCheck`, `ChainIssue`, `ChainReport`, `ShownResult`, `ShownConflicts`, `ReviewOption`, `ReviewBlocker`, `ReviewerChoice`), `Orchestration/CandidateChain.swift` (Treiber), `Workbench/Candidates.swift` (Aktionen, Konfliktvorschau, Meldungstexte) und neue Entscheidungsblätter.
- `AppServices` erhält `chain`, nur wenn die Integrationswiederherstellung gelungen ist; die App ruft `step()` in einer eigenen Schleife, damit ein langer Merge den Scheduler-Takt nicht verzögert.
- Scheduler und Review-Start wählen den Prüfer über dieselbe Regel (`ReviewerChoice`), sodass der bei der Autorenreservierung eingeplante Prüfer derselbe ist, den das Blatt später anbietet.
