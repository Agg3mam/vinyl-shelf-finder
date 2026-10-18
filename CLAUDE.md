# Vinyl Shelf Finder – faste regler

Læs `HANDOFF.md` før arbejdet starter (og `HANDOFF-privat.md`, hvis den findes lokalt).

## Mac og Windows følges ad

Mac-appen (`Sources/`, Swift) og Windows-appen (`windows/`, C#) er **den samme app**. Brugeren vil have, at de altid kan det samme.

- En ændring i den ene app laves også i den anden **i samme opgave**: samme funktion, samme tekster, samme
  standardindstillinger og samme checks (`swift run VinylCoreChecks` og `windows/src/VinylCore.Checks`).
- Gælder også fejlrettelser, medmindre fejlen kun kan opstå på den ene platform (skriv så hvorfor i commit-beskeden).
- Opdatér `PARITET.md` i samme commit. En funktion, der kun findes ét sted, skal stå der med en begrundelse.
- Kan den anden platform ikke testes lokalt, så lad GitHub Actions bygge og se på billederne
  (`ci-snapshots` / `ci-snapshots-windows`), før opgaven meldes færdig.
- Workflowet "Paritet" advarer, når et push kun ændrer den ene app.

## Andre regler

- **Ingen personlige oplysninger i repoet** (det er offentligt): navne, mapper, computernavne, IP-adresser,
  samlingens størrelse, brugerens vaner. De hører til i den lokale `HANDOFF-privat.md`.
- **En opdatering må aldrig ændre sorteringen** af brugerens plader. Nye sorteringsvalg er slået fra, når de
  mangler i den gemte `sort_rules`, og slås kun til af brugeren selv.
- Brugerens rigtige database, Discogs-token og iMusic-feed må ikke røres i test (se HANDOFF afsnit 3).
- Commit og push kun, når brugeren beder om det. Commits bruger GitHubs skjulte e-mail.
- Skriv til brugeren på dansk, i almindeligt sprog.
