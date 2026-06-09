cmake_minimum_required(VERSION 3.14)
project(iolink VERSION 0.1.0 LANGUAGES C)

# ── Options ───────────────────────────────────────────────────────────────────
set(LOG_LEVEL               "WARNING")
set(IOLINK_NUM_PORTS        4)
set(IOLINK_NUM_DIAG_ENTRIES 10)
set(IOLINK_MAX_EVENTS       6)
set(IOLINK_HW               "MAX14819")

set(ILINK_VERSION_MAJOR 0)
set(ILINK_VERSION_MINOR 1)
set(ILINK_VERSION_PATCH 0)

# ── Generate headers ─────────────────────────────────────────────────────────
configure_file(iolink_options.h.in iolink_options.h)
configure_file(version.h.in version.h)

# ── Sources ───────────────────────────────────────────────────────────────────
file(GLOB IOLINK_SOURCES src/*.c)
file(GLOB OSAL_LINUX_SOURCES   iol_osal/linux-spidev/*.c)
file(GLOB OSAL_SOURCES   osal/src/linux/*.c)

# ── Library ───────────────────────────────────────────────────────────────────
add_library(iolink SHARED ${IOLINK_SOURCES} ${OSAL_LINUX_SOURCES} ${OSAL_SOURCES})

target_include_directories(iolink
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/iol_osal/include>
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/osal/include>
        $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_SOURCE_DIR}/osal/src/linux
)

target_compile_options(iolink PRIVATE -Wall -Wextra -Wno-unused-parameter)

# ── Install ───────────────────────────────────────────────────────────────────
include(GNUInstallDirs)
install(TARGETS iolink
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(FILES
    include/iolink.h
    include/iolink_dl.h
    include/iolink_main.h
    include/iolink_max14819.h
    include/iolink_types.h
    iol_osal/include/osal_irq.h
    iol_osal/include/osal_spi.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/iolink_options.h
    ${CMAKE_CURRENT_BINARY_DIR}/version.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
