//! Reclamation of the member pool (`ControlStorage.reclaim_floor`): both machines and the
//! report replay must reach the same layout by their own code, and a run that reclaims must
//! compute what the same run computes when it does not.
const std = @import("std");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const source_state = @import("source_state.zig");
const reporting = @import("value_report.zig");
const trace_report = @import("failure_report.zig");
const replay = @import("trace_replay.zig");

const never = types.ControlStorage.reclaim_never;
const fuel = replay.fuel;

/// Programs whose frames and loop visits leave members behind, hand some on, and keep some in
/// cells, instances and captures: every kind of root a reclamation has to honour.
const programs = [_][]const u8{
    // Text (RFC-0069): units, joins, rejected joins, scalars, slices and character keys built
    // and dropped inside visits, so that reclamation moves members strings and characters sit in.
    "Step(S:tuple(i64,string))<computes>:tuple(i64,string)=Block{U:=For(C:S(1),C);T:=Attempt(string[U],\"!\");tuple{S(0)+T.Length,T+\"x\"}}\nV<public>:tuple(i64,string)=Iterate(Step,12,tuple{0,\"aé\"})",
    "Grow(S:[]char)<computes>:[]char=Block{T:=Attempt(string[S],\"!\");D:=tuple{T.Length,1};S+array{Attempt(T[0],'z')}}\nAll<public>:[]char=Iterate(Grow,40,array{'a'})\nBack<public>:string=Attempt(string[All],\"!\")",
    "Step(S:i64)<computes>:i64=Block{U:=array{0oC3,0o28};T:=Attempt(string[U],\"!\");S+T.Length}\nTotal<public>:i64=Iterate(Step,30,0)",
    "Step(S:tuple(i64,[]char32))<computes>:tuple(i64,[]char32)=Block{Text:=\"aé😀b\";R:=Attempt(Text.ScalarAt[S(0)],0u3F);P:=tuple{R,S(0)};tuple{S(0)+1,S(1)+array{P(0)}}}\nV<public>:tuple(i64,[]char32)=Iterate(Step,9,tuple{0,array{}})",
    "var Seen:map(char,i64)=map{}\nText:string=\"banana\"\nStep(S:i64)<transacts>:i64=Block{C:=Attempt(Text[S],'?');set Seen[C]=Or(Lookup(Seen,C),0)+1;T:=tuple{S,C};S+1}\nTotal<public>:i64=Iterate(Step,9,0)\nM<public>:map(char,i64)=Seen",
    "Cut(T:string,I:i64)<computes><decides>:string=T.Slice[I]\nStep(S:tuple(i64,i64))<computes>:tuple(i64,i64)=Block{U:=tuple{S(0),S(1)};tuple{U(0)+1,U(1)+Attempt(Cut[\"aé😀b\",U(0)].Length,100)}}\nV<public>:tuple(i64,i64)=Iterate(Step,10,tuple{0,0})",
    "Units(T:string)<computes>:[]char=For(C:T,C)\nJoin(U:[]char)<computes><decides>:string=string[U]\nStep(S:tuple(i64,string))<computes>:tuple(i64,string)=Block{U:=Units(S(1));H:=Attempt(Join[U+array{0oC3}],\"?\");G:=Attempt(Join[U+array{'y'}],\"?\");tuple{S(0)+H.Length,G}}\nV<public>:tuple(i64,string)=Iterate(Step,25,tuple{0,\"é\"})",
    "Step(S:tuple(i64,string))<computes>:tuple(i64,string)=Block{P:=tuple{S(0),1};tuple{P(0)+P(1),S(1)+ToString(Attempt(S(1)[P(0)],'?'))+\"{0u1F600}\"}}\nV<public>:tuple(i64,string)=Iterate(Step,15,tuple{0,\"aé\"})",
    // The acceptance shape: a cell write, a tuple and a call per visit.
    "var Count:i64=0\nStep(S:i64)<transacts>:i64=Block{set Count=Count+1;T:=tuple{S,S+1};T(1)}\nTotal<public>:i64=Iterate(Step,200,0)\nSeen<public>:i64=Count",
    // The state itself is an aggregate, so each visit's survivor slides down.
    "Step(S:tuple(i64,i64))<computes>:tuple(i64,i64)=tuple{S(1),S(0)+S(1)}\nFib<public>:tuple(i64,i64)=Iterate(Step,60,tuple{0,1})",
    // A state that names another aggregate built in the same visit.
    "R:=struct{N:i64,Items:[]i64}\nStep(X:R)<computes>:R=R{N:=X.N+1,Items:=array{X.N,X.N+1}}\nV<public>:R=Iterate(Step,50,R{N:=0,Items:=array{}})",
    "Step(S:tuple(tuple(i64,i64),[]i64))<computes>:tuple(tuple(i64,i64),[]i64)=Block{P:=tuple{S(0)(1),S(0)(0)+1};Dead:=array{P(0),P(1)};tuple{P,array{Dead.Length,P(0)}}}\nV<public>:tuple(tuple(i64,i64),[]i64)=Iterate(Step,40,tuple{tuple{0,0},array{}})",
    // Arrays that really accumulate: in place, and past garbage that sits between appends.
    "Grow(S:[]i64)<computes>:[]i64=S+array{S.Length}\nAll<public>:[]i64=Iterate(Grow,100,array{})",
    "Grow(S:[]i64)<computes>:[]i64=Block{T:=tuple{S.Length,1};S+array{T(0)}}\nAll<public>:[]i64=Iterate(Grow,60,array{})",
    "Grow(S:[][]i64)<computes>:[][]i64=S+array{array{S.Length,S.Length+1}}\nAll<public>:[][]i64=Iterate(Grow,30,array{})",
    // Cells keep aggregates that a visit built, replaced visit after visit.
    "var Last:tuple(i64,i64)=tuple{0,0}\nStep(S:i64)<transacts>:i64=Block{set Last=tuple{S,S*2};Last(1)-S+1}\nTotal<public>:i64=Iterate(Step,80,0)\nKept<public>:tuple(i64,i64)=Last",
    "var Log:[]i64=array{}\nStep(S:i64)<transacts>:i64=Block{T:=tuple{S,S};set Log=Log+array{T(0)};S+1}\nTotal<public>:i64=Iterate(Step,50,0)\nKept<public>:[]i64=Log",
    // Instances hold aggregates: one made before the loop and rewritten, and one per visit.
    \\Bag:=class{var Items:[]i64}
    \\Fill(B:Bag,S:i64)<transacts>:i64=Block{set B.Items=array{S,S+1};T:=tuple{S,B.Items.Length};S+T(1)-1}
    \\Run(N:i64)<transacts>:[]i64=Block{B:=Bag{Items:=array{}};Iterate(Fn(S:i64){Fill(B,S)},N,0);B.Items}
    \\End<public>:[]i64=Run(60)
    ,
    "P:=class{var T:tuple(i64,i64)}\nStep(S:i64)<transacts>:i64=Block{X:=P{T:=tuple{S,S+1}};Y:=tuple{X.T(1),0};Y(0)}\nTotal<public>:i64=Iterate(Step,40,0)\nLast<public>:P=P{T:=tuple{Total,Total}}",
    // Captures: a callable bound in a visit, one iterated over, and one that is the state.
    "Add(A:tuple(i64,i64),B:i64)<computes>:i64=A(0)+A(1)+B\nStep(S:i64)<computes>:i64=Block{F:=Bind(Add,tuple{S,1});F(0)}\nTotal<public>:i64=Iterate(Step,50,0)",
    "Scale(K:tuple(i64,i64),S:i64)<computes>:i64=Block{T:=tuple{S,K(1)};T(0)+K(0)}\nF:function(tuple(i64),i64)=Bind(Scale,tuple{2,3})\nA<public>:i64=Iterate(F,40,0)",
    "Plus(K:i64,X:i64)<computes>:i64=K+X\nNext(F:function(tuple(i64),i64))<computes>:function(tuple(i64),i64)=Bind(Plus,F(1))\nF<public>:function(tuple(i64),i64)=Iterate(Next,30,Bind(Plus,0))\nA<public>:i64=F(0)",
    "Twice(K:i64)<computes>:i64=Iterate(Fn(S:tuple(i64,i64)){tuple{S(1),S(0)+K}},9,tuple{1,K})(1)\nStep(S:i64)<computes>:i64=S+Twice(S)-Twice(S)+1\nA<public>:i64=Iterate(Step,25,0)",
    // Loops inside loops and calls inside loops, each with its own mark.
    "Inner(S:tuple(i64,i64))<computes>:tuple(i64,i64)=tuple{S(0)+1,S(1)+S(0)}\nOuter(S:i64)<computes>:i64=Block{T:=Iterate(Inner,5,tuple{S,0});U:=tuple{T(1),S};S+U(0)-T(1)+1}\nTotal<public>:i64=Iterate(Outer,30,0)",
    "Pair(N:i64)<computes>:tuple(i64,i64)=If(N==0,tuple{0,0},Block{P:=Pair(N-1);tuple{P(1),P(0)+N}})\nStep(S:tuple(i64,i64))<computes>:tuple(i64,i64)=Block{P:=Pair(6);tuple{S(1)+P(0),S(0)+P(1)}}\nB<public>:tuple(i64,i64)=Iterate(Step,20,tuple{0,0})\nC<public>:tuple(i64,i64)=Pair(25)",
    "Build(N:i64)<computes>:[]i64=If(N==0,array{},Build(N-1)+array{N})\nA<public>:[]i64=Build(30)\nB<public>:i64=Build(20).Length",
    // Failure and rollback: a failed frame's members, a restored cell, a trace after reclaiming.
    "var C:i64=0\nTry(S:i64)<transacts><decides>:tuple(i64,i64)=Block{set C=C+1;T:=tuple{S,C};Require[S<5];T}\nStep(S:i64)<transacts>:i64=Block{P:=Attempt(Try[S],tuple{S,-1});S+1+P(1)-P(1)}\nTotal<public>:i64=Iterate(Step,12,0)\nSeen<public>:i64=C",
    "var Held:tuple(i64,i64)=tuple{7,8}\nStep(S:i64)<transacts>:i64=Block{set Held=tuple{S,S};T:=tuple{S,1};S+T(1)}\nBad(N:i64)<transacts><decides>:i64=Block{X:=Iterate(Step,N,0);Fail[\"stop\"];X}\nA<public>:i64=Attempt(Bad[30],-1)\nKept<public>:tuple(i64,i64)=Held\nB<public>:i64=Iterate(Step,30,0)\nNow<public>:tuple(i64,i64)=Held",
    "Step(S:tuple(i64,string))<transacts><decides>:tuple(i64,string)=Block{Require[S(0)<25];tuple{S(0)+1,S(1)}}\nF:function<transacts><decides>(tuple(tuple(i64,string)),tuple(i64,string))=Step\nA<public>:i64=Attempt(Iterate(F,40,tuple{0,\"a\"})(0),-1)\nB<public>:i64=Attempt(Iterate(F,20,tuple{0,\"b\"})(0),-1)",
    // State loops and the loops written over them.
    "Next(S:tuple(i64,i64))<computes>:option(tuple(i64,i64))=If(S(0)<40,option{tuple{S(0)+1,S(1)+S(0)}},option{})\nEnd<public>:tuple(i64,i64)=Loop(Next,tuple{0,0})",
    "Spin(N:i64)<transacts>:i64=Block{var I:i64=0;var Acc:i64=0;While(I<N,Block{set Acc=Acc+I*I;set I=I+1});Acc}\nA<public>:i64=Spin(60)\nSq(N:i64)<computes>:[]i64=For(X:array{1,2,3,4,5,6,7,8},X*N)\nG<public>:[]i64=Sq(3)\nH(S:i64)<computes>:i64=S+Sq(S).Length-7\nI<public>:i64=Iterate(H,12,0)",
    // Loops that are left early (RFC-0068): the locals a `Loop{}` carries travel in its state,
    // through a `Break`, through a `Return` out of a `For` inside it, and past a failure.
    "Spin(N:i64)<transacts>:tuple(i64,i64)=Block{var Last:tuple(i64,i64)=tuple{0,0};var I:i64=0;Loop{set I=I+1;set Last=tuple{I,Last(0)};Dead:=tuple{I,I};If(I>=N,Break(),false)};Last}\nA<public>:tuple(i64,i64)=Spin(40)",
    "Items:[]i64=array{4,5,6}\nFind(T:i64)<transacts>:tuple(i64,[]i64)=Block{var Seen:[]i64=array{};var R:i64=0;Loop{set R=R+1;For(X:Items,Block{Pair:=tuple{X,R};If(Pair(0)*Pair(1)>T,Return(tuple{R,Seen+array{X}}),false)});set Seen=Seen+array{R}};tuple{0,Seen}}\nB<public>:tuple(i64,[]i64)=Find(40)",
    "var C:[]i64=array{}\nWork(N:i64)<transacts><decides>:i64=Block{var I:i64=0;Loop{Defer{set C=C+array{I}};set I=I+1;T:=tuple{I,N};Require[T(0)<9];If(I>=N,Break(),false)};I}\nA<public>:i64=Attempt(Work[6],-1)\nB<public>:i64=Attempt(Work[20],-2)\nK<public>:[]i64=C",
    // More of the same from the independent review: a `Return` that commits nested regions,
    // `Defer`s through a `For`, and a loop that fails, each holding aggregates.
    "var Count:i64=0\nSpin(N:i64)<transacts>:i64=Block{var Last:tuple(i64,i64)=tuple{0,0};Loop{set Count=Count+1;set Last=tuple{Count,Last(0)};If(Count>=N,Break(),false)};Last(0)*10+Last(0)-Last(1)}\nTotal<public>:i64=Spin(60)\nSeen<public>:i64=Count",
    "var Held:tuple(i64,i64)=tuple{7,8}\nIn(N:i64)<transacts>:tuple(i64,i64)=Attempt(Block{set Held=tuple{N,N};Attempt(Block{set Held=tuple{N,Held(0)+1};T:=tuple{N,2};If(N>0,Return(tuple{T(1),Held(1)}),false);Fail[\"no\"];Held},tuple{0,0})},tuple{1,1})\nStep(S:i64)<transacts>:i64=Block{P:=Attempt(Block{Q:=In(S);Require[S<10];Q},tuple{S,-1});S+1+P(1)-P(1)}\nTotal<public>:i64=Iterate(Step,20,0)\nKept<public>:tuple(i64,i64)=Held",
    "var Trace:[]i64=array{}\nItems:[]i64=array{5,6,7}\nFind(T:i64)<transacts>:tuple(i64,i64)=Block{Defer{set Trace=Trace+array{T}};For(I->X:Items,Block{Defer{set Trace=Trace+array{X}};If(X==T,Return(tuple{I,X}),false);0});tuple{-1,-1}}\nStep(S:i64)<transacts>:i64=S+Find(5+S-(S/4)*4)(0)+2\nTotal<public>:i64=Iterate(Step,8,0)\nN<public>:i64=Trace.Length",
    "var Cell:tuple(i64,i64)=tuple{0,0}\nStrict(N:i64)<transacts><decides>:tuple(i64,i64)=Block{var I:i64=0;var P:tuple(i64,i64)=tuple{0,0};Loop{set Cell=tuple{I,N};set P=tuple{P(1),I};Require[I<N];set I=I+1;If(I>=3,Break(),false)};P}\nStep(S:i64)<transacts>:i64=Block{Q:=Attempt(Strict[S],tuple{9,9});S+1+Q(0)-Q(0)}\nTotal<public>:i64=Iterate(Step,12,0)\nKept<public>:tuple(i64,i64)=Cell",
    "Rev:=native{\"std.reversed\"}\nStep(S:[]i64)<computes>:[]i64=Rev(S+array{S.Length})\nR<public>:[]i64=Iterate(Step,12,array{})",
    // The same loops with the forms of RFC-0066, RFC-0070 and RFC-0072 in them: a `Loop{}` that
    // carries a tuple holding a rational, a `First` whose result is a tuple, and a `Case` over it
    // whose arms break and return.
    "Xs:[]i64=array{3,5,7}\nTerm(K:i64)<computes>:rational=Attempt(Rational[1,K],MakeRationalFromInt(0))\nWalk(N:i64)<transacts>:tuple(rational,i64)=Block{var Acc:tuple(rational,i64)=tuple{MakeRationalFromInt(0),0};var I:i64=0;Loop{set I=I+1;Dead:=array{Acc(0),Term(I)};Y:=Attempt(First[X:Xs,X>I,tuple{X,I}],tuple{0,0});Case(Y,tuple{0,_} => Break(),tuple{X,_} where X>N => Return(tuple{Acc(0)+Term(X),X}),_ => false);set Acc=tuple{Acc(0)+Term(Y(0)),Y(1)}};Acc}\nStep(S:i64)<transacts>:i64=S+Walk(S)(1)+1\nTotal<public>:i64=Iterate(Step,3,0)\nLast<public>:tuple(rational,i64)=Walk(9)",
    // Maps, strings in members, and empty aggregates as state.
    "var Scores:map(string,i64)=map{\"a\"=>1}\nStep(S:i64)<transacts>:i64=Block{set Scores[\"a\"]=S;set Scores[\"b\"]=S+1;T:=tuple{S,1};S+T(1)}\nTotal<public>:i64=Iterate(Step,30,0)\nM<public>:map(string,i64)=Scores",
    "Step(S:tuple(string,i64))<computes>:tuple(string,i64)=tuple{S(0)+\"x\",S(1)+1}\nT<public>:tuple(string,i64)=Iterate(Step,20,tuple{\"a\",0})",
    "KA(X:[]i64)<computes>:[]i64=Block{T:=tuple{X.Length,0};X}\nKO(X:option(i64))<computes>:option(i64)=Block{T:=tuple{1,2};X}\nA<public>:[]i64=Iterate(KA,9,array{})\nO<public>:option(i64)=Iterate(KO,9,option{})",
    // Rationals are two-word scalars: inside a state they move with it and are never followed.
    "Term(K:i64)<computes>:rational=Attempt(Rational[1,K*(K+1)],MakeRationalFromInt(0))\nStep(S:tuple(rational,i64))<computes>:tuple(rational,i64)=Block{Dead:=array{S(0),-S(0)};tuple{S(0)+Term(S(1)),S(1)+Dead.Length-1}}\nSum<public>:tuple(rational,i64)=Iterate(Step,60,tuple{MakeRationalFromInt(0),1})\nvar Held:map(rational,i64)=map{}\nPut(S:i64)<transacts>:i64=Block{set Held[Term(S+1)]=S;S+1}\nCount<public>:i64=Iterate(Put,20,0)+Held.Length",
    // Members a native made, which a replay admits and does not rebuild: dropped, and kept.
    native_garbage,
    "Rev:=native{\"std.reversed\"}\nStep(S:[]i64)<computes>:[]i64=Rev(S+array{S.Length})\nR<public>:[]i64=Iterate(Step,12,array{})",
};
const native_garbage = "Sorted:=native{\"std.sorted\"}\nStep(S:i64)<computes>:i64=Block{A:=Sorted(array{S,3,1});S+A.Length-2}\nTotal<public>:i64=Iterate(Step,30,0)";

