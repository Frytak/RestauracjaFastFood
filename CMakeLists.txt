cmake_minimum_required(VERSION 3.16)

project(
  restauracja
  VERSION 0.1.0
  DESCRIPTION "Symulacja restauracji fast food na procesach i watkach"
  LANGUAGES CXX)

# C++17, because the project has to build on torus.uck.pk.edu.pl as well.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Each program from docs/PLAN.md gets its own add_executable here. Shared code
# from src/wspolne/ becomes a static library linked into all of them.
add_executable(kierownik src/kierownik.cpp)

target_include_directories(kierownik PRIVATE include)
target_compile_options(kierownik PRIVATE -Wall -Wextra -Wpedantic)

install(TARGETS kierownik RUNTIME DESTINATION bin)
