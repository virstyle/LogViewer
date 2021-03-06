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

unit LogViewer.Receivers.WinODS;

{ Receives messages posted by the OutputDebugString Windows API routine. The
  OutputDebugString messages are fetched in a thread and queued as TLogMessage
  compatible stream.  }

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.Classes, System.SysUtils,

  LogViewer.Interfaces,

  Spring, Spring.Collections;

type
  TProcessInfo = packed record
    ProcessId   : Integer;
    ProcessName : UTF8String;
  end;

  TODSMessage = class
    Id          : Cardinal;
    TimeStamp   : TDateTime;
    MsgText     : AnsiString; // ODS messages are always AnsiStrings.
    ProcessInfo : TProcessInfo;
  end;

  { Thread instance that captures OutputDebugString content }

  TODSThread = class(TThread)
  private
    FODSQueue         : IQueue<TODSMessage>;
    FCloseEventHandle : THandle;

  protected
    procedure Execute; override;

  public
    constructor Create(AODSQueue: IQueue<TODSMessage>);
  end;

type
  TWinODSChannelReceiver = class(TInterfacedObject, IChannelReceiver)
  private class var
    FCounter : Integer;
  private
    FEnabled          : Boolean;
    FBuffer           : TMemoryStream;
    FODSQueue         : IQueue<TODSMessage>;
    FODSThread        : TODSThread;
    FOnReceiveMessage : Event<TReceiveMessageEvent>;
    FName             : string;

  protected
    function GetName: string;
    procedure SetName(const Value: string);
    function GetEnabled: Boolean;
    procedure SetEnabled(const Value: Boolean);
    function GetOnReceiveMessage: IEvent<TReceiveMessageEvent>;

    procedure FODSQueueChanged(
      Sender     : TObject;
      const Item : TODSMessage;
      Action     : TCollectionChangedAction
    );

  public
    constructor Create(const AName: string); reintroduce;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;

    property Enabled: Boolean
      read GetEnabled write SetEnabled;

    property Name: string
      read GetName write SetName;

    property OnReceiveMessage: IEvent<TReceiveMessageEvent>
      read GetOnReceiveMessage;
  end;

implementation

uses
  Winapi.PsAPI, Winapi.TlHelp32,
  System.SyncObjs, System.DateUtils;

var
  LastChildOrder : Cardinal;

{$REGION 'interfaced routines'}
function GetExenameForProcessUsingPSAPI(AProcessID: DWORD): string;
var
  I          : DWORD;
  cbNeeded   : DWORD;
  Modules    : array [1 .. 1024] of HINST;
  ProcHandle : THandle;
  FileName   : array [0 .. 512] of Char;
begin
  SetLastError(0);
  Result     := '';
  ProcHandle := OpenProcess(
    PROCESS_QUERY_INFORMATION or PROCESS_VM_READ,
    False,
    AProcessID
  );
  if ProcHandle <> 0 then
  begin
    try
      if EnumProcessModules(ProcHandle, @Modules[1], SizeOf(Modules), cbNeeded)
      then
        for I := 1 to cbNeeded div SizeOf(HINST) do
        begin
          if GetModuleFilenameEx(ProcHandle, Modules[I], FileName,
            SizeOf(FileName)) > 0 then
          begin
            if CompareText(ExtractFileExt(FileName), '.EXE') = 0 then
            begin
              Result := FileName;
              Break;
            end;
          end;
        end;
    finally
      CloseHandle(ProcHandle);
    end;
  end;
end;

function GetExenameForProcessUsingToolhelp32(AProcessID: DWORD): string;
var
  Snapshot  : THandle;
  ProcEntry : TProcessEntry32;
  Ret       : BOOL;
begin
  SetLastError(0);
  Result   := '';
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot <> INVALID_HANDLE_VALUE then
    try
      ProcEntry.dwSize := SizeOf(ProcEntry);
      Ret              := Process32First(Snapshot, ProcEntry);
      while Ret do
      begin
        if ProcEntry.th32ProcessID = AProcessID then
        begin
          Result := ProcEntry.szExeFile;
          Break;
        end
        else
          Ret := Process32Next(Snapshot, ProcEntry);
      end;
    finally
      CloseHandle(Snapshot);
    end;
