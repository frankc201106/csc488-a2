#lang racket #| Compile A2's Language L2 to Language X2 |#

(provide L2→X2
         Mac? heap-size postamble)

(require "A2.L2.rkt")
(require "A2.L1.rkt")
(require "A2.L0.rkt")
(require "A2.M0.rkt")

(module+ test (require rackunit))

; Whether to emit code for the Mac, that Apple's gcc wrapper for clang handles. |#
(define Mac? (make-parameter #true))

; Size of the heap.
(define heap-size (make-parameter (/ (* 4 (expt 2 30)) 8))) ; 4G of 8-byte data.

; Code to append to main.
;
; If you put the resulting assembly code into a file file.s then the following postamble
;  prints the execution time and lowest byte of the result to the console if run with:
;   gcc -o file file.s ; time ./file ; echo $?
;
(define postamble (make-parameter "movq %rcx, %rax")) ; Return result.

#| X2
   ==
 Language X2 is a subset of 64-bit x86 assembly language, which we'll emit in the AT&T syntax.
 Details are in the rest of this file. |#

#| Machine Model
   =============
 Our current model of execution has a few global variables, which are frequently accessed and updated,
  and a stack with frequent stack-like operations. Many machine architectures provide the following
  model, and optimize for this pattern of use.

 The Model
 ---------
 Program: a sequence of statements.
 Execution: sequential, except after a statement that explicitly sets the current statement address.
 State: a fixed set of global variables, a stack, a large array, and a current statement address. |#

#| Global Variables
   ================
 The global variables in a CPU are called registers.

 From our point of view the general purpose X2 registers are all interchangeable. We'll use:

   register : use
   --------------
   a        : temporary variable
   c        : expression result
   10       : next location to allocate in heap
   11       : current environment

 In 64-bit x86 with the AT&T syntax we refer to them as %rax, %rcx, %r10, and %r11.
 The names are not meaningful so let's hide them. |#

(define (register name) (~a '% name))
(define temp   (register 'rax))
(define result (register 'rcx))
(define next   (register 'r10))
(define env    (register 'r11))

#| Setting and Accessing Registers
   =============================== |#

(module+ test
  ; result = temp
  (check-equal? (movq temp result) "movq %rax, %rcx")
  ; result += temp
  (check-equal? (addq temp result) "addq %rax, %rcx"))

(define (movq from to) (~a 'movq " " from   ", " to))
(define (addq from to) (~a 'addq " " from   ", " to))
(define (imulq from to) (~a 'imulq " " from ", " to))

#| Integer Constants
   =================
 Integer constants are prefixed with "$".
 They can appear as ‘from’ in movq and addq. |#

(module+ test
  ; temp = 488
  (check-equal? (movq (constant 488) temp) "movq $488, %rax"))

(define (constant i) (~a '$ i))

#| Addresses of Statements
   =======================
 We can refer to the address of a statement by putting a label before the statement, and
  then use the label. In particular, we can change the execution order by jumping to a
  statement's address.

 We wont jump to [as opposed to call] stored locations, only explicit labels.

 To increase portability and flexibility, without much effort, we'll “mangle” labels by
  potentially adding an underscore [for the Mac's gcc wrapper around clang], and make them
  relative to the current instruction pointer [reasons and details aren't important for us]
  This does make them count as offset dereferences, and the limitation of the previous
  section applies. |#

; main()
;   temp = make_add
;   goto main
#;(labelled 'main
            (movq (label-reference 'make_add) temp)
            (jmp 'main))

(define (mangle name) (~a (if (Mac?) '_ "") name))
(define (labelled name . lines) (list (~a (mangle name) ':)
                                      lines))
(define (label-reference name) (~a (mangle name) "@GOTPCREL(%rip)"))

(define (jmp-label name) (~a 'jmp " " (mangle name)))

#| The Stack
   =========
 We can push a value [constant, or contents of a register], and pop a value into a register.

 Also, we can “call” a statement address [see “Addresses of Statements” below] that's stored
  in a register, which:
    1. Pushes the address of the statement that follows the call.
    2. Jumps to the address that's in the register.

 Coversely, we can “return”, which pops an address that's stored on the stack and jumps to it. |#

(define (pushq from) (~a 'pushq " "   from))
(define (popq  to)   (~a 'popq  " "   to))
(define (callq from) (~a 'call  " *(" from ")"))
(define (retq)       (~a 'retq))

#| Dereferencing and Pointer Arithmetic
   ====================================
 We'll store 64-bit data in our heap: the nth piece of data at an address is 8×n bytes after it.

 We can dereference a register containing an address, with an optional offset.
 Most ‘from’s or ‘to’s in the statements we're using can be a dereference, but not at the same time
  in a single statement. |#

(module+ test
  ; result = temp[0]
  (check-equal? (movq (★ temp) result) "movq 0(%rax), %rcx")
  ; result[488] = temp
  (check-equal? (movq temp (★ result 488)) "movq %rax, 3904(%rcx)"))

(define (⊕ offset) (* 8 offset))
(define (★ register [offset 0]) (~a (⊕ offset) "(" register ")"))

#| Conditional Execution
   =====================
 We can jump to an address conditionally, in particular on condition that two values are equal.
 Comparison sets a CPU flag, that various jump instructions react to.

 For comparison to a constant, the constant must be the first argument.

 We wont jump to calculated locations, only explicit labels. |#

; if (temp == result) goto main
#;(list (cmpq temp result)
        (je 'main))

(define (cmpq from-1 from-2) (~a 'cmpq " " from-1 ", " from-2))
(define (je-label name) (~a 'je " " (mangle name)))

#| L2 Statement to X2
   ==================
 Implement the seven functions needed to translate an L2 statement to an X2 statement or
  [possibly nested] list of statements.

 The nesting of the list structure is irrelevant: L2→X2 will flatten the results. |#

(define (l2→X2 l2) (match l2
                     [`(L2: set_result ,<i>) (set_result <i>)]
                     [`(L2: push_result) (push_result)]
                     [`(L2: closure ,<name>) (closure <name>)]
                     [`(L2: call) (call)]
                     [`(L2: variable ,<n>) (variable <n>)]
                     [`(L2: set ,<n>) (set <n>)]
                     [`(L2: label ,<name>) (label <name>)]
                     [`(L2: jump ,<name>) (jump <name>)]
                     [`(L2: jump_false ,<name>) (jump_false <name>)]))

; Set result to integer i.
(define (set_result i)
  (movq (constant i) result))

; Push result onto the stack.
(define (push_result)
  (pushq result))

; Put a closure on the heap.
;   A closure is a pair of body address and an env.
;   The closure is put at the address referred to by next, and then next is adjusted
;    to point to the next place to put a pair.
(define (closure name)
  (list (movq (label-reference name) temp)
        (movq temp (★ next))
        (movq env (★ next 1))
        (movq next result)
        (addq (constant 16) next)))

; Call the closure that's on the stack, with the argument that's in result.
;   Temporarily stores env on the stack.
;   Sets env to a new environment containing the closure's environment and the argument.
;   Calls the closure.
(define (call)
  (list
   (popq temp) ; closure[0] = func_ptr and closure[1] = closure_env_ptr
   (pushq env)
   ; --- Making and changing into new environment ---
   (movq (★ temp 1) env) ; next[0] = temp[1] or closure_env_ptr
   (movq env (★ next 0))
   (movq result (★ next 1)) ; next[1] = result or argument
   (movq next env) ; env = next, we want env[0] == f and env[1] == closure_env_ptr
   (addq (constant 16) next)
   ; --- End Making and changing into new environment ---
   (callq temp)
   (popq env)))

; Puts the value of the variable n levels up from env, into result.
;   To “loop” n times: emits n statements.
(define (variable n)
  (append
   (list (movq env temp))
   (build-list n (λ (_) (movq (★ temp) temp)))
   (list (movq (★ temp 1) result))))

; Sets the variable n levels up from env, to the value of result.
;   To “loop” n times: emits n statements.
(define (set n)
  (append
   (list (movq env temp))
   (build-list n (λ (_) (movq (★ temp) temp)))
   (list (movq result (★ temp 1)))))

; Names the current statement address.
(define (label name)
  (labelled name))

; Jumps to a named statement address.
(define (jump name)
  (jmp-label name))

; Jumps to a named statement address, if result is false.
;   False is represented by 0.
(define (jump_false name)
  (list
   (cmpq (constant 0) result)
   (je-label name)))

#| L2 to X2
   ======== |#

(define (L2→X2 compiled)
  (match-define (compiled:L2 code λs) compiled)
  (map (curryr ~a "\n")
       (flatten (list (~a '.globl "  " (mangle 'main))
                      RTL
                      (map λ→X2 λs)
                      (labelled 'main
                                (movq (label-reference 'heap) next)
                                (map l2→X2 code)
                                (postamble)
                                (retq))
                      (~a '.comm  "  " (mangle 'heap) "," (heap-size) "," (if (Mac?) 4 32))))))

; For a compiled λ from L2: the code for its body, including a return, labelled by the name of the λ.
(define (λ→X2 a-λ) (labelled (first a-λ)
                             (map l2→X2 (second a-λ))
                             (retq)))


#| Runtime Library
   =============== |#

; Addition and Multiplication
; ---------------------------

; Roughly, we've been treating addition as if it's:
#;(define + (λ_make_add (variable_1)
                        (λ_add (variable_0)
                               (primitive-addition variable_0 variable_1))))
(define (make_add)
  (labelled
   'make_add
   (closure 'add)
   (retq)))

(define (add)
  (labelled
   'add
   (variable 0)
   (pushq result)
   (variable 1)
   (popq temp)
   (addq temp result)
   (retq)))

(define (make_multiply)
  (labelled
   'make_multiply
   (closure 'multiply)
   (retq)))

(define (multiply)
  (labelled
   'multiply
   (variable 0)
   (pushq result)
   (variable 1)
   (popq temp)
   (imulq temp result)
   (retq)))

; L1→L2 translates ‘+’ to a statement that creates a make_add closure.
(module+ test
  (check-equal? (L1→L2 '(L1: var +)) (compiled:L2
                                      '((L2: closure make_add))
                                      '())))

; Put X2 versions of make_add and add in RTL below.
; Similarly, find the 64-bit x86 instruction for multiplication, and add multiplication.

; Escape Continuations
; --------------------

; The continuation of an expression is:
;
;   The state of the heap, and the stack and env before the expression begins evaluating,
;    and the address of the statement after the expression's statements, with that statement
;    waiting to work with the result.

; Write out the compilation of (call/ec f) to convince yourself that the continuation of
;  that expression is on the stack. And convince yourself that setting the result to v
;  and executing a return with the stack in that state continues as if the value of
;  (call/ec f) is v [and any side-effects until then are in the heap and persist].

; (call/ec f) calls f with an escape continuation k, where (k v) escapes the evaluation
;  of (call/ec f) to produce v. Roughly, we treat call/ec as:
#;(λ_call_ec (f) (f ((λ_make_ec (saved-stack-pointer)
                                (λ_ec (result) (set! stack-pointer saved-stack-pointer)
                                      result))
                     stack-pointer)))

#;(define (call/ec f)
    (define current-stack-pointer stack-pointer)
    (define k (λ (r)
                (set! stack-pointer current-stack-pointer)
                (set! result r)))
    (f k))
#;(define (call/ec f)
    (define current-stack-pointer stack-pointer)
    (f (λ (r)
         (set! stack-pointer current-stack-pointer)
         (set! result r))))

#; (define (call/ec f)
     (f ((λ (sp) (λ (r)
                   (set! stack-pointer sp)
                   (set! result r)))
         stack-pointer)))


; The CPU's stack pointer is a register:
(define stack-pointer (register 'rsp))

; A2's L1→L2 translates ‘call/ec’ to a statement that creates a call_ec closure.
(module+ test
  (check-equal? (L1→L2 '(L1: var call/ec)) (compiled:L2
                                            '((L2: closure call_ec))
                                            '())))
(define (ec)
  (labelled
   'ec
   (variable 1) ; move sp to result
   (movq result stack-pointer) ; stack-pointer = result
   (variable 0) ; result = r
   (retq)))

(define (make_ec)
  (labelled
   'make_ec
   (closure 'ec) ; create closure_ec and put it into result
   (retq)))

(define (call_ec)
  (labelled
   'call_ec
   (variable 0)
   (pushq result) ; stack: [f] 
   (closure 'make_ec)
   (pushq result) ; stack [f closure_make_ec]
   (movq stack-pointer result)
   (call) ; after this: result = ((closure make_ec) stack-pointer)
   (call)
   (retq)))



; Put X2 versions of call_ec, make_ec, and ec in RTL below.

; Booleans
; --------
; As mentioned earlier, we're representing false by the value 0.
; We'll represent true by non-zero values.

; Roughly, we've been treating “less than” as if it's:
#;(define < (λ_make_less_than (variable_1)
                              (λ_less_than (variable_0)
                                           (primitive-less-than variable_1 variable_0))))

; L1→L2 translates ‘<’ to a statement that creates a make_less_than closure.
(module+ test
  (check-equal? (L1→L2 '(L1: var <)) (compiled:L2
                                      '((L2: closure make_less_than))
                                      '())))


(define (make_less_than)
  (labelled
   'make_less_than
   (closure 'less_than)
   (retq)))

(define (less_than)
  (labelled
   'less_than
   (variable 0)
   (pushq result)
   (variable 1)
   (popq temp)
   (cmpq temp result)
   (setl result-byte)
   (movzbq result-byte result)
   (retq)))

; The CPU flags set by a comparison can be stored as a byte, which we then “widen” to a 64 bit value.
; if result < temp
;    result = 1
; else
;    result = 0
#;(list (cmpq temp result)
        (setl result-byte)
        (movzbq result-byte result))

(define (setl to) (~a 'setb  " " to))
(define result-byte (register 'cl))
(define (movzbq from-1 from-2) (~a 'movzbq " " from-1 ", " from-2))

; Put X2 versions of make_less_than and less_than in RTL below.
(define RTL (list (make_add)
                  (add)
                  (make_less_than)
                  (less_than)
                  (make_multiply)
                  (multiply)
                  (call_ec)
                  (make_ec)
                  (ec)))

#;(module+ test
    (check-equal?
     (L1→L2 (L0→L1 (M0→L0
                    '(not 0))))
     (compiled:L2
      '((L2: closure lambda_0) (L2: push_result) (L2: closure lambda_1) (L2: call))
      '((lambda_0 ((L2: variable 0) (L2: push_result) (L2: set_result 0) (L2: call)))
        (lambda_1
         ((L2: variable 0)
          (L2: jump_false else_0)
          (L2: set_result 0)
          (L2: jump end_0)
          (L2: label else_0)
          (L2: set_result 1)
          (L2: label end_0))))))
    (check-equal?
     (L1→L2 (L0→L1 (M0→L0
                    '(not 5))))
     (compiled:L2
      '((L2: closure lambda_0) (L2: push_result) (L2: closure lambda_1) (L2: call))
      '((lambda_0 ((L2: variable 0) (L2: push_result) (L2: set_result 5) (L2: call)))
        (lambda_1
         ((L2: variable 0)
          (L2: jump_false else_0)
          (L2: set_result 0)
          (L2: jump end_0)
          (L2: label else_0)
          (L2: set_result 1)
          (L2: label end_0)))))))

; Passed
; Cond without else
(define simple-cond-testcase '((λ (x)
                                 (cond [(= x 34) 100]
                                       [(= x 43) 101]))
                               (- 45 2)))
; Passed
; let with 2 inits
(define simple-let-testcase '(let ([x 100] [y 130])
                               (+ x y)))

; Passesd
; let with 2 inits and a curried function call
(define simple-let-testcase2 '(let ([x 99] [y 488]) ((λ (x y) 0 1) 99 100)))
; Passed
(define simple-let-testcase3 '(let ([x 99] [y 488]) ((λ (x y) 0 y) 99 100)))


; local
; local w/ 1 init and 1 body
(define local-testcase0 '(local [(define (f a)
                                   100)]
                           (f 0)))
(define local-testcase1 '(local [(define (f a)
                                   (< 1 101))]
                           (f 0)))
(define local-testcase2 '(local [(define (f a)
                                   (+ 1 101))]
                           (f 0)))
(define local-testcase3 '(local [(define (f a)
                                   (not 1))]
                           (f 0)))
(define local-testcase4 '(local [(define (f a)
                                   (⊖ 1))]
                           (f 0)))
(define local-testcase5 '(local [(define (f a)
                                   (- 0 2))]
                           (f 0)))

(define local-testcase6 '(local [(define (f a)
                                   (= 2 2))]
                           (f 0)))

(define local-testcase7 '(local [(define (f a)
                                   (and (>= 2 2) (> 2 1)))]
                           (f 0)))

(define naive-fib '(local [(define (fib n)
                             (cond [(= n 1) 1]
                                   [(= n 2) 1]
                                   [else (+ (fib (- n 1))
                                            (fib (- n 2)))]))]
                     (fib 20)))

(define less-than-testcase '(< 2 3))

(define while-fib '(let ([x 20] [f1 1] [f2 1] [answer 0] [count 3])
                     (while (< count (+ x 1))
                            (set! answer (+ f1 f2))
                            (set! f1 f2)
                            (set! f2 answer)
                            (set! count (+ count 1)))
                     answer))

(define while2 '(let ([n 0])
                  (while (< n 14)
                         (set! n (+ n 1)))
                  n))

(define when-simple-t '(when (= 10 10)
                         42))

(define when-simple-f '(when (= 10 11)
                         42))

(define break1 '(let ([n 0])  
                  (when (= n 0)
                    (breakable (break 42)))))

(define break2 '(let ([n 0])  
                  (breakable (let ([n 0])
                               (while (< n 14)
                                      (set! n (+ n 1))
                                      (when (= n 10)
                                        (break n)))))))

(define return '(let ([n 0])  
                  (returnable (let ([n 0])
                                (while (< n 14)
                                       (set! n (+ n 1))
                                       (when (= n 10)
                                         (return n)))))))

(define continue '(let ([n 0] [hit 0])
                    (while (< n 14)
                           (continuable
                            (when (= n 10)
                              (set! hit (+ hit 1))
                              (set! n (+ n 1))
                              (continue n)))
                           (set! n (+ n 1)))
                    hit))

(define multi-exec '(let ([n 0])
                      (>> (set! n (+ n 1))
                          (set! n (+ n 1))
                          (set! n (+ n 1)))
                      n))

(define maybe-monad '(let ([n 0])
                       (>>= (set! n (+ n 1))
                            (set! n (+ n 2))
                            0
                            (set! n (+ n 3)))
                       n))

(define mixed-in '(cond [(and (>= 2 3) (> 2 3)) 0]
                        [(or (>= 2 3) (> 2 3)) 1]
                        [else (⊖ 1)]))

(define sigma1 '(Σ j 0 3 j))

(define sigma2 '(Σ j 0 3 (* j j)))

(define out (open-output-file "file.s" 	#:exists 'replace))
(define assembly (L2→X2 (L1→L2 (L0→L1 (M0→L0 sigma2)))))
(map (λ (x) (display x out)) assembly)
(close-output-port out)
