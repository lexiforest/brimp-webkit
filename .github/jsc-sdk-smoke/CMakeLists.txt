cmake_minimum_required(VERSION 3.20)

project(JavaScriptCoreSDKSmoke C)

find_package(JavaScriptCore CONFIG REQUIRED)

add_executable(jsc-sdk-smoke main.c)
target_link_libraries(
    jsc-sdk-smoke PRIVATE JavaScriptCore::JavaScriptCore)
