# Handoff: Vinyl Shelf Finder (hele projektet)

**Opdateret:** 18. oktober 2026 (Windows: rettelser, sorteringsliste, eksport/import, efternavn, gren `claude/ret-tokenfelt`).

**Dette er den eneste handoff-fil.** Den indeholder alt, en ny Claude-session skal vide for at
arbejde videre på projektet, uanset hvad opgaven er. Giv den videre som den første besked,
fx: *"Læs HANDOFF.md, og hjælp mig med …"*. Opdatér filen, når der er lavet noget nyt.

`README.md` er brugervejledningen. Personlige oplysninger (om brugeren, netværk og computere) står kun i
`HANDOFF-privat.md`, som ligger lokalt og aldrig lægges på GitHub. Læs den, hvis den findes.
Gamle handoffs ligger kun som arkiv i `../design-work/` og skal ikke læses.

---

## 1. Hvad appen er

En native macOS-app (SwiftUI og SQLite), som finder fysiske vinylplader i reolen ud fra
brugerens Discogs-samling. Kernen er nabosystemet: *"Find X. Din plade står lige efter X og
lige før Y."*

Funktioner, der virker i dag (sidepanelet):

| Område | Indhold |
|---|---|
| Søg + Find i reolen | Lokal søgning, der tåler stavefejl. "Find i reolen" viser reol, sektion, naboer og referenceplader |
| Sektioner | "Jeg står her", sektionsgrænser og ⇄ ved plader, der står uden for sorteringen. Kontrol af sektionen sker plade for plade |
| Nye plader / Fjernet fra Discogs / Ude af reolen | Indbakke efter en sync. Forslag til placering. Status: på plads, **på væggen**, udlånt, opbevaret andet sted, mangler |
| Historik | Alle flytninger. De kan fortrydes |
| Værdi | Discogs' estimat for hele samlingen og markedsdata for hver plade |
| Hvad skal jeg høre? / Lyttelog | Tilfældigt forslag ud fra filtre, og registrering af spillede plader (⌘L) |
| **Find nye plader** | Søgning i hele Discogs' katalog med billigste køb øverst. Købet sker i et Discogs-vindue inde i appen. iMusic.dk som ekstra købssted (søgning, og pris via brugerens Daisycon-feed) |
| Reolskilte (⌘P) | En A4-PDF med QR-kode pr. sektion. Koden er stadig `vinylshelf://`, så den virker kun på Mac'en |

Genveje: ⌘K søg, ↑↓ vælg, ↩/⌘F Find i reolen, ⇧⌘M flyt, ⌘L spillet, ⌘R sync, ⌘P skilte.

---

## 2. Sådan arbejdes der

- **Mac og Windows følges ad** (brugerens krav, 18. okt): en ændring i den ene app laves også i den anden i samme
  opgave. Se `CLAUDE.md` og tabellen i `PARITET.md`.
- **Dansk** og almindeligt sprog uden unødvendig teknik.
- **Spørg, før du bygger.** Stil få konkrete spørgsmål og giv en anbefaling. Fortæl om planen, og hvorfor.
- Giv gerne **flere forslag at vælge imellem**, helst **visuelt** (mockups eller skærmbilleder).
- Appen skal være **simpel**. Undgå at den virker "vibecoded": tilfældige gradienter, emoji,
  glas overalt eller uens afstande.
- **Store opgaver kan deles ud på parallelle agenter.** Hver agent arbejder i sin egen kopi
  med sine egne filer, og kun én agent redigerer en given fil. Hold agenterne effektive.
- "Tjek det selv" betyder: verificér selv i stedet for at bede brugeren teste.
- Afslut Mac-ændringer med `./build-app.sh --install`, og sig: *"Tryk ⌘Q og åbn appen igen fra Programmer."*

---

## 3. Regler, der ikke må brydes

1. **Brugerens rigtige database må ikke røres:** `~/Library/Application Support/VinylShelfFinder/vinyl.sqlite`.
   Test altid med `--demo` og en isoleret hjemmemappe:
   `CFFIXED_USER_HOME=<tom mappe i scratchpad> .build/debug/VinylShelfFinder --demo …`
2. **iMusic-feed-URL'en** (Daisycon) indeholder brugerens media_id. Den ligger kun i nøgleringen
   (service `dk.vinylshelffinder.imusicfeed`) og må aldrig logges, vises eller hentes i test.
3. **Discogs-tokenet** ligger kun i nøgleringen (service `dk.vinylshelffinder.discogs`). Det må
   aldrig udskrives, logges eller vises.
   - Brugeren har givet lov til et **begrænset antal læse-opslag** (cirka 20) med tokenet,
     når priser skal verificeres. Det sker via et lille testprogram, der læser tokenet i
     processen og kun udskriver svar-felter.
   - Spørg igen ved større runder.
   - Aldrig PUT/POST, køb eller ændringer på kontoen.
4. **discogs.com må ikke indlæses i test.** Discogs-vinduet testes med en lokal side.
5. **Skærmbilleder:** kun af demo-appens eget vindue med `screencapture -x -o -l <windowNumber>`, aldrig
   hele skærmen. Der er ingen Tilgængeligheds-tilladelse og derfor ingen tastetryk. Handlinger
   udløses inde fra appen med testkode.
6. Sikkerhedsindstillinger, nøglering og certifikater ændrer brugeren selv.
7. Projektet er et **git-repo** og ligger **offentligt** på GitHub: `https://github.com/Agg3mam/vinyl-shelf-finder`.
   - Commits bruger GitHubs skjulte e-mail. Brug aldrig brugerens rigtige e-mail eller computerens navn.
   - **Skriv aldrig personlige oplysninger i repoet** (navne, mapper, computernavne, IP-adresser, samlingens
     størrelse, brugerens vaner). De hører til i `HANDOFF-privat.md`.
   - Commit og push kun, når brugeren beder om det.
   - Byggefiler (`.build/`, `build/`, `*.app`) er udeladt via `.gitignore`.
   - Tag stadig en sikkerhedskopi i `../design-work/` før større eksperimenter.

