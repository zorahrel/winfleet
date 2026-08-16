// Stampa "x,y,larghezza,altezza" della finestra di stream piu' grande.
//
// Serve perche' chiedere la geometria ad AppleScript richiede il permesso di
// Accessibilita', che macOS revoca ogni volta che il binario cambia firma — e
// Moonlight viene rifirmato a ogni build. Quando succede osascript non fallisce in
// modo visibile: risponde vuoto, e chi lo interroga conclude che non c'e' nessuna
// finestra mentre e' li' davanti. CoreGraphics risponde sempre, senza permessi.
import CoreGraphics
import Foundation

// .optionAll e non .optionOnScreenOnly: una finestra su un altro Space o ridotta a
// icona non e' "on screen", ma esiste - e dire "nessuna finestra" quando c'e'
// manda a cercare un guasto che non c'e'.
let opts = CGWindowListOption(arrayLiteral: .optionAll)
var best: (Double, [String: Any])? = nil

for w in (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? [] {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("Moonlight") else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let ww = b["Width"] as? Double, let hh = b["Height"] as? Double else { continue }
    // Sopra i 40.000 punti quadrati: sotto ci sono solo pannelli e tooltip.
    let area = ww * hh
    if area > 40000 && (best == nil || area > best!.0) { best = (area, b) }
}

if let b = best?.1,
   let x = b["X"] as? Double, let y = b["Y"] as? Double,
   let w = b["Width"] as? Double, let h = b["Height"] as? Double {
    print("\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))")
}
