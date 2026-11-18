# Plan projektu: Restauracja fast food

Treść zadania znajduje się w pliku [zadanie.md](zadanie.md). Dokument opisuje przyjętą architekturę projektu: podział ról na procesy i wątki, wykorzystywane mechanizmy komunikacji międzyprocesowej oraz sposób synchronizacji. Dokument nie zawiera kodu, a jedynie decyzje projektowe wraz z ich uzasadnieniem.

## Założenia ogólne

Każda rola opisana w zadaniu jest realizowana przez osobny program uruchamiany za pomocą `fork()` i `exec()`. Kierownik uruchamia pozostałe procesy, ale nie pełni roli centralnego serwera pośredniczącego w komunikacji. Klienci samodzielnie wybierają kasę, komunikują się z nią przez kolejki komunikatów i zajmują miejsca w restauracji za pomocą semafora. Wspólny stan restauracji jest przechowywany w pamięci dzielonej.

W projekcie nie występuje aktywne czekanie. Proces lub wątek, który nie ma nic do wykonania, jest zablokowany w wywołaniu systemowym: `semop`, `msgrcv`, `read`, `wait`, `sigwait`, `pthread_cond_wait` lub `nanosleep`. Funkcja `nanosleep` jest używana wyłącznie do symulowania upływu czasu (np. jedzenia lub gotowania). Pełne zestawienie miejsc oczekiwania znajduje się w sekcji „Miejsca oczekiwania”.

Projekt jest pisany w C++ w standardzie C++17, co zapewnia zgodność z kompilatorem dostępnym na serwerze torus. Synchronizacja jest realizowana wyłącznie przez API systemowe, ponieważ to ono podlega ocenie. Nie są używane `std::thread`, `std::mutex` ani `std::condition_variable`.

## Procesy i wątki

| Program | Liczba instancji | Wątki |
| --- | --- | --- |
| `kierownik` | 1 | główny, obsługa poleceń z klawiatury, nadzór kas, zegar |
| `logger` | 1 | jeden |
| `kucharz` | 1 | jeden |
| `obsluga` | 1 | główny (obsługa sygnałów) oraz od 2 do 4 wątków kas |
| `generator` | 1 | główny (uruchamianie klientów), zbieranie zakończonych procesów |
| `klient` | jeden proces na grupę klientów | wątek opiekuna oraz po jednym wątku na każde dziecko |

Uzasadnienie podziału:

**Kierownik** jest procesem głównym. Tworzy struktury IPC, uruchamia pozostałe programy, egzekwuje zasady otwierania i zamykania kas, a po zakończeniu symulacji usuwa wszystkie zasoby. Proces ten jest wielowątkowy, ponieważ musi jednocześnie oczekiwać na kilka niezależnych zdarzeń: polecenie użytkownika, zmianę długości kolejek, godzinę zamknięcia oraz zakończenie procesów potomnych.

**Logger** jest osobnym procesem, ponieważ do pliku z logami zapisuje wiele procesów jednocześnie. Wszystkie procesy przesyłają linie logu do łącza nazwanego, z którego logger je odczytuje i zapisuje do pliku. Plik ma w ten sposób jednego właściciela, a linie nie przeplatają się, ponieważ zapis do FIFO o rozmiarze nieprzekraczającym `PIPE_BUF` jest atomowy.

**Kucharz** jest jednym procesem jednowątkowym, ponieważ zadanie przewiduje jednego kucharza. Wprowadzenie dodatkowych wątków nie miałoby uzasadnienia.

**Obsługa** jest jednym procesem, w którym każda kasa jest osobnym wątkiem. Kasy współdzielą dane (statystyki, stan obsługi), a otwarcie kasy sprowadza się do wywołania `pthread_create()`. Sygnały od kierownika trafiają do procesu obsługi, który zgodnie z treścią zadania sam decyduje, którą kasę zamknąć.

**Generator klientów** jest procesem dodatkowym, nieopisanym w treści zadania. W losowych odstępach czasu uruchamia program `klient` przez `fork()` i `exec()`, a następnie zbiera zakończone procesy funkcją `wait()`. Generator jest liderem własnej grupy procesów, do której należą wszyscy klienci, dzięki czemu kierownik może wysłać sygnał do wszystkich klientów jednym wywołaniem `kill(-pgid, ...)`. Rozwiązanie to zwalnia też kierownika z obowiązku zbierania dużej liczby procesów potomnych.

**Klient** jest procesem, zgodnie z wymaganiem prowadzenia symulacji na procesach. Jeden proces reprezentuje jedną grupę: osobę dorosłą oraz od 0 do 3 dzieci w wieku do 6 lat. Dzieci są wątkami w procesie opiekuna. Odzwierciedla to fakt, że dziecko nie wchodzi, nie zamawia i nie wychodzi samodzielnie, a jednocześnie stanowi naturalne zastosowanie zmiennej warunkowej (dzieci oczekują, aż opiekun przyniesie jedzenie).

## Struktury IPC

