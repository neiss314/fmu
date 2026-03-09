{$MODE objfpc}

program fmu;

{$H+}

uses
  crt,
  Classes,
  SysUtils,
  SHA1 in 'SHA1\SHA1.pp',       // Модуль для вычисления SHA1-хеша (подключаемый файл)
  ziputils in 'unzip\ziputils.pp', // Вспомогательные функции для работы с ZIP
  Unzip32 in 'unzip\Unzip32.pp',   // Основной модуль для распаковки ZIP-архивов
  jsontools in 'JSON\jsontools.pp', // Модуль для парсинга и генерации JSON
  commandline in 'CommandLine\CommandLine.pp', // Модуль для разбора параметров командной строки
  WinInet;

const
  JSONInfoFull = 'https://mods.factorio.com/api/mods/';
  // Базовые URL для получения информации о модах и скачивания файлов
  ModDownloadURL = 'https://mods-storage.re146.dev/';
  // Зеркало для скачивания (добавлено в релизных exe)
  IgnoredMods: array[0..1] of string = ('base', 'space-age');
  // Список модов, которые игнорируются при обработке зависимостей (встроенные моды Factorio)
  // Версия программы
  VersionStr = '1.0.0';

  // Размер буфера для чтения данных (используется при работе с файлами и сетью)
  BUFFER_SIZE = 65535;
  // User-Agent для HTTP-запросов (имитация браузера)
  strUserAgentDefault = 'Mozilla/5.0 (Windows; U; MSIE 7.0; Windows NT 6.0; en-US)';
  // Флаги для WinInet: не использовать кэш, всегда загружать заново
  dwFlags = INTERNET_FLAG_RELOAD or INTERNET_FLAG_NO_CACHE_WRITE;

var
  GlobalInetSession: HINTERNET = nil; // Глобальный сеанс WinInet (открывается один раз)
  GetStartDir: string;
  // Рабочая папка, в которой ищем моды (передаётся через параметр -P)

