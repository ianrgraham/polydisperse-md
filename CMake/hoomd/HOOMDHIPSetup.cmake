if(ENABLE_HIP)
    find_package(HIP QUIET)

    if (HIP_FOUND)
        # call hipcc to tell us about the backend compiler
        set(ENV{HIPCC_VERBOSE} 1)

        FILE(WRITE ${CMAKE_CURRENT_BINARY_DIR}/hip_test.cc "
int main(int argc, char **argv)
{ }
")
        EXECUTE_PROCESS(COMMAND ${HIP_HIPCC_EXECUTABLE} ${CMAKE_CURRENT_BINARY_DIR}/hip_test.cc OUTPUT_VARIABLE _hipcc_verbose_out)

        string(REPLACE " " ";" _hipcc_verbose_options ${_hipcc_verbose_out})

        # get the compiler executable for device code
        LIST(GET _hipcc_verbose_options 1 _hip_compiler)

        # set it as the compiler
        if (${_hip_compiler} MATCHES nvcc)
            set(HIP_PLATFORM nvcc)
        elseif(${_hip_compiler} MATCHES hcc)
            set(HIP_PLATFORM hcc)
        elseif(${_hip_compiler} MATCHES clang)
            set(HIP_PLATFORM hip-clang)
        else()
            message(ERROR "Unknown HIP backend " ${_hip_compiler})
        endif()

        # use hipcc as C++ linker for shared libraries
        SET(CMAKE_CUDA_COMPILER ${HIP_HIPCC_EXECUTABLE})

        # this is hack to set the right options on hipcc, may not be portable
        include(hipcc)

        # override command line, so that it doesn't contain "-x cu"
        set(CMAKE_CUDA_COMPILE_WHOLE_COMPILATION
            "<CMAKE_CUDA_COMPILER> ${CMAKE_CUDA_HOST_FLAGS} <DEFINES> <INCLUDES> <FLAGS> -c <SOURCE> -o <OBJECT>")

        # setup nvcc to build for all CUDA architectures. Allow user to modify the list if desired
        set(AMDGPU_TARGET_LIST gfx900 gfx906 gfx908 CACHE STRING "List of AMD GPU to compile HIP code for. Separate with semicolons.")

        foreach(_amdgpu_target ${AMDGPU_TARGET_LIST})
            set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} --amdgpu-target=${_amdgpu_target}")
        endforeach (_amdgpu_target)

        if (HIP_FOUND)
            # reduce link time (no device linking)
            set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -fno-gpu-rdc")
        endif()

        # these are no-ops, as device linking is not supported with hcc
        set(CMAKE_CUDA_DEVICE_LINK_LIBRARY "<CMAKE_CUDA_COMPILER> -o <TARGET> -x c++ -c /dev/null")
        set(CMAKE_CUDA_DEVICE_LINK_EXECUTABLE "<CMAKE_CUDA_COMPILER> -o <TARGET> -x c++ -c /dev/null")

        if(CMAKE_GENERATOR STREQUAL "Ninja")
            # this is also ugly, but ninja/hipcc is only supported with a future cmake
            CMAKE_MINIMUM_REQUIRED(VERSION 3.17.0 FATAL_ERROR)

            # hipcc can write dependencies (undocumented CMake option)
            set(CMAKE_DEPFILE_FLAGS_CUDA "-MD -MT <OBJECT> -MF <DEPFILE>")
        endif()

        # don't let CMake examine the compiler, because it will fail
        SET(CMAKE_CUDA_COMPILER_FORCED TRUE)

        #search for HIP include directory
        find_path(HIP_INCLUDE_DIR hip/hip_runtime.h
                PATHS
               "${HIP_ROOT_DIR}"
                ENV ROCM_PATH
                ENV HIP_PATH
                PATH_SUFFIXES include)

        find_path(ROCm_hsa_INCLUDE_DIR
            NAMES hsa/hsa.h
            PATHS
            ${HIP_ROOT_DIR}/hsa
            ${HIP_ROOT_DIR}/hsa
            $ENV{ROCM_PATH}/hsa
            $ENV{HIP_PATH}/hsa
            $ENV{HSA_PATH}
            /opt/rocm
            PATH_SUFFIXES include
            NO_DEFAULT_PATH)

        option(ENABLE_ROCTRACER "Enable roctracer profiler integration" off)

        list(APPEND HIP_INCLUDE_DIR ${ROCm_hsa_INCLUDE_DIR})
    else()
        # here we go if hipcc is not available, fall back on internal HIP->CUDA headers
        ENABLE_LANGUAGE(CUDA)

        set(HIP_INCLUDE_DIR "$<IF:$<STREQUAL:${CMAKE_PROJECT_NAME},HOOMD>,${CMAKE_CURRENT_SOURCE_DIR},${HOOMD_INSTALL_PREFIX}/${PYTHON_SITE_INSTALL_DIR}/include>/hoomd/extern/HIP/include/")

        # use CUDA runtime version
        string(REGEX MATCH "([0-9]*).([0-9]*).([0-9]*).*" _hip_version_match "${CMAKE_CUDA_COMPILER_VERSION}")
        set(HIP_VERSION_MAJOR "${CMAKE_MATCH_1}")
        set(HIP_VERSION_MINOR "${CMAKE_MATCH_2}")
        set(HIP_VERSION_PATCH "${CMAKE_MATCH_3}")
        set(HIP_PLATFORM "nvcc")
        set(CUB_INCLUDE_DIR "$<IF:$<STREQUAL:${CMAKE_PROJECT_NAME},HOOMD>,${CMAKE_CURRENT_SOURCE_DIR},${HOOMD_INSTALL_PREFIX}/${PYTHON_SITE_INSTALL_DIR}/include>/hoomd/extern/cub/")

        # hipCUB
        # funny enough, we require this only on NVIDA platforms due to issues with hipCUB's cmake build system
        # on AMD platforms, it is an external dependency
        if (CMAKE_CUDA_COMPILER_VERSION VERSION_LESS 11)
            set(HIPCUB_INCLUDE_DIR "$<IF:$<STREQUAL:${CMAKE_PROJECT_NAME},HOOMD>,${CMAKE_CURRENT_SOURCE_DIR},${HOOMD_INSTALL_PREFIX}/${PYTHON_SITE_INSTALL_DIR}/include>/hoomd/extern/hipCUB/hipcub/include/;${CUB_INCLUDE_DIR}")
        else()
            # Use system provided CUB for CUDA 11 and newer
            set(HIPCUB_INCLUDE_DIR "$<IF:$<STREQUAL:${CMAKE_PROJECT_NAME},HOOMD>,${CMAKE_CURRENT_SOURCE_DIR},${HOOMD_INSTALL_PREFIX}/${PYTHON_SITE_INSTALL_DIR}/include>/hoomd/extern/hipCUB/hipcub/include/")
        endif()
    endif()

    ENABLE_LANGUAGE(CUDA)

    if(NOT TARGET HIP::hip)
        add_library(HIP::hip INTERFACE IMPORTED)
        set_target_properties(HIP::hip PROPERTIES
            INTERFACE_INCLUDE_DIRECTORIES "${HIP_INCLUDE_DIR};${HIPCUB_INCLUDE_DIR}")

        # set HIP_VERSION_* on non-CUDA targets (the version is already defined on AMD targets through hipcc)
        set_property(TARGET HIP::hip APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS
            $<$<NOT:$<COMPILE_LANGUAGE:CUDA>>:HIP_VERSION_MAJOR=${HIP_VERSION_MAJOR}>)
        set_property(TARGET HIP::hip APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS
            $<$<NOT:$<COMPILE_LANGUAGE:CUDA>>:HIP_VERSION_MINOR=${HIP_VERSION_MINOR}>)
        set_property(TARGET HIP::hip APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS
            $<$<NOT:$<COMPILE_LANGUAGE:CUDA>>:HIP_VERSION_PATCH=${HIP_VERSION_PATCH}>)

        # branch upon HCC or NVCC target
        if(${HIP_PLATFORM} STREQUAL "nvcc")
            set_property(TARGET HIP::hip APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS
                $<$<NOT:$<COMPILE_LANGUAGE:CUDA>>:__HIP_PLATFORM_NVCC__>)
        elseif(${HIP_PLATFORM} STREQUAL "hcc" OR ${HIP_PLATFORM} STREQUAL "hip-clang")
            set_property(TARGET HIP::hip APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS
                $<$<NOT:$<COMPILE_LANGUAGE:CUDA>>:__HIP_PLATFORM_HCC__>)
        endif()
    endif()
    find_package(CUDALibs REQUIRED)
endif()