/// Programs that build run strings and class instances inside frames and loop visits, drop
/// some, and keep others by every kind of value that can name one: the state, a cell, a field
/// of another instance, a member, a capture, a map key, a failure trace, a rolled back region.
const stores = [_][]const u8{
    // Strings. A string per visit of which only the length is kept.
    "Step(S:i64)<computes>:i64=Block{T:=\"n{S}\";S+T.Length-T.Length+1}\nTotal<public>:i64=Iterate(Step,60,0)",
    // A state that grows in place while each visit also leaves a string behind.
    "Step(S:tuple(i64,string))<computes>:tuple(i64,string)=Block{D:=ToString(S(0))+\"-\";tuple{S(0)+D.Length,S(1)+\"x\"}}\nV<public>:tuple(i64,string)=Iterate(Step,30,tuple{0,\"a\"})",
    // A cell that keeps a view into the string a visit built, replaced visit after visit.
    "Cut(T:string,I:i64)<computes><decides>:string=T.Slice[I]\nvar Last:string=\"\"\nStep(S:i64)<transacts>:i64=Block{T:=\"item{S}!\";set Last=Attempt(Cut[T,2],T);S+1}\nTotal<public>:i64=Iterate(Step,40,0)\nKept<public>:string=Last",
    // A cell that accumulates text behind the garbage of every visit.
    "var Acc:string=\"\"\nStep(S:i64)<transacts>:i64=Block{T:=\"{S},\";U:=T+T;set Acc=Acc+T;S+U.Length-U.Length+1}\nTotal<public>:i64=Iterate(Step,30,0)\nAll<public>:string=Acc",
    // Reasons of failures are strings a visit built; the traces keep the first of them.
    "Bad(N:i64)<computes><decides>:i64=Block{Fail[\"bad{N}\"];N}\nStep(S:i64)<transacts>:i64=Block{D:=\"x{S}\";Attempt(Bad[S],S+D.Length-D.Length+1)}\nTotal<public>:i64=Iterate(Step,40,0)",
    // Strings inside members and maps, empty strings, and strings a native built or cut.
    "Step(S:tuple(i64,[]string))<computes>:tuple(i64,[]string)=Block{T:=\"k{S(0)}\";E:=\"\"+\"\";D:=tuple{T,E,T+T};tuple{S(0)+1,If(S(0)<6,S(1)+array{D(2)},array{E,T})}}\nV<public>:tuple(i64,[]string)=Iterate(Step,20,tuple{0,array{}})",
    "var Names:map(string,i64)=map{}\nStep(S:i64)<transacts>:i64=Block{K:=\"key{S-(S/4)*4}\";set Names[K]=S;D:=K+K;S+1}\nTotal<public>:i64=Iterate(Step,24,0)\nM<public>:map(string,i64)=Names",
    "Upper:=native{\"std.upper\"}\nSplit:=native{\"std.split\"}\nJoin:=native{\"std.join\"}\nStep(S:tuple(i64,string))<computes>:tuple(i64,string)=Block{T:=Upper(\"ab{S(0)},cd\");P:=Split(T,\",\");tuple{S(0)+P.Length-1,Join(P,\"+\")}}\nV<public>:tuple(i64,string)=Iterate(Step,20,tuple{0,\"\"})",
    // Instances. One per visit, written, read and dropped.
    "P:=class{var N:i64}\nStep(S:i64)<transacts>:i64=Block{X:=P{N:=S};set X.N=X.N+1;X.N}\nTotal<public>:i64=Iterate(Step,60,0)",
    // The last three instances travel in the state; older ones become unreachable.
    "P:=class{var N:i64}\nStep(S:tuple(P,P,P))<transacts>:tuple(P,P,P)=tuple{S(1),S(2),P{N:=S(2).N+1}}\nEnd<public>:tuple(P,P,P)=Iterate(Step,50,tuple{P{N:=0},P{N:=1},P{N:=2}})\nSum<public>:i64=End(0).N+End(2).N",
    // The same window in an array cell that is written an element at a time.
    "P:=class{var N:i64}\nvar Ring:[]P=array{P{N:=0},P{N:=0},P{N:=0}}\nStep(S:i64)<transacts>:i64=Block{X:=P{N:=S};Attempt(Block{set Ring[S-(S/3)*3]=X;0},1);S+1}\nTotal<public>:i64=Iterate(Step,40,0)\nSum<public>:i64=Attempt(Ring[0].N+Ring[1].N+Ring[2].N,-1)",
    // A linked list built node by node and then walked again and again: everything stays.
    "Node:=class{Value:i64,var Next:option(Node)}\nPush(S:option(Node))<transacts>:option(Node)=option{Node{Value:=1,Next:=S}}\nHead:option(Node)=Iterate(Push,30,option{})\nWalk(S:tuple(option(Node),i64))<transacts>:option(tuple(option(Node),i64))=Attempt(Block{N:=S(0)?;D:=tuple{N.Value,1};option{tuple{N.Next,S(1)+D(0)}}},option{})\nSum(K:i64)<transacts>:i64=K+Loop(Walk,tuple{Head,0})(1)-29\nTotal<public>:i64=Iterate(Sum,6,0)",
    // A list that grows at its tail: each node is named only by the field of the one before.
    "Node:=class{Value:i64,var Next:option(Node)}\nFirst:Node=Node{Value:=0,Next:=option{}}\nGrow(Last:Node)<transacts>:Node=Block{N:=Node{Value:=Last.Value+1,Next:=option{}};D:=Node{Value:=-1,Next:=option{N}};set Last.Next=option{N};N}\nEnd<public>:Node=Iterate(Grow,30,First)\nLength<public>:i64=End.Value",
    // Instances and strings made inside regions that fail.
    "P:=class{var N:i64,var T:string}\nTry(S:i64)<transacts><decides>:i64=Block{X:=P{N:=S,T:=\"t{S}\"};set X.N=S+1;Require[S<5];X.N+X.T.Length}\nStep(S:i64)<transacts>:i64=Block{V:=Attempt(Try[S],S+1);S+1+V-V}\nTotal<public>:i64=Iterate(Step,12,0)",
    // Records that name instances: one made before the regions and one made inside them,
    // written in a nested region that commits, and rolled back or kept by the outer one.
    "P:=class{var N:i64}\nvar Hold:P=P{N:=0}\nStep(S:i64)<transacts>:i64=Block{A:=Attempt(Block{X:=P{N:=S};Attempt(Block{set X.N=S+1;set Hold.N=S;Require[S<6];0},1);set Hold=X;Require[S<9];X.N},-1);S+1+A-A}\nTotal<public>:i64=Iterate(Step,14,0)\nKept<public>:i64=Hold.N",
    // A write that drops the last reference to an instance, undone: while the region is open
    // an inner loop reclaims, and afterwards the field names the old instance again.
    "P:=class{var N:i64}\nQ:=class{var Ref:P}\nPoke(B:Q,K:i64)<transacts>:i64=Block{set B.Ref=P{N:=K};D:=P{N:=0-K};K+1}\nStep(S:i64)<transacts>:i64=Block{Old:=P{N:=S};B:=Q{Ref:=Old};R:=Attempt(Block{set B.Ref=P{N:=-1};Iterate(Fn(K:i64){Poke(B,K)},4,0);Require[S<0];0},B.Ref.N);S+1+R-S}\nTotal<public>:i64=Iterate(Step,10,0)",
    // The same with the regions opened before the loop: every visit runs inside them, so what
    // they would restore is older than every visit.
    "P:=class{var N:i64}\nQ:=class{var Ref:P}\nvar Seen:i64=0\nPoke(B:Q,K:i64)<transacts>:i64=Block{set B.Ref=P{N:=K};set Seen=Seen+1;D:=P{N:=0-K};K+1}\nRun(B:Q)<transacts><decides>:i64=Block{X:=Iterate(Fn(K:i64){Poke(B,K)},9,0);Require[X<0];X}\nOld:P=P{N:=7}\nBox:Q=Q{Ref:=Old}\nA<public>:i64=Attempt(Attempt(Run[Box],Run[Box]),Box.Ref.N)\nB<public>:i64=Seen\nMore(K:i64)<transacts>:i64=Poke(Box,K)\nC<public>:i64=Iterate(More,9,0)+Box.Ref.N",
    // Cycles: two instances that name each other, dropped, and one such pair kept by a cell.
    "N:=class{var Other:option(N),Tag:i64}\nvar Keep:option(N)=option{}\nStep(S:i64)<transacts>:i64=Block{A:=N{Other:=option{},Tag:=S};B:=N{Other:=option{A},Tag:=0-S};set A.Other=option{B};If(S==7,Block{set Keep=option{B};0},0);S+1}\nTotal<public>:i64=Iterate(Step,30,0)\nBack<public>:i64=Attempt(Block{B:=Keep?;A:=B.Other?;C:=A.Other?;A.Tag*100+C.Tag},-1)",
    // An instance named only by the captures of a function value that is the state.
    "P:=class{var N:i64}\nGet(X:P,K:i64)<transacts>:i64=X.N+K\nStep(S:tuple(i64,function<transacts>(tuple(i64),i64)))<transacts>:tuple(i64,function<transacts>(tuple(i64),i64))=Block{X:=P{N:=S(0)+1};D:=P{N:=0};tuple{S(1)(0),Bind(Get,X)}}\nSeed:P=P{N:=0}\nV<public>:i64=Iterate(Step,30,tuple{0,Bind(Get,Seed)})(0)",
    // Instances named only as keys of a map: in a state, and in a cell that drops them again.
    "P:=class<unique>{var N:i64}\nStep(S:map(P,i64))<transacts>:map(P,i64)=Block{X:=P{N:=S.Length};D:=P{N:=-1};If(S.Length<4,Block{var M:map(P,i64)=S;set M[X]=X.N;M},map{X=>0})}\nM<public>:map(P,i64)=Iterate(Step,22,map{})\nCount<public>:i64=M.Length",
    "P:=class<unique>{var N:i64}\nvar Seen:map(P,i64)=map{}\nStep(S:i64)<transacts>:i64=Block{X:=P{N:=S};set Seen=If(Seen.Length<3,Seen,map{});set Seen[X]=S;S+1}\nTotal<public>:i64=Iterate(Step,20,0)\nSize<public>:i64=Seen.Length",
    // An instance named only by what a deferred body will read, across loops that reclaim.
    "P:=class{var N:i64}\nvar Sum:i64=0\nWork(S:i64)<transacts>:i64=Block{X:=P{N:=S};Defer{set Sum=Sum+X.N};Iterate(Fn(K:i64){Block{D:=P{N:=K};K+D.N-D.N+1}},3,0);S+1}\nTotal<public>:i64=Iterate(Work,20,0)\nSeen<public>:i64=Sum",
    "P:=class{var N:i64}\nvar Sum:i64=0\nWork(N:i64)<transacts>:i64=Block{var I:i64=0;Loop{X:=P{N:=I};Defer{set Sum=Sum+X.N};set I=I+1;D:=P{N:=0};If(I>=N,Break(),false)};I}\nTotal<public>:i64=Work(25)\nSeen<public>:i64=Sum",
    // A local of a `Loop{}` that holds an instance from one visit to the next.
    "P:=class{var N:i64}\nSpin(N:i64)<transacts>:i64=Block{var Cur:P=P{N:=0};var I:i64=0;Loop{set I=I+1;set Cur=P{N:=Cur.N+I};D:=P{N:=0};If(I>=N,Break(),false)};Cur.N}\nA<public>:i64=Spin(40)",
    // Instances that hold strings and aggregates, held by options inside tuples inside a cell.
    "P:=class{var T:string,var Items:[]i64}\nvar Slot:tuple(i64,option(P))=tuple{0,option{}}\nStep(S:i64)<transacts>:i64=Block{X:=P{T:=\"p{S}\",Items:=array{S,S+1}};D:=P{T:=\"dead\"+X.T,Items:=array{}};set Slot=tuple{S,option{X}};S+1}\nTotal<public>:i64=Iterate(Step,30,0)\nText<public>:string=Attempt(Block{X:=Slot(1)?;X.T},\"none\")\nSize<public>:i64=Attempt(Block{X:=Slot(1)?;X.Items[0]+X.Items.Length},-1)",
    // Calls that return instances and strings through several frames.
    "P:=class{var N:i64,var T:string}\nMake(N:i64)<transacts>:P=If(N==0,P{N:=0,T:=\"z\"},Block{Q:=Make(N-1);D:=P{N:=N,T:=Q.T+\"d\"};P{N:=Q.N+N,T:=Q.T+\"a\"}})\nStep(S:i64)<transacts>:i64=Block{X:=Make(5);S+X.N+X.T.Length-20}\nTotal<public>:i64=Iterate(Step,12,0)\nLast<public>:P=Make(7)",
    // Two strings that start at one place: the state's grew in place from the one a cell
    // holds, so the bytes in use reach as far as the longer of them, whichever is met last.
    "var Short:string=\"\"\nStep(S:tuple(i64,string))<transacts>:tuple(i64,string)=Block{A:=\"p{S(0)}\";set Short=A;B:=A+\"-long-tail\";D:=\"dead{S(0)}\";tuple{S(0)+D.Length-D.Length+1,B}}\nV<public>:tuple(i64,string)=Iterate(Step,20,tuple{0,\"\"})\nKept<public>:string=Short",
    "var Long:string=\"\"\nStep(S:tuple(i64,string))<transacts>:tuple(i64,string)=Block{A:=\"q{S(0)}\";B:=A+\"-long-tail\";set Long=B;D:=\"dead{S(0)}\";tuple{S(0)+D.Length-D.Length+1,A}}\nV<public>:tuple(i64,string)=Iterate(Step,20,tuple{0,\"\"})\nKept<public>:string=Long",
    // The standard forms (RFC-0077). Rows moved by the generic kernels name members below
    // them: a state of rows that is sliced, searched, flattened and rebuilt visit after visit.
    "Step(S:[][]i64)<computes>:[][]i64=Block{Row:=array{S.Length,S.Length+1};Flat:=Concatenate(S);At:=Attempt(Flat.Find[S.Length],0);Tail:=Attempt(S.Slice[1],S);Grown:=Attempt(Tail.Insert[0,array{Row,Flat.RemoveAllElements(At)}],Tail);Attempt(Grown.Remove[2,Grown.Length],Grown)}\nV<public>:[][]i64=Iterate(Step,40,array{array{1},array{2,3}})",
    // Maps merged and text replaced, inserted and cut inside visits; a cell keeps the last of each.
    "var Names:map(string,i64)=map{}\nvar Line:string=\"\"\nStep(S:i64)<transacts>:i64=Block{K:=\"k{S-(S/5)*5}\";set Names=ConcatenateMaps(Names,map{K=>S,\"last\"=>S});T:=\"a-{S}-a\".ReplaceAll(\"a\",\"bb\");set Line=Attempt(T.Insert[2,K].Remove[0,1],T);D:=Join(array{T,K},\"/\");S+D.Length-D.Length+Abs(0-1)}\nTotal<public>:i64=Iterate(Step,40,0)\nM<public>:map(string,i64)=Names\nL<public>:string=Line",
    // From the review of RFC-0077: records that hold arrays of strings, rows of strings, maps
    // of arrays in a cell, floats through a region that fails, and text with a two-unit scalar,
    // each rebuilt by several standard forms a visit.
    "Pt:=struct{X:i64,Tags:[]string}\nStep(S:[]Pt)<computes>:[]Pt=Block{N:=S.Length;P:=Pt{X:=N,Tags:=array{\"t{N}\",\"u\"}};Dead:=array{P,P};A:=Attempt(S.Insert[0,array{P}],S);B:=A.ReplaceAllElements(P,Pt{X:=0-N,Tags:=array{\"r{N}\"}});C:=Attempt(B.ReplaceElement[0,P],B);D:=Attempt(C.ReplaceFirstElement[P,Pt{X:=N*2,Tags:=P.Tags}],C);E:=D.RemoveAllElements(Pt{X:=4,Tags:=array{\"t2\",\"u\"}});Attempt(E.Slice[0,6],E)}\nV<public>:[]Pt=Iterate(Step,30,array{})",
    "Step(S:[][]string)<computes>:[][]string=Block{N:=S.Length;Row:=array{\"a{N}\",\"b\"};T:=tuple{N,Row};X:=Concatenate(S,array{Row},array{array{\"z\"}});Y:=X.ReplaceAll(array{array{\"z\"},Row},array{Row,Row});Z:=Y.RemoveAllElements(array{\"z\"});L:=Attempt(Z.Last[1],Row);W:=Attempt(Z.RemoveFirstElement[L],Z);Attempt(W.Remove[0,W.Length-5],W)}\nV<public>:[][]string=Iterate(Step,40,array{})\nF<public>:[]string=Concatenate(V)\nJ<public>:string=Join(F,\"+\")",
    "var Held:map(string,[]i64)=map{}\nStep(S:i64)<transacts>:i64=Block{K:=\"k{S-(S/3)*3}\";Old:=Or(Lookup(Held,K),array{});set Held=ConcatenateMaps(map{K=>Old+array{S},\"x{S}\"=>array{}},Held);Dead:=ConcatenateMaps(Held,Held);set Held=ConcatenateMaps(Held,map{K=>Attempt(Old.Insert[0,array{S}],Old)});S+1}\nTotal<public>:i64=Iterate(Step,25,0)\nM<public>:map(string,[]i64)=Held",
    "Bad(S:[]float)<computes><decides>:[]float=Block{T:=S.ReplaceAllElements(NaN,0.5);U:=T.Insert[1,array{Sqrt(2.0)}];U.Find[7.0];U}\nStep(S:[]float)<computes>:[]float=Block{A:=Attempt(Bad[S],S);B:=Attempt(S.Insert[0,array{Lerp(1.0,2.0,0.5),NaN}],S);X:=Attempt(B.Last[].IsFinite[],Pow(2.0,3.0));Attempt(B.Slice[0,8].ReplaceElement[3,X],B)}\nV<public>:[]float=Iterate(Step,30,array{1.0})",
    "var Text:string=\"é\"\nStep(S:[]string)<transacts>:[]string=Block{N:=S.Length;T:=Text.ReplaceAll(\"é\",\"éa{N}\");set Text=Attempt(T.Remove[0,2],T);U:=Attempt(T.Insert[2,\"-\"],T);C:=Attempt(U.Last[],0o3F);P:=Attempt(U.Find[C],0-1);X:=S.ReplaceAllElements(T,U)+array{T,\"p{P}\"};Attempt(X.Slice[X.Length-6],X)}\nV<public>:[]string=Iterate(Step,24,array{})\nK<public>:string=Text",
};
/// Text that says what a finished run left reachable from its bindings and nothing else: each
/// binding's value, then every instance a binding reaches, with its fields. An instance is
/// named by how many reachable instances were created before it, so two runs that differ only
/// in which unreachable instances they still hold, and so in the ids of the others, read the
/// same. A stored run keeps every instance it created; a run that reclaims keeps fewer and
/// numbers the rest by where they lie afterwards.
const Graph = struct {
    x: evaluator.Execution,
    reached: []bool,
    rank: []u32,
    out: std.ArrayList(u8) = .empty,

    fn create(x: evaluator.Execution) !Graph {
        const allocator = std.testing.allocator;
        const reached = try allocator.alloc(bool, x.object_cells.len);
        errdefer allocator.free(reached);
        @memset(reached, false);
        return .{ .x = x, .reached = reached, .rank = try allocator.alloc(u32, x.object_cells.len) };
    }
    fn destroy(self: *Graph) void {
        std.testing.allocator.free(self.reached);
        std.testing.allocator.free(self.rank);
        self.out.deinit(std.testing.allocator);
    }
    fn follow(self: *Graph, value: types.Value) !void {
        switch (value) {
            .aggregate => |aggregate| for (self.x.aggregate_values[aggregate.elements.start..aggregate.elements.end]) |member| try self.follow(member),
            .callable => |callable| for (self.x.aggregate_values[callable.captures.start..callable.captures.end]) |member| try self.follow(member),
            .object => {
                const cells = self.x.objectCells(value) orelse return error.DanglingInstance;
                const first = value.object.id - self.x.program.source_cells.len;
                try std.testing.expectEqual(@as(i64, @backingInt(value.object.value_type)), cells[0].value.integer);
                if (self.reached[first]) return;
                self.reached[first] = true;
                for (cells[1..]) |cell| try self.follow(cell.value);
            },
            else => {},
        }
    }
    fn print(self: *Graph, value: types.Value) !void {
        const allocator = std.testing.allocator;
        switch (value) {
            .integer => |v| try self.out.print(allocator, "{d}", .{v}),
            .boolean => |v| try self.out.print(allocator, "{}", .{v}),
            .floating => |v| try self.out.print(allocator, "f{x}", .{@as(u64, @bitCast(v))}),
            .string => |v| try self.out.print(allocator, "\"{s}\"", .{v}),
            .rational => |v| try self.out.print(allocator, "{d}/{d}", .{ v.numerator, v.denominator }),
            .enumeration => |v| try self.out.print(allocator, "e{d}.{d}", .{ @backingInt(v.value_type), v.index }),
            .object => |v| try self.out.print(allocator, "#{d}", .{self.rank[v.id - self.x.program.source_cells.len]}),
            .aggregate, .callable => {
                const span = if (value == .aggregate) value.aggregate.elements else value.callable.captures;
                if (value == .callable) try self.out.print(allocator, "fn{d}", .{value.callable.function});
                try self.out.append(allocator, '[');
                for (self.x.aggregate_values[span.start..span.end]) |member| {
                    try self.print(member);
                    try self.out.append(allocator, ',');
                }
                try self.out.append(allocator, ']');
            },
        }
    }
    fn text(self: *Graph) ![]const u8 {
        const allocator = std.testing.allocator;
        const x = self.x;
        for (x.program.bindings) |binding| if (x.active(binding.node)) try self.follow(x.values[binding.node]);
        var count: u32 = 0;
        for (self.reached, self.rank) |reached, *rank| {
            rank.* = count;
            count += @intFromBool(reached);
        }
        for (x.program.bindings) |binding| {
            try self.out.print(allocator, "{s}=", .{binding.name.text(x.program.source)});
            if (x.active(binding.node)) try self.print(x.values[binding.node]);
            try self.out.append(allocator, '\n');
        }
        for (self.reached, 0..) |reached, first| if (reached) {
            const class: types.Type = @fromBackingInt(@intCast(x.object_cells[first].value.integer));
            const cells = x.objectCells(.{ .object = .{ .value_type = class, .id = @intCast(x.program.source_cells.len + first) } }).?;
            try self.out.print(allocator, "#{d}:{d}(", .{ self.rank[first], @backingInt(class) });
            for (cells[1..]) |cell| {
                try self.print(cell.value);
                try self.out.append(allocator, ',');
            }
            try self.out.appendSlice(allocator, ")\n");
        };
        return self.out.items;
    }
};
/// The reachable state of a finished run, copied: the run's storage is used again.
fn graphOf(x: evaluator.Execution) ![]u8 {
    var graph = try Graph.create(x);
    defer graph.destroy();
    return std.testing.allocator.dupe(u8, try graph.text());
}
/// What a stored run reported and left reachable, to hold later runs of the program against.
const Stored = struct {
    report: []const u8,
    graph: []u8,
    instance_cells: usize,

    fn of(x: evaluator.Execution, report: []const u8) !Stored {
        return .{ .report = report, .graph = try graphOf(x), .instance_cells = x.object_cells.len };
    }
    fn destroy(self: Stored) void {
        std.testing.allocator.free(self.graph);
    }
    /// A report of a run that reclaimed equals the stored run's report byte for byte: a report
    /// lists the instances its bindings reach under ids that count only those, so it does not
    /// matter which unreachable instances a run still holds.
    fn expect(self: Stored, reported: []const u8, run: evaluator.Execution) !void {
        const graph = try graphOf(run);
        defer std.testing.allocator.free(graph);
        try std.testing.expectEqualStrings(self.graph, graph);
        try std.testing.expect(run.object_cells.len <= self.instance_cells);
        try std.testing.expectEqualStrings(self.report, reported);
    }
};
const Run = struct { reference: evaluator.Execution, actual: evaluator.Execution };

const Fixture = struct {
    inner: replay.Fixture,

    fn create() !Fixture {
        return .{ .inner = try replay.Fixture.create() };
    }
    fn destroy(self: Fixture) void {
        self.inner.destroy();
    }
    fn configure(self: Fixture, trace: types.TraceMode, window: u32, floor: u32) void {
        self.inner.mode(trace, window);
        self.inner.h.control.reclaim_floor = floor;
        self.inner.h.runtime.machine.control.reclaim_floor = floor;
        self.inner.again.control.trace_window = window;
        self.inner.again.control.reclaim_floor = floor;
    }
    fn reference(self: Fixture, p: types.Program, budget: u64) evaluator.Result {
        const h = self.inner.h;
        return evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    }
    /// Runs both machines and requires them to agree on everything a run leaves behind: values,
    /// the whole pool, cells, failures, the witness and how often they reclaimed.
    fn both(self: Fixture, p: types.Program, budget: u64) !Run {
        const h = self.inner.h;
        const expected = self.reference(p, budget);
        const actual = h.runtime.evaluate(p, budget);
        try std.testing.expect(expected == .ok and actual == .ok);
        const a = expected.ok;
        const b = actual.ok;
        try std.testing.expectEqualSlices(bool, a.activity, b.activity);
        try std.testing.expectEqual(a.failure_count, b.failure_count);
        try std.testing.expectEqualDeep(a.failures, b.failures);
        for (a.values, b.values, 0..) |x, y, index| if (b.active(index)) try replay.same(x, y);
        try std.testing.expectEqual(a.aggregate_values.len, b.aggregate_values.len);
        for (a.aggregate_values, b.aggregate_values) |x, y| try replay.same(x, y);
        try std.testing.expectEqual(h.state.cell_count, h.runtime.machine.source.cell_count);
        for (h.state.cells[0..h.state.cell_count], h.runtime.machine.source.cells[0..h.state.cell_count]) |x, y| {
            try std.testing.expectEqual(x.initialized, y.initialized);
            if (x.initialized) try replay.same(x.value, y.value);
        }
        try std.testing.expectEqual(a.object_cells.len, b.object_cells.len);
        try std.testing.expectEqual(a.trace, b.trace);
        try std.testing.expectEqualDeep(a.witness, b.witness);
        try std.testing.expectEqual(a.reclaims, b.reclaims);
        try std.testing.expectEqual(h.control.reclaims, h.runtime.machine.control.reclaims);
        try std.testing.expectEqual(h.control.reclaimed_members, h.runtime.machine.control.reclaimed_members);
        try std.testing.expectEqual(h.control.reclaim_at, h.runtime.machine.control.reclaim_at);
        try std.testing.expectEqual(h.control.reclaimed_bytes, h.runtime.machine.control.reclaimed_bytes);
        try std.testing.expectEqual(h.control.reclaimed_cells, h.runtime.machine.control.reclaimed_cells);
        try std.testing.expectEqual(h.control.string_reclaim_at, h.runtime.machine.control.string_reclaim_at);
        try std.testing.expectEqual(h.control.object_reclaim_at, h.runtime.machine.control.object_reclaim_at);
        // The string pools are one buffer that both machines filled alike, to the same end.
        try std.testing.expectEqual(a.program.strings.len, b.program.strings.len);
        for (a.object_cells, b.object_cells) |x, y| try replay.same(x.value, y.value);
        try wellFormed(a);
        try wellFormed(b);
        return .{ .reference = a, .actual = b };
    }
    /// What both machines make of a budget: the run they agree on, or the diagnostic they
    /// agree on. (The harness's own `run` reports through a stored witness.)
    fn outcome(self: Fixture, p: types.Program, budget: u64) !?types.Diagnostic {
        const h = self.inner.h;
        const expected = self.reference(p, budget);
        if (expected == .ok) {
            _ = try self.both(p, budget);
            return null;
        }
        const actual = h.runtime.evaluate(p, budget);
        try std.testing.expect(actual == .failed);
        try std.testing.expectEqualDeep(expected.failed, actual.failed);
        try std.testing.expect(h.frames.depth == 0 and h.state.depth == 0 and h.runtime.machine.calls.depth == 0 and h.runtime.machine.source.depth == 0);
        try std.testing.expect(h.control.call_count == 0 and h.runtime.machine.control.call_count == 0);
        return actual.failed;
    }
    /// The value report alone, with the work a long run's replay needs.
    fn values(self: Fixture, x: evaluator.Execution, p: types.Program, budget: u64, into: []u8) ![]const u8 {
        var out = std.Io.Writer.fixed(into);
        _ = try reporting.writeReplayed(&out, x, self.inner.again.producer(p, budget), false, .{ .work = 1 << 24 });
        return out.buffered();
    }
    /// The value report and the failure report of a digest run, after its replay admitted it.
    fn report(self: Fixture, x: evaluator.Execution, p: types.Program, budget: u64, into: []u8) ![]const u8 {
        var out = std.Io.Writer.fixed(into);
        _ = try reporting.writeReplayed(&out, x, self.inner.again.producer(p, budget), false, .{});
        try trace_report.writeReplayed(&out, x, self.inner.again.producer(p, budget), "test.forb", .{});
        return out.buffered();
    }
};

/// Every value a finished run still holds names members inside the pool, and every member
/// names only members below itself: nothing was left pointing at reclaimed space.
fn wellFormed(x: evaluator.Execution) !void {
    const top = x.aggregate_values.len;
    for (x.values, 0..) |value, index| if (x.active(index)) try std.testing.expect(end(value) <= top);
    for (x.object_cells) |cell| try std.testing.expect(end(cell.value) <= top);
    for (x.aggregate_values, 0..) |value, index| try std.testing.expect(end(value) <= index);
    // Every string a cell or a trace holds lies in the pool, and every instance a cell names
    // exists: its first cell says so. (Members and registers may name what a rollback forgot.)
    for (x.object_cells) |cell| {
        if (cell.value == .string) try std.testing.expect(inPool(x, cell.value.string));
        if (cell.value == .object) try std.testing.expectEqual(@as(i64, @backingInt(cell.value.object.value_type)), (x.objectCells(cell.value) orelse return error.DanglingInstance)[0].value.integer);
    }
    for (x.failures) |trace| if (trace.reason) |reason| try std.testing.expect(inPool(x, reason));
    try std.testing.expect(std.unicode.utf8ValidateSlice(x.program.strings));
}
fn inPool(x: evaluator.Execution, text: []const u8) bool {
    const pool = x.program.strings;
    const offset = @intFromPtr(text.ptr) -% @intFromPtr(pool.ptr);
    return offset <= pool.len and text.len <= pool.len - offset;
}
fn end(value: types.Value) usize {
    const span = switch (value) {
        .aggregate => |aggregate| aggregate.elements,
        .callable => |callable| callable.captures,
        else => return 0,
    };
    return if (span.start == span.end) 0 else span.end;
}

