# Build și distribuție

## Artefact curent

- Versiune: 1.5.4
- Format: DMG cu aplicația și shortcut către Applications
- Arhitecturi: Apple Silicon (`arm64`) și Intel (`x86_64`)
- Conținut inclus: aplicație, renderer Desktop, modul Screen Saver, utilitar pentru
  eliminarea integrărilor Lock Screen vechi, helper YouTube și FFmpeg universal
- Deployment target: macOS 15+
- Semnătură curentă pentru QA: Apple Development
- Notarizare: nu este efectuată fără certificat `Developer ID Application` și profil notarytool

Buildul 1.5.4 înregistrează automat providerul Wallpaper Studio la prima pornire
din `/Applications` și curăță înregistrarea explicită înainte de aplicare. Pentru
distribuție către alte persoane, semnătura Apple Development nu este suficientă:
folosește Developer ID + notarizare, altfel WallpaperAgent poate refuza extensia
chiar dacă aplicația principală se deschide.

## Generare

```sh
Tools/package_release.sh
```

Scriptul verifică checksumul helperului, generează proiectul, construiește ambele
arhitecturi, asamblează componentele, semnează bundle-urile, verifică semnătura,
creează DMG-ul și scrie un checksum SHA-256.

## Distribuție publică

După instalarea certificatului Developer ID și configurarea unui profil notarytool:

```sh
SIGN_IDENTITY="Developer ID Application: Nume (TEAMID)" \
NOTARY_PROFILE="wallpaper-studio-notary" \
Tools/package_release.sh
```

În acest mod scriptul folosește timestamp securizat, trimite DMG-ul la Apple,
aplică ticketul de notarizare și îl validează.

## QA realizat

- toate cele 30 de teste Swift trec;
- build Debug și Release universal reușit;
- semnătura ad-hoc a aplicației și a componentelor este validă;
- DMG verificat prin checksum-ul intern `hdiutil`;
- executabilele aplicației, rendererului și Screen Saverului conțin ambele arhitecturi;
- helperul YouTube inclus pornește și raportează versiunea corectă;
- bundle-ul Screen Saver se încarcă și expune clasa principală corectă;
- schema 1 este migrată automat la schema 2;
- UUID-urile monitorului real au fost reconstruite și comparate cu selecția;
- rendererul raportează exact monitoarele pe care a pornit, iar aplicația refuză
  confirmarea dacă răspunsul diferă.
- redarea Desktop se oprește împreună cu sunetul când o fereastră acoperă
  monitorul și revine numai după ce desktopul devine din nou vizibil;
- Screen Saver folosește o copie de redare optimizată pentru rezoluția monitorului,
  cu decodare hardware și maximum 60 fps.

Captura vizuală automată nu a putut fi efectuată deoarece macOS nu a acordat
permisiunea Screen Recording procesului Codex. Aceasta nu afectează buildul sau
funcționarea aplicației.
