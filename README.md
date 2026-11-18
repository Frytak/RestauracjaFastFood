# Restauracja Fast Food

Symulacja restauracji fast food na procesach i wątkach, projekt z Systemów
Operacyjnych. Treść zadania jest w [docs/zadanie.md](docs/zadanie.md), a plan
w [docs/PLAN.md](docs/PLAN.md).

## Quick start

```sh
nix run .
```

Bez Nixa, np. na torusie:

```sh
cmake -B build
cmake --build build
./build/kierownik
```

Na razie jest tylko szkielet, który się buduje. Symulacja jest opisana
w planie.

## Development

```sh
nix develop     # powłoka z narzędziami i hookami gita
nix fmt         # formatowanie
nix flake check # budowanie i sprawdzanie formatowania
```

Po przerwanym przebiegu warto sprawdzić `ipcs`, czy nie zostały stare
struktury IPC.

## Layout

```text
src/        po jednym pliku na program, wspólny kod w src/wspolne/
include/    nagłówki
config/     konfiguracja restauracji
tests/      skrypty scenariuszy testowych
docs/       treść zadania, plan i raport
```

## License

MIT
