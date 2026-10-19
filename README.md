# Vinyl Shelf Finder

Et macOS-program, der finder dine fysiske vinylplader i reolen.
Discogs fortæller, hvad du ejer. Den lokale database fortæller, hvor det står.

> **Find X. Din plade står lige efter X og lige før Y.**

## På telefonen

**Webapp: <https://agg3mam.github.io/vinyl-shelf-finder/>** (gratis, ingen App Store)

Åbn linket i Safari på iPhone (eller Chrome på Android), tryk **Del › Føj til hjemmeskærm**, og log ind med den
samme e-mail og adgangskode som under Konto i appen på computeren. Så kan du søge, finde pladen i reolen, scanne
reolskilte, bruge Cover Flow og "Hvad skal jeg høre?", sætte flueben i sorteringslisten og registrere "Spillet".
Vil du bare se den, så prøv eksempeldata: <https://agg3mam.github.io/vinyl-shelf-finder/?demo>

## Kom i gang

```bash
./build-app.sh                                   # bygger build/Vinyl Shelf Finder.app
open "build/Vinyl Shelf Finder.app"              # rigtig samling (Discogs)
open "build/Vinyl Shelf Finder.app" --args --demo  # prøv med 43 eksempelplader
./build-app.sh --install                         # bygger og lægger appen i Programmer
```

Kræver macOS 26+ og Swift (Command Line Tools er nok, Xcode er ikke nødvendig).

1. Opret et token på <https://www.discogs.com/settings/developers> og indsæt det.
2. Appen henter din Collection.
3. Angiv reoler og sektioner, og justér grænserne, så de passer med virkeligheden → **Opret reol**.

## Brug

| Genvej | Handling |
|---|---|
| ⌘K | Søg (artist, titel, label, katalognr., release ID – tåler stavefejl) |
| ↑ ↓ | Vælg resultat |
| ↩ / ⌘F | **Find i reolen**: reol, sektion og de bedste referenceplader |
| ⇧⌘M | Flyt plade |
| ⌘R | Synkronisér med Discogs |

Andet:

- **Sektioner** i sidepanelet viser reolen digitalt ("Jeg står her"), inklusive sektionsgrænser. Plader, der ikke står i forventet sortering, markeres med ⇄.
- **Kontroller sektion** går sektionen igennem plade for plade: ✓ rigtigt, ⚠️ andet sted, ➕ mangler, ❓ ved ikke.
- **Nye plader**: efter en sync får hver ny plade et forslag ("mellem X og Y"). Du kan placere den med ét klik.
- **Status**: på plads, på væggen, udlånt (med navn), opbevaret andet sted (med sted), mangler. En plade, der er ude af reolen, tæller ikke med i nummereringen: de andre rykker sammen, og naboerne springer den over. Appen husker dens plads, og **Sæt tilbage på plads** viser præcis hvor den skal stå (som Find i reolen).
- **Historik** logger alle flytninger. Flytninger kan fortrydes.
- **Værdi**: Discogs' estimat for samlingen (min/median/max) samt laveste udbudspris, antal til salg og har/ønsker pr. plade.
- **Hvad skal jeg høre?**: tilfældigt forslag filtreret på genre, årti og "ikke hørt længe". Plader, du ikke har hørt længe, vægtes højere. Mellemrum giver et nyt forslag.
- **Lyttelog**: tryk "Spillet" (⌘L) på en plade. Viser mest spillede, seneste og antal aldrig spillede. En registrering kan fortrydes.
- **Find nye plader** (sidepanelet, kræver Discogs-forbindelse): søg i hele Discogs' katalog, vælg album og udgave, se laveste pris og antal til salg, og læg udgaven på din ønskeliste. **Køb på Discogs** åbner Discogs' egen salgsside i et vindue i appen – selve købet sker hos Discogs (API'et kan ikke købe), og appen læser eller gemmer aldrig login eller betaling.
- **iMusic.dk** som ekstra købssted: "Søg på iMusic" åbner iMusics søgning i din browser. Med dit eget produktfeed fra Daisycon (Indstillinger › iMusic) vises iMusics pris og lagerstatus, og "Køb på iMusic" åbner varen. Feedet hentes højst én gang i døgnet og gemmes kun som cache (`~/Library/Caches/VinylShelfFinder/imusic.sqlite`).
- **Reolskilte** (⌘P): en A4-PDF med ét skilt pr. sektion (første → sidste kunstner og antal) og en QR-kode `vinylshelf://section/<id>`, der åbner sektionen i appen.

## Arkitektur

```
Sources/
  VinylCore/          al logik – ingen UI
    Models.swift      Release (Discogs) ≠ Copy (fysisk kopi) ≠ Location (reol/sektion)
    Store.swift       SQLite-skema, flytninger, sync der aldrig rører placeringer
    Library.swift     naboer, sektionsgrænser, reference-mode, placeringsforslag
    Sorting.swift     konfigurerbare regler (The, AC/DC, Æ Ø Å, Various, overrides)
    Search.swift      lokal søgning med stavefejl-tolerance
    Discogs.swift     API-klient (rate limit, pagination)
    Keychain.swift    token i macOS' nøglering
    Backup.swift      daglig sikkerhedskopi af databasen
    DiscogsQueue.swift fælles kø (rate limit) og cache til Discogs-kald
    IMusicFeed.swift  iMusic: søge-URL, Daisycon-feed (streamet), separat cache, matching
  VinylShelfFinder/   SwiftUI-app
  VinylCoreChecks/    selvtest: swift run VinylCoreChecks
```

Vigtige designvalg:

- **Identitet**: releases identificeres med Discogs release ID. Hver fysisk kopi svarer til en Discogs *instance ID*, så to eksemplarer af samme pressing også er to forskellige kopier.
- **Rækkefølgen er sandheden**: `placements(copy_id, location_id, position)`. `previous`/`next` gemmes aldrig. De beregnes fra rækkefølgen, og positioner omnummereres i en transaktion ved hver flytning.
- **Sync er ikke-destruktiv**: metadata opdateres, og placeringer røres ikke. Plader, der forsvinder fra Discogs, markeres og slettes kun efter din bekræftelse.
- **Sorteringsregler flytter aldrig plader**, der allerede står. De bruges kun ved første opdeling og til forslag.
- **Klar til scanning**: tabellen `scan_codes` (kode → plade/release/sektion) og `locations.scan_code` er forberedt.

Data: `~/Library/Application Support/VinylShelfFinder/vinyl.sqlite` (demo: `demo.sqlite`).
Covers caches i `~/Library/Caches/VinylShelfFinder/covers`.

## Sikkerhedskopi

Appen gemmer selv en kopi af databasen én gang om dagen (ved start og derefter hver time, hvis
der ikke er taget en i dag). Kopierne hedder `vinyl-ÅÅÅÅ-MM-DD.sqlite` og ligger i
**iCloud Drive › Vinyl Shelf Finder backup**, eller i **Dokumenter** hvis iCloud Drive ikke er slået til.
De 14 nyeste beholdes. Se Indstillinger › Sikkerhedskopi.

Sådan gendannes en kopi:

1. Afslut appen (⌘Q).
2. Kør i Terminal (skift datoen ud med den kopi, du vil have tilbage):

```bash
cd ~/Library/Application\ Support/VinylShelfFinder
mkdir -p gammel && mv vinyl.sqlite* gammel/
cp ~/Library/Mobile\ Documents/com~apple~CloudDocs/Vinyl\ Shelf\ Finder\ backup/vinyl-2026-10-01.sqlite vinyl.sqlite
```

3. Åbn appen igen. Den nuværende database ligger i mappen `gammel`, hvis du fortryder.
