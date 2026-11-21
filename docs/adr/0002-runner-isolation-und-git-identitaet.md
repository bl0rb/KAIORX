# ADR 0002 · Runner im Prozess, Sandbox-Isolation und Repository-Identität

**Status:** angenommen, 19. November 2026; §5 ergänzt am 21. November 2026 · **Betrifft:** Paket C, `Plan/macos-und-git.md` (Prozesse, Schutzgrenze) und `Plan/laufzeitvertrag.md` (`project.git_common_identity`)

## 1. Runner zunächst im App-Prozess

**Kontext.** Der Plan sieht einen signierten Runner vor, der an die GUI gebunden ist und über Pipes ein Protokoll spricht. Paket C verlangt Worktrees, Prozessgruppen, Stop/Drain sowie EOF- und Stderr-Flut, aber noch keine App.

**Entscheidung.** `ProcessHost` ist eine Bibliothek. Sie übernimmt alles, was der Helper später tun soll:
- `posix_spawn` mit eigener Prozessgruppe und `POSIX_SPAWN_CLOEXEC_DEFAULT`, sodass nur stdin, stdout und stderr vererbt werden
- eine explizite Umgebung aus einer Positivliste
- getrenntes, begrenztes Lesen beider Streams
- Stop in der Reihenfolge INT → TERM → KILL an die Gruppe
- Drain und Timeouts

Signale gehen nur an eine noch nicht eingesammelte Gruppe. Das Kindende wird mit `waitid(WNOWAIT)` erkannt, Reste der Gruppe werden beendet, solange der Zombie die Gruppen-ID noch reserviert, und erst danach wird eingesammelt.

**Folgen.** Der Helper-Prozess mit Protokollversion und Auftrags-ID entsteht mit der Xcode-App. Er bettet dieselbe Bibliothek ein. Bis dahin endet ein Kindprozess nicht automatisch, wenn die App abstürzt, denn es gibt keine Verbindung, deren EOF ihn beenden könnte. Nach einem Neustart findet `recoverAfterRestart` solche Läufe und markiert sie als `uncertain`.

## 2. Schreib- und Leseschutz über die macOS-Sandbox

**Kontext.** Laut Plan bringen Worktrees, `cwd` und separate Prozesse keine Beschränkung durch das Betriebssystem. Fehlt ein wirksamer Schreibschutz, sind automatische Schreibrechte für Agenten ausgeschlossen.

**Entscheidung.** `Confinement` startet Kindprozesse über `/usr/bin/sandbox-exec` mit einem erzeugten Profil:
- Schreiben ist nur in den freigegebenen Wurzeln erlaubt, also im eigenen Worktree und im Lauf-Temp.
- KAIORX-Daten (Datenbank, fremde Worktrees, fremde Läufe) und Zugangsdaten-Ordner im Home (`.ssh`, `.aws` und andere) sind weder lesbar noch schreibbar.
- Netzwerk ist gesperrt.

Die Regeln gelten auch für Enkelprozesse. `Confinement.probe` prüft auf dem jeweiligen Mac, ob ein verbotener Schreibzugriff tatsächlich scheitert. `RoleProfile` legt die Regeln für Autor, Reviewer und Test-Runner fest.

**Grenzen.**
- `sandbox-exec` ist von Apple als veraltet markiert und nicht dokumentiert. Jede neue macOS-Version braucht vor der Freigabe den Probe-Test und die Isolationstests.
- Fällt die Probe negativ aus, gibt es keine automatischen Schreibrechte für Agenten (Gate des Plans).
- Keychain-Zugriffe laufen über Systemdienste, nicht über Dateien. Ein verborgener Ordner schützt sie nicht. Die Keychain-Negativtests bleiben Teil von Paket D.
- Ein Prozess, der mit `setsid` eine eigene Sitzung beginnt, verlässt die Prozessgruppe. Der Host bricht dann das Lesen nach einer Frist ab (`outputCutOff`), kann den Prozess aber nicht beenden.

