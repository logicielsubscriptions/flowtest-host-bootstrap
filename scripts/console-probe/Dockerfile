# escape=`
#
# A minimal Windows console application that reports what the container runtime
# does to its entrypoint process. See probe.ps1 for why this exists.
#
# Deliberately NOT based on the engine image: the question is about the runtime,
# so answering it must not wait on an engine image, on config staging, or on a
# flow-test stack. All three are blocked; this is not.

ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2022
FROM ${BASE_IMAGE}

COPY probe.ps1 C:/probe.ps1

ENV PROBE_SECONDS=300

LABEL com.logiciel.flowtest.purpose="console control event probe"

# EXEC form, no wrapper - the same shape the engine images use, so the process
# tree under test matches the one that will run in production.
ENTRYPOINT ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\probe.ps1"]
