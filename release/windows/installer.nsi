; installer.nsi -- the WinMojo installer.
;
; What it is for: the zip is still the whole product -- unpack it anywhere
; and the first launcher run repoints it at itself -- but "download a zip,
; extract it, find griddle.cmd" is three decisions a person should not have
; to make. This wraps the same tree in the installer Windows users expect:
; pick a directory, get shortcuts, appear in Apps & Features, uninstall
; cleanly.
;
; Per-user by design, like install.ps1 before it: RequestExecutionLevel user
; means no elevation prompt and no admin, the default directory is under
; %LOCALAPPDATA%, and the uninstall entry lives in HKCU. The user can point
; it anywhere they can write -- a second drive, a memory stick -- because the
; tree relocates itself; the installer runs paths.cmd once at the end so the
; configuration is right before the first launch rather than after it.
;
; Built by create-release.ps1 -Installer, which passes:
;   /DRELEASE_DIR=<staged release tree>   what to package
;   /DREVISION=<git short hash>           shown in Apps & Features
;   /DOUTFILE=<output .exe>               where to write the installer

Unicode true
; /DQUICK builds with zlib for a fast test cycle; a real release takes the
; several extra minutes of solid LZMA for a much smaller download.
!ifdef QUICK
SetCompressor /SOLID zlib
!else
SetCompressor /SOLID lzma
SetCompressorDictSize 64
!endif

!ifndef RELEASE_DIR
  !error "pass /DRELEASE_DIR=<staged release tree>"
!endif
!ifndef REVISION
  !define REVISION "dev"
!endif
!ifndef OUTFILE
  !define OUTFILE "winmojo-setup-${REVISION}.exe"
!endif

Name "WinMojo"
OutFile "${OUTFILE}"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\WinMojo\app"
; A previous install's choice of directory wins over the default.
InstallDirRegKey HKCU "Software\WinMojo" "InstallDir"

!include "MUI2.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "WinMojo"
!define MUI_WELCOMEPAGE_TEXT "Mojo for Windows x64: the compiler, the Griddle IDE, a Python runtime, the examples and the guide.$\r$\n$\r$\nEverything installs into one directory of your choice. Nothing needs administrator rights, nothing goes into system directories, and uninstalling removes exactly what installing created."
!define MUI_FINISHPAGE_RUN "$INSTDIR\bin\griddle.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Start Griddle"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README.md"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Open the README"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${RELEASE_DIR}\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; ---- what gets installed --------------------------------------------------

Section "Toolchain and IDE" SecCore
  SectionIn RO  ; a release without the compiler is not one
  SetOutPath "$INSTDIR"
  File "${RELEASE_DIR}\LICENSE"
  File "${RELEASE_DIR}\README.md"
  File "${RELEASE_DIR}\modular.cfg.in"
  File "${RELEASE_DIR}\modular.cfg"
  File "${RELEASE_DIR}\modular.cfg.root"
  File "${RELEASE_DIR}\BUILD-REVISION.txt"
  File "${RELEASE_DIR}\SHA256SUMS.txt"
  File "${RELEASE_DIR}\paths.cmd"
  File "${RELEASE_DIR}\install.ps1"
  File "${RELEASE_DIR}\griddle.cmd"
  File "${RELEASE_DIR}\mojo.cmd"
  File "${RELEASE_DIR}\vsenv.cmd"
  File "${RELEASE_DIR}\mojo-shell.cmd"
  File "${RELEASE_DIR}\mojo-gpu-run.cmd"
  File "${RELEASE_DIR}\mojo-gpu-build.cmd"
  File "${RELEASE_DIR}\mandelbrot.cmd"
  SetOutPath "$INSTDIR\bin"
  File /r "${RELEASE_DIR}\bin\*.*"
  SetOutPath "$INSTDIR\lib"
  File /r "${RELEASE_DIR}\lib\*.*"
  SetOutPath "$INSTDIR\Licenses"
  File /nonfatal /r "${RELEASE_DIR}\Licenses\*.*"
  ; hello.mojo ships even when the examples do not: the getting-started
  ; chapter's first build must exist on every install.
  SetOutPath "$INSTDIR\examples"
  File "${RELEASE_DIR}\examples\hello.mojo"
  ; The working directories the toolchain expects to find.
  CreateDirectory "$INSTDIR\cache"
  CreateDirectory "$INSTDIR\crashdb"

  ; Point the configuration at wherever the user chose, now, so the first
  ; launch -- from the finish page, a shortcut, or the exe directly -- finds
  ; paths that are already right. griddle.exe would heal them itself, but a
  ; plain `mojo build` from mojo-shell.cmd deserves the same head start.
  nsExec::ExecToLog 'cmd /c call "$INSTDIR\paths.cmd"'
  Pop $0

  ; Apps & Features, per user.
  WriteRegStr HKCU "Software\WinMojo" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "DisplayName" "WinMojo (Mojo for Windows x64)"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "DisplayVersion" "${REVISION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "Publisher" "WINMOJOX64Blackwell (unofficial fork)"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "DisplayIcon" "$INSTDIR\bin\griddle.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo" "EstimatedSize" "$0"
