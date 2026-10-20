cmake_minimum_required(VERSION 3.20)
project(libpng_probe LANGUAGES C)

find_path(LIBPNG_INCLUDE_DIR png.h
	PATHS "${LIBPNG_PREFIX}/include"
	NO_DEFAULT_PATH
	NO_CMAKE_FIND_ROOT_PATH
	REQUIRED
)
find_library(LIBPNG_LIBRARY png16
	PATHS "${LIBPNG_PREFIX}/lib"
	NO_DEFAULT_PATH
	NO_CMAKE_FIND_ROOT_PATH
	REQUIRED
)
find_path(ZLIB_INCLUDE_DIR zlib.h
	PATHS "${ZLIB_PREFIX}/include"
	NO_DEFAULT_PATH
	NO_CMAKE_FIND_ROOT_PATH
	REQUIRED
)
find_library(ZLIB_LIBRARY z
	PATHS "${ZLIB_PREFIX}/lib"
	NO_DEFAULT_PATH
	NO_CMAKE_FIND_ROOT_PATH
	REQUIRED
)

add_executable(dependency-probe main.c)
target_include_directories(dependency-probe PRIVATE "${LIBPNG_INCLUDE_DIR}" "${ZLIB_INCLUDE_DIR}")
target_link_libraries(dependency-probe PRIVATE "${LIBPNG_LIBRARY}" "${ZLIB_LIBRARY}")