fn compileAll(f: Fixture, source: []const u8) !types.Program {
    return f.inner.h.compile(source);
}

test "the wait before the next reclamation follows the floor, the room left and the last cost" {
    const due = types.ControlStorage.reclaimDue;
    const limit = types.limits.aggregate_elements;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), due(never, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), due(0, 0, 0));
    try std.testing.expectEqual(@as(u64, 100), due(100, 0, 0));
    try std.testing.expectEqual(@as(u64, 140), due(100, 40, 0));
    // An expensive reclamation is not repeated before an eighth of its cost was appended.
    try std.testing.expectEqual(@as(u64, 40 + 200), due(100, 40, 1600));
    try std.testing.expectEqual(@as(u64, 40 + 100), due(100, 40, 799));
    // A nearly full pool waits for half of what is left, and a full one never reclaims idly.
    try std.testing.expectEqual(@as(u64, limit - 10 + 5), due(100, limit - 10, 0));
    try std.testing.expectEqual(@as(u64, limit), due(100, limit, 0));
    // Storage for a run's steps is far too large for the native stack.
    const control = try @import("scratch.zig").storage(types.ControlStorage);
    defer @import("scratch.zig").release(control);
    @import("scratch.zig").initialise(control);
    control.reset(0);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), control.reclaim_at);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), control.string_reclaim_at);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), control.object_reclaim_at);
    control.trace = .digest;
    control.reset(0);
    try std.testing.expectEqual(@as(u64, types.ControlStorage.default_reclaim_floor), control.reclaim_at);
    // The other stores get the same share of their capacity: an eighth, by default.
    try std.testing.expectEqual(@as(u64, types.limits.string_bytes / 8), control.string_reclaim_at);
    try std.testing.expectEqual(@as(u64, types.limits.object_cells / 8), control.object_reclaim_at);
    const usage = types.ControlStorage.Usage;
    const full: usage = .{ .members = control.reclaim_at, .strings = 4000, .cells = 300 };
    const marks: usage = .{ .members = 16, .strings = 800, .cells = 20 };
    // A frame reclaims when a store is due and holds something the frame built.
    try std.testing.expect(control.reclaimNow(full, marks, 3, false, 0));
    try std.testing.expect(!control.reclaimNow(full, .{ .members = full.members, .strings = 800, .cells = 300 }, 3, false, 0));
    try std.testing.expect(!control.reclaimNow(.{ .members = full.members - 1, .strings = control.string_reclaim_at - 1, .cells = control.object_reclaim_at - 1 }, .{}, 3, false, 0));
    try std.testing.expect(control.reclaimNow(.{ .strings = control.string_reclaim_at }, .{}, 3, false, 0));
    try std.testing.expect(!control.reclaimNow(.{ .strings = control.string_reclaim_at }, .{ .strings = control.string_reclaim_at }, 3, false, 0));
    try std.testing.expect(control.reclaimNow(.{ .cells = control.object_reclaim_at }, .{}, 3, false, 0));
    try std.testing.expect(!control.reclaimNow(.{ .cells = control.object_reclaim_at }, .{ .cells = control.object_reclaim_at }, 3, false, 0));
    // The frame of a call from the root reclaims once more as it returns, but only in a run
    // that has reclaimed before, and only if it built something.
    try std.testing.expect(!control.reclaimNow(.{ .members = 3 }, .{}, 1, true, 0));
    control.reclaims = 1;
    try std.testing.expect(control.reclaimNow(.{ .members = 3 }, .{}, 1, true, 0) and control.reclaimNow(.{ .strings = 3 }, .{}, 1, true, 0) and control.reclaimNow(.{ .cells = 3 }, .{}, 1, true, 0));
    try std.testing.expect(!control.reclaimNow(.{ .members = 3 }, .{}, 1, false, 0) and !control.reclaimNow(.{ .members = 3 }, .{}, 2, true, 0));
    try std.testing.expect(!control.reclaimNow(.{ .members = 3, .strings = 9, .cells = 2 }, .{ .members = 3, .strings = 9, .cells = 2 }, 1, true, 0));
    // And only if what it built is an eighth of what there is to examine: the members and
    // bytes above the marks, every cell and every record.
    try std.testing.expect(control.reclaimNow(.{ .members = 3, .cells = 21 }, .{ .cells = 21 }, 1, true, 0));
    try std.testing.expect(!control.reclaimNow(.{ .members = 3, .cells = 22 }, .{ .cells = 22 }, 1, true, 0) and !control.reclaimNow(.{ .members = 3, .cells = 21 }, .{ .cells = 21 }, 1, true, 4));
    try std.testing.expect(control.reclaimNow(.{ .cells = 30 }, .{ .cells = 26 }, 1, true, 2) and !control.reclaimNow(.{ .cells = 30 }, .{ .cells = 27 }, 1, true, 0));
    try std.testing.expect(control.reclaimNow(.{ .strings = 800, .cells = 700 }, .{ .cells = 700 }, 1, true, 0) and !control.reclaimNow(.{ .strings = 800, .cells = 701 }, .{ .cells = 701 }, 1, true, 0));
    control.reclaims = 0;
    // What it examined: the members and an eighth of the bytes above the marks, every cell,
    // and every record.
    const examined = types.ControlStorage.reclaimExamined(full, marks, 40);
    try std.testing.expectEqual(full.members - 16 + 300 + 3200 / 8 + 40, examined);
    control.reclaimed(full, .{ .members = 10, .strings = 900, .cells = 30 }, 80, 5, 0);
    try std.testing.expectEqual(@as(u64, 1), control.reclaims);
    try std.testing.expectEqual(@as(u64, types.ControlStorage.default_reclaim_floor - 10), control.reclaimed_members);
    try std.testing.expectEqual(@as(u64, 3100), control.reclaimed_bytes);
    try std.testing.expectEqual(@as(u64, 270), control.reclaimed_cells);
    try std.testing.expectEqual(@as(u64, 10 + types.ControlStorage.default_reclaim_floor), control.reclaim_at);
    try std.testing.expectEqual(@as(u64, 900 + types.limits.string_bytes / 8), control.string_reclaim_at);
    try std.testing.expectEqual(@as(u64, 30 + types.limits.object_cells / 8), control.object_reclaim_at);
    // A frame nearer the root than the one that reclaimed does not wait for the floor: it
    // reclaims once that reclamation's work, 80, is paid for by ten members or cells or eighty
    // bytes. A frame as deep or deeper waits for the floor as before.
    for ([_]u32{ 1, 4 }) |depth| {
        try std.testing.expect(!control.reclaimNow(.{ .members = 19, .strings = 979, .cells = 39 }, .{}, depth, false, 0));
        try std.testing.expect(control.reclaimNow(.{ .members = 20 }, .{}, depth, false, 0) and control.reclaimNow(.{ .strings = 980 }, .{}, depth, false, 0) and control.reclaimNow(.{ .cells = 40 }, .{}, depth, false, 0));
        try std.testing.expect(!control.reclaimNow(.{ .members = 20, .strings = 980, .cells = 40 }, .{ .members = 20, .strings = 980, .cells = 40 }, depth, false, 0));
    }
    for ([_]u32{ 5, 6 }) |depth| try std.testing.expect(!control.reclaimNow(.{ .members = 20, .strings = 980, .cells = 40 }, .{}, depth, true, 0));
    // Bytes wait for the whole of what a reclamation examined, cells and members for an eighth.
    const strings = types.ControlStorage.stringDue;
    const objects = types.ControlStorage.objectDue;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), strings(never, 0, 0));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), objects(never, 0, 0, 0));
    try std.testing.expectEqual(@as(u64, 50), strings(0, 50, 0));
    try std.testing.expectEqual(@as(u64, 50 + 1600), strings(0, 50, 1600));
    try std.testing.expectEqual(@as(u64, 50 + 200), objects(0, 0, 50, 1600));
    try std.testing.expectEqual(@as(u64, types.limits.string_bytes - 5), strings(never - 1, types.limits.string_bytes - 10, 0));
    // Half the room the instances have left, which the program's own cells do not lessen.
    try std.testing.expectEqual(@as(u64, 7 + types.limits.object_cells - 5), objects(never - 1, 7, 7 + types.limits.object_cells - 10, 0));
}

test "a task's end after a switch waits for the last reclamation to be paid for only if a switch happened since it" {
    const control = try @import("scratch.zig").storage(types.ControlStorage);
    defer @import("scratch.zig").release(control);
    @import("scratch.zig").initialise(control);
    control.trace = .digest;
    control.reset(0);
    // Without a reclamation, nothing is late; one that examined 8,000 pays off at 1,000 more
    // members, 1,000 more cells or 8,000 more bytes (and the room left is far larger).
    const built: types.ControlStorage.Usage = .{ .members = 3 };
    try std.testing.expect(!control.reclaimReturn(built, .{}, 1, true, 0, 5, 0));
    control.reclaimed(.{ .members = 20 }, .{}, 8000, 4, 7);
    // No switch since the frame's push: the depth-1 rule alone decides (it built an eighth of
    // what a reclamation would examine, which is everything it built here).
    try std.testing.expect(control.reclaimReturn(built, .{}, 1, true, 7, 7, 0));
    // A switch since the push and since the reclamation: the end waits to be paid for.
    try std.testing.expect(!control.reclaimReturn(built, .{}, 1, true, 6, 8, 0));
    try std.testing.expect(control.reclaimReturn(.{ .members = 1000 }, .{}, 1, true, 6, 8, 0));
    // A switch since the push but none since the reclamation (the task reclaimed in its own
    // loop after it resumed): the end is not held back by the switch that resumed it.
    try std.testing.expect(control.reclaimReturn(built, .{}, 1, true, 6, 7, 0));
    // A reset forgets it.
    control.reset(0);
    try std.testing.expectEqual(@as(u64, 0), control.reclaim_switches);
}

test "both machines and the replay reclaim alike and compute what an unreclaimed run computes" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    var reclaiming: usize = 0;
    var freed: types.ControlStorage.Usage = .{};
    for (programs ++ stores ++ replay.programs) |source| {
        const p = try compileAll(f, source);
        // The same run with its witness stored: reclamation must not change what it reports.
        f.configure(.full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.inner.h.run(p, fuel)).ok;
        try std.testing.expectEqual(@as(u64, 0), stored.reclaims);
        var out = std.Io.Writer.fixed(plain);
        _ = try reporting.write(&out, stored, false, .{});
        try trace_report.write(&out, stored, "test.forb", .{});
        const expected = try Stored.of(stored, out.buffered());
        defer expected.destroy();
        const steps = stored.callWitness().?.count;
        const members = stored.aggregate_values.len;
        const bytes = stored.program.strings.len;
        f.configure(.digest, 64, never);
        const unreclaimed = try f.both(p, fuel);
        try std.testing.expectEqual(@as(u64, 0), unreclaimed.actual.reclaims);
        try std.testing.expectEqual(members, unreclaimed.actual.aggregate_values.len);
        try std.testing.expectEqual(bytes, unreclaimed.actual.program.strings.len);
        try std.testing.expectEqual(expected.instance_cells, unreclaimed.actual.object_cells.len);
        try std.testing.expectEqualStrings(expected.report, try f.report(unreclaimed.actual, p, fuel, other));
        var reclaimed = false;
        for ([_]u32{ 0, 1, 5, 40 }) |floor| for ([_]u32{ 1, 3, 64 }) |window| {
            f.configure(.digest, window, floor);
            const runs = f.both(p, fuel) catch |problem| {
                std.debug.print("floor {d} window {d}:\n{s}\n", .{ floor, window, source });
                return problem;
            };
            try std.testing.expectEqual(steps, runs.actual.witness.count);
            try std.testing.expect(runs.actual.aggregate_values.len <= members and runs.actual.program.strings.len <= bytes and runs.actual.object_cells.len <= expected.instance_cells);
            if (runs.actual.reclaims != 0) reclaimed = true;
            if (floor == 0 and window == 1) {
                freed.members += f.inner.h.control.reclaimed_members;
                freed.strings += f.inner.h.control.reclaimed_bytes;
                freed.cells += f.inner.h.control.reclaimed_cells;
            }
            // Each machine's run is admitted by a replay that works the layout out again.
            const reported = f.report(runs.actual, p, fuel, other) catch |problem| {
                std.debug.print("floor {d} window {d}:\n{s}\n", .{ floor, window, source });
                return problem;
            };
            expected.expect(reported, runs.actual) catch |problem| {
                std.debug.print("floor {d} window {d}:\n{s}\n", .{ floor, window, source });
                return problem;
            };
            try expected.expect(try f.report(runs.reference, p, fuel, other), runs.reference);
        };
        // Without a witness there is nothing to replay, and the machines still agree.
        f.configure(.off, 5, 0);
        const silent = try f.both(p, fuel);
        try std.testing.expect(silent.actual.aggregate_values.len <= members);
        const graph = try graphOf(silent.actual);
        defer std.testing.allocator.free(graph);
        try std.testing.expectEqualStrings(expected.graph, graph);
        if (reclaimed) reclaiming += 1;
    }
    // Every program written for this file leaves something to reclaim, in each of the stores.
    try std.testing.expect(reclaiming >= programs.len + stores.len);
    try std.testing.expect(freed.members > 1000 and freed.strings > 1000 and freed.cells > 500);
}

test "a loop that builds more members than the pool holds completes, and one that keeps them does not" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    const text = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(text);
    const budget = 1 << 20;
    // Two members a visit: 12,000 in all, in a pool of 8,192.
    const p = try compileAll(f, "var Count:i64=0\nStep(S:i64)<transacts>:i64=Block{set Count=Count+1;T:=tuple{S,S+1};T(1)}\nTotal<public>:i64=Iterate(Step,6000,0)\nSeen<public>:i64=Count");
    // Without reclamation the pool is the ceiling, in both machines at the same place.
    f.configure(.digest, types.ControlStorage.default_trace_window, never);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, (try f.outcome(p, budget)).?.code);
    for ([_]types.TraceMode{ .digest, .off }) |trace| {
        f.configure(trace, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
        const runs = try f.both(p, budget);
        try std.testing.expectEqual(@as(i64, 6000), runs.actual.get("Total").?.integer);
        try std.testing.expectEqual(@as(i64, 6000), runs.actual.get("Seen").?.integer);
        // Nothing survives a visit, so every reclamation empties the pool: 12,000 members in
        // portions of the floor, and once more for the rest as the call returns.
        try std.testing.expectEqual(@as(u64, 12000 / types.ControlStorage.default_reclaim_floor + 1), runs.actual.reclaims);
        try std.testing.expectEqual(@as(usize, 0), runs.actual.aggregate_values.len);
        if (trace == .digest) try std.testing.expectEqualStrings("{\"Count\":6000,\"Total\":6000,\"Seen\":6000}\n", try f.values(runs.actual, p, budget, text));
    }
    // An array that really grows, a cell that keeps what each visit built, and instances that
    // each hold a tuple and are all kept by a cell are still in use: they stop at the pool,
    // alike in both machines.
    const wide = "P:=class{var T:tuple(i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64,i64)}\n";
    for ([_][]const u8{
        "Grow(S:[]i64)<computes>:[]i64=S+array{S.Length}\nAll<public>:i64=Iterate(Grow,9000,array{}).Length",
        "Grow(S:[]i64)<computes>:[]i64=Block{T:=tuple{S.Length,1};S+array{T(0)}}\nAll<public>:i64=Iterate(Grow,9000,array{}).Length",
        "var Log:[]i64=array{}\nStep(S:i64)<transacts>:i64=Block{T:=tuple{S,S};set Log=Log+array{T(0)};S+1}\nTotal<public>:i64=Iterate(Step,9000,0)",
        wide ++ "var Keep:[]P=array{}\nStep(S:i64)<transacts>:i64=Block{X:=P{T:=tuple{S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S}};set Keep=Keep+array{X};S+1}\nTotal<public>:i64=Iterate(Step,2000,0)",
    }) |source| {
        const growing = try compileAll(f, source);
        f.configure(.digest, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
        // An append behind garbage copies the array, so these cost the square of their length.
        const ample = 1 << 25;
        const failed = (try f.outcome(growing, ample)).?;
        try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, failed.code);
        // Reclaiming at every chance finds the same members in use and stops at the same place,
        // except for the last program: its `Keep` is copied with a room as long as itself
        // (RFC-0055, "Rooms"), one allocation of more than half of what the pool has left, so
        // which allocation finds the pool full depends on how much garbage the last
        // reclamation left. Both stop with `aggregate_limit`.
        f.configure(.digest, types.ControlStorage.default_trace_window, 0);
        const eager = (try f.outcome(growing, ample)).?;
        if (std.mem.startsWith(u8, source, wide)) try std.testing.expectEqual(failed.code, eager.code) else try std.testing.expectEqualDeep(failed, eager);
    }
    // The same instances with nothing to keep them: what each holds goes with it, so 48,000
    // members and 4,000 cells pass through a pool of 8,192 members and 1,024 cells.
    const dropped = try compileAll(f, wide ++ "Step(S:i64)<transacts>:i64=Block{X:=P{T:=tuple{S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S,S}};S+X.T(0)-S+1}\nTotal<public>:i64=Iterate(Step,2000,0)");
    f.configure(.digest, types.ControlStorage.default_trace_window, never);
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, (try f.outcome(dropped, budget)).?.code);
    for ([_]types.TraceMode{ .digest, .off }) |trace| {
        f.configure(trace, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
        const runs = try f.both(dropped, budget);
        try std.testing.expectEqual(@as(i64, 2000), runs.actual.get("Total").?.integer);
        try std.testing.expect(runs.actual.reclaims > 10 and runs.actual.object_cells.len < 256 and runs.actual.aggregate_values.len < 2048);
        if (trace == .digest) try std.testing.expect(std.mem.startsWith(u8, try f.values(runs.actual, dropped, budget, text), "{\"Total\":2000"));
    }
}

test "reclamation is not charged: the exact fuel a run needs is the same with and without it" {
    const f = try Fixture.create();
    defer f.destroy();
    for (programs[0..6] ++ stores[0..3] ++ stores[8..11] ++ stores[13..18]) |source| {
        const p = try compileAll(f, source);
        var needed: [2]u64 = undefined;
        var refused: [2]types.Diagnostic = undefined;
        for ([_]u32{ never, 0 }, &needed, &refused) |floor, *exact, *last| {
            f.configure(.digest, 7, floor);
            var low: u64 = 0;
            var high: u64 = fuel;
            // The least budget that completes; one unit less stops both machines alike.
            while (low < high) {
                const middle = low + (high - low) / 2;
                if ((try f.outcome(p, middle)) == null) high = middle else low = middle + 1;
            }
            exact.* = low;
            last.* = (try f.outcome(p, low - 1)).?;
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, last.code);
            _ = try f.both(p, low);
        }
        try std.testing.expectEqual(needed[0], needed[1]);
        try std.testing.expectEqualDeep(refused[0], refused[1]);
    }
}

/// A second run whose pool, as the replay sees it in one window, differs in one member.
const Corrupter = struct {
    inner: types.TraceProducer,
    sink: types.TraceSink = undefined,
    copy: []types.Value,
    /// Which window to change, which member of it, and whether to change its type.
    window: usize,
    member: usize,
    retype: bool,
    seen: usize = 0,
    changed: bool = false,
    fn run(context: *anyopaque, sink: types.TraceSink) bool {
        const self: *Corrupter = @ptrCast(@alignCast(context));
        self.sink = sink;
        return self.inner.run(self.inner.context, .{ .context = self, .write = write });
    }
    fn write(context: *anyopaque, steps: []const types.CallStep, members: []const types.Value, strings: usize) void {
        const self: *Corrupter = @ptrCast(@alignCast(context));
        defer self.seen += 1;
        if (self.seen != self.window or members.len == 0) return self.sink.write(self.sink.context, steps, members, strings);
        const copy = self.copy[0..members.len];
        @memcpy(copy, members);
        const slot = &copy[self.member % members.len];
        slot.* = if (self.retype) (if (slot.* == .boolean) .{ .integer = 1 } else .{ .boolean = true }) else switch (slot.*) {
            .integer => |value| .{ .integer = value +% 1 },
            .aggregate => |value| .{ .aggregate = .{ .value_type = value.value_type, .elements = .{ .start = value.elements.start, .end = value.elements.end + 1 } } },
            else => .{ .integer = 7 },
        };
        self.changed = true;
        self.sink.write(self.sink.context, steps, copy, strings);
    }
};

test "a replay of a run that reclaimed rejects forged results, members, cells, counts and second runs" {
    const f = try Fixture.create();
    defer f.destroy();
    const text = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(text);
    const honest_text = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(honest_text);
    const copy = try std.testing.allocator.alloc(types.Value, types.limits.aggregate_elements);
    defer std.testing.allocator.free(copy);
    var random = std.Random.DefaultPrng.init(0x7265636c61696d);
    const rng = random.random();
    for (programs ++ stores) |source| {
        const p = try compileAll(f, source);
        f.configure(.digest, 3, 0);
        const x = (try f.both(p, fuel)).actual;
        try std.testing.expect(x.reclaims != 0);
        const freed: types.ControlStorage.Usage = .{ .members = f.inner.h.runtime.machine.control.reclaimed_members, .strings = f.inner.h.runtime.machine.control.reclaimed_bytes, .cells = f.inner.h.runtime.machine.control.reclaimed_cells };
        const honest = try f.report(x, p, fuel, honest_text);
        const again = f.inner.again;
        var forged = x;
        forged.witness.digest ^= 1;
        try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        // The run reclaimed as often as the replay finds it must have, on the floor it names.
        for ([_]u64{ 0, x.reclaims - 1, x.reclaims + 1 }) |claimed| {
            forged = x;
            forged.reclaims = claimed;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        }
        for ([_]u32{ never, 1 << 20 }) |floor| {
            forged = x;
            forged.reclaim_floor = floor;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        }
        // A stored witness cannot belong to a run that reclaimed.
        forged = x;
        forged.trace = .full;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
        // Every result of a traced root call is the value the replay moved by its own rule.
        const values = try std.testing.allocator.dupe(types.Value, x.values);
        defer std.testing.allocator.free(values);
        for (p.nodes, 0..) |node, index| {
            if (!node.isInvocation() or !x.active(index)) continue;
            const kept = values[index];
            values[index] = switch (kept) {
                .integer => |value| .{ .integer = value +% 1 },
                .aggregate => |value| if (value.elements.start == 0) continue else .{ .aggregate = .{ .value_type = value.value_type, .elements = .{ .start = value.elements.start - 1, .end = value.elements.end - 1 } } },
                .callable => |value| if (value.captures.start == 0) continue else .{ .callable = .{ .value_type = value.value_type, .function = value.function, .captures = .{ .start = value.captures.start - 1, .end = value.captures.end - 1 } } },
                else => continue,
            };
            forged = x;
            forged.values = values;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
            values[index] = kept;
        }
        // Every member the run still holds is the member the second run holds there.
        const members = try std.testing.allocator.dupe(types.Value, x.aggregate_values);
        defer std.testing.allocator.free(members);
        for (members, 0..) |*member, index| {
            member.* = switch (member.*) {
                .integer => |value| .{ .integer = value +% 1 },
                .boolean => |value| .{ .boolean = !value },
                else => continue,
            };
            forged = x;
            forged.aggregate_values = members;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
            member.* = x.aggregate_values[index];
        }
        forged = x;
        forged.aggregate_values = x.aggregate_values[0 .. x.aggregate_values.len - @intFromBool(x.aggregate_values.len != 0)];
        if (x.aggregate_values.len != 0) try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        // Every instance cell is the cell the replay built and moved.
        const cells = try std.testing.allocator.dupe(source_state.Cell, x.object_cells);
        defer std.testing.allocator.free(cells);
        for (cells, 0..) |*cell, index| {
            cell.value = switch (cell.value) {
                .integer => |value| .{ .integer = value +% 1 },
                .aggregate => |value| if (value.elements.start == 0) continue else .{ .aggregate = .{ .value_type = value.value_type, .elements = .{ .start = value.elements.start - 1, .end = value.elements.end - 1 } } },
                else => continue,
            };
            forged = x;
            forged.object_cells = cells;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
            cell.* = x.object_cells[index];
        }
        // A second run that shows the replay a pool other than its own is either caught or
        // changed a member nothing looks at again; it never changes what is printed.
        for (0..24) |_| {
            var corrupter: Corrupter = .{ .inner = again.producer(p, fuel), .copy = copy, .window = rng.intRangeLessThan(usize, 0, 40), .member = rng.int(u32), .retype = rng.boolean() };
            var out = std.Io.Writer.fixed(text);
            if (reporting.writeReplayed(&out, x, .{ .context = &corrupter, .run = Corrupter.run }, false, .{})) |_| {
                try trace_report.writeReplayed(&out, x, again.producer(p, fuel), "test.forb", .{});
                try std.testing.expectEqualStrings(honest, out.buffered());
            } else |problem| {
                try std.testing.expect(corrupter.changed);
                try std.testing.expectEqual(error.InvalidExecution, problem);
                try std.testing.expectEqual(@as(usize, 0), out.end);
            }
        }
        // The honest run is still admitted after all of that.
        try std.testing.expectEqualStrings(honest, try f.report(x, p, fuel, text));
        // A second run that never reclaims has another layout and validates nothing, unless
        // the first run's reclamations found nothing to free and so moved nothing either. It
        // comes last: it leaves the string pool, which the runs share, as the reported run
        // did not, and nothing can be said about that run afterwards.
        again.control.reclaim_floor = never;
        if (freed.members + freed.strings + freed.cells != 0) try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(x, again.producer(p, fuel), false, .{})) else _ = try reporting.validateReplayed(x, again.producer(p, fuel), false, .{});
        again.control.reclaim_floor = 0;
    }
}

