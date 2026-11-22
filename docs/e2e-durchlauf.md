# Gesamtdurchlauf mit echten Anbietern (Stufe 0.7)

Anleitung für den Kontoinhaber. Sie führt einmal durch die ganze Kette in der App: Projekt, Testprofil, Auftrag, Zustimmung, automatischer Autorenlauf, Versiegeln und Bauen, Tests, Review beim anderen Anbieter, Freigabe, Veröffentlichung und Lieferbranch. Dabei laufen der **echte Claude Code** und der **echte Codex** im **Debug-Build** der App.

- **Stand:** Branch `feat/live-kit-package-a` mit den Modellprofilen aus der Live-Abnahme, ADR 0009, 0010, 0011 und 0012.
- **Wer:** nur der Kontoinhaber, von Hand, auf dem eigenen Mac. Claude Code, Codex, Skripte und CI führen diese Schritte nicht aus (`CLAUDE.md`).
- **Dauer:** Hauptweg etwa 60 bis 90 Minuten, die optionalen Teile je 15 bis 30 Minuten.
- **Wozu:** Der Durchlauf ist die Datenquelle für die Nachweise von I.1, I.3 und I.4 (`Plan/paket-i.md`, Stufe 0.7). Die Daten bleiben deshalb in der echten Datenbank.

> **Modellprofile kommen aus der Live-Abnahme (ADR 0012).** Beim Start registriert die App aus dem committeten Bericht `20261120-1429-a265` vier Profile: Claude 2.1.329 mit `sonnet` und Codex 0.170.0 mit `gpt-6.2-sol`, je als Autor und Prüfer, Stufe `standard`. Trage Profile **nicht** von Hand in die Datenbank ein.
>
> - Hat sich Claude oder Codex selbst aktualisiert, bleiben die Profile nutzbar. Die Aufgabe wartet dann mit „Wartet auf deinen Start: … nicht live abgenommen“, nicht mit „Kein passendes Modellprofil“. Dann brauchst du zuerst eine neue Live-Abnahme; nach dem Commit ihres Patches startest du KAIORX neu.
> - Nur Aufgaben der Stufe `intensive` (oder eine Eskalation dorthin) warten mit „Kein passendes Modellprofil“: Für diese Stufe ist noch kein Modell abgenommen.

## 1 Protokoll führen

Lege vor dem Start eine Protokolldatei **außerhalb** des Wegwerf-Repositories an, zum Beispiel `~/kaiorx-e2e-protokoll.md`. Trage jeden Schritt der Checkliste (Abschnitt 20) als eine Zeile ein:

| Zeit | Schritt | Erwartet | Beobachtet | OK / Abweichung | Bild |
|---|---|---|---|---|---|
| 14:05 | E8.3 | Aufgabe „Wartet auf deine Zustimmung“ | wie erwartet | OK | – |
| 14:07 | E10.1 | Lauf „Läuft“ | „Wartet auf deinen Start: Dieser Build von Claude 2.1.329 ist nicht live abgenommen“ | Abweichung | `e10-1.png` |

- **Zeit:** Uhrzeit, zu der du das Ergebnis gesehen hast (nicht die des Klicks). Bei Wartezeiten beide Zeiten notieren.
- **Erwartet:** steht in dieser Anleitung jeweils hinter „Erwartet“. Kopiere den Text oder schreibe nur „wie erwartet“.
- **Beobachtet:** wörtlich den Status- oder Meldungstext der App, nicht deine Deutung.
- **Bildschirmfoto nur bei Abweichung** (⇧⌘4, Leertaste, Fenster). Prüfe es vor dem Weitergeben auf E-Mail-Adressen, Kontonamen und fremde Fenster.
- Eine Abweichung ist kein Grund zum Abbruch. Mach weiter, solange der nächste Schritt noch erreichbar ist, und notiere, wie du weitergekommen bist.

## 2 Sicherheit: Was KAIORX schreibt

- **Dein Checkout** (Arbeitsdateien, Index, `HEAD`) wird nur an zwei Stellen geschrieben:
  - durch **„Sichern“ im Editor**, das du selbst auslöst (ADR 0007);
  - durch den **Lieferbranch**, den du ausdrücklich anlegst. Er legt nur einen neuen Branch (`refs/heads/…`) an, ändert aber weder den ausgecheckten Branch noch Arbeitsdateien oder Index.
- **Im Repository** legt KAIORX außerdem eigene Refs unter `refs/kaiorx/` an:
  - `integrations/<Auftrag>` für den Integrationsstand;
  - `results/<Lauf>` für versiegelte Ergebnisse;
  - `candidates/…` für Kandidaten-Pins.

  Dazu kommt Worktree-Verwaltung in `.git/worktrees/`. Die Worktrees selbst liegen unter `~/Library/Application Support/KAIORX/workspace/`, nicht in deinem Repository. KAIORX pusht nie.
- **Agenten** arbeiten in eigenen Worktrees unter OS-Isolation (`sandbox-exec`, ADR 0002) mit verborgenem Benutzerordner. Prüfer arbeiten schreibgeschützt.
- **Release-Builds starten Anbieter nie automatisch.** Ein Release-Build ist immer `distributed`, und ohne Anbieterfreigabe wartet jede Aufgabe auf deinen Start (ADR 0009). Automatik gibt es nur im selbst gebauten Debug-Build (`personal`). Dieser Durchlauf nutzt deshalb den Debug-Build.
- **Entscheidungsblätter:** Return und Escape wählen immer die sichere Wahl („Nicht jetzt“, „Nicht zustimmen“, „Nicht bestätigen“ …), nie die Freigabe. Klicke Freigaben mit der Maus oder mit Tab und Leertaste.
- Führe die Schritte dieser Anleitung nicht über Claude Code oder Codex aus. Starte die App selbst, und tippe die Terminalbefehle selbst in Terminal.app.

## 3 Tastenkürzel

| Kürzel | Wo | Wirkung |
|---|---|---|
| ⌘O | Menü „Ablage“ | „Projekt öffnen …“ |
| ⇧⌘N | Menü „Ablage“ | „Neuer Auftrag …“ |
| ⌥⌘T | Menü „Ablage“ | „Testprofile …“ |
| ⌥⌘M | Menü „Fenster“ | Monitor öffnen |
| ⌘. | Menü „Lauf“ | „Ausgewählten Lauf abbrechen“ (Aufgabe mit laufendem Lauf muss gewählt sein) |
| ⇧⌘D | Aufgabendetail | „Zustimmung erteilen …“ bzw. „Entscheiden …“ |
| ⇧⌘E | Ergebnis-Kasten | „Ergebnis entscheiden …“ |
| ⇧⌘T | Kandidat, Abschnitt „Tests“ | „Tests ausführen“ |
| ⌥⌘R | Kandidat, Abschnitt „Review“ | „Review starten …“ / „Review erneut starten …“ |
| ⇧⌘K | Kandidat, Abschnitt „Konflikte“ | „Konflikte lösen …“ |
| ⇧⌘R | veröffentlichter Kandidat | „Zurücknehmen …“ |
| ⇧⌘B | Aufgabenliste des Auftrags | „In Branch liefern …“ |
| ⌘S | Editor | „Sichern“ (schreibt in deinen Checkout) |
| Return / Esc | jedes Entscheidungsblatt | sichere Wahl, nie die Freigabe |

