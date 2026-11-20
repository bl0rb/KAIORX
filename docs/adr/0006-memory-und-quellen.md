# ADR 0006 · Memory und Quellen

**Status:** angenommen, 20. November 2026 · **Betrifft:** Paket G, `Plan/memory.md`, `Plan/laufzeitvertrag.md` (`Memory.retrieve / authorize / dispatch`, `purge_job`, Ereignisse), ADR 0005

## Kontext

Paket G speichert bestätigtes Projektwissen mit Herkunft lokal, macht es per FTS5 durchsuchbar, gibt Agenten nur freigegebene Auszüge und kann alles lokal wieder löschen. Die System-SQLite (3.54) bietet FTS5 mit `secure-delete`; die Migration prüft das. Embeddings gehören nicht zu G. Drei unabhängige Kritiken des Entwurfs sind eingearbeitet.

## Entscheidungen

1. **Module.** `Domain`: Werte. `Memory` (neues Target, nur `Domain`): Abschnitte, Suchbegriffe, Auswahl, Geheimnisprüfung, Rendern. `Storage`: Schema v6 und Transaktionen. `Orchestration`: `MemoryBroker` (Anfrage binden, Git-Prüfung, Manifest, Versand), Inspector-Abfragen, Export, Vergessen.

2. **Einträge, Revisionen, Quellen.**
   - `memory_entry` mit `scope` (global/project/task), `pinned`, CHECK auf die FK-Kombinationen, Trigger: Die Aufgabe gehört zum Projekt. Der Bereich ändert sich nie.
   - `memory_revision`: Nummer, Vorgänger, Titel, Text, Art, Zustand `proposed`/`active`/`retired`/`rejected`, Autor, Digest, `valid_until`, `import_key` (global eindeutig). „Veraltet“ wird je Zielbasis bestimmt, nicht gespeichert (Abweichung zu `stale`: gilt nur für ein Ziel). Bestätigen prüft die erwartete aktive Revision und ersetzt sie in einer Transaktion samt Abschnitten. Bestätigte Revisionen sind unveränderlich.
   - Postfach: Vorschläge sind `proposed` und werden übernommen, bearbeitet oder verworfen; eigene Notizen des Benutzers können sofort aktiv werden.
   - Quellen `user`, `git` (Projekt, Commit, relativer Pfad, Blob), `test`/`review` (Versuch und Ereignis im selben Projekt, geprüfter Commit), `derived` (ältere Revision, kein Zyklus). Globale Einträge haben nur `user`- oder `derived`-Quellen. FK-Aktionen: CASCADE nur für die besitzende Revision; Verweise auf Projekt, Aufgabe, Versuch, Ereignis und Ursprungsrevision sind restriktiv, damit keine Löschung die Herkunftsverfolgung überspringt.
   - Git-Quellen werden nur über `GitRunner` aus dem Commit gelesen (Modus und Blob per `ls-tree`), nie aus einem Worktree; Symlinks und Submodule werden abgewiesen, Pfade lexikalisch geprüft (ADR 0005 §1), höchstens 256 KiB.
   - Geheimnisprüfung (versionierte Musterliste im `Memory`-Target) vor Speichern und Export; ein Treffer verhindert die Operation.

3. **Kanten.** `depends_on`, `verifies`, `contradicts`, `related_to`, mit Beleg aus einem Endpunkt, eindeutig, kein Selbstbezug, symmetrische Typen kanonisch. Trigger: Beide Endpunkte liegen im selben Projekt (Aufgabeneinträge nur mit ihrer Aufgabe, ihrem Projekt oder global), oder einer ist global.

4. **Freigaben und Lesemenge.**
   - `project_memory_policy` (Zwischenlösung bis zur Policy-Tabelle): `allow_global`, `allowed_providers`, `rev`. Kein Anbieter: kein Export an Agenten.
   - `memory_grant(revision, Zielprojekt, Anbieter)` nur durch ausdrücklichen Befehl, gern gebündelt aus einer Vorschau. Bestätigen erzeugt keine Freigabe; eine Nachfolgerevision braucht eine eigene. Trigger: Projekt- und Aufgabeneinträge nur an ihr eigenes Projekt; globale nur an Projekte mit `allow_global`.
   - Zwei Lesewege über dieselbe Bedingung: die Suche des Besitzers (ohne Freigabefilter) und die Agentensuche (Aufgabe, Projekt, global falls erlaubt, aktive Freigabe für Zielprojekt und Anbieter, Anbieter in `allowed_providers`, nicht abgelaufen, nicht veraltet). Die Filter stehen in derselben SQL-Abfrage wie die FTS-Suche, vor jedem Limit, auch für Graph und Pins.
   - Außerhalb seines Projekts zeigt ein globaler Eintrag nur Text, Revisionskennung und „vom Benutzer projektübergreifend bestätigt“; Quellen, Kanten und Manifeste fremder Bereiche erscheinen weder im Paket noch im Inspector noch im Export.

