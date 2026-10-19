// Haptisk feedback i webappen. Android: navigator.vibrate. iPhone: Safari har intet API, men en
// kontakt (<input type="checkbox" switch>, iOS 18+) giver et let "klik", når den skiftes. Virker det
// ikke på telefonen, sker der bare ingenting.

// Som biblioteket ios-haptics: en ny kontakt hver gang, klikket via sin label og fjernet igen. Safari giver kun
// klikket, når det sker under et tryk (ikke mens fingeren glider, og ikke bagefter).
function iosSwitch() {
  const label = document.createElement("label");
  label.setAttribute("aria-hidden", "true");
  label.style.display = "none";
  const input = document.createElement("input");
  input.type = "checkbox";
  input.setAttribute("switch", "");
  label.append(input);
  document.head.append(label);
  label.click();
  label.remove();
}

let last = 0;
/** "tick": en plade passerer midten · "edge": enden af sektionen · "success": forslaget er fundet. */
export function haptic(kind = "tick", paced = false) {
  const now = performance.now();
  if (kind === "tick" && !paced && now - last < 35) return; // ikke en summen, når man bladrer meget hurtigt
  last = now;
  try {
    if (navigator.vibrate) navigator.vibrate(kind === "tick" ? 6 : kind === "edge" ? [12, 40, 12] : [10, 50, 20]);
    else {
      iosSwitch();
      if (kind !== "tick") setTimeout(iosSwitch, 90);
    }
  } catch { /* ingen haptik */ }
}
