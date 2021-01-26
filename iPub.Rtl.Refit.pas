unit iPub.Rtl.Refit;

interface

{$SCOPEDENUMS ON}

uses
  { Delphi }
  System.SysUtils,
  System.Rtti,
  System.TypInfo,
  System.JSON.Serializers,
  System.Generics.Collections,
  System.NetEncoding,
  System.Net.HttpClientComponent;

type
  // Exceptions
  EipRestService = class(Exception);
  EipRestServiceStatusCode = class(EipRestService)
  strict private
    FStatusCode: Integer;
    FStatusText: string;
  public
    constructor Create(const AStatusCode: Integer; const AStatusText, AMethodName: string);
    property StatusCode: Integer read FStatusCode;
    property StatusText: string read FStatusText;
  end;

  TipUrlAttribute = class abstract(TCustomAttribute)
  strict private
    FUrl: string;
  public
    constructor Create(const AUrl: string);
    property Url: string read FUrl;
  end;

  TBodyContentKind = (Default, MultipartFormData);

  // Parameter attribute
  BodyAttribute = class(TCustomAttribute)
  strict private
    FBodyType: TBodyContentKind;
  public
    constructor Create(const ABodyType: TBodyContentKind = TBodyContentKind.Default);
    property BodyType: TBodyContentKind read FBodyType;
  end;

  // Parameter attribute
  HeaderAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  // Methods attributes - Method kind and relative url
  GetAttribute = class(TipUrlAttribute);
  PostAttribute = class(TipUrlAttribute);
  DeleteAttribute = class(TipUrlAttribute);
  OptionsAttribute = class(TipUrlAttribute);
  TraceAttribute = class(TipUrlAttribute);
  HeadAttribute = class(TipUrlAttribute);
  PutAttribute = class(TipUrlAttribute);
  PatchAttribute = class(TipUrlAttribute);

  // Method and type attribute
  HeadersAttribute = class(HeaderAttribute)
  strict private
    FValue: string;
  public
    constructor Create(const AName, AValue: string);
    property Value: string read FValue;
  end;

  // Types attributes
  BaseUrlAttribute = class(TipUrlAttribute);

  // The rest api interface must be descendent of IipRestApi or inside the {$M+} directive
  {$M+}IipRestApi = interface end;{$M-}

  // We want to keep the unit compact
  // so any consumer could use only this unit for registring converters
  TJsonConverter = System.JSON.Serializers.TJsonConverter;

  { IApiJsonSerializer }

  // This is meant to be used to set a custom serializer
  TApiJsonSerializer = class
  public
    function Deserialize(const AJson: string; const ATypeInfo: PTypeInfo): TValue; virtual; abstract;
    function Serialize(const AValue: TValue): string; virtual; abstract;
    function GetConverters: TList<TJsonConverter>; virtual; abstract;
    function SupportsConvertorsRegistration: Boolean; virtual; abstract;
    property Converters: TList<TJsonConverter> read GetConverters;
  end;

  { TipRestService }

  // This class and the rest api interfaces created by this class are thread safe.
  // As the connections are synchronous, the ideal is to call the api functions in
  // the background. If you have multiple threads you can also create multiple rest
  // api interfaces for the same api, each one will have a different connection.
  TipRestService = class
  protected
    type
      TJsonConverterClass = class of TJsonConverter;
      TApiJsonSerializerClass = class of TApiJsonSerializer;
  protected
    procedure MakeFor(const ATypeInfo: Pointer; const AClient: TNetHTTPClient; const ABaseUrl: string; const AThreadSafe: Boolean; out AResult); virtual; abstract;
  public
    function &For<T: IInterface>: T; overload;
    function &For<T: IInterface>(const ABaseUrl: string): T; overload;
    // You can pass your own client, but you will be responsible for giving the client free after use the rest api interface returned
    function &For<T: IInterface>(const AClient: TNetHTTPClient; const ABaseUrl: string = ''; AThreadSafe: Boolean = True): T; overload;
    procedure RegisterConverters(const AConverterClasses: TArray<TJsonConverterClass>); virtual; abstract;
    procedure SetJsonSerializer(const AApiJsonSerializerClass: TApiJsonSerializerClass); virtual; abstract;
  end;

var
  GRestService: TipRestService;

implementation

uses
  { Delphi }
  System.Classes,
  System.Character,
  System.SyncObjs,
  System.JSON.Types,
  System.JSON.Writers,
  System.JSON.Readers,
  System.Net.HttpClient,
  System.Net.Mime,
  System.Net.URLClient,
  idGlobal;

