; Instalador .exe do agente (Inno Setup 6). Gerado por Agent\Gerar-Instalador.ps1 (nao compile na mao).
; Parametros recebidos do script: /DOrigem=<pasta do pacote> /DVersao=<x.y.z> /DSaida=<pasta de saida>
#ifndef Origem
  #error Compile pelo Gerar-Instalador.ps1
#endif

[Setup]
AppId=PresencaAgentePP
AppName=Agente de Presenca
AppVersion={#Versao}
AppPublisher=Presenca e Produtividade
DefaultDirName={autopf}\PresencaAgente
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=yes
DisableWelcomePage=no
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#Saida}
OutputBaseFilename=Instalar-Agente-PP-{#Versao}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Agente de Presenca
CloseApplications=no

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
; Tudo vai para a pasta temporaria: quem instala de fato e o Install-Agente.ps1 (mesma logica testada do pacote .zip).
Source: "{#Origem}\*"; DestDir: "{tmp}\agente"; Flags: ignoreversion recursesubdirs

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Atualizar-Agente.ps1"" -Desinstalar"; \
  Flags: runhidden waituntilterminated; RunOnceId: "RemoverAgentePP"

[UninstallDelete]
; garante que a pasta do programa (e sobras do atualizador) saiam por completo
Type: filesandordirs; Name: "{app}"
Type: filesandordirs; Name: "{app}.bak"
Type: filesandordirs; Name: "{app}.novo"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  Codigo: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    // se havia uma instalacao anterior feita por script, a entrada antiga sai (agora vale a do instalador)
    RegDeleteKeyIncludingSubkeys(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PresencaAgentePP');
    if (not Exec('powershell.exe',
         '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{tmp}\agente\Instalar-Pacote.ps1') + '" -SemRegistroDesinstalacao',
         '', SW_HIDE, ewWaitUntilTerminated, Codigo)) or (Codigo <> 0) then
      RaiseException('Não foi possível instalar o agente (código ' + IntToStr(Codigo) + '). Execute como administrador e tente de novo.');

    // Instalação com tela: abre uma janela mostrando o progresso do acesso remoto (RustDesk). Em instalação silenciosa
    // (/VERYSILENT) nada aparece, e as atualizações automáticas do agente também não mostram nada. Falha aqui não
    // desfaz a instalação do agente: o atualizador tenta de novo sozinho.
    if not WizardSilent then
      Exec('powershell.exe',
        '-NoProfile -ExecutionPolicy Bypass -Command "try { Import-Module ''' + ExpandConstant('{app}\Presenca.psm1') + ''' -Force; Show-RemotoInstalacao -PastaAgente ''' + ExpandConstant('{app}') + ''' } catch { Write-Host $_.Exception.Message; Start-Sleep 10 }"',
        '', SW_SHOW, ewWaitUntilTerminated, Codigo);
  end;
end;
