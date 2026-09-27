# Plan de produs și implementare

## 1. Viziune

Aplicația va fi un utilitar macOS nativ care administrează o bibliotecă personală de imagini și videoclipuri și permite alegerea independentă a conținutului pentru:

- Desktop;
- Screen Saver;
- Lock Screen.

Cerința centrală este ca videoclipul ales pentru Lock Screen să fie redat de macOS chiar în spatele interfeței de autentificare atunci când sesiunea utilizatorului este blocată, inclusiv după `Control–Command–Q`. Nu este suficient un preview în aplicație sau o fereastră care imită Lock Screen.

Interfața trebuie să se simtă ca o aplicație Apple: SwiftUI, controale standard, sidebar, toolbar, meniuri și scurtături macOS, suport complet pentru Light/Dark Mode și fără design web introdus într-o fereastră nativă.

Numele de lucru este `Wallpaper Studio`; numele final va fi ales înainte de semnare și distribuție.

## 2. Principii

1. Funcțiile bazate pe API-uri publice Apple sunt implicite și stabile.
2. Integrarea Lock Screen care atinge structuri interne macOS este marcată `Experimental`, dezactivată implicit și are întotdeauna backup și Restore.
3. Aplicația nu trebuie să ascundă, acopere sau intercepteze interfața de autentificare macOS.
4. Importul media nu modifică originalul utilizatorului. Aplicația lucrează numai pe copii din propria bibliotecă.
5. Conversia, generarea de thumbnails și I/O-ul se execută în afara thread-ului principal.
6. Video-ul este oprit sau redus când ecranul doarme, sesiunea nu este activă, Low Power Mode este pornit ori starea termică este ridicată.
7. Prima versiune nu cere conturi și nu include tracking. Rețeaua este folosită numai când utilizatorul pornește explicit un import YouTube.

## 3. Platformă și compatibilitate

- Deployment target: macOS 15 Sequoia.
- Validare suplimentară: macOS 26 Tahoe.
- Arhitecturi de distribuție: `arm64` și `x86_64`.
- Limbaj: Swift 6, cu un target Objective-C mic numai dacă modulul Screen Saver o cere pentru compatibilitate maximă.
- UI: SwiftUI, cu AppKit pentru ferestrele de wallpaper și integrările de sistem.
- Distribuție principală: aplicație Developer ID, Hardened Runtime, notarizată, în afara Mac App Store.

## 4. Experiența principală

### Sidebar

- Library
- Desktop
- Screen Saver
- Lock Screen
- Automation

### Library

- Grid cu preview-uri, nume, durată, rezoluție și stare de procesare.
- Import local prin buton, drag and drop și meniul File.
- Import YouTube printr-un flux separat: URL, preview metadata, confirmarea drepturilor și pregătire locală.
- Filtre pentru All, Videos, Images și Favorites.
- Search nativ.
- Acțiuni: Rename, Favorite, Reveal in Finder, Reprocess, Delete.
- Inspector cu crop mode, punctul cadrului static, calitate și preview.

### Configurator

Ecranul principal folosește un singur editor și trei destinații selectabile:

1. Desktop: imagine macOS, imagine/video din Bibliotecă sau Off.
2. Screen Saver: imagine/video, Follow Desktop sau Off.
3. Lock Screen: Follow Screen Saver, imagine/video, System Default sau Off.

Pentru fiecare destinație sunt grupate separat sursa, ecranele și redarea. Un
toggle alege între toate ecranele și un singur ecran identificat prin UUID stabil.
Bara fixă de jos arată starea, permite anularea modificărilor și aplicarea unei
singure destinații sau a întregului profil. Interfața folosește exclusiv materiale,
text și contrast semantic macOS, fără accente cromatice explicite.

### Menu bar

- Pause/Resume wallpaper.
- Next item.
- Open Library.
- Active profile.
- Low Power status.
- Quit engine / Quit app.

## 5. Arhitectură

### Targets

1. `WallpaperStudio.app` — interfața, biblioteca, importul și configurarea.
2. `WallpaperRenderer` — agent inclus în bundle, pornit cu acordul utilizatorului prin `SMAppService`.
3. `WallpaperStudio.saver` — modul Screen Saver bazat pe `ScreenSaverView` și AVFoundation.
4. `WallpaperStudioTests` — teste unitare și de integrare cu Swift Testing.
5. `WallpaperStudioUITests` — fluxuri critice cu XCTest UI.