type
  TMethodKind = (Get, Post, Delete, Options, Trace, Head, Put, Patch);

  { TRttiUtils }

  TRttiUtils = class sealed
  public
    class function Attributes<T: TCustomAttribute>(const AAttributes: TArray<TCustomAttribute>): TArray<T>; static;
    class function HasAttribute<T: TCustomAttribute>(const AAttributes: TArray<TCustomAttribute>): Boolean; overload; static;
    class function HasAttribute<T: TCustomAttribute>(const AAttributes: TArray<TCustomAttribute>; out AAttribute: T): Boolean; overload; static;
    class function IsDateTime(const ATypeInfo: PTypeInfo): Boolean; static;
  end;

  { TDefaultApiJsonSerializer }

  TDefaultApiJsonSerializer = class(TApiJsonSerializer)
  private
    type
      TSJsonSerializer = class(System.JSON.Serializers.TJsonSerializer) end; // To expose protected methods? The S is just to diff the name
  strict private
    FJsonSerializer: TSJsonSerializer;
    function GetSerializer: TSJsonSerializer;
    property JsonSerializer: TSJsonSerializer read GetSerializer;
  public
    destructor Destroy; override;
    function GetConverters: TList<TJsonConverter>; override;
    function Deserialize(const AJson: string; const ATypeInfo: PTypeInfo): TValue; override;
    function Serialize(const AValue: TValue): string; override;
    function SupportsConvertorsRegistration: Boolean; override;

    property Converters:  TList<TJsonConverter> read GetConverters;
  end;

  { TipJsonEnumConverter }

  TipJsonEnumConverter = class(TJsonConverter)
  public
    function CanConvert(ATypeInf: PTypeInfo): Boolean; override;
    function ReadJson(const AReader: TJsonReader; ATypeInf: PTypeInfo; const AExistingValue: TValue;
      const ASerializer: TJsonSerializer): TValue; override;
    procedure WriteJson(const AWriter: TJsonWriter; const AValue: TValue; const ASerializer: TJsonSerializer); override;
  end;

  { TipJsonSetConverter }

  TipJsonSetConverter = class(TJsonConverter)
  public
    function CanConvert(ATypeInf: PTypeInfo): Boolean; override;
    function ReadJson(const AReader: TJsonReader; ATypeInf: PTypeInfo; const AExistingValue: TValue;
      const ASerializer: TJsonSerializer): TValue; override;
    procedure WriteJson(const AWriter: TJsonWriter; const AValue: TValue; const ASerializer: TJsonSerializer); override;
  end;

  { TApiParam }

  TApiParam = class
  strict private
    FArgIndex: Integer;
    FIsDateTime: Boolean;
    FKind: TTypeKind;
    FName: string;
  public
    constructor Create(const AArgIndex: Integer; const AIsDateTime: Boolean; const AKind: TTypeKind; const AName: string);
    property ArgIndex: Integer read FArgIndex;
    property IsDateTime: Boolean read FIsDateTime;
    property Kind: TTypeKind read FKind;
    property Name: string read FName;
  end;

  { TApiProperty }

  TApiProperty = class
  strict private
    FDefaultValue: TValue;
    FGetMethod: Pointer;
    FIndex: Integer;
    FIsDateTime: Boolean;
    FKind: TTypeKind;
    FName: string;
    FSetMethod: Pointer;
  public
    constructor Create(const AGetMethod, ASetMethod: TRttiMethod; const AIndex: Integer);
    procedure CallMethod(const AMethodHandle: Pointer; const AArgs: TArray<TValue>;
      var AResult: TValue; var AProperties: TArray<TValue>);
    function GetValue(const AProperties: TArray<TValue>): TValue;
    property DefaultValue: TValue read FDefaultValue;
    property GetMethod: Pointer read FGetMethod;
    property IsDateTime: Boolean read FIsDateTime;
    property Kind: TTypeKind read FKind;
    property Name: string read FName;
    property SetMethod: Pointer read FSetMethod;
  end;

  { TApiMethod }

  TApiMethod = class
  strict private
    FBodyArgIndex: Integer;
    FBodyIsDateTime: Boolean;
    FBodyKind: TTypeKind;
    FBodyContentKind: TBodyContentKind;
    FKind: TMethodKind;
    FHeaderParameters: TArray<TApiParam>;
    FHeaders: TNameValueArray;
    FParameters: TArray<TApiParam>;
    FQualifiedName: string;
    FRelativeUrl: string;
    FResultKind: TTypeKind;
    FResultIsDateTime: Boolean;
    FResultTypeInfo: PTypeInfo;
  public
    constructor Create(const AQualifiedName: string; const ATypeHeaders: TNameValueArray; const ARttiParameters: TArray<TRttiParameter>; const ARttiReturnType: TRttiType; const AAttributes: TArray<TCustomAttribute>);
    destructor Destroy; override;
    procedure CallApi(const AClient: TNetHTTPClient; const ABaseUrl: string;
      const AJsonSerializer: TApiJsonSerializer; const AArgs: TArray<TValue>;
      var AResult: TValue; const AProperties: TObjectList<TApiProperty>;
      const APropertiesValues: TArray<TValue>);
  end;

  { IApiType }

  IApiType = interface
    function GetBaseUrl: string;
    function GetIID: TGUID;
    function GetMethods: TObjectDictionary<Pointer, TApiMethod>;
    function GetProperties: TObjectList<TApiProperty>;
    function GetPropertiesMethods: TDictionary<Pointer, TApiProperty>;
    function GetTypeInfo: PTypeInfo;
    property BaseUrl: string read GetBaseUrl;
    property IID: TGUID read GetIID;
    property Methods: TObjectDictionary<Pointer, TApiMethod> read GetMethods;
    property Properties: TObjectList<TApiProperty> read GetProperties;
    property PropertiesMethods: TDictionary<Pointer, TApiProperty> read GetPropertiesMethods;
    property TypeInfo: PTypeInfo read GetTypeInfo;
  end;

  { TApiType }

  TApiType = class(TInterfacedObject, IApiType)
  strict private
    FBaseUrl: string;
    FIID: TGUID;
    FMethods: TObjectDictionary<Pointer, TApiMethod>;
    FProperties: TObjectList<TApiProperty>;
    FPropertiesMethods: TDictionary<Pointer, TApiProperty>;
    FTypeInfo: PTypeInfo;
    function GetBaseUrl: string;
    function GetIID: TGUID;
    function GetMethods: TObjectDictionary<Pointer, TApiMethod>;
    function GetProperties: TObjectList<TApiProperty>;
    function GetPropertiesMethods: TDictionary<Pointer, TApiProperty>;
    function GetTypeInfo: PTypeInfo;
  public
    constructor Create(const ABaseUrl: string; const AIID: TGUID; const AMethods: TObjectDictionary<Pointer, TApiMethod>;
      const AProperties: TObjectList<TApiProperty>; const APropertiesMethods: TDictionary<Pointer, TApiProperty>; const ATypeInfo: PTypeInfo);
    destructor Destroy; override;
  end;

  { TApiVirtualInterface }

  TApiVirtualInterface = class(TVirtualInterface)
  strict private
    FApiType: IApiType;
    FBaseUrl: string;
    FClient: TNetHTTPClient;
    FClientOwn: Boolean;
    FJsonSerializer: TApiJsonSerializer;
    FLocker: TCriticalSection;
    FProperties: TArray<TValue>;
    procedure CallMethod(const AMethodHandle: Pointer; const AArgs: TArray<TValue>; var AResult: TValue);
  public
    constructor Create(const AApiType: IApiType; const AConverters: TArray<TJsonConverter>; const AClient: TNetHTTPClient; const AJsonSerializerClass: TipRestService.TApiJsonSerializerClass; const ABaseUrl: string; const AThreadSafe: Boolean);
    destructor Destroy; override;
  end;

  { TRestServiceManager }

  TRestServiceManager = class(TipRestService)
  strict private
    FApiTypeMap: TDictionary<PTypeInfo, IApiType>;
    FConvertersList: TObjectList<TJsonConverter>;
    FApiJsonSerializerClass: TipRestService.TApiJsonSerializerClass;
    {$IF CompilerVersion >= 34.0}
    FLock: TLightweightMREW;
    {$ELSE}
    FLock: TCriticalSection;
    {$ENDIF}
    function CreateApiType(const ATypeInfo: PTypeInfo): IApiType;
  protected
    procedure MakeFor(const ATypeInfo: Pointer; const AClient: TNetHTTPClient; const ABaseUrl: string; const AThreadSafe: Boolean; out AResult); override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure RegisterConverters(const AConverterClasses: TArray<TipRestService.TJsonConverterClass>); override;
    procedure SetJsonSerializer(const AApiJsonSerializerClass: TipRestService.TApiJsonSerializerClass); override;
  end;

const
  CMethodsWithBodyContent: set of TMethodKind = [TMethodKind.Post, TMethodKind.Put, TMethodKind.Patch];
  CMethodsWithoutResponseContent: set of TMethodKind = [TMethodKind.Head];
  CSupportedResultKind: set of TTypeKind = [TTypeKind.tkUString, TTypeKind.tkClass, TTypeKind.tkMRecord, TTypeKind.tkRecord, TTypeKind.tkDynArray];

{ EipRestServiceStatusCode }

constructor EipRestServiceStatusCode.Create(const AStatusCode: Integer;
  const AStatusText, AMethodName: string);
begin
  inherited CreateFmt('Unexpected response calling %s method (code: %d; text: %s)', [AMethodName, AStatusCode, AStatusText]);
  FStatusCode := AStatusCode;
  FStatusText := AStatusText;
end;

{ TipUrlAttribute }

constructor TipUrlAttribute.Create(const AUrl: string);
begin
  inherited Create;
  FUrl := AUrl;
end;

{ HeaderAttribute }

constructor HeaderAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

{ HeadersAttribute }

