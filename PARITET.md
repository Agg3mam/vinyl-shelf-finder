# Paritet: Mac og Windows

Hvad hver app kan. Målet er ✅ i begge kolonner. Opdatér tabellen i samme commit som ændringen (se `CLAUDE.md`).

✅ = findes · ❌ = mangler · — = giver ikke mening på platformen (med begrundelse)

| Funktion | Mac | Windows | Bemærkning |
|---|---|---|---|
| Søg, plade-detalje, Find i reolen, Sæt tilbage, Flyt | ✅ | ✅ | |
| Sektioner, Kontrollér sektion, sektionsgrænser (⇄) | ✅ | ✅ | |
| Nye / Fjernet fra Discogs / Ude af reolen | ✅ | ✅ | |
| Cover Flow | ✅ | ✅ | Altid hvid baggrund (ikke tonet efter coveret), også i mørk tilstand. Også på iPhone og i webappen |
| Historik med Fortryd | ✅ | ✅ | |
| Hvad skal jeg høre? / Lyttelog | ✅ | ✅ | |
| Værdi (estimat og markedsdata) | ✅ | ✅ | |
| Find nye plader, Discogs-vindue, ønskeliste | ✅ | ✅ | |
| iMusic som købssted | ✅ | ✅ | |
| Cd'er som egen hylde, skiftet Plader / Cd'er | ✅ | ✅ | |
| Kom i gang (forbind, hent, opret reol) | ✅ | ✅ | |
| Reolskilte med QR-kode | ✅ | ✅ | Mac: PDF. Windows: HTML til udskrift |
| Daglig sikkerhedskopi | ✅ | ✅ | |
| Opdatering fra GitHub ("Opdatér nu") | ✅ | ✅ | |
| Søg efter opdatering manuelt | ✅ | ✅ | Mac: appmenuen. Windows: "Opdatering" i sidepanelet |
| Sorteringsliste med flueben | ✅ | ✅ | |
| instance_id over 32 bit | ✅ | ✅ | Mac havde aldrig fejlen (Swift `Int` er 64 bit) |
| Digitale filer står ikke på en hylde | ✅ | ✅ | En fil, der allerede har en plads, bliver stående (begge apps) |
| Sortering: "Tal sidst" | ✅ | ✅ | Standard: til på Windows, fra på Mac (en opdatering må ikke ændre Mac-sorteringen) |
| Sortering: "Efternavn først" | ✅ | ✅ | |
| Eksport / import / nulstil | ✅ | ✅ | Samme filformat: en eksport fra den ene kan importeres i den anden |
| `vinylshelf://`-adresser (QR åbner appen) | ✅ | ✅ | Windows registrerer adressen for brugeren og kører kun ét vindue |
| Konto i skyen (Supabase): log ind med e-mail, synkronisering | ✅ | ✅ | Samme poster og felter, sikkerhedskopi før reoler slettes. iPhone-appen bruger samme konto (se nedenfor) |
| Adgangskode til kontoen (vælges under Konto; login uden mail) | ✅ | ✅ | `setPassword`/`SetPasswordAsync`, `signIn`/`SignInAsync`. Også på iPhone, hvor det er første valg |
| Ny søgning: faste rangeringsregler (som Algolia/Meilisearch), stavefejl efter ordlængde, romertal, "acdc"/"okcomputer", albummer før sange | ✅ | ✅ | `Search.swift` / `Search.cs` giver identisk rækkefølge (afprøvet på 907 søgninger; fælles checks "søgning ...") |
| Søg på en sang (sanglister fra Discogs, hentes i baggrunden) | ✅ | ✅ | Skema v7 (`release_tracks`). Sangen vises under resultatet og fremhæves i "Sange" på pladen. Status og "Hent sanglister" under Indstillinger › Discogs. Følger med via kontoen (feltet `tracks`) |
| QR-koden på et trykt skilt følger sektionen til andre enheder | ✅ | ✅ | Feltet `code` i sektionens post (`locations.scan_code`). Begge gemmer koden, når skiltene laves (Windows fra 19. okt; allerede trykte skilte virker, når skiltene er åbnet én gang efter opdateringen) |
| Mobilside på lokalnettet | ❌ | ❌ | Halvt lavet (kun ruter), ingen server endnu |