**Hente projektet på en anden Mac** (kræver macOS 26+ og Command Line Tools: `xcode-select --install`):
```bash
gh repo clone Agg3mam/vinyl-shelf-finder && cd vinyl-shelf-finder && ./build-app.sh --install
```
Appen starter uden data. Forbind til Discogs i appen, eller prøv den med eksempeldata:
`open "/Applications/Vinyl Shelf Finder.app" --args --demo`.

---

**Grene (18. okt):** Alt er samlet i `main` (v1.1.0), og de gamle `claude/`-grene er slettet. Afsnittene nedenfor
nævner gamle grennavne som historik. Nyt arbejde laves i en ny gren fra `main`. En udgivelse laves ved at skubbe
grenen `claude/udgivelse-vX.Y.Z` (se `.github/workflows/udgivelse.yml`). `ci-snapshots` og `ci-snapshots-windows`
skrives af GitHub Actions og skal blive stående.

## 4. Teknik

- **Kun Command Line Tools, ingen Xcode.** Det er Swift 6.x med macOS 27 SDK, og brugerens Mac kører macOS 27.
  - Brug `@ViewState`, ikke `@State`. Det er et typealias i `App.swift`, fordi `@State`-makroens plugin kun følger med Xcode.
  - Ingen XCTest og ingen Swift Testing. Brug i stedet **`swift run VinylCoreChecks`**, som havde **305 checks**, alle grønne pr. 1. okt. Grenen `claude/quirky-franklin-9sjx8p` har **375 checks**. Grenen `claude/imusic-kobssted` (bygger videre på den) har **419 checks**, grønne på GitHub Actions (macOS 26, Swift 6.3).
    Tilføj checks for ny logik.
  - Store `body`-udtryk kan få compileren til at crashe. Del dem op i små views.
- **Minimum er macOS 26.** Liquid Glass (`.glassEffect`, `GlassEffectContainer`, `.glassProminent`) bruges direkte uden fallback.
- **Byg:** `swift build`. App-bundle: `./build-app.sh`, installation: `./build-app.sh --install`.
  - Appen signeres med certifikatet "Vinyl Shelf Finder Udvikler", hvis det findes. Ellers bliver den ad-hoc-signeret,
    og så spørger macOS om nøgleringen efter hver ny build. Brugeren har endnu **ikke** oprettet
    certifikatet. Det kan foreslås igen.
- Ved opstart læser appen kun tokenets attributter (`Keychain.hasToken`), så der kommer ingen nøgleringsdialog
  ved start. "Find nye plader" læser tokenet én gang pr. session.

### Kodekort

```
Sources/VinylCore/            al logik, ingen UI
  Models, Store, SQLite       skema, flytninger, ikke-destruktiv sync
  Library, Sorting, Search    naboer, sektionsgrænser, forslag, stavefejl-søgning
  Listening                   lyttelog, forslag, reolskilte (scanCode)
  Discogs, Keychain           API-klient (rate limit reaktivt), token
  DiscogsCatalog              katalogsøgning, udgaver (+ udbredelse), ønskeliste, URL'er
  Market                      priser: /marketplace/stats (valuta i svaret), Værdi-data, DKK⇄EUR
  MobileSite                  HTML + routing til mobilsiden (INGEN server endnu)
  Demo                        43 eksempelplader
Sources/VinylShelfFinder/     SwiftUI
  AppModel                    app-tilstand, sync, værdi-opdatering
  ContentView, ListViews, RecordDetailView, Sheets (1054 linjer: Find i reolen, flyt, kontrol …)
  ListeningViews, ValueView, SettingsView, OnboardingView, LabelsPDF, CoverView
  FindNewModel / FindNewViews (søgning) / FindNewDetailViews (billigste køb + udgaver)
  DiscogsBrowser              WKWebView-vindue: ingen scripts, ingen cookie-læsning, kun http(s)
  DesignTokens                Spacing, Typo, Ink, adaptive(light:dark:), GlassPanel, ContentSurface,
                              StageButtonStyle, Eyebrow, Motion (respekterer Reduce Motion), .recordStage
  Snapshot                    --snapshot <mappe>: offscreen-PNG af nøgleskærme
Sources/VinylCoreChecks/      selvtest (305 checks)
```

### Designprincipper i data (må ikke brydes)

- En release identificeres med sit Discogs release ID, og en fysisk kopi med sit instance ID.
- `previous`/`next` gemmes aldrig. De beregnes ud fra `placements(location_id, position)`.
- En sync flytter eller sletter aldrig fysiske placeringer.
- Plader, der er ude af reolen, beholder deres placering i databasen, men tæller ikke med i den fysiske nummerering.
- Sorteringen følger **præcis Discogs' rækkefølge** (`SortRules.useDiscogsOrder`, `copies.discogs_rank`).
- **En opdatering må aldrig ændre rækkefølgen på Mac'en** (brugerens krav, 18. okt). Placeringerne flyttes aldrig af
  en opdatering, men sorteringsreglerne bestemmer forslag og ⇄-markeringer. Nye sorteringsvalg (fx "Tal sidst" og
  "Efternavn først" fra Windows) skal derfor være **slået fra**, når de mangler i den gemte `sort_rules`, og må kun
  slås til af brugeren selv. Windows har "Tal sidst" slået til som standard; det må ikke kopieres til Mac.

---

## 5. Design (valgt og udrullet)

- **Retning 2 – Liquid Glass**, udrullet i hele appen.
  - Pladeskærmene (Find, plade-detalje, "Hvad skal jeg høre?", Find nye plader) bruger
    `.recordStage(release)` med en tonet scene ud fra coveret. Den følger lys og mørk tilstand: i lys tilstand er tonen bleg, og teksten mørk.
  - Systemskærmene bruger accentfarven `AppAccent` (blågrøn).
- Al tekst er på dansk. Der bruges SF Symbols, ikke emoji.
  - `CopyStatus` har stadig en gammel emoji-egenskab i `Models.swift`, men UI'et bruger `symbol`.
- **Mac-appen og mobilsiden skal dele samme udtryk.** Mobilsidens CSS i `MobileSite.swift` er
  stadig det gamle udkast "varm pladebutik" og skal laves om til Liquid Glass-udtrykket.