constructor HeadersAttribute.Create(const AName, AValue: string);
begin
  inherited Create(AName);
  FValue := AValue;
end;

{ BodyAttribute }

constructor BodyAttribute.Create(const ABodyType: TBodyContentKind);
begin
  inherited Create;
  FBodyType := ABodyType;
end;

{ TipRestService }

function TipRestService.&For<T>: T;
begin
  MakeFor(TypeInfo(T), nil, '', True, Result);
end;

function TipRestService.&For<T>(const ABaseUrl: string): T;
begin
  MakeFor(TypeInfo(T), nil, ABaseUrl, True, Result);
end;

function TipRestService.&For<T>(const AClient: TNetHTTPClient;
  const ABaseUrl: string; AThreadSafe: Boolean): T;
begin
  MakeFor(TypeInfo(T), AClient, ABaseUrl, AThreadSafe, Result);
end;

{ TRttiUtils }

class function TRttiUtils.Attributes<T>(
  const AAttributes: TArray<TCustomAttribute>): TArray<T>;
var
  I: Integer;
  LCount: Integer;
begin
  LCount := 0;
  SetLength(Result, Length(AAttributes));
  for I := 0 to Length(AAttributes)-1 do
    if AAttributes[I] is T then
    begin
      Result[LCount] := T(AAttributes[I]);
      Inc(LCount);
    end;
  if LCount <> Length(Result) then
    SetLength(Result, LCount);
end;

class function TRttiUtils.HasAttribute<T>(
  const AAttributes: TArray<TCustomAttribute>): Boolean;
var
  I: Integer;
begin
  for I := 0 to Length(AAttributes)-1 do
    if AAttributes[I] is T then
      Exit(True);
  Result := False;
end;

class function TRttiUtils.HasAttribute<T>(
  const AAttributes: TArray<TCustomAttribute>; out AAttribute: T): Boolean;
var
  I: Integer;
begin
  for I := 0 to Length(AAttributes)-1 do
    if AAttributes[I] is T then
    begin
      AAttribute := T(AAttributes[I]);
      Exit(True);
    end;
  AAttribute := nil;
  Result := False;
end;

class function TRttiUtils.IsDateTime(const ATypeInfo: PTypeInfo): Boolean;
begin
  Result := (ATypeInfo = System.TypeInfo(TDate)) or
    (ATypeInfo = System.TypeInfo(TDateTime)) or (ATypeInfo = System.TypeInfo(TTime));
end;

{ TDefaultApiJsonSerializer }

destructor TDefaultApiJsonSerializer.Destroy;
begin
  if Assigned(FJsonSerializer) then
    FJsonSerializer.Free;
  inherited;
end;

function TDefaultApiJsonSerializer.GetConverters: TList<TJsonConverter>;
begin
  Result := JsonSerializer.Converters;
end;

function TDefaultApiJsonSerializer.GetSerializer: TSJsonSerializer;
begin
  // It will require the use of Rtti to call the right constructor
  // https://stackoverflow.com/questions/791069/how-can-i-create-an-delphi-object-from-a-class-reference-and-ensure-constructor
  // So I would rather do it like this, because it will be needed for this serializer
  // see TApiVirtualInterface.Create() for where it is supposed to call the right constructor
  if not Assigned(FJsonSerializer) then
    FJsonSerializer := TSJsonSerializer.Create;
  Result := FJsonSerializer;
end;

function TDefaultApiJsonSerializer.Deserialize(const AJson: string;
  const ATypeInfo: PTypeInfo): TValue;
var
  LStringReader: TStringReader;
  LJsonReader: TJsonTextReader;
begin
  LStringReader := TStringReader.Create(AJson);
  try
    LJsonReader := TJsonTextReader.Create(LStringReader);
    LJsonReader.DateTimeZoneHandling := JsonSerializer.DateTimeZoneHandling;
    LJsonReader.DateParseHandling := JsonSerializer.DateParseHandling;
    LJsonReader.MaxDepth := JsonSerializer.MaxDepth;
    try
      Result := JsonSerializer.InternalDeserialize(LJsonReader, ATypeInfo);
    finally
      LJsonReader.Free;
    end;
  finally
    LStringReader.Free;
  end;
end;

function TDefaultApiJsonSerializer.Serialize(const AValue: TValue): string;
var
  LStringBuilder: TStringBuilder;
  LStringWriter: TStringWriter;
  LJsonWriter: TJsonTextWriter;
begin
  LStringBuilder := TStringBuilder.Create($7FFF);
  LStringWriter := TStringWriter.Create(LStringBuilder);
  try
    LJsonWriter := TJsonTextWriter.Create(LStringWriter);
    LJsonWriter.FloatFormatHandling := JsonSerializer.FloatFormatHandling;
    LJsonWriter.DateFormatHandling := JsonSerializer.DateFormatHandling;
    LJsonWriter.DateTimeZoneHandling := JsonSerializer.DateTimeZoneHandling;
    LJsonWriter.StringEscapeHandling := JsonSerializer.StringEscapeHandling;
    LJsonWriter.Formatting := JsonSerializer.Formatting;
    try
      JsonSerializer.InternalSerialize(LJsonWriter, AValue);
    finally
      LJsonWriter.Free;
    end;
    Result := LStringBuilder.ToString(True);
  finally
    LStringWriter.Free;
    LStringBuilder.Free;
  end;
end;

function TDefaultApiJsonSerializer.SupportsConvertorsRegistration: Boolean;
begin
  Result := True;
end;

{ TipJsonEnumConverter }

function TipJsonEnumConverter.CanConvert(ATypeInf: PTypeInfo): Boolean;
begin
  Result := (ATypeInf.Kind = TTypeKind.tkEnumeration) and (ATypeInf <> TypeInfo(Boolean)) and (ATypeInf.TypeData <> nil);
end;

function TipJsonEnumConverter.ReadJson(const AReader: TJsonReader;
  ATypeInf: PTypeInfo; const AExistingValue: TValue;
  const ASerializer: TJsonSerializer): TValue;
begin
  Result := AReader.Value;
  if not Result.IsOrdinal then
    Result := TValue.FromOrdinal(ATypeInf, GetEnumValue(ATypeInf, Result.AsString));
end;

procedure TipJsonEnumConverter.WriteJson(const AWriter: TJsonWriter;
  const AValue: TValue; const ASerializer: TJsonSerializer);
begin
  if (AValue.AsOrdinal < AValue.TypeData.MinValue) or (AValue.AsOrdinal > AValue.TypeData.MaxValue) then
    AWriter.WriteNull
  else
    AWriter.WriteValue(GetEnumName(AValue.TypeInfo, AValue.AsOrdinal));
end;

{ TipJsonSetConverter }

function TipJsonSetConverter.CanConvert(ATypeInf: PTypeInfo): Boolean;
begin
  Result := (ATypeInf.Kind = TTypeKind.tkSet);
end;

function TipJsonSetConverter.ReadJson(const AReader: TJsonReader;
  ATypeInf: PTypeInfo; const AExistingValue: TValue;
  const ASerializer: TJsonSerializer): TValue;
var
  LSetString: string;
  LString: string;
