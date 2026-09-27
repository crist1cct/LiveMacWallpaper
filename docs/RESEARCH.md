# Research tehnic

Data verificării: 5 septembrie 2026.

## Rezumat executiv

Aplicația poate oferi o experiență aproape complet automată, dar cele trei destinații nu au același nivel de suport în macOS:

| Destinație | Implementare | Stabilitate |
|---|---|---|
| Desktop static | `NSWorkspace.setDesktopImageURL` | API publică Apple |
| Desktop video | fereastră AppKit la nivelul Desktopului + AVFoundation | API-uri publice, compoziție proprie |
| Screen Saver | bundle `.saver` cu `ScreenSaverView` | framework Apple, instalare externă |
| Lock Screen separat | editarea ramurii `Idle`/asset Aerial | integrare privată, experimentală |

Concluzia de produs este să păstrăm funcțiile Desktop și redare ca bază stabilă, iar Lock Screen independent ca modul experimental cu backup și Restore.

## Ce oferă oficial Apple

### Desktop static

`NSWorkspace` poate citi și seta imaginea Desktop pentru un anumit `NSScreen`, iar apelul trebuie făcut pe main thread. Este soluția oficială pentru imagini statice.

Sursă: https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageurl(for:)

### Redare și pregătire video

AVFoundation oferă:

- `AVAssetExportSession` pentru conversie;
- preseturi HEVC 1080p, 4K și highest quality;
- `AVQueuePlayer` și `AVPlayerLooper` pentru loop;
- `AVAssetImageGenerator` pentru thumbnails și postere asincrone.

Surse:

- https://developer.apple.com/documentation/avfoundation/avassetexportsession
- https://developer.apple.com/documentation/avfoundation/export-presets
- https://developer.apple.com/documentation/avfoundation/exporting-video-to-alternative-formats
- https://developer.apple.com/documentation/avfoundation/avplayerlooper
- https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/generatecgimageasynchronously(for:completionhandler:)

### Fereastra de wallpaper

Core Graphics definește nivelurile `desktopWindow` și `desktopIconWindow`. AppKit permite ferestrelor să intre în toate Spaces și să rămână staționare în Mission Control. Aceste API-uri fac posibil un video aflat deasupra imaginii statice și sub iconițele Finder.

Surse:

- https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct

### Screen Saver

Apple documentează bundle-urile cu extensia `.saver`, instalate într-un director `Library/Screen Savers`, cu o subclasă `ScreenSaverView`. Documentația recomandă binary universal pentru compatibilitate `arm64` și `x86_64`.

Sursă: https://developer.apple.com/documentation/screensaver

### Pornire automată

În macOS 13+, `SMAppService` este API-ul recomandat pentru Login Items, LaunchAgents și LaunchDaemons incluse în bundle. Înregistrarea rămâne supusă aprobării utilizatorului.

Sursă: https://developer.apple.com/documentation/servicemanagement/smappservice

### Fișiere alese de utilizator

Apple recomandă `fileImporter` sau `NSOpenPanel`. Pentru acces persistent în App Sandbox sunt necesare security-scoped bookmarks. Planul nostru copiază media în Application Support, reducând dependența de acces ulterior la fișierul original.

Sursă: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox

### Energie și lifecycle

`NSWorkspace` publică notificări pentru sleep/wake, sesiune și Spaces. `ProcessInfo` oferă Low Power Mode și thermal state. Instruments și Xcode oferă Time Profiler, Energy/Power Profiler, File Activity și metrici de performanță.

Surse:

- https://developer.apple.com/documentation/appkit/nsworkspace
- https://developer.apple.com/documentation/foundation/processinfo
- https://developer.apple.com/documentation/xcode/improving-your-app-s-performance

### Interfață nativă

Human Interface Guidelines recomandă sidebar pentru zonele principale, toolbar restrâns la acțiuni frecvente, comenzi echivalente în menu bar și Settings standard macOS.

Surse:

- https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/
- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/design/human-interface-guidelines/settings

