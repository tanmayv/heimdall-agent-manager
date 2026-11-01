; REQ-ENR-4: the Windows installer installs the Heimdall App or the Bridge.
; There is no combined "App and Bridge" choice on Windows: the App sets up a
; Bridge for this computer from Settings > Bridges (the same ham-bridge setup,
; with in-app progress and retry), so the installer does not run Bridge setup
; for an App install. macOS (.pkg) and Linux (first launch) keep their choices.
;
; electron-builder includes this file in the installer and the uninstaller build
; (BUILD_UNINSTALLER). Its NSIS runs with -WX, so everything only the installer
; uses stays behind !ifndef BUILD_UNINSTALLER, and pages/functions are defined
; inside the hook macros, where MUI2 is already included.
;
; The Bridge component runs the bundled bootstrap (resources\bridge\install.ps1),
; which verifies the bundled archive against SHA256SUMS and execs
; `ham-bridge setup` without --headless, so ham-bridge opens the approval page.
; "Bridge only" then removes the app files again: ham-bridge setup has copied
; what the Bridge needs into its own profile, and the Bridge's tray owns its
; uninstall (REQ-ENR-6).
;
; The Bridge is a per-user service, so setup must run as the signed-in user.
; When the user picks "Anyone who uses this computer", the sections run in the
; elevated inner UAC instance (possibly as another account that supplied admin
; credentials); there, setup is handed back to the outer, non-elevated instance
; with UAC_AsUser_Call, the way electron-builder starts the app as the user.
;
; Silent installs: /COMPONENTS=app|bridge (default app, so an unattended
; install never waits on a browser approval) and /HUB=<url>. The former
; /COMPONENTS=both is refused with a message naming the supported values.
; App auto-updates (--updated) skip the page and never touch the Bridge; it
; updates itself (ham-bridge update).

!ifndef BUILD_UNINSTALLER
  !include LogicLib.nsh
  !include FileFunc.nsh
  !include nsDialogs.nsh

  Var HeimdallComponents
  Var HeimdallHub
  Var HeimdallRadioApp
  Var HeimdallRadioBridge

  !define HEIMDALL_DEFAULT_HUB "https://hub.brolabs.ai"
!endif

!macro customInit
  StrCpy $HeimdallComponents "app"
  StrCpy $HeimdallHub "${HEIMDALL_DEFAULT_HUB}"
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/COMPONENTS=" $R1
  ${IfNot} ${Errors}
    ${If} $R1 == "app"
    ${OrIf} $R1 == "bridge"
      StrCpy $HeimdallComponents $R1
    ${Else}
      MessageBox MB_ICONSTOP|MB_OK "/COMPONENTS must be app or bridge (got $R1). To use both, install the app and set up the Bridge from Settings > Bridges." /SD IDOK
      SetErrorLevel 2
      Quit
    ${EndIf}
  ${EndIf}
  ClearErrors
  ${GetOptions} $R0 "/HUB=" $R1
  ${IfNot} ${Errors}
  ${AndIf} $R1 != ""
    StrCpy $HeimdallHub $R1
  ${EndIf}
!macroend

!macro customPageAfterChangeDir
  Page custom HeimdallComponentsPage HeimdallComponentsLeave

  Function HeimdallComponentsPage
    ; An update keeps whatever was installed; there is nothing to choose.
    ${If} ${isUpdated}
      Abort
    ${EndIf}
    !insertmacro MUI_HEADER_TEXT "Choose what to install" "Install the Ninjy app or the Ninjy Bridge."
    nsDialogs::Create 1018
    Pop $0
    ${If} $0 == error
      Abort
    ${EndIf}
    ${NSD_CreateLabel} 0 0 100% 48u "The App is the Ninjy desktop window. To let agents run on this computer too, install the App and connect this computer from Settings > Bridges in the app. The Bridge alone connects this computer to your Ninjy Hub without the desktop window; setting it up opens your browser to approve this computer."
    Pop $0
    ${NSD_CreateRadioButton} 0 54u 100% 12u "App (recommended)"
    Pop $HeimdallRadioApp
    ${NSD_CreateRadioButton} 0 70u 100% 12u "Bridge only"
    Pop $HeimdallRadioBridge
    ${If} $HeimdallComponents == "bridge"
      ${NSD_Check} $HeimdallRadioBridge
    ${Else}
      ${NSD_Check} $HeimdallRadioApp
    ${EndIf}
    nsDialogs::Show
  FunctionEnd

  Function HeimdallComponentsLeave
    ${NSD_GetState} $HeimdallRadioBridge $0
    ${If} $0 == ${BST_CHECKED}
      StrCpy $HeimdallComponents "bridge"
    ${Else}
      StrCpy $HeimdallComponents "app"
    ${EndIf}
  FunctionEnd

  ; Runs in the outer, non-elevated installer instance (UAC_AsUser_Call from the
  ; elevated inner one). In: $1 = hub URL, $INSTDIR synced. Out: $0 = exit code.
  ; The outer instance has no log window, so setup runs in its own console.
  Function HeimdallBridgeSetupAsUser
    ClearErrors
    ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\resources\bridge\install.ps1" -Bundle "$INSTDIR\resources\bridge\heimdall-local-windows-amd64.zip" -ChecksumFile "$INSTDIR\resources\bridge\SHA256SUMS" -Hub "$1" -Interactive' $0
    ${If} ${Errors}
      StrCpy $0 "error"
    ${EndIf}
  FunctionEnd
