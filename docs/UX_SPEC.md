# Specificație UX — backend și fluxuri

Data: 5 septembrie 2026  
Stadiu: implementat în interfața SwiftUI.

## 1. Obiectiv

Aplicația trebuie să facă o operație tehnică dificilă să pară simplă: utilizatorul adaugă conținut o singură dată, alege separat ce apare pe Desktop, în Screen Saver și pe Lock Screen, apoi apasă `Aplică`.

Principiul de bază este controlul fără surprize. Nicio selecție pentru o destinație nu o schimbă implicit pe alta, cu excepția cazului în care utilizatorul alege explicit `Urmează Desktopul` sau `Urmează Screen Saverul`.

## 2. Arhitectura informației

Sidebarul are patru zone în MVP:

1. `Bibliotecă` — import, căutare și administrare media.
2. `Configurează` — Desktop, Screen Saver și Lock Screen într-un singur composer.
3. `Automatizare` — pornire la login și reguli de energie; poate fi ascuns până când agentul există.
4. `Setări` — calitate implicită, stocare, diagnostic și funcții experimentale.

Toolbarul conține numai acțiunile dependente de context:

- în Bibliotecă: `Importă`, Search și schimbarea Grid/List;
- în Configurează: selectoare de monitor pentru fiecare destinație și `Aplică`;
- acțiunile rare rămân în meniurile aplicației sau în inspector.

## 3. Prima lansare

Prima lansare nu afișează un wizard lung. Ecranul gol din Bibliotecă explică produsul și oferă două acțiuni:

- `Alege fișiere…` — acțiunea principală;
- `Importă din YouTube…` — acțiune secundară, prezentă numai dacă feature flag-ul este activ.

Sub acțiuni apare textul: „Fișierele originale rămân nemodificate. Wallpaper Studio pregătește copii optimizate în biblioteca sa.”

Permisiunile și Login Item nu sunt cerute la pornire. Sunt solicitate în context, când utilizatorul activează pentru prima dată funcția care le cere.

## 4. Import local

### Intrări

- butonul `Alege fișiere…`;
- drag and drop în fereastra Bibliotecii;
- `File > Import Files…` cu scurtătura `⌘O`.

### Flux

1. Fișierul apare imediat ca un card placeholder.
2. Starea trece prin `Se verifică`, `Se copiază`, `Se optimizează`, `Se creează previzualizarea`, apoi `Gata`.
3. Importurile multiple sunt afișate separat; interfața rămâne utilizabilă.
4. La succes, cardul devine selectabil pentru toate destinațiile compatibile.
5. La eșec, cardul rămâne temporar cu motivul și acțiunile `Încearcă din nou` și `Elimină`.

În etapa curentă backendul emite fazele operației. Procentele necunoscute folosesc un indicator nedeterminat; UI-ul nu inventează un procent.

## 5. Import YouTube

Importul YouTube este un sheet dedicat, nu un câmp permanent în Bibliotecă.

### Pasul 1 — Link

- titlu: `Importă din YouTube`;
- câmp: `Link video`;
- acțiune: `Verifică linkul`;
- se acceptă un singur video, Short, Live arhivat sau link `youtu.be` prin HTTPS;
- playlisturile și domeniile asemănătoare sunt respinse local, înaintea rețelei.

Dacă helperul nu este disponibil, sheet-ul afișează: „Importul YouTube nu este inclus în această versiune a aplicației.” Nu recomandă Homebrew utilizatorului final.

### Pasul 2 — Verificare

După citirea metadata se afișează thumbnail, titlu, canal și durată. Utilizatorul poate verifica dacă a lipit clipul corect înainte de download.

Confirmarea obligatorie este debifată implicit:

„Confirm că descărcarea este autorizată de funcționalitatea YouTube sau că am permisiunile scrise necesare de la YouTube și deținătorii drepturilor.”

Butonul `Importă` rămâne dezactivat până la confirmare. Acceptarea nu este memorată global și nu elimină responsabilitatea verificării pentru următorul clip.

### Pasul 3 — Download și pregătire

Sheet-ul rămâne deschis și afișează:

1. `Se validează linkul`;
2. `Se citește informația video`;
3. `Se descarcă`;
4. fazele normale de pregătire locală;
5. `Adăugat în Bibliotecă`.

`Anulează` trebuie să oprească procesul și să elimine staging-ul; anularea completă va fi conectată când runnerul streaming este implementat. În backendul actual, închiderea sheet-ului nu trebuie prezentată ca anulare până când procesul nu este întrerupt efectiv.

### Limite și erori

- mai lung de 120 minute: „Clipul depășește limita de 2 ore.”
- mai mare de 2 GB: „Clipul depășește limita de import de 2 GB.”
- format indisponibil: „Nu am găsit o variantă video compatibilă pentru acest clip.”
- privat, restricționat sau protejat: „Acest clip nu poate fi importat fără acces sau permisiuni suplimentare.” Nu se oferă import de cookies.
- eroare de rețea: păstrează linkul și confirmarea în sheet, pentru retry în aceeași sesiune.

## 6. Bibliotecă

### Card media

Un card afișează preview, titlu, tip, rezoluție și durata pentru video. Badge-urile sunt rezervate pentru informație utilă: `Se pregătește`, `Eroare`, `Favorit` și `YouTube`.

Acțiuni contextuale:

- `Redenumește`;
- `Favorit`;
- `Arată în Finder`;
- `Reprocesează`;
- `Șterge din Bibliotecă…`.

Ștergerea explică faptul că elimină numai copia aplicației. Dacă elementul este folosit de un profil activ, utilizatorul trebuie să aleagă un înlocuitor sau să dezactiveze destinația înaintea confirmării.

### Stări