**Neubewertung.** Wenn `sandbox-exec` entfällt oder unzuverlässig wird: App-Sandbox mit XPC-Dienst, Endpoint-Security oder eine VM, wie im Plan für fremde Repositories vorgesehen.

## 3. Repository-Identität über den Root-Commit

**Kontext.** Der Vertrag verlangt eine Repository-Identität, die nach einem Ordnerumzug nur nach Abgleich wiedergefunden wird. Der Pfad des gemeinsamen Git-Verzeichnisses taugt dafür nicht: Ein anderes Repository am selben Ort hätte denselben Pfad.

**Entscheidung.**
- `project.git_common_identity` ist `<objektformat>:<kleinster Root-Commit von HEAD>`. Der Wert bleibt bei Umzug und Neuklonen gleich und unterscheidet unabhängige Repositories.
- Ein Projekt behält seine erste Identität. Eine abweichende Identität im selben Ordner wird abgewiesen.
- Repositories ohne Commit lassen sich nicht anbinden, weil ihnen die Basis fehlt.

**Folgen.** Ein Umschreiben der Historie bis zum Root-Commit gilt als anderes Repository. Das ist gewollt, denn alle gespeicherten OIDs wären danach ungültig.

## 4. Prozess-Sperre der Datenbank mit kurzer Wiederholung

**Entscheidung.** `Store` sperrt die Datenbank mit `flock` auf `<db>.lock` (`O_CLOEXEC`).

Ein Kind, das ein anderer Thread gerade startet, hält bis zu seinem `exec` kurz eine Kopie aller offenen Dateibeschreibungen. Das gilt auch für solche mit `O_CLOEXEC`. In diesem Fenster sähe ein sofort neu geöffneter Store seine eigene, eben freigegebene Sperre als belegt. Deshalb wiederholt der Store den Versuch bis zu 1 s lang. Ein echter zweiter Prozess hält die Sperre dauerhaft und wird weiterhin abgewiesen.

## 5. Gemeinsame Isolationsproben (21. November 2026)

**Kontext.** Beide Profile, `testRunner` und `agentCLI`, beginnen mit `(allow default)` und verweigern danach gezielt (`Confinement.swift`). `Confinement.probe` prüft nur einen verbotenen Schreibzugriff. Was ein Kindprozess über Systemdienste außerhalb der Sandbox auslösen kann, hat bisher kein Test geprüft. Paket I braucht dieselben Proben später als Selbsttest pro Mac (I.4) und als Gegenprobe für eine VM (I.5); Stufe 0.5 im Plan.