begin
  if AReader.TokenType = TJsonToken.StartArray then
  begin
    LSetString := '';
    while AReader.Read and (AReader.TokenType <> TJsonToken.EndArray) do
    begin
      Result := AReader.Value;
      if AReader.TokenType = TJsonToken.String then
        LString := Result.AsString
      else
        LString := Result.AsOrdinal.ToString;
      if LString.IsEmpty then
        Continue;
      if not LSetString.IsEmpty then
        LSetString := LSetString + ',';
      LSetString := LSetString + LString;
    end;
    Result := AExistingValue;
    StringToSet(Result.TypeInfo, LSetString, Result.GetReferenceToRawData);
  end
  else
    Result := AReader.Value;
end;

procedure TipJsonSetConverter.WriteJson(const AWriter: TJsonWriter;
  const AValue: TValue; const ASerializer: TJsonSerializer);
var
  LStrings: TArray<string>;
  LString: string;
begin
  AWriter.WriteStartArray;
  LStrings := SetToString(AValue.TypeInfo, AValue.GetReferenceToRawData).Split([',']);
  for LString in LStrings do
    AWriter.WriteValue(LString);
  AWriter.WriteEndArray;
end;

{ TApiParam }

constructor TApiParam.Create(const AArgIndex: Integer; const AIsDateTime: Boolean; const AKind: TTypeKind;
  const AName: string);
begin
  inherited Create;
  FArgIndex := AArgIndex;
  FIsDateTime := AIsDateTime;
  FKind := AKind;
  FName := AName;
end;

{ TApiMethod }

procedure TApiMethod.CallApi(const AClient: TNetHTTPClient; const ABaseUrl: string;
  const AJsonSerializer: TApiJsonSerializer; const AArgs: TArray<TValue>;
  var AResult: TValue; const AProperties: TObjectList<TApiProperty>;
  const APropertiesValues: TArray<TValue>);

  function GetStringValue(const AValue: TValue; const ATypeKind: TTypeKind; const AIsDateTime: Boolean): string; inline;
  begin
    case ATypeKind of
      TTypeKind.tkFloat:
        begin
          if AIsDateTime then
            Result := AValue.ToString
          else
            Result := AValue.AsExtended.ToString(TFormatSettings.Invariant);
        end;
    else
      Result := AValue.ToString;
    end;
  end;

var
  I: Integer;
  J: Integer;
  LRelativeUrl: string;
  LArgumentAsString: string;
  LResponse: IHTTPResponse;
  LResponseContent: TBytesStream;
  LBodyContent: TMemoryStream;
  LResponseString: string;
  LHeaders: TNameValueArray;
  LStr: string;
  LHasABody: Boolean;
  LContentHeaderSet: Boolean;
  LMultipartFormData: TMultipartFormData;
begin
  LHeaders := Copy(FHeaders);
  SetLength(LHeaders, Length(LHeaders) + Length(FHeaderParameters));
  for I := 0 to Length(FHeaderParameters)-1 do
    LHeaders[Length(FHeaders) + I] := TNameValuePair.Create(FHeaderParameters[I].Name,
      GetStringValue(AArgs[FHeaderParameters[I].ArgIndex], FHeaderParameters[I].Kind, FHeaderParameters[I].IsDateTime));
  // Find and filling the masks of header values
  for I := 0 to Length(FHeaders)-1 do
  begin
    LStr := LHeaders[I].Value.ToLower;
    for J := 0 to Length(FParameters)-1 do
    begin
      if LStr.Contains('{' + FParameters[J].Name.ToLower + '}') then
      begin
        LArgumentAsString := GetStringValue(AArgs[FParameters[J].ArgIndex], FParameters[J].Kind, FParameters[J].IsDateTime);
        LHeaders[I].Value := LHeaders[I].Value.Replace('{' + FParameters[J].Name + '}', TNetEncoding.URL.EncodeForm(LArgumentAsString), [rfReplaceAll, rfIgnoreCase]);
      end;
      if LStr.Contains('{a' + FParameters[J].Name.ToLower + '}') then
      begin
        LArgumentAsString := GetStringValue(AArgs[FParameters[J].ArgIndex], FParameters[J].Kind, FParameters[J].IsDateTime);
        LHeaders[I].Value := LHeaders[I].Value.Replace('{a' + FParameters[J].Name + '}', TNetEncoding.URL.EncodeForm(LArgumentAsString), [rfReplaceAll, rfIgnoreCase]);
      end;
    end;
    for J := 0 to AProperties.Count-1 do
    begin
      if LStr.Contains('{' + AProperties[J].Name + '}') then
      begin
        LArgumentAsString := GetStringValue(AProperties[J].GetValue(APropertiesValues), AProperties[J].Kind, AProperties[J].IsDateTime);
        LHeaders[I].Value := LHeaders[I].Value.Replace('{' + AProperties[J].Name + '}', TNetEncoding.URL.EncodeForm(LArgumentAsString), [rfReplaceAll, rfIgnoreCase]);
      end;
    end;
  end;
  LRelativeUrl := FRelativeUrl;
  for I := 0 to Length(FParameters)-1 do
  begin
    LArgumentAsString := GetStringValue(AArgs[FParameters[I].ArgIndex], FParameters[I].Kind, FParameters[I].IsDateTime);
    LRelativeUrl := LRelativeUrl.Replace('{' + FParameters[I].Name + '}', TNetEncoding.URL.EncodeForm(LArgumentAsString), [rfReplaceAll]);
  end;
  LStr := LRelativeUrl.ToLower;
  for I := 0 to AProperties.Count-1 do
  begin
    if LStr.Contains('{' + AProperties[I].Name + '}') then
    begin
      LArgumentAsString := GetStringValue(AProperties[I].GetValue(APropertiesValues), AProperties[I].Kind, AProperties[I].IsDateTime);
      LRelativeUrl := LRelativeUrl.Replace('{' + AProperties[I].Name + '}', TNetEncoding.URL.EncodeForm(LArgumentAsString), [rfReplaceAll, rfIgnoreCase]);
    end;
  end;

  LBodyContent := nil;
  LHasABody := FKind in CMethodsWithBodyContent;

  try
    if LHasABody then
    begin
      LBodyContent := TMemoryStream.Create;

      case FBodyContentKind of
        TBodyContentKind.Default:
        begin
          if FBodyArgIndex > -1 then
          begin
            if FBodyKind in [TTypeKind.tkClass, TTypeKind.tkInterface, TTypeKind.tkMRecord, TTypeKind.tkRecord] then
              WriteStringToStream(LBodyContent, AJsonSerializer.Serialize(AArgs[FBodyArgIndex]), IndyTextEncoding_UTF8)
            else
              WriteStringToStream(LBodyContent, GetStringValue(AArgs[FBodyArgIndex], FBodyKind, FBodyIsDateTime), IndyTextEncoding_UTF8);
          end
          else
            LBodyContent.Clear;
        end;
        TBodyContentKind.MultipartFormData:
        begin
          if AArgs[FBodyArgIndex].IsInstanceOf(TMultipartFormData) then
          begin
            LMultipartFormData := TMultipartFormData(AArgs[FBodyArgIndex].AsObject);
            LMultipartFormData.Stream.Position := 0;
            // You can optimize by using the LMultipartFormData.Stream directly but you need to handle the flow of freeing LBodyContent
            LBodyContent.CopyFrom(LMultipartFormData.Stream, LMultipartFormData.Stream.Size);

            // make sure content type is valid
            LContentHeaderSet := False;
            for I := Low(LHeaders) to High(LHeaders) do
            begin
              if LHeaders[I].Name = 'Content-Type' then
              begin
                LHeaders[I].Value := LMultipartFormData.MimeTypeHeader;
                LContentHeaderSet := True;
                Break;
              end;
            end;

            if not LContentHeaderSet then
            begin
              LHeaders := LHeaders + [TNameValuePair.Create('Content-Type', LMultipartFormData.MimeTypeHeader)];
            end;
          end
          else
            raise EipRestService.Create('Body content kind set to "TBodyContentKind.MultipartFormData" but content is not of "TMultipartFormData"');
        end;
      else
        raise EipRestService.Create('Unkown body content kind!!');
      end;

      LBodyContent.Position := 0;
    end;

    LRelativeUrl := ABaseUrl + LRelativeUrl;

    if FKind in CMethodsWithoutResponseContent then
      LResponseContent := nil
    else
      LResponseContent := TBytesStream.Create;
    try
      case FKind of
        TMethodKind.Get: LResponse := AClient.Get(LRelativeUrl, LResponseContent, LHeaders);
        TMethodKind.Post: LResponse := AClient.Post(LRelativeUrl, LBodyContent, LResponseContent, LHeaders);
        TMethodKind.Delete: LResponse := AClient.Delete(LRelativeUrl, LResponseContent, LHeaders);
        TMethodKind.Options: LResponse := AClient.Options(LRelativeUrl, LResponseContent, LHeaders);
        TMethodKind.Trace: LResponse := AClient.Trace(LRelativeUrl, LResponseContent, LHeaders);
        TMethodKind.Head: LResponse := AClient.Head(LRelativeUrl, LHeaders);
        TMethodKind.Put: LResponse := AClient.Put(LRelativeUrl, LBodyContent, LResponseContent, LHeaders);
        TMethodKind.Patch: LResponse := AClient.Patch(LRelativeUrl, LBodyContent, LResponseContent, LHeaders);
      else
        Assert(False);
      end;
      if (LResponse.StatusCode < 200) or (LResponse.StatusCode > 299) then
        raise EipRestServiceStatusCode.Create(LResponse.StatusCode, LResponse.StatusText, FQualifiedName);
      if Assigned(LResponseContent) and (FResultKind <> TTypeKind.tkUnknown) then
      begin
        if LResponse.ContentCharSet.ToLower <> 'utf-8' then
          raise EipRestService.CreateFmt('Unsupported charset %s received from %s method', [LResponse.ContentCharSet, FQualifiedName]);
        LResponseString := TEncoding.UTF8.GetString(LResponseContent.Bytes, 0, LResponseContent.Size);

        case FResultKind of
          TTypeKind.tkUString: AResult := LResponseString;
          TTypeKind.tkDynArray,
          TTypeKind.tkClass,
          TTypeKind.tkMRecord,
          TTypeKind.tkRecord: AResult := AJsonSerializer.Deserialize(LResponseString, FResultTypeInfo);
        else
          Assert(False);
        end;
      end;
    finally
      if Assigned(LResponseContent) then
        LResponseContent.Free;
    end;
  finally
    if Assigned(LBodyContent) then
      LBodyContent.Free;
  end;
