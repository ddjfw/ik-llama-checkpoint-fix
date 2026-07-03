@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

rem =========================================================
rem Ornstein3.6-27B-MTP-NSC-ACE-SABER 전용 서버 (ik_llama.cpp)
rem CPU Offload / Long Context 안정판
rem =========================================================

rem =========================================================
rem 1. 경로 설정
rem =========================================================
set "LLAMA=C:\llama-ik\build\bin\Release\llama-server.exe"
set "MODEL=C:\models\Ornstein3.6-27B-MTP-NSC-ACE-SABER-IQ4_XS-13GiB.gguf"
set "MMPROJ=C:\models\Qwen3.6-27B-mmproj-hybrid-Q8_0-F16.gguf"

set "HOST=127.0.0.1"
set "PORT=8080"

set "THREADS=8"
set "THREADS_BATCH=12"

set "CACHE_RAM=14336"
set "MMAP_FLAG=--no-mmap"
set "REASONING_FLAG=--reasoning-format deepseek"
set "CHECKPOINT_FLAGS=--ctx-checkpoints 8"

rem CPU offload 제어용
rem ngl 999 = 거의 전체 GPU
rem ngl 수치를 낮출수록 일부 레이어를 CPU로 오프로딩
set "NGL=999"
set "OFFLOAD_MODE=Full GPU"
set "AUTO_OFFLOAD=1"

rem =========================================================
rem 2. MTP 감지 (ik 버전별 플래그명 차이 대비)
rem =========================================================
set "MTP_FLAGS="
"%LLAMA%" --help 2>&1 | findstr /I /C:"--spec-type" >nul
if not errorlevel 1 (
    set "MTP_FLAGS=--spec-type mtp --spec-draft-n-max 2 --spec-draft-p-min 0.75"
) else (
    "%LLAMA%" --help 2>&1 | findstr /I /C:"-mtp" >nul
    if not errorlevel 1 (
        set "MTP_FLAGS=-mtp --draft-max 2 --draft-p-min 0.75 --draft-min 1"
    )
)

