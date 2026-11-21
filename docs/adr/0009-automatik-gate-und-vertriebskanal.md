# ADR 0009 · Automatik-Gate und Vertriebskanal

**Status:** vorgeschlagen, 21. November 2026; Abnahme durch den Kontoinhaber offen · **Betrifft:** `Plan/paket-i.md` Stufe 0.1, Paket A, ADR 0003 §1, ADR 0005 §7 und §10, ADR 0008 §2

## Kontext

Paket A verlangt: „Offene Drittanbieter-Automation bleibt per Capability gesperrt.“ Seit dem abschließenden Live-Lauf (ADR 0008) sind Claude 2.1.329 und Codex 0.170.0 `liveVerified`, und das Gate des Schedulers ließ damit mehr zu als gewollt:

- `CompatibilityGate.allowsAutomatic` fragte nur, ob es für den Anbieter **irgendeinen** `liveVerified`-Eintrag gibt. Ein Drittnutzer mit genau diesem Programm wäre automatisch geroutet worden; mit einem anderen Programm reservierte der Scheduler und scheiterte erst beim Start an `AdapterPolicy.check` (Fehlstart, Wiederholung, Benutzerentscheidung).
- Ob die OS-Isolation auf diesem Mac wirkt (`Confinement.probe`), prüfte nur das Onboarding; erzwungen wurde es nicht.
- Ob eine Anmeldung ein reines Abo ist, prüfte vor automatischen Starts niemand.
- `accessRestored` nach einer Quota-Sperre gab immer `true` zurück.

## Entscheidungen

1. **Vertriebskanal im Build.** `DistributionChannel` hat zwei Werte: `personal` (der eigene Build des Kontoinhabers) und `distributed` (jeder Build, der den Mac des Kontoinhabers verlassen kann).
   - Die App liest den Kanal aus ihrer Info.plist, Schlüssel `KAIORXDistributionChannel`. Er kommt aus der Build-Einstellung `KAIORX_DISTRIBUTION_CHANNEL` über `Signing/KAIORX-Info.plist`, die Xcode mit der erzeugten Info.plist zusammenführt: Debug `personal`, Release `distributed`.
   - **Schließt im Zweifel:** Fehlt der Schlüssel, ist er unbekannt, nicht ersetzt (`$(KAIORX_DISTRIBUTION_CHANNEL)`) oder anders geschrieben, gilt `distributed`. Auch die Standardeinstellung von `AppConfiguration` ist das Gate eines vertriebenen Builds.

2. **Der Release-Build des Kontoinhabers ist `distributed`.** Das gilt auch für die eigene, notarisierte Kopie. `scripts/release.sh` setzt den Kanal ausdrücklich und verweigert das Signieren, wenn die gebaute Info.plist etwas anderes nennt. Ein signiertes, notarisiertes Programm weiß nicht, wer es startet, und kann weitergegeben werden. Automatik nutzt der Kontoinhaber in seinem lokal gebauten Debug-Build (`personal`), der nie mit Developer ID signiert oder notarisiert wird. Automatik in einem vertriebenen Build ist Sache von I.4 und braucht eine Anbieterfreigabe (Punkt 3).

3. **Anbieterfreigabe (`ProviderClearance`).** Im vertriebenen Kanal startet kein echter Anbieter (Claude, Codex) automatisch ohne eine gültige Freigabe für diesen Anbieter.
   - Ein Eintrag nennt Anbieter, Kanal, Umfang, das Freigabedokument unter `docs/provider-clearance/`, dessen SHA-256 und den letzten gültigen Tag (`YYYY-MM-DD`, UTC; ein fehlerhaftes Datum gilt nie).
   - **Die Liste ist leer.** Einträge fügt nur der Kontoinhaber hinzu, mit dem redigierten Dokument des Anbieters, wie bei `matrix.patch`; nie ein Agent.
   - Ein Test prüft bei jedem Build jeden Eintrag gegen sein Dokument (vorhanden, unverändert, unter `docs/provider-clearance/`, Kanal `distributed`, Umfang genannt, Datum lesbar), entsprechend `everyMatrixEntryHasConsistentEvidence`.
   - Ohne Freigabe liest das Gate im vertriebenen Kanal nichts über die Installation: kein `--version`, keine Anmeldeprüfung.