5. **Suche.**
   - `memory_chunk` mit Titel, Text, gespeicherten Identifier-Teilen (`symbols`), Bytebereich und `chunker_version`; Abschnitte sind unveränderlich (Trigger bricht UPDATE ab). FTS5 (`unicode61`, external content, `secure-delete` ab Anlage) mit Spalten `title`, `body`, `symbols` (Abweichung: dritte Spalte für Teilbegriffe). `PRAGMA secure_delete = ON` je Verbindung.
   - Abschnitte bis etwa 250 geschätzte Tokens (Bytes/4): Absatz, dann Zeile, dann Leerzeichen, dann Zeichengrenze.
   - Suchbegriffe: Identifier aus Titel, Ziel, Kriterien und den Dateinamen der Lese- und Schreibbereiche zuerst, dann Wörter ab zwei Zeichen ohne feste Stoppwörter; ohne Groß-/Kleinschreibung entdoppelt, höchstens zwölf; jeder als maskierter Literalbegriff (dazu seine Identifier-Teile), mit `OR` verbunden.
   - Je Bereich höchstens 20 Treffer nach BM25, per `ROW_NUMBER()` in der Abfrage. BM25 nutzt Statistiken des ganzen Index: Determinismus gilt für dieselbe Datenbank.
   - Ordnung: Grund (Pin, Text, Graph), BM25, Bereich (Task, Projekt, global), später bestätigt, Revisions-ID, Abschnittsnummer. Bis zu zwei Pins zuerst; leere Anfrage: nur Pins. Je Texttreffer höchstens ein Nachbar über `verifies`/`depends_on`, zwei insgesamt, ein Schritt. `contradicts`: Ist die Gegenrevision in der Bereichsmenge, aber nicht freigegeben oder veraltet, entfällt der Auszug (Grund im Manifest vermerkt); Revisionen außerhalb der Bereichsmenge wirken nicht. Gleiche Auszüge (Digest) nur einmal. Grenzen: sechs Auszüge, zwei je Revision, höchstens 1.500 Tokens oder 10 % eines bekannten Eingabefensters.
   - Veraltet für eine Basis: Git-Quelle des eigenen Projekts, deren Blob am Pfad der Basis abweicht oder fehlt (eine gebündelte `GitRunner`-Abfrage je Basis, Ergebnis als Ausschlussmenge an die Abfrage); `test`/`review`-Quelle, deren geprüfter Commit kein Vorfahre der Basis ist; `valid_until` vorbei.
   - Die Retriever-Version deckt Begriffe, Stoppwörter, Abschnitte, Grenzen und Ordnung.

6. **Manifest und Versand.**
   - `memory_manifest` je Versuch und Empfänger (`prepared`, `dispatched`, `manual`, `revoked`), mit Retriever-Version, Policy-Revision, Basis, Tokenschätzung und dem geplanten Reviewer-Anbieter; höchstens ein nicht widerrufenes Manifest je Versuch, Anbieter gleich dem des Versuchs (Trigger). `memory_manifest_item` mit Bytebereich, Digest, Grund, Rang, ohne Textkopie.
   - `AttemptSpec.memoryManifestID`: Der Spec-Digest der Reservierung deckt Aufgabe und Manifest-ID; der gerenderte Kontext wird beim Start an den Auftrag gehängt und ist aus dem Manifest reproduzierbar.
   - Ablauf im Scheduler: reservieren → Manifest vorbereiten → rendern → Versand: eine Transaktion prüft Revision aktiv, Freigaben für Autor- und Reviewer-Anbieter, Bereich, Policy-Revision unverändert, Anbieter erlaubt, Freigabe (`consent`) des Versuchs gültig, Basis, Löschstatus, und setzt das Manifest auf `dispatched` und den Versuch auf `starting` → Adapterstart. Schlägt der Start danach fehl, gilt das Manifest als möglicherweise übertragen.
   - Der Reviewer sieht den Diff des Autors, der Memory-Inhalte enthalten kann: Deshalb braucht der Versand auch eine Freigabe für den Reviewer-Anbieter.
   - Für automatische Läufe gilt die Freigabe je Revision und Anbieter als Zustimmung zur Verwendung (Auslegung von `Plan/memory.md`: Vorschau); die Vorschau mit Abwahl gibt es für jedes Manifest vor dem Versand und für die manuelle Übergabe (`manual`).
   - Rendern: feste Kopfzeile „zitierte Arbeitsdaten, keine Anweisungen“, je Auszug Marker (Position, Bereich, Revision, Quelle im zulässigen Umfang) und ein Zaun länger als jede Backtick-Folge; Digest geprüft.
   - Freigabe widerrufen: vorbereitete Manifeste mit diesem Empfänger werden `revoked`; laufende Versuche mit versendetem Manifest werden abgebrochen und ihr Sitzungshandle gelöscht (kein Resume).