Ohne Kürzel: „Freigeben …“, „Ablehnen …“, „Review einfügen …“, „Übernahme erneut versuchen“, „Erneut versuchen“.

## 4 Voraussetzungen

### 4.1 Debug-Build

In Terminal.app, im KAIORX-Repository:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project KAIORX.xcodeproj -scheme KAIORX -configuration Debug \
  -skipPackagePluginValidation -derivedDataPath build/DerivedData build
/usr/libexec/PlistBuddy -c 'Print :KAIORXDistributionChannel' \
  build/DerivedData/Build/Products/Debug/KAIORX.app/Contents/Info.plist
```

- **Erwartet:** Der Build endet mit `** BUILD SUCCEEDED **`, und die letzte Zeile lautet `personal`.
- Steht dort `distributed` oder `$(KAIORX_DISTRIBUTION_CHANNEL)`, ist es der falsche Build: Es würde nichts automatisch starten.
- `build/` ist nicht versioniert. Der Ordner braucht etwa 1 bis 2 GB.

### 4.2 Claude Code und Codex: Version, Build, Anmeldung

Automatisch starten nur **genau** die live abgenommenen Builds (`Packages/KAIORXKit/Sources/Providers/Compatibility.swift`). Es zählen Version **und** SHA-256 des nativen Programms:

| Anbieter | Version | SHA-256 des nativen Programms | Anmeldung |
|---|---|---|---|
| Claude Code | 2.1.329 | `8c1729568b19cdadedd0a978bf692f9f279ef554c8a333c4e132b94fd8725550` | Abo |
| Codex | 0.170.0 | `9248cfeebec9b4cc3034d5114caab10fbf426cbfa79dba410c5fa1b72762abd6` | ChatGPT-Anmeldung über die CLI |

Die App sucht die Programme in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.npm-global/bin`, `~/.claude/local` und zuletzt in den nvm-Versionen (neueste zuerst). Der erste Treffer gilt. Prüfe beide in Terminal.app:

```sh
claude --version        # erwartet: 2.1.329 (Claude Code)
codex --version         # erwartet: codex-cli 0.170.0
shasum -a 256 "$(realpath "$(command -v claude)")"
CODEX_PKG="$(dirname "$(dirname "$(realpath "$(command -v codex)")")")"
shasum -a 256 "$CODEX_PKG/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
```

- **Erwartet:** beide Prüfsummen wie in der Tabelle.
- Weicht eine ab, startet dieser Anbieter weder automatisch noch auf deinen Start („Dieser Build von … ist nicht live abgenommen“). Dann brauchst du zuerst eine neue Live-Abnahme (`docs/live-acceptance/README.md`).
- **Selbst-Update von Claude Code:** Claude Code hat sich schon einmal selbst aktualisiert (2.1.328 → 2.1.329). Nutze Claude Code während des Durchlaufs nicht nebenbei, oder setze vorher in deiner Shell `export DISABLE_AUTOUPDATER=1`. Prüfe die Version vor Schritt 9 noch einmal.

**Anmeldung in KAIORX' eigenen Konfigurationsordnern.** KAIORX nutzt nicht `~/.claude` oder `~/.codex`, sondern eigene Ordner unter Application Support (dieselben wie bei der Live-Abnahme). Prüfe den Stand dort:

```sh
SUPPORT="$HOME/Library/Application Support/KAIORX"
CLAUDE_CONFIG_DIR="$SUPPORT/claude-config" claude auth status
CODEX_HOME="$SUPPORT/codex-home" codex login status
```

- **Erwartet:** Claude ist mit dem Abo angemeldet (kein API-Schlüssel), Codex mit ChatGPT.
- Die Ausgabe enthält deine E-Mail-Adresse. Gib sie nicht weiter; notiere nur „angemeldet, Abo“.
- **Nicht angemeldet:** Nutze die Befehle, die das Onboarding der App unter „Befehl kopieren: …“ anbietet (Schritt 5):
  - Claude: `CLAUDE_CONFIG_DIR='…/claude-config' claude`, dort anmelden und mit `/exit` beenden, ohne eine Anfrage zu schicken;
  - Codex: `CODEX_HOME='…/codex-home' codex login`.
- **Zusatzguthaben ausschalten:** Schalte bei beiden Anbietern das Zusatzguthaben aus (Claude: usage credits; ChatGPT: Guthaben für andere Apps oder ein App-Limit unter 100 %). Ein Konto, das nicht nur über das Abo abrechnet, sperrt die Automatik („… rechnet nicht nur über das Abo ab“).

### 4.3 Wegwerf-Repository

Ein kleines eigenes Repository mit einer trivialen Aufgabe und einem winzigen Test. Lege es nicht in `/tmp` an, damit es einen Neustart übersteht:

```sh
mkdir -p ~/kaiorx-e2e && cd ~/kaiorx-e2e
git init -q -b main
printf '# KAIORX E2E\n\nWegwerf-Repository für den Gesamtdurchlauf.\n' > README.md
cat > check.sh <<'EOF'
#!/bin/sh
# Prüft hallo.txt nur, wenn es die Datei gibt.
if [ -f hallo.txt ]; then
  grep -qx 'Hallo Welt' hallo.txt
fi
EOF
git add -A && git commit -qm start
printf 'nicht committet\n' > lokal.txt     # bleibt absichtlich uncommittet
```

- `lokal.txt` ist eine uncommittete Datei im Checkout. An ihr siehst du am Ende, dass KAIORX den Checkout nicht anfasst.
- Der Integrationsstand eines Auftrags beginnt beim `HEAD`, den der Checkout beim Anlegen des Auftrags hat. Committe also vorher alles, was der Auftrag sehen soll.

### 4.4 Datenbank, Kontingent, Speicherplatz

- **Echte Datenbank:** Der normale Start nutzt `~/Library/Application Support/KAIORX/kaiorx.sqlite`. Fehlt sie, legt die App sie beim ersten Start an. Alles aus diesem Durchlauf bleibt dort und ist so gewollt. Starte die App nur einmal gleichzeitig. Starte sie nicht mit `-KAIORXUITest`; das wäre der Testmodus mit Testanbietern. Rufe `kaiorx-dev` während des Durchlaufs nur mit `--db <tmp>` auf.
- **Kontingent:** Der Hauptweg verbraucht einen Autorenlauf (Erwartung: Claude) und ein Review (Erwartung: Codex). Tests laufen lokal ohne Kontingent. Die optionalen Teile kosten mehr (siehe Abschnitt 18).
  - Meldet ein Anbieter kein Kontingent, erlaubt die Zustimmung höchstens **3 gestartete Läufe je Anbieter**. Bei Claude wurden in der Live-Abnahme keine Kontingentsignale beobachtet. Danach warten Aufgaben mit „Wartet auf das Nutzungslimit“.
  - Das lokale Tokenbudget je Auftrag (Standard 200.000 je Anbieter) zählt KAIORX zusätzlich.
