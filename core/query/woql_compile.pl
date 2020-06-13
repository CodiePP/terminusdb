:- module(woql_compile,[
              lookup/3,
              lookup_backwards/3,
              compile_query/3,
              compile_query/4,
              empty_context/1,
              empty_context/2,
              filter_transaction_object_read_write_objects/3
          ]).

/** <module> WOQL Compile
 *
 * Core compiler for the WOQL query language.
 *
 * * * * * * * * * * * * * COPYRIGHT NOTICE  * * * * * * * * * * * * * * *
 *                                                                       *
 *  This file is part of TerminusDB.                                     *
 *                                                                       *
 *  TerminusDB is free software: you can redistribute it and/or modify   *
 *  it under the terms of the GNU General Public License as published by *
 *  the Free Software Foundation, under version 3 of the License.        *
 *                                                                       *
 *                                                                       *
 *  TerminusDB is distributed in the hope that it will be useful,        *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of       *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
 *  GNU General Public License for more details.                         *
 *                                                                       *
 *  You should have received a copy of the GNU General Public License    *
 *  along with TerminusDB.  If not, see <https://www.gnu.org/licenses/>. *
 *                                                                       *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

:- use_module(inference).
:- use_module(frame, [
                  update_object/3,
                  delete_object/2
              ]).
:- use_module(jsonld).
:- use_module(json_woql).
% We may need to patch this in again...
%:- use_module(ask), [enrich_graph_fragment/5]).
:- use_module(global_prefixes, [default_prefixes/1]).
:- use_module(resolve_query_resource).
:- use_module(path).
:- use_module(metadata).

:- use_module(core(util)).
% Get op precedence
:- reexport(core(util/syntax)).

:- use_module(core(account)).
:- use_module(core(triple)).
:- use_module(core(transaction)).

%:- use_module(core(validation/schema)).
:- use_module(core(validation)).

:- use_module(library(http/json)).
:- use_module(library(http/json_convert)).
:- use_module(library(solution_sequences)).
:- use_module(library(http/http_log)).

:- use_module(library(apply)).
:- use_module(library(yall)).
:- use_module(library(apply_macros)).

:- use_module(check_types).

/*
 * Ctx is a context object which is used in WOQL queries to
 * keep track of state.
 *
 *******
 * TODO: This is complicated, punt to later
 *
 * store_id --> store_id{ descriptor : graph_descriptor,
 *                        id : integer }
 * store_ids = list(store_id)
 *
 * woql_var ---> woql_var{ prolog_var : var,
 *                         store_ids : store_ids }
 ******
 *
 * woql_var ---> var % currently snarfing prolog unification
 *
 * var_binding ---> var_binding{ woql_var : woql_var,
 *                               var_name : atom }
 *
 * resource_binding --> resource_set{ value : list(descriptor), woql_var : var }
 *                    | resource{ value : descriptor, woql_var : var }
 *
 * compiler_context ---> compiler_context{ <write_graph : graph_descriptor>,
 *                                         <default_collection : collection_descriptor>,
 *                                         filter : graph_filter,
 *                                         bindings : list(var_binding),
 *                                         selected : list(var_binding),
 *                                         resources : list(resource_binding),
 *                                         files : list(file_descriptors)
 *                                       }
 */

/*
 * merge(S0,S1,SM) is det.
 *
 * We need to merge multiple states into a signal state for output.
 *
 * we use S0 as the "merge in set"
 */
merge_states(S0) -->
    { B0 = (S0.get(bindings)),
      R0 = (S0.get(resources)) },

    view(bindings,B1),
    view(resources,R1),

    { merge_output_bindings(B0,B1,Bindings),
      merge_resource_bindings(R0,R1,Resources) },

    put(bindings,Bindings),
    put(resources,Resources).


unify_same_named_vars([],_Var).
unify_same_named_vars([Var1|Vars],Var) :-
    (   var_compare((=), Var, Var1)
    ->  Var = Var1
    ;   true),
    unify_same_named_vars(Vars,Var).

unify_output_bindings([], _).
unify_output_bindings([Var|Vars], Bindings) :-
    unify_same_named_vars(Bindings,Var),
    unify_output_bindings(Vars, Bindings).

merge_output_bindings(B0, B1, Bindings) :-
    unify_output_bindings(B0,B1),
    append(B0, B1, All),
    predsort(var_compare, All, Bindings).

unify_identical_resource([], _).
unify_identical_resource([Resource|Resources], Resource1) :-
    ignore(Resource = Resource1),
    unify_identical_resource(Resources, Resource1).

unify_resource_bindings([], _).
unify_resource_bindings([Resource|Resources], Resources1) :-
    unify_identical_resource(Resources1,Resource),
    unify_resource_bindings(Resources,Resources1).

merge_resource_bindings(B0, B1, Bindings) :-
    unify_resource_bindings(B0, B1),
    append(B0, B1, All),
    predsort(compare, All, Bindings).

/******************************
 * Binding management utilities
 ******************************/

/* Lookup a variable by name */
lookup(Var_Name,Prolog_Var,[Record|_B0]) :-
    var_record_pl_var(Var_Name,Record,Prolog_Var),
    !.
lookup(Var_Name,Prolog_Var,[_Record|B0]) :-
    lookup(Var_Name,Prolog_Var,B0).

lookup_or_extend(Var_Name, Prolog_Var) -->
    update(bindings,B0,B1),
    {
        (   lookup(Var_Name, Prolog_Var, B0)
        ->  B1=B0
        ;   B1=[var_binding{
                    woql_var : Prolog_Var,
                    var_name : Var_Name}
                |B0])
    }.

lookup_backwards(Prolog_Var,Var_Name,[var_binding{woql_var: _Woql_Var, prolog_var: Binding_Var, var_name: Var_Name}|_]) :-
    Prolog_Var == Binding_Var,
    !.
lookup_backwards(Prolog_Var,Var_Name,[_|Records]) :-
    lookup_backwards(Prolog_Var, Var_Name, Records).

resolve_prefix(Pre,Suf,URI) -->
    view(prefixes,Prefixes),
    {
        (   Full_Prefix = Prefixes.get(Pre)
        ->  true
        ;   format(atom(M), 'Unresolvable prefix ~q', [Pre:Suf]),
            throw(error(syntax_error(M))))
    },
    (   {v(Var_Name) = Suf}
    ->  view(bindings, Bindings),
        { lookup(Var_Name, Var, Bindings),
          freeze(URI, uri_to_prefixed(URI, Prefixes, Pre:Var))
        }
    ;   {atomic_list_concat([Full_Prefix,Suf],URI)}
    ).

variable_resolve(Var_Name,Variable) -->
    lookup_or_extend(Var_Name,Variable).

type_resolve(v(Var_Name), Variable, true) -->
    variable_resolve(Var_Name,Variable).
type_resolve(type(Type), Result, Goal) -->
    { Goal = basetype_subsumption_of(Type, Result) }.

language_resolve(v(Var_Name),Variable) -->
    variable_resolve(Var_Name,Variable).
language_resolve(lang(String),String)  --> {true}.

base_literal_resolve(v(Var_Name),Variable) -->
    variable_resolve(Var_Name,Variable).
base_literal_resolve(base(String),String) --> {true}.

% NOTE: This is wrong. Resources need to be compiled to
% a representation with a descriptor
register_resource(Uri, Var) -->
    update(resources,Old,New),
    { (   memberchk(Uri=Var, Old)
      ->  Old = New
      ;   New = [Uri=Var|Old])
    }.

literal_resolve(X@L, XS@LE, true) -->
    base_literal_resolve(X, XS),
    language_resolve(L, LE).
literal_resolve(X^^T, XE^^TE, Goal) -->
    base_literal_resolve(X,XE),
    type_resolve(T, TE, Goal).

term_resolve(v(Var_Name), Variable, true) -->
    variable_resolve(Var_Name, Variable).
term_resolve(l(Literal), Variable, Goal) -->
    literal_resolve(Literal,Variable,Goal).
term_resolve(r(Uri), Var, true) -->
    register_resource(Uri, Var).
term_resolve(n(Uri), n(Uri), true) -->
    { true }.


resolve(Element-Term,Mode-Type,(Mode_Goal,Type_Goal,Term_Goal)-true) -->
    term_resolve(Element,Term,Term_Goal),
    { mode_check(Element,Mode,Term,Mode_Goal),
      do_or_die(
          type_check(Element,Type,Term,Type_Goal),
          error(woql_type_error(Element,Term,Type)))
    }.


/*
 * compile_representation(S,T,V) is det.
 *
 * Gives the internal representation of some type T from some string S.
 */

compile_representation(String,Type,String^^Type) :-
    var(Type),
    !.
compile_representation(String,'http://www.w3.org/2001/XMLSchema#dateTime',Date) :-
    !,
    guess_date(String,Date).
compile_representation(String,Type,String^^Type).

var_record_pl_var(Var_Name,
                  var_binding{
                      woql_var : Prolog_Var,
                      var_name : Var_Name},
                  Prolog_Var).
var_record_pl_var(Var_Name,
                  var_binding{
                      woql_var : Prolog_Var,
                      prolog_var: _,
                      var_name : Var_Name},
                  Prolog_Var).

var_compare(Op, Left, Right) :-
    compare(Op, Left.var_name, Right.var_name).


compile_query(Term, Prog, Ctx_In, Ctx_Out) :-
    (   compile_wf(Term, Pre_Prog, Ctx_In, Ctx_Out),
        % Unsuspend all updates so they run at the end of the query
        % this is redundant if we do a pre-pass that sets the guard as well.
        Guard = Ctx_Out.update_guard,
        Prog = (Pre_Prog, Guard = true)
    ->  true
    ;   format(atom(M), 'Failure to compile term ~q', [Term]),
        throw(compilation_error(M))).

get_varname(Var,[X=Y|_Rest],Name) :-
    Y == Var,
    !,
    Name = X.
get_varname(Var,[_|Rest],Name) :-
    get_varname(Var,Rest,Name).

guess_varnames([],[]).
guess_varnames([X=Y|Rest],[X|Names]) :-
    var(Y),
    !,
    guess_varnames(Rest,Names).
guess_varnames([_|Rest],Names) :-
    guess_varnames(Rest,Names).

literal_string(Val^^_, Val).
literal_string(Val@_, Val).

% NOTE: Obviously this will not work
patch_binding(X,X).

patch_bindings([],[]).
patch_bindings([V=X|B0],[V=Y|B1]) :-
    patch_binding(X,Y),
    patch_bindings(B0,B1).

as_vars([],[]).
as_vars([as(_X,Y)|Rest],[Y|Vars]) :-
    as_vars(Rest,Vars).
as_vars([as(_X,Y,_T)|Rest],[Y|Vars]) :-
    as_vars(Rest,Vars).

position_vars([],[]).
position_vars([v(V)|Rest],[v(V)|Vars]) :-
    position_vars(Rest,Vars).