/// A second run that, in one window, shows the replay a member of the wrong type in the newest
/// aggregate that window's steps name.
const Retyper = struct {
    inner: types.TraceProducer,
    sink: types.TraceSink = undefined,
    copy: []types.Value,
    window: usize,
    seen: usize = 0,
    changed: bool = false,
    fn run(context: *anyopaque, sink: types.TraceSink) bool {
        const self: *Retyper = @ptrCast(@alignCast(context));
        self.sink = sink;
        return self.inner.run(self.inner.context, .{ .context = self, .write = write });
    }
    fn write(context: *anyopaque, steps: []const types.CallStep, members: []const types.Value, strings: usize) void {
        const self: *Retyper = @ptrCast(@alignCast(context));
        var newest: ?types.Span = null;
        for (steps) |step| if (step.value == .aggregate and step.value.aggregate.elements.end - step.value.aggregate.elements.start >= 2) {
            newest = step.value.aggregate.elements;
        };
        // Only the windows that name such an aggregate count.
        const span = newest orelse return self.sink.write(self.sink.context, steps, members, strings);
        defer self.seen += 1;
        if (self.seen != self.window) return self.sink.write(self.sink.context, steps, members, strings);
        const copy = self.copy[0..members.len];
        @memcpy(copy, members);
        copy[span.start + 1] = .{ .boolean = true };
        self.changed = true;
        self.sink.write(self.sink.context, steps, copy, strings);
    }
};

test "what a replay learnt about a position does not outlive the member that was there" {
    const f = try Fixture.create();
    defer f.destroy();
    const copy = try std.testing.allocator.alloc(types.Value, types.limits.aggregate_elements);
    defer std.testing.allocator.free(copy);
    // Every visit sorts an array into the same positions, which are reclaimed in between. The
    // sorted array is a native's result: only the check of its members' types looks at it, and
    // nothing reads the second member afterwards.
    const p = try compileAll(f, native_garbage);
    f.configure(.digest, 64, 0);
    const x = (try f.both(p, fuel)).actual;
    try std.testing.expect(x.reclaims >= 20);
    _ = try reporting.validateReplayed(x, f.inner.again.producer(p, fuel), false, .{});
    for (0..x.reclaims) |window| {
        var retyper: Retyper = .{ .inner = f.inner.again.producer(p, fuel), .copy = copy, .window = window };
        const outcome = reporting.validateReplayed(x, .{ .context = &retyper, .run = Retyper.run }, false, .{});
        try std.testing.expect(retyper.changed);
        try std.testing.expectError(error.InvalidExecution, outcome);
    }
}

/// A random loop program: a step function over one of three state types whose body is a run
/// of statements that build, keep, share, capture, store and roll back aggregates.
const Generator = struct {
    rng: std.Random,
    text: std.ArrayList(u8) = .empty,
    names: u32 = 0,

    const prelude =
        \\var Cell:tuple(i64,i64)=tuple{0,0}
        \\var Log:[]i64=array{}
        \\var N:i64=0
        \\Box:=class{var T:tuple(i64,i64)}
        \\Mk(A:i64,B:i64)<computes>:tuple(i64,i64)=tuple{A,B}
        \\Sum(P:tuple(i64,i64))<computes>:i64=P(0)+P(1)
        \\Add(K:tuple(i64,i64),X:i64)<computes>:i64=K(0)+X
        \\Inner(S:tuple(i64,i64))<computes>:tuple(i64,i64)=tuple{S(1),S(0)+1}
        \\Deep(D:i64,V:i64)<computes>:tuple(i64,i64)=If(D==0,tuple{V,0},Block{P:=Deep(D-1,V);tuple{P(1)+1,P(0)}})
        \\Risky(S:i64,Limit:i64)<transacts><decides>:tuple(i64,i64)=Block{set N=N+1;set Cell=tuple{S,N};Require[S<Limit];tuple{S,N}}
        \\
    ;

    fn add(self: *Generator, comptime format: []const u8, arguments: anytype) !void {
        try self.text.print(std.testing.allocator, format, arguments);
    }
    fn small(self: *Generator) i64 {
        return self.rng.intRangeLessThan(i64, 0, 9);
    }
    fn statement(self: *Generator) !void {
        const name = self.names;
        self.names += 1;
        const c = self.small();
        switch (self.rng.intRangeLessThan(u8, 0, 13)) {
            0 => try self.add("T{d}:=tuple{{V,V+{d}}};", .{ name, c }),
            1 => try self.add("A{d}:=array{{V,{d}}}+array{{V}};", .{ name, c }),
            2 => try self.add("set Cell=tuple{{V,{d}}};", .{c}),
            3 => try self.add("set Log=Log+array{{V}};", .{}),
            4 => try self.add("set Shared.T=Mk(V,{d});", .{c}),
            5 => try self.add("B{d}:=Box{{T:=tuple{{V,{d}}}}};set B{d}.T=Mk(B{d}.T(1),V);", .{ name, c, name, name }),
            6 => try self.add("F{d}:=Bind(Add,tuple{{V,{d}}});G{d}:=F{d}({d});", .{ name, c, name, name, c }),
            7 => try self.add("I{d}:=Iterate(Inner,{d},tuple{{V,{d}}});", .{ name, self.rng.intRangeLessThan(u8, 0, 4), c }),
            8 => try self.add("P{d}:=Attempt(Risky[V,{d}],tuple{{V,-1}});", .{ name, self.rng.intRangeLessThan(u8, 0, 30) }),
            9 => try self.add("set N=N+1;", .{}),
            10 => try self.add("M{d}:=Sum(Mk(V,{d}));", .{ name, c }),
            11 => try self.add("D{d}:=Deep({d},V);", .{ name, self.rng.intRangeLessThan(u8, 0, 5) }),
            else => try self.add("set Cell=Attempt(Block{{set Log=Log+array{{V}};Risky[V,{d}]}},Cell);", .{self.rng.intRangeLessThan(u8, 0, 30)}),
        }
    }
    fn program(self: *Generator) ![]const u8 {
        self.text.clearRetainingCapacity();
        self.names = 0;
        try self.text.appendSlice(std.testing.allocator, prelude);
        const visits = self.rng.intRangeLessThan(u8, 1, 24);
        const shape = self.rng.intRangeLessThan(u8, 0, 3);
        const header = switch (shape) {
            0 => "Step(Shared:Box,S:i64)<transacts>:i64=Block{V:=S;",
            1 => "Step(Shared:Box,S:tuple(i64,i64))<transacts>:tuple(i64,i64)=Block{V:=S(0);",
            else => "Step(Shared:Box,S:[]i64)<transacts>:[]i64=Block{V:=S.Length;",
        };
        try self.text.appendSlice(std.testing.allocator, header);
        for (0..self.rng.intRangeLessThan(u8, 0, 7)) |_| try self.statement();
        try self.text.appendSlice(std.testing.allocator, switch (shape) {
            0 => "V+1}\n",
            1 => "tuple{V+1,Cell(1)+Shared.T(0)}}\n",
            else => if (self.rng.boolean()) "S+array{V}}\n" else "If(V<4,S+array{N},array{V})}\n",
        });
        const initial = switch (shape) {
            0 => "0",
            1 => "tuple{0,0}",
            else => "array{}",
        };
        const kind = switch (shape) {
            0 => "i64",
            1 => "tuple(i64,i64)",
            else => "[]i64",
        };
        try self.add("Keep:=Box{{T:=tuple{{1,2}}}}\nRun(B:Box,Count:i64)<transacts>:{s}=Iterate(Fn(S:{s}){{Step(B,S)}},Count,{s})\n", .{ kind, kind, initial });
        // Sometimes the whole loop is undone, with everything it stored.
        if (self.rng.intRangeLessThan(u8, 0, 4) == 0) {
            try self.add("Undone(B:Box)<transacts><decides>:{s}=Block{{X:=Run(B,{d});Fail[\"undo\"];X}}\nGone<public>:{s}=Attempt(Undone[Keep],{s})\n", .{ kind, visits, kind, initial });
        }
        try self.add("R<public>:{s}=Run(Keep,{d})\nAgain<public>:{s}=Run(Keep,{d})\nC<public>:tuple(i64,i64)=Cell\nL<public>:[]i64=Log\nQ<public>:i64=N\nK<public>:tuple(i64,i64)=Keep.T\n", .{ kind, visits, kind, self.rng.intRangeLessThan(u8, 0, 6) });
        return self.text.items;
    }
};

test "five hundred random loop programs report the same with reclamation at every chance and with none" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    var random = std.Random.DefaultPrng.init(0x6d656d62657273);
    var generator: Generator = .{ .rng = random.random() };
    defer generator.text.deinit(std.testing.allocator);
    var reclaims: u64 = 0;
    var freed: u64 = 0;
    for (0..500) |_| {
        const source = try generator.program();
        const p = try compileAll(f, source);
        f.configure(.full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.inner.h.run(p, fuel)).ok;
        var out = std.Io.Writer.fixed(plain);
        _ = try reporting.write(&out, stored, false, .{});
        try trace_report.write(&out, stored, "test.forb", .{});
        const expected = try Stored.of(stored, out.buffered());
        defer expected.destroy();
        const steps = stored.callWitness().?.count;
        const failures = stored.failure_count;
        const floor: u32 = if (generator.rng.boolean()) 0 else generator.rng.intRangeLessThan(u32, 0, 64);
        f.configure(.digest, generator.rng.intRangeLessThan(u32, 1, 40), floor);
        const runs = f.both(p, fuel) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        try std.testing.expectEqual(steps, runs.actual.witness.count);
        try std.testing.expectEqual(failures, runs.actual.failure_count);
        const reported = f.report(runs.actual, p, fuel, other) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        expected.expect(reported, runs.actual) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        try expected.expect(try f.report(runs.reference, p, fuel, other), runs.reference);
        reclaims += runs.actual.reclaims;
        freed += f.inner.h.control.reclaimed_members;
    }
    // The generator is only worth running if it keeps the collector busy.
    try std.testing.expect(reclaims > 2000 and freed > 10000);
}

/// Whether two values are the same value held the same way: the same span, instance or
/// string address, not merely equal contents.
fn identical(a: types.Value, b: types.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |text| text.ptr == b.string.ptr and text.len == b.string.len,
        .floating => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.floating)),
        else => std.meta.eql(a, b),
    };
}

/// A second run that, in one window, says its string pool ends somewhere else.
const Misteller = struct {
    inner: types.TraceProducer,
    sink: types.TraceSink = undefined,
    window: usize,
    longer: bool,
    seen: usize = 0,
    changed: bool = false,
    fn run(context: *anyopaque, sink: types.TraceSink) bool {
        const self: *Misteller = @ptrCast(@alignCast(context));
        self.sink = sink;
        return self.inner.run(self.inner.context, .{ .context = self, .write = write });
    }
    fn write(context: *anyopaque, steps: []const types.CallStep, members: []const types.Value, strings: usize) void {
        const self: *Misteller = @ptrCast(@alignCast(context));
        defer self.seen += 1;
        if (self.seen != self.window or (!self.longer and strings == 0)) return self.sink.write(self.sink.context, steps, members, strings);
        self.changed = true;
        self.sink.write(self.sink.context, steps, members, if (self.longer) strings + 1 else strings - 1);
    }
};

test "a replay rejects a final state that names an instance or a string the rule reclaimed" {
    const f = try Fixture.create();
    defer f.destroy();
    const allocator = std.testing.allocator;
    const text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(text);
    const honest_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(honest_text);
    var random = std.Random.DefaultPrng.init(0x6c6976656e657373);
    const rng = random.random();
    var forged_instances: usize = 0;
    var forged_strings: usize = 0;
    var stale_states: usize = 0;
    for (stores) |source| {
        const p = try compileAll(f, source);
        // What the run leaves when it reclaims nothing: every instance it created and every
        // string where it was built. Presented as the state of the run that reclaimed, each
        // part of it names what that run no longer holds.
        f.configure(.digest, 3, never);
        const kept = (try f.both(p, fuel)).actual;
        const stale_values = try allocator.dupe(types.Value, kept.values);
        defer allocator.free(stale_values);
        const stale_cells = try allocator.dupe(source_state.Cell, kept.object_cells);
        defer allocator.free(stale_cells);
        const stale_members = try allocator.dupe(types.Value, kept.aggregate_values);
        defer allocator.free(stale_members);
        const stale_strings = kept.program.strings.len;
        f.configure(.digest, 3, 0);
        const x = (try f.both(p, fuel)).actual;
        try std.testing.expect(x.reclaims != 0);
        const again = f.inner.again;
        const honest = try f.report(x, p, fuel, honest_text);
        var forged = x;
        var differs = false;
        for (stale_values, x.values, 0..) |stale, value, index| {
            if (x.active(index) and !identical(stale, value)) differs = true;
        }
        if (differs) {
            forged.values = stale_values;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
            stale_states += 1;
        }
        if (stale_cells.len != x.object_cells.len) {
            forged = x;
            forged.object_cells = stale_cells;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
            // The instances the run freed, listed as if it still held them, with its own values.
            forged.values = stale_values;
            forged.aggregate_values = stale_members;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
            stale_states += 1;
        }
        if (stale_strings != x.program.strings.len) {
            forged = x;
            forged.program.strings = x.program.strings.ptr[0..stale_strings];
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        }
        if (x.program.strings.len != 0) {
            forged = x;
            forged.program.strings = x.program.strings[0 .. x.program.strings.len - 1];
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
        }
        // One reference at a time: every instance id and string address a traced call
        // returned, and every one a cell of an instance holds, is the one the replay worked out.
        const values = try allocator.dupe(types.Value, x.values);
        defer allocator.free(values);
        for (p.nodes, 0..) |node, index| {
            if (!node.isInvocation() or !x.active(index)) continue;
            const original = values[index];
            const changes: []const types.Value = switch (original) {
                .object => |object| &.{
                    .{ .object = .{ .value_type = object.value_type, .id = object.id + 1 } },
                    .{ .object = .{ .value_type = object.value_type, .id = object.id -| 2 } },
                    .{ .object = .{ .value_type = object.value_type, .id = @intCast(p.source_cells.len + stale_cells.len) } },
                },
                .string => |string| if (string.len == 0) continue else &.{
                    .{ .string = string[1..] },
                    .{ .string = string[0 .. string.len - 1] },
                    .{ .string = (string.ptr + 1)[0..string.len] },
                },
                else => continue,
            };
            for (changes) |change| {
                if (identical(change, original)) continue;
                values[index] = change;
                forged = x;
                forged.values = values;
                try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
                if (original == .object) forged_instances += 1 else forged_strings += 1;
            }
            values[index] = original;
        }
        const cells = try allocator.dupe(source_state.Cell, x.object_cells);
        defer allocator.free(cells);
        for (cells, 0..) |*cell, index| {
            const original = cell.value;
            cell.value = switch (original) {
                .object => |object| .{ .object = .{ .value_type = object.value_type, .id = if (rng.boolean()) object.id + 1 else object.id -| 1 } },
                .string => |string| if (string.len == 0) continue else .{ .string = if (rng.boolean()) string[1..] else (string.ptr + 1)[0..string.len] },
                else => continue,
            };
            if (identical(cell.value, original)) {
                cell.value = original;
                continue;
            }
            forged = x;
            forged.object_cells = cells;
            try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
            if (original == .object) forged_instances += 1 else forged_strings += 1;
            cell.* = x.object_cells[index];
        }
        // So is every one a member holds: the members printed are the second run's.
        const members = try allocator.dupe(types.Value, x.aggregate_values);
        defer allocator.free(members);
        for (members, 0..) |*member, index| {
            const original = member.*;
            member.* = switch (original) {
                .object => |object| .{ .object = .{ .value_type = object.value_type, .id = if (rng.boolean()) object.id + 1 else object.id -| 1 } },
                .string => |string| if (string.len == 0) continue else .{ .string = if (rng.boolean()) string[1..] else (string.ptr + 1)[0..string.len] },
                else => continue,
            };
            if (!identical(member.*, original)) {
                forged = x;
                forged.aggregate_values = members;
                try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
                if (original == .object) forged_instances += 1 else forged_strings += 1;
            }
            member.* = x.aggregate_values[index];
        }
        // An instance more or fewer than the run holds, whichever end it is taken from.
        if (cells.len != 0) {
            const count = @import("aggregate_types.zig").classCells(@fromBackingInt(@intCast(cells[0].value.integer)), p.definitions).?;
            for ([_][]const source_state.Cell{ cells[count..], cells[0 .. cells.len - 1], stale_cells[0..@min(stale_cells.len, cells.len + count)] }) |listed| {
                if (listed.len == cells.len) continue;
                forged = x;
                forged.object_cells = listed;
                try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
            }
        }
        // The reason of a failure is a string like any other.
        if (x.failures.len != 0) {
            const traces = try allocator.dupe(types.FailureTrace, x.failures);
            defer allocator.free(traces);
            for (traces, 0..) |*trace, index| {
                const reason = trace.reason orelse continue;
                if (reason.len == 0) continue;
                for ([_][]const u8{ reason[1..], reason[0 .. reason.len - 1], (reason.ptr + 1)[0..reason.len] }) |change| {
                    trace.reason = change;
                    forged = x;
                    forged.failures = traces;
                    try std.testing.expectError(error.InvalidExecution, reporting.validateReplayed(forged, again.producer(p, fuel), false, .{}));
                    forged_strings += 1;
                }
                trace.* = x.failures[index];
            }
        }
        // A second run that says its string pool ends elsewhere is caught, or changed nothing
        // the replay goes by; it never changes what is printed.
        for (0..16) |_| {
            var misteller: Misteller = .{ .inner = again.producer(p, fuel), .window = rng.intRangeLessThan(usize, 0, 60), .longer = rng.boolean() };
            var out = std.Io.Writer.fixed(text);
            if (reporting.writeReplayed(&out, x, .{ .context = &misteller, .run = Misteller.run }, false, .{})) |_| {
                try trace_report.writeReplayed(&out, x, again.producer(p, fuel), "test.forb", .{});
                try std.testing.expectEqualStrings(honest, out.buffered());
            } else |problem| {
                try std.testing.expect(misteller.changed);
                try std.testing.expectEqual(error.InvalidExecution, problem);
                try std.testing.expectEqual(@as(usize, 0), out.end);
            }
        }
        try std.testing.expectEqualStrings(honest, try f.report(x, p, fuel, text));
    }
    // The programs gave the forgeries something to bite on.
    try std.testing.expect(forged_instances >= 12 and forged_strings >= 60 and stale_states >= 20);
}

