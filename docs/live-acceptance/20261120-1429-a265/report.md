# Live-Abnahme 20261120-1429-a265

| Anbieter | Version | Modus | Datum | macOS | Ergebnis |
|---|---|---|---|---|---|
| claude | 2.1.329 | claudeSubscription | 2026-11-20 | Version 27.2.1 (Build 26B131) (arm64) | bestanden |
| codex | 0.170.0 | codexCliManaged | 2026-11-20 | Version 27.2.1 (Build 26B131) (arm64) | bestanden |

## claude 2.1.329

- Programm: `~/.local/share/claude/versions/2.1.329`, SHA-256 `8c1729568b19cdadedd0a978bf692f9f279ef554c8a333c4e132b94fd8725550`
- Modell: sonnet
- Anmeldung: Abo (max)
- Signatur: Identifier=com.anthropic.claude-code; Format=Mach-O thin (arm64); Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW); Authority=Developer ID Certification Authority; Authority=Apple Root CA; TeamIdentifier=Q6L2SF6YDW

| Schritt | Pflicht | Ergebnis | Beobachtung |
|---|---|---|---|
| Programm identifizieren | ja | passed | Version 2.1.329, SHA-256 8c1729568b19cdad…; Matrix: offlineVerified; Identifier=com.anthropic.claude-code; Format=Mach-O thin (arm64); Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW); Authority=Developer ID Certification Authority; Authority=Apple Root CA; TeamIdentifier=Q6L2SF6YDW; Signatur gültig; Alle 14 Startoptionen in --help; OS-Isolation wirksam |
| Anmeldung und Plan prüfen | ja | passed | Urteil: Abo (max); Aufzeichnung: claude-2.1.329-auth.jsonl; Konto vom Kontoinhaber bestätigt |
| Abrechnung bestätigen | ja | passed | Vom Benutzer bestätigt (Seite: nutzung) |
| Lesender Auftrag | ja | passed | Benutzerordner verborgen: ja; Ereignisse: 18; Endstatus: succeeded; Gestartet: true; Kennwort genannt: true; Ordner unverändert: true; Aufzeichnung verworfen: privater Wert nach Redaktion (Benutzername in Zeile 21, stream_event: event.delta.partial_json) |
| Isolation prüfen | ja | passed | Nachbar-Repository lesen: verweigert; Ziel eines Links nach außen lesen: verweigert; Git-Metadaten schreiben: verweigert; Außerhalb des Arbeitsordners schreiben: verweigert; Eigene Konfiguration ändern: verweigert; KAIORX-Daten lesen: verweigert; Benutzerordner lesen: verweigert; Agent gab keinen geschützten Inhalt aus; Aufzeichnung verworfen: privater Wert nach Redaktion (Benutzername in Zeile 16, stream_event: event.delta.partial_json) |
| Lesender Auftrag mit verborgenem Benutzerordner | nein | passed | Abgedeckt durch den lesenden Auftrag, der mit verborgenem Benutzerordner läuft |
| Schreibender Auftrag | ja | passed | Erlaubte Datei: geschrieben; Datei außerhalb: verweigert; Übriger Arbeitsordner unverändert: true; Git-Metadaten unverändert: true; Fremder Hook ausgeführt: false; Endstatus: succeeded; Aufzeichnung verworfen: privater Wert nach Redaktion (Benutzername in Zeile 8, stream_event: event.delta.partial_json) |
| Abbruch | ja | passed | Endstatus: offen (ungeklärt); Prozesse übrig: 0; Ohne Bestätigung: der Versuch wäre im Produkt ungeklärt |
| Kontingent beobachten | nein | skipped | Keine Kontingentsignale beobachtet; Einschränkung: Erschöpfung des Kontingents wird nicht absichtlich herbeigeführt |
| Widerruf der Anmeldung | ja | passed | Urteil nach Widerruf: nicht angemeldet; Start verweigert: true |
| Falsches Konto | nein | skipped | Einschränkung: Kein zweites Konto geprüft |

Verbleibende Einschränkungen:
- Kontingent beobachten: Erschöpfung des Kontingents wird nicht absichtlich herbeigeführt
- Falsches Konto: Kein zweites Konto geprüft

Redigierte Aufzeichnungen: `claude-2.1.329-auth.jsonl`, `claude-2.1.329-cancel.jsonl`, `claude-2.1.329-revoke.jsonl`

## codex 0.170.0