- **Speicherplatz:** einige GB frei: Debug-Build 1 bis 2 GB, dazu Worktrees, Datenbank und Sicherungen. Prüfe mit `df -h ~`.

### 4.5 Checkout vorher festhalten

```sh
cd ~/kaiorx-e2e
{ git rev-parse HEAD; git status --porcelain=v2 --branch; git branch --list; } > ~/kaiorx-e2e-vorher.txt
```

## 5 Start und Onboarding

1. **E5.1** Starte die App:

   ```sh
   open build/DerivedData/Build/Products/Debug/KAIORX.app
   ```

   **Erwartet:** zuerst „KAIORX startet …“, dann die Willkommensseite „Willkommen bei KAIORX“ (solange noch kein Projekt offen ist).

2. **E5.2** Lies die Onboarding-Liste. Die Prüfungen laufen kurz nach dem Start. Sie lesen nur `--version` und prüfen die Sandbox; sie melden sich nirgends an und rufen kein Modell auf. **Erwartet:**
   - „Git“: Bereit, mit dem Pfad.
   - „Claude“: „Version 2.1.329, live abgenommen“.
   - „Codex“: „Version 0.170.0, live abgenommen“.
   - „Claude-Anmeldung“ und „Codex-Anmeldung“: „Wird beim ersten Lauf geprüft“, je mit „Befehl kopieren: …“. Das ist normal: KAIORX liest keine Anmeldedaten.
   - „Schreibschutz für Agenten“: „sandbox-exec wirkt.“ (vorher kurz „Noch nicht geprüft.“).
   - „Projekt“: „Noch kein Projekt geöffnet.“

   Das Onboarding prüft nur die Version, nicht den Build. Die Prüfsumme hast du in 4.2 geprüft.

3. **E5.3** Wenn „Schreibschutz für Agenten“ „Fehlt“ zeigt, startet keine Automatik („Der Schreibschutz für Agenten wirkt nicht“). Notiere den Detailtext und brich ab.

4. **E5.4** **Modellprofile prüfen.** Die Abfrage liest nur:

   ```sh
   sqlite3 -readonly "$HOME/Library/Application Support/KAIORX/kaiorx.sqlite" \
     "SELECT provider, role, tier, model FROM model_profile WHERE verified_at IS NOT NULL AND disabled_reason IS NULL;"
   ```

   **Erwartet:** genau diese vier Zeilen (Reihenfolge egal):

   ```text
   claude|author|standard|sonnet
   claude|reviewer|standard|sonnet
   codex|author|standard|gpt-6.2-sol
   codex|reviewer|standard|gpt-6.2-sol
   ```

   Ist die Ausgabe leer, notiere das als Abweichung: Dann hat der Abgleich beim Start nicht geklappt.

## 6 Projekt öffnen und vertrauen

1. **E6.1** Wähle „Projekt öffnen …“ (⌘O, Willkommensseite oder Werkzeugleiste „Projekt öffnen“). **Erwartet:** ein Ordnerdialog mit dem Text „Wähle ein eigenes Git-Repository.“
2. **E6.2** Wähle `~/kaiorx-e2e` und klicke „Öffnen“. **Erwartet:** das Blatt „Projekt als vertrauenswürdig öffnen?“ mit dem Pfad und dem Hinweis, dass Tests und Werkzeuge mit deinen Rechten laufen. Return wählt „Nicht öffnen“.
3. **E6.3** Klicke „Vertrauen und öffnen“. **Erwartet:** In der Seitenleiste erscheint ein Abschnitt `kaiorx-e2e` mit „Noch kein Auftrag“. In der Mitte steht „Kein Auftrag gewählt“.

## 7 Testprofil anlegen und bestätigen

1. **E7.1** Öffne „Testprofile …“ (⌥⌘T oder Werkzeugleiste „Testprofile“). **Erwartet:** das Blatt „Testprofile für kaiorx-e2e“ mit „Nur bestätigte Profile laufen. Jede Änderung braucht eine neue Bestätigung.“
2. **E7.2** Fülle unter „Profil hinzufügen oder ändern“ aus und klicke „Vorschlagen“:

   | Feld | Wert |
   |---|---|
   | Name | `Prüfung` |
   | Programm | `/bin/sh` |
   | Argumente | `check.sh` (eins pro Zeile) |
   | Arbeitsordner | `.` |
   | Zeitlimit (s) | `60` |
   | Testeingaben | `check.sh` |
   | Darf in den Worktree schreiben (Build-Ausgaben) | aus |

   **Erwartet:** Die Liste zeigt „Prüfung“ mit „Nicht bestätigt“, dem Befehl `/bin/sh check.sh` und „Arbeitsordner . · Zeitlimit 60 s“.
3. **E7.3** Klicke „Bestätigen …“. **Erwartet:** die Seite „Testprofil bestätigen“ mit diesen Angaben:
   - „Befehl: /bin/sh check.sh“, „Arbeitsordner im Worktree: .“, „Zeitlimit: 60 s“;
   - „Schreibt nur in seinen temporären Ordner“, „Testeingaben: check.sh“;
   - die Isolationszeile und „Prüfsumme: …“.

   Return wählt „Nicht bestätigen“.
4. **E7.4** Klicke „Bestätigen“. **Erwartet:** Status „Bestätigt“. Schließe das Blatt mit „Schließen“.

## 8 Auftrag anlegen (der Plan wird dabei angenommen)

Die App hat keinen eigenen Planschritt. „Anlegen“ legt den Auftrag an, schlägt die Aufgaben als Planfassung 1 vor, nimmt sie an, setzt den Auftrag auf „Aktiv“ und legt den Integrationsstand `refs/kaiorx/integrations/<Auftrag>` auf dem `HEAD` deines Checkouts an.

1. **E8.1** Öffne „Neuer Auftrag …“ (⇧⌘N oder Werkzeugleiste „Neuer Auftrag“) und fülle aus:

   | Feld | Wert |
   |---|---|
   | Ziel des Auftrags | `Begrüßungsdatei anlegen` |
   | Titel | `hallo.txt anlegen` |
   | Akzeptanzkriterium | `Es gibt hallo.txt mit genau einer Zeile: Hallo Welt. Sonst ändert sich nichts.` |
   | Schreibbereich (Pfade, durch Komma getrennt) | `hallo.txt` |
   | Tokenbudget je Anbieter | `200000` (Standard) |

   Unter dem Budget steht „Gilt für Claude und Codex in diesem Auftrag.“