/* indexing_list(Spec,Header,Values,Bindings,Result) is det.
 *
 * A fold over Spec into Result
 */
indexing_as_list([],_,_,_,[]).
indexing_as_list([As_Clause|Rest],Header,Values,Bindings,[Term|Result]) :-
    (   As_Clause = as(N,v(V))
    ->  Type = none
    ;   As_Clause = as(N,v(V),Type)),
    lookup(V,Xe,Bindings),
    Term = (   nth1(Idx,Header,N)
           ->  (   nth1(Idx,Values,Value)
               ->  (   Type = none
                   ->  Value = Xe
                   ;   typecast(Value,Type,[],Xe))
               ;   format(string(Msg),"Too few values in get: ~q with header: ~q and values: ~q giving index: ~q creating prolog: ~q",[N,Header,Values,Idx, nth1(Idx,Values,Value)]),
                   throw(error(syntax_error(Msg),
                               context(indexing_as_list/5,_)))
               )
           ;   format(string(Msg),"No such indexed name in get: ~q with header: ~q and values: ~q giving",[N,Header,Values]),
               throw(error(syntax_error(Msg),
                           context(indexing_as_list/5,_)))
           ),
    indexing_as_list(Rest,Header,Values,Bindings,Result).

indexing_position_list([],_,_,_,[]).
indexing_position_list([v(V)|Rest],N,Values,Bindings,[Term|Result]) :-
    lookup(V,Xe,Bindings),
    Term = (   nth0(N,Values,Xe)
           ->  true
           ;   format(string(Msg),"No such index in get: ~q for values: ~q",[N,Values]),
               throw(error(syntax_error(Msg),
                           context(indexing_position_list/5,_)))
           ),
    M is N+1,
    indexing_position_list(Rest,M,Values,Bindings,Result).

indexing_term(Spec,Header,Values,Bindings,Indexing_Term) :-
    (   indexing_as_list(Spec,Header,Values,Bindings,Indexing_List)
    ;   indexing_position_list(Spec,0,Values,Bindings,Indexing_List),
        Header=false),
    list_conjunction(Indexing_List,Indexing_Term).

/*
 * woql_equal(AE,BE) is det.
 */
woql_equal(AE,BE) :-
    nonvar(AE),
    nonvar(BE),
    % Probably strictly should check subsumption
    % TODO: Lang!!! Foo@Bar
    AE = Y^^_T1,
    BE = Y^^_T2,
    !.
woql_equal(AE,BE) :-
    AE=BE.

/*
 * woql_less(AE,BE) is det.
 *
 * TODO: May need other cases.
 */
woql_less(X^^'http://www.w3.org/2001/XMLSchema#dateTime',
          Y^^'http://www.w3.org/2001/XMLSchema#dateTime') :-
    !,
    X @< Y.
woql_less(X^^T1,Y^^T2) :-
    basetype_subsumption_of(T1,'http://www.w3.org/2001/XMLSchema#decimal'),
    basetype_subsumption_of(T2,'http://www.w3.org/2001/XMLSchema#decimal'),
    !,
    X < Y.
woql_less(AE,BE) :-
    % dodgy - should switch on type
    compare((<),AE,BE).

/*
 * woql_greater(AE,BE) is det.
 *
 * TODO: May need other cases.
 */
woql_greater(X^^'http://www.w3.org/2001/XMLSchema#dateTime',
             Y^^'http://www.w3.org/2001/XMLSchema#dateTime') :-
    !,
    X @> Y.
woql_greater(X^^T1,
             Y^^T2) :-
    basetype_subsumption_of(T1,'http://www.w3.org/2001/XMLSchema#decimal'),
    basetype_subsumption_of(T2,'http://www.w3.org/2001/XMLSchema#decimal'),
    !,
    X > Y.
woql_greater(AE,BE) :-
    % dodgy - should switch on type
    compare((>),AE,BE).

/*
 * csv_term(Path,Has_Header,Header,Indexing,Prog,Options) is det.
 *
 * Create a program term Prog for a csv with Header and column reference strategy
 * Indexing.
 */
csv_term(Path,true,Header,Values,Indexing_Term,Prog,Options) :-
    Prog = (
        % header row only
        csv_read_file_row(Path, Header_Row, [line(1)|Options]),
        Header_Row =.. [_|Header]
    ->  csv_read_file_row(Path, Value_Row, [line(Line)|Options]),
        Line > 1,
        Value_Row =.. [_|Pre_Values],
        maplist(term_literal,Pre_Values,Values),
        Indexing_Term
    ),
    !.
csv_term(Path,false,_,Values,Indexing_Term,Prog,Options) :-
    Prog = (
        csv_read_file_row(Path, Value_Row, Options),
        Value_Row =.. [_|Pre_Values],
        maplist(term_literal,Pre_Values,Values),
        Indexing_Term
    ),
    !.
csv_term(Path,Has_Header,Header,Values,Indexing_Term,Prog,Options) :-
    format(atom(M),'Unknown csv processing options for "get" processing: ~q~n',
           [csv_term(Path,Has_Header,Header,Values,Indexing_Term,Prog,Options)]),
    throw(error(syntax_error(M),
                context(csv_term/7,Path))).

json_term(Path,Header,Values,Indexing_Term,Prog,_New_Options) :-
    setup_call_cleanup(
        open(Path,read,In),
        json_read_dict(In,Dict,[]),
        close(In)
    ),
    get_dict(columns,Dict,Pre_Header),
    maplist([Str,Atom]>>atom_string(Atom,Str),Pre_Header,Header),
    get_dict(data,Dict,Rows),
    Prog = (
        member(Row,Rows),
        maplist(term_literal,Row,Values),
        Indexing_Term
    ).


/*
 * bool_convert(+Bool_Id,-Bool) is det.
 * bool_convert(-Bool_Id,+Bool) is nondet.
 *
 * Converts a boolean representation from json.
 */
bool_convert(true,true).
bool_convert("true",true).
bool_convert(1,true).
bool_convert("false",false).
bool_convert(false,false).
bool_convert(0,false).

/*
 * convert_csv_options(+Options, -CSV_Options) is det.
 *
 * We need the various parsing options etc. to be implemented here
 * by converting from URI terms to proper CSV library terms.
 */
convert_csv_options(Options,CSV_Options) :-
    (   memberchk('http://terminusdb.com/woql#separator'(A),Options)
    ->  atom_codes(A,[C]),
        CSV_Options1 = [separator(C)]
    ;   CSV_Options1 = []),

    (   memberchk('http://terminusdb.com/woql#convert'(Bool_Str),Options)
    ->  bool_convert(Bool_Str,Bool),
        CSV_Options2 = [convert(Bool)|CSV_Options1]
    ;   CSV_Options2 = [convert(false)|CSV_Options1]),

    CSV_Options = CSV_Options2.

/*
 * turtle_term(Path,Values,Prog,Options) is det.
 *
 * Create a program term Prog for a csv with Header and column reference strategy
 * Indexing.
 */
turtle_term(Path,Vars,Prog,Options) :-
    Prog = (turtle:rdf_read_turtle(Path, Triples, [encoding(utf8)|Options]),
            member(Triple,Triples),
            literals:normalise_triple(Triple, rdf(X,P,Y)),
            Vars = [X,P,Y]).



/*
 *
 */

compile_goal(p(Predicate),Goal) -->
    compile_predicate(Predicate,Goal).
compile_goal((Q1,Q2),(Goal1,Goal2)) -->
    compile_goal(Q1,Goal1),
    compile_goal(Q2,Goal2).
compile_goal((Q1;Q2),(Goal1;Goal2)) -->
    peek(S0),
    compile_goal(Q1,Goal1),
    peek(S1),
    return(S0),
    compile_goal(Q2,Goal2),
    merge_states(S1).

compile_predicate(Predicate, Goal) -->
    { Predicate =.. [P|Args],
      length(Args,N) },
    compile_predicate_descriptor(P/N,Args,Goal).

is_true(true).

