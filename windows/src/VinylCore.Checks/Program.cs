using VinylShelfFinder.Checks;

// Selvtest af kernelogikken til Windows-versionen. Samme idé som VinylCoreChecks på Mac:
// ingen testframework, bare en lang række check(...) med danske beskeder.
// Kør: dotnet run (i mappen src/VinylCore.Checks). Afslutter med kode 1, hvis noget fejler.

// Hver fil i projektet tilføjer sine checks som en statisk metode, der kaldes her.
ModelChecks.Run();
DataChecks.Run();
NetChecks.Run();
UpdateChecks.Run();

Console.WriteLine(Check.Failures == 0
    ? $"✓ Alle {Check.Passes} checks bestået"
    : $"✗ {Check.Failures} fejl, {Check.Passes} bestået");
return Check.Failures == 0 ? 0 : 1;
