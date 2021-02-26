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
  REST.Client;

type
  { Exceptions }

  EipRestService = class(Exception);
  EipRestServiceCanceled = class(EipRestService);
  EipRestServiceFailed = class(EipRestService);
  EipRestServiceJson = class(EipRestService);
  EipRestServiceStatusCode = class(EipRestService)
  strict private
    FStatusCode: Integer;
    FStatusText: string;
  public
    constructor Create(const AStatusCode: Integer; const AStatusText, AMethodName: string);
    property StatusCode: Integer read FStatusCode;
    property StatusText: string read FStatusText;
  end;


  { Attributes }

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

  TipUrlAttribute = class abstract(TCustomAttribute)
  strict private
    FUrl: string;
  public
    constructor Create(const AUrl: string);
    property Url: string read FUrl;
  end;

  // Methods attributes - Method kind and relative url
  GetAttribute = class(TipUrlAttribute);
  PostAttribute = class(TipUrlAttribute);
  DeleteAttribute = class(TipUrlAttribute);
  PutAttribute = class(TipUrlAttribute);
  PatchAttribute = class(TipUrlAttribute);

  // Method and type attribute
  HeadersAttribute = class(TCustomAttribute)
  strict private
    FName: string;
    FValue: string;
  public
    constructor Create(const AName, AValue: string);
    property Name: string read FName;
    property Value: string read FValue;
  end;

  // Types attributes
  BaseUrlAttribute = class(TipUrlAttribute);


  { TipRestService }

  // This class and the rest api interfaces created by this class are thread safe.
  // As the connections are synchronous, the ideal is to call the api functions in
  // the background. If you have multiple threads you can also create multiple rest
  // api interfaces for the same api, each one will have a different connection.
  TipRestService = class abstract
  public
    type
      TApiJsonSerializer = class abstract
      {$REGION ' - Internal use'}
      protected
        function GetConverters: TArray<TJsonConverter>; virtual; abstract;
        function InternalDeserialize(const AJson: string; const ATypeInfo: PTypeInfo): TValue; virtual; abstract;
        procedure InternalPopulate(const AJson: string; var AValue: TValue); virtual; abstract;
        function InternalSerialize(const AValue: TValue): string; virtual; abstract;
        procedure SetConverters(const AConverters: TArray<TJsonConverter>); virtual; abstract;
      {$ENDREGION}
      public
        constructor Create; virtual;
        function Deserialize<T>(const AJson: string): T;
        procedure Populate<T>(const AJson: string; var AValue: T);
        function Serialize<T>(const AValue: T): string;
        property Converters: TArray<TJsonConverter> read GetConverters;
      end;
      TApiJsonSerializerClass = class of TApiJsonSerializer;
      TJsonConverterClass = class of TJsonConverter;
  protected
    function GetJsonSerializer: TApiJsonSerializer; virtual; abstract;
    procedure MakeFor(const ATypeInfo: Pointer; const AClient: TRESTClient; const ABaseUrl: string; const AThreadSafe: Boolean; const AJsonSerializerClass: TApiJsonSerializerClass; out AResult); virtual; abstract;
  public
    function &For<T: IInterface>: T; overload;
    function &For<T: IInterface>(const ABaseUrl: string): T; overload;
    // You can pass your own client, but you will be responsible for giving the client free after use the rest api interface returned
    function &For<T: IInterface>(const AClient: TRESTClient; const ABaseUrl: string = ''; const AThreadSafe: Boolean = True; const AJsonSerializerClass: TApiJsonSerializerClass = nil): T; overload;
    procedure RegisterConverters(const AConverterClasses: TArray<TJsonConverterClass>); virtual; abstract;
    // Default json serializer used internally, but you can access it for manual serializations
    property JsonSerializer: TApiJsonSerializer read GetJsonSerializer;
  end;


  { IipRestApi }

  // The rest api interface that you will declare, must be descendent of IipRestApi
  {$M+}
  IipRestApi = interface
    // You can cancel the current request (for example when you need to close the program), but will raise an
    // exception EipRestServiceCanceled
    procedure CancelRequest;
    function GetAuthenticator: TCustomAuthenticator;
    function GetJsonSerializer: TipRestService.TApiJsonSerializer;
    function GetResponse: TRESTResponse;
    procedure SetAuthenticator(AValue: TCustomAuthenticator);
    // Set this authenticator is necessary when the api need a OAuth1 or OAuth2 for example, then you can use
    // the native components like TOAuth2Authenticator. Then you will need to create and configure the
    // authenticator by your self, set here and after finished all api calls you will need to destroy the authenticator
    // (this rest service will not destroy it)
    property Authenticator: TCustomAuthenticator read GetAuthenticator write SetAuthenticator;
    // Json serializer used internally, but you can access it for manual serializations
    property JsonSerializer: TipRestService.TApiJsonSerializer read GetJsonSerializer;
    // The response will be useful when you need to use a TRESTResponseDataSetAdapter
    property Response: TRESTResponse read GetResponse;
  end;
  {$M-}

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
  System.Net.Mime,
  System.Net.URLClient,
  REST.Types;