Wszystkie struktury są tworzone przez kierownika z prawami `0600`, ponieważ wszystkie procesy symulacji działają jako ten sam użytkownik i żaden inny użytkownik nie potrzebuje do nich dostępu. Klucze są generowane funkcją `ftok()` na podstawie pliku kluczy tworzonego przez kierownika przy starcie (`run/klucz`, funkcją `creat()`) oraz różnych identyfikatorów projektu. Ścieżka do pliku kluczy jest przekazywana każdemu procesowi w argumentach `exec()`.

### Pamięć dzielona

Jeden segment zawierający strukturę stanu restauracji:

- konfigurację potrzebną wszystkim procesom: menu, ceny, pojemności pojemników P1..P9, godziny otwarcia, przelicznik czasu,
- moment rozpoczęcia symulacji, na podstawie którego każdy proces wyznacza czas symulowany na potrzeby logów,
- stan każdej z 4 kas (zamknięta, otwarta, w trakcie zamykania) oraz liczbę osób w jej kolejce,
- flagi: restauracja zamknięta dla nowych klientów, ewakuacja,
- identyfikatory procesów obsługi, kucharza i generatora,
- statystyki: liczba klientów, którzy weszli, liczba rezygnacji, utarg, liczba sprzedanych biletów do łazienki.

Dostęp do segmentu jest chroniony semaforem `MUTEKS_STANU`.

### Semafory

Wykorzystywany jest jeden zestaw semaforów System V:

| Semafor | Wartość początkowa | Przeznaczenie |
| --- | --- | --- |
| `MUTEKS_STANU` | 1 | wzajemne wykluczanie przy dostępie do pamięci dzielonej |
| `WOLNE_MIEJSCA` | K | liczba osób, które mogą jeszcze wejść do restauracji |
| `CZEKAJACY_PRIORYTET` | 0 | liczba osób z niepełnosprawnością oczekujących przy wejściu |
| `LAZIENKA_DAMSKA` | 3 | wolne miejsca w łazience damskiej |
| `LAZIENKA_MESKA` | 4 | wolne miejsca w łazience męskiej |
| `LAZIENKA_DOSTEPNA` | 1 | łazienka dla osób z niepełnosprawnością |
| `POJEMNIK_1` .. `POJEMNIK_9` | 0 | liczba porcji danego dania lub napoju w pojemniku |
| `WOLNE_W_POJEMNIKACH` | P1 + ... + P9 | łączna liczba wolnych miejsc we wszystkich pojemnikach |
| `ZMIANA_KOLEJEK` | 0 | budzenie wątku kierownika nadzorującego kasy |

Semafory, które proces zajmuje i sam zwalnia (muteks, miejsca, łazienki, `CZEKAJACY_PRIORYTET`), są używane z flagą `SEM_UNDO`. W przypadku nagłego zakończenia klienta, np. podczas ewakuacji, system automatycznie zwalnia zajmowane przez niego zasoby i nie dochodzi do zakleszczenia. Semafory pojemników nie używają `SEM_UNDO`, ponieważ porcję umieszcza w pojemniku jeden proces (kucharz), a pobiera inny (obsługa).

Dwa elementy synchronizacji zostały zrealizowane wyłącznie za pomocą semaforów:

**Pierwszeństwo przy wejściu.** Zwykły klient wchodzi do restauracji jedną atomową operacją `semop` na dwóch semaforach: oczekiwanie, aż `CZEKAJACY_PRIORYTET` osiągnie wartość 0, oraz zmniejszenie `WOLNE_MIEJSCA` o liczebność grupy. Osoba z niepełnosprawnością najpierw zwiększa `CZEKAJACY_PRIORYTET`, następnie oczekuje na `WOLNE_MIEJSCA`, a po wejściu zmniejsza `CZEKAJACY_PRIORYTET`. Dopóki taka osoba oczekuje, żaden zwykły klient nie zajmie zwolnionego miejsca. Kolejność wejścia jest w ten sposób zapewniona przez jądro, bez utrzymywania osobnej kolejki.

**Kompletowanie zamówienia.** Kasa pobiera z pojemników wszystkie pozycje zamówienia jedną operacją `semop` z flagą `IPC_NOWAIT`, która wykonuje się w całości albo wcale. W przypadku błędu `EAGAIN` kasa odczytuje stan pojemników funkcją `semctl(GETVAL)` i informuje klienta o brakujących i dostępnych pozycjach. Kasa nigdy nie oczekuje na kucharza, ponieważ zadanie wprost wymaga, aby przy braku dania obsługa poprosiła klienta o zmianę zamówienia.

### Kolejki komunikatów

- **Cztery kolejki kas**, po jednej na kasę. Typ komunikatu określa priorytet: 1 oznacza osobę z niepełnosprawnością, 2 zwykłe zamówienie lub zakup biletu do łazienki, 3 polecenie zamknięcia kasy. Wątek kasy odbiera komunikaty wywołaniem `msgrcv(..., -3, ...)`, które zawsze zwraca komunikat o najniższym typie. Osoby z niepełnosprawnością są dzięki temu obsługiwane poza kolejnością, a polecenie zamknięcia zostaje odebrane dopiero po obsłużeniu wszystkich zamówień.
- **Kolejka do klientów**, w której typem komunikatu jest PID klienta. Służy do przesyłania odpowiedzi kasy: przyjęcia zamówienia wraz z kwotą, informacji o braku dania oraz paragonu.
- **Kolejka do kas**, w której typem komunikatu jest numer kasy. Służy do przesyłania odpowiedzi klienta w trakcie obsługi: zmienionego zamówienia, rezygnacji lub zapłaty. Kasa w danej chwili obsługuje tylko jednego klienta, więc komunikaty nie mogą zostać pomylone.