- Tidligere design-billeder ligger i `design-snapshots/` (fx `design-retning-*`, `endelig`, `lys-tilstand`).

---

## 6. Status pr. område

### Færdigt 1. oktober
- Design udrullet, polering og animationer (`Motion`), og rettelser efter brugertest.
- Status "På væggen" og guiden "Sæt tilbage på plads".
- "Find nye plader" er bygget om i flere omgange. Status lige nu (detaljer i afsnit 6a):
  - **Valutafejl rettet.** Discogs' `/releases/{id}` ignorerer `curr_abbr` og giver altid brugerens Discogs-valuta,
    som er **DKK**. Appen ganger derfor ikke længere kroner med 7,46. Prisen pr. udgave kommer nu fra `/marketplace/stats`,
    og det er verificeret mod det rigtige Discogs for 6 udgaver.
  - **Værdi-skærmen** havde samme fejl. Den er rettet, og gamle gemte priser slettes én gang (`market_prices_v2`).
    Brugeren skal trykke opdatér én gang.
  - **Forslag B "Bedste køb øverst"**, valgt af brugeren:
    - Kortet viser den billigste udgave blandt de 12 mest udbredte og en tydelig knap til at købe den.
    - "Andre udgaver" står med pris direkte på hver linje.
    - Resten ligger under "Vis alle N udgaver".
  - Søgningen rangeres lokalt efter antal ramte søgeord.
  - Én delt Discogs-klient pr. session.
- **Fælles Discogs-kø og cache** (`DiscogsQueue.swift`, gren `claude/quirky-franklin-9sjx8p`, bygget og testet på GitHub Actions, ikke mod det rigtige Discogs):
  - `DiscogsRateLimiter.shared`: token-bucket med 15 kald i et hug og derefter 45 i minuttet (højst 60/min) for **alle** klienter.
    Søgning, udgaver og ønskeliste går foran priser og Værdi. Fejl 429 og "under 3 kald tilbage" giver pause for alle.
  - `DiscogsResponseCache`: søgninger og `/masters/…` gemmes i hukommelsen i 10 minutter (højst 100 svar), og ens kald,
    der kører samtidig, lægges sammen. Kun "Find nye plader" bruger cachen. Priser, samling og konto hentes altid frisk.
  - Søgningen laver nu **ét kald**. Kun når master-søgningen finder under 10 album, søges der også efter releases.
    Ulempe: ved store søgninger vises releases uden master ikke længere.
- **Cover Flow** (`CoverFlowView.swift`, `VinylCore/CoverFlow.swift`): knappen "Cover Flow" i en sektions værktøjslinje
  viser sektionen som på en iPod classic i detaljekolonnen. Midten = det valgte i listen. ← → (også fra listen),
  trackpad (glider med fingrene, fjeder 400/30 når de løftes; `CoverFlowGeometry.glide`), musehjul, træk med musen,
  klik på sidecover; klik på midten/↩ = Find i reolen. Spejling under coverne. Tallene ligger mellem iPlayr
  (kun inspiration, ingen licens) og ipod-classic-js (MIT): 65°, perspektiv 0,4, sidecovers 90 %. Snapshot `13b-coverflow-alene.png` (ImageRenderer; `cacheDisplay` kan ikke tegne 3D).
- **GitHub Actions** (`.github/workflows/checks.yml`, runner `macos-26`): bygger, kører VinylCoreChecks (375 grønne
  pr. 1. okt) og tager demo-snapshots ved hvert push. Billederne ligger som artefakt og på grenen `ci-snapshots`
  (kan hentes med git fra en cloud-session, hvor artefakter er blokeret).
- **Daglig sikkerhedskopi** (`Backup.swift`, Indstillinger › Sikkerhedskopi): `VACUUM INTO` til
  iCloud Drive › Vinyl Shelf Finder backup (ellers Dokumenter), én fil pr. dag, de 14 nyeste beholdes.
  Kører ved start og hver time, aldrig i `--demo` eller `--snapshot`. Gendannelse står i README.

### iMusic.dk som ekstra købssted (2. okt, gren `claude/imusic-kobssted`, PR mod main)

- **Trin 1 (uden konto):** "Søg på iMusic" på albumkortet i Find nye plader og som lille link ved
  "Se pladen på Discogs" i plade-detaljen. Åbner i standardbrowseren (`NSWorkspace`), aldrig i Discogs-vinduet.
  URL: `https://imusic.dk/page/search?query=<kunstner titel>`, kun vinyl: `https://imusic.dk/vinyl/search?query=…`
  (`IMusicLink.searchURL`). **Ikke verificeret i en browser:** imusic.dk var blokeret fra udviklingsmiljøet;
  formatet er fundet i adresser, som søgemaskiner har gemt. Tjek det første gang på Mac'en.
- **Trin 2 (med brugerens Daisycon-feed):** Indstillinger › iMusic › "iMusic-feed (Daisycon)". URL'en gemmes i
  nøgleringen (`KeychainSecret.iMusicFeed`, service `dk.vinylshelffinder.imusicfeed`); kun https på daisycon.io godtages.
  - `VinylCore/IMusicFeed.swift`: henter feedet til en midlertidig fil højst én gang i døgnet (ved start og "Opdatér nu"),
    læser det streamet (JSON i bidder via `JSONElementScanner`, XML via `XMLParser(stream:)`), beholder kun aktive
    musikvarer og gemmer dem i **`~/Library/Caches/VinylShelfFinder/imusic.sqlite`** (aldrig i vinyl.sqlite).
  - Match: først stregkode/EAN (normaliseret, UPC-12 → EAN-13), ellers kunstner + titel med `SearchIndex`'s
    normalisering og stavefejl-afstand; vinyl foretrækkes. Stregkoder kommer fra Discogs-søgeresultatets `barcode`
    (oftest kun for enkelte udgaver). Plade-detaljen har ingen stregkode, så dér matches på tekst.
  - Viser "iMusic: 249 kr. · på lager" (eller leveringstekst/"bestillingsvare") og "Køb på iMusic" (feedets link).
  - Slået fra i `--demo` og `--snapshot` (hverken nøglering eller net).