type
  TMethodKind = (Get, Post, Delete, Put, Patch);

  { TRttiUtils }

  TRttiUtils = class sealed
  public
    class function Attributes<T: TCustomAttribute>(const AAttributes: TArray<TCustomAttribute>): TArray<T>; static;
    class function HasAttribute<T: TCustomAttribute>(const AAttributes: TArray<TCustomAttribute>): Boolean; overload; static;
    class function HasAttribute<T: TCustomAttribute>(const AAttributes: TArray<TCustomAttribute>; out AAttribute: T): Boolean; overload; static;
    class function IsDateTime(const ATypeInfo: PTypeInfo): Boolean; static;
  end;

  { TDefaultApiJsonSerializer }

  TDefaultApiJsonSerializer = class(TipRestService.TApiJsonSerializer)
  private
    type
      TJsonContractResolver = class(TJsonDefaultContractResolver)
      protected
        procedure SetPropertySettingsFromAttributes(const AProperty: TJsonProperty; const ARttiMember: TRttiMember;
          AMemberSerialization: TJsonMemberSerialization); override;
      end;

      TSystemJsonSerializer = class(TJsonSerializer)
      public
        function Deserialize(const AJson: string; const ATypeInfo: PTypeInfo): TValue; overload;
        function Serialize(const AValue: TValue): string; overload;
      end;
  strict private
    FConverters: TArray<TJsonConverter>;
  protected
    function GetConverters: TArray<TJsonConverter>; override;
    function InternalDeserialize(const AJson: string; const ATypeInfo: PTypeInfo): TValue; override;
    procedure InternalPopulate(const AJson: string; var AValue: TValue); override;
    function InternalSerialize(const AValue: TValue): string; override;
    procedure SetConverters(const AConverters: TArray<TJsonConverter>); override;
  end;

  { TJsonConverters }

  TJsonConverters = record
  public
    type
      TEnumConverter = class(TJsonConverter)
      public
        function CanConvert(ATypeInf: PTypeInfo): Boolean; override;
        function ReadJson(const AReader: TJsonReader; ATypeInf: PTypeInfo; const AExistingValue: TValue;
          const ASerializer: TJsonSerializer): TValue; override;
        procedure WriteJson(const AWriter: TJsonWriter; const AValue: TValue; const ASerializer: TJsonSerializer); override;
      end;

      TSetConverter = class(TJsonConverter)
      public
        function CanConvert(ATypeInf: PTypeInfo): Boolean; override;
        function ReadJson(const AReader: TJsonReader; ATypeInf: PTypeInfo; const AExistingValue: TValue;
          const ASerializer: TJsonSerializer): TValue; override;
        procedure WriteJson(const AWriter: TJsonWriter; const AValue: TValue; const ASerializer: TJsonSerializer); override;
      end;

      TBooleanConverter = class(TJsonConverter)
      public
        function CanConvert(ATypeInf: PTypeInfo): Boolean; override;
        function ReadJson(const AReader: TJsonReader; ATypeInf: PTypeInfo; const AExistingValue: TValue;
          const ASerializer: TJsonSerializer): TValue; override;
        procedure WriteJson(const AWriter: TJsonWriter; const AValue: TValue; const ASerializer: TJsonSerializer); override;
      end;

      TInt64Converter = class(TJsonConverter)
      public
        function CanConvert(ATypeInf: PTypeInfo): Boolean; override;
        function ReadJson(const AReader: TJsonReader; ATypeInf: PTypeInfo; const AExistingValue: TValue;
          const ASerializer: TJsonSerializer): TValue; override;
        procedure WriteJson(const AWriter: TJsonWriter; const AValue: TValue; const ASerializer: TJsonSerializer); override;
      end;

      TUInt64Converter = class(TJsonConverter)
      public
        function CanConvert(ATypeInf: PTypeInfo): Boolean; override;
        function ReadJson(const AReader: TJsonReader; ATypeInf: PTypeInfo; const AExistingValue: TValue;
          const ASerializer: TJsonSerializer): TValue; override;
        procedure WriteJson(const AWriter: TJsonWriter; const AValue: TValue; const ASerializer: TJsonSerializer); override;
      end;
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
    FBodyContentKind: TBodyContentKind;
    FBodyIsDateTime: Boolean;
    FBodyKind: TTypeKind;
    FKind: TMethodKind;
    FHeaderParameters: TArray<TApiParam>;
    FHeaders: TNameValueArray;
    FParameters: TArray<TApiParam>;
    FQualifiedName: string;
    FRelativeUrl: string;
    FResultKind: TTypeKind;
    FResultIsDateTime: Boolean;
    FResultTypeInfo: PTypeInfo;
    FTryFunction: Boolean;
    FTryFunctionResultParameterIndex: Integer;
  public
    constructor Create(const AQualifiedName: string; const ATypeHeaders: TNameValueArray;
      const ARttiParameters: TArray<TRttiParameter>; const ARttiReturnType: TRttiType; const AAttributes: TArray<TCustomAttribute>);
    destructor Destroy; override;
    procedure CallApi(const ABaseUrl: string;
      const AJsonSerializer: TipRestService.TApiJsonSerializer; const AArgs: TArray<TValue>;
      var AResult: TValue; const AProperties: TObjectList<TApiProperty>;
      const APropertiesValues: TArray<TValue>; const ACancelRequest: PBoolean;
      const ARequest: TRESTRequest);
  end;

  { IApiType }

  IApiType = interface
    function GetAuthenticatorPropertyIndex: Integer;
    function GetBaseUrl: string;
    function GetCancelRequestMethod: Pointer;
    function GetIID: TGUID;
    function GetJsonSerializerGetterMethod: Pointer;
    function GetMethods: TObjectDictionary<Pointer, TApiMethod>;
    function GetProperties: TObjectList<TApiProperty>;
    function GetPropertiesMethods: TDictionary<Pointer, TApiProperty>;
    function GetResponseGetterMethod: Pointer;
    function GetTypeInfo: PTypeInfo;
    property AuthenticatorPropertyIndex: Integer read GetAuthenticatorPropertyIndex;
    property BaseUrl: string read GetBaseUrl;
    property CancelRequestMethod: Pointer read GetCancelRequestMethod;
    property IID: TGUID read GetIID;
    property JsonSerializerGetterMethod: Pointer read GetJsonSerializerGetterMethod;
    property Methods: TObjectDictionary<Pointer, TApiMethod> read GetMethods;
    property Properties: TObjectList<TApiProperty> read GetProperties;
    property PropertiesMethods: TDictionary<Pointer, TApiProperty> read GetPropertiesMethods;
    property ResponseGetterMethod: Pointer read GetResponseGetterMethod;
    property TypeInfo: PTypeInfo read GetTypeInfo;
  end;

  { TApiType }

  TApiType = class(TInterfacedObject, IApiType)
  strict private
    FAuthenticatorPropertyIndex: Integer;
    FBaseUrl: string;
    FCancelRequestMethod: Pointer;
    FIID: TGUID;
    FJsonSerializerGetterMethod: Pointer;
    FMethods: TObjectDictionary<Pointer, TApiMethod>;
    FProperties: TObjectList<TApiProperty>;
    FPropertiesMethods: TDictionary<Pointer, TApiProperty>;
    FResponseGetterMethod: Pointer;
    FTypeInfo: PTypeInfo;
    function GetAuthenticatorPropertyIndex: Integer;
    function GetBaseUrl: string;
    function GetCancelRequestMethod: Pointer;
    function GetIID: TGUID;
    function GetJsonSerializerGetterMethod: Pointer;
    function GetMethods: TObjectDictionary<Pointer, TApiMethod>;
    function GetProperties: TObjectList<TApiProperty>;
    function GetPropertiesMethods: TDictionary<Pointer, TApiProperty>;
    function GetResponseGetterMethod: Pointer;
    function GetTypeInfo: PTypeInfo;
  public
    constructor Create(const AAuthenticatorPropertyIndex: Integer; const ABaseUrl: string;
      const ACancelRequestMethod: Pointer; const AIID: TGUID;
      const AMethods: TObjectDictionary<Pointer, TApiMethod>; const AProperties: TObjectList<TApiProperty>;
      const APropertiesMethods: TDictionary<Pointer, TApiProperty>; const AJsonSerializerGetterMethod,
      AResponseGetterMethod: Pointer; const ATypeInfo: PTypeInfo);
    destructor Destroy; override;
  end;

  { TApiVirtualInterface }

  TApiVirtualInterface = class(TVirtualInterface)
  strict private
    FApiType: IApiType;
    FBaseUrl: string;
    FCancelNextRequest: Boolean;
    FClient: TRESTClient;
    FClientOwn: Boolean;
    FJsonSerializer: TipRestService.TApiJsonSerializer;
    FLocker: TCriticalSection;
    FProperties: TArray<TValue>;
    FRequest: TRESTRequest;
    FResponse: TRESTResponse;
    procedure CallMethod(const AMethodHandle: Pointer; const AArgs: TArray<TValue>; var AResult: TValue);
    procedure CancelRequest;
    function GetAuthenticator: TCustomAuthenticator;
  public
    constructor Create(const AApiType: IApiType; const AConverters: TArray<TJsonConverter>; const AClient: TRESTClient; const AJsonSerializerClass: TipRestService.TApiJsonSerializerClass; const ABaseUrl: string; const AThreadSafe: Boolean);
    destructor Destroy; override;
  end;

  { TRestServiceManager }

  TRestServiceManager = class(TipRestService)
  strict private
    FApiTypeMap: TDictionary<PTypeInfo, IApiType>;
    FConvertersList: TObjectList<TJsonConverter>;
    FJsonSerializer: TipRestService.TApiJsonSerializer;
    {$IF CompilerVersion >= 34.0}
    FLock: TLightweightMREW;
    {$ELSE}
    FLock: TCriticalSection;
    {$ENDIF}
    function CreateApiType(const ATypeInfo: PTypeInfo): IApiType;
  protected
    function GetJsonSerializer: TipRestService.TApiJsonSerializer; override;
    procedure MakeFor(const ATypeInfo: Pointer; const AClient: TRESTClient; const ABaseUrl: string;
      const AThreadSafe: Boolean; const AJsonSerializerClass: TipRestService.TApiJsonSerializerClass; out AResult); override;
  public
    {$IF CompilerVersion < 34.0}
    constructor Create;
    {$ENDIF}
    destructor Destroy; override;
    procedure RegisterConverters(const AConverterClasses: TArray<TipRestService.TJsonConverterClass>); override;
  end;