### Łącza

- **FIFO z logami** (`mkfifo`, `0600`). Kierownik tworzy łącze i uruchamia loggera, który otwiera je do odczytu. Dopiero wtedy kierownik otwiera FIFO do zapisu. Kolejność ta jest istotna: gdyby logger odziedziczył deskryptor do zapisu, nigdy nie otrzymałby końca pliku. Otwarcie FIFO blokuje się do czasu otwarcia drugiej strony, co stanowi jednocześnie synchronizację startu bez aktywnego czekania.
- **`dup()` i `dup2()`**. Kierownik wywołuje `dup(1)`, aby zachować deskryptor terminala na komunikaty dla użytkownika, a następnie `dup2()`, aby przekierować standardowe wyjście na FIFO. Wszystkie później uruchamiane procesy dziedziczą standardowe wyjście wskazujące na FIFO i zapisują do niego całe linie pojedynczym wywołaniem `write()`. Logger odczytuje dane funkcją `read()`, zapisuje je do pliku funkcją `write()` i kończy działanie, gdy `read()` zwróci 0, czyli po zamknięciu łącza przez wszystkich piszących.
- **Łącze nienazwane do sygnalizacji gotowości** (`pipe`). Obsługa, kucharz i generator dziedziczą deskryptor do zapisu i po zakończeniu inicjalizacji (dołączenie pamięci dzielonej, instalacja obsługi sygnałów) zapisują do niego jeden bajt. Kierownik odczytuje trzy bajty blokującym wywołaniem `read()` i dopiero wtedy otwiera restaurację.
- **`popen()` przy zakończeniu.** Po zakończeniu symulacji kierownik przetwarza plik logu potokiem poleceń (np. zliczenie zdarzeń według typu) i wyświetla podsumowanie na terminalu.

### Sygnały

| Polecenie z zadania | Sygnał | Odbiorca |
| --- | --- | --- |
| sygnał 1: otwarcie kolejnej kasy | `SIGUSR1` | obsługa |
| sygnał 2: zamknięcie kasy z najkrótszą kolejką | `SIGUSR2` | obsługa |
| sygnał 3: natychmiastowe opuszczenie restauracji | `SIGTERM` | grupa generatora (generator i klienci) oraz obsługa |
| godzina zamknięcia: wstrzymanie wpuszczania klientów | `SIGUSR1` | grupa generatora |

Rozważono użycie sygnałów o numerach dosłownie odpowiadających treści zadania (1, 2, 3, czyli `SIGHUP`, `SIGINT`, `SIGQUIT`). Rozwiązanie to odrzucono, ponieważ `SIGINT` jest generowany przez Ctrl+C i trafia do całej pierwszoplanowej grupy procesów, co prowadziłoby do konfliktu.

Sygnał Ctrl+C jest obsługiwany wyłącznie przez kierownika i traktowany jako ewakuacja z pełnym usunięciem zasobów. Procesy potomne przed wywołaniem `exec()` ustawiają `signal(SIGINT, SIG_IGN)`. Ignorowanie sygnału jest zachowywane po `exec()`, więc Ctrl+C nie przerywa ich działania w nieprzewidzianym momencie.

W miejscach, w których sygnał ma przerwać oczekiwanie, procedura obsługi jest instalowana funkcją `sigaction()` bez flagi `SA_RESTART`. Zablokowane wywołanie `semop` lub `nanosleep` zwraca wtedy błąd `EINTR`, a proces sprawdza ustawioną flagę i podejmuje odpowiednią decyzję.

## Przebieg działania ról

### Kierownik

1. Weryfikuje argumenty wywołania i plik konfiguracyjny. Każda niepoprawna wartość skutkuje czytelnym komunikatem i zakończeniem programu (szczegóły w sekcji dotyczącej walidacji).
2. Tworzy plik kluczy, pamięć dzieloną, semafory, kolejki komunikatów i FIFO.
3. Uruchamia loggera, a następnie obsługę, kucharza i generatora za pomocą `fork()` i `exec()`.
4. Oczekuje na sygnał gotowości trzech procesów przez łącze nienazwane.
5. Tworzy wątki pomocnicze:
   - **wątek poleceń** odczytuje z klawiatury polecenia `1`, `2`, `3` oraz `s` (stan). Jest odłączony (`pthread_detach`), ponieważ przez większość czasu pozostaje zablokowany w `read()` na standardowym wejściu i nie może zostać poprawnie zakończony przez `pthread_join`. Kończy się razem z procesem.
   - **wątek nadzoru kas** oczekuje na `ZMIANA_KOLEJEK`, po wybudzeniu odczytuje stan kolejek pod muteksem i sprawdza zasady opisane w dalszej części dokumentu. W razie potrzeby wysyła sygnał do obsługi.
   - **wątek zegara** oczekuje w `pthread_cond_timedwait` do godziny zamknięcia. Zmienna warunkowa została użyta zamiast zwykłego uśpienia, ponieważ przy ewakuacji wątek główny wywołuje `pthread_cond_broadcast`, co natychmiast budzi zegar.