end;

constructor TApiMethod.Create(const AQualifiedName: string;
  const ATypeHeaders: TNameValueArray; const ARttiParameters: TArray<TRttiParameter>;
  const ARttiReturnType: TRttiType; const AAttributes: TArray<TCustomAttribute>);

  function IsBodyParam(const ARttiParameter: TRttiParameter; out ABodyContentKind: TBodyContentKind): Boolean;
  var
    LBodyAttribute: BodyAttribute;
    LName: string;
  begin
    LName := ARttiParameter.Name.ToLower;

    Result := (LName = 'abody') or
      (LName = 'body') or
      (LName = 'bodycontent') or
      (LName = 'abodycontent') or
      (LName = 'content') or
      (LName = 'acontent');

    if not Result then
    begin
      Result := TRttiUtils.HasAttribute<BodyAttribute>(ARttiParameter.GetAttributes, LBodyAttribute);
      if Result then
        ABodyContentKind := LBodyAttribute.BodyType;
    end
    else
    begin
      // you can declare the body of type TMultipartFormData with out the attribute
      if ARttiParameter.ParamType.Handle.Name = 'TMultipartFormData' then
      begin
        ABodyContentKind := TBodyContentKind.MultipartFormData;
      end
      else
      begin
        ABodyContentKind := TBodyContentKind.Default;
      end;
    end;
  end;

  function FixName(const AName: string; var ARelativeUrl: string): string;
  begin
    if (Length(AName) > 1) and (AName.Chars[0].ToLower = 'a') and (AName.Chars[1].IsUpper) then
    begin
      Result := AName.Substring(1).ToLower;
      // This is just to force the parameter to lower case, because in call we will ignore the case to improve performance
      ARelativeUrl := ARelativeUrl.Replace('{' + Result + '}', '{' + Result + '}', [rfReplaceAll, rfIgnoreCase]);
      ARelativeUrl := ARelativeUrl.Replace('{a' + Result + '}', '{' + Result + '}', [rfReplaceAll, rfIgnoreCase]);
    end
    else
    begin
      Result := AName.ToLower;
      // This is just to force the parameter to lower case, because in call we will ignore the case to improve performance
      ARelativeUrl := ARelativeUrl.Replace('{' + AName + '}', '{' + Result + '}', [rfReplaceAll, rfIgnoreCase]);
    end;
  end;

var
  LParametersCount: Integer;
  LFoundMethodKind: Boolean;
  LIsDateTime: Boolean;
  LHeadersAttributes: TArray<HeadersAttribute>;
  LHeaderAttribute: HeaderAttribute;
  I: Integer;