type
  // Указатель на запись TModInfo
  PModInfo = ^TModInfo;

  // Структура для хранения информации о моде
  TModInfo = record
    ModName: string;      // Имя мода
    CurrentVer: string;   // Текущая версия (из локального ZIP)
    LatestVer: string;    // Последняя доступная версия (из API)
    ExpectedSHA1: string; // Ожидаемый SHA1 (из API, для проверки целостности)
  end;

  // Процедура для вывода сообщения с заданным цветом текста
  procedure Msg(const s: string; attr: Word);
  var
    savedAttr: Word;

  // Внутренняя процедура установки цвета текста и фона
    procedure SetTextColor(attr: Word);
    begin
      TextColor(attr and $0F);          // младшие 4 бита – цвет текста
      TextBackground((attr shr 4) and $07); // следующие 3 бита – цвет фона
    end;

  begin
    savedAttr := TextAttr;               // сохраняем текущие атрибуты
    SetTextColor(attr);                  // устанавливаем нужный цвет
    WriteLn(s);                           // выводим строку
    TextAttr := savedAttr;                // восстанавливаем атрибуты
  end;

  // Функция вычисления SHA1 для файла
  // Возвращает строку с хешем (40 символов) или пустую строку в случае ошибки
  function CalculateFileSHA1(const FileName: string): string;
  var
    SHA1Digest: TSHA1Digest;
  begin
    Result := '';
    if FileExists(FileName) then
    begin
      SHA1Digest := SHA1File(FileName, BUFFER_SIZE * 2); // читаем файл блоками по 128K
      Result := SHA1Print(SHA1Digest);                   // преобразуем в шестнадцатеричную строку
    end;
  end;

  // Функция извлечения файла из ZIP-архива в поток памяти
  // Параметры:
  //   fStream - поток, в который будет помещено содержимое файла
  //   fZipFilePath - путь к ZIP-архиву
  //   fUnpackedFile - имя файла внутри архива (можно использовать '*' для поиска в подпапках)
  // Возвращает True при успешном извлечении, иначе False
  function UnzipInStream(var fStream: TMemoryStream; const fZipFilePath, fUnpackedFile: string): Boolean;
  var
    UnZipper: unzFile;               // дескриптор открытого ZIP-архива
    zfinfos: unz_file_info_ptr;       // указатель на информацию о файле в архиве
    li_SizeRead: LongInt;             // количество прочитанных байт за один раз
    fMemorySize: LongWord;             // общий размер извлечённого файла
    FBuffer: array[0..BUFFER_SIZE - 1] of Byte; // буфер для чтения
    zipArchive, SearchingFile: String; // имена в ANSI-кодировке для unzOpen
    fMemory: TMemoryStream;            // временный поток для накопления данных
  begin
    Result := False;
    // Преобразуем имена в ANSI (требуется библиотекой unzip)
    zipArchive := UTF8Encode(fZipFilePath);
    // Добавляем '*' в начале, чтобы найти файл в любой подпапке (структура Factorio: modname_version/info.json)
    SearchingFile := UTF8Encode('*' + fUnpackedFile);
    fMemorySize := 0;
    UnZipper := unzOpen(PChar(zipArchive)); // открываем архив
    try
      // Ищем нужный файл внутри архива (по маске)
      if unzLocateFile(UnZipper, PAnsiChar(SearchingFile)) = UNZ_OK then
      begin
        unzOpenCurrentFile(UnZipper);          // открываем текущий файл для чтения
        New(zfinfos);                            // выделяем память под информацию о файле
        try
          // Получаем информацию о файле (не используется, но требуется для корректной работы)
          unzGetCurrentFileInfo(UnZipper, zfinfos, PAnsiChar(SearchingFile), SizeOf(SearchingFile), nil, 0, nil, 0);
          fMemory := TMemoryStream.Create;
          try
            // Читаем данные из архива блоками, пока не достигнем конца
            repeat
              li_SizeRead := unzReadCurrentFile(UnZipper, @FBuffer[0], SizeOf(FBuffer));
              if li_SizeRead <= 0 then
              begin
                Break;
              end;                          // конец файла или ошибка
              fMemory.WriteBuffer(FBuffer[0], li_SizeRead); // пишем во временный поток
              Inc(fMemorySize, li_SizeRead);
            until False;
            fMemory.Position := 0;
            if fMemorySize > 0 then
            begin
              fStream.CopyFrom(fMemory, fMemorySize); // копируем в итоговый поток
              Result := True;
            end;
          finally
            fMemory.Free;
          end;
        finally
          Dispose(zfinfos); // освобождаем память
        end;
      end;
    finally
      unzCloseCurrentFile(UnZipper); // закрываем текущий файл
      unzClose(UnZipper);             // закрываем архив
    end;
  end;

  // Проверяет, является ли файл корректным ZIP-архивом (проверка сигнатуры PK в начале)
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
          Result := (Sig[0] = $50) and (Sig[1] = $4B); // первые два байта = 'P','K'
        end;
      finally
        FS.Free;
      end;
    except
      Result := False; // при ошибке считаем файл невалидным
    end;
  end;

  // URL-кодирование строки (замена небезопасных символов на %XX)
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

  // Загружает данные из URL в поток (без сохранения в файл)
  // Возвращает True при успешной загрузке (размер > 0)
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
    hSession := GlobalInetSession; // используем глобальную сессию
    if hSession = nil then
    begin
      WriteLn('Failed to initialize internet connection');
      Exit;
    end;
    // Открываем URL
    hFile := InternetOpenUrl(hSession, PChar(fURL), nil, 0, dwFlags, 0);
    if hFile = nil then
    begin
      WriteLn('Failed to connect to server');
      Exit;
    end;
    try
      // Получаем HTTP-статус ответа
      StatusSize := SizeOf(StatusCode);
      if not HttpQueryInfo(hFile, HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER, @StatusCode, StatusSize, Index) then
      begin
        WriteLn('Failed to query HTTP status');
        Exit;
      end;
      // Проверяем, что статус успешный (2xx)
      if (StatusCode < 200) or (StatusCode >= 300) then
      begin
        WriteLn('HTTP error: ', StatusCode);
        Exit;
      end;
      // Читаем данные блоками
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
        end; // конец данных
        fDLStream.WriteBuffer(Buffer, BytesRead);
        Inc(DownloadedSize, BytesRead);
      end;
      // Если что-то скачали – успех
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

  // Загружает файл из URL и сохраняет на диск, отображает прогресс.
  // Возвращает SHA1 скачанного файла или пустую строку при ошибке.
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
    ContentLength: Int64 = 0;          // полный размер файла (если известен)
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

      // Получаем статус ответа
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

      // Пытаемся узнать размер файла из заголовка Content-Length
      ContentSize := SizeOf(ContentLengthDW);
      if HttpQueryInfo(hFile, HTTP_QUERY_CONTENT_LENGTH or HTTP_QUERY_FLAG_NUMBER, @ContentLengthDW, ContentSize, Index) then
      begin
        ContentLength := ContentLengthDW;
      end
      else
      begin
        ContentLength := -1;
      end; // размер неизвестен

      // Создаём файл для записи
      FS := TFileStream.Create(fSaveToFileName, fmCreate);
      // Читаем данные и отображаем прогресс
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

        // Вывод прогресса в консоль (одна строка обновляется)
        if ContentLength > 0 then
        begin
          if ContentLength < 1024 * 1024 then // размер в килобайтах
          begin
            Write(#13, '  Downloaded: ', DownloadedSize div 1024, ' KB / ', ContentLength div 1024, ' KB (',
              (DownloadedSize * 100) div ContentLength, '%)');
          end
          else // размер в мегабайтах
          begin
            Write(#13, '  Downloaded: ', DownloadedSize div (1024 * 1024), ' MB / ', ContentLength div (1024 * 1024),
              ' MB (', (DownloadedSize * 100) div ContentLength, '%)');
          end;
        end
        else
        begin
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
      WriteLn; // переход на новую строку после завершения прогресса
    finally
      if hFile <> nil then
      begin
        InternetCloseHandle(hFile);
      end;
      FreeAndNil(FS);
    end;

    // Проверяем результат скачивания
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
      Msg('  Download failed', $0C); // красный цвет
      if FileExists(fSaveToFileName) then
      begin
        DeleteFile(fSaveToFileName);
      end;
    end;
  end;

  // Извлекает имя мода из строки зависимости (пример: "? base >= 1.0" -> "base")
  // Удаляет кавычки, игнорирует необязательные/противоречивые префиксы, отсекает операторы сравнения.
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
    // Удаляем двойные кавычки (если есть)
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

    // Пропускаем начальные пробелы (уже Trim сделал, но оставим для совместимости)
    FirstNonSpace := 1;
    while (FirstNonSpace <= Length(s)) and (s[FirstNonSpace] = ' ') do
    begin
      Inc(FirstNonSpace);
    end;
    if FirstNonSpace > Length(s) then
    begin
      Exit;
    end;

    // Проверяем первый значимый символ на наличие специальных префиксов: ? ! ~ ( — такие зависимости игнорируем
    PrefixChar := s[FirstNonSpace];
    if PrefixChar in ['?', '!', '~', '('] then
    begin
      Exit;
    end;

    // Обработка скобок в начале: "(something) modname"
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

    // Ищем позицию первого оператора сравнения (>=, >, <=, <, =, ~)
    FoundOpPos := Length(s) + 1;
    for i := 0 to 5 do
    begin
      opPos := Pos(Operators[i], s);
      if (opPos > 0) and (opPos < FoundOpPos) then
      begin
        FoundOpPos := opPos;
      end;
    end;

    // Если нашли оператор, отсекаем всё после него
    if FoundOpPos <= Length(s) then
    begin
      s := Trim(Copy(s, 1, FoundOpPos - 1));
    end;

    // Отсекаем пробел и последующую часть (если оператор не найден, но есть пробел)
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

  // Процедура загрузки недостающего мода (зависимости) и добавления его в список.
  // Рекурсивно добавляет собственные зависимости этого мода в список fDependencies.
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
    URL := JSONInfoFull + UrlEncode(fModName);

    mJSONStream := TMemoryStream.Create;
    try
      // Получаем JSON с информацией о моде
      if not DownloadToStream(URL, mJSONStream) then
      begin
        WriteLn('  Failed to fetch mod information');
        Exit;
      end;

      mJSONStream.Position := 0;
      JSONFile := TJsonNode.Create;
      try
        JSONFile.LoadFromStream(mJSONStream);
        // Ищем массив "releases"
        ReleasesNode := JSONFile.Find('releases');
        if (ReleasesNode = nil) or (ReleasesNode.Kind <> nkArray) or (ReleasesNode.Count = 0) then
        begin
          WriteLn('  No releases found');
          Exit;
        end;

        // Берём последний релиз (самый новый)
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

        // Имя файла для сохранения
        DownloadedFile := GetStartDir + fModName + '_' + LatestVer + '.zip';
        // Скачиваем сам мод
        ComputedSHA1 := DownloadFile(ModDownloadURL + UrlEncode(fModName) + '/' + LatestVer + '.zip', DownloadedFile);

        if ComputedSHA1 = '' then
        begin
          WriteLn('  Download failed');
          Exit;
        end;

        // Проверяем SHA1, если он предоставлен API
        if (ExpectedSHA1 <> '') and (ComputedSHA1 <> ExpectedSHA1) then
        begin
          WriteLn('  SHA1 mismatch');
          DeleteFile(DownloadedFile);
          Exit;
        end;
        Msg('  Successfully downloaded and verified', $0A); // зелёный цвет

      finally
        JSONFile.Free;
      end;

      // Создаём запись о моде и добавляем в общий список
      New(pMod);
      pMod^.ModName := fModName;
      pMod^.CurrentVer := LatestVer;
      pMod^.LatestVer := LatestVer;
      pMod^.ExpectedSHA1 := ExpectedSHA1;
      fModInfo.Add(pMod);

      // Теперь извлекаем info.json из скачанного архива, чтобы найти его зависимости
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

              // Проверяем, не игнорируется ли мод
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

              // Проверяем, не установлен ли уже этот мод
              Found := False;
              for j := 0 to fModInfo.Count - 1 do
              begin
                if PModInfo(fModInfo.Items[j])^.ModName = fDepName then
                begin
                  Found := True;
                  Break;
                end;
              end;

              // Если уже есть в основном списке или уже в списке зависимостей – пропускаем
              if Found or (fDependencies.IndexOf(fDepName) >= 0) then
              begin
                Continue;
              end;

              // Добавляем новую зависимость в очередь на скачивание
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
  ShowVer: Boolean; // флаг вывода версии