**Entscheidung.** `IsolationProbes` im Target `Workspace` führt synthetische Proben unter einer gegebenen `Confinement` über `ProcessHost` aus und liefert je Probe ein typisiertes Ergebnis: `blocked`, `reached`, `inconclusive` oder `skipped`.
- **Proben:** Marke in `~/Documents` lesen, Marke in `~/.ssh` lesen, KAIORX-Daten lesen (Datenbank im Supportordner und Workspace-Wurzel), außerhalb der Schreibwurzeln schreiben, in den Worktree schreiben, die `.git`-Link-Datei ändern oder verschieben, TCP zu einem Listener auf 127.0.0.1, DNS-Auflösung, ein Kind mit `setsid`, das den Stopp der Prozessgruppe überlebt.
- **Störende Proben nur auf Wunsch** (`KAIORX_INTRUSIVE_PROBES=1`), weil sie die Sitzung des Benutzers berühren: `launchctl submit` eines harmlosen Jobs, LaunchServices-`open` einer synthetischen Hintergrund-App, `defaults write` in eine Bench-Domain. Jede räumt immer auf: `launchctl remove`, `lsregister -u` und Löschen der App, `defaults delete` und Löschen der Plist-Datei genau dieser Domain.
- **Wirkung statt Exit-Code:** Die Suite prüft selbst, ob die Probe gewirkt hat (Marke gelesen, Datei auf der Platte, Verbindung beim Listener angekommen, Job bei launchd gelistet, Wert bei cfprefsd gespeichert). Job und App schreiben ihre Marke außerhalb aller Schreibwurzeln; dort kann sie nur ein Prozess ohne Sandbox ablegen. Ein Kontrolllauf ohne Isolation zeigt, dass jede Probe einen Ausbruch erkennt. `blocked` braucht zusätzlich einen Beleg für die Verweigerung: Das Probenskript beweist mit einer ersten Zeile samt Lauf-Token, dass es lief, prüft, dass das Werkzeug vorhanden ist, und meldet dessen Exit-Code; verweigert gilt nur bei der Signatur der Sandbox (`Operation not permitted` für beide `.git`-Versuche, Exit 1 = EPERM ohne Ausgabe bei `launchctl submit`, Fehler -54 (permErr) bei `open`, „Could not write domain“ bei `defaults write`). Ein Skript, das nicht startet, ein fehlendes Werkzeug oder ein anderer Fehler ergibt `inconclusive`, nie `blocked`.
- **Synthetische Umgebung:** `IsolationProbeFixture` bildet die Ordner des Produkts in einem falschen Benutzerordner nach (Supportordner mit Datenbank und den Zustandsordnern der CLIs, Workspace mit Worktree und Lauf-Temp, ein Ordner außerhalb). Der echte Benutzerordner wird nie benutzt; nur cfprefsd legt eine Bench-Domain im echten Einstellungsordner ab, die die Probe wieder löscht.
- **Vertrag je Rolle:** `IsolationProbe.mustBlock(role)` nennt, was eine Rolle verweigern muss. `violations` zählt auch `inconclusive` als Verstoß (schließt bei Unklarheit); ein absichtlich defektes Profil fällt durch.

**Messung** auf macOS 27.2.1 (26B131), Fake-Benutzerordner, beide `testRunner`-Varianten und `agentCLI` als Autor und Reviewer für Claude und Codex:

| Probe | `testRunner` vorher | `agentCLI` vorher | jetzt (beide) |
|---|---|---|---|
| `~/Documents` lesen | erreicht | verweigert | unverändert (Lücke bei `testRunner`) |
| `~/.ssh` lesen | verweigert | verweigert | verweigert |
| KAIORX-Daten lesen | **erreicht** (Supportordner) | verweigert | verweigert |
| außerhalb schreiben, `.git` ändern | verweigert | verweigert | verweigert |
| Worktree schreiben | nur mit `writesWorktree` | nur als Autor | unverändert |
| TCP 127.0.0.1, DNS | verweigert | erreicht | unverändert (für `agentCLI` nötig) |
| `setsid`-Überlebender | erreicht | erreicht | erreicht (Lücke) |
| `launchctl submit` | verweigert | verweigert | verweigert |
| LaunchServices `open` | **erreicht** | **erreicht** | verweigert |
| `defaults write` | **erreicht** | erreicht im Test, im Produkt verweigert | verweigert |

Ein Profildurchlauf dauert etwa 0,3 s, mit den störenden Proben etwa 0,4 s; der Selbsttest bleibt damit weit unter den 10 s, die I.4 vorsieht.

**Härtungen**, nur wo sie für die CLIs klar sicher sind:
1. **`(deny lsopen)` für alle Rollen.** `open` startete eine App, die außerhalb jeder Sandbox lief und außerhalb der Schreibwurzeln schrieb: ein vollständiger Ausbruch, auch aus `agentCLI` (Codex führt Befehle ohne eigene Sandbox aus, ADR 0008). Die CLIs laufen ohne Oberfläche; die Anmeldung macht der Benutzer selbst im Terminal (ADR 0008, Punkt 2). LaunchServices antwortet danach mit Fehler -54.
2. **`(deny user-preference-write)` für alle Rollen.** cfprefsd schreibt in die echten Einstellungen des Kontos, unabhängig von `HOME` und vom Dateischreibschutz; ein Test hätte so die Einstellungen anderer Apps ändern können. Gemessen: cfprefsd beachtet die Regel nur zusammen mit `(deny file-write*)`, das jedes Profil hat. Werte im eigenen Prozess bleiben lesbar (`UserDefaults` setzen und lesen im selben Prozess funktioniert), nur das Speichern scheitert. Für `agentCLI` verweigert cfprefsd im Produkt schon heute, weil der echte Benutzerordner verborgen ist; die Regel macht das davon unabhängig und ändert für die CLIs nichts.

   Beide Regeln hängen an `Confinement.allowsSessionServices` (Standard: aus).