const
  CMethodsWithBodyContent: set of TMethodKind = [TMethodKind.Post, TMethodKind.Put, TMethodKind.Patch];
  CMethodsWithoutResponseContent: set of TMethodKind = [];
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

{ BodyAttribute }

constructor BodyAttribute.Create(const ABodyType: TBodyContentKind);
begin
  inherited Create;
  FBodyType := ABodyType;
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
  inherited Create;
  FName := AName;
  FValue := AValue;
end;

{ TipRestService.TApiJsonSerializer }

constructor TipRestService.TApiJsonSerializer.Create;
begin
  inherited Create;
end;

function TipRestService.TApiJsonSerializer.Deserialize<T>(
  const AJson: string): T;
begin
  Result := InternalDeserialize(AJson, TypeInfo(T)).AsType<T>;
end;

procedure TipRestService.TApiJsonSerializer.Populate<T>(const AJson: string;
  var AValue: T);
var
  LValue: TValue;
begin
  TValue.Make(@AValue, TypeInfo(T), LValue);
  InternalPopulate(AJson, LValue);
  AValue := LValue.AsType<T>;
end;

function TipRestService.TApiJsonSerializer.Serialize<T>(
  const AValue: T): string;
var
  LValue: TValue;
begin
  TValue.Make(@AValue, TypeInfo(T), LValue);
  Result := InternalSerialize(LValue);
end;

{ TipRestService }

function TipRestService.&For<T>: T;
begin
  MakeFor(TypeInfo(T), nil, '', True, nil, Result);
end;

function TipRestService.&For<T>(const ABaseUrl: string): T;
begin
  MakeFor(TypeInfo(T), nil, ABaseUrl, True, nil, Result);
end;

function TipRestService.&For<T>(const AClient: TRESTClient;
  const ABaseUrl: string; const AThreadSafe: Boolean;
  const AJsonSerializerClass: TipRestService.TApiJsonSerializerClass): T;
begin
  MakeFor(TypeInfo(T), AClient, ABaseUrl, AThreadSafe, AJsonSerializerClass, Result);
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

{ TDefaultApiJsonSerializer.TJsonContractResolver }

procedure TDefaultApiJsonSerializer.TJsonContractResolver.SetPropertySettingsFromAttributes(
  const AProperty: TJsonProperty; const ARttiMember: TRttiMember;
  AMemberSerialization: TJsonMemberSerialization);
begin
  inherited;
  if (not AProperty.Ignored) and (AProperty.AttributeProvider.GetAttribute(JsonNameAttribute) = nil) then
  begin
    if (ARttiMember is TRttiField) and
      (Length(AProperty.Name) > 1) and
      AProperty.Name.StartsWith('F', True) and
      AProperty.Name.Chars[1].IsUpper then
    begin
      AProperty.Name := AProperty.Name.Substring(1);
    end;
    // Apply camel case
    if Length(AProperty.Name) > 0 then
      AProperty.Name := AProperty.Name.Chars[0].ToLower + AProperty.Name.Substring(1);
  end;
end;

{ TDefaultApiJsonSerializer.TSystemJsonSerializer }

function TDefaultApiJsonSerializer.TSystemJsonSerializer.Deserialize(
  const AJson: string; const ATypeInfo: PTypeInfo): TValue;
var
  LStringReader: TStringReader;
  LJsonReader: TJsonTextReader;
begin
  LStringReader := TStringReader.Create(AJson);
  try
    LJsonReader := TJsonTextReader.Create(LStringReader);
    LJsonReader.DateTimeZoneHandling := DateTimeZoneHandling;
    LJsonReader.DateParseHandling := DateParseHandling;
    LJsonReader.MaxDepth := MaxDepth;
    try
      Result := InternalDeserialize(LJsonReader, ATypeInfo);
    finally
      LJsonReader.Free;
    end;
  finally
    LStringReader.Free;
  end;
end;

