{ Very simple and light command-line parameter parsing tool }
{
var
  Cmd: TCmdLine;
begin
  Cmd := TCmdLine.Create;
  try
    Cmd.AddBoolKey('V', False, 'verbose');
    Cmd.AddStrKey ('O', 'out.txt', 'output');
    Cmd.RequirePaths(1, 1);  // ровно один positional-аргумент

    Cmd.Parse;

    if not Cmd.IsValid then
    begin
      WriteLn('Usage: demo [-V] [-O=<file>] <inputfile>');
      Halt(1);
    end;

    WriteLn('Input : ', Cmd.Paths[0]);
    WriteLn('Output: ', Cmd.StrKey['O']);
    if Cmd.BoolKey['V'] then
      WriteLn('Verbose mode on');
  finally
    Cmd.Free;
  end;
end.
```

Примеры вызова:
```
demo input.txt
demo -V -O=result.txt input.txt
demo --verbose+ --output=result.txt input.txt
}
unit CommandLine;

interface

uses
  SysUtils, Classes;

type
  TKeyChar = 'A'..'Z';

  PCmdKey = ^TCmdKey;

  TCmdKey = record
    Alias: string;
    ValueStr: string;
    Key: TKeyChar;
    BoolKey: Boolean;
    ValueBool: Boolean;
  end;

  // Cmdline key syntax:
  // ( '-' | '/' ) NAME ( [ '+' | '-' ] | '=' ( '"' STR '"' | STR ) )
  // because of std Windows cmdline parser, keys in form '/key=str'
  // are also valid. And all of this keys transform to '/key=str' form.
  // Key parsing disabler/enabler '--' also supported.
  // Numbers are treated as strings.

  ECmdLine = class(Exception);

  { TCmdLine
    Usage:
      1. Add expected keys via AddBoolKey / AddStrKey.
      2. Optionally call RequirePaths to restrict the number of positional args.
      3. Call Parse.
      4. Check IsValid, then read BoolKey / StrKey / Paths as needed.
      5. Call Clear (or destroy the object) when done. }
  TCmdLine = class(TObject)
  private
    const
      { Sentinel value meaning "no upper limit on path count" }
      MaxPathsUnlimited = -1;

  private
    FParsed: Boolean;
    FValidParsed: Boolean;
    FKeyList: TList;        // defined (registered) keys
    FParsedKeyList: TList;  // keys actually found on the command line
    FParsedPathsList: TStringList;
    FMinPaths: Integer;
    FMaxPaths: Integer;     // MaxPathsUnlimited (-1) = no upper limit

    { Returns a key record pointer from FParsedKeyList (InParsedKeys=True)
      or FKeyList (InParsedKeysъlse), or nil if not found. }
    function FindKey(Key: TKeyChar; InParsedKeys: Boolean): PCmdKey;

    { Looks up a key by its single-char name or alias (case-insensitive).
      Searches FKeyList only. }
    function FindKeyAlias(const S: string): PCmdKey;

    { Checks that a key with the given char or alias is not already registered. }
    function KeyExists(Key: TKeyChar; const Alias: string): Boolean;

    { Parses a single token that starts with '-' or '/'.
      Adds a matching record to FParsedKeyList on success.
      Returns True on success, False if the token should be treated as a path. }
    function ParseKeyToken(const Token: string): Boolean;

    { Frees all records in a TList of PCmdKey and clears the list. }
    procedure FreeCmdKeyList(List: TList);

    function GetBoolKey(Key: TKeyChar): Boolean;
    function GetPath(Index: Integer): string;
    function GetPathCount: Integer;
    function GetStrKey(Key: TKeyChar): string;
  public
    { Register a boolean key (flag).
      Key     - single uppercase letter used as the short name.
      Default - value returned when the key is absent from the command line.
      Alias   - optional long name (e.g. 'verbose'); case-insensitive. }
    procedure AddBoolKey(Key: TKeyChar; Default: Boolean; const Alias: string = '');

    { Register a string-valued key.
      Default - value returned when the key is absent from the command line. }
    procedure AddStrKey(Key: TKeyChar; const Default: string; const Alias: string = '');

    { Set the allowed range for positional arguments (paths).
      Pass MaxPathsUnlimited (or omit MaxCount) to allow any number.
      Raises ECmdLine if MaxCount < MinCount. }
    procedure RequirePaths(MinCount: Integer = 0; MaxCount: Integer = MaxPathsUnlimited);

    { Remove all registered keys and parsed results; reset to initial state. }
    procedure Clear;

    { Parse the process command line (ParamStr / ParamCount). }
    procedure Parse;

    { Returns True when Parse has been called AND the positional-argument count
      satisfies the range set by RequirePaths. }
    function IsValid: Boolean;

    { Value of a boolean key. Raises ECmdLine if not yet parsed or wrong type. }
    property BoolKey[Key: TKeyChar]: Boolean read GetBoolKey;

    { Value of a string key. Raises ECmdLine if not yet parsed or wrong type. }
    property StrKey[Key: TKeyChar]: string read GetStrKey;

    { Number of positional arguments found. Raises ECmdLine if not yet parsed. }
    property PathCount: Integer read GetPathCount;

    { Positional argument by index. Raises ECmdLine if not yet parsed. }
    property Paths[Index: Integer]: string read GetPath;

    constructor Create;
    destructor Destroy; override;
  end;


