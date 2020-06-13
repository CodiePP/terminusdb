:- module(resolve_query_resource,[
              resolve_string_descriptor/3,
              resolve_absolute_descriptor/2,
              resolve_relative_descriptor//2,
              resolve_relative_descriptor/3,
              resolve_absolute_string_descriptor/2,
              resolve_relative_string_descriptor/3,
              resolve_absolute_string_descriptor_and_graph/3,
              resolve_filter/2
          ]).

/** <module> Resolve Query Resource
 *
 * Resolves resource URIs to the appropiate associated graph_descriptor.
 *
 */

:- use_module(core(util)).
:- use_module(core(triple)).

:- use_module(library(pcre)).

resolve_string_descriptor(Default_Descriptor, String, Descriptor) :-
    (   resolve_relative_string_descriptor(Default_Descriptor,
                                           String,
                                           Descriptor)
    ->  true
    ;   resolve_absolute_string_descriptor(String, Descriptor)).

resolve_absolute_descriptor(["terminus"], terminus_descriptor{}) :- !.
resolve_absolute_descriptor([terminus], terminus_descriptor{}) :- !.
resolve_absolute_descriptor([X, Label], Descriptor) :-
    ground(X),
    X = label,
    !,
    resolve_absolute_descriptor(["label", Label], Descriptor).
resolve_absolute_descriptor(["label", Label], label_descriptor{label: Label_String}) :-
    !,
    (   atom(Label)
    ->  atom_string(Label, Label_String)
    ;   Label = Label_String).
resolve_absolute_descriptor([User, Database, X], Descriptor) :-
    ground(X),
    X = '_meta',
    !,
    resolve_absolute_descriptor([User, Database, "_meta"],Descriptor).
resolve_absolute_descriptor([User, Database, "_meta"], database_descriptor{database_name: Database_Name}) :-
    !,
    (   atom(User)
    ->  User_Atom = User
    ;   freeze(User_Atom, atom_string(User_Atom, User)),
        freeze(User, atom_string(User_Atom, User))),

    (   atom(Database)
    ->  Database_Atom = Database
    ;  freeze(Database_Atom, atom_string(Database_Atom, Database)),
       freeze(Database, atom_string(Database_Atom, Database))),

    freeze(Database_Name, atom_string(Database_Name_Atom, Database_Name)),
    freeze(Database_Name_Atom, atom_string(Database_Name_Atom, Database_Name)),

    user_database_name(User_Atom, Database_Atom, Database_Name_Atom).
resolve_absolute_descriptor([User, Database, Repository, X], Descriptor) :-
    ground(X),
    X = '_commits',
    !,
    resolve_absolute_descriptor([User, Database, Repository, "_commits"],Descriptor).
resolve_absolute_descriptor([User, Database, Repository, "_commits"],
                            repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: Repository_String
                            })
:-
    !,
    (   atom(Repository)
    ->  atom_string(Repository, Repository_String)
    ;   freeze(Repository, string(Repository)),
        Repository = Repository_String),
    resolve_absolute_descriptor([User, Database, "_meta"], Database_Descriptor).
resolve_absolute_descriptor([User, Database, Repository, X, Branch], Descriptor) :-
    ground(X),
    X = branch,
    !,
    resolve_absolute_descriptor([User, Database, Repository, "branch", Branch], Descriptor).
resolve_absolute_descriptor([User, Database, Repository, "branch", Branch],
                            branch_descriptor{
                                repository_descriptor: Repository_Descriptor,
                                branch_name: Branch_String
                            })
:-
    !,
    (   var(Branch)
    ->  Branch = Branch_String
    ;   text_to_string(Branch, Branch_String)),
    resolve_absolute_descriptor([User, Database, Repository, "_commits"], Repository_Descriptor).
resolve_absolute_descriptor([User, Database, Repository, X, Commit], Descriptor) :-
    ground(X),
    X = commit,
    !,
    resolve_absolute_descriptor([User, Database, Repository, "commit", Commit], Descriptor).
resolve_absolute_descriptor([User, Database, Repository, "commit", Commit],
                            commit_descriptor{
                                repository_descriptor: Repository_Descriptor,
                                commit_id: Commit_String
                            })
