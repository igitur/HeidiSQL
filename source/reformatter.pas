unit reformatter;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Variants, Classes, Math, Graphics, fpjson, jsonparser,
  Controls, Forms, Dialogs, StdCtrls, ExtCtrls, fphttpclient, Process,
  apphelpers, extra_controls, dbconnection, dbstructures, dbstructures.mysql;

type
  { Available SQL formatters. The ordinal values are only used for the order of the
    radio group and the combo box - persisted settings use TReformatterKindToId, so
    reordering or inserting an entry can never change what a stored value means. }
  TReformatterKind = (rkInternal, rkHeidiSQLOnline, rkSqlFormatOrg, rkExternal);

const
  ReformatterKindIds: array[TReformatterKind] of String =
    ('internal', 'heidisql', 'sqlformat', 'external');

function ReformatterKindToId(Kind: TReformatterKind): String;
function ReformatterKindById(Id: String): TReformatterKind;
function ReformatterKindByIndex(Index: Integer): TReformatterKind;
function ReformatterCaption(Kind: TReformatterKind): String;
function ReformatterKindStored: TReformatterKind;
procedure StoreReformatterKind(Kind: TReformatterKind);
function ReformatterAskStored: Boolean;
procedure StoreReformatterAsk(Value: Boolean);
function ReformatterExternalCommandStored: String;
procedure StoreReformatterExternalCommand(Value: String);

type
  TfrmReformatter = class(TExtForm)
    grpReformatter: TRadioGroup;
    btnCancel: TButton;
    btnOk: TButton;
    lblFormatProviderLink: TLabel;
    chkKeepAsking: TCheckBox;
    lblCommandLine: TLabel;
    edtCommandLine: TEdit;
    btnCommandLineBrowse: TButton;
    procedure btnOkClick(Sender: TObject);
    procedure btnCommandLineBrowseClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure grpReformatterClick(Sender: TObject);
    procedure lblFormatProviderLinkClick(Sender: TObject);
  private
    { Private declarations }
    FInputCode, FOutputCode: String;
    procedure UpdateCommandLineControls;
  public
    { Public declarations }
    function FormatSqlInternal(SQL: String): String;
    function FormatSqlOnlineHeidisql(SQL: String): String;
    function FormatSqlOnlineSqlformatOrg(SQL: String): String;
    function FormatSqlExternal(SQL: String): String;
    function SelectedKind: TReformatterKind;
    function AskBeforeFormatting: Boolean;
    function ExecuteFormatter: Boolean;
    property InputCode: String read FInputCode write FInputCode;
    property OutputCode: String read FOutputCode;
  end;

var
  frmReformatter: TfrmReformatter;

implementation

uses main;

{$R *.lfm}


function ReformatterKindToId(Kind: TReformatterKind): String;
begin
  Result := ReformatterKindIds[Kind];
end;


function ReformatterKindById(Id: String): TReformatterKind;
var
  Kind: TReformatterKind;
begin
  for Kind := Low(TReformatterKind) to High(TReformatterKind) do begin
    if SameText(ReformatterKindIds[Kind], Id) then begin
      Result := Kind;
      Exit;
    end;
  end;
  // An id written by a newer version, or a corrupted value. Fall back to the
  // built-in formatter instead of guessing what was meant.
  Result := rkInternal;
end;


function ReformatterKindByIndex(Index: Integer): TReformatterKind;
begin
  if (Index >= Ord(Low(TReformatterKind))) and (Index <= Ord(High(TReformatterKind))) then
    Result := TReformatterKind(Index)
  else
    Result := rkInternal;
end;


function ReformatterCaption(Kind: TReformatterKind): String;
begin
  Result := '';
  case Kind of
    rkInternal: Result := _('Internal');
    rkHeidiSQLOnline: Result := f_('Online on %s', [APPDOMAIN]);
    rkSqlFormatOrg: Result := f_('Online on %s', ['sqlformat.org']);
    rkExternal: Result := _('External command line tool');
  end;
end;


procedure MigrateReformatterSettings;
var
  LegacyChoice: Integer;
begin
  if AppSettings.ValueExists(asReformatterId) then
    Exit;
  // Older builds stored the choice as an index into the formatter list, and did so
  // twice: "Reformatter" (last used in the dialog) and "ReformatterNoDialog"
  // (0 = always ask, n = formatter n-1). Convert the pair once, and leave the old
  // values untouched, so a downgrade still finds a usable index.
  LegacyChoice := AppSettings.ReadInt(asReformatterNoDialog);
  if LegacyChoice > 0 then begin
    StoreReformatterKind(ReformatterKindByIndex(LegacyChoice - 1));
    StoreReformatterAsk(False);
  end else begin
    StoreReformatterKind(ReformatterKindByIndex(AppSettings.ReadInt(asReformatter)));
    StoreReformatterAsk(True);
  end;
