unit iPub.Rtl.Refit;

interface

{$SCOPEDENUMS ON}

uses
  { Delphi }
  System.SysUtils,
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

  // Parameter attribute
  BodyAttribute = class(TCustomAttribute);

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

  { TipRestService }

  // This class and the rest api interfaces created by this class are thread safe.
  // As the connections are synchronous, the ideal is to call the api functions in
  // the background. If you have multiple threads you can also create multiple rest
  // api interfaces for the same api, each one will have a different connection.
  TipRestService = class
  protected
    procedure MakeFor(const ATypeInfo: Pointer; const AClient: TNetHTTPClient; const ABaseUrl: string; out AResult); virtual; abstract;
  public
    function &For<T: IInterface>: T; overload;
    function &For<T: IInterface>(const ABaseUrl: string): T; overload;
    // You can pass your own client, but you will be responsible for giving the client free after use the rest api interface returned
    function &For<T: IInterface>(const AClient: TNetHTTPClient; const ABaseUrl: string = ''): T; overload;
  end;

var
  GRestService: TipRestService;

implementation

uses
  { Delphi }
  System.Classes,
  System.Character,
  System.Rtti,
  System.TypInfo,
  System.Generics.Collections,
  System.SyncObjs,
  System.JSON.Writers,
  System.JSON.Readers,
  System.JSON.Serializers,
  System.Net.HttpClient,
  System.Net.URLClient;

type
  TMethodKind = (Get, Post, Delete, Options, Trace, Head, Put);

  { TRttiUtils }

  TRttiUtils = class sealed
  public
    class function Attributes<T: TCustomAttribute>(const AAttributes: TArray<TCustomAttribute>): TArray<T>; static;
    class function HasAttribute<T: TCustomAttribute>(const AAttributes: TArray<TCustomAttribute>; out AAttribute: T): Boolean; static;
  end;

  { TApiJsonSerializer }

  TApiJsonSerializer = class(TJsonSerializer)
  public
    function Deserialize(const AJson: string; const ATypeInfo: PTypeInfo): TValue; overload;
    function Serialize(const AValue: TValue): string; overload;
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

  { TApiMethod }

  TApiMethod = class
  strict private
    FBodyArgIndex: Integer;
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
  public
    constructor Create(const AQualifiedName: string; const ATypeHeaders: TNameValueArray; const ARttiParameters: TArray<TRttiParameter>; const ARttiReturnType: TRttiType; const AAttributes: TArray<TCustomAttribute>);
    destructor Destroy; override;
    procedure CallApi(const AClient: TNetHTTPClient; const ABaseUrl: string;
      const AJsonSerializer: TApiJsonSerializer; const AArgs: TArray<TValue>;
      var AResult: TValue);
  end;

  { IApiType }

  IApiType = interface
    function GetBaseUrl: string;
    function GetIID: TGUID;
    function GetMethods: TObjectDictionary<Pointer, TApiMethod>;
    function GetTypeInfo: PTypeInfo;
    property BaseUrl: string read GetBaseUrl;
    property IID: TGUID read GetIID;
    property Methods: TObjectDictionary<Pointer, TApiMethod> read GetMethods;
    property TypeInfo: PTypeInfo read GetTypeInfo;
  end;

  { TApiType }

  TApiType = class(TInterfacedObject, IApiType)
  strict private
    FBaseUrl: string;
    FIID: TGUID;
    FMethods: TObjectDictionary<Pointer, TApiMethod>;
    FTypeInfo: PTypeInfo;
    function GetBaseUrl: string;
    function GetIID: TGUID;
    function GetMethods: TObjectDictionary<Pointer, TApiMethod>;
    function GetTypeInfo: PTypeInfo;
  public
    constructor Create(const ABaseUrl: string; const AIID: TGUID; const AMethods: TObjectDictionary<Pointer, TApiMethod>; const ATypeInfo: PTypeInfo);
    destructor Destroy; override;
  end;

  { TApiVirtualInterface }

  TApiVirtualInterface = class(TVirtualInterface)
  strict private
    FApiType: IApiType;
    FBaseUrl: string;
    FCallLock: TCriticalSection;
    FClient: TNetHTTPClient;
    FClientOwn: Boolean;
    FJsonSerializer: TApiJsonSerializer;
    procedure CallApi(const AMethodHandle: Pointer; const AArgs: TArray<TValue>; var AResult: TValue);
  public
    constructor Create(const AApiType: IApiType; const AClient: TNetHTTPClient; const ABaseUrl: string);
    destructor Destroy; override;
  end;

  { TRestServiceManager }

  TRestServiceManager = class(TipRestService)
  strict private
    FApiTypeMap: TDictionary<PTypeInfo, IApiType>;
    {$IF CompilerVersion >= 34.0}
    FLock: TLightweightMREW;
    {$ELSE}
    FLock: TCriticalSection;
    {$ENDIF}
    function CreateApiType(const ATypeInfo: PTypeInfo): IApiType;
  protected
    procedure MakeFor(const ATypeInfo: Pointer; const AClient: TNetHTTPClient; const ABaseUrl: string; out AResult); override;
  public
    {$IF CompilerVersion < 34.0}
    constructor Create;
    {$ENDIF}
    destructor Destroy; override;
  end;