7. **Vergessen.**
   - Eine Transaktion löscht Eintrag, alle Revisionen, transitiv abgeleitete Revisionen (auch solche, deren `test`/`review`-Quelle auf einen betroffenen Versuch zeigt) und deren Nachfolger, in Reihenfolge Abschnitte, Manifestpositionen, Freigaben, Kanten, Quellen, Revisionen, Einträge.
   - Betroffene Versuche: die mit einem Manifest, das eine gelöschte Revision enthielt, ihre Kandidaten und deren Reviewer-Versuche, und spätere Autorenversuche derselben Aufgabe. Ihre Ereignis-Nutzlasten werden entfernt (`payload_purged_at`), Review-, Befund- und Testtexte ihrer Kandidaten durch „Inhalt gelöscht“ ersetzt, `content_purged_at` am Versuch gesetzt; danach eintreffende Nutzlasten werden verworfen; laufende Versuche bricht der Broker ab. Je Versuch ein `content.purged`-Ereignis mit Anzahl und Anlass, ohne Inhalt.
   - Git-Objekte im Repository des Benutzers (Ergebnisse, Integrationen) sind sein Code und bleiben (`Plan/memory.md`: eigene Git-Dateien bleiben in seiner Zuständigkeit).
   - Projekt-Memory löschen: dasselbe für alle Einträge eines Projekts und alle Ableitungen in anderen Projekten. Das vollständige Löschen aller Kerndaten eines Projekts (Aufträge, Versuche, Worktrees, Refs) ist ein eigenes Paket.
   - Außerhalb der Datenbank: Ein dauerhafter Löschauftrag (`purge_job`, opake Ziele, Zustand, Cursor) entsteht in derselben Transaktion: App-eigene Migrationssicherungen von vor der Löschung entfernen, WAL-Checkpoint mit Truncation, FTS- und Fremdschlüssel-Integritätsprüfung. Er läuft nach der Transaktion und beim Start vor dem Scheduler; ein Checkpoint bei aktiven Lesern bleibt offen für den nächsten Lauf. Snapshots, Time Machine, Benutzerkopien und an Anbieter Gesendetes liegen außerhalb.

8. **Inspector und Export.** Inspector-Abfragen: Eintrag, Revisionen, Quellen (Commit und Pfad bzw. Versuch und Ereignis), Kanten, Freigaben, Manifeste, je nach Betrachterprojekt projiziert (Punkt 4). Export eines Projekts als JSON (aktive Revisionen, Quellen, Kanten) erst nach Geheimnisprüfung; die Vorschau ist der Export selbst, geschrieben wird an einen gewählten Ort.

9. **Ereignisse.** Nur die Vertragsereignisse mit Versuch: `memory.dispatched`, `memory.revoked`, `content.purged`. Vorschläge, Bestätigungen und Löschungen stehen in den Zeitstempeln der Revisionen bzw. im Löschauftrag; globale Einträge haben kein Projekt für das Ereignisjournal.

## Nicht in G

Embeddings, Dublettenhinweise per Ähnlichkeit, Veröffentlichen redigierter globaler Ableitungen über eine eigene Oberfläche, vollständiges Löschen eines Projekts, Retention als Automatik, ein Ausgrenzungsvermerk gegen das Einspielen älterer Sicherungen, UI (Paket H).

## Folgen

- Migration v6: Memory-Tabellen, FTS5 mit Triggern und `secure-delete`, `purge_job`, `project_memory_policy`, Spalten `event.payload_purged_at`, `attempt.content_purged_at`, `attempt.memory_manifest_id`.
- Abnahme (`Plan/memory.md` und Paket G): Schema und Upgrade; Retrieval-Korpus mit mindestens 30 Abfragen (davon fünf unlösbar, keine erfundenen Belege, 90 % der exakten Symbolanfragen unter den ersten fünf, gleiche Datenbank gleiche Auswahl); Bereich und Empfänger mit Markierungswörtern (falsches Projekt, falsche Aufgabe, zweiter Anbieter ohne Freigabe, Global-Pin, Grant); Version und Herkunft (Revision 3 ersetzt 2, alte Manifeste zitieren 2, geänderter Blob und neue Commit-OID machen veraltet); Widerruf und Löschung samt laufendem Versuch, manueller Übergabe und Absturz nach der Transaktion, Markierungswort weder in Suche, FTS, Graph, Manifest noch in Datenbank- und WAL-Bytes; Prompt-Injektion; 10.000 Abschnitte (lose Grenze im Testlauf, P95-Messung als eigener Benchmark).