2. **E8.2** Klicke „Anlegen“. **Erwartet:** Links erscheint „Auftrag xxxxxx“ (die ersten sechs Zeichen der ID, nicht das Ziel) mit dem Statussymbol „Aktiv“. In der Mitte steht die Aufgabenliste mit „hallo.txt anlegen“ und darüber „Noch nichts veröffentlicht“.
3. **E8.3** Wähle die Aufgabe. **Erwartet:**
   - Spalte „Wartet auf“ und Aufgabendetail: „Wartet auf deine Zustimmung“;
   - im Detail der Knopf „Zustimmung erteilen …“;
   - unter „Läufe“: „Noch kein Lauf“;
   - in der Werkzeugleiste „Entscheidungen (1)“ mit dem Eintrag „hallo.txt anlegen: Wartet auf deine Zustimmung“.

## 9 Zustimmung für Autor und Prüfer

Ein Blatt deckt beide Anbieter ab: jeder als Autor **und** als Reviewer. Der Scheduler startet einen Autor nur, wenn ein unabhängiger Prüfer des anderen Anbieters möglich ist.

1. **E9.1** Prüfe noch einmal `claude --version` (Selbst-Update, 4.2).
2. **E9.2** Klicke „Zustimmung erteilen …“ (⇧⌘D). **Erwartet:** das Blatt „Zustimmung für automatische Läufe“ mit der Aktion „Claude und Codex dürfen Aufgaben dieses Projekts automatisch bearbeiten und prüfen.“ Unter „Geltungsbereich“:
   - „Claude: Rollen Autor, Reviewer; Schreibbereich: das ganze Projekt, je Aufgabe nur ihre Pfade“;
   - dieselbe Zeile für Codex;
   - „Ohne gemeldetes Kontingent höchstens 3 Läufe je Anbieter“;
   - „Gültig bis zum Widerruf“;
   - „Jeder Lauf überträgt freigegebene Inhalte an Claude und Codex.“

   Return wählt „Nicht zustimmen“.
3. **E9.3** Klicke „Zustimmen“. **Erwartet:** Der Wartegrund verschwindet innerhalb von etwa einer Sekunde, und der Lauf startet (Schritt 10).

**Mögliche andere Wartegründe** (je ein Satz in der Spalte „Wartet auf“; notiere den genauen Text):

| Text | Bedeutung |
|---|---|
| „Wartet auf deinen Start: Die installierte Version Claude … ist nicht live abgenommen“ | falsche Version (4.2) |
| „Wartet auf deinen Start: Dieser Build von Claude 2.1.329 ist nicht live abgenommen“ | gleiche Version, anderer Build |
| „Wartet auf deinen Start: Claude ist in KAIORX nicht angemeldet“ | Anmeldung im KAIORX-Ordner fehlt (4.2) |
| „Wartet auf deinen Start: Claude rechnet nicht nur über das Abo ab“ | Zusatzguthaben aktiv |
| „Wartet auf deinen Start: Der Schreibschutz für Agenten wirkt nicht“ | Sandbox-Prüfung gescheitert |
| „Wartet auf deinen Start: Claude startet in dieser Ausgabe von KAIORX nie automatisch (keine Anbieterfreigabe)“ | falscher Build (Release statt Debug, 4.1) |
| „Kein unabhängiger Reviewer verfügbar“ | Zustimmung für den anderen Anbieter fehlt |
| „Kein passendes Modellprofil“ | Aufgabe der Stufe `intensive`; abgenommen ist nur `standard` (ADR 0012) |
| „Wartet auf das Nutzungslimit“ | Kontingent oder die 3-Läufe-Grenze |

Bei „Wartet auf deinen Start: …“ kannst du die Aufgabe selbst starten: „Entscheiden …“ (⇧⌘D), dann das Blatt „Aufgabe starten“ und „Starten“. Ein selbst gestarteter Lauf läuft aber auch nur mit einem live abgenommenen Build. Notiere die Automatik-Abweichung trotzdem.

## 10 Automatischer Lauf und Monitor

1. **E10.1** **Erwartet** im Aufgabendetail unter „Läufe“: „Autor · Claude · sonnet“, nacheinander mit den Status „Reserviert“, „Startet“ und „Läuft“. Die Aufgabe zeigt „Läuft“.
   - Wird Codex Autor, ist das keine Abweichung. Dann prüft in Schritt 13 Claude.
2. **E10.2** Öffne den Monitor (⌥⌘M oder Werkzeugleiste „Monitor“). **Erwartet:**
   - Filter „Offen“ zeigt den Lauf mit Aufgabe, „Claude · sonnet“, Rolle „Autor“, Status „Läuft“ und wachsender Laufzeit;
   - Auswahl des Laufs zeigt rechts den „Verlauf“ mit Ereignissen, die laufend nachkommen.
3. **E10.3** Warte das Ende ab. **Erwartet:**
   - Lauf „Erfolgreich“; im Monitor verschwindet er aus „Offen“ und steht unter „Beendet“;
   - Aufgabe „Ergebnis liegt vor“, im Detail der Kasten „Ergebnis“.
   - Notiere die Laufzeit.
4. **E10.4** Lauf scheitert („Fehlgeschlagen“): Kopiere im Monitor mit „Redigiert kopieren“ den Verlauf (Abschnitt 19). Notiere den Wartegrund der Aufgabe.

## 11 Versiegeln und Bauen (automatisch)

Die Kandidatenkette prüft einmal je Sekunde. Sie versiegelt nur auf dem Host und startet dabei keinen Anbieter.

1. **E11.1** **Erwartet** im Kasten „Ergebnis“, nach wenigen Sekunden:
   1. „Wird versiegelt …“;
   2. „Versiegelt: Commit <12 Zeichen> – Kandidat wird gebaut …“;
   3. „Schreibbereich: hallo.txt“.
2. **E11.2** **Erwartet:**
   - Der Kasten „Ergebnis“ verschwindet, darunter erscheint die Kandidatenansicht „Kandidat <12 Zeichen>“ mit Status „Gebaut“ und „Ziel refs/kaiorx/integrations/<Auftrag> · gegen <12 Zeichen>“.
   - Gate-Zeilen: „Kein grüner Test für …“ und „Kein zustimmendes unabhängiges Review für …“.
   - Dateiliste: `hallo.txt` als neu, mit Diff `+Hallo Welt`.
   - Die Aufgabe zeigt „Wird geprüft“, „Entscheidungen“ enthält „Tests ausführen: hallo.txt anlegen“.