function TDefaultApiJsonSerializer.TSystemJsonSerializer.Serialize(
  const AValue: TValue): string;
var
  LStringBuilder: TStringBuilder;
  LStringWriter: TStringWriter;
  LJsonWriter: TJsonTextWriter;
begin
  LStringBuilder := TStringBuilder.Create($7FFF);
  LStringWriter := TStringWriter.Create(LStringBuilder);
  try
    LJsonWriter := TJsonTextWriter.Create(LStringWriter);
    LJsonWriter.FloatFormatHandling := FloatFormatHandling;
    LJsonWriter.DateFormatHandling := DateFormatHandling;
    LJsonWriter.DateTimeZoneHandling := DateTimeZoneHandling;
    LJsonWriter.StringEscapeHandling := StringEscapeHandling;
    LJsonWriter.Formatting := Formatting;
    try
      InternalSerialize(LJsonWriter, AValue);
    finally
      LJsonWriter.Free;
    end;
    Result := LStringBuilder.ToString(True);
  finally
    LStringWriter.Free;
    LStringBuilder.Free;
  end;
end;

{ TDefaultApiJsonSerializer }

function TDefaultApiJsonSerializer.GetConverters: TArray<TJsonConverter>;
begin
  Result := Copy(FConverters);
end;

function TDefaultApiJsonSerializer.InternalDeserialize(const AJson: string;
  const ATypeInfo: PTypeInfo): TValue;
var
  LJsonSerializer: TSystemJsonSerializer;
begin
  LJsonSerializer := TSystemJsonSerializer.Create;
  try
    LJsonSerializer.ContractResolver := TJsonContractResolver.Create;
    LJsonSerializer.Converters.AddRange(FConverters);
    Result := LJsonSerializer.Deserialize(AJson, ATypeInfo);
  finally
    LJsonSerializer.Free;
  end;
end;

procedure TDefaultApiJsonSerializer.InternalPopulate(const AJson: string; var AValue: TValue);
var
  LJsonSerializer: TSystemJsonSerializer;
begin
  LJsonSerializer := TSystemJsonSerializer.Create;
  try
    LJsonSerializer.ContractResolver := TJsonContractResolver.Create;
    LJsonSerializer.Converters.AddRange(FConverters);
    LJsonSerializer.Populate(AJson, AValue);
  finally
    LJsonSerializer.Free;
  end;
end;

function TDefaultApiJsonSerializer.InternalSerialize(const AValue: TValue): string;
var
  LJsonSerializer: TSystemJsonSerializer;
begin
  LJsonSerializer := TSystemJsonSerializer.Create;
  try
    LJsonSerializer.ContractResolver := TJsonContractResolver.Create;
    LJsonSerializer.Converters.AddRange(FConverters);
    Result := LJsonSerializer.Serialize(AValue);
  finally
    LJsonSerializer.Free;
  end;
end;

procedure TDefaultApiJsonSerializer.SetConverters(const AConverters: TArray<TJsonConverter>);
begin
  FConverters := AConverters;
end;

{ TJsonConverters.TEnumConverter }

function TJsonConverters.TEnumConverter.CanConvert(ATypeInf: PTypeInfo): Boolean;
begin
  Result := (ATypeInf.Kind = TTypeKind.tkEnumeration) and (ATypeInf <> TypeInfo(Boolean)) and (ATypeInf.TypeData <> nil);
end;

function TJsonConverters.TEnumConverter.ReadJson(const AReader: TJsonReader;
  ATypeInf: PTypeInfo; const AExistingValue: TValue;
  const ASerializer: TJsonSerializer): TValue;
begin
  Result := AReader.Value;
  if not Result.IsOrdinal then
    Result := TValue.FromOrdinal(ATypeInf, GetEnumValue(ATypeInf, Result.AsString));
end;

procedure TJsonConverters.TEnumConverter.WriteJson(const AWriter: TJsonWriter;
  const AValue: TValue; const ASerializer: TJsonSerializer);
begin
  if (AValue.AsOrdinal < AValue.TypeData.MinValue) or (AValue.AsOrdinal > AValue.TypeData.MaxValue) then
    AWriter.WriteNull
  else
    AWriter.WriteValue(GetEnumName(AValue.TypeInfo, AValue.AsOrdinal));
end;

{ TJsonConverters.TSetConverter }

function TJsonConverters.TSetConverter.CanConvert(ATypeInf: PTypeInfo): Boolean;
begin
  Result := (ATypeInf.Kind = TTypeKind.tkSet);
end;