3. **Supportordner als Zugangsdaten-Ordner.** `Library/Application Support/KAIORX` steht jetzt in `WorkspaceLayout.secretHomePaths`. Bisher verbarg `testRunner` nur die Workspace-Wurzel und die Datenbankdateien (`WorkspaceService.storeFiles`); `codex-home/auth.json` mit der Codex-Anmeldung und `claude-config` waren lesbar. Eine CLI sieht weiterhin ihren eigenen Zustandsordner (sichtbare Wurzel), aber nicht den der anderen.

**Verbleibende Lücken:**
- **`setsid`-Überlebende** in allen Profilen. Die Sandbox hat dafür keine Regel; `ProcessHost` bricht nach dem Gruppenstopp nur das Lesen ab (§2). Der Überlebende behält die Sandbox, Lese- und Schreibschutz gelten also weiter, aber er läuft weiter. Abhilfe erst mit Verfolgung des Prozessbaums, dem Helper oder der VM (I.5).
- **Benutzerordner für `testRunner` lesbar**, außer Zugangsdaten und KAIORX. Toolchains und Caches liegen dort (`~/.rustup`, `~/.nvm`, `~/Library/Developer`), und Tests, die Git aufrufen, lesen das gemeinsame Repository im Checkout des Benutzers. `hideHome` steht für eine Option im Testprofil-Register (0.6) bereit. TCC schützt `Documents`, `Desktop` und `Downloads` nur, solange KAIORX selbst keinen Zugriff darauf hat.
- **Netzwerk für `agentCLI` ganz offen**, auch Loopback (lokale Datenbanken, Entwicklungsserver) und DNS. Der Anbieter braucht Netzwerk; eine Loopback-Sperre würde lokale Proxys brechen und ist deshalb nicht klar sicher. Eine Liste der Anbieter-Endpunkte wäre eine eigene Entscheidung.
- **`launchctl submit`** weist launchd für jeden Prozess in einer Sandbox ab, auch mit nur `(allow default)` (im Einzelversuch genauso `launchctl bootstrap` und `load`); das ist keine Regel von KAIORX. Die Probe meldet, falls sich das mit einer neuen macOS-Version ändert.
- **Nicht geprobt:** Apple Events (`appleevent-send`, etwa Terminal fernsteuern, die TCC-Abfrage käme im Namen von KAIORX), die Zwischenablage, Unix-Sockets anderer Dienste (ob ein verborgener `~/.docker` auch `connect` auf den Docker-Socket verhindert, ist offen). Kandidaten für die nächste Probenrunde.
- Tests laufen mit falschem Benutzerordner. Dass cfprefsd bei verborgenem echtem Benutzerordner verweigert, ist nur im Einzelversuch gemessen; die ausdrückliche Regel macht die Tests davon unabhängig.

**Folgen.**
- `Confinement.probe` und die bisherigen Isolationstests bleiben unverändert.
- Die Rollentests führen die Suite ohne störende Proben in jedem Testlauf aus. Vor der Freigabe einer neuen macOS-Version laufen sie zusätzlich mit `KAIORX_INTRUSIVE_PROBES=1`.
- Die neuen Regeln für `agentCLI` (LaunchServices, Einstellungen) sind nicht live gemessen. `liveVerified` bleibt davon unberührt, weil die CLIs beides in ihren Läufen nicht nutzen. Der nächste Live-Lauf des Kontoinhabers misst sie mit, weil Adapter und Kit dieselbe `agentCLIConfinement` bauen.