6. Wątek główny oczekuje na zakończenie generatora (`waitpid`). Generator kończy działanie dopiero po wyjściu ostatniego klienta, co wyznacza koniec dnia zarówno w zwykłym trybie, jak i po ewakuacji.
7. Usuwanie zasobów: kierownik kończy obsługę i kucharza i oczekuje na nich, zamyka swój deskryptor FIFO (logger otrzymuje koniec pliku i kończy działanie), oczekuje na loggera, generuje podsumowanie przez `popen()`, usuwa wszystkie struktury IPC (`IPC_RMID`), FIFO oraz plik kluczy (`unlink`). Pozostaje jedynie plik z logami.

### Generator klientów

Wątek główny w pętli losuje odstęp czasu, usypia na ten czas, a następnie uruchamia klienta przez `fork()` i `exec()`. Przed każdym uruchomieniem sprawdza pod muteksem, czy liczba działających klientów nie przekracza limitu z konfiguracji. W przypadku osiągnięcia limitu oczekuje w `pthread_cond_wait`.

Wątek zbierający oczekuje w `pthread_cond_wait` na pojawienie się co najmniej jednego działającego klienta, a następnie wywołuje `wait()`. Po zebraniu procesu zmniejsza licznik i budzi wątek główny (`pthread_cond_signal`). Zmienna warunkowa jest konieczna, ponieważ przy braku procesów potomnych `wait()` natychmiast zwraca błąd `ECHILD`, co prowadziłoby do aktywnego czekania.

Po godzinie zamknięcia lub w przypadku ewakuacji generator przestaje uruchamiać nowych klientów, oczekuje na zebranie wszystkich procesów i kończy działanie.

### Klient

1. Losuje swoje cechy: płeć, niepełnosprawność (około 1%), liczbę dzieci (od 0 do 3), zamiar złożenia zamówienia (około 98%) oraz chęć skorzystania z łazienki.
2. Wchodzi do restauracji przez semafor `WOLNE_MIEJSCA`, zajmując tyle miejsc, ile osób liczy grupa. Po wejściu sprawdza flagę zamknięcia. Jeżeli restauracja jest już zamknięta, zwalnia miejsca i wychodzi.
3. Tworzy wątki dzieci, które oczekują na zmiennej warunkowej na podanie jedzenia.
4. Wybiera kasę: pod muteksem stanu wyszukuje otwartą kasę z najkrótszą kolejką, zwiększa jej licznik i podnosi semafor `ZMIANA_KOLEJEK`. Osoba z niepełnosprawnością wysyła zamówienie z typem 1 i nie jest wliczana do kolejki.
5. Wysyła zamówienie (losowa liczba pozycji z menu) i oczekuje na odpowiedź. W przypadku braku dania wybiera jedną z pozycji wskazanych przez kasę jako dostępne lub rezygnuje. Po kilku nieudanych próbach rezygnuje bezwarunkowo.
6. Płaci, otrzymuje paragon, ustawia flagę podania jedzenia i wywołuje `pthread_cond_broadcast`. Dzieci i opiekun spożywają posiłek, po czym opiekun oczekuje na zakończenie wątków dzieci (`pthread_join`). W przypadku rezygnacji dzieci również są budzone, z informacją o wyjściu bez posiłku.
7. Opcjonalnie korzysta z łazienki. Klient, który nie dokonał zakupu, najpierw kupuje w kasie bilet za 5 zł (zwykła wizyta w kolejce z innym rodzajem zamówienia). Mężczyzna korzysta z łazienki męskiej. Kobieta próbuje zająć miejsce w łazience damskiej, a jeśli jest pełna, w łazience dostępnej (obie próby z `IPC_NOWAIT`). Gdy obie są zajęte, oczekuje na miejsce w łazience damskiej. Osoba z niepełnosprawnością oraz opiekun z dziećmi korzystają z łazienki dostępnej.
8. Wychodzi z restauracji i zwalnia zajmowane miejsca.

Sygnał zamknięcia (`SIGUSR1`) dotyczy klienta wyłącznie przed wejściem. Bezpośrednio po wejściu klient wywołuje `signal(SIGUSR1, SIG_IGN)`, aby sygnał nie przerywał posiłku ani obsługi przy kasie. Wątki dzieci mają zablokowane wszystkie sygnały (`pthread_sigmask` przed `pthread_create`), dzięki czemu sygnały zawsze trafiają do wątku opiekuna.

Po otrzymaniu `SIGTERM` klient zapisuje do logu informację o opuszczeniu restauracji w trakcie ewakuacji, przywraca domyślną obsługę sygnału (`signal(SIGTERM, SIG_DFL)`) i wysyła go do siebie funkcją `raise(SIGTERM)`. Generator może dzięki temu rozpoznać w `wait()`, że proces zakończył się z powodu sygnału, a nie przez `exit`.