!macroend

; Same as electron-builder's default finish page, except that "Run Heimdall" is
; hidden and skipped when only the Bridge was installed (there is no app).
!macro customFinishPage
  !define MUI_FINISHPAGE_RUN
  !define MUI_FINISHPAGE_RUN_FUNCTION "HeimdallStartApp"
  !define MUI_PAGE_CUSTOMFUNCTION_SHOW HeimdallFinishShow
  !insertmacro MUI_PAGE_FINISH

  ; After MUI_PAGE_FINISH, which declares $mui.FinishPage.Run. Mirrors
  ; electron-builder's own finish-page StartApp function: its StartApp macro
  ; declares Var /GLOBAL startAppArgs and installSection.nsh already inserts it
  ; (doStartApp), so inserting it here too fails makensis with
  ; 'variable "startAppArgs" already declared'.
  Function HeimdallStartApp
    ${If} $HeimdallComponents != "bridge"
      ${If} ${isUpdated}
        StrCpy $1 "--updated"
      ${Else}
        StrCpy $1 ""
      ${EndIf}
      ${StdUtils.ExecShellAsUser} $0 "$launchLink" "open" "$1"
    ${EndIf}
  FunctionEnd

  Function HeimdallFinishShow
    ${If} $HeimdallComponents == "bridge"
      ShowWindow $mui.FinishPage.Run ${SW_HIDE}
    ${EndIf}
  FunctionEnd
!macroend

!macro customInstall
  ${IfNot} ${isUpdated}
  ${AndIf} $HeimdallComponents == "bridge"
    DetailPrint "Setting up the Ninjy Bridge for $HeimdallHub (approve this computer in your browser)..."
    SetDetailsPrint both
    ${If} ${UAC_IsInnerInstance}
      ; Elevated per-machine install: never set the Bridge up as the admin.
      DetailPrint "Running Bridge setup as the signed-in user in a separate window..."
      Push $1
      StrCpy $1 $HeimdallHub
      StrCpy $0 "not run"
      !insertmacro UAC_AsUser_Call Function HeimdallBridgeSetupAsUser ${UAC_SYNCREGISTERS}|${UAC_SYNCINSTDIR}
      Pop $1
    ${Else}
      nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\resources\bridge\install.ps1" -Bundle "$INSTDIR\resources\bridge\heimdall-local-windows-amd64.zip" -ChecksumFile "$INSTDIR\resources\bridge\SHA256SUMS" -Hub "$HeimdallHub" -Interactive'
      Pop $0
    ${EndIf}
    ${If} $0 != 0
      ; Nothing usable was installed: leave no app behind and fail the install.
      ExecWait '"$INSTDIR\${UNINSTALL_FILENAME}" /S _?=$INSTDIR'
      Delete "$INSTDIR\${UNINSTALL_FILENAME}"
      RMDir /r "$INSTDIR"
      MessageBox MB_ICONSTOP|MB_OK "Ninjy Bridge setup failed (exit code $0); nothing was installed. Run the installer again, or install the App and set up the Bridge from Settings > Bridges." /SD IDOK
      SetErrorLevel 2
      Quit
    ${Else}
      DetailPrint "Bridge only: removing the Ninjy app files."
      ExecWait '"$INSTDIR\${UNINSTALL_FILENAME}" /S _?=$INSTDIR'
      Delete "$INSTDIR\${UNINSTALL_FILENAME}"
      RMDir /r "$INSTDIR"
    ${EndIf}
  ${EndIf}
!macroend
