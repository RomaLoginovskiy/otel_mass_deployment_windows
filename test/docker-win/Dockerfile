# escape=`
# Windows E2E test image: IIS + Coralogix OpAMP supervisor, driven by the real deploy
# automation. Proves CX_IIS_SERVICES (set by the scripts from the actual IIS apps) populates
# the Service-ownership tags via the supervisor path, aligned with per-app OTEL_SERVICE_NAME.
#
# Build from the REPO ROOT so the deploy/ scripts are in context:
#   docker build -f test/docker-win/Dockerfile -t cx-iis-owner-test .
# Requires Docker in Windows-container mode (Hyper-V isolation on Win11 clients).
FROM mcr.microsoft.com/windows/servercore/iis:windowsservercore-ltsc2022

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
WORKDIR C:\\cx

# Server Core defaults to legacy TLS; GitHub (vendor collector MSI download) needs TLS 1.2.
# Without this the vendor installer fails: "The decryption operation failed".
RUN Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name SchUseStrongCrypto -Value 1 -Type DWord; `
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' -Name SchUseStrongCrypto -Value 1 -Type DWord

# The real fleet automation + the base (template) collector config that carries the processor.
COPY deploy/ C:/cx/deploy/
COPY test/docker-win/entrypoint.ps1 C:/cx/entrypoint.ps1
# Coralogix collector binary (v0.155.0), baked in so the container does not need the vendor
# installer's GitHub MSI download (which fails in a minimal Server Core container). The
# collector runs directly against the base config = HYBRID semantics (base authoritative).
COPY test/docker-win/otelcol-contrib.exe C:/cx/otelcol-contrib.exe

# Coralogix send key + domain are supplied at run time (docker run -e ...), never baked in.
ENV CORALOGIX_DOMAIN=eu1.coralogix.com `
    CX_TEST_SITES=shop,wallet,blog

ENTRYPOINT ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\cx\\entrypoint.ps1"]