### Obsługa

Wątek główny przed utworzeniem kas blokuje sygnały `SIGUSR1`, `SIGUSR2` i `SIGTERM` funkcją `pthread_sigmask`. Maska jest dziedziczona przez wszystkie wątki, więc żaden sygnał nie trafi do wątku kasy. Następnie wątek główny tworzy dwie kasy i oczekuje na sygnały w `sigwait()`.

- `SIGUSR1`: jeżeli działa mniej niż 4 kasy, otwiera jedną z zamkniętych (`pthread_create`). W przeciwnym razie zapisuje do logu informację o braku kasy do otwarcia.
- `SIGUSR2`: jeżeli działa więcej niż 2 kasy, wybiera kasę z najkrótszą kolejką, oznacza ją w pamięci dzielonej jako zamykaną (klienci przestają ją wybierać) i umieszcza w jej kolejce komunikat zamknięcia (typ 3). Wątek tej kasy zostaje odłączony (`pthread_detach`), ponieważ nie będzie oczekiwania na jego zakończenie. Po obsłużeniu kolejki kończy się wywołaniem `pthread_exit`.
- `SIGTERM`: w przypadku ewakuacji obsługa natychmiast kończy działanie. Przy zwykłym zakończeniu dnia wysyła komunikat zamknięcia do każdej otwartej kasy, oczekuje na wątki przez `pthread_join` i dopiero wtedy kończy działanie. Wybór wariantu następuje na podstawie flagi w pamięci dzielonej.

Wątek kasy w pętli odbiera komunikaty. Po otrzymaniu zamówienia zmniejsza licznik kolejki (i podnosi `ZMIANA_KOLEJEK`), próbuje skompletować zamówienie z pojemników, w razie braku prowadzi wymianę komunikatów z klientem, wylicza kwotę, przyjmuje zapłatę, a po wydaniu porcji zwiększa `WOLNE_W_POJEMNIKACH` o liczbę wydanych pozycji. Po otrzymaniu komunikatu zamknięcia kończy pracę dopiero wtedy, gdy licznik jej kolejki osiągnie zero. Zabezpiecza to przed sytuacją, w której klient wybrał kasę tuż przed oznaczeniem jej jako zamykanej, a zamówienie wysłał już po komunikacie zamknięcia.

Statystyki procesu obsługi (utarg, liczba klientów) są współdzielone przez wątki kas i chronione muteksem pthread. Po obsłużeniu klienta kasa próbuje zająć muteks funkcją `pthread_mutex_trylock`. Jeżeli muteks jest zajęty, kwota jest odkładana do lokalnego licznika i dopisywana przy kolejnej okazji, co pozwala uniknąć blokowania obsługi kolejki.

### Kucharz

Kucharz w pętli oczekuje na `WOLNE_W_POJEMNIKACH` (gdy wszystkie pojemniki są pełne, pozostaje zablokowany w `semop`), losuje produkt spośród tych, których pojemnik ma wolne miejsce, przygotowuje go (`nanosleep` z losowym czasem) i zwiększa semafor odpowiedniego pojemnika. Ponieważ kucharz jest jedynym producentem, zarezerwowane przez niego miejsce nie może zostać zajęte przez inny proces. Pobieranie porcji przez kasy może jedynie zwiększyć liczbę wolnych miejsc.

Po otrzymaniu `SIGTERM` procedura obsługi ustawia flagę, wywołanie `semop` lub `nanosleep` zwraca `EINTR` i pętla zostaje zakończona.

### Logger

Logger otwiera FIFO do odczytu, tworzy plik logu (`creat`, `0600`), a następnie w pętli odczytuje dane z FIFO i zapisuje je do pliku. Kończy działanie, gdy `read()` zwróci 0. Każda linia zawiera czas symulowany, rolę i PID, np. `[12:47] KLIENT 48213: brak D3, wybieram D1`, dzięki czemu log odzwierciedla chronologiczny przebieg dnia w restauracji.

## Zasady otwierania i zamykania kas

Zasady są egzekwowane przez wątek nadzoru w procesie kierownika, budzony przy każdej zmianie długości kolejek.

- Jeżeli w którejkolwiek kolejce stoi więcej niż 7 osób i działa mniej niż 4 kasy, wysyłany jest sygnał 1.
- Jeżeli działa więcej niż 2 kasy i spełniony jest warunek `K / (N - 1) < 7` (K to łączna liczba osób we wszystkich kolejkach, N to liczba czynnych kas), wysyłany jest sygnał 2.

Standardowe sygnały nie są kolejkowane, dlatego po wysłaniu sygnału kierownik nie wysyła kolejnego, dopóki w pamięci dzielonej nie zmieni się liczba czynnych kas. Aby kierownik mógł wykryć tę zmianę bez aktywnego czekania, obsługa po otwarciu lub zamknięciu kasy również podnosi semafor `ZMIANA_KOLEJEK`.