const
  CMethodsWithBodyContent: set of TMethodKind = [TMethodKind.Post, TMethodKind.Put];
  CMethodsWithoutResponseContent: set of TMethodKind = [TMethodKind.Head];
  CSupportedResultKind: set of TTypeKind = [TTypeKind.tkUString, TTypeKind.tkClass, TTypeKind.tkMRecord, TTypeKind.tkRecord];

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

{ TipRestService }

function TipRestService.&For<T>: T;
begin
  MakeFor(TypeInfo(T), nil, '', Result);
end;

function TipRestService.&For<T>(const ABaseUrl: string): T;
begin
  MakeFor(TypeInfo(T), nil, ABaseUrl, Result);
end;

function TipRestService.&For<T>(const AClient: TNetHTTPClient;
  const ABaseUrl: string): T;
begin
  MakeFor(TypeInfo(T), AClient, ABaseUrl, Result);
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

{ TApiJsonSerializer }

function TApiJsonSerializer.Deserialize(const AJson: string;
  const ATypeInfo: PTypeInfo): TValue;
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

function TApiJsonSerializer.Serialize(const AValue: TValue): string;
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
  const AJsonSerializer: TApiJsonSerializer; const AArgs: TArray<TValue>; var AResult: TValue);

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
  LRelativeUrl: string;
  LArgumentAsString: string;
  LResponse: IHTTPResponse;
  LResponseContent: TBytesStream;
  LBodyContent: TStringList;
  LResponseString: string;
  LHeaders: TNameValueArray;
