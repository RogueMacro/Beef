cmake_minimum_required(VERSION 3.12)

################### Variables. ####################
# Change if you want modify path or other values. #
###################################################

set(PROJECT_NAME IDEHelper)
# Output Variables
set(OUTPUT_DEBUG Debug/bin)
set(CMAKE_DEBUG_POSTFIX "_d")
set(OUTPUT_RELEASE Release/bin)

############## CMake Project ################
#        The main options of project        #
#############################################

project(${PROJECT_NAME} CXX C)

# Define Release by default.
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE "Debug")
  message(STATUS "Build type not specified: Use Debug by default.")
endif(NOT CMAKE_BUILD_TYPE)

# Definition of Macros
add_definitions(
   -DIDEHELPER_EXPORTS
   -DBFSYSLIB_DYNAMIC
   -DUNICODE
   -D_UNICODE
   -DBF_NO_FBX
   -DFT2_BUILD_LIBRARY
   -DBFSYSLIB_DYNAMIC
)

set (CMAKE_CXX_STANDARD 17)
# Compiler/CeZmij.c needs C99+ with GNU extensions (zmij uses the 'asm' keyword
# on GCC/Clang, which strict ISO mode disables)
set (CMAKE_C_STANDARD 11)
set (CMAKE_C_EXTENSIONS ON)
#add_definitions(-D_GLIBCXX_USE_CXX11_ABI=1)

INCLUDE(CheckIncludeFiles)
CHECK_INCLUDE_FILES(backtrace.h HAVE_BACKTRACE_HEADERS)
if (HAVE_BACKTRACE_HEADERS)
   add_definitions(-DBFP_HAS_BACKTRACE)
endif ()

if (${APPLE})
  include_directories(
    .
    ../
    ../BeefySysLib/
    ../BeefySysLib/third_party
    ../BeefySysLib/third_party/freetype/include

    ../BeefySysLib/platform/osx
  )
else()
  include_directories(
    .
    ../
    ../BeefySysLib/
    ../BeefySysLib/third_party
    ../BeefySysLib/third_party/freetype/include

    ../BeefySysLib/platform/linux
  )
endif()