Dosłowne zastosowanie obu zasad prowadzi do sprzeczności. Przykładowo: działają dwie kasy, w jednej kolejce stoi 8 osób, w drugiej 0. Po otwarciu trzeciej kasy `N = 3`, a `K / (N - 1) = 8 / 2 = 4`, co natychmiast spełnia warunek zamknięcia. Osoby stojące w kolejce nie przechodzą do nowej kasy, więc po jej zamknięciu sytuacja wraca do stanu wyjściowego, a kasa jest naprzemiennie otwierana i zamykana. W związku z tym przyjęto, że nowo otwarta kasa nie może zostać zamknięta przed upływem minimalnego czasu (np. 10 minut symulacji), a warunek zamknięcia jest sprawdzany wyłącznie wtedy, gdy żadna kolejka nie przekracza 7 osób. Problem ten zostanie opisany w raporcie jako niejednoznaczność założeń.

Polecenia wprowadzone ręcznie z klawiatury są realizowane w ten sam sposób (sygnał do obsługi), a obsługa niezależnie sprawdza ograniczenia 2 i 4 kas. Kierownik weryfikuje je wcześniej, aby od razu poinformować użytkownika o niewykonalności polecenia.

## Godzina zamknięcia i ewakuacja

O godzinie Tk wątek zegara ustawia flagę zamknięcia w pamięci dzielonej i wysyła `SIGUSR1` do grupy generatora. Generator przestaje uruchamiać nowych klientów. Klienci oczekujący przed wejściem otrzymują `EINTR` i odchodzą. Klienci przebywający w restauracji kontynuują wizytę bez zmian.

W tym miejscu występuje sytuacja wyścigu: klient może sprawdzić flagę, a zablokować się na semaforze dopiero po nadejściu sygnału. Nie prowadzi to jednak do błędu. Każdy wychodzący klient zwalnia miejsca, więc taki klient ostatecznie wejdzie, odczyta flagę zamknięcia, zwolni miejsca i wyjdzie. Sygnał jedynie przyspiesza ten proces.

W przypadku ewakuacji (sygnał 3 lub Ctrl+C w procesie kierownika) kierownik ustawia flagę ewakuacji, wysyła `SIGTERM` do grupy generatora i do obsługi, budzi swoje wątki i przechodzi do standardowej procedury usuwania zasobów. Miejsca i łazienki zajmowane przez zakończonych klientów są zwalniane dzięki `SEM_UNDO`.

## Miejsca oczekiwania

| Proces / wątek | Zdarzenie | Mechanizm |
| --- | --- | --- |
| kierownik, wątek główny | zakończenie generatora, następnie obsługi, kucharza i loggera | `waitpid` |
| kierownik, wątek poleceń | wprowadzenie polecenia | `read` ze standardowego wejścia |
| kierownik, nadzór kas | zmiana długości kolejek | `semop` na `ZMIANA_KOLEJEK` |
| kierownik, zegar | godzina zamknięcia lub ewakuacja | `pthread_cond_timedwait` |
| kierownik, start | gotowość pozostałych procesów | `read` z łącza nienazwanego |
| logger | kolejne linie logu | `read` z FIFO |
| kucharz | wolne miejsce w pojemnikach | `semop` na `WOLNE_W_POJEMNIKACH` |
| kucharz | przygotowanie potrawy | `nanosleep` |
| obsługa, wątek główny | polecenie kierownika | `sigwait` |
| obsługa, kasa | zamówienie lub polecenie zamknięcia | `msgrcv` na kolejce kasy |
| obsługa, kasa | odpowiedź klienta w trakcie obsługi | `msgrcv` na kolejce do kas |
| generator, wątek główny | czas do pojawienia się kolejnego klienta | `nanosleep` |
| generator, wątek główny | zwolnienie miejsca w limicie procesów | `pthread_cond_wait` |
| generator, wątek zbierający | pojawienie się działającego klienta | `pthread_cond_wait` |
| generator, wątek zbierający | zakończenie klienta | `wait` |
| klient | wejście do restauracji | `semop` na `WOLNE_MIEJSCA` |
| klient | odpowiedź kasy | `msgrcv` na kolejce do klientów |
| klient | jedzenie, łazienka | `nanosleep` |
| klient | miejsce w łazience | `semop` na semaforze łazienki |
| klient, dziecko | podanie jedzenia | `pthread_cond_wait` |
| klient, opiekun | zakończenie posiłku przez dzieci | `pthread_join` |

## Czas symulacji

Plik konfiguracyjny określa, ile milisekund czasu rzeczywistego odpowiada jednej minucie w restauracji. Przy wartości 100 ms dzień od 10:00 do 18:00 trwa 48 sekund. Kierownik zapisuje moment rozpoczęcia symulacji w pamięci dzielonej, a każdy proces wyznacza na jego podstawie czas symulowany na potrzeby logów. Czasy jedzenia, gotowania i obsługi są podawane w konfiguracji w minutach restauracji i przeliczane przy każdym wywołaniu `nanosleep`.

Jeżeli `nanosleep` zostanie przerwany sygnałem, który nie kończy procesu, funkcja zwraca pozostały czas, a proces kontynuuje uśpienie przez pozostały okres.

