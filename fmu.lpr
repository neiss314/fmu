{$MODE objfpc}
program fmu;

{$H+}
uses
  crt,
  Classes,
  SysUtils,
  SHA1 in 'SHA1\SHA1.pp',
  ziputils in 'unzip\ziputils.pp',
  Unzip32 in 'unzip\Unzip32.pp',
  jsontools in 'JSON\jsontools.pp',
  commandline in 'CommandLine\CommandLine.pp',
  WinInet;

const
  JSONInfoFull = 'https://mods.factorio.com/api/mods/';
  ModDownloadURL = '';
  IgnoredMods: array[0..1] of string = ('base', 'space-age');

  BUFFER_SIZE = 65535;
  strUserAgentDefault = 'Mozilla/5.0 (Windows; U; MSIE 7.0; Windows NT 6.0; en-US)';
  dwFlags = INTERNET_FLAG_RELOAD or INTERNET_FLAG_NO_CACHE_WRITE;

var
  GlobalInetSession: HINTERNET = nil;
  GetStartDir: string;

type
  PModInfo = ^TModInfo;

  TModInfo = record
    ModName: string;
    CurrentVer: string;
    LatestVer: string;
    ExpectedSHA1: string;
  end;

  procedure Msg(const s: string; attr: Word);
  var
    savedAttr: Word;

    procedure SetTextColor(attr: Word);
    begin
      TextColor(attr and $0F);
      TextBackground((attr shr 4) and $07);
    end;

  begin
    savedAttr := TextAttr;
    SetTextColor(attr);
    WriteLn(s);
    TextAttr := savedAttr;
  end;

  function CalculateFileSHA1(const FileName: string): string;
  begin
    Result := '';
    if FileExists(FileName) then
    begin
      Result := SHA1Print(SHA1File(FileName, BUFFER_SIZE * 2));
    end;
  end;

  function UnzipInStream(var fStream: TMemoryStream; const fZipFilePath, fUnpackedFile: string): Boolean;
  var
    UnZipper: unzFile;
    zfinfos: unz_file_info_ptr;
    li_SizeRead: LongInt;
    fMemorySize: LongWord;
    FBuffer: array[0..BUFFER_SIZE - 1] of Byte;
    zipArchive, SearchingFile: String;
    fMemory: TMemoryStream;
  begin
    Result := False;
    zipArchive := UTF8Encode(fZipFilePath);
    // Wildcard '*' нужен для поиска файла в подпапках внутри ZIP
    // (моды Factorio хранят info.json как modname_version/info.json)
    SearchingFile := UTF8Encode('*' + fUnpackedFile);
    fMemorySize := 0;
    UnZipper := unzOpen(PChar(zipArchive));
    try
      if unzLocateFile(UnZipper, PAnsiChar(SearchingFile)) = UNZ_OK then
      begin
        unzOpenCurrentFile(UnZipper);
        New(zfinfos);
        try
          unzGetCurrentFileInfo(UnZipper, zfinfos, PAnsiChar(SearchingFile), SizeOf(SearchingFile), nil, 0, nil, 0);
          fMemory := TMemoryStream.Create;
          try
            // Читаем чанками; li_SizeRead <= 0 означает конец файла или ошибку
            repeat
              li_SizeRead := unzReadCurrentFile(UnZipper, @FBuffer[0], SizeOf(FBuffer));
              if li_SizeRead <= 0 then
              begin
                Break;
              end;
              fMemory.WriteBuffer(FBuffer[0], li_SizeRead);
              Inc(fMemorySize, li_SizeRead);
            until False;
            fMemory.Position := 0;
            if fMemorySize > 0 then
            begin
              fStream.CopyFrom(fMemory, fMemorySize);
              Result := True;
            end;
          finally
            fMemory.Free;
          end;
        finally
          Dispose(zfinfos);
        end;
      end;
    finally
      unzCloseCurrentFile(UnZipper);
      unzClose(UnZipper);
    end;
  end;

  function IsValidZipFile(const fFileName: string): Boolean;
  var
    FS: TFileStream;
    Sig: array[0..1] of Byte;
  begin
    Result := False;
    if not FileExists(fFileName) then
    begin
      Exit;
    end;
    try
      FS := TFileStream.Create(fFileName, fmOpenRead or fmShareDenyNone);
      try
        if FS.Size >= 2 then
        begin
          FS.Read(Sig[0], 2);
          Result := (Sig[0] = $50) and (Sig[1] = $4B);
        end;
      finally
        FS.Free;
      end;
    except
      Result := False;
    end;
  end;

  function UrlEncode(const s: string): string;
  const
    SafeChars = ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'];
  var
    i: Integer;
    c: Char;
  begin
    Result := '';
    for i := 1 to Length(s) do
    begin
      c := s[i];
      if c in SafeChars then
      begin
        Result := Result + c;
      end
      else if c = ' ' then
      begin
        Result := Result + '%20';
      end
      else
      begin
        Result := Result + '%' + IntToHex(Ord(c), 2);
      end;
    end;
  end;

  function DownloadToStream(const fURL: string; fDLStream: TStream): Boolean;
  var
    hSession, hFile: HINTERNET;
    Buffer: array[0..BUFFER_SIZE - 1] of Byte;
    BytesRead: DWORD;
    StatusCode: DWORD;
    StatusSize: DWORD;
    Index: DWORD = 0;
    DownloadedSize: Int64 = 0;
  begin
    Result := False;
    fDLStream.Size := 0;
    fDLStream.Position := 0;
    hSession := GlobalInetSession;
    if hSession = nil then
    begin
      WriteLn('Failed to initialize internet connection');
      Exit;
    end;
    hFile := InternetOpenUrl(hSession, PChar(fURL), nil, 0, dwFlags, 0);
    if hFile = nil then
    begin
      WriteLn('Failed to connect to server');
      Exit;
    end;
    try
      StatusSize := SizeOf(StatusCode);
      if not HttpQueryInfo(hFile, HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER, @StatusCode, StatusSize, Index) then
      begin
        WriteLn('Failed to query HTTP status');
        Exit;
      end;
      if (StatusCode < 200) or (StatusCode >= 300) then
      begin
        WriteLn('HTTP error: ', StatusCode);
        Exit;
      end;
      while True do
      begin
        if not InternetReadFile(hFile, @Buffer, SizeOf(Buffer), BytesRead) then
        begin
          WriteLn('Failed to read from server');
          Exit;
        end;
        if BytesRead = 0 then
        begin
          Break;
        end;
        fDLStream.WriteBuffer(Buffer, BytesRead);
        Inc(DownloadedSize, BytesRead);
      end;
      if DownloadedSize > 0 then
      begin
        fDLStream.Position := 0;
        Result := True;
      end
      else
      begin
        WriteLn('Download failed (empty response)');
        fDLStream.Size := 0;
      end;
    finally
      InternetCloseHandle(hFile);
    end;
  end;

  function DownloadFile(const fURL, fSaveToFileName: string): string;
  var
    hSession, hFile: HINTERNET;
    FS: TFileStream = nil;
    Buffer: array[0..BUFFER_SIZE - 1] of Byte;
    BytesRead: DWORD;
    DownloadedSize: Int64 = 0;
    StatusCode: DWORD;
    StatusSize: DWORD;
    Index: DWORD = 0;
    ContentLength: Int64 = 0;
    ContentLengthDW: DWORD = 0;
    ContentSize: DWORD = 0;
  begin
    Result := '';
    hSession := GlobalInetSession;
    if hSession = nil then
    begin
      WriteLn('Failed to initialize internet connection');
      Exit;
    end;

    hFile := nil;
    try
      hFile := InternetOpenUrl(hSession, PChar(fURL), nil, 0, dwFlags, 0);
      if hFile = nil then
      begin
        WriteLn('Failed to connect to server');
        Exit;
      end;

      StatusSize := SizeOf(StatusCode);
      if not HttpQueryInfo(hFile, HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER, @StatusCode, StatusSize, Index) then
      begin
        WriteLn('Failed to query HTTP status');
        Exit;
      end;

      if (StatusCode < 200) or (StatusCode >= 300) then
      begin
        WriteLn('HTTP error: ', StatusCode);
        Exit;
      end;

      ContentSize := SizeOf(ContentLengthDW);
      if HttpQueryInfo(hFile, HTTP_QUERY_CONTENT_LENGTH or HTTP_QUERY_FLAG_NUMBER, @ContentLengthDW, ContentSize, Index) then
      begin
        ContentLength := ContentLengthDW;
      end
      else
      begin
        ContentLength := -1;
      end;

      FS := TFileStream.Create(fSaveToFileName, fmCreate);
      while True do
      begin
        if not InternetReadFile(hFile, @Buffer, SizeOf(Buffer), BytesRead) then
        begin
          WriteLn('Failed to read from server');
          Exit;
        end;
        if BytesRead = 0 then
        begin
          Break;
        end;
        FS.WriteBuffer(Buffer, BytesRead);
        Inc(DownloadedSize, BytesRead);
        //SetTextColor($0B);
        if ContentLength > 0 then
        begin
          // Размер известен — показываем прогресс в %
          if ContentLength < 1024 * 1024 then
          begin
            Write(#13, '  Downloaded: ', DownloadedSize div 1024, ' KB / ',
              ContentLength div 1024, ' KB (',
              (DownloadedSize * 100) div ContentLength, '%)');
          end
          else
          begin
            Write(#13, '  Downloaded: ', DownloadedSize div (1024 * 1024), ' MB / ',
              ContentLength div (1024 * 1024), ' MB (',
              (DownloadedSize * 100) div ContentLength, '%)');
          end;
        end
        else
        begin
          // Размер неизвестен — показываем просто сколько скачано
          if DownloadedSize < 1024 * 1024 then
          begin
            Write(#13, '  Downloaded: ', DownloadedSize div 1024, ' KB');
          end
          else
          begin
            Write(#13, '  Downloaded: ', DownloadedSize div (1024 * 1024), ' MB');
          end;
        end;
      end;
      //SetTextColor(GetAttr);
      WriteLn;
    finally
      if hFile <> nil then
      begin
        InternetCloseHandle(hFile);
      end;
      FreeAndNil(FS);
    end;

    if DownloadedSize > 0 then
    begin
      if IsValidZipFile(fSaveToFileName) then
      begin
        WriteLn('  Downloaded: ', DownloadedSize, ' bytes');
        Result := CalculateFileSHA1(fSaveToFileName);
        if Result = '' then
        begin
          WriteLn('Failed to calculate SHA1, deleting file');
          DeleteFile(fSaveToFileName);
        end;
      end
      else
      begin
        WriteLn('Warning: downloaded file is not a valid ZIP archive');
        DeleteFile(fSaveToFileName);
      end;
    end
    else
    begin
      Msg('  Download failed', $0C);
      if FileExists(fSaveToFileName) then
      begin
        DeleteFile(fSaveToFileName);
      end;
    end;
  end;

  function ExtractModNameFromDependency(const fDepStr: String): String;
  var
    s: string = '';
    p, opPos, i: Integer;
    FirstNonSpace: Integer;
    PrefixChar: Char;
    FoundOpPos: Integer;
  const
    Operators: array[0..5] of String = ('>=', '>', '<=', '<', '=', '~');
  begin
    Result := '';
    for PrefixChar in fDepStr do
    begin
      if PrefixChar <> '"' then
      begin
        s := s + PrefixChar;
      end;
    end;
    s := Trim(s);
    if s = '' then
    begin
      Exit;
    end;
    FirstNonSpace := 1;
    while (FirstNonSpace <= Length(s)) and (s[FirstNonSpace] = ' ') do
    begin
      Inc(FirstNonSpace);
    end;
    if FirstNonSpace > Length(s) then
    begin
      Exit;
    end;
    PrefixChar := s[FirstNonSpace];
    if PrefixChar in ['?', '!', '~', '('] then
    begin
      Exit;
    end;
    if (Length(s) >= 3) and (s[FirstNonSpace] = '(') then
    begin
      p := Pos(') ', s);
      if p > 0 then
      begin
        s := Trim(Copy(s, p + 2, Length(s)));
      end
      else
      begin
        p := Pos(')', s);
        if p > 0 then
        begin
          s := Trim(Copy(s, p + 1, Length(s)));
        end;
      end;
      s := Trim(s);
      if s = '' then
      begin
        Exit;
      end;
      if s[1] in ['?', '!', '~'] then
      begin
        Exit;
      end;
    end;
    FoundOpPos := Length(s) + 1;
    for i := 0 to 5 do
    begin
      opPos := Pos(Operators[i], s);
      if (opPos > 0) and (opPos < FoundOpPos) then
      begin
        FoundOpPos := opPos;
      end;
    end;
    if FoundOpPos <= Length(s) then
    begin
      s := Trim(Copy(s, 1, FoundOpPos - 1));
    end;
    p := Pos(' ', s);
    if p > 0 then
    begin
      s := Trim(Copy(s, 1, p - 1));
    end;
    s := Trim(s);
    if s <> '' then
    begin
      Result := s;
    end;
  end;

  procedure DownloadMissingMod(const fModName: string; var fModInfo: TList; var fDependencies: TStringList);
  var
    URL, LatestVer, ExpectedSHA1, DownloadedFile: string;
    ComputedSHA1: string;
    mJSONStream: TMemoryStream;
    pMod: PModInfo;
    JSONFile, ReleasesNode, LastRelease, DepNode: TJsonNode;
    i, j: Integer;
    fDepName: string;
    IsIgnored, Found: Boolean;
  begin
    if GetStartDir = '' then
    begin
      WriteLn('Error finding the mods folder');
      exit;
    end;
    WriteLn('Downloading missing dependency: ', fModName);
    //GetStartDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
    URL := JSONInfoFull + UrlEncode(fModName);

    mJSONStream := TMemoryStream.Create;
    try
      if not DownloadToStream(URL, mJSONStream) then
      begin
        WriteLn('  Failed to fetch mod information');
        Exit;
      end;

      mJSONStream.Position := 0;
      JSONFile := TJsonNode.Create;
      try
        JSONFile.LoadFromStream(mJSONStream);
        ReleasesNode := JSONFile.Find('releases');
        if (ReleasesNode = nil) or (ReleasesNode.Kind <> nkArray) or (ReleasesNode.Count = 0) then
        begin
          WriteLn('  No releases found');
          Exit;
        end;

        LastRelease := ReleasesNode.Child(ReleasesNode.Count - 1);
        if (LastRelease.Find('version') = nil) or (LastRelease.Find('sha1') = nil) then
        begin
          WriteLn('  No version or sha1 found');
          Exit;
        end;
        LatestVer := LastRelease.Find('version').AsString;
        ExpectedSHA1 := LastRelease.Find('sha1').AsString;
        if LatestVer = '' then
        begin
          WriteLn('  Could not determine latest version');
          Exit;
        end;
        WriteLn('  Latest version: ', LatestVer);
        DownloadedFile := GetStartDir + fModName + '_' + LatestVer + '.zip';
        ComputedSHA1 := DownloadFile(ModDownloadURL + UrlEncode(fModName) + '/' + LatestVer + '.zip', DownloadedFile);

        if ComputedSHA1 = '' then
        begin
          WriteLn('  Download failed');
          Exit;
        end;

        if (ExpectedSHA1 <> '') and (ComputedSHA1 <> ExpectedSHA1) then
        begin
          WriteLn('  SHA1 mismatch');
          DeleteFile(DownloadedFile);
          Exit;
        end;
        Msg('  Successfully downloaded and verified', $0A);

      finally
        JSONFile.Free;
      end;

      New(pMod);
      pMod^.ModName := fModName;
      pMod^.CurrentVer := LatestVer;
      pMod^.LatestVer := LatestVer;
      pMod^.ExpectedSHA1 := ExpectedSHA1;
      fModInfo.Add(pMod);

      mJSONStream.Clear;
      mJSONStream.Position := 0;
      mJSONStream.Size := 0;

      if UnzipInStream(mJSONStream, DownloadedFile, 'info.json') then
      begin
        mJSONStream.Position := 0;
        JSONFile := TJsonNode.Create;
        try
          JSONFile.LoadFromStream(mJSONStream);
          DepNode := JSONFile.Find('dependencies');

          if (DepNode <> nil) and (DepNode.Kind = nkArray) then
          begin
            for i := 0 to DepNode.Count - 1 do
            begin
              fDepName := Trim(DepNode.Child(i).Value);
              if fDepName = '' then
              begin
                Continue;
              end;

              fDepName := ExtractModNameFromDependency(fDepName);
              if fDepName = '' then
              begin
                Continue;
              end;
              IsIgnored := False;
              for j := Low(IgnoredMods) to High(IgnoredMods) do
              begin
                if fDepName = IgnoredMods[j] then
                begin
                  IsIgnored := True;
                  Break;
                end;
              end;
              if IsIgnored then
              begin
                Continue;
              end;
              Found := False;
              for j := 0 to fModInfo.Count - 1 do
              begin
                if PModInfo(fModInfo.Items[j])^.ModName = fDepName then
                begin
                  Found := True;
                  Break;
                end;
              end;

              if Found or (fDependencies.IndexOf(fDepName) >= 0) then
              begin
                Continue;
              end;

              fDependencies.Add(fDepName);
              WriteLn('  Added dependency: ', fDepName);
            end;
          end;
        finally
          JSONFile.Free;
        end;
      end
      else
      begin
        WriteLn('  Warning: info.json not found in downloaded archive');
      end;

    finally
      mJSONStream.Free;
    end;
    Msg('  Successfully installed', $0A);
  end;

var
  ZipPath, fName, fVersion, fDepName, dlURL: string;
  DownloadedFile, CurrentFile, ComputedSHA1: string;
  InfoStream: TMemoryStream;
  JSONFile, DepNode, LastRelease: TJsonNode;
  AllDependencies, ModList: TStringList;
  ModInfo: TList;
  sr: TSearchRec;
  pMod: PModInfo;
  i, j, k: Integer;
  IsIgnored, Found: Boolean;
  Cmd: TCmdLine;
  ver: Boolean;
begin
  GetStartDir := ExtractFilePath(ParamStr(0));
  Cmd := TCmdLine.Create;
  try
    Cmd.AddStrKey('P', '', 'PATH');
    Cmd.AddBoolKey('V', False, 'version');
    //Cmd.RequirePaths(0, 1);
    Cmd.Parse;
    if Cmd.IsValid then
    begin
      // fmu.exe -p="some path"
      GetStartDir := LowerCase(Cmd.StrKey['P']);
      if not DirectoryExists(GetStartDir, False) then
      begin
        GetStartDir := ExtractFilePath(ParamStr(0));
      end;
      ver := Cmd.BoolKey['V'];
    end
    else
    begin
      WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' [-V] [-P="path to folder"]');
    end;
  finally
    Cmd.Free;
    GetStartDir := IncludeTrailingPathDelimiter(GetStartDir);
  end;
  writeln();
  if ver then
  begin
    Msg('F A C T O R I O   M O D   U P D A T E R   V E R S I O N   1.0.0', $0B);
  end
  else
  begin
    Msg('F A C T O R I O   M O D   U P D A T E R', $0B);
  end;
  writeln();

  ZipPath := GetStartDir + '*.zip';
  GlobalInetSession := InternetOpen(strUserAgentDefault, INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if GlobalInetSession = nil then
  begin
    WriteLn('Warning: Failed to initialize internet connection');
    WriteLn('Press Enter to exit...');
    ReadLn;
    Exit;
  end;
  ModInfo := TList.Create;
  ModList := TStringList.Create;
  AllDependencies := TStringList.Create;

  InfoStream := TMemoryStream.Create;
  try
    if FindFirst(ZipPath, faAnyFile, sr) = 0 then
    begin
      repeat
        ModList.Add(sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    for i := 0 to ModList.Count - 1 do
    begin
      InfoStream.Clear;
      InfoStream.Position := 0;
      InfoStream.Size := 0;

      if IsValidZipFile(GetStartDir + ModList[i]) then
      begin
        if UnzipInStream(InfoStream, GetStartDir + ModList[i], 'info.json') then
        begin
          InfoStream.Position := 0;
          JSONFile := TJsonNode.Create;
          try
            JSONFile.LoadFromStream(InfoStream);
            fName := JSONFile.Force('name').AsString;
            fVersion := JSONFile.Force('version').AsString;
            New(pMod);
            pMod^.ModName := fName;
            pMod^.CurrentVer := fVersion;
            pMod^.LatestVer := '';
            pMod^.ExpectedSHA1 := '';
            ModInfo.Add(pMod);

            DepNode := JSONFile.Find('dependencies');
            if DepNode <> nil then
            begin
              for j := 0 to DepNode.Count - 1 do
              begin
                fDepName := Trim(DepNode.Child(j).Value);
                if fDepName = '' then
                begin
                  Continue;
                end;
                fDepName := ExtractModNameFromDependency(fDepName);

                if fDepName = '' then
                begin
                  Continue;
                end;
                IsIgnored := False;
                for k := Low(IgnoredMods) to High(IgnoredMods) do
                begin
                  if fDepName = IgnoredMods[k] then
                  begin
                    IsIgnored := True;
                    Break;
                  end;
                end;
                if not IsIgnored then
                begin
                  if AllDependencies.IndexOf(fDepName) = -1 then
                  begin
                    AllDependencies.Add(fDepName);
                  end;
                end;
              end;
            end;
          finally
            JSONFile.Free;
          end;
        end
        else
        begin
          WriteLn('Warning: info.json not found in ', ModList[i]);
        end;
      end;
    end;
    if ModInfo.Count > 0 then
    begin
      Msg('Checking for updates...', $0E);
    end
    else
    begin
      Msg('Nothing found... Skipping', $0C);
      WriteLn('Press Enter to exit...');
      ReadLn;
      Exit;
    end;
    WriteLn();
    for i := 0 to ModInfo.Count - 1 do
    begin
      pMod := PModInfo(ModInfo[i]);
      //WriteLn('Processing mod: ', pMod^.ModName, ' (current version: ', pMod^.CurrentVer, ')');
      Msg(pMod^.ModName + ' (current version: ' + pMod^.CurrentVer + ')', $0F);
      InfoStream.Clear;
      InfoStream.Position := 0;
      InfoStream.Size := 0;
      dlURL := JSONInfoFull + UrlEncode(pMod^.ModName);
      if DownloadToStream(dlURL, InfoStream) then
      begin
        JSONFile := TJsonNode.Create;
        try
          try
            JSONFile.LoadFromStream(InfoStream);
          except
            WriteLn('  Failed to parse mod information');
            Continue;
          end;
          DepNode := JSONFile.Find('releases');
          if (DepNode <> nil) and (DepNode.Kind = nkArray) and (DepNode.Count > 0) then
          begin
            LastRelease := DepNode.Child(DepNode.Count - 1);
            if LastRelease.Find('version') <> nil then
            begin
              pMod^.LatestVer := LastRelease.Find('version').AsString;
            end;
            if LastRelease.Find('sha1') <> nil then
            begin
              pMod^.ExpectedSHA1 := LastRelease.Find('sha1').AsString;
            end;
          end;
        finally
          JSONFile.Free;
        end;

        if pMod^.LatestVer <> '' then
        begin
          WriteLn('  Latest version: ', pMod^.LatestVer);
          if pMod^.CurrentVer <> pMod^.LatestVer then
          begin
            Msg('  Update available', $0E);
            CurrentFile := GetStartDir + pMod^.ModName + '_' + pMod^.CurrentVer + '.zip';
            DownloadedFile := GetStartDir + pMod^.ModName + '_' + pMod^.LatestVer + '.zip';
            ComputedSHA1 := DownloadFile(ModDownloadURL + UrlEncode(pMod^.ModName) + '/' + pMod^.LatestVer + '.zip', DownloadedFile);

            if ComputedSHA1 <> '' then
            begin
              if pMod^.ExpectedSHA1 <> '' then
              begin
                if ComputedSHA1 = pMod^.ExpectedSHA1 then
                begin
                  Msg('  SHA1 check passed', $0A);
                  DeleteFile(CurrentFile);
                end
                else
                begin
                  Msg('  SHA1 mismatch!', $0C);
                  WriteLn('    Expected: ', pMod^.ExpectedSHA1);
                  WriteLn('    Got:      ', ComputedSHA1);
                  DeleteFile(DownloadedFile);
                end;
              end
              else
              begin
                WriteLn('  SHA1 verification skipped (no checksum provided)');
              end;
            end
            else
            begin
              WriteLn('  Download failed or file is empty');
              if FileExists(DownloadedFile) then
              begin
                DeleteFile(DownloadedFile);
              end;
            end;
          end
          else
          begin
            Msg('  Already up to date', $0A);
          end;
        end;
      end
      else
      begin
        Msg('Failed to fetch: ' + pMod^.ModName + '. Skipping.', $08);
      end;
    end;

    if Assigned(AllDependencies) and (AllDependencies.Count > 0) then
    begin
      for i := AllDependencies.Count - 1 downto 0 do
      begin
        AllDependencies[i] := Trim(AllDependencies[i]);
        if AllDependencies[i] = '' then
        begin
          AllDependencies.Delete(i);
        end;
      end;
      AllDependencies.Sort;
      for i := AllDependencies.Count - 1 downto 1 do
      begin
        if AllDependencies[i] = AllDependencies[i - 1] then
        begin
          AllDependencies.Delete(i);
        end;
      end;
      for i := AllDependencies.Count - 1 downto 0 do
      begin
        fDepName := AllDependencies[i];
        Found := False;
        for j := 0 to ModInfo.Count - 1 do
        begin
          if PModInfo(ModInfo[j])^.ModName = fDepName then
          begin
            Found := True;
            Break;
          end;
        end;
        if Found then
        begin
          AllDependencies.Delete(i);
        end;
      end;

      while AllDependencies.Count > 0 do
      begin
        fDepName := AllDependencies[0];
        AllDependencies.Delete(0);
        DownloadMissingMod(fDepName, ModInfo, AllDependencies);
      end;
    end;
  finally
    for i := 0 to ModInfo.Count - 1 do
    begin
      Dispose(PModInfo(ModInfo[i]));
    end;
    ModList.Free;
    AllDependencies.Free;
    ModInfo.Free;
    InfoStream.Free;
  end;

  if GlobalInetSession <> nil then
  begin
    InternetCloseHandle(GlobalInetSession);
  end;

  WriteLn('');
  Msg('All done.', $0A);
  WriteLn('Press Enter to exit...');
  ReadLn;
end.
