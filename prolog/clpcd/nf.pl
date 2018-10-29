/*

    Part of CLP(R) (Constraint Logic Programming over Reals)

    Author:        Leslie De Koninck
    E-mail:        Leslie.DeKoninck@cs.kuleuven.be
    WWW:           http://www.swi-prolog.org
		   http://www.ai.univie.ac.at/cgi-bin/tr-online?number+95-09
    Copyright (C): 2004, K.U. Leuven and
		   1992-1995, Austrian Research Institute for
		              Artificial Intelligence (OFAI),
			      Vienna, Austria

    This software is part of Leslie De Koninck's master thesis, supervised
    by Bart Demoen and daily advisor Tom Schrijvers.  It is based on CLP(Q,R)
    by Christian Holzbaur for SICStus Prolog and distributed under the
    license details below with permission from all mentioned authors.

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/


:- module(clpcd_nf,
	[
	    add_constraint/2,
	    nf/3,
	    entailed/2,
	    split/3,
	    repair/3,
	    nf_constant/2,
	    wait_linear/4,
	    nf2term/3
	]).

:- use_module(library(clpcd/geler)).
:- use_module(library(clpcd/ineq)).
:- use_module(library(clpcd/domain_ops)).
:- use_module(library(clpcd/bv)).
:- use_module(library(clpcd/store)).
:- use_module(library(clpcd/highlight), []).

% -------------------------------------------------------------------------

% {Constraint}
%
% Adds the constraint Constraint to the constraint store.
%
% First rule is to prevent binding with other rules when a variable is input
% Constraints are converted to normal form and if necessary, submitted to the linear
% equality/inequality solver (bv + ineq) or to the non-linear store (geler)

add_constraint(Rel, CLP) :-
	var(Rel),
	!,
	throw(instantiation_error(CLP:{Rel},1)).
add_constraint((R,Rs), CLP) :-
	!,
	add_constraint(R, CLP),
        add_constraint(Rs, CLP).
add_constraint((R;Rs), CLP) :-
	!,
	( add_constraint(R, CLP)
        ; add_constraint(Rs, CLP)
        ). % for entailment checking
add_constraint(L < R, CLP) :-
	!,
	nf(L-R,CLP,Nf),
	submit_lt(Nf, CLP).
add_constraint(L > R, CLP) :-
	!,
	nf(R-L,CLP,Nf),
	submit_lt(Nf, CLP).
add_constraint(L =< R, CLP) :-
	!,
	nf(L-R,CLP,Nf),
	submit_le(Nf, CLP).
add_constraint(<=(L,R), CLP) :-
	!,
	nf(L-R,CLP,Nf),
	submit_le(Nf, CLP).
add_constraint(L >= R, CLP) :-
	!,
	nf(R-L,CLP,Nf),
	submit_le(Nf, CLP).
add_constraint(L =\= R, CLP) :-
	!,
	nf(L-R,CLP,Nf),
	submit_ne(CLP, Nf).
add_constraint(L =:= R, CLP) :-
	!,
	nf(L-R,CLP,Nf),
	submit_eq(Nf, CLP).
add_constraint(L = R, CLP) :-
	!,
	nf(L-R,CLP,Nf),
	submit_eq(Nf, CLP).
add_constraint(Rel, CLP) :- throw(type_error(CLP:{Rel},1,'a constraint',Rel)).

% entailed(CLP, C)
%
% s -> c = ~s v c = ~(s /\ ~c)
% where s is the store and c is the constraint for which
% we want to know whether it is entailed.
% C is negated and added to the store. If this fails, then c is entailed by s

entailed(CLP, C) :-
	negate(C,CLP,Cn),
	\+ add_constraint(Cn, CLP).

% negate(C,Res).
%
% Res is the negation of constraint C
% first rule is to prevent binding with other rules when a variable is input

negate(Rel,CLP,_) :-
	var(Rel),
	!,
	throw(instantiation_error(entailed(CLP,Rel),1)).
negate((A,B),C,(Na;Nb)) :-
	!,
	negate(A,C,Na),
	negate(B,C,Nb).
negate((A;B),C,(Na,Nb)) :-
	!,
	negate(A,C,Na),
	negate(B,C,Nb).
negate(A<B,_,A>=B) :- !.
negate(A>B,_,A=<B) :- !.
negate(A=<B,_,A>B) :- !.
negate(A>=B,_,A<B) :- !.
negate(A=:=B,_,A=\=B) :- !.
negate(A=B,_,A=\=B) :- !.
negate(A=\=B,_,A=:=B) :- !.
negate(Rel,CLP,_) :- throw( type_error(entailed(CLP,Rel),1,'a constraint',Rel)).

% submit_eq(Nf, CLP)
%
% Submits the equality Nf = 0 to the constraint store, where Nf is in normal form.
% The following cases may apply:
% a) Nf = []
% b) Nf = [A]
%	b1) A = k
%	b2) invertible(A)
%	b3) linear -> A = 0
%	b4) nonlinear -> geler
% c) Nf=[A,B|Rest]
%	c1) A=k
%		c11) (B=c*X^+1 or B=c*X^-1), Rest=[] -> B=-k/c or B=-c/k
%		c12) invertible(A,B)
%		c13) linear(B|Rest)
%		c14) geler
%	c2) linear(Nf)
%	c3) nonlinear -> geler

submit_eq([], _).	% trivial success: case a
submit_eq([T|Ts], CLP) :-
	submit_eq(Ts,CLP,T).
submit_eq([],CLP,A) :- submit_eq_b(A, CLP).	% case b
submit_eq([B|Bs],CLP,A) :- submit_eq_c(A,CLP,B,Bs).	% case c

% submit_eq_b(A, CLP)
%
% Handles case b of submit_eq/1

% case b1: A is a constant (non-zero)
submit_eq_b(v(_,[]), _) :-
	!,
	fail.
% case b2/b3: A is n*X^P => X = 0
submit_eq_b(v(_,[X^P]), _) :-
	var(X),
	P > 0,
	!,
	X = 0.
% case b2: non-linear is invertible: NL(X) = 0 => X - inv(NL)(0) = 0
submit_eq_b(v(_,[NL^1]), CLP) :-
	nonvar(NL),
	nl_invertible(CLP,NL,X,0,Inv),
	!,
	nf(-Inv,CLP,S),
	nf_add(X, CLP, S, New),
	submit_eq(New, CLP).
% case b4: A is non-linear and not invertible => submit equality to geler
submit_eq_b(Term, CLP) :-
	term_variables(Term,Vs),
	geler(CLP,Vs,resubmit_eq(CLP, [Term])).

% submit_eq_c(A,CLP,B,Rest)
%
% Handles case c of submit_eq/1

% case c1: A is a constant
submit_eq_c(v(I,[]),CLP,B,Rest) :-
	!,
	submit_eq_c1(Rest,CLP,B,I).
% case c2: A,B and Rest are linear
submit_eq_c(A,CLP,B,Rest) :-	% c2
	A = v(_,[X^1]),
	var(X),
	B = v(_,[Y^1]),
	var(Y),
	linear(Rest),
	!,
	Hom = [A,B|Rest],
	% 'solve_='(Hom).
	nf_length(Hom,0,Len),
	log_deref(Len, CLP, Hom, [], HomD),
	solve(CLP,HomD).
% case c3: A, B or Rest is non-linear => geler
submit_eq_c(A,CLP,B,Rest) :-
	Norm = [A,B|Rest],
	term_variables(Norm,Vs),
	geler(CLP,Vs,resubmit_eq(CLP, Norm)).

root_d(CLP, I, K, P, R) :-
        div_d(CLP, I, K, Base),
        div_d(CLP, 1, P, Exp),
        N is Base ** Exp,
        cast_d(CLP, N, R).

% submit_eq_c1(Rest,CLP,B,K)
%
% Handles case c1 of submit_eq/1

% case c11a:
% i+kX^p=0 if p is an odd integer
% special case: one solution if P is negativ but also for a negative X
submit_eq_c1([], CLP, v(K,[X^P]), I) :-
	var(X),
        P =\= 0,
        compare_d(CLP, =, integer(P), P),
        0 > sign(-I)*sign(K),
        1 =:= integer(P) mod 2,
        !,
        root_d(CLP, I, K, P, R),
        Val is -R,
        X = Val.
% case c11b:
% i+kX^p=0 for p =\= 0, integer(P) =:= P
% special case: generate 2 solutions if p is a positive even integer
submit_eq_c1([], CLP, v(K,[X^P]), I) :-
	var(X),
        P =\= 0,
        compare_d(CLP, =, integer(P), P),
        0 =< sign(-I)*sign(K),
        0 =:= integer(P) mod 2,
	!,
        root_d(CLP, -I, K, P, Val),
	( X = Val
	; ValNeg is -Val,
          X = ValNeg
        ).
% case c11c:
% i+kX^p=0 for p =\= 0, 0 =< (-I/K)
submit_eq_c1([], CLP, v(K,[X^P]), I) :-
        var(X),
        P =\= 0,
        0 =< sign(-I)*sign(K),
	!,
        root_d(CLP, -I, K, P, Val),
        X = Val.
% case c11d: fail if var(X) and none of the above.
submit_eq_c1([], _, v(_K,[X^_P]), _I) :-
        var(X),
        !,
        fail.
% case c11e: fail for { -25 = _X^2.5 } and { -25 = _X^(-2.5) } and may be others!
% 			 if you uncomment this case { -25 = _X^2.5 } throw an error(evaluation_error(undefined))
% 			 and { -25 = _X^(-2.5) } succeed with an unbound X
submit_eq_c1([], CLP, v(K,[X^P]), I) :-
        nonvar(X),
        X = exp(_,_),   % TLS added 03/12
        compare_d(CLP, =, 1, abs(P)),
        0 >= I,
        0 >= K,
        !,
        fail.
% case c12: non-linear, invertible: cNL(X)^1+k=0 => inv(NL)(-k/c) = 0 ;
%				    cNL(X)^-1+k=0 => inv(NL)(-c/k) = 0
submit_eq_c1([],CLP,v(K,[NL^P]),I) :-
	nonvar(NL),
	(   compare_d(CLP, =, P, 1),
            div_d(CLP, -I, K, Y)
	;   compare_d(CLP, =, P, -1),
            div_d(CLP, -K, I, Y)
	),
	nl_invertible(CLP,NL,X,Y,Inv),
	!,
	nf(-Inv,CLP,S),
	nf_add(X, CLP, S, New),
	submit_eq(New, CLP).
% case c13: linear: X + Y + Z + c = 0 =>
submit_eq_c1(Rest,CLP,B,I) :-
	B = v(_,[Y^1]),
	var(Y),
	linear(Rest),
	!,
	% 'solve_='( [v(I,[]),B|Rest]).
	Hom = [B|Rest],
	nf_length(Hom,0,Len),
	normalize_scalar(I,Nonvar),
	log_deref(Len, CLP, Hom, [], HomD),
	add_linear_11(CLP, Nonvar, HomD, LinD),
	solve(CLP,LinD).
% case c14: other cases => geler
submit_eq_c1(Rest,CLP,B,I) :-
	Norm = [v(I,[]),B|Rest],
	term_variables(Norm,Vs),
	geler(CLP,Vs,resubmit_eq(CLP, Norm)).

% -----------------------------------------------------------------------

% submit_lt(Nf)
%
% Submits the inequality Nf<0 to the constraint store, where Nf is in normal form.

% 0 < 0 => fail
submit_lt([], _) :- fail.
% A + B < 0
submit_lt([A|As], CLP) :- submit_lt(As, CLP, A).

% submit_lt(As,A)
%
% Does what submit_lt/1 does where Nf = [A|As]

% v(K,P) < 0
submit_lt([], CLP, v(K,P)) :- submit_lt_b(P,CLP,K).
% A + B + Bs < 0
submit_lt([B|Bs], CLP, A) :- submit_lt_c(Bs,CLP,A,B).

% submit_lt_b(P,CLP,K)
%
% Does what submit_lt/2 does where A = [v(K,P)] and As = []

% c < 0
submit_lt_b([],CLP,I) :-
	!,
	compare_d(CLP, <, I, 0).
% cX^1 < 0 : if c < 0 then X > 0, else X < 0
submit_lt_b([X^1],CLP,K) :-
	var(X),
	!,
	(   K > 0
	->  ineq_one_s_p_0(CLP, X)	% X is strictly negative
	;   ineq_one_s_n_0(CLP, X)	% X is strictly positive
	).
% non-linear => geler
submit_lt_b(P,CLP,K) :-
	term_variables(P,Vs),
	geler(CLP,Vs,resubmit_lt(CLP, [v(K,P)])).

% submit_lt_c(Bs,CLP,A,B)
%
% Does what submit_lt/2 does where As = [B|Bs].

%  c + kX < 0 => kX < c
submit_lt_c([],CLP,A,B) :-
	A = v(I,[]),
	B = v(K,[Y^1]),
	var(Y),
	!,
	ineq_one(strict, CLP, Y, K, I).
% linear < 0 => solve, non-linear < 0 => geler
submit_lt_c(Rest,CLP,A,B) :-
	Norm = [A,B|Rest],
	(   linear(Norm)
	->  'solve_<'(CLP, Norm)
	;   term_variables(Norm,Vs),
	    geler(CLP,Vs,resubmit_lt(CLP, Norm))
	).

% submit_le(Nf)
%
% Submits the inequality Nf =< 0 to the constraint store, where Nf is in normal form.
% See also submit_lt/1

% 0 =< 0 => success
submit_le([], _).
% A + B =< 0
submit_le([A|As], CLP) :- submit_le(As, CLP, A).

% submit_le(As,A)
%
% See submit_lt/2. This handles less or equal.

% v(K,P) =< 0
submit_le([], CLP, v(K,P)) :- submit_le_b(P,CLP,K).
% A + B + Bs =< 0
submit_le([B|Bs], CLP, A) :- submit_le_c(Bs,CLP,A,B).

% submit_le_b(P,K)
%
% See submit_lt_b/2. This handles less or equal.

% c =< 0
submit_le_b([],CLP,I) :-
	!,
	compare_d(CLP, =<, I, 0).
% cX^1 =< 0: if c < 0 then X >= 0, else X =< 0
submit_le_b([X^1],CLP,K) :-
	var(X),
	!,
	(   K > 0
	->  ineq_one_n_p_0(CLP, X)	% X is non-strictly negative
	;   ineq_one_n_n_0(CLP, X)	% X is non-strictly positive
	).
%  cX^P =< 0 => geler
submit_le_b(P,CLP,K) :-
	term_variables(P,Vs),
	geler(CLP,Vs,resubmit_le(CLP, [v(K,P)])).

% submit_le_c(Bs,CLP,A,B)
%
% See submit_lt_c/4. This handles less or equal.

% c + kX^1 =< 0 => kX =< 0
submit_le_c([],CLP,A,B) :-
	A = v(I,[]),
	B = v(K,[Y^1]),
	var(Y),
	!,
	ineq_one(nonstrict, CLP, Y, K, I).
% A, B & Rest are linear => solve, otherwise => geler
submit_le_c(Rest,CLP,A,B) :-
	Norm = [A,B|Rest],
	(   linear(Norm)
	->  'solve_=<'(CLP, Norm)
	;   term_variables(Norm,Vs),
	    geler(CLP,Vs,resubmit_le(CLP, Norm))
	).

% submit_ne(CLP,Nf)
%
% Submits the inequality Nf =\= 0 to the constraint store, where Nf is in normal form.
% if Nf is a constant => check constant = 0, else if Nf is linear => solve else => geler

submit_ne(CLP,Norm1) :-
	(   nf_constant(Norm1,K)
	->  K =\= 0
	;   linear(Norm1)
	->  'solve_=\\='(CLP,Norm1)
	;   term_variables(Norm1,Vs),
	    geler(CLP,Vs,resubmit_ne(CLP,Norm1))
	).

% linear(A)
%
% succeeds when A is linear: all elements are of the form v(_,[]) or v(_,[X^1])

linear([]).
linear(v(_,Ps)) :- linear_ps(Ps).
linear([A|As]) :-
	linear(A),
	linear(As).

% linear_ps(A)
%
% Succeeds when A = V^1 with V a variable.
% This reflects the linearity of v(_,A).

linear_ps([]).
linear_ps([V^1]) :- var(V).	% excludes sin(_), ...

%
% Goal delays until Term gets linear.
% At this time, Var will be bound to the normalform of Term.
%
:- meta_predicate wait_linear(?, ?, ?, 0 ).

wait_linear(CLP,Term,Var,Goal) :-
	nf(Term,CLP,Nf),
	(   linear(Nf)
	->  Var = Nf,
	    call(Goal)
	;   term_variables(Nf,Vars),
	    geler(CLP,Vars,wait_linear_retry(CLP, Nf, Var, Goal))
	).
%
% geler clients
%
resubmit_eq(CLP, N) :-
	repair(CLP, N, Norm),
	submit_eq(Norm, CLP).
resubmit_lt(CLP, N) :-
	repair(CLP, N, Norm),
	submit_lt(Norm, CLP).
resubmit_le(CLP, N) :-
	repair(CLP, N, Norm),
	submit_le(Norm, CLP).
resubmit_ne(CLP,N) :-
	repair(CLP, N, Norm),
	submit_ne(CLP,Norm).

wait_linear_retry(CLP,Nf0,Var,Goal) :-
	repair(CLP, Nf0, Nf),
	(   linear(Nf)
	->  Var = Nf,
	    call(Goal)
	;   term_variables(Nf,Vars),
	    geler(CLP,Vars,wait_linear_retry(CLP, Nf, Var, Goal))
	).
% -----------------------------------------------------------------------

% nl_invertible(F,X,Y,Res)
%
% Res is the evaluation of the inverse of nonlinear function F in variable X
% where X is Y

nl_invertible_(sin(X),_,X,Y,Res) :- Res is asin(Y).
nl_invertible_(cos(X),_,X,Y,Res) :- Res is acos(Y).
nl_invertible_(tan(X),_,X,Y,Res) :- Res is atan(Y).
nl_invertible_(exp(B,C),CLP,X,A,Res) :-
	(   nf_constant(B,Kb)
	->  A > 0,
	    Kb > 0,
            % Kb =\= 1.0
            compare_d(CLP, \=, Kb, 1),
	    X = C, % note delayed unification
	    Res is log(A)/log(Kb)
	;   nf_constant(C,Kc),
            A =\= 0,
	    Kc > 0,
	    X = B, % note delayed unification
	    Res is A**(1/Kc)
	).

nl_invertible(C,F,X,Y,Res) :-
        nl_invertible_(F,C,X,Y,N),
        cast_d(C,N,Res).

% -----------------------------------------------------------------------

% nf(Exp,CLP,Nf)
%
% Returns in Nf, the normal form of expression Exp
%
% v(A,[B^C,D^E|...]) means A*B^C*D^E*... where A is a scalar (number)
% v(A,[]) means scalar A

% variable X => 1*X^1
nf(X,_,Norm) :-
	var(X),
	!,
	Norm = [v(1,[X^1])].
nf(X,CLP,Norm) :-
	nf_number(CLP,X,Norm),
        !.
% nf(#(Const),Norm) :-
% 	monash_constant(Const,Value),
% 	!,
% 	Norm = [v(Value,[])].
nf(-A,CLP,Norm) :-
	!,
	nf(A,CLP,An),
	nf_mul_factor(v(-1,[]), CLP, An, Norm).
nf(+A,CLP,Norm) :-
	!,
	nf(A,CLP,Norm).
%
nf(A+B,CLP,Norm) :-
	!,
	nf(A,CLP,An),
	nf(B,CLP,Bn),
	nf_add(An, CLP, Bn, Norm).
nf(A-B,CLP,Norm) :-
	!,
	nf(A,CLP,An),
	nf(-B,CLP,Bn),
	nf_add(An, CLP, Bn, Norm).
%
nf(A*B,CLP,Norm) :-
	!,
	nf(A,CLP,An),
	nf(B,CLP,Bn),
	nf_mul(CLP, An, Bn, Norm).
nf(A/B,CLP,Norm) :-
	!,
	nf(A,CLP,An),
	nf(B,CLP,Bn),
	nf_div(Bn,An,Norm).
% non-linear function, one argument: Term = f(Arg) equals f'(Sa1) = Skel
nf(Term,CLP,Norm) :-
	nonlin_1(Term,Arg,Skel,Sa1),
	!,
	nf(Arg,CLP,An),
	nf_nonlin_1(CLP, Skel, An, Sa1, Norm).
% non-linear function, two arguments: Term = f(A1,A2) equals f'(Sa1,Sa2) = Skel
nf(Term,CLP,Norm) :-
	nonlin_2(Term,A1,A2,Skel,Sa1,Sa2),
	!,
	nf(A1, CLP, A1n),
	nf(A2, CLP, A2n),
	nf_nonlin_2(CLP,Skel,A1n,A2n,Sa1,Sa2,Norm).
%
nf(Term,CLP,_) :-
	throw(type_error(nf(Term,CLP,_),1,'a numeric expression',Term)).

% nf_number(N,Res)
%
% If N is a number, N is normalized

nf_number(CLP, N, Res) :-
        cast_d(CLP, N, Num),
	(   Num =:= 0
	->  Res = []
	;   Res = [v(Num,[])]
	).

nonlin_1(abs(X),X,abs(Y),Y).
nonlin_1(sin(X),X,sin(Y),Y).
nonlin_1(cos(X),X,cos(Y),Y).
nonlin_1(tan(X),X,tan(Y),Y).
nonlin_2(min(A,B),A,B,min(X,Y),X,Y).
nonlin_2(max(A,B),A,B,max(X,Y),X,Y).
nonlin_2(exp(A,B),A,B,exp(X,Y),X,Y).
nonlin_2(pow(A,B),A,B,exp(X,Y),X,Y).	% pow->exp
nonlin_2(A^B,A,B,exp(X,Y),X,Y).
nonlin_2(A**B,A,B,exp(X,Y),X,Y).

nf_nonlin_1(CLP,Skel,An,S1,Norm) :-
	(   nf_constant(An,S1)
	->  nl_eval(Skel,Res),
	    nf_number(CLP,Res,Norm)
	;   S1 = An,
	    Norm = [v(1,[Skel^1])]).
nf_nonlin_2(CLP,Skel,A1n,A2n,S1,S2,Norm) :-
	(   nf_constant(A1n,S1),
	    nf_constant(A2n,S2)
	->  nl_eval(Skel,Res),
	    nf_number(CLP,Res,Norm)
	;   Skel=exp(_,_),
	    nf_constant(A2n,Exp),
	    integerp(CLP,Exp,I)
	->  nf_power(CLP, I, A1n, Norm)
	;   S1 = A1n,
	    S2 = A2n,
	    Norm = [v(1,[Skel^1])]
	).

% evaluates non-linear functions in one variable where the variable is bound
nl_eval(abs(X),R) :- R is abs(X).
nl_eval(sin(X),R) :- R is sin(X).
nl_eval(cos(X),R) :- R is cos(X).
nl_eval(tan(X),R) :- R is tan(X).
% evaluates non-linear functions in two variables where both variables are
% bound
nl_eval(min(X,Y),R) :- R is min(X,Y).
nl_eval(max(X,Y),R) :- R is max(X,Y).
nl_eval(exp(X,Y),R) :- R is X**Y.

%
% check if a Nf consists of just a constant
%

nf_constant([],Z) :- Z = 0.
nf_constant([v(K,[])],K).

% split(NF,SNF,C)
%
% splits a normalform expression NF into two parts:
% - a constant term C (which might be 0)
% - the homogene part of the expression
%
% this method depends on the polynf ordering, i.e. [] < [X^1] ...

split([],[],0).
split([First|T],H,I) :-
	(   First = v(I,[])
	->  H = T
	;   I = 0,
	    H = [First|T]
	).

% nf_add(A,B,C): merges two normalized additions into a new normalized addition
%
% a normalized addition is one where the terms are ordered, e.g. X^1 < Y^1, X^1 < X^2 etc.
% terms in the same variable with the same exponent are added,
% e.g. when A contains v(5,[X^1]) and B contains v(4,[X^1]) then C contains v(9,[X^1]).

nf_add([], _, Bs, Bs).
nf_add([A|As], CLP, Bs, Cs) :- nf_add(Bs, CLP, A, As, Cs).

nf_add([], _, A, As, Cs) :- Cs = [A|As].
nf_add([B|Bs], CLP, A, As, Cs) :-
	A = v(Ka,Pa),
	B = v(Kb,Pb),
	compare(Rel,Pa,Pb),
	nf_add_case(Rel,CLP,A,As,Cs,B,Bs,Ka,Kb,Pa).

% nf_add_case(Rel,CLP,A,As,Cs,B,Bs,Ka,Kb,Pa)
%
% merges sorted lists [A|As] and [B|Bs] into new sorted list Cs
% A = v(Ka,Pa) and B = v(Kb,_)
% Rel is the ordering relation (<, > or =) between A and B.
% when Rel is =, Ka and Kb are added to form a new scalar for Pa
nf_add_case(<,CLP,A,As,Cs,B,Bs,_,_,_) :-
	Cs = [A|Rest],
	nf_add(As, CLP, B, Bs, Rest).
nf_add_case(>,CLP,A,As,Cs,B,Bs,_,_,_) :-
	Cs = [B|Rest],
	nf_add(Bs, CLP, A, As, Rest).
nf_add_case(=,CLP,_,As,Cs,_,Bs,Ka,Kb,Pa) :-
	Kc is Ka + Kb,
	(   % Kc =:= 0.0
            compare_d(CLP, =, Ka, -Kb)
	->  nf_add(As, CLP, Bs, Cs)
	;   Cs = [v(Kc,Pa)|Rest],
	    nf_add(As, CLP, Bs, Rest)
	).

nf_mul(CLP, A, B, Res) :-
	nf_length(A,0,LenA),
	nf_length(B,0,LenB),
	nf_mul_log(LenA, CLP, A, [], LenB, B, Res).

nf_mul_log(0, _, As, As, _, _, []) :- !.
nf_mul_log(1, CLP, [A|As], As, Lb, B, R) :-
	!,
	nf_mul_factor_log(Lb, CLP, B, [], A, R).
nf_mul_log(2, CLP, [A1,A2|As], As, Lb, B, R) :-
	!,
	nf_mul_factor_log(Lb, CLP, B, [], A1, A1b),
	nf_mul_factor_log(Lb, CLP, B, [], A2, A2b),
	nf_add(A1b, CLP, A2b, R).
nf_mul_log(N, CLP, A0, A2, Lb, B, R) :-
	P is N>>1,
	Q is N-P,
	nf_mul_log(P, CLP, A0, A1, Lb, B, Rp),
	nf_mul_log(Q, CLP, A1, A2, Lb, B, Rq),
	nf_add(Rp, CLP, Rq, R).


% nf_add_2: does the same thing as nf_add, but only has 2 elements to combine.
nf_add_2(CLP, Af, Bf, Res) :-		%  unfold: nf_add([Af],[Bf],Res).
	Af = v(Ka,Pa),
	Bf = v(Kb,Pb),
	compare(Rel,Pa,Pb),
	nf_add_2_case(Rel, CLP, Af, Bf, Res, Ka, Kb, Pa).

nf_add_2_case(<, _, Af, Bf, [Af,Bf], _, _, _).
nf_add_2_case(>, _, Af, Bf, [Bf,Af], _, _, _).
nf_add_2_case(=, CLP, _, _, Res, Ka, Kb, Pa) :-
	Kc is Ka + Kb,
	(   % Kc =:= 0
            compare_d(CLP, =, Ka, -Kb)
	->  Res = []
	;   Res = [v(Kc,Pa)]
	).

% nf_mul_k(A,B,C)
%
% C is the result of the multiplication of each element of A (of the form v(_,_)) with scalar B (which shouldn't be 0)
nf_mul_k([],_,[]).
nf_mul_k([v(I,P)|Vs],K,[v(Ki,P)|Vks]) :-
	Ki is K*I,
	nf_mul_k(Vs,K,Vks).

% nf_mul_factor(A,Sum,Res)
%
% multiplies each element of the list Sum with factor A which is of the form v(_,_)
% and puts the result in the sorted list Res.
nf_mul_factor(v(K,[]), _, Sum, Res) :-
	!,
	nf_mul_k(Sum,K,Res).
nf_mul_factor(F, CLP, Sum, Res) :-
	nf_length(Sum,0,Len),
	nf_mul_factor_log(Len, CLP, Sum, [], F, Res).

% nf_mul_factor_log(Len,[Sum|SumTail],SumTail,F,Res)
%
% multiplies each element of Sum with F and puts the result in the sorted list Res
% Len is the length of Sum
% Sum is split logarithmically each step

nf_mul_factor_log(0, _, As, As, _, []) :- !.
nf_mul_factor_log(1, _, [A|As], As, F, [R]) :-
	!,
	mult(A,F,R).
nf_mul_factor_log(2, CLP, [A,B|As], As, F, Res) :-
	!,
	mult(A,F,Af),
	mult(B,F,Bf),
	nf_add_2(CLP, Af, Bf, Res).
nf_mul_factor_log(N, CLP, A0, A2, F, R) :-
	P is N>>1, % P is rounded(N/2)
	Q is N-P,
	nf_mul_factor_log(P, CLP, A0, A1, F, Rp),
	nf_mul_factor_log(Q, CLP, A1, A2, F, Rq),
	nf_add(Rp, CLP, Rq, R).

% mult(A,B,C)
%
% multiplies A and B into C each of the form v(_,_)

mult(v(Ka,La),v(Kb,Lb),v(Kc,Lc)) :-
	Kc is Ka*Kb,
	pmerge(La,Lb,Lc).

% pmerge(A,B,C)
%
% multiplies A and B into sorted C, where each is of the form of the second argument of v(_,_)

pmerge([],Bs,Bs).
pmerge([A|As],Bs,Cs) :- pmerge(Bs,A,As,Cs).

pmerge([],A,As,Res) :- Res = [A|As].
pmerge([B|Bs],A,As,Res) :-
	A = Xa^Ka,
	B = Xb^Kb,
	compare(R,Xa,Xb),
	pmerge_case(R,A,As,Res,B,Bs,Ka,Kb,Xa).

% pmerge_case(Rel,A,As,Res,B,Bs,Ka,Kb,Xa)
%
% multiplies and sorts [A|As] with [B|Bs] into Res where each is of the form of
% the second argument of v(_,_)
%
% A is Xa^Ka and B is Xb^Kb, Rel is ordening relation between Xa and Xb

pmerge_case(<,A,As,Res,B,Bs,_,_,_) :-
	Res = [A|Tail],
	pmerge(As,B,Bs,Tail).
pmerge_case(>,A,As,Res,B,Bs,_,_,_) :-
	Res = [B|Tail],
	pmerge(Bs,A,As,Tail).
pmerge_case(=,_,As,Res,_,Bs,Ka,Kb,Xa) :-
	Kc is Ka + Kb,
	(   Kc =:= 0
	->  pmerge(As,Bs,Res)
	;   Res = [Xa^Kc|Tail],
	    pmerge(As,Bs,Tail)
	).

% nf_div(Factor,In,Out)
%
% Out is the result of the division of each element in In (which is of the form v(_,_)) by Factor.

% division by zero
nf_div([],_,_) :-
	!,
	zero_division.
% division by v(K,P) => multiplication by v(1/K,P^-1)
nf_div([v(K,P)],Sum,Res) :-
	!,
        div_d(CLP, 1, K, Ki),
	mult_exp(P,-1,Pi),
	nf_mul_factor(v(Ki,Pi), CLP, Sum, Res).
nf_div(D,A,[v(1,[(A/D)^1])]).

% zero_division
%
% called when a division by zero is performed
zero_division :- fail.	% raise_exception(_) ?

% mult_exp(In,Factor,Out)
%
% Out is the result of the multiplication of the exponents of the elements in In
% (which are of the form X^Exp by Factor.
mult_exp([],_,[]).
mult_exp([X^P|Xs],K,[X^I|Tail]) :-
	I is K*P,
	mult_exp(Xs,K,Tail).
%
% raise to integer powers
%
% | ?- time({(1+X+Y+Z)^15=0}). (sicstus, try with SWI)
% Timing 00:00:02.610	  2.610   iterative
% Timing 00:00:00.660	  0.660   binomial
nf_power(CLP, N, Sum, Norm) :-
	integer(N),
	compare(Rel,N,0),
	(   Rel = (<)
	->  Pn is -N,
	    % nf_power_pos(Pn,Sum,Inorm),
	    binom(Sum, CLP, Pn, Inorm),
	    nf_div(Inorm,[v(1,[])],Norm)
	;   Rel = (>)
	->  % nf_power_pos(N,Sum,Norm)
	    binom(Sum, CLP, N, Norm)
	;   Rel = (=)
	->  % 0^0 is indeterminate but we say 1
	    Norm = [v(1,[])]
	).

%
% N>0
%
% binomial method
binom(Sum, _, 1, Power) :-
	!,
	Power = Sum.
binom([], _, _, []).
binom([A|Bs], CLP, N, Power) :-
	(   Bs = []
	->  nf_power_factor(A,N,Ap),
	    Power = [Ap]
	;   Bs = [_|_]
	->  factor_powers(N,A,v(1,[]),Pas),
	    sum_powers(N, CLP, Bs, [v(1,[])], Pbs, []),
	    combine_powers(Pas,Pbs,0,N,1,[],Power)
	).

combine_powers([],[],_,_,_,Pi,Pi).
combine_powers([A|As],[B|Bs],L,R,C,Pi,Po) :-
	nf_mul(CLP, A, B, Ab),
	nf_mul_k(Ab,C,Abc),
	nf_add(Abc, CLP, Pi, Pii),
	L1 is L+1,
	R1 is R-1,
	C1 is C*R//L1,
	combine_powers(As,Bs,L1,R1,C1,Pii,Po).

nf_power_factor(v(K,P),N,v(Kn,Pn)) :-
	Kn is K**N,
	mult_exp(P,N,Pn).

factor_powers(0,_,Prev,[[Prev]]) :- !.
factor_powers(N,F,Prev,[[Prev]|Ps]) :-
	N1 is N-1,
	mult(Prev,F,Next),
	factor_powers(N1,F,Next,Ps).
sum_powers(0, _, _, Prev, [Prev|Lt], Lt) :- !.
sum_powers(N, CLP, S, Prev, L0, Lt) :-
	N1 is N-1,
	nf_mul(CLP, S, Prev, Next),
	sum_powers(N1, CLP, S, Next, L0, [Prev|Lt]).

% ------------------------------------------------------------------------------
repair(CLP, Sum, Norm) :-
	nf_length(Sum,0,Len),
	repair_log(Len, CLP, Sum, [], Norm).
repair_log(0, -, As, As, []) :- !.
repair_log(1, CLP, [v(Ka,Pa)|As], As, R) :-
	!,
	repair_term(CLP, Ka, Pa, R).
repair_log(2, CLP, [v(Ka,Pa),v(Kb,Pb)|As], As, R) :-
	!,
	repair_term(CLP, Ka, Pa, Ar),
	repair_term(CLP, Kb, Pb, Br),
	nf_add(Ar, CLP, Br, R).
repair_log(N, CLP, A0, A2, R) :-
	P is N>>1,
	Q is N-P,
	repair_log(P, CLP, A0, A1, Rp),
	repair_log(Q, CLP, A1, A2, Rq),
	nf_add(Rp, CLP, Rq, R).

repair_term(CLP, K, P, Norm) :-
	length(P,Len),
	repair_p_log(Len,P,[],Pr,[v(1,[])],Sum),
	nf_mul_factor(v(K,Pr), CLP, Sum, Norm).

repair_p_log(0,Ps,Ps,[],L0,L0) :- !.
repair_p_log(1,[X^P|Ps],Ps,R,L0,L1) :-
	!,
	repair_p(X,P,R,L0,L1).
repair_p_log(2,[X^Px,Y^Py|Ps],Ps,R,L0,L2) :-
	!,
	repair_p(X,Px,Rx,L0,L1),
	repair_p(Y,Py,Ry,L1,L2),
	pmerge(Rx,Ry,R).
repair_p_log(N,P0,P2,R,L0,L2) :-
	P is N>>1,
	Q is N-P,
	repair_p_log(P,P0,P1,Rp,L0,L1),
	repair_p_log(Q,P1,P2,Rq,L1,L2),
	pmerge(Rp,Rq,R).

repair_p(Term,P,[Term^P],L0,L0) :- var(Term).
repair_p(Term,P,[],L0,L1) :-
	nonvar(Term),
	repair_p_one(Term, CLP, TermN),
	nf_power(CLP, P, TermN, TermNP),
	nf_mul(CLP, TermNP, L0, L1).
%
% An undigested term a/b is distinguished from an
% digested one by the fact that its arguments are
% digested -> cuts after repair of args!
%
repair_p_one(Term, CLP, TermN) :-
	nf_number(CLP,Term,TermN),	% freq. shortcut for nf/2 case below
	!.
repair_p_one(A1/A2, CLP, TermN) :-
	repair(CLP, A1, A1n),
	repair(CLP, A2, A2n),
	!,
	nf_div(A2n,A1n,TermN).
repair_p_one(Term, CLP, TermN) :-
	nonlin_1(Term,Arg,Skel,Sa),
	repair(CLP, Arg, An),
	!,
	nf_nonlin_1(CLP, Skel, An, Sa, TermN).
repair_p_one(Term, CLP, TermN) :-
	nonlin_2(Term,A1,A2,Skel,Sa1,Sa2),
	repair(CLP, A1, A1n),
	repair(CLP, A2, A2n),
	!,
	nf_nonlin_2(CLP,Skel,A1n,A2n,Sa1,Sa2,TermN).
repair_p_one(Term, CLP, TermN) :-
	nf(Term, CLP, TermN).

nf_length([],Li,Li).
nf_length([_|R],Li,Lo) :-
	Lii is Li+1,
	nf_length(R,Lii,Lo).
% ------------------------------------------------------------------------------
% nf2term(NF,CLP,Term)
%
% transforms a normal form into a readable term

% empty normal form = 0
nf2term([],_,0).
% term is first element (+ next elements)
nf2term([F|Fs],CLP,T) :-
	f02t(F,CLP,T0),	% first element
	yfx(Fs,CLP,T0,T).	% next elements

yfx([],_,T0,T0).
yfx([F|Fs],CLP,T0,TN) :-
	fn2t(F,CLP,Ft,Op),
	T1 =.. [Op,T0,Ft],
	yfx(Fs,CLP,T1,TN).

% f02t(v(K,P),CLP,T)
%
% transforms the first element of the normal form (something of the form v(K,P))
% into a readable term
f02t(v(K,P),CLP,T) :-
	(   % just a constant
	    P = []
	->  T = K
	;   compare_d(CLP, =, K, 1) % K =:= 1
	->  p2term(P,CLP,T)
	;   compare_d(CLP, =, K, -1) % K =:= -1
	->  T = -Pt,
	    p2term(P,CLP,Pt)
	;   T = K*Pt,
	    p2term(P,CLP,Pt)
	).

% f02t(v(K,P),T,Op)
%
% transforms a next element of the normal form (something of the form v(K,P))
% into a readable term
fn2t(v(K,P),CLP,Term,Op) :-
	(   compare_d(CLP, =, K, 1) % K =:= 1
	->  Term = Pt,
	    Op = +
	;   compare_d(CLP, =, K, -1) % K =:= -1
	->  Term = Pt,
	    Op = -
	;   K < 0 % K < 0
	->  Kf is -K,
	    Term = Kf*Pt,
	    Op = -
	;   % K > 0
	    Term = K*Pt,
	    Op = +
	),
	p2term(P,CLP,Pt).

% transforms the P part in v(_,P) into a readable term
p2term([X^P|Xs],CLP,Term) :-
	(   Xs = []
	->  pe2term(CLP,X,Xt),
	    exp2term(P,Xt,Term)
	;   Xs = [_|_]
	->  Term = Xst*Xtp,
	    pe2term(CLP,X,Xt),
	    exp2term(P,Xt,Xtp),
	    p2term(Xs,CLP,Xst)
	).

%
exp2term(1,X,X) :- !.
exp2term(-1,X,1/X) :- !.
exp2term(P,X,Term) :-
	% Term = exp(X,Pn)
	Term = X^P.

pe2term(_,X,Term) :-
	var(X),
	Term = X.
pe2term(CLP,X,Term) :-
	nonvar(X),
	X =.. [F|Args],
	pe2term_args(Args,CLP,Argst),
	Term =.. [F|Argst].

pe2term_args([],_,[]).
pe2term_args([A|As],CLP,[T|Ts]) :-
	nf2term(A,CLP,T),
	pe2term_args(As,CLP,Ts).

		 /*******************************
		 *	       SANDBOX		*
		 *******************************/
:- multifile
	sandbox:safe_primitive/1.

sandbox:safe_primitive(nf_r:{_}).
sandbox:safe_primitive(nf_r:entailed(_)).