3. **Abweichungen, die die Kette dir überlässt:**
   - „1 Pfad verworfen“ / „Pfade verworfen“: Der Autor hat außerhalb von `hallo.txt` geschrieben. „Ergebnis entscheiden …“ (⇧⌘E) öffnet „Abweichende Änderungen“ mit „Ohne diese Pfade bauen“ und „Nicht bauen“; siehe auch 18.3.
   - „Leer: der Lauf hat nichts geändert“: „Ergebnis entscheiden …“ öffnet „Leeres Ergebnis“ mit „Als erledigt annehmen“. Wähle es nicht, sondern notiere die Abweichung; ein leeres Ergebnis ist hier falsch.
   - „Versiegeln fehlgeschlagen: …“ / „Bauen fehlgeschlagen: …“: Notiere den Text und versuche „Erneut versuchen“. Die Kette wiederholt selbst mit wachsendem Abstand (bis 5 Minuten).
   - „Kandidatenkette nicht verfügbar – Git-Arbeit angehalten“: Die Git-Wiederherstellung beim Start ist gescheitert. Brich ab und schicke die Angaben aus Abschnitt 19.

## 12 Tests ausführen

1. **E12.1** In der Kandidatenansicht steht der Abschnitt „Tests“ mit „Noch kein Testlauf für diesen Commit“ und „Profil: Prüfung“ samt Befehl `/bin/sh check.sh`. Klicke „Tests ausführen“ (⇧⌘T). **Erwartet:** zuerst „Tests laufen …“ und der Kandidat „Tests laufen“, nach wenigen Sekunden „Tests bestanden“ mit „Profil: Prüfung“.
2. **E12.2** **Erwartet:**
   - Kandidat „Im Review“; die Gate-Zeile zum Test ist weg, die zum Review bleibt;
   - Abschnitt „Review“ mit „Noch kein Review“;
   - „Entscheidungen“ enthält „Review starten: hallo.txt anlegen“.
3. **Abweichung** „Tests fehlgeschlagen“: Der Kandidat wird abgelehnt, und die Aufgabe geht zurück an den Autor. Das kostet einen weiteren Autorenlauf. Notiere die Zusammenfassung unter dem Ergebnis.
   - „Tests konnten nicht laufen“ und „Zeitlimit überschritten“ sind kein Urteil über die Änderung: Der Kandidat bleibt „Gebaut“ und lässt sich erneut testen.

## 13 Review beim anderen Anbieter starten

Reviews startet nur der Benutzer (ADR 0009 §8). Ein Review verbraucht Kontingent beim Prüferkonto.

1. **E13.1** Klicke „Review starten …“ (⌥⌘R). **Erwartet:**
   - Abschnitt „Prüfer“ mit einer Zeile je Anbieter. „Codex · gpt-6.2-sol“ ist gewählt; „Claude“ trägt „– Der Prüfer muss von einem anderen Anbieter kommen als der Autor“.
   - Darunter das Blatt „Review starten“ mit diesen Zeilen:
     - „Geprüfter Commit: <voller Commit>“, „Prüfer: Codex · gpt-6.2-sol“;
     - „Autor: Claude – der Prüfer kommt von einem anderen Anbieter“;
     - „Diff und Testbelege gehen an Codex.“;
     - „Der Prüfer arbeitet schreibgeschützt in einem eigenen Worktree.“;
     - „Ein Review verbraucht Kontingent beim Prüferkonto.“
   - Eine Zeile „Automatik (nur zur Information): …“ darf erscheinen; sie sperrt nicht.
   - Return wählt „Nicht jetzt“.
2. **E13.2** Klicke „Review starten“. **Erwartet:** „Review bei Codex gestartet. Das Ergebnis wird übernommen, sobald der Prüfer fertig ist.“ Schließe mit „Fertig“.
3. **E13.3** **Erwartet:**
   - Abschnitt „Review“ zeigt „Review läuft (Codex)“; unter „Läufe“ steht „Reviewer · Codex · gpt-6.2-sol“ mit „Läuft“.
   - Der Monitor zeigt den Lauf mit Rolle „Reviewer“.
   - Ein Lauf im Status „Wartet auf Entscheidung“ ist nicht vorgesehen. Codex-Freigaben entscheidet KAIORX selbst nach Rolle; notiere diesen Status, falls er auftaucht.

## 14 Review übernommen → „Angenommen“

Fertige Reviews sammelt die Kette selbst ein.

1. **E14.1** **Erwartet**, wenige Sekunden nach Ende des Prüferlaufs:
   1. kurz „Review wird übernommen …“;
   2. dann „Zugestimmt“;
   3. der Kandidat „Angenommen“ ohne Gate-Zeilen;
   4. die Aufgabe „Wartet auf Freigabe“;
   5. „Entscheidungen“ enthält „Veröffentlichen: hallo.txt anlegen“, und in der Kandidatenansicht erscheint „Freigeben …“.
2. **Abweichungen:**
   - „Änderungen verlangt“: Der Prüfer hat Befunde gemeldet. Sie stehen unter dem Kandidaten mit „Gemeldet: …“ und „Vorschlag: …“. Befunde, die eine Entscheidung brauchen, haben ein Feld „Begründung“ und die Knöpfe „Annehmen“ und „Zurückweisen“ (blockierende lassen sich nicht annehmen). „Entscheidungen“ zeigt „Befunde entscheiden: …“. Notiere die Schwere, nicht den Text.
   - „Unlesbar“: Das Review nennt nicht genau diesen Commit oder ist nicht lesbar.
   - **„Review nicht übernommen – versuche die Übernahme erneut oder starte ein neues Review“** mit der roten Zeile „Review konnte nicht übernommen werden: …“: Klicke **„Übernahme erneut versuchen“**. Das startet keinen Prüfer und verbraucht kein Kontingent. **Erwartet:** Beim nächsten Durchlauf erscheint „Review wird übernommen …“, dann „Zugestimmt“. Hilft das nicht, notiere den Text. „Review erneut starten …“ startet einen neuen Prüfer und kostet Kontingent.
   - „Prüfer abgebrochen“: Der Prüferlauf ist gescheitert. Hole den Verlauf mit „Redigiert kopieren“; „Review erneut starten …“ ist möglich.

## 15 Freigabe und Veröffentlichung

1. **E15.1** Klicke „Freigeben …“. **Erwartet:** das Blatt „Integration veröffentlichen“ mit der Aktion „Den geprüften Commit <12 Zeichen> auf das Integrationsziel setzen.“ Unter „Geltungsbereich“:
   - „Aufgabe: hallo.txt anlegen“, „Zielref: refs/kaiorx/integrations/<Auftrag>“;
   - „Geprüfter Commit: …“, „Erwarteter bisheriger Stand: …“;
   - „Dein Checkout und deine Branches bleiben unverändert.“

   „Noch offen“ ist leer. Return wählt „Nicht jetzt“.
2. **E15.2** Klicke „Freigeben und veröffentlichen“. **Erwartet:**
   - Kandidat „Veröffentlicht“, Aufgabe „Integriert“;
   - über der Aufgabenliste „Veröffentlichte Kandidaten: 1“;
   - „Entscheidungen (0)“ mit „Nichts wartet auf dich“.
   - Der Auftrag bleibt „Aktiv“: KAIORX schließt Aufträge nicht selbst ab.
   - Die Freigabe gilt 15 Minuten. Bei „Die Freigabe ist abgelaufen. Bitte neu freigeben.“ öffne das Blatt neu.