begin
  LHeaders := Copy(FHeaders);
  SetLength(LHeaders, Length(LHeaders) + Length(FHeaderParameters));
  for I := 0 to Length(FHeaderParameters)-1 do
    LHeaders[Length(LHeaders) + I] := TNameValuePair.Create(FHeaderParameters[I].Name,
      GetStringValue(AArgs[FHeaderParameters[I].ArgIndex], FHeaderParameters[I].Kind, FHeaderParameters[I].IsDateTime));
  LRelativeUrl := FRelativeUrl;
  for I := 0 to Length(FParameters)-1 do
  begin
    LArgumentAsString := GetStringValue(AArgs[FParameters[I].ArgIndex], FParameters[I].Kind, FParameters[I].IsDateTime);
    LRelativeUrl := LRelativeUrl.Replace('{' + FParameters[I].Name + '}', TNetEncoding.URL.EncodeForm(LArgumentAsString), [rfReplaceAll]);
  end;
  if FKind in CMethodsWithBodyContent then
    LBodyContent := TStringList.Create
  else
    LBodyContent := nil;
  try
    if Assigned(LBodyContent) then
    begin
      if FBodyArgIndex > -1 then
      begin
        if FBodyKind in [TTypeKind.tkClass, TTypeKind.tkInterface, TTypeKind.tkMRecord, TTypeKind.tkRecord] then
          LBodyContent.Text := AJsonSerializer.Serialize(AArgs[FBodyArgIndex])
        else
          LBodyContent.Text := GetStringValue(AArgs[FBodyArgIndex], FBodyKind, FBodyIsDateTime);
      end
      else
        LBodyContent.Text := '';
    end;
    LRelativeUrl := ABaseUrl + LRelativeUrl;

    if FKind in CMethodsWithoutResponseContent then
      LResponseContent := nil
    else
      LResponseContent := TBytesStream.Create;
    try
      case FKind of
        TMethodKind.Get: LResponse := AClient.Get(LRelativeUrl, LResponseContent, LHeaders);
        TMethodKind.Post: LResponse := AClient.Post(LRelativeUrl, LBodyContent, LResponseContent, nil, LHeaders);
        TMethodKind.Delete: LResponse := AClient.Delete(LRelativeUrl, LResponseContent, LHeaders);
        TMethodKind.Options: LResponse := AClient.Options(LRelativeUrl, LResponseContent, LHeaders);
        TMethodKind.Trace: LResponse := AClient.Trace(LRelativeUrl, LResponseContent, LHeaders);
        TMethodKind.Head: LResponse := AClient.Head(LRelativeUrl, LHeaders);
        TMethodKind.Put: LResponse := AClient.Put(LRelativeUrl, LBodyContent, LResponseContent, nil, LHeaders);
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

  function IsBodyParam(const AName: string; const AAttributtes: TArray<TCustomAttribute>): Boolean;
  var
    LBodyAttribute: BodyAttribute;
  begin
    Result := (AName = 'abody') or
      (AName = 'body') or
      (AName = 'bodycontent') or
      (AName = 'abodycontent') or
      (AName = 'content') or
      (AName = 'acontent');
    if not Result then
      Result := TRttiUtils.HasAttribute<BodyAttribute>(AAttributtes, LBodyAttribute);
  end;

  function IsDateTime(const ATypeInfo: PTypeInfo): Boolean; inline;
  begin
    Result := (ATypeInfo = System.TypeInfo(TDate)) or
      (ATypeInfo = System.TypeInfo(TDateTime)) or (ATypeInfo = System.TypeInfo(TTime));
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
  LHeadersAttribute: HeadersAttribute;
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
    if TRttiUtils.HasAttribute<HeadersAttribute>(ARttiParameters[I].GetAttributes, LHeadersAttribute) then
      raise EipRestService.CreateFmt('Argument %s have a invalid type in method %s', [ARttiParameters[I].Name, FQualifiedName]);
    LIsDateTime := IsDateTime(ARttiParameters[I].ParamType.Handle);
    if TRttiUtils.HasAttribute<HeaderAttribute>(ARttiParameters[I].GetAttributes, LHeaderAttribute) then
    begin
      SetLength(FHeaderParameters, Length(FHeaderParameters) + 1);
      FHeaderParameters[Length(FHeaderParameters)-1] := TApiParam.Create(I + 1, LIsDateTime, ARttiParameters[I].ParamType.TypeKind, LHeaderAttribute.Name);
    end
    else
    begin
      if IsBodyParam(ARttiParameters[I].Name.ToLower, ARttiParameters[I].GetAttributes) then
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
    FResultTypeInfo := ARttiReturnType.Handle;
    FResultIsDateTime := IsDateTime(ARttiReturnType.Handle);
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
  const AMethods: TObjectDictionary<Pointer, TApiMethod>; const ATypeInfo: PTypeInfo);
begin
  inherited Create;
  FBaseUrl := ABaseUrl;
  FIID := AIID;
  FMethods := AMethods;
  FTypeInfo := ATypeInfo;
end;

destructor TApiType.Destroy;
begin
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

function TApiType.GetTypeInfo: PTypeInfo;
begin
  Result := FTypeInfo;
end;

{ TApiVirtualInterface }

procedure TApiVirtualInterface.CallApi(const AMethodHandle: Pointer;
  const AArgs: TArray<TValue>; var AResult: TValue);
var
  LAccept: string;
  LAsync: Boolean;
  LMethod: TApiMethod;
begin
  if not FApiType.Methods.TryGetValue(AMethodHandle, LMethod) then
    raise EipRestService.Create('Unexpected error calling the api');
  FCallLock.Enter;
  try
    LAccept := FClient.Accept;
    LAsync := FClient.Asynchronous;
    FClient.Accept := 'application/json';
    FClient.Asynchronous := False;
    try
      LMethod.CallApi(FClient, FBaseUrl, FJsonSerializer, AArgs, AResult);
    finally
      FClient.Asynchronous := LAsync;
      FClient.Accept := LAccept;
    end;
  finally
    FCallLock.Leave;
  end;