## Walidacja, obsługa błędów, prawa dostępu i usuwanie zasobów

**Walidacja danych (4.1 b).** Weryfikacji podlegają:

- argumenty wywołania kierownika (ścieżka do konfiguracji, ewentualne nadpisania wartości),
- każdy klucz konfiguracji: godziny w formacie HH:MM z godziną otwarcia wcześniejszą niż zamknięcia, K większe od 0, dodatnie pojemności i ceny, wartości procentowe z zakresu od 0 do 100, minimum nie większe od maksimum; nieznane klucze są odrzucane,
- limit jednocześnie działających klientów, porównywany z wartością `getrlimit(RLIMIT_NPROC)` pomniejszoną o zapas na pozostałe procesy. W przypadku przekroczenia kierownik informuje o maksymalnej dopuszczalnej wartości i nie rozpoczyna symulacji,
- polecenia z klawiatury: akceptowane są wyłącznie `1`, `2`, `3` i `s`, a polecenie `1` przy czterech czynnych kasach lub `2` przy dwóch skutkuje komunikatem zamiast wysłania sygnału,
- argumenty programów uruchamianych przez `exec()`, ponieważ mogą one zostać uruchomione również ręcznie.

**Obsługa błędów (4.1 c).** Wynik każdego wywołania systemowego jest sprawdzany, a błędy są zgłaszane funkcją `perror()`. Wartość `errno` jest analizowana tam, gdzie błąd jest spodziewany i ma znaczenie dla dalszego działania: `EINTR` (przerwanie sygnałem), `EAGAIN` (brak porcji w pojemniku, brak miejsca w łazience, przekroczenie limitu procesów przy `fork`), `EIDRM` i `EINVAL` (usunięcie struktury w trakcie ewakuacji) oraz `ECHILD`.

**Prawa dostępu (4.1 d).** Pamięć dzielona, semafory, kolejki komunikatów, FIFO, plik kluczy i plik logu mają prawa `0600`, a katalog `run/` prawa `0700`.

**Usuwanie zasobów (4.1 e).** Kierownik usuwa wszystkie struktury IPC, FIFO oraz plik kluczy. Pozostaje jedynie plik z logami. Po zakończeniu symulacji polecenie `ipcs` nie powinno wykazywać żadnych struktur należących do użytkownika, co stanowi jeden ze scenariuszy testowych.

## Struktura repozytorium

Struktura repozytorium jest zgodna z `~/ProgrammingProjects/Standards/PROJECT_STRUCTURE.md`, w wariancie dla języków C i C++ (CMake, flake oparty na flake-parts, treefmt, CI uruchamiające `nix flake check`).

```text
projekt/
├── .clang-format
├── .envrc
├── .github/workflows/ci.yml
├── .gitignore
├── CMakeLists.txt
├── LICENSE
├── README.md
├── flake.lock
├── flake.nix
├── config/
│   └── restauracja.conf      Tp, Tk, K, pojemniki, ceny, czasy, limity
├── docs/
│   ├── zadanie.md
│   ├── PLAN.md
│   └── raport/               źródło raportu i wygenerowany PDF
├── include/restauracja/
│   ├── wspolne.hpp           stałe, klucze ftok, indeksy semaforów,
│   │                         struktura pamięci dzielonej, komunikaty
│   ├── ipc.hpp               funkcje pomocnicze dla semop, msgsnd/msgrcv itd.
│   ├── log.hpp
│   ├── czas.hpp
│   └── konfiguracja.hpp
├── src/
│   ├── kierownik.cpp
│   ├── logger.cpp
│   ├── generator.cpp
│   ├── klient.cpp
│   ├── obsluga.cpp
│   ├── kucharz.cpp
│   └── wspolne/              kod współdzielony przez programy
│       ├── ipc.cpp
│       ├── log.cpp
│       ├── czas.cpp
│       └── konfiguracja.cpp
└── tests/                    skrypty scenariuszy testowych
```

Każdy plik w katalogu `src/`, z wyjątkiem `wspolne/`, odpowiada osobnemu programowi. CMake buduje z `src/wspolne/` bibliotekę statyczną, która jest dołączana do każdego programu. Wszystkie pliki wykonywalne trafiają do jednego katalogu, a kierownik uruchamia pozostałe programy przez `exec()` ze ścieżką względną wobec własnego pliku wykonywalnego. Z punktu widzenia Nixa projekt stanowi jeden pakiet (`packages.default`), a `nix run` uruchamia kierownika.

Katalogi `run/` (plik kluczy, FIFO) i `logs/` są tworzone w trakcie działania programu i zostały dodane do `.gitignore`.

## Funkcje systemowe do odnośników w raporcie

Zestawienie miejsc, w których występują poszczególne grupy funkcji wymienione w punkcie 5.2:

