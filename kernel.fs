\ kernel.fs -- the high-level half of the Forth kernel. kernel.lisp metacompiles this file
\ into flash: each : definition becomes a header plus a list of execution tokens. Control
\ words (if, begin, do, ...) and ['] [char] ." s" recurse are resolved by the metacompiler
\ here; the immediate words of the same names below compile code at run time on the chip.
\ Console protocol and word set follow Mecrisp-Stellaris, so lisp.fs loads unchanged.

: true -1 ;
: false 0 ;
: bl 32 ;
: here dp @ ;
: allot dp +! ;
: , here ! 4 allot ;
: c, here c! 1 allot ;
: aligned 3 + -4 and ;
: align here aligned dp ! ;
: unused dict-limit here - ;
: hex 16 base ! ;
: decimal 10 base ! ;
: within ( n lo hi -- f ) over - >r - r> u< ;
: /string ( a n k -- a+k n-k ) rot over + -rot - ;

\ ---- output ----
: cr 10 emit ;
: space bl emit ;
: type ( a n -- ) 0 ?do dup c@ emit 1+ loop drop ;
: <# padend hld ! ;
: hold ( c -- ) -1 hld +! hld @ c! ;
: digit ( n -- c ) dup 9 > if 7 + then 48 + ;
: # ( lo hi -- lo' hi ) >r base @ u/mod swap digit hold r> ;
: #s ( lo hi -- 0 hi ) begin # over 0= until ;
: #> ( lo hi -- a n ) 2drop hld @ padend over - ;
: sign ( n -- ) 0< if 45 hold then ;
: u. 0 <# #s #> type space ;
: . dup abs 0 <# #s rot sign #> type space ;
: .s depth begin dup 0> while dup pick . 1- repeat drop ;
: words latest @ begin dup while dup 5 + count type space @ repeat drop cr ;

\ ---- input ----
: accept ( addr max -- len ) >r 0
  begin key dup 13 = over 10 = or 0= while
    dup 8 = over 127 = or
    if drop dup if 1- 8 emit space 8 emit then
    else dup 9 = if drop 32 then
      over r@ < if dup emit 2 pick 2 pick + c! 1+ else drop then
    then
  repeat drop rdrop nip space ;
: query tib 512 accept #tib ! 0 >in ! ;
: token ( -- addr len )
  tib >in @ +  tib #tib @ +  swap
  begin 2dup > if dup c@ 33 < else 0 then while 1+ repeat
  dup begin 2 pick over > if dup c@ 32 > else 0 then while 1+ repeat
  rot over > if dup 1+ else dup then tib - >in !  over - ;
: parse ( c -- addr len ) >r tib >in @ + tib #tib @ + over
  begin 2dup > if dup c@ r@ <> else 0 then while 1+ repeat rdrop
  tuck > if dup 1+ else dup then tib - >in ! over - ;

\ ---- dictionary ----
: upc ( c -- C ) dup 97 123 within if 32 - then ;
: name= ( a1 n1 a2 n2 -- f ) rot over <> if 2drop drop 0 exit then
  0 ?do over i + c@ upc over i + c@ upc <> if 2drop 0 unloop exit then loop 2drop -1 ;
: >xt ( header -- xt ) 5 + count + aligned ;
: find ( addr len -- xt 1|-1 | addr len 0 )
  latest @ begin dup while
    dup 4 + c@ 64 and 0= if
      >r 2dup r@ 5 + count name= if 2drop r@ >xt r> 4 + c@ 128 and if 1 else -1 then exit then r>
    then @
  repeat ;
: header ( addr len -- ) 2dup find if drop ."  Redefine " 2dup type ." . " else 2drop then
  align here latest @ , latest ! 0 c, dup c, here swap dup allot move align ;
: hide latest @ 4 + dup c@ 64 or swap c! ;
: reveal latest @ 4 + dup c@ 64 invert and swap c! ;
: immediate latest @ 4 + dup c@ 128 or swap c! ;

\ ---- numbers ----
: digit? ( c -- n true | false ) upc 48 - dup 9 > if 7 - dup 10 < if drop 0 exit then then
  dup base @ u< if -1 else drop 0 then ;
: number ( addr len -- n true | false )
  base @ >r 0 nneg !
  over c@ 36 = if 16 base ! 1 /string else
  over c@ 35 = if 10 base ! 1 /string else
  over c@ 37 = if 2 base ! 1 /string then then then
  over c@ 45 = if -1 nneg ! 1 /string then
  dup 0= if 2drop r> base ! 0 exit then
  0 -rot begin dup while
    over c@ digit? 0= if 2drop drop r> base ! 0 exit then
    >r rot base @ * r> + -rot 1 /string
  repeat 2drop
  nneg @ if negate then r> base ! -1 ;

\ ---- outer interpreter ----
: abort sp0 sp! quit ;
: notfound ( addr len -- ) space type ."  not found." cr abort ;
: ?stack depth 0< if ."  Stack underflow" cr abort then ;
: interpret
  begin token dup while
    find ?dup if
      state @ if 0< if , else execute then else drop execute then
    else
      2dup number if nip nip state @ if ['] lit , , then else notfound then
    then ?stack
  repeat 2drop ;
: quit rp0 rp! 0 state ! begin query interpret ."  ok." cr again ;
: cold cr ." lisp-forth-lisp Forth kernel for STM32F446 (own Thumb-2 build)" cr quit ;

\ ---- compiler ----
: [ 0 state ! ; immediate
: ] -1 state ! ;
: : token header docol , hide ] ;
: ; ['] exit , reveal [ ; immediate
: ' token find dup 0= if drop notfound then drop ;
: ['] ' ['] lit , , ; immediate
: literal ['] lit , , ; immediate
: [char] token drop c@ ['] lit , , ; immediate
: char token drop c@ ;
: recurse latest @ >xt , ; immediate
: ( 41 parse 2drop ; immediate
: \ #tib @ >in ! ; immediate
: (s",) 34 parse ['] (s") , dup c, here swap dup allot move align ;
: s" state @ if (s",) else 34 parse then ; immediate   \ interpreting: the string stays in the input line
: ." (s",) ['] type , ; immediate
: variable ( x "name" -- ) token header dovar , , ;
: constant ( x "name" -- ) token header docon , , ;
: buffer: ( n "name" -- ) token header dovar , allot align ;
: if ['] 0branch , here 0 , ; immediate
: then here swap ! ; immediate
: else ['] branch , here 0 , swap here swap ! ; immediate
: begin here ; immediate
: until ['] 0branch , , ; immediate
: again ['] branch , , ; immediate
: while ['] 0branch , here 0 , swap ; immediate
: repeat ['] branch , , here swap ! ; immediate
: do ['] (do) , here 0 , here ; immediate
: ?do ['] (?do) , here 0 , here ; immediate
: loop ['] (loop) , , here swap ! ; immediate
: +loop ['] (+loop) , , here swap ! ; immediate