:-
    !,
    (   var(Commit)
    ->  Commit = Commit_String
    ;   text_to_string(Commit, Commit_String)),
    resolve_absolute_descriptor([User, Database, Repository, "_commits"], Repository_Descriptor).
resolve_absolute_descriptor([User, Database],
                            Descriptor) :-
    !,
    resolve_absolute_descriptor([User, Database, "local", "branch", "master"], Descriptor).
resolve_absolute_descriptor([User, Database, Repository], Descriptor) :-
    !,
    resolve_absolute_descriptor([User, Database, Repository, branch, master], Descriptor).

:- begin_tests(resolve_absolute_string).
test(user_db) :-
    Address = ["a_user", "a_database"],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = branch_descriptor{
                     repository_descriptor: Repository_Descriptor,
                     branch_name: "master"
                 },
    Repository_Descriptor = repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: "local"
                            },
    Database_Descriptor = database_descriptor{
                              database_name:"a_user|a_database"
                          }.

test(user_db_repo) :-
    Address = ["a_user", "a_database", "a_remote"],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = branch_descriptor{
                     repository_descriptor: Repository_Descriptor,
                     branch_name: "master"
                 },
    Repository_Descriptor = repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: "a_remote"
                            },
    Database_Descriptor = database_descriptor{
                              database_name:"a_user|a_database"
                          }.
test(user_db_repo_branch) :-
    Address = ["a_user", "a_database", "a_remote", "branch", "a_branch"],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = branch_descriptor{
                     repository_descriptor: Repository_Descriptor,
                     branch_name: "a_branch"
                 },
    Repository_Descriptor = repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: "a_remote"
                            },
    Database_Descriptor = database_descriptor{
                              database_name:"a_user|a_database"
                          }.
test(user_db_repo_commits) :-
    Address = ["a_user", "a_database", "a_remote", "_commits"],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: "a_remote"
                            },
    Database_Descriptor = database_descriptor{
                              database_name:"a_user|a_database"
                          }.
test(user_db_meta) :-
    Address = ["a_user", "a_database", "_meta"],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = database_descriptor{
                     database_name:"a_user|a_database"
                 }.

:- end_tests(resolve_absolute_string).
:- begin_tests(resolve_absolute_atom).
test(user_db) :-
    Address = [a_user, a_database],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = branch_descriptor{
                     repository_descriptor: Repository_Descriptor,
                     branch_name: "master"
                 },
    Repository_Descriptor = repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: "local"
                            },
    Database_Descriptor = database_descriptor{
                              database_name:"a_user|a_database"
                          }.

test(user_db_repo) :-
    Address = [a_user, a_database, a_remote],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = branch_descriptor{
                     repository_descriptor: Repository_Descriptor,
                     branch_name: "master"
                 },
    Repository_Descriptor = repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: "a_remote"
                            },
    Database_Descriptor = database_descriptor{
                              database_name:"a_user|a_database"
                          }.
test(user_db_repo_branch) :-
    Address = [a_user, a_database, a_remote, branch, a_branch],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = branch_descriptor{
                     repository_descriptor: Repository_Descriptor,
                     branch_name: "a_branch"
                 },
    Repository_Descriptor = repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: "a_remote"
                            },
    Database_Descriptor = database_descriptor{
                              database_name:"a_user|a_database"
                          }.
test(user_db_repo_commits) :-
    Address = [a_user, a_database, a_remote, '_commits'],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = repository_descriptor{
                                database_descriptor: Database_Descriptor,
                                repository_name: "a_remote"
                            },
    Database_Descriptor = database_descriptor{
                              database_name:"a_user|a_database"
                          }.
test(user_db_meta) :-
    Address = [a_user, a_database, '_meta'],

    resolve_absolute_descriptor(Address, Descriptor),

    Descriptor = database_descriptor{
                     database_name:"a_user|a_database"
                 }.

:- end_tests(resolve_absolute_atom).

:- begin_tests(address_from_descriptor).
test(database_descriptor) :-
    Descriptor = database_descriptor{database_name: "a_user|a_database"},

    resolve_absolute_descriptor(Address, Descriptor),

    Address = ["a_user", "a_database", "_meta"].