| Stare | Prezentare | Acțiune principală |
|---|---|---|
| Bibliotecă goală | explicație scurtă și zonă drag and drop | `Alege fișiere…` |
| Import activ | carduri placeholder și faza reală | continuă lucrul în aplicație |
| Fără rezultate | „Niciun element nu corespunde căutării.” | `Șterge filtrele` |
| Eroare de stocare | banner persistent, fără pierdere silențioasă | `Vezi detalii` |

## 7. Configurează

Composerul prezintă trei destinații, în această ordine:

### Desktop

- `Imagine statică`;
- `Video`;
- toate monitoarele sau o selecție individuală;
- încadrare și pauză în modul Consum redus;
- `Dezactivat`.

### Screen Saver

- un element din Bibliotecă;
- `Urmează Desktopul`;
- toate monitoarele sau o selecție individuală;
- `Dezactivat`.

### Lock Screen

- `Implicit Apple`;
- un element static;
- `Urmează Screen Saverul`;
- `Video experimental`, numai după activarea funcțiilor experimentale și verificarea compatibilității.

Fiecare destinație arată clar selecția rezolvată. Dacă Screen Saver urmează Desktopul, iar Desktopul este schimbat, preview-ul Screen Saver se actualizează înainte de Apply.

`Aplică` este dezactivat când există o referință lipsă, un ciclu între destinații sau media încă neprocesată. Validarea backend returnează eroarea exactă; UI-ul o atașează cardului relevant.

### Aplicare

Aplicarea este tratată ca o singură operație percepută de utilizator:

1. se validează profilul;
2. se salvează configurația versionată;
3. se aplică destinațiile stabile;
4. operația experimentală se execută separat, cu backup și verificare;
5. apare un rezumat: `Configurația a fost aplicată` sau destinația care necesită atenție.

## 8. Lock Screen video

Prima activare afișează o explicație, nu doar un switch:

„Wallpaper Studio folosește componenta video nativă macOS în spatele parolei și Touch ID. Integrarea nu este documentată public de Apple și poate necesita restaurare după un update de sistem.”

Acțiuni:

- `Activează funcția experimentală`;
- `Nu acum`.

Înainte de Apply, UI-ul arată starea verificată de backend:

- `Compatibil cu această versiune macOS`;
- `Structură neașteptată — nu vom modifica Lock Screen`;
- `Versiune macOS neverificată — funcția este indisponibilă`.

După aplicare, utilizatorul primește acțiunea `Blochează și verifică`. Testul real este Lock Screen nativ după `Control–Command–Q`, nu o imitație în aplicație.

Pentru pornire/restart cu FileVault, textul este explicit: „Înainte de încărcarea sesiunii macOS poate afișa numai posterul static extras din video.”

`Restaurează setările Apple` rămâne vizibil în Setări > Experimental chiar dacă aplicarea anterioară a eșuat.

## 9. Contract backend → UI

| Semnal backend | Comportament UI |
|---|---|
| `ImportPhase` | etichetă de fază; progres nedeterminat când valoarea nu există |
| `YouTubeHelperStatus` | arată disponibilitatea funcției și versiunea numai în diagnostic |
| `YouTubeMetadata` | card de confirmare înainte de download |
| `MediaItem` | sursa unică pentru card, inspector și selecțiile de destinație |
| `ProfileValidator` error | blochează Apply și indică destinația afectată |
| `RuntimeConfiguration` | sursa adevărului pentru profilul activ și procesele auxiliare |
| `LockScreenCompatibilityReport` | decide dacă opțiunea experimentală este disponibilă, fără presupuneri în UI |

View-modelurile din etapa UI vor apela numai `WallpaperBackend`; nu vor accesa direct fișierele, helperul sau store-ul intern macOS.

## 10. Copy și ton

- Se spune ce se întâmplă: `Se pregătește video`, nu `Procesare asset`.
- Erorile includ acțiunea posibilă și nu dau vina pe utilizator.
- Termenul `experimental` este folosit consecvent pentru Lock Screen video.
- Detaliile tehnice și versiunile helperului apar în Diagnostic, nu în fluxul principal.
- Nicio alertă nu promite video la cold boot.

## 11. Accesibilitate și tastatură

- Toate funcțiile sunt accesibile fără drag and drop.
- Ordinea de focus urmează sidebar → toolbar → conținut → inspector.
- Cardurile au label VoiceOver cu titlu, tip, durată și stare; preview-ul decorativ nu dublează informația.
- Se respectă Reduce Motion: preview-urile video nu pornesc automat când opțiunea este activă.
- Se respectă Increase Contrast și Differentiate Without Color; stările nu sunt indicate numai prin culoare.
- `⌘O` import local, `⌘F` căutare, `⌘,` Setări și `Space` preview pentru elementul selectat.

## 12. Confidențialitate și diagnostic

- Importul local nu folosește rețeaua.
- Pentru YouTube, rețeaua pornește numai după `Verifică linkul`; UI-ul nu face prefetch la simpla lipire.
- Nu se cer parole, cookies sau autentificare în browser.
- Diagnostic exportă stări și coduri de eroare, nu URL-uri complete ori nume personale implicit.
- Nu există analytics în MVP.

## 13. Criterii UX pentru etapa UI

- Un utilizator nou poate importa un fișier local și aplica un Desktop în mai puțin de un minut.
- Se vede permanent diferența dintre configurația editată și cea activă.
- Selecțiile celor trei destinații pot fi diferite fără efecte ascunse.
- Nicio operație lungă nu blochează fereastra principală.
- Funcția YouTube nu descarcă înaintea preview-ului și confirmării.
- Funcția Lock Screen video nu este prezentată ca API Apple garantată.
- Orice eșec oferă o cale clară: retry, schimbarea selecției, diagnostic sau restore.