if not defined MTP_FLAGS (
    echo([WARNING] MTP 플래그 감지 실패. MTP 없이 실행됩니다.
)

echo ============================================================
echo([ Ornstein3.6-27B-MTP-NSC-ACE-SABER 전용 서버 - ik 빌드 ]
echo(모델: %MODEL%
echo(MTP : %MTP_FLAGS%
echo ============================================================
echo(

rem =========================================================
rem 3. 비전 어댑터 선택
rem =========================================================
echo([ 비전 어댑터 로드 여부 ])
echo( Y. 비전 포함 [mmproj 활성화 / VRAM + 약 300MB]
echo( N. 텍스트 전용 [권장]
echo(
set /p V_CHOICE="비전 로드 여부 (Y/N, 기본값 N): "
if "%V_CHOICE%"=="" set "V_CHOICE=N"

if /I "%V_CHOICE%"=="Y" (
    if not exist "%MMPROJ%" (
        echo([ERROR] mmproj 파일 없음: %MMPROJ%
        pause
        goto :END
    )
    set "MMPROJ_FLAG=--mmproj ""%MMPROJ%"""
    set "VISION_LABEL=Vision ON"
) else (
    set "MMPROJ_FLAG="
    set "VISION_LABEL=Text only"
)
echo(

rem =========================================================
rem 4. 작업 유형 (샘플링)
rem =========================================================
echo ============================================================
echo([ 작업 유형 선택 ])
echo( 1. 일반 추론 / 논리 설계  [Temp 1.0 / Top-P 0.95 / Top-K 20]
echo( 2. 정밀 코딩 / 디버깅    [Temp 0.6 / Top-P 0.95 / Top-K 20] - 권장
echo( 3. 일반 대화 / 요약      [Temp 0.7 / Top-P 0.80 / Top-K 20]
echo ============================================================
set /p S_CHOICE="작업 유형 선택 (1-3, 기본값 2): "
if "%S_CHOICE%"=="" set "S_CHOICE=2"

set "SAMPLING=--temp 0.6 --top-p 0.95 --top-k 20"
if "%S_CHOICE%"=="1" set "SAMPLING=--temp 1.0 --top-p 0.95 --top-k 20"
if "%S_CHOICE%"=="2" set "SAMPLING=--temp 0.6 --top-p 0.95 --top-k 20"
if "%S_CHOICE%"=="3" set "SAMPLING=--temp 0.7 --top-p 0.80 --top-k 20"

rem =========================================================
rem 4.5. GPU/CPU 오프로딩 프로필
rem =========================================================
echo(
echo ============================================================
echo([ GPU/CPU 오프로딩 프로필 ])
echo( A. 자동 선택 [기본값]
echo(    - 128K 미만   : Full GPU [ngl 999]
echo(    - 128K~159K   : High VRAM [ngl 60]
echo(    - 160K~191K   : Balanced  [ngl 56]
echo(    - 192K 이상   : Text-only면 ngl 56, Vision이면 ngl 52
echo(
echo( 1. Full GPU      [ngl 999]
echo( 2. High VRAM     [ngl 60]
echo( 3. Balanced      [ngl 56]
echo( 4. Safe Hybrid   [ngl 48]
echo( 5. LongCtx Safe  [ngl 40]
echo( 6. Custom        [ngl 직접 입력]
echo ============================================================
set /p O_CHOICE="오프로딩 선택 (A/1-6, 기본값 A): "
if "%O_CHOICE%"=="" set "O_CHOICE=A"

if /I "%O_CHOICE%"=="A" (
    set "AUTO_OFFLOAD=1"
    set "OFFLOAD_MODE=Auto"
) else (
    set "AUTO_OFFLOAD=0"
)

if "%O_CHOICE%"=="1" (
    set "NGL=999"
    set "OFFLOAD_MODE=Full GPU"
)
if "%O_CHOICE%"=="2" (
    set "NGL=60"
    set "OFFLOAD_MODE=High VRAM"
)
if "%O_CHOICE%"=="3" (
    set "NGL=56"
    set "OFFLOAD_MODE=Balanced"
)
if "%O_CHOICE%"=="4" (
    set "NGL=48"
    set "OFFLOAD_MODE=Safe Hybrid"
)
if "%O_CHOICE%"=="5" (
    set "NGL=40"
    set "OFFLOAD_MODE=LongCtx Safe"
)
if "%O_CHOICE%"=="6" (
    set /p NGL="사용할 GPU layer 수 입력 (예: 56): "
    if "!NGL!"=="" set "NGL=56"
    set "OFFLOAD_MODE=Custom"
)
echo(

rem =========================================================
rem 5. 컨텍스트 프리셋
rem =========================================================
echo ============================================================
echo([ 안정형 - 실무 권장 ])
echo( 11.  16K Context   [B256  / UB128  / KV q6_K / MTP ON]
echo( 12.  32K Context   [B512  / UB256  / KV q6_K / MTP ON] - 권장
echo(
echo([ 표준형 - 에이전트 / LangGraph ])
echo( 21.  32K Context   [B512  / UB256  / KV q4_0 / MTP ON]
echo( 22.  48K Context   [B256  / UB128  / KV q4_0 / MTP ON / AMB 256]
echo(
echo([ 품질 우선 - 코딩 / 정밀 추론 ])
echo( 31.  16K Context   [KV q8_0 / MTP ON]
echo( 32.  32K Context   [KV q8_0 / MTP ON]
echo(
echo([ 속도 우선 - 프리필 가속 ])
echo( 41.  16K Context   [B2048 / UB1024 / KV q4_0 / MTP ON]
echo( 42.  32K Context   [B2048 / UB1024 / KV q4_0 / MTP ON]
echo(
echo([ 장문 실험형 - 속도 저하 감수 ])
echo( 61.  64K Context   [B256  / UB128  / KV q4_0 / AMB 256 / MTP ON]
echo( 62.  96K Context   [B256  / UB128  / KV q4_0 / AMB 128 / MTP OFF]
echo( 63. 110K Context   [B256  / UB128  / KV q4_0 / AMB 128 / MTP OFF]
echo( 64. 135K Context   [B128  / UB64   / KV q4_0 / AMB 128 / MTP OFF]
echo( 65. 160K Context   [B128  / UB64   / KV q4_0 / AMB 128 / MTP OFF]
echo( 66. 192K Context   [B64   / UB64   / KV q4_0 / AMB 128 / MTP OFF]
echo(
echo([ MTP OFF - 안정성 우선 ])
echo( 51.  32K Context   [B512  / UB256  / KV q4_0 / MTP OFF]
echo( 52.  64K Context   [B256  / UB128  / KV q4_0 / AMB 256 / MTP OFF]
echo(
echo( E. Exit
echo ============================================================
echo(
set /p CHOICE="옵션 번호 입력: "

if /I "%CHOICE%"=="E" goto :END

rem 기본값 초기화
set "CTX="
set "B=512"
set "UB=256"
set "CTK=q4_0"
set "CTV=q4_0"
set "MODE="
set "ATTN_FLAG="
set "USE_MTP=1"

rem 안정형
if "%CHOICE%"=="11" (
    set "CTX=16384"
    set "B=256"
    set "UB=128"
    set "CTK=q6_K"
    set "CTV=q6_K"
    set "ATTN_FLAG="
    set "MODE=16K-Safe-MTP"
    goto :RUN
)
if "%CHOICE%"=="12" (
    set "CTX=32768"
    set "B=512"
    set "UB=256"
    set "CTK=q6_K"
    set "CTV=q6_K"
    set "ATTN_FLAG="
    set "MODE=32K-Safe-MTP"
    goto :RUN
)

rem 표준형
if "%CHOICE%"=="21" (
    set "CTX=32768"
    set "B=512"
    set "UB=256"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG="
    set "MODE=32K-Agent-MTP"
    goto :RUN
)
if "%CHOICE%"=="22" (
    set "CTX=49152"
    set "B=256"
    set "UB=128"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG=-amb 256"
    set "MODE=48K-Agent-MTP"
    goto :RUN
)

rem 품질 우선
if "%CHOICE%"=="31" (
    set "CTX=16384"
    set "B=256"
    set "UB=128"
    set "CTK=q8_0"
    set "CTV=q8_0"
    set "ATTN_FLAG="
    set "MODE=16K-Quality-MTP"
    goto :RUN
)
if "%CHOICE%"=="32" (
    set "CTX=32768"
    set "B=512"
    set "UB=256"
    set "CTK=q8_0"
    set "CTV=q8_0"
    set "ATTN_FLAG="
    set "MODE=32K-Quality-MTP"
    goto :RUN
)

rem 속도 우선
if "%CHOICE%"=="41" (
    set "CTX=16384"
    set "B=2048"
    set "UB=1024"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG="
    set "MODE=16K-Speed-MTP"
    goto :RUN
)
if "%CHOICE%"=="42" (
    set "CTX=32768"
    set "B=2048"
    set "UB=1024"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG="
    set "MODE=32K-Speed-MTP"
    goto :RUN
)

rem MTP OFF
if "%CHOICE%"=="51" (
    set "CTX=32768"
    set "B=512"
    set "UB=256"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG="
    set "MODE=32K-NoMTP"
    set "USE_MTP=0"
    goto :RUN
)
if "%CHOICE%"=="52" (
    set "CTX=65536"
    set "B=256"
    set "UB=128"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG=-amb 256"
    set "MODE=64K-NoMTP"
    set "USE_MTP=0"
    goto :RUN
)

rem 장문 실험형
if "%CHOICE%"=="61" (
    set "CTX=65536"
    set "B=256"
    set "UB=128"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG=-amb 256"
    set "MODE=64K-Long-MTP"
    goto :RUN
)

if "%CHOICE%"=="62" (
    set "CTX=98304"
    set "B=256"
    set "UB=128"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG=-amb 128"
    set "MODE=96K-Long"
    set "USE_MTP=0"
    goto :RUN
)

if "%CHOICE%"=="63" (
    set "CTX=110000"
    set "B=256"
    set "UB=128"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG=-amb 128"
    set "MODE=110K-Long"
    set "USE_MTP=0"
    goto :RUN
)

if "%CHOICE%"=="64" (
    set "CTX=135000"
    set "B=128"
    set "UB=64"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG=-amb 128"
    set "MODE=135K-Extreme"
    set "USE_MTP=0"
    echo(
    echo([WARNING] 135K 컨텍스트는 속도가 크게 느려질 수 있습니다.
    echo(          프리필 완료까지 상당한 시간이 걸릴 수 있습니다.
    echo(
    set "CONFIRM="
    set /p CONFIRM="그래도 진행하시겠습니까? (Y/N, 기본값 N): "
    if not defined CONFIRM set "CONFIRM=N"
    if /I not "!CONFIRM!"=="Y" goto :END
    goto :RUN
)

if "%CHOICE%"=="65" (
    set "CTX=163840"
    set "B=128"
    set "UB=64"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG=-amb 128"
    set "MODE=160K-Long"
    set "USE_MTP=0"
    goto :RUN
)

if "%CHOICE%"=="66" (
    set "CTX=236608"
    set "B=512"
    set "UB=256"
    set "CTK=q4_0"
    set "CTV=q4_0"
    set "ATTN_FLAG=-amb 128"
    set "MODE=192K-Extreme"
    set "USE_MTP=0"
    echo(
    echo([WARNING] 192K 컨텍스트는 프리필 시간이 매우 길고 디코딩 속도도 크게 떨어집니다.
    echo(          시스템 RAM 32GB 이상, 가능하면 64GB 이상 권장.
    echo(
    set "CONFIRM="
    set /p CONFIRM="그래도 진행하시겠습니까? (Y/N, 기본값 N): "
    if not defined CONFIRM set "CONFIRM=N"
    if /I not "!CONFIRM!"=="Y" goto :END
    goto :RUN
)

echo(잘못된 선택입니다.
pause
goto :END

:RUN
if "%CTX%"=="" goto :END

rem MTP 적용 여부 결정
if "%USE_MTP%"=="0" set "MTP_FLAGS="

rem Auto offload: 컨텍스트가 길수록 GPU 레이어 수를 줄이되,
rem 현재 3080 16GB 로그 기준으로 192K에서도 48은 너무 보수적이라 상향
if "%AUTO_OFFLOAD%"=="1" (
    set "NGL=999"
    set "OFFLOAD_MODE=AUTO Full GPU"

    if %CTX% GEQ 131072 (
        set "NGL=60"
        set "OFFLOAD_MODE=AUTO High VRAM"
    )

    if %CTX% GEQ 163840 (
        set "NGL=56"
        set "OFFLOAD_MODE=AUTO Balanced"
    )

    if %CTX% GEQ 196608 (
        set "NGL=56"
        set "OFFLOAD_MODE=AUTO 192K Text"
        if /I "%V_CHOICE%"=="Y" (
            set "NGL=52"
            set "OFFLOAD_MODE=AUTO 192K Vision"
        )
    )
)

rem 장문 + 비전 조합 경고
if /I "%V_CHOICE%"=="Y" (
    if %CTX% GEQ 131072 (
        echo(
        echo([WARNING] 128K 이상 장문 컨텍스트에서 Vision ON은 VRAM 압박을 더 높일 수 있습니다.
        echo(          가능하면 텍스트 전용 모드를 권장합니다.
        echo(
    )
)

rem 이전 서버 종료
taskkill /F /IM llama-server.exe >nul 2>&1
timeout /t 1 /nobreak >nul

echo(
echo ============================================================
echo([ RUNNING: Ornstein3.6-27B-MTP-NSC-ACE-SABER ])
echo(Model      : IQ4_XS (~13GB)
echo(Vision     : %VISION_LABEL%
echo(Mode       : %MODE%
echo(CTX        : %CTX%
echo(Batch      : %B% / UB: %UB%
echo(KV Cache   : %CTK% / %CTV%
echo(Offload    : %OFFLOAD_MODE%
echo(GPU Layers : %NGL%
echo(Checkpoints: %CHECKPOINT_FLAGS%
echo(Attention  : %ATTN_FLAG%
echo(MTP        : %MTP_FLAGS%
echo(Reasoning  : deepseek
echo(Sampling   : %SAMPLING%
echo ============================================================
echo(

"%LLAMA%" ^
  -m "%MODEL%" ^
  %MMPROJ_FLAG% ^
  -c %CTX% ^
  -b %B% ^
  -ub %UB% ^
  -t %THREADS% ^
  -tb %THREADS_BATCH% ^
  -ngl %NGL% ^
  -fa on ^
  %ATTN_FLAG% ^
  -ctk %CTK% ^
  -ctv %CTV% ^
  -khad ^
  -vhad ^
  -np 1 ^
  -cram %CACHE_RAM% ^
  -cram-n-min 100 ^
  %CHECKPOINT_FLAGS% ^
  %MTP_FLAGS% ^
  %REASONING_FLAG% ^
  %SAMPLING% ^
  --jinja ^
  --peg ^
  --host %HOST% ^
  --port %PORT% ^
  %MMAP_FLAG%

pause

:END
exit /b 0