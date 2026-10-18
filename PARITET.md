# Paritet: Mac og Windows

Hvad hver app kan. Målet er ✅ i begge kolonner. Opdatér tabellen i samme commit som ændringen (se `CLAUDE.md`).

✅ = findes · ❌ = mangler · — = giver ikke mening på platformen (med begrundelse)

| Funktion | Mac | Windows | Bemærkning |
|---|---|---|---|
| Søg, plade-detalje, Find i reolen, Sæt tilbage, Flyt | ✅ | ✅ | |
| Sektioner, Kontrollér sektion, sektionsgrænser (⇄) | ✅ | ✅ | |
| Nye / Fjernet fra Discogs / Ude af reolen | ✅ | ✅ | |
| Cover Flow | ✅ | ✅ | |
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
| Konto i skyen (Supabase): log ind med e-mail, synkronisering | ✅ | ✅ | Samme poster og felter; iPhone-app kommer |
| Mobilside på lokalnettet | ❌ | ❌ | Halvt lavet (kun ruter), ingen server endnu |