## Limita Lock Screen

Documentația publică Apple pentru Lock Screen descrie securitatea, timpul de oprire, parola, mesajul și clock appearance, dar nu oferă o API publică pentru a seta independent un video de lock screen.

Aceasta este o concluzie din documentația disponibilă, nu o garanție contractuală că Apple nu are mecanisme interne.

Sursă: https://support.apple.com/guide/mac-help/change-lock-screen-settings-on-mac-mh11784/mac

Pe Mac-ul local cu macOS 26.6, store-ul existent are ramuri separate `Desktop` și `Idle` în `AllSpacesAndDisplays` și `SystemDefault`. Acest lucru confirmă că separarea există intern, dar formatul nu este API public și se poate schimba la un update macOS.

### Autentificare după lock versus autentificare la cold boot

Pentru cerința produsului sunt două momente tehnic diferite:

1. După `Control–Command–Q` sau revenirea din Screen Saver, sesiunea utilizatorului există deja. Providerul nativ Wallpaper/Aerial poate reda un asset video sub controalele de autentificare. Acesta este obiectivul funcției `Video Lock Screen`.
2. Imediat după pornire, mai ales cu FileVault, sesiunea utilizatorului și agentul aplicației nu sunt încă active, iar fișierele din home pot să nu fie disponibile. Pentru această fază produsul oferă un poster static extras din video, nu promite redare video.

Implementările open-source analizate confirmă primul scenariu prin asset Aerial și ramura `Idle`. Ele generează separat un poster pentru cold boot, ceea ce susține aceeași delimitare.

Aplicația nu va folosi o fereastră proprie ridicată peste nivelul de protecție al sistemului. Video-ul trebuie redat de componenta nativă macOS, astfel încât parola, Touch ID și toate controalele de securitate să rămână integral gestionate de sistem.

## Proiecte open-source analizate

### Wallpaper Sync

Repo: https://github.com/GonzaloRojas14/Wallpaper-Sync

Pattern-uri validate:

- video pe Desktop prin `AVPlayer` într-o fereastră sub iconițe;
- conversie HEVC o singură dată;
- câte un player per display;
- pauză la lock și sleep;
- configurare Aerial și update al ramurii `Idle`;
- backup și restore al assetului Aerial.

Riscuri observate:

- dependență runtime de FFmpeg și Homebrew;
- restartarea proceselor Apple;
- modificarea formatelor private ale wallpaper store;
- poster cold-boot scris într-o locație de sistem.

### LivePaper

Repo: https://github.com/Raunik2/LivePaper

Pattern-uri validate:

- `AVQueuePlayer` + `AVPlayerLooper` + `AVPlayerLayer`;
- ferestre per monitor;
- reacție la Spaces, sleep și wake;
- snapshot static ca fallback;
- înregistrarea unui asset în manifestul Aerial;
- health check pentru integrarea privată.

Pattern-uri pe care planul nostru nu le va adopta:

- fereastră ridicată peste nivelul de shielding al Lock Screen;
- instalarea automată a unor binare descărcate;
- preferințe Screen Saver modificate fără separarea clară Stable/Experimental.

### VideoScreenSaver

Repo: https://github.com/GeneralD/VideoScreenSaver

Pattern-uri validate:

- `ScreenSaverView` cu `AVPlayerLayer`;
- playback mut și aspect fill;
- cleanup complet în `stopAnimation`;
- preview/config sheet în host-ul Screen Saver.

Toate cele trei proiecte sunt MIT. Nu este necesară copierea codului lor; dacă reutilizăm ulterior o porțiune substanțială, păstrăm copyright-ul și licența cerute.

## Distribuție

Mac App Store cere App Sandbox și nu permite instalarea de cod sau resurse în locații comune, auto-start fără consimțământ ori privilegii root. Din acest motiv, funcționalitatea completă este potrivită pentru distribuție Developer ID în afara Store.

Un build Developer ID trebuie să aibă semnături valide, Hardened Runtime și notarizare; distribuția folosește `notarytool` și stapling.