test "strings and instances that are dropped pass through pools they would fill, and kept ones stop at the limit" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    const text = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(text);
    const budget = 1 << 22;
    const Case = struct { source: []const u8, limit: types.Diagnostic.Code, total: i64 };
    // 9,000 strings of 20 bytes and more in a pool of 65,536 bytes; 2,000 instances of three
    // cells in 1,024 cells; and both at once, each instance holding its string.
    for ([_]Case{
        .{ .source = "Step(S:i64)<computes>:i64=Block{T:=\"n{S}0123456789abcdef\";S+T.Length-T.Length+1}\nTotal<public>:i64=Iterate(Step,9000,0)", .limit = .string_limit, .total = 9000 },
        .{ .source = "P:=class{var N:i64,var M:i64}\nStep(S:i64)<transacts>:i64=Block{X:=P{N:=S,M:=1};set X.N=X.N+X.M;X.N}\nTotal<public>:i64=Iterate(Step,2000,0)", .limit = .object_limit, .total = 2000 },
        .{ .source = "P:=class{var T:string}\nvar Last:option(P)=option{}\nStep(S:i64)<transacts>:i64=Block{X:=P{T:=\"name{S}0123456789abcdef0123456789abcdef\"};set Last=option{X};S+X.T.Length-X.T.Length+1}\nTotal<public>:i64=Iterate(Step,3000,0)", .limit = .object_limit, .total = 3000 },
    }) |case| {
        const p = try compileAll(f, case.source);
        f.configure(.digest, types.ControlStorage.default_trace_window, never);
        try std.testing.expectEqual(case.limit, (try f.outcome(p, budget)).?.code);
        for ([_]types.TraceMode{ .digest, .off }) |trace| {
            f.configure(trace, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
            const runs = try f.both(p, budget);
            try std.testing.expectEqual(case.total, runs.actual.get("Total").?.integer);
            try std.testing.expect(runs.actual.reclaims > 2);
            try std.testing.expect(runs.actual.program.strings.len < types.limits.string_bytes / 2 and runs.actual.object_cells.len < types.limits.object_cells / 2);
            if (trace == .digest) try std.testing.expect(std.mem.startsWith(u8, try f.values(runs.actual, p, budget, text), "{"));
        }
    }
    // What a run really keeps is still in use: a string that grows, strings a cell collects,
    // a list that grows and instances a cell collects stop at their limits, at the same node in
    // both machines, however eagerly the run reclaims.
    for ([_]Case{
        .{ .source = "Grow(S:string)<computes>:string=S+\"0123456789abcdef\"\nAll<public>:i64=Iterate(Grow,9000,\"\").Length", .limit = .string_limit, .total = 0 },
        .{ .source = "var Names:map(i64,string)=map{}\nStep(S:i64)<transacts>:i64=Block{D:=\"dead{S}\";set Names[S]=\"name{S}0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\";S+1}\nTotal<public>:i64=Iterate(Step,200,0)", .limit = .string_limit, .total = 0 },
        .{ .source = "Node:=class{Value:i64,var Next:option(Node)}\nPush(S:option(Node))<transacts>:option(Node)=Block{D:=Node{Value:=0,Next:=S};option{Node{Value:=1,Next:=S}}}\nHead<public>:option(Node)=Iterate(Push,2000,option{})", .limit = .object_limit, .total = 0 },
        .{ .source = "P:=class{var N:i64}\nvar Keep:map(i64,P)=map{}\nStep(S:i64)<transacts>:i64=Block{set Keep[S-(S/700)*700]=P{N:=S};S+1}\nTotal<public>:i64=Iterate(Step,4000,0)", .limit = .object_limit, .total = 0 },
    }) |case| {
        const growing = try compileAll(f, case.source);
        f.configure(.digest, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
        const ample = 1 << 26;
        try std.testing.expectEqual(case.limit, (try f.outcome(growing, ample)).?.code);
        // Which allocation finds the pool full depends on how much garbage lies in it then,
        // and so on the floor; that it is full of what is in use does not.
        f.configure(.digest, types.ControlStorage.default_trace_window, 0);
        try std.testing.expectEqual(case.limit, (try f.outcome(growing, ample)).?.code);
        f.configure(.off, types.ControlStorage.default_trace_window, 7);
        try std.testing.expectEqual(case.limit, (try f.outcome(growing, ample)).?.code);
    }
}

/// A random program over a small graph of instances: two cells that hold nodes, nodes that
/// name each other through two fields and hold a string, and a step function whose statements
/// create, link, unlink, rename and roll back.
const GraphGenerator = struct {
    rng: std.Random,
    text: std.ArrayList(u8) = .empty,
    names: u32 = 0,

    const prelude =
        \\Node:=class{var Val:i64,var Name:string,var Next:option(Node),var Peer:option(Node)}
        \\var A:option(Node)=option{}
        \\var B:option(Node)=option{}
        \\var Log:string=""
        \\var Count:i64=0
        \\Make(V:i64)<transacts>:Node=Node{Val:=V,Name:="n{V}",Next:=option{},Peer:=option{}}
        \\Risky(N:Node,S:i64,Limit:i64)<transacts><decides>:i64=Block{set N.Val=N.Val+1;set N.Name=N.Name+"!";set Count=Count+1;X:=Make(S);set N.Peer=option{X};Require[S<Limit];N.Val}
        \\Depth(N:option(Node),K:i64)<transacts>:i64=If(K==0,0,Attempt(Block{X:=N?;1+Depth(X.Next,K-1)},0))
        \\NameOf(N:option(Node))<transacts>:string=Attempt(Block{X:=N?;X.Name},"-")
        \\PeerOf(N:option(Node))<transacts>:string=Attempt(Block{X:=N?;Y:=X.Peer?;Y.Name},"-")
        \\
    ;

    fn add(self: *GraphGenerator, comptime format: []const u8, arguments: anytype) !void {
        try self.text.print(std.testing.allocator, format, arguments);
    }
    fn statement(self: *GraphGenerator) !void {
        const name = self.names;
        self.names += 1;
        const c = self.rng.intRangeLessThan(i64, 0, 9);
        const limit = self.rng.intRangeLessThan(u8, 0, 24);
        switch (self.rng.intRangeLessThan(u8, 0, 17)) {
            0 => try self.add("N{d}:=Make(V+{d});", .{ name, c }),
            1 => try self.add("set A=option{{Make(V)}};", .{}),
            2 => try self.add("set B=A;", .{}),
            3 => try self.add("Attempt(Block{{X:=A?;set X.Next=B;0}},0);", .{}),
            4 => try self.add("Attempt(Block{{X:=A?;set X.Next=option{{Make(V+{d})}};0}},0);", .{c}),
            5 => try self.add("Attempt(Block{{X:=A?;set A=X.Next;0}},0);", .{}),
            6 => try self.add("R{d}:=Attempt(Block{{X:=B?;Risky[X,V,{d}]}},-1);", .{ name, limit }),
            7 => try self.add("set Log=Log+\"{{V}}\";", .{}),
            8 => try self.add("T{d}:=\"s{{V}}\"+\"x\";", .{name}),
            9 => try self.add("Attempt(Block{{X:=A?;set X.Name=\"v{{V}}\";0}},0);", .{}),
            10 => try self.add("Attempt(Block{{X:=A?;Y:=B?;set X.Peer=option{{Y}};set Y.Peer=option{{X}};0}},0);", .{}),
            11 => try self.add("D{d}:=Depth(A,5);", .{name}),
            12 => try self.add("set A=option{{}};", .{}),
            13 => try self.add("Q{d}:=Attempt(Block{{set A=option{{Make(V)}};X:=A?;set X.Next=B;Risky[X,V,{d}]}},-2);", .{ name, limit }),
            14 => try self.add("I{d}:=Iterate(Fn(K:i64){{Block{{set B=option{{Make(K)}};K+1}}}},{d},0);", .{ name, self.rng.intRangeLessThan(u8, 0, 4) }),
            15 => try self.add("Attempt(Block{{X:=B?;Y:=X.Peer?;set B=option{{Y}};0}},0);", .{}),
            else => try self.add("W{d}:=Attempt(Block{{X:=A?;set X.Name=X.Name+\"+\";Attempt(Block{{set X.Val=V;set B=option{{Make(V)}};Require[V<{d}];0}},1);Require[V<{d}];X.Val}},-3);", .{ name, limit, self.rng.intRangeLessThan(u8, 0, 24) }),
        }
    }
    fn program(self: *GraphGenerator) ![]const u8 {
        self.text.clearRetainingCapacity();
        self.names = 0;
        try self.text.appendSlice(std.testing.allocator, prelude);
        const visits = self.rng.intRangeLessThan(u8, 1, 24);
        const carried = self.rng.boolean();
        // The state is a counter, or a counter and a node that only the state names.
        try self.text.appendSlice(std.testing.allocator, if (carried) "Step(S:tuple(i64,option(Node)))<transacts>:tuple(i64,option(Node))=Block{V:=S(0);" else "Step(S:i64)<transacts>:i64=Block{V:=S;");
        for (0..self.rng.intRangeLessThan(u8, 0, 8)) |_| try self.statement();
        try self.text.appendSlice(std.testing.allocator, if (carried) "tuple{V+1,If(V-(V/3)*3==0,S(1),option{Make(V+100)})}}\n" else "V+1}\n");
        const kind = if (carried) "tuple(i64,option(Node))" else "i64";
        const initial = if (carried) "tuple{0,option{}}" else "0";
        try self.add("Run(Visits:i64)<transacts>:{s}=Iterate(Step,Visits,{s})\n", .{ kind, initial });
        // Sometimes the whole loop is undone, with every instance and string it made.
        if (self.rng.intRangeLessThan(u8, 0, 4) == 0) {
            try self.add("Undone()<transacts><decides>:{s}=Block{{X:=Run({d});Fail[\"undo{{Count}}\"];X}}\nGone<public>:{s}=Attempt(Undone[],{s})\n", .{ kind, visits, kind, initial });
        }
        try self.add("R<public>:{s}=Run({d})\nAgain<public>:{s}=Run({d})\nHA<public>:option(Node)=A\nHB<public>:option(Node)=B\nDA<public>:i64=Depth(A,9)\nNA<public>:string=NameOf(A)\nPB<public>:string=PeerOf(B)\nL<public>:string=Log\nC<public>:i64=Count\n", .{ kind, visits, kind, self.rng.intRangeLessThan(u8, 0, 6) });
        return self.text.items;
    }
};

test "four hundred random programs over a graph of instances leave the same reachable state with and without reclamation" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(other);
    var random = std.Random.DefaultPrng.init(0x696e7374616e6365);
    var generator: GraphGenerator = .{ .rng = random.random() };
    defer generator.text.deinit(std.testing.allocator);
    var reclaims: u64 = 0;
    var freed: types.ControlStorage.Usage = .{};
    var fewer: usize = 0;
    for (0..400) |_| {
        const source = try generator.program();
        const p = try compileAll(f, source);
        f.configure(.full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.inner.h.run(p, fuel)).ok;
        var out = std.Io.Writer.fixed(plain);
        _ = try reporting.write(&out, stored, false, .{});
        try trace_report.write(&out, stored, "test.forb", .{});
        const expected = try Stored.of(stored, out.buffered());
        defer expected.destroy();
        const steps = stored.callWitness().?.count;
        const failures = stored.failure_count;
        const floor: u32 = if (generator.rng.boolean()) 0 else generator.rng.intRangeLessThan(u32, 0, 64);
        f.configure(.digest, generator.rng.intRangeLessThan(u32, 1, 40), floor);
        const runs = f.both(p, fuel) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        try std.testing.expectEqual(steps, runs.actual.witness.count);
        try std.testing.expectEqual(failures, runs.actual.failure_count);
        const reported = f.report(runs.actual, p, fuel, other) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        expected.expect(reported, runs.actual) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        try expected.expect(try f.report(runs.reference, p, fuel, other), runs.reference);
        if (runs.actual.object_cells.len < expected.instance_cells) fewer += 1;
        reclaims += runs.actual.reclaims;
        freed.members += f.inner.h.control.reclaimed_members;
        freed.strings += f.inner.h.control.reclaimed_bytes;
        freed.cells += f.inner.h.control.reclaimed_cells;
    }
    // The generator is only worth running if it keeps every part of the collector busy.
    try std.testing.expect(reclaims > 4000 and freed.members > 3000 and freed.strings > 15000 and freed.cells > 6000 and fewer > 100);
}

test "instances take exactly object_cells cells, whatever the number of the program's own, in both machines and in the report" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    const allocator = std.testing.allocator;
    const text = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(text);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    const budget = 1 << 20;
    // Two cells an instance, each named by the one made after it, so that all stay in use.
    const fit = types.limits.object_cells / 2;
    for ([_]usize{ 0, 1, 200, 250 }) |own| for ([_]usize{ fit, fit + 1 }) |instances| {
        source.clearRetainingCapacity();
        for (0..own) |index| try source.print(allocator, "var V{d}:i64={d}\n", .{ index, index });
        try source.print(allocator, "Node<public>:=class{{var Prev<public>:option(Node)}}\nPush(S:option(Node))<transacts>:option(Node)=option{{Node{{Prev:=S}}}}\nHead<public>:option(Node)=Iterate(Push,{d},option{{}})\n", .{instances});
        const p = try compileAll(f, source.items);
        try std.testing.expectEqual(own, p.source_cells.len);
        // Stored, with its report replayed from the witness by the harness.
        f.configure(.full, types.ControlStorage.default_trace_window, 0);
        const stored = try f.inner.h.run(p, budget);
        if (instances > fit) {
            try std.testing.expectEqual(types.Diagnostic.Code.object_limit, stored.failed.code);
        } else {
            try std.testing.expectEqual(@as(usize, types.limits.object_cells), stored.ok.object_cells.len);
            var out = std.Io.Writer.fixed(text);
            _ = try reporting.write(&out, stored.ok, true, .{});
            try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"Head\":[{\"$object\":1022}],\"$objects\":["));
        }
        // And when the run reclaims at every chance and at none: every instance is in use.
        for ([_]u32{ 0, types.ControlStorage.default_reclaim_floor, never }) |floor| {
            f.configure(.digest, types.ControlStorage.default_trace_window, floor);
            const failed = try f.outcome(p, budget);
            if (instances > fit) {
                try std.testing.expectEqual(types.Diagnostic.Code.object_limit, failed.?.code);
                try std.testing.expectEqualDeep(stored.failed, failed.?);
                continue;
            }
            try std.testing.expect(failed == null);
            const runs = try f.both(p, budget);
            try std.testing.expectEqual(@as(usize, types.limits.object_cells), runs.actual.object_cells.len);
            try std.testing.expect(std.mem.startsWith(u8, try f.values(runs.actual, p, budget, text), "{"));
        }
    };
}

/// Builds eight bytes and returns the first four: the rest is in the pool and no value names it.
fn padded(ctx: *native.Context, args: []const types.Value) native.Outcome {
    _ = args;
    const out = ctx.text(8) catch return .{ .fault = .string_limit };
    @memset(out, 'x');
    return .{ .scalar = .{ .string = out[0..4] } };
}
const native = @import("native.zig");
const hiding = [_]native.Entry{
    .{ .id = "t.padded", .params = &.{}, .result = .{ .element = .string, .kind = .scalar }, .cost = .{}, .call = padded },
};

test "a native that builds more bytes than it returns leaves the replay knowing where the pool ends" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    f.inner.h.front.natives = &hiding;
    for ([_][]const u8{
        // The hidden bytes lie between the native's string and the next one a visit builds,
        // and between one frame's mark and the next.
        "Pad:=native{\"t.padded\"}\nInner(S:i64)<computes>:i64=Block{T:=Pad();U:=\"u{S}\";S+T.Length+U.Length-U.Length-3}\nStep(S:tuple(i64,string))<computes>:tuple(i64,string)=Block{T:=Pad();K:=Iterate(Inner,2,S(0));tuple{K-1,T+\"{S(0)}\"}}\nV<public>:tuple(i64,string)=Iterate(Step,20,tuple{0,\"\"})",
        // An inner loop begins right after a native: its mark lies beyond the hidden bytes,
        // and the string it carries from visit to visit slides down to there and no further.
        "Pad:=native{\"t.padded\"}\nInner(S:string)<computes>:string=Block{T:=Pad();D:=T+T;T+\"y\"}\nStep(S:tuple(i64,string))<computes>:tuple(i64,string)=Block{T:=Pad();K:=Iterate(Inner,3,\"\");tuple{S(0)+K.Length-4,K+T}}\nW<public>:tuple(i64,string)=Iterate(Step,12,tuple{0,\"\"})",
        "Pad:=native{\"t.padded\"}\nvar Last:string=\"\"\nStep(S:i64)<transacts>:i64=Block{T:=Pad();set Last=T+\"{S}\";D:=Pad()+Pad();S+D.Length-7}\nTotal<public>:i64=Iterate(Step,20,0)\nKept<public>:string=Last",
    }) |source| {
        const p = try compileAll(f, source);
        f.configure(.full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.inner.h.run(p, fuel)).ok;
        var out = std.Io.Writer.fixed(plain);
        _ = try reporting.write(&out, stored, false, .{});
        try trace_report.write(&out, stored, "test.forb", .{});
        const expected = try Stored.of(stored, out.buffered());
        defer expected.destroy();
        for ([_]u32{ 0, 3, 40 }) |floor| for ([_]u32{ 1, 5, 64 }) |window| {
            f.configure(.digest, window, floor);
            const runs = try f.both(p, fuel);
            try std.testing.expect(runs.actual.reclaims != 0);
            try expected.expect(try f.report(runs.actual, p, fuel, other), runs.actual);
            try expected.expect(try f.report(runs.reference, p, fuel, other), runs.reference);
        };
    }
}

test "a call that ends in a native and reclaims as it returns is replayed in step with the run" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    // The run sends a window after the native's step and another as it reclaims; the root
    // goes on to build members, or to the next call, only after both.
    for ([_][]const u8{
        "Upper:=native{\"std.upper\"}\nStep(S:i64)<computes>:i64=Block{T:=tuple{S,S};T(0)+1}\nV<public>:i64=Iterate(Step,300,0)\nUp(S:string)<computes>:string=Upper(S+\"a\")\nZ<public>:string=Iterate(Up,2,\"z\")\nW<public>:tuple(i64,string)=tuple{V,Z}",
        "Upper:=native{\"std.upper\"}\nStep(S:i64)<computes>:i64=Block{T:=tuple{S,S};T(0)+1}\nV<public>:i64=Iterate(Step,300,0)\nShout(T:string)<transacts>:string=Upper(T)\nZ<public>:string=Shout(\"z\")\nW<public>:tuple(i64,string)=tuple{V,Z}",
        "Upper:=native{\"std.upper\"}\nStep(S:i64)<computes>:i64=Block{T:=tuple{S,S};T(0)+1}\nV<public>:i64=Iterate(Step,300,0)\nUp(S:string)<computes>:string=Upper(S+\"a\")\nZ<public>:string=Iterate(Up,2,\"z\")\nMore(S:tuple(i64,string))<computes>:tuple(i64,string)=Block{J:=\"j{S(0)}\";tuple{S(0)+J.Length,S(1)+\"x\"}}\nY<public>:tuple(i64,string)=Iterate(More,5,tuple{0,\"\"})",
        "Upper:=native{\"std.upper\"}\nUp(S:string)<computes>:string=Upper(S+\"a\")\nZ<public>:string=Iterate(Up,2,\"z\")\nW<public>:tuple(i64,string)=tuple{1,Z}",
    }) |source| {
        const p = try compileAll(f, source);
        f.configure(.full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.inner.h.run(p, fuel)).ok;
        var out = std.Io.Writer.fixed(plain);
        _ = try reporting.write(&out, stored, false, .{});
        try trace_report.write(&out, stored, "test.forb", .{});
        const expected = try Stored.of(stored, out.buffered());
        defer expected.destroy();
        for ([_]u32{ 0, 1, 40, 100, never }) |floor| for ([_]u32{ 1, 3, 64, types.ControlStorage.default_trace_window }) |window| {
            f.configure(.digest, window, floor);
            const runs = try f.both(p, fuel);
            try expected.expect(try f.report(runs.actual, p, fuel, other), runs.actual);
            try expected.expect(try f.report(runs.reference, p, fuel, other), runs.reference);
        };
    }
}

test "calls from the root that build little do not each reclaim a run that holds much" {
    const f = try Fixture.create();
    defer f.destroy();
    const allocator = std.testing.allocator;
    const other = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(other);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    var reclaims: [2]u64 = undefined;
    // A list of two hundred nodes that stays, built by a loop that reclaims; then no call, or
    // forty short ones. Each of those would have to read six hundred cells to free two members.
    for ([_]usize{ 0, 40 }, &reclaims) |calls, *count| {
        source.clearRetainingCapacity();
        try source.appendSlice(allocator, "Node:=class{Value:i64,var Next:option(Node)}\nPush(S:option(Node))<transacts>:option(Node)=Block{D:=tuple{1,2};option{Node{Value:=1,Next:=S}}}\nHead:option(Node)=Iterate(Push,200,option{})\nT(K:i64)<computes>:i64=Block{X:=tuple{K,K};X(0)+1}\n");
        for (0..calls) |index| try source.print(allocator, "A{d}:i64=Iterate(T,1,{d})\n", .{ index, index });
        try source.appendSlice(allocator, "Z<public>:i64=Iterate(T,1,7)\n");
        const p = try compileAll(f, source.items);
        f.configure(.digest, 64, 20);
        const runs = try f.both(p, fuel);
        try std.testing.expect(runs.actual.reclaims > 3);
        try std.testing.expectEqual(@as(usize, 600), runs.actual.object_cells.len);
        _ = try f.report(runs.actual, p, fuel, other);
        count.* = runs.actual.reclaims;
    }
    // The members they leave do add up to a reclamation now and then, by the ordinary rule.
    try std.testing.expect(reclaims[1] <= reclaims[0] + 2);
}

// RFC-0082, P3.5: reclamation across task stacks. A frame end that saw another task run since
// its push reclaims too, with the registers available in every suspended frame, their seeds and
// captures as roots, above its marks or the stores' sizes when the root ended; the suspended
// frames' marks above it are remapped. The programs below fit the pool when nothing is
// reclaimed, so each digest run is held against the stored run of the same program.

/// Task programs whose garbage is left by frames that saw a switch: loop visits with a
/// suspension in them, frames under a call that suspends, arms and branches. Each keeps values
/// across its suspensions in registers, captures, seeds, lower frames, events and cells.
const task_programs = [_][]const u8{
    // A service loop per task, each visit sleeping; an array made before the loop is read after it.
    \\var Visits:i64 = 0
    \\Service(Keep:[]i64)<transacts><suspends>:i64 = Block{
    \\    Held := Keep + array{7}
    \\    Loop{ If(Visits >= 60, Break(), false); set Visits = Visits + 1; J := array{Visits, Visits, Visits}; Sleep(0.0) }
    \\    Held.Length + Visits
    \\}
    \\A:task(i64) = Spawn{ Service(array{1, 2, 3}) }
    \\B:task(i64) = Spawn{ Service(array{4}) }
    ,
    // Strings and instances held across sleeps, a field rewritten each visit, string marks moving.
    \\Box := class{ var Name:string, Items:[]i64 }
    \\Worker(N:i64)<transacts><suspends>:string = Block{
    \\    B := Box{ Name := "w{N}", Items := array{N, N} }
    \\    S := "start {N}"
    \\    var I:i64 = 0
    \\    Loop{ If(I >= 30, Break(), false); set I = I + 1; T := "junk {I} {N}"; C := Box{ Name := T, Items := array{I} }; set B.Name = "{B.Name}."; Sleep(0.0) }
    \\    "{S} {B.Name} {B.Items.Length}"
    \\}
    \\A:task(string) = Spawn{ Worker(1) }
    \\B:task(string) = Spawn{ Worker(2) }
    ,
    // Lower frames of a suspended task hold what they built; an event carries built arrays; a
    // `Sync` keeps its arms' results; a branch is waited for at its frame's end.
    \\E:event([]i64) = event([]i64){}
    \\Deep(D:i64)<transacts><suspends>:[]i64 = If(D == 0, Block{ Sleep(0.0); array{D} }, Block{ Mine := array{D, D}; R := Deep(D - 1); Mine + R })
    \\Ear()<transacts><suspends>:i64 = Block{ var Sum:i64 = 0; Loop{ Xs := E.Await(); If(Xs.Length == 0, Break(), false); set Sum = Sum + Xs.Length; J := array{Sum, Sum} }; Sum }
    \\Watch(N:i64)<transacts><suspends>:i64 = Block{ Branch{ K := array{N}; Sleep(0.0); J := array{N, N}; J.Length }; Kept := array{N, N, N}; Sleep(0.0); Kept.Length }
    \\Main()<transacts><suspends>:i64 = Block{
    \\    var I:i64 = 0
    \\    var Total:i64 = 0
    \\    Loop{ If(I >= 12, Break(), false); set I = I + 1; Xs := Deep(4); E.Signal(Xs + array{I}); P := Sync(Block{ Sleep(0.0); array{I} }, Block{ Q := array{I, I}; Sleep(0.0); Q }); set Total = Total + P(0).Length + P(1).Length + Watch(I); Sleep(0.0) }
    \\    Done:[]i64 = array{}; E.Signal(Done)
    \\    Total
    \\}
    \\A:task(i64) = Spawn{ Ear() }
    \\M:task(i64) = Spawn{ Main() }
    ,
    // The root builds after a task's frames were pushed, and the tasks reclaim after the root.
    \\Slow(N:i64)<transacts><suspends>:i64 = Block{ Own := array{N, N}; Sleep(0.1); var I:i64 = 0; Loop{ If(I >= 30, Break(), false); set I = I + 1; J := array{I, I}; S := "s{I}"; Sleep(0.0) }; Own.Length + I }
    \\A:task(i64) = Spawn{ Slow(1) }
    \\Built:[]i64 = array{5, 6, 7} + array{8}
    \\Said:string = "root {Built.Length}"
    \\B:task(i64) = Spawn{ Slow(2) }
    \\Tail:[]i64 = Built + array{9}
    ,
    // A state loop whose visits sleep reads its captures at every visit, and an iteration its seed.
    \\Step(K:[]i64, S:i64)<transacts><suspends>:option(i64) = Block{ Sleep(0.0); J := K + array{S}; If(S >= 25, option{}, option{S + J.Length - K.Length}) }
    \\Next(S:[]i64)<transacts><suspends>:[]i64 = Block{ Sleep(0.0); J := array{S.Length}; array{S.Length + J.Length} }
    \\Run(K:[]i64)<transacts><suspends>:i64 = Block{ L := Loop(Bind(Step, K), 0); I := Iterate(Next, 20, array{1}); L + I.Length + K.Length }
    \\A:task(i64) = Spawn{ Run(array{3, 4, 5}) }
    \\B:task(i64) = Spawn{ Run(array{6}) }
    ,
    // Live variables (RFC-0084) written by tasks between their sleeps: records, links and
    // entries move with the cells when a visit that saw a switch reclaims.
    \\var Source:i64 = 0
    \\var live Doubled:i64 = Source * 2
    \\live Label:string = "source {Source}"
    \\Box := class{ var N:i64 }
    \\Tick(N:i64)<transacts><suspends>:i64 = Block{ var I:i64 = 0; Loop{ If(I >= 20, Break(), false); set I = I + 1; set Source = Source + N; J := array{Doubled, I}; Made := Box{ N := Label.Length }; Sleep(0.0) }; Doubled }
    \\A:task(i64) = Spawn{ Tick(1) }
    \\B:task(i64) = Spawn{ Tick(2) }
    ,
};

/// Budgets for task programs: they run for many more nodes than the call programs above.
const task_fuel: u64 = 1 << 24;

