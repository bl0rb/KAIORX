# ADR 0004 · Kandidaten, Belege, Freigabe und Publikation

**Status:** angenommen, 19. November 2026 · **Betrifft:** Paket E, `Plan/macos-und-git.md` (Git-Transaktion, Schritte 4–7), `Plan/laufzeitvertrag.md` (Integrationskandidat)

## Entscheidungen

1. **Kandidat.**
   - Ein versiegeltes Autorenergebnis `R` wird in einem eigenen Integrations-Worktree auf den aktuellen Zielstand `P` gemischt (`merge --no-ff`): erster Elternteil `P`, zweiter `R`.
   - Hooks, rerere und Editoren sind aus. Filter und eigene Merge-Treiber hat der Worktree-Preflight schon abgewiesen.
   - Ein bereits enthaltenes Ergebnis ergibt keinen Kandidaten.
   - Bei Konflikten bleibt der Kandidat `conflicted`. Die Konfliktpfade kommen aus den Indexstufen. Der Benutzer entscheidet jeden Pfad: ours, theirs, Inhalt oder löschen. Erst dann entsteht der Commit `C`.
   - Jede Auflösung geht über Git-Objekte und den Index (`hash-object`, `update-index`, `checkout-index`), nie über Dateisystempfade. Ein Symlink im Worktree kann so nicht nach außen führen.
   - Konflikte an Pfaden, die auf keiner Seite existieren (Datei/Ordner, verschiedene Typen, Ordner-Umbenennungen), werden nicht angeboten. Der Merge wird abgebrochen.
   - Löst eine Auflösung einen Revert auf den aktuellen Stand auf, wird der Kandidat verworfen.
   - Eine Auflösung lässt sich wiederholen: Ist der Commit schon entstanden (kein Merge mehr offen, `HEAD` hat genau die erwarteten Eltern), wird er übernommen. Hat ein abgebrochener Aufruf erst einen Teil der Pfade bereitgestellt, wird Merge bzw. Revert neu gestartet, und alle Entscheidungen gelten neu. Das Pinnen ist idempotent; ein gescheitertes Pinnen schließt seinen Journaleintrag, damit ein neuer Versuch ohne Neustart möglich ist.
   - `C` wird unter `refs/kaiorx/candidates/<id>` gepinnt, über das Journal.
   - Zustände: `conflicted → built → testing → reviewing → accepted → publishing → published`, Abbruch über `rejected` oder `superseded`.
   - Je Aufgabe ist höchstens ein offener Kandidat erlaubt, je Ziel höchstens eine laufende Publikation.
   - Ein Ergebnis, dessen Kandidat an Belegen scheiterte (roter Test oder blockierender Befund), wird nicht neu gebaut. Es braucht ein neues Autorenergebnis. Verdrängte Kandidaten (Ziel weitergezogen) dürfen neu gebaut werden.
   - Die Aufgabe folgt ihrem Kandidaten in derselben Store-Transaktion: `built → verifying`, `conflicted → conflict`, `accepted → awaitingMerge`, zurück nach `reviewing → verifying`, `rejected → needsChanges`. Neu ist `awaitingMerge → verifying`, wenn ein verdrängter Kandidat neu gebaut wird oder neue Befunde die Prüfung wieder öffnen (Ergänzung zum Laufzeitvertrag).
   - Seitenzustände werden zuerst zu ihrer Wiederaufnahmestufe verlassen. Kann die Aufgabe nicht folgen, wird die ganze Transaktion verworfen; es gibt keinen halben Zustand.
   - Integrationsschritte laufen nur, solange die Aufgabe in Prüfung ist: nicht `blocked` (Halt durch den Benutzer), nicht beendet, nicht zurück beim Autor (`ready`, `needsChanges`). Belege und Entscheidungen prüfen das in ihrer Store-Transaktion. Freigabe und Publikation verlangen `awaitingMerge`.
   - Ein Halt wird nie implizit aufgehoben: Kann eine blockierte Aufgabe nicht folgen, wird der Kandidatenwechsel verweigert. Die Belege bleiben gespeichert; Freigabe und Publikation werten einen Kandidaten in `reviewing` vorher neu aus.
   - Ein Halt während eines Konflikts kehrt in den Konflikt zurück, solange der Kandidat `conflicted` ist.
   - Geht die Aufgabe nach `ready` oder `needsChanges` oder endet sie ohne Integration, werden ihre offenen Kandidaten in derselben Transaktion verworfen. Deren Integrations-Worktrees entfernt `recover`.
   - `conflict`, `awaitingMerge` (außer der Rückkehr aus `blocked`), `awaitingMerge → verifying`, `conflict → verifying` und `integrated` setzt nur die Integration, kein Befehl. Eine Revert-Aufgabe kann per Befehl nicht nach `ready` oder `needsChanges`; sie lässt sich nur blockieren oder beenden. Während ein Kandidat publiziert wird, lässt sich seine Aufgabe nur blockieren; eine gescheiterte Publikation gibt den Kandidaten frei, ohne die Aufgabe zu bewegen.