### Module logice

- `MediaLibrary`: catalogul, folderele și metadata.
- `MediaPipeline`: inspectare, copiere, transcodare, poster și thumbnail.
- `YouTubeImportService`: validare strictă URL, metadata și download unic prin helper izolat.
- `DesktopImageService`: imagine statică prin API-ul public `NSWorkspace`.
- `DesktopVideoEngine`: ferestre AppKit la nivelul Desktopului, câte una pentru fiecare display.
- `ScreenSaverService`: build, instalare, configurare și verificare pentru `.saver`.
- `LockScreenAdapter`: compatibilitate Sequoia/Tahoe, backup, apply, verify și restore.
- `RuntimeConfiguration`: configurație JSON versionată și scrisă atomic pentru agent și screen saver.
- `PowerPolicy`: sleep/wake, sesiune, Low Power Mode și thermal state.
- `Diagnostics`: `Logger`, evenimente și export de diagnostic fără date personale implicite.

### Persistență

- Manifest JSON versionat, gestionat de un actor și scris atomic pentru metadata din Library.
- Fișiere media în `~/Library/Application Support/<bundle-id>/Media/<UUID>/`.
- Thumbnails și postere regenerabile în `Caches`.
- Configurația activă într-un JSON mic, versionat, accesibil proceselor incluse.
- Backupurile Lock Screen într-un director separat, cu hash, versiune de macOS și dată.

## 6. Pipeline media

### Import local

1. Utilizatorul alege un fișier cu `fileImporter`/`NSOpenPanel` sau drag and drop.
2. Aplicația validează tipul UTType și existența unei piste video sau a unei imagini valide.
3. Originalul este copiat într-un staging directory.
4. Se încarcă asincron durata, dimensiunea, transformarea, codec-ul și HDR.
5. Se generează thumbnail și poster.
6. Pentru video se creează un `.mov` HEVC pregătit pentru redare, fără audio în varianta de wallpaper.
7. Rezultatul este mutat atomic în Library și apare `Ready`.

### Profiluri de calitate

- Efficient: maximum 1080p HEVC.
- Native: păstrează rezoluția până la 4K.
- Original: passthrough numai dacă fișierul este deja compatibil.

AVFoundation este motorul implicit. FFmpeg nu intră în MVP; poate deveni ulterior un importator opțional pentru formate pe care AVFoundation nu le poate deschide.

### Import YouTube

1. Se acceptă numai URL-uri HTTPS de video individual `youtube.com` sau `youtu.be`; playlisturile sunt respinse.
2. Metadata este citită înainte de download și se afișează titlul, canalul și durata.
3. Utilizatorul trebuie să confirme că descărcarea este autorizată de YouTube sau că deține permisiunile scrise necesare. Confirmarea este versionată și valabilă numai pentru acțiunea curentă.
4. Helperul `yt-dlp` este invocat direct prin `Process.arguments`, fără shell, configurație externă, cookie-uri sau autentificare.
5. Limitele inițiale sunt două ore și 2 GB. Se cere un singur stream MP4 H.264, apoi AVFoundation îl normalizează ca orice import local.
6. Fișierul intermediar stă într-un staging unic și este șters la final; numai copia pregătită intră în Library.

Backendul este implementat, însă funcția rămâne în spatele unui feature flag pentru distribuția publică până la verificarea juridică și de produs. Aplicația livrată va include un helper semnat în propriul bundle; nu va instala Homebrew și nu va descărca executabile la runtime.

## 7. Desktop

### Imagine statică

- Se aplică prin `NSWorkspace.setDesktopImageURL` pentru fiecare `NSScreen`.
- Se păstrează opțiunile de scaling per display.
- Este traseul complet suportat de Apple.

### Video

- `NSWindow` borderless, non-key, fără shadow și cu `ignoresMouseEvents = true`.
- Nivelul ferestrei este sub iconițele Finder și deasupra imaginii statice.
- `AVQueuePlayer` + `AVPlayerLooper` + `AVPlayerLayer` pentru loop continuu și decodare nativă.
- O instanță per display în MVP; optimizarea cu player partajat se evaluează după profilare.
- Rebuild controlat la schimbarea display-urilor și a Spaces.
- Pauză la screen sleep, sesiune inactivă, Low Power Mode și thermal pressure.
- Poster static dedesubt pentru ca Desktopul să nu devină negru la restartul rendererului.