4. **Prüfung vor der Reservierung (`AutomationGate`).** Der Scheduler fragt das Gate vor jeder automatischen Reservierung (Akteur `scheduler`), billig zuerst:
   1. Kanal und Freigabe (Punkt 3).
   2. Das **installierte** Programm: Version und SHA-256 über `BinaryIdentity`, zwischengespeichert je aufgelöstem Pfad und Dateisignatur (Gerät, Inode, Größe, Änderungszeit). Es nutzt den Zwischenspeicher, mit dem der Adapter auch startet (`installedIdentity()`).
   3. Ein `liveVerified`-Matrixeintrag für diese Version, der genau diesen Build nennt. Gate und `AdapterPolicy.check` nutzen dieselbe Prüfung (`CompatibilityMatrix.liveVerification`). Ein `liveVerified`-Eintrag ohne Build-SHA gibt nichts mehr frei; heute hat jeder einen (Evidenztest).
   4. Das letzte Ergebnis von `Confinement.probe` ist `effective` (Punkt 5).
   5. Die Abo-Vorprüfung meldet `subscription` (Punkt 6).

   Scheitert eine Stufe, reserviert der Tick nichts. Die Aufgabe wartet mit `awaitingUserStart` und einem stabilen Grund nach dem Anbieter, zum Beispiel `claude:versionNotLiveVerified:2.1.330`, `codex:channel:distributed`, `claude:confinement`, `claude:subscription:signedOut`. Der Grund enthält nur Codes und Versionen, keine Meldungstexte und keine Plannamen; ein unveränderter Grund schreibt deshalb keine neue Entscheidung. Die Oberfläche zeigt ihn als Satz („Wartet auf deinen Start: Die installierte Version Claude 2.1.330 ist nicht live abgenommen“). Der Benutzer kann wie bisher selbst starten. So gibt es keine Schleife aus Reservieren und Scheitern mehr.

5. **Isolation erzwingen.** `Confinement.probe` läuft beim Start der App (in `AppBootstrap`, sobald im Kanal überhaupt Automatik möglich ist), sonst vor dem ersten automatischen Start und auf Anforderung (`refreshConfinement`). Jede Sandbox-Prüfung des Onboardings gilt ebenfalls als letztes Ergebnis. Nicht geprüft oder nicht wirksam heißt: keine Automatik.

6. **Abo-Vorprüfung.** Vor automatischen Starts liest das Gate das Abo-Urteil: bei Claude `claude auth status --json` (`ClaudeCodeAdapter.authStatus`), bei Codex `account/read` (`CodexAppServerAdapter.inspect`). Das ist die Produktvorprüfung, die ADR 0008 §2 erlaubt: keine Inferenz, keine Anmeldung, dieselbe Umgebung und Isolation wie ein Reviewer-Versuch, ein eigener temporärer Ordner, der danach entfernt wird.
   - Nur `subscription` lässt starten; `signedOut`, `otherBilling`, `unclear` und jeder Fehler beim Lesen sperren.
   - Das Urteil gilt fünf Minuten, auch ein negatives. Damit läuft die Prüfung nicht bei jedem Tick, und eine Abmeldung stoppt die Automatik spätestens nach dieser Zeit. Gleichzeitige Anfragen teilen sich einen Lesevorgang.
   - Gelesen wird nur, wenn alle billigeren Stufen bestanden haben.
   - Alle Quellen des Gates (installiertes Programm, Sandbox-Prüfung, Abo-Urteil) sind injizierbar. Tests nutzen Attrappen und erreichen nie die echten Programme. Erst `prepare` beim Start der App bindet die echten Adapter.