2. **Belege gelten genau einem Commit.**
   - Test, Review, Befunde und Freigabe tragen die Kandidaten-OID.
   - Belege für eine andere OID oder für einen beendeten Kandidaten werden abgewiesen oder zählen nicht. Während ein Kandidat publiziert wird, nimmt er keine Belege und Entscheidungen an.
   - Ein neu gebauter Kandidat beginnt ohne Belege.
   - Jeder neue Beleg erhöht die Version des Kandidaten. Freigabe und Publikation prüfen das Gate erneut, und die Publikation bindet sich in derselben Transaktion an die geprüfte Version.
   - Neue Befunde nach der Annahme führen zurück nach `reviewing` (Freigaben werden widerrufen). Ein blockierender Befund verwirft den Kandidaten.

3. **Tests.**
   - Ein bestätigtes Testprofil läuft in einem frischen QA-Worktree bei `C` mit Test-Runner-Isolation.
   - Ein Infrastrukturfehler oder Timeout erlaubt einen neuen Lauf.
   - Ein roter Test, ein Absturz oder geänderte versionierte Dateien verwerfen den Kandidaten. Scheitert danach nur das Aufräumen des QA-Worktrees, gilt das Ergebnis trotzdem; `recover` meldet nicht entfernbare Worktrees als hängend.
   - Geänderte Testeingaben werden festgehalten und dem Reviewer gezeigt: Pfadpräfixe des Profils (Teil seines Digests), vom Profil genannte Dateien sowie Hook- und CI-Orte.
   - Ein verlorener Testlauf (Absturz der App) setzt den Kandidaten bei `recover` auf `built` zurück. `recover` entfernt auch QA- und Integrations-Worktrees verlorener Läufe; nur der Worktree eines `conflicted`-Kandidaten bleibt.

