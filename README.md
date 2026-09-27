# Wallpaper Studio

Aplicație macOS nativă pentru o bibliotecă personală de imagini și videoclipuri,
cu selecții independente pentru Desktop, Screen Saver și Lock Screen.

Funcții principale:

- imagini sau video pe Desktop, aplicate pe toate monitoarele sau numai pe cel ales;
- Screen Saver propriu, cu aceeași alegere explicită a ecranului și stocare
  compatibilă cu izolarea de securitate macOS;
- conținut separat pentru blocare, pornit prin motorul Screen Saver autorizat de
  macOS 26, fără ferestre peste autentificare și fără modificarea fișierelor Apple;
- import local și YouTube la rezoluția maximă disponibilă;
- controale native de redare și aplicare rapidă pe fiecare destinație;
- redimensionare, zoom și poziționare liberă pentru video, plus volum opțional
  pe Desktop, Screen Saver și Login Window;
- conversie automată pentru formate incompatibile (inclusiv VP9 4K);
- pornire automată a rendererului și pauză în modul Consum redus;
- video și sunet oprite automat, separat pe fiecare monitor, cât timp desktopul
  este acoperit de o fereastră;
- copie de redare optimizată automat pentru Screen Saver, până la 4K/60 fps,
  fără modificarea fișierului original din bibliotecă.

## Versiunea 1.7 — redesign Apple TV

- interfață refăcută de la zero, în stilul aplicației Apple TV: fereastră
  întunecată fără bară de titlu, tab bar plutitor (Acasă · Bibliotecă · Setări),
  hero cinematic cu previzualizare video, rafturi orizontale și carduri cu efect
  de „focus” (ridicare, înclinare după cursor, reflexie);
- `Acasă` arată dintr-o privire ce rulează acum pe Desktop, în Screen Saver și pe
  Lock Screen; un clic pe oricare deschide pagina wallpaperului;
- fiecare wallpaper are o pagină proprie pe tot ecranul: alegi destinația,
  ecranul și sunetul, apoi un singur buton `Setează`; Esc închide, Enter aplică;
- căutare în bara de sus (⌘F), navigare cu ⌘1/⌘2/⌘3, Liquid Glass pe macOS 26;
- sunetul pe Lock Screen nu mai vine „în valuri”: audio urmează ceasul exact al
  buclei video, așteaptă (mut) cât imaginea accelerează după blocare și corectează
  deriva prin ajustări fine de viteză (±3 %, fără schimbarea tonului) în loc de
  salturi repetate; resincronizarea completă se face rar și în spatele unui fade.

Versiunea 1.1.4 folosește o configurație versionată care păstrează UUID-ul stabil al
monitorului ales. Aplicarea pe Desktop este confirmată de renderer pentru lista
exactă de ecrane, iar pachetul Screen Saver își verifică configurația după scriere.

## Build local

```sh
xcodegen generate
xcodebuild -project WallpaperStudio.xcodeproj -scheme WallpaperStudio build
```

## Teste

```sh
swift test
```

## DMG

Helper-ele universale din `Vendor` trebuie să corespundă versiunilor și
checksumurilor documentate în `Vendor/README.md`.

```sh
Tools/package_release.sh
```

Pentru distribuție publică fără avertismente Gatekeeper:

```sh
SIGN_IDENTITY="Developer ID Application: …" \
NOTARY_PROFILE="wallpaper-studio-notary" \
Tools/package_release.sh
```

Vezi `docs/PLAN.md`, `docs/RESEARCH.md` și `docs/UX_SPEC.md` pentru deciziile de
produs, limitele macOS și fluxurile UX.