7. **Echtes `accessRestored`.** Nach Ablauf einer Quota-Sperre durchläuft das Gate zuerst dieselben billigeren Stufen wie vor einer Reservierung (Punkt 4, Stufen 1 bis 4: Kanal und Freigabe, installierter Build mit `liveVerified`-Eintrag, wirksame Isolation). Erst wenn alle bestanden haben, liest es das Abo-Urteil neu, am Zwischenspeicher vorbei, und hebt die Sperre nur bei `subscription` auf.
   - Scheitert eine billigere Stufe, ist der Zugang nicht wiederhergestellt, ohne dass das Abo-Urteil gelesen wird. Im vertriebenen Kanal ohne Freigabe liest das Gate auch hier nichts über die Installation (Punkt 3), auch wenn die Sperre aus einem Benutzerstart stammt.
   - Sonst folgt wie in ADR 0005 §10 eine zeitlich begrenzte Sperre mit Verdopplung bis zum Höchstwert; die Prüfung läuft also nicht bei jedem Tick, sondern erst nach Ablauf der erneuerten Sperre.
   - Ohne gebundene Adapter oder ohne Adapter für den Anbieter ist der Zugang nicht wiederhergestellt.

8. **Benutzerstarts bleiben erlaubt**, in jedem Kanal. Ein ausdrücklicher Start fragt das Gate nicht. Beim Start selbst gilt weiter `AdapterPolicy` (ADR 0003 §1): Es läuft nur ein live abgenommener Build, und nur isoliert. Reviews startet heute nur der Benutzer; der Scheduler reserviert keine.

9. **Einfache Gates.** `CapabilityGate` hat jetzt `automaticVerdict` und `prepare`; beide haben Standardumsetzungen. Ein Gate, das nur `allowsAutomatic` beantwortet, sperrt mit dem Grund `<anbieter>` wie bisher. Das UI-Test-Gate bleibt unverändert.

## Abweichungen von früheren Entscheidungen

- **ADR 0005 §7:** „Automatische Starts brauchen … produktiv `liveVerified` in der Kompatibilitätsmatrix“ heißt jetzt: Kanal und Freigabe, der installierte Build mit `liveVerified`-Eintrag, wirksame Isolation und ein frisches Abo-Urteil, alles vor der Reservierung.
- **ADR 0005 §10:** Die Zugangsprüfung nach einer Sperre ist das Abo-Urteil, nicht mehr eine Annahme.
- **ADR 0003 §1:** Ein `liveVerified`-Eintrag ohne Build-SHA gibt keinen Build mehr frei.
- `task.wait_reason` bleibt freier Text; der neue Grund ist ein längeres Detail von `awaitingUserStart`. Keine Migration.

## Nicht in 0.1

Erwartete Kontoidentität beim Abo-Urteil (braucht eine Migration, ADR 0008 „Nicht in A“); Einwilligung v2 mit Hintergrund-Umfang; Selbsttest der Isolationsproben pro Mac (0.5, I.4); manuelle Übergabe für Claude (`RunMode.manual`) und der freigegebene vertriebene Modus (I.4). Ein ausdrücklicher Benutzerstart mit nicht abgenommenem Build scheitert weiter erst beim Adapterstart; eine Vorprüfung dafür gehört zur manuellen Übergabe.

## Folgen

- Neu: `DistributionChannel`, `ProviderClearance`, `ClearanceCheck` (Providers), `AutomationGate`, `AutomationBlock`, `GateContext` (Orchestration), `Signing/KAIORX-Info.plist`. `CompatibilityGate` entfällt.
- `AppBootstrap` übergibt dem Gate die laufenden Adapter, bevor der Scheduler entsteht; die App wählt das Gate nach ihrem Kanal und meldet dem Gate jede Sandbox-Prüfung des Onboardings.
- `scripts/release.sh` baut nur noch den vertriebenen Kanal. Ein vertriebener Build startet Claude und Codex nie automatisch, bis der Kontoinhaber eine Freigabe einträgt.
- Im persönlichen Kanal läuft eine abgenommene, isolierte und per Abo angemeldete Installation wie bisher automatisch; Tests in virtueller Zeit prüfen beide Kanäle.
