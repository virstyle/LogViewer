{
  Copyright (C) 2013-2017 Tim Sinaeve tim.sinaeve@gmail.com

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
}

unit LogViewer.MainForm;

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Variants, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ComCtrls,

  LogViewer.Messages.View, LogViewer.Interfaces, LogViewer.Receivers.WinIPC,
  LogViewer.Receivers.WinODS,
  LogViewer.Factories, LogViewer.Manager, LogViewer.Settings;

type
  TfrmMain = class(TForm)
    pgcMain  : TPageControl;
    tsIPC    : TTabSheet;
    tsODS    : TTabSheet;
    tsZeroMQ : TTabSheet;
    sbrMain: TStatusBar;
  private
    FMessageViewerIPC : TfrmMessagesView;
    FReceiverIPC      : IChannelReceiver;
    FMessageViewerODS : TfrmMessagesView;
    FReceiverODS      : IChannelReceiver;
    FManager          : TdmManager;
    FSettings         : TLogViewerSettings;
    FMainToolbar      : TToolBar;
    function GetActions: ILogViewerActions;
    function GetMenus: ILogViewerMenus;
    function GetManager: ILogViewerManager;

  public
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;


    property Manager: ILogViewerManager
      read GetManager;

    property Actions: ILogViewerActions
      read GetActions;

    { Menu components to use in the user interface. }
    property Menus: ILogViewerMenus
      read GetMenus;
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

{$REGION 'construction and destruction'}
procedure TfrmMain.AfterConstruction;
begin
  inherited AfterConstruction;
  FSettings := TLogViewerSettings.Create;
  FReceiverIPC := TWinIPChannelReceiver.Create;
  FReceiverODS := TWinODSReceiver.Create;

  FManager := TLogViewerFactories.CreateManager(Self);
  FMessageViewerIPC := TLogViewerFactories.CreateMessageView(
    Self,
    tsIPC,
    FReceiverIPC
  );
  FMessageViewerODS := TLogViewerFactories.CreateMessageView(
    Self,
    tsODS,
    FReceiverODS
  );
  FMainToolbar := TLogViewerFactories.CreateMainToolbar(
    Self,
    Self,
    Actions,
    Menus
  );

  FReceiverIPC.Enabled := True;
  FReceiverODS.Enabled := False;

end;

procedure TfrmMain.BeforeDestruction;
begin
  FSettings.Free;
  inherited BeforeDestruction;
end;
{$ENDREGION}

{$REGION 'property access methods'}
function TfrmMain.GetActions: ILogViewerActions;
begin
  Result := Manager.Actions;
end;

function TfrmMain.GetManager: ILogViewerManager;
begin
  Result := FManager as ILogViewerManager;
end;

function TfrmMain.GetMenus: ILogViewerMenus;
begin
  Result := Manager.Menus;
end;
{$ENDREGION}

end.