test(repository_descriptor) :-
    Descriptor = repository_descriptor{
                     database_descriptor: Database_Descriptor,
                     repository_name: "a_repo"
                 },
    Database_Descriptor = database_descriptor{database_name: "a_user|a_database"},

    resolve_absolute_descriptor(Address, Descriptor),

    Address = ["a_user", "a_database", "a_repo", "_commits"].

test(branch_descriptor) :-
    Descriptor = branch_descriptor{
                     repository_descriptor: Repository_Descriptor,
                     branch_name: "a_branch"
                 },
    Repository_Descriptor = repository_descriptor{
                     database_descriptor: Database_Descriptor,
                     repository_name: "a_repo"
                 },
    Database_Descriptor = database_descriptor{database_name: "a_user|a_database"},

    resolve_absolute_descriptor(Address, Descriptor),

    Address = ["a_user", "a_database", "a_repo", "branch", "a_branch"].

test(commit_descriptor) :-
    Descriptor = commit_descriptor{
                     repository_descriptor: Repository_Descriptor,
                     commit_id: "a_commit_id"
                 },
    Repository_Descriptor = repository_descriptor{
                     database_descriptor: Database_Descriptor,
                     repository_name: "a_repo"
                 },
    Database_Descriptor = database_descriptor{database_name: "a_user|a_database"},

    resolve_absolute_descriptor(Address, Descriptor),

    Address = ["a_user", "a_database", "a_repo", "commit", "a_commit_id"].

:- end_tests(address_from_descriptor).

descriptor_parent(terminus_descriptor{}, _) :-
    throw(error(descriptor_has_no_parent(terminus_descriptor{}))).
descriptor_parent(root, _) :-
    throw(error(descriptor_has_no_parent(terminus_descriptor{}))).
descriptor_parent(terminus_descriptor{}, root) :- !.
descriptor_parent(user(_), root) :- !.
descriptor_parent(some_label, root) :- !.
descriptor_parent(branch_of(Parent), Parent) :- !.
descriptor_parent(commit_of(Parent), Parent) :- !.
descriptor_parent(Descriptor, some_label) :-
    label_descriptor{} :< Descriptor,
    !.
descriptor_parent(database_descriptor{database_name: Database_Name},
                  user(User)) :-
    !,
    user_database_name(User_Atom, _Database, Database_Name),
    atom_string(User_Atom, User).
descriptor_parent(Descriptor, Parent) :-
    repository_descriptor{ database_descriptor: Parent } :< Descriptor,
    !.
descriptor_parent(Descriptor, branch_of(Parent)) :-
    branch_descriptor{ repository_descriptor: Parent } :< Descriptor,
    !.
descriptor_parent(Descriptor, commit_of(Parent)) :-
    commit_descriptor{ repository_descriptor: Parent } :< Descriptor,
    !.

descriptor_user(root, _User) :-
    !,
    throw(error(descriptor_has_no_user)).
descriptor_user(Database_Descriptor, User) :-
    is_dict(Database_Descriptor),
    database_descriptor{database_name: Database_Name} :< Database_Descriptor,
    !,
    user_database_name(User_Atom, _Db, Database_Name),
    atom_string(User_Atom, User).
descriptor_user(user(User), User) :- !.
descriptor_user(Descriptor, User) :-
    descriptor_parent(Descriptor, Parent),
    descriptor_user(Parent, User).

descriptor_database(root, _Database_Descriptor) :-
    !,
    throw(error(descriptor_has_no_database)).
descriptor_database(Database_Descriptor, Database_Descriptor) :-
    is_dict(Database_Descriptor),
    database_descriptor{} :< Database_Descriptor,
    !.
descriptor_database(Descriptor, Database_Descriptor) :-
    descriptor_parent(Descriptor, Parent),
    descriptor_database(Parent, Database_Descriptor).

descriptor_repository(root, _Repository_Descriptor) :-
    !,
    throw(error(descriptor_has_no_repository)).
descriptor_repository(Repository_Descriptor, Repository_Descriptor) :-
    is_dict(Repository_Descriptor),
    repository_descriptor{} :< Repository_Descriptor,
    !.
descriptor_repository(Descriptor, Repository_Descriptor) :-
    descriptor_parent(Descriptor, Parent),
    descriptor_repository(Parent, Repository_Descriptor).

context_completion(terminus_descriptor{},
                   terminus_descriptor{}) :- !.
context_completion(Label_Context, Label_Context) :-
    label_descriptor{} :< Label_Context,
    !.
