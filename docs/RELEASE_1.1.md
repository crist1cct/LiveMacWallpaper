# Wallpaper Studio 1.1

## Lock Screen și Login Window

Integrarea veche care înlocuia un fișier Apple Aerial a fost eliminată. Pe macOS
26, wallpaperurile Tahoe sunt livrate din volumul de sistem semnat și pot fi
recreate ori recitite de serviciile Apple, motiv pentru care înlocuirea unui slot
din cache nu garanta ce apărea la autentificare.

Versiunea 1.1 instalează, cu aprobarea administratorului:

- `LoginWallpaperRenderer.app` în `/Library/Application Support/Wallpaper Studio`;
- videoclipul și configurația într-o locație comună, accesibilă înainte de login;
- un LaunchAgent în `/Library/LaunchAgents`, limitat la sesiunile `Aqua` și
  `LoginWindow`.

Rendererul folosește AppKit și AVPlayer, creează câte o fereastră pentru ecranele
alese și o poziționează imediat sub nivelul ferestrelor normale, astfel încât
controalele Apple de autentificare să rămână deasupra. Redarea este oprită la
deblocare și când displayul intră în sleep.

Ecranul FileVault Preboot rămâne în afara domeniului aplicației: apare înainte de
încărcarea macOS și nu poate executa un LaunchAgent AppKit.

## Interfață

- Biblioteca folosește un hero cinematic și carduri 16:9 inspirate de Apple TV.
- Preview-ul video nu mai afișează controlerul flotant AVPlayer.
- Configurarea folosește o paletă Apple neutră: negru, alb, gri și materiale native.
- Instalarea/actualizarea videoclipului este în Configurare → Lock Screen.
- Lock Screen păstrează control separat pentru ecrane, umplere/încadrare,
  redimensionare, poziție și sunet.

## Redare și eficiență

- Pe Desktop, videoclipul și sunetul se opresc automat pe monitorul acoperit de
  orice fereastră normală și continuă când desktopul redevine vizibil.
- Screen Saver creează la aplicare o copie de redare HEVC/H.264 adaptată
  monitorului (1080p sau 4K, maximum 60 fps). Fișierul original din bibliotecă
  rămâne intact, iar copia este refolosită la următoarea aplicare.

## Migrare

La prima instalare, componenta nouă oprește vechiul daemon Aerial și restaurează
copia fișierului Apple atunci când backupul versiunii anterioare este disponibil.