4. **Review.**
   - Der Reviewer läuft bei einem anderen Anbieter als der Autor, schreibgeschützt in einem eingefrorenen Worktree bei `C`.
   - Er erhält Kriterien, Testbelege und den Diff `P..C`.
   - Er antwortet mit einem JSON-Bericht: OID, Urteil, Befunde mit Schweregrad, Datei, Zeile, Auswirkung und Vorschlag.
   - Gelesen wird nur der letzte ```json-Block der eigenen Antworten, mit Zäunen als ganzen Zeilen (CRLF wie LF). Es gibt keinen Rückgriff auf frühere Blöcke; ein unvollständiger letzter Block macht den Bericht `invalid`.
   - Ein Reviewer-Versuch zählt genau einmal und nur, wenn er ein erfolgreicher Reviewer derselben Aufgabe ist.
   - Der Diff steht im Prompt zwischen Zäunen, die länger sind als jede Backtick-Folge im Diff.
   - Der Reviewer-Worktree ist an seinen Versuch gebunden und wird bei jedem Ausgang entfernt.
   - Ein Revert wird gegen den Anbieter des ursprünglichen Autors geprüft.
   - Ein Befund mit gültiger Stelle im Diff behält seinen Schweregrad, auch ohne Auswirkung oder Vorschlag. Befunde ohne gültige Stelle werden Kommentare. Ausnahme: als blockierend oder major gemeldete Befunde werden `major` (sie brauchen eine Entscheidung). Ein gemeldeter blockierender Befund macht den Bericht zur Änderungsanforderung, gleich welches Urteil er nennt.
   - Schweregrade werden ohne Groß-/Kleinschreibung und umgebende Leerzeichen gelesen; ein fehlender, unbekannter oder nicht als Text angegebener Schweregrad gilt als `major`. Zeilen sind ganze Zahlen, keine Wahrheitswerte. Ist `findings` keine Liste, ist der Bericht `invalid`; Text-Einträge in der Liste werden Kommentare.
   - Ein Bericht über eine andere OID oder ein unlesbarer Bericht ist `invalid` und speichert nur Kommentare. Befunde zählen im Gate aus jedem Bericht zum Commit, auch wenn sein Urteil unlesbar ist.
   - Ein vom Benutzer importiertes Review ist als `userImported` gekennzeichnet.

5. **Publikationsgate.** Publiziert wird nur, wenn alle Bedingungen erfüllt sind:
   - ein grüner Test für `C`
   - ein zustimmendes, unabhängiges Review für `C`
   - kein blockierender Befund (blockierende Befunde lassen sich nicht annehmen, nur in einem neuen Kandidaten beheben)
   - alle anderen Befunde entschieden, mit Begründung
   - eine Freigabe für genau `C` auf genau `P`

6. **Publikation.**
   - Freigabe und Journaleintrag entstehen in einer Transaktion, danach folgt `update-ref <ziel> C P`.
   - Die Version des Kandidaten wird vor der Gate-Prüfung gelesen. Auch der automatische Wechsel `reviewing ↔ accepted` ist an diese Version gebunden.
   - Weitere Freigaben desselben Kandidaten (Doppelklick) werden bei der Publikation widerrufen.
   - Bei Erfolg werden Kandidat, Freigabe, Aufgabe und Ereignis in einer Transaktion abgeschlossen. Eine Aufgabe, die der Benutzer während der Publikation blockiert hat, wird ebenfalls `integrated`: Das Ziel steht dann bereits auf `C`.
   - Ist das Ziel inzwischen weitergezogen, wird der Kandidat `superseded`, seine Freigaben werden widerrufen, und eine neue Belegkette ist nötig.
   - Scheitert das Update bei unverändertem Ziel (etwa wegen einer Ref-Sperre), lässt sich die Publikation wiederholen. Kandidat und Freigabe bleiben gültig.
   - Bei einem unklaren Fehler bleibt der Eintrag `prepared` für `recover`.
   - Zustandswechsel, die nicht parallel laufen dürfen, werden in der Store-Transaktion entschieden (`onlyFrom`). So verdrängt kein veralteter Stand einen Kandidaten, der gerade publiziert wird.
   - Wiederherstellung:
     - Steht das Ziel auf `C`, wird der Eintrag abgeschlossen.
     - Steht es auf `P`, wird der Vergleich nur wiederholt, wenn die Freigabe gültig ist und die Aufgabe weiter in `awaitingMerge` wartet. Sonst geht der Kandidat zurück nach `accepted`; ein Halt bleibt bestehen.
     - Bei jedem anderen Stand wird der Kandidat `superseded`.
     - Ein Eintrag, dessen Abschluss scheitert, blockiert die anderen nicht.

7. **Lieferbranch.**
   - `refs/heads/<name>` im Original-Repository wird nur neu angelegt (create-only), am aktuellen Zielstand. Ist der Name belegt, bekommt er ein Suffix.
   - Namen müssen wörtlich sein: `@`, `@{…}` und Namen, die mit `-` beginnen, werden abgewiesen.
   - „Belegt“ wird ohne Beachtung von Groß- und Kleinschreibung und Unicode-Normalisierung geprüft, auch für Ordner/Datei-Konflikte (`a` neben `a/b`). Auf APFS wäre `Main` sonst ein Alias eines gepackten `main`.
   - Checkout, Index und vorhandene Branches des Benutzers bleiben unberührt.
   - Der Vorgang ist nicht journalisiert. Er ist idempotent prüfbar, weil der Ref entweder existiert oder nicht.

8. **Revert.**
   - Ein neuer Kandidat vom aktuellen Zielstand mit `revert -m 1` des publizierten Merge-Commits, in einer eigenen Aufgabe. Die Aufgabe ist eine Host-Aufgabe und beginnt in `verifying`.
   - Aufgabe und Kandidat entstehen in einer Transaktion. Je Original ist höchstens ein offener Revert erlaubt; die Prüfung läuft vor der Git-Arbeit. Ist nichts mehr zurückzunehmen, entsteht kein Kandidat.
   - Ein Revert mit Konflikten hält seine Aufgabe in `conflict`. Wird der Revert verworfen oder verdrängt, endet seine Aufgabe als `noResult`, denn es gibt keinen Autor, der nachbessert.
   - Ein an Belegen gescheiterter Revert wird auf demselben Zielstand nicht neu gebaut.
   - Er durchläuft dieselben Schritte: Konflikt, Test, Review, Freigabe, Publikation.
