# ADR 0002 · Runner im Prozess, Sandbox-Isolation und Repository-Identität

**Status:** angenommen, 19. November 2026 · **Betrifft:** Paket C, `Plan/macos-und-git.md` (Prozesse, Schutzgrenze) und `Plan/laufzeitvertrag.md` (`project.git_common_identity`)

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