end;


function ReformatterKindStored: TReformatterKind;
begin
  MigrateReformatterSettings;
  Result := ReformatterKindById(AppSettings.ReadString(asReformatterId));
end;


procedure StoreReformatterKind(Kind: TReformatterKind);
begin
  AppSettings.WriteString(asReformatterId, ReformatterKindToId(Kind));
end;


function ReformatterAskStored: Boolean;
begin
  MigrateReformatterSettings;
  Result := AppSettings.ReadBool(asReformatterAsk);
end;


procedure StoreReformatterAsk(Value: Boolean);
begin
  AppSettings.WriteBool(asReformatterAsk, Value);
end;


function ReformatterExternalCommandStored: String;
begin
  Result := AppSettings.ReadString(asReformatterExternalCommand);
end;


procedure StoreReformatterExternalCommand(Value: String);
begin
  AppSettings.WriteString(asReformatterExternalCommand, Value);
end;


function TfrmReformatter.SelectedKind: TReformatterKind;
begin
  Result := ReformatterKindByIndex(grpReformatter.ItemIndex);
end;


procedure TfrmReformatter.UpdateCommandLineControls;
var
  ShowCommandLine: Boolean;
begin
  ShowCommandLine := SelectedKind = rkExternal;
  lblCommandLine.Visible := ShowCommandLine;
  edtCommandLine.Visible := ShowCommandLine;
  btnCommandLineBrowse.Visible := ShowCommandLine;
end;


function TfrmReformatter.AskBeforeFormatting: Boolean;
begin
  Result := ReformatterAskStored
    // An external formatter without a command line cannot run, so ask in that case
    // even if the user asked not to be asked again.
    or ((SelectedKind = rkExternal) and (Trim(edtCommandLine.Text) = ''));
end;


function TfrmReformatter.ExecuteFormatter: Boolean;
var
  StartTime: UInt64;
  TimeElapsed: Double;
begin
  // Clear the previous result first: an empty OutputCode is what tells the caller
  // that formatting failed, and then it must leave the editor content alone.
  FOutputCode := '';
  Screen.Cursor := crHourGlass;
  try
    StartTime := GetTickCount64;
    case SelectedKind of
      rkInternal: FOutputCode := FormatSqlInternal(FInputCode);
      rkHeidiSQLOnline: FOutputCode := FormatSqlOnlineHeidisql(FInputCode);
      rkSqlFormatOrg: FOutputCode := FormatSqlOnlineSqlformatOrg(FInputCode);
      rkExternal: FOutputCode := FormatSqlExternal(FInputCode);
    end;
    // Unify line breaks, so selection end will be correct:
    FOutputCode := fixNewlines(FOutputCode);
    TimeElapsed := GetTickCount64 - StartTime;
    MainForm.LogSQL(f_('Code reformatted in %s, using formatter %s',
      [FormatTimeNumber(TimeElapsed/1000, True, 3), ReformatterKindToId(SelectedKind)]));
    Result := FOutputCode <> '';
    if not Result then
      ErrorDialog(_('The formatter returned an empty result.'));
  except
    on E:Exception do begin
      FOutputCode := '';
      Result := False;
      ErrorDialog(E.ClassName + ': ' + E.Message);
    end;
  end;
  Screen.Cursor := crDefault;
end;


procedure TfrmReformatter.btnOkClick(Sender: TObject);
begin
  if SelectedKind = rkExternal then begin
    if Trim(edtCommandLine.Text) = '' then begin
      ErrorDialog(_('Please specify the command line of the external formatter.'));
      ModalResult := mrNone;
      Exit;
    end;
    StoreReformatterExternalCommand(Trim(edtCommandLine.Text));
  end;
  if ExecuteFormatter then begin
    StoreReformatterAsk(chkKeepAsking.Checked);
    ModalResult := mrOk;
  end else
    ModalResult := mrNone;
end;


procedure TfrmReformatter.btnCommandLineBrowseClick(Sender: TObject);
var
  Dialog: TOpenDialog;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := _('Select the executable of the external formatter');
    Dialog.Options := [ofFileMustExist];
    if Dialog.Execute then
      edtCommandLine.Text := Dialog.FileName;
  finally
    Dialog.Free;
  end;