begin
  inherited Create;
  FQualifiedName := AQualifiedName;
  LHeadersAttributes := TRttiUtils.Attributes<HeadersAttribute>(AAttributes);
  SetLength(FHeaders, Length(LHeadersAttributes));
  for I := 0 to Length(LHeadersAttributes)-1 do
    FHeaders[I] := TNameValuePair.Create(LHeadersAttributes[I].Name, LHeadersAttributes[I].Value);
  FHeaders := ATypeHeaders + FHeaders;

  LFoundMethodKind := False;
  for I := 0 to Length(AAttributes)-1 do
  begin
    if AAttributes[I] is TipUrlAttribute then
    begin
      if AAttributes[I] is GetAttribute then
        FKind := TMethodKind.Get
      else if AAttributes[I] is PostAttribute then
        FKind := TMethodKind.Post
      else if AAttributes[I] is DeleteAttribute then
        FKind := TMethodKind.Delete
      else if AAttributes[I] is OptionsAttribute then
        FKind := TMethodKind.Options
      else if AAttributes[I] is TraceAttribute then
        FKind := TMethodKind.Trace
      else if AAttributes[I] is HeadAttribute then
        FKind := TMethodKind.Head
      else if AAttributes[I] is PutAttribute then
        FKind := TMethodKind.Put
      else if AAttributes[I] is PatchAttribute then
        FKind := TMethodKind.Patch
      else
        Continue;
      FRelativeUrl := TipUrlAttribute(AAttributes[I]).Url.Trim;
      if not FRelativeUrl.StartsWith('/') then
        FRelativeUrl := '/' + FRelativeUrl;
      if Length(FRelativeUrl) = 1 then
        raise EipRestService.CreateFmt('Invalid relative url in method %s', [FQualifiedName]);
      LFoundMethodKind := True;
      Break;
    end;
  end;
  if not LFoundMethodKind then
    raise EipRestService.CreateFmt('Cannot possible to find one method kind in %s attributes. ' +
      'You can use for example [Get(''\users'')].', [FQualifiedName]);

  LParametersCount := 0;
  SetLength(FParameters, Length(ARttiParameters));
  FBodyArgIndex := -1;
  FBodyKind := TTypeKind.tkUnknown;

  for I := 0 to Length(ARttiParameters)-1 do
  begin
    if ARttiParameters[I].ParamType = nil then
      raise EipRestService.CreateFmt('Argument %s have a invalid type in method %s', [ARttiParameters[I].Name, FQualifiedName]);
    if TRttiUtils.HasAttribute<HeadersAttribute>(ARttiParameters[I].GetAttributes) then
      raise EipRestService.CreateFmt('Argument %s have a invalid type in method %s', [ARttiParameters[I].Name, FQualifiedName]);
    LIsDateTime := TRttiUtils.IsDateTime(ARttiParameters[I].ParamType.Handle);
    if TRttiUtils.HasAttribute<HeaderAttribute>(ARttiParameters[I].GetAttributes, LHeaderAttribute) then
    begin
      SetLength(FHeaderParameters, Length(FHeaderParameters) + 1);
      FHeaderParameters[Length(FHeaderParameters)-1] := TApiParam.Create(I + 1, LIsDateTime, ARttiParameters[I].ParamType.TypeKind, LHeaderAttribute.Name);
    end
    else
    begin
      if IsBodyParam(ARttiParameters[I], FBodyContentKind) then
      begin
        if FBodyArgIndex <> -1 then
          raise EipRestService.CreateFmt('Found two content body argument in method %s', [FQualifiedName]);
        if not (FKind in CMethodsWithBodyContent) then
          raise EipRestService.CreateFmt('The kind of the method %s does not permit a body content', [FQualifiedName]);
        FBodyArgIndex := I + 1;
        FBodyIsDateTime := LIsDateTime;
        FBodyKind := ARttiParameters[I].ParamType.TypeKind;
      end
      else
      begin
        FParameters[LParametersCount] := TApiParam.Create(I + 1, LIsDateTime, ARttiParameters[I].ParamType.TypeKind, FixName(ARttiParameters[I].Name, FRelativeUrl));
        Inc(LParametersCount);
      end;
    end;
  end;

  if Length(FParameters) <> LParametersCount then
    SetLength(FParameters, LParametersCount);

  if ARttiReturnType = nil then
    FResultKind := TTypeKind.tkUnknown
  else
  begin
    if FKind in CMethodsWithoutResponseContent then
      raise EipRestService.CreateFmt('The kind of method %s does not permit any result', [FQualifiedName]);
    FResultKind := ARttiReturnType.TypeKind;
    if not (FResultKind in CSupportedResultKind) then
      raise EipRestService.CreateFmt('The result type in %s method is not allowed', [FQualifiedName]);
    if (FResultKind = TTypeKind.tkDynArray) and ((not Assigned(TRttiDynamicArrayType(ARttiReturnType).ElementType)) or
       not (TRttiDynamicArrayType(ARttiReturnType).ElementType.TypeKind in [TTypeKind.tkClass, TTypeKind.tkMRecord, TTypeKind.tkRecord])) then
    begin
      raise EipRestService.CreateFmt('The result type in %s method is not allowed', [FQualifiedName]);
    end;
    FResultTypeInfo := ARttiReturnType.Handle;
    FResultIsDateTime := TRttiUtils.IsDateTime(ARttiReturnType.Handle);
  end;
end;

destructor TApiMethod.Destroy;
var
  I: Integer;
begin
  for I := 0 to Length(FParameters)-1 do
    FParameters[I].Free;
  for I := 0 to Length(FHeaderParameters)-1 do
    FHeaderParameters[I].Free;
  inherited;
end;

{ TApiType }

constructor TApiType.Create(const ABaseUrl: string; const AIID: TGUID;
  const AMethods: TObjectDictionary<Pointer, TApiMethod>;
  const AProperties: TObjectList<TApiProperty>;
  const APropertiesMethods: TDictionary<Pointer, TApiProperty>; const ATypeInfo: PTypeInfo);
begin
  inherited Create;
  FBaseUrl := ABaseUrl;
  FIID := AIID;
  FMethods := AMethods;
  FProperties := AProperties;
  FPropertiesMethods := APropertiesMethods;
  FTypeInfo := ATypeInfo;
end;

destructor TApiType.Destroy;
begin
  FProperties.Free;
  FPropertiesMethods.Free;
  FMethods.Free;
  inherited;
end;

function TApiType.GetBaseUrl: string;
begin
  Result := FBaseUrl;
end;

function TApiType.GetIID: TGUID;
begin
  Result := FIID;
end;

function TApiType.GetMethods: TObjectDictionary<Pointer, TApiMethod>;
begin
  Result := FMethods;
end;

function TApiType.GetProperties: TObjectList<TApiProperty>;
begin
  Result := FProperties;
end;

function TApiType.GetPropertiesMethods: TDictionary<Pointer, TApiProperty>;
begin
  Result := FPropertiesMethods;
end;

function TApiType.GetTypeInfo: PTypeInfo;
begin
  Result := FTypeInfo;
end;

{ TApiVirtualInterface }

procedure TApiVirtualInterface.CallMethod(const AMethodHandle: Pointer;
  const AArgs: TArray<TValue>; var AResult: TValue);
var
  LAccept: string;
  LAcceptCharSet: string;
  LConnectionTimeout: Integer;
  LHandleRedirects: Boolean;
  LResponseTimeout: Integer;
  LAsync: Boolean;
  LMethod: TApiMethod;
  LProperty: TApiProperty;
begin
  if FApiType.Methods.TryGetValue(AMethodHandle, LMethod) then
  begin
    if Assigned(FLocker) then
      FLocker.Enter;
    try
      LAccept := FClient.Accept;
      LAcceptCharSet := FClient.AcceptCharSet;
      LConnectionTimeout := FClient.ConnectionTimeout;
      LHandleRedirects := FClient.HandleRedirects;
      LResponseTimeout := FClient.ResponseTimeout;
      LAsync := FClient.Asynchronous;
      FClient.Accept := 'application/json';
      FClient.AcceptCharSet := 'UTF-8';
      FClient.ConnectionTimeout := 10000;
      FClient.HandleRedirects := False;
      FClient.ResponseTimeout := 10000;
      FClient.Asynchronous := False;
      try
        LMethod.CallApi(FClient, FBaseUrl, FJsonSerializer, AArgs, AResult, FApiType.Properties, FProperties);
      finally
        FClient.Asynchronous := LAsync;
        FClient.Accept := LAccept;
        FClient.AcceptCharSet := LAcceptCharSet;
        FClient.ConnectionTimeout := LConnectionTimeout;
        FClient.HandleRedirects := LHandleRedirects;
        FClient.ResponseTimeout := LResponseTimeout;
      end;
    finally
      if Assigned(FLocker) then
        FLocker.Leave;
    end;
  end
  else if FApiType.PropertiesMethods.TryGetValue(AMethodHandle, LProperty) then
  begin
    if Assigned(FLocker) then
      FLocker.Enter;
    try
      LProperty.CallMethod(AMethodHandle, AArgs, AResult, FProperties);
    finally
      if Assigned(FLocker) then
        FLocker.Leave;
    end;
  end
  else
    raise EipRestService.Create('Unexpected error calling the api');
