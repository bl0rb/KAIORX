# KAIORX Icon-Set — Constellation K

Basis: Das zuletzt gewählte KAIORX-Motiv (Konstellations-K mit fünf Leuchtpunkten und umlaufendem Orbit). Das Originalmotiv ist als Raster-Artwork enthalten. Für sehr kleine Browser-Icons wurde eine vereinfachte, editierbare SVG-Interpretation entwickelt.

## Dateien und Einsatz

- `branding/original-concept.png`: unverändertes ausgewähltes Motiv als Referenz.
- `branding/kaiorx-original-1024.png`: Originalmotiv mit transparentem, weich gerundetem Rand, 1024×1024.
- `branding/kaiorx-constellation-vector.svg`: skalierbare, stilistisch passende Vektorneuzeichnung (keine Pixel-für-Pixel-Vektorisierung).
- `branding/kaiorx-mark.svg`: bewusst vereinfachte Vektorversion für kleine Größen.
- `macos/KAIORX.icns`: macOS-Programmsymbol mit mehreren Größen.
- `macos/AppIcon.iconset/`: klassischer Iconset-Ordner für macOS / iconutil.
- `macos/AppIcon.appiconset/`: mit Xcode verwendbares Asset-Catalog-AppIcon mit Contents.json.
- `macos/KAIORX-1024.png`: hochaufgelöstes PNG.
- `ios/AppIcon.appiconset/`: iOS AppIcon mit einer opaken 1024×1024 PNG und Contents.json.
- `web/favicon.ico`: Multigrößen-Favicon 16×16, 32×32 und 48×48.
- `web/favicon.svg`: Browser-Tab-Icon, das in modernen Browsern skalierbar ist.
- `web/favicon-{16,32,48,64}x{16,32,48,64}.png`: klassische PNG-Favicons.
- `web/apple-touch-icon.png`: 180×180 für iPhone/iPad-Websites.
- `web/android-chrome-{192,512}x{192,512}.png`: PWA Icons.
- `web/android-chrome-maskable-{192,512}x{192,512}.png`: PWA-Safe-Zone-Versionen.
- `web/safari-pinned-tab.svg`: monochrome Safari-Pinned-Tab-Maske.
- `web/site.webmanifest`: PWA-Manifest (URLs setzen das Hosting der Dateien im Root voraus).
- `web/html-snippet.html`: Beispieltags für den HTML-Head.

## Verwendung

**macOS / Xcode:** Den Ordner `macos/AppIcon.appiconset` ins `Assets.xcassets` verschieben bzw. importieren und im Target als App Icon auswählen. Alternativ die fertige `KAIORX.icns` in bestehende Projekt-Buildprozesse integrieren.

**iOS / Xcode:** Den Ordner `ios/AppIcon.appiconset` ins Asset Catalog übernehmen. Das iOS-AppIcon hat absichtlich keine Transparenz; iOS übernimmt die Maskierung der Ecken.

**Web:** Dateien aus `web/` ins öffentliche Root-Verzeichnis kopieren und `html-snippet.html` im HTML-Head einfügen. Bei anderem Speicherpfad alle `/`-Pfade anpassen. Der Manifestname / die URLs sind Beispieldaten und können editiert werden.

**Design:** Farben: Navy `#07102a`, Cyan `#23eaff`, Blau `#69b9ff`, Magenta `#e35bfd`. Der macOS-Rastersatz verwendet das gewählte Original; der Websatz verwendet eine weniger detailreiche Vektorvariante, damit das K bei 16 Pixeln noch zu erkennen ist.