Surse:

- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

## Toolchain local verificat

- macOS 26.6, Apple Silicon (`arm64`).
- Xcode 26.6.
- macOS SDK 26.5.
- Swift 6.3.3.
- Homebrew instalat.
- O identitate validă de code signing disponibilă.
- Framework-uri prezente în SDK: SwiftUI/AppKit, AVFoundation, ScreenSaver, ServiceManagement și SwiftData.
- XcodeGen 2.46.0 instalat pentru generarea viitoarelor targets de aplicație.
- `yt-dlp` 2026.8.19 instalat numai ca unealtă locală de dezvoltare și testare.
- `ffmpeg` nu este cerut de la utilizator: aplicația include un helper minimal universal construit din sursa oficială 9.0.1.
- Tuist nu este necesar.

## Decizii despre instrumente

### XcodeGen — recomandat

Un proiect cu app, agent, `.saver`, tests și UI tests devine greu de întreținut manual în `project.pbxproj`. XcodeGen generează proiectul dintr-un `project.yml` lizibil și reproductibil. Este o unealtă de development, nu intră în aplicația livrată.

Repo: https://github.com/yonaskolb/XcodeGen

### FFmpeg — fallback inclus

Testul real cu un MP4 VP9 3840×2160 a arătat că AVFoundation poate inspecta pista,
dar refuză presetările HEVC/H.264 și nu poate extrage posterul. Aplicația încearcă
întâi conversia Apple; numai dacă aceasta nu poate produce un fișier redabil,
apelează helperul FFmpeg minimal și transformă pista în H.264 fără sunet.

Helperul este compilat universal pentru `arm64` și `x86_64`, cu o configurație
LGPL 2.1+ fără componente GPL. DMG-ul include licența, arhiva sursei corespunzătoare,
checksumul și scriptul reproductibil de build.

Sursă: https://ffmpeg.org/legal.html

### Import YouTube

Termenii YouTube interzic descărcarea conținutului în afara cazurilor autorizate expres de serviciu sau acoperite de permisiunile scrise cerute. Politicile YouTube API interzic clienților API să descarce, importe, facă backup, cache sau să stocheze copii ale conținutului audiovizual fără aprobare prealabilă. Din acest motiv, funcția are confirmare explicită, nu încearcă să ocolească autentificarea/DRM și rămâne dezactivată în distribuția publică până la review juridic.

Surse:

- https://www.youtube.com/static?template=terms
- https://developers.google.com/youtube/terms/developer-policies

Pentru prototipul local, `yt-dlp` oferă metadata JSON (`--dump-single-json`), output pe linii și template-uri de progres. Există și un binar universal macOS, ceea ce permite izolarea helperului în bundle în locul unei dependențe Homebrew la client. Backendul folosește `--ignore-config`, `--no-playlist`, un director temporar unic și argumente `Process` separate.

Surse:

- https://github.com/yt-dlp/yt-dlp/blob/master/README.md
- https://github.com/yt-dlp/yt-dlp/releases

### Teste

- Swift Testing pentru unit și integration tests.
- XCTest UI pentru fluxurile Library/Apply/Restore.
- Fixtures plist anonimizate pentru adapterele Lock Screen.

Surse:

- https://developer.apple.com/documentation/testing
- https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project

### Logging și diagnostic

Folosim `Logger` din OSLog în loc de fișiere text ad-hoc. Mesajele sensibile sunt private implicit, iar utilizatorul poate exporta un raport anonimizat.

Sursă: https://developer.apple.com/documentation/os/logging/

## Skill-uri instalate pentru următoarea etapă

- `security-best-practices` — review de securitate în timpul implementării.
- `security-threat-model` — modelarea riscurilor pentru import, helper și Lock Screen Experimental.
- `screenshot` — QA vizual al interfeței native.

Catalogul nu conține în prezent un skill dedicat dezvoltării Swift/macOS. Zona experimentală a catalogului nu a fost disponibilă la verificare.