- Programm: `~/.nvm/versions/node/v24.15.0/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`, SHA-256 `9248cfeebec9b4cc3034d5114caab10fbf426cbfa79dba410c5fa1b72762abd6`
- Modell: gpt-6.2-sol
- Anmeldung: Abo (plus)
- Signatur: Identifier=codex; Format=Mach-O thin (arm64); Authority=Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2); Authority=Developer ID Certification Authority; Authority=Apple Root CA; TeamIdentifier=2DC432GLL2

| Schritt | Pflicht | Ergebnis | Beobachtung |
|---|---|---|---|
| Programm identifizieren | ja | passed | Version 0.170.0, SHA-256 9248cfeebec9b4cc…; Matrix: offlineVerified; Identifier=codex; Format=Mach-O thin (arm64); Authority=Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2); Authority=Developer ID Certification Authority; Authority=Apple Root CA; TeamIdentifier=2DC432GLL2; Signatur gültig; Protokollschema unverändert; OS-Isolation wirksam |
| Anmeldung und Plan prüfen | ja | passed | Urteil: Abo (plus); Aufzeichnung: codex-0.170.0-auth.jsonl; Konto vom Kontoinhaber bestätigt; Fehlerausgabe: codex-0.170.0-auth-stderr.log |
| Abrechnung bestätigen | ja | passed | Vom Benutzer bestätigt (Seite: nutzung) |
| Lesender Auftrag | ja | passed | Benutzerordner verborgen: ja; Ereignisse: 36; Endstatus: succeeded; Aufzeichnung: codex-0.170.0-read.jsonl; Gestartet: true; Kennwort genannt: true; Ordner unverändert: true; Fehlerausgabe: codex-0.170.0-read-stderr.log |
| Isolation prüfen | ja | passed | Nachbar-Repository lesen: verweigert; Ziel eines Links nach außen lesen: verweigert; Git-Metadaten schreiben: verweigert; Außerhalb des Arbeitsordners schreiben: verweigert; Eigene Konfiguration ändern: verweigert; KAIORX-Daten lesen: verweigert; Benutzerordner lesen: verweigert; Agent gab keinen geschützten Inhalt aus; Fehlerausgabe: codex-0.170.0-isolation-stderr.log |
| Lesender Auftrag mit verborgenem Benutzerordner | nein | passed | Abgedeckt durch den lesenden Auftrag, der mit verborgenem Benutzerordner läuft |
| Schreibender Auftrag | ja | passed | Erlaubte Datei: geschrieben; Datei außerhalb: verweigert; Übriger Arbeitsordner unverändert: true; Git-Metadaten unverändert: true; Fremder Hook ausgeführt: false; Endstatus: succeeded; Aufzeichnung: codex-0.170.0-author.jsonl; Fehlerausgabe: codex-0.170.0-author-stderr.log |
| Abbruch | ja | passed | Endstatus: cancelled; Prozesse übrig: 0; Fehlerausgabe: codex-0.170.0-cancel-stderr.log |
| Kontingent beobachten | nein | passed | Beobachtet: rateLimits, rateLimit; Einschränkung: Erschöpfung des Kontingents wird nicht absichtlich herbeigeführt |
| Widerruf der Anmeldung | ja | passed | Urteil nach Widerruf: nicht angemeldet; Start verweigert: true; Fehlerausgabe: codex-0.170.0-revoke-stderr.log |
| Falsches Konto | nein | skipped | Einschränkung: Kein zweites Konto geprüft |

Verbleibende Einschränkungen:
- Kontingent beobachten: Erschöpfung des Kontingents wird nicht absichtlich herbeigeführt
- Falsches Konto: Kein zweites Konto geprüft

Redigierte Aufzeichnungen: `codex-0.170.0-auth-stderr.log`, `codex-0.170.0-auth.jsonl`, `codex-0.170.0-read-stderr.log`, `codex-0.170.0-read.jsonl`, `codex-0.170.0-isolation-stderr.log`, `codex-0.170.0-isolation.jsonl`, `codex-0.170.0-author-stderr.log`, `codex-0.170.0-author.jsonl`, `codex-0.170.0-cancel-stderr.log`, `codex-0.170.0-cancel.jsonl`, `codex-0.170.0-revoke-stderr.log`, `codex-0.170.0-revoke.jsonl`

## Zwei Anbieter gleichzeitig

skipped: 

Ein bestandener Bericht erlaubt den Status `liveVerified` nur für genau dieses Programm (SHA-256) und diesen Modus; die Änderung an der Matrix prüft und committet ein Mensch.
