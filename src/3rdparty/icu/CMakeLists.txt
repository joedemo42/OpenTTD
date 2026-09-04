if(NOT IOS)
    add_subdirectory(tests)
endif()

add_files(
    scriptrun.cpp
    scriptrun.h
    CONDITION ICU_I18N_FOUND
)