context_completion(Database_Context, Completion) :-
    database_descriptor{} :< Database_Context,
    !,
    Repo_Descriptor = repository_descriptor{
                          database_descriptor: Database_Context,
                          repository_name: "local"
                      },
    Completion = branch_descriptor{
                     repository_descriptor: Repo_Descriptor,
                     branch_name: "master"
                 }.
context_completion(Repository_Context, Completion) :-
    repository_descriptor{} :< Repository_Context,
    !,
    Completion = branch_descriptor{
                     repository_descriptor: Repository_Context,
                     branch_name: "master"
                 }.
context_completion(Branch_Context, Branch_Context) :-
    branch_descriptor{} :< Branch_Context,
    !.
context_completion(Commit_Context, Commit_Context) :-
    commit_descriptor{} :< Commit_Context.

resolve_relative_descriptor(root, _Descriptor, [], []) :-
    !,
    throw(error(address_resolve('tried to resolve root which is not a valid descriptor'))).
resolve_relative_descriptor(some_label, _Descriptor, [], []) :-
    !,
    throw(error(address_resolve('tried to resolve the label root which is not a valid descriptor'))).
resolve_relative_descriptor(user(_User), _Descriptor, [], []) :-
    !,
    throw(error(address_resolve('tried to resolve a user which is not a valid descriptor'))).
resolve_relative_descriptor(branch_of(_Repo), _Descriptor, [], []) :-
    !,
    throw(error(address_resolve('tried to resolve a branch root which is not a valid descriptor'))).
resolve_relative_descriptor(commit_of(_Repo), _Descriptor, [], []) :-
    !,
    throw(error(address_resolve('tried to resolve a commit root which is not a valid descriptor'))).
resolve_relative_descriptor(Context, Descriptor) -->
    [".."],
    !,
    { descriptor_parent(Context, Parent) },
    resolve_relative_descriptor(Parent, Descriptor).
resolve_relative_descriptor(_Context, Descriptor) -->
    ["_root"],
    !,
    resolve_relative_descriptor(root, Descriptor).
resolve_relative_descriptor(Context, Descriptor) -->
    ["_user"],
    !,
    { descriptor_user(Context, User) },
    resolve_relative_descriptor(user(User), Descriptor).
resolve_relative_descriptor(Context, Descriptor) -->
    ["_database"],
    !,
    { descriptor_database(Context, Database) },
    resolve_relative_descriptor(Database, Descriptor).
resolve_relative_descriptor(Context, Descriptor) -->
    ["_repository"],
    !,
    { descriptor_repository(Context, Repository) },
    resolve_relative_descriptor(Repository, Descriptor).
resolve_relative_descriptor(root, Descriptor) -->
    !,
    resolve_root_relative_descriptor(Descriptor).
resolve_relative_descriptor(some_label, Descriptor) -->
    % todo: perhaps ensure that label cannot be an encoded user/database pair
    % on the other hand, being able to do so may be a feature, as long as it's only allowed for admin users
    [ Label ],
    !,
    resolve_relative_descriptor(label_descriptor{label: Label},
                                Descriptor).
resolve_relative_descriptor(branch_of(Repo_Descriptor),
                            Descriptor) -->
    [ Branch_Name ],
    !,
    resolve_relative_descriptor(branch_descriptor{
                                    repository_descriptor: Repo_Descriptor,
                                    branch_name: Branch_Name
                                },
                                Descriptor).
resolve_relative_descriptor(commit_of(Repo_Descriptor),
                            Descriptor) -->
    [ Commit_Name ],
    !,
    resolve_relative_descriptor(commit_descriptor{
                                    repository_descriptor: Repo_Descriptor,
                                    commit_id: Commit_Name
                                },
                                Descriptor).
resolve_relative_descriptor(user(_), _Descriptor, [], []) :-
    !,
    throw(error(address_resolve('tried to resolve user which is not a valid descriptor'))).
resolve_relative_descriptor(Context, Descriptor, [], []) :-
    !,
    context_completion(Context, Descriptor).
resolve_relative_descriptor(user(User), Descriptor) -->
    !,
    resolve_user_relative_descriptor(User, Descriptor).
resolve_relative_descriptor(Context, Descriptor) -->
    { database_descriptor{} :< Context },
    !,
    resolve_database_relative_descriptor(Context, Descriptor).