test "P3.5: frames that saw another task run reclaim, and what suspended frames hold stays: digest runs report as stored ones" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    for (task_programs) |source| {
        const p = try compileAll(f, source);
        f.configure(.full, types.ControlStorage.default_trace_window, 0);
        const stored = (try f.inner.h.run(p, task_fuel)).ok;
        try std.testing.expectEqual(@as(u64, 0), stored.reclaims);
        var out = std.Io.Writer.fixed(plain);
        _ = try reporting.write(&out, stored, false, .{});
        const expected = try Stored.of(stored, out.buffered());
        defer expected.destroy();
        const members = stored.aggregate_values.len;
        for ([_]u32{ 0, 1, 5, 40 }) |floor| for ([_]u32{ 1, 3, 64 }) |window| {
            f.configure(.digest, window, floor);
            const runs = f.both(p, task_fuel) catch |problem| {
                std.debug.print("floor {d} window {d}:\n{s}\n", .{ floor, window, source });
                return problem;
            };
            try std.testing.expectEqualDeep(stored.scheduler, runs.actual.scheduler);
            if (floor == 0) {
                try std.testing.expect(runs.actual.reclaims != 0);
                // The visits' garbage is gone: under the P3.1 rule it stayed until the root's
                // turn, which never comes in a task.
                try std.testing.expect(runs.actual.aggregate_values.len * 2 < members);
            }
            var into = std.Io.Writer.fixed(other);
            _ = reporting.writeReplayed(&into, runs.actual, f.inner.again.producer(p, task_fuel), false, .{ .work = 1 << 26 }) catch |problem| {
                std.debug.print("floor {d} window {d}:\n{s}\n", .{ floor, window, source });
                return problem;
            };
            try expected.expect(into.buffered(), runs.actual);
            into = std.Io.Writer.fixed(other);
            _ = try reporting.writeReplayed(&into, runs.reference, f.inner.again.producer(p, task_fuel), false, .{ .work = 1 << 26 });
            try expected.expect(into.buffered(), runs.reference);
        };
        // Without a witness both machines still agree, and leave the same reachable state.
        f.configure(.off, 5, 0);
        const silent = try f.both(p, task_fuel);
        const graph = try graphOf(silent.actual);
        defer std.testing.allocator.free(graph);
        try std.testing.expectEqualStrings(expected.graph, graph);
    }
}

test "P3.5: a service loop with a sleep in every visit runs in bounded stores, where a stored run fills them" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    const text = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(text);
    // Each visit builds members, a string and an instance, and sleeps: 10,000 visits pass far
    // more of each through the stores than the bootstrap profile holds (8,192 members, 64 KiB
    // of strings, 1,024 cells). An array, a string and an instance made before the loop are
    // held across every sleep and read at the end.
    const p = try compileAll(f,
        \\Note := class{ var Count:i64, Text:string }
        \\var Visits:i64 = 0
        \\Service(N:i64)<transacts><suspends>:string = Block{
        \\    Keep := array{N, N + 1}
        \\    Name := "service {N}"
        \\    Own := Note{ Count := 0, Text := Name }
        \\    Loop{ If(Own.Count >= 5000, Break(), false); set Own.Count = Own.Count + 1; set Visits = Visits + 1; J := array{Own.Count, N}; S := "visit {Own.Count} of {Name}"; X := Note{ Count := J.Length, Text := S }; Sleep(0.0) }
        \\    "{Own.Text} {Keep.Length} {Own.Count}"
        \\}
        \\A:task(string) = Spawn{ Service(1) }
        \\B:task(string) = Spawn{ Service(2) }
    );
    // A stored run keeps every step, so nothing is reclaimed and the stores fill.
    f.configure(.full, types.ControlStorage.default_trace_window, 0);
    try std.testing.expect(try f.outcome(p, task_fuel) != null);
    // Under the P3.1 rule the visits, which all saw a switch, would reclaim nothing either; the
    // digest run reclaims at their ends and completes in both machines.
    for ([_]types.TraceMode{ .digest, .off }) |trace| {
        f.configure(trace, types.ControlStorage.default_trace_window, types.ControlStorage.default_reclaim_floor);
        const runs = try f.both(p, task_fuel);
        try std.testing.expectEqual(@as(i64, 10000), runs.actual.cells[0].value.integer);
        try std.testing.expect(runs.actual.reclaims > 20);
        // What stays is what the two tasks hold, whatever the number of visits.
        try std.testing.expect(runs.actual.aggregate_values.len < 2048 and runs.actual.object_cells.len < 256 and runs.actual.program.strings.len < 32 * 1024);
        try std.testing.expectEqual(@as(u64, 20002), runs.actual.scheduler.switches);
        if (trace == .digest) try std.testing.expectEqualStrings("{\"Visits\":10000,\"A\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":\"service 1 2 5000\"}},\"B\":{\"$task\":{\"sequence\":2,\"state\":\"completed\",\"result\":\"service 2 2 5000\"}},\"$scheduler\":{\"tick_rate\":60,\"tick\":5000,\"created\":2,\"completed\":2,\"canceled\":0,\"switches\":20002,\"waiting\":[]}}\n", try f.values(runs.actual, p, task_fuel, text));
    }
}

fn elapsed(start: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toNanoseconds(), std.time.ns_per_ms));
}

/// The P3.5 gate at scale: two tasks each run `visits` visits of a service loop that builds an
/// array, a string of some sixty bytes and an instance of five cells and then sleeps, in a
/// digest run whose replay works every reclamation out again. With a million visits in all
/// that is more than the program profile's members, string bytes and cells several times over;
/// the stores hold only what the tasks keep. Prints how long each machine and the replay took.
pub fn serviceLoop(f: replay.Fixture, visits: u64) !void {
    const h = f.h;
    var buffer: [2048]u8 = undefined;
    const source = try std.fmt.bufPrint(&buffer,
        \\Note := class{{ var Count:i64, Text:string, A:i64, B:i64 }}
        \\var Visits:i64 = 0
        \\Service(N:i64)<transacts><suspends>:string = Block{{
        \\    Keep := array{{N, N + 1}}
        \\    Name := "service {{N}}"
        \\    Own := Note{{ Count := 0, Text := Name, A := N, B := N }}
        \\    Loop{{ If(Own.Count >= {d}, Break(), false); set Own.Count = Own.Count + 1; set Visits = Visits + 1; J := array{{Own.Count, N, N}}; S := "visit {{Own.Count}} of {{Name}}, which keeps its own note"; X := Note{{ Count := J.Length, Text := S, A := N, B := Own.Count }}; Sleep(0.0) }}
        \\    "{{Own.Text}} {{Keep.Length}} {{Own.Count}}"
        \\}}
        \\A:task(string) = Spawn{{ Service(1) }}
        \\B:task(string) = Spawn{{ Service(2) }}
    , .{visits});
    const p = try h.compile(source);
    const budget: u64 = 1 << 40;
    f.mode(.digest, types.ControlStorage.default_trace_window);
    defer f.mode(.full, types.ControlStorage.default_trace_window);
    const start = std.Io.Clock.awake.now(std.testing.io);
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, budget);
    const referenced = elapsed(start);
    const actual = h.runtime.evaluate(p, budget);
    const ran = elapsed(start);
    if (actual != .ok) std.debug.print("service loop failed: {t}\n", .{actual.failed.code});
    try std.testing.expect(reference == .ok and actual == .ok);
    try std.testing.expectEqualDeep(reference.ok.scheduler, actual.ok.scheduler);
    try std.testing.expectEqual(reference.ok.reclaims, actual.ok.reclaims);
    try std.testing.expectEqual(4 * visits + 2, actual.ok.scheduler.switches);
    try std.testing.expectEqual(@as(i64, @intCast(2 * visits)), actual.ok.cells[0].value.integer);
    // What stays is what the two tasks hold, whatever the number of visits.
    try std.testing.expect(actual.ok.aggregate_values.len < 4096 and actual.ok.object_cells.len < 1024 and actual.ok.program.strings.len < 64 * 1024);
    var report: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&report);
    _ = try reporting.writeReplayed(&out, actual.ok, f.again.producer(p, budget), false, .{ .work = std.math.maxInt(u64) });
    std.debug.print("{d} service visits that each sleep, {d} reclamations, {d} members left: reference={d}ms vm={d}ms replay={d}ms\n", .{ 2 * visits, actual.ok.reclaims, actual.ok.aggregate_values.len, referenced, ran - referenced, elapsed(start) - ran });
    var expected: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), try std.fmt.bufPrint(&expected, "\"result\":\"service 1 2 {d}\"", .{visits})) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), try std.fmt.bufPrint(&expected, "\"result\":\"service 2 2 {d}\"", .{visits})) != null);
}

test "P3.5: the service loop at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try replay.Fixture.create();
    defer f.destroy();
    try serviceLoop(f, 2000);
}

test "P3.5: what a suspended frame holds is in use: a task that keeps all it builds stops at the pool in both machines alike" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    // The array grows in a local of a frame that sleeps in every visit; every reclamation finds
    // it reachable from the saved registers and keeps it.
    const p = try compileAll(f,
        \\Hoard(N:i64)<transacts><suspends>:i64 = Block{
        \\    var Kept:[]i64 = array{}
        \\    Loop{ If(Kept.Length >= 9000, Break(), false); set Kept = Kept + array{N, N, N, N, N, N, N, N}; Sleep(0.0) }
        \\    Kept.Length
        \\}
        \\A:task(i64) = Spawn{ Hoard(1) }
    );
    f.configure(.digest, types.ControlStorage.default_trace_window, never);
    const unreclaimed = (try f.outcome(p, 1 << 30)).?;
    try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, unreclaimed.code);
    for ([_]u32{ 0, 16, types.ControlStorage.default_reclaim_floor }) |floor| {
        f.configure(.digest, types.ControlStorage.default_trace_window, floor);
        const failed = (try f.outcome(p, 1 << 30)).?;
        try std.testing.expectEqual(types.Diagnostic.Code.aggregate_limit, failed.code);
        try std.testing.expectEqualStrings("+", p.source[failed.span.start..failed.span.end]);
    }
}

/// Records every window a machine sends: how many steps, the pool it was sent with (a hash of
/// each member, strings by their bytes) and the size of the string pool.
const Windows = struct {
    seen: std.ArrayList(u64) = .empty,

    fn sink(self: *Windows) types.TraceSink {
        return .{ .context = self, .write = write };
    }
    fn write(context: *anyopaque, steps: []const types.CallStep, members: []const types.Value, strings: usize) void {
        const self: *Windows = @ptrCast(@alignCast(context));
        var hash = std.hash.Wyhash.init(steps.len);
        hash.update(std.mem.asBytes(&members.len));
        hash.update(std.mem.asBytes(&strings));
        for (members) |member| {
            hash.update(@tagName(member));
            switch (member) {
                .string => |bytes| hash.update(bytes),
                .floating => |value| hash.update(std.mem.asBytes(&value)),
                .integer => |value| hash.update(std.mem.asBytes(&value)),
                .aggregate => |value| hash.update(std.mem.asBytes(&value.elements)),
                .callable => |value| {
                    hash.update(std.mem.asBytes(&value.function));
                    hash.update(std.mem.asBytes(&value.captures));
                },
                .object => |value| hash.update(std.mem.asBytes(&value.id)),
                else => {},
            }
        }
        self.seen.append(std.testing.allocator, hash.final()) catch unreachable;
    }
};

test "P3.5: both machines send the same pool in every window, so they agree on the layout after every reclamation" {
    const f = try Fixture.create();
    defer f.destroy();
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    for (task_programs) |source| {
        const p = try compileAll(f, source);
        // A window of one step, sent before every reclamation and after every step, shows each
        // pool a reclamation leaves.
        f.configure(.digest, 1, 0);
        var reference: Windows = .{};
        defer reference.seen.deinit(std.testing.allocator);
        var actual: Windows = .{};
        defer actual.seen.deinit(std.testing.allocator);
        f.inner.h.control.trace_sink = reference.sink();
        f.inner.h.runtime.machine.control.trace_sink = actual.sink();
        defer {
            f.inner.h.control.trace_sink = null;
            f.inner.h.runtime.machine.control.trace_sink = null;
        }
        const runs = try f.both(p, task_fuel);
        try std.testing.expect(runs.actual.reclaims != 0);
        try std.testing.expect(reference.seen.items.len > 100);
        try std.testing.expectEqualSlices(u64, reference.seen.items, actual.seen.items);
        f.inner.h.control.trace_sink = null;
        f.inner.h.runtime.machine.control.trace_sink = null;
        // The replay works each reclamation out again and admits the run.
        var into = std.Io.Writer.fixed(other);
        _ = try reporting.writeReplayed(&into, runs.actual, f.inner.again.producer(p, task_fuel), false, .{ .work = 1 << 26 });
    }
}

/// Random task programs: a few tasks, each running a loop whose visits build and drop arrays,
/// strings and instances, keep some across their suspensions, signal, await, sleep, call down
/// into frames that sleep, and run `Sync` and `Branch`.
const TaskGenerator = struct {
    rng: std.Random,
    text: std.ArrayList(u8) = .empty,
    names: u32 = 0,

    const prelude =
        \\Box := class{ var T:[]i64, Name:string }
        \\E:event([]i64) = event([]i64){}
        \\var Log:[]i64 = array{}
        \\var Count:i64 = 0
        \\Deep(D:i64)<transacts><suspends>:[]i64 = If(D <= 0, Block{ Sleep(0.0); array{D} }, Block{ Mine := array{D, D}; R := Deep(D - 1); Mine + R })
        \\Watch(N:i64)<transacts><suspends>:i64 = Block{ Branch{ K := array{N}; Sleep(0.0); J := "b{N}"; J.Length }; Kept := array{N, N}; Sleep(0.0); Kept.Length }
        \\Ear()<transacts><suspends>:i64 = Block{ var Sum:i64 = 0; Loop{ Xs := E.Await(); set Sum = Sum + Xs.Length; J := array{Sum} }; Sum }
        \\
    ;

    fn add(self: *TaskGenerator, comptime format: []const u8, arguments: anytype) !void {
        try self.text.print(std.testing.allocator, format, arguments);
    }
    fn statement(self: *TaskGenerator) !void {
        const name = self.names;
        self.names += 1;
        const c = self.rng.intRangeLessThan(u8, 0, 9);
        switch (self.rng.intRangeLessThan(u8, 0, 14)) {
            0 => try self.add("A{d} := array{{I, {d}}} + array{{I}}; ", .{ name, c }),
            1 => try self.add("S{d} := \"s{{I}} {d}\"; ", .{ name, c }),
            2 => try self.add("B{d} := Box{{ T := array{{I}}, Name := \"n{{I}}\" }}; ", .{name}),
            3 => try self.add("set Log = Log + array{{I}}; ", .{}),
            4 => try self.add("set Keep.T = Keep.T + array{{{d}}}; ", .{c}),
            5 => try self.add("E.Signal(array{{I, {d}}}); ", .{c}),
            6 => try self.add("Sleep(0.0); ", .{}),
            7 => try self.add("Sleep({d}.0 / 60.0); ", .{c}),
            8 => try self.add("D{d} := Deep({d}); ", .{ name, self.rng.intRangeLessThan(u8, 0, 4) }),
            9 => try self.add("P{d} := Sync(Block{{ Sleep(0.0); array{{I}} }}, Block{{ Q := \"q{{I}}\"; Sleep(0.0); Q }}); ", .{name}),
            10 => try self.add("W{d} := Watch(I); ", .{name}),
            11 => try self.add("set Count = Count + Held.Length + Title.Length; ", .{}),
            12 => try self.add("F{d} := Bind(Mix, Held); G{d} := F{d}(I); ", .{ name, name, name }),
            else => try self.add("set Keep = Box{{ T := array{{I, {d}}}, Name := \"k{{I}}\" }}; ", .{c}),
        }
    }
    fn program(self: *TaskGenerator) ![]const u8 {
        self.text.clearRetainingCapacity();
        self.names = 0;
        try self.text.appendSlice(std.testing.allocator, prelude);
        try self.text.appendSlice(std.testing.allocator, "Mix(K:[]i64, X:i64)<computes>:i64 = K.Length + X\n");
        const tasks = self.rng.intRangeLessThan(u8, 1, 4);
        for (0..tasks) |task| {
            try self.add("Work{d}(N:i64)<transacts><suspends>:string = Block{{\n    Held := array{{N, {d}}}\n    Title := \"task {{N}}\"\n    var Keep:Box = Box{{ T := array{{N}}, Name := Title }}\n    var I:i64 = 0\n    Loop{{ If(I >= {d}, Break(), false); set I = I + 1; ", .{ task, task, self.rng.intRangeLessThan(u8, 1, 12) });
            for (0..self.rng.intRangeLessThan(u8, 1, 7)) |_| try self.statement();
            try self.add("Sleep(0.0) }}\n    \"{{Title}} {{Held.Length}} {{Keep.T.Length}} {{Keep.Name}}\"\n}}\n", .{});
        }
        if (self.rng.boolean()) try self.add("L:task(i64) = Spawn{{ Ear() }}\n", .{});
        for (0..tasks) |task| try self.add("T{d}:task(string) = Spawn{{ Work{d}({d}) }}\nR{d}:[]i64 = array{{{d}}} + Log\n", .{ task, task, task + 1, task, task });
        try self.add("Seen:i64 = Count\n", .{});
        return self.text.items;
    }
};

test "P3.5: random task programs report the same with reclamation at every chance and with none" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    var random = std.Random.DefaultPrng.init(0x70333572656331);
    var generator: TaskGenerator = .{ .rng = random.random() };
    defer generator.text.deinit(std.testing.allocator);
    var reclaims: u64 = 0;
    for (0..200) |_| {
        const source = try generator.program();
        const p = compileAll(f, source) catch |problem| {
            std.debug.print("does not compile:\n{s}\n", .{source});
            return problem;
        };
        f.configure(.full, types.ControlStorage.default_trace_window, 0);
        const stored = switch (try f.inner.h.run(p, task_fuel)) {
            .ok => |x| x,
            .failed => |diagnostic| {
                std.debug.print("{t}:\n{s}\n", .{ diagnostic.code, source });
                return error.TestUnexpectedResult;
            },
        };
        var out = std.Io.Writer.fixed(plain);
        _ = try reporting.write(&out, stored, false, .{});
        const expected = try Stored.of(stored, out.buffered());
        defer expected.destroy();
        const floor: u32 = if (generator.rng.boolean()) 0 else generator.rng.intRangeLessThan(u32, 0, 64);
        f.configure(.digest, generator.rng.intRangeLessThan(u32, 1, 40), floor);
        const runs = f.both(p, task_fuel) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        try std.testing.expectEqualDeep(stored.scheduler, runs.actual.scheduler);
        var into = std.Io.Writer.fixed(other);
        _ = reporting.writeReplayed(&into, runs.actual, f.inner.again.producer(p, task_fuel), false, .{ .work = 1 << 26 }) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        expected.expect(into.buffered(), runs.actual) catch |problem| {
            std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
            return problem;
        };
        reclaims += runs.actual.reclaims;
    }
    try std.testing.expect(reclaims > 1000);
}

test "a growing For keeps its room through reclamation: the same fuel, linear in its length, and a replay that follows it" {
    const f = try Fixture.create();
    defer f.destroy();
    const text = try std.testing.allocator.alloc(u8, 1 << 16);
    defer std.testing.allocator.free(text);
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        // One range: the accumulator lies behind the loop's state wrapper at every visit.
        .{ "Xs:[]i64=For(K:1..600,K*3)\nN<public>:i64=Xs.Length\nLast<public>:i64=Attempt(Xs[599],0)", "],\"N\":600,\"Last\":1800}" },
        // Nested generators: each inner loop grows its own result between the outer appends.
        .{ "Ps:[]i64=For(I:1..30,J:1..20,I*100+J)\nN<public>:i64=Ps.Length\nLast<public>:i64=Attempt(Ps[599],0)", "],\"N\":600,\"Last\":3020}" },
        // Instances, and a filter on the established form that loops over a tuple state.
        .{ "P:=class{N:i64}\nAll:[]P=For(K:1..300,P{N:=K})\nXs:[]i64=array{1,2,3,4,5,6,7,8,9,10}\nBig:[]i64=For(X:Xs,X>5,X*X)\nN<public>:i64=All.Length+Big.Length*1000\nS<public>:i64=Attempt(Big[4],0)", "],\"N\":5300,\"S\":100" },
    }) |case| {
        const p = try compileAll(f, case[0]);
        var needed: [2]u64 = undefined;
        for ([_]types.TraceMode{ .digest, .digest }, [_]u32{ never, 0 }, &needed) |trace, floor, *exact| {
            f.configure(trace, 7, floor);
            var low: u64 = 0;
            var high: u64 = fuel;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if ((try f.outcome(p, middle)) == null) high = middle else low = middle + 1;
            }
            exact.* = low;
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try f.outcome(p, low - 1)).?.code);
            const runs = try f.both(p, low);
            if (floor == 0) try std.testing.expect(runs.actual.reclaims > 0);
            // The report lists every binding, and the instances; the public ones are the last.
            if (trace == .digest) try std.testing.expect(std.mem.indexOf(u8, try f.values(runs.actual, p, low, text), case[1]) != null);
        }
        // The fuel of a run that never reclaims and of one that reclaims at every chance is one
        // number, and it is linear: copying the accumulator at every element charged about
        // 180,000 units for 600 of them.
        try std.testing.expectEqual(needed[0], needed[1]);
        try std.testing.expect(needed[0] < 40 * 600);
    }
}

test "rooms: what a join writes into a room is reached by the reclamation of the frame that wrote it" {
    const f = try Fixture.create();
    defer f.destroy();
    const text = try std.testing.allocator.alloc(u8, 1 << 16);
    defer std.testing.allocator.free(text);
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        // `Xs` has a room below the mark of `Add`, whose reclamation does not walk below its
        // mark: `Add` copies instead of writing the string it builds there.
        .{ "Xs:[]string=For(K:1..40,\"a\")\nAdd(A:[]string,K:i64)<computes>:[]string=Block{G:=ToString(K)+\"garbage\";H:=G+\"more\";A+array{ToString(K)+\"zz\"}}\nYs:[]string=Add(Xs,777)\nW:string=ToString(123456)+\"qqqqqqqqq\"\nL<public>:string=Attempt(Ys[40],\"none\")", "\"L\":\"777zz\"" },
        // Strings and instances a `For` builds go into the room of its accumulator, above the
        // loop's mark, and read back after reclamations at every chance.
        .{ "Ss:[]string=For(K:1..300,\"s{K}\")\nT<public>:string=Attempt(Ss[299],\"\")+Attempt(Ss[0],\"\")", "\"T\":\"s300s1\"" },
        .{ "P:=class{N:i64}\nAll:[]P=For(K:1..300,P{N:=K*2})\nSum:=native{\"std.sum\"}\nS<public>:i64=Sum(For(X:All,X.N))", "\"S\":90300" },
    }) |case| {
        const p = try compileAll(f, case[0]);
        for ([_]u32{ never, 0 }) |floor| {
            f.configure(.digest, 7, floor);
            const runs = try f.both(p, fuel);
            if (floor == 0) try std.testing.expect(runs.actual.reclaims > 0);
            try std.testing.expect(std.mem.indexOf(u8, try f.values(runs.actual, p, fuel, text), case[1]) != null);
        }
    }
}

test "rooms: a copy that fits is never refused for its room" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    var text: [256]u8 = undefined;
    // A tuple state copies an array of 2,400 members, then a copy of that: with a room as
    // long as the copy the second would need more members than the pool has left.
    const p = try compileAll(f, "Grow(S:[]i64)<computes>:[]i64=S+array{S.Length}\nA:[]i64=Iterate(Grow,2400,array{})\nStep(S:tuple(i64,[]i64))<computes>:tuple(i64,[]i64)=tuple{S(0)+1,S(1)+array{S(0)}}\nT:tuple(i64,[]i64)=Iterate(Step,2,tuple{0,A})\nN<public>:i64=T(1).Length");
    for ([_]u32{ never, 0 }) |floor| {
        f.configure(.digest, types.ControlStorage.default_trace_window, floor);
        const runs = try f.both(p, fuel);
        var out = std.Io.Writer.fixed(&text);
        _ = try reporting.writeReplayed(&out, runs.actual, f.inner.again.producer(p, fuel), true, .{ .work = 1 << 24 });
        try std.testing.expectEqualStrings("{\"N\":2402}\n", out.buffered());
    }
}

/// The least fuel with which both machines finish `p` in the configuration of `f`.
fn roomLeast(f: Fixture, p: types.Program) !u64 {
    return leastWithin(f, p, fuel);
}

/// The least fuel up to `most` with which both machines finish `p` in the configuration of `f`.
fn leastWithin(f: Fixture, p: types.Program, most: u64) !u64 {
    var low: u64 = 0;
    var high: u64 = most;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if ((try f.outcome(p, middle)) == null) high = middle else low = middle + 1;
    }
    try std.testing.expect(low < most);
    return low;
}