implementation

{ TCmdLine }

constructor TCmdLine.Create;
begin
  inherited Create;
  FKeyList         := TList.Create;
  FParsedKeyList   := TList.Create;
  FParsedPathsList := TStringList.Create;
  FMinPaths        := 0;
  FMaxPaths        := MaxPathsUnlimited;
  FValidParsed     := False;
  FParsed          := False;
end;

destructor TCmdLine.Destroy;
begin
  FreeCmdKeyList(FKeyList);
  FKeyList.Free;
  FreeCmdKeyList(FParsedKeyList);
  FParsedKeyList.Free;
  FParsedPathsList.Free;
  inherited Destroy;
end;

procedure TCmdLine.FreeCmdKeyList(List: TList);
var
  i: Integer;
begin
  for i := 0 to List.Count - 1 do
    Dispose(PCmdKey(List.Items[i]));
  List.Clear;
end;

procedure TCmdLine.Clear;
begin
  FreeCmdKeyList(FKeyList);
  FreeCmdKeyList(FParsedKeyList);
  FParsedPathsList.Clear;
  FMinPaths    := 0;
  FMaxPaths    := MaxPathsUnlimited;
  FValidParsed := False;
  FParsed      := False;
end;

function TCmdLine.KeyExists(Key: TKeyChar; const Alias: string): Boolean;
var
  i: Integer;
  P: PCmdKey;
  UpperAlias: string;
begin
  UpperAlias := UpperCase(Alias);
  for i := 0 to FKeyList.Count - 1 do
  begin
    P := PCmdKey(FKeyList.Items[i]);
    if P^.Key = Key then
    begin
      Result := True;
      Exit;
    end;
    if (Alias <> '') and (UpperCase(P^.Alias) = UpperAlias) then
    begin
      Result := True;
      Exit;
    end;
  end;
  Result := False;
end;

procedure TCmdLine.AddBoolKey(Key: TKeyChar; Default: Boolean; const Alias: string);
var
  P: PCmdKey;
begin
  if KeyExists(Key, Alias) then
    raise ECmdLine.CreateFmt(
      'Key "%s" (or alias "%s") is already registered', [Key, Alias]);
  FParsed := False;
  New(P);
  P^.Key       := Key;
  P^.Alias     := Alias;
  P^.BoolKey   := True;
  P^.ValueBool := Default;
  P^.ValueStr  := '';
  FKeyList.Add(P);
end;

procedure TCmdLine.AddStrKey(Key: TKeyChar; const Default: string; const Alias: string);
var
  P: PCmdKey;
begin
  if KeyExists(Key, Alias) then
    raise ECmdLine.CreateFmt(
      'Key "%s" (or alias "%s") is already registered', [Key, Alias]);
  FParsed := False;
  New(P);
  P^.Key       := Key;
  P^.Alias     := Alias;
  P^.BoolKey   := False;
  P^.ValueStr  := Default;
  P^.ValueBool := False;
  FKeyList.Add(P);
end;

procedure TCmdLine.RequirePaths(MinCount: Integer; MaxCount: Integer);
begin
  if (MaxCount <> MaxPathsUnlimited) and (MaxCount < MinCount) then
    raise ECmdLine.CreateFmt(
      'RequirePaths: MaxCount (%d) must be >= MinCount (%d) or MaxPathsUnlimited',
      [MaxCount, MinCount]);
  FMinPaths := MinCount;
  FMaxPaths := MaxCount;
  FParsed   := False;
end;

function TCmdLine.FindKey(Key: TKeyChar; InParsedKeys: Boolean): PCmdKey;
var
  i: Integer;
  L: TList;
begin
  if InParsedKeys then
    L := FParsedKeyList
  else
    L := FKeyList;
  for i := 0 to L.Count - 1 do
  begin
    Result := PCmdKey(L.Items[i]);
    if Result^.Key = Key then
      Exit;
  end;
  Result := nil;
end;

function TCmdLine.FindKeyAlias(const S: string): PCmdKey;
var
  i: Integer;
  Str: string;
begin
  Str := UpperCase(S);
  for i := 0 to FKeyList.Count - 1 do
  begin
    Result := PCmdKey(FKeyList.Items[i]);
    if (UpperCase(Result^.Alias) = Str) or (Result^.Key = Str) then
      Exit;
  end;
  Result := nil;
end;

function TCmdLine.ParseKeyToken(const Token: string): Boolean;
var
  State: (sBegin, sKey, sBool, sStr, sError);
  i, NameL: Integer;
  Ch: Char;
  Name: string;
  K: TCmdKey;
  PK: PCmdKey;
