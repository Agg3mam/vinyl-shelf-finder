# Handoff: Vinyl Shelf Finder (hele projektet)

**Opdateret:** 1. oktober 2026, aften (sent: fælles Discogs-kø, cache og daglig backup).

**Dette er den eneste handoff-fil.** Den indeholder alt, en ny Claude-session skal vide for at
arbejde videre på projektet, uanset hvad opgaven er. Giv den videre som den første besked,
fx: *"Læs HANDOFF.md, og hjælp mig med …"*. Opdatér filen, når der er lavet noget nyt.

Projektet ligger i `/Users/holgerskov/Claude code/VinylShelfFinder`. `README.md` er brugervejledningen.
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
| **Find nye plader** | Søgning i hele Discogs' katalog med billigste køb øverst. Købet sker i et Discogs-vindue inde i appen |
| Reolskilte (⌘P) | En A4-PDF med QR-kode pr. sektion. Koden er stadig `vinylshelf://`, så den virker kun på Mac'en |

Genveje: ⌘K søg, ↑↓ vælg, ↩/⌘F Find i reolen, ⇧⌘M flyt, ⌘L spillet, ⌘R sync, ⌘P skilte.

---

## 2. Om brugeren, og hvordan man arbejder med dem

- **Dansk** og almindeligt sprog uden unødvendig teknik. Brugeren har ikke Xcode-erfaring.
- **Spørg, før du bygger.** Stil få konkrete spørgsmål og giv en anbefaling. Brief brugeren om planen, og fortæl hvorfor.
- Brugeren vil gerne have **flere forslag at vælge imellem** og helst se dem **visuelt**,
  fx som widget-mockups eller skærmbilleder.
- Appen skal være **simpel**. Undgå at den virker "vibecoded": tilfældige gradienter, emoji,
  glas overalt eller uens afstande.
- **Store opgaver deles gerne ud på parallelle agenter.** Hver agent arbejder i sin egen kopi
  (`../design-work/<navn>`) med sine egne filer, og kun én agent redigerer en given fil.
  Brugeren har ramt sin forbrugsgrænse flere gange, så hold agenterne effektive.
- Når brugeren siger "tjek det selv", mener de det. Verificér selv i stedet for at bede brugeren teste.
- Appen er **installeret i Programmer**. Afslut altid med `./build-app.sh --install`, og sig til brugeren:
  *"Tryk ⌘Q og åbn appen igen fra Programmer."*

---

## 3. Regler, der ikke må brydes

1. **Brugerens rigtige database må ikke røres:** `~/Library/Application Support/VinylShelfFinder/vinyl.sqlite`.
   Den indeholder ca. 114 plader og 2 sektioner. Test altid med `--demo` og en isoleret hjemmemappe:
   `CFFIXED_USER_HOME=<tom mappe i scratchpad> .build/debug/VinylShelfFinder --demo …`
2. **Discogs-tokenet** ligger kun i nøgleringen (service `dk.vinylshelffinder.discogs`). Det må
   aldrig udskrives, logges eller vises.
   - Brugeren har givet lov til et **begrænset antal læse-opslag** (cirka 20) med tokenet,
     når priser skal verificeres. Det sker via et lille testprogram, der læser tokenet i
     processen og kun udskriver svar-felter.
   - Spørg igen ved større runder.
   - Aldrig PUT/POST, køb eller ændringer på kontoen.
3. **discogs.com må ikke indlæses i test.** Discogs-vinduet testes med en lokal side.
4. **Skærmbilleder:** kun af demo-appens eget vindue med `screencapture -x -o -l <windowNumber>`, aldrig
   hele skærmen. Der er ingen Tilgængeligheds-tilladelse og derfor ingen tastetryk. Handlinger
   udløses inde fra appen med testkode.
5. Sikkerhedsindstillinger, nøglering og certifikater ændrer brugeren selv.
6. Projektet er et **git-repo** og ligger privat på GitHub: `https://github.com/Agg3mam/vinyl-shelf-finder`
   (brugerens konto er `Agg3mam`, og `gh` ligger i `/opt/homebrew/bin/gh`).
   - Commits bruger GitHubs skjulte e-mail. Brug aldrig brugerens rigtige e-mail eller Mac'ens navn.
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

## 4. Teknik

- **Kun Command Line Tools, ingen Xcode.** Det er Swift 6.x med macOS 27 SDK, og brugerens Mac kører macOS 27.
  - Brug `@ViewState`, ikke `@State`. Det er et typealias i `App.swift`, fordi `@State`-makroens plugin kun følger med Xcode.
  - Ingen XCTest og ingen Swift Testing. Brug i stedet **`swift run VinylCoreChecks`**, som havde **305 checks**, alle grønne pr. 1. okt. Grenen `claude/quirky-franklin-9sjx8p` har **375 checks**, grønne på GitHub Actions (macOS 26, Swift 6.3).
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

### Ikke færdigt / næste skridt (spørg brugeren om rækkefølgen)

1. **Mobilside via iPhone-hotspot (opgave 1)**, så QR-koderne virker. Det er det største åbne punkt.
   - Brugeren har **intet wifi**. Mac'en er på internettet via iPhonens hotspot, hvor iPhonen er `172.20.10.1` og Mac'en
     senest var `172.20.10.2`. Navnet `Mclovin-7.local` er uafprøvet. Firewallen er slået til.
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
   - Skal testes sammen med brugeren på iPhonen: virker `.local` eller kun IP-adressen? Firewall-dialogen
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