begin
  // --- Начало программы: разбор параметров командной строки ---
  GetStartDir := ExtractFilePath(ParamStr(0)); // по умолчанию папка с exe
  Cmd := TCmdLine.Create;
  try
    Cmd.AddStrKey('P', '', 'PATH');        // ключ -P для указания папки с модами
    Cmd.AddBoolKey('V', False, 'version'); // ключ -V для вывода версии
    //Cmd.RequirePaths(0, 1);
    Cmd.Parse;
     // fmu.exe -p="some path"
    if Cmd.IsValid then
    begin
      // Если параметр -P указан, пытаемся использовать его
      GetStartDir := LowerCase(Cmd.StrKey['P']);
      if not DirectoryExists(GetStartDir, False) then
      begin
        GetStartDir := ExtractFilePath(ParamStr(0));
      end; // если папка не существует, возвращаемся к папке exe
      ShowVer := Cmd.BoolKey['V'];
    end
    else
    begin
      WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' [-V] [-P="path to folder"]');
    end;
  finally
    Cmd.Free;
    GetStartDir := IncludeTrailingPathDelimiter(GetStartDir); // добавляем разделитель в конец пути
  end;

  writeln();
  if ShowVer then
  begin
    Msg('F A C T O R I O   M O D   U P D A T E R   V E R S I O N   ' + VersionStr, $0B);  // голубой
  end
  else
  begin
    Msg('F A C T O R I O   M O D   U P D A T E R', $0B);
  end;
  writeln();

  ZipPath := GetStartDir + '*.zip';
  // --- Инициализация WinInet ---
  GlobalInetSession := InternetOpen(strUserAgentDefault, INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if GlobalInetSession = nil then
  begin
    WriteLn('Warning: Failed to initialize internet connection');
    WriteLn('Press Enter to exit...');
    ReadLn;
    Exit;
  end;

  // --- Создание списков ---
  ModInfo := TList.Create;          // список всех обработанных модов (PModInfo)
  ModList := TStringList.Create;    // список имён ZIP-файлов
  AllDependencies := TStringList.Create; // список имён недостающих зависимостей

  InfoStream := TMemoryStream.Create; // поток для временного хранения info.json и JSON-ответов
  try
    // --- Шаг 1: Поиск всех ZIP-файлов в рабочей папке ---
    if FindFirst(ZipPath, faAnyFile, sr) = 0 then
    begin
      repeat
        ModList.Add(sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;

    // --- Шаг 2: Обработка каждого найденного ZIP-файла ---
    for i := 0 to ModList.Count - 1 do
    begin
      InfoStream.Clear;
      InfoStream.Position := 0;
      InfoStream.Size := 0;

      if IsValidZipFile(GetStartDir + ModList[i]) then
      begin
        // Пытаемся извлечь info.json
        if UnzipInStream(InfoStream, GetStartDir + ModList[i], 'info.json') then
        begin
          InfoStream.Position := 0;
          JSONFile := TJsonNode.Create;
          try
            JSONFile.LoadFromStream(InfoStream);
            fName := JSONFile.Force('name').AsString;       // имя мода
            fVersion := JSONFile.Force('version').AsString; // версия из локального файла
            New(pMod);
            pMod^.ModName := fName;
            pMod^.CurrentVer := fVersion;
            pMod^.LatestVer := '';
            pMod^.ExpectedSHA1 := '';
            ModInfo.Add(pMod);

            // Обрабатываем зависимости из info.json
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

                // Проверка на игнорируемые моды
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
                  end; // добавляем в общий список, если ещё нет
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

    // Если не найдено ни одного мода – завершаем
    if ModInfo.Count > 0 then
    begin
      Msg('Checking for updates...', $0E);
    end // жёлтый
    else
    begin
      Msg('Nothing found... Skipping', $0C); // красный
      WriteLn('Press Enter to exit...');
      ReadLn;
      Exit;
    end;
    WriteLn();

    // --- Шаг 3: Проверка обновлений для каждого установленного мода ---
    for i := 0 to ModInfo.Count - 1 do
    begin
      pMod := PModInfo(ModInfo[i]);
      Msg(pMod^.ModName + ' (current version: ' + pMod^.CurrentVer + ')', $0F); // белый

      // Запрашиваем информацию о моде с сервера
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
          // Ищем массив releases и берём последний куст
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
            Msg('  Update available', $0E); // жёлтый
            CurrentFile := GetStartDir + pMod^.ModName + '_' + pMod^.CurrentVer + '.zip';
            DownloadedFile := GetStartDir + pMod^.ModName + '_' + pMod^.LatestVer + '.zip';

            // Скачиваем новую версию
            ComputedSHA1 := DownloadFile(ModDownloadURL + UrlEncode(pMod^.ModName) + '/' + pMod^.LatestVer + '.zip', DownloadedFile);

            if ComputedSHA1 <> '' then
            begin
              if pMod^.ExpectedSHA1 <> '' then
              begin
                if ComputedSHA1 = pMod^.ExpectedSHA1 then
                begin
                  Msg('  SHA1 check passed', $0A); // зелёный
                  DeleteFile(CurrentFile); // удаляем старый файл
                end
                else
                begin
                  Msg('  SHA1 mismatch!', $0C); // красный
                  WriteLn('    Expected: ', pMod^.ExpectedSHA1);
                  WriteLn('    Got:      ', ComputedSHA1);
                  DeleteFile(DownloadedFile); // удаляем битый файл
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
            Msg('  Already up to date', $0A); // зелёный
          end;
        end;
      end
      else
      begin
        Msg('Failed to fetch: ' + pMod^.ModName + '. Skipping.', $08);  // тёмно-серый
      end;
    end;

    // --- Шаг 4: Обработка недостающих зависимостей (рекурсивно) ---
    if Assigned(AllDependencies) and (AllDependencies.Count > 0) then
    begin
      // Очистка списка: удаляем пустые строки, дубликаты
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

      // Удаляем те зависимости, которые уже есть в ModInfo (уже установлены)
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

      // Рекурсивно скачиваем оставшиеся зависимости
      while AllDependencies.Count > 0 do
      begin
        fDepName := AllDependencies[0];
        AllDependencies.Delete(0);
        DownloadMissingMod(fDepName, ModInfo, AllDependencies);
      end;
    end;

  finally
    // Освобождение памяти
    for i := 0 to ModInfo.Count - 1 do
    begin
      Dispose(PModInfo(ModInfo[i]));
    end;
    ModList.Free;
    AllDependencies.Free;
    ModInfo.Free;
    InfoStream.Free;
  end;

  // Закрываем сессию WinInet
  if GlobalInetSession <> nil then
  begin
    InternetCloseHandle(GlobalInetSession);
  end;

  WriteLn('');
  Msg('All done.', $0A); // зелёный
  WriteLn('Press Enter to exit...');
  ReadLn;
end.

