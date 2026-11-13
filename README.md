# CEIDG Wydruk (macOS)

Mała aplikacja (AppKit) z wbudowaną przeglądarką: wpisujesz NIP → aplikacja otwiera
wyszukiwarkę CEIDG, wpisuje NIP, otwiera wpis firmy, klika „Wydruk” i zapisuje
oficjalny PDF w folderze **Pobrane** (`CEIDG_<NIP>.pdf`), po czym go otwiera.

## Wymagania
- macOS 13+, Xcode lub Command Line Tools (`xcode-select --install`)

## Uruchomienie
```bash
swift run              # szybki start
./build-app.sh         # buduje CEIDGWydruk.app
open CEIDGWydruk.app
```

## Uwagi
- Strona CEIDG jest widoczna w oknie. Jeśli automat się zatrzyma (captcha, zmiana
  wyglądu strony), dokończ ręcznie – kliknięty wydruk PDF i tak zostanie zapisany.
- „Zapisz stronę jako PDF” zapisuje aktualnie widoczną stronę (wyjście awaryjne).
- Adres startowy: `searchURL` na początku `Sources/CEIDGWydruk/main.swift`.
  Selektory przycisków są w enumie `JS` – w razie zmian na stronie wystarczy je poprawić.

## Raycast
1. Zbuduj aplikację: `bash build-app.sh` (instaluje ją też w `~/Applications`).
2. Raycast → Settings → Extensions → **+** → *Add Script Directory* → wskaż folder `raycast` z tego projektu.
3. W Raycast wpisz „Wydruk CEIDG”, naciśnij Tab, wpisz NIP i Enter.

Z Terminala to samo: `open "ceidgwydruk://1234563218"`.