begin
  Result := False;
  State  := sBegin;
  Name   := '';
  NameL  := 0;
  { NameL is reused in sBool state as a flag:
    1 = key ended with '+' (True), 0 = ended with '-' (False). }

  for i := 2 to Length(Token) do
  begin
    Ch := Token[i];
    case State of
      sBegin:
        if Ch in ['0'..'9', 'A'..'Z', 'a'..'z'] then
        begin
          Name  := Ch;
          NameL := 1;
          State := sKey;
        end
        else
          Exit;

      sKey:
        case Ch of
          '0'..'9', 'A'..'Z', 'a'..'z':
          begin
            Inc(NameL);
            SetLength(Name, NameL);
            Name[NameL] := Ch;
          end;
          '+', '-':
          begin
            PK := FindKeyAlias(Name);
            if PK = nil then Exit;
            K     := PK^;
            Name  := '';
            NameL := Ord(Ch = '+'); { 1 = True, 0 = False }
            State := sBool;
          end;
          '=':
          begin
            PK := FindKeyAlias(Name);
            if PK = nil then Exit;
            K     := PK^;
            Name  := '';
            NameL := 0;
            State := sStr;
          end;
          else
            Exit;
        end;

      sBool:
        Exit; { no characters allowed after '+'/'-' }

      sStr:
      begin
        Inc(NameL);
        SetLength(Name, NameL);
        Name[NameL] := Ch;
      end;

      sError:
        Exit;
    end;
  end;

  case State of
    sStr:
    begin
      if K.BoolKey then Exit;
      if (Name <> '') and (Name[1] = '"') then
        K.ValueStr := AnsiDequotedStr(Name, '"')
      else
        K.ValueStr := Name;
    end;

    sKey:
    begin
      { Bare key with no suffix: toggle bool, or clear string value. }
      PK := FindKeyAlias(Name);
      if PK = nil then Exit;
      K := PK^;
      if K.BoolKey then
        K.ValueBool := not K.ValueBool
      else
        K.ValueStr := '';
    end;

    sBool:
    begin
      if not K.BoolKey then Exit;
      K.ValueBool := (NameL = 1);
    end;

    else
      Exit; { sBegin or sError }
  end;

  New(PK);
  PK^ := K;
  FParsedKeyList.Add(PK);
  Result := True;
end;

procedure TCmdLine.Parse;
var
  i: Integer;
  S: string;
  DoNotParseAsKeys: Boolean;
begin
  FreeCmdKeyList(FParsedKeyList);
  FParsedPathsList.Clear;
  FParsed          := True;
  FValidParsed     := False;
  DoNotParseAsKeys := False;

  for i := 1 to ParamCount do
  begin
    S := ParamStr(i);

    { '--' toggles key-parsing on/off, allowing paths that start with '-'. }
    if S = '--' then
    begin
      DoNotParseAsKeys := not DoNotParseAsKeys;
      Continue;
    end;

    if (not DoNotParseAsKeys) and (S <> '') and (S[1] in ['-', '/']) then
    begin
      { If the token looks like a key but fails to parse, treat it as a path. }
      if not ParseKeyToken(S) then
        FParsedPathsList.Add(S);
    end
    else
      FParsedPathsList.Add(S);
  end;

  { Validate positional-argument count. }
  i := FParsedPathsList.Count;
  if (i < FMinPaths) or
     ((FMaxPaths <> MaxPathsUnlimited) and (i > FMaxPaths)) then
    Exit;

  FValidParsed := True;
end;

function TCmdLine.IsValid: Boolean;
begin
  if not FParsed then
    raise ECmdLine.Create('CmdLine must be parsed before calling IsValid');
  Result := FValidParsed;
end;

function TCmdLine.GetBoolKey(Key: TKeyChar): Boolean;
var
  K: PCmdKey;
begin
  if not FParsed then
    raise ECmdLine.Create('CmdLine must be parsed before reading BoolKey');

  { Prefer the value found on the command line; fall back to the registered default. }
  K := FindKey(Key, True);
  if K = nil then
    K := FindKey(Key, False);

  if K = nil then
  begin
    Result := False;
    Exit;
  end;

  if not K^.BoolKey then
    raise ECmdLine.CreateFmt('Key "%s" is not a boolean key', [Key]);

  Result := K^.ValueBool;
end;

function TCmdLine.GetStrKey(Key: TKeyChar): string;
var
  K: PCmdKey;
begin
  if not FParsed then
    raise ECmdLine.Create('CmdLine must be parsed before reading StrKey');

  K := FindKey(Key, True);
  if K = nil then
    K := FindKey(Key, False);

  if K = nil then
  begin
    Result := '';
    Exit;
  end;

  if K^.BoolKey then
    raise ECmdLine.CreateFmt('Key "%s" is not a string key', [Key]);

  Result := K^.ValueStr;
end;

function TCmdLine.GetPathCount: Integer;
begin
  if not FParsed then
    raise ECmdLine.Create('CmdLine must be parsed before reading PathCount');
  Result := FParsedPathsList.Count;
end;

function TCmdLine.GetPath(Index: Integer): string;
begin
  if not FParsed then
    raise ECmdLine.Create('CmdLine must be parsed before reading Paths');
  Result := FParsedPathsList[Index];
end;

end.