end;

constructor TApiVirtualInterface.Create(const AApiType: IApiType;
  const AConverters: TArray<TJsonConverter>; const AClient: TNetHTTPClient;
  const AJsonSerializerClass: TipRestService.TApiJsonSerializerClass;
  const ABaseUrl: string; const AThreadSafe: Boolean);
var
  I: Integer;
begin
  inherited Create(AApiType.TypeInfo,
    procedure(AMethod: TRttiMethod; const AArgs: TArray<TValue>; out AResult: TValue)
    begin
      TApiVirtualInterface(AArgs[0].AsInterface).CallMethod(AMethod.Handle, AArgs, AResult);
    end);
  if AThreadSafe then
    FLocker := TCriticalSection.Create;
  FApiType := AApiType;
  FBaseUrl := ABaseUrl.Trim;
  if FBaseUrl.IsEmpty then
    FBaseUrl := AApiType.BaseUrl
  else if FBaseUrl.EndsWith('/') then
    FBaseUrl := FBaseUrl.Substring(0, Length(FBaseUrl)-1).TrimRight;
  if FBaseUrl.IsEmpty then
    raise EipRestService.Create('Invalid base url. The base url can be set as an argument or declaring the attribute [BaseUrl(?)] above the apiinterface service');

  FJsonSerializer := AJsonSerializerClass.Create;

  if (Length(AConverters) > 0) and FJsonSerializer.SupportsConvertorsRegistration then
    FJsonSerializer.Converters.InsertRange(0, AConverters);
  if Assigned(AClient) then
    FClient := AClient
  else
  begin
    FClient := TNetHTTPClient.Create(nil);
    FClientOwn := True;
  end;
  SetLength(FProperties, FApiType.Properties.Count);
  for I := 0 to Length(FProperties)-1 do
    FProperties[I] := FApiType.Properties[I].DefaultValue;
end;

destructor TApiVirtualInterface.Destroy;
begin
  if Assigned(FLocker) then
    FLocker.Free;
  if FClientOwn then
    FClient.Free;
  FJsonSerializer.Free;
  inherited;
end;

{ TRestServiceManager }

constructor TRestServiceManager.Create;
begin
  inherited Create;
  {$IF CompilerVersion < 34.0}
  FLock := TCriticalSection.Create;
  {$ENDIF}
  FConvertersList := nil;
  FApiTypeMap := nil;
  FApiJsonSerializerClass := TDefaultApiJsonSerializer;
end;

function TRestServiceManager.CreateApiType(
  const ATypeInfo: PTypeInfo): IApiType;
var
  LBaseUrlAttr: BaseUrlAttribute;
  LContext: TRttiContext;
  LRttiType: TRttiType;
  LRttiMethods: TArray<TRttiMethod>;
  LRttiMethod: TRttiMethod;
  LRttiPropertiesMethods: TList<TRttiMethod>;
  LAttributes: TArray<TCustomAttribute>;
  LMethods: TObjectDictionary<Pointer, TApiMethod>;
  LInterfaceHeaders: TNameValueArray;
  LHeadersAttributes: TArray<HeadersAttribute>;
  LProperties: TObjectList<TApiProperty>;
  LPropertiesMethods: TDictionary<Pointer, TApiProperty>;
  LFound: Boolean;
  LIID: TGUID;
  LBaseUrl: string;
  I: Integer;
begin
  LMethods := TObjectDictionary<Pointer, TApiMethod>.Create([doOwnsValues]);
  LProperties := TObjectList<TApiProperty>.Create(True);
  LPropertiesMethods := TDictionary<Pointer, TApiProperty>.Create;
  LContext := TRttiContext.Create;
  try
    LRttiType := LContext.GetType(ATypeInfo);
    LIID := TRttiInterfaceType(LRttiType).GUID;
    if TRttiUtils.HasAttribute<BaseUrlAttribute>(LRttiType.GetAttributes, LBaseUrlAttr)  then
    begin
      LBaseUrl := LBaseUrlAttr.Url.Trim;
      if LBaseUrl.EndsWith('/') then
        LBaseUrl := LBaseUrl.Substring(0, Length(LBaseUrl)-1).TrimRight;
    end
    else
      LBaseUrl := '';
    LHeadersAttributes := TRttiUtils.Attributes<HeadersAttribute>(LRttiType.GetAttributes);
    SetLength(LInterfaceHeaders, Length(LHeadersAttributes));
    for I := 0 to Length(LHeadersAttributes)-1 do
      LInterfaceHeaders[I] := TNameValuePair.Create(LHeadersAttributes[I].Name, LHeadersAttributes[I].Value);

    LRttiPropertiesMethods := TList<TRttiMethod>.Create;
    try
      LRttiMethods := LRttiType.GetMethods;
      for LRttiMethod in LRttiMethods do
      begin
        if LMethods.ContainsKey(LRttiMethod.Handle) then
          raise EipRestService.Create('Unexpected error adding two duplicated methods');
        LAttributes := LRttiMethod.GetAttributes;
        if TRttiUtils.HasAttribute<TipUrlAttribute>(LAttributes) then
          LMethods.Add(LRttiMethod.Handle, TApiMethod.Create(LRttiMethod.Parent.Name + '.' + LRttiMethod.Name, LInterfaceHeaders, LRttiMethod.GetParameters, LRttiMethod.ReturnType, LAttributes))
        else if (LRttiMethod.MethodKind = System.TypInfo.TMethodKind.mkProcedure) and
          (LRttiMethod.Name.StartsWith('Set', True)) and (LRttiMethod.Name.Length > 3) and
          (Length(LRttiMethod.GetParameters) = 1)  then
        begin
          LRttiPropertiesMethods.Add(LRttiMethod);
        end
        else if (LRttiMethod.MethodKind = System.TypInfo.TMethodKind.mkFunction) and
          (LRttiMethod.Name.StartsWith('Get', True)) and (LRttiMethod.Name.Length > 3) and
          (Length(LRttiMethod.GetParameters) = 0)  then
        begin
          LRttiPropertiesMethods.Add(LRttiMethod);
        end
        else
          raise EipRestService.CreateFmt('Invalid method %s', [LRttiMethod.Name]);
      end;

      while LRttiPropertiesMethods.Count > 1 do
      begin
        LFound := False;
        for I := 1 to LRttiPropertiesMethods.Count-1 do
        begin
          if LRttiPropertiesMethods[I].Name.Substring(3).ToLower = LRttiPropertiesMethods[0].Name.SubString(3).ToLower then
          begin
            // Rare case but possible, when have 2 methods with same name and with overload
            if LRttiPropertiesMethods[I].Name.ToLower = LRttiPropertiesMethods[0].Name.ToLower then
              raise EipRestService.CreateFmt('Invalid method %s', [LRttiPropertiesMethods[0].Name]);
            if LRttiPropertiesMethods[0].MethodKind = System.TypInfo.TMethodKind.mkFunction then
              LProperties.Add(TApiProperty.Create(LRttiPropertiesMethods[0], LRttiPropertiesMethods[I], LProperties.Count))
            else
              LProperties.Add(TApiProperty.Create(LRttiPropertiesMethods[I], LRttiPropertiesMethods[0], LProperties.Count));
            LRttiPropertiesMethods.Delete(I);
            LRttiPropertiesMethods.Delete(0);
            LFound := True;
            Break;
          end;
        end;
        if not LFound then
          raise EipRestService.CreateFmt('Invalid method %s', [LRttiPropertiesMethods[0].Name]);
      end;
      if LRttiPropertiesMethods.Count > 0 then
        raise EipRestService.CreateFmt('Invalid method %s', [LRttiPropertiesMethods[0].Name]);
    finally
      LRttiPropertiesMethods.Free;
    end;
    for I := 0 to LProperties.Count-1 do
    begin
      if LPropertiesMethods.ContainsKey(LProperties[I].GetMethod) or LPropertiesMethods.ContainsKey(LProperties[I].SetMethod) then
        raise EipRestService.Create('Cannot possible to have properties with same read or write methods');
      LPropertiesMethods.Add(LProperties[I].GetMethod, LProperties[I]);
      LPropertiesMethods.Add(LProperties[I].SetMethod, LProperties[I]);
    end;
  finally
    LContext.Free;
  end;
  if LMethods.Count = 0 then
    raise EipRestService.Create('The interface type don''t have methods or {$M+} directive or is not descendent from IipRestApi');
  if LIID = TGUID.Empty then
    raise EipRestService.Create('The interface type must have one GUID');
  Result := TApiType.Create(LBaseUrl, LIID, LMethods, LProperties, LPropertiesMethods, ATypeInfo);