## 8. Screen Saver

- Modul `.saver` instalat în `~/Library/Screen Savers` numai după o acțiune explicită în aplicație.
- Implementare `ScreenSaverView` cu `AVPlayerLayer`, fără audio, aspect fill/fit și loop.
- Preview-ul din System Settings folosește aceeași configurație activă.
- Aplicația verifică dacă modulul este instalat și oferă `Open Screen Saver Settings`.
- Selectarea automată prin preferințe interne va fi tratată ca opțiune experimentală; traseul stabil deschide panoul Apple pentru confirmarea utilizatorului.

## 9. Lock Screen

macOS nu oferă o API publică documentată pentru setarea independentă a unui video pe Lock Screen. Implementarea se împarte în două niveluri.

### Comportamentul cerut

| Situație | Rezultat țintă |
|---|---|
| Sesiune blocată cu `Control–Command–Q` | Video redat sub parola/Touch ID native macOS |
| Revenire din Screen Saver la autentificare | Video redat sub interfața nativă de autentificare |
| Logout către fereastra multi-user | Compatibilitate testată separat; nu este garantată de API publică |
| Pornire/restart cu FileVault sau înainte de încărcarea sesiunii | Poster static extras din video |

Redarea de la sesiunea blocată va fi realizată prin integrarea cu providerul Aerial/Wallpaper al macOS. Aplicația noastră nu va desena o fereastră proprie peste câmpul de parolă și nu va reproduce interfața de autentificare.

### Stable

- `System Default` sau `Follow Screen Saver`.
- Nu modifică structuri interne și nu ridică ferestre peste interfața de autentificare.
- Poate genera un poster static de fallback în propria bibliotecă.

### Experimental

- Modifică numai ramura `Idle` din store-ul wallpaper, fără a copia configurația `Desktop`.
- Pentru video, înregistrează controlat un asset Aerial din spațiul utilizatorului și configurează providerul nativ de Lock Screen să îl redea sub interfața de autentificare.
- Validează rezultatul prin blocarea reală a sesiunii; un preview din aplicație nu este considerat succes.
- Înainte de orice schimbare: copie a fișierelor, backup al `Index.plist`, validare plist și hash.
- Scriere atomică într-un fișier temporar, validare, apoi replace.
- După aplicare: verifică providerul și ID-ul selectat; dacă verificarea eșuează, restaurează automat.
- Adapter separat pentru fiecare versiune macOS cunoscută. O versiune necunoscută refuză schimbarea, nu încearcă euristic.
- Buton permanent `Restore Apple Defaults`.
- Fără `CGShieldingWindowLevel` și fără ferestre peste login/password UI.
- Generează un `lockscreen.png` din același video pentru faza de cold boot, când procesele și fișierele utilizatorului nu sunt încă disponibile pentru redare video.

Structura locală macOS 26.6 confirmă că `Desktop` și `Idle` sunt noduri separate în `AllSpacesAndDisplays` și `SystemDefault`, deci independența este posibilă tehnic, dar rămâne o integrare privată și fragilă.

## 10. Siguranță și confidențialitate

- Fără comenzi shell construite din nume sau căi furnizate de utilizator.
- API-uri Foundation pentru copiere, hash, plist și procese; argumentele sunt transmise separat când un proces este inevitabil.
- Niciun download automat de executabile.
- Nicio instalare Homebrew din aplicație.
- Importul YouTube nu folosește playlisturi, cookie-uri de browser, login, DRM sau opțiuni din fișierele de configurare ale helperului.
- URL-urile YouTube sunt validate după schemă, host exact și formă înainte de a porni un proces.
- Nicio parolă cerută sau stocată.
- Importul folosește acces acordat de utilizator și copiază fișierul în containerul aplicației.
- Logurile nu includ implicit căi complete sau nume de fișiere personale.
- Lock Screen Experimental are preview al operației, backup, verificare și restore.

## 11. Toolchain

### Necesare

