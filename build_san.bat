@echo off
setlocal enabledelayedexpansion

echo ===================================================
echo   Compilando Core Atari 2600 - Tang Nano 20K (SAN)
echo ===================================================
echo.

set GW_SH=gw_sh.exe

:: Verifica se gw_sh esta no PATH
where /q gw_sh.exe
if %ERRORLEVEL% equ 0 (
    echo [INFO] Encontrado gw_sh.exe no PATH do sistema.
    goto RUN_BUILD
)

:: Se nao estiver no PATH, procura por instalacoes padrao da Gowin
echo [INFO] gw_sh.exe nao encontrado no PATH. Procurando em C:\Gowin...

set GOWIN_FOUND=0
for /d %%D in ("C:\Gowin\Gowin_*") do (
    if exist "%%D\IDE\bin\gw_sh.exe" (
        set "GW_SH=%%D\IDE\bin\gw_sh.exe"
        set GOWIN_FOUND=1
        echo [INFO] Encontrado Gowin EDA em: !GW_SH!
    )
)

if !GOWIN_FOUND! equ 0 (
    echo [ERRO] Nao foi possivel encontrar a instalacao do Gowin EDA.
    echo Certifique-se de que o Gowin EDA esta instalado em C:\Gowin ou adicione a pasta IDE\bin ao PATH.
    echo.
    pause
    exit /b 1
)

:RUN_BUILD
echo [INFO] Iniciando sintese e geracao de Bitstream via TCL script...
echo.

"%GW_SH%" build_tn20k_san.tcl

if %ERRORLEVEL% equ 0 (
    echo.
    echo ===================================================
    echo   [SUCESSO] Compilacao concluida com sucesso!
    echo   Bitstream gerado em impl\pnr\
    echo ===================================================
) else (
    echo.
    echo ===================================================
    echo   [ERRO] Falha durante a compilacao. Veja o log acima.
    echo ===================================================
)

echo.
pause
