cmake_minimum_required(VERSION 3.20)
project(zlib_probe LANGUAGES C)

find_package(ZLIB REQUIRED CONFIG COMPONENTS static
	PATHS "${DEPENDENCY_PACKAGE_DIR}"
	NO_DEFAULT_PATH
	NO_CMAKE_FIND_ROOT_PATH
)

add_executable(dependency-probe main.c)
target_link_libraries(dependency-probe PRIVATE ZLIB::ZLIBSTATIC)