test "rooms: near the limit of the pool every floor completes, as before rooms" {
    const f = try Fixture.create();
    defer f.destroy();
    var buffer: [768]u8 = undefined;
    // Junk of a few sizes before each append of a tuple state, so that the pool holds more or
    // less garbage at each copy depending on the floor. A copy that fits is never refused for
    // its room, so every floor completes; how much room it leaves, and so the fuel, may differ.
    for ([_]u32{ 400, 1200, 1600, 2000 }) |junk| {
        const source = try std.fmt.bufPrint(&buffer, "Grow(S:[]i64)<computes>:[]i64=S+array{{S.Length}}\nJunk(N:i64)<computes>:i64=Iterate(Grow,N,array{{}}).Length\nA:[]i64=Iterate(Grow,1800,array{{}})\nStep(S:tuple(i64,[]i64))<computes>:tuple(i64,[]i64)=Block{{G:=Junk({d});tuple{{S(0)+G-{d}+1,S(1)+array{{S(0)}}}}}}\nT:tuple(i64,[]i64)=Iterate(Step,4,tuple{{0,A}})\nN<public>:i64=T(1).Length", .{ junk, junk });
        const p = try compileAll(f, source);
        for ([_]u32{ 0, 300, 600, 1500 }) |floor| {
            f.configure(.digest, 7, floor);
            _ = try roomLeast(f, p);
        }
    }
}