function TJsonConverters.TSetConverter.ReadJson(const AReader: TJsonReader;
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

procedure TJsonConverters.TSetConverter.WriteJson(const AWriter: TJsonWriter;
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

{ TJsonConverters.TBooleanConverter }

function TJsonConverters.TBooleanConverter.CanConvert(
  ATypeInf: PTypeInfo): Boolean;
begin
  Result := ATypeInf = TypeInfo(Boolean);
end;

function TJsonConverters.TBooleanConverter.ReadJson(const AReader: TJsonReader;
  ATypeInf: PTypeInfo; const AExistingValue: TValue;
  const ASerializer: TJsonSerializer): TValue;
var
  LBool: Boolean;
begin
  Result := AReader.Value;
  // This is necessary when received a Boolean in string format
  if Result.IsType<string> then
  begin
    LBool := StrToBool(Result.AsString);
    TValue.Make(@LBool, AExistingValue.TypeInfo, Result);
  end;
end;

procedure TJsonConverters.TBooleanConverter.WriteJson(
  const AWriter: TJsonWriter; const AValue: TValue;
  const ASerializer: TJsonSerializer);
begin
  AWriter.WriteValue(AValue);
end;

{ TJsonConverters.TInt64Converter }

function TJsonConverters.TInt64Converter.CanConvert(
  ATypeInf: PTypeInfo): Boolean;
begin
  Result := ATypeInf = TypeInfo(Int64);
end;

function TJsonConverters.TInt64Converter.ReadJson(const AReader: TJsonReader;
  ATypeInf: PTypeInfo; const AExistingValue: TValue;
  const ASerializer: TJsonSerializer): TValue;
var
  LOrdinal: Int64;
begin
  Result := AReader.Value;
  // This is necessary when received a Int64 in string format
  if Result.IsType<string> then
  begin
    LOrdinal := StrToInt64(Result.AsString);
    TValue.Make(@LOrdinal, AExistingValue.TypeInfo, Result);
  end;
end;

procedure TJsonConverters.TInt64Converter.WriteJson(
  const AWriter: TJsonWriter; const AValue: TValue;
  const ASerializer: TJsonSerializer);
begin
  AWriter.WriteValue(AValue);
end;

{ TJsonConverters.TUInt64Converter }

function TJsonConverters.TUInt64Converter.CanConvert(
  ATypeInf: PTypeInfo): Boolean;
begin
  Result := ATypeInf = TypeInfo(UInt64);
end;

function TJsonConverters.TUInt64Converter.ReadJson(const AReader: TJsonReader;
  ATypeInf: PTypeInfo; const AExistingValue: TValue;
  const ASerializer: TJsonSerializer): TValue;
var
  LOrdinal: UInt64;
begin
  Result := AReader.Value;
  // This is necessary when received a UInt64 in string format
  if Result.IsType<string> then
  begin
    LOrdinal := StrToUInt64(Result.AsString);
    TValue.Make(@LOrdinal, AExistingValue.TypeInfo, Result);
  end;
end;

procedure TJsonConverters.TUInt64Converter.WriteJson(
  const AWriter: TJsonWriter; const AValue: TValue;
  const ASerializer: TJsonSerializer);
begin
  AWriter.WriteValue(AValue);
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

{ TApiMethod }

procedure TApiMethod.CallApi(const ABaseUrl: string;
  const AJsonSerializer: TipRestService.TApiJsonSerializer; const AArgs: TArray<TValue>;
  var AResult: TValue; const AProperties: TObjectList<TApiProperty>;
  const APropertiesValues: TArray<TValue>; const ACancelRequest: PBoolean; const ARequest: TRESTRequest);

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
  LBodyContent: TMemoryStream;
  LBodyBytes: TBytes;
  LResponseString: string;
  LHeaders: TNameValueArray;
  LStr: string;
  LContentHeaderIndex: Integer;
  LMultipartFormData: TMultipartFormData;
  LValue: TValue;
begin
  if FTryFunction then
    AResult := False;
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
        LHeaders[I].Value := LHeaders[I].Value.Replace('{' + FParameters[J].Name + '}', LArgumentAsString, [rfReplaceAll, rfIgnoreCase]);
      end;
      if LStr.Contains('{a' + FParameters[J].Name.ToLower + '}') then
      begin
        LArgumentAsString := GetStringValue(AArgs[FParameters[J].ArgIndex], FParameters[J].Kind, FParameters[J].IsDateTime);
        LHeaders[I].Value := LHeaders[I].Value.Replace('{a' + FParameters[J].Name + '}', LArgumentAsString, [rfReplaceAll, rfIgnoreCase]);
      end;
    end;
    for J := 0 to AProperties.Count-1 do
    begin
      if LStr.Contains('{' + AProperties[J].Name + '}') then
      begin
        LArgumentAsString := GetStringValue(AProperties[J].GetValue(APropertiesValues), AProperties[J].Kind, AProperties[J].IsDateTime);
        LHeaders[I].Value := LHeaders[I].Value.Replace('{' + AProperties[J].Name + '}', LArgumentAsString, [rfReplaceAll, rfIgnoreCase]);
      end;
    end;
  end;
  LContentHeaderIndex := -1;
  for I := Low(LHeaders) to High(LHeaders) do
  begin
    if LHeaders[I].Name.ToLower = 'content-type' then
    begin
      LContentHeaderIndex := I;
      Break;
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
  try
    if FKind in CMethodsWithBodyContent then
    begin
      LBodyContent := TMemoryStream.Create;
      case FBodyContentKind of
        TBodyContentKind.Default:
          if FBodyArgIndex > -1 then
          begin
            if FBodyKind in [TTypeKind.tkClass, TTypeKind.tkInterface, TTypeKind.tkMRecord, TTypeKind.tkRecord] then
            begin
              try
                LBodyBytes := TEncoding.UTF8.GetBytes(AJsonSerializer.InternalSerialize(AArgs[FBodyArgIndex]));
              except
                on E: Exception do
                begin
                  if FTryFunction then
                    Exit
                  else
                    Exception.RaiseOuterException(EipRestServiceJson.Create('Json serialization failed'));
                end;
              end;
            end
            else
              LBodyBytes := TEncoding.UTF8.GetBytes(GetStringValue(AArgs[FBodyArgIndex], FBodyKind, FBodyIsDateTime));
            if Length(LBodyBytes) > 0 then
              LBodyContent.WriteBuffer(LBodyBytes, Length(LBodyBytes));
          end;
        TBodyContentKind.MultipartFormData:
          begin
            if AArgs[FBodyArgIndex].IsInstanceOf(TMultipartFormData) then
            begin
              LMultipartFormData := TMultipartFormData(AArgs[FBodyArgIndex].AsObject);
              LMultipartFormData.Stream.Position := 0;
              // You can optimize by using the LMultipartFormData.Stream directly but you need to handle the flow of freeing LBodyContent
              LBodyContent.CopyFrom(LMultipartFormData.Stream, LMultipartFormData.Stream.Size);
              // Make sure content type is valid
              if LContentHeaderIndex > -1 then
                LHeaders[LContentHeaderIndex].Value := LMultipartFormData.MimeTypeHeader
              else
              begin
                LHeaders := LHeaders + [TNameValuePair.Create('Content-Type', LMultipartFormData.MimeTypeHeader)];
                LContentHeaderIndex := Length(LHeaders) - 1;
              end;
            end
            else
              raise EipRestService.Create('Body content kind set to "TBodyContentKind.MultipartFormData" but content is not of "TMultipartFormData"');
          end;
      else
        Assert(False);
      end;
      LBodyContent.Position := 0;
      // Set the default content type
      if LContentHeaderIndex = -1 then
        LHeaders := LHeaders + [TNameValuePair.Create('Content-Type', CONTENTTYPE_APPLICATION_JSON)];
    end;
    LRelativeUrl := ABaseUrl + LRelativeUrl;

    case FKind of
      TMethodKind.Get: ARequest.Method := TRESTRequestMethod.rmGET;
      TMethodKind.Post: ARequest.Method := TRESTRequestMethod.rmPOST;
      TMethodKind.Delete: ARequest.Method := TRESTRequestMethod.rmDELETE;
      TMethodKind.Put: ARequest.Method := TRESTRequestMethod.rmPUT;
      TMethodKind.Patch: ARequest.Method := TRESTRequestMethod.rmPATCH;
    else
      Assert(False);
    end;
    ARequest.Client.BaseURL := LRelativeUrl;
    ARequest.Params.Clear;
    ARequest.ClearBody;
    if Assigned(LBodyContent) then
      ARequest.AddBody(LBodyContent);
    for I := 0 to Length(LHeaders)-1 do
    begin
      if LHeaders[I].Name.ToLower = 'content-type' then
        ARequest.Params.AddItem(LHeaders[I].Name, LHeaders[I].Value, TRESTRequestParameterKind.pkHTTPHEADER,
          [TRESTRequestParameterOption.poDoNotEncode], ContentTypeFromString(LHeaders[I].Value))
      else
        ARequest.Params.AddItem(LHeaders[I].Name, LHeaders[I].Value, TRESTRequestParameterKind.pkHTTPHEADER,
          [TRESTRequestParameterOption.poDoNotEncode]);
    end;
    if ACancelRequest^ then
    begin
      ACancelRequest^ := False;
      if FTryFunction then
        Exit
      else
        raise EipRestServiceCanceled.Create('Request canceled');
    end;
    try
      ARequest.Execute;
    except
      on E: ERESTException do
      begin
        if FTryFunction then
          Exit
        else
          Exception.RaiseOuterException(EipRestServiceFailed.Create('Service or connection failed'));
      end;
    end;
    {$IF CompilerVersion >= 34} // Delphi 10.4 Sydney
    if ARequest.IsCancelled then
    begin
      ACancelRequest^ := False;
      if FTryFunction then
        Exit
      else
        raise EipRestServiceCanceled.Create('Request canceled');
    end;
    {$ELSE}
    if ACancelRequest^ then
    begin
      ACancelRequest^ := False;
      if FTryFunction then
        Exit
      else
        raise EipRestServiceCanceled.Create('Request canceled');
    end;
    {$ENDIF}
    if (ARequest.Response.StatusCode < 200) or (ARequest.Response.StatusCode > 299) then
    begin
      if FTryFunction then
        Exit
      else
        raise EipRestServiceStatusCode.Create(ARequest.Response.StatusCode, ARequest.Response.StatusText, FQualifiedName);
    end;
    if (not (FKind in CMethodsWithoutResponseContent)) and (FResultKind <> TTypeKind.tkUnknown) then
    begin
      LResponseString := ARequest.Response.Content;
      case FResultKind of
        TTypeKind.tkUString:
          begin
            if FTryFunction then
              AArgs[FTryFunctionResultParameterIndex] := LResponseString
            else
              AResult := LResponseString;
          end;
        TTypeKind.tkDynArray,
        TTypeKind.tkClass,
        TTypeKind.tkMRecord,
        TTypeKind.tkRecord:
          begin
            try
              LValue := AJsonSerializer.InternalDeserialize(LResponseString, FResultTypeInfo);
            except
              on E: Exception do
              begin
                if FTryFunction then
                  Exit
                else
                  Exception.RaiseOuterException(EipRestServiceJson.Create('Json deserialization failed'));
              end;
            end;
            if FTryFunction then
              AArgs[FTryFunctionResultParameterIndex] := LValue
            else
              AResult := LValue;
          end;
      else
        Assert(False);
      end;
    end;
    if FTryFunction then
      AResult := True;
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
        ABodyContentKind := LBodyAttribute.BodyType
      else
        ABodyContentKind := TBodyContentKind.Default;
    end
    // You can declare the body of type TMultipartFormData with out the attribute
    else if ARttiParameter.ParamType.Name = 'TMultipartFormData' then
      ABodyContentKind := TBodyContentKind.MultipartFormData
    else
      ABodyContentKind := TBodyContentKind.Default
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
  LRttiReturnType: TRttiType;
  I: Integer;
begin
  inherited Create;
  FTryFunction := False;
  FTryFunctionResultParameterIndex := -1;
  FQualifiedName := AQualifiedName;
  if TRttiUtils.HasAttribute<HeaderAttribute>(AAttributes) then
    raise EipRestService.CreateFmt('Cannot possible to use the attribute [Header()] in method "%s", it is reserved just for parameters. For methods, use the attribute [Headers()] in plural', [AQualifiedName]);
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

  if ARttiReturnType = nil then
    FResultKind := TTypeKind.tkUnknown
  else
  begin
    LRttiReturnType := ARttiReturnType;
    FTryFunction := (LRttiReturnType.Handle = TypeInfo(Boolean)) and AQualifiedName.ToLower.Contains('.try');
    if FTryFunction then
    begin
      for I := 0 to Length(ARttiParameters)-1 do
      begin
        if [TParamFlag.pfVar, TParamFlag.pfOut] * ARttiParameters[I].Flags <> [] then
        begin
          FTryFunctionResultParameterIndex := I + 1;
          Break;
        end;
      end;
      if FTryFunctionResultParameterIndex = -1 then
        FResultKind := TTypeKind.tkUnknown
      else
        LRttiReturnType := ARttiParameters[FTryFunctionResultParameterIndex - 1].ParamType;
    end;

    if (not FTryFunction) or (FTryFunctionResultParameterIndex > -1) then
    begin
      if FKind in CMethodsWithoutResponseContent then
        raise EipRestService.CreateFmt('The kind of method %s does not permit any result', [FQualifiedName]);
      FResultKind := LRttiReturnType.TypeKind;
      if not (FResultKind in CSupportedResultKind) then
        raise EipRestService.CreateFmt('The result type in %s method is not allowed', [FQualifiedName]);
      if (FResultKind = TTypeKind.tkDynArray) and ((not Assigned(TRttiDynamicArrayType(LRttiReturnType).ElementType)) or
         not (TRttiDynamicArrayType(LRttiReturnType).ElementType.TypeKind in [TTypeKind.tkClass, TTypeKind.tkMRecord, TTypeKind.tkRecord])) then
      begin
        raise EipRestService.CreateFmt('The result type in %s method is not allowed', [FQualifiedName]);
      end;
      FResultTypeInfo := LRttiReturnType.Handle;
      FResultIsDateTime := TRttiUtils.IsDateTime(LRttiReturnType.Handle);
    end;
  end;

  LParametersCount := 0;
  SetLength(FParameters, Length(ARttiParameters));
  FBodyArgIndex := -1;
  FBodyKind := TTypeKind.tkUnknown;

  for I := 0 to Length(ARttiParameters)-1 do
  begin
    if I = FTryFunctionResultParameterIndex - 1 then
      Continue;
    if [TParamFlag.pfVar, TParamFlag.pfOut] * ARttiParameters[I].Flags <> [] then
      raise EipRestService.CreateFmt('Argument %s have a invalid flag (var or out) in method %s. This flags are accepted only in Try functions and only by one argument.', [ARttiParameters[I].Name, FQualifiedName]);
    if ARttiParameters[I].ParamType = nil then
      raise EipRestService.CreateFmt('Argument %s have a invalid type in method %s', [ARttiParameters[I].Name, FQualifiedName]);
    if TRttiUtils.HasAttribute<HeadersAttribute>(ARttiParameters[I].GetAttributes) then
      raise EipRestService.CreateFmt('Wrong declarations of the attribute [Headers()] in parameter "%s" in method "%s". The attribute Headers is just for methods or types (api interface type). To declare header in parameters use the attribute [Header()] in singular.', [ARttiParameters[I].Name, FQualifiedName]);
    LIsDateTime := TRttiUtils.IsDateTime(ARttiParameters[I].ParamType.Handle);
    if TRttiUtils.HasAttribute<HeaderAttribute>(ARttiParameters[I].GetAttributes, LHeaderAttribute) then
    begin
      if LHeaderAttribute.Name.Contains(':') then
        raise EipRestService.CreateFmt('You cannot declare the value of the header in attribute [Header()] of the parameter "%s" in method "%s". Please declare just the key of the header', [ARttiParameters[I].Name, FQualifiedName]);
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

constructor TApiType.Create(const AAuthenticatorPropertyIndex: Integer;
  const ABaseUrl: string; const ACancelRequestMethod: Pointer; const AIID: TGUID;
  const AMethods: TObjectDictionary<Pointer, TApiMethod>;
  const AProperties: TObjectList<TApiProperty>;
  const APropertiesMethods: TDictionary<Pointer, TApiProperty>;
  const AJsonSerializerGetterMethod, AResponseGetterMethod: Pointer;
  const ATypeInfo: PTypeInfo);
begin
  inherited Create;
  FAuthenticatorPropertyIndex := AAuthenticatorPropertyIndex;
  FBaseUrl := ABaseUrl;
  FCancelRequestMethod := ACancelRequestMethod;
  FIID := AIID;
  FJsonSerializerGetterMethod := AJsonSerializerGetterMethod;
  FMethods := AMethods;
  FProperties := AProperties;
  FPropertiesMethods := APropertiesMethods;
  FResponseGetterMethod := AResponseGetterMethod;
  FTypeInfo := ATypeInfo;
end;

destructor TApiType.Destroy;
begin
  FProperties.Free;
  FPropertiesMethods.Free;
  FMethods.Free;
  inherited;
end;

function TApiType.GetAuthenticatorPropertyIndex: Integer;
begin
  Result := FAuthenticatorPropertyIndex;
end;

function TApiType.GetBaseUrl: string;
begin
  Result := FBaseUrl;
end;

function TApiType.GetCancelRequestMethod: Pointer;
begin
  Result := FCancelRequestMethod;
end;

function TApiType.GetIID: TGUID;
begin
  Result := FIID;
end;

function TApiType.GetJsonSerializerGetterMethod: Pointer;
begin
  Result := FJsonSerializerGetterMethod;
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

function TApiType.GetResponseGetterMethod: Pointer;
begin
  Result := FResponseGetterMethod;
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
  LAuthenticator: TCustomAuthenticator;
  LHandleRedirects: Boolean;
  {$IF CompilerVersion >= 34} // Delphi 10.4 Sydney
  LConnectionTimeout: Integer;
  LReadTimeout: Integer;
  {$ENDIF}
  LSyncEvents: Boolean;
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
      LAuthenticator := FClient.Authenticator;
      {$IF CompilerVersion >= 34} // Delphi 10.4 Sydney
      LConnectionTimeout := FClient.ConnectTimeout;
      LReadTimeout := FClient.ReadTimeout;
      {$ENDIF}
      LHandleRedirects := FClient.HandleRedirects;
      LSyncEvents := FClient.SynchronizedEvents;
      FClient.Accept := 'application/json';
      FClient.AcceptCharSet := 'utf-8';
      FClient.Authenticator := GetAuthenticator;
      {$IF CompilerVersion >= 34} // Delphi 10.4 Sydney
      FClient.ConnectTimeout := 10000;
      FClient.ReadTimeout := 10000;
      {$ENDIF}
      FClient.HandleRedirects := False;
      FClient.SynchronizedEvents := False;
      FRequest.Client := FClient;
      try
        LMethod.CallApi(FBaseUrl, FJsonSerializer, AArgs, AResult, FApiType.Properties, FProperties, @FCancelNextRequest, FRequest);
      finally
        FClient.Accept := LAccept;
        FClient.AcceptCharSet := LAcceptCharSet;
        FClient.Authenticator := LAuthenticator;
        FClient.HandleRedirects := LHandleRedirects;
        {$IF CompilerVersion >= 34} // Delphi 10.4 Sydney
        FClient.ConnectTimeout := LConnectionTimeout;
        FClient.ReadTimeout := LReadTimeout;
        {$ENDIF}
        FClient.SynchronizedEvents := LSyncEvents;
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
  else if FApiType.CancelRequestMethod = AMethodHandle then
    CancelRequest
  else if FApiType.ResponseGetterMethod = AMethodHandle then
    AResult := FResponse
  else if FApiType.JsonSerializerGetterMethod = AMethodHandle then
    AResult := FJsonSerializer
  else
    raise EipRestService.Create('Unexpected error calling the api');
end;

procedure TApiVirtualInterface.CancelRequest;
begin
  FCancelNextRequest := True;
  {$IF CompilerVersion >= 34} // Delphi 10.4 Sydney
  FRequest.Cancel;
  {$ENDIF}
end;

constructor TApiVirtualInterface.Create(const AApiType: IApiType;
  const AConverters: TArray<TJsonConverter>; const AClient: TRESTClient;
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
  if Assigned(AJsonSerializerClass) then
    FJsonSerializer := AJsonSerializerClass.Create
  else
    FJsonSerializer := TDefaultApiJsonSerializer.Create;
  if Length(AConverters) > 0 then
    FJsonSerializer.SetConverters(AConverters);
  if Assigned(AClient) then
    FClient := AClient
  else
  begin
    FClient := TRESTClient.Create(nil);
    FClientOwn := True;
  end;
  SetLength(FProperties, FApiType.Properties.Count);
  for I := 0 to Length(FProperties)-1 do
    FProperties[I] := FApiType.Properties[I].DefaultValue;
  FResponse := TRESTResponse.Create(nil);
  FRequest := TRESTRequest.Create(nil);
  FRequest.Response := FResponse;
end;

destructor TApiVirtualInterface.Destroy;
begin
  FRequest.Free;
  FResponse.Free;
  if Assigned(FLocker) then
    FLocker.Free;
  if FClientOwn then
    FClient.Free;
  FJsonSerializer.Free;
  inherited;
end;

function TApiVirtualInterface.GetAuthenticator: TCustomAuthenticator;
begin
  if (FApiType.AuthenticatorPropertyIndex >= 0) and (FProperties[FApiType.AuthenticatorPropertyIndex].AsObject is TCustomAuthenticator) then
    Result := TCustomAuthenticator(FProperties[FApiType.AuthenticatorPropertyIndex].AsObject)
  else
    Result := nil;
end;

{ TRestServiceManager }

{$IF CompilerVersion < 34.0}
constructor TRestServiceManager.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;
{$ENDIF}

function TRestServiceManager.CreateApiType(
  const ATypeInfo: PTypeInfo): IApiType;
var
  LAuthenticatorPropertyIndex: Integer;
  LBaseUrlAttr: BaseUrlAttribute;
  LCancelRequestMethod: Pointer;
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
  LJsonSerializerGetterMethod: Pointer;
  LResponseGetterMethod: Pointer;
  LFound: Boolean;
  LIID: TGUID;
  LBaseUrl: string;
  I: Integer;
begin
  LCancelRequestMethod := nil;
  LJsonSerializerGetterMethod := nil;
  LResponseGetterMethod := nil;
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
    if TRttiUtils.HasAttribute<HeaderAttribute>(LRttiType.GetAttributes) then
      raise EipRestService.Create('Cannot possible to use the attribute [Header()] in type declaration, it is reserved just for parameters. For type declarations, use the attribute [Headers()] in plural');
    LHeadersAttributes := TRttiUtils.Attributes<HeadersAttribute>(LRttiType.GetAttributes);
    SetLength(LInterfaceHeaders, Length(LHeadersAttributes));
    for I := 0 to Length(LHeadersAttributes)-1 do
      LInterfaceHeaders[I] := TNameValuePair.Create(LHeadersAttributes[I].Name, LHeadersAttributes[I].Value);

    LRttiPropertiesMethods := TList<TRttiMethod>.Create;
    try
      LRttiMethods := LRttiType.GetMethods;
      for LRttiMethod in LRttiMethods do
      begin
        if (LRttiMethod.Name.ToLower = 'cancelrequest') and (Length(LRttiMethod.GetParameters) = 0) and not Assigned(LCancelRequestMethod) then
        begin
          LCancelRequestMethod := LRttiMethod.Handle;
          Continue;
        end;
        if (LRttiMethod.Name.ToLower = 'getresponse') and (Length(LRttiMethod.GetParameters) = 0) and (LRttiMethod.ReturnType <> nil) and
          (LRttiMethod.ReturnType.Handle = TRESTResponse.ClassInfo) and not Assigned(LResponseGetterMethod) then
        begin
          LResponseGetterMethod := LRttiMethod.Handle;
          Continue;
        end;
        if (LRttiMethod.Name.ToLower = 'getjsonserializer') and (Length(LRttiMethod.GetParameters) = 0) and (LRttiMethod.ReturnType <> nil) and
          (LRttiMethod.ReturnType.Handle = TipRestService.TApiJsonSerializer.ClassInfo) and not Assigned(LJsonSerializerGetterMethod) then
        begin
          LJsonSerializerGetterMethod := LRttiMethod.Handle;
          Continue;
        end;
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
  LAuthenticatorPropertyIndex := -1;
  for I := 0 to LProperties.Count-1 do
  begin
    if (LProperties[I].Name.ToLower = 'authenticator') and (LProperties[I].Kind = TTypeKind.tkClass) then
    begin
      LAuthenticatorPropertyIndex := I;
      Break;
    end;
  end;
  Result := TApiType.Create(LAuthenticatorPropertyIndex, LBaseUrl, LCancelRequestMethod,
    LIID, LMethods, LProperties, LPropertiesMethods, LJsonSerializerGetterMethod,
    LResponseGetterMethod, ATypeInfo);
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
  if Assigned(FJsonSerializer) then
    FJsonSerializer.Free;
  inherited;
end;

function TRestServiceManager.GetJsonSerializer: TipRestService.TApiJsonSerializer;

  function _ConvertersListCount: Integer;
  begin
    if Assigned(FConvertersList) then
      Result := FConvertersList.Count
    else
      Result := 0;
  end;

begin
  {$IF CompilerVersion >= 34.0}
  FLock.BeginRead;
  {$ELSE}
  FLock.Enter;
  {$ENDIF}
  try
    Result := FJsonSerializer;
    if Assigned(Result) and (Length(Result.Converters) = _ConvertersListCount) then
      Exit;
  finally
    {$IF CompilerVersion >= 34.0}
    FLock.EndRead;
    {$ELSE}
    FLock.Leave;
    {$ENDIF}
  end;

  {$IF CompilerVersion >= 34.0}
  FLock.BeginWrite;
  {$ELSE}
  FLock.Enter;
  {$ENDIF}
  try
    if not Assigned(FJsonSerializer) then
      FJsonSerializer := TDefaultApiJsonSerializer.Create;
    Result := FJsonSerializer;
    if Length(FJsonSerializer.Converters) <> _ConvertersListCount then
    begin
      if Assigned(FConvertersList) then
        FJsonSerializer.SetConverters(FConvertersList.ToArray)
      else
        FJsonSerializer.SetConverters(nil);
    end;
  finally
    {$IF CompilerVersion >= 34.0}
    FLock.EndWrite;
    {$ELSE}
    FLock.Leave;
    {$ENDIF}
  end;
end;

procedure TRestServiceManager.MakeFor(const ATypeInfo: Pointer;
  const AClient: TRESTClient; const ABaseUrl: string; const AThreadSafe: Boolean;
  const AJsonSerializerClass: TipRestService.TApiJsonSerializerClass; out AResult);
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

  LInterface := TApiVirtualInterface.Create(LApiType, LConverters, AClient, AJsonSerializerClass, ABaseUrl, AThreadSafe);
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

initialization
  GRestService := TRestServiceManager.Create;
  GRestService.RegisterConverters([TJsonConverters.TEnumConverter, TJsonConverters.TSetConverter,
    TJsonConverters.TBooleanConverter, TJsonConverters.TInt64Converter, TJsonConverters.TUInt64Converter]);
finalization
  FreeAndNil(GRestService);
end.
