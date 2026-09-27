# Wallpaper Studio 1.0 — plan de refacere și lansare

## Obiectiv

Versiunea 1.0 separă fără ambiguități Desktop, Screen Saver și Lock Screen,
păstrează alegerea monitorului după repornire și confirmă destinația înainte de a
raporta aplicarea ca reușită.

## Schema configurației

- Schema runtime este versiunea 2.
- `DisplayTarget` are numai două stări: `all` sau `display(UUID)`.
- Configurațiile vechi cu `targetDisplayIDs` sunt migrate automat și rescrise
  atomic; biblioteca utilizatorului nu trebuie recreată.
- Un monitor deconectat nu produce aplicare pe alt monitor din greșeală. În UI,
  selecția este mutată controlat pe monitorul principal când lista se schimbă;
  rendererul refuză o configurație veche care nu mai poate fi rezolvată.

## Aplicare și verificare

| Destinație | Aplicare | Confirmare |
|---|---|---|
| Desktop video | câte o fereastră AppKit pe ecranul cerut | rendererul returnează profilul și UUID-urile ecranelor active |
| Desktop imagine | API-ul public `NSWorkspace` pentru fiecare ecran | URL-ul activ este recitit de la macOS pentru fiecare ecran |
| Screen Saver | pachet runtime separat, selectat automat în registrul modern macOS | modulul, configurația și UUID-urile ecranelor sunt recitite după scriere |
| Lock Screen nativ | comandă nativă Control–Command–Q după activarea Aerialului personal | slotul video și selecția Idle sunt verificate înainte de blocare |
| Lock Screen Aerial | copie HEVC video-only instalată cu backup și restaurare | fișierul este verificat byte-for-byte, apoi providerul/asset-ul Idle este recitit |

## UX și UI

- O singură destinație este editată la un moment dat.
- Sursa, ecranele și redarea sunt trei grupuri clare.
- Preview mare 16:10 și sumar permanent pentru conținutul ales.
- Acțiuni persistente: anulare, aplicarea destinației și aplicarea completă.
- Confirmarea reușită afișează numele monitoarelor raportate de renderer.
- Design monocrom, adaptiv Light/Dark, bazat pe materiale și culori semantice
  neutre macOS.
- Actualizarea Aerial este disponibilă numai în Configurează → Lock Screen.
- Aerialul arată explicit când videoclipul, formatul sau setările trebuie actualizate.

## Criterii de lansare

- toate testele Swift trec;
- aplicația, rendererul și extensia Screen Saver trec verificarea de tip și build;
- build universal `arm64` + `x86_64`;
- semnăturile interne sunt valide;
- DMG-ul conține numai aplicația și shortcut-ul Applications la rădăcină;
- checksum SHA-256 generat;
- pentru distribuție publică fără avertisment Gatekeeper: semnare Developer ID,
  notarizare și staple cu acreditările titularului.

## Limită macOS

Apple nu oferă un API public pentru video independent în fereastra standard de
autentificare. Integrarea folosește un slot Aerial video-only și rămâne dependentă
de implementarea macOS, care poate fi schimbată de actualizări de sistem.
Sunetul este disponibil în Screen Saver-ul Wallpaper Studio, nu în Aerialul nativ.
Înainte de prima autentificare după pornire, FileVault și macOS controlează complet
ecranul; un proces al utilizatorului nu poate reda video în acea fază.