test "rooms: no join writes into a room once another task has run" {
    const f = try Fixture.create();
    defer f.destroy();
    // `Inner`'s frame is pushed before `W1` makes its string and reclaims over it later, above
    // a member mark that lies above the room behind `X`.
    const p = try compileAll(f,
        \\W1()<transacts><suspends>:[]string = Block{ Sleep(0.1); X:[]string = For(I:1..40,"a"); Sleep(1.0); X+array{ToString(777)+"zz"} }
        \\Junk(N:i64)<computes>:i64 = Block{ G:=ToString(N)+"garbagegarbage"; H:=G+"more"; H.Length }
        \\Inner()<transacts><suspends>:i64 = Block{ Sleep(1.0); B:string = ToString(5)+"yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"; C:=B+B; D:=C+C; E:=D+D; F:=E+E; F.Length }
        \\W2()<transacts><suspends>:i64 = Block{ Sleep(0.5); Inner() }
        \\W3(T:task([]string))<transacts><suspends>:string = Block{ Sleep(3.0); J:=Junk(3)+Junk(4); Y:=T.Await(); Attempt(Y[40],"none") }
        \\T1:task([]string)=Spawn{W1()}
        \\T2:task(i64)=Spawn{W2()}
        \\T3:task(string)=Spawn{W3(T1)}
    );
    const text = try std.testing.allocator.alloc(u8, 1 << 16);
    defer std.testing.allocator.free(text);
    for ([_]u32{ never, 0 }) |floor| {
        f.configure(.digest, 7, floor);
        const runs = try f.both(p, fuel);
        if (floor == 0) try std.testing.expect(runs.actual.reclaims > 0);
        const shown = try f.values(runs.actual, p, fuel, text);
        try std.testing.expect(std.mem.indexOf(u8, shown, "\"777zz\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, shown, "garb") == null);
    }
}

test "pf2: a For in a frame pushed after the last switch grows into its room, in every task form" {
    const f = try Fixture.create();
    defer f.destroy();
    const text = try std.testing.allocator.alloc(u8, 1 << 16);
    defer std.testing.allocator.free(text);
    var buffer: [2048]u8 = undefined;
    // `{0}` is the length, `{1}` a quarter of it. Each program builds its arrays in frames
    // pushed after another task ran: a spawned function awaited by another task, a function
    // called after a sleep, a loop after a sleep, and two tasks that take turns, building
    // instances and strings while the other's frames are suspended.
    const Form = struct { []const u8 };
    const forms = [_]Form{
        .{"Build(N:i64)<transacts><suspends>:[]i64 = For(I:1..N, I*3)\nT:task([]i64) = Spawn{{ Build({0}) }}\nW()<transacts><suspends>:i64 = Block{{ Xs := T.Await(); Xs.Length + Attempt(Xs[{0}-1], 0) }}\nU:task(i64) = Spawn{{ W() }}\n# {1}"},
        .{"Build(N:i64)<computes>:[]i64 = For(I:1..N, I*3)\nRun()<transacts><suspends>:i64 = Block{{ Sleep(0.0); Xs := Build({0}); Xs.Length + Attempt(Xs[{0}-1], 0) }}\nT:task(i64) = Spawn{{ Run() }}\n# {1}"},
        .{"Run()<transacts><suspends>:i64 = Block{{ Sleep(0.0); Xs := For(I:1..{0}, I*3); Xs.Length + Attempt(Xs[{0}-1], 0) }}\nT:task(i64) = Spawn{{ Run() }}\n# {1}"},
        .{"P := class{{ N:i64, S:string }}\nRun(K:i64)<transacts><suspends>:string = Block{{ Sleep(0.0); Ps := For(I:1..{1}, P{{N := I*K, S := \"p{{I}}\"}}); Sleep(0.0); Ss := For(I:1..{0}, \"s{{I*K}}\"); Sleep(0.0); A := Attempt(Ps[{1}-1].N, 0); B := Attempt(Ps[0].S, \"\"); C := Attempt(Ss[{0}-1], \"\"); \"{{Ps.Length}} {{A}} {{B}} {{C}}\" }}\nT1:task(string) = Spawn{{ Run(1) }}\nT2:task(string) = Spawn{{ Run(2) }}"},
    };
    inline for (forms, 0..) |form, which| {
        var needed: [2]u64 = undefined;
        for ([_]u64{ 200, 400 }, &needed) |length, *least| {
            const source = try std.fmt.bufPrint(&buffer, form[0], .{ length, length / 4 });
            const p = try compileAll(f, source);
            var wanted_text: [128]u8 = undefined;
            const wanted = if (which < 3) try std.fmt.bufPrint(&wanted_text, "\"result\":{d}}}", .{4 * length}) else try std.fmt.bufPrint(&wanted_text, "\"result\":\"{d} {d} p1 s{d}\"", .{ length / 4, 2 * (length / 4), 2 * length });
            var fuels: [4]u64 = undefined;
            var index: usize = 0;
            for ([_]types.TraceMode{ .digest, .off }) |trace| for ([_]u32{ never, 0 }) |floor| {
                f.configure(trace, 7, floor);
                fuels[index] = try roomLeast(f, p);
                const runs = try f.both(p, fuels[index]);
                if (floor == 0) try std.testing.expect(runs.actual.reclaims > 0);
                if (trace == .digest) {
                    const shown = try f.values(runs.actual, p, fuels[index], text);
                    if (std.mem.indexOf(u8, shown, wanted) == null) {
                        std.debug.print("form {d} wants {s}:\n{s}\n", .{ which, wanted, shown });
                        return error.TestUnexpectedResult;
                    }
                }
                index += 1;
            };
            // One number of fuel whether and how the run reclaims.
            for (fuels[1..]) |other| try std.testing.expectEqual(fuels[0], other);
            least.* = fuels[0];
        }
        // Linear: twice the elements need about twice the fuel. Copying the accumulator at
        // every element, as every frame did once a task had run, needed four times as much.
        if (needed[1] * 10 >= needed[0] * 25 or needed[1] > (if (which == 3) 200 else 80) * 400) {
            std.debug.print("form {d}: fuel {d} for 200, {d} for 400\n", .{ which, needed[0], needed[1] });
            return error.TestUnexpectedResult;
        }
    }
}

/// The fuel of `form` at 200 and 400 (`{0}`; `{1}` is a quarter of it), the same in digest and
/// off runs, reclaiming at every chance or (if `never_too`) never, with the value report
/// holding `wanted` (`{0}` is the length) after the replay admitted it.
fn sleepingFuel(f: Fixture, comptime form: []const u8, comptime wanted: []const u8, never_too: bool) ![2]u64 {
    const text = try std.testing.allocator.alloc(u8, 1 << 16);
    defer std.testing.allocator.free(text);
    var buffer: [2048]u8 = undefined;
    var needed: [2]u64 = undefined;
    for ([_]u64{ 200, 400 }, &needed) |length, *least| {
        const p = try compileAll(f, try std.fmt.bufPrint(&buffer, form, .{ length, length / 4 }));
        var wanted_text: [128]u8 = undefined;
        const want = try std.fmt.bufPrint(&wanted_text, wanted, .{length});
        var fuels: [4]u64 = undefined;
        var index: usize = 0;
        const floors: []const u32 = if (never_too) &.{ never, 0 } else &.{ 0, 0 };
        for ([_]types.TraceMode{ .digest, .off }) |trace| for (floors) |floor| {
            f.configure(trace, 7, floor);
            fuels[index] = try leastWithin(f, p, 1 << 24);
            const runs = try f.both(p, fuels[index]);
            if (floor == 0) try std.testing.expect(runs.actual.reclaims > 0);
            if (trace == .digest) {
                const shown = try f.values(runs.actual, p, fuels[index], text);
                if (std.mem.indexOf(u8, shown, want) == null or std.mem.indexOf(u8, shown, "garb") != null) {
                    std.debug.print("wants {s}:\n{s}\n", .{ want, shown });
                    return error.TestUnexpectedResult;
                }
            }
            index += 1;
        };
        // One number of fuel whether and how the run reclaims.
        for (fuels[1..]) |other| try std.testing.expectEqual(fuels[0], other);
        least.* = fuels[0];
    }
    return needed;
}

test "w15: a For whose visits sleep grows into its room unless another task holds suspended frames" {
    const f = try Fixture.create();
    defer f.destroy();
    // A `For` whose every visit waits: its frame has seen a switch at every join after the
    // first. Alone in the run, no frame of another task is suspended at its joins, so it
    // grows into its room: integers, strings made in the visit, instances, and a wait inside
    // a function the body calls. Short tasks that make garbage and end between its visits
    // change nothing. Two such loops in two tasks: integers, which name nothing a reclamation
    // could free, grow into their rooms too.
    const Form = struct { []const u8, []const u8, bool };
    const forms = [_]Form{
        .{ "Run()<transacts><suspends>:i64 = Block{{ Xs := For(I:1..{0}, Block{{ Sleep(0.0); I*3 }}); Attempt(Xs[{0}-1], 0) - 2 * Xs.Length }}\nT:task(i64) = Spawn{{ Run() }}\n# {1}", "\"result\":{d}}}", true },
        .{ "Wait(I:i64)<transacts><suspends>:i64 = Block{{ Sleep(0.0); I }}\nRun()<transacts><suspends>:string = Block{{ Ss := For(I:1..{0}, Block{{ J := Wait(I); \"s{{J}}\" }}); \"{{Ss.Length}} {{Attempt(Ss[{0}-1], \"\")}}\" }}\nT:task(string) = Spawn{{ Run() }}\n# {1}", "\"result\":\"{d} s", true },
        .{ "P := class{{ N:i64, S:string }}\nRun()<transacts><suspends>:string = Block{{ Ps := For(I:1..{1}, Block{{ Sleep(0.0); P{{N := I, S := \"p{{I}}\"}} }}); \"{{Ps.Length * 4}} {{Attempt(Ps[{1}-1].S, \"\")}}\" }}\nT:task(string) = Spawn{{ Run() }}\n# {0}", "\"result\":\"{d} p", true },
        .{ "Junk(N:i64)<computes>:i64 = Block{{ G := ToString(N) + \"garbagegarbage\"; H := G + \"more\"; H.Length }}\nRun()<transacts><suspends>:string = Block{{ Ss := For(I:1..{1}, Block{{ T := Spawn{{ Junk(I) }}; Sleep(0.0); \"s{{I}}\" }}); \"{{Ss.Length * 4}} {{Attempt(Ss[{1}-1], \"\")}}\" }}\nT:task(string) = Spawn{{ Run() }}\n# {0}", "\"result\":\"{d} s", true },
        .{ "Run(K:i64)<transacts><suspends>:i64 = Block{{ Xs := For(I:1..{0}, Block{{ Sleep(0.0); I*K }}); Attempt(Xs[{0}-1], 0) - 2 * Xs.Length }}\nT1:task(i64) = Spawn{{ Run(3) }}\nT2:task(i64) = Spawn{{ Run(3) }}\n# {1}", "\"result\":{d}}}", true },
        .{ "Wait(I:i64)<transacts><suspends>:i64 = Block{{ Sleep(0.0); I }}\nRun(K:i64)<transacts><suspends>:i64 = Block{{ Xs := For(I:1..{0}, Block{{ J := Wait(I); J*K }}); Attempt(Xs[{0}-1], 0) - 2 * Xs.Length }}\nT1:task(i64) = Spawn{{ Run(3) }}\nT2:task(i64) = Spawn{{ Run(3) }}\n# {1}", "\"result\":{d}}}", true },
        // Two loops of strings: the other task's suspended frames reclaim above marks of their
        // own, above the room, so each copies, as before (RFC-0055, "Rooms", the third
        // condition). Its values stay right.
        .{ "Run(K:i64)<transacts><suspends>:string = Block{{ Ss := For(I:1..{1}, Block{{ Sleep(0.0); \"s{{I*K}}\" }}); \"{{Ss.Length * 4}} {{Attempt(Ss[{1}-1], \"\")}}\" }}\nT1:task(string) = Spawn{{ Run(1) }}\nT2:task(string) = Spawn{{ Run(1) }}\n# {0}", "\"result\":\"{d} s", false },
    };
    inline for (forms, 0..) |form, which| {
        // A loop that copies at every element holds the square of its length in a run that
        // never reclaims, more than the `bootstrap` pool.
        const needed = try sleepingFuel(f, form[0], form[1], form[2]);
        std.debug.print("w15 sleeping For form {d}: fuel {d} for 200, {d} for 400\n", .{ which, needed[0], needed[1] });
        // Linear: twice the elements need about twice the fuel; copying at every element needs
        // four times as much.
        if (form[2] and needed[1] * 10 >= needed[0] * 25) return error.TestUnexpectedResult;
    }
}

/// Random programs of one to three tasks, each building an array with a `For` whose visits wait
/// (directly, deep in frames that sleep, or not at all) while short tasks and tasks that sleep
/// come and go: integers, strings made in the visit, instances, arrays of arrays, strings made
/// before the loop, and floats. The joins of such a `For` take every path of
/// `array_concat.contextOf`.
const SleepingForGenerator = struct {
    rng: std.Random,
    text: std.ArrayList(u8) = .empty,
    names: u32 = 0,

    const prelude =
        \\Box := class{ N:i64, Name:string }
        \\Deep(D:i64)<transacts><suspends>:i64 = If(D <= 0, Block{ Sleep(0.0); D }, Block{ Mine := "d{D}"; R := Deep(D - 1); Mine.Length + R })
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbagegarbage"; H := G + "more"; H.Length }
        \\Nap(N:i64)<transacts><suspends>:i64 = Block{ J := "nap {N}"; Sleep(0.0); K := J + "garbage"; Sleep(0.0); K.Length }
        \\
    ;
    const Element = struct { type: []const u8, value: []const u8 };
    const elements = [_]Element{
        .{ .type = "i64", .value = "I * {d}" },
        .{ .type = "string", .value = "\"e{{I}} {d}\"" },
        .{ .type = "Box", .value = "Box{{ N := I + {d}, Name := \"b{{I}}\" }}" },
        .{ .type = "[]i64", .value = "array{{I, {d}}}" },
        .{ .type = "string", .value = "Before{d}" },
        .{ .type = "float", .value = "1.0 / {d}.0" },
    };

    fn add(self: *SleepingForGenerator, comptime format: []const u8, arguments: anytype) !void {
        try self.text.print(std.testing.allocator, format, arguments);
    }
    fn statement(self: *SleepingForGenerator) !void {
        const name = self.names;
        self.names += 1;
        switch (self.rng.intRangeLessThan(u8, 0, 8)) {
            0, 1 => try self.add("Sleep(0.0); ", .{}),
            2 => try self.add("Sleep({d}.0 / 60.0); ", .{self.rng.intRangeLessThan(u8, 1, 4)}),
            3 => try self.add("Q{d} := Deep({d}); ", .{ name, self.rng.intRangeLessThan(u8, 0, 3) }),
            4 => try self.add("S{d} := \"junk {{I}}\" + \"x\"; ", .{name}),
            5 => try self.add("U{d} := Spawn{{ Junk(I) }}; ", .{name}),
            6 => try self.add("V{d} := Spawn{{ Nap(I) }}; ", .{name}),
            else => try self.add("A{d} := array{{I, I}}; ", .{name}),
        }
    }
    fn program(self: *SleepingForGenerator) ![]const u8 {
        self.text.clearRetainingCapacity();
        self.names = 0;
        try self.text.appendSlice(std.testing.allocator, prelude);
        const tasks = self.rng.intRangeLessThan(u8, 1, 4);
        var kinds: [3]usize = undefined;
        for (kinds[0..tasks], 0..) |*kind, task| {
            kind.* = self.rng.uintLessThan(usize, elements.len);
            const element = elements[kind.*];
            const c = self.rng.intRangeLessThan(u8, 1, 9);
            try self.add("Work{d}(N:i64)<transacts><suspends>:[]{s} = Block{{\n    Before{d} := \"before {{N}}\"\n    Sleep({d}.0 / 60.0)\n    Xs := For(I:1..{d}, Block{{ ", .{ task, element.type, c, self.rng.intRangeLessThan(u8, 0, 3), self.rng.intRangeLessThan(u8, 1, 40) });
            for (0..self.rng.intRangeLessThan(u8, 0, 4)) |_| try self.statement();
            switch (kind.*) {
                inline 0...elements.len - 1 => |which| try self.add(elements[which].value, .{c}),
                else => unreachable,
            }
            try self.add(" }})\n    Xs\n}}\n", .{});
        }
        for (kinds[0..tasks], 0..) |kind, task| try self.add("T{d}:task([]{s}) = Spawn{{ Work{d}({d}) }}\n", .{ task, elements[kind].type, task, task + 1 });
        return self.text.items;
    }
};

test "w15: random sleeping For programs: both machines, the replay and runs that reclaim at floor 0, at a random floor and never agree, fuel included" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    var random = std.Random.DefaultPrng.init(0x7731_3520_666f_72);
    var generator: SleepingForGenerator = .{ .rng = random.random() };
    defer generator.text.deinit(std.testing.allocator);
    var reclaims: u64 = 0;
    for (0..60) |_| {
        const source = try generator.program();
        const p = compileAll(f, source) catch |problem| {
            std.debug.print("does not compile:\n{s}\n", .{source});
            return problem;
        };
        // The stored run, which never reclaims, against digest and off runs that reclaim at
        // every chance or at a random floor: one report and one number of fuel.
        f.configure(.full, types.ControlStorage.default_trace_window, never);
        const least = leastWithin(f, p, task_fuel) catch |problem| {
            std.debug.print("full:\n{s}\n", .{source});
            return problem;
        };
        const stored = switch (try f.inner.h.run(p, least)) {
            .ok => |x| x,
            .failed => |diagnostic| {
                std.debug.print("{t}:\n{s}\n", .{ diagnostic.code, source });
                return error.TestUnexpectedResult;
            },
        };
        var out = std.Io.Writer.fixed(plain);
        _ = try reporting.write(&out, stored, false, .{});
        const expected = try Stored.of(stored, out.buffered());
        defer expected.destroy();
        for ([_]types.TraceMode{ .digest, .off }, [_]u32{ 0, generator.rng.intRangeLessThan(u32, 0, 64) }) |trace, floor| {
            f.configure(trace, generator.rng.intRangeLessThan(u32, 1, 40), floor);
            const fuel_here = leastWithin(f, p, task_fuel) catch |problem| {
                std.debug.print("{t} floor {d}:\n{s}\n", .{ trace, floor, source });
                return problem;
            };
            if (fuel_here != least) {
                std.debug.print("{t} floor {d}: fuel {d}, stored {d}:\n{s}\n", .{ trace, floor, fuel_here, least, source });
                return error.TestUnexpectedResult;
            }
            const runs = try f.both(p, least);
            try std.testing.expectEqualDeep(stored.scheduler, runs.actual.scheduler);
            reclaims += runs.actual.reclaims;
            if (trace == .off) continue;
            var into = std.Io.Writer.fixed(other);
            _ = reporting.writeReplayed(&into, runs.actual, f.inner.again.producer(p, least), false, .{ .work = 1 << 26 }) catch |problem| {
                std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
                return problem;
            };
            expected.expect(into.buffered(), runs.actual) catch |problem| {
                std.debug.print("floor {d}:\n{s}\n", .{ floor, source });
                return problem;
            };
        }
    }
    try std.testing.expect(reclaims > 100);
}

/// Runs `source` stored (`full`, never reclaiming) and in digest and off runs at reclamation
/// floors 0, 1, 5, 40 and never, with windows 1 and 7: the same least fuel everywhere, both
/// machines agreeing on the whole pool, and the replay admitting each machine's digest run with
/// the stored run's report, which holds `wanted`. From the independent review of w15.
fn everyFloor(f: Fixture, name: []const u8, source: []const u8, wanted: []const u8, plain: []u8, other: []u8) !void {
    const p = compileAll(f, source) catch |problem| {
        std.debug.print("{s}: does not compile:\n{s}\n", .{ name, source });
        return problem;
    };
    f.configure(.full, types.ControlStorage.default_trace_window, never);
    const least = leastWithin(f, p, task_fuel) catch |problem| {
        std.debug.print("{s}: full run fails at every fuel\n", .{name});
        return problem;
    };
    const stored = switch (try f.inner.h.run(p, least)) {
        .ok => |x| x,
        .failed => |diagnostic| {
            std.debug.print("{s}: {t}\n", .{ name, diagnostic.code });
            return error.TestUnexpectedResult;
        },
    };
    var out = std.Io.Writer.fixed(plain);
    _ = try reporting.write(&out, stored, false, .{});
    if (std.mem.indexOf(u8, out.buffered(), wanted) == null) {
        std.debug.print("{s}: wants {s}:\n{s}\n", .{ name, wanted, out.buffered() });
        return error.TestUnexpectedResult;
    }
    const expected = try Stored.of(stored, out.buffered());
    defer expected.destroy();
    var reclaims: u64 = 0;
    for ([_]types.TraceMode{ .digest, .off }) |trace| for ([_]u32{ 0, 1, 5, 40, never }) |floor| for ([_]u32{ 1, 7 }) |window| {
        f.configure(trace, window, floor);
        const here = leastWithin(f, p, task_fuel) catch |problem| {
            std.debug.print("{s}: {t} floor {d} window {d} fails\n", .{ name, trace, floor, window });
            return problem;
        };
        if (here != least) {
            std.debug.print("{s}: {t} floor {d} window {d}: fuel {d}, stored {d}\n", .{ name, trace, floor, window, here, least });
            return error.TestUnexpectedResult;
        }
        const runs = try f.both(p, least);
        try std.testing.expectEqualDeep(stored.scheduler, runs.actual.scheduler);
        reclaims += runs.actual.reclaims;
        if (trace == .off) continue;
        var into = std.Io.Writer.fixed(other);
        _ = reporting.writeReplayed(&into, runs.actual, f.inner.again.producer(p, least), false, .{ .work = 1 << 26 }) catch |problem| {
            std.debug.print("{s}: replay of vm refused at floor {d} window {d}: {t}\n", .{ name, floor, window, problem });
            return problem;
        };
        expected.expect(into.buffered(), runs.actual) catch |problem| {
            std.debug.print("{s}: vm report differs at floor {d} window {d}:\n{s}\n", .{ name, floor, window, into.buffered() });
            return problem;
        };
        into = std.Io.Writer.fixed(other);
        _ = reporting.writeReplayed(&into, runs.reference, f.inner.again.producer(p, least), false, .{ .work = 1 << 26 }) catch |problem| {
            std.debug.print("{s}: replay of reference refused at floor {d} window {d}: {t}\n", .{ name, floor, window, problem });
            return problem;
        };
        expected.expect(into.buffered(), runs.reference) catch |problem| {
            std.debug.print("{s}: reference report differs at floor {d} window {d}\n", .{ name, floor, window });
            return problem;
        };
    };
    try std.testing.expect(reclaims > 0);
}

/// Joins after a task switch at the root and in every concurrency form, each with the text its
/// report must hold.
const Probe = struct { []const u8, []const u8, []const u8 };
const switched_joins = [_]Probe{
    // The root joins after a switch, with no task suspended: strings into rooms.
    .{
        "root-sync-strings",
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbagegarbage"; H := G + "more"; H.Length }
        \\T0:task(i64) = Spawn{ Junk(1) }
        \\B:[]string = array{ToString(5) + "b"}
        \\A0:[]string = array{ToString(1) + "a"}
        \\P0:[]i64 = array{0}
        \\A1:[]string = A0 + B
        \\P1:[]i64 = array{1}
        \\A2:[]string = A1 + B
        \\P2:[]i64 = array{2}
        \\A3:[]string = A2 + B
        \\P3:[]i64 = array{3}
        \\A4:[]string = A3 + B
        \\P4:[]i64 = array{4}
        \\A5:[]string = A4 + B
        \\N:string = "{A5.Length} {Attempt(A5[5], "")}"
        ,
        "\"N\":\"6 5b\"",
    },
    // The root joins integers after a task suspended (inert path at the root).
    .{
        "root-suspended-ints",
        \\Slow()<transacts><suspends>:i64 = Block{ Mine := "slow" + ToString(3); Sleep(0.0); J := Mine + "more"; J.Length }
        \\T0:task(i64) = Spawn{ Slow() }
        \\B:[]i64 = array{5}
        \\A0:[]i64 = array{1}
        \\P0:[]string = array{"x"}
        \\A1:[]i64 = A0 + B
        \\P1:[]string = array{"y"}
        \\A2:[]i64 = A1 + B
        \\P2:[]string = array{"z"}
        \\A3:[]i64 = A2 + B
        \\P3:[]string = array{"w"}
        \\A4:[]i64 = A3 + B
        \\P4:[]string = array{"v"}
        \\A5:[]i64 = A4 + B
        \\N:i64 = A5.Length * 100 + Attempt(A5[5], 0)
        ,
        "\"N\":605",
    },
    // The root joins strings after a task suspended: exposed, so it copies.
    .{
        "root-suspended-strings-captured",
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbagegarbage"; H := G + "more"; H.Length }
        \\Use(Xs:[]string)<transacts><suspends>:string = Block{ Sleep(0.0); J := Junk(3); Ys := For(I:1..30, Block{ Sleep(0.0); K := Junk(I); "u{I}" }); "{Xs.Length} {Attempt(Xs[5], "")} {Ys.Length} {Attempt(Ys[29], "")}" }
        \\Slow()<transacts><suspends>:i64 = Block{ Mine := "slow" + ToString(3); Sleep(0.0); J := Mine + "more"; J.Length }
        \\T0:task(i64) = Spawn{ Slow() }
        \\B:[]string = array{ToString(5) + "b"}
        \\A0:[]string = array{ToString(1) + "a"}
        \\P0:[]i64 = array{0}
        \\A1:[]string = A0 + B
        \\P1:[]i64 = array{1}
        \\A2:[]string = A1 + B
        \\P2:[]i64 = array{2}
        \\A3:[]string = A2 + B
        \\P3:[]i64 = array{3}
        \\A4:[]string = A3 + B
        \\P4:[]i64 = array{4}
        \\A5:[]string = A4 + B
        \\T1:task(string) = Spawn{ Use(A5) }
        \\Q:[]string = A5 + array{ToString(7) + "q"}
        ,
        "\"result\":\"6 5b 30 u30\"",
    },
    // A synchronous task captures the root's array, which then grows into its room.
    .{
        "root-sync-captured",
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbagegarbage"; H := G + "more"; H.Length }
        \\Use(Xs:[]string)<transacts><suspends>:string = Block{ Sleep(0.0); J := Junk(3); Ys := For(I:1..30, Block{ Sleep(0.0); K := Junk(I); "u{I}" }); "{Xs.Length} {Attempt(Xs[3], "")} {Ys.Length} {Attempt(Ys[29], "")}" }
        \\T0:task(i64) = Spawn{ Junk(1) }
        \\B:[]string = array{ToString(5) + "b"}
        \\A0:[]string = array{ToString(1) + "a"}
        \\P0:[]i64 = array{0}
        \\A1:[]string = A0 + B
        \\P1:[]i64 = array{1}
        \\A2:[]string = A1 + B
        \\P2:[]i64 = array{2}
        \\A3:[]string = A2 + B
        \\T1:task(string) = Spawn{ Use(A3) }
        \\P3:[]i64 = array{3}
        \\A4:[]string = A3 + B
        \\P4:[]i64 = array{4}
        \\A5:[]string = A4 + B
        \\N:string = "{A5.Length} {Attempt(A5[5], "")}"
        ,
        "\"result\":\"4 5b 30 u30\"",
    },
    // Sync arms in every visit of a For in a task.
    .{
        "sync-arms",
        \\Run()<transacts><suspends>:string = Block{ Ss := For(I:1..40, Block{ P := Sync(Block{ Sleep(0.0); "a{I}" }, Block{ Sleep(0.0); "b{I}" }); P(0) + P(1) }); "{Ss.Length} {Attempt(Ss[39], "")}" }
        \\T:task(string) = Spawn{ Run() }
        ,
        "\"result\":\"40 a40b40\"",
    },
    // Race arms: the loser sleeps longer and is cancelled.
    .{
        "race-arms",
        \\Run()<transacts><suspends>:string = Block{ Ss := For(I:1..40, Block{ R := Race(Block{ Sleep(0.0); "a{I}" }, Block{ Sleep(1.0); "b{I}" }); R + "!" }); "{Ss.Length} {Attempt(Ss[39], "")}" }
        \\T:task(string) = Spawn{ Run() }
        ,
        "\"result\":\"40 a40!\"",
    },
    // Branch in every visit.
    .{
        "branch",
        \\var Out:i64 = 0
        \\Run()<transacts><suspends>:string = Block{ Ss := For(I:1..40, Block{ Branch{ Sleep(0.0); Set(Out, Out + 1) }; Sleep(0.0); "s{I}" + ToString(Out) }); "{Ss.Length} {Attempt(Ss[39], "")}" }
        \\T:task(string) = Spawn{ Run() }
        ,
        "\"result\":\"40 s40",
    },
    // A task spawned and awaited in every visit.
    .{
        "await-task",
        \\Make(I:i64)<transacts><suspends>:string = Block{ Sleep(0.0); "m{I}" + "x" }
        \\Run()<transacts><suspends>:string = Block{ Ss := For(I:1..40, Block{ T := Spawn{ Make(I) }; S := T.Await(); S + "!" }); "{Ss.Length} {Attempt(Ss[39], "")}" }
        \\T:task(string) = Spawn{ Run() }
        ,
        "\"result\":\"40 m40x!\"",
    },
    // A sleeping task spawned and cancelled in every visit.
    .{
        "cancel",
        \\Nap(I:i64)<transacts><suspends>:i64 = Block{ S := "nap{I}"; Sleep(5.0); S.Length }
        \\Run()<transacts><suspends>:string = Block{ Ss := For(I:1..40, Block{ T := Spawn{ Nap(I) }; Sleep(0.0); T.Cancel(); Sleep(0.0); "c{I}" + "y" }); "{Ss.Length} {Attempt(Ss[39], "")}" }
        \\T:task(string) = Spawn{ Run() }
        ,
        "\"result\":\"40 c40y\"",
    },
    // An Await on a module var another task sets.
    .{
        "await-guard",
        \\var X:i64 = 0
        \\Waiter()<transacts><suspends>:string = Block{ Ss := For(I:1..30, Block{ Await(X >= I); "w{I}" + "z" }); "{Ss.Length} {Attempt(Ss[29], "")}" }
        \\Setter()<transacts><suspends>:i64 = Block{ Xs := For(I:1..30, Block{ Sleep(0.0); set X = I; I }); Xs.Length }
        \\A:task(string) = Spawn{ Waiter() }
        \\B:task(i64) = Spawn{ Setter() }
        ,
        "\"result\":\"30 w30z\"",
    },
    // A reaction to a module var the loop writes.
    .{
        "when",
        \\var X:i64 = 0
        \\var Seen:i64 = 0
        \\Watch:task(void) = When(X, Set(Seen, Seen + 1))
        \\Run()<transacts><suspends>:string = Block{ Ss := For(I:1..30, Block{ set X = I; Sleep(0.0); "r{I} {Seen}" }); "{Ss.Length} {Attempt(Ss[29], "")}" }
        \\T:task(string) = Spawn{ Run() }
        ,
        "\"result\":\"30 r30",
    },
    // A task handed off on top of its spawner, whose For sees a switch at every visit (a short
    // task) and grows strings into its room while its spawner's frames are on the stack below.
    .{
        "handoff-on-spawner",
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbagegarbage"; H := G + "more"; H.Length }
        \\Inner()<transacts><suspends>:[]string = For(I:1..60, Block{ U := Spawn{ Junk(I) }; "s{I}" + "x" })
        \\Outer()<transacts><suspends>:string = Block{ Sleep(0.0); Mine := "o" + ToString(1); T := Spawn{ Inner() }; Xs := T.Await(); J := Junk(9); "{Mine} {Xs.Length} {Attempt(Xs[59], "")} {Attempt(Xs[0], "")}" }
        \\T:task(string) = Spawn{ Outer() }
        ,
        "\"result\":\"o1 60 s60x s1x\"",
    },
    // Two tasks: one grows strings after short tasks while the other sleeps (exposed), then alone.
    .{
        "two-tasks-mixed",
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbagegarbage"; H := G + "more"; H.Length }
        \\A()<transacts><suspends>:string = Block{ Ss := For(I:1..60, Block{ U := Spawn{ Junk(I) }; If(I < 20, Block{ Sleep(0.0); 0 }, 0); "a{I}" + "x" }); "{Ss.Length} {Attempt(Ss[59], "")}" }
        \\B()<transacts><suspends>:string = Block{ Ss := For(I:1..10, Block{ Sleep(0.0); M := "b{I}"; M + "y" }); "{Ss.Length} {Attempt(Ss[9], "")}" }
        \\T1:task(string) = Spawn{ A() }
        \\T2:task(string) = Spawn{ B() }
        ,
        "\"result\":\"60 a60x\"",
    },
};

// I14-D6: the evaluations of dead live locals cost the same fuel in every trace mode.
test "w15: dead live locals cost the same fuel in full, digest and off runs" {
    const f = try Fixture.create();
    defer f.destroy();
    var buffer: [512]u8 = undefined;
    for ([_]u64{ 10, 20, 40 }) |n| {
        const p = try compileAll(f, try std.fmt.bufPrint(&buffer, "var M:i64 = 0\nVisit(I:i64)<transacts>:i64 = Block{{ var live L:i64 = M + I; set M = M + 1; L }}\nXs:[]i64 = For(I:1..{d}, Visit(I))\nN:i64 = Xs.Length", .{n}));
        var fuels: [3]u64 = undefined;
        for ([_]types.TraceMode{ .full, .digest, .off }, &fuels) |trace, *least| {
            f.configure(trace, 7, if (trace == .full) never else 0);
            least.* = try leastWithin(f, p, task_fuel);
        }
        try std.testing.expectEqual(fuels[0], fuels[1]);
        try std.testing.expectEqual(fuels[0], fuels[2]);
    }
}

test "w15: joins after a switch at the root, in Sync, Race, Branch, Await, Cancel and When arms and a handoff agree at every floor" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    var failed: usize = 0;
    inline for (switched_joins) |probe| {
        everyFloor(f, probe[0], probe[1], probe[2], plain, other) catch |problem| {
            std.debug.print("{s} FAILED: {t}\n", .{ probe[0], problem });
            failed += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

/// c7-1: the least fuel of `source` stored (`full`, which never reclaims), and the same in
/// `digest` and `off` runs at floors 0, 1, 5, 40, `floor` and never and windows 1 and 7: a `+`
/// extends its left string only when no run would have made a string after it, so a
/// reclamation that frees what was made later changes no charge. Short of that fuel, every run
/// stops at the stored run's node; at it, both machines agree, and the replay of either
/// reports the stored run. Returns whether any run reclaimed strings.
fn c71Check(f: Fixture, source: []const u8, floor: u32, plain: []u8, other: []u8) !bool {
    const p = try compileAll(f, source);
    f.configure(.full, types.ControlStorage.default_trace_window, never);
    const least = try leastWithin(f, p, task_fuel);
    const short = (try f.outcome(p, least / 2)) orelse return error.TestUnexpectedResult;
    const stored = (try f.inner.h.run(p, least)).ok;
    var out = std.Io.Writer.fixed(plain);
    _ = try reporting.write(&out, stored, false, .{});
    const expected = try Stored.of(stored, out.buffered());
    defer expected.destroy();
    var reclaimed = false;
    for ([_]types.TraceMode{ .digest, .off }) |trace| for ([_]u32{ 0, 1, 5, 40, floor, never }) |at| for ([_]u32{ 1, 7 }) |window| {
        f.configure(trace, window, at);
        const here = try leastWithin(f, p, task_fuel);
        if (here != least) {
            std.debug.print("c7-1: {t} floor {d} window {d} needs {d}, stored {d}:\n{s}\n", .{ trace, at, window, here, least, source });
            return error.TestUnexpectedResult;
        }
        const stopped = (try f.outcome(p, least / 2)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(short.code, stopped.code);
        try std.testing.expectEqual(short.span, stopped.span);
        const runs = try f.both(p, least);
        if (runs.actual.reclaims != 0 and f.inner.h.control.reclaimed_bytes != 0) reclaimed = true;
        if (trace == .off) continue;
        for ([_]evaluator.Execution{ runs.actual, runs.reference }) |run| {
            var into = std.Io.Writer.fixed(other);
            _ = try reporting.writeReplayed(&into, run, f.inner.again.producer(p, least), false, .{ .work = 1 << 26 });
            try expected.expect(into.buffered(), run);
        }
    };
    return reclaimed;
}

test "c7-1: a reclamation changes no string join's fuel: one least fuel, and one place to stop short of it, at every floor and trace mode" {
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    // The review's case: `Junk`'s strings are made after `S` and are garbage when `S + "tail"`
    // runs; a run that reclaims them used to find `S` at the tail and extend it, for less fuel.
    try std.testing.expect(try c71Check(f,
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbagegarbagegarbage"; H := G + "more"; H.Length }
        \\Run(N:i64)<computes>:i64 = Block{ S := "s" + ToString(N) + "0123456789012345678901234567890123456789"; J := Junk(N); T := S + "tail"; T.Length + J }
        \\Xs:[]i64 = For(I:1..200, Run(I))
    , 3, plain, other));
    // An accumulator still grows in place after a reclamation that keeps it newest, and after
    // its first copy past one that did not; a task's string made before a sleep, joined after.
    try std.testing.expect(try c71Check(f,
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbage"; G.Length }
        \\Step(S:string)<computes>:string = Block{ J := Junk(S.Length); T := S + "ab"; If(J > 100, T + "!", T) }
        \\Grown:string = Iterate(Step, 150, "x")
        \\Nap(N:i64)<transacts><suspends>:i64 = Block{ J := "nap {N}"; Sleep(0.0); K := J + "garbage"; Sleep(0.0); K.Length }
        \\Work(N:i64)<transacts><suspends>:[]i64 = For(I:1..30, Block{ T := Spawn{ Nap(I) }; Junk(I) + T.Await() })
        \\A:task([]i64) = Spawn{ Work(1) }
        \\B:task([]i64) = Spawn{ Work(2) }
        \\Length<public>:i64 = Grown.Length
    , 9, plain, other));
}

/// c7-1: the review's generator of task programs that build strings and arrays in loops whose
/// visits sleep, spawn, race and cancel, with garbage strings made between joins.
const C71Generator = struct {
    rng: std.Random,
    text: std.ArrayList(u8) = .empty,
    names: u32 = 0,

    const prelude =
        \\Box := class{ N:i64, Name:string }
        \\mode := enum{ Light, Dark }
        \\var X:i64 = 0
        \\var Out:i64 = 0
        \\var Seen:i64 = 0
        \\var Keep:[]string = array{}
        \\Deep(D:i64)<transacts><suspends>:i64 = If(D <= 0, Block{ Sleep(0.0); D }, Block{ Mine := "d{D}"; R := Deep(D - 1); Mine.Length + R })
        \\Junk(N:i64)<computes>:i64 = Block{ G := ToString(N) + "garbagegarbage"; H := G + "more"; H.Length }
        \\Nap(N:i64)<transacts><suspends>:i64 = Block{ J := "nap {N}"; Sleep(0.0); K := J + "garbage"; Sleep(0.0); K.Length }
        \\Long(N:i64)<transacts><suspends>:i64 = Block{ J := "long {N}"; Sleep(2.0); K := J + "garbage"; K.Length }
        \\Make(I:i64)<transacts><suspends>:string = Block{ G := "mk{I}" + "garbage"; Sleep(0.0); "m{I}" + "x" }
        \\Grow(N:i64)<transacts><suspends>:[]string = For(I:1..N, Block{ Sleep(0.0); "g{I}" + "y" })
        \\Rat(A:i64)<computes>:rational = Attempt(Rational[A, 3], MakeRationalFromInt(0))
        \\Append(Xs:[]string, I:i64)<transacts><suspends>:[]string = Block{ Sleep(0.0); Xs + array{"ap{I}"} }
        \\Mk(I:i64)<computes>:function(tuple(i64),i64) = Fn(Z:i64){Z + I + 3}
        \\Fixed:function(tuple(i64),i64) = Mk(7)
        \\
    ;
    const Element = struct { type: []const u8, value: []const u8 };
    const elements = [_]Element{
        .{ .type = "i64", .value = "I * {d}" },
        .{ .type = "string", .value = "\"e{{I}} {d}\"" },
        .{ .type = "Box", .value = "Box{{ N := I + {d}, Name := \"b{{I}}\" }}" },
        .{ .type = "[]i64", .value = "array{{I, {d}}}" },
        .{ .type = "string", .value = "Before{d}" },
        .{ .type = "float", .value = "1.0 / {d}.0" },
        .{ .type = "mode", .value = "If(I > {d}, mode.Light, mode.Dark)" },
        .{ .type = "rational", .value = "Rat(I + {d})" },
        .{ .type = "string", .value = "Make(I + {d})" },
        .{ .type = "[]string", .value = "Grow(1 + {d} / 4)" },
        .{ .type = "tuple(i64,string)", .value = "tuple{{I, \"t{{I}} {d}\"}}" },
        .{ .type = "function(tuple(i64),i64)", .value = "Mk(I + {d})" },
        .{ .type = "function(tuple(i64),i64)", .value = "If(I > {d}, Fixed, Mk(0))" },
        .{ .type = "option(string)", .value = "If(I > {d}, option{{\"o{{I}}\" + \"p\"}}, option{{}})" },
        .{ .type = "string", .value = "Attempt(Keep[0], \"k{d}\")" },
    };
    fn stringy(kind: usize) bool {
        return kind == 1 or kind == 4 or kind == 8 or kind == 14;
    }

    fn add(self: *C71Generator, comptime format: []const u8, arguments: anytype) !void {
        try self.text.print(std.testing.allocator, format, arguments);
    }
    fn statement(self: *C71Generator) !void {
        const name = self.names;
        self.names += 1;
        switch (self.rng.intRangeLessThan(u8, 0, 16)) {
            0, 1 => try self.add("Sleep(0.0); ", .{}),
            2 => try self.add("Sleep({d}.0 / 60.0); ", .{self.rng.intRangeLessThan(u8, 1, 4)}),
            3 => try self.add("Q{d} := Deep({d}); ", .{ name, self.rng.intRangeLessThan(u8, 0, 3) }),
            4 => try self.add("S{d} := \"junk {{I}}\" + \"x\"; ", .{name}),
            5 => try self.add("U{d} := Spawn{{ Junk(I) }}; ", .{name}),
            6 => try self.add("V{d} := Spawn{{ Nap(I) }}; ", .{name}),
            7 => try self.add("P{d} := Sync(Block{{ Sleep(0.0); \"a{{I}}\" + \"q\" }}, Block{{ Sleep(0.0); \"b{{I}}\" }}); ", .{name}),
            8 => try self.add("R{d} := Race(Block{{ Sleep(0.0); \"a{{I}}\" + \"r\" }}, Block{{ Sleep(1.0); \"b{{I}}\" }}); ", .{name}),
            9 => try self.add("Branch{{ Sleep(0.0); Set(Out, Out + 1) }}; ", .{}),
            10 => try self.add("T{d} := Spawn{{ Make(I) }}; W{d} := T{d}.Await(); ", .{ name, name, name }),
            11 => try self.add("C{d} := Spawn{{ Long(I) }}; Sleep(0.0); C{d}.Cancel(); ", .{ name, name }),
            12 => try self.add("set X = X + 1; ", .{}),
            13 => try self.add("L{d} := Spawn{{ Long(I) }}; ", .{name}),
            14 => try self.add("set Keep = Keep + array{{\"kp{{I}}\" + \"z\"}}; ", .{}),
            else => try self.add("A{d} := array{{I, I}}; ", .{name}),
        }
    }
    fn program(self: *C71Generator) ![]const u8 {
        self.text.clearRetainingCapacity();
        self.names = 0;
        try self.text.appendSlice(std.testing.allocator, prelude);
        if (self.rng.boolean()) try self.add("Watch:task(void) = When(X, Block{{ M := \"seen{{X}}\" + \"w\"; set Keep = Keep + array{{M}}; Set(Seen, Seen + 1) }})\n", .{});
        const tasks = self.rng.intRangeLessThan(u8, 1, 4);
        var kinds: [3]usize = undefined;
        for (kinds[0..tasks], 0..) |*kind, task| {
            kind.* = self.rng.uintLessThan(usize, elements.len);
            const element = elements[kind.*];
            const c = self.rng.intRangeLessThan(u8, 1, 9);
            const count = self.rng.intRangeLessThan(u8, 1, 30);
            try self.add("Work{d}(N:i64)<transacts><suspends>:[]{s} = Block{{\n    Before{d} := \"before {{N}}\"\n    Sleep({d}.0 / 60.0)\n    Xs := For(I:1..{d}, Block{{ ", .{ task, element.type, c, self.rng.intRangeLessThan(u8, 0, 3), count });
            for (0..self.rng.intRangeLessThan(u8, 0, 4)) |_| try self.statement();
            switch (kind.*) {
                inline 0...elements.len - 1 => |which| try self.add(elements[which].value, .{c}),
                else => unreachable,
            }
            try self.add(" }})\n", .{});
            if (stringy(kind.*)) {
                // Joins in the frame after the loop: the accumulator grows into its room after
                // more switches, with strings made in this frame.
                const extra = self.rng.intRangeLessThan(u8, 0, 4);
                for (0..extra) |index| {
                    if (self.rng.boolean()) try self.add("    Sleep(0.0)\n", .{});
                    if (self.rng.boolean()) try self.add("    Z{d} := Spawn{{ Nap({d}) }}\n", .{ index, index });
                    if (index == 0) {
                        try self.add("    Pad0 := array{{0}}\n    Xs0 := Xs + array{{ToString(0) + \"after\"}}\n", .{});
                    } else try self.add("    Pad{d} := array{{{d}}}\n    Xs{d} := Xs{d} + array{{ToString({d}) + \"after\"}}\n", .{ index, index, index, index - 1, index });
                }
                if (extra == 0) try self.add("    Xs\n}}\n", .{}) else if (self.rng.uintLessThan(u8, 3) == 0) try self.add("    Append(Xs{d}, N)\n}}\n", .{extra - 1}) else try self.add("    Xs{d}\n}}\n", .{extra - 1});
            } else try self.add("    Xs\n}}\n", .{});
        }
        for (kinds[0..tasks], 0..) |kind, task| try self.add("T{d}:task([]{s}) = Spawn{{ Work{d}({d}) }}\n", .{ task, elements[kind].type, task, task + 1 });
        // Root joins after the spawns: strings into rooms, with tasks perhaps suspended.
        if (self.rng.boolean()) {
            try self.add("RB:[]string = array{{ToString(5) + \"b\"}}\nR0:[]string = array{{ToString(1) + \"a\"}}\n", .{});
            const n = self.rng.intRangeLessThan(u8, 2, 6);
            for (1..n) |index| try self.add("RP{d}:[]i64 = array{{{d}}}\nR{d}:[]string = R{d} + RB\n", .{ index, index, index, index - 1 });
            if (self.rng.boolean()) try self.add("TU:task([]string) = Spawn{{ Append(R{d}, 9) }}\n", .{n - 1});
        }
        return self.text.items;
    }
};

test "c7-1: generated task programs need one fuel at every floor and trace mode" {
    try @import("profile.zig").requireBootstrap();
    const f = try Fixture.create();
    defer f.destroy();
    const plain = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(plain);
    const other = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(other);
    var reclaimed: usize = 0;
    var checked: usize = 0;
    // Seed 2's seventh program is the one the review found first (a join in `Nap` after a sleep).
    for ([_]u64{ 2, 3, 4 }) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var generator: C71Generator = .{ .rng = random.random() };
        defer generator.text.deinit(std.testing.allocator);
        for (0..c71_programs) |_| {
            const source = try generator.program();
            const floor = generator.rng.intRangeLessThan(u32, 1, 64);
            if (try c71Check(f, source, floor, plain, other)) reclaimed += 1;
            checked += 1;
        }
    }
    try std.testing.expectEqual(3 * c71_programs, checked);
    try std.testing.expect(reclaimed * 2 > checked);
}
const c71_programs: usize = 8;