3. **E15.3** Prüfe in Terminal.app:

   ```sh
   cd ~/kaiorx-e2e
   git for-each-ref --format='%(refname)' refs/kaiorx/
   git show "$(git for-each-ref --format='%(refname)' 'refs/kaiorx/integrations/*' | head -1)":hallo.txt
   git worktree list
   ```

   **Erwartet:**
   - Refs unter `refs/kaiorx/integrations/`, `refs/kaiorx/results/` und `refs/kaiorx/candidates/`;
   - die Ausgabe `Hallo Welt`;
   - Worktrees nur unter `~/Library/Application Support/KAIORX/workspace/`. Fertige Autoren- und Prüfer-Worktrees räumt die Kette nach und nach weg; einige dürfen noch stehen.

## 16 Lieferbranch

1. **E16.1** Klicke über der Aufgabenliste „In Branch liefern …“ (⇧⌘B). **Erwartet:** das Blatt „In neuen Branch liefern“ mit diesen Angaben:
   - das Feld „Name des neuen Branches“, vorbelegt mit `kaiorx/auftrag-xxxxxx`;
   - „Neuer Branch: refs/heads/kaiorx/auftrag-xxxxxx“ und „Integrationsstand: …“;
   - „Veröffentlichte Kandidaten: 1“;
   - „Vorhandene Branches, dein Checkout und dein Index bleiben unverändert; nichts wird gepusht.“

   Return wählt „Nicht liefern“.
2. **E16.2** Klicke „Branch anlegen“. **Erwartet:** „Branch „kaiorx/auftrag-xxxxxx“ angelegt. Dein Checkout und deine anderen Branches sind unverändert.“ Schließe mit „Fertig“.
3. **E16.3** Prüfe:

   ```sh
   git branch --list 'kaiorx/*'
   git show kaiorx/auftrag-xxxxxx:hallo.txt      # erwartet: Hallo Welt
   git log --oneline -3 kaiorx/auftrag-xxxxxx
   ```

## 17 Checkout nachher prüfen

```sh
cd ~/kaiorx-e2e
{ git rev-parse HEAD; git status --porcelain=v2 --branch; git branch --list; } > ~/kaiorx-e2e-nachher.txt
diff ~/kaiorx-e2e-vorher.txt ~/kaiorx-e2e-nachher.txt
cat lokal.txt; ls
```

- **E17.1** **Erwartet:**
  - Der einzige Unterschied ist die neue Zeile `kaiorx/auftrag-xxxxxx` aus `git branch --list`.
  - `HEAD`, der ausgecheckte Branch und der Status (mit dem uncommitteten `lokal.txt`) sind gleich.
  - Im Checkout gibt es **kein** `hallo.txt`; das liegt nur im Integrationsstand und im Lieferbranch.

## 18 Optional

Jeder Teil verbraucht Kontingent. Mit der 3-Läufe-Grenze (4.4) hat Claude nach dem Hauptweg voraussichtlich noch zwei Autorenstarts. Ein abgebrochener Lauf zählt mit, sobald er gestartet ist. Wähle deshalb aus, und wähle bei Reviews möglichst Codex als Prüfer.

### 18.1 Zurücknehmen (Revert)

Kosten: kein Autorenlauf, ein Review.

1. **E18.1.1** Klicke am veröffentlichten Kandidaten „Zurücknehmen …“ (⇧⌘R). **Erwartet:** das Blatt „Veröffentlichung zurücknehmen“ mit diesen Zeilen:
   - „Zurückgenommener Commit: …“;
   - „Der Revert läuft als eigene Aufgabe durch Test, Review und Freigabe; das Ziel ändert sich erst nach deiner Freigabe.“;
   - „Gelieferte Branches, dein Checkout und deine Branches bleiben unverändert.“

   Return wählt „Nicht zurücknehmen“.
2. **E18.1.2** Klicke „Revert bauen“. **Erwartet:** „Der Revert-Kandidat ist gebaut. Er läuft als eigene Aufgabe durch Test, Review und Freigabe; veröffentlicht wird er erst nach deiner Freigabe.“ und der Knopf „Revert-Aufgabe zeigen“.
3. **E18.1.3** Führe die Revert-Aufgabe wie in Schritt 12 bis 15 durch: „Tests ausführen“ (`check.sh` besteht, weil `hallo.txt` dann fehlt), „Review starten …“ mit Codex, „Freigeben …“. **Erwartet am Ende:** Der Revert-Kandidat zeigt „Veröffentlicht“, und `git show <Integrationsref>:hallo.txt` meldet, dass die Datei fehlt. Der Lieferbranch aus Schritt 16 bleibt unverändert. Ohne weiteres Review kannst du den Revert-Kandidaten auch mit „Ablehnen …“ beenden; dann endet die Rücknahme, und die Veröffentlichung bleibt bestehen.

### 18.2 Ablehnen mit Grund und Nacharbeit

Kosten: ein Autorenlauf, danach ein Review.

Das geht mit jedem offenen Kandidaten, zum Beispiel in einem neuen Auftrag wie in Schritt 8 mit `gruss.txt` statt `hallo.txt`.

1. **E18.2.1** Klicke am Kandidaten „Ablehnen …“. **Erwartet:** das Blatt „Kandidat ablehnen“ mit „Die Aufgabe geht zurück zur Überarbeitung; Freigaben dieses Kandidaten werden widerrufen. Die Begründung geht an den nächsten Autor dieser Aufgabe, außer sie sieht nach einem Geheimnis aus.“
2. **E18.2.2** Begründung, zum Beispiel `Bitte zusätzlich eine zweite Zeile: Tschüss`. Klicke „Ablehnen“. **Erwartet:** Kandidat „Abgelehnt“, Aufgabe „Änderungen nötig“ mit „Wartet auf deine Freigabe zur Nacharbeit“ und dem Knopf „Entscheiden …“.
3. **E18.2.3** Klicke „Entscheiden …“. **Erwartet:** das Blatt „Nacharbeit erlauben“ mit „Dein Grund geht an den nächsten Autor: „Bitte zusätzlich …““ und „Jeder Versuch kann beim Anbieter Kontingent und Budget verbrauchen.“ Klicke „Nacharbeit erlauben“. **Erwartet:** ein neuer Autorenlauf startet; das neue Ergebnis enthält die zweite Zeile.

### 18.3 Ergebnis verwerfen mit Grund

„Ergebnis verwerfen …“ gibt es nur für Planaufgaben, und nur wenn das Siegel Pfade verworfen hat (zum Beispiel „1 Pfad verworfen“) oder Versiegeln oder Bauen hängt. Die echten Anbieter schreiben nur in den erlaubten Pfad; das hat die Live-Abnahme geprüft. Ein Pfad außerhalb des Schreibbereichs entsteht deshalb mit ihnen kaum. Lässt sich der Fall nicht herbeiführen, notiere „nicht erreichbar“; das ist kein Fehler.

