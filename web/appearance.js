// Udseende (Konto › Indstillinger › Udseende): tema (automatisk/lys/mørk) og stil. Gemmes kun på denne enhed og sættes,
// før siden tegnes, så den ikke blinker i den forkerte stil.
(function () {
  let theme = "", style = "";
  try { theme = localStorage.getItem("theme") || ""; style = localStorage.getItem("style") || ""; } catch { /* privat browsing */ }
  const root = document.documentElement;
  if (theme === "light" || theme === "dark") root.dataset.theme = theme;
  if (style === "kasse" || style === "cover" || style === "fokus") root.dataset.style = style;
})();