end;

function GetExenameForProcess(AProcessID: DWORD): string;
begin
  if (Win32Platform = VER_PLATFORM_WIN32_NT) and (Win32MajorVersion <= 4) then
    Result := GetExenameForProcessUsingPSAPI(AProcessID)
  else
    Result := GetExenameForProcessUsingToolhelp32(AProcessID);
  Result := ExtractFileName(Result)
end;

function GetExenameForWindow(AWndHandle: HWND): string;
var
  ProcessID: DWORD;
begin
  Result := '';
  if IsWindow(AWndHandle) then
  begin
    GetWindowThreadProcessID(AWndHandle, ProcessID);
    if ProcessID <> 0 then
      Result := GetExenameForProcess(ProcessID);
  end;
end;
{$ENDREGION}

{$REGION 'construction and destruction'}
constructor TWinODSChannelReceiver.Create(const AName: string);
begin
  inherited Create;
  if AName = '' then
  begin
    FName := Copy(ClassName, 2, Length(ClassName)) + IntToStr(FCounter);
  end
  else
    FName := AName;
end;

procedure TWinODSChannelReceiver.AfterConstruction;
begin
  inherited AfterConstruction;
  Inc(FCounter);
  FBuffer := TMemoryStream.Create;
  FODSQueue := TCollections.CreateQueue<TODSMessage>;
  FODSQueue.OnChanged.Add(FODSQueueChanged);
  FODSThread := TODSThread.Create(FODSQueue);
end;

procedure TWinODSChannelReceiver.BeforeDestruction;
begin
  FODSThread.Terminate;
  FBuffer.Free;
  FODSThread.Free;
  inherited BeforeDestruction;
end;
{$ENDREGION}

{$REGION 'event handlers'}
procedure TWinODSChannelReceiver.FODSQueueChanged(Sender: TObject;
  const Item: TODSMessage; Action: TCollectionChangedAction);
const
  ZeroBuf : Integer = 0;
var
  TextSize : Integer;
  MsgType  : Integer;
  DataSize : Integer;
begin
  if Action = caAdded then
  begin
    if OnReceiveMessage.CanInvoke then
    begin
      FBuffer.Clear;
      TextSize := Length(Item.MsgText);

      //lmtValue
      //MsgType := 0;
      MsgType := 3;
      FBuffer.Seek(0, soFromBeginning);
      FBuffer.WriteBuffer(MsgType, SizeOf(Integer));
      FBuffer.WriteBuffer(Item.TimeStamp, SizeOf(TDateTime));
      FBuffer.WriteBuffer(TextSize, SizeOf(Integer));
      FBuffer.WriteBuffer(Item.MsgText[1], TextSize);

//      DataSize := SizeOf(Item.ProcessInfo);
//      FBuffer.WriteBuffer(DataSize, SizeOf(Integer));
//      FBuffer.WriteBuffer(Item.ProcessInfo, DataSize);

      //FBuffer.WriteBuffer(Item.MsgText[1], TextSize);
      FBuffer.WriteBuffer(ZeroBuf, SizeOf(Integer));
      //FBuffer.WriteBuffer(ZeroBuf, SizeOf(Integer));
//      TextSize := Length(Item.ProcessName);
//      FBuffer.WriteBuffer(TextSize, SizeOf(Integer));
//      FBuffer.WriteBuffer(Item.ProcessName[1], TextSize);
      OnReceiveMessage.Invoke(Self, FBuffer);
    end
  end;
end;
{$ENDREGION}

{$REGION 'property access methods'}
function TWinODSChannelReceiver.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

function TWinODSChannelReceiver.GetName: string;
begin
  Result := FName;
end;