Tritt er auf:

1. **E18.3.1** Öffne mit „Ergebnis verwerfen …“ (oder im Blatt „Abweichende Änderungen“) das Blatt „Ergebnis verwerfen“. **Erwartet:** die Zeilen „Verworfen: <Pfad> – außerhalb des Schreibbereichs“ und „Die Zählung der Versuche beginnt neu.“ und „Ein neuer Lauf kann Kontingent verbrauchen.“, dazu das Feld „Grund (freiwillig)“. Return verwirft nicht, auch nicht im Grundfeld.
2. **E18.3.2** Klicke „Verwerfen und neu bearbeiten lassen“. **Erwartet:** „Ergebnis verworfen. Die Aufgabe wird neu bearbeitet; die Zählung der Versuche beginnt neu.“ Danach startet ein neuer Autorenlauf, der den Grund im Prompt hat.

### 18.4 Konflikt sicher herbeiführen

Kosten: zwei Autorenläufe, zwei Reviews; zum Lösen keins.

Konflikte entstehen nur innerhalb eines Auftrags. Zwei Aufgaben mit demselben Schreibbereich laufen nacheinander; die Rücknahme der ersten trifft dann auf die Änderung der zweiten. Alles geschieht im Integrationsstand, dein Checkout bleibt unberührt.

1. **E18.4.1** Lege einen neuen Auftrag „Farbe“ mit **„Aufgabe hinzufügen“** und zwei Aufgaben an:

   | Titel | Akzeptanzkriterium | Schreibbereich |
   |---|---|---|
   | `Farbe blau` | `Die erste Zeile von README.md lautet genau: # Farbe: blau. Sonst ändert sich nichts.` | `README.md` |
   | `Farbe grün` | `Die erste Zeile von README.md lautet genau: # Farbe: grün. Sonst ändert sich nichts.` | `README.md` |

   **Erwartet:** Eine Aufgabe läuft, die andere wartet mit „Wartet auf einen freien Schreibbereich“.
2. **E18.4.2** Führe beide wie in Schritt 11 bis 15 bis „Veröffentlicht“.
   - Geht schon die zweite Aufgabe in „Konflikt“, ist das ebenfalls ein gültiger Konfliktfall. Weiter mit E18.4.4; dort heißt die Wahl „Ergebnis übernehmen“.
3. **E18.4.3** Nimm den **zuerst** veröffentlichten Kandidaten mit „Zurücknehmen …“ und „Revert bauen“ zurück. **Erwartet:** „Der Revert hat Konflikte in einer Datei: README.md. Die Revert-Aufgabe steht in „Konflikt“; ohne Auflösung kannst du den Revert ablehnen.“ Klicke „Revert-Aufgabe zeigen“.
4. **E18.4.4** **Erwartet:** Aufgabe „Konflikt“, Kandidat „Konflikt“, Abschnitt „Konflikte“ mit „README.md – Beide geändert“, und „Entscheidungen“ enthält „Konflikt lösen: …“.
5. **E18.4.5** Klicke „Konflikte lösen …“ (⇧⌘K). **Erwartet:**
   - das Blatt „Konflikt lösen“ mit „Integrationsstand: …“, „Rücknahme: …“ (bzw. „Ergebnis: …“) und „README.md: Beide geändert – noch offen“;
   - unter „Noch offen“ die Zeile „Noch ohne Entscheidung: 1 Datei“;
   - je Datei die Wahl „Integrationsstand behalten | Rücknahme übernehmen (Ergebnis übernehmen) | Datei löschen“, ohne Vorauswahl;
   - „Änderungen ansehen“ zeigt „Was der Lauf geändert hat“ und „Was sich im Integrationsstand geändert hat“, beide nur lesend.
6. **E18.4.6** Wähle „Rücknahme übernehmen“ (bzw. „Ergebnis übernehmen“) und klicke „Auflösen und Kandidat bauen“. **Erwartet:** „Konflikt gelöst – Kandidat gebaut. Als Nächstes Tests ausführen.“
   - Mit „Integrationsstand behalten“ käme stattdessen „Nach deiner Auflösung bleibt nichts zu integrieren; der Kandidat wurde abgelehnt.“ Auch das ist ein gültiges Ergebnis.
   - Danach Tests und Review wie gehabt, oder „Ablehnen …“, um ohne weiteres Kontingent zu enden.

### 18.5 Lauf abbrechen mit ⌘.

Kosten: ein gestarteter Autorenlauf.

Am sparsamsten verbindest du das mit einem Lauf aus 18.2 oder 18.4.

1. **E18.5.1** Wähle die Aufgabe, solange ihr Lauf „Läuft“, und drücke ⌘. (Menü „Lauf“, „Ausgewählten Lauf abbrechen“). Alternativ geht „Abbrechen“ in der Zeile des Laufs oder im Monitor.
2. **E18.5.2** **Erwartet:** „Wird abgebrochen“, dann „Abgebrochen“.
   - Bei Claude hat die Live-Abnahme den Abbruch als ungeklärt erfasst. Dann zeigt der Lauf „Ungeklärt“, und das Detail bietet „Ungeklärten Lauf entscheiden …“ an. Das Blatt „Ungeklärter Lauf“ hat „Als abgebrochen abschließen“; Return wählt „Offen lassen“. Das ist bei Claude keine Abweichung.
   - Notiere, welchen Status und Wartegrund die Aufgabe danach zeigt.

## 19 Wenn etwas scheitert: Was du zurückschickst

Die App hat keine Export- oder Diagnosefunktion außer „Redigiert kopieren“ im Monitor und schreibt kein eigenes Log. Schicke Folgendes:

1. **Das Protokoll** (Abschnitt 1) mit allen Abweichungen und den Bildschirmfotos.
2. **Den Verlauf des betroffenen Laufs:**
   1. Im Monitor den Filter „Alle“ wählen und den Lauf auswählen.
   2. „Redigiert kopieren“ klicken (bei Erfolg „Kopiert“) und in eine Textdatei einfügen.

   Mögliche Geheimnisse ersetzt die App durch `[entfernt: …]`. E-Mail-Adressen, Kontonamen und Pfade mit deinem Benutzernamen entfernt sie nicht unbedingt. Lies die Datei vor dem Senden durch und ersetze solche Stellen (zum Beispiel durch `<email>`, `~`).