## iPhone-appen (`ios/`)

En tredje app, ikke en kopi af Mac/Windows: den viser og finder, men ændrer ikke reolerne. Den bruger
`VinylCore` direkte (Swift-pakkens bibliotek), så søgning, naboer og Find-teksterne er præcis de samme som på Mac.
Data kommer kun fra kontoen i skyen (ingen Discogs-forbindelse på telefonen).

| Funktion | iPhone | Bemærkning |
|---|---|---|
| Log ind (link eller kode fra mailen) og automatisk synkronisering | ✅ | Linket i mailen åbner appen direkte (`vinylshelf://auth`) |
| Søg (tåler stavefejl), Find i reolen, naboer | ✅ | Samme tekster som Mac (`referenceAdvice`) |
| Reoler og sektioner (plader og cd'er) | ✅ | Kun visning |
| Scan QR-koden på et reolskilt | ✅ | I appen (VisionKit) eller med Kamera-appen |
| "Spillet" | ✅ | Synkroniseres til Mac og Windows |
| Søg på en sang og se sanglisten | ✅ | Sanglisterne kommer fra computeren via kontoen |
| Cover Flow i en sektion | ✅ | Knap øverst til højre (liste/Cover Flow). Samme geometri (`CoverFlowGeometry`), hvid baggrund, haptik for hver plade og ved enden |
| Hvad skal jeg høre? (fanen "Hør") | ✅ | Samme filtre og `ListenPicker` som Mac. Cover Flow snurrer hen til forslaget |
| Flytte plader, sektioner, Discogs, Værdi, Find nye plader | ❌ | Laves på computeren |


## Webappen (`web/`)

En fjerde udgave: en webside, der lægges på telefonens hjemmeskærm ("Føj til hjemmeskærm"). Gratis, uden App Store
og uden 7-dages grænse. Den kan det samme som iPhone-appen og ændrer heller ikke reolerne. Søgning og "Find i
reolen" er en JavaScript-port af `Search.swift` og `Library.swift` (`web/core/`); checken "Webappens checks"
(`web/checks/run.sh`) sammenligner med Swift ved hver push: samme top-20 og samme tekster.

| Funktion | Web | Bemærkning |
|---|---|---|
| Log ind med e-mail og adgangskode, mail-link som reserve | ✅ | Linket fra mailen kopieres og sættes ind (en hjemmeskærm-app deler ikke login med Safari) |
| Hentning fra kontoen, gemt i browseren (virker uden net) | ✅ | IndexedDB. Synk ved start, når appen kommer frem, kort efter "Spillet" og hvert 5. minut |
| Søg (tåler stavefejl), også sange | ✅ | Identisk med Swift (`web/checks`) |
| Reoler og sektioner (plader og cd'er), Find i reolen, naboer | ✅ | Samme tekster som Mac (`referenceAdvice`) |
| Scan QR-koden på et reolskilt | ✅ | I webappen med kameraet (jsQR i `web/vendor`). Kamera-appen åbner `vinylshelf://` i den rigtige app, ikke i webappen |
| "Spillet" | ✅ | Samme post som iPhone (enhed `web`); gemmes og sendes senere, hvis der ikke er net |
| Cover Flow i en sektion og "Hør" (Hvad skal jeg høre?) | ✅ | Som iPhone. Port af `CoverFlowGeometry` og `ListenPicker` i `core/library.js`. Haptik: Android vibrerer; iPhone bruger iOS' kontakt-klik (iOS 18+), da Safari ikke har et haptik-API |
| Log ud | ✅ | Fjerner også reolerne fra telefonen (iPhone-appen beholder dem), da en webside kan deles af flere |
| Flytte plader, sektioner, Discogs, Værdi, Find nye plader | ❌ | Laves på computeren |