compile_predicate_descriptor(P/N,Args,Goal) -->
    { query_term_properties(P/N,System_P/N,Modes,Types),
      zip(Args,Resolved,Args_Resolved),
      zip(Modes,Types,Modes_Types) },
    mapm(resolve,Args_Resolved,Modes_Types,Pre_Goals_Post_Goals),
    
    { zip(Pre_Goals, Post_Goals, Pre_Goals_Post_Goals),
      (   Resource
      ->  lookup_resource(Resource_Var)
      Predicate_Goal =.. [System_P|Resolved],
      append([Pre_Goals,[Predicate_Goal],Post_Goals], Goal_List),
      xfy_list(',',Goal, Goal_List) }.

mode_check_var(ground,Var,Term,
               (do_or_die(
                    ground(Term),
                    error(instantiation_error(Var,Term))))).
mode_check_var(any,_,_,true).

mode_check(v(Var),Type,Term,Goal) :-
    mode_check_var(Type,Var,Term,Goal).
mode_check(n(_),_,_,true).
mode_check(l(_),_,_,true).
mode_check(o(_),_,_,true).
mode_check(r(_),_,_,true).

type_check_node(node).
type_check_node(obj).

type_check_literal(literal).
type_check_literal(obj).

type_check(r(Term), resource, _, true) :-
    % Must be atom at compile time.
    do_or_die(
        the(atom,Term),
        error(woql_type_error(Term,resource))).
type_check(v(_), Type, Term, will_be(Type,Term)).
type_check(n(_), Type, _, true) :-
    type_check_node(Type).
type_check(l(_), Type, _, true) :-
    type_check_literal(Type).


query_term_properties(t/3,t//3,[any,any,any],[node,node,obj]).
query_term_properties(t/4,t//4,[any,any,any,ground],[node,node,obj,resource]).
query_term_properties(insert/3,insert//3,[any,any,any],[node,node,obj]).
query_term_properties(insert/4,insert//4,[any,any,any,ground],[node,node,obj,resource]).
query_term_properties(read_object/3,read_object//3,[node,number,dict]).

/*
compile_wf(read_object(Doc_ID,N,Doc),
           frame:document_jsonld(S0,URI,N,JSON)) -->
    assert_read_access,
    resolve(Doc_ID,URI),
    resolve(Doc,JSON),
    peek(S0). */
query_term_properties(read_object/2,read_object/2,[node,dict]).
/*
compile_wf(read_object(Doc_ID,Doc), frame:document_jsonld(S0,URI,JSON)) -->
    assert_read_access,
    resolve(Doc_ID,URI),
    resolve(Doc,JSON),
    peek(S0).
compile_wf(update_object(Doc),(
               freeze(Guard,
                      frame:update_object(DocE,S0)))) -->
    assert_write_access,
    resolve(Doc,DocE),
    view(update_guard, Guard),
    peek(S0).
compile_wf(update_object(X,Doc),(
               freeze(Guard,
                      frame:update_object(URI,DocE,S0)))) -->
    assert_write_access,
    resolve(X,URI),
    resolve(Doc,DocE),
    view(update_guard, Guard),
    peek(S0).
compile_wf(delete_object(X),(
               freeze(Guard,
                      frame:delete_object(URI,S0)))) -->
    assert_write_access,
    resolve(X,URI),
    view(update_guard, Guard),
    peek(S0).
% TODO: Need to translate the reference WG to a read-write object.
compile_wf(delete(X,P,Y,G),Goal)
-->
    view(default_collection,Collection_Descriptor),
    {
        ensure_filter_resolves_to_graph_descriptor(G, Collection_Descriptor, Graph_Descriptor)
    },
    update(write_graph,Old_Graph_Descriptor,Graph_Descriptor),
    compile_wf(delete(X,P,Y), Goal),
    update(write_graph, _, Old_Graph_Descriptor).
compile_wf(delete(X,P,Y),(
               freeze(Guard,
                      delete(Read_Write_Object,XE,PE,YE,_)
                     )
           ))
-->
    assert_write_access,
    resolve(X,XE),
    resolve(P,PE),
    resolve(Y,YE),
    view(write_graph,Graph_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(update_guard, Guard),
    {
       graph_descriptor_transaction_objects_read_write_object(Graph_Descriptor, Transaction_Objects, Read_Write_Object)
    }.
% TODO: Need to translate the reference WG to a read-write object.
compile_wf(insert(X,P,Y,G),Goal)
-->
    view(default_collection,Collection_Descriptor),
    {
        ensure_filter_resolves_to_graph_descriptor(G, Collection_Descriptor, Graph_Descriptor)
    },
    update(write_graph,Old_Graph_Descriptor,Graph_Descriptor),
    compile_wf(insert(X,P,Y), Goal),
    update(write_graph, _, Old_Graph_Descriptor).
compile_wf(insert(X,P,Y),(
               freeze(Guard,
                      insert(Read_Write_Object,XE,PE,YE,_))
           ))
-->
    assert_write_access,
    resolve(X,XE),
    resolve(P,PE),
    resolve(Y,YE),
    view(write_graph,Graph_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(update_guard, Guard),
    {
        graph_descriptor_transaction_objects_read_write_object(Graph_Descriptor, Transaction_Objects, Read_Write_Object)
    }.
compile_wf(A=B,woql_equal(AE,BE)) -->
    resolve(A,AE),
    resolve(B,BE).
compile_wf(A<B,woql_less(AE,BE)) -->
    resolve(A,AE),
    resolve(B,BE).
compile_wf(A>B,woql_greater(AE,BE)) -->
    resolve(A,AE),
    resolve(B,BE).
compile_wf(like(A,B,F), Isub) -->
    resolve(A,AE),
    resolve(B,BE),
    resolve(F,FE),
    { marshall_args(isub(AE,BE,true,FE), Isub) }.
compile_wf(isa(X,C),(instance_class(XE,D,Transaction_Object),
                     subsumption_of(D,CE,Transaction_Object))) -->
    resolve(X,XE),
    resolve(C,CE),
    view(default_collection,Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object)
    }.
compile_wf(A << B,(distinct([AE,BE], subsumption_of(AE,BE,Transaction_Object)))) -->
    resolve(A,AE),
    resolve(B,BE),
    view(default_collection,Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object)
    }.
compile_wf(opt(P), optional(Goal)) -->
    compile_wf(P,Goal).
compile_wf(addition(X,P,Y),Goal) -->
    assert_read_access,
    resolve(X,XE),
    resolve(P,PE),
    resolve(Y,YE),
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(filter, Filter),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object),
        filter_transaction(Filter, Transaction_Object, New_Transaction_Object),
        append([New_Transaction_Object.instance_objects,
                New_Transaction_Object.schema_objects,
                New_Transaction_Object.inference_objects], Objects),
        Goal = (not_literal(XE),not_literal(PE),xrdf_added(Objects, XE, PE, YE))
    }.
compile_wf(addition(X,P,Y,G),Goal) -->
    {
        resolve_filter(G,Filter)
    },
    update(filter, Old_Filter, Filter),
    compile_wf(addition(X,P,Y),Goal),
    update(filter, _, Old_Filter).
compile_wf(removal(X,P,Y),Goal) -->
    assert_read_access,
    resolve(X,XE),
    resolve(P,PE),
    resolve(Y,YE),
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(filter, Filter),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object),
        filter_transaction(Filter, Transaction_Object, New_Transaction_Object),
        append([New_Transaction_Object.instance_objects,
                New_Transaction_Object.schema_objects,
                New_Transaction_Object.inference_objects], Objects),
        Goal = (not_literal(XE),not_literal(PE),xrdf_deleted(Objects, XE, PE, YE))
    }.
compile_wf(removal(X,P,Y,G),Goal) -->
    {
        resolve_filter(G,Filter)
    },
    update(filter, Old_Filter, Filter),
    compile_wf(removal(X,P,Y), Goal),
    update(filter, _Filter, Old_Filter).
compile_wf(t(X,P,Y),Goal) -->
    assert_read_access,
    resolve(X,XE),
    resolve(P,PE),
    resolve(Y,YE),
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(filter, Filter),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object),
        filter_transaction_object_goal(Filter, Transaction_Object, t(XE, PE, YE), Search_Clause),
        Goal = (not_literal(XE),not_literal(PE),Search_Clause)
    }.
compile_wf(t(X,P,Y,G),Goal) -->
    {
        resolve_filter(G,Filter)
    },
    update(filter, Old_Filter, Filter),
    compile_wf(t(X,P,Y), Goal),
    update(filter, _Filter, Old_Filter).
compile_wf(path(X,Pattern,Y,Path),Goal) -->
    assert_read_access,
    resolve(X,XE),
    resolve(Y,YE),
    resolve(Path,PathE),
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(filter, Filter),
    view(prefixes,Prefixes),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object),
        filter_transaction(Filter, Transaction_Object, New_Transaction_Object),
        (   compile_pattern(Pattern,Compiled_Pattern,Prefixes,New_Transaction_Object)
        ->  true
        ;   throw(error(syntax_error('Unable to compile pattern', Pattern)))),
        Goal = (
            calculate_path_solutions(Compiled_Pattern,XE,YE,Full_Path,Filter,New_Transaction_Object),
            % Don't bind PathE until we're done with the full query (for constraints)
            Full_Path = PathE
        )
    }.
compile_wf((A;B),(ProgA;ProgB)) -->
    peek(S0),
    compile_wf(A,ProgA),
    peek(S1),
    return(S0),
    compile_wf(B,ProgB),
    merge(S1). % merges S1 back in to current state.
compile_wf((A,B),(ProgA,ProgB)) -->
    compile_wf(A,ProgA),
    compile_wf(B,ProgB),
    {
        debug(terminus(woql_compile(compile_wf)), 'Conjunctive Program: ~q',[(ProgA,ProgB)])
    }.
compile_wf(when(A,B),(ProgA,ProgB)) --> % forall(ProgA, ProgB)
    compile_wf(A,ProgA),
    compile_wf(B,ProgB).
compile_wf(select(VL,P), Prog) -->
    compile_wf(P, Prog),
    restrict(VL).
compile_wf(using(Collection_String,P),Goal) -->
    update(default_collection,Old_Default_Collection,Default_Collection),
    { resolve_string_descriptor(Old_Default_Collection,Collection_String,Default_Collection) },
    update_descriptor_transactions(Default_Collection),
    compile_wf(P, Goal),
    update(default_collection,_,Old_Default_Collection).
compile_wf(from(Filter_String,P),Goal) -->
    { resolve_filter(Filter_String,Filter) },
    update(filter,Old_Default_Filter,Filter),
    compile_wf(P, Goal),
    update(filter,_,Old_Default_Filter).
compile_wf(prefixes(NS,S), Prog) -->
    % Need to convert the datatype of prefixes here.
    debug_wf('DO YOU HEAR ME ~q', [NS]),
    update(prefixes,NS_Old,NS_New),
    { append(NS, NS_Old, NS_New) },
    compile_wf(S, Prog),
    update(prefixes,_,NS_Old).
% NOTE: DEPRECATED
compile_wf(with(GN,GS,Q), (Program, Sub_Query)) -->
    resolve(GN,GName),
    update(default_collection,Old_Default_Collection,Default_Collection),
    view(files,Files),
    % TODO: Extend with options for various file types.
    { file_spec_path_options(GS, Files, Path, _{}, Options),
      extend_database_with_temp_graph(GName,Path,Options,Program,Old_Default_Collection,Default_Collection)
    },
    compile_wf(Q,Sub_Query),
    update(default_collection,_,Old_Default_Collection).
compile_wf(get(Spec,File_Spec), Prog) -->
    {
        Default = _{
                      'http://terminusdb.com/woql#header' : "true",
                      'http://terminusdb.com/woql#type' : "csv"},

        (   as_vars(Spec,Vars),
            Has_Header = true
        ;   position_vars(Spec,Vars),
            Has_Header = false
        )
    },

    % Make sure all variables are given bindings
    mapm(resolve,Vars,BVars),
    view(bindings,Bindings),
    view(files,Files),
    {
        file_spec_path_options(File_Spec, Files, Path, Default, New_Options),
        convert_csv_options(New_Options,CSV_Options),

        (   memberchk('http://terminusdb.com/woql#type'("csv"),New_Options)
        ->  indexing_term(Spec,Header,Values,Bindings,Indexing_Term),
            csv_term(Path,Has_Header,Header,Values,Indexing_Term,Prog,CSV_Options)
        ;   memberchk('http://terminusdb.com/woql#type'("turtle"),New_Options),
            Has_Header = false
        ->  turtle_term(Path,BVars,Prog,CSV_Options)
        ;   memberchk('http://terminusdb.com/woql#type'("panda_json"),New_Options)
        ->  indexing_term(Spec,Header,Values,Bindings,Indexing_Term),
            json_term(Path,Header,Values,Indexing_Term,Prog,New_Options)
        ;   format(atom(M), 'Unknown file type for "get" processing: ~q', [File_Spec]),
            throw(error(M)))
    }.
compile_wf(put(Spec,Query,File_Spec), Prog) -->
    {
        maplist([Name as Var,Var,Name]>>(true), Spec, Vars, Names)
    },
    % Make sure all variables are bound
    mapm(resolve,Vars,VarsE),
    compile_wf(Query,Compiled_Query),
    {

        (   File_Spec = file(CSV_Path,Options)
        ;   File_Spec = file(CSV_Path),
            Options = []),

        Header_Row =.. [row|Names],

        Prog = setup_call_cleanup(
                   open(CSV_Path, write, Out),
                   (
                       csv_write_stream(Out,[Header_Row], Options),
                       forall(
                           (
                               Compiled_Query,
                               maplist([Value,Data]>>(
                                           (   Value=Data@_
                                           ->  true
                                           ;   Value=Data^^_
                                           ->  true
                                           ;   Data=Value)
                                       ),
                                       VarsE, Row_Data),
                               Row_Term =.. [row|Row_Data]
                           ),
                           csv_write_stream(Out,[Row_Term],Options)
                       )
                   ),
                   close(Out)
               )
    }.
compile_wf(where(P), Prog) -->
    compile_wf(P, Prog).
compile_wf(typecast(Val,Type,_Hints,Cast),
           (typecast(ValE, TypeE, [], CastE))) -->
    resolve(Val,ValE),
    resolve(Type,TypeE),
    resolve(Cast,CastE).
% Note: Should we not just make a transformer for marshalling?
compile_wf(hash(Base,Args,Id),(
               literally(BaseE,BaseL),
               literally(ArgsE,ArgsL),
               hash(BaseL,ArgsL,IdE),
               unliterally(BaseL,BaseE),
               unliterally(ArgsL,ArgsE)
           )) -->
    resolve(Base, BaseE),
    mapm(resolve,Args,ArgsE),
    resolve(Id,IdE).
compile_wf(random_idgen(Base,Args,Id),(
               literally(BaseE,BaseL),
               literally(ArgsE,ArgsL),
               random_idgen(BaseL,ArgsL,IdE),
               unliterally(BaseL,BaseE),
               unliterally(ArgsL,ArgsE)
           )) -->
    resolve(Base, BaseE),
    mapm(resolve,Args,ArgsE),
    resolve(Id,IdE).
compile_wf(idgen(Base,Args,Id),(
               literally(BaseE,BaseL),
               literally(ArgsE,ArgsL),
               idgen(BaseL,ArgsL,IdE),
               unliterally(BaseL,BaseE),
               unliterally(ArgsL,ArgsE)
           )) -->
    resolve(Base, BaseE),
    mapm(resolve,Args,ArgsE), % Note: How can we resolve this properly? Freeze?
    resolve(Id,IdE).
compile_wf(start(N,S),(literally(NE,Num),offset(Num,Prog))) -->
    resolve(N,NE),
    compile_wf(S, Prog).
compile_wf(limit(N,S),(literally(NE,Num),limit(Num,Prog))) -->
    resolve(N,NE),
    compile_wf(S, Prog).
compile_wf(asc(X),asc(XE)) -->
    resolve(X,XE).
compile_wf(desc(X),desc(XE)) -->
    resolve(X,XE).
compile_wf(order_by(L,S),order_by(LSpec,Prog)) -->
    mapm(compile_wf, L, LSpec),
    compile_wf(S, Prog).
compile_wf(into(G,S),Goal) -->
    % TODO: Resolve G to descriptor
    % swap in new graph
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object),
        resolve_filter(G,Filter),
        (   Filter = type_name_filter{ type : _Type, name : [_Name]}
        ->  filter_transaction_graph_descriptor(Filter, Transaction_Object, Graph_Descriptor)
        ;   format(atom(M), 'Unresolvable write filter: ~q', [G]),
            throw(error(syntax_error(M),
                        context(compile_wf//2, into/2)))
        )
    },
    update(write_graph,OG,Graph_Descriptor),
    compile_wf(S,Goal),
    % swap old graph back in
    update(write_graph,_,OG).
compile_wf(not(P),not(Q)) -->
    compile_wf(P, Q).
compile_wf(concat(L,A),Concat) -->
    resolve(L,LE),
    resolve(A,AE),
    { marshall_args(interpolate_string(LE,AE),Concat) }.
compile_wf(trim(S,A),Trim) -->
    resolve(S,SE),
    resolve(A,AE),
    { marshall_args(trim(SE,AE),Trim) }.
compile_wf(pad(S,C,N,V),Pad) -->
    resolve(S,SE),
    resolve(C,CE),
    resolve(N,NE),
    resolve(V,VE),
    { marshall_args(pad(SE,CE,NE,VE,Pad),Pad) }.
compile_wf(sub_string(S,B,L,A,Sub),Sub_String) -->
    resolve(S,SE),
    resolve(B,BE),
    resolve(L,LE),
    resolve(A,AE),
    resolve(Sub,SubE),
    { marshall_args(utils:sub_string(SE,BE,LE,AE,SubE),Sub_String) }.
compile_wf(re(P,S,L),Re) -->
    resolve(P,PE),
    resolve(S,SE),
    resolve(L,LE),
    { marshall_args(utils:re(PE,SE,LE),Re) }.
compile_wf(split(S,P,L),Split) -->
    resolve(S,SE),
    resolve(P,PE),
    resolve(L,LE),
    { marshall_args(utils:pattern_string_split(PE,SE,LE),Split) }.
compile_wf(upper(S,A),Upper) -->
    resolve(S,SE),
    resolve(A,AE),
    { marshall_args(string_upper(SE,AE), Upper) }.
compile_wf(lower(S,A),Lower) -->
    resolve(S,SE),
    resolve(A,AE),
    { marshall_args(string_lower(SE,AE),Lower) }.
compile_wf(format(X,A,L),format(atom(XE),A,LE)) -->
    % TODO: You can execute an arbitrary goal!!!!
    resolve(X,XE),
    mapm(resolve,L,LE).
compile_wf(X is Arith, (Pre_Term,
                        XA is ArithE,
                        XE = XA^^'http://www.w3.org/2001/XMLSchema#decimal')) -->
    resolve(X,XE),
    compile_arith(Arith,Pre_Term,ArithE).
compile_wf(dot(Dict,Key,Value), get_dict(KeyE,DictE,ValueE)) -->
    resolve(Dict,DictE),
    resolve(Key,KeyE),
    resolve(Value,ValueE).
compile_wf(group_by(WGroup,WTemplate,WQuery,WAcc),group_by(Group,Template,Query,Acc)) -->
    resolve(WGroup,Group),
    resolve(WTemplate,Template),
    compile_wf(WQuery, Query),
    resolve(WAcc,Acc).
compile_wf(length(L,N),Length) -->
    resolve(L,LE),
    resolve(N,NE),
    { marshall_args(length(LE,NE), Length) }.
compile_wf(member(X,Y),Member) -->
    resolve(X,XE),
    resolve(Y,YE),
    { marshall_args(member(XE,YE), Member) }.
compile_wf(join(X,S,Y),Join) -->
    resolve(X,XE),
    resolve(S,SE),
    resolve(Y,YE),
    { marshall_args(utils:join(XE,SE,YE), Join) }.
compile_wf(sum(X,Y),Sum) -->
    resolve(X,XE),
    resolve(Y,YE),
    { marshall_args(sumlist(XE,YE), Sum) }.
compile_wf(timestamp_now(X), (get_time(Timestamp)))
-->
    resolve(X,XE),
    {
        XE = Timestamp^^'http://www.w3.org/2001/XMLSchema#decimal'
    }.
compile_wf(size(Path,Size),Goal) -->
    resolve(Size,SizeE),
    {
        (   resolve_absolute_string_descriptor_and_graph(Path, Descriptor, Graph)
        ->  true
        ;   resolve_absolute_string_descriptor(Path, Descriptor),
            Graph = none
        )
    },
    update_descriptor_transactions(Descriptor),
    peek(Context),
    {
        Context_2 = (Context.put(_{ default_collection : Descriptor })),
        assert_read_access(Context_2),
        Transaction_Objects = (Context_2.transaction_objects),
        (   Graph = none
        ->  collection_descriptor_transaction_object(Descriptor,Transaction_Objects,
                                                     Transaction_Object),
            Goal = (transaction_object_size(Transaction_Object,Numerical_Size),
                    unliterally(Numerical_Size,SizeE))
        ;   graph_descriptor_transaction_objects_read_write_object(Graph, Transaction_Objects, Read_Write_Object),
            Goal = (read_object_size(Read_Write_Object,Numerical_Size),
                    unliterally(Numerical_Size,SizeE))
        )
    }.
compile_wf(triple_count(Path,Count),Goal) -->
    resolve(Count,CountE),
    {
        (   resolve_absolute_string_descriptor_and_graph(Path, Descriptor, Graph)
        ->  true
        ;   resolve_absolute_string_descriptor(Path, Descriptor),
            Graph = none
        )
    },
    update_descriptor_transactions(Descriptor),
    peek(Context),
    {
        Context_2 = (Context.put(_{ default_collection : Descriptor })),
        assert_read_access(Context_2),
        Transaction_Objects = (Context_2.transaction_objects),
        (   Graph = none
        ->  collection_descriptor_transaction_object(Descriptor,Transaction_Objects,
                                                     Transaction_Object),
            Goal = (transaction_object_triple_count(Transaction_Object,Numerical_Count),
                    unliterally(Numerical_Count,CountE))
        ;   graph_descriptor_transaction_objects_read_write_object(Graph, Transaction_Objects, Read_Write_Object),
            Goal = (read_object_triple_count(Read_Write_Object,Numerical_Count),
                    unliterally(Numerical_Count,CountE))
        )
    }.
compile_wf(true,true) -->
    [].
compile_wf(Q,_) -->
    {
        format(atom(M), 'Unable to compile AST query ~q', [Q]),
        throw(error(syntax_error(M),
                    context(compile_wf//1,Q)))
    }.
*/
debug_wf(Lit) -->
    { debug(terminus(woql_compile(compile_wf)), '~w', [Lit]) },
    [].

debug_wf(Fmt, Args) -->
    { debug(terminus(woql_compile(compile_wf)), Fmt, Args) },
    [].

/*
 * file_spec_path_options(File_Spec,Path,Default, Options) is semidet.
 *
 * Converts a file spec into a referenceable file path which can be opened as a stream.
 */
file_spec_path_options(File_Spec,_Files,Path,Default,New_Options) :-
    (   File_Spec = file(Path,Options)
    ;   File_Spec = file(Path),
        Options = []),
    merge_options(Options,Default,New_Options).
file_spec_path_options(File_Spec,_Files,Path,Default,New_Options) :-
    (   File_Spec = remote(URI,Options)
    ;   File_Spec = remote(URI),
        Options = []),
    merge_options(Options,Default,New_Options),
    copy_remote(URI,URI,Path,New_Options).
file_spec_path_options(File_Spec,Files,Path,Default,New_Options) :-
    (   File_Spec = post(Name,Options)
    ;   File_Spec = post(Name),
        Options = []),
    atom_string(Name_Atom,Name),
    merge_options(Options,Default,New_Options),
    memberchk(Name_Atom=file(_Original,Path), Files).

% Could be a single fold, but then we always get a conjunction with true
list_conjunction([],true).
list_conjunction(L,Goal) :-
    L = [_|_],
    reverse(L,R),
    R = [A|Rest],
    foldl([X,Y,(X,Y)]>>true, Rest, A, Goal).

list_disjunction([],true).
list_disjunction(L,Goal) :-
    L = [_|_],
    reverse(L,R),
    R = [A|Rest],
    foldl([X,Y,(X;Y)]>>true, Rest, A, Goal).

:- begin_tests(woql_compile).

test(basic_triple,[]) :-
    Term = (
        t(n(a),n(b),n(c)
    ),
    true.

:- end_tests(woql_compile).

/*
:- begin_tests(woql).

% At some point this should be exhaustive. Currently we add as we find bugs.

:- use_module(ask,[ask/2,create_context/2, create_context/3, context_extend_prefixes/3]).
% NOTE: This circularity is very irritating...
% We are merely hoping that query_response is loaded before we run this test.
%:- use_module(query_response, [run_context_ast_jsonld_response/3]).
:- use_module(library(ordsets)).
:- use_module(core(util/test_utils)).
:- use_module(core(api)).
:- use_module(core(transaction)).

query_test_response(Descriptor, Query, Response) :-
    create_context(Descriptor,commit_info{ author : "automated test framework",
                                           message : "testing"}, Context),
    woql_context(Prefixes),
    New_Prefixes = (Prefixes.put(_{ empty : "" })), % convenient for testing...
    context_extend_prefixes(Context,New_Prefixes,Context0),
    json_woql(Query, Context0.prefixes, AST),
    query_response:run_context_ast_jsonld_response(Context0, AST, Response).

test(subsumption, [])
:-
    Query = _{'@type' : "Subsumption",
              child : _{ '@type' : "Node",
                         node : "terminus:User"},
              parent : _{'@type' : "Variable",
                         'variable_name' :
                         _{'@type' : "xsd:string",
                           '@value' : "Parent"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    % Tag the dicts so we can sort them
    maplist([D,D]>>(json{} :< D), JSON.bindings, Orderable),
    list_to_ord_set(Orderable,Bindings_Set),
    list_to_ord_set([json{'Parent':'http://www.w3.org/2002/07/owl#Thing'},
                     json{'Parent':'http://terminusdb.com/schema/terminus#User'},
                     json{'Parent':'http://terminusdb.com/schema/terminus#Agent'},
                     json{'Parent':'http://terminusdb.com/schema/terminus#Document'}],
                    Expected),
    ord_seteq(Bindings_Set,Expected).


test(substring, [])
:-
    Query = _{'@type' : "Substring",
              string : _{ '@type' : "Datatype",
                          datatype : _{'@type' : "xsd:string",
                                       '@value' : "Test"}},
              before : _{ '@type' : "Datatype",
                          datatype : _{'@type' : "xsd:string",
                                       '@value' : 1}},
              length : _{'@type' : "Variable",
                         variable_name :
                         _{'@type' : "xsd:string",
                           '@value' : "Length"}},
              after : _{ '@type' : "Datatype",
                         datatype : _{'@type' : "xsd:integer",
                                      '@value' : 1}},
              substring : _{'@type' : "Variable",
                            variable_name :
                            _{'@type' : "xsd:string",
                              '@value' : "Substring"}}
             },
    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Length':_{'@type':'http://www.w3.org/2001/XMLSchema#decimal','@value':2},
      'Substring':_{'@type':'http://www.w3.org/2001/XMLSchema#string','@value':"es"}
     } :< Res.

test(typecast_string_integer, [])
:-
    Query = _{'@type' : "Typecast",
              typecast_value : _{ '@type' : "Datatype",
                                  datatype : _{'@type' : "xsd:string",
                                               '@value' : "202"}},
              typecast_type : _{ '@type' : "Node",
                                 node : "xsd:integer"},
              typecast_result : _{'@type' : "Variable",
                                  variable_name :
                                  _{'@type' : "xsd:string",
                                    '@value' : "Casted"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Casted':_{'@type':'http://www.w3.org/2001/XMLSchema#integer',
                 '@value':202}} :< Res.

test(eval, [])
:-
    Query = _{'@type' : "Eval",
              expression :
              _{ '@type' : "Plus",
                 first : _{ '@type' : "Datatype",
                            datatype : _{'@type' : "xsd:integer",
                                         '@value' : 2}},
                 second : _{ '@type' : "Datatype",
                               datatype : _{'@type' : "xsd:integer",
                                            '@value' : 2}}},
              result : _{'@type' : "Variable",
                         variable_name :
                         _{'@type' : "xsd:string",
                           '@value' : "Sum"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Sum':_{'@type':'http://www.w3.org/2001/XMLSchema#decimal',
              '@value':4}} :< Res.


test(add_triple, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query = _{'@type' : "AddTriple",
              subject : _{ '@type' : "Node",
                           node : "doc:DBadmin"},
              predicate : _{ '@type' : "Node",
                               node : "rdfs:label"},
              object : _{ '@type' : "Node",
                            node : "xxx"}},

    make_branch_descriptor('admin', 'test', Descriptor),
    query_test_response(Descriptor, Query, JSON),
    JSON.inserts = 1.

test(add_quad, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query = _{'@type' : "AddQuad",
              subject : _{ '@type' : "Node",
                             node : "doc:DBadmin"},
              predicate : _{ '@type' : "Node",
                               node : "rdfs:label"},
              object : _{ '@type' : "Node",
                          node : "xxx"},
              graph : _{ '@type' : "Datatype",
                         datatype : _{'@type' : "xsd:string",
                                      '@value' : "instance/main"}
                       }},

    make_branch_descriptor('admin', 'test', Descriptor),
    query_test_response(Descriptor, Query, JSON),
    JSON.inserts = 1.

test(upper, []) :-
    Query = _{'@type' : "Upper",
              left : _{ '@type' : "Datatype",
                        datatype : _{ '@type' : "xsd:string",
                                      '@value' : "Aaaa"}},
              right : _{'@type' : "Variable",
                        variable_name :
                        _{'@type' : "xsd:string",
                          '@value' : "Upcased"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Upcased':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                  '@value': "AAAA"}} :< Res.


test(unique, []) :-
    Query = _{'@type' : "Unique",
              base : _{ '@type' : "Datatype",
                        datatype : _{ '@type' : "xsd:string",
                                      '@value' : "http://foo.com/"}},
              key_list : _{ '@type' : "Array",
                              'array_element' :
                              [_{ '@type' : "ArrayElement",
                                  index : _{ '@type' : "xsd:integer", '@value' : 0},
                                  datatype : _{ '@type' : "xsd:string",
                                               '@value' : "a"}},
                               _{ '@type' : "ArrayElement",
                                  index : _{ '@type' : "xsd:integer", '@value' : 1},
                                  datatype : _{ '@type' : "xsd:string",
                                               '@value' : "b"}},
                               _{ '@type' : "ArrayElement",
                                  index : _{ '@type' : "xsd:integer", '@value' : 2},
                                  datatype : _{ '@type' : "xsd:string",
                                               '@value' : "c"}}]},
              uri : _{'@type' : "Variable",
                      variable_name :
                      _{'@type' : "xsd:string",
                        '@value' : "URI"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'URI': 'http://foo.com/900150983cd24fb0d6963f7d28e17f72'} :< Res.

test(split, []) :-
    Query = _{'@type' : "Split",
              split_string : _{ '@type' : "Datatype",
                                datatype : _{ '@type' : "xsd:string",
                                              '@value' : "you_should_be_split"}},
              split_pattern : _{ '@type' : "Datatype",
                                 datatype : _{ '@type' : "xsd:string",
                                               '@value' : "_"}},
              split_list : _{'@type' : "Variable",
                             variable_name :
                             _{'@type' : "xsd:string",
                               '@value' : "Split"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Split': [_{'@type':'http://www.w3.org/2001/XMLSchema#string','@value':"you"},
                _{'@type':'http://www.w3.org/2001/XMLSchema#string','@value':"should"},
                _{'@type':'http://www.w3.org/2001/XMLSchema#string','@value':"be"},
                _{'@type':'http://www.w3.org/2001/XMLSchema#string','@value':"split"}]}
                 :< Res.


test(join, []) :-
    Query = _{'@type' : "Join",
              join_list : _{ '@type' : 'Array',
                             array_element :
                             [_{ '@type' : "ArrayElement",
                                 index : _{ '@type' : "xsd:integer",
                                            '@value' : 0},
                                 datatype : _{ '@type' : "xsd:string",
                                               '@value' : "you"}},
                              _{ '@type' : "ArrayElement",
                                 index : _{ '@type' : "xsd:integer",
                                            '@value' : 1},
                                 datatype : _{ '@type' : "xsd:string",
                                               '@value' : "should"}},
                              _{ '@type' : "ArrayElement",
                                 index : _{ '@type' : "xsd:integer",
                                            '@value' : 2},
                                 datatype : _{ '@type' : "xsd:string",
                                               '@value' : "be"}},
                              _{ '@type' : "ArrayElement",
                                 index : _{ '@type' : "xsd:integer",
                                            '@value' : 3},
                                 datatype : _{ '@type' : "xsd:string",
                                               '@value' : "joined"}}]},
              join_separator : _{ '@type' : "Datatype",
                                  datatype : _{ '@type' : "xsd:string",
                                                '@value' : "_"}},
              join : _{'@type' : "Variable",
                       variable_name :
                       _{'@type' : "xsd:string",
                         '@value' : "Join"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Join': _{'@type':'http://www.w3.org/2001/XMLSchema#string',
                '@value':"you_should_be_joined"}} :< Res.


test(isa, []) :-
    Query = _{'@type' : "IsA",
              element : _{ '@type' : "Node",
                           node : "doc:admin"},
              of_type : _{'@type' : "Variable",
                          variable_name :
                          _{'@type' : "xsd:string",
                            '@value' : "IsA"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    maplist([D,D]>>(json{} :< D), JSON.bindings, Orderable),
    list_to_ord_set(Orderable,Bindings_Set),
    list_to_ord_set([json{'IsA':'http://www.w3.org/2002/07/owl#Thing'},
                     json{'IsA':'http://terminusdb.com/schema/terminus#User'},
                     json{'IsA':'http://terminusdb.com/schema/terminus#Agent'},
                     json{'IsA':'http://terminusdb.com/schema/terminus#Document'}],
                    Expected),
    ord_seteq(Bindings_Set, Expected).

test(like, []) :-
    Query = _{'@type' : "Like",
              left : _{ '@type' : "Datatype",
                          datatype : _{ '@type' : "xsd:string",
                                       '@value' : "joined"}},
              right : _{ '@type' : "Datatype",
                           datatype : _{ '@type' : "xsd:string",
                                        '@value' : "joined"}},
              like_similarity : _{'@type' : "Variable",
                                  variable_name :
                                  _{'@type' : "xsd:string",
                                    '@value' : "Similarity"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Similarity':_{'@type':'http://www.w3.org/2001/XMLSchema#decimal',
                     '@value':1.0}} :< Res.

test(exp, []) :-

    Query = _{'@type' : "Eval",
              expression :
              _{ '@type' : "Exp",
                 first : _{ '@type' : "Datatype",
                            datatype : _{'@type' : "xsd:integer",
                                         '@value' : 2}},
                 second : _{ '@type' : "Datatype",
                             datatype : _{'@type' : "xsd:integer",
                                          '@value' : 2}}},
              result : _{'@type' : "Variable",
                         variable_name :
                         _{'@type' : "xsd:string",
                           '@value' : "Exp"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Exp':_{'@type':'http://www.w3.org/2001/XMLSchema#decimal',
              '@value':4}} :< Res.

test(limit, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))]) :-

    make_branch_descriptor('admin', 'test', Descriptor),
    create_context(Descriptor, commit_info{ author : "test",
                                            message : "testing"}, Context),

    with_transaction(
        Context,
        ask(Context, (insert('x','y','z'),
                      insert('x','y','w'),
                      insert('x','y','q'))),
        _Meta),

    Query = _{'@type' : "Limit",
              limit : _{ '@type' : "Datatype",
                           datatype : _{ '@type' : "xsd:integer",
                                         '@value' : 2}},
              query : _{ '@type' : "Triple",
                         subject : _{'@type' : "Variable",
                                     variable_name :
                                     _{'@type' : "xsd:string",
                                       '@value' : "Subject"}},
                         predicate : _{'@type' : "Variable",
                                       variable_name :
                                       _{'@type' : "xsd:string",
                                         '@value' : "Predicate"}},
                         object : _{'@type' : "Variable",
                                    variable_name :
                                    _{'@type' : "xsd:string",
                                      '@value' : "Object"}}
                       }},

    query_test_response(Descriptor, Query, JSON),
    maplist([D,D]>>(json{} :< D), JSON.bindings, Orderable),

    list_to_ord_set(Orderable,Bindings_Set),
    list_to_ord_set([json{'Object':q,'Predicate':y,'Subject':x},
                     json{'Object':w,'Predicate':y,'Subject':x}],
                    Expected),
    ord_seteq(Bindings_Set,Expected).

test(indexed_get, [])
:-
    Query =
    _{'@type' : 'Get',
      as_vars : [
          _{'@type' : 'IndexedAsVar',
            index : _{ '@type' : "xsd:integer",
                       '@value' : 0},
            variable_name : _{ '@type' : "xsd:string",
                               '@value' : "First"}},
          _{'@type' : 'IndexedAsVar',
            index : _{ '@type' : "xsd:integer",
                       '@value' : 1},
            variable_name : _{ '@type' : "xsd:string",
                               '@value' : "Second"}}],
      query_resource :
      _{'@type' : 'RemoteResource',
        remote_uri : _{ '@type' : "xsd:anyURI",
                        '@value' : "https://terminusdb.com/t/data/bike_tutorial.csv"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res|_] = JSON.bindings,
    % Should this really be without a header?
    _{'First':_{'@type':'http://www.w3.org/2001/XMLSchema#string','@value':"Duration"},
      'Second':_{'@type':'http://www.w3.org/2001/XMLSchema#string','@value':"Start date"}} :< Res.

test(named_get, [])
:-
    Query =
    _{'@type' : 'Get',
      as_vars : [
          _{'@type' : 'NamedAsVar',
            identifier : _{ '@type' : "xsd:string",
                            '@value' : "Duration"},
            variable_name : _{ '@type' : "xsd:string",
                               '@value' : "Duration"}},
          _{'@type' : 'NamedAsVar',
            identifier : _{ '@type' : "xsd:string",
                            '@value' : "Bike number"},
            variable_name : _{ '@type' : "xsd:string",
                               '@value' : "Bike_Number"}}
      ],
      query_resource :
      _{'@type' : 'RemoteResource',
        remote_uri : _{ '@type' : "xsd:anyURI",
                        '@value' : "https://terminusdb.com/t/data/bike_tutorial.csv"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [First|_] = JSON.bindings,

    _{'Bike_Number': _{'@type':'http://www.w3.org/2001/XMLSchema#string',
                      '@value':"W21477"},
      'Duration': _{'@type':'http://www.w3.org/2001/XMLSchema#string',
                    '@value':"790"}
     } :< First.

test(named_get_two, [])
:-
    Query =
    _{
        '@type': "woql:Get",
        'woql:as_vars': [
            _{ '@type': "woql:NamedAsVar",
               'woql:identifier': _{ '@type': "xsd:string",
                                     '@value': "Start station"
                                   },
               'woql:variable_name': _{ '@type': "xsd:string",
                                        '@value': "Start_Station"}
             },
            _{ '@type': "woql:NamedAsVar",
               'woql:identifier': _{ '@type': "xsd:string",
                                     '@value': "End station"
                                   },
               'woql:variable_name': _{ '@type': "xsd:string",
                                        '@value': "End_Station"
                                      }
             },
            _{ '@type': "woql:NamedAsVar",
               'woql:identifier': _{ '@type': "xsd:string",
                                     '@value': "Start date"
                                   },
               'woql:variable_name': _{ '@type': "xsd:string",
                                        '@value': "Start_Time"
                                      }
             },
            _{
                '@type': "woql:NamedAsVar",
                'woql:identifier': _{ '@type': "xsd:string",
                                      '@value': "End date"
                                    },
                'woql:variable_name': _{ '@type': "xsd:string",
                                         '@value': "End_Time"
                                       }
            },
            _{
                '@type': "woql:NamedAsVar",
                'woql:identifier': _{ '@type': "xsd:string",
                                      '@value': "Duration"
                                    },
                'woql:variable_name': _{ '@type': "xsd:string",
                                         '@value': "Duration"}
            },
            _{ '@type': "woql:NamedAsVar",
               'woql:identifier': _{ '@type': "xsd:string",
                                     '@value': "Start station number"
                                   },
               'woql:variable_name': _{ '@type': "xsd:string",
                                        '@value': "Start_ID" }
             },
            _{ '@type': "woql:NamedAsVar",
               'woql:identifier': _{ '@type': "xsd:string",
                                     '@value': "End station number"
                                   },
               'woql:variable_name': _{ '@type': "xsd:string",
                                        '@value': "End_ID"
                                      }
             },
            _{ '@type': "woql:NamedAsVar",
               'woql:identifier': _{ '@type': "xsd:string",
                                     '@value': "Bike number"
                                   },
               'woql:variable_name': _{ '@type': "xsd:string",
                                        '@value': "Bike"
                                      }},
            _{ '@type': "woql:NamedAsVar",
               'woql:identifier': _{ '@type': "xsd:string",
                                     '@value': "Member type" },
               'woql:variable_name': _{ '@type': "xsd:string",
                                        '@value': "Member_Type" }}
        ],
        'woql:query_resource':
        _{ '@type': "woql:RemoteResource",
           'woql:remote_uri': _{'@type': "xsd:anyURI",
                                '@value': "https://terminusdb.com/t/data/bikeshare/2011-capitalbikeshare-tripdata.csv"
                               }
         }
    },

    query_test_response(terminus_descriptor{}, Query, JSON),

    [Res|_] = JSON.bindings,
    _{'Bike':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
               '@value':"W00247"},
      'Duration':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                   '@value':"3548"},
      'End_ID':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                 '@value':"31620"},
      'End_Station':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                      '@value':"5th & F St NW"},
      'End_Time':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                   '@value':"2011-01-01 01:00:37"},
      'Member_Type':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                      '@value':"Member"},
      'Start_ID':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                   '@value':"31620"},
      'Start_Station':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                        '@value':"5th & F St NW"},
      'Start_Time':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                     '@value':"2011-01-01 00:01:29"}} :< Res.

test(concat, [])
:-
    Query =
    _{'@type' : 'Concatenate',
      concat_list :
      _{'@type' : 'Array',
        array_element : [
            _{'@type' : 'ArrayElement',
              index : _{ '@type' : "xsd:integer",
                         '@value' : 0},
              datatype : _{ '@type' : "xsd:string",
                            '@value' : "First"}},
            _{'@type' : 'ArrayElement',
              index : _{ '@type' : "xsd:integer",
                         '@value' : 1},
              datatype : _{ '@type' : "xsd:string",
                            '@value' : "Second"}}
        ]},
      concatenated :
      _{'@type' : 'Variable',
        variable_name : _{ '@type' : "xsd:string",
                           '@value' : "Concatenated" }}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Concatenated':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                       '@value':"FirstSecond"}} :< Res.

test(sum, [])
:-
    Query =
    _{'@type' : 'Sum',
      sum_list :
      _{'@type' : 'Array',
        array_element : [
            _{'@type' : 'ArrayElement',
              index : _{ '@type' : "xsd:integer",
                         '@value' : 0},
              datatype : _{ '@type' : "xsd:integer",
                            '@value' : 1}},
            _{'@type' : 'ArrayElement',
              index : _{ '@type' : "xsd:integer",
                         '@value' : 1},
              datatype : _{ '@type' : "xsd:integer",
                            '@value' : 2}}
        ]},
      sum :
      _{'@type' : 'Variable',
        variable_name : _{ '@type' : "xsd:string",
                           '@value' : "Sum" }}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Sum':_{'@type':'http://www.w3.org/2001/XMLSchema#decimal',
              '@value': 3}} :< Res.

test(length, [])
:-
    Query = _{'@type' : "Length",
              length_list : _{'@type' : 'Array',
                              array_element : [
                                  _{'@type' : 'ArrayElement',
                                    index : _{ '@type' : "xsd:integer",
                                               '@value' : 0},
                                    datatype : _{ '@type' : "xsd:integer",
                                                  '@value' : 1}},
                                  _{'@type' : 'ArrayElement',
                                    index : _{ '@type' : "xsd:integer",
                                               '@value' : 1},
                                    datatype : _{ '@type' : "xsd:integer",
                                                  '@value' : 2}}
                              ]},
              length : _{ '@type' : "Variable",
                          variable_name : _{ '@type' : "xsd:string",
                                             '@value'  : "Length"}}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res] = JSON.bindings,
    _{'Length':_{'@type':'http://www.w3.org/2001/XMLSchema#decimal',
                 '@value': 2}} :< Res.


test(order_by, []) :-

    Query = _{'@type' : "OrderBy",
              variable_ordering : [_{ '@type' : "VariableOrdering",
                                      index : _{'@type' : "xsd:integer",
                                                '@value' : 0},
                                      ascending : _{'@type' : "xsd:boolean",
                                                    '@value' : true},
                                      variable : _{'@type' : "Variable",
                                                   variable_name : _{ '@type' : "xsd:string",
                                                                      '@value' : "X"}}}],
              query : _{ '@type' : 'Or',
                         query_list :
                         [_{'@type' : "QueryListElement",
                            index : _{'@type' : "xsd:integer",
                                      '@value' : 0},
                            query : _{ '@type' : "Equals",
                                       left : _{'@type' : "Variable",
                                                variable_name :
                                                _{'@type' : "xsd:string",
                                                  '@value' : "X"}},
                                       right : _{'@type' : "xsd:string",
                                                 '@value' : 10}}},
                          _{'@type' : "QueryListElement",
                            index : _{'@type' : "xsd:integer",
                                      '@value' : 0},
                            query : _{ '@type' : "Equals",
                                       left : _{'@type' : "Variable",
                                                variable_name :
                                                _{'@type' : "xsd:string",
                                                  '@value' : "X"}},
                                       right : _{'@type' : "xsd:string",
                                                 '@value' : 20}}}]}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    JSON.bindings = [_{'X':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                             '@value':10}},
                     _{'X':_{'@type':'http://www.w3.org/2001/XMLSchema#string',
                             '@value':20}}].

test(path, []) :-

    % Pattern is:
    % terminus:access , (  terminus:authority_scope
    %                   ;  terminus:authority_scope, plus(terminus:resource_includes))
    Pattern =
    _{'@type' : "PathSequence",
      path_first :
      _{ '@type' : "PathPredicate",
         path_predicate : _{ '@id' : "terminus:access"}},
      path_second :
      _{ '@type' : "PathOr",
         path_left :
         _{ '@type' : "PathPredicate",
            path_predicate : _{ '@id' : "terminus:authority_scope"}},
         path_right :
         _{ '@type' : "PathSequence",
            path_first :
            _{ '@type' : "PathPredicate",
               path_predicate : _{ '@id' : "terminus:authority_scope"}},
            path_second :
            _{ '@type' : "PathPlus",
               path_pattern :
               _{ '@type' : "PathPredicate",
                  path_predicate : _{ '@id' : "terminus:resource_includes"}}}}}},

    Query = _{'@type' : "And",
              query_list :
              [_{'@type' : "QueryListElement",
                 index : _{'@type' : "xsd:integer",
                           '@value' : 0},
                 query :
                 _{'@type' : "Path",
                   subject : _{'@type' : "Variable",
                               variable_name : _{ '@type' : "xsd:string",
                                                  '@value' : "Subject"}},
                   path_pattern : Pattern,
                   object : _{'@type' : "Variable",
                              variable_name :
                              _{'@type' : "xsd:string",
                                '@value' : "Object"}},
                   path : _{'@type' : "Variable",
                            variable_name :
                            _{'@type' : "xsd:string",
                              '@value' : "Path"}}}},
               _{'@type' : "QueryListElement",
                 index : _{'@type' : "xsd:integer",
                           '@value' : 1},
                 query :
                 _{'@type' : "Member",
                   member_list : _{'@type' : "Variable",
                                   variable_name : _{ '@type' : "xsd:string",
                                                      '@value' : "Path"}},
                   member : _{'@type' : "Variable",
                              variable_name : _{ '@type' : "xsd:string",
                                                 '@value' : "Edge"}}}},
               _{'@type' : "QueryListElement",
                 index : _{'@type' : "xsd:integer",
                           '@value' : 2},
                 query :
                 _{'@type' : "Dot",
                   dictionary : _{'@type' : "Variable",
                                  variable_name : _{ '@type' : "xsd:string",
                                                     '@value' : "Edge"}},
                   dictionary_key : _{'@type' : "Node",
                                      node : "object"},
                   dictionary_value : _{'@type' : "Variable",
                                        variable_name : _{ '@type' : "xsd:string",
                                                           '@value' : "Edge_Object"}}}}
              ]
             },

    query_test_response(terminus_descriptor{}, Query, JSON),
    [Res|_] = JSON.bindings,
    _{'Edge':_{'@type':"http://terminusdb.com/schema/woql#Edge",
               'http://terminusdb.com/schema/woql#object':'terminus:///terminus/document/server_access',
               'http://terminusdb.com/schema/woql#predicate':'http://terminusdb.com/schema/terminus#access',
               'http://terminusdb.com/schema/woql#subject':'terminus:///terminus/document/access_all_areas'},
      'Edge_Object':'terminus:///terminus/document/server_access',
      'Object':'terminus:///terminus/document/server',
      'Path':[_{'@type':"http://terminusdb.com/schema/woql#Edge",
                'http://terminusdb.com/schema/woql#object':'terminus:///terminus/document/server_access',
                'http://terminusdb.com/schema/woql#predicate':'http://terminusdb.com/schema/terminus#access',
                'http://terminusdb.com/schema/woql#subject':'terminus:///terminus/document/access_all_areas'},
              _{'@type':"http://terminusdb.com/schema/woql#Edge",
                'http://terminusdb.com/schema/woql#object':'terminus:///terminus/document/server',
                'http://terminusdb.com/schema/woql#predicate':'http://terminusdb.com/schema/terminus#authority_scope',
                'http://terminusdb.com/schema/woql#subject':'terminus:///terminus/document/server_access'}],
      'Subject':'terminus:///terminus/document/access_all_areas'} :< Res.


test(path_star, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]) :-
    make_branch_descriptor('admin', 'test', Descriptor),
    Commit_Info = commit_info{ author : "me",
                               message : "Graph creation"},

    create_graph(Descriptor,
                 Commit_Info,
                 schema,
                 main,
                 _Transaction_Metadata2),

    create_context(Descriptor,
                   Commit_Info,
                   Context),

    with_transaction(
        Context,
        ask(Context,
            (
                insert(node, rdf:type, owl:'Class', "schema/main"),
                insert(p, rdf:type, owl:'ObjectProperty', "schema/main"),
                insert(p, rdfs:domain, node, "schema/main"),
                insert(p, rdfs:range, node, "schema/main"),
                insert(a, rdf:type, node),
                insert(b, rdf:type, node),
                insert(c, rdf:type, node),
                insert(a, p, b),
                insert(b, p, c),
                insert(c, p, a)
            )),
        _Meta),

    findall((a-Y=Simple_Path),
            (   ask(Descriptor,
                    path(a, star(p(p)), Y, Path)),
                maplist([Edge,(A,B,C)]>>(
                            get_dict('http://terminusdb.com/schema/woql#subject',Edge, A),
                            get_dict('http://terminusdb.com/schema/woql#predicate',Edge, B),
                            get_dict('http://terminusdb.com/schema/woql#object',Edge, C)
                        ), Path, Simple_Path)
            ),
            Solutions),
    Solutions = [a-a=[],
                 a-b=[(a,p,b)],
                 a-c=[(a,p,b),(b,p,c)],
                 a-a=[(a,p,b),(b,p,c),(c,p,a)]].

test(complex_path, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]) :-
    make_branch_descriptor('admin', 'test', Descriptor),
    Commit_Info = commit_info{ author : "me",
                               message : "Graph creation"},

    create_graph(Descriptor,
                 Commit_Info,
                 schema,
                 main,
                 _Transaction_Metadata2),

    create_context(Descriptor,
                   Commit_Info,
                   Context),

    with_transaction(
        Context,
        ask(Context,
            (
                insert(node, rdf:type, owl:'Class', "schema/main"),
                insert(p, rdf:type, owl:'ObjectProperty', "schema/main"),
                insert(p, rdfs:domain, node, "schema/main"),
                insert(p, rdfs:range, node, "schema/main"),
                insert(q, rdf:type, owl:'ObjectProperty', "schema/main"),
                insert(q, rdfs:domain, node, "schema/main"),
                insert(q, rdfs:range, node, "schema/main"),
                insert(a, rdf:type, node),
                insert(b, rdf:type, node),
                insert(c, rdf:type, node),
                insert(d, rdf:type, node),
                insert(e, rdf:type, node),
                insert(f, rdf:type, node),
                insert(a, p, b),
                insert(b, p, c),
                insert(c, p, a),
                insert(a, p, d),
                insert(d, p, e),
                insert(e, p, a),
                insert(a, q, f)
            )),
        _Meta),

    findall((a-Y=Simple_Path),
            (   ask(Descriptor,
                    path(a, (star(p(p));plus(p(q))), Y, Path)),
                maplist([Edge,(A,B,C)]>>(
                            get_dict('http://terminusdb.com/schema/woql#subject',Edge, A),
                            get_dict('http://terminusdb.com/schema/woql#predicate',Edge, B),
                            get_dict('http://terminusdb.com/schema/woql#object',Edge, C)
                        ), Path, Simple_Path)
            ),
            Solutions),

    Solutions = [a-a=[],
                 a-b=[(a,p,b)],
                 a-d=[(a,p,d)],
                 a-c=[(a,p,b),(b,p,c)],
                 a-a=[(a,p,b),(b,p,c),(c,p,a)],
                 a-e=[(a,p,d),(d,p,e)],
                 a-a=[(a,p,d),(d,p,e),(e,p,a)],
                 a-f=[(a,q,f)]].

test(group_by, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ])
:-
    make_branch_descriptor('admin', 'test', Descriptor),
    create_context(Descriptor, commit_info{ author : "test",
                                            message : "testing"}, Context),

    with_transaction(
        Context,
        ask(Context, (insert(x,p,z),
                      insert(x,p,w),
                      insert(x,p,q),
                      insert(y,p,z),
                      insert(y,p,w))),
        _Meta),

    Query = _{'@type' : "GroupBy",
              group_by : [_{ '@type' : "VariableListElement",
                             index : _{'@type' : "xsd:integer",
                                       '@value' : 0},
                             variable_name : _{ '@type' : "xsd:string",
                                                '@value' : "Subject"}}],
              group_template :  [_{ '@type' : "VariableListElement",
                                    index : _{'@type' : "xsd:integer",
                                              '@value' : 0},
                                    variable_name : _{ '@type' : "xsd:string",
                                                       '@value' : "Predicate"}},
                                 _{ '@type' : "VariableListElement",
                                    index : _{'@type' : "xsd:integer",
                                              '@value' : 1},
                                    variable_name : _{ '@type' : "xsd:string",
                                                       '@value' : "Object"}}],
              query : _{ '@type' : "Triple",
                         subject : _{'@type' : "Variable",
                                     variable_name :
                                     _{'@type' : "xsd:string",
                                       '@value' : "Subject"}},
                         predicate : _{'@type' : "Variable",
                                       variable_name :
                                       _{'@type' : "xsd:string",
                                         '@value' : "Predicate"}},
                         object : _{'@type' : "Variable",
                                    variable_name :
                                    _{'@type' : "xsd:string",
                                      '@value' : "Object"}}
                       },
              grouped : _{'@type' : "Variable",
                          variable_name :
                          _{'@type' : "xsd:string",
                            '@value' : "Grouped"}}},

    query_test_response(Descriptor, Query, JSON),
    [_{'Grouped': [[p,q],
                   [p,w],
                   [p,z]],
       'Object':"terminus:unknown",'Predicate':"terminus:unknown",'Subject':x},
     _{'Grouped': [[p,w],
                   [p,z]],
       'Object':"terminus:unknown",'Predicate':"terminus:unknown",'Subject':y}] = JSON.bindings.

test(select, []) :-

    Query = _{'@type' : "Limit",
              limit : _{'@type' : "xsd:integer",
                        '@value' : 1},
              query : _{'@type' : "Select",
                        variable_list : [_{ '@type' : "VariableListElement",
                                            index : _{'@type' : "xsd:integer",
                                                      '@value' : 0},
                                            variable_name : _{ '@type' : "xsd:string",
                                                               '@value' : "Subject"}}],
                        query : _{ '@type' : "Triple",
                                   subject : _{'@type' : "Variable",
                                               variable_name :
                                               _{'@type' : "xsd:string",
                                                 '@value' : "Subject"}},
                                   predicate : _{'@type' : "Variable",
                                                 variable_name :
                                                 _{'@type' : "xsd:string",
                                                   '@value' : "Predicate"}},
                                   object : _{'@type' : "Variable",
                                              variable_name :
                                              _{'@type' : "xsd:string",
                                                '@value' : "Object"}}
                                 }}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [_{'Subject':'terminus:///terminus/document/access_all_areas'}] = JSON.bindings.

test(when, []) :-

    Query = _{'@type' : "When",
              query : _{'@type' : "True"},
              consequent : _{'@type' : "True"}},

    query_test_response(terminus_descriptor{}, Query, JSON),
    [_{}] = JSON.bindings.


test(transaction_semantics_after, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),


    with_transaction(
        Context,
        forall(ask(Context,
                   (
                       X = 1^^xsd:integer,
                       insert(a, b, X),
                       X = 2^^xsd:integer
                   )),
               true),
        _Meta_Data
    ),

    \+ once(ask(Descriptor,
                t(a, b, 1^^xsd:integer))).


test(transaction_semantics_disjunct, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),

    with_transaction(
        Context,
        forall(ask(Context,
                   (
                       (   X = 1^^xsd:integer
                       ;   X = 2^^xsd:integer),
                       insert(a, b, X),
                       X = 2^^xsd:integer
                   )),
               true),
        _Meta_Data
    ),

    once(ask(Descriptor,
             (   not(t(a, b, 1^^xsd:integer)),
                 t(a, b, 2^^xsd:integer)))).


test(transaction_semantics_conditional, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),

    with_transaction(
        Context,
        forall(ask(Context,
                   (
                       (   X = 1^^xsd:integer
                       ;   X = 2^^xsd:integer),
                       insert(a, b, X),
                       (   X = 1^^xsd:integer
                       ;   X = 2^^xsd:integer)
                   )),
               true),
        _Meta_Data
    ),

    once(ask(Descriptor,
             (   t(a, b, 1^^xsd:integer),
                 t(a, b, 2^^xsd:integer)))).


test(disjunction_equality, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),

    with_transaction(
        Context,
        ask(Context,
            (
                insert(a, public, c),
                insert(a, private, f)
            )),
        _Meta_Data
    ),

    findall(
        Elt-Status,
        ask(Descriptor,
            (
                (   t(a, private, Elt),
                    Status = private
                ;   t(a, public, Elt),
                    Status = public)
            )),
        Statuses),

    Statuses = [f-private,c-(public)].

test(metadata_branch, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    ask(Descriptor,
        (   size('admin/test',Size_Lit),
            triple_count('admin/test', Count_Lit)
        )),

    Size_Lit = Size^^xsd:decimal,
    Count_Lit = 5^^xsd:decimal,
    Size < 1000,
    Size > 0.

test(metadata_graph, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    ask(Descriptor,
        (   size('admin/test/local/branch/master/instance/main',Size_Lit),
            triple_count('admin/test/local/branch/master/instance/main', Count_Lit)
        )),

    Size_Lit = Size^^xsd:decimal,
    Count_Lit = 5^^xsd:decimal,
    Size < 1000,
    Size > 0.

test(metadata_triple_count_json, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    Query = _{'@type' : "TripleCount",
              resource : _{'@type' : "xsd:string",
                           '@value' : "admin/test"},
              triple_count : _{'@type' : "Variable",
                               variable_name :
                               _{'@type' : "xsd:string",
                                 '@value' : "Count"}}},

    query_test_response(Descriptor, Query, JSON),
    [Binding] = (JSON.bindings),
    (Binding.'Count'.'@value' = 5).


test(metadata_triple_count_json, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    Query = _{'@type' : "Size",
              resource : _{'@type' : "xsd:string",
                           '@value' : "admin/test"},
              size : _{'@type' : "Variable",
                       variable_name :
                       _{'@type' : "xsd:string",
                         '@value' : "Size"}}},

    query_test_response(Descriptor, Query, JSON),
    [Binding] = (JSON.bindings),
    (Binding.'Size'.'@value' = Val),
    Val > 0,
    Val < 1000.

test(metadata_size_commits_json, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    Query = _{'@type' : "Size",
              resource : _{'@type' : "xsd:string",
                           '@value' : "admin/test/local/_commits"},
              size : _{'@type' : "Variable",
                       variable_name :
                       _{'@type' : "xsd:string",
                         '@value' : "Size"}}},

    query_test_response(Descriptor, Query, JSON),
    [Binding] = (JSON.bindings),
    (Binding.'Size'.'@value' = Val),
    Val > 0,
    Val < 15000.

test(ast_disjunction_test, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(account1, account_owner, user1),
                      insert(account1, public_databases, my_database1),
                      insert(account1, private_databases, my_database2))),
        _Meta_Data
    ),

    findall(AID-UID-DBID-Public_Or_Private,
            ask(Descriptor,
                (   (t(AID, account_owner, UID),
                     (   (   t(AID, public_databases, DBID),
                             Public_Or_Private = "public"^^xsd:string)
                     ;   (   t(AID, private_databases, DBID),
                             Public_Or_Private = "private"^^xsd:string)
                     )))),
            Results),

    Results = [account1-user1-my_database1-("public"^^xsd:string),
               account1-user1-my_database2-("private"^^xsd:string)].


test(json_disjunction_test, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(account1, account_owner, user1),
                      insert(account1, public_databases, my_database1),
                      insert(account1, private_databases, my_database2))),
        _Meta_Data
    ),

    Query = _{'@type' : "And",
              query_list :
              [_{'@type' : "QueryListElement",
                 index : _{'@type' : "xsd:integer",
                           '@value' : 0},
                 query :
                 _{'@type' : "Triple",
                   subject : _{'@type' : "Variable",
                               variable_name :
                               _{ '@type' : "xsd:string",
                                  '@value' : "AID"}},
                   predicate : _{'@type' : "Node",
                                 node : _{ '@id' : "empty:account_owner"}},
                   object : _{'@type' : "Variable",
                              variable_name :
                              _{'@type' : "xsd:string",
                                '@value' : "UID"}}}},
               _{'@type' : "QueryListElement",
                 index : _{'@type' : "xsd:integer",
                           '@value' : 1},
                 query :
                 _{'@type' : "Or",
                   query_list :
                   [_{'@type' : "QueryListElement",
                      index : _{'@type' : "xsd:integer",
                                '@value' : 0},
                      query :
                      _{'@type' : "And",
                        query_list :
                        [_{'@type' : "QueryListElement",
                           index : _{'@type' : "xsd:integer",
                                     '@value' : 0},
                           query :
                           _{'@type' : "Triple",
                             subject : _{'@type' : "Variable",
                                         variable_name :
                                         _{ '@type' : "xsd:string",
                                            '@value' : "AID"}},
                             predicate : _{'@type' : "Node",
                                           node : _{ '@id' : "empty:public_databases"}},
                             object : _{'@type' : "Variable",
                                        variable_name :
                                        _{'@type' : "xsd:string",
                                          '@value' : "DBID"}}}},
                         _{'@type' : "QueryListElement",
                           index : _{'@type' : "xsd:integer",
                                     '@value' : 0},
                           query : _{'@type' : "Equals",
                                     left : _{'@type' : "Variable",
                                              variable_name :
                                              _{'@type' : "xsd:string",
                                                '@value' : "Public_Or_Private"}},
                                     right : _{'@type' : "Datatype",
                                               datatype : _{'@type' : "xsd:string",
                                                            '@value' : "public"}}}}]}},
                    _{'@type' : "QueryListElement",
                      index : _{'@type' : "xsd:integer",
                                '@value' : 0},
                      query :
                      _{'@type' : "And",
                        query_list :
                        [_{'@type' : "QueryListElement",
                           index : _{'@type' : "xsd:integer",
                                     '@value' : 0},
                           query :
                           _{'@type' : "Triple",
                             subject : _{'@type' : "Variable",
                                         variable_name :
                                         _{ '@type' : "xsd:string",
                                            '@value' : "AID"}},
                             predicate : _{'@type' : "Node",
                                           node : _{'@id' : "empty:private_databases"}},
                             object : _{'@type' : "Variable",
                                        variable_name :
                                        _{'@type' : "xsd:string",
                                          '@value' : "DBID"}}}},
                         _{'@type' : "QueryListElement",
                           index : _{'@type' : "xsd:integer",
                                     '@value' : 0},
                           query : _{'@type' : "Equals",
                                     left : _{'@type' : "Variable",
                                              variable_name :
                                              _{'@type' : "xsd:string",
                                                '@value' : "Public_Or_Private"}},
                                     right : _{'@type' : "Datatype",
                                               datatype : _{'@type' : "xsd:string",
                                                            '@value' : "private"}}}}]}}
                   ]}}]},

    woql_context(Prefixes),
    New_Prefixes = (Prefixes.put(_{ empty : "" })),
    json_woql(Query, New_Prefixes, AST),
    AST = (
        t(v('AID'),account_owner,v('UID')),
        (
            t(v('AID'),public_databases,v('DBID')),
            v('Public_Or_Private')="public"^^'http://www.w3.org/2001/XMLSchema#string'
        ;   t(v('AID'),private_databases,v('DBID')),
            v('Public_Or_Private')="private"^^'http://www.w3.org/2001/XMLSchema#string')),

    query_test_response(Descriptor, Query, Response),

    Bindings = (Response.bindings),
    Bindings = [_{'AID':account1,
                  'DBID':my_database1,
                  'Public_Or_Private':
                  _{'@type':'http://www.w3.org/2001/XMLSchema#string',
                    '@value':"public"},
                  'UID':user1},
                _{'AID':account1,
                  'DBID':my_database2,
                  'Public_Or_Private':
                  _{'@type':'http://www.w3.org/2001/XMLSchema#string',
                    '@value':"private"},
                  'UID':user1}].


test(ast_when_test, [
         setup((setup_temp_store(State),
                create_db_without_schema('admin|test', 'test','a test'))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(a, b, d),
                      insert(a, b, e))),
        _Meta_Data1
    ),

    create_context(Descriptor, Commit_Info, Context2),

    AST = when(t(a,b,v('X')),
               insert(e, f, v('X'))),
    query_response:run_context_ast_jsonld_response(Context2, AST, _JSON),

    findall(t(X,P,Y),
            ask(Descriptor, t(X, P, Y)),
            Triples),

    Triples = [t(a,b,c),t(a,b,d),t(a,b,e),t(e,f,c),t(e,f,d),t(e,f,e)].

:- end_tests(woql).
*/