end;


procedure TfrmReformatter.FormCreate(Sender: TObject);
var
  Kind: TReformatterKind;
begin
  // Single source of truth for the formatter list: the combo box in Preferences
  // copies these items, so an item index always maps to the same TReformatterKind.
  grpReformatter.Items.Clear;
  for Kind := Low(TReformatterKind) to High(TReformatterKind) do
    grpReformatter.Items.Add(ReformatterCaption(Kind));
  grpReformatter.ItemIndex := Ord(ReformatterKindStored);
  edtCommandLine.Text := ReformatterExternalCommandStored;
  chkKeepAsking.Checked := ReformatterAskStored;
  grpReformatterClick(Self);
  lblFormatProviderLink.Font.Style := lblFormatProviderLink.Font.Style + [fsUnderline];
end;

procedure TfrmReformatter.FormDestroy(Sender: TObject);
begin
  // Remember the last used formatter and its command line, regardless of whether
  // the dialog was confirmed. Whether to ask again at all is stored by btnOkClick.
  StoreReformatterKind(SelectedKind);
  StoreReformatterExternalCommand(Trim(edtCommandLine.Text));
end;


procedure TfrmReformatter.grpReformatterClick(Sender: TObject);
begin
  case SelectedKind of
    rkInternal: begin
      lblFormatProviderLink.Visible := False;
    end;
    rkHeidiSQLOnline: begin
      lblFormatProviderLink.Caption := 'github.com/doctrine/sql-formatter (Jeremy Dorn)';
      lblFormatProviderLink.Hint := 'https://github.com/doctrine/sql-formatter';
      lblFormatProviderLink.Visible := True;
    end;
    rkSqlFormatOrg: begin
      lblFormatProviderLink.Caption := 'SQLFormat.org (Andi Albrecht)';
      lblFormatProviderLink.Hint := 'https://sqlformat.org/';
      lblFormatProviderLink.Visible := True;
    end;
    rkExternal: begin
      lblFormatProviderLink.Visible := False;
    end;
  end;
  UpdateCommandLineControls;
end;

procedure TfrmReformatter.lblFormatProviderLinkClick(Sender: TObject);
begin
  apphelpers.ShellExec(TLabel(Sender).Hint);
end;

function TfrmReformatter.FormatSqlInternal(SQL: String): String;
var
  Conn: TDBConnection;
  SQLFunc: TSQLFunction;
  AllKeywords, ImportantKeywords, PairKeywords: TStringList;
  i, Run, KeywordMaxLen: Integer;
  IsEsc, IsQuote, InComment, InBigComment, InString, InKeyword, InIdent, LastWasComment: Boolean;
  c, p: Char;
  Keyword, PreviousKeyword, TestPair: String;
  DT: TDBDatatype;
