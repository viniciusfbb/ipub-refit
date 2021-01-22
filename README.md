# iPub Refit
<a href="https://www.embarcadero.com/products/delphi" title=""><img src="https://img.shields.io/static/v1?label=Delphi%20Supported%20Versions&message=10.2%2B&color=blueviolet&style=for-the-badge"></a> <a href="http://docwiki.embarcadero.com/PlatformStatus/en/Main_Page" title=""><img src="https://img.shields.io/static/v1?label=Supported%20platforms&message=Full%20Cross-Platform&color=blue&style=for-the-badge"></a>

The iPub Refit is a library to consume REST services in a very simple way, declaring only one interface and is created by the iPub team.

This project inspired / based on the existing [Refit in .Net], and it turns your REST API into a live interface:

  ```delphi
  TUser = record
    name: string;
    location: string;
    id: Integer;
  end;

  [BaseUrl('https://api.github.com')]
  IGithubApi = interface(IipRestApi)
    ['{4C3B546F-216D-46D9-8E7D-0009C0771064}']
    [Get('/users/{aUser}')]
    function GetUser(const AUser: string): TUser;
    [Get('/users/{aUser}')]
    function GetUserJson(const AUser: string): string;
  end;
  ```
  
The GRestService instance generates an implementation of IGitHubApi that internally uses TNetHTTPClient to make its calls:

  ```delphi
  var
    LGithubApi: IGithubApi;
    LUser: TUser;
  begin
    LGithubApi := GRestService.&For<IGithubApi>;
    LUser := LGithubApi.GetUser('viniciusfbb');
    Showmessage(LGithubApi.GetUserJson('viniciusfbb'));
  ```

