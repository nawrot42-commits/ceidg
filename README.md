# CEIDG Wydruk (macOS)

Mała aplikacja SwiftUI: wpisujesz NIP → pobiera dane firmy z CEIDG i zapisuje wydruk jako PDF (A4).

## Wymagania
- macOS 13+, Xcode lub Command Line Tools (`xcode-select --install`)
- Bezpłatny token API CEIDG (JWT) – wniosek na biznes.gov.pl („Dostęp do API CEIDG / hurtowni danych”)

## Uruchomienie
```bash
swift run              # szybki start
./build-app.sh         # buduje CEIDGWydruk.app
open CEIDGWydruk.app
```
Token wpisz w **Ustawieniach** aplikacji (⌘,).

## Jak działa
- Sprawdza sumę kontrolną NIP.
- Odpytuje `GET https://dane.biznes.gov.pl/api/ceidg/v3/firma?nip=…` z nagłówkiem `Authorization: Bearer <token>`.
- Z otrzymanych danych (firma, właściciel, NIP/REGON, status, adresy, PKD, daty) generuje PDF i otwiera go.

Uwaga: to wydruk wygenerowany z danych API, a nie urzędowy wydruk z wyszukiwarki CEIDG.
Oficjalny PDF można pobrać z wyszukiwarki CEIDG (link w oknie aplikacji).
