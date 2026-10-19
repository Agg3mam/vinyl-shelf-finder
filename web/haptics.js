// Haptisk feedback i webappen. Android: navigator.vibrate. iPhone: Safari har intet API, men en
// kontakt (<input type="checkbox" switch>, iOS 18+) giver et let "klik", når den skiftes. Virker det
// ikke på telefonen, sker der bare ingenting.

let label = null;
function iosSwitch() {
  if (!label) {
    label = document.createElement("label");
    label.setAttribute("aria-hidden", "true");
    label.style.cssText = "position:fixed;left:-100px;top:0;width:1px;height:1px;overflow:hidden;opacity:0;pointer-events:none";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.setAttribute("switch", "");
    input.tabIndex = -1;
    label.append(input);
    document.body.append(label);
  }
  label.click();
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