- Xcode și `xcodebuild`.
- Swift 6 și Swift Concurrency.
- SwiftUI, AppKit, AVFoundation, AVKit, CoreGraphics, ScreenSaver, ServiceManagement, UniformTypeIdentifiers și OSLog.
- XcodeGen ca unealtă de dezvoltare pentru un proiect multi-target reproductibil.
- `yt-dlp` ca helper izolat pentru importul YouTube; inclus și semnat în bundle numai după aprobarea funcției pentru distribuție.
- Swift Testing și XCTest UI.
- Instruments: Time Profiler, Allocations, File Activity și Energy Log/Power Profiler.
- `codesign`, `notarytool`, `stapler` și `spctl` pentru livrare.

### Opționale

- FFmpeg numai într-o fază ulterioară pentru formate incompatibile; distribuirea lui cere o strategie explicită de licențiere LGPL/GPL.
- Sparkle pentru update-uri, numai după MVP și după modelarea securității update-ului.

## 12. Etape de livrare

### M0 — Foundation

- Pachet Swift inițial, modele, stocare atomică și test plan. **În lucru: backendul de bază este funcțional.**
- Proiectul XcodeGen multi-target se generează când începe etapa UI/targets de aplicație.
- Design tokens minime și shell-ul SwiftUI.
- Logging, error model și runtime configuration versionată.

### M1 — Library

- Import imagine/video, drag and drop și progres.
- Import YouTube individual, preview metadata, confirmarea drepturilor și pregătire locală.
- Metadata, thumbnail, poster și persistare.
- Conversie HEVC prin AVFoundation.
- Grid, search, inspector, favorites și delete sigur.

### M2 — Desktop

- Imagine statică prin API publică.
- Video wallpaper per display.
- Fill/Fit, pause/resume, Spaces, display reconnect și fallback poster.
- Agent la login cu consimțământ prin `SMAppService`.

### M3 — Screen Saver

- Target `.saver`, preview și redare full screen.
- Instalare/actualizare controlată.
- Alegere din aceeași Library și deschiderea System Settings.

### M4 — Lock Screen Experimental

- Parser și model de compatibilitate pentru `Index.plist`.
- Adapter macOS 15 și macOS 26.
- Asset Aerial, apply numai pe `Idle`, backup, verify și restore.
- Teste cu fixtures anonimizate și teste manuale de restart/lock/unlock.

### M5 — Polish și distribuție

- Accessibility, VoiceOver, keyboard navigation și localization RO/EN.
- Profilare CPU/GPU/memorie/energie.
- Build universal, Developer ID, Hardened Runtime și notarizare.
- DMG/ZIP, release notes și ghid de recovery.

## 13. Criterii de acceptare pentru prima versiune

- Importul nu blochează interfața și originalul nu este modificat.
- Importul YouTube nu pornește fără confirmarea explicită și nu acceptă URL-uri din afara domeniilor aprobate.
- Library revine identic după relansare.
- Imaginea statică poate fi aplicată separat pe fiecare monitor.
- Video-ul rămâne sub iconițe, nu primește click-uri și funcționează în toate Spaces.
- Redarea se oprește la sleep și se reia corect la wake.
- Modulul Screen Saver rulează atât în preview, cât și full screen.
- Desktop, Screen Saver și Lock Screen pot avea selecții diferite acolo unde sistemul permite.
- După `Control–Command–Q`, video-ul selectat este redat de componenta nativă macOS sub controalele de autentificare.
- La cold boot/FileVault apare posterul corect extras din același video; aplicația nu promite video înainte de încărcarea sesiunii.
- Orice operație experimentală Lock Screen poate fi restaurată complet.
- Pe o versiune macOS necunoscută, aplicația nu scrie în store-ul wallpaper.
- Testele unitare, de integrare și UI trec pe configurația Release.
- Bundle-ul este semnat corect și poate trece validarea de notarizare.

## 14. Decizii amânate

- Numele comercial și identitatea vizuală.
- Activarea importului YouTube în buildul public, după review juridic și verificarea termenilor valabili la lansare.
- Playlisturi, cont YouTube, clipuri private sau age-restricted; nu intră în MVP.
- Marketplace de wallpaper-uri; nu intră în MVP.
- Sync iCloud al bibliotecii; nu intră în MVP.
- Mac App Store: posibil numai ca ediție redusă, fără instalare `.saver` și fără Lock Screen Experimental.
