cmake_minimum_required(VERSION 3.17)
project(sdl3-probe LANGUAGES C)

find_package(SDL3 REQUIRED CONFIG
	PATHS "${DEPENDENCY_PACKAGE_DIR}"
	NO_DEFAULT_PATH
	NO_CMAKE_FIND_ROOT_PATH
)

add_executable(dependency-probe main.c)
target_link_libraries(dependency-probe PRIVATE SDL3::SDL3-static)
