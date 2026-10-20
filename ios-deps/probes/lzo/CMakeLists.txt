cmake_minimum_required(VERSION 3.20)
project(lzo_probe LANGUAGES C)

find_path(LZO_INCLUDE_DIR lzo/lzo1x.h
	PATHS "${LZO_PREFIX}/include"
	NO_DEFAULT_PATH
	NO_CMAKE_FIND_ROOT_PATH
	REQUIRED
)
find_library(LZO_LIBRARY lzo2
	PATHS "${LZO_PREFIX}/lib"
	NO_DEFAULT_PATH
	NO_CMAKE_FIND_ROOT_PATH
	REQUIRED
)

add_executable(dependency-probe main.c)
target_include_directories(dependency-probe PRIVATE "${LZO_INCLUDE_DIR}")
target_link_libraries(dependency-probe PRIVATE "${LZO_LIBRARY}")