############## Artefacts Output #################
# Defines outputs , depending Debug or Release. #
#################################################

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  add_definitions(
    -D_DEBUG
  )
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${OUTPUT_DEBUG}")
  set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${OUTPUT_DEBUG}")
  set(CMAKE_EXECUTABLE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${OUTPUT_DEBUG}")
else()
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${OUTPUT_RELEASE}")
  set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${OUTPUT_RELEASE}")
  set(CMAKE_EXECUTABLE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/${OUTPUT_RELEASE}")
endif()

################### Dependencies ##################
# Add Dependencies to project.                    #
###################################################

option(BUILD_DEPENDS
   "Build other CMake project."
   ON
)

# Dependencies : disable BUILD_DEPENDS to link with lib already build.
if(BUILD_DEPENDS)

else()

endif()

################# Flags ################
# Defines Flags for Windows and Linux. #
########################################

if(MSVC)
   set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /W3 /MD /MDd /Od /EHsc")
   set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /W3 /GL /Od /Oi /Gy /EHsc")
endif(MSVC)
if(NOT MSVC)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17 -fno-rtti -Wno-multichar -Wno-invalid-offsetof")
endif(NOT MSVC)

################ Files ################
#   --   Add files to project.   --   #
#######################################

file(GLOB SRC_FILES
    BfDiff.cpp
    Debugger.cpp
    DebugManager.cpp
    DebugVisualizers.cpp
    NetManager.cpp
    SpellChecker.cpp
    Targets.cpp
    X86XmmInfo.cpp
    LLDBDebugger.cpp
    LLDBDebuggerHost.cpp
    LLDBDebuggerShadow.cpp
    GDBDebugger.cpp

    Beef/BfCommon.cpp
    Clang/CDepChecker.cpp
    Clang/ClangHelper.cpp
    Compiler/BfAst.cpp
    Compiler/BfAstAllocator.cpp
    Compiler/BfAutoComplete.cpp
    Compiler/BfCodeGen.cpp
    Compiler/BfCompiler.cpp
    Compiler/BfConstResolver.cpp
    Compiler/BfContext.cpp
    Compiler/BfDefBuilder.cpp
    Compiler/BfDeferEvalChecker.cpp
    Compiler/BfDemangler.cpp
    Compiler/BfElementVisitor.cpp
    Compiler/BfNamespaceVisitor.cpp
    Compiler/BfExprEvaluator.cpp
    Compiler/BfIRBuilder.cpp
    Compiler/BfIRCodeGen.cpp
    Compiler/BfMangler.cpp
    Compiler/BfModule.cpp
    Compiler/BfModuleTypeUtils.cpp
    Compiler/BfParser.cpp
    Compiler/BfPrinter.cpp
    Compiler/BfReducer.cpp
    Compiler/BfResolvedTypeUtils.cpp
    Compiler/BfResolvePass.cpp
    Compiler/BfSource.cpp
    Compiler/BfSourceClassifier.cpp
    Compiler/BfSourcePositionFinder.cpp
    Compiler/BfStmtEvaluator.cpp
    Compiler/BfSystem.cpp
    Compiler/BfUtil.cpp
    Compiler/BfVarDeclChecker.cpp
    Compiler/BfTargetTriple.cpp
    Compiler/CeMachine.cpp
    Compiler/CeZmij.c
    Compiler/CeDebugger.cpp
    Compiler/MemReporter.cpp

    Backend/BeContext.cpp
    Backend/BeIRCodeGen.cpp
    Backend/BeModule.cpp
)

find_package(LLVM 22.1 CONFIG COMPONENTS)

if (LLVM_FOUND)
  message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION}")
  message(STATUS "Using LLVMConfig.cmake in: ${LLVM_DIR}")

  include_directories(${LLVM_INCLUDE_DIRS})
  add_definitions(${LLVM_DEFINITIONS})

  string(APPEND TARGET_LIBS_OS "-lLLVM-22 ${LLVM_SYSTEM_LIBS}")
  string(STRIP ${TARGET_LIBS_OS} TARGET_LIBS_OS)
else()
  message(FATAL_ERROR "LLVM not found")
endif()

option(BF_DBG_HOST "Build the Beef debug info and expression evaluation layer" ON)

if(UNIX)
  if (APPLE)
    # Link Apple's LLDB.framework (from Xcode or the Command Line Tools), which keeps its LLVM internal. Homebrew's
    # liblldb links Homebrew's newer libLLVM, and that can't share a process with the LLVM 22 we link: its
    # expression parser crashes. Apple ships no SB API headers, so those come from Homebrew's 'lldb' formula -
    # the SB API is ABI stable.
    # Weak-linked, so the IDE still starts on a machine without Xcode / the Command Line Tools (CreateDebuggerLLDB
    # then returns NULL and debugging reports what's missing).
    execute_process(COMMAND xcode-select -p OUTPUT_VARIABLE XCODE_DEVELOPER_DIR OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    find_library(LLDB_LIBRARY NAMES LLDB PATHS "${XCODE_DEVELOPER_DIR}/../SharedFrameworks" "${XCODE_DEVELOPER_DIR}/Library/PrivateFrameworks" NO_DEFAULT_PATH)
    find_path(LLDB_INCLUDE_DIR lldb/API/LLDB.h PATHS /opt/homebrew/opt/lldb/include /usr/local/opt/lldb/include NO_DEFAULT_PATH)
    if (LLDB_LIBRARY)
      get_filename_component(LLDB_FRAMEWORK_DIR "${LLDB_LIBRARY}" DIRECTORY)
      set(LLDB_LINK_FLAGS "-F${LLDB_FRAMEWORK_DIR} -weak_framework LLDB -Wl,-rpath,${LLDB_FRAMEWORK_DIR}")
    endif()
  else()
    find_path(LLDB_INCLUDE_DIR lldb/API/LLDB.h HINTS ${LLVM_INCLUDE_DIRS})
    find_library(LLDB_LIBRARY NAMES lldb-22 liblldb-22 lldb liblldb HINTS ${LLVM_LIBRARY_DIRS})
    set(LLDB_LINK_FLAGS "${LLDB_LIBRARY}")
  endif()

  if (NOT BF_DBG_HOST)
    message(WARNING "BF_DBG_HOST is OFF; IDE debugger support will be disabled")
  elseif (LLDB_INCLUDE_DIR AND LLDB_LIBRARY)
    message(STATUS "Found LLDB: ${LLDB_LIBRARY}")
    include_directories(SYSTEM ${LLDB_INCLUDE_DIR})
    add_definitions(-DLLDB_ENABLED)
    string(APPEND TARGET_LIBS_OS " ${LLDB_LINK_FLAGS}")
    string(STRIP ${TARGET_LIBS_OS} TARGET_LIBS_OS)
  elseif (APPLE)
    message(WARNING "LLDB was not found (needs Xcode or the Command Line Tools, and 'brew install lldb' for headers); IDE debugger support will be disabled")
  else()
    message(WARNING "LLDB was not found; IDE debugger support will be disabled")
  endif()

endif()

if (BF_DBG_HOST AND NOT MSVC)
  set(DBG_HOST_FILES
    DbgModule.cpp
    DebugTarget.cpp
    DbgTypeMap.cpp
    DbgExprEvaluator.cpp
    DbgEvalSupport.cpp
    DbgSymbolSupport.cpp
    DbgEvalPool.cpp
    HotHeap.cpp
  )
  if (UNIX AND NOT APPLE)
    list(APPEND DBG_HOST_FILES ElfDbgModule.cpp)
  endif()
  set_source_files_properties(${DBG_HOST_FILES} PROPERTIES COMPILE_DEFINITIONS BF_DBG_64)
  list(APPEND SRC_FILES ${DBG_HOST_FILES})
endif()

# Add library to build.
add_library(${PROJECT_NAME} STATIC
   ${SRC_FILES}
)

if (HAVE_BACKTRACE_HEADERS)
  string(APPEND TARGET_LIBS_OS " -lbacktrace")
  string(STRIP ${TARGET_LIBS_OS} TARGET_LIBS_OS)
endif()

if (DEFINED BF_ENABLE_SDL)
  string(STRIP ${TARGET_LIBS_OS} TARGET_LIBS_OS)
endif()

if (CMAKE_BUILD_TYPE STREQUAL "Debug" )
  FILE(WRITE "${CMAKE_CURRENT_SOURCE_DIR}/../IDE/dist/IDEHelper_libs_d.txt" ${TARGET_LIBS_OS})
else()
  FILE(WRITE "${CMAKE_CURRENT_SOURCE_DIR}/../IDE/dist/IDEHelper_libs.txt" ${TARGET_LIBS_OS})
endif()

# Link with other dependencies.
if(MSVC)
  target_link_libraries(${PROJECT_NAME} BeefySysLib kernel32.lib user32.lib gdi32.lib winspool.lib comdlg32.lib advapi32.lib shell32.lib ole32.lib oleaut32.lib uuid.lib odbc32.lib odbccp32.lib LLVMX86Disassembler.lib LLVMMCDisassembler.lib LLVMSupport.lib LLVMX86Info.lib LLVMX86Desc.lib %(AdditionalDependencies) LLVMMC.lib LLVMObject.lib LLVMCore.lib LLVMBitReader.lib LLVMAsmParser.lib LLVMMCParser.lib LLVMCodeGen.lib LLVMTarget.lib LLVMX86CodeGen.lib LLVMScalarOpts.lib LLVMInstCombine.lib LLVMSelectionDAG.lib LLVMProfileData.lib LLVMTransformUtils.lib LLVMAnalysis.lib LLVMX86AsmParser.lib LLVMAsmPrinter.lib LLVMBitWriter.lib LLVMVectorize.lib LLVMipo.lib LLVMInstrumentation.lib LLVMDebugInfoDWARF.lib LLVMDebugInfoPDB.lib LLVMDebugInfoCodeView.lib LLVMGlobalISel.lib LLVMBinaryFormat.lib LLVMAggressiveInstCombine.lib libcurl_a.lib)
else()
  target_link_libraries(${PROJECT_NAME} BeefySysLib hunspell pthread dl ${TARGET_LIBS_OS})
endif()