## Using
  #### Interface
  To declare the rest api interface, there are two obligations:
  - The interface must be descendent of the IipRestApi or be declared inside a {$M+} directive.
  - The interface must have one IID (GUID).
    
  #### Methods
  The methods of the rest api interface can be a procedure or a function returning a string, record, class, dynamic array of record or dynamic array of class. The method name don't matter. To declare you should declare an attribute informing the method kind and relative url
  You should declare the method kind of the interface method and the relative url
  ```delphi
  [Get('/users/{AUser}')]
  function GetUserJson(const AUser: string): string;
  [Post('/users/{AUser}?message={AMessage}')]
  function GetUserJson(const AUser, AMessage: string): string;
  ```
  All standard methods are supported (Get, Post, Delete, Options, Trace, Head, Put).
  
  The relative url can have masks {argument_name}, in anywhere and can repeat, to mark where an argument can be inserted. More details in the next topic.

  #### Methods arguments
  In your rest api interface, the arguments name of methods will be used to replace the masks {argument_name} in relative url. In this step we permit case insensitive names and names without the first letter A of argument names used commonly in delphi language. So, this cases will have the same result:
  ```delphi
    [Get('/users/{AUser}')]
    function GetUser(const AUser: string): TUser;
    [Get('/users/{aUser}')]
    function GetUser(const AUser: string): TUser;
    [Get('/users/{User}')]
    function GetUser(const AUser: string): TUser;
    [Get('/users/{user}')]
    function GetUser(const AUser: string): TUser;
  ```
  If the argument name is ```Body```, ```ABody```, ```BodyContent```, ```ABodyContent```, ```Content``` or ```AContent```, the argument will be used as the body of the request. You can also declare other name and use the attribute [Body] in this argument. When a argument is a body, no matter the argument type, it will be casted to string. If it is a record or class, we will serialize it to a json automatically.
  Remember that the mask {argument_name} in relative url, can be in anywhere, including inside queries, and can repeat.
  
  The type of the argument don't matter, we will cast to string automatically. So you can use, for example, an integer parameter:
  ```delphi
    [Get('/users/{AUserId}')]
    function GetUser(const AUserId: Integer): string;
  ```

  #### Base Url
  
  You can declare optionally the base url using the attribute [BaseUrl('xxx')] before the interface:
  ```delphi
  [BaseUrl('https://api.github.com')]
  IGithubApi = interface(IipRestApi)
    ['{4C3B546F-216D-46D9-8E7D-0009C0771064}']
  end;
  ```
  Or you can set directly when the rest service generate a new rest api interface, this is the first base url that the service will consider:
  ```delphi
  LGithubApi := GRestService.&For<IGithubApi>('https://api.github.com');
  ```
  
  #### Headers
  You can declare the headers necessary in the api interface and method. To the declare static headers that will be used in all api call, just declare above the interface:
  ```delphi  
  [Headers('User-Agent', 'Awesome Octocat App')]
  [Headers('Header-A', '1')]
  IGithubApi = interface(IipRestApi)
    ['{4C3B546F-216D-46D9-8E7D-0009C0771064}']
  end;
  ```
  To the declare static headers that will be used in one api method, just declare above the interface:
  ```delphi  
  IGithubApi = interface(IipRestApi)
    ['{4C3B546F-216D-46D9-8E7D-0009C0771064}']
    [Headers('Header-A', '1')]
    [Get('/users/{AUser}')]
    function GetUserJson(const AUser: string): string;
  end;
  ```
  Note: you can declare many [Headers] attribute in one method or in one rest api interface.
  
  But to declare dynamic headers, you will need to declare the [Header] attribute in the parameter declaration:
  ```delphi
  IGithubApi = interface(IipRestApi)
    ['{4C3B546F-216D-46D9-8E7D-0009C0771064}']
    [Post('/users/{AUser}')]
    function GetUserJson(const AUser: string; [Header('Authorization')] const AAuthToken: string): string;
  end;
  ```
  
  #### Authentication
  If the api need some kind of authentication, you can implement it before create the rest api interface, using the TNetHTTPClient, and creating the rest api interface passing it as argument:
  ```delphi
  var
    LClient: TNetHTTPClient;
    LGithubApi: IGithubApi;
  begin
    LClient := TNetHTTPClient.Create(nil);
    try
      // Do the authentication steps
      ...
      LGithubApi := GRestService.&For<IGithubApi>(LClient);
      Showmessage(LGithubApi.GetUserJson('viniciusfbb'));
    finally
      LClient.Free;
    end;
  end;
  ```
  
  #### Functional example
  ```delphi
  uses
    iPub.Rtl.Refit;

  type
    TUser = record
      Name: string;
      Location: string;
      Id: Integer;
    end;

    TRepository = record
      Name: string;
      Full_Name: string;
      Fork: Boolean;
      Description: string;
    end;

    TIssue = record
    public
      type
        TUser = record
          Login: string;
          Id: Integer;
        end;
        TLabel = record
          Name: string;
          Color: string;
        end;
    public
      Url: string;
      Title: string;
      User: TIssue.TUser;
      Labels: TArray<TIssue.TLabel>;
      State: string;
      Body: string;
    end;

    [BaseUrl('https://api.github.com')]
    IGithubApi = interface(IipRestApi)
      ['{4C3B546F-216D-46D9-8E7D-0009C0771064}']
      [Get('/users/{user}')]
      function GetUser(const AUser: string): TUser;
      [Get('/users/{user}/repos')]
      function GetUserRepos(const AUser: string): TArray<TRepository>;
      [Get('/repos/{repositoryOwner}/{repositoryName}/issues?page={page}')]
      function GetRepositoryIssues(const ARepositoryOwner, ARepositoryName: string; APage: Integer = 1): TArray<TIssue>;
      [Get('/repos/{repositoryOwner}/{repositoryName}/issues?page={page}&state=open')]
      function GetRepositoryIssuesOpen(const ARepositoryOwner, ARepositoryName: string; APage: Integer = 1): TArray<TIssue>;
    end;

  procedure TForm1.FormCreate(Sender: TObject);
  var
    LGithubApi: IGithubApi;
    LUser: TUser;
    LRepos: TArray<TRepository>;
    LIssues: TArray<TIssue>;
  begin
    LGithubApi := GRestService.&For<IGithubApi>;
    LUser := LGithubApi.GetUser('viniciusfbb');
    LRepos := LGithubApi.GetUserRepos('viniciusfbb');
    LIssues := LGithubApi.GetRepositoryIssues('rails', 'rails');
    LIssues := LGithubApi.GetRepositoryIssuesOpen('rails', 'rails', 2);
  end;
  ``` 

  #### Using json attributes
  The types used in your interface can use the json attributes normally. All attributes of the unit System.JSON.Serializers are allowed. Example:
  ```delphi
  uses
    iPub.Rtl.Refit, System.JSON.Serializers;

  type
    TRepository = record
      Name: string;
      [JsonName('full_name')] FullName: string;
      Fork: Boolean;
      Description: string;
    end;

    [BaseUrl('https://api.github.com')]
    IGithubApi = interface(IipRestApi)
      ['{4C3B546F-216D-46D9-8E7D-0009C0771064}']
      [Get('/users/{user}/repos')]
      function GetUserRepos(const AUser: string): TArray<TRepository>;
    end;

  procedure TForm1.FormCreate(Sender: TObject);
  var
    LGithubApi: IGithubApi;
    LRepos: TArray<TRepository>;
  begin
    LGithubApi := GRestService.&For<IGithubApi>;
    LRepos := LGithubApi.GetUserRepos('viniciusfbb');
  end;
  ``` 

  #### Registering a custom json converter
  If you have a special type, that need a custom convert, you can create your own json converter descendent of the TJsonConverter in System.JSON.Serializers and register it in us library:
  ```delphi
  GRestService.RegisterConverters([TNullableStringConverter]);
  ```
  You will register just one time, preferably at initialization.

  #### Nullable types
  This library does not implement nullable types because there are several different implementations on the internet, several libraries already have their own nullable type. But with the possibility of registering custom json converters, it is easy to implement any type of nullable in the code to use together with this library. Here one example of one nullable type with the json converter:
  ```delphi
  unit ExampleOfNullables;

  interface

  uses
    System.Rtti, System.TypInfo, System.JSON.Serializers, System.JSON.Readers,
    System.JSON.Writers, System.JSON.Types, iPub.Rtl.Refit;

  type
    TNullable<T> = record
    strict private
      FIsNotNull: Boolean;
      function GetIsNull: Boolean;
      procedure SetIsNull(AValue: Boolean);
    public
      Value: T;
      property IsNull: Boolean read GetIsNull write SetIsNull;
    end;

  implementation

  type
    TNullableConverter<T> = class(TJsonConverter)
    public
      procedure WriteJson(const AWriter: TJsonWriter; const AValue: TValue; const ASerializer: TJsonSerializer); override;
      function ReadJson(const AReader: TJsonReader; ATypeInf: PTypeInfo; const AExistingValue: TValue;
        const ASerializer: TJsonSerializer): TValue; override;
      function CanConvert(ATypeInf: PTypeInfo): Boolean; override;
    end;

  { TNullable<T> }

  function TNullable<T>.GetIsNull: Boolean;
  begin
    Result := not FIsNotNull;
  end;

  procedure TNullable<T>.SetIsNull(AValue: Boolean);
  begin
    FIsNotNull := not AValue;
  end;

  { TNullableConverter<T> }

  function TNullableConverter<T>.CanConvert(ATypeInf: PTypeInfo): Boolean;
  begin
    Result := ATypeInf = TypeInfo(TNullable<T>);
  end;

  function TNullableConverter<T>.ReadJson(const AReader: TJsonReader;
    ATypeInf: PTypeInfo; const AExistingValue: TValue;
    const ASerializer: TJsonSerializer): TValue;
  var
    LNullable: TNullable<T>;
  begin
    if AReader.TokenType = TJsonToken.Null then
    begin
      LNullable.IsNull := True;
      LNullable.Value := Default(T);
    end
    else
    begin
      LNullable.IsNull := False;
      LNullable.Value := AReader.Value.AsType<T>;
    end;
    TValue.Make(@LNullable, TypeInfo(TNullable<T>), Result);
  end;

  procedure TNullableConverter<T>.WriteJson(const AWriter: TJsonWriter;
    const AValue: TValue; const ASerializer: TJsonSerializer);
  var
    LNullable: TNullable<T>;
    LValue: TValue;
  begin
    LNullable := AValue.AsType<TNullable<T>>;
    if LNullable.IsNull then
      AWriter.WriteNull
    else
    begin
      TValue.Make(@LNullable.Value, TypeInfo(T), LValue);
      AWriter.WriteValue(LValue);
    end;
  end;

  initialization
    GRestService.RegisterConverters([TNullableConverter<string>,
      TNullableConverter<Byte>, TNullableConverter<Word>,
      TNullableConverter<Integer>, TNullableConverter<Cardinal>,
      TNullableConverter<Single>, TNullableConverter<Double>,
      TNullableConverter<Int64>, TNullableConverter<UInt64>,
      TNullableConverter<TDateTime>, TNullableConverter<Boolean>,
      TNullableConverter<Char>]);
  end.
  ```

  Now, you can use the nullable with this library like:
  ```delphi
  uses
    iPub.Rtl.Refit, ExampleOfNullables;

  type
    TUser = record
      Name: TNullable<string>;
      Location: string;
      Id: Integer;
      Email: TNullable<string>;
    end;

    [BaseUrl('https://api.github.com')]
    IGithubApi = interface(IipRestApi)
      ['{4C3B546F-216D-46D9-8E7D-0009C0771064}']
      [Get('/users/{user}')]
      function GetUser(const AUser: string): TUser;
    end;

  // ...

  var
    LGithubApi: IGithubApi;
    LUser: TUser;
  begin
    LGithubApi := GRestService.&For<IGithubApi>;
    LUser := LGithubApi.GetUser('viniciusfbb');
    // Now you will see that LUser.Name.IsNull = False but the LUser.Email.IsNull = True
  ```

  #### Considerations
  The GRestService and the rest api interfaces created by it are thread safe.
  
  As the connections are synchronous, the ideal is to call the api functions in the background. If you have multiple threads you can also create multiple rest api interfaces for the same api, each one will have a different connection.


## Compatibility
This library full cross-platform and was made and tested on delphi Sydney 10.4, but it is likely to work on previous versions, probably in Delphi 10.2 Tokyo or newer.

## License
The iPub Refit is licensed under MIT, and the license file is included in this folder.

[Refit in .Net]: https://github.com/reactiveui/refit