end;

constructor TApiVirtualInterface.Create(const AApiType: IApiType;
  const AClient: TNetHTTPClient; const ABaseUrl: string);
begin
  inherited Create(AApiType.TypeInfo,
    procedure(AMethod: TRttiMethod; const AArgs: TArray<TValue>; out AResult: TValue)
    begin
      TApiVirtualInterface(AArgs[0].AsInterface).CallApi(AMethod.Handle, AArgs, AResult);
    end);
  FCallLock := TCriticalSection.Create;
  FApiType := AApiType;
  FBaseUrl := ABaseUrl.Trim;
  if FBaseUrl.IsEmpty then
    FBaseUrl := AApiType.BaseUrl
  else if FBaseUrl.EndsWith('/') then
    FBaseUrl := FBaseUrl.Substring(0, Length(FBaseUrl)-1).TrimRight;
  if FBaseUrl.IsEmpty then
    raise EipRestService.Create('Invalid base url. The base url can be set as an argument or declaring the attribute [BaseUrl(?)] above the apiinterface service');
  FJsonSerializer := TApiJsonSerializer.Create;
  if Assigned(AClient) then
    FClient := AClient
  else
  begin
    FClient := TNetHTTPClient.Create(nil);
    FClientOwn := True;
  end;
end;

destructor TApiVirtualInterface.Destroy;
begin
  FCallLock.Free;
  if FClientOwn then
    FClient.Free;
  FJsonSerializer.Free;
  inherited;
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
  LBaseUrlAttr: BaseUrlAttribute;
  LContext: TRttiContext;
  LRttiType: TRttiType;
  LRttiMethods: TArray<TRttiMethod>;
  LRttiMethod: TRttiMethod;
  LMethods: TObjectDictionary<Pointer, TApiMethod>;
  LInterfaceHeaders: TNameValueArray;
  LHeadersAttributes: TArray<HeadersAttribute>;
  LIID: TGUID;
  LBaseUrl: string;
  I: Integer;
begin
  LMethods := TObjectDictionary<Pointer, TApiMethod>.Create([doOwnsValues]);
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

    repeat
      LRttiMethods := LRttiType.GetMethods;
      for LRttiMethod in LRttiMethods do
      begin
        if LMethods.ContainsKey(LRttiMethod.Handle) then
          raise EipRestService.Create('Unexpected error adding two duplicated methods');
        LMethods.Add(LRttiMethod.Handle, TApiMethod.Create(LRttiType.Name + '.' + LRttiMethod.Name, LInterfaceHeaders, LRttiMethod.GetParameters, LRttiMethod.ReturnType, LRttiMethod.GetAttributes));
      end;
      LRttiType := LRttiType.BaseType;
    until LRttiType = nil;
  finally
    LContext.Free;
  end;
  if LMethods.Count = 0 then
    raise EipRestService.Create('The interface type don''t have methods or {$M+} directive or is not descendent from IipRestApi');
  if LIID.IsEmpty then
    raise EipRestService.Create('The interface type must have one GUID');
  Result := TApiType.Create(LBaseUrl, LIID, LMethods, ATypeInfo);
end;

destructor TRestServiceManager.Destroy;
begin
  {$IF CompilerVersion < 34.0}
  FLock.Free;
  {$ENDIF}
  if Assigned(FApiTypeMap) then
    FApiTypeMap.Free;
  inherited;
end;

procedure TRestServiceManager.MakeFor(const ATypeInfo: Pointer;
  const AClient: TNetHTTPClient; const ABaseUrl: string; out AResult);
var
  LInterface: IInterface;
  LApiType: IApiType;
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

  LInterface := TApiVirtualInterface.Create(LApiType, AClient, ABaseUrl);
  if not Supports(LInterface, LApiType.IID, AResult) then
    raise EipRestService.Create('Unexpected error creating the service');
end;

initialization
  GRestService := TRestServiceManager.Create;
finalization
  FreeAndNil(GRestService);
end.