| Grupa | Funkcje | Miejsce użycia |
| --- | --- | --- |
| pliki | `creat`, `open`, `close`, `read`, `write`, `unlink` | logger (plik logu, FIFO), kierownik (plik kluczy, usuwanie zasobów) |
| procesy | `fork`, `exec`, `exit`, `wait` | kierownik (uruchamianie ról), generator (klienci, wątek zbierający) |
| wątki | `pthread_create`, `pthread_join`, `pthread_detach`, `pthread_exit` | obsługa (kasy), klient (dzieci), kierownik (wątek poleceń) |
| muteksy | `pthread_mutex_lock`, `unlock`, `trylock` | generator (licznik klientów), klient (podanie jedzenia), obsługa (statystyki, `trylock`) |
| zmienne warunkowe | `pthread_cond_wait`, `signal`, `broadcast` | generator (`signal`), klient (`broadcast` do dzieci), kierownik (zegar) |
| sygnały | `kill`, `raise`, `signal`, `sigaction` | kierownik (`kill`), klient (`raise`), procesy potomne przed `exec` (`signal`), kucharz i klient (`sigaction`) |
| semafory | `ftok`, `semget`, `semctl`, `semop` | wejście, łazienki, pojemniki, muteks stanu |
| łącza | `mkfifo`, `pipe`, `dup`, `dup2`, `popen` | logi (FIFO, `dup` i `dup2` w kierowniku), sygnalizacja gotowości (`pipe`), podsumowanie (`popen`) |
| pamięć dzielona | `ftok`, `shmget`, `shmat`, `shmdt`, `shmctl` | stan restauracji |
| kolejki komunikatów | `ftok`, `msgget`, `msgsnd`, `msgrcv`, `msgctl` | komunikacja klienta z kasą |
| gniazda | `socket`, `bind`, `listen`, `accept`, `connect` | opcjonalnie, opis poniżej |

Symulacja nie wymaga użycia gniazd. W miarę możliwości czasowych zostanie dodany program `panel`, który łączy się przez gniazdo `AF_UNIX` z dodatkowym wątkiem kierownika i przesyła te same polecenia, co klawiatura. Rozszerzenie to zostanie opisane w raporcie jako element dodatkowy.

Odnośniki w raporcie będą permalinkami do konkretnego commita w serwisie GitHub, a nie do gałęzi `main`, aby numery linii pozostały aktualne.

## Przypadki użycia do raportu

Raport (4.1 a) powinien przedstawiać następujące przypadki użycia, każdy wraz z odpowiednim fragmentem logu:

1. Typowy klient: wejście, kolejka, zamówienie, zapłata, posiłek, wyjście.
2. Brak dania: zmiana zamówienia oraz, w osobnym przebiegu, rezygnacja.
3. Klient bez zakupu, który płaci 5 zł za wstęp do łazienki.
4. Opiekun z dziećmi: wspólne wejście, zajęcie kilku miejsc, skorzystanie z łazienki dostępnej.
5. Osoba z niepełnosprawnością wchodząca i zamawiająca poza kolejnością.
6. Pełna restauracja: klienci oczekujący przy wejściu.
7. Otwarcie kasy po przekroczeniu 7 osób w kolejce oraz zamknięcie kasy przy spadku ruchu.
8. Ręczne wysłanie sygnałów 1 i 2, w tym odmowa przy 4 i przy 2 czynnych kasach.
9. Sygnał 3: natychmiastowa ewakuacja.
10. Godzina zamknięcia: wstrzymanie wpuszczania nowych klientów i opróżnienie restauracji.
11. Niepoprawne dane w konfiguracji i w poleceniach.

## Scenariusze testowe

Testy zostaną przygotowane jako skrypty w katalogu `tests/`, które uruchamiają symulację z określoną konfiguracją, a następnie analizują log oraz wynik polecenia `ipcs`:

- K równe 1, w celu wymuszenia oczekiwania przy wejściu,
- pojemniki o pojemności 1 i długi czas gotowania, w celu wymuszenia braków dań,
- duża liczba jednoczesnych klientów, w celu przekroczenia 7 osób w kolejce,
- ewakuacja w momencie największego ruchu, a następnie weryfikacja, że `ipcs` nie zawiera struktur i nie pozostały żadne procesy,
- limit procesów większy niż `RLIMIT_NPROC`, z oczekiwanym komunikatem i brakiem uruchomienia symulacji,
- zakończenie klienta poleceniem `kill -9` w trakcie wizyty, w celu sprawdzenia zwolnienia miejsc przez `SEM_UNDO`.

Problemy zaobserwowane podczas testów zostaną opisane w raporcie (5.1).

## Kwestie do weryfikacji przed implementacją

- Wersje `g++` i `cmake` dostępne na serwerze torus. W przypadku zbyt starej wersji CMake lub jej braku konieczne będzie obniżenie `cmake_minimum_required` albo kompilacja pojedynczym poleceniem `g++`.
- Limity IPC na serwerze torus (`ipcs -l`): maksymalna liczba semaforów w zestawie oraz rozmiar kolejki komunikatów.
- Wartość `ulimit -u` na serwerze torus, od której zależy maksymalna liczba jednocześnie działających klientów.
- Pozostałości po przerwanych przebiegach (`ipcs`, `ipcrm`). Kierownik przy starcie powinien wykryć istniejącą strukturę o danym kluczu (`IPC_CREAT | IPC_EXCL`) i poinformować o tym użytkownika zamiast korzystać z nieaktualnych danych.