SectionEnd

Section "Python runtime" SecPython
  ; The standalone CPython Griddle's Python menu and the compiler's Python
  ; interop use. Without it, both depend on what the machine happens to
  ; have -- usually the Microsoft Store stub, which is not a Python.
  SetOutPath "$INSTDIR\python"
  File /r "${RELEASE_DIR}\python\*.*"
SectionEnd

Section "Examples" SecExamples
  ; The curated Windows examples the IDE's Examples menu opens as projects.
  SetOutPath "$INSTDIR\examples"
  File /r "${RELEASE_DIR}\examples\*.*"
SectionEnd

Section "Programmer's Guide" SecGuide
  SetOutPath "$INSTDIR\WinMojoGuide"
  File /r "${RELEASE_DIR}\WinMojoGuide\*.*"
SectionEnd

Section "Start Menu shortcuts" SecStartMenu
  ; To the exe, not the .cmd: griddle.exe repoints the configuration and the
  ; environment itself at startup, and an exe shortcut does not flash a
  ; console window.
  CreateDirectory "$SMPROGRAMS\WinMojo"
  CreateShortCut "$SMPROGRAMS\WinMojo\Griddle.lnk" "$INSTDIR\bin\griddle.exe" "" "$INSTDIR\bin\griddle.exe" 0 SW_SHOWNORMAL "" "The Mojo IDE"
  CreateShortCut "$SMPROGRAMS\WinMojo\Mojo shell.lnk" "$INSTDIR\mojo-shell.cmd" "" "" 0 SW_SHOWNORMAL "" "A console with the toolchain on PATH"
  CreateShortCut "$SMPROGRAMS\WinMojo\Uninstall WinMojo.lnk" "$INSTDIR\uninstall.exe"
SectionEnd

Section /o "Desktop shortcut" SecDesktop
  CreateShortCut "$DESKTOP\Griddle.lnk" "$INSTDIR\bin\griddle.exe" "" "$INSTDIR\bin\griddle.exe" 0 SW_SHOWNORMAL "" "The Mojo IDE"
SectionEnd

; ---- component descriptions ----------------------------------------------

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecCore} "The Mojo compiler, the Griddle IDE, the language server, the debugger, the standard library and the Win32 metadata. Required."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecPython} "A relocatable CPython used by Python interop and the IDE's Python menu. Without it, Python features need a suitable Python already on this machine."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecExamples} "The Windows example projects the IDE's Examples menu opens: windows, sound, GPU work, games."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecGuide} "The programmer's guide and reference, as Markdown."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecStartMenu} "Griddle, a toolchain shell, and the uninstaller in the Start Menu."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "Griddle on the desktop."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---- uninstall ------------------------------------------------------------

Section "Uninstall"
  ; Everything the installer created lives under $INSTDIR, and projects the
  ; user made live wherever the user made them -- the IDE never writes them
  ; here. So removal is the directory, the shortcuts and the two registry
  ; keys, and nothing else.
  ;
  ; The sentinel first: $INSTDIR is wherever the user pointed the installer,
  ; and deleting a directory recursively on the strength of a registry entry
  ; alone is how uninstallers make the news. No template, no deletion.
  IfFileExists "$INSTDIR\modular.cfg.in" +3 0
    MessageBox MB_OK|MB_ICONSTOP "This does not look like a WinMojo installation (no modular.cfg.in in $INSTDIR); nothing was removed." /SD IDOK
    Abort
  RMDir /r "$INSTDIR"
  Delete "$SMPROGRAMS\WinMojo\Griddle.lnk"
  Delete "$SMPROGRAMS\WinMojo\Mojo shell.lnk"
  Delete "$SMPROGRAMS\WinMojo\Uninstall WinMojo.lnk"
  RMDir "$SMPROGRAMS\WinMojo"
  Delete "$DESKTOP\Griddle.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\WinMojo"
  DeleteRegKey HKCU "Software\WinMojo"
SectionEnd