procedure TWinODSChannelReceiver.SetName(const Value: string);
begin
  FName := Value;
end;

procedure TWinODSChannelReceiver.SetEnabled(const Value: Boolean);
begin
  if Value <> Enabled then
  begin
    FEnabled := Value;
  end;
end;

function TWinODSChannelReceiver.GetOnReceiveMessage: IEvent<TReceiveMessageEvent>;
begin
  Result := FOnReceiveMessage;
end;
{$ENDREGION}

{$REGION 'TODSThread'}
{$REGION 'construction and destruction'}
constructor TODSThread.Create(AODSQueue: IQueue<TODSMessage>);
begin
  inherited Create;
  FODSQueue := AODSQueue;
  FCloseEventHandle := CreateEvent(nil, True, False, nil);
end;
{$ENDREGION}

{$REGION 'protected methods'}
procedure TODSThread.Execute;
var
  AckEvent         : THandle;
  ReadyEvent       : THandle;
  SharedFile       : THandle;
  SharedMem        : Pointer;
  ReturnCode       : DWORD;
  ODSMessage       : TODSMessage;
  HandlesToWaitFor : array [0 .. 1] of THandle;
  SA               : SECURITY_ATTRIBUTES;
  SD               : SECURITY_DESCRIPTOR;
begin
  SA.nLength              := SizeOf(SECURITY_ATTRIBUTES);
  SA.bInheritHandle       := TRUE;
  SA.lpSecurityDescriptor := @SD;

  if not InitializeSecurityDescriptor(@SD, SECURITY_DESCRIPTOR_REVISION) then
    Exit;

  if not SetSecurityDescriptorDacl(@SD, TRUE, nil { (PACL)NULL } , False) then
    Exit;

  AckEvent := CreateEvent(@SA, False, TRUE, 'DBWIN_BUFFER_READY');
  if AckEvent = 0 then
    Exit;

  ReadyEvent := CreateEvent(@SA, False, False, 'DBWIN_DATA_READY');
  if ReadyEvent = 0 then
    Exit;

  SharedFile := CreateFileMapping(
    THandle(-1),
    @SA,
    PAGE_READWRITE,
    0,
    4096,
    'DBWIN_BUFFER'
  );
  if SharedFile = 0 then
    Exit;

  SharedMem := MapViewOfFile(SharedFile, FILE_MAP_READ, 0, 0, 512);
  if not Assigned(SharedMem) then
    Exit;

  while not Terminated do
  begin
    HandlesToWaitFor[0] := FCloseEventHandle;
    HandlesToWaitFor[1] := ReadyEvent;

    SetEvent(AckEvent);
    ReturnCode := WaitForMultipleObjects(
      2,
      @HandlesToWaitFor,
      False { bWaitAll } ,
      3000 { INFINITE }
    );

    case ReturnCode of
      WAIT_TIMEOUT :
        Continue;

      WAIT_OBJECT_0 :
        begin
          Break;
        end;
      WAIT_OBJECT_0 + 1 :
        begin
          ODSMessage             := TODSMessage.Create;
          ODSMessage.TimeStamp   := Now;
          ODSMessage.ProcessInfo.ProcessId   := LPDWORD(SharedMem)^;
          ODSMessage.ProcessInfo.ProcessName := UTF8String(GetExenameForProcess(ODSMessage.ProcessInfo.ProcessId));
           //'$' + inttohex (pThisPid^,2)
          ODSMessage.MsgText := AnsiString(PAnsiChar(SharedMem) + SizeOf(DWORD));
          // the native version of OutputDebugString is ASCII. result is always AnsiString
          ODSMessage.Id := LastChildOrder;
          Inc(LastChildOrder);
          Queue(procedure
            begin
              FODSQueue.Enqueue(ODSMessage);
            end
          );
        end;
      WAIT_FAILED:
        Continue;
    end;
  end;
  UnmapViewOfFile(SharedMem);
  CloseHandle(SharedFile);
end;
{$ENDREGION}
{$ENDREGION}

end.