const
  WordChars = ['a'..'z', 'A'..'Z', '0'..'9', '_', '.'];
  WhiteSpaces = [#9, #10, #13, #32];
begin
  Conn := MainForm.ActiveConnection;
  // Known SQL keywords, get converted to UPPERCASE
  AllKeywords := TStringList.Create;
  AllKeywords.Text := MySQLKeywords.Text;

  for SQLFunc in Conn.SQLFunctions do begin
    // Leave out operator functions like ">>", and the "X()" function so hex values don't get touched
    if (SQLFunc.Declaration <> '') and (SQLFunc.Name <> 'X') then
      AllKeywords.Add(SQLFunc.Name);
  end;
  for DT in Conn.Datatypes do
    AllKeywords.Add(DT.Name);
  KeywordMaxLen := 0;
  for i:=0 to AllKeywords.Count-1 do
    KeywordMaxLen := Max(KeywordMaxLen, Length(AllKeywords[i]));

  // A subset of the above list, each of them will get a linebreak left to it
  ImportantKeywords := Explode(',', 'SELECT,FROM,LEFT,RIGHT,STRAIGHT,NATURAL,INNER,JOIN,WHERE,GROUP,ORDER,HAVING,LIMIT,CREATE,DROP,UPDATE,INSERT,REPLACE,TRUNCATE,DELETE');
  // Keywords which followers should not get separated into a new line
  PairKeywords := Explode(',', 'LEFT,RIGHT,STRAIGHT,NATURAL,INNER,ORDER,GROUP');

  IsEsc := False;
  InComment := False;
  InBigComment := False;
  LastWasComment := False;
  InString := False;
  InIdent := False;
  Run := 1;
  Result := '';
  SQL := SQL + ' ';
  SetLength(Result, Length(SQL)*2);
  Keyword := '';
  PreviousKeyword := '';
  for i:=1 to Length(SQL) do begin
    c := SQL[i]; // Current char
    if i > 1 then p := SQL[i-1] else p := #0; // Previous char

    // Detection logic - where are we?
    if c = '\' then IsEsc := not IsEsc
    else IsEsc := False;
    IsQuote := (c = '''') or (c = '"');
    if c = '`' then InIdent := not InIdent;
    if (not IsEsc) and IsQuote then InString := not InString;
    if (c = '#') or ((c = '-') and (p = '-')) then InComment := True;
    if ((c = #10) or (c = #13)) and InComment then begin
      LastWasComment := True;
      InComment := False;
    end;
    if (c = '*') and (p = '/') and (not InComment) and (not InString) then InBigComment := True;
    if (c = '/') and (p = '*') and (not InComment) and (not InString) then InBigComment := False;
    InKeyword := (not InComment) and (not InBigComment) and (not InString) and (not InIdent) and CharInSet(c, WordChars);

    // Creation of returning text
    if InKeyword then begin
      Keyword := Keyword + c;
    end else begin
      if Keyword <> '' then begin
        if AllKeywords.IndexOf(KeyWord) > -1 then begin
          while (Run > 1) and CharInSet(Result[Run-1], WhiteSpaces) do
            Dec(Run);
          Keyword := UpperCase(Keyword);
          if Run > 1 then begin
            // SELECT, WHERE, JOIN etc. get a new line, but don't separate LEFT JOIN with linebreaks
            if LastWasComment or ((ImportantKeywords.IndexOf(Keyword) > -1) and (PairKeywords.IndexOf(PreviousKeyword) = -1)) then
              Keyword := CRLF + Keyword
            else if (Result[Run-1] <> '(') then
              Keyword := ' ' + Keyword;
          end;
          LastWasComment := False;
        end;
        PreviousKeyword := Trim(Keyword);
        Insert(Keyword, Result, Run);
        Inc(Run, Length(Keyword));
        Keyword := '';
      end;
      if (not InComment) and (not InBigComment) and (not InString) and (not InIdent) then begin
        TestPair := Result[Run-1] + c;
        if (TestPair = '  ') or (TestPair = '( ') then begin
          c := Result[Run-1];
          Dec(Run);
        end;
        if (TestPair = ' )') or (TestPair = ' ,') then
          Dec(Run);
      end;
      Result[Run] := c;
      Inc(Run);
    end;

  end;

  // Cut overlength
  SetLength(Result, Run-2);
end;


function TfrmReformatter.FormatSqlOnlineHeidisql(SQL: String): String;
var
  HttpReq: THttpDownload;
  Parameters, Response: TStringList;
begin
  HttpReq := THttpDownload.Create(Self);
  HttpReq.RequestHeaders.Add('Content-Type: text/plain; charset=utf-8');
  Parameters := TStringList.Create;
  Parameters.AddPair('indent', CodeIndent);
  Parameters.AddPair('input', FInputCode);
  Response := TStringList.Create;
  HttpReq.FormPost(APPDOMAIN + 'sql-formatter.php', Parameters, Response);
  if Response.Count = 0 then
    raise Exception.Create(_('Empty result from online reformatter'));
  Result := Response.Text;
  HttpReq.Free;
end;


function TfrmReformatter.FormatSqlOnlineSqlformatOrg(SQL: String): String;
var
  HttpReq: THttpDownload;
  Parameters, Response: TStringList;
  JsonResponseStr: String;
  JsonParser: TJSONParser;
  JsonTmp: TJSONData;
begin
  HttpReq := THttpDownload.Create(Self);
  HttpReq.RequestHeaders.Add('Content-Type: application/json; charset=utf-8');
  // Parameter documentation: https://sqlformat.org/api/
  Parameters := TStringList.Create;
  Parameters.AddPair('sql', FInputCode);
  Parameters.AddPair('reindent', '1');
  if AppSettings.ReadBool(asTabsToSpaces) then
    Parameters.AddPair('indent_width', AppSettings.ReadInt(asTabWidth).ToString)
  else
    Parameters.AddPair('indent_width', '2');
  Parameters.AddPair('keyword_case', 'upper');
  Response := TStringList.Create;
  HttpReq.FormPost('https://sqlformat.org/api/v1/format', Parameters, Response);
  JsonResponseStr := Response.Text;
  if JsonResponseStr.IsEmpty then
    raise Exception.Create(_('Empty result from online reformatter'));
  JsonParser := TJSONParser.Create(JsonResponseStr, []);
  JsonTmp := JsonParser.Parse;
  Result := JsonTmp.GetPath('result').AsString;
  JsonTmp.Free;
  JsonParser.Free;
  HttpReq.Free;
end;

{**
  Splits a command line into arguments, honouring double quoted parts, so that
  "C:\Some Path\formatter.exe" --option "some value" works as expected.
  TProcess.CommandLine does the same, but is deprecated.
}
procedure SplitReformatterCommandLine(Command: String; Arguments: TStrings);
var
  i: Integer;
  Current: String;
  InQuote: Boolean;
begin
  Arguments.Clear;
  Current := '';
  InQuote := False;
  for i := 1 to Length(Command) do begin
    case Command[i] of
      '"': InQuote := not InQuote;
      ' ', #9:
        if InQuote then
          Current := Current + Command[i]
        else begin
          if Current <> '' then begin
            Arguments.Add(Current);
            Current := '';
          end;
        end;
      else
        Current := Current + Command[i];
    end;
  end;
  if Current <> '' then
    Arguments.Add(Current);
end;


{**
  Runs the configured external command line formatter. The SQL is written to the
  process' stdin and the formatted SQL is expected on its stdout, which is what
  command line formatters like sleek, sql-formatter or pgFormatter do.
}
function TfrmReformatter.FormatSqlExternal(SQL: String): String;
var
  Proc: TProcess;
  Command: String;
  CommandArguments: TStringList;
  Buffer: array[0..4095] of Byte;
  Chunk, Position, i: Integer;
  Output: TMemoryStream;
  Started, TimeoutMs: Int64;

  procedure DrainOutput;
  var
    ReadCount: LongInt;
  begin
    // Read whatever is available without blocking, so a formatter which writes a
    // lot of output while we are still feeding it cannot fill up the pipe.
    while Proc.Output.NumBytesAvailable > 0 do begin
      ReadCount := Proc.Output.Read(Buffer, SizeOf(Buffer));
      if ReadCount <= 0 then
        Break;
      Output.WriteBuffer(Buffer, ReadCount);
    end;
  end;

begin
  Result := '';
  Command := Trim(edtCommandLine.Text);
  if Command = '' then
    raise Exception.Create(_('No command line configured for the external formatter'));

  TimeoutMs := AppSettings.ReadInt(asReformatterTimeout) * 1000;
  if TimeoutMs <= 0 then
    TimeoutMs := 15000;

  CommandArguments := TStringList.Create;
  Output := TMemoryStream.Create;
  Proc := TProcess.Create(nil);
  try
    SplitReformatterCommandLine(Command, CommandArguments);
    if CommandArguments.Count = 0 then
      raise Exception.Create(_('No command line configured for the external formatter'));

    Proc.Options := [poUsePipes];
    {$IFDEF WINDOWS}
    // No console window flashing up while the formatter works
    Proc.Options := Proc.Options + [poNoConsole];
    {$ENDIF}
    Proc.Executable := CommandArguments[0];
    for i := 1 to CommandArguments.Count-1 do
      Proc.Parameters.Add(CommandArguments[i]);
    Proc.Execute;
    try
      // Feed the SQL to stdin, draining output in between
      Position := 1;
      while Position <= Length(SQL) do begin
        Chunk := Min(1024, Length(SQL) - Position + 1);
        Proc.Input.WriteBuffer(SQL[Position], Chunk);
        Inc(Position, Chunk);
        DrainOutput;
      end;
      try
        Proc.CloseInput;
      except
        // The process may have exited already, e.g. when it rejects its arguments
      end;

      Started := GetTickCount64;
      while Proc.Running do begin
        DrainOutput;
        Sleep(10);
        if GetTickCount64 - Started > TimeoutMs then begin
          Proc.Terminate(1);
          raise Exception.Create(f_('The external formatter did not finish within %d seconds',
            [TimeoutMs div 1000]));
        end;
      end;
      DrainOutput;

      if Proc.ExitStatus <> 0 then
        raise Exception.Create(f_('%s exited with code %d, so its output is not used',
          [ExtractFileName(Command), Proc.ExitStatus]));

      if Output.Size > 0 then begin
        SetLength(Result, Output.Size);
        Output.Position := 0;
        Output.ReadBuffer(Result[1], Output.Size);
      end;
    finally
      // Release the pipes even when an exception is on its way out
      Proc.Terminate(0);
    end;
  finally
    Proc.Free;
    Output.Free;
    CommandArguments.Free;
  end;
end;

end.