3. **Zustände als Codes**, ohne Inhalte. Die Abfrage liest nur und gibt weder Titel noch Prompts aus:

   ```sh
   sqlite3 -readonly "$HOME/Library/Application Support/KAIORX/kaiorx.sqlite" "
     SELECT 'task', state, resume_state, wait_reason FROM task ORDER BY created_at;
     SELECT 'attempt', role, provider, model, state, error_class, process_lost FROM attempt ORDER BY reserved_at;
     SELECT 'candidate', kind, state FROM candidate ORDER BY created_at;
     SELECT 'test', status, exit_code FROM test_result ORDER BY at;
     SELECT 'review', origin, reviewer_provider, status FROM review ORDER BY at;
     SELECT 'gitop', kind, state FROM git_operation ORDER BY created_at;
     SELECT 'profile', provider, role, tier, verified_at IS NOT NULL FROM model_profile;"
   ```

4. **Git-Zustand des Wegwerf-Repositories:** die Ausgaben von `git for-each-ref --format='%(refname)' refs/kaiorx/`, `git worktree list` (Benutzername durch `~` ersetzen) und den `diff` aus Schritt 17.
5. **Versionen:** `claude --version`, `codex --version`, die ersten 16 Zeichen beider Prüfsummen aus 4.2 und die macOS-Version (`sw_vers`).
6. **Bei einem Absturz** der App den neuesten Bericht `~/Library/Logs/DiagnosticReports/KAIORX-*.ips`, nach Durchsicht auf persönliche Angaben.

**Nicht weiterschicken:**

- die Datenbank `kaiorx.sqlite` und ihre Sicherungen (sie enthalten Prompts und Inhalte);
- den Inhalt von `claude-config/` und `codex-home/` (Anmeldedaten);
- die Ausgaben von `claude auth status` und `codex login status` (E-Mail-Adresse);
- Schlüssel, Tokens und E-Mails, auch nicht als Bildschirmfoto.

## 20 Checkliste

Hake ab und trage Zeit und Beobachtung im Protokoll ein. Fett markiert ist der Hauptweg.

**Voraussetzungen**

- [ ] **E4.1** Debug-Build gebaut, Kanal `personal`
- [ ] **E4.2a** `claude --version` 2.1.329, Prüfsumme `8c1729…5550`
- [ ] **E4.2b** `codex --version` 0.170.0, Prüfsumme `9248cf…abd6`
- [ ] **E4.2c** beide in den KAIORX-Ordnern angemeldet (Abo bzw. ChatGPT), Zusatzguthaben aus
- [ ] **E4.3** Wegwerf-Repository mit `check.sh`, Commit und uncommittetem `lokal.txt`
- [ ] **E4.4** einige GB frei, nur eine App-Instanz, kein `-KAIORXUITest`
- [ ] **E4.5** `~/kaiorx-e2e-vorher.txt` geschrieben

**Start und Projekt**

- [ ] **E5.1** App startet, „Willkommen bei KAIORX“
- [ ] **E5.2** Onboarding: Git, Claude und Codex „live abgenommen“, Anmeldung „Wird beim ersten Lauf geprüft“, „sandbox-exec wirkt.“
- [ ] **E5.4** vier Modellprofile: Claude `sonnet` und Codex `gpt-6.2-sol`, je Autor und Prüfer, Stufe `standard`
- [ ] **E6.1–E6.3** Projekt per „Vertrauen und öffnen“ geöffnet, Return wählte „Nicht öffnen“

**Testprofil, Auftrag, Zustimmung**

- [ ] **E7.2** Testprofil „Prüfung“ vorgeschlagen, „Nicht bestätigt“
- [ ] **E7.3–E7.4** „Testprofil bestätigen“ gezeigt, Return wählte „Nicht bestätigen“, danach „Bestätigt“
- [ ] **E8.2** Auftrag angelegt, „Aktiv“, „Noch nichts veröffentlicht“
- [ ] **E8.3** „Wartet auf deine Zustimmung“, „Entscheidungen (1)“
- [ ] **E9.2** Blatt „Zustimmung für automatische Läufe“ mit Claude und Codex, Return wählte „Nicht zustimmen“
- [ ] **E9.3** nach „Zustimmen“ startet der Lauf ohne weiteren Wartegrund

**Lauf, Kette, Prüfung**

- [ ] **E10.1** „Autor · Claude · sonnet“: Reserviert → Startet → Läuft
- [ ] **E10.2** Monitor zeigt den Lauf und den Verlauf
- [ ] **E10.3** „Erfolgreich“, Aufgabe „Ergebnis liegt vor“, Laufzeit notiert
- [ ] **E11.1** „Wird versiegelt …“ → „Versiegelt: Commit … – Kandidat wird gebaut …“
- [ ] **E11.2** Kandidat „Gebaut“, Diff `+Hallo Welt`, Aufgabe „Wird geprüft“
- [ ] **E12.1** „Tests ausführen“ → „Tests bestanden“
- [ ] **E12.2** Kandidat „Im Review“, „Noch kein Review“
- [ ] **E13.1** Blatt „Review starten“ mit Codex, Claude gesperrt („anderer Anbieter“), Return wählte „Nicht jetzt“
- [ ] **E13.2–E13.3** „Review bei Codex gestartet …“, „Review läuft (Codex)“
- [ ] **E14.1** „Review wird übernommen …“ → „Zugestimmt“, Kandidat „Angenommen“, Aufgabe „Wartet auf Freigabe“
- [ ] **E14.2** falls nötig: „Übernahme erneut versuchen“ wirkt ohne neuen Prüferlauf

**Veröffentlichung, Lieferung, Checkout**

- [ ] **E15.1** Blatt „Integration veröffentlichen“, „Noch offen“ leer, Return wählte „Nicht jetzt“
- [ ] **E15.2** „Veröffentlicht“, „Integriert“, „Veröffentlichte Kandidaten: 1“, „Entscheidungen (0)“
- [ ] **E15.3** `refs/kaiorx/…` vorhanden, `hallo.txt` im Integrationsstand, Worktrees nur unter Application Support
- [ ] **E16.1–E16.2** „In neuen Branch liefern“ → „Branch … angelegt“
- [ ] **E16.3** Lieferbranch enthält `hallo.txt`
- [ ] **E17.1** Checkout unverändert bis auf den neuen Branch; kein `hallo.txt` im Checkout

**Optional**

- [ ] **E18.1** Revert gebaut, getestet, geprüft und veröffentlicht (oder abgelehnt)
- [ ] **E18.2** Ablehnung mit Grund; „Nacharbeit erlauben“ zeigt den Grund; neuer Lauf berücksichtigt ihn
- [ ] **E18.3** Verwerfen mit Grund (oder „nicht erreichbar“ notiert)
- [ ] **E18.4** Konflikt herbeigeführt und mit „Rücknahme übernehmen“ gelöst
- [ ] **E18.5** Abbruch mit ⌘.: „Abgebrochen“ (Claude: ggf. „Ungeklärt“ → „Als abgebrochen abschließen“)

**Abschluss**

- [ ] **E19** Protokoll und, bei Abweichungen, die Angaben aus Abschnitt 19 zurückgeschickt, ohne Geheimnisse und E-Mails
