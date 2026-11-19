# ADR 0001 · System-SQLite3 statt GRDB

**Status:** angenommen, 19. November 2026 · **Ändert:** ADR 03 „Persistenz“ in `Plan/ARCHITEKTURPLAN.md`

## Kontext

ADR 03 sieht GRDB als schmalen Swift-Zugriff auf SQLite vor, gepinnt nach einem Swift-6-Buildtest. Für Paket B (lokaler Kern) soll das Repository zunächst ohne externe Paketabhängigkeit bauen. Der Plan nennt das direkte SQLite-C-API selbst als Alternative: Es spart die Paketabhängigkeit, erhöht aber den Aufwand für Ownership und Migrationen.

## Entscheidung

`Storage` nutzt die SQLite3-Bibliothek von macOS (`import SQLite3`, SQLite 3.54 auf dem Entwicklungsrechner) über einen kleinen internen Wrapper (`SQLiteConnection`). Er ist bewusst knapp: Verbindung, Parameterbindung, Abfragen, `BEGIN IMMEDIATE`-Transaktionen und Online-Backup. Migrationen, Prüfsummen und das Backup vor einem Upgrade sind selbst implementiert (`Migrator`).

Die Vorgaben aus dem Laufzeitvertrag gelten unverändert:

- `foreign_keys=ON` pro Verbindung, WAL, `synchronous=FULL` und ein Busy-Timeout
- ein serieller Writer: der `Store`-Actor, ohne `await` zwischen Prüfung und Commit
- `STRICT`-Tabellen und CHECKs auf Enum-Spalten

## Folgen

- Keine Paketabhängigkeit; `swift build` funktioniert offline.
- Statement-Caching, Row-Decoding, Observation und Connection-Pools fehlen. Sie werden erst gebaut, wenn eine Messung (Plan, Messziele der Beta) sie verlangt.
- Die SQLite-Version folgt der macOS-Version. `STRICT`-Tabellen und partielle Indizes prüfen die Tests von Paket B. FTS5 wird mit Paket G (Memory) geprüft, bevor das Schema es nutzt.

## Neubewertung

Ein Wechsel zu GRDB ist angebracht, wenn eine dieser Bedingungen eintritt:

- Der Wrapper wächst über Verbindung, Abfrage und Migration hinaus, zum Beispiel um Observation für die UI oder einen Lese-Pool.
- Ein Bug im eigenen Binding- oder Transaktionscode kostet mehr als die Pflege der Abhängigkeit.

Der Wechsel betrifft nur `Storage`; das Schema und die Migrationsversionen bleiben gleich.