end;

destructor TRestServiceManager.Destroy;
begin
  {$IF CompilerVersion < 34.0}
  FLock.Free;
  {$ENDIF}
  if Assigned(FConvertersList) then
    FConvertersList.Free;
  if Assigned(FApiTypeMap) then
    FApiTypeMap.Free;
  inherited;
end;

procedure TRestServiceManager.MakeFor(const ATypeInfo: Pointer;
  const AClient: TNetHTTPClient; const ABaseUrl: string; const AThreadSafe: Boolean; out AResult);
var
  LInterface: IInterface;
  LApiType: IApiType;
  LConverters: TArray<TJsonConverter>;
begin
  if PTypeInfo(ATypeInfo).Kind <> TTypeKind.tkInterface then
    raise EipRestService.Create('Invalid type');

  {$IF CompilerVersion >= 34.0}
  FLock.BeginRead;
  {$ELSE}
  FLock.Enter;
  {$ENDIF}
  try
    if Assigned(FApiTypeMap) then
      FApiTypeMap.TryGetValue(ATypeInfo, LApiType)
    else
      LApiType := nil;
    if Assigned(FConvertersList) then
      LConverters := FConvertersList.ToArray
    else
      LConverters := nil;
  finally
    {$IF CompilerVersion >= 34.0}
    FLock.EndRead;
    {$ELSE}
    FLock.Leave;
    {$ENDIF}
  end;

  if not Assigned(LApiType) then
  begin
    LApiType := CreateApiType(ATypeInfo);
    {$IF CompilerVersion >= 34.0}
    FLock.BeginWrite;
    {$ELSE}
    FLock.Enter;
    {$ENDIF}
    try
      if not Assigned(FApiTypeMap) then
        FApiTypeMap := TDictionary<PTypeInfo, IApiType>.Create;
      if FApiTypeMap.ContainsKey(ATypeInfo) then
        LApiType := FApiTypeMap[ATypeInfo]
      else
        FApiTypeMap.Add(ATypeInfo, LApiType);
    finally
      {$IF CompilerVersion >= 34.0}
      FLock.EndWrite;
      {$ELSE}
      FLock.Leave;
      {$ENDIF}
    end;
  end;

  LInterface := TApiVirtualInterface.Create(LApiType, LConverters, AClient, FApiJsonSerializerClass, ABaseUrl, AThreadSafe);
  if not Supports(LInterface, LApiType.IID, AResult) then
    raise EipRestService.Create('Unexpected error creating the service');
end;

procedure TRestServiceManager.RegisterConverters(
  const AConverterClasses: TArray<TipRestService.TJsonConverterClass>);
var
  I: Integer;
begin
  {$IF CompilerVersion >= 34.0}
  FLock.BeginWrite;
  {$ELSE}
  FLock.Enter;
  {$ENDIF}
  try
    if not Assigned(FConvertersList) then
      FConvertersList := TObjectList<TJsonConverter>.Create(True);
    for I := Length(AConverterClasses)-1 downto 0 do
      FConvertersList.Insert(0, AConverterClasses[I].Create);
  finally
    {$IF CompilerVersion >= 34.0}
    FLock.EndWrite;
    {$ELSE}
    FLock.Leave;
    {$ENDIF}
  end;
end;

procedure TRestServiceManager.SetJsonSerializer(const AApiJsonSerializerClass: TipRestService.TApiJsonSerializerClass);
begin
  FApiJsonSerializerClass := AApiJsonSerializerClass;
end;

{ TApiProperty }

procedure TApiProperty.CallMethod(const AMethodHandle: Pointer;
  const AArgs: TArray<TValue>; var AResult: TValue;
  var AProperties: TArray<TValue>);
begin
  if AMethodHandle = FGetMethod then
    AResult := GetValue(AProperties)
  else
    AProperties[FIndex] := AArgs[1];
end;

constructor TApiProperty.Create(const AGetMethod, ASetMethod: TRttiMethod;
  const AIndex: Integer);
begin
  inherited Create;
  if AGetMethod.ReturnType.Handle <> ASetMethod.GetParameters[0].ParamType.Handle then
    raise EipRestService.CreateFmt('Incompatible types of methods %s and %s', [AGetMethod.Name, ASetMethod.Name]);
  FIsDateTime := TRttiUtils.IsDateTime(AGetMethod.ReturnType.Handle);
  FKind := AGetMethod.ReturnType.TypeKind;
  FName := AGetMethod.Name.Substring(3).ToLower;
  FGetMethod := AGetMethod.Handle;
  FIndex := AIndex;
  FSetMethod := ASetMethod.Handle;
  TValue.Make(nil, AGetMethod.ReturnType.Handle, FDefaultValue);
end;

function TApiProperty.GetValue(const AProperties: TArray<TValue>): TValue;
begin
  Result := AProperties[FIndex];
end;

initialization
  GRestService := TRestServiceManager.Create;
  GRestService.RegisterConverters([TipJsonEnumConverter, TipJsonSetConverter]);
finalization
  FreeAndNil(GRestService);
end.