- **Daisycon-fakta** (fra søgeresultater og offentlig kode, Daisycons sider var blokeret, så **ikke læst direkte**):
  feed-URL `https://daisycon.io/datafeed/?media_id=…&program_id[]=19392&standard_id=…&language_code=…&locale_id=…&type=JSON`,
  struktur `datafeed › programs › products › product_info / update_info`, felter `title`, `link`, `price`, `ean`,
  `brand`, `category`, `category_path`, `keywords`, `in_stock`, `in_stock_amount`, `delivery_time`,
  `delivery_description`, `update_info.status` (inactive/deleted springes over). Intet kunstner-, format- eller
  valutafelt (kunstner fra "Kunstner - Titel" eller brand, valuta antages DKK). `X-Total-Count: 0` = ikke godkendt endnu.
  Parseren er tolerant (flere mulige navne pr. felt i `IMusicFields`).
- **Ikke verificeret:** om iMusic-kampagnen (19392) faktisk har et produktfeed, feedets størrelse, standard_id/locale_id
  for Danmark, og at `link` er affiliate-linket. Første rigtige hentning sker på brugerens Mac.

### 17. okt: cd'er, Windows-version og opdatering (status ved overdragelse)

Arbejdet blev stoppet midt i. Alt er
skubbet til GitHub. Projektet er nu **offentligt** (brugerens eget valg, så appen kan hente
opdateringer uden adgangskode). Ingen af grenene er merget; PR #1 (iMusic) er stadig åben.

Grene (hver bygger oven på den forrige):
- `claude/imusic-kobssted`: iMusic (PR #1).
- `claude/cd-hylde`: **cd'er som egen hylde i Mac-appen. Færdig og grøn på CI.**
  Kopier deles op efter Discogs' format (`Medium.of(format:)`, kun første format: CD/CDr/SACD/HDCD
  er cd, alt andet plader) eller brugerens valg ("Flyt til cd-hylden" i højrekliksmenuen og
  statusmenuen). Skema v5: `locations.medium` (vinyl/cd) og `copies.medium_override`.
  `loadLibrary(medium:)` giver én hylde ad gangen; `createLayout(_:medium:)` rører kun den hylde.
  Skiftet "Plader / Cd'er" øverst (og i Indstillinger › Reol) vises, når der er cd'er; en hylde
  uden reoler viser opdelingen. Demo har 10 cd'er på "Cd-reol 1" (2 sektioner).
  Snapshots: `14-cd-sektion.png`, `14b-cd-find.png`, `14c-cd-opdeling.png`.
  Ikke set endnu: plade-detaljen og Find efter rettelsen "Cd-reol"/"Cd 2 af 5" (sidste commit).
