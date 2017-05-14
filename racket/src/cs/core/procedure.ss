(define-values (prop:method-arity-error method-arity-error? method-arity-error-ref)
  (make-struct-type-property 'method-arity-error))

(define-values (prop:procedure procedure-struct? procedure-struct-ref)
  (make-struct-type-property 'procedure (lambda (v info)
                                          (if (exact-integer? v)
                                              (+ v (let ([p (list-ref info 6)])
                                                     (if p
                                                         (struct-type-field-count p)
                                                         0)))
                                              v))))

(define (procedure? v)
  (or (chez:procedure? v)
      (and (record? v)
           (struct-property-ref prop:procedure (record-rtd v) #f))))

(define apply
  (case-lambda
    [(proc args)
     (if (chez:procedure? proc)
         (chez:apply proc args)
         (chez:apply (extract-procedure proc) args))]
    [(proc . argss)
     (if (chez:procedure? proc)
         (chez:apply chez:apply proc argss)
         (chez:apply chez:apply (extract-procedure proc) argss))]))

(define-syntax |#%app|
  (syntax-rules ()
    [(_ rator rand ...)
     ((extract-procedure rator) rand ...)]))

(define (extract-procedure f)
  (cond
   [(chez:procedure? f) f]
   [else (or (try-extract-procedure f)
             (not-a-procedure f))]))

(define (try-extract-procedure f)
  (cond
   [(record? f)
    (let* ([v (struct-property-ref prop:procedure (record-rtd f) #f)])
      (cond
       [(procedure? v) (case-lambda
                         [(a) (v f a)]
                         [(a b) (v f a b)]
                         [(a b c) (v f a b c)]
                         [args (apply v f args)])]
       [(fixnum? v)
        (let ([v (unsafe-struct-ref f v)])
          (if (chez:procedure? v)
              v
              (try-extract-procedure v)))]
       [else #f]))]
   [else #f]))

(define (procedure-arity-includes? orig-f orig-n)
  (cond
   [(chez:procedure? orig-f)
    (unless (exact-nonnegative-integer? orig-n)
      (raise-argument-error 'procedure-arity-includes? "exact-nonnegative-integer?" orig-n))
    (bitwise-bit-set? (procedure-arity-mask orig-f) orig-n)]
   [else
    (let arity-includes? ([f orig-f] [n orig-n])
      (cond
       [(chez:procedure? f)
        (cond
         [(exact-nonnegative-integer? n)
          (bitwise-bit-set? (procedure-arity-mask f) n)]
         [(exact-nonnegative-integer? orig-n)
          #f]
         [else
          (raise-argument-error 'procedure-arity-includes? "exact-nonnegative-integer?" orig-n)])]
       [(record? f)
        (let* ([v (struct-property-ref prop:procedure (record-rtd f) #f)])
          (cond
           [(fixnum? v)
            (arity-includes? (unsafe-struct-ref f v) n)]
           [else
            (arity-includes? v (if (exact-integer? n)
                                   (add1 n)
                                   n))]))]
       [else
        (raise-argument-error 'procedure-arity-includes? "procedure?" orig-f)]))]))

(define (procedure-arity orig-f)
  (cond
   [(chez:procedure? orig-f)
    (mask->arity (procedure-arity-mask orig-f))]
   [else
    (let proc-arity ([f orig-f] [shift 0])
      (cond
       [(chez:procedure? f)
        (mask->arity (bitwise-arithmetic-shift-right (procedure-arity-mask f) shift))]
       [(record? f)
        (let* ([rtd (record-rtd f)]
               [v (struct-property-ref prop:procedure rtd #f)])
          (cond
           [(fixnum? v)
            (proc-arity (unsafe-struct-ref f v) shift)]
           [else
            (proc-arity v (add1 shift))]))]
       [else
        (raise-argument-error 'procedure-arity "procedure?" orig-f)]))]))

(define (mask->arity mask)
  (let loop ([mask mask] [pos 0])
    (cond
     [(= mask 0) null]
     [(= mask -1) (arity-at-least pos)]
     [(bitwise-bit-set? mask 0)
      (let ([rest (loop (bitwise-arithmetic-shift-right mask 1) (add1 pos))])
        (cond
         [(null? rest) pos]
         [(pair? rest) (cons pos rest)]
         [else (list pos rest)]))]
     [else
      (loop (bitwise-arithmetic-shift-right mask 1) (add1 pos))])))

;; Public, limited variant:
(define (procedure-extract-target f)
  (cond
   [(record? f)
    (let* ([rtd (record-rtd f)]
           [v (struct-property-ref prop:procedure rtd #f)])
      (cond
       [(fixnum? v)
        (let ([v (unsafe-struct-ref f v)])
          (and (chez:procedure? v) v))]
       [else #f]))]
   [else #f]))

(define (not-a-procedure f)
  (error 'apply (format "not a procedure: ~s" f)))

;; ----------------------------------------

(define-record named-procedure (proc name))

;; ----------------------------------------

(define-record procedure-impersonator impersonator (wrapper))
(define-record procedure-chaperone chaperone (wrapper))

(define-record procedure*-impersonator procedure-impersonator ())
(define-record procedure*-chaperone procedure-chaperone ())

(define-values (impersonator-prop:application-mark application-mark? application-mark-ref)
  (make-impersonator-property 'application-mark))

(define (impersonate-procedure proc wrapper . props)
  (do-impersonate-procedure 'impersonate-procedure make-procedure-impersonator proc wrapper
                            make-props-procedure-impersonator props
                            values ""))

(define (chaperone-procedure proc wrapper . props)
  (do-impersonate-procedure 'chaperone-procedure make-procedure-chaperone proc wrapper
                            make-props-procedure-chaperone props
                            values ""))

(define (impersonate-procedure* proc wrapper . props)
  (do-impersonate-procedure 'impersonate-procedure* make-procedure*-impersonator proc wrapper
                            make-props-procedure-impersonator props
                            (lambda (n) (bitwise-arithmetic-shift-right n 1)) " (adding an extra argument)"))

(define (chaperone-procedure* proc wrapper . props)
  (do-impersonate-procedure 'chaperone-procedure* make-procedure*-chaperone proc wrapper
                            make-props-procedure-chaperone props
                            (lambda (n) (bitwise-arithmetic-shift-right n 1)) " (adding an extra argument)"))

(define (do-impersonate-procedure who make-procedure-impersonator  proc wrapper
                                  make-props-procedure-impersonator props
                                  arity-shift arity-shift-str)
  (unless (procedure? proc)
    (raise-argument-error who "procedure?" proc))
  (when wrapper
    (unless (procedure? wrapper)
      (raise-argument-error who "procedure?" wrapper))
    (let ([m (procedure-arity-mask proc)])
      (unless (= m (bitwise-and m (arity-shift (procedure-arity-mask wrapper))))
        (raise-arguments-error who
                               (string-append
                                "arity of wrapper procedure does not cover arity of original procedure"
                                arity-shift-str)
                               "wrapper" wrapper
                               "original" proc))))
  (let ([val (if (impersonator? proc)
                 (impersonator-val proc)
                 proc)]
        [props (add-impersonator-properties who
                                            props
                                            (if (impersonator? proc)
                                                (impersonator-props proc)
                                                empty-hasheq))])
    (if wrapper
        (make-procedure-impersonator val proc props wrapper)
        (make-props-procedure-impersonator val proc props))))

(define (call-with-application-mark props k)
  (let ([mark (hamt-ref props impersonator-prop:application-mark #f)])
    (cond
     [(pair? mark)
      (call-with-immediate-continuation-mark
       (car mark)
       (lambda (v)
         (if (eq? v none)
             (k mark #f #f)
             (k mark #t v)))
       none)]
     [else
      (k #f #f #f)])))
               
(define (impersonate-apply proc . args)
  (let ([n (length args)])
    (cond
     [(not (procedure-arity-includes? (impersonator-val proc) n))
      ;; Let primitive application complain:
      (|#%app| (impersonator-val proc) args)]
     [else
      ;; Loop through wrappers so that `{chaperone,impersonate}-procedure*`
      ;; wrappers can receive the original `proc` argument:
      (let loop ([p proc] [args args])
        (cond
         [(or (procedure-impersonator? p)
              (procedure-chaperone? p))
          ;; Check for `impersonator-prop:application-mark`, since we'll need
          ;; to grab any immediately available mark in that case
          (call-with-application-mark
           (impersonator-props p)
           ;; The `mark-pair` argument is the `impersonator-prop:application-mark` value,
           ;; and `has-current-mark?` indincates whether `current-mark-val` is the value
           ;; of that mark on the current continuation frame
           (lambda (mark-pair has-current-mark? current-mark-val)
             (let* ([chaperone? (procedure-chaperone? p)]
                    [wrapper (if chaperone?
                                 (procedure-chaperone-wrapper p)
                                 (procedure-impersonator-wrapper p))]
                    [next-p (impersonator-next p)]
                    [new-args
                     ;; Call the wrapper procedure, propagating the current value
                     ;; (if any) of the `impersonator-prop:application-mark`-specified mark
                     (call-with-values
                         (lambda ()
                           (let ([call
                                  (lambda ()
                                    ;; Calling convention is different for `procedure*`
                                    ;; and non-`procedure*` variants:
                                    (if (if chaperone?
                                            (procedure*-chaperone? p)
                                            (procedure*-impersonator? p))
                                        (apply wrapper proc args)
                                        (apply wrapper args)))])
                             ;; Set mark, if any, while calling:
                             (cond
                              [has-current-mark?
                               (with-continuation-mark (car mark-pair) current-mark-val (call))]
                              [else (call)])))
                       list)]
                    [nn (length new-args)]
                    [check
                     (lambda (who args new-args)
                       (when chaperone?
                         (for-each (lambda (e e2)
                                     (unless (chaperone-of? e2 e)
                                       (raise-chaperone-error who e e2)))
                                   args
                                   new-args)))]
                    [continue
                     ;; To continue iretaing through wrappers:
                     (lambda (new-args)
                       (if mark-pair
                           (with-continuation-mark (car mark-pair) (cdr mark-pair)
                             (loop next-p new-args))
                           (loop next-p new-args)))])
               ;; Loop to check for extra post proc or `'mark <key> <val>`
               (let loop ([nn nn] [new-args new-args] [post-proc #f] [pos 0])
                 (cond
                  [(fx= n nn)
                   ;; No more extra results, so `new-args` should match up with `args`:
                   (check '|procedure chaperone| args new-args)
                   (cond
                    [post-proc
                     (call-with-values
                         (lambda () (continue new-args))
                       (lambda results
                         (let ([new-results (call-with-values (lambda () (apply post-proc results)) list)])
                           (unless (= (length results) (length new-results))
                             (raise-result-wrapper-result-arity-error))
                           (check '|procedure-result chaperone| results new-results)
                           (apply values new-results))))]
                    [else
                     (continue new-args)])]
                  [(and (fx> nn n)
                        (not post-proc)
                        (procedure? (car new-args)))
                   ;; Extra procedure result => wrapper to apply to function results
                   (loop (fx1- nn) (cdr new-args) (car new-args) (fx1+ pos))]
                  [(and (fx> nn n)
                        (eq? 'mark (car new-args)))
                   ;; 'mark => wrap call with a continuation mark
                   (unless (fx>= (fx- nn 3) n)
                     (raise-mark-missing-key-or-val-error chaperone? pos next-p wrapper))
                   (with-continuation-mark (cadr new-args) (caddr new-args)
                     (loop (fx- nn 3) (cdddr new-args) post-proc (fx+ pos 3)))]
                  [(fx> nn n)
                   (raise-wrapper-bad-extra-result-error chaperone? pos (car new-args) next-p wrapper)]
                  [else
                   (raise-wrapper-result-arity-error chaperone? proc wrapper n nn)])))))]
         [(impersonator? p)
          (loop (impersonator-next p) args)]
         [else
          (apply p args)]))])))

(define (set-procedure-impersonator-hash!)
  (record-type-hash-procedure (record-type-descriptor procedure-chaperone)
                              (lambda (c hash-code)
                                (hash-code (impersonator-next c))))
  (record-type-hash-procedure (record-type-descriptor procedure-impersonator)
                              (lambda (i hash-code)
                                (hash-code (impersonator-next i)))))

(define (raise-chaperone-error who e e2)
  (raise-arguments-error
   who
   (string-append "non-chaperone result; received an argument"
                  " that is not a chaperone of the original argument")
   "original" e
   "received" e2))

(define (raise-result-wrapper-result-arity-error)
  (raise
   (exn:fail:contract:arity
    (string-append "procedure-result chaperone: result arity mismatch;\n"
                   " expected number of values not received from wrapper on the original procedure's result")
    (current-continuation-marks))))

(define (raise-mark-missing-key-or-val-error chaperone? pos next-p wrapper)
  (raise-arguments-error (if chaperone?
                             '|procedure chaperone|
                             '|procedure impersonator|)
                         (string-append
                          "wrapper's " (nth-str pos) " result needs addition extra results;\n"
                          "  " (nth-str pos) " extra result (before original argument count) needs an additional\n"
                          "  two results after 'mark")
                         "original" next-p
                         "wrapper" wrapper))

(define (raise-wrapper-bad-extra-result-error chaperone? pos v next-p wrapper)
  (raise-arguments-error (if chaperone?
                             '|procedure chaperone|
                             '|procedure impersonator|)
                         (string-append
                          "wrapper's " (nth-str pos) " result is not valid;\n"
                          " " (nth-str pos) " extra result (before original argument count) should be\n"
                          " 'mark" (if (zero? pos)
                                       " or a wrapper for the original procedure's result"
                                       ""))
                         "original" next-p
                         "wrapper" wrapper
                         "received" v))

(define (raise-wrapper-result-arity-error chaperone? proc wrapper expected-n got-n)
  (raise
   (exn:fail:contract:arity
    (string-append
     (if chaperone?
         "procedure chaperone"
         "procedure impersonator")
     ": arity mismatch;\n"
     " expected number of results not received from wrapper on the original\n"
     " procedure's arguments\n"
     "  original: " ((error-value->string-handler)
                     proc
                     (error-print-width))
     "\n"
     "  wrapper: " ((error-value->string-handler)
                    wrapper
                    (error-print-width))
     "\n"
     "  expected: " (number->string expected-n) " or more\n"
     "  received: " (number->string got-n))
    (current-continuation-marks))))

;; ----------------------------------------

(define (set-primitive-applicables!)
  (struct-property-set! prop:procedure
                        (record-type-descriptor position-based-accessor)
                        (lambda (pba s p)
                          (if (and (record? s (position-based-accessor-rtd pba))
                                   (< p (position-based-accessor-field-count pba)))
                              (unsafe-struct-ref s (+ p (position-based-accessor-offset pba)))
                              (error 'struct-ref "bad access"))))

  (struct-property-set! prop:procedure
                        (record-type-descriptor position-based-mutator)
                        (lambda (pbm s p v)
                          (if (and (record? s (position-based-mutator-rtd pbm))
                                   (< p (position-based-mutator-field-count pbm)))
                              (unsafe-struct-set! s (+ p (position-based-mutator-offset pbm)) v)
                              (error 'struct-set! "bad assignment"))))

  (struct-property-set! prop:procedure
                        (record-type-descriptor named-procedure)
                        0)
  (struct-property-set! prop:object-name
                        (record-type-descriptor named-procedure)
                        1)

  (struct-property-set! prop:procedure
                        (record-type-descriptor procedure-chaperone)
                        impersonate-apply)
  (struct-property-set! prop:procedure
                        (record-type-descriptor procedure-impersonator)
                        impersonate-apply)
  (struct-property-set! prop:procedure
                        (record-type-descriptor procedure*-chaperone)
                        impersonate-apply)
  (struct-property-set! prop:procedure
                        (record-type-descriptor procedure*-impersonator)
                        impersonate-apply))