resolve_relative_descriptor(Context, Descriptor) -->
    { repository_descriptor{} :< Context },
    !,
    resolve_repository_relative_descriptor(Context, Descriptor).
resolve_relative_descriptor(Context, Descriptor) -->
    { branch_descriptor{} :< Context },
    !,
    resolve_repository_relative_descriptor(Context.repository_descriptor, Descriptor).
resolve_relative_descriptor(Context, Descriptor) -->
    { commit_descriptor{} :< Context },
    !,
    resolve_repository_relative_descriptor(Context.repository_descriptor, Descriptor).

resolve_root_relative_descriptor(root) -->
    [ ".." ],
    !.
resolve_root_relative_descriptor(terminus_descriptor{}) -->
    [ "terminus" ],
    !.
resolve_root_relative_descriptor(Descriptor) --> 
    [ "label" ],
    !,
    resolve_relative_descriptor(some_label, Descriptor).
resolve_root_relative_descriptor(Descriptor) -->
    [ User ],
    !,
    resolve_relative_descriptor(user(User), Descriptor).

resolve_user_relative_descriptor(User, Descriptor) -->
    [ Db ],
    !,
    { user_database_name(User, Db, Database_Name_Atom),
      atom_string(Database_Name_Atom, Database_Name) },
    resolve_relative_descriptor(database_descriptor{
                                    database_name: Database_Name
                                }, Descriptor).
resolve_database_relative_descriptor(Context, Context) -->
    [ "_meta" ],
    !.
resolve_database_relative_descriptor(Context, Descriptor) -->
    [ Repository ],
    !,
    resolve_relative_descriptor(repository_descriptor{
                                    database_descriptor: Context,
                                    repository_name: Repository
                                },
                                Descriptor).

resolve_repository_relative_descriptor(Context, Context) -->
    [ "_commits" ],
    !.
resolve_repository_relative_descriptor(Context, Descriptor) -->
    [ "branch" ],
    !,
    resolve_relative_descriptor(branch_of(Context),
                                Descriptor).
resolve_repository_relative_descriptor(Context, Descriptor) -->
    [ "commit" ],
    !,
    resolve_relative_descriptor(commit_of(Context),
                                Descriptor).

:- begin_tests(absolute_and_relative_paths_equivalent).
test(terminus_descriptor) :-
    Address = ["terminus"],
    resolve_absolute_descriptor(Address, Descriptor1),
    resolve_relative_descriptor(root, Descriptor2, Address, []),
    Descriptor1 = Descriptor2.

test(label_descriptor) :-
    Address = ["label", "a_label"],
    resolve_absolute_descriptor(Address, Descriptor1),
    resolve_relative_descriptor(root, Descriptor2, Address, []),
    Descriptor1 = Descriptor2.

test(database_descriptor) :-
    Address = ["a_user", "a_database", "_meta"],
    resolve_absolute_descriptor(Address, Descriptor1),
    resolve_relative_descriptor(root, Descriptor2, Address, []),
    Descriptor1 = Descriptor2.

test(repository_descriptor) :-
    Address = ["a_user", "a_database", "a_repository", "_commits"],
    resolve_absolute_descriptor(Address, Descriptor1),
    resolve_relative_descriptor(root, Descriptor2, Address, []),
    Descriptor1 = Descriptor2.

test(branch_descriptor) :-
    Address = ["a_user", "a_database", "a_repository", "branch", "a_branch"],
    resolve_absolute_descriptor(Address, Descriptor1),
    resolve_relative_descriptor(root, Descriptor2, Address, []),
    Descriptor1 = Descriptor2.

test(commit_descriptor) :-
    Address = ["a_user", "a_database", "a_repository", "commit", "a_commit"],
    resolve_absolute_descriptor(Address, Descriptor1),
    resolve_relative_descriptor(root, Descriptor2, Address, []),
    Descriptor1 = Descriptor2.

:- end_tests(absolute_and_relative_paths_equivalent).

resolve_relative_descriptor(Context, Path, Descriptor) :-
    resolve_relative_descriptor(Context, Descriptor, Path, []).

resolve_absolute_string_descriptor(String, Descriptor) :-
    pattern_string_split('/', String, Path_Unfiltered),
    exclude('='(""), Path_Unfiltered, Path),
    resolve_absolute_descriptor(Path, Descriptor).

resolve_relative_string_descriptor(Context, String, Descriptor) :-
    pattern_string_split('/', String, Path_Unfiltered),
    exclude('='(""), Path_Unfiltered, Path),

    resolve_relative_descriptor(Context, Path, Descriptor).

resolve_absolute_string_descriptor_and_graph(String, Descriptor,Graph) :-
    pattern_string_split('/', String, Path_Unfiltered),
    exclude('='(""), Path_Unfiltered, Path),
    once(append(Descriptor_Path,[_Type,_Name],Path)),
    resolve_absolute_descriptor(Descriptor_Path, Descriptor),
    resolve_absolute_graph_descriptor(Path, Graph).

% Note: Currently we only have instance/schema/inference updates for normal and terminus graphs.
% so this resolution is limited to these types.
resolve_absolute_graph_descriptor([Account_ID, DB, Repo, "branch", Branch, Type, Name], Graph) :-
    !,
    user_database_name(Account_ID, DB, DB_Name),
    atom_string(DB_Name, DB_Name_Str),
    atom_string(Type_Atom, Type),
    Graph = branch_graph{ database_name : DB_Name_Str,
                          repository_name : Repo,
                          branch_name : Branch,
                          type : Type_Atom,
                          name : Name}.
resolve_absolute_graph_descriptor([Account_ID, DB, Repo, "commit", RefID, Type, Name], Graph) :-
    !,
    user_database_name(Account_ID, DB, DB_Name),
    atom_string(DB_Name, DB_Name_Str),
    atom_string(Type_Atom, Type),
    Graph = single_commit_graph{ database_name : DB_Name_Str,
                                 repository_name : Repo,
                                 commit_id : RefID,
                                 type : Type_Atom,
                                 name : Name}.
resolve_absolute_graph_descriptor(["terminus", Type, Name], Graph) :-
    atom_string(Type_Atom, Type),
    Graph = terminus_graph{ type : Type_Atom,
                            name : Name }.

%%
% resolve_filter(Filter_String,Filter) is det.
%
%  Turn a filter string into a a filter - used with 'from'
%
%  Syntax:
%
%  'schema/*' => search schema graphs
%  '{instance,schema}/*' => search the union of instance and schema
%  '*/*' => search everything
%  'instance/{foo,main}' => search in foo and main
%
resolve_filter(Filter_String,Filter) :-
    (   re_matchsub('^(?P<type>[^/]*)$', Filter_String, Resource_Dict,[])
    ->  atom_string(Type,Resource_Dict.type),
        Filter = type_filter{ types : [Type]}
    ;   re_matchsub('^\\*/\\*$', Filter_String, _Resource_Dict,[])
    ->  Filter = type_filter{ types : [instance, schema, inference]}
    ;   re_matchsub('^\\{(?P<types>[^}]*)\\}/\\*$', Filter_String, Resource_Dict,[])
    ->  pattern_string_split(',',Resource_Dict.types, Type_Strings),
        maplist(atom_string, Types, Type_Strings),
        forall(member(Type, Types),
               memberchk(Type, [instance,schema,inference])),
        Filter = type_filter{ types : Types }
    ;   re_matchsub('^(?P<type>[^/]*)/\\*$', Filter_String, Resource_Dict,[])
    ->  atom_string(Type, Resource_Dict.type),
        memberchk(Type, [instance,schema,inference]),
        Filter = type_filter{ types : [Type] }
    ;   re_matchsub('^(?P<type>[^/]*)/\\{(?P<names>[^\\}]*)\\}$', Filter_String, Resource_Dict,[])
    ->  pattern_string_split(',',Resource_Dict.names, Names),
        atom_string(Type,Resource_Dict.type),
        memberchk(Type, [instance,schema,inference]),
        Filter = type_name_filter{ type : Type,
                                   names: Names }
    ;   re_matchsub('^(?P<type>[^/]*)/(?P<name>[^/]*)$', Filter_String, Resource_Dict,[])
    ->  atom_string(Type, Resource_Dict.type),
        memberchk(Type, [instance,schema,inference]),
        Filter = type_name_filter{ type : Type,
                                   names : [Resource_Dict.name] }
    ).