- `claude/windows-app`: Windows-versionen (C#/.NET 8/WinUI 3, mappen `windows/`). Kernen er
  færdig og oversat 1:1 fra Swift med 524 checks (`cd windows && dotnet run --project
  src/VinylCore.Checks`), inkl. cd'er. Database-skemaet er identisk med Mac (v5).
  WinUI-skallen bygges, testes og zippes af `.github/workflows/windows.yml` på windows-latest.
- `claude/windows-ui` (commit 35b0ca7): første Windows-skærme, **skrevet, men aldrig bygget**.
  Findes: `WindowsCredentialStore.cs` (Credential Manager), `AppModel.cs` (som AppModel.swift),
  `UI/Ui.cs` (farver, tekststile, cover, "2A"-mærke), `Views/RecordRow.cs`, `Views/SearchPane.cs`,
  `Views/ListPanes.cs` (indbakke og sektion), `Views/RecordParts.cs` (placeringspanel, naboer).
  De er midlertidigt holdt ude af bygget med `<Compile Remove=...>` i VinylShelfFinder.csproj.
  Mangler: `Views/DetailPane.cs` og `Views/FindOverlay.cs` (fra RecordDetailView.swift og
  Sheets.swift), `Views/OnboardingView.cs`, MainWindow der bygger sidepanelet i kode og viser
  panerne (Find som overlay-Grid, så skærmbilledet kan fange det), `--demo` i App.xaml.cs og i
  smoke-testen i windows.yml, skærmbilleder af søg/detalje/Find/sektion/opsætning. Fjern derefter
  `Compile Remove`, skub, og ret det, CI melder.
- `claude/opdatering` (= cd-hylde + windows-app): **opdateringsknap, kun Mac-delen skrevet**.
  `Sources/VinylCore/Update.swift` (versioner, GitHubs svar, højst ét tjek pr. døgn, kun
  GitHub-adresser) med checks, `Sources/VinylShelfFinder/Updater.swift` (tjek ved start, "Version X
  er klar" med "Opdatér nu"/"Senere", fanen Indstillinger › Opdatering, henter zip, tjekker
  bundle-id, signerer med "Vinyl Shelf Finder Udvikler", hvis certifikatet findes, så nøgleringen
  husker appen, udskifter appen og åbner den igen). `.github/workflows/release-mac.yml` bygger
  `VinylShelfFinder-macOS.zip` på et tag `v*`.
  **Windows-delen er lavet (17. okt, session 2):** `windows/src/VinylCore/Update.cs` (port af
  Update.swift, 11 nye checks, i alt 535), `windows/src/VinylShelfFinder/Updater.cs` (tjek ved start
  højst én gang i døgnet, tilstand i `%LOCALAPPDATA%\VinylShelfFinder\update.json`, henter
  `VinylShelfFinder-Windows-x64.zip`, tjekker at exe'en findes, og et skjult PowerShell-script kopierer
  de nye filer ind, når appen er lukket, og åbner den igen). Bjælke øverst i hovedvinduet med
  "Version X er klar", "Opdatér nu" og "Senere", og punktet "Opdatering" nederst i sidepanelet.
  Slået fra i `--demo` og `--smoke`. Version 0.1.0 i csproj (som Mac); windows.yml sætter
  `-p:Version=` fra tagget. Ikke afprøvet: selve udskiftningen på en rigtig Windows-maskine (kræver
  en udgivelse). Mangler: den første udgivelse (spørg brugeren, før der laves et tag).

Næste skridt, i den rækkefølge brugeren bad om: gør opdateringen færdig (Mac + Windows), lav
første udgivelse (fx v1.0.0, efter brugerens ja), og byg resten af Windows-skærmene (Værdi,
Lytning, Lyttelog, Find nye plader med WebView2, iMusic, Cover Flow, Historik, Indstillinger,
skiftet Plader/Cd'er) med højst to agenter ad gangen.

### 17. okt (session 2): Windows-skærmene (gren `claude/windows-skaerme`)

Bygger oven på `claude/opdatering` + `claude/windows-ui`. Alle Mac-skærmene er oversat til WinUI 3
(bygget i C#, ikke XAML, i `windows/src/VinylShelfFinder/Views/`): søg, plade-detalje (med prislinje og
iMusic), Find i reolen og "Sæt tilbage" (lag over vinduet: `FindOverlay`), Flyt og navn/sted
(`Dialogs`), Nye/Fjernet/Ude af reolen, sektioner (højreklik: Kontrollér, Tilføj, Slet tom),
Cover Flow (`CoverFlowPane`, PlaneProjection), Kom i gang (`OnboardingView`), skiftet Plader/Cd'er og
Synkronisér i værktøjslinjen, Historik med Fortryd, Hvad skal jeg høre?, Lyttelog, Værdi,
Indstillinger (Discogs, Sortering, Reol, iMusic, Sikkerhedskopi, Opdatering), Kontrollér sektion og
synkroniseringsrapport (`CheckShelf`), Find nye plader (`FindNewModel` + `FindNewPanes`), Discogs-
vinduet (`DiscogsBrowserWindow`, WebView2, ingen scripts, data i %LOCALAPPDATA%\VinylShelfFinder\WebView2),
iMusic (`IMusicModel`, feed-URL i Legitimationsadministrator), reolskilte som HTML med QR (`LabelsPrint`,
pakken QRCoder 1.6.0) og daglig sikkerhedskopi.

- `--demo` bruger demo.sqlite og intet net. CI kører `--demo --smoke` og gemmer billeder af hver skærm
  (01-start … 12-find-nye-plader) på grenen `ci-snapshots-windows`.
- **Lokal oversættelse uden Windows:** installér .NET 8 (dotnet-install.sh) og byg et hjælpeprojekt, der
  inkluderer `VinylShelfFinder/**/*.cs` + referencer til WindowsAppSDK's `lib/net6.0-windows10.0.18362.0/*.dll`
  og WebView2's `lib_manual/.../Microsoft.Web.WebView2.Core.Projection.dll`, med `EnableWindowsTargeting`,
  `AllowUnsafeBlocks` og en stub-fil med de felter, XAML ellers genererer (Root, Nav, ListHost …).
  Det fanger næsten alle fejl før CI.
- Ikke lavet på Windows: `vinylshelf://`-adresser (QR-koder åbner ikke appen), mobilsiden (heller ikke
  færdig på Mac). Ikke afprøvet på en rigtig Windows-pc: Discogs-login/køb i WebView2, iMusic-feed,
  opdatering via "Opdatér nu".
- Ingen af grenene er merget. Første udgivelse (v1.0.0) venter på, at brugeren laver den på GitHub
  (sessionen må ikke skubbe tags).

### 17.–18. okt (session 3, på en Windows-pc): rettelser og nye funktioner (gren `claude/ret-tokenfelt`)

Bygger på v1.0.0 (= `claude/windows-skaerme`). Lavet og testet på en rigtig Windows 11-pc (Git og .NET 8 SDK
installeret). **Kun Windows; Mac-appen har ikke fået noget af det nedenfor.** Windows-kernen har nu **584 checks**, alle grønne.

- **Rettede nedbrud:** "Forbind" lukkede appen (OnboardingView genbrugte tokenfeltet i en ny forælder,
  WinUI 0x800F1000), og sync fejlede ("samlingen kunne ikke læses"), fordi Discogs' `instance_id` nu er større
  end int.MaxValue. `InstanceId` er `long` hele vejen (JSON, model, sync, database).
  Mac-appen har ikke fejlen (Swift `Int` er 64 bit, SQLite bruges med `bind_int64`/`column_int64`); to checks i
  VinylCoreChecks sikrer det (18. okt).
- **Logo:** `Assets/AppIcon.ico` fra Mac-ikonet (uden macOS' kant), i .exe, hovedvindue og Discogs-vindue.
- **Digitale filer** (første format "File") står hverken på plade- eller cd-hylden (`MediumExtensions.ShelfOf`),
  meldes ikke som nye eller fjernede; brugeren kan selv flytte en fil til en hylde.
- **Sorteringsliste** (sidepanelet): hele rækkefølgen for én hylde ad gangen, sektion for sektion, med flueben
  (gemt i settings `sort_checked_vinyl/cd`), "Næste" og "Start forfra". Kan ses før reolerne er lavet.
- **Eksport / import / nulstil** (Indstillinger › Sikkerhedskopi og data, `DataTransfer.cs`): eksport er en hel
  SQLite-fil (VACUUM INTO). Import og nulstilling tager først en sikkerhedskopi (`før-import-…`/`før-nulstilling-…`
  i backup-mappen), bestilles som filer ved siden af databasen og udføres ved næste start, før databasen åbnes;
  appen genstarter sig selv. En import uden bekræftelse bruges aldrig; tomme filer afvises.
- **Sortering:** "Tal sidst" (`SortRules.NumbersLast`, standard til, gælder også Discogs' rækkefølge) og
  "Efternavn først" (`SurnameSort.cs` + `SurnameDialog`): appen gætter, hvilke kunstnere der er personer,
  brugeren krydser af, valgene bliver sorteringsnavne ("Dylan, Bob"), og Discogs' rækkefølge slås fra.
  Fravalgte gemmes i settings `surname_not_persons`.
- **Fra en test-agents gennemgang, rettet:** Flyt-dialogens "Efter"-liste frøs med to ens titler (nu ComboBoxItem
  med nummer), "Opdel samlingen forfra…" virkede ikke fra Indstillinger, async-knapper uden try/catch, cd-hylden
  sagde "plader", digital fil tilbage til "Følg Discogs" beholdt en skjult placering.
- **Ikke rettet (kosmetisk):** flere ikoner er tomme strenge i koden (fx "Opdatering" i sidepanelet), detaljepanelet
  bliver skåret af ved 1280×820 og er ubrugeligt ved 800×600, Søg vælger ikke første resultat efter skift tilbage,
  knapper med ikon har intet navn for Oplæser. Test-agenten så tilfældige 0xC0000374-nedbrud under sin
  UI Automation-test; 6 billedtest i træk uden den gav 0 nedbrud, så årsagen var sandsynligvis frysningen ovenfor.
- **Foreslået, ikke bygget:** "bunke-sortering" (grovsortér i bunker pr. sektion, så finsortér 70 ad gangen) og at
  "[Lowbudget] Blues Band" o.l. med tegn foran sorteres under bogstavet.
- Test på Windows: `cd windows; dotnet run --project src/VinylCore.Checks -c Release`, og
  `VinylShelfFinder.exe --demo --smoke <mappe>` (nu også billeder af sorteringslisten). UI kan drives med
  UI Automation fra PowerShell (gem scripts som UTF-8 med BOM). Brugerens rigtige database
  `%LOCALAPPDATA%\VinylShelfFinder\vinyl.sqlite` er kun læst via kopier.

### 18. okt: Mac-appen får sorteringslisten (gren `claude/ret-tokenfelt`)

- `Sources/VinylCore/SortList.swift` (port af SortList.cs, samme settings `sort_checked_vinyl/cd`) + 8 checks.
- `SortListView.swift` i midterkolonnen (plade-detaljen til højre), punktet "Sorteringsliste" under Søg,
  "Se hele rækkefølgen" i opsætningens trin 3, og listen kan ses før reolerne er lavet (`needsOnboarding`).
  Skiftet Plader/Cd'er bliver på sorteringslisten. Snapshot `15-sorteringsliste.png`.
- Menupunktet "Søg efter opdatering…" i appmenuen (`Updater.checkFromMenu`).
- Stadig kun på Windows: "Efternavn først", "Tal sidst", eksport/import/nulstil.

### 18. okt: Mac og Windows ens (gren `claude/ret-tokenfelt`)

Brugeren vil have, at appsene følges ad (`CLAUDE.md`, `PARITET.md`, workflowet "Paritet").
- Mac fik: "Tal sidst" (**fra** som standard på Mac), "Efternavn først" (`SurnameSort.swift`, `SurnameSheet.swift`),
  digitale filer uden hylde, eksport/import/nulstil (`DataTransfer.swift`, samme filformat som Windows; genstart
  via `/bin/sh` der venter på, at appen lukker). 500 checks.
- Begge: en digital fil, der allerede har en plads, bliver stående (`keepPlacedDigitalFiles` ved åbning).
- Windows fik `vinylshelf://`: `ActivationRegistrationManager.RegisterForProtocolActivation` (HKCU), ét eksemplar
  (`AppInstance.FindOrRegisterForKey`, ny start sender adressen videre), `--restart` efter import/nulstilling.
  Ikke i `--demo`/`--smoke`. Smoke-testen tjekker `OpenScanCode`.

### 18. okt: konto i skyen (gren `claude/sky-synk`), **igangværende arbejde, start her**

Brugeren vil have én konto på Mac, Windows og (senere) iPhone, så det, der laves på computeren, kan ses på
telefonen. Valgt: **Supabase** (gratis, EU/Frankfurt), projekt-URL og offentlig nøgle (publishable) i `CloudConfig`
(Swift og C#). Databasen i skyen: `supabase/schema.sql` (én tabel `sync_records`, RLS: kun ejeren). Brugeren har
kørt skemaet. Send og bed aldrig om `service_role`/secret-nøglen eller database-adgangskoden. Andre kan bruge
projektet med egen konto (RLS adskiller data), men hver skal have sit eget Discogs-token.

**Sådan virker det**
- **Skema v6** (begge): `uid` på copies/locations/plays, tabellen `sync_state` (det sidst synkroniserede pr. post).
- **SyncDocs** (`.swift`/`.cs`): hele systemet som poster (release, copy, location, section = hele rækkefølgen,
  play, setting). Ændringer findes ved at sammenligne med `sync_state`. Hver synk: hent siden markøren (−5 s
  overlap) → læg ind → send egne ændringer → markér → ny markør. Ved samtidig ændring vinder skyen. Historik
  synkroniseres ikke (endnu). Discogs-token og iMusic-adresse kommer **aldrig** i skyen.
- Første gang med reoler både i skyen og lokalt spørges der (`NeedsChoice`: brug kontoens / denne enheds).
- Apps: fanen **Konto** (første fane i Indstillinger), synk ved start, 4 s efter ændringer og hvert 5. minut.
  Login gemmes i nøgleringen / Legitimationsadministrator (`dk.vinylshelffinder.cloud`).
- Checks: Mac `swift run -c release VinylCoreChecks` (528), Windows på Mac
  `~/.dotnet/dotnet run --project windows/src/VinylCore.Checks -c Release` (614, .NET 8 i hjemmemappen).
  Begge har en falsk server (`StubCloud`), så der testes aldrig mod den rigtige konto.

**Login: problemet lige nu (brugeren er IKKE logget ind endnu)**
- Gratisplanen: mail-skabeloner kan ikke redigeres uden egen SMTP, så mailen har kun et **link** (ingen kode).
  Den indbyggede mail sender **højst 2 mails i timen** for hele projektet.
- Linket går til Supabase `/auth/v1/verify?token=…&type=magiclink&redirect_to=vinylshelf://auth`
  (`vinylshelf://auth` står under Redirect URLs). Når brugeren klikker, får de en blank side eller "noget gik galt,
  kunne ikke åbne appen". `vinylshelf://` peger korrekt på `/Applications/Vinyl Shelf Finder.app` (tjekket).
  Klikket bruger linket op.
- Løsning 1 (commit `f704fe6`, installeret på Mac): **kopiér linket** (højreklik › Kopiér link) og indsæt i appen.
  Appen sender selv `POST /auth/v1/verify {type, token_hash}`. Brugeren prøvede og fik "Koden er forkert eller
  udløbet". Serveren svarer `otp_expired` for et ukendt/brugt token (afprøvet med curl og falsk token). Mulige
  årsager: linket var allerede klikket/brugt, det var ikke den nyeste mail, eller linket blev sat i kodefeltet.
- Løsning 2 (commit `00512b5`, installeret på Mac, CI grøn): ét felt "Linket fra mailen" + én "Log ind"-knap
  (`completeCloudInput` / `CompleteCloudInputAsync` vælger selv kode eller link). Et brugt link giver nu sin egen
  besked (`CloudClient.usedLink` / `UsedLink`). Checks består på begge, og Mac-appen kompilerer
  (`swift build --product VinylShelfFinder`). Windows-UI er kun tjekket af CI, når grenen er pushet.
- Hvis det stadig fejler med en frisk mail, hvor linket ikke er klikket: bed brugeren indsætte linket i chatten
  **med token-delen fjernet**, så formen kan tjekkes. Overvej så egen SMTP (fx Resend, brugeren skal selv oprette
  konto) så skabelonen kan vise en 6-cifret kode (`{{ .Token }}`). Det fjerner også mailgrænsen.

**Næste skridt (i rækkefølge)**
1. Gennemgå hele grenen `claude/sky-synk` mod `main` (se "Gennemgang" nedenfor).
2. Få brugeren logget ind på Mac (husk mailgrænsen: vent ~1 time efter sidste mail). Tjek at "Senest
   synkroniseret" får et tidspunkt.
3. Merge `claude/sky-synk` til `main` og lav en ny udgivelse (push `claude/udgivelse-vX.Y.Z`), så Windows kan
   opdatere og logge ind.
4. iPhone-appen (Xcode og iOS 27-simulatoren er installeret; iPhone 18 Pro-simulator findes): login, søgning,
   Find i reolen, sektioner, QR-scanning, Spillet. Genbrug `VinylCore`.
5. Senere: egen SMTP, synk af historik.

**Gennemgang (gør dette først)**
- `git diff main...claude/sky-synk`: læs alt. Fokus: sikkerhed (ingen hemmelige nøgler, token/iMusic aldrig i skyen
  eller logs, RLS i `supabase/schema.sql`), datatab (sletninger, `NeedsChoice`, at en opdatering aldrig ændrer
  sorteringen), v6-migreringen på en kopi af en ældre database, fejlbeskeder på dansk, og at Mac og Windows gør
  præcis det samme (`PARITET.md`).
- Kør begge check-suiter og byg Mac-appen. Ret fund på begge platforme. Rør aldrig den rigtige database i test.

**Installation på Mac (brugerens rigtige app)**
1. Sikkerhedskopi først: `sqlite3 "~/Library/Application Support/VinylShelfFinder/vinyl.sqlite" ".backup '…/vinyl-før-<navn>.sqlite'"`.
2. `/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.0" Resources/Info.plist`,
   `./build-app.sh --install` (tager ~12 min, kør i baggrunden og sig det til brugeren), derefter
   `git checkout Resources/Info.plist`.
3. Brugeren lukker appen med ⌘Q og åbner den igen.

### Ikke færdigt / næste skridt (spørg brugeren om rækkefølgen)

1. **Mobilside på det lokale netværk (opgave 1)**, så QR-koderne virker. Det er det største åbne punkt.
   - Netværket, mobilsiden skal virke på, er beskrevet i `HANDOFF-privat.md`.
   - Beslutninger, der er taget:
     - Serveren skal altid køre, når appen er åben, med en kontakt i Indstillinger til at slå den fra.
     - Mobilsiden har **én "Spillet"-knap**. Ellers er den kun til at læse.
     - Forsiden har et søgefelt og en liste over sektioner.
     - Sektionssiden er en nummereret liste med små covers, hvor plader ude af reolen er nedtonede.
     - Plade-siden har et stort cover øverst.
   - Lavet: `MobileSite.swift` med ruter (`/`, `/section/<id>`, `/record/<id>`, `POST /record/<id>/play`,
     `/cover/<id>`) og checks for routing og parsing.
   - Mangler:
     - en `NWListener`-server (kun Network.framework, ingen afhængigheder), fast port (forslag 8765) og levering af covers,
     - nye QR-koder (`http://…:port/section/<id>`). Den gamle `vinylshelf://` skal stadig kunne læses,
     - en indikator i appen med adresse og QR-kode,
     - restyling til Liquid Glass.
   - Skal testes sammen med brugeren på telefonen: virker `.local` eller kun IP-adressen? Firewall-dialogen
     kan dukke op efter hver build ved ad-hoc-signering. Fortæl det på forhånd. Skiltene skal printes igen.
2. **Find nye plader, resten:**
   - kø, cache og ét kald pr. søgning er lavet (se ovenfor); mangler afprøvning mod det rigtige Discogs,
   - Se afsnit 6a.
   - **Ikke testet mod det rigtige discogs.com:** login og betaling i appens WKWebView, og `sell/list?master_id&format`-URL'en.
3. **Udviklercertifikat**, så nøgleringen ikke spørger efter hver build. Brugeren skal selv oprette det i Nøgleringsadgang.
4. Oprydning:
   - `Sheets.swift` er stor (1054 linjer) og kan deles op.
   - Testindgange i produktionskoden: `FindNewModel.testService`, `DiscogsBrowser.makeDataStore`.
   - `design-work/` indeholder mange gamle kopier og backups, men slet ikke uden at spørge.

---

## 6a. "Find nye plader" i detaljer

**Sådan virker den** (sidepanel → Discogs → Find nye plader). Den kræver et token og er slået fra i demo-tilstand.

1. **Midterkolonnen:**
   - søgefelt (søgningen starter ved mindst 2 tegn og 0,4 sekunders pause),
   - formatvælger Alle / Vinyl / CD / Kassette, som huskes i `UserDefaults` under `findnew_format`,
   - liste over album med mærkerne "I din samling" og "På ønskelisten", og "Vis flere".
2. **Højre kolonne (forslag B):**
   - Albumkortet viser **"Billigste vinyl lige nu"** med pris, udgave, antal til salg og "+ fragt".
     Der står "indtil videre", mens appen stadig tjekker.
   - Knapperne er **Køb på Discogs** og ♡.
   - **Andre udgaver** står med pris, **Køb** og ♡ på hver linje, billigst først.
   - **Vis alle N udgaver** har "Hent pris" pr. udgave.
   - Nederst er der knappen "Se alle tilbud på Discogs" og en forklaring.
3. **Discogs-vinduet** (`DiscogsBrowser.swift`): Discogs' API kan ikke købe, så købet sker på Discogs' egen side.

**Sådan findes "billigste":**
- Appen henter op til 3 sider á 100 udgaver (`versionPagesToRank`).
- Udgaverne sorteres efter udbredelse, dvs. `stats.community` har + ønsker (`mostPopularFirst`).
- Pris hentes for de **12 mest udbredte** (`pricedCount`), højst 3 ad gangen (`priceConcurrency`).
- Priser gemmes i hukommelsen i 15 minutter.
- Den billigste udgave findes blandt alle udgaver, der har fået hentet en pris.
- Alle udgaver kan ikke tjekkes. Discogs giver kun pris for én udgave pr. kald, og Blue Train har fx 199 vinyludgaver.

**Kald pr. handling:**

| Handling | Kald |
|---|---|
| Søgning | 1 (`type=master`), 2 hvis under 10 masters (også `type=release`). Gentaget søgning: 0 (cache) |
| Vælg album | 1–3 (`/masters/{id}/versions`, 0 hvis i cache) + 12 (`/marketplace/stats/{id}`) |
| "Hent pris" | 1 |
| ♡ | 1 PUT `/users/{name}/wants/{id}` |

**Fakta om Discogs' API (målt mod det rigtige Discogs 1. okt 2026):**
- Brugerens Discogs-valuta er **DKK**, og Discogs understøtter DKK.
- `/releases/{id}` → `lowest_price` er **altid i brugerens Discogs-valuta**. `curr_abbr` ignoreres.
- `/marketplace/stats/{id}?curr_abbr=X` → `{"lowest_price":{"value":…,"currency":"X"},"num_for_sale":…}`.
  Det er den pålidelige kilde, fordi valutaen står i svaret.
- `/masters/{id}` → `lowest_price` er det billigste eksemplar i **alle** formater og stande, fx 8,77 kr. for Blue Train.
  Det er misvisende, og appen bruger det ikke længere.
- `main_release` på en master har ofte 0 til salg.
- Discogs' egen søgning rangerer dårligt ved flere ord. Appen omrangerer derfor lokalt (`rankedForQuery`).
- Priserne er uden fragt, moms og gebyrer og gælder uanset stand. Discogs' kurv viser derfor et højere beløb.
- Grænsen er ca. 60 kald i minuttet. Alle kald går gennem `DiscogsRateLimiter.shared`, som holder 3 sekunders pause, når der er under 3 kald tilbage, og 5–15 sekunder ved fejl 429.
- Valuta i appen: standard er DKK. `MarketCurrency.converted` regner kun mellem EUR og DKK (kurs 7,46038).
  Der opfindes aldrig en kurs for andre valutaer.

**Kendte svagheder (ikke rettet):**
1.–3. Kø, cache og 2 kald pr. søgning er rettet (se afsnit 6). Cachen er kun i hukommelsen og tømmes ved genstart.
4. **Covers fra søgeresultater** lægges i disk-cachen (`~/Library/Caches/VinylShelfFinder/covers`) uden grænse.
5. **Ikke testet mod det rigtige discogs.com:**
   - login og betaling i appens WKWebView,
   - `https://www.discogs.com/sell/list?master_id={id}&format={Vinyl|CD|Cassette}`.
6. **Værdi-skærmens samlede værdi** (`/collection/value`) er tekst i brugerens Discogs-valuta og omregnes ikke.

**Testdata:** `StubCatalogService` i `design-work/koeb-B/Sources/VinylShelfFinder/KoebBTest.swift`
har 20 udgaver med udbredelse og priser og én fejl, så "Prøv igen" kan ses. Billederne ligger i `design-snapshots/koeb-B/`.

---

## 7. Test og værktøjer

| Formål | Sådan |
|---|---|
| Logik | `swift run VinylCoreChecks` (skal være grøn) |
| Offscreen-billeder | `.build/debug/VinylShelfFinder --demo --snapshot <mappe>` |
| Rigtigt vindue + billeder | Kopiér projektet til `../design-work/<navn>`, tilføj hook i `App.swift`, og kør `--demo --walkthrough-live <mappe> [--find-nye]`. Seneste eksempel: `design-work/koeb-B` (`KoebBTest.swift` med `StubCatalogService`) |
| Animationer/hak | `design-work/motion-F/.../MotionTest.swift` (`--onscreen --motiontest <mappe>`) |
| Priser mod Discogs | Lille testprogram i scratchpad: `swiftc -O -module-name VinylCore Sources/VinylCore/*.swift main.swift -lsqlite3`, hvor `main.swift` henter tokenet med `Keychain.loadToken()` og kalder klienten. Udskriv kun svar-felter, aldrig tokenet. Kun læsning, cirka 20 kald, kun med brugerens lov. macOS spørger brugeren om nøgleringen |

Beskyt altid kørsler mod at hænge:
`( CFFIXED_USER_HOME=$H .build/debug/VinylShelfFinder --demo … & p=$!; sleep 150; kill $p )`.
Testværktøjer flettes **ikke** ind i appen.

---

## 8. Forslag til, hvordan du starter

1. Læs denne fil. Kør `swift build` og `swift run VinylCoreChecks`.
2. Spørg brugeren, hvad der skal ske nu. Anbefal en rækkefølge, fx at mobilsiden kommer først, fordi den er det største åbne løfte.
   Spørg også, om "Find nye plader" føles god nok efter forslag B.
3. Vis forslag visuelt, før du bygger. Byg, test med demo, `./build-app.sh --install`, og bed om ⌘Q og genstart.
4. **Til sidst: opdatér denne fil** (status, beslutninger og antal checks), så den stadig er den eneste, der skal gives videre